//! The messages between bots, as rows. Every function here runs inside one transaction (`Ctx`), checks a rule of
//! `docs/bot-communication.md`, and writes what follows from it: the message, a line in each bot's history, and
//! what is to be typed into an agent (`bot_outbox`, which `desk` empties). Nothing here waits or talks to Core.
//!
//! - Three kinds: an ask is open until it is answered, declined or not answered in time; a tell is sent and
//!   done; a hand-off is open until it is accepted, declined or not accepted in time, and accepted until its
//!   result is reported.
//! - One owner: a piece of work (`bot_work`) belongs to the bot that started it until another bot accepts a
//!   hand-off of it. Only the owner hands it off, and to one bot at a time.
//! - The limits: so many messages between the same two bots about one piece of work and so many new messages per bot in a while. A reply, an acceptance or a refusal of
//!   something that is still open always goes through, so nothing is left hanging because of a limit.
//! - A stop ends every exchange the stopped bot is part of, and the bots that waited are told.

use super::{Bot, Ctx, blocks, notes, plans};
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::Serialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    Ask,
    Tell,
    Handoff,
}

impl Kind {
    pub(crate) fn parse(name: &str) -> Option<Self> {
        match name {
            "ask" => Some(Self::Ask),
            "tell" => Some(Self::Tell),
            "handoff" => Some(Self::Handoff),
            _ => None,
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Tell => "tell",
            Self::Handoff => "handoff",
        }
    }
}

/// A kind as a sentence says it.
fn word(kind: &str) -> &str {
    if kind == "handoff" { "hand-off" } else { kind }
}

pub(crate) enum Closing<'a> {
    Reply(&'a str),
    Accept,
    Decline(&'a str),
}

/// Why a bot was taken out of its exchanges.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Why {
    Person,
    Switch,
    Removed,
}

impl Why {
    fn clause(self) -> &'static str {
        match self {
            Self::Person => "was stopped by the person",
            Self::Switch => "may no longer message other bots (the person turned that off)",
            Self::Removed => "was removed by the person",
        }
    }
}

#[derive(Clone, Debug)]
pub(crate) struct Message {
    pub id: i64,
    pub work: i64,
    pub kind: String,
    pub sender: String,
    pub receiver: String,
    pub text: String,
    pub about: Option<i64>,
    pub state: String,
    pub via: String,
    pub sent_ms: i64,
    pub delivered_ms: Option<i64>,
    pub deadline_ms: Option<i64>,
    pub ended_ms: Option<i64>,
}

const MESSAGE: &str =
    "id,work,kind,sender,receiver,text,about,state,via,sent_ms,delivered_ms,deadline_ms,ended_ms";

fn read_message(row: &Row<'_>) -> rusqlite::Result<Message> {
    Ok(Message {
        id: row.get(0)?,
        work: row.get(1)?,
        kind: row.get(2)?,
        sender: row.get(3)?,
        receiver: row.get(4)?,
        text: row.get(5)?,
        about: row.get(6)?,
        state: row.get(7)?,
        via: row.get(8)?,
        sent_ms: row.get(9)?,
        delivered_ms: row.get(10)?,
        deadline_ms: row.get(11)?,
        ended_ms: row.get(12)?,
    })
}

pub(crate) fn message(db: &Connection, id: i64) -> rusqlite::Result<Option<Message>> {
    db.prepare_cached(&format!("SELECT {MESSAGE} FROM bot_messages WHERE id=?1"))?
        .query_row([id], read_message)
        .optional()
}

struct Work {
    id: i64,
    owner: String,
    origin: String,
    chain: Vec<String>,
    state: String,
    ended_why: Option<String>,
}

fn work(db: &Connection, id: i64) -> rusqlite::Result<Work> {
    db.query_row(
        "SELECT id,owner,origin,chain,state,ended_why FROM bot_work WHERE id=?1",
        [id],
        |row| {
            Ok(Work {
                id: row.get(0)?,
                owner: row.get(1)?,
                origin: row.get(2)?,
                chain: serde_json::from_str(&row.get::<_, String>(3)?).unwrap_or_default(),
                state: row.get(4)?,
                ended_why: row.get(5)?,
            })
        },
    )
}

/// What a line in a bot's history is about, beside its text.
#[derive(Default)]
pub(crate) struct About<'a> {
    pub code: Option<&'a str>,
    pub message: Option<i64>,
    pub journal: Option<i64>,
    pub checkin: Option<i64>,
    pub promise: Option<i64>,
}

/// Adds a line to a bot's history. `unread` raises the bot's unread mark; `notify` a notification as well,
/// unless the bot's Notifications switch is off.
pub(crate) fn entry(
    ctx: &Ctx<'_>,
    bot: &str,
    kind: &str,
    text: &str,
    about: About<'_>,
    unread: bool,
    notify: bool,
) -> rusqlite::Result<i64> {
    ctx.db.query_row(
        "INSERT INTO bot_history (bot,kind,text,at_ms,unread,notify,code,message,journal,checkin,promise)
         VALUES (?1,?2,?3,?4,?5,
                 ?6 AND coalesce((SELECT notifications FROM bots WHERE id=?1),1),
                 ?7,?8,?9,?10,?11) RETURNING id",
        params![
            bot,
            kind,
            text,
            ctx.now,
            unread,
            notify,
            about.code,
            about.message,
            about.journal,
            about.checkin,
            about.promise
        ],
        |row| row.get(0),
    )
}

/// Something to type into a bot's agent.
#[derive(Default)]
pub(crate) struct Post<'a> {
    pub bot: &'a str,
    pub text: &'a str,
    pub cause: &'a str,
    pub message: Option<i64>,
    pub work: Option<i64>,
    pub checkin: Option<i64>,
    pub promise: Option<i64>,
    pub quiet: bool,
}

pub(crate) fn post(ctx: &Ctx<'_>, post: Post<'_>) -> rusqlite::Result<i64> {
    ctx.db.query_row(
        "INSERT INTO bot_outbox (bot,text,cause,message,work,checkin,promise,quiet,created_ms,give_up_ms,delivery_receipt)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,CASE WHEN ?3 IN ('message','outcome') THEN 'unsent' END) RETURNING id",
        params![
            post.bot,
            post.text,
            post.cause,
            post.message,
            post.work,
            post.checkin,
            post.promise,
            post.quiet,
            ctx.now,
            ctx.now + seconds(ctx.set.deliver_seconds)
        ],
        |row| row.get(0),
    )
}

pub(crate) fn seconds(count: u64) -> i64 {
    i64::try_from(count.saturating_mul(1_000)).unwrap_or(i64::MAX)
}

/// Plain text of at most `limit` characters, or `None` when nothing is left.
pub(crate) fn clean(text: &str, limit: usize) -> Option<String> {
    let text: String = text
        .trim()
        .chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .take(limit)
        .collect();
    (!text.trim().is_empty()).then_some(text)
}

fn same_name(one: &str, other: &str) -> bool {
    notes::line(one).to_lowercase() == notes::line(other).to_lowercase()
}

/// The bot `to` names for `sender`: by its name, whatever the case, or by its agent's name.
fn named(db: &Connection, sender: &Bot, to: &str) -> rusqlite::Result<Result<Bot, String>> {
    let others: Vec<Bot> = super::all(db)?
        .into_iter()
        .filter(|bot| bot.id != sender.id)
        .collect();
    let mut matches: Vec<&Bot> = others
        .iter()
        .filter(|bot| same_name(&bot.name, to))
        .collect();
    if matches.is_empty() {
        matches = others
            .iter()
            .filter(|bot| bot.agent_name == to || bot.id == to)
            .collect();
    }
    let open: Vec<String> = others
        .iter()
        .filter(|bot| bot.takes_messages)
        .map(|bot| format!("\"{}\"", notes::line(&bot.name)))
        .collect();
    let roster = if open.is_empty() {
        "No bot here takes messages right now.".to_owned()
    } else {
        format!("Bots you can write to: {}.", open.join(", "))
    };
    let to = notes::line(to).chars().take(40).collect::<String>();
    Ok(match matches.as_slice() {
        [] => Err(format!(
            "No bot named \"{to}\" can be written to here, so nothing was sent. {roster}"
        )),
        [one] if one.takes_messages => Ok((*one).clone()),
        [_] => Err(format!(
            "\"{to}\" does not take messages from other bots, so nothing was sent. Tell the person if you need it: they can allow it in that bot's settings."
        )),
        _ => Err(format!(
            "More than one bot here is named \"{to}\", so nothing was sent. Tell the person: they have to rename one."
        )),
    })
}

/// The newest task typed into the session of this launch, before the row `before` when one is given.
pub(crate) fn newest_task(
    db: &Connection,
    key: &str,
    before: Option<i64>,
) -> rusqlite::Result<Option<i64>> {
    db.query_row(
        "SELECT max(t.id) FROM journal l JOIN journal t
           ON t.id=l.id OR (t.core_id=l.core_id AND t.address=l.address AND t.created_ms=l.created_ms)
         WHERE l.launch_key=?1 AND t.kind='task' AND t.state!='not_sent' AND t.text!='' AND t.id<?2",
        params![key, before.unwrap_or(i64::MAX)],
        |row| row.get(0),
    )
}

/// The piece of work a new message of `sender` belongs to. A message sent while answering something another
/// bot or the workspace sent about a piece of work belongs to that work. Anything else (a turn the person
/// started, a check-in) starts a new piece of work, which further messages of the same turn join.
fn work_for(ctx: &Ctx<'_>, sender: &Bot, task: Option<i64>) -> rusqlite::Result<Work> {
    let caused: Option<(String, Option<i64>)> = match task {
        Some(task) => ctx
            .db
            .query_row(
                "SELECT cause,work FROM bot_outbox WHERE task=?1",
                [task],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?,
        None => None,
    };
    if let Some((_, Some(id))) = caused {
        return work(ctx.db, id);
    }
    let known: Option<i64> = ctx
        .db
        .query_row(
            // Without a task to go by, a piece of work that was ended is not taken up again.
            "SELECT id FROM bot_work WHERE started_by=?1 AND anchor IS ?2 AND (state='open' OR ?2 IS NOT NULL)
             ORDER BY id DESC LIMIT 1",
            params![sender.id, task],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(id) = known {
        return work(ctx.db, id);
    }
    let origin = match (&caused, task) {
        (Some((cause, _)), _) => cause.as_str(),
        (None, Some(_)) => "person",
        (None, None) => "none",
    };
    let id: i64 = ctx.db.query_row(
        "INSERT INTO bot_work (started_by,owner,origin,anchor,chain,started_ms) VALUES (?1,?1,?2,?3,?4,?5) RETURNING id",
        params![
            sender.id,
            origin,
            task,
            serde_json::to_string(&[&sender.id]).unwrap_or_default(),
            ctx.now
        ],
        |row| row.get(0),
    )?;
    work(ctx.db, id)
}

/// A line about a limit, once per piece of work for each bot it is written to.
fn limit_line(ctx: &Ctx<'_>, bot: &str, code: &str, work: i64, text: &str) -> rusqlite::Result<()> {
    let said: bool = ctx.db.query_row(
        "SELECT EXISTS(SELECT 1 FROM bot_history h WHERE h.bot=?1 AND h.code=?2 AND h.at_ms>?4
                         AND (h.message IS NULL OR h.message IN (SELECT id FROM bot_messages WHERE work=?3)))",
        params![bot, code, work, ctx.now - seconds(ctx.set.window_seconds)],
        |row| row.get(0),
    )?;
    if !said {
        let last: Option<i64> = ctx.db.query_row(
            "SELECT max(id) FROM bot_messages WHERE work=?1",
            [work],
            |row| row.get(0),
        )?;
        entry(
            ctx,
            bot,
            "notice",
            text,
            About {
                code: Some(code),
                message: last,
                ..About::default()
            },
            true,
            true,
        )?;
    }
    Ok(())
}

#[derive(Debug)]
pub(crate) struct Sent {
    /// The message's number, which `text` also says.
    #[cfg_attr(not(test), expect(dead_code))]
    pub id: i64,
    /// What the sending agent reads.
    pub text: String,
}

/// Sends an ask, a tell or a hand-off from `sender` to the bot named `to`. `task` is the newest task of the
/// sender's session (`newest_task`), which says what piece of work this is about. An `Err` is a refusal in
/// words for the sender; nothing was sent then.
pub(crate) fn send(
    ctx: &Ctx<'_>,
    sender: &Bot,
    task: Option<i64>,
    kind: Kind,
    to: &str,
    text: &str,
    via: &str,
) -> rusqlite::Result<Result<Sent, String>> {
    if !sender.may_message {
        return Ok(Err("The person turned off messages to other bots for you, so nothing was sent. Ask the person instead.".into()));
    }
    let Some(text) = clean(text, blocks::MESSAGE_CHARS) else {
        return Ok(Err(
            "Write what to send: plain text, up to 4000 characters.".into(),
        ));
    };
    let receiver = match named(ctx.db, sender, to)? {
        Ok(receiver) => receiver,
        Err(refusal) => return Ok(Err(refusal)),
    };
    let work = work_for(ctx, sender, task)?;
    let (from, name) = (notes::line(&sender.name), notes::line(&receiver.name));
    if work.state != "open" {
        return Ok(Err(format!(
            "This exchange was ended ({}), so nothing was sent. Tell the person where things stand; only they can start it again.",
            work.ended_why.as_deref().unwrap_or("it was stopped")
        )));
    }
    if kind == Kind::Handoff {
        if work.owner != sender.id {
            return Ok(Err(format!(
                "This piece of work is not yours to hand off: {} owns it. Ask \"{name}\" for what you need with `{} bot ask`, or leave the hand-off to its owner.",
                super::name_of(ctx.db, &work.owner),
                ctx.cmd
            )));
        }
        let pending: Option<(i64, String)> = ctx
            .db
            .query_row(
                "SELECT id,receiver FROM bot_messages WHERE work=?1 AND kind='handoff' AND state='open' LIMIT 1",
                [work.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?;
        if let Some((id, other)) = pending {
            return Ok(Err(format!(
                "You already handed this work to {} (hand-off #{id}), which has not accepted or declined yet. A piece of work goes to one bot at a time: wait for it.",
                super::name_of(ctx.db, &other)
            )));
        }
    }
    let between: u32 = ctx.db.query_row(
        "SELECT count(*) FROM bot_messages WHERE work=?1
           AND ((sender=?2 AND receiver=?3) OR (sender=?3 AND receiver=?2))",
        params![work.id, sender.id, receiver.id],
        |row| row.get(0),
    )?;
    if between >= ctx.set.pair_messages {
        let line = format!(
            "{from} and {name} have exchanged {between} messages about this, which is the limit. {from} was told to bring the matter to you."
        );
        limit_line(ctx, &sender.id, "limit_pair", work.id, &line)?;
        limit_line(ctx, &receiver.id, "limit_pair", work.id, &line)?;
        return Ok(Err(format!(
            "You and \"{name}\" have exchanged {between} messages about this piece of work, which is the limit, so nothing was sent. Do not write to \"{name}\" about it again. Bring the matter to the person: tell them what is still open."
        )));
    }
    let recent: u32 = ctx.db.query_row(
        "SELECT count(*) FROM bot_messages WHERE sender=?1 AND kind IN ('ask','tell','handoff') AND sent_ms>?2",
        params![sender.id, ctx.now - seconds(ctx.set.window_seconds)],
        |row| row.get(0),
    )?;
    if recent >= ctx.set.messages_per_window {
        let window = notes::span(ctx.set.window_seconds);
        limit_line(
            ctx,
            &sender.id,
            "limit_rate",
            work.id,
            &format!(
                "{from}'s message to {name} was not sent: it has written to other bots {recent} times in the last {window}, which is the limit. {from} was told to bring it to you."
            ),
        )?;
        return Ok(Err(format!(
            "You have sent {recent} messages to other bots in the last {window}, which is the limit, so nothing was sent. Tell the person what you wanted to send."
        )));
    }

    let state = if kind == Kind::Tell { "sent" } else { "open" };
    let id: i64 = ctx.db.query_row(
        "INSERT INTO bot_messages (work,kind,sender,receiver,text,state,via,sent_ms) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) RETURNING id",
        params![work.id, kind.name(), sender.id, receiver.id, text, state, via, ctx.now],
        |row| row.get(0),
    )?;
    if !work.chain.contains(&receiver.id) {
        let mut chain = work.chain.clone();
        chain.push(receiver.id.clone());
        ctx.db.execute(
            "UPDATE bot_work SET chain=?2 WHERE id=?1",
            params![work.id, serde_json::to_string(&chain).unwrap_or_default()],
        )?;
    }
    for bot in [&sender.id, &receiver.id] {
        let about = About {
            code: Some(kind.name()),
            message: Some(id),
            ..About::default()
        };
        entry(ctx, bot, "message", &text, about, false, false)?;
    }
    let from_person = work.origin == "person";
    let typed = match kind {
        Kind::Ask => notes::ask(ctx.cmd, &sender.name, id, &text, ctx.set),
        Kind::Tell => notes::tell(&sender.name, id, &text),
        Kind::Handoff => notes::handoff(ctx.cmd, &sender.name, id, &text, ctx.set, from_person),
    };
    post(
        ctx,
        Post {
            bot: &receiver.id,
            text: &typed,
            cause: "message",
            message: Some(id),
            work: Some(work.id),
            ..Post::default()
        },
    )?;
    let text = match kind {
        Kind::Ask => format!(
            "Sent ask #{id} to \"{name}\". Its answer comes to you later as a message, also when you are not working: do not wait or poll for it. Finish your reply now and say that you asked."
        ),
        Kind::Tell => format!("Sent tell #{id} to \"{name}\". No answer will come."),
        Kind::Handoff => format!(
            "Sent hand-off #{id} to \"{name}\". It has {} to accept or decline, and you are told which. The work stays yours until it accepts; its result comes to you later as a message. Finish your reply now and say that you handed it over.",
            notes::span(ctx.set.handoff_accept_seconds)
        ),
    };
    Ok(Ok(Sent { id, text }))
}

fn close_message(ctx: &Ctx<'_>, id: i64, state: &str) -> rusqlite::Result<()> {
    ctx.db.execute(
        "UPDATE bot_messages SET state=?2,ended_ms=?3,deadline_ms=NULL WHERE id=?1",
        params![id, state, ctx.now],
    )?;
    Ok(())
}

/// Records what `bot` sends back about message `about`: a row, and a line in both histories.
fn back(
    ctx: &Ctx<'_>,
    about: &Message,
    kind: &str,
    text: &str,
    via: &str,
) -> rusqlite::Result<i64> {
    if let Some(outbox) = ctx.db.query_row(
        "SELECT id FROM bot_outbox WHERE cause='message' AND message=?1 AND bot=?2
         AND (state IN ('pending','typing') OR (state='typed' AND delivery_receipt='uncertain'))",
        params![about.id, about.receiver],
        |row| row.get(0),
    ).optional()? {
        typed(ctx, outbox)?;
    }
    let id: i64 = ctx.db.query_row(
        "INSERT INTO bot_messages (work,kind,sender,receiver,text,about,state,via,sent_ms)
         VALUES (?1,?2,?3,?4,?5,?6,'sent',?7,?8) RETURNING id",
        params![
            about.work,
            kind,
            about.receiver,
            about.sender,
            text,
            about.id,
            via,
            ctx.now
        ],
        |row| row.get(0),
    )?;
    for bot in [&about.receiver, &about.sender] {
        let line = About {
            code: Some(kind),
            message: Some(id),
            ..About::default()
        };
        entry(ctx, bot, "message", text, line, false, false)?;
    }
    Ok(id)
}

/// `bot` answers, accepts or declines the ask or hand-off `id` that was sent to it. `Ok` is what its agent
/// reads. A late response expires the open message before returning a refusal.
pub(crate) fn close(
    ctx: &Ctx<'_>,
    bot: &Bot,
    id: i64,
    closing: Closing<'_>,
    via: &str,
) -> rusqlite::Result<Result<String, String>> {
    let cmd = ctx.cmd;
    let Some(about) = message(ctx.db, id)?
        .filter(|m| m.receiver == bot.id && matches!(m.kind.as_str(), "ask" | "handoff"))
    else {
        return Ok(Err(format!(
            "No ask or hand-off #{id} was sent to you. `{cmd} bot list` shows what is open."
        )));
    };
    let asker = notes::line(&super::name_of(ctx.db, &about.sender));
    let kind = word(&about.kind).to_owned();
    let work = work(ctx.db, about.work)?;
    let ended = |how: &str| Ok(Err(format!("The {kind} #{id} {how}, so nothing was sent.")));
    match about.state.as_str() {
        "open" | "accepted" if work.state == "open" => {}
        "open" | "accepted" | "stopped" => {
            return ended(&format!(
                "was ended ({})",
                work.ended_why.as_deref().unwrap_or("it was stopped")
            ));
        }
        "answered" => return ended("is already answered"),
        "declined" => return ended("was already declined"),
        _ => {
            let ago =
                u64::try_from((ctx.now - about.ended_ms.unwrap_or(ctx.now)) / 1_000).unwrap_or(0);
            let ago = notes::span(if ago >= 60 { ago / 60 * 60 } else { ago });
            return Ok(Err(format!(
                "The {kind} #{id} ended {ago} ago because it was not {} in time, and {asker} was told. If it still matters, send a new message: {cmd} bot tell \"{asker}\" \"TEXT\".",
                if about.kind == "ask" {
                    "answered"
                } else {
                    "accepted"
                }
            )));
        }
    }
    // A delayed acknowledgement can arrive between the delivery deadline and the next clock tick.
    if about.state == "open" && about.delivered_ms.is_none() {
        let overdue = ctx.db.query_row(
            "SELECT id,state FROM bot_outbox WHERE cause='message' AND message=?1
             AND state IN ('pending','typing') AND give_up_ms<=?2",
            params![id, ctx.now],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?)),
        ).optional()?;
        if let Some((outbox, state)) = overdue {
            if state == "pending" {
                untyped(ctx, outbox, "its delivery deadline passed.")?;
            } else {
                // The attempt may have reached the recipient. Leave its receipt uncertain.
                end_unanswered(ctx, &about, None)?;
            }
            return ended("passed its delivery deadline");
        }
    }
    if about.state == "open" && about.deadline_ms.is_some_and(|deadline| ctx.now >= deadline) {
        end_unanswered(ctx, &about, None)?;
        return ended("passed its deadline");
    }
    let from_person = work.origin == "person";
    // What comes back is typed into the agent of the bot that asked.
    let outcome = |text: String, message: i64| {
        post(
            ctx,
            Post {
                bot: &about.sender,
                text: &text,
                cause: "outcome",
                message: Some(message),
                work: Some(about.work),
                ..Post::default()
            },
        )
    };
    match (about.kind.as_str(), about.state.as_str(), closing) {
        ("ask", _, Closing::Accept) => Ok(Err(format!(
            "An ask needs an answer, not an acceptance: {cmd} bot reply {id} \"YOUR ANSWER\"."
        ))),
        ("handoff", "accepted", Closing::Accept) => Ok(Err(format!(
            "You already accepted hand-off #{id}. Report its result with: {cmd} bot reply {id} \"RESULT\"."
        ))),
        (_, _, Closing::Reply(text)) => {
            let Some(text) = clean(text, blocks::ANSWER_CHARS) else {
                return Ok(Err(
                    "Write the answer: plain text, up to 6000 characters.".into()
                ));
            };
            let handoff = about.kind == "handoff";
            if handoff && about.state == "open" {
                // A result without an acceptance: the work was taken over all the same.
                back(ctx, &about, "accept", "Accepted.", via)?;
                ctx.db.execute(
                    "UPDATE bot_work SET owner=?2 WHERE id=?1",
                    params![about.work, bot.id],
                )?;
            }
            let reply = back(ctx, &about, "reply", &text, via)?;
            close_message(ctx, id, "answered")?;
            let typed = if handoff {
                notes::report(&bot.name, id, &text, from_person)
            } else {
                notes::answer(&bot.name, id, &text)
            };
            outcome(typed, reply)?;
            Ok(Ok(if handoff {
                format!("Reported the result of hand-off #{id} to {asker}.")
            } else {
                format!("Answered ask #{id}: {asker} gets it as its next message.")
            }))
        }
        (_, _, Closing::Decline(reason)) => {
            let Some(reason) = clean(reason, 600) else {
                return Ok(Err(format!(
                    "Say why: {cmd} bot decline {id} \"WHY\". {asker} is told your reason."
                )));
            };
            let decline = back(ctx, &about, "decline", &reason, via)?;
            close_message(ctx, id, "declined")?;
            // A hand-off that was accepted and is given back: the work is the sender's again.
            ctx.db.execute(
                "UPDATE bot_work SET owner=?2 WHERE id=?1 AND owner=?3",
                params![about.work, about.sender, bot.id],
            )?;
            outcome(notes::declined(&bot.name, id, &kind, &reason), decline)?;
            Ok(Ok(format!(
                "Declined {kind} #{id}: {asker} is told your reason."
            )))
        }
        (_, _, Closing::Accept) => {
            back(ctx, &about, "accept", "Accepted.", via)?;
            ctx.db.execute(
                "UPDATE bot_messages SET state='accepted',deadline_ms=NULL WHERE id=?1",
                [id],
            )?;
            ctx.db.execute(
                "UPDATE bot_work SET owner=?2 WHERE id=?1",
                params![about.work, bot.id],
            )?;
            Ok(Ok(format!(
                "Accepted hand-off #{id}: the work is yours now. Do it, then report the result to {asker} with: {cmd} bot reply {id} \"RESULT\".{}",
                if from_person {
                    " It started with the person: say the result in your reply too."
                } else {
                    ""
                }
            )))
        }
    }
}

/// Ends an ask or a hand-off that got no answer: in time (`why` is `None`), or because it never reached the
/// other bot's agent. Both histories say so, the sender's agent is told, and a hand-off is flagged for the
/// main bot.
fn end_unanswered(ctx: &Ctx<'_>, about: &Message, why: Option<&str>) -> rusqlite::Result<()> {
    close_message(ctx, about.id, "expired")?;
    let (from, to) = (
        notes::line(&super::name_of(ctx.db, &about.sender)),
        notes::line(&super::name_of(ctx.db, &about.receiver)),
    );
    let kind = word(&about.kind);
    let limit = if about.kind == "ask" {
        ctx.set.ask_seconds
    } else {
        ctx.set.handoff_accept_seconds
    };
    let line = match (why, about.kind.as_str()) {
        (Some(why), _) => format!("{from}'s {kind} #{} did not reach {to}: {why}", about.id),
        (None, "ask") => format!(
            "{to} did not answer {from}'s ask #{} within {}. {from} was told.",
            about.id,
            notes::span(limit)
        ),
        (None, _) => format!(
            "{to} did not accept {from}'s hand-off #{} within {}. The work is still {from}'s, and {from} was told.",
            about.id,
            notes::span(limit)
        ),
    };
    for bot in [&about.sender, &about.receiver] {
        let about = About {
            code: Some("expired"),
            message: Some(about.id),
            ..About::default()
        };
        entry(ctx, bot, "notice", &line, about, false, false)?;
    }
    post(
        ctx,
        Post {
            bot: &about.sender,
            text: &notes::expired(&to, about.id, kind, limit, why),
            cause: "outcome",
            message: Some(about.id),
            work: Some(about.work),
            ..Post::default()
        },
    )?;
    if about.kind == "handoff" {
        plans::flag(
            ctx,
            "handoff",
            &format!("handoff:{}", about.id),
            &format!(
                "Nobody accepted the hand-off #{} from {from} to {to}: \"{}\". The work is still {from}'s.",
                about.id,
                plans::one_line(&about.text, 240)
            ),
        )?;
    }
    Ok(())
}

/// Ends every ask and hand-off whose time is up. Returns how many.
pub(crate) fn expire(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    let due: Vec<Message> = ctx
        .db
        .prepare_cached(&format!(
            "SELECT {MESSAGE} FROM bot_messages WHERE state='open' AND deadline_ms IS NOT NULL AND deadline_ms<=?1 ORDER BY id"
        ))?
        .query_map([ctx.now], read_message)?
        .collect::<Result<_, _>>()?;
    for message in &due {
        end_unanswered(ctx, message, None)?;
    }
    Ok(due.len())
}

/// Resolve the same durable outbox ID from its exact journal attempt. Only proof of
/// non-delivery allows a new attempt. A crash with no result is ambiguous.
pub(crate) fn reconcile_delivery(ctx: &Ctx<'_>, id: i64) -> rusqlite::Result<bool> {
    let result: Option<(Option<String>,i64)> = ctx.db.query_row(
        "SELECT j.state,o.give_up_ms FROM bot_outbox o LEFT JOIN journal j ON j.id=o.task
         WHERE o.id=? AND o.state='typing' AND o.cause IN ('message','outcome')",
        [id], |r| Ok((r.get(0)?,r.get(1)?))).optional()?;
    let Some((state, deadline)) = result else { return Ok(false); };
    match state.as_deref() {
        Some("not_sent") if ctx.now < deadline => {
            ctx.db.execute("UPDATE bot_outbox SET state='pending',task=NULL,delivery_receipt='unsent',retry_after_ms=? WHERE id=?",
                params![ctx.now+5_000,id])?;
            return Ok(true);
        }
        Some("not_sent") => {
            untyped(ctx,id,"its delivery deadline passed.")?;
        }
        Some("sent") => typed(ctx,id)?,
        _ => {
            ctx.db.execute("UPDATE bot_outbox SET delivery_receipt='uncertain',detail='Delivery unconfirmed; waiting for acknowledgement.' WHERE id=?",[id])?;
            ctx.db.execute("UPDATE bot_messages SET deadline_ms=coalesce(deadline_ms,?2)
                WHERE state='open' AND id=(SELECT message FROM bot_outbox WHERE id=?1 AND cause='message')",params![id,deadline])?;
        }
    }
    Ok(false)
}

/// The text of an outbox row went into the agent: an ask's or a hand-off's time starts now.
pub(crate) fn typed(ctx: &Ctx<'_>, outbox: i64) -> rusqlite::Result<()> {
    ctx.db.execute(
        "UPDATE bot_outbox SET state='typed',typed_ms=coalesce(typed_ms,?2),delivery_receipt=CASE WHEN cause IN ('message','outcome') THEN 'acknowledged' END WHERE id=?1",
        params![outbox, ctx.now],
    )?;
    ctx.db.execute(
        "UPDATE bot_messages SET delivered_ms=?2,
            deadline_ms=CASE WHEN state='open' AND kind='ask' THEN ?2+?3
                             WHEN state='open' AND kind='handoff' THEN ?2+?4 ELSE deadline_ms END
         WHERE id=(SELECT message FROM bot_outbox WHERE id=?1 AND cause='message') AND delivered_ms IS NULL",
        params![
            outbox,
            ctx.now,
            seconds(ctx.set.ask_seconds),
            seconds(ctx.set.handoff_accept_seconds)
        ],
    )?;
    Ok(())
}

/// The text of an outbox row could not be typed. An ask or a hand-off ends as not answered, and its sender is
/// told why; anything else leaves a line for the person, so nothing is lost without a word.
pub(crate) fn untyped(ctx: &Ctx<'_>, outbox: i64, why: &str) -> rusqlite::Result<()> {
    let row: Option<(String, String, Option<i64>, String)> = ctx
        .db
        .query_row(
            "UPDATE bot_outbox SET state='failed',detail=?2,delivery_receipt=CASE WHEN cause IN ('message','outcome') THEN CASE WHEN give_up_ms<=?3 THEN 'expired' ELSE 'unsent' END END WHERE id=?1 AND state IN ('pending','typing')
               AND NOT EXISTS (SELECT 1 FROM job_deliveries WHERE outbox=bot_outbox.id)
             RETURNING bot,cause,message,text",
            params![outbox, why, ctx.now],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )
        .optional()?;
    let Some((bot, cause, about, _)) = row else {
        return Ok(());
    };
    let name = notes::line(&super::name_of(ctx.db, &bot));
    match (
        cause.as_str(),
        about.map(|id| message(ctx.db, id)).transpose()?.flatten(),
    ) {
        ("message", Some(about)) if about.state == "open" => {
            end_unanswered(ctx, &about, Some(why))?;
        }
        ("message", Some(about)) => {
            let line = format!(
                "{}'s {} #{} did not reach {name}: {why}",
                notes::line(&super::name_of(ctx.db, &about.sender)),
                word(&about.kind),
                about.id
            );
            for bot in [&about.sender, &about.receiver] {
                let about = About {
                    code: Some("undelivered"),
                    message: Some(about.id),
                    ..About::default()
                };
                entry(ctx, bot, "notice", &line, about, true, true)?;
            }
        }
        ("outcome", about) => {
            let line = format!(
                "What came back for {name} could not be typed into its agent: {why} It is in this chat above."
            );
            let about = About {
                code: Some("undelivered"),
                message: about.map(|m| m.id),
                ..About::default()
            };
            entry(ctx, &bot, "notice", &line, about, true, true)?;
        }
        // A check-in, a promise that is due and a note have their own clocks, which notice the silence.
        _ => {}
    }
    Ok(())
}

/// Gives up what has waited too long to be typed.
pub(crate) fn give_up(ctx: &Ctx<'_>) -> rusqlite::Result<usize> {
    // Outcomes have no recipient acknowledgement command. Close an uncertain
    // attempt at its deadline without replaying it or claiming it was delivered.
    let uncertain = ctx.db.execute("UPDATE bot_outbox SET state='failed',detail='The delivery deadline passed without confirmation.'
        WHERE cause='outcome' AND state='typing' AND delivery_receipt='uncertain' AND give_up_ms<=?1
          AND NOT EXISTS(SELECT 1 FROM job_deliveries WHERE outbox=bot_outbox.id)", [ctx.now])?;
    let late: Vec<i64> = ctx
        .db
        .prepare_cached(
            "SELECT id FROM bot_outbox WHERE state='pending' AND give_up_ms<=?1
               AND NOT EXISTS (SELECT 1 FROM job_deliveries WHERE outbox=bot_outbox.id) ORDER BY id",
        )?
        .query_map([ctx.now], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    for id in &late {
        untyped(
            ctx,
            *id,
            &format!(
                "its agent could not be reached within {}.",
                notes::span(ctx.set.deliver_seconds)
            ),
        )?;
    }
    Ok(uncertain + late.len())
}

/// Takes `bot` out of every exchange it is part of: the person stopped it, turned its messages off, or removed
/// it. Each piece of work it has something open in is ended as a whole, what was waiting to be typed for it is
/// not typed, and every bot that waited for an answer is told. Returns how many asks and hand-offs ended.
pub(crate) fn stop(ctx: &Ctx<'_>, bot: &Bot, why: Why) -> rusqlite::Result<usize> {
    if matches!(why, Why::Person | Why::Removed) {
        ctx.db.execute(
            "UPDATE helper_followups SET cancelled=1 WHERE bot=?1 AND (outbox IS NULL OR outbox IN
             (SELECT id FROM bot_outbox WHERE bot=?1 AND state IN ('pending','typing')))",
            [&bot.id],
        )?;
        ctx.db.execute(
            "UPDATE bot_outbox SET state='dropped', detail='The bot was stopped.'
             WHERE state='pending' AND id IN (SELECT outbox FROM helper_followups WHERE bot=?1 AND cancelled=1)",
            [&bot.id],
        )?;
    }
    let works: Vec<i64> = ctx
        .db
        .prepare_cached(
            "SELECT DISTINCT m.work FROM bot_messages m JOIN bot_work w ON w.id=m.work
             WHERE w.state='open' AND (m.sender=?1 OR m.receiver=?1)
               AND (m.state IN ('open','accepted')
                    OR EXISTS (SELECT 1 FROM bot_outbox o
                               WHERE o.work=m.work AND o.bot=?1 AND o.cause='message' AND o.state='pending'))
             ORDER BY m.work",
        )?
        .query_map([&bot.id], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let name = notes::line(&bot.name);
    let ended_why = format!("{name} {}", why.clause());
    let mut ended = 0;
    for work in works {
        ctx.db.execute(
            "UPDATE bot_work SET state='stopped',ended_ms=?2,ended_why=?3 WHERE id=?1",
            params![work, ctx.now, ended_why],
        )?;
        ctx.db.execute(
            // A message that was not typed yet is not typed. An answer that was already given still arrives.
            "UPDATE bot_outbox SET state='dropped',detail=?2 WHERE work=?1 AND cause IN ('message','notice') AND state='pending'",
            params![work, ended_why],
        )?;
        let open: Vec<Message> = ctx
            .db
            .prepare_cached(&format!(
                "SELECT {MESSAGE} FROM bot_messages WHERE work=?1 AND state IN ('open','accepted') ORDER BY id"
            ))?
            .query_map([work], read_message)?
            .collect::<Result<_, _>>()?;
        for about in open {
            close_message(ctx, about.id, "stopped")?;
            ended += 1;
            let (from, to) = (
                notes::line(&super::name_of(ctx.db, &about.sender)),
                notes::line(&super::name_of(ctx.db, &about.receiver)),
            );
            let kind = word(&about.kind);
            let line = format!(
                "{ended_why}, so {from}'s {kind} #{} to {to} ended without an answer.",
                about.id
            );
            for party in [&about.sender, &about.receiver] {
                let about = About {
                    code: Some("stopped"),
                    message: Some(about.id),
                    ..About::default()
                };
                entry(ctx, party, "notice", &line, about, false, false)?;
            }
            // The bot that waited for the answer must act on this: its agent is told. Nobody else's is.
            if about.sender != bot.id {
                post(
                    ctx,
                    Post {
                        bot: &about.sender,
                        text: &notes::stopped(&name, about.id, kind, why.clause()),
                        cause: "outcome",
                        message: Some(about.id),
                        work: Some(work),
                        ..Post::default()
                    },
                )?;
            }
        }
    }
    Ok(ended)
}

/// The person stopped the agent of this launch: whatever was typed into it so far got its answer or never will,
/// so a later reply is not read as an answer to it.
pub(crate) fn floor(ctx: &Ctx<'_>, key: &str) -> rusqlite::Result<()> {
    ctx.db.execute(
        "INSERT INTO bot_state (key,value) SELECT 'floor:'||?1, coalesce(max(id),0) FROM journal WHERE true
         ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [key],
    )?;
    Ok(())
}

/// What the workspace typed as the task with this journal row.
struct Typed {
    outbox: i64,
    cause: String,
    message: Option<i64>,
    checkin: Option<i64>,
    promise: Option<i64>,
    quiet: bool,
}

/// A reply the agent of `bot` saved (journal row `reply`, for the launch `key`). This is where a turn the
/// workspace started ends:
/// - blocks in the reply that address another bot are passed on as messages;
/// - a turn that another bot's ask or hand-off started and that ended with it still open gets one reminder;
/// - a recurring check-in that reports nothing leaves nothing;
/// - anything else the bot wrote after something the workspace typed is put into its history as what it said.
///   The row carries the reply's journal id, so an app that followed the same turn shows it once.
pub(crate) fn on_reply(
    ctx: &Ctx<'_>,
    bot: &Bot,
    key: &str,
    reply: i64,
    text: &str,
) -> rusqlite::Result<()> {
    let db = ctx.db;
    // The turn that ends with this reply began after the reply before it, or after the person's last Stop.
    let previous: i64 = db.query_row(
        "SELECT max(coalesce((SELECT max(id) FROM journal WHERE reply_for=?1 AND kind='reply' AND id<?2
                                AND answers_task IS NULL),0),
                    coalesce((SELECT CAST(value AS INTEGER) FROM bot_state WHERE key='floor:'||?1),0))",
        params![key, reply],
        |row| row.get(0),
    )?;
    let tasks: Vec<i64> = db
        .prepare_cached(
            "SELECT t.id FROM journal l JOIN journal t
               ON t.id=l.id OR (t.core_id=l.core_id AND t.address=l.address AND t.created_ms=l.created_ms)
             WHERE l.launch_key=?1 AND t.kind='task' AND t.state!='not_sent' AND t.text!=''
               AND t.id>?2 AND t.id<?3 ORDER BY t.id",
        )?
        .query_map(params![key, previous, reply], |row| row.get(0))?
        .collect::<Result<_, _>>()?;
    let mut typed = Vec::new();
    for task in &tasks {
        let found = db
            .query_row(
                "SELECT id,cause,message,checkin,promise,quiet FROM bot_outbox WHERE task=?1",
                [task],
                |row| {
                    Ok(Typed {
                        outbox: row.get(0)?,
                        cause: row.get(1)?,
                        message: row.get(2)?,
                        checkin: row.get(3)?,
                        promise: row.get(4)?,
                        quiet: row.get(5)?,
                    })
                },
            )
            .optional()?;
        typed.extend(found);
    }
    // `ours`: the newest thing typed before this reply came from the workspace, so the reply is the bot speaking
    // by itself. `only_ours`: nothing the person wrote is part of the turn at all.
    let ours = tasks.last().is_some_and(|task| {
        db.query_row(
            "SELECT EXISTS(SELECT 1 FROM bot_outbox WHERE task=?1)",
            [task],
            |row| row.get(0),
        )
        .unwrap_or(false)
    });
    let only_ours = ours && typed.len() == tasks.len();
    let newest = typed.last();
    let visible = blocks::visible(text);

    let read_only: bool = db.query_row(
        "SELECT document_read_only FROM journal WHERE launch_key=?1", [key], |r| r.get(0),
    )?;
    let commands = if read_only { Vec::new() } else { blocks::blocks(text) };
    for block in commands {
        let (to, sent) = match block {
            blocks::Block::Message { to, kind, text } => {
                let kind = Kind::parse(&kind).unwrap_or(Kind::Ask);
                let sent = send(ctx, bot, tasks.last().copied(), kind, &to, &text, "block")?;
                (to, sent)
            }
            blocks::Block::Request { name, purpose } => {
                let main = super::main_bot(db)?.filter(|main| main.id != bot.id);
                let sent = match main {
                    Some(main) => {
                        let ask = format!(
                            "{} asks for a new bot named \"{name}\". Purpose: {}\nYou decide: answer with a create_bot block for \"{name}\", or say why not.",
                            notes::line(&bot.name),
                            if purpose.is_empty() { "(none given)" } else { &purpose }
                        );
                        send(ctx, bot, tasks.last().copied(), Kind::Ask, &main.name, &ask, "block")?
                    }
                    None => Err("This server has no main bot that could create it. Tell the person: they can make one bot the main bot in its settings.".into()),
                };
                (name, sent)
            }
        };
        if let Err(why) = sent {
            let line = format!(
                "{}'s message to {} was not sent. {why}",
                notes::line(&bot.name),
                notes::line(&to)
            );
            let about = About {
                code: Some("not_sent"),
                ..About::default()
            };
            entry(ctx, &bot.id, "notice", &line, about, false, false)?;
            // Told once. A bot that answers that with another message that cannot be sent is not told again.
            if newest.is_none_or(|typed| typed.cause != "notice") {
                post(
                    ctx,
                    Post {
                        bot: &bot.id,
                        text: &notes::not_sent(&to, &why),
                        cause: "notice",
                        ..Post::default()
                    },
                )?;
            }
        }
    }

    // A turn that was started by another bot's ask or hand-off and ended with it still open, without a word to
    // any bot: the bot is reminded, once, that its words in its own chat do not reach the bot that asked. They are
    // never taken for the answer: "I will look into it" is not one.
    let asked: Vec<i64> = typed
        .iter()
        .filter(|typed| typed.cause == "message")
        .filter_map(|typed| typed.message)
        .collect();
    for id in asked.into_iter().filter(|_| only_ours) {
        let Some(about) = message(db, id)?.filter(|about| {
            about.state == "open" && about.receiver == bot.id && about.kind != "tell"
        }) else {
            continue;
        };
        if read_only {
            // Only an explicit answer to this single incoming request can leave the
            // chat. Never forward prose from an unrelated or mixed turn.
            if typed.len() == 1 && about.kind == "ask" {
                let requester = super::name_of(db, &about.sender);
                for block in blocks::blocks(text) {
                    if let blocks::Block::Message { to, kind, text } = block
                        && kind == "tell" && to.eq_ignore_ascii_case(&requester) {
                        let _ = close(ctx, bot, id, Closing::Reply(&text), "block")?;
                        break;
                    }
                }
            }
            continue;
        }
        let wrote: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM bot_messages WHERE sender=?1 AND id>?2)",
            params![bot.id, id],
            |row| row.get(0),
        )?;
        let reminded: bool = db.query_row(
            "SELECT EXISTS(SELECT 1 FROM bot_outbox WHERE bot=?1 AND cause='notice' AND message=?2)",
            params![bot.id, id],
            |row| row.get(0),
        )?;
        if wrote || reminded {
            continue;
        }
        let left = about
            .deadline_ms
            .map(|until| u64::try_from((until - ctx.now).max(0) / 1_000).unwrap_or(0));
        post(
            ctx,
            Post {
                bot: &bot.id,
                text: &notes::reminder(
                    ctx.cmd,
                    &super::name_of(db, &about.sender),
                    id,
                    word(&about.kind),
                    left,
                ),
                cause: "notice",
                message: Some(id),
                work: Some(about.work),
                ..Post::default()
            },
        )?;
    }
    for typed in &typed {
        db.execute(
            "UPDATE bot_outbox SET outcome=coalesce(outcome,'replied') WHERE id=?1",
            [typed.outbox],
        )?;
    }
    let mut quiet = false;
    if let Some(checkin) = typed.iter().rev().find_map(|typed| typed.checkin) {
        quiet = only_ours && newest.is_some_and(|typed| typed.quiet) && notes::is_quiet(&visible);
        db.execute(
            "UPDATE bot_checkins SET last_outcome=?2 WHERE id=?1",
            params![checkin, if quiet { "quiet" } else { "reported" }],
        )?;
    }
    if !ours || quiet || visible.is_empty() && blocks::blocks(text).is_empty() {
        return Ok(());
    }
    let newest = newest.expect("a turn of ours has a typed task");
    let about = newest
        .message
        .map(|id| message(db, id))
        .transpose()?
        .flatten();
    // A check-in that fired into this turn is what the reply is the outcome of, whatever else was typed after it.
    let checkin = typed.iter().rev().find_map(|typed| typed.checkin);
    let code = match (newest.cause.as_str(), &about) {
        _ if checkin.is_some() => "checkin".to_owned(),
        ("message", Some(about)) => about.kind.clone(),
        (cause, _) => cause.to_owned(),
    };
    // What a bot says after a plain ask or tell is in its chat without an alert; the rest is news for the person.
    let notify = !matches!(code.as_str(), "ask" | "tell" | "notice");
    entry(
        ctx,
        &bot.id,
        "said",
        text,
        About {
            code: Some(&code),
            message: newest.message,
            journal: Some(reply),
            checkin,
            promise: newest.promise,
        },
        true,
        notify,
    )?;
    Ok(())
}

// ---- For the app and for `bot list`.

#[derive(Serialize)]
pub(crate) struct Party {
    id: String,
    name: String,
}

#[derive(Serialize)]
pub(crate) struct MessageView {
    id: i64,
    work: i64,
    kind: String,
    from: Party,
    to: Party,
    text: String,
    about: Option<i64>,
    state: String,
    via: String,
    sent_ms: i64,
    delivered_ms: Option<i64>,
    deadline_ms: Option<i64>,
    ended_ms: Option<i64>,
}

fn view(db: &Connection, message: Message) -> MessageView {
    MessageView {
        from: Party {
            name: super::name_of(db, &message.sender),
            id: message.sender,
        },
        to: Party {
            name: super::name_of(db, &message.receiver),
            id: message.receiver,
        },
        id: message.id,
        work: message.work,
        kind: message.kind,
        text: message.text,
        about: message.about,
        state: message.state,
        via: message.via,
        sent_ms: message.sent_ms,
        delivered_ms: message.delivered_ms,
        deadline_ms: message.deadline_ms,
        ended_ms: message.ended_ms,
    }
}

/// One line of a bot's history.
#[derive(Serialize)]
pub(crate) struct Entry {
    pub id: i64,
    pub bot: String,
    pub kind: String,
    pub text: String,
    pub at_ms: i64,
    pub unread: bool,
    pub notify: bool,
    pub code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub journal: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub checkin: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub promise: Option<i64>,
    /// For a message between bots: `out` in the history of the bot that wrote it, `in` in the other's.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub direction: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<MessageView>,
}

/// Which lines of the histories to read.
#[derive(Default)]
pub(crate) struct Lines<'a> {
    pub bot: Option<&'a str>,
    pub kind: Option<&'a str>,
    /// Lines after this id, oldest first. Without it: the newest lines.
    pub after: Option<i64>,
    pub before: Option<i64>,
    pub limit: usize,
}

/// History lines, oldest first: with `after` the first `limit` after it, otherwise the last `limit` (before
/// `before`, when that is given).
pub(crate) fn entries(db: &Connection, lines: &Lines<'_>) -> rusqlite::Result<Vec<Entry>> {
    let newest_first = lines.after.is_none() || lines.before.is_some();
    let mut rows: Vec<Entry> = db
        .prepare_cached(&format!(
            "SELECT id,bot,kind,text,at_ms,unread,notify,code,journal,checkin,promise,message FROM bot_history
             WHERE id>?1 AND id<?2 AND (?3 IS NULL OR bot=?3) AND (?4 IS NULL OR kind=?4)
             ORDER BY id {} LIMIT ?5",
            if newest_first { "DESC" } else { "ASC" }
        ))?
        .query_map(
            params![
                lines.after.unwrap_or(0),
                lines.before.unwrap_or(i64::MAX),
                lines.bot,
                lines.kind,
                lines.limit.clamp(1, 500) as i64
            ],
            |row| {
                Ok((
                    Entry {
                        id: row.get(0)?,
                        bot: row.get(1)?,
                        kind: row.get(2)?,
                        text: row.get(3)?,
                        at_ms: row.get(4)?,
                        unread: row.get(5)?,
                        notify: row.get(6)?,
                        code: row.get(7)?,
                        journal: row.get(8)?,
                        checkin: row.get(9)?,
                        promise: row.get(10)?,
                        direction: None,
                        message: None,
                    },
                    row.get::<_, Option<i64>>(11)?,
                ))
            },
        )?
        .collect::<Result<Vec<_>, _>>()?
        .into_iter()
        .map(|(mut entry, about)| {
            if let Some(about) = about.and_then(|id| message(db, id).ok().flatten()) {
                if entry.kind == "message" {
                    entry.direction = Some(if about.sender == entry.bot { "out" } else { "in" });
                }
                entry.message = Some(view(db, about));
            }
            entry
        })
        .collect();
    if newest_first {
        rows.reverse();
    }
    Ok(rows)
}

/// The asks, tells and hand-offs a bot sent or was sent, newest first; with `open`, only those not yet ended.
pub(crate) fn exchanges(
    db: &Connection,
    bot: &str,
    open: bool,
) -> rusqlite::Result<Vec<MessageView>> {
    let found: Vec<Message> = db
        .prepare_cached(&format!(
            "SELECT {MESSAGE} FROM bot_messages WHERE (sender=?1 OR receiver=?1) AND kind IN ('ask','tell','handoff')
               AND (?2=0 OR state IN ('open','accepted')) ORDER BY id DESC LIMIT 100"
        ))?
        .query_map(params![bot, open], read_message)?
        .collect::<Result<_, _>>()?;
    Ok(found.into_iter().map(|message| view(db, message)).collect())
}

/// `bot list` for an agent: who it can write to and what is open.
pub(crate) fn list_text(ctx: &Ctx<'_>, bot: &Bot) -> rusqlite::Result<String> {
    let cmd = ctx.cmd;
    let others: Vec<Bot> = super::all(ctx.db)?
        .into_iter()
        .filter(|other| other.id != bot.id)
        .collect();
    let mut text = if !bot.may_message {
        "The person turned off messages to other bots for you. Ask the person instead.".to_owned()
    } else if others.is_empty() {
        "There is no other bot on this server.".to_owned()
    } else {
        let mut text = "Bots on this server:".to_owned();
        for other in &others {
            text.push_str(&format!(
                "\n  \"{}\"{}{}",
                notes::line(&other.name),
                if other.main { " (the main bot)" } else { "" },
                if other.takes_messages {
                    ""
                } else {
                    " (takes no messages from bots)"
                }
            ));
        }
        text.push_str(&format!(
            "\nWrite to one: {cmd} bot ask|tell|handoff NAME \"TEXT\""
        ));
        text
    };
    let minutes = |until: Option<i64>| {
        until.map_or_else(String::new, |until| {
            format!(
                ", {} left",
                notes::span(u64::try_from((until - ctx.now).max(0) / 1_000).unwrap_or(0))
            )
        })
    };
    for about in exchanges(ctx.db, &bot.id, true)?.into_iter().rev() {
        let kind = word(&about.kind).to_owned();
        let line = if about.to.id == bot.id {
            match (about.kind.as_str(), about.state.as_str()) {
                ("ask", _) => format!(
                    "Waiting for you: ask #{} from {}{}. Answer: {cmd} bot reply {} \"TEXT\"",
                    about.id,
                    about.from.name,
                    minutes(about.deadline_ms),
                    about.id
                ),
                (_, "accepted") => format!(
                    "Yours: the work of hand-off #{} from {}. Report its result: {cmd} bot reply {} \"RESULT\"",
                    about.id, about.from.name, about.id
                ),
                _ => format!(
                    "Waiting for you: hand-off #{} from {}{}. {cmd} bot accept {} or {cmd} bot decline {} \"WHY\"",
                    about.id,
                    about.from.name,
                    minutes(about.deadline_ms),
                    about.id,
                    about.id
                ),
            }
        } else {
            format!(
                "You wait for {}: {kind} #{} ({}{})",
                about.to.name,
                about.id,
                about.state,
                minutes(about.deadline_ms)
            )
        };
        text.push('\n');
        text.push_str(&line);
        text.push_str(&format!(" — \"{}\"", plans::one_line(&about.text, 100)));
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::{Settings, testing};
    use crate::history::History;

    const T0: i64 = 1_000_000;

    fn count(history: &History, sql: &str) -> i64 {
        history
            .db()
            .unwrap()
            .query_row(sql, [], |row| row.get(0))
            .unwrap()
    }

    /// Everything waiting to be typed, as (bot id, cause, text), and marks it typed at `now`.
    fn deliver(history: &History, now: i64, set: &Settings) -> Vec<(String, String, String)> {
        let pending: Vec<(i64, String, String, String)> = history
            .db()
            .unwrap()
            .prepare("SELECT id,bot,cause,text FROM bot_outbox WHERE state='pending' ORDER BY id")
            .unwrap()
            .query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .unwrap()
            .collect::<Result<_, _>>()
            .unwrap();
        testing::at(history, now, set, |ctx| {
            for (id, ..) in &pending {
                typed(ctx, *id)?;
            }
            Ok(())
        });
        pending
            .into_iter()
            .map(|(_, bot, cause, text)| (bot, cause, text))
            .collect()
    }

    fn lines(history: &History, bot: &str) -> Vec<(String, Option<String>, String)> {
        entries(
            &history.db().unwrap(),
            &Lines {
                bot: Some(&testing::id_of(bot)),
                after: Some(0),
                limit: 500,
                ..Lines::default()
            },
        )
        .unwrap()
        .into_iter()
        .map(|entry| (entry.kind, entry.code, entry.text))
        .collect()
    }

    fn state(history: &History, id: i64) -> String {
        message(&history.db().unwrap(), id).unwrap().unwrap().state
    }

    fn sent(
        history: &History,
        now: i64,
        set: &Settings,
        from: &str,
        kind: Kind,
        to: &str,
        text: &str,
    ) -> Result<i64, String> {
        let sender = testing::bot(history, from);
        testing::at(history, now, set, |ctx| {
            send(ctx, &sender, None, kind, to, text, "command")
        })
        .map(|sent| sent.id)
    }

    fn closed(
        history: &History,
        now: i64,
        set: &Settings,
        by: &str,
        id: i64,
        closing: Closing<'_>,
    ) -> Result<String, String> {
        let bot = testing::bot(history, by);
        testing::at(history, now, set, |ctx| {
            close(ctx, &bot, id, closing, "command")
        })
    }

    #[test]
    fn a_response_at_the_deadline_expires_once_even_before_the_clock_ticks() {
        let set = Settings::default();
        for (kind, seconds_to_close, closing) in [
            (Kind::Ask, set.ask_seconds, Closing::Reply("answer")),
            (Kind::Ask, set.ask_seconds, Closing::Decline("reason")),
            (Kind::Handoff, set.handoff_accept_seconds, Closing::Accept),
            (Kind::Handoff, set.handoff_accept_seconds, Closing::Decline("reason")),
            (Kind::Handoff, set.handoff_accept_seconds, Closing::Reply("result")),
        ] {
            let (_dir, history) = testing::journal(&["Jarvis", "Infra"]);
            let id = sent(&history, T0, &set, "Jarvis", kind, "Infra", "fixture").unwrap();
            let delivered = T0 + 1_000;
            deliver(&history, delivered, &set);
            let deadline = delivered + seconds(seconds_to_close);
            assert!(closed(&history, deadline, &set, "Infra", id, closing).is_err());
            assert!(closed(&history, deadline + 1, &set, "Infra", id, Closing::Reply("retry")).is_err());
            assert_eq!(testing::at(&history, deadline + 1, &set, expire), 0);
            assert_eq!(state(&history, id), "expired");
            assert_eq!(count(&history, "SELECT count(*) FROM bot_messages WHERE about IS NOT NULL"), 0);
            assert_eq!(count(&history, "SELECT count(*) FROM bot_work WHERE owner='jarvis-id'"), 1);
            assert_eq!(count(&history, "SELECT count(*) FROM bot_outbox WHERE cause='outcome'"), 1);
            assert_eq!(
                count(&history, "SELECT typed_ms FROM bot_outbox WHERE delivery_receipt='acknowledged'"),
                delivered
            );
        }
    }

    #[test]
    fn a_late_response_to_a_pending_delivery_settles_the_outbox_once() {
        let (_dir, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let id = sent(&history, T0, &set, "Jarvis", Kind::Ask, "Infra", "fixture").unwrap();
        let deadline = T0 + seconds(set.deliver_seconds);
        for now in [deadline, deadline + 1] {
            assert!(closed(&history, now, &set, "Infra", id, Closing::Reply("late")).is_err());
        }
        assert_eq!(testing::at(&history, deadline + 1, &set, give_up), 0);
        assert_eq!(state(&history, id), "expired");
        assert_eq!(
            count(&history, "SELECT count(*) FROM bot_outbox WHERE state='failed'
                             AND delivery_receipt='expired' AND typed_ms IS NULL"),
            1
        );
        assert_eq!(count(&history, "SELECT count(*) FROM bot_history WHERE kind='notice'"), 2);
        assert_eq!(count(&history, "SELECT count(*) FROM bot_outbox WHERE cause='outcome'"), 1);
    }

    #[test]
    fn a_restart_preserves_the_cutoff_for_older_unconfirmed_deliveries() {
        let (_dir, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let handoff = sent(&history, T0, &set, "Jarvis", Kind::Handoff, "Infra", "first").unwrap();
        let ask = sent(&history, T0, &set, "Jarvis", Kind::Ask, "Infra", "second").unwrap();
        let deadline = T0 + seconds(set.deliver_seconds);
        history.db().unwrap().execute(
            "UPDATE bot_outbox SET state='typed', typed_ms=?1, delivery_receipt='uncertain'",
            [T0 + 1],
        ).unwrap();
        crate::bots::desk::recover_outbox(&history);
        closed(&history, deadline - 1, &set, "Infra", handoff, Closing::Accept).unwrap();
        assert!(closed(&history, deadline, &set, "Infra", handoff, Closing::Accept).is_err());
        assert!(closed(&history, deadline, &set, "Infra", ask, Closing::Reply("late")).is_err());
        closed(&history, deadline + 1, &set, "Infra", handoff, Closing::Reply("done")).unwrap();
        assert_eq!(state(&history, handoff), "answered");
        assert_eq!(state(&history, ask), "expired");
        for (id, receipt) in [(handoff, "acknowledged"), (ask, "uncertain")] {
            let saved: String = history.db().unwrap().query_row(
                "SELECT delivery_receipt FROM bot_outbox WHERE cause='message' AND message=?",
                [id], |row| row.get(0),
            ).unwrap();
            assert_eq!(saved, receipt);
        }
    }

    #[test]
    fn uncertain_outcome_closes_at_its_cutoff_without_resending() {
        let (_dir, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let ask = sent(&history, T0, &set, "Jarvis", Kind::Ask, "Infra", "fixture").unwrap();
        closed(&history, T0 + 1, &set, "Infra", ask, Closing::Reply("answer")).unwrap();
        let deadline = T0 + 100;
        let id: i64 = history.db().unwrap().query_row("UPDATE bot_outbox SET state='typing',give_up_ms=?1
            WHERE cause='outcome' RETURNING id", [deadline], |r| r.get(0)).unwrap();
        testing::at(&history, deadline - 1, &set, |ctx| reconcile_delivery(ctx, id));
        testing::at(&history, deadline - 1, &set, give_up);
        assert_eq!(count(&history, "SELECT count(*) FROM bot_outbox WHERE cause='outcome' AND state='typing'"), 1);
        testing::at(&history, deadline, &set, give_up);
        assert_eq!(count(&history, "SELECT count(*) FROM bot_outbox WHERE cause='outcome' AND state='failed' AND delivery_receipt='uncertain'"), 1);
    }

    #[test]
    fn delayed_ack_settles_an_uncertain_attempt_once() {
        let (_dir, history) = testing::journal(&["Jarvis","Infra"]);
        let set = Settings::default();
        let ask = sent(&history,T0,&set,"Jarvis",Kind::Ask,"Infra","fixture").unwrap();
        let outbox: i64 = history.db().unwrap().query_row("SELECT id FROM bot_outbox WHERE message=?",[ask],|r|r.get(0)).unwrap();
        history.db().unwrap().execute("UPDATE bot_outbox SET state='typing' WHERE id=?",[outbox]).unwrap();
        testing::at(&history,T0+1,&set,|ctx| reconcile_delivery(ctx,outbox));
        assert!(deliver(&history,T0+2,&set).is_empty());
        closed(&history,T0+3,&set,"Infra",ask,Closing::Reply("fixture ack")).unwrap();
        assert!(closed(&history,T0+4,&set,"Infra",ask,Closing::Reply("late duplicate")).is_err());
        assert_eq!(history.db().unwrap().query_row("SELECT delivery_receipt FROM bot_outbox WHERE id=?",[outbox],|r|r.get::<_,String>(0)).unwrap(),"acknowledged");
    }

    #[test]
    fn a_proven_unsent_attempt_keeps_its_identity_when_the_recipient_returns() {
        let (_root, history) = testing::journal(&["Jarvis", "Infra"]);
        let settings = Settings::default();
        let ask = sent(&history, T0, &settings, "Jarvis", Kind::Ask, "Infra", "fixture").unwrap();
        let outbox: i64 = history.db().unwrap().query_row(
            "SELECT id FROM bot_outbox WHERE message=?", [ask], |row| row.get(0)).unwrap();
        let task = history.db().unwrap().query_row(
            "INSERT INTO journal(core_id,agent,kind,state,text,at_ms)
             VALUES('fixture','fixture','task','not_sent','fixture',?) RETURNING id",
            [T0], |row| row.get::<_,i64>(0)).unwrap();
        history.db().unwrap().execute("UPDATE bot_outbox SET state='typing',task=? WHERE id=?",
            params![task,outbox]).unwrap();
        assert!(testing::at(&history, T0 + 1, &settings, |ctx| reconcile_delivery(ctx, outbox)));
        assert_eq!(count(&history, "SELECT retry_after_ms FROM bot_outbox
            WHERE state='pending' AND task IS NULL AND delivery_receipt='unsent'"), T0 + 5_001);
        let retry_at = T0 + 6_000;
        testing::at(&history, retry_at, &settings, |ctx| {
            let retry: i64 = ctx.db.query_row(
                "INSERT INTO journal(core_id,agent,kind,state,text,at_ms)
                 VALUES('fixture','fixture','task','sent','retry',?) RETURNING id",
                [retry_at], |row| row.get(0),
            )?;
            ctx.db.execute("UPDATE bot_outbox SET state='typing', task=?2 WHERE id=?1",
                params![outbox, retry])?;
            reconcile_delivery(ctx, outbox)
        });
        assert!(!testing::at(&history, retry_at + 1, &settings, |ctx| reconcile_delivery(ctx, outbox)));
        let asked = message(&history.db().unwrap(), ask).unwrap().unwrap();
        assert_eq!(asked.delivered_ms, Some(retry_at));
        assert_eq!(asked.deadline_ms, Some(retry_at + seconds(settings.ask_seconds)));
        assert_eq!(count(&history, "SELECT id FROM bot_outbox WHERE state='typed' AND delivery_receipt='acknowledged'"), outbox);
        assert!(deliver(&history, retry_at + 1, &settings).is_empty());
    }

    #[test]
    fn offline_recipient_expires_without_delivery() {
        let (_dir, history) = testing::journal(&["Jarvis","Infra"]);
        let set = Settings::default();
        let ask = sent(&history,T0,&set,"Jarvis",Kind::Ask,"Infra","fixture").unwrap();
        let deadline = T0+seconds(set.deliver_seconds);
        testing::at(&history,deadline,&set,give_up);
        assert_eq!(state(&history,ask),"expired");
        assert_eq!(history.db().unwrap().query_row("SELECT delivery_receipt FROM bot_outbox WHERE cause='message' AND message=?",[ask],|r|r.get::<_,String>(0)).unwrap(),"expired");
    }

    #[test]
    fn an_ask_is_shown_in_both_histories_typed_for_the_other_bot_and_its_answer_comes_back() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let ask = sent(
            &history,
            T0,
            &set,
            "Jarvis",
            Kind::Ask,
            "infra",
            "Which port?",
        )
        .unwrap();
        assert_eq!(state(&history, ask), "open");
        // Asynchronous: the sender got its answer at once, and the ask waits to be typed for Infra's agent.
        let typed = deliver(&history, T0 + 5_000, &set);
        assert_eq!(typed.len(), 1);
        assert_eq!(
            (typed[0].0.as_str(), typed[0].1.as_str()),
            ("infra-id", "message")
        );
        assert!(typed[0].2.starts_with(
            "[Message from the bot Jarvis, passed on by SwarmHub] ask #1\nWhich port?"
        ));
        // The time to answer counts from when it was typed.
        let asked = message(&history.db().unwrap(), ask).unwrap().unwrap();
        assert_eq!(asked.deadline_ms, Some(T0 + 5_000 + 600_000));
        for bot in ["Jarvis", "Infra"] {
            assert_eq!(
                lines(&history, bot),
                [("message".into(), Some("ask".into()), "Which port?".into())]
            );
        }

        let said = closed(
            &history,
            T0 + 9_000,
            &set,
            "Infra",
            ask,
            Closing::Reply("5432"),
        )
        .unwrap();
        assert!(said.contains("Jarvis gets it as its next message"));
        assert_eq!(state(&history, ask), "answered");
        let typed = deliver(&history, T0 + 9_500, &set);
        assert_eq!(
            (typed[0].0.as_str(), typed[0].1.as_str()),
            ("jarvis-id", "outcome")
        );
        assert!(typed[0].2.starts_with(
            "[Answer from the bot Infra, passed on by SwarmHub] to your ask #1\n5432"
        ));
        for bot in ["Jarvis", "Infra"] {
            let shown = lines(&history, bot);
            assert_eq!(shown.len(), 2, "{bot}");
            assert_eq!(
                shown[1],
                ("message".into(), Some("reply".into()), "5432".into())
            );
        }
        // Who sent what is part of every line.
        let db = history.db().unwrap();
        let seen = entries(
            &db,
            &Lines {
                bot: Some("jarvis-id"),
                after: Some(0),
                limit: 10,
                ..Lines::default()
            },
        )
        .unwrap();
        assert_eq!(seen[0].direction, Some("out"));
        assert_eq!(seen[1].direction, Some("in"));
        let reply = serde_json::to_value(&seen[1]).unwrap();
        assert_eq!(reply["message"]["from"]["name"], "Infra");
        assert_eq!(reply["message"]["to"]["name"], "Jarvis");
        assert_eq!(reply["message"]["about"], ask);
        drop(db);
        // Answered is an ending: it cannot be answered or declined again, and it does not lapse.
        assert!(
            closed(
                &history,
                T0 + 10_000,
                &set,
                "Infra",
                ask,
                Closing::Reply("again")
            )
            .unwrap_err()
            .contains("already answered")
        );
        assert_eq!(testing::at(&history, T0 + 9_000_000, &set, expire), 0);
        // Only the bot that was asked can answer, and an ask is not accepted.
        assert!(
            closed(&history, T0, &set, "Jarvis", ask, Closing::Reply("me"))
                .unwrap_err()
                .contains("No ask or hand-off #1 was sent to you")
        );
        let other = sent(
            &history,
            T0 + 20_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "And the host?",
        )
        .unwrap();
        assert!(
            closed(&history, T0 + 21_000, &set, "Infra", other, Closing::Accept)
                .unwrap_err()
                .contains("needs an answer")
        );
    }

    #[test]
    fn a_tell_expects_no_answer_and_cannot_be_answered() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let tell = sent(
            &history,
            T0,
            &set,
            "Jarvis",
            Kind::Tell,
            "Infra",
            "Standup moved to 10:30.",
        )
        .unwrap();
        assert_eq!(state(&history, tell), "sent");
        let typed = deliver(&history, T0 + 1_000, &set);
        assert!(typed[0].2.contains("tell #1") && typed[0].2.contains("expects no answer"));
        assert!(
            message(&history.db().unwrap(), tell)
                .unwrap()
                .unwrap()
                .deadline_ms
                .is_none()
        );
        assert!(
            closed(
                &history,
                T0 + 2_000,
                &set,
                "Infra",
                tell,
                Closing::Reply("ok")
            )
            .is_err()
        );
        assert_eq!(testing::at(&history, T0 + 9_000_000, &set, expire), 0);
        assert_eq!(state(&history, tell), "sent");
        assert_eq!(count(&history, "SELECT count(*) FROM bot_outbox"), 1);
    }

    #[test]
    fn an_ask_ends_declined_or_unanswered_and_the_sender_is_told_which() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let first = sent(
            &history,
            T0,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Deploy it?",
        )
        .unwrap();
        deliver(&history, T0, &set);
        assert!(
            closed(
                &history,
                T0 + 1_000,
                &set,
                "Infra",
                first,
                Closing::Decline(" ")
            )
            .unwrap_err()
            .contains("Say why")
        );
        closed(
            &history,
            T0 + 1_000,
            &set,
            "Infra",
            first,
            Closing::Decline("Not my area."),
        )
        .unwrap();
        assert_eq!(state(&history, first), "declined");
        let typed = deliver(&history, T0 + 1_000, &set);
        assert!(
            typed[0].0 == "jarvis-id"
                && typed[0]
                    .2
                    .contains("Infra declined your ask #1. Its reason: Not my area.")
        );
        assert!(typed[0].2.contains("Bring it to the person"));

        // Not answered in time: ten minutes after it was typed, not after it was sent.
        let second = sent(
            &history,
            T0 + 2_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Still there?",
        )
        .unwrap();
        assert_eq!(
            testing::at(&history, T0 + 9_000_000, &set, expire),
            0,
            "not typed yet: no clock runs"
        );
        deliver(&history, T0 + 60_000, &set);
        assert_eq!(
            testing::at(&history, T0 + 60_000 + 599_000, &set, expire),
            0
        );
        assert_eq!(
            testing::at(&history, T0 + 60_000 + 600_000, &set, expire),
            1
        );
        assert_eq!(state(&history, second), "expired");
        let typed = deliver(&history, T0 + 700_000, &set);
        assert_eq!(typed.len(), 1);
        assert!(
            typed[0].0 == "jarvis-id"
                && typed[0]
                    .2
                    .contains("did not answer your ask #3 within 10 minutes")
        );
        for bot in ["Jarvis", "Infra"] {
            let last = lines(&history, bot).pop().unwrap();
            assert_eq!(last.1.as_deref(), Some("expired"), "{bot}");
            assert!(
                last.2
                    .contains("did not answer Jarvis's ask #3 within 10 minutes")
            );
        }
        // Too late: the answer is refused with what happened, and the ask stays ended.
        let late = closed(
            &history,
            T0 + 760_000,
            &set,
            "Infra",
            second,
            Closing::Reply("Yes"),
        )
        .unwrap_err();
        assert!(
            late.contains("ended 1 minute ago because it was not answered in time")
                && late.contains("bot tell \"Jarvis\"")
        );
        assert_eq!(
            testing::at(&history, T0 + 9_000_000, &set, expire),
            0,
            "an ending happens once"
        );
        // The limit is a setting.
        let short = Settings {
            ask_seconds: 30,
            ..Settings::default()
        };
        let third = sent(
            &history,
            T0 + 800_000,
            &short,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Quick?",
        )
        .unwrap();
        deliver(&history, T0 + 800_000, &short);
        assert_eq!(testing::at(&history, T0 + 830_000, &short, expire), 1);
        assert_eq!(state(&history, third), "expired");
    }

    #[test]
    fn a_hand_off_moves_the_work_when_it_is_accepted_and_ends_reported_declined_or_unaccepted() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra", "Shop"]);
        let set = Settings::default();
        let owner = |work: i64| -> String {
            history
                .db()
                .unwrap()
                .query_row("SELECT owner FROM bot_work WHERE id=?1", [work], |row| {
                    row.get(0)
                })
                .unwrap()
        };
        let handoff = sent(
            &history,
            T0,
            &set,
            "Jarvis",
            Kind::Handoff,
            "Infra",
            "Rotate the keys.",
        )
        .unwrap();
        let typed = deliver(&history, T0, &set);
        assert!(typed[0].2.contains("hand-off #1") && typed[0].2.contains("bot accept 1"));
        assert_eq!(
            message(&history.db().unwrap(), handoff)
                .unwrap()
                .unwrap()
                .deadline_ms,
            Some(T0 + 300_000)
        );
        assert_eq!(
            owner(1),
            "jarvis-id",
            "the work stays with its owner until it is accepted"
        );
        // One owner, one bot at a time: no second hand-off while the first is open.
        assert!(
            sent(
                &history,
                T0 + 1_000,
                &set,
                "Jarvis",
                Kind::Handoff,
                "Shop",
                "Rotate the keys."
            )
            .unwrap_err()
            .contains("one bot at a time")
        );

        let said = closed(
            &history,
            T0 + 2_000,
            &set,
            "Infra",
            handoff,
            Closing::Accept,
        )
        .unwrap();
        assert!(said.contains("the work is yours now") && said.contains("bot reply 1"));
        assert_eq!(
            (state(&history, handoff), owner(1)),
            ("accepted".to_owned(), "infra-id".to_owned())
        );
        assert!(
            deliver(&history, T0 + 2_000, &set).is_empty(),
            "accepting wakes nobody"
        );
        assert_eq!(
            testing::at(&history, T0 + 9_000_000, &set, expire),
            0,
            "accepted work does not lapse"
        );
        assert!(
            closed(
                &history,
                T0 + 3_000,
                &set,
                "Infra",
                handoff,
                Closing::Accept
            )
            .unwrap_err()
            .contains("already accepted")
        );
        // The work is Infra's now, so Jarvis cannot hand it to someone else.
        assert!(
            sent(
                &history,
                T0 + 3_000,
                &set,
                "Jarvis",
                Kind::Handoff,
                "Shop",
                "Rotate the keys."
            )
            .unwrap_err()
            .contains("Infra owns it")
        );

        closed(
            &history,
            T0 + 60_000,
            &set,
            "Infra",
            handoff,
            Closing::Reply("Keys rotated."),
        )
        .unwrap();
        assert_eq!(state(&history, handoff), "answered");
        let typed = deliver(&history, T0 + 60_000, &set);
        assert!(typed[0].0 == "jarvis-id" && typed[0].2.starts_with("[Report from the bot Infra, passed on by SwarmHub] on your hand-off #1\nKeys rotated."));
        let codes: Vec<_> = lines(&history, "Jarvis")
            .into_iter()
            .map(|line| line.1.unwrap())
            .collect();
        assert_eq!(codes, ["handoff", "accept", "reply"]);
        assert_eq!(lines(&history, "Infra").len(), 3);

        // Declined with a reason: the work stays where it was, and the sender is told why.
        let key = testing::session(&history, "Shop", "t9");
        let task = newest_task(&history.db().unwrap(), &key, None).unwrap();
        let shop = testing::bot(&history, "Shop");
        let second = testing::at(&history, T0 + 100_000, &set, |ctx| {
            send(
                ctx,
                &shop,
                task,
                Kind::Handoff,
                "Infra",
                "Refund order 7.",
                "command",
            )
        })
        .unwrap()
        .id;
        let typed = deliver(&history, T0 + 100_000, &set);
        assert!(
            typed[0].2.contains("started with the person"),
            "its first message was sent in a turn of the person"
        );
        closed(
            &history,
            T0 + 101_000,
            &set,
            "Infra",
            second,
            Closing::Decline("Refunds are not mine."),
        )
        .unwrap();
        assert_eq!(state(&history, second), "declined");
        assert_eq!(owner(2), "shop-id");
        let typed = deliver(&history, T0 + 101_000, &set);
        assert!(
            typed[0].0 == "shop-id"
                && typed[0].2.contains("declined your hand-off")
                && typed[0].2.contains("Refunds are not mine.")
        );
        // After a refusal the owner may hand it to another bot.
        let third = testing::at(&history, T0 + 102_000, &set, |ctx| {
            send(
                ctx,
                &shop,
                task,
                Kind::Handoff,
                "Jarvis",
                "Refund order 7.",
                "command",
            )
        })
        .unwrap()
        .id;
        deliver(&history, T0 + 102_000, &set);
        // Nobody accepts within five minutes: it ends, the sender is told, and the main bot will hear of it.
        assert_eq!(
            testing::at(&history, T0 + 102_000 + 299_000, &set, expire),
            0
        );
        assert_eq!(
            testing::at(&history, T0 + 102_000 + 300_000, &set, expire),
            1
        );
        assert_eq!(
            (state(&history, third), owner(2)),
            ("expired".to_owned(), "shop-id".to_owned())
        );
        let typed = deliver(&history, T0 + 500_000, &set);
        assert!(
            typed[0].0 == "shop-id"
                && typed[0]
                    .2
                    .contains("did not accept your hand-off #6 within 5 minutes")
                && typed[0].2.contains("still yours")
        );
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_flags WHERE kind='handoff' AND key='handoff:6'"
            ),
            1
        );
        assert!(
            closed(
                &history,
                T0 + 600_000,
                &set,
                "Jarvis",
                third,
                Closing::Accept
            )
            .unwrap_err()
            .contains("not accepted in time")
        );

        // A result without an acceptance takes the work over all the same.
        let fourth = testing::at(&history, T0 + 700_000, &set, |ctx| {
            send(
                ctx,
                &shop,
                task,
                Kind::Handoff,
                "Infra",
                "Count the stock.",
                "command",
            )
        })
        .unwrap()
        .id;
        closed(
            &history,
            T0 + 701_000,
            &set,
            "Infra",
            fourth,
            Closing::Reply("42 items."),
        )
        .unwrap();
        assert_eq!(
            (state(&history, fourth), owner(2)),
            ("answered".to_owned(), "infra-id".to_owned())
        );
    }

    #[test]
    fn the_same_two_bots_exchange_at_most_eight_messages_about_one_piece_of_work() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings {
            messages_per_window: 100,
            ..Settings::default()
        };
        // Four asks and their four answers are eight messages.
        for round in 0..4 {
            let now = T0 + round * 10_000;
            let ask = sent(&history, now, &set, "Jarvis", Kind::Ask, "Infra", "Next?").unwrap();
            deliver(&history, now, &set);
            closed(
                &history,
                now + 1_000,
                &set,
                "Infra",
                ask,
                Closing::Reply("Next."),
            )
            .unwrap();
            deliver(&history, now + 1_000, &set);
        }
        let refused = sent(
            &history,
            T0 + 50_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Next?",
        )
        .unwrap_err();
        assert!(
            refused.contains("exchanged 8 messages")
                && refused.contains("Bring the matter to the person")
        );
        // The other direction is the same pair.
        assert!(
            sent(
                &history,
                T0 + 51_000,
                &set,
                "Jarvis",
                Kind::Tell,
                "Infra",
                "Bye."
            )
            .is_err()
        );
        assert_eq!(count(&history, "SELECT count(*) FROM bot_messages"), 8);
        assert!(
            deliver(&history, T0 + 52_000, &set).is_empty(),
            "the other bot's agent is not woken at a limit"
        );
        // Both chats get one line about it, however often the sender tries.
        for bot in ["Jarvis", "Infra"] {
            let limits: Vec<_> = lines(&history, bot)
                .into_iter()
                .filter(|line| line.1.as_deref() == Some("limit_pair"))
                .collect();
            assert_eq!(limits.len(), 1, "{bot}");
            assert_eq!(
                limits[0].2,
                "Jarvis and Infra have exchanged 8 messages about this, which is the limit. Jarvis was told to bring the matter to you."
            );
        }
        let db = history.db().unwrap();
        let line = entries(
            &db,
            &Lines {
                bot: Some("infra-id"),
                kind: Some("notice"),
                after: Some(0),
                limit: 5,
                ..Lines::default()
            },
        )
        .unwrap();
        assert!(line[0].unread && line[0].notify);
        drop(db);

        // What is still open may always be closed: a limit leaves nothing hanging.
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let last = sent(&history, T0, &set, "Jarvis", Kind::Ask, "Infra", "One").unwrap();
        for _ in 0..7 {
            sent(&history, T0, &set, "Jarvis", Kind::Tell, "Infra", "More").unwrap();
        }
        assert!(
            sent(
                &history,
                T0,
                &set,
                "Jarvis",
                Kind::Tell,
                "Infra",
                "Too many"
            )
            .is_err()
        );
        assert!(
            closed(
                &history,
                T0 + 1_000,
                &set,
                "Infra",
                last,
                Closing::Reply("Answer")
            )
            .is_ok()
        );
        // A new message of the person is a new piece of work, with its own count.
        let key = testing::session(&history, "Jarvis", "t7");
        let jarvis = testing::bot(&history, "Jarvis");
        let task = newest_task(&history.db().unwrap(), &key, None).unwrap();
        assert!(task.is_some());
        assert!(
            testing::at(&history, T0 + 2_000, &set, |ctx| send(
                ctx,
                &jarvis,
                task,
                Kind::Ask,
                "Infra",
                "Fresh",
                "command"
            ))
            .is_ok()
        );
        // The limit is a setting.
        let tight = Settings {
            pair_messages: 2,
            ..set.clone()
        };
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        sent(&history, T0, &tight, "Jarvis", Kind::Tell, "Infra", "1").unwrap();
        sent(&history, T0, &tight, "Infra", Kind::Tell, "Jarvis", "2").unwrap();
        // Each bot's own first message started its own piece of work here, so each has room for one more.
        assert!(sent(&history, T0, &tight, "Jarvis", Kind::Tell, "Infra", "3").is_ok());
        assert!(sent(&history, T0, &tight, "Jarvis", Kind::Tell, "Infra", "4").is_err());
    }

    #[test]
    fn fifth_and_later_recipients_join_the_same_work_with_legacy_settings() {
        let (_scratch, history) = testing::journal(&["A", "B", "C", "Boppy", "Jarvis", "F"]);
        let set = {
            let db = history.db().unwrap();
            db.execute(
                "INSERT OR REPLACE INTO bot_state(key,value) VALUES('settings',?1)",
                [r#"{"chain_bots":4,"messages_per_window":2,"pair_messages":2}"#],
            )
            .unwrap();
            Settings::load(&db).unwrap()
        };
        assert_eq!((set.pair_messages, set.messages_per_window), (2, 2));
        assert!(
            serde_json::to_value(&set)
                .unwrap()
                .get("chain_bots")
                .is_none()
        );
        let keys: Vec<String> = ["A", "B", "C", "Boppy"]
            .iter()
            .enumerate()
            .map(|(i, name)| testing::session(&history, name, &format!("t{}", i + 1)))
            .collect();
        // The person writes to A. A asks B; B, while answering, asks C; C asks Boppy.
        let mut work = None;
        for (index, pair) in [("A", "B"), ("B", "C"), ("C", "Boppy")].iter().enumerate() {
            let sender = testing::bot(&history, pair.0);
            let task = newest_task(&history.db().unwrap(), &keys[index], None).unwrap();
            let ask = testing::at(&history, T0 + index as i64, &set, |ctx| {
                send(ctx, &sender, task, Kind::Ask, pair.1, "Help?", "command")
            })
            .unwrap()
            .id;
            let asked = message(&history.db().unwrap(), ask).unwrap().unwrap();
            assert_eq!(
                *work.get_or_insert(asked.work),
                asked.work,
                "one piece of work"
            );
            // The ask is typed into the next bot's session: that task is what ties its turn to this work.
            let receiver = testing::bot(&history, pair.1);
            let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
                "address":format!("t{}", index + 2),"name":receiver.agent_name,"state":"live","status":null,"template":"fixture",
                "created_ms":42,"exit_code":null,"reason":null,"first_message":null,
                "labels":{"swarmhub.workspace":"agent","swarmhub.launch":keys[index + 1]}
            })).unwrap();
            let (task, _) = history
                .start_task("core", &terminal, "typed", None, false, &[])
                .unwrap();
            history
                .db()
                .unwrap()
                .execute(
                    "UPDATE bot_outbox SET task=?1,state='typed' WHERE message=?2",
                    params![task, ask],
                )
                .unwrap();
        }
        let chain: String = history
            .db()
            .unwrap()
            .query_row(
                "SELECT chain FROM bot_work WHERE id=?1",
                [work.unwrap()],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(chain, r#"["a-id","b-id","c-id","boppy-id"]"#);
        let boppy = testing::bot(&history, "Boppy");
        let task = newest_task(&history.db().unwrap(), &keys[3], None).unwrap();
        let fifth = testing::at(&history, T0 + 10, &set, |ctx| {
            send(ctx, &boppy, task, Kind::Ask, "Jarvis", "Help?", "command")
        })
        .unwrap();
        let owner = testing::bot(&history, "A");
        let origin = newest_task(&history.db().unwrap(), &keys[0], None).unwrap();
        let sixth = testing::at(&history, T0 + 10, &set, |ctx| {
            send(
                ctx,
                &owner,
                origin,
                Kind::Handoff,
                "F",
                "Take it.",
                "command",
            )
        })
        .unwrap();
        {
            let db = history.db().unwrap();
            for id in [fifth.id, sixth.id] {
                assert_eq!(message(&db, id).unwrap().unwrap().work, work.unwrap());
            }
            let saved = super::work(&db, work.unwrap()).unwrap();
            assert_eq!(
                saved.chain,
                ["a-id", "b-id", "c-id", "boppy-id", "jarvis-id", "f-id"]
            );
            assert_eq!(saved.owner, owner.id);
        }
        // A bot that is already part of it can be written to again.
        assert!(
            testing::at(&history, T0 + 11, &set, |ctx| send(
                ctx,
                &boppy,
                task,
                Kind::Ask,
                "A",
                "Back to you?",
                "command"
            ))
            .is_ok()
        );
        // Only the owner hands the work off: Boppy was asked, it does not own it.
        assert!(
            testing::at(&history, T0 + 12, &set, |ctx| send(
                ctx,
                &boppy,
                task,
                Kind::Handoff,
                "B",
                "Take it.",
                "command"
            ))
            .unwrap_err()
            .contains("A owns it")
        );
        closed(&history, T0 + 13, &set, "F", sixth.id, Closing::Accept).unwrap();
        assert_eq!(
            super::work(&history.db().unwrap(), work.unwrap())
                .unwrap()
                .owner,
            "f-id"
        );
        let too_fast = testing::at(&history, T0 + 14, &set, |ctx| {
            send(ctx, &boppy, task, Kind::Tell, "F", "Again", "command")
        })
        .unwrap_err();
        assert!(too_fast.contains("in the last"));
        let later = T0 + seconds(set.window_seconds) + 20;
        testing::at(&history, later, &set, |ctx| {
            send(ctx, &boppy, task, Kind::Tell, "Jarvis", "Again", "command")
        })
        .unwrap();
        let too_many = testing::at(&history, later, &set, |ctx| {
            send(ctx, &boppy, task, Kind::Tell, "Jarvis", "Again", "command")
        })
        .unwrap_err();
        assert!(too_many.contains("exchanged"));
    }

    #[test]
    fn a_bot_sends_at_most_six_new_messages_in_ten_minutes_and_may_still_answer() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra", "Shop"]);
        let set = Settings {
            pair_messages: 64,
            ..Settings::default()
        };
        let waiting = sent(&history, T0, &set, "Infra", Kind::Ask, "Jarvis", "Status?").unwrap();
        for index in 0..6 {
            let to = if index % 2 == 0 { "Infra" } else { "Shop" };
            sent(
                &history,
                T0 + index * 1_000,
                &set,
                "Jarvis",
                Kind::Tell,
                to,
                "FYI",
            )
            .unwrap();
        }
        let refused = sent(
            &history,
            T0 + 7_000,
            &set,
            "Jarvis",
            Kind::Tell,
            "Shop",
            "FYI",
        )
        .unwrap_err();
        assert!(refused.contains("sent 6 messages to other bots in the last 10 minutes"));
        assert_eq!(
            lines(&history, "Jarvis")
                .iter()
                .filter(|line| line.1.as_deref() == Some("limit_rate"))
                .count(),
            1
        );
        assert!(
            !lines(&history, "Shop")
                .iter()
                .any(|line| line.1.as_deref() == Some("limit_rate"))
        );
        // An answer is not a new message.
        assert!(
            closed(
                &history,
                T0 + 8_000,
                &set,
                "Jarvis",
                waiting,
                Closing::Reply("Fine.")
            )
            .is_ok()
        );
        // Ten minutes after the first, there is room again.
        assert!(
            sent(
                &history,
                T0 + 600_000,
                &set,
                "Jarvis",
                Kind::Tell,
                "Shop",
                "FYI"
            )
            .is_ok()
        );
    }

    #[test]
    fn a_message_goes_only_to_a_bot_that_can_be_named_and_takes_messages() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra", "Shop"]);
        let set = Settings::default();
        let unknown = sent(&history, T0, &set, "Jarvis", Kind::Ask, "Nobody", "Hi").unwrap_err();
        assert!(
            unknown.contains("No bot named \"Nobody\"") && unknown.contains("\"Infra\", \"Shop\"")
        );
        assert!(
            sent(&history, T0, &set, "Jarvis", Kind::Ask, "Jarvis", "Hi").is_err(),
            "not to itself"
        );
        assert!(
            sent(&history, T0, &set, "Jarvis", Kind::Ask, "Infra", "  ")
                .unwrap_err()
                .contains("Write what to send")
        );
        // By the agent's name too, and whatever the case.
        assert!(sent(&history, T0, &set, "Jarvis", Kind::Tell, "INFRA", "Hi").is_ok());
        assert!(
            sent(
                &history,
                T0,
                &set,
                "Jarvis",
                Kind::Tell,
                "shop-shopid",
                "Hi"
            )
            .is_ok()
        );
        let register = |wanted: crate::bots::Registration| {
            crate::bots::register(&history.db().unwrap(), &wanted, T0)
                .unwrap()
                .unwrap();
        };
        register(crate::bots::Registration {
            id: "shop-id".into(),
            takes_messages: Some(false),
            ..Default::default()
        });
        assert!(
            sent(&history, T0, &set, "Jarvis", Kind::Ask, "Shop", "Hi")
                .unwrap_err()
                .contains("does not take messages from other bots")
        );
        register(crate::bots::Registration {
            id: "twin".into(),
            name: Some("infra".into()),
            ..Default::default()
        });
        assert!(
            sent(&history, T0, &set, "Jarvis", Kind::Ask, "Infra", "Hi")
                .unwrap_err()
                .contains("More than one bot")
        );
        // The bot's own switch: it is told to ask the person, and nothing is written anywhere.
        register(crate::bots::Registration {
            id: "jarvis-id".into(),
            may_message: Some(false),
            ..Default::default()
        });
        let before = count(&history, "SELECT count(*) FROM bot_messages");
        let off = sent(&history, T0, &set, "Jarvis", Kind::Ask, "twin", "Hi").unwrap_err();
        assert!(
            off.contains("turned off messages to other bots for you")
                && off.contains("Ask the person instead")
        );
        assert_eq!(count(&history, "SELECT count(*) FROM bot_messages"), before);
    }

    #[test]
    fn a_stop_ends_the_exchanges_a_bot_is_part_of_and_tells_the_bots_that_waited() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra", "Shop"]);
        let set = Settings::default();
        let key = testing::session(&history, "Jarvis", "t7");
        let jarvis = testing::bot(&history, "Jarvis");
        let task = newest_task(&history.db().unwrap(), &key, None).unwrap();
        let send_as_jarvis = |now: i64, to: &str, text: &str| {
            testing::at(&history, now, &set, |ctx| {
                send(ctx, &jarvis, task, Kind::Ask, to, text, "command")
            })
        };
        let to_infra = send_as_jarvis(T0, "Infra", "Which port?").unwrap().id;
        deliver(&history, T0, &set);
        let to_shop = send_as_jarvis(T0 + 1_000, "Shop", "Which price?")
            .unwrap()
            .id;
        // Shop's ask has not been typed yet when the person stops Infra.
        let infra = testing::bot(&history, "Infra");
        assert_eq!(
            testing::at(&history, T0 + 2_000, &set, |ctx| stop(
                ctx,
                &infra,
                Why::Person
            )),
            2
        );
        assert_eq!(
            (state(&history, to_infra), state(&history, to_shop)),
            ("stopped".to_owned(), "stopped".to_owned())
        );
        // Jarvis waited: its agent is told, once for each ask. What waited to be typed for Shop is not typed.
        let typed = deliver(&history, T0 + 3_000, &set);
        assert_eq!(typed.len(), 2);
        assert!(
            typed
                .iter()
                .all(|(bot, cause, _)| bot == "jarvis-id" && cause == "outcome")
        );
        assert!(
            typed[0].2.contains(
                "Infra was stopped by the person, so your ask #1 ended without an answer"
            )
        );
        assert!(
            typed[0]
                .2
                .contains("Do not write to Infra about this again")
        );
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_outbox WHERE state='dropped' AND bot='shop-id'"
            ),
            1
        );
        for bot in ["Jarvis", "Infra"] {
            assert!(
                lines(&history, bot)
                    .iter()
                    .any(|line| line.1.as_deref() == Some("stopped")
                        && line.2.contains(
                            "Infra was stopped by the person, so Jarvis's ask #1 to Infra ended"
                        ))
            );
        }
        // Nothing further is sent in that exchange: not an answer, and not a new message.
        assert!(
            closed(
                &history,
                T0 + 4_000,
                &set,
                "Infra",
                to_infra,
                Closing::Reply("5432")
            )
            .unwrap_err()
            .contains("was ended (Infra was stopped by the person)")
        );
        assert!(
            closed(
                &history,
                T0 + 4_000,
                &set,
                "Shop",
                to_shop,
                Closing::Reply("9.99")
            )
            .is_err()
        );
        assert!(
            send_as_jarvis(T0 + 5_000, "Infra", "Again?")
                .unwrap_err()
                .contains("This exchange was ended (Infra was stopped by the person)")
        );
        assert_eq!(testing::at(&history, T0 + 9_000_000, &set, expire), 0);
        assert_eq!(count(&history, "SELECT count(*) FROM bot_messages"), 2);
        // A stop with nothing open ends nothing, and the next message of the person starts afresh.
        assert_eq!(
            testing::at(&history, T0 + 6_000, &set, |ctx| stop(
                ctx,
                &infra,
                Why::Person
            )),
            0
        );
        assert!(
            sent(
                &history,
                T0 + 7_000,
                &set,
                "Jarvis",
                Kind::Ask,
                "Infra",
                "New matter"
            )
            .is_ok()
        );

        // The switch ends them the same way, and says why.
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let ask = sent(
            &history,
            T0,
            &set,
            "Infra",
            Kind::Handoff,
            "Jarvis",
            "Take the release.",
        )
        .unwrap();
        closed(&history, T0 + 1_000, &set, "Jarvis", ask, Closing::Accept).unwrap();
        let jarvis = testing::bot(&history, "Jarvis");
        assert_eq!(
            testing::at(&history, T0 + 2_000, &set, |ctx| stop(
                ctx,
                &jarvis,
                Why::Switch
            )),
            1
        );
        let typed = deliver(&history, T0 + 2_000, &set);
        assert!(typed.iter().any(|(bot, _, text)| bot == "infra-id" && text.contains("Jarvis may no longer message other bots (the person turned that off), so your hand-off #1 ended")));
        // The stopped bot's own agent is not typed to about its own stop.
        let infra = testing::bot(&history, "Infra");
        let own = sent(
            &history,
            T0 + 3_000,
            &set,
            "Infra",
            Kind::Ask,
            "Jarvis",
            "And now?",
        )
        .unwrap();
        deliver(&history, T0 + 3_000, &set);
        testing::at(&history, T0 + 4_000, &set, |ctx| {
            stop(ctx, &infra, Why::Removed)
        });
        assert_eq!(state(&history, own), "stopped");
        assert!(deliver(&history, T0 + 4_000, &set).is_empty());
    }

    #[test]
    fn a_message_that_cannot_be_typed_ends_as_not_answered_with_the_reason() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let ask = sent(
            &history,
            T0,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Which port?",
        )
        .unwrap();
        // Its agent never came up: after the time a message may wait, it is given up.
        assert_eq!(testing::at(&history, T0 + 599_000, &set, give_up), 0);
        assert_eq!(testing::at(&history, T0 + 600_000, &set, give_up), 1);
        assert_eq!(state(&history, ask), "expired");
        let typed = deliver(&history, T0 + 601_000, &set);
        assert!(typed[0].0 == "jarvis-id" && typed[0].2.contains("Your ask #1 did not reach Infra: its agent could not be reached within 10 minutes."));
        // A tell that cannot be typed leaves a line for the person in both chats.
        let tell = sent(
            &history,
            T0 + 700_000,
            &set,
            "Jarvis",
            Kind::Tell,
            "Infra",
            "FYI",
        )
        .unwrap();
        let outbox: i64 = history
            .db()
            .unwrap()
            .query_row(
                "SELECT id FROM bot_outbox WHERE message=?1",
                [tell],
                |row| row.get(0),
            )
            .unwrap();
        testing::at(&history, T0 + 701_000, &set, |ctx| {
            untyped(ctx, outbox, "its agent could not be started.")
        });
        for bot in ["Jarvis", "Infra"] {
            let last = lines(&history, bot).pop().unwrap();
            assert_eq!(last.1.as_deref(), Some("undelivered"));
            assert!(
                last.2.contains(
                    "Jarvis's tell #2 did not reach Infra: its agent could not be started."
                )
            );
        }
        // Failing once is final: the same row is not failed twice.
        testing::at(&history, T0 + 702_000, &set, |ctx| {
            untyped(ctx, outbox, "again")
        });
        assert_eq!(
            lines(&history, "Infra")
                .iter()
                .filter(|line| line.1.as_deref() == Some("undelivered"))
                .count(),
            1
        );
    }

    /// Types what waits for `bot` as a task of its session, and gives the journal row.
    fn type_into(
        history: &History,
        name: &str,
        key: &str,
        address: &str,
        now: i64,
        set: &Settings,
    ) -> i64 {
        let bot = testing::bot(history, name);
        let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
            "address":address,"name":bot.agent_name,"state":"live","status":null,"template":"fixture",
            "created_ms":42,"exit_code":null,"reason":null,"first_message":null,
            "labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        })).unwrap();
        let (outbox, text): (i64, String) = history.db().unwrap().query_row(
            "SELECT id,text FROM bot_outbox WHERE bot=?1 AND state='pending' ORDER BY id LIMIT 1", [&bot.id], |row| Ok((row.get(0)?, row.get(1)?))).unwrap();
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
                params![task, outbox],
            )
            .unwrap();
        testing::at(history, now, set, |ctx| typed(ctx, outbox));
        task
    }

    fn replied(
        history: &History,
        name: &str,
        key: &str,
        text: &str,
        now: i64,
        set: &Settings,
    ) -> i64 {
        assert!(crate::history::publish_reply(history.file(), key, "Agent", text, None).unwrap());
        let reply: i64 = history
            .db()
            .unwrap()
            .query_row(
                "SELECT max(id) FROM journal WHERE kind='reply'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        let bot = testing::bot(history, name);
        testing::at(history, now, set, |ctx| {
            on_reply(ctx, &bot, key, reply, text)
        });
        reply
    }

    #[test]
    fn a_turn_the_workspace_started_ends_in_the_bots_history_and_a_turn_of_the_person_does_not() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let (jarvis, infra) = (
            testing::session(&history, "Jarvis", "t7"),
            testing::session(&history, "Infra", "t8"),
        );
        // The person's own turn: the app follows it, so nothing is added.
        replied(&history, "Jarvis", &jarvis, "Hello, person.", T0, &set);
        replied(&history, "Infra", &infra, "Hello, person.", T0, &set);
        assert!(lines(&history, "Jarvis").is_empty() && lines(&history, "Infra").is_empty());

        // A tell is typed into Infra; what Infra says then is in its chat, unread, without an alert.
        sent(
            &history,
            T0,
            &set,
            "Jarvis",
            Kind::Tell,
            "Infra",
            "Standup moved.",
        )
        .unwrap();
        type_into(&history, "Infra", &infra, "t8", T0 + 1_000, &set);
        let reply = replied(
            &history,
            "Infra",
            &infra,
            "Noted: standup moved.",
            T0 + 2_000,
            &set,
        );
        let db = history.db().unwrap();
        let said = entries(
            &db,
            &Lines {
                bot: Some("infra-id"),
                kind: Some("said"),
                after: Some(0),
                limit: 5,
                ..Lines::default()
            },
        )
        .unwrap();
        assert_eq!(said.len(), 1);
        assert_eq!(
            (
                said[0].text.as_str(),
                said[0].code.as_deref(),
                said[0].journal
            ),
            ("Noted: standup moved.", Some("tell"), Some(reply))
        );
        assert!(said[0].unread && !said[0].notify);
        drop(db);
        assert_eq!(
            count(&history, "SELECT count(*) FROM bot_messages"),
            1,
            "a tell is not answered by a reply"
        );
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_outbox WHERE outcome='replied'"
            ),
            1
        );

        // An ask that the bot answers in its own chat, without the command: the words are not taken for the
        // answer (they could as well be "I will look into it"). The bot is reminded, once.
        let ask = sent(
            &history,
            T0 + 10_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Which port?",
        )
        .unwrap();
        type_into(&history, "Infra", &infra, "t8", T0 + 11_000, &set);
        replied(&history, "Infra", &infra, "It is 5432.", T0 + 12_000, &set);
        assert_eq!(state(&history, ask), "open");
        assert_eq!(
            lines(&history, "Infra")
                .iter()
                .filter(|line| line.0 == "said")
                .count(),
            2
        );
        let reminder: (String, String) = history
            .db()
            .unwrap()
            .query_row(
                "SELECT cause,text FROM bot_outbox WHERE bot='infra-id' AND state='pending'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .unwrap();
        assert_eq!(reminder.0, "notice");
        assert!(
            reminder.1.starts_with(
                "[From SwarmHub] Your turn ended, and the ask #2 from Jarvis is still open"
            ),
            "{}",
            reminder.1
        );
        assert!(
            reminder.1.contains("swarmhub-herdr bot reply 2") && reminder.1.contains("9 minutes")
        );
        // In the reminder's turn it only talks again: it is not reminded a second time. Then it sends the answer.
        type_into(&history, "Infra", &infra, "t8", T0 + 13_000, &set);
        replied(
            &history,
            "Infra",
            &infra,
            "Right, one moment.",
            T0 + 13_500,
            &set,
        );
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_outbox WHERE bot='infra-id' AND cause='notice'"
            ),
            1
        );
        closed(
            &history,
            T0 + 14_000,
            &set,
            "Infra",
            ask,
            Closing::Reply("It is 5432."),
        )
        .unwrap();
        assert_eq!(state(&history, ask), "answered");
        // The answer reaches Jarvis; what Jarvis then says is news for the person.
        type_into(&history, "Jarvis", &jarvis, "t7", T0 + 13_000, &set);
        replied(
            &history,
            "Jarvis",
            &jarvis,
            "Infra says the port is 5432.",
            T0 + 14_000,
            &set,
        );
        let db = history.db().unwrap();
        let said = entries(
            &db,
            &Lines {
                bot: Some("jarvis-id"),
                kind: Some("said"),
                after: Some(0),
                limit: 5,
                ..Lines::default()
            },
        )
        .unwrap();
        assert_eq!(said.len(), 1);
        assert_eq!(said[0].code.as_deref(), Some("outcome"));
        assert!(said[0].unread && said[0].notify);
        drop(db);

        // An ask that was answered with the command: the reply of that turn is what the bot said, not an answer.
        let ask = sent(
            &history,
            T0 + 20_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "And the host?",
        )
        .unwrap();
        type_into(&history, "Infra", &infra, "t8", T0 + 21_000, &set);
        closed(
            &history,
            T0 + 22_000,
            &set,
            "Infra",
            ask,
            Closing::Reply("db.internal"),
        )
        .unwrap();
        replied(
            &history,
            "Infra",
            &infra,
            "I answered Jarvis.",
            T0 + 23_000,
            &set,
        );
        assert_eq!(
            count(
                &history,
                &format!("SELECT count(*) FROM bot_messages WHERE about={ask}")
            ),
            1
        );
        assert_eq!(
            lines(&history, "Infra")
                .iter()
                .filter(|line| line.0 == "said")
                .count(),
            4
        );
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_outbox WHERE bot='infra-id' AND cause='notice'"
            ),
            1,
            "answered with the command: no reminder"
        );

        // A bot that asks back first has not answered, and needs no reminder: it wrote to a bot.
        type_into(&history, "Jarvis", &jarvis, "t7", T0 + 24_000, &set);
        replied(
            &history,
            "Jarvis",
            &jarvis,
            "Got the host.",
            T0 + 24_500,
            &set,
        );
        let ask = sent(
            &history,
            T0 + 30_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Deploy now?",
        )
        .unwrap();
        let task = type_into(&history, "Infra", &infra, "t8", T0 + 31_000, &set);
        let infra_bot = testing::bot(&history, "Infra");
        testing::at(&history, T0 + 32_000, &set, |ctx| {
            send(
                ctx,
                &infra_bot,
                Some(task),
                Kind::Ask,
                "Jarvis",
                "Which version?",
                "command",
            )
        })
        .unwrap();
        replied(
            &history,
            "Infra",
            &infra,
            "I asked Jarvis which version.",
            T0 + 33_000,
            &set,
        );
        assert_eq!(state(&history, ask), "open");
        // Its question belongs to the same piece of work.
        assert_eq!(
            count(
                &history,
                &format!("SELECT count(DISTINCT work) FROM bot_messages WHERE id>={ask}")
            ),
            1
        );

        // A turn the person wrote into is theirs: nothing is taken from it.
        let ask = sent(
            &history,
            T0 + 40_000,
            &set,
            "Infra",
            Kind::Ask,
            "Jarvis",
            "Are you there?",
        )
        .unwrap();
        type_into(&history, "Jarvis", &jarvis, "t7", T0 + 41_000, &set);
        let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
            "address":"t7","name":"jarvis-jarvis","state":"live","status":null,"template":"fixture","created_ms":42,
            "exit_code":null,"reason":null,"first_message":null,"labels":{"swarmhub.workspace":"agent","swarmhub.launch":jarvis}
        })).unwrap();
        let (own, _) = history
            .start_task("core", &terminal, "The person steers.", None, false, &[])
            .unwrap();
        history
            .finish(own, crate::history::State::Sent, None, None)
            .unwrap();
        let before = lines(&history, "Jarvis").len();
        replied(
            &history,
            "Jarvis",
            &jarvis,
            "Answering you both.",
            T0 + 42_000,
            &set,
        );
        assert_eq!(state(&history, ask), "open");
        assert_eq!(lines(&history, "Jarvis").len(), before);
    }

    #[test]
    fn a_reply_after_something_the_workspace_typed_is_the_bot_speaking_and_a_stop_closes_what_came_before()
     {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let (jarvis, infra) = (
            testing::session(&history, "Jarvis", "t7"),
            testing::session(&history, "Infra", "t8"),
        );
        // The person's message to Jarvis has no reply yet when Infra's ask is typed into the same turn.
        let ask = sent(
            &history,
            T0,
            &set,
            "Infra",
            Kind::Ask,
            "Jarvis",
            "Which port?",
        )
        .unwrap();
        type_into(&history, "Jarvis", &jarvis, "t7", T0 + 1_000, &set);
        let reply = replied(
            &history,
            "Jarvis",
            &jarvis,
            "Hello, and the port is 5432.",
            T0 + 2_000,
            &set,
        );
        // The workspace typed last, so the words are in the bot's history, with the reply's row: an app that
        // followed the person's turn has the same row and shows it once. They are not taken for the answer.
        let db = history.db().unwrap();
        let said = entries(
            &db,
            &Lines {
                bot: Some("jarvis-id"),
                kind: Some("said"),
                after: Some(0),
                limit: 5,
                ..Lines::default()
            },
        )
        .unwrap();
        assert_eq!(said.len(), 1);
        assert_eq!(
            (said[0].journal, said[0].code.as_deref()),
            (Some(reply), Some("ask"))
        );
        drop(db);
        assert_eq!(state(&history, ask), "open");

        // Infra's first message of the person was never answered: the person stopped it. What is typed after
        // the stop starts a turn of its own, in which an ask left open is noticed again.
        let infra_bot = testing::bot(&history, "Infra");
        let ask = sent(
            &history,
            T0 + 10_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Which host?",
        )
        .unwrap();
        type_into(&history, "Infra", &infra, "t8", T0 + 11_000, &set);
        testing::at(&history, T0 + 12_000, &set, |ctx| floor(ctx, &infra));
        assert_eq!(
            testing::at(&history, T0 + 12_000, &set, |ctx| stop(
                ctx,
                &infra_bot,
                Why::Person
            )),
            2
        );
        assert_eq!(state(&history, ask), "stopped");
        let ask = sent(
            &history,
            T0 + 20_000,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Which host, again?",
        )
        .unwrap();
        // The stop notes for Jarvis come first in its outbox; Infra's is the new ask.
        type_into(&history, "Infra", &infra, "t8", T0 + 21_000, &set);
        replied(&history, "Infra", &infra, "db.internal", T0 + 22_000, &set);
        assert_eq!(state(&history, ask), "open");
        assert_eq!(
            count(
                &history,
                &format!(
                    "SELECT count(*) FROM bot_outbox WHERE bot='infra-id' AND cause='notice' AND message={ask}"
                )
            ),
            1
        );
    }

    #[test]
    fn blocks_in_a_reply_are_passed_on_as_messages_and_a_refusal_is_told_once() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let set = Settings::default();
        let (jarvis, infra) = (
            testing::session(&history, "Jarvis", "t7"),
            testing::session(&history, "Infra", "t8"),
        );
        replied(&history, "Infra", &infra, "Hello, person.", T0, &set);
        // An agent that still writes the block the app taught it, in a turn of the person.
        let reply = "I will ask Infra.\n```swarmhub\n{\"op\":\"message_bot\",\"to\":\"Infra\",\"message\":\"Which port?\"}\n```";
        replied(&history, "Jarvis", &jarvis, reply, T0, &set);
        let ask: (i64, String, String, String) = history
            .db()
            .unwrap()
            .query_row("SELECT id,kind,via,text FROM bot_messages", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .unwrap();
        assert_eq!(
            (ask.1.as_str(), ask.2.as_str(), ask.3.as_str()),
            ("ask", "block", "Which port?")
        );
        assert_eq!(
            lines(&history, "Jarvis").len(),
            1,
            "the person's turn itself is not copied"
        );
        // Infra answers in words and writes to Jarvis with a block of its own.
        type_into(&history, "Infra", &infra, "t8", T0 + 1_000, &set);
        replied(
            &history,
            "Infra",
            &infra,
            "5432.\n```swarmhub\n{\"op\":\"message_bot\",\"to\":\"Jarvis\",\"kind\":\"tell\",\"message\":\"Also: TLS only.\"}\n```",
            T0 + 2_000,
            &set,
        );
        // The ask stays open, and since Infra wrote to a bot in that turn it needs no reminder.
        assert_eq!(state(&history, ask.0), "open");
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_outbox WHERE cause='notice'"
            ),
            0
        );
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_messages WHERE kind='tell' AND via='block'"
            ),
            1
        );

        // A block that cannot be sent: the bot is told once, and a second failure only leaves a line.
        type_into(&history, "Jarvis", &jarvis, "t7", T0 + 3_000, &set);
        let nobody =
            "```swarmhub\n{\"op\":\"message_bot\",\"to\":\"Nobody\",\"message\":\"Hi\"}\n```";
        replied(&history, "Jarvis", &jarvis, nobody, T0 + 4_000, &set);
        let told: (i64, String, String) = history
            .db()
            .unwrap()
            .query_row(
                "SELECT id,cause,text FROM bot_outbox WHERE bot='jarvis-id' AND state='pending'",
                [],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .unwrap();
        assert_eq!(told.1, "notice");
        assert!(told.2.starts_with(
            "[From SwarmHub] Your message to \"Nobody\" was not sent. No bot named \"Nobody\""
        ));
        type_into(&history, "Jarvis", &jarvis, "t7", T0 + 5_000, &set);
        replied(&history, "Jarvis", &jarvis, nobody, T0 + 6_000, &set);
        assert_eq!(
            count(
                &history,
                "SELECT count(*) FROM bot_outbox WHERE bot='jarvis-id' AND state='pending'"
            ),
            0
        );
        assert_eq!(
            lines(&history, "Jarvis")
                .iter()
                .filter(|line| line.1.as_deref() == Some("not_sent"))
                .count(),
            2
        );

        // A request for a new bot goes to the main bot as an ask.
        replied(
            &history,
            "Infra",
            &infra,
            "```swarmhub\n{\"op\":\"request_bot\",\"name\":\"Research\",\"purpose\":\"Reads papers.\"}\n```",
            T0 + 7_000,
            &set,
        );
        let asked: String = history.db().unwrap().query_row(
            "SELECT text FROM bot_messages WHERE receiver='jarvis-id' AND kind='ask' ORDER BY id DESC LIMIT 1", [], |row| row.get(0)).unwrap();
        assert!(
            asked
                .starts_with("Infra asks for a new bot named \"Research\". Purpose: Reads papers.")
        );
    }

    #[test]
    fn bot_list_names_the_others_and_what_is_open() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra", "Shop"]);
        let set = Settings::default();
        let ask = sent(
            &history,
            T0,
            &set,
            "Jarvis",
            Kind::Ask,
            "Infra",
            "Which port?",
        )
        .unwrap();
        deliver(&history, T0, &set);
        let handoff = sent(
            &history,
            T0,
            &set,
            "Shop",
            Kind::Handoff,
            "Infra",
            "Refund order 7.",
        )
        .unwrap();
        closed(&history, T0, &set, "Infra", handoff, Closing::Accept).unwrap();
        let infra = testing::bot(&history, "Infra");
        let text = testing::at(&history, T0 + 60_000, &set, |ctx| list_text(ctx, &infra));
        assert!(text.contains("\"Jarvis\" (the main bot)") && text.contains("\"Shop\""));
        assert!(text.contains(&format!("Waiting for you: ask #{ask} from Jarvis, 9 minutes left. Answer: swarmhub-herdr bot reply {ask}")));
        assert!(text.contains(&format!("Yours: the work of hand-off #{handoff} from Shop")));
        let jarvis = testing::bot(&history, "Jarvis");
        let text = testing::at(&history, T0 + 60_000, &set, |ctx| list_text(ctx, &jarvis));
        assert!(text.contains(&format!(
            "You wait for Infra: ask #{ask} (open, 9 minutes left)"
        )));
        assert_eq!(
            exchanges(&history.db().unwrap(), "infra-id", true)
                .unwrap()
                .len(),
            2
        );
        assert_eq!(
            exchanges(&history.db().unwrap(), "jarvis-id", false)
                .unwrap()
                .len(),
            1
        );
    }
}
