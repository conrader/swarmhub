//! Bots on the server: who they are, what they write to each other, when they plan to come back, and what they
//! promised (`docs/bot-communication.md`).
//!
//! A bot is the app's record: a name, instructions, an agent program and a model. The app registers its bots
//! here (`routes`), so the workspace can type a message into a bot's agent, and start that agent when it is not
//! running, with no app connected. An app that registers no bot gets none of this: no note is added to any
//! task and no command below does anything.
//!
//! - `rules`: the messages between bots (ask, tell, hand off, reply, accept, decline), who owns a piece of work,
//!   how every ask and hand-off ends, the limits, and what a stop ends. Everything there is one SQLite
//!   transaction that writes rows; nothing in it talks to Herdr Core.
//! - `plans`: planned check-ins, open promises, and what the main bot is told about.
//! - `desk`: what does talk to Core. It types what `rules` and `plans` left in the outbox into the bots' agents,
//!   starts an agent that is not running, reads the replies agents save, and runs the clocks.
//! - `cli`: `swarmhub-herdr bot|checkin|promise …`, run by an agent in its own terminal, over the same road as
//!   `helper` and `project` (socket, or files for a sandboxed command).
//! - `routes`: the API and the event stream for the app.

use crate::history::{History, StoreError, now};
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

mod blocks;
mod ci;
pub(crate) mod completions;
pub(crate) mod cli;
pub(crate) mod desk;
mod notes;
mod plans;
mod routes;
mod rules;

pub(crate) use cli::Ask;
pub(crate) use desk::{answer, start_serving, stopped_agent};
pub(crate) use plans::rezone as rezone_plans;
pub(crate) use routes::routes;

/// How an agent's shell reaches the commands: the workspace's own program, so an agent started by another
/// build of it still talks to this one.
pub(crate) fn command() -> String {
    static COMMAND: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    COMMAND
        .get_or_init(|| {
            let own = std::env::current_exe().ok();
            let named = own
                .as_deref()
                .and_then(|path| path.file_name())
                .and_then(|name| name.to_str())
                .unwrap_or("swarmhub-herdr");
            // The plain name when that is what a shell would run anyway.
            let on_path = std::env::var_os("PATH").and_then(|paths| {
                std::env::split_paths(&paths)
                    .map(|folder| folder.join(named))
                    .find(|path| path.is_file())
            });
            match (own.as_deref(), on_path) {
                (Some(own), Some(found))
                    if std::fs::canonicalize(&found).ok().as_deref() == Some(own) =>
                {
                    named.to_owned()
                }
                (Some(own), _) => own
                    .to_str()
                    .filter(|path| !path.chars().any(|c| c.is_whitespace() || c == '\''))
                    .map_or_else(|| "swarmhub-herdr".to_owned(), str::to_owned),
                (None, _) => "swarmhub-herdr".to_owned(),
            }
        })
        .clone()
}

/// The time limits and the limits on messages, check-ins and promises. The defaults are the numbers of
/// `docs/bot-communication.md`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub(crate) struct Settings {
    /// An ask that is not answered this long after it was typed into the receiver's agent ends unanswered.
    pub ask_seconds: u64,
    /// A hand-off that is not accepted this long after it was typed ends unaccepted.
    pub handoff_accept_seconds: u64,
    /// Messages between the same two bots about one piece of work.
    pub pair_messages: u32,
    /// New messages (ask, tell, hand-off) one bot may send within `window_seconds`.
    pub messages_per_window: u32,
    pub window_seconds: u64,
    /// A message that could not be typed into the receiver's agent this long after it was sent is given up.
    pub deliver_seconds: u64,
    /// Two check-ins of one bot fire at least this far apart.
    pub checkin_gap_seconds: u64,
    pub checkins_per_bot: u32,
    /// A check-in whose agent has not answered after this long is recorded as unanswered.
    pub checkin_answer_seconds: u64,
    pub promises_per_bot: u32,
    /// An overdue promise is raised with the bot; this long after that, with the person.
    pub promise_grace_seconds: u64,
    /// The main bot gets at most one note about problems per this long.
    pub initiative_seconds: u64,
    /// Notify the main bot of an undeliverable job completion.
    pub completion_fallback_to_main: bool,
    /// The fallback IANA time zone when the workspace person has no saved zone.
    pub timezone: String,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            ask_seconds: 600,
            handoff_accept_seconds: 300,
            pair_messages: 8,
            messages_per_window: 6,
            window_seconds: 600,
            deliver_seconds: 600,
            checkin_gap_seconds: 300,
            checkins_per_bot: 10,
            checkin_answer_seconds: 900,
            promises_per_bot: 20,
            promise_grace_seconds: 600,
            initiative_seconds: 300,
            completion_fallback_to_main: false,
            timezone: configured_server_timezone().unwrap_or_else(|| "UTC".to_owned()),
        }
    }
}

/// The lowest and highest value each number may be set to.
pub(crate) const BOUNDS: [(&str, u64, u64); 12] = [
    ("ask_seconds", 30, 86_400),
    ("handoff_accept_seconds", 30, 86_400),
    ("pair_messages", 2, 64),
    ("messages_per_window", 1, 100),
    ("window_seconds", 60, 86_400),
    ("deliver_seconds", 60, 3_600),
    ("checkin_gap_seconds", 60, 86_400),
    ("checkins_per_bot", 0, 50),
    ("checkin_answer_seconds", 60, 86_400),
    ("promises_per_bot", 0, 100),
    ("promise_grace_seconds", 30, 86_400),
    ("initiative_seconds", 30, 86_400),
];

pub(crate) fn configured_server_timezone() -> Option<String> {
    std::env::var("TZ")
        .ok()
        .or_else(|| std::fs::read_to_string("/etc/timezone").ok())
        .map(|zone| zone.trim().trim_start_matches(':').to_owned())
        .filter(|zone| zone.parse::<chrono_tz::Tz>().is_ok())
}

impl Settings {
    pub(crate) fn saved(db: &Connection) -> rusqlite::Result<Option<String>> {
        db.query_row(
            "SELECT value FROM bot_state WHERE key='settings'",
            [],
            |row| row.get(0),
        )
        .optional()
    }

    /// Older clients and persisted settings may include this retired field.
    /// All other unknown keys still fail validation.
    fn decode(mut value: serde_json::Value) -> serde_json::Result<Self> {
        if let Some(fields) = value.as_object_mut() {
            fields.remove("chain_bots");
        }
        serde_json::from_value(value)
    }

    pub(crate) fn load(db: &Connection) -> rusqlite::Result<Self> {
        Ok(Self::saved(db)?
            .and_then(|text| serde_json::from_str(&text).and_then(Self::decode).ok())
            .unwrap_or_default())
    }

    /// Why these settings cannot be saved.
    pub(crate) fn problem(&self) -> Option<String> {
        let value = serde_json::to_value(self).ok()?;
        for (name, low, high) in BOUNDS {
            let number = value[name].as_u64().unwrap_or(0);
            if !(low..=high).contains(&number) {
                return Some(format!("{name} must be between {low} and {high}."));
            }
        }
        if self.timezone.parse::<chrono_tz::Tz>().is_err() {
            return Some("timezone must be an IANA time zone such as Europe/Warsaw.".into());
        }
        None
    }

    pub(crate) fn save(&self, db: &Connection) -> rusqlite::Result<()> {
        db.execute(
            "INSERT INTO bot_state (key,value) VALUES ('settings',?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [serde_json::to_string(self).unwrap_or_default()],
        )?;
        Ok(())
    }

    pub(crate) fn zone(&self) -> chrono_tz::Tz {
        self.timezone.parse().unwrap_or(chrono_tz::UTC)
    }
}

/// A bot as the app registered it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Bot {
    pub id: String,
    pub name: String,
    pub agent_name: String,
    pub main: bool,
    pub template: String,
    pub model: String,
    pub instructions: String,
    pub projects: Vec<i64>,
    /// It may write to other bots. Off: its messages are refused and it is told to ask the person.
    pub may_message: bool,
    /// Other bots may write to it.
    pub takes_messages: bool,
    /// Its planned check-ins fire, and (the main bot) it is told about problems.
    pub takes_initiative: bool,
    /// History entries for it may raise a notification.
    pub notifications: bool,
    #[serde(skip)]
    pub noted_launch: Option<String>,
    pub read_through: i64,
    pub created_ms: i64,
    pub updated_ms: i64,
}

const BOT: &str = "id,name,agent_name,main,template,model,instructions,projects,may_message,takes_messages,takes_initiative,notifications,noted_launch,read_through,created_ms,updated_ms";

fn read_bot(row: &Row<'_>) -> rusqlite::Result<Bot> {
    Ok(Bot {
        id: row.get(0)?,
        name: row.get(1)?,
        agent_name: row.get(2)?,
        main: row.get(3)?,
        template: row.get(4)?,
        model: row.get(5)?,
        instructions: row.get(6)?,
        projects: serde_json::from_str(&row.get::<_, String>(7)?).unwrap_or_default(),
        may_message: row.get(8)?,
        takes_messages: row.get(9)?,
        takes_initiative: row.get(10)?,
        notifications: row.get(11)?,
        noted_launch: row.get(12)?,
        read_through: row.get(13)?,
        created_ms: row.get(14)?,
        updated_ms: row.get(15)?,
    })
}

/// The registered bots, oldest first.
pub(crate) fn all(db: &Connection) -> rusqlite::Result<Vec<Bot>> {
    db.prepare_cached(&format!(
        "SELECT {BOT} FROM bots WHERE removed_ms IS NULL ORDER BY created_ms,id"
    ))?
    .query_map([], read_bot)?
    .collect()
}

pub(crate) fn one(db: &Connection, id: &str) -> rusqlite::Result<Option<Bot>> {
    db.prepare_cached(&format!(
        "SELECT {BOT} FROM bots WHERE id=?1 AND removed_ms IS NULL"
    ))?
    .query_row([id], read_bot)
    .optional()
}

/// A bot's name wherever it was removed since, for a line about something it did.
pub(crate) fn name_of(db: &Connection, id: &str) -> String {
    db.query_row("SELECT name FROM bots WHERE id=?1", [id], |row| row.get(0))
        .unwrap_or_else(|_| "a bot that was removed".to_owned())
}

pub(crate) fn main_bot(db: &Connection) -> rusqlite::Result<Option<Bot>> {
    db.prepare_cached(&format!(
        "SELECT {BOT} FROM bots WHERE main=1 AND removed_ms IS NULL ORDER BY updated_ms DESC LIMIT 1"
    ))?
    .query_row([], read_bot)
    .optional()
}

/// The end of an agent's name: the start of its bot's id, which stays when the bot is renamed.
pub(crate) fn suffix(name: &str) -> &str {
    name.rsplit('-').next().unwrap_or(name)
}

/// The name a bot's agent runs under, as the app derives it: the bot's name in lowercase letters, digits and
/// dashes, then the first six letters and digits of its id.
pub(crate) fn agent_name(name: &str, id: &str) -> String {
    let tail: String = id
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|c| c.to_ascii_lowercase())
        .take(6)
        .collect();
    let mut slug = String::new();
    for c in name.chars().flat_map(char::to_lowercase) {
        if c.is_ascii_alphanumeric() {
            slug.push(c);
        } else if !slug.is_empty() && !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let room = 32usize.saturating_sub(tail.len() + 1);
    let mut slug: String = slug.trim_end_matches('-').chars().take(room).collect();
    while slug.ends_with('-') {
        slug.pop();
    }
    if slug.is_empty() {
        format!("agent-{tail}")
    } else {
        format!("{slug}-{tail}")
    }
}

/// The bot an agent of this name belongs to: the same name, or the same id ending after a rename.
pub(crate) fn of_agent(db: &Connection, agent: &str) -> rusqlite::Result<Option<Bot>> {
    let bots = all(db)?;
    Ok(bots
        .iter()
        .find(|bot| bot.agent_name == agent)
        .or_else(|| {
            bots.iter()
                .find(|bot| agent.contains('-') && suffix(&bot.agent_name) == suffix(agent))
        })
        .cloned())
}

/// Who runs a command: a bot's own agent, a helper, or an agent of no registered bot.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Who {
    Bot(Box<Bot>),
    Helper,
    Nobody,
}

pub(crate) fn of_launch(db: &Connection, key: &str) -> rusqlite::Result<Who> {
    let launch: Option<(i64, String)> = db
        .query_row(
            "SELECT id,agent FROM journal WHERE launch_key=?1",
            [key],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    let Some((launch, agent)) = launch else {
        return Ok(Who::Nobody);
    };
    let helper: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM helpers WHERE launch=?1)",
        [launch],
        |row| row.get(0),
    )?;
    if helper {
        return Ok(Who::Helper);
    }
    Ok(of_agent(db, &agent)?.map_or(Who::Nobody, |bot| Who::Bot(Box::new(bot))))
}

/// What the app sends for one bot. A field that is left out keeps its value; a new bot gets the defaults.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Registration {
    pub id: String,
    pub name: Option<String>,
    pub agent_name: Option<String>,
    pub main: Option<bool>,
    pub template: Option<String>,
    pub model: Option<String>,
    pub instructions: Option<String>,
    pub projects: Option<Vec<i64>>,
    pub may_message: Option<bool>,
    pub takes_messages: Option<bool>,
    pub takes_initiative: Option<bool>,
    pub notifications: Option<bool>,
}

pub(crate) const ID_SHAPE: &str =
    "Give each bot an id of 1 to 64 letters, digits and dashes that stays the same for that bot.";
pub(crate) const NAME_SHAPE: &str = "Give the bot a name of 1 to 40 characters on one line.";
pub(crate) const TEXT_SHAPE: &str = "Use plain text: up to 32 characters for a template, 160 for a model and 12 KB for instructions.";

pub(crate) fn valid_id(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
}

fn plain(text: &str, limit: usize) -> bool {
    text.len() <= limit
        && !text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
}

/// Saves one bot as the app describes it and gives it back, with what changed that the rules care about.
pub(crate) fn register(
    db: &Connection,
    wanted: &Registration,
    at: i64,
) -> rusqlite::Result<Result<(Bot, Change), String>> {
    let id = wanted.id.to_ascii_lowercase();
    if !valid_id(&id) {
        return Ok(Err(ID_SHAPE.into()));
    }
    let before = one(db, &id)?;
    let name = match (wanted.name.as_deref().map(str::trim), &before) {
        (Some(name), _) => name.to_owned(),
        (None, Some(before)) => before.name.clone(),
        (None, None) => return Ok(Err(NAME_SHAPE.into())),
    };
    if name.is_empty() || name.chars().count() > 40 || name.chars().any(char::is_control) {
        return Ok(Err(NAME_SHAPE.into()));
    }
    let keep = |new: Option<&String>, old: Option<&String>| {
        new.or(old)
            .map(|text| text.trim().to_owned())
            .unwrap_or_default()
    };
    let template = keep(
        wanted.template.as_ref(),
        before.as_ref().map(|b| &b.template),
    );
    let model = keep(wanted.model.as_ref(), before.as_ref().map(|b| &b.model));
    let instructions = keep(
        wanted.instructions.as_ref(),
        before.as_ref().map(|b| &b.instructions),
    );
    if !plain(&template, 32) || !plain(&model, 160) || !plain(&instructions, 12 * 1024) {
        return Ok(Err(TEXT_SHAPE.into()));
    }
    let agent = match (&wanted.agent_name, &before) {
        (Some(agent), _) => agent.trim().to_owned(),
        // A rename keeps the agent's name: the running agent is still this bot's.
        (None, Some(before)) => before.agent_name.clone(),
        (None, None) => agent_name(&name, &id),
    };
    if !crate::core::valid_name(&agent) {
        return Ok(Err(
            "agent_name must be 1 to 32 lowercase letters, digits, dots, dashes or underscores."
                .into(),
        ));
    }
    let projects = wanted
        .projects
        .clone()
        .or_else(|| before.as_ref().map(|b| b.projects.clone()))
        .unwrap_or_default();
    if projects.len() > 64 {
        return Ok(Err("A bot can be given at most 64 projects.".into()));
    }
    let flag = |new: Option<bool>, old: Option<bool>, default: bool| new.or(old).unwrap_or(default);
    let bot = Bot {
        id: id.clone(),
        name,
        agent_name: agent,
        main: flag(wanted.main, before.as_ref().map(|b| b.main), false),
        template,
        model,
        instructions,
        projects,
        may_message: flag(
            wanted.may_message,
            before.as_ref().map(|b| b.may_message),
            true,
        ),
        takes_messages: flag(
            wanted.takes_messages,
            before.as_ref().map(|b| b.takes_messages),
            true,
        ),
        takes_initiative: flag(
            wanted.takes_initiative,
            before.as_ref().map(|b| b.takes_initiative),
            true,
        ),
        notifications: flag(
            wanted.notifications,
            before.as_ref().map(|b| b.notifications),
            true,
        ),
        noted_launch: before.as_ref().and_then(|b| b.noted_launch.clone()),
        read_through: before.as_ref().map_or(0, |b| b.read_through),
        created_ms: before.as_ref().map_or(at, |b| b.created_ms),
        updated_ms: at,
    };
    if before.as_ref()
        == Some(&Bot {
            updated_ms: before.as_ref().map_or(at, |b| b.updated_ms),
            ..bot.clone()
        })
    {
        return Ok(Ok((before.unwrap_or(bot), Change::default())));
    }
    // One main bot per server: the newest choice wins.
    if bot.main {
        db.execute(
            "UPDATE bots SET main=0,updated_ms=?2 WHERE main=1 AND id!=?1",
            params![bot.id, at],
        )?;
    }
    db.execute(
        "INSERT INTO bots (id,name,agent_name,main,template,model,instructions,projects,may_message,
                           takes_messages,takes_initiative,notifications,created_ms,updated_ms,removed_ms)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,NULL)
         ON CONFLICT(id) DO UPDATE SET name=excluded.name,agent_name=excluded.agent_name,main=excluded.main,
           template=excluded.template,model=excluded.model,instructions=excluded.instructions,
           projects=excluded.projects,may_message=excluded.may_message,takes_messages=excluded.takes_messages,
           takes_initiative=excluded.takes_initiative,notifications=excluded.notifications,
           updated_ms=excluded.updated_ms,removed_ms=NULL",
        params![
            bot.id,
            bot.name,
            bot.agent_name,
            bot.main,
            bot.template,
            bot.model,
            bot.instructions,
            serde_json::to_string(&bot.projects).unwrap_or_else(|_| "[]".into()),
            bot.may_message,
            bot.takes_messages,
            bot.takes_initiative,
            bot.notifications,
            bot.created_ms,
            at
        ],
    )?;
    let change = Change {
        messaging_off: before.as_ref().is_some_and(|b| b.may_message) && !bot.may_message,
    };
    Ok(Ok((bot, change)))
}

/// What a registration changed that ends something.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Change {
    /// "May message other bots" was turned off: the exchanges the bot is part of end.
    pub messaging_off: bool,
}

/// Remembers that the agent of this launch was given the notes for bots.
pub(crate) fn noted(history: &History, bot: &str, key: &str) -> Result<(), StoreError> {
    history.db()?.execute(
        "UPDATE bots SET noted_launch=?2 WHERE id=?1",
        params![bot, key],
    )?;
    Ok(())
}

/// The note a new agent of a registered bot reads with its first task, and the bot it is for. `None` for an
/// agent of no registered bot, which is told nothing.
pub(crate) fn launch_note(
    w: &crate::Workspace,
    agent: &str,
) -> Result<Option<(String, String)>, StoreError> {
    let db = w.history.db()?;
    let Some(bot) = of_agent(&db, agent)? else {
        return Ok(None);
    };
    let others = all(&db)?;
    Ok(Some((
        bot.id.clone(),
        notes::standing(&bot, &others, &command(), w.fleet_authority().configured().is_ok()),
    )))
}

/// Whether any bot is registered. Without one the workspace does nothing here.
pub(crate) fn any(history: &History) -> bool {
    history.db().is_ok_and(|db| {
        db.query_row(
            "SELECT EXISTS(SELECT 1 FROM bots WHERE removed_ms IS NULL)",
            [],
            |row| row.get(0),
        )
        .unwrap_or(false)
    })
}

/// One clock for a transaction of rules: the time, the settings and the command agents run.
pub(crate) struct Ctx<'a> {
    pub db: &'a Connection,
    pub now: i64,
    pub set: &'a Settings,
    pub zone: chrono_tz::Tz,
    pub cmd: &'a str,
}

/// Runs `work` in one write transaction with the saved settings.
pub(crate) fn write<T>(
    history: &History,
    work: impl FnOnce(&Ctx<'_>) -> rusqlite::Result<T>,
) -> Result<T, StoreError> {
    let mut db = history.db()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let set = Settings::load(&tx)?;
    let cmd = command();
    let done = work(&Ctx {
        db: &tx,
        now: now(),
        set: &set,
        zone: crate::person_profile::zone(&tx, set.zone())?,
        cmd: &cmd,
    })?;
    tx.commit()?;
    Ok(done)
}

/// Like `write`, for a change that is all or nothing: what `work` wrote is kept only when it says `Ok`.
pub(crate) fn attempt<T, E>(
    history: &History,
    work: impl FnOnce(&Ctx<'_>) -> rusqlite::Result<Result<T, E>>,
) -> Result<Result<T, E>, StoreError> {
    let mut db = history.db()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let set = Settings::load(&tx)?;
    let cmd = command();
    let done = work(&Ctx {
        db: &tx,
        now: now(),
        set: &set,
        zone: crate::person_profile::zone(&tx, set.zone())?,
        cmd: &cmd,
    })?;
    if done.is_ok() {
        tx.commit()?;
    }
    Ok(done)
}

pub(crate) fn profile_moved(
    db: &Connection,
    now: i64,
    before: chrono_tz::Tz,
    after: chrono_tz::Tz,
    city_changed: bool,
) -> rusqlite::Result<()> {
    if before == after && !city_changed {
        return Ok(());
    }
    let Some(main) = main_bot(db)? else {
        return Ok(());
    };
    const MOVE_NOTE_GAP_MS: i64 = 60_000;
    let recently_noted: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM bot_history WHERE bot=?1 AND code='user_moved' AND at_ms>?2)",
        params![main.id, now.saturating_sub(MOVE_NOTE_GAP_MS)],
        |row| row.get(0),
    )?;
    if recently_noted {
        return Ok(());
    }
    let line = if before != after {
        format!("User moved: {before} -> {after}")
    } else {
        "User moved: location updated.".to_owned()
    };
    let set = Settings::load(db)?;
    let ctx = Ctx {
        db,
        now,
        set: &set,
        zone: after,
        cmd: &command(),
    };
    rules::entry(
        &ctx,
        &main.id,
        "notice",
        &line,
        rules::About {
            code: Some("user_moved"),
            ..rules::About::default()
        },
        true,
        false,
    )?;
    rules::post(
        &ctx,
        rules::Post {
            bot: &main.id,
            text: &format!("{} {line}", notes::MAIN_LEAD),
            cause: "note",
            ..rules::Post::default()
        },
    )?;
    Ok(())
}

#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    /// A journal with bots registered under these names; the first is the main bot.
    pub(crate) fn journal(names: &[&str]) -> (tempfile::TempDir, History) {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        for (index, name) in names.iter().enumerate() {
            let db = history.db().unwrap();
            register(
                &db,
                &Registration {
                    id: id_of(name),
                    name: Some((*name).to_owned()),
                    main: Some(index == 0),
                    template: Some("fixture".into()),
                    ..Registration::default()
                },
                1_000,
            )
            .unwrap()
            .unwrap();
        }
        (scratch, history)
    }

    /// The id a test bot of this name is registered under: its first word.
    pub(crate) fn id_of(name: &str) -> String {
        format!(
            "{}-id",
            name.split(' ').next().unwrap_or(name).to_lowercase()
        )
    }

    pub(crate) fn bot(history: &History, name: &str) -> Bot {
        one(&history.db().unwrap(), &id_of(name)).unwrap().unwrap()
    }

    /// Runs rules at a chosen time with chosen settings.
    pub(crate) fn at<T>(
        history: &History,
        now: i64,
        set: &Settings,
        work: impl FnOnce(&Ctx<'_>) -> rusqlite::Result<T>,
    ) -> T {
        let mut db = history.db().unwrap();
        let tx = db.transaction().unwrap();
        let done = work(&Ctx {
            db: &tx,
            now,
            set,
            zone: crate::person_profile::zone(&tx, set.zone()).unwrap(),
            cmd: "swarmhub-herdr",
        })
        .unwrap();
        tx.commit().unwrap();
        done
    }

    /// A running session for a bot, as a launch would record it: its launch key.
    pub(crate) fn session(history: &History, name: &str, address: &str) -> String {
        let bot = bot(history, name);
        let (launch, key) = history
            .start_launch(
                "core",
                &bot.agent_name,
                "A message of the person.",
                None,
                "{}",
                "",
            )
            .unwrap()
            .unwrap();
        let terminal: crate::core::Terminal = serde_json::from_value(serde_json::json!({
            "address":address,"name":bot.agent_name,"state":"live","status":null,"template":"fixture",
            "created_ms":42,"exit_code":null,"reason":null,"first_message":null,
            "labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        }))
        .unwrap();
        history
            .finish(launch, crate::history::State::Sent, None, Some(&terminal))
            .unwrap();
        key
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_bot_is_registered_once_and_an_agent_is_found_by_its_name_or_the_end_of_it() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra Bot"]);
        let db = history.db().unwrap();
        // The app's own name for the agent, from the bot's name and the start of its id.
        assert_eq!(
            agent_name("Jarvis", "A79B16C2-0000-4000-8000-000000000000"),
            "jarvis-a79b16"
        );
        assert_eq!(agent_name("  Ünï code!! Bot ", "xy"), "n-code-bot-xy");
        assert_eq!(agent_name("…", "0f-1e"), "agent-0f1e");
        assert_eq!(agent_name(&"long".repeat(20), "abcdef12").len(), 32);
        assert_eq!(
            one(&db, "infra-id").unwrap().unwrap().agent_name,
            "infra-bot-infrai"
        );
        let jarvis = one(&db, "jarvis-id").unwrap().unwrap();
        assert!(jarvis.main && jarvis.may_message && jarvis.takes_messages);
        assert!(jarvis.takes_initiative && jarvis.notifications);
        assert_eq!(jarvis.agent_name, "jarvis-jarvis");
        assert_eq!(main_bot(&db).unwrap().unwrap().id, "jarvis-id");
        assert_eq!(
            of_agent(&db, "jarvis-jarvis").unwrap().unwrap().id,
            "jarvis-id"
        );
        // Renamed in the app: the agent that still runs under the old name is the same bot's.
        assert_eq!(
            of_agent(&db, "old-name-jarvis").unwrap().unwrap().id,
            "jarvis-id"
        );
        assert!(of_agent(&db, "someone-else").unwrap().is_none());
        assert!(of_agent(&db, "jarvis").unwrap().is_none());

        // A field that is left out keeps its value, and a second main bot takes the role.
        let (changed, change) = register(
            &db,
            &Registration {
                id: "INFRA-ID".into(),
                main: Some(true),
                may_message: Some(false),
                ..Registration::default()
            },
            2_000,
        )
        .unwrap()
        .unwrap();
        assert!(changed.main && !changed.may_message && change.messaging_off);
        assert_eq!(
            (changed.name.as_str(), changed.template.as_str()),
            ("Infra Bot", "fixture")
        );
        assert_eq!(main_bot(&db).unwrap().unwrap().id, "infra-id");
        assert!(!one(&db, "jarvis-id").unwrap().unwrap().main);
        // The same registration again changes nothing.
        let again = Registration {
            id: "infra-id".into(),
            ..Registration::default()
        };
        let (same, change) = register(&db, &again, 3_000).unwrap().unwrap();
        assert_eq!((same.updated_ms, change), (2_000, Change::default()));

        for refused in [
            Registration {
                id: "bad id".into(),
                name: Some("X".into()),
                ..Registration::default()
            },
            Registration {
                id: "new".into(),
                ..Registration::default()
            },
            Registration {
                id: "new".into(),
                name: Some("two\nlines".into()),
                ..Registration::default()
            },
            Registration {
                id: "new".into(),
                name: Some("X".into()),
                agent_name: Some("Not Valid".into()),
                ..Registration::default()
            },
        ] {
            assert!(register(&db, &refused, 4_000).unwrap().is_err());
        }
    }

    #[test]
    fn who_runs_a_command_is_a_bot_a_helper_or_nobody() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let key = testing::session(&history, "Jarvis", "t7");
        let (_, stranger) = history
            .start_launch("core", "stranger-123456", "Hi", None, "{}", "")
            .unwrap()
            .unwrap();
        let db = history.db().unwrap();
        assert!(matches!(of_launch(&db, &key).unwrap(), Who::Bot(bot) if bot.name == "Jarvis"));
        assert_eq!(of_launch(&db, &stranger).unwrap(), Who::Nobody);
        assert_eq!(of_launch(&db, "no-such-key").unwrap(), Who::Nobody);
        // A helper's terminal is named after its parent's address, and it is in the helpers table.
        db.execute(
            "INSERT INTO journal (launch_key,core_id,agent,kind,state,text,at_ms) VALUES ('helperkey','core','easy-1-t7','task','sent','Count',1)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO helpers (launch,parent_key,name,difficulty,template,model)
             SELECT id,?1,'easy-1','easy','fixture','small' FROM journal WHERE launch_key='helperkey'",
            [&key],
        )
        .unwrap();
        assert_eq!(of_launch(&db, "helperkey").unwrap(), Who::Helper);
    }

    #[test]
    fn settings_keep_to_their_bounds_and_default_to_the_numbers_of_the_specification() {
        let (_scratch, history) = testing::journal(&[]);
        let db = history.db().unwrap();
        let set = Settings::load(&db).unwrap();
        assert_eq!(
            (
                set.ask_seconds,
                set.handoff_accept_seconds,
                set.pair_messages
            ),
            (600, 300, 8)
        );
        assert_eq!(
            (
                set.messages_per_window,
                set.window_seconds,
                set.checkin_gap_seconds,
                set.checkins_per_bot
            ),
            (6, 600, 300, 10)
        );
        assert!(set.problem().is_none());
        let short = Settings {
            checkin_gap_seconds: 59,
            ..set.clone()
        };
        assert!(short.problem().unwrap().contains("checkin_gap_seconds"));
        let nowhere = Settings {
            timezone: "Mars/Olympus".into(),
            ..set.clone()
        };
        assert!(nowhere.problem().unwrap().contains("timezone"));
        let changed = Settings {
            ask_seconds: 120,
            timezone: "Europe/Warsaw".into(),
            ..set
        };
        changed.save(&db).unwrap();
        assert_eq!(Settings::load(&db).unwrap(), changed);
        drop(db);
        assert!(!any(&history));
    }
}
