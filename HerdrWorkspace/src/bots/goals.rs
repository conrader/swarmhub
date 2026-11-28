//! A goal the workspace keeps working on for a bot.
//!
//! The person sets an objective. The workspace types one step at a time into the bot's agent, the way a
//! check-in is typed, reads the step's outcome from the last line of the reply, and types the next step.
//! It runs on the server, so it goes on while no app is open, and the bot's agent is started when it is not
//! running. A goal ends when the bot gives evidence that the objective is met. It pauses when the bot needs
//! the person, when two steps bring nothing new, when a step limit is reached, or when a step gets no result.
//!
//! Like `rules` and `plans`, everything here is rows in one transaction; `desk` runs the clock and does the
//! typing.

use super::{
    Bot, Ctx, notes, plans,
    rules::{About, Post, entry, post},
};
use ring::rand::{SecureRandom, SystemRandom};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

const OBJECTIVE_CHARS: usize = 2_000;
const DETAIL_CHARS: usize = 800;
/// Steps a goal may take when the person set no limit: an unattended goal must not run without end.
pub(crate) const DEFAULT_STEPS: i64 = 40;
const MAX_STEPS: i64 = 500;
/// A step that was typed and has no reply after this long pauses the goal.
const STEP_MS: i64 = 3_600_000;
const SEEN: usize = 32;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Direction {
    Increase,
    Decrease,
}

/// What a step measured, in the bot's own words for the unit: "free space went from 2 to 3 GB, target 20".
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub(crate) struct Measurement {
    unit: String,
    direction: Direction,
    target: f64,
    before: f64,
    after: f64,
}

impl Measurement {
    fn valid(&self) -> bool {
        !self.unit.trim().is_empty()
            && self.unit.chars().count() <= 80
            && [self.target, self.before, self.after].iter().all(|n| n.is_finite())
    }

    fn matches(&self, other: &Self) -> bool {
        self.unit.eq_ignore_ascii_case(&other.unit)
            && self.direction == other.direction
            && self.target == other.target
    }

    fn improves(&self, baseline: f64) -> bool {
        match self.direction {
            Direction::Increase => self.after > baseline,
            Direction::Decrease => self.after < baseline,
        }
    }

    fn reached(&self) -> bool {
        match self.direction {
            Direction::Increase => self.after >= self.target,
            Direction::Decrease => self.after <= self.target,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Outcome {
    Progress,
    Complete,
    Blocked,
    NoProgress,
    Failed,
}

/// The last line of a step's reply.
#[derive(Clone, Debug, Deserialize)]
struct Report {
    iteration: String,
    outcome: Outcome,
    evidence: String,
    #[serde(default)]
    measurement: Option<Measurement>,
    #[serde(default, rename = "alternateAction")]
    alternate_action: Option<String>,
}

impl Report {
    /// The report and what the bot wrote before it.
    fn read(reply: &str) -> Option<(Self, String)> {
        let text = reply.trim();
        let start = text.rfind('\n').map_or(0, |at| at + 1);
        let report: Self = serde_json::from_str(text[start..].trim()).ok()?;
        (!report.evidence.trim().is_empty()).then(|| (report, text[..start].trim().to_owned()))
    }
}

/// A goal as the app shows it.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub(crate) struct Goal {
    pub id: i64,
    pub bot: String,
    pub objective: String,
    /// `queued`, `running`, `waiting`, `completed` or `stopped`.
    pub state: String,
    /// Why it waits: `blocked` (the bot needs the person), `stalled`, `unconfirmed`, `undelivered`, `silent`.
    pub pause: Option<String>,
    pub iteration: i64,
    pub step_limit: i64,
    pub detail: String,
    pub best: Option<Measurement>,
    pub created_ms: i64,
    pub updated_ms: i64,
    #[serde(skip)]
    attempt: Option<String>,
    #[serde(skip)]
    outbox: Option<i64>,
    #[serde(skip)]
    tries: i64,
    #[serde(skip)]
    stalls: i64,
    #[serde(skip)]
    seen: Vec<String>,
}

const GOAL: &str = "id,bot,objective,state,pause,iteration,step_limit,detail,best,created_ms,updated_ms,attempt,outbox,tries,stalls,seen";

fn read_goal(row: &Row<'_>) -> rusqlite::Result<Goal> {
    let best: Option<String> = row.get(8)?;
    let seen: String = row.get(15)?;
    Ok(Goal {
        id: row.get(0)?,
        bot: row.get(1)?,
        objective: row.get(2)?,
        state: row.get(3)?,
        pause: row.get(4)?,
        iteration: row.get(5)?,
        step_limit: row.get(6)?,
        detail: row.get(7)?,
        best: best.and_then(|best| serde_json::from_str(&best).ok()),
        created_ms: row.get(9)?,
        updated_ms: row.get(10)?,
        attempt: row.get(11)?,
        outbox: row.get(12)?,
        tries: row.get(13)?,
        stalls: row.get(14)?,
        seen: serde_json::from_str(&seen).unwrap_or_default(),
    })
}

fn save(ctx: &Ctx<'_>, goal: &Goal) -> rusqlite::Result<()> {
    ctx.db.execute(
        "UPDATE bot_goals SET state=?2,pause=?3,iteration=?4,detail=?5,best=?6,attempt=?7,outbox=?8,tries=?9,
                stalls=?10,seen=?11,updated_ms=?12 WHERE id=?1",
        params![
            goal.id,
            goal.state,
            goal.pause,
            goal.iteration,
            goal.detail,
            goal.best.as_ref().and_then(|best| serde_json::to_string(best).ok()),
            goal.attempt,
            goal.outbox,
            goal.tries,
            goal.stalls,
            serde_json::to_string(&goal.seen).unwrap_or_else(|_| "[]".into()),
            ctx.now
        ],
    )?;
    Ok(())
}

fn one(db: &rusqlite::Connection, id: i64) -> rusqlite::Result<Option<Goal>> {
    db.query_row(&format!("SELECT {GOAL} FROM bot_goals WHERE id=?1"), [id], read_goal)
        .optional()
}

/// The bot's newest goal, also one that has ended.
pub(crate) fn latest(db: &rusqlite::Connection, bot: &str) -> rusqlite::Result<Option<Goal>> {
    db.query_row(
        &format!("SELECT {GOAL} FROM bot_goals WHERE bot=?1 ORDER BY id DESC LIMIT 1"),
        [bot],
        read_goal,
    )
    .optional()
}

/// Every bot's newest goal, for the app's feed.
pub(crate) fn latest_all(db: &rusqlite::Connection) -> rusqlite::Result<Vec<Goal>> {
    db.prepare_cached(&format!(
        "SELECT {GOAL} FROM bot_goals WHERE id IN (SELECT max(id) FROM bot_goals GROUP BY bot) ORDER BY id"
    ))?
    .query_map([], read_goal)?
    .collect()
}

fn active(db: &rusqlite::Connection, bot: &str) -> rusqlite::Result<Option<Goal>> {
    db.query_row(
        &format!("SELECT {GOAL} FROM bot_goals WHERE bot=?1 AND state IN ('queued','running','waiting')"),
        [bot],
        read_goal,
    )
    .optional()
}

fn token() -> String {
    let mut bytes = [0u8; 16];
    // The token only tells this step's report from another's; a clock stands in if the system has no randomness.
    if SystemRandom::new().fill(&mut bytes).is_err() {
        bytes.copy_from_slice(&crate::history::now().to_le_bytes().repeat(2));
    }
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..])
}

/// A threshold the objective itself names ("get 20 GB free on OVH"). Such a goal is complete only with a
/// measurement in that unit, even when the first report leaves it out. Other goals set their metric by reporting it.
fn free_space_target(objective: &str) -> Option<(f64, String)> {
    const ACTIONS: [&str; 18] = [
        "zrób", "zrob", "zrobić", "zrobic", "uzyskaj", "zapewnij", "zwolnij", "odzyskaj", "zapewnić",
        "ensure", "reach", "achieve", "get", "free up", "maintain", "make", "leave", "keep",
    ];
    const UNITS: [&str; 8] = ["KiB", "MiB", "GiB", "TiB", "KB", "MB", "GB", "TB"];
    let primary = objective.split("\nFollow-up: ").next().unwrap_or(objective);
    let lower = primary.trim_start().to_lowercase();
    let lead = ["please ", "proszę ", "prosze "]
        .iter()
        .find_map(|polite| lower.strip_prefix(polite))
        .unwrap_or(&lower)
        .trim_start();
    // A request to report on or look into a threshold can end below it.
    if !ACTIONS.iter().any(|action| lead.starts_with(action))
        && !lead.starts_with(|first: char| first.is_ascii_digit())
    {
        return None;
    }
    let number = |word: &str| -> Option<f64> {
        let plain = word.replace(',', ".");
        (!plain.is_empty() && plain.chars().all(|c| c.is_ascii_digit() || c == '.'))
            .then(|| plain.parse::<f64>().ok())
            .flatten()
            .filter(|n| *n > 0.0)
    };
    let unit = |word: &str| UNITS.iter().find(|unit| unit.eq_ignore_ascii_case(word)).copied();
    let words: Vec<&str> = primary
        .split(|c: char| c.is_whitespace() || matches!(c, '(' | ')' | ';' | ':'))
        .filter(|word| !word.is_empty())
        .map(|word| word.trim_end_matches(['.', ',', '!', '?']))
        .collect();
    for (at, word) in words.iter().enumerate() {
        // "20 GB free" and "20GB free".
        let (target, found, next) = match number(word) {
            Some(target) => match words.get(at + 1).and_then(|word| unit(word)) {
                Some(found) => (target, found, at + 2),
                None => continue,
            },
            None => {
                let digits = word.find(|c: char| c.is_ascii_alphabetic()).unwrap_or(0);
                match (number(&word[..digits]), unit(&word[digits..])) {
                    (Some(target), Some(found)) => (target, found, at + 1),
                    _ => continue,
                }
            }
        };
        let rest: Vec<String> = words[next.min(words.len())..]
            .iter()
            .take(3)
            .map(|word| word.to_lowercase())
            .collect();
        let rest: Vec<&str> = rest.iter().map(String::as_str).collect();
        let free = match rest.as_slice() {
            ["wolnego", ..] | ["free", ..] | ["of", "free", ..] => true,
            ["wolnej", "przestrzeni", ..] => true,
            _ => false,
        };
        if free {
            return Some((target, found.to_owned()));
        }
    }
    None
}

impl Goal {
    fn accepts(&self, reading: &Measurement) -> bool {
        if !reading.valid() || self.best.as_ref().is_some_and(|best| !reading.matches(best)) {
            return false;
        }
        match free_space_target(&self.objective) {
            Some((target, unit)) => {
                reading.target == target
                    && reading.unit.eq_ignore_ascii_case(&unit)
                    && reading.direction == Direction::Increase
            }
            None => true,
        }
    }

    /// What the report counts as. A bot's word for "done" or "progress" holds only with a measurement that
    /// shows it, once the goal has a metric.
    fn assessed(&self, report: &Report) -> (Outcome, String) {
        let evidence = report.evidence.trim().to_owned();
        match report.outcome {
            Outcome::Blocked => match report.alternate_action.as_deref().map(str::trim).filter(|next| !next.is_empty()) {
                Some(next) => (
                    Outcome::NoProgress,
                    format!("Next authorized action: {}\n{evidence}", next.chars().take(360).collect::<String>()),
                ),
                None => (Outcome::Blocked, evidence),
            },
            Outcome::Complete | Outcome::Progress => match &report.measurement {
                Some(reading) if !self.accepts(reading) => (
                    Outcome::NoProgress,
                    format!("Measure the same target and unit again. {evidence}"),
                ),
                Some(reading) if report.outcome == Outcome::Complete && !reading.reached() => (
                    Outcome::NoProgress,
                    format!("The reported measurement is short of the target. {evidence}"),
                ),
                Some(reading)
                    if report.outcome == Outcome::Progress
                        && (!reading.improves(reading.before)
                            || self.best.as_ref().is_some_and(|best| !reading.improves(best.after))) =>
                {
                    (Outcome::NoProgress, evidence)
                }
                Some(_) => (report.outcome, evidence),
                None if self.best.is_some() || free_space_target(&self.objective).is_some() => (
                    Outcome::NoProgress,
                    format!("Measure the target again to verify the result. {evidence}"),
                ),
                None => (report.outcome, evidence),
            },
            Outcome::NoProgress | Outcome::Failed => (report.outcome, evidence),
        }
    }

    fn pause(&mut self, why: &str, detail: String) {
        self.state = "waiting".into();
        self.pause = Some(why.into());
        self.attempt = None;
        self.outbox = None;
        self.detail = detail;
    }

    /// Takes a step's report into the goal. Returns what the report counted as.
    fn finish(&mut self, report: &Report) -> Outcome {
        let (outcome, evidence) = self.assessed(report);
        if let Some(reading) = &report.measurement
            && self.accepts(reading)
            && self.best.as_ref().is_none_or(|best| reading.improves(best.after))
        {
            self.best = Some(reading.clone());
        }
        self.attempt = None;
        self.outbox = None;
        self.pause = None;
        self.detail = evidence.chars().take(DETAIL_CHARS).collect();
        match outcome {
            Outcome::Complete => self.state = "completed".into(),
            Outcome::Blocked => {
                let detail = self.detail.clone();
                self.pause("blocked", detail);
            }
            Outcome::Failed | Outcome::NoProgress => {
                self.stalls += 1;
                self.state = "queued".into();
            }
            Outcome::Progress => {
                let key = self.detail.to_lowercase().split_whitespace().collect::<Vec<_>>().join(" ");
                if self.seen.contains(&key) {
                    self.stalls += 1;
                } else {
                    self.seen.push(key);
                    if self.seen.len() > SEEN {
                        self.seen.remove(0);
                    }
                    self.stalls = 0;
                }
                self.state = "queued".into();
            }
        }
        if self.state == "queued" && self.iteration >= self.step_limit {
            self.state = "stopped".into();
            self.detail = format!("Step limit reached. {}", self.detail).trim().to_owned();
        } else if self.state == "queued" && self.stalls >= 2 {
            let detail = format!("Two steps produced no new progress. {}", self.detail);
            self.pause("stalled", detail);
        }
        outcome
    }

    /// What is typed into the bot's agent for the step with this token.
    fn request(&self, token: &str) -> String {
        let mut text = format!(
            "[Goal step {}, from SwarmHub] The person set this goal for you: {}\n\
             (The person did not write this now. Work on one step toward the goal. Your standing rules say what needs the person's yes.)\n\
             End your reply with one JSON line for this step. Set outcome to progress, complete, blocked, no_progress, or failed.\n\
             For progress name the new result. For complete give evidence that the entire objective was met. Otherwise explain what is needed.\n\
             {{\"iteration\":\"{token}\",\"outcome\":\"...\",\"evidence\":\"...\"}}\n\
             Keep the person's objective, named target and constraints in scope. Take the largest useful authorized action now. A helper is optional unless the person requires delegation. If a method fails, do independent work yourself. An approval applies only to its stated action. Never retry or substitute a denied action.\n\
             Check the current state first. If the objective is already met, report complete with evidence even if another actor achieved it. For a numeric target measure the same resource before and after in the same unit. Include measurement in the final JSON: {{\"unit\":\"GB\",\"direction\":\"increase\",\"target\":20,\"before\":2,\"after\":3}}. Use the actual unit and target; direction is increase or decrease. Report no_progress for unchanged results. Requests, handoffs and repeated status checks alone are not progress.\n\
             If only a method is blocked and a different authorized action is available, include alternateAction naming that concrete action. If the objective itself needs a decision, report blocked and ask once.",
            self.iteration, self.objective
        );
        if let Some((target, unit)) = free_space_target(&self.objective) {
            text.push_str(&format!(
                "\nRequired measurement: free space on the requested volume, target {target} {unit}, direction increase."
            ));
        }
        if let Some(best) = &self.best {
            text.push_str(&format!(
                "\nBest reported measurement: {} {}, target {} ({}).",
                best.after,
                best.unit,
                best.target,
                if best.direction == Direction::Increase { "increase" } else { "decrease" }
            ));
        }
        if !self.detail.is_empty() {
            text.push_str("\nLast result: ");
            text.push_str(&self.detail);
        }
        text
    }
}

fn told(ctx: &Ctx<'_>, goal: &Goal, line: &str) -> rusqlite::Result<()> {
    let about = About { code: Some("goal"), ..About::default() };
    entry(ctx, &goal.bot, "notice", line, about, true, true)?;
    Ok(())
}

/// Sets a goal for the bot. A goal it still had ends.
pub(crate) fn start(
    ctx: &Ctx<'_>,
    bot: &Bot,
    objective: &str,
    step_limit: Option<i64>,
) -> rusqlite::Result<Result<Goal, String>> {
    let objective = objective.trim();
    if objective.is_empty() || objective.chars().count() > OBJECTIVE_CHARS {
        return Ok(Err(format!("Give the goal in at most {OBJECTIVE_CHARS} characters.")));
    }
    let limit = step_limit.unwrap_or(DEFAULT_STEPS);
    if !(1..=MAX_STEPS).contains(&limit) {
        return Ok(Err(format!("Set between 1 and {MAX_STEPS} steps.")));
    }
    if let Some(mut earlier) = active(ctx.db, &bot.id)? {
        drop_pending(ctx, earlier.id)?;
        earlier.state = "stopped".into();
        earlier.pause = None;
        earlier.attempt = None;
        earlier.outbox = None;
        earlier.detail = "Replaced by a new goal.".into();
        save(ctx, &earlier)?;
    }
    let id: i64 = ctx.db.query_row(
        "INSERT INTO bot_goals (bot,objective,step_limit,created_ms,updated_ms) VALUES (?1,?2,?3,?4,?4) RETURNING id",
        params![bot.id, objective, limit, ctx.now],
        |row| row.get(0),
    )?;
    Ok(Ok(one(ctx.db, id)?.expect("the goal was just saved")))
}

fn drop_pending(ctx: &Ctx<'_>, goal: i64) -> rusqlite::Result<()> {
    ctx.db.execute(
        "UPDATE bot_outbox SET state='dropped',outcome='stopped' WHERE goal=?1 AND state='pending'",
        [goal],
    )?;
    Ok(())
}

/// The person stops the bot's goal. A step its agent is already working on is not interrupted here.
pub(crate) fn stop(ctx: &Ctx<'_>, bot: &str) -> rusqlite::Result<Option<Goal>> {
    let Some(mut goal) = active(ctx.db, bot)? else {
        return Ok(None);
    };
    drop_pending(ctx, goal.id)?;
    goal.state = "stopped".into();
    goal.pause = None;
    goal.attempt = None;
    goal.outbox = None;
    goal.detail = "Stopped by you.".into();
    save(ctx, &goal)?;
    Ok(Some(goal))
}

/// A waiting goal goes on with a fresh count of steps without progress.
pub(crate) fn resume(ctx: &Ctx<'_>, bot: &str) -> rusqlite::Result<Option<Goal>> {
    let Some(mut goal) = active(ctx.db, bot)?.filter(|goal| goal.state == "waiting") else {
        return Ok(None);
    };
    goal.state = "queued".into();
    goal.pause = None;
    goal.stalls = 0;
    goal.seen.clear();
    save(ctx, &goal)?;
    Ok(Some(goal))
}

/// The person wrote to the bot and it answered: a goal that waited for the person's decision goes on.
pub(crate) fn person_answered(ctx: &Ctx<'_>, bot: &str) -> rusqlite::Result<()> {
    if let Some(mut goal) = active(ctx.db, bot)?
        .filter(|goal| goal.state == "waiting" && goal.pause.as_deref() == Some("blocked"))
    {
        goal.state = "queued".into();
        goal.pause = None;
        goal.stalls = 0;
        goal.detail = format!("The person replied in chat after you reported: {}", goal.detail)
            .chars()
            .take(DETAIL_CHARS)
            .collect();
        save(ctx, &goal)?;
    }
    Ok(())
}

/// Types the next step of every goal that is ready for one. A bot with something else waiting to be typed
/// gets that first. Returns how many steps were put into the outbox.
pub(crate) fn advance(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    let ready: Vec<Goal> = ctx
        .db
        .prepare_cached(&format!("SELECT {GOAL} FROM bot_goals WHERE state='queued' ORDER BY id LIMIT 64"))?
        .query_map([], read_goal)?
        .collect::<Result<_, _>>()?;
    let mut stepped = 0;
    for mut goal in ready {
        if super::one(ctx.db, &goal.bot)?.is_none() {
            goal.state = "stopped".into();
            goal.detail = "The bot was removed.".into();
            save(ctx, &goal)?;
            continue;
        }
        let waiting: bool = ctx.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM bot_outbox WHERE bot=?1 AND state IN ('pending','typing'))",
            [&goal.bot],
            |row| row.get(0),
        )?;
        if waiting {
            continue;
        }
        if goal.iteration >= goal.step_limit {
            goal.state = "stopped".into();
            goal.detail = format!("Step limit reached. {}", goal.detail).trim().to_owned();
            save(ctx, &goal)?;
            told(ctx, &goal, &format!("Goal stopped: {}", goal.detail))?;
            continue;
        }
        let attempt = token();
        goal.iteration += 1;
        let text = goal.request(&attempt);
        let outbox = post(
            ctx,
            Post { bot: &goal.bot, text: &text, cause: "note", goal: Some(goal.id), ..Post::default() },
        )?;
        goal.state = "running".into();
        goal.pause = None;
        goal.attempt = Some(attempt);
        goal.outbox = Some(outbox);
        goal.tries = 1;
        save(ctx, &goal)?;
        stepped += 1;
    }
    Ok(stepped)
}

/// What a reply to a goal step leaves for the chat.
pub(crate) struct Settled {
    /// The reply without its report line.
    pub text: String,
    /// A line for the person after the reply: the goal is complete, paused or stopped.
    pub after: Option<String>,
}

/// The bot's agent answered the step typed from outbox row `outbox`.
pub(crate) fn settle(ctx: &Ctx<'_>, bot: &Bot, id: i64, outbox: i64, reply: &str) -> rusqlite::Result<Option<Settled>> {
    let Some(mut goal) = one(ctx.db, id)? else {
        return Ok(None);
    };
    let read = Report::read(reply);
    let prose = |report: &Report, prose: &str| {
        if prose.is_empty() { report.evidence.trim().to_owned() } else { prose.to_owned() }
    };
    // A late answer to a step of a goal that was stopped or went on by another way is only shown.
    if goal.state != "running" || goal.outbox != Some(outbox) {
        return Ok(read.map(|(report, text)| Settled { text: prose(&report, &text), after: None }));
    }
    let name = notes::line(&bot.name);
    let Some((report, text)) = read.filter(|(report, _)| {
        goal.attempt.as_deref().is_some_and(|attempt| attempt.eq_ignore_ascii_case(report.iteration.trim()))
    }) else {
        goal.pause("unconfirmed", "The reply had no confirmed goal outcome. Review it before resuming.".into());
        save(ctx, &goal)?;
        return Ok(Some(Settled {
            text: reply.to_owned(),
            after: Some(format!("Goal paused: {name}'s reply did not say how the step ended. Review it, then resume the goal.")),
        }));
    };
    goal.finish(&report);
    save(ctx, &goal)?;
    let objective = plans::one_line(&goal.objective, 160);
    let after = match (goal.state.as_str(), goal.pause.as_deref()) {
        ("completed", _) => Some(format!("Goal completed: {objective}")),
        ("stopped", _) => Some(format!("Goal stopped: {}", plans::one_line(&goal.detail, 240))),
        ("waiting", Some("blocked")) => Some(format!("Goal paused: {name} needs your answer. It goes on when you reply in this chat.")),
        ("waiting", _) => Some(format!("Goal paused: {}", plans::one_line(&goal.detail, 240))),
        _ => None,
    };
    Ok(Some(Settled { text: prose(&report, &text), after }))
}

/// Steps that did not reach the agent or got no result. One that did not arrive is typed once more; after
/// that, and for a step with no reply within the hour, the goal pauses and the person is told.
pub(crate) fn overdue(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    let running: Vec<Goal> = ctx
        .db
        .prepare_cached(&format!("SELECT {GOAL} FROM bot_goals WHERE state='running' ORDER BY id LIMIT 64"))?
        .query_map([], read_goal)?
        .collect::<Result<_, _>>()?;
    let mut paused = 0;
    for mut goal in running {
        let row: Option<(String, i64, Option<String>, String)> = match goal.outbox {
            Some(outbox) => ctx
                .db
                .query_row(
                    "SELECT state,coalesce(typed_ms,created_ms),detail,text FROM bot_outbox WHERE id=?1",
                    [outbox],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
                )
                .optional()?,
            None => None,
        };
        let name = notes::line(&super::name_of(ctx.db, &goal.bot));
        let Some((state, since, detail, text)) = row else {
            goal.pause("undelivered", "The step was lost before it reached the agent. Resume the goal to try again.".into());
            save(ctx, &goal)?;
            told(ctx, &goal, &format!("Goal paused: {}", goal.detail))?;
            paused += 1;
            continue;
        };
        match state.as_str() {
            "failed" | "dropped" if goal.tries < 2 => {
                let outbox = post(
                    ctx,
                    Post { bot: &goal.bot, text: &text, cause: "note", goal: Some(goal.id), ..Post::default() },
                )?;
                goal.outbox = Some(outbox);
                goal.tries += 1;
                save(ctx, &goal)?;
            }
            "failed" | "dropped" => {
                goal.pause(
                    "undelivered",
                    format!(
                        "The step did not reach {name}'s agent, also on a second try: {}",
                        detail.as_deref().unwrap_or("it could not be typed.")
                    ),
                );
                save(ctx, &goal)?;
                told(ctx, &goal, &format!("Goal paused: {}", goal.detail))?;
                paused += 1;
            }
            "typed" | "typing" if since <= ctx.now - STEP_MS => {
                goal.pause("silent", format!("{name}'s agent gave no result for this step within an hour."));
                save(ctx, &goal)?;
                told(ctx, &goal, &format!("Goal paused: {}", goal.detail))?;
                plans::flag(
                    ctx,
                    "goal",
                    &format!("goal:{}:{}", goal.id, goal.iteration),
                    &format!(
                        "A goal step of the bot {name} got no result within an hour. Read {name}'s terminal for what its agent is doing or waiting on."
                    ),
                )?;
                paused += 1;
            }
            _ => {}
        }
    }
    Ok(paused)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::{Settings, rules, testing};
    use crate::history::History;

    const NOON: i64 = 1_763_294_400_000;
    const MINUTE: i64 = 60_000;

    fn pending(history: &History) -> Vec<(i64, String, Option<i64>)> {
        history
            .db()
            .unwrap()
            .prepare("SELECT id,text,goal FROM bot_outbox WHERE state='pending' ORDER BY id")
            .unwrap()
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap()
    }

    fn lines(history: &History, name: &str, kind: &str) -> Vec<(Option<String>, String, bool)> {
        rules::entries(
            &history.db().unwrap(),
            &rules::Lines {
                bot: Some(&testing::id_of(name)),
                kind: Some(kind),
                after: Some(0),
                limit: 100,
                ..rules::Lines::default()
            },
        )
        .unwrap()
        .into_iter()
        .map(|entry| (entry.code, entry.text, entry.notify))
        .collect()
    }

    fn token_in(text: &str) -> String {
        let at = text.find("{\"iteration\":\"").unwrap() + 14;
        text[at..at + 36].to_owned()
    }

    /// One bot with a live agent, and what types a step into it and brings the agent's answer back.
    struct Fixture {
        _scratch: tempfile::TempDir,
        history: History,
        set: Settings,
        key: String,
        terminal: crate::core::Terminal,
        bot: Bot,
    }

    impl Fixture {
        fn new() -> Self {
            let (scratch, history) = testing::journal(&["Infra"]);
            let key = testing::session(&history, "Infra", "t7");
            crate::history::publish_reply(history.file(), &key, "Agent", "Hello.", None).unwrap();
            let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
                "address":"t7","name":"infra-infra","state":"live","status":null,"template":"fixture","created_ms":42,
                "exit_code":null,"reason":null,"first_message":null,"labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
            })).unwrap();
            let bot = testing::bot(&history, "Infra");
            Self { _scratch: scratch, history, set: Settings::default(), key, terminal, bot }
        }

        fn at<T>(&self, now: i64, work: impl FnOnce(&Ctx<'_>) -> rusqlite::Result<T>) -> T {
            testing::at(&self.history, now, &self.set, work)
        }

        fn goal(&self) -> Goal {
            latest(&self.history.db().unwrap(), &self.bot.id).unwrap().unwrap()
        }

        /// Types the waiting step and returns its outbox row and token.
        fn typed(&self, now: i64) -> (i64, String) {
            let (id, text, goal) = pending(&self.history).pop().unwrap();
            assert!(goal.is_some(), "a goal step");
            let (task, _) = self.history.start_task("core", &self.terminal, &text, None, false, &[]).unwrap();
            self.history.finish(task, crate::history::State::Sent, None, None).unwrap();
            self.history.db().unwrap()
                .execute("UPDATE bot_outbox SET task=?1 WHERE id=?2", params![task, id]).unwrap();
            self.at(now, |ctx| rules::typed(ctx, id));
            (id, token_in(&text))
        }

        fn replies(&self, now: i64, answer: &str) {
            crate::history::publish_reply(self.history.file(), &self.key, "Agent", answer, None).unwrap();
            let reply: i64 = self.history.db().unwrap()
                .query_row("SELECT max(id) FROM journal", [], |row| row.get(0)).unwrap();
            self.at(now, |ctx| rules::on_reply(ctx, &self.bot, &self.key, reply, answer));
        }

        fn step(&self, now: i64, outcome: &str, evidence: &str, extra: &str) {
            assert_eq!(self.at(now, advance), 1);
            let (_, token) = self.typed(now);
            self.replies(
                now + MINUTE,
                &format!("Working on it.\n{{\"iteration\":\"{token}\",\"outcome\":\"{outcome}\",\"evidence\":\"{evidence}\"{extra}}}"),
            );
        }
    }

    #[test]
    fn a_goal_steps_by_itself_until_the_bot_shows_it_is_met() {
        let f = Fixture::new();
        let set = f.at(NOON, |ctx| start(ctx, &f.bot, "  Tidy the build folder ", None)).unwrap();
        assert_eq!((set.state.as_str(), set.iteration, set.step_limit), ("queued", 0, DEFAULT_STEPS));
        assert_eq!(set.objective, "Tidy the build folder");

        assert_eq!(f.at(NOON, advance), 1);
        assert_eq!(f.at(NOON, advance), 0, "one step at a time");
        let first = pending(&f.history).pop().unwrap().1;
        assert!(first.starts_with("[Goal step 1, from SwarmHub] The person set this goal for you: Tidy the build folder"));
        assert!(first.contains("End your reply with one JSON line") && !first.contains("Last result"));
        let (_, token) = f.typed(NOON);
        assert_eq!(f.goal().state, "running");
        f.replies(NOON + MINUTE, &format!("Removed the old objects.\n{{\"iteration\":\"{token}\",\"outcome\":\"progress\",\"evidence\":\"Removed 40 object files\"}}"));
        let after = f.goal();
        assert_eq!((after.state.as_str(), after.detail.as_str()), ("queued", "Removed 40 object files"));
        // The chat gets the bot's words without the report line, and no alert for a step.
        let said = lines(&f.history, "Infra", "said");
        assert_eq!(said.last().unwrap(), &(Some("goal".into()), "Removed the old objects.".into(), false));

        // The next step carries the last result, and nobody had to ask for it.
        assert_eq!(f.at(NOON + 2 * MINUTE, advance), 1);
        let second = pending(&f.history).pop().unwrap().1;
        assert!(second.starts_with("[Goal step 2, from SwarmHub]") && second.contains("Last result: Removed 40 object files"));
        let (_, token) = f.typed(NOON + 2 * MINUTE);
        f.replies(NOON + 3 * MINUTE, &format!("{{\"iteration\":\"{token}\",\"outcome\":\"complete\",\"evidence\":\"The folder holds only sources\"}}"));
        let done = f.goal();
        assert_eq!((done.state.as_str(), done.iteration), ("completed", 2));
        assert_eq!(f.at(NOON + 4 * MINUTE, advance), 0);
        // A reply that is only the report shows its evidence; the person is told the goal is complete.
        assert_eq!(lines(&f.history, "Infra", "said").last().unwrap().1, "The folder holds only sources");
        assert_eq!(
            lines(&f.history, "Infra", "notice").last().unwrap(),
            &(Some("goal".into()), "Goal completed: Tidy the build folder".into(), true)
        );
    }

    #[test]
    fn a_blocked_goal_waits_for_the_person_and_goes_on_when_they_answer() {
        let f = Fixture::new();
        f.at(NOON, |ctx| start(ctx, &f.bot, "Rotate the staging keys", None)).unwrap();
        f.step(NOON, "blocked", "Which key vault should I use?", "");
        let waits = f.goal();
        assert_eq!((waits.state.as_str(), waits.pause.as_deref()), ("waiting", Some("blocked")));
        assert_eq!(f.at(NOON + 5 * MINUTE, advance), 0);
        assert!(lines(&f.history, "Infra", "notice").last().unwrap().1.contains("Infra needs your answer"));

        // The person answers in the chat: a task of theirs, and the agent's reply to it.
        let (task, _) = f.history.start_task("core", &f.terminal, "Use the shared vault.", None, false, &[]).unwrap();
        f.history.finish(task, crate::history::State::Sent, None, None).unwrap();
        f.replies(NOON + 10 * MINUTE, "Understood, the shared vault.");
        let again = f.goal();
        assert_eq!((again.state.as_str(), again.pause), ("queued", None));
        assert!(again.detail.starts_with("The person replied in chat after you reported: Which key vault"));
        assert_eq!(f.at(NOON + 11 * MINUTE, advance), 1);

        // A method that is blocked while another is open is no reason to wait.
        let (_, token) = f.typed(NOON + 11 * MINUTE);
        f.replies(NOON + 12 * MINUTE, &format!("{{\"iteration\":\"{token}\",\"outcome\":\"blocked\",\"evidence\":\"The API is down\",\"alternateAction\":\"Use the CLI\"}}"));
        let next = f.goal();
        assert_eq!(next.state, "queued");
        assert!(next.detail.starts_with("Next authorized action: Use the CLI"));
    }

    #[test]
    fn two_steps_without_progress_pause_and_resume_starts_the_count_again() {
        let f = Fixture::new();
        f.at(NOON, |ctx| start(ctx, &f.bot, "Speed up the report", None)).unwrap();
        f.step(NOON, "progress", "Cached the totals", "");
        f.step(NOON + 5 * MINUTE, "progress", "cached  the TOTALS", "");
        assert_eq!(f.goal().state, "queued", "the same result once more is one stall");
        f.step(NOON + 10 * MINUTE, "no_progress", "Nothing left to cache", "");
        let stalled = f.goal();
        assert_eq!((stalled.state.as_str(), stalled.pause.as_deref()), ("waiting", Some("stalled")));
        assert!(stalled.detail.starts_with("Two steps produced no new progress."));
        assert!(f.at(NOON + 11 * MINUTE, |ctx| person_answered(ctx, &f.bot.id)).eq(&()));
        assert_eq!(f.goal().state, "waiting", "only a goal that asked the person goes on by their message");

        assert_eq!(f.at(NOON + 12 * MINUTE, |ctx| resume(ctx, &f.bot.id)).unwrap().state, "queued");
        f.step(NOON + 13 * MINUTE, "failed", "The profiler crashed", "");
        assert_eq!(f.goal().state, "queued", "one failure after Resume is not two");
        assert!(f.at(NOON + 14 * MINUTE, |ctx| resume(ctx, &f.bot.id)).is_none(), "nothing waits");
    }

    #[test]
    fn the_step_limit_stops_a_goal_and_a_new_goal_replaces_the_old() {
        let f = Fixture::new();
        assert!(f.at(NOON, |ctx| start(ctx, &f.bot, " ", None)).is_err());
        assert!(f.at(NOON, |ctx| start(ctx, &f.bot, "x", Some(0))).is_err());
        f.at(NOON, |ctx| start(ctx, &f.bot, "Review the queue", Some(1))).unwrap();
        f.step(NOON, "progress", "Reviewed ten items", "");
        let stopped = f.goal();
        assert_eq!((stopped.state.as_str(), stopped.detail.as_str()), ("stopped", "Step limit reached. Reviewed ten items"));
        assert!(lines(&f.history, "Infra", "notice").last().unwrap().1.starts_with("Goal stopped: Step limit reached."));

        let first = f.at(NOON + 5 * MINUTE, |ctx| start(ctx, &f.bot, "First", None)).unwrap();
        assert_eq!(f.at(NOON + 5 * MINUTE, advance), 1);
        let second = f.at(NOON + 6 * MINUTE, |ctx| start(ctx, &f.bot, "Second", None)).unwrap();
        assert!(pending(&f.history).is_empty(), "the replaced goal's step is taken back");
        let db = f.history.db().unwrap();
        assert_eq!(one(&db, first.id).unwrap().unwrap().detail, "Replaced by a new goal.");
        assert_eq!(latest_all(&db).unwrap().iter().map(|goal| goal.id).collect::<Vec<_>>(), [second.id]);
        drop(db);

        // Stop takes back a step that was not typed yet and leaves nothing to advance.
        assert_eq!(f.at(NOON + 7 * MINUTE, advance), 1);
        let ended = f.at(NOON + 8 * MINUTE, |ctx| stop(ctx, &f.bot.id)).unwrap();
        assert_eq!((ended.state.as_str(), ended.detail.as_str()), ("stopped", "Stopped by you."));
        assert!(pending(&f.history).is_empty());
        assert_eq!(f.at(NOON + 9 * MINUTE, advance), 0);
        assert!(f.at(NOON + 9 * MINUTE, |ctx| stop(ctx, &f.bot.id)).is_none());
    }

    #[test]
    fn a_numeric_goal_is_complete_only_with_a_measurement_that_reaches_it() {
        assert_eq!(free_space_target("Get 20 GB free on OVH"), Some((20.0, "GB".into())));
        assert_eq!(free_space_target("zrobic 20 GB wolnego na OVH"), Some((20.0, "GB".into())));
        assert_eq!(free_space_target("Please free up 1,5TiB of free space."), Some((1.5, "TiB".into())));
        assert_eq!(free_space_target("Zapewnij 35 GiB wolnej przestrzeni na M4"), Some((35.0, "GiB".into())));
        assert_eq!(free_space_target("Report whether OVH has 20 GB free"), None);
        assert_eq!(free_space_target("Get the 20 GB archive off OVH"), None);

        let f = Fixture::new();
        f.at(NOON, |ctx| start(ctx, &f.bot, "Get 20 GB free on OVH", None)).unwrap();
        assert_eq!(f.at(NOON, advance), 1);
        assert!(pending(&f.history).pop().unwrap().1.contains("Required measurement: free space on the requested volume, target 20 GB, direction increase."));
        let (_, token) = f.typed(NOON);
        // "Done" without a measurement is not done.
        f.replies(NOON + MINUTE, &format!("{{\"iteration\":\"{token}\",\"outcome\":\"complete\",\"evidence\":\"Moved the logs\"}}"));
        let unproven = f.goal();
        assert_eq!(unproven.state, "queued");
        assert!(unproven.detail.starts_with("Measure the target again to verify the result."));
        // Progress that is measured is kept as the best reading.
        f.step(NOON + 2 * MINUTE, "progress", "Removed caches", ",\"measurement\":{\"unit\":\"GB\",\"direction\":\"increase\",\"target\":20,\"before\":2,\"after\":12}");
        assert_eq!(f.goal().best.unwrap().after, 12.0);
        assert_eq!(f.at(NOON + 4 * MINUTE, advance), 1);
        assert!(pending(&f.history).pop().unwrap().1.contains("Best reported measurement: 12 GB, target 20 (increase)."));
        let (_, token) = f.typed(NOON + 4 * MINUTE);
        // A reading short of the target does not complete it, and another unit is not accepted.
        f.replies(NOON + 5 * MINUTE, &format!("{{\"iteration\":\"{token}\",\"outcome\":\"complete\",\"evidence\":\"19 GB free\",\"measurement\":{{\"unit\":\"GB\",\"direction\":\"increase\",\"target\":20,\"before\":12,\"after\":19}}}}"));
        assert!(f.goal().detail.starts_with("The reported measurement is short of the target."));
        f.at(NOON + 6 * MINUTE, |ctx| resume(ctx, &f.bot.id));
        f.step(NOON + 6 * MINUTE, "complete", "24 GB free", ",\"measurement\":{\"unit\":\"GB\",\"direction\":\"increase\",\"target\":20,\"before\":19,\"after\":24.4}");
        let done = f.goal();
        assert_eq!((done.state.as_str(), done.best.unwrap().after), ("completed", 24.4));
    }

    #[test]
    fn a_step_that_does_not_arrive_or_gets_no_result_pauses_the_goal() {
        let f = Fixture::new();
        f.at(NOON, |ctx| start(ctx, &f.bot, "Check the mirrors", None)).unwrap();
        // Something else waits to be typed for this bot: it goes first.
        let other = f.at(NOON, |ctx| post(ctx, Post { bot: &f.bot.id, text: "A note.", cause: "notice", ..Post::default() }));
        assert_eq!(f.at(NOON, advance), 0);
        f.at(NOON, |ctx| rules::typed(ctx, other));
        assert_eq!(f.at(NOON, advance), 1);

        // The step cannot be typed: it is tried once more, then the goal pauses.
        let first = pending(&f.history).pop().unwrap();
        f.at(NOON + MINUTE, |ctx| rules::untyped(ctx, first.0, "its agent could not be started."));
        assert_eq!(f.at(NOON + MINUTE, overdue), 0);
        let again = pending(&f.history).pop().unwrap();
        assert!(again.0 != first.0 && again.1 == first.1, "the same step, typed again");
        f.at(NOON + 2 * MINUTE, |ctx| rules::untyped(ctx, again.0, "its agent could not be started."));
        assert_eq!(f.at(NOON + 2 * MINUTE, overdue), 1);
        let lost = f.goal();
        assert_eq!((lost.state.as_str(), lost.pause.as_deref()), ("waiting", Some("undelivered")));
        assert!(lost.detail.contains("also on a second try: its agent could not be started."));

        // Resumed, typed, and then silence for an hour.
        f.at(NOON + 3 * MINUTE, |ctx| resume(ctx, &f.bot.id));
        assert_eq!(f.at(NOON + 3 * MINUTE, advance), 1);
        let (outbox, token) = f.typed(NOON + 3 * MINUTE);
        assert_eq!(f.at(NOON + 62 * MINUTE, overdue), 0);
        assert_eq!(f.at(NOON + 63 * MINUTE, overdue), 1);
        let silent = f.goal();
        assert_eq!((silent.state.as_str(), silent.pause.as_deref()), ("waiting", Some("silent")));
        let flagged: String = f.history.db().unwrap()
            .query_row("SELECT text FROM bot_flags WHERE kind='goal'", [], |row| row.get(0)).unwrap();
        assert!(flagged.contains("Read Infra's terminal"));
        // Its answer, when it does come, is shown and changes nothing by itself.
        f.replies(NOON + 70 * MINUTE, &format!("Late.\n{{\"iteration\":\"{token}\",\"outcome\":\"complete\",\"evidence\":\"All mirrors answer\"}}"));
        assert_eq!(f.goal().state, "waiting");
        assert_eq!(lines(&f.history, "Infra", "said").last().unwrap().1, "Late.");
        let _ = outbox;

        // A reply to a step without its report line pauses the goal for the person to read.
        f.at(NOON + 71 * MINUTE, |ctx| resume(ctx, &f.bot.id));
        assert_eq!(f.at(NOON + 71 * MINUTE, advance), 1);
        f.typed(NOON + 71 * MINUTE);
        f.replies(NOON + 72 * MINUTE, "I looked at the mirrors.");
        let unconfirmed = f.goal();
        assert_eq!((unconfirmed.state.as_str(), unconfirmed.pause.as_deref()), ("waiting", Some("unconfirmed")));
    }
}
