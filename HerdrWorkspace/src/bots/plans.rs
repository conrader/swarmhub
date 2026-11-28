//! What a bot plans and promises, and what the main bot is told about.
//!
//! - A planned check-in brings a bot back to something: once ("in 30 minutes") or again and again ("every
//!   weekday at 9"). It fires on the server, so no app has to be connected, and the bot's agent is started if it
//!   is not running. A bot's check-ins fire at least `checkin_gap_seconds` apart and a bot has at most
//!   `checkins_per_bot` planned. A one-off always leaves its outcome in the bot's history: what the bot said,
//!   or a line that it did not answer. A recurring one that answers that there is nothing to report leaves
//!   nothing.
//! - A promise is "I will do or report X by T". Done closes it. Overdue, it is raised with the bot once; if it
//!   is still open after `promise_grace_seconds`, the person gets a notice.
//! - A flag is something the main bot is told about, once: at most one note per `initiative_seconds`, and only
//!   while its "Takes initiative" switch is on.
//!
//! Like `rules`, everything here is rows in one transaction; `desk` runs the clocks and does the typing.

use super::{
    Bot, Ctx, notes,
    rules::{About, Post, clean, entry, post, seconds},
};
use chrono::{DateTime, NaiveDate, Utc};
use chrono_tz::Tz;
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

const WHAT_CHARS: usize = 1_000;
/// A flag nobody was told about for this long is no longer news.
const FLAG_AGE_MS: i64 = 3_600_000;
const FLAGS_PER_NOTE: usize = 5;

pub(crate) fn one_line(text: &str, limit: usize) -> String {
    let mut words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if words.chars().count() > limit {
        words = words.chars().take(limit.saturating_sub(1)).collect();
        words.push('…');
    }
    words
}

/// When a check-in fires.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Schedule {
    Ci {
        url: String,
        #[serde(default)]
        failure: Option<String>,
    },
    Once {
        at_ms: i64,
    },
    LocalOnce {
        date: NaiveDate,
        hour: u8,
        minute: u8,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timezone: Option<Tz>,
    },
    Interval {
        seconds: u64,
    },
    Daily {
        hour: u8,
        minute: u8,
        #[serde(default)]
        weekdays: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timezone: Option<Tz>,
    },
}

/// When, as an agent's command or the app says it. Clock times follow the person unless a zone is pinned.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "when", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum When {
    Ci {
        url: String,
    },
    /// "in 30m".
    In {
        seconds: u64,
    },
    /// "at 17:30": the next time the clock shows it.
    At {
        hour: u8,
        minute: u8,
        #[serde(default)]
        timezone: Option<Tz>,
    },
    /// A moment.
    On {
        at_ms: i64,
    },
    /// "every 2h".
    Every {
        seconds: u64,
    },
    /// "every day at 9:00", "every weekday at 9:00".
    Daily {
        hour: u8,
        minute: u8,
        weekdays: bool,
        #[serde(default)]
        timezone: Option<Tz>,
    },
}

impl When {
    #[cfg(test)]
    fn moment(&self, ctx: &Ctx<'_>) -> Option<i64> {
        self.deadline(ctx)?.next(ctx.now, ctx.zone)
    }

    pub(crate) fn deadline(&self, ctx: &Ctx<'_>) -> Option<Schedule> {
        Some(match *self {
            Self::In { seconds: count } => Schedule::Once {
                at_ms: ctx.now.checked_add(seconds(count))?,
            },
            Self::On { at_ms } => Schedule::Once { at_ms },
            Self::At {
                hour,
                minute,
                timezone,
            } => {
                let zone = timezone.unwrap_or(ctx.zone);
                let at_ms = crate::routines::next_local(ctx.now, zone, hour, minute, false)?;
                let date = DateTime::<Utc>::from_timestamp_millis(at_ms)?
                    .with_timezone(&zone)
                    .date_naive();
                Schedule::LocalOnce {
                    date,
                    hour,
                    minute,
                    timezone,
                }
            }
            _ => return None,
        })
    }

    pub(crate) fn schedule(&self, ctx: &Ctx<'_>) -> Option<Schedule> {
        Some(match *self {
            Self::Ci { ref url } => Schedule::Ci {
                url: super::ci::pull_request(url)?,
                failure: None,
            },
            Self::Every { seconds } => Schedule::Interval { seconds },
            Self::Daily {
                hour,
                minute,
                weekdays,
                timezone,
            } => Schedule::Daily {
                hour,
                minute,
                weekdays,
                timezone,
            },
            _ => return self.deadline(ctx),
        })
    }
}

impl Schedule {
    pub(crate) fn recurring(&self) -> bool {
        matches!(self, Self::Daily { .. } | Self::Interval { .. })
    }

    /// When it fires next after `after`. `None` for a one-off whose moment has passed, and for a schedule that
    /// names no time.
    pub(crate) fn next(&self, after: i64, zone: Tz) -> Option<i64> {
        match self {
            Self::Ci { .. } => Some(after),
            Self::Once { at_ms } => (*at_ms > after).then_some(*at_ms),
            Self::LocalOnce { .. } => self.local_at(zone).filter(|at| *at > after),
            Self::Interval { seconds: count } if *count > 0 => after.checked_add(seconds(*count)),
            Self::Interval { .. } => None,
            Self::Daily {
                hour,
                minute,
                weekdays,
                timezone,
            } => crate::routines::next_local(
                after,
                timezone.unwrap_or(zone),
                *hour,
                *minute,
                *weekdays,
            ),
        }
    }

    fn local_at(&self, zone: Tz) -> Option<i64> {
        let Self::LocalOnce {
            date,
            hour,
            minute,
            timezone,
        } = *self
        else {
            return None;
        };
        crate::routines::local_on_date(date, timezone.unwrap_or(zone), hour, minute)
    }

    fn after_move(&self, at: i64, zone: Tz, next_ms: Option<i64>) -> Option<i64> {
        match self {
            Self::Daily { timezone: None, .. } => {
                // Leave a recently due check-in for fire_due to claim.
                let cutoff = crate::routines::schedule_lateness_cutoff(at);
                if next_ms.is_some_and(|due| (cutoff..=at).contains(&due)) {
                    return None;
                }
                self.next(at, zone)
            }
            Self::LocalOnce { timezone: None, .. } => self.local_at(zone).map(|due| due.max(at)),
            _ => None,
        }
    }

    /// "every 30 minutes", "every weekday at 09:00 (Europe/Warsaw)".
    pub(crate) fn words(&self, ctx: &Ctx<'_>) -> String {
        match self {
            Self::Ci { url, .. } => format!("when a check fails on {url}"),
            Self::Once { at_ms } => format!("once, on {}", notes::clock(*at_ms, ctx.zone)),
            Self::LocalOnce { timezone, .. } => format!(
                "once, on {} ({})",
                self.local_at(ctx.zone)
                    .map_or_else(|| "an unknown time".into(), |at| notes::clock(at, ctx.zone)),
                zone_words(*timezone, ctx.zone)
            ),
            Self::Interval { seconds } => format!("every {}", notes::span(*seconds)),
            Self::Daily {
                hour,
                minute,
                weekdays,
                timezone,
            } => format!(
                "every {} at {hour:02}:{minute:02} ({})",
                if *weekdays { "weekday" } else { "day" },
                zone_words(*timezone, ctx.zone)
            ),
        }
    }
}

fn zone_words(pinned: Option<Tz>, user_zone: Tz) -> String {
    pinned.map_or_else(
        || format!("{user_zone}, follows user"),
        |zone| zone.to_string(),
    )
}

/// A planned check-in as the app and `checkin list` show it.
#[derive(Clone, Debug, Serialize)]
pub(crate) struct Checkin {
    pub id: i64,
    pub bot: String,
    pub what: String,
    pub schedule: Schedule,
    /// When it fires next. `null` once a one-off has fired.
    pub next_ms: Option<i64>,
    /// `planned`, `done` (a one-off that fired) or `cancelled`.
    pub state: String,
    /// `bot` or `person`.
    pub planned_by: String,
    pub created_ms: i64,
    pub last_fired_ms: Option<i64>,
    /// How its last firing ended: `reported`, `quiet`, `no_answer`, `not_delivered`; `null` while it is awaited.
    pub last_outcome: Option<String>,
    pub fires: i64,
    /// The bot's "Takes initiative" switch is off, so it does not fire.
    pub paused: bool,
    pub enabled: bool,
    pub control_revision: i64,
}

const CHECKIN: &str = "c.id,c.bot,c.what,c.schedule,c.next_ms,c.state,c.planned_by,c.created_ms,c.last_fired_ms,c.last_outcome,c.fires,
    NOT c.enabled OR NOT coalesce((SELECT takes_initiative FROM bots WHERE id=c.bot),1),c.enabled,c.control_revision";

fn read_checkin(row: &Row<'_>) -> rusqlite::Result<Checkin> {
    Ok(Checkin {
        id: row.get(0)?,
        bot: row.get(1)?,
        what: row.get(2)?,
        schedule: serde_json::from_str(&row.get::<_, String>(3)?)
            .unwrap_or(Schedule::Once { at_ms: 0 }),
        next_ms: row.get(4)?,
        state: row.get(5)?,
        planned_by: row.get(6)?,
        created_ms: row.get(7)?,
        last_fired_ms: row.get(8)?,
        last_outcome: row.get(9)?,
        fires: row.get(10)?,
        paused: row.get(11)?,
        enabled: row.get(12)?,
        control_revision: row.get(13)?,
    })
}

/// A bot's check-ins: the planned ones, soonest first, then (with `all`) the newest that fired or were cancelled.
pub(crate) fn checkins(
    db: &rusqlite::Connection,
    bot: Option<&str>,
    all: bool,
) -> rusqlite::Result<Vec<Checkin>> {
    db.prepare_cached(&format!(
        "SELECT {CHECKIN} FROM bot_checkins c WHERE (?1 IS NULL OR c.bot=?1) AND (?2 OR c.state='planned')
         ORDER BY c.state!='planned', CASE WHEN c.state='planned' THEN c.next_ms END, c.id DESC LIMIT 200"
    ))?
    .query_map(params![bot, all], read_checkin)?
    .collect()
}

/// Plans a check-in for `bot`. An `Err` says which limit refused it.
pub(crate) fn plan(
    ctx: &Ctx<'_>,
    bot: &Bot,
    when: &When,
    what: &str,
    by: &str,
) -> rusqlite::Result<Result<Checkin, String>> {
    let gap = notes::span(ctx.set.checkin_gap_seconds);
    if !bot.takes_initiative {
        return Ok(Err("The person turned off \"Takes initiative\" for you, so no check-in was planned. Tell the person what you would have checked, and when.".into()));
    }
    let Some(what) = clean(what, WHAT_CHARS) else {
        return Ok(Err("Say what to come back to, in words that make sense without this conversation: up to 1000 characters of plain text.".into()));
    };
    let Some(schedule) = when.schedule(ctx) else {
        return Ok(Err(
            "That is not a time a check-in can be planned for.".into()
        ));
    };
    if let Schedule::Interval { seconds } = schedule
        && seconds < ctx.set.checkin_gap_seconds
    {
        return Ok(Err(format!(
            "Check-ins of one bot are at least {gap} apart, so nothing was planned. Use `every {gap}` or longer."
        )));
    }
    let Some(first) = schedule.next(ctx.now, ctx.zone) else {
        return Ok(Err(
            "That time has passed, so nothing was planned. Give a time that is still to come."
                .into(),
        ));
    };
    let planned = checkins(ctx.db, Some(&bot.id), false)?;
    if planned.len() >= ctx.set.checkins_per_bot as usize {
        return Ok(Err(format!(
            "You already have {} check-ins planned, which is the limit, so nothing was planned. Cancel one first: `{} checkin list`, `{} checkin cancel ID`.",
            planned.len(),
            ctx.cmd,
            ctx.cmd
        )));
    }
    let apart = seconds(ctx.set.checkin_gap_seconds);
    if !matches!(schedule, Schedule::Ci { .. })
        && let Some(near) = planned
            .iter()
            .filter(|c| !matches!(c.schedule, Schedule::Ci { .. }))
            .find(|other| {
                other
                    .next_ms
                    .is_some_and(|next| (next - first).abs() < apart)
            })
    {
        return Ok(Err(format!(
            "Check-ins of one bot are at least {gap} apart, and #{} (\"{}\") is planned for {}. Nothing was planned: pick a time at least {gap} away from it, or put both into one check-in.",
            near.id,
            one_line(&near.what, 60),
            notes::clock(near.next_ms.unwrap_or(first), ctx.zone)
        )));
    }
    let fired: Option<i64> = ctx.db.query_row(
        "SELECT max(last_fired_ms) FROM bot_checkins WHERE bot=?1",
        [&bot.id],
        |row| row.get(0),
    )?;
    if !matches!(schedule, Schedule::Ci { .. })
        && let Some(fired) = fired.filter(|fired| first - fired < apart)
    {
        return Ok(Err(format!(
            "Check-ins of one bot are at least {gap} apart, and one fired at {}. Nothing was planned: the earliest time is {}.",
            notes::clock(fired, ctx.zone),
            notes::clock(fired + apart, ctx.zone)
        )));
    }
    let id: i64 = ctx.db.query_row(
        "INSERT INTO bot_checkins (bot,what,schedule,next_ms,planned_by,created_ms) VALUES (?1,?2,?3,?4,?5,?6) RETURNING id",
        params![
            bot.id,
            what,
            serde_json::to_string(&schedule).unwrap_or_default(),
            first,
            by,
            ctx.now
        ],
        |row| row.get(0),
    )?;
    let planned = ctx
        .db
        .prepare_cached(&format!(
            "SELECT {CHECKIN} FROM bot_checkins c WHERE c.id=?1"
        ))?
        .query_row([id], read_checkin)?;
    Ok(Ok(planned))
}

/// Called in the same write transaction as the scheduler's claim. The revision
/// distinguishes a retry from an old request arriving after two newer changes.
pub(crate) fn set_enabled(ctx: &Ctx<'_>, bot: &str, id: i64, enabled: bool, revision: i64)
    -> rusqlite::Result<Result<Checkin, &'static str>> {
    let read = || ctx.db.query_row(&format!("SELECT {CHECKIN} FROM bot_checkins c
        WHERE c.bot=?1 AND c.id=?2 AND c.state='planned'"), params![bot,id], read_checkin).optional();
    let Some(item) = read()? else { return Ok(Err("This bot no longer has this planned check-in.")); };
    if item.enabled == enabled && (item.control_revision == revision || revision.checked_add(1) == Some(item.control_revision)) {
        return Ok(Ok(item));
    }
    if revision != item.control_revision { return Ok(Err("The check-in changed. Refresh before changing it again.")); }
    let recompute = enabled && (item.next_ms.is_none_or(|due| due <= ctx.now)
        || matches!(item.schedule, Schedule::Daily { .. } | Schedule::LocalOnce { .. }));
    let next = if recompute {
        let Some(next) = item.schedule.next(ctx.now, ctx.zone) else {
            return Ok(Err("The one-off time has passed. This check-in remains paused."));
        };
        Some(next)
    } else { item.next_ms };
    ctx.db.execute("UPDATE bot_checkins SET enabled=?3,next_ms=?4,control_revision=control_revision+1
        WHERE id=?1 AND bot=?2 AND state='planned' AND control_revision=?5", params![id,bot,enabled,next,revision])?;
    Ok(read()?.ok_or("The check-in is no longer planned."))
}

/// Cancels a planned check-in of `bot`.
pub(crate) fn cancel(ctx: &Ctx<'_>, bot: &str, id: i64) -> rusqlite::Result<bool> {
    Ok(ctx.db.execute(
        "UPDATE bot_checkins SET state='cancelled',next_ms=NULL WHERE id=?1 AND bot=?2 AND state='planned'",
        params![id, bot],
    )? == 1)
}

/// Fires the check-ins whose time has come: what to do is put into the outbox for the bot's agent. One whose
/// bot fired another less than the gap ago waits for the gap to pass; one whose bot has "Takes initiative" off
/// waits for the switch. Returns how many fired.
pub(crate) fn fire_due(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    let due: Vec<Checkin> = ctx
        .db
        .prepare_cached(&format!(
            "SELECT {CHECKIN} FROM bot_checkins c WHERE c.state='planned' AND c.enabled AND c.next_ms<=?1 AND (json_extract(c.schedule,'$.kind')!='ci' OR json_extract(c.schedule,'$.failure') IS NOT NULL) ORDER BY c.next_ms,c.id LIMIT 64"
        ))?
        .query_map([ctx.now], read_checkin)?
        .collect::<Result<_, _>>()?;
    let mut fired = 0;
    for checkin in due {
        let Some(bot) = super::one(ctx.db, &checkin.bot)? else {
            cancel(ctx, &checkin.bot, checkin.id)?;
            continue;
        };
        if !bot.takes_initiative {
            continue;
        }
        let last: Option<i64> = ctx.db.query_row(
            "SELECT max(last_fired_ms) FROM bot_checkins WHERE bot=?1",
            [&bot.id],
            |row| row.get(0),
        )?;
        if last.is_some_and(|last| ctx.now - last < seconds(ctx.set.checkin_gap_seconds)) {
            continue;
        }
        let recurring = checkin.schedule.recurring();
        let often = recurring.then(|| checkin.schedule.words(ctx));
        let task = match &checkin.schedule {
            Schedule::Ci {
                url,
                failure: Some(link),
            } => format!(
                "A check failed on {url}. Check details: {link}\n{}",
                checkin.what
            ),
            _ => checkin.what.clone(),
        };
        let text = notes::checkin(
            ctx.cmd,
            checkin.id,
            &task,
            often.as_deref(),
            checkin.created_ms,
            ctx.zone,
        );
        post(
            ctx,
            Post {
                bot: &bot.id,
                text: &text,
                cause: "checkin",
                checkin: Some(checkin.id),
                quiet: recurring,
                ..Post::default()
            },
        )?;
        // A recurring one that was due while the server was down fires once, then goes on from now.
        let next = if recurring {
            checkin.schedule.next(ctx.now, ctx.zone)
        } else {
            None
        };
        ctx.db.execute(
            "UPDATE bot_checkins SET last_fired_ms=?2,fires=fires+1,last_outcome=NULL,next_ms=?3,
                    state=CASE WHEN ?3 IS NULL THEN 'done' ELSE state END WHERE id=?1",
            params![checkin.id, ctx.now, next],
        )?;
        fired += 1;
    }
    Ok(fired)
}

/// A check-in that fired and got no answer, or could not be typed at all, is tried once more. When the second
/// try ends the same way it leaves a line for the person (always for a one-off, and for a recurring one the
/// first time in a row) and a flag for the main bot, which can look at the agent's terminal.
pub(crate) fn unanswered(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    let late: Vec<(i64, String, i64, String, Option<String>, String, bool)> = ctx
        .db
        .prepare_cached(
            "SELECT o.id,o.bot,o.checkin,o.state,o.detail,o.text,o.quiet FROM bot_outbox o
             WHERE o.cause='checkin' AND o.outcome IS NULL
               AND (o.state IN ('failed','dropped')
                    OR (o.state IN ('typed','typing') AND coalesce(o.typed_ms,o.created_ms)<=?1))
             ORDER BY o.id",
        )?
        .query_map([ctx.now - seconds(ctx.set.checkin_answer_seconds)], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
                row.get(5)?,
                row.get(6)?,
            ))
        })?
        .collect::<Result<_, _>>()?;
    for (outbox, bot, id, state, detail, text, quiet) in &late {
        let typed = matches!(state.as_str(), "typed" | "typing");
        let outcome = if typed { "no_answer" } else { "not_delivered" };
        ctx.db.execute(
            "UPDATE bot_outbox SET outcome=?2 WHERE id=?1",
            params![outbox, outcome],
        )?;
        let found: Option<(String, String, Option<i64>, Option<String>)> = ctx
            .db
            .query_row(
                "SELECT what,schedule,last_fired_ms,last_outcome FROM bot_checkins WHERE id=?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()?;
        let Some((what, schedule, fired, before)) = found else {
            continue;
        };
        // The first miss of a firing is tried once more before anyone is told: a session that was replaced
        // or was stuck when the first one came often answers the second.
        let tries: i64 = ctx.db.query_row(
            "SELECT count(*) FROM bot_outbox WHERE cause='checkin' AND checkin=?1 AND created_ms>=?2",
            params![id, fired.unwrap_or(0)],
            |row| row.get(0),
        )?;
        if tries < 2 && super::one(ctx.db, bot)?.is_some_and(|bot| bot.takes_initiative) {
            post(
                ctx,
                Post {
                    bot,
                    text: &notes::checkin_again(text, typed),
                    cause: "checkin",
                    checkin: Some(*id),
                    quiet: *quiet,
                    ..Post::default()
                },
            )?;
            continue;
        }
        ctx.db.execute(
            "UPDATE bot_checkins SET last_outcome=?2 WHERE id=?1",
            params![id, outcome],
        )?;
        let again = if tries >= 2 { ", also on a second try" } else { "" };
        let name = notes::line(&super::name_of(ctx.db, bot));
        // At most one flag a day for a check-in, so a recurring one that keeps failing does not fill the notes.
        flag(
            ctx,
            "checkin",
            &format!("checkin:{id}:{}", ctx.now / 86_400_000),
            &format!(
                "The check-in \"{}\" of the bot {name} got no answer{again}. Read {name}'s terminal for what its agent is doing or waiting on.",
                one_line(&what, 160)
            ),
        )?;
        let recurring = serde_json::from_str::<Schedule>(&schedule).is_ok_and(|s| s.recurring());
        if recurring && matches!(before.as_deref(), Some("no_answer" | "not_delivered")) {
            continue;
        }
        let at = notes::clock(fired.unwrap_or(ctx.now), ctx.zone);
        let line = if typed {
            format!(
                "The check-in \"{}\" fired at {at}, but {name}'s agent gave no answer within {}{again}.",
                one_line(&what, 160),
                notes::span(ctx.set.checkin_answer_seconds)
            )
        } else {
            format!(
                "The check-in \"{}\" was due at {at}, but it did not reach {name}'s agent{again}: {}",
                one_line(&what, 160),
                detail.as_deref().unwrap_or("it could not be typed.")
            )
        };
        let about = About {
            code: Some("checkin_unanswered"),
            checkin: Some(*id),
            ..About::default()
        };
        entry(ctx, bot, "notice", &line, about, true, true)?;
    }
    Ok(late.len())
}

/// `checkin list` for an agent.
pub(crate) fn checkin_text(ctx: &Ctx<'_>, bot: &Bot) -> rusqlite::Result<String> {
    let planned = checkins(ctx.db, Some(&bot.id), false)?;
    if planned.is_empty() {
        return Ok(format!(
            "You have no check-ins planned. Plan one: {} checkin in 30m \"WHAT\"",
            ctx.cmd
        ));
    }
    let mut text = format!(
        "Planned check-ins: {} of the {} allowed, at least {} apart.{}",
        planned.len(),
        ctx.set.checkins_per_bot,
        notes::span(ctx.set.checkin_gap_seconds),
        if bot.takes_initiative {
            ""
        } else {
            " They do not fire: the person turned off \"Takes initiative\" for you."
        }
    );
    for checkin in &planned {
        text.push_str(&format!(
            "\n#{} · {} · next {} · {}",
            checkin.id,
            checkin.schedule.words(ctx),
            checkin
                .next_ms
                .map_or_else(|| "never".into(), |next| notes::clock(next, ctx.zone)),
            one_line(&checkin.what, 120)
        ));
    }
    text.push_str(&format!("\nCancel one: {} checkin cancel ID", ctx.cmd));
    Ok(text)
}

// ---- Promises.

#[derive(Clone, Debug, Serialize)]
pub(crate) struct Promise {
    pub id: i64,
    pub bot: String,
    pub what: String,
    pub due_ms: i64,
    /// `open`, `raised` (overdue, and the bot was told), `overdue` (the person was told), `done`, `dropped`.
    pub state: String,
    pub created_ms: i64,
    pub raised_ms: Option<i64>,
    pub overdue_ms: Option<i64>,
    pub closed_ms: Option<i64>,
    pub note: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub local_schedule: Option<Schedule>,
}

const PROMISE: &str =
    "id,bot,what,due_ms,state,created_ms,raised_ms,overdue_ms,closed_ms,note,local_schedule";

fn read_promise(row: &Row<'_>) -> rusqlite::Result<Promise> {
    Ok(Promise {
        id: row.get(0)?,
        bot: row.get(1)?,
        what: row.get(2)?,
        due_ms: row.get(3)?,
        state: row.get(4)?,
        created_ms: row.get(5)?,
        raised_ms: row.get(6)?,
        overdue_ms: row.get(7)?,
        closed_ms: row.get(8)?,
        note: row.get(9)?,
        local_schedule: row
            .get::<_, Option<String>>(10)?
            .and_then(|text| serde_json::from_str(&text).ok()),
    })
}

/// A bot's promises: the open ones, soonest first, then (with `all`) the newest closed ones.
pub(crate) fn promises(
    db: &rusqlite::Connection,
    bot: Option<&str>,
    all: bool,
) -> rusqlite::Result<Vec<Promise>> {
    db.prepare_cached(&format!(
        "SELECT {PROMISE} FROM bot_promises WHERE (?1 IS NULL OR bot=?1) AND (?2 OR state IN ('open','raised','overdue'))
         ORDER BY state IN ('done','dropped'), CASE WHEN state IN ('open','raised','overdue') THEN due_ms END, id DESC LIMIT 200"
    ))?
    .query_map(params![bot, all], read_promise)?
    .collect()
}

/// Records that `bot` will do or report `what` by `due_ms`.
pub(crate) fn promise(
    ctx: &Ctx<'_>,
    bot: &Bot,
    schedule: Option<Schedule>,
    what: &str,
) -> rusqlite::Result<Result<Promise, String>> {
    let Some(what) = clean(what, WHAT_CHARS) else {
        return Ok(Err(
            "Say what you promise: up to 1000 characters of plain text.".into(),
        ));
    };
    let Some(due_ms) = schedule
        .as_ref()
        .and_then(|schedule| schedule.next(ctx.now, ctx.zone))
    else {
        return Ok(Err(
            "Say by when, as a time that is still to come: --by 30m, --by 17:30.".into(),
        ));
    };
    let open = promises(ctx.db, Some(&bot.id), false)?.len();
    if open >= ctx.set.promises_per_bot as usize {
        return Ok(Err(format!(
            "You have {open} open promises, which is the limit, so nothing was recorded. Close what is done: `{} promise list`, `{} promise done ID`.",
            ctx.cmd, ctx.cmd
        )));
    }
    let local = schedule
        .filter(|schedule| matches!(schedule, Schedule::LocalOnce { .. }))
        .map(|schedule| serde_json::to_string(&schedule).expect("valid local schedule"));
    let id: i64 = ctx.db.query_row(
        "INSERT INTO bot_promises (bot,what,due_ms,created_ms,local_schedule) VALUES (?1,?2,?3,?4,?5) RETURNING id",
        params![bot.id, what, due_ms, ctx.now, local],
        |row| row.get(0),
    )?;
    Ok(Ok(ctx
        .db
        .prepare_cached(&format!("SELECT {PROMISE} FROM bot_promises WHERE id=?1"))?
        .query_row([id], read_promise)?))
}

/// Closes a promise of `bot` as `done` or `dropped`.
pub(crate) fn settle(
    ctx: &Ctx<'_>,
    bot: &str,
    id: i64,
    state: &str,
    note: Option<&str>,
) -> rusqlite::Result<bool> {
    Ok(ctx.db.execute(
        "UPDATE bot_promises SET state=?3,closed_ms=?4,note=?5 WHERE id=?1 AND bot=?2 AND state IN ('open','raised','overdue')",
        params![id, bot, state, ctx.now, note.and_then(|note| clean(note, 600))],
    )? == 1)
}

/// Runs the promises' clock: one that is due is raised with its bot, once; one that is still open after the
/// grace time is recorded as a notice for the person, and flagged for the main bot.
pub(crate) fn raise_due(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    let due: Vec<Promise> = ctx
        .db
        .prepare_cached(&format!(
            "SELECT {PROMISE} FROM bot_promises
             WHERE (state='open' AND due_ms<=?1) OR (state='raised' AND raised_ms<=?2) ORDER BY id LIMIT 64"
        ))?
        .query_map(
            params![ctx.now, ctx.now - seconds(ctx.set.promise_grace_seconds)],
            read_promise,
        )?
        .collect::<Result<_, _>>()?;
    for promise in &due {
        let Some(bot) = super::one(ctx.db, &promise.bot)? else {
            settle(
                ctx,
                &promise.bot,
                promise.id,
                "dropped",
                Some("The bot was removed."),
            )?;
            continue;
        };
        if promise.state == "open" {
            ctx.db.execute(
                "UPDATE bot_promises SET state='raised',raised_ms=?2 WHERE id=?1",
                params![promise.id, ctx.now],
            )?;
            post(
                ctx,
                Post {
                    bot: &bot.id,
                    text: &notes::promise(
                        ctx.cmd,
                        promise.id,
                        &promise.what,
                        promise.due_ms,
                        ctx.zone,
                    ),
                    cause: "promise",
                    promise: Some(promise.id),
                    ..Post::default()
                },
            )?;
            continue;
        }
        ctx.db.execute(
            "UPDATE bot_promises SET state='overdue',overdue_ms=?2 WHERE id=?1",
            params![promise.id, ctx.now],
        )?;
        let line = format!(
            "{} promised \"{}\" by {} and has not marked it done.",
            notes::line(&bot.name),
            one_line(&promise.what, 200),
            notes::clock(promise.due_ms, ctx.zone)
        );
        let about = About {
            code: Some("promise_overdue"),
            promise: Some(promise.id),
            ..About::default()
        };
        entry(ctx, &bot.id, "notice", &line, about, true, true)?;
        if !bot.main {
            flag(ctx, "promise", &format!("promise:{}", promise.id), &line)?;
        }
    }
    Ok(due.len())
}

/// `promise list` for an agent.
pub(crate) fn promise_text(ctx: &Ctx<'_>, bot: &Bot) -> rusqlite::Result<String> {
    let open = promises(ctx.db, Some(&bot.id), false)?;
    if open.is_empty() {
        return Ok("You have no open promises.".into());
    }
    let mut text = "Your open promises:".to_owned();
    for promise in &open {
        text.push_str(&format!(
            "\n#{} · by {}{} · {}",
            promise.id,
            notes::clock(promise.due_ms, ctx.zone),
            if promise.state == "open" {
                ""
            } else {
                " (overdue)"
            },
            one_line(&promise.what, 160)
        ));
    }
    text.push_str(&format!("\nClose one: {} promise done ID", ctx.cmd));
    Ok(text)
}

/// Recompute pending wall-clock plans in the same transaction as a profile change.
pub(crate) fn rezone(db: &rusqlite::Connection, at: i64, zone: Tz) -> rusqlite::Result<()> {
    for (select, update) in [
        (
            "SELECT id,schedule,next_ms FROM bot_checkins WHERE enabled AND state='planned'
               AND json_extract(schedule,'$.kind') IN ('daily','local_once')
               AND json_extract(schedule,'$.timezone') IS NULL",
            "UPDATE bot_checkins SET next_ms=?2 WHERE id=?1",
        ),
        (
            "SELECT id,local_schedule,NULL FROM bot_promises WHERE state='open'
               AND local_schedule IS NOT NULL AND json_extract(local_schedule,'$.timezone') IS NULL",
            "UPDATE bot_promises SET due_ms=?2 WHERE id=?1",
        ),
    ] {
        let rows = db.prepare(select)?.query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get(2)?))
        })?.collect::<Result<Vec<_>, _>>()?;
        let mut update = db.prepare_cached(update)?;
        for (id, raw, next_ms) in rows {
            if let Some(due) = serde_json::from_str::<Schedule>(&raw).ok()
                .and_then(|schedule| schedule.after_move(at, zone, next_ms))
            {
                update.execute(params![id, due])?;
            }
        }
    }
    Ok(())
}

// ---- What the main bot is told about.

/// Notes something for the main bot. The same `key` is noted once. Says whether it was new.
pub(crate) fn flag(ctx: &Ctx<'_>, kind: &str, key: &str, text: &str) -> rusqlite::Result<bool> {
    Ok(ctx.db.execute(
        "INSERT OR IGNORE INTO bot_flags (kind,key,text,at_ms) VALUES (?1,?2,?3,?4)",
        params![kind, key, text, ctx.now],
    )? == 1)
}

/// Puts one note with what was flagged since the last one into the main bot's outbox, when there is a main
/// bot whose "Takes initiative" switch is on and the last note is long enough ago. Returns how many flags it
/// carries.
pub(crate) fn note_main(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    let Some(main) = super::main_bot(ctx.db)?.filter(|main| main.takes_initiative) else {
        return Ok(0);
    };
    let last: i64 = ctx
        .db
        .query_row(
            "SELECT CAST(value AS INTEGER) FROM bot_state WHERE key='last_note_ms'",
            [],
            |row| row.get(0),
        )
        .optional()?
        .unwrap_or(0);
    if ctx.now - last < seconds(ctx.set.initiative_seconds) {
        return Ok(0);
    }
    let flags: Vec<(i64, String)> = ctx
        .db
        .prepare_cached(
            "SELECT id,text FROM bot_flags WHERE told_ms IS NULL AND at_ms>?1 ORDER BY id LIMIT ?2",
        )?
        .query_map(
            params![ctx.now - FLAG_AGE_MS, FLAGS_PER_NOTE as i64],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?
        .collect::<Result<_, _>>()?;
    if flags.is_empty() {
        return Ok(0);
    }
    let lines: Vec<String> = flags.iter().map(|(_, text)| text.clone()).collect();
    post(
        ctx,
        Post {
            bot: &main.id,
            text: &notes::main_note(&lines),
            cause: "note",
            ..Post::default()
        },
    )?;
    for (id, _) in &flags {
        ctx.db.execute(
            "UPDATE bot_flags SET told_ms=?2 WHERE id=?1",
            params![id, ctx.now],
        )?;
    }
    ctx.db.execute(
        "INSERT INTO bot_state (key,value) VALUES ('last_note_ms',?1)
         ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [ctx.now.to_string()],
    )?;
    Ok(flags.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::{Settings, rules, testing};
    use crate::history::History;

    /// 2026-11-16 12:00:00 UTC, a Monday.
    const NOON: i64 = 1_794_830_400_000;
    const MINUTE: i64 = 60_000;

    fn utc() -> Settings {
        Settings {
            timezone: "UTC".into(),
            ..Settings::default()
        }
    }

    fn planned(
        history: &History,
        now: i64,
        set: &Settings,
        name: &str,
        when: When,
        what: &str,
    ) -> Result<Checkin, String> {
        let bot = testing::bot(history, name);
        testing::at(history, now, set, |ctx| plan(ctx, &bot, &when, what, "bot"))
    }

    fn outbox(history: &History) -> Vec<(i64, String, String, String, bool)> {
        history
            .db()
            .unwrap()
            .prepare(
                "SELECT id,bot,cause,text,quiet FROM bot_outbox WHERE state='pending' ORDER BY id",
            )
            .unwrap()
            .query_map([], |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                ))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn notices(history: &History, name: &str) -> Vec<(Option<String>, String, bool, bool)> {
        rules::entries(
            &history.db().unwrap(),
            &rules::Lines {
                bot: Some(&testing::id_of(name)),
                kind: Some("notice"),
                after: Some(0),
                limit: 100,
                ..rules::Lines::default()
            },
        )
        .unwrap()
        .into_iter()
        .map(|entry| (entry.code, entry.text, entry.unread, entry.notify))
        .collect()
    }

    #[test]
    fn a_schedule_says_when_it_fires_next() {
        assert_eq!(NOON % 86_400_000, 43_200_000, "noon");
        let (_scratch, history) = testing::journal(&[]);
        let set = utc();
        testing::at(&history, NOON, &set, |ctx| {
            assert_eq!(
                When::In { seconds: 1_800 }.schedule(ctx),
                Some(Schedule::Once {
                    at_ms: NOON + 30 * MINUTE
                })
            );
            // "at 17:30" is today; "at 9:00" has passed today, so it is tomorrow.
            assert_eq!(
                When::At {
                    hour: 17,
                    minute: 30,
                    timezone: None
                }
                .moment(ctx),
                Some(NOON + 330 * MINUTE)
            );
            assert_eq!(
                When::At {
                    hour: 9,
                    minute: 0,
                    timezone: None
                }
                .moment(ctx),
                Some(NOON + 21 * 60 * MINUTE)
            );
            assert_eq!(
                When::Every { seconds: 7_200 }.schedule(ctx),
                Some(Schedule::Interval { seconds: 7_200 })
            );
            let weekdays = When::Daily {
                hour: 9,
                minute: 0,
                weekdays: true,
                timezone: None,
            }
            .schedule(ctx)
            .unwrap();
            assert_eq!(
                weekdays,
                Schedule::Daily {
                    hour: 9,
                    minute: 0,
                    weekdays: true,
                    timezone: None
                }
            );
            assert_eq!(
                weekdays.words(ctx),
                "every weekday at 09:00 (UTC, follows user)"
            );
            // Monday noon: Tuesday 9:00. Friday noon: Monday 9:00.
            assert_eq!(
                weekdays.next(NOON, chrono_tz::UTC),
                Some(NOON + 21 * 60 * MINUTE)
            );
            let friday = NOON + 4 * 24 * 60 * MINUTE;
            assert_eq!(
                weekdays.next(friday, chrono_tz::UTC),
                Some(friday + (3 * 24 - 3) * 60 * MINUTE)
            );
            assert_eq!(
                Schedule::Interval { seconds: 600 }.next(NOON, chrono_tz::UTC),
                Some(NOON + 10 * MINUTE)
            );
            assert_eq!(
                Schedule::Interval { seconds: 600 }.words(ctx),
                "every 10 minutes"
            );
            assert_eq!(
                Schedule::Once { at_ms: NOON }.next(NOON, chrono_tz::UTC),
                None,
                "a one-off does not fire twice"
            );
            assert!(When::Every { seconds: 60 }.moment(ctx).is_none());
            Ok(())
        });
        // The time zone is the setting's.
        let warsaw = Settings {
            timezone: "Europe/Warsaw".into(),
            ..Settings::default()
        };
        testing::at(&history, NOON, &warsaw, |ctx| {
            assert_eq!(
                When::At {
                    hour: 17,
                    minute: 30,
                    timezone: None
                }
                .moment(ctx),
                Some(NOON + 270 * MINUTE)
            );
            Ok(())
        });
    }

    #[test]
    fn rezone_preserves_a_recent_daily_check_in_and_advances_a_missed_one() {
        use chrono_tz::{Asia::Bangkok, Europe::Warsaw};
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let ms = |input| {
            DateTime::parse_from_rfc3339(input)
                .unwrap()
                .timestamp_millis()
        };
        let warsaw = Settings {
            timezone: Warsaw.to_string(),
            ..Settings::default()
        };
        let bangkok = Settings {
            timezone: Bangkok.to_string(),
            ..Settings::default()
        };
        let due_in_warsaw = ms("2026-03-29T01:00:00Z"); // 02:30 falls in Warsaw's DST gap.
        let due_in_bangkok = ms("2026-03-29T19:30:00Z");
        let next_in_warsaw = ms("2026-03-30T00:30:00Z");
        let checkin = planned(
            &history,
            due_in_warsaw - 60 * MINUTE,
            &warsaw,
            "Jarvis",
            When::Daily {
                hour: 2,
                minute: 30,
                weekdays: false,
                timezone: None,
            },
            "Check the deploy.",
        )
        .unwrap();
        assert_eq!(checkin.next_ms, Some(due_in_warsaw));
        let slot = || {
            let db = history.db().unwrap();
            let checkins = checkins(&db, Some("jarvis-id"), false).unwrap();
            (checkins[0].next_ms, checkins[0].fires)
        };

        let moved_at = due_in_warsaw + 30_000;
        testing::at(&history, moved_at, &bangkok, |ctx| {
            crate::person_profile::rezone(ctx.db, ctx.now, Warsaw, Bangkok)
        });
        assert_eq!(slot(), (Some(due_in_warsaw), 0));
        assert_eq!(testing::at(&history, moved_at, &bangkok, fire_due), 1);
        assert_eq!(testing::at(&history, moved_at, &bangkok, fire_due), 0);
        assert_eq!(slot(), (Some(due_in_bangkok), 1));

        let returned_at = due_in_bangkok + crate::routines::LATE_MS + 1;
        testing::at(&history, returned_at, &warsaw, |ctx| {
            crate::person_profile::rezone(ctx.db, ctx.now, Bangkok, Warsaw)
        });
        assert_eq!(testing::at(&history, returned_at, &warsaw, fire_due), 0);
        assert_eq!(slot(), (Some(next_in_warsaw), 1));
        assert_eq!(testing::at(&history, next_in_warsaw, &warsaw, fire_due), 1);
        assert_eq!(outbox(&history).len(), 2);
    }

    #[test]
    fn check_ins_are_at_least_five_minutes_apart_and_at_most_ten_per_bot() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = utc();
        let first = planned(
            &history,
            NOON,
            &set,
            "Jarvis",
            When::In { seconds: 1_800 },
            "Check the deploy.",
        )
        .unwrap();
        assert_eq!(
            (
                first.next_ms,
                first.state.as_str(),
                first.planned_by.as_str()
            ),
            (Some(NOON + 30 * MINUTE), "planned", "bot")
        );
        // Less than five minutes from another one, before or after it.
        for near in [1_800 - 299, 1_800 + 299, 1_800] {
            let refused = planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::In { seconds: near },
                "Too close.",
            )
            .unwrap_err();
            assert!(
                refused.contains("at least 5 minutes apart") && refused.contains("#1"),
                "{near}: {refused}"
            );
        }
        assert!(
            planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::In {
                    seconds: 1_800 + 300
                },
                "Far enough."
            )
            .is_ok()
        );
        // A recurring one may not recur faster than that.
        assert!(
            planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::Every { seconds: 299 },
                "Too often."
            )
            .unwrap_err()
            .contains("at least 5 minutes apart")
        );
        assert!(
            planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::Every { seconds: 300 },
                "Often."
            )
            .is_ok()
        );
        // Another bot has its own.
        assert!(
            planned(
                &history,
                NOON,
                &set,
                "Infra",
                When::In { seconds: 1_800 },
                "Mine."
            )
            .is_ok()
        );
        assert!(
            planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::On { at_ms: NOON - 1 },
                "Past."
            )
            .unwrap_err()
            .contains("has passed")
        );
        assert!(
            planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::In { seconds: 9_000 },
                " "
            )
            .unwrap_err()
            .contains("Say what to come back to")
        );

        // At most ten planned.
        for index in 0..7 {
            planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::In {
                    seconds: 10_000 + index * 600,
                },
                "More.",
            )
            .unwrap();
        }
        let full = planned(
            &history,
            NOON,
            &set,
            "Jarvis",
            When::In { seconds: 90_000 },
            "Eleventh.",
        )
        .unwrap_err();
        assert!(full.contains("already have 10 check-ins planned, which is the limit"));
        let db = history.db().unwrap();
        assert_eq!(checkins(&db, Some("jarvis-id"), false).unwrap().len(), 10);
        assert_eq!(checkins(&db, Some("infra-id"), false).unwrap().len(), 1);
        assert_eq!(checkins(&db, None, true).unwrap().len(), 11);
        drop(db);
        // Cancelling frees a place; only the bot's own can be cancelled.
        assert!(!testing::at(&history, NOON, &set, |ctx| cancel(
            ctx, "infra-id", first.id
        )));
        assert!(testing::at(&history, NOON, &set, |ctx| cancel(
            ctx,
            "jarvis-id",
            first.id
        )));
        assert!(!testing::at(&history, NOON, &set, |ctx| cancel(
            ctx,
            "jarvis-id",
            first.id
        )));
        assert!(
            planned(
                &history,
                NOON,
                &set,
                "Jarvis",
                When::In { seconds: 90_000 },
                "Now it fits."
            )
            .is_ok()
        );
        let jarvis = testing::bot(&history, "Jarvis");
        let text = testing::at(&history, NOON, &set, |ctx| checkin_text(ctx, &jarvis));
        assert!(
            text.starts_with("Planned check-ins: 10 of the 10 allowed, at least 5 minutes apart.")
        );
        assert!(
            text.contains("every 5 minutes") && text.contains("swarmhub-herdr checkin cancel ID")
        );
        // The limits are settings.
        let loose = Settings {
            checkin_gap_seconds: 60,
            checkins_per_bot: 2,
            ..utc()
        };
        assert!(
            planned(
                &history,
                NOON,
                &loose,
                "Infra",
                When::In {
                    seconds: 1_800 + 60
                },
                "A minute later."
            )
            .is_ok()
        );
        assert!(
            planned(
                &history,
                NOON,
                &loose,
                "Infra",
                When::In { seconds: 9_000 },
                "Third."
            )
            .unwrap_err()
            .contains("already have 2")
        );
    }

    #[test]
    fn a_check_in_fires_with_nobody_connected_and_a_one_off_always_leaves_its_outcome() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let set = utc();
        let key = testing::session(&history, "Jarvis", "t7");
        crate::history::publish_reply(history.file(), &key, "Agent", "Hello.", None).unwrap();
        let once = planned(
            &history,
            NOON,
            &set,
            "Jarvis",
            When::In { seconds: 1_800 },
            "Check the deploy.",
        )
        .unwrap();
        assert_eq!(testing::at(&history, NOON + 29 * MINUTE, &set, fire_due), 0);
        assert_eq!(testing::at(&history, NOON + 30 * MINUTE, &set, fire_due), 1);
        assert_eq!(
            testing::at(&history, NOON + 31 * MINUTE, &set, fire_due),
            0,
            "a one-off fires once"
        );
        let waiting = outbox(&history);
        assert_eq!(waiting.len(), 1);
        let (id, bot, cause, text, quiet) = &waiting[0];
        assert_eq!(
            (bot.as_str(), cause.as_str(), *quiet),
            ("jarvis-id", "checkin", false)
        );
        assert!(text.starts_with("[Planned check-in #1, from SwarmHub] It was planned on 16 Nov 12:00 for now: Check the deploy."));
        assert!(text.contains("say the outcome in your reply"));
        let db = history.db().unwrap();
        let fired = &checkins(&db, Some("jarvis-id"), true).unwrap()[0];
        assert_eq!(
            (
                fired.state.as_str(),
                fired.next_ms,
                fired.fires,
                fired.last_fired_ms
            ),
            ("done", None, 1, Some(NOON + 30 * MINUTE))
        );
        assert!(
            checkins(&db, Some("jarvis-id"), false).unwrap().is_empty(),
            "it no longer counts as planned"
        );
        drop(db);

        // Its agent answers: that answer is the outcome, in the bot's history, with an alert.
        let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
            "address":"t7","name":"jarvis-jarvis","state":"live","status":null,"template":"fixture","created_ms":42,
            "exit_code":null,"reason":null,"first_message":null,"labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        })).unwrap();
        let (task, _) = history
            .start_task("core", &terminal, text, None, false, &[])
            .unwrap();
        history
            .finish(task, crate::history::State::Sent, None, None)
            .unwrap();
        history
            .db()
            .unwrap()
            .execute(
                "UPDATE bot_outbox SET task=?1 WHERE id=?2",
                params![task, id],
            )
            .unwrap();
        testing::at(&history, NOON + 30 * MINUTE, &set, |ctx| {
            rules::typed(ctx, *id)
        });
        crate::history::publish_reply(history.file(), &key, "Agent", "The deploy is green.", None)
            .unwrap();
        let reply: i64 = history
            .db()
            .unwrap()
            .query_row("SELECT max(id) FROM journal", [], |row| row.get(0))
            .unwrap();
        let jarvis = testing::bot(&history, "Jarvis");
        testing::at(&history, NOON + 31 * MINUTE, &set, |ctx| {
            rules::on_reply(ctx, &jarvis, &key, reply, "The deploy is green.")
        });
        let db = history.db().unwrap();
        let said = rules::entries(
            &db,
            &rules::Lines {
                bot: Some("jarvis-id"),
                after: Some(0),
                limit: 10,
                ..rules::Lines::default()
            },
        )
        .unwrap();
        assert_eq!(said.len(), 1);
        assert_eq!(
            (
                said[0].kind.as_str(),
                said[0].text.as_str(),
                said[0].code.as_deref(),
                said[0].checkin
            ),
            (
                "said",
                "The deploy is green.",
                Some("checkin"),
                Some(once.id)
            )
        );
        assert!(said[0].unread && said[0].notify);
        assert_eq!(
            checkins(&db, Some("jarvis-id"), true).unwrap()[0]
                .last_outcome
                .as_deref(),
            Some("reported")
        );
        drop(db);
        assert_eq!(
            testing::at(&history, NOON + 600 * MINUTE, &set, unanswered),
            0
        );

        // A one-off whose agent never answers still leaves a line: fifteen minutes after it was typed.
        let silent = planned(
            &history,
            NOON + 60 * MINUTE,
            &set,
            "Jarvis",
            When::In { seconds: 600 },
            "Check the backup.",
        )
        .unwrap();
        assert_eq!(testing::at(&history, NOON + 70 * MINUTE, &set, fire_due), 1);
        let id = outbox(&history)[0].0;
        testing::at(&history, NOON + 71 * MINUTE, &set, |ctx| {
            rules::typed(ctx, id)
        });
        assert_eq!(
            testing::at(&history, NOON + 85 * MINUTE, &set, unanswered),
            0
        );
        assert_eq!(
            testing::at(&history, NOON + 86 * MINUTE, &set, unanswered),
            1
        );
        // The first miss is tried once more, and nobody is told yet.
        assert!(notices(&history, "Jarvis").is_empty());
        let (again, _, cause, text, _) = outbox(&history).pop().unwrap();
        assert!(cause == "checkin" && text.contains("Check the backup.") && text.contains("Second try: the first one got no answer"));
        testing::at(&history, NOON + 87 * MINUTE, &set, |ctx| {
            rules::typed(ctx, again)
        });
        assert_eq!(
            testing::at(&history, NOON + 101 * MINUTE, &set, unanswered),
            0
        );
        assert_eq!(
            testing::at(&history, NOON + 102 * MINUTE, &set, unanswered),
            1
        );
        assert_eq!(
            testing::at(&history, NOON + 103 * MINUTE, &set, unanswered),
            0,
            "said once"
        );
        let lines = notices(&history, "Jarvis");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].0.as_deref(), Some("checkin_unanswered"));
        assert_eq!(
            lines[0].1,
            "The check-in \"Check the backup.\" fired at 16 Nov 13:10, but Jarvis's agent gave no answer within 15 minutes, also on a second try."
        );
        // The main bot is told once, so it can read the terminal.
        let flagged: String = history.db().unwrap()
            .query_row("SELECT text FROM bot_flags WHERE kind='checkin'", [], |row| row.get(0)).unwrap();
        assert!(flagged.contains("Check the backup.") && flagged.contains("Read Jarvis's terminal"));
        assert!(lines[0].2 && lines[0].3);
        assert_eq!(
            checkins(&history.db().unwrap(), Some("jarvis-id"), true)
                .unwrap()
                .iter()
                .find(|c| c.id == silent.id)
                .unwrap()
                .last_outcome
                .as_deref(),
            Some("no_answer")
        );
        // One that could not be typed at all says so at once.
        planned(
            &history,
            NOON + 120 * MINUTE,
            &set,
            "Jarvis",
            When::In { seconds: 600 },
            "Check the queue.",
        )
        .unwrap();
        testing::at(&history, NOON + 130 * MINUTE, &set, fire_due);
        let id = outbox(&history)[0].0;
        testing::at(&history, NOON + 131 * MINUTE, &set, |ctx| {
            rules::untyped(ctx, id, "its agent could not be started.")
        });
        assert_eq!(
            testing::at(&history, NOON + 131 * MINUTE, &set, unanswered),
            1
        );
        assert_eq!(notices(&history, "Jarvis").len(), 1, "a second try comes first");
        let (again, _, _, text, _) = outbox(&history).pop().unwrap();
        assert!(text.contains("Second try: the first one did not reach you"));
        testing::at(&history, NOON + 132 * MINUTE, &set, |ctx| {
            rules::untyped(ctx, again, "its agent could not be started.")
        });
        assert_eq!(
            testing::at(&history, NOON + 132 * MINUTE, &set, unanswered),
            1
        );
        assert!(
            notices(&history, "Jarvis")[1]
                .1
                .contains("did not reach Jarvis's agent, also on a second try: its agent could not be started.")
        );
    }

    #[test]
    fn paused_schedules_survive_restart_and_conditional_control_is_idempotent() {
        let (dir, history) = testing::journal(&["Fixture", "Other"]);
        let set = utc();
        let owner = testing::id_of("Fixture");
        let once = planned(&history, NOON, &set, "Fixture", When::In { seconds: 600 }, "One-off").unwrap();
        let recurring = planned(&history, NOON, &set, "Fixture", When::Every { seconds: 3600 }, "Recurring").unwrap();
        testing::at(&history, NOON, &set, |ctx| {
            assert!(set_enabled(ctx, "other-id", once.id, false, 0)?.is_err());
            for id in [once.id, recurring.id] {
                assert_eq!(set_enabled(ctx, &owner, id, false, 0)?.unwrap().control_revision, 1);
                assert_eq!(set_enabled(ctx, &owner, id, false, 0)?.unwrap().control_revision, 1);
            }
            assert!(set_enabled(ctx, &owner, once.id, true, 1)?.unwrap().enabled);
            assert!(!set_enabled(ctx, &owner, once.id, false, 2)?.unwrap().enabled);
            Ok(())
        });
        history.db().unwrap().execute("UPDATE bots SET takes_initiative=0 WHERE id=?", [&owner]).unwrap();
        drop(history);
        let history = History::open_at(&dir.path().join("workspace")).unwrap();
        let later = NOON + 61 * MINUTE;
        testing::at(&history, later, &set, |ctx| {
            let list = checkins(ctx.db, Some(&owner), false)?;
            assert_eq!(list.len(), 2);
            assert!(list.iter().all(|item| !item.enabled && item.fires == 0));
            assert_eq!(fire_due(ctx)?, 0);
            assert!(set_enabled(ctx, &owner, once.id, true, 3)?.unwrap_err().contains("passed"));
            let resumed = set_enabled(ctx, &owner, recurring.id, true, 1)?.unwrap();
            assert_eq!(resumed.schedule, recurring.schedule);
            assert_eq!(resumed.next_ms, Some(later + 60 * MINUTE));
            assert!(set_enabled(ctx, &owner, recurring.id, false, 0)?.is_err());
            assert_eq!(set_enabled(ctx, &owner, recurring.id, true, 1)?.unwrap().next_ms, resumed.next_ms);
            assert_eq!(fire_due(ctx)?, 0);
            Ok(())
        });
        assert_eq!(testing::at(&history, later + 60 * MINUTE, &set, fire_due), 0);
        history.db().unwrap().execute("UPDATE bots SET takes_initiative=1 WHERE id=?", [&owner]).unwrap();
        assert_eq!(testing::at(&history, later + 60 * MINUTE, &set, fire_due), 1);
        assert_eq!(testing::at(&history, later + 60 * MINUTE, &set, fire_due), 0);
    }

    #[test]
    fn a_recurring_check_in_with_nothing_to_report_leaves_nothing_and_fires_again() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let set = utc();
        let key = testing::session(&history, "Jarvis", "t7");
        crate::history::publish_reply(history.file(), &key, "Agent", "Hello.", None).unwrap();
        let every = planned(
            &history,
            NOON,
            &set,
            "Jarvis",
            When::Every { seconds: 600 },
            "Is the flag file there?",
        )
        .unwrap();
        assert_eq!(every.next_ms, Some(NOON + 10 * MINUTE));
        let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
            "address":"t7","name":"jarvis-jarvis","state":"live","status":null,"template":"fixture","created_ms":42,
            "exit_code":null,"reason":null,"first_message":null,"labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        })).unwrap();
        let jarvis = testing::bot(&history, "Jarvis");
        let fire = |now: i64, answer: &str| {
            assert_eq!(testing::at(&history, now, &set, fire_due), 1);
            let (id, _, _, text, quiet) = outbox(&history).pop().unwrap();
            assert!(
                quiet
                    && text.contains("to recur every 10 minutes")
                    && text.contains("reply with exactly: NOTHING TO REPORT")
            );
            let (task, _) = history
                .start_task("core", &terminal, &text, None, false, &[])
                .unwrap();
            history
                .finish(task, crate::history::State::Sent, None, None)
                .unwrap();
            history
                .db()
                .unwrap()
                .execute(
                    "UPDATE bot_outbox SET task=?1 WHERE id=?2",
                    params![task, id],
                )
                .unwrap();
            testing::at(&history, now, &set, |ctx| rules::typed(ctx, id));
            crate::history::publish_reply(history.file(), &key, "Agent", answer, None).unwrap();
            let reply: i64 = history
                .db()
                .unwrap()
                .query_row("SELECT max(id) FROM journal", [], |row| row.get(0))
                .unwrap();
            testing::at(&history, now + 1_000, &set, |ctx| {
                rules::on_reply(ctx, &jarvis, &key, reply, answer)
            });
        };
        let shown = || {
            history
                .db()
                .unwrap()
                .query_row("SELECT count(*) FROM bot_history", [], |row| {
                    row.get::<_, i64>(0)
                })
                .unwrap()
        };
        fire(NOON + 10 * MINUTE, "NOTHING TO REPORT");
        assert_eq!(shown(), 0, "nothing is shown and nothing notified");
        fire(NOON + 20 * MINUTE, "Nothing to report.");
        assert_eq!(shown(), 0);
        let db = history.db().unwrap();
        let state = &checkins(&db, Some("jarvis-id"), false).unwrap()[0];
        assert_eq!(
            (state.fires, state.last_outcome.as_deref(), state.next_ms),
            (2, Some("quiet"), Some(NOON + 30 * MINUTE))
        );
        drop(db);
        // The time it has news, the news is shown.
        fire(NOON + 30 * MINUTE, "The flag file is there now.");
        assert_eq!(shown(), 1);
        assert_eq!(
            testing::at(&history, NOON + 600 * MINUTE, &set, unanswered),
            0
        );
        // After downtime it fires once, not once for every time it missed, and goes on from now.
        assert_eq!(
            testing::at(&history, NOON + 600 * MINUTE, &set, fire_due),
            1
        );
        assert_eq!(
            testing::at(&history, NOON + 600 * MINUTE, &set, fire_due),
            0
        );
        assert_eq!(
            checkins(&history.db().unwrap(), Some("jarvis-id"), false).unwrap()[0].next_ms,
            Some(NOON + 610 * MINUTE)
        );
    }

    #[test]
    fn a_late_answer_to_the_first_try_takes_back_the_second() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let set = utc();
        let key = testing::session(&history, "Jarvis", "t7");
        crate::history::publish_reply(history.file(), &key, "Agent", "Hello.", None).unwrap();
        planned(&history, NOON, &set, "Jarvis", When::In { seconds: 600 }, "Check the backup.").unwrap();
        let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
            "address":"t7","name":"jarvis-jarvis","state":"live","status":null,"template":"fixture","created_ms":42,
            "exit_code":null,"reason":null,"first_message":null,"labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        })).unwrap();
        let jarvis = testing::bot(&history, "Jarvis");
        assert_eq!(testing::at(&history, NOON + 10 * MINUTE, &set, fire_due), 1);
        let (id, _, _, text, _) = outbox(&history).pop().unwrap();
        let (task, _) = history.start_task("core", &terminal, &text, None, false, &[]).unwrap();
        history.finish(task, crate::history::State::Sent, None, None).unwrap();
        history.db().unwrap()
            .execute("UPDATE bot_outbox SET task=?1 WHERE id=?2", params![task, id]).unwrap();
        testing::at(&history, NOON + 10 * MINUTE, &set, |ctx| rules::typed(ctx, id));
        // The agent is still on it after fifteen minutes: a second try is queued.
        assert_eq!(testing::at(&history, NOON + 26 * MINUTE, &set, unanswered), 1);
        assert_eq!(outbox(&history).len(), 1);
        // Its answer to the first try arrives before the second was typed.
        let answer = "The backup is complete.";
        crate::history::publish_reply(history.file(), &key, "Agent", answer, None).unwrap();
        let reply: i64 = history.db().unwrap()
            .query_row("SELECT max(id) FROM journal", [], |row| row.get(0)).unwrap();
        testing::at(&history, NOON + 27 * MINUTE, &set, |ctx| {
            rules::on_reply(ctx, &jarvis, &key, reply, answer)
        });
        assert!(outbox(&history).is_empty(), "the second try is taken back");
        assert_eq!(testing::at(&history, NOON + 600 * MINUTE, &set, unanswered), 0);
        assert!(notices(&history, "Jarvis").is_empty());
        assert_eq!(
            checkins(&history.db().unwrap(), Some("jarvis-id"), true).unwrap()[0].last_outcome.as_deref(),
            Some("reported")
        );
    }

    #[test]
    fn two_check_ins_of_a_bot_never_fire_closer_than_the_gap_and_the_switch_holds_them() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let set = utc();
        planned(
            &history,
            NOON,
            &set,
            "Jarvis",
            When::Every { seconds: 600 },
            "Every ten.",
        )
        .unwrap();
        planned(
            &history,
            NOON,
            &set,
            "Jarvis",
            When::In { seconds: 16 * 60 },
            "Once.",
        )
        .unwrap();
        // The server was down until both are due: they do not fire together.
        assert_eq!(testing::at(&history, NOON + 20 * MINUTE, &set, fire_due), 1);
        assert_eq!(testing::at(&history, NOON + 24 * MINUTE, &set, fire_due), 0);
        assert_eq!(testing::at(&history, NOON + 25 * MINUTE, &set, fire_due), 1);
        let fired: Vec<i64> = history
            .db()
            .unwrap()
            .prepare("SELECT created_ms FROM bot_outbox ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get(0))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        assert_eq!(fired, [NOON + 20 * MINUTE, NOON + 25 * MINUTE]);
        // A new one cannot be planned for right after one fired.
        assert!(testing::at(&history, NOON + 26 * MINUTE, &set, |ctx| {
            cancel(ctx, "jarvis-id", 1)
        }));
        let refused = planned(
            &history,
            NOON + 26 * MINUTE,
            &set,
            "Jarvis",
            When::In { seconds: 120 },
            "Again.",
        )
        .unwrap_err();
        assert!(
            refused.contains("one fired at 16 Nov 12:25")
                && refused.contains("the earliest time is 16 Nov 12:30")
        );
        planned(
            &history,
            NOON + 26 * MINUTE,
            &set,
            "Jarvis",
            When::Every { seconds: 600 },
            "Every ten again.",
        )
        .unwrap();

        // "Takes initiative" off: nothing fires and nothing new is planned; on again, what was due fires.
        crate::bots::register(
            &history.db().unwrap(),
            &crate::bots::Registration {
                id: "jarvis-id".into(),
                takes_initiative: Some(false),
                ..Default::default()
            },
            NOON,
        )
        .unwrap()
        .unwrap();
        assert_eq!(testing::at(&history, NOON + 60 * MINUTE, &set, fire_due), 0);
        assert!(
            planned(
                &history,
                NOON + 60 * MINUTE,
                &set,
                "Jarvis",
                When::In { seconds: 3_600 },
                "No."
            )
            .unwrap_err()
            .contains("turned off \"Takes initiative\"")
        );
        assert!(checkins(&history.db().unwrap(), Some("jarvis-id"), false).unwrap()[0].paused);
        crate::bots::register(
            &history.db().unwrap(),
            &crate::bots::Registration {
                id: "jarvis-id".into(),
                takes_initiative: Some(true),
                ..Default::default()
            },
            NOON,
        )
        .unwrap()
        .unwrap();
        assert_eq!(testing::at(&history, NOON + 61 * MINUTE, &set, fire_due), 1);
    }

    #[test]
    fn an_overdue_promise_is_raised_with_the_bot_once_and_then_with_the_person() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = utc();
        let infra = testing::bot(&history, "Infra");
        let made = testing::at(&history, NOON, &set, |ctx| {
            let due = When::In { seconds: 1_800 }.deadline(ctx);
            promise(ctx, &infra, due, "Send the weekly report.")
        })
        .unwrap();
        assert_eq!(
            (made.state.as_str(), made.due_ms),
            ("open", NOON + 30 * MINUTE)
        );
        assert!(
            testing::at(&history, NOON, &set, |ctx| promise(
                ctx,
                &infra,
                Some(Schedule::Once { at_ms: NOON - 1 }),
                "Late."
            ))
            .unwrap_err()
            .contains("by when")
        );
        assert!(
            testing::at(&history, NOON, &set, |ctx| promise(
                ctx, &infra, None, "When?"
            ))
            .is_err()
        );
        // Done before it is due: closed, and never raised.
        let quick = testing::at(&history, NOON, &set, |ctx| {
            promise(
                ctx,
                &infra,
                Some(Schedule::Once {
                    at_ms: NOON + MINUTE,
                }),
                "Quick one.",
            )
        })
        .unwrap();
        assert!(testing::at(&history, NOON + 30_000, &set, |ctx| settle(
            ctx,
            "infra-id",
            quick.id,
            "done",
            Some("Sent.")
        )));
        assert!(
            !testing::at(&history, NOON + 30_000, &set, |ctx| settle(
                ctx,
                "jarvis-id",
                made.id,
                "done",
                None
            )),
            "only its own"
        );
        assert_eq!(
            testing::at(&history, NOON + 29 * MINUTE, &set, raise_due),
            0
        );

        // Due: raised with the bot, once.
        assert_eq!(
            testing::at(&history, NOON + 30 * MINUTE, &set, raise_due),
            1
        );
        assert_eq!(
            testing::at(&history, NOON + 31 * MINUTE, &set, raise_due),
            0
        );
        let waiting = outbox(&history);
        assert_eq!(waiting.len(), 1);
        assert_eq!(
            (waiting[0].1.as_str(), waiting[0].2.as_str()),
            ("infra-id", "promise")
        );
        assert!(waiting[0].3.starts_with(
            "[From SwarmHub] Your promise #1 was due at 16 Nov 12:30: Send the weekly report."
        ));
        assert!(waiting[0].3.contains("swarmhub-herdr promise done 1"));
        assert!(
            notices(&history, "Infra").is_empty(),
            "the person is not told yet"
        );
        let text = testing::at(&history, NOON + 31 * MINUTE, &set, |ctx| {
            promise_text(ctx, &infra)
        });
        assert!(text.contains("#1 · by 16 Nov 12:30 (overdue) · Send the weekly report."));

        // Still open ten minutes later: a notice for the person, and the main bot will hear of it.
        assert_eq!(
            testing::at(&history, NOON + 39 * MINUTE, &set, raise_due),
            0
        );
        assert_eq!(
            testing::at(&history, NOON + 40 * MINUTE, &set, raise_due),
            1
        );
        assert_eq!(
            testing::at(&history, NOON + 90 * MINUTE, &set, raise_due),
            0,
            "each step happens once"
        );
        let lines = notices(&history, "Infra");
        assert_eq!(lines.len(), 1);
        assert_eq!(lines[0].0.as_deref(), Some("promise_overdue"));
        assert_eq!(
            lines[0].1,
            "Infra promised \"Send the weekly report.\" by 16 Nov 12:30 and has not marked it done."
        );
        assert!(lines[0].2 && lines[0].3);
        assert_eq!(
            outbox(&history).len(),
            1,
            "the bot is not raised a second time"
        );
        let db = history.db().unwrap();
        assert_eq!(
            promises(&db, Some("infra-id"), false).unwrap()[0].state,
            "overdue"
        );
        let flagged: String = db
            .query_row(
                "SELECT text FROM bot_flags WHERE key='promise:1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(flagged.starts_with("Infra promised"));
        drop(db);
        // Done still closes it.
        assert!(testing::at(&history, NOON + 95 * MINUTE, &set, |ctx| {
            settle(ctx, "infra-id", made.id, "done", None)
        }));
        assert!(
            promises(&history.db().unwrap(), Some("infra-id"), false)
                .unwrap()
                .is_empty()
        );
        assert_eq!(
            promises(&history.db().unwrap(), None, true).unwrap().len(),
            2
        );

        // Done after it was raised and before the grace time is up: the person is never told.
        let second = testing::at(&history, NOON + 100 * MINUTE, &set, |ctx| {
            promise(
                ctx,
                &infra,
                Some(Schedule::Once {
                    at_ms: NOON + 101 * MINUTE,
                }),
                "Second.",
            )
        })
        .unwrap();
        assert_eq!(
            testing::at(&history, NOON + 101 * MINUTE, &set, raise_due),
            1
        );
        assert!(testing::at(&history, NOON + 105 * MINUTE, &set, |ctx| {
            settle(ctx, "infra-id", second.id, "done", None)
        }));
        assert_eq!(
            testing::at(&history, NOON + 200 * MINUTE, &set, raise_due),
            0
        );
        assert_eq!(notices(&history, "Infra").len(), 1);
    }

    #[test]
    fn only_the_main_bot_is_told_about_problems_and_only_so_often() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = utc();
        assert_eq!(
            testing::at(&history, NOON, &set, note_main),
            0,
            "nothing to tell"
        );
        testing::at(&history, NOON, &set, |ctx| {
            assert!(flag(
                ctx,
                "blocked",
                "blocked:k1",
                "The agent of Infra is waiting at a prompt in its terminal."
            )?);
            assert!(
                !flag(ctx, "blocked", "blocked:k1", "Again.")?,
                "one thing is flagged once"
            );
            flag(
                ctx,
                "helper",
                "helper:9",
                "The helper easy-1 of Infra stopped without an answer.",
            )
        });
        assert_eq!(testing::at(&history, NOON + 1_000, &set, note_main), 2);
        let waiting = outbox(&history);
        assert_eq!(waiting.len(), 1);
        assert_eq!(
            (waiting[0].1.as_str(), waiting[0].2.as_str()),
            ("jarvis-id", "note"),
            "the main bot, and nobody else"
        );
        assert!(waiting[0].3.starts_with("[SwarmHub note for the main bot] The person did not write this.\n- The agent of Infra is waiting at a prompt in its terminal.\n- The helper easy-1 of Infra stopped without an answer.\n"));
        assert!(
            waiting[0]
                .3
                .contains("Triage this alert under the standing approvals.")
        );
        // At most one note in five minutes: what is flagged meanwhile waits and goes out together.
        testing::at(&history, NOON + 2_000, &set, |ctx| {
            flag(
                ctx,
                "machine",
                "machine:web-1:1",
                "The project server web-1 cannot be reached.",
            )
        });
        assert_eq!(testing::at(&history, NOON + 4 * MINUTE, &set, note_main), 0);
        assert_eq!(
            testing::at(&history, NOON + 5 * MINUTE + 1_000, &set, note_main),
            1
        );
        assert_eq!(
            testing::at(&history, NOON + 60 * MINUTE, &set, note_main),
            0,
            "told once"
        );
        assert_eq!(outbox(&history).len(), 2);

        // "Takes initiative" off: the main bot is told nothing, and old news is not told later.
        crate::bots::register(
            &history.db().unwrap(),
            &crate::bots::Registration {
                id: "jarvis-id".into(),
                takes_initiative: Some(false),
                ..Default::default()
            },
            NOON,
        )
        .unwrap()
        .unwrap();
        testing::at(&history, NOON + 61 * MINUTE, &set, |ctx| {
            flag(
                ctx,
                "handoff",
                "handoff:3",
                "Nobody accepted the hand-off #3.",
            )
        });
        assert_eq!(
            testing::at(&history, NOON + 70 * MINUTE, &set, note_main),
            0
        );
        crate::bots::register(
            &history.db().unwrap(),
            &crate::bots::Registration {
                id: "jarvis-id".into(),
                takes_initiative: Some(true),
                ..Default::default()
            },
            NOON,
        )
        .unwrap()
        .unwrap();
        assert_eq!(
            testing::at(&history, NOON + 200 * MINUTE, &set, note_main),
            0,
            "more than an hour old"
        );
        // No main bot: nobody is told.
        crate::bots::register(
            &history.db().unwrap(),
            &crate::bots::Registration {
                id: "jarvis-id".into(),
                main: Some(false),
                ..Default::default()
            },
            NOON,
        )
        .unwrap()
        .unwrap();
        testing::at(&history, NOON + 201 * MINUTE, &set, |ctx| {
            flag(
                ctx,
                "handoff",
                "handoff:4",
                "Nobody accepted the hand-off #4.",
            )
        });
        assert_eq!(
            testing::at(&history, NOON + 210 * MINUTE, &set, note_main),
            0
        );
    }
}
