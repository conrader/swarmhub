//! The part of `bots` that talks to Herdr Core and runs with nobody connected.
//!
//! - `answer` does what an agent's `bot`, `checkin` or `promise` command asks.
//! - A clock runs every two seconds, and at once when something was asked: it reads the replies agents saved
//!   since the last look (`rules::on_reply`), ends what ran out of time, fires check-ins, raises promises, and
//!   types what is waiting in the outbox into the bots' agents, one message per bot at a time. A bot whose
//!   agent is not running is started first, ahead of the message (`warm`), with the bot's registered
//!   instructions.
//! - A slower watch notes what the main bot is told about: an agent waiting at a prompt, a helper that stopped
//!   without an answer, a project server that cannot be reached.
//!
//! None of it runs while no bot is registered.

use super::{Ask, Bot, Who, cli::NOT_A_BOT, notes, plans, rules};
use crate::{ApiError, Workspace, core::Terminal, history::now, warm};
use rusqlite::{OptionalExtension, params};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Mutex,
    time::Duration,
};
use tokio::sync::Notify;

const TICK: Duration = Duration::from_secs(2);
const WATCH: Duration = Duration::from_secs(20);
/// An agent that has shown a prompt for this long is flagged.
const BLOCKED_MS: i64 = 60_000;
const HELPER: &str = "A helper may not write to bots, plan check-ins or record promises. Put what you need into your answer: the agent that started you reads it.";
const UNKNOWN_BOT: &str = "This agent does not belong to a bot that SwarmHub knows on this server, so nothing was sent or planned. Tell the person what you wanted to do.";
const STORAGE: &str = "The workspace could not use its saved history. Nothing was changed.";

static WAKE: Notify = Notify::const_new();
/// Bots with a delivery on its way: one message at a time is typed into an agent.
static BUSY: Mutex<BTreeSet<String>> = Mutex::new(BTreeSet::new());

/// Has the clock look now instead of at its next tick.
pub(crate) fn kick() {
    WAKE.notify_one();
}

/// Does what an agent's `bot`, `checkin` or `promise` command asks, for the agent with this launch key.
/// `core_id` is the check that the key belongs to a session of this workspace (`helpers::registered`).
pub(crate) async fn answer(
    w: &Workspace,
    core_id: Result<String, String>,
    key: &str,
    ask: Ask,
) -> Result<String, String> {
    core_id.map_err(|why| {
        if why == crate::helpers::UNREGISTERED {
            NOT_A_BOT.to_owned()
        } else {
            why
        }
    })?;
    let said =
        super::write(&w.history, |ctx| perform(ctx, key, ask)).map_err(|_| STORAGE.to_owned())?;
    kick();
    said
}

/// What a command of the agent with this launch key does, as rows. A helper and an agent of no registered bot
/// are refused here, whatever they ask.
fn perform(ctx: &super::Ctx<'_>, key: &str, ask: Ask) -> rusqlite::Result<Result<String, String>> {
    let bot = match super::of_launch(ctx.db, key)? {
        Who::Bot(bot) => *bot,
        Who::Helper => return Ok(Err(HELPER.to_owned())),
        Who::Nobody => return Ok(Err(UNKNOWN_BOT.to_owned())),
    };
    let cmd = ctx.cmd;
    Ok(match ask {
        Ask::List => Ok(rules::list_text(ctx, &bot)?),
        Ask::Send { kind, to, text } => match rules::Kind::parse(&kind) {
            Some(kind) => {
                let task = rules::newest_task(ctx.db, key, None)?;
                rules::send(ctx, &bot, task, kind, &to, &text, "command")?.map(|sent| sent.text)
            }
            None => Err("A message is an ask, a tell or a handoff.".to_owned()),
        },
        Ask::Reply { id, text } => {
            rules::close(ctx, &bot, id, rules::Closing::Reply(&text), "command")?
        }
        Ask::Accept { id } => rules::close(ctx, &bot, id, rules::Closing::Accept, "command")?,
        Ask::Decline { id, reason } => {
            rules::close(ctx, &bot, id, rules::Closing::Decline(&reason), "command")?
        }
        Ask::Checkin { when, what } => plans::plan(ctx, &bot, &when, &what, "bot")?.map(|planned| {
            format!(
                "Planned check-in #{}: {}, next on {}. It runs on the server, also with the app closed{}. Cancel it with: {cmd} checkin cancel {}",
                planned.id,
                planned.schedule.words(ctx),
                planned.next_ms.map_or_else(|| "?".into(), |next| notes::clock(next, ctx.set)),
                if planned.schedule.recurring() { "" } else { ", and what you find then is shown to the person" },
                planned.id
            )
        }),
        Ask::Checkins => Ok(plans::checkin_text(ctx, &bot)?),
        Ask::CancelCheckin { id } => {
            if plans::cancel(ctx, &bot.id, id)? {
                Ok(format!("Cancelled check-in #{id}."))
            } else {
                Err(format!(
                    "You have no planned check-in #{id}. See yours with: {cmd} checkin list"
                ))
            }
        }
        Ask::Promise { by, what } => {
            let due = by.moment(ctx);
            plans::promise(ctx, &bot, due, &what)?.map(|made| {
                format!(
                    "Recorded promise #{}, due {}. When it is done, run: {cmd} promise done {}. If it is still open then, you are reminded once, and after that the person is told.",
                    made.id,
                    notes::clock(made.due_ms, ctx.set),
                    made.id
                )
            })
        }
        Ask::PromiseDone { id, note } => {
            if plans::settle(ctx, &bot.id, id, "done", note.as_deref())? {
                Ok(format!("Closed promise #{id}."))
            } else {
                Err(format!(
                    "You have no open promise #{id}. See yours with: {cmd} promise list"
                ))
            }
        }
        Ask::Promises => Ok(plans::promise_text(ctx, &bot)?),
    })
}

/// The person stopped this agent, or ended it: the exchanges its bot is part of end, and the bots that waited
/// are told.
pub(crate) fn stopped_agent(w: &Workspace, agent: &Terminal) {
    let Some(key) = agent.launch_key() else {
        return;
    };
    if !super::any(&w.history) {
        return;
    }
    let _ = super::write(&w.history, |ctx| {
        if let Who::Bot(bot) = super::of_launch(ctx.db, key)? {
            rules::floor(ctx, key)?;
            rules::stop(ctx, &bot, rules::Why::Person)?;
        }
        Ok(())
    });
    kick();
}

/// Starts the clock and the watch.
pub(crate) fn start_serving(w: Workspace) {
    // What a workspace that stopped left half-typed is never typed again, like a task of the journal.
    if let Ok(db) = w.history.db() {
        let _ = db.execute(
            "UPDATE bot_outbox SET state='typed',typed_ms=coalesce(typed_ms,?1),detail='The workspace restarted while this was being typed.' WHERE state='typing'",
            [now()],
        );
    }
    let clock = w.clone();
    tokio::spawn(async move {
        loop {
            let _ = tokio::time::timeout(TICK, WAKE.notified()).await;
            if super::any(&clock.history) {
                tick(&clock).await;
            }
        }
    });
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(WATCH);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut seen = Seen::default();
        loop {
            tick.tick().await;
            if super::any(&w.history) {
                watch(&w, &mut seen).await;
            }
        }
    });
}

/// One look: replies, clocks, then the outbox.
async fn tick(w: &Workspace) {
    let _ = read_replies(w);
    let _ = super::write(&w.history, |ctx| {
        rules::expire(ctx)?;
        rules::give_up(ctx)?;
        plans::fire_due(ctx)?;
        plans::unanswered(ctx)?;
        plans::raise_due(ctx)?;
        plans::note_main(ctx)?;
        Ok(())
    });
    drain(w);
}

/// Reads the replies saved since the last look. An agent's hook saves a reply straight into the journal, also
/// while the workspace is stopped, so they are found by their place in the journal and none is read twice.
fn read_replies(w: &Workspace) -> Result<(), crate::history::StoreError> {
    let behind: bool = w.history.db()?.query_row(
        "SELECT coalesce((SELECT max(id) FROM journal),0) >
                coalesce((SELECT CAST(value AS INTEGER) FROM bot_state WHERE key='reply_cursor'),0)",
        [],
        |row| row.get(0),
    )?;
    if !behind {
        return Ok(());
    }
    super::write(&w.history, |ctx| {
        let cursor: i64 = ctx
            .db
            .query_row(
                "SELECT CAST(value AS INTEGER) FROM bot_state WHERE key='reply_cursor'",
                [],
                |row| row.get(0),
            )
            .optional()?
            .unwrap_or(0);
        let replies: Vec<(i64, String, String)> = ctx
            .db
            .prepare_cached(
                "SELECT id,reply_for,text FROM journal
                 WHERE id>?1 AND kind='reply' AND reply_for IS NOT NULL AND answers_task IS NULL
                 ORDER BY id LIMIT 50",
            )?
            .query_map([cursor], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?
            .collect::<Result<_, _>>()?;
        for (id, key, text) in &replies {
            if let Who::Bot(bot) = super::of_launch(ctx.db, key)? {
                rules::on_reply(ctx, &bot, key, *id, text)?;
            }
        }
        // A full page may have more behind it; otherwise everything in the journal has been seen.
        let seen: i64 = if replies.len() == 50 {
            replies.last().map_or(cursor, |reply| reply.0)
        } else {
            ctx.db
                .query_row("SELECT coalesce(max(id),0) FROM journal", [], |row| {
                    row.get(0)
                })?
        };
        ctx.db.execute(
            "INSERT INTO bot_state (key,value) VALUES ('reply_cursor',?1)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            [seen.to_string()],
        )?;
        Ok(())
    })
}

struct Waiting {
    id: i64,
    bot: String,
    text: String,
}

/// Starts typing the oldest waiting message of every bot that has none on its way.
fn drain(w: &Workspace) {
    let Ok(db) = w.history.db() else {
        return;
    };
    let waiting: Vec<Waiting> = db
        .prepare_cached(
            "SELECT id,bot,text FROM bot_outbox WHERE state='pending' ORDER BY id LIMIT 200",
        )
        .and_then(|mut rows| {
            rows.query_map([], |row| {
                Ok(Waiting {
                    id: row.get(0)?,
                    bot: row.get(1)?,
                    text: row.get(2)?,
                })
            })?
            .collect()
        })
        .unwrap_or_default();
    drop(db);
    for item in waiting {
        let free = BUSY
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(item.bot.clone());
        if !free {
            continue;
        }
        let w = w.clone();
        tokio::spawn(async move {
            let bot = item.bot.clone();
            let outcome = deliver(&w, &item).await;
            if let Outcome::Failed(why) = &outcome {
                let _ = super::write(&w.history, |ctx| rules::untyped(ctx, item.id, why));
            }
            BUSY.lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .remove(&bot);
            // What the typing changed, and the next message for this bot, are looked at right away.
            if !matches!(outcome, Outcome::Later) {
                kick();
            }
        });
    }
}

enum Outcome {
    Typed,
    /// Not now: the agent shows a prompt, or Core is away. The row stays, and its own time limit ends the wait.
    Later,
    Failed(String),
}

fn explain(error: ApiError) -> String {
    match error {
        ApiError::Core(failure) => crate::helpers::explain(failure),
        ApiError::Conflict(why) | ApiError::TooMany(why) | ApiError::PayloadTooLarge(why) => {
            why.to_owned()
        }
        _ => "its agent could not be started.".to_owned(),
    }
}

/// Where the running agent of `bot` is among Core's terminals: one this workspace started, under the bot's name.
fn agent_of(w: &Workspace, core_id: &str, agents: &[Terminal], bot: &Bot) -> Option<usize> {
    let db = w.history.db().ok()?;
    agents.iter().position(|agent| {
        agent.require_live().is_ok() && agent.launch_key().is_some_and(|key| {
            let here: bool = db
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM journal WHERE launch_key=?1 AND core_id=?2)",
                    params![key, core_id],
                    |row| row.get(0),
                )
                .unwrap_or(false);
            here && matches!(super::of_launch(&db, key), Ok(Who::Bot(found)) if found.id == bot.id)
        })
    })
}

/// Starts the agent of `bot` ahead of its first task, as the app does when a chat opens: the same name, its
/// saved profile, the registered template, model, instructions and projects.
async fn start(w: &Workspace, bot: &Bot) -> Result<Terminal, String> {
    let templates = w.core.templates().await.map_err(crate::helpers::explain)?;
    let usable = |template: &&crate::core::Template| {
        template.error.is_none() && crate::core::valid_name(&template.name)
    };
    let template = if bot.template.is_empty() {
        templates.iter().find(usable)
    } else {
        templates
            .iter()
            .filter(usable)
            .find(|template| template.name == bot.template)
    }
    .ok_or_else(|| {
        format!(
            "Herdr has no template {:?} to start its agent from.",
            bot.template
        )
    })?;
    let catalog = crate::runtimes::Catalog::load(w.history.file());
    // A bot with no model of its own starts on the first one the server lists, as in the app.
    let model_id = match catalog.models(template) {
        Some(_) if !bot.model.is_empty() => Some(bot.model.clone()),
        Some((_, offered)) => offered.first().map(|model| model.id.clone()),
        None => None,
    };
    let (profile, name, projects) = {
        let db = w.history.db().map_err(|_| STORAGE)?;
        let profiles: Vec<(i64, String)> = db
            .prepare_cached("SELECT id,runtime_name FROM profiles ORDER BY id DESC")
            .and_then(|mut rows| {
                rows.query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
                    .collect()
            })
            .map_err(|_| STORAGE)?;
        let known = profiles
            .iter()
            .find(|(_, name)| *name == bot.agent_name)
            .or_else(|| {
                profiles.iter().find(|(_, name)| {
                    name.contains('-') && super::suffix(name) == super::suffix(&bot.agent_name)
                })
            })
            .cloned();
        // A project that was removed since the app registered the bot is left out, not a reason to fail.
        let projects: Vec<i64> = bot
            .projects
            .iter()
            .copied()
            .filter(|id| {
                db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM projects WHERE id=?1)",
                    [id],
                    |row| row.get(0),
                )
                .unwrap_or(false)
            })
            .collect();
        match known {
            Some((id, name)) => (Some(id), name, projects),
            None => (None, bot.agent_name.clone(), projects),
        }
    };
    let launch = crate::Launch {
        name,
        template: template.name.clone(),
        task: String::new(),
        warm: true,
        profile_id: profile,
        expected_runtime: None,
        model_choice: None,
        model_id,
        standing_instructions: None,
        instructions_revision: None,
        collect_results: false,
        projects,
    };
    let instructions = crate::profiles::validate_instructions(&bot.instructions)
        .map(str::to_owned)
        .unwrap_or_default();
    crate::launch_agent(w.clone(), launch, Some(instructions))
        .await
        .map(|created| created.terminal)
        .map_err(explain)
}

/// Whether the session of this launch has had no task yet and was started without instructions.
fn uninstructed(history: &crate::history::History, key: &str) -> bool {
    history.db().is_ok_and(|db| {
        matches!(rules::newest_task(&db, key, None), Ok(None))
            && db
                .query_row(
                    "SELECT NOT EXISTS(SELECT 1 FROM journal j
                                       LEFT JOIN warm_launches w ON w.launch=j.id
                                       WHERE j.launch_key=?1
                                         AND (coalesce(w.instructions,'')!='' OR j.launch_instructions IS NOT NULL))",
                    [key],
                    |row| row.get(0),
                )
                .unwrap_or(false)
    })
}

/// Types one waiting message into its bot's agent, starting the agent when none runs.
async fn deliver(w: &Workspace, item: &Waiting) -> Outcome {
    let bot = match w.history.db().map(|db| super::one(&db, &item.bot)) {
        Ok(Ok(Some(bot))) => bot,
        Ok(Ok(None)) => return Outcome::Failed("the bot was removed.".into()),
        _ => return Outcome::Later,
    };
    let (Ok(hello), Ok(mut agents)) = (w.core.identify().await, w.core.agents().await) else {
        return Outcome::Later;
    };
    let agent = match agent_of(w, &hello.core.id, &agents, &bot) {
        Some(index) => agents.swap_remove(index),
        None => match start(w, &bot).await {
            Ok(agent) => agent,
            // Another start of the same bot is on its way (the app opened its chat): look again shortly.
            Err(why)
                if why.contains("already starting") || why.contains("End the running session") =>
            {
                return Outcome::Later;
            }
            Err(why) => return Outcome::Failed(format!("its agent could not be started: {why}")),
        },
    };
    // An agent at a prompt would take the text for the prompt's answer.
    if agent
        .status
        .as_ref()
        .is_some_and(|status| status.state == "blocked")
    {
        return Outcome::Later;
    }
    let key = agent.launch_key().unwrap_or_default().to_owned();
    // An agent that started before its bot was registered has not read the notes: they go in front, once.
    let unread = bot.noted_launch.as_deref() != Some(key.as_str());
    let mut text = if unread {
        let others = w
            .history
            .db()
            .ok()
            .and_then(|db| super::all(&db).ok())
            .unwrap_or_default();
        format!(
            "{}\n\n{}",
            notes::standing(&bot, &others, &super::command()),
            item.text
        )
    } else {
        item.text.clone()
    };
    // An agent the app started ahead of its first message has read nothing yet: the app sends a bot's
    // instructions with the person's first message. When the workspace is first to write, it sends them.
    if !bot.instructions.is_empty() && uninstructed(&w.history, &key) {
        text = notes::instructed(&bot.instructions, &text);
    }
    if crate::core::validate_task(&text).is_err() {
        return Outcome::Failed("it does not fit into one task.".into());
    }
    let Ok((record, _)) = w
        .history
        .start_task(&hello.core.id, &agent, &text, None, false, &[])
    else {
        return Outcome::Later;
    };
    let claimed = w.history.db().is_ok_and(|db| {
        db.execute(
            "UPDATE bot_outbox SET state='typing',task=?2 WHERE id=?1 AND state='pending'",
            params![item.id, record],
        ) == Ok(1)
    });
    if !claimed {
        // It was dropped meanwhile (a stop): nothing is typed.
        let _ = w.history.finish(
            record,
            crate::history::State::NotSent,
            Some("The exchange this belonged to was ended."),
            None,
        );
        return Outcome::Typed;
    }
    match crate::deliver_task_waiting(w.clone(), agent, record, text, warm::Wait::Queued).await {
        Ok(_) => {
            let _ = super::write(&w.history, |ctx| rules::typed(ctx, item.id));
            if unread {
                let _ = super::noted(&w.history, &bot.id, &key);
            }
            Outcome::Typed
        }
        Err(error) => Outcome::Failed(crate::helpers::explain(error)),
    }
}

/// What the watch has seen before, to tell something new from something that lasts.
#[derive(Default)]
struct Seen {
    /// When each agent was first seen at a prompt, by launch key.
    blocked: BTreeMap<String, i64>,
    /// How many looks in a row each project server could not be reached.
    unreachable: BTreeMap<String, u32>,
    round: u32,
}

/// Notes what the main bot is told about.
async fn watch(w: &Workspace, seen: &mut Seen) {
    seen.round = seen.round.wrapping_add(1);
    let (Ok(hello), Ok(agents)) = (w.core.identify().await, w.core.agents().await) else {
        return;
    };
    let at = now();
    let mut flags: Vec<(&str, String, String)> = Vec::new();
    {
        let Ok(db) = w.history.db() else {
            return;
        };
        // Whose agent this is: a bot's own, or a helper of a bot's agent.
        let owner = |key: &str| -> Option<(String, bool)> {
            match super::of_launch(&db, key).ok()? {
                Who::Bot(bot) => (!bot.main).then_some((bot.name.clone(), false)),
                Who::Helper => {
                    let parent: String = db
                        .query_row(
                            "SELECT h.parent_key FROM helpers h JOIN journal j ON j.id=h.launch WHERE j.launch_key=?1",
                            [key],
                            |row| row.get(0),
                        )
                        .ok()?;
                    match super::of_launch(&db, &parent).ok()? {
                        Who::Bot(bot) => Some((bot.name.clone(), true)),
                        _ => None,
                    }
                }
                Who::Nobody => None,
            }
        };
        let mut still = BTreeSet::new();
        for agent in &agents {
            let Some(key) = agent.launch_key().filter(|_| agent.require_live().is_ok()) else {
                continue;
            };
            if agent
                .status
                .as_ref()
                .is_none_or(|status| status.state != "blocked")
            {
                continue;
            }
            still.insert(key.to_owned());
            let since = *seen.blocked.entry(key.to_owned()).or_insert(at);
            if at - since < BLOCKED_MS {
                continue;
            }
            if let Some((bot, helper)) = owner(key) {
                flags.push((
                    "blocked",
                    format!("blocked:{key}:{}", agent.turn()),
                    format!(
                        "{} {} is waiting at a prompt in its terminal ({}) and cannot go on by itself. A person has to answer the prompt.",
                        if helper { "A helper of the bot" } else { "The agent of the bot" },
                        notes::line(&bot),
                        agent.address
                    ),
                ));
            }
        }
        seen.blocked.retain(|key, _| still.contains(key));

        // Helpers that have ended since the last look, with no reply after their latest task.
        let cursor: i64 = db
            .query_row(
                "SELECT CAST(value AS INTEGER) FROM bot_state WHERE key='helper_cursor'",
                [],
                |row| row.get(0),
            )
            .unwrap_or(i64::MAX);
        let helpers: Vec<(i64, String, String, String, String, String, bool)> = db
            .prepare_cached(
                "SELECT h.launch,h.name,h.parent_key,j.launch_key,j.text,
                        CASE WHEN j.address IS NULL AND j.state='not_sent' THEN 'never_ran' ELSE j.state END,
                        EXISTS(SELECT 1 FROM journal r WHERE r.reply_for=j.launch_key AND r.kind='reply'
                               AND r.id>(SELECT coalesce(max(t.id),j.id) FROM journal t
                                         WHERE t.kind='task' AND t.core_id=j.core_id AND t.address=j.address
                                           AND t.created_ms=j.created_ms))
                 FROM helpers h JOIN journal j ON j.id=h.launch
                 WHERE h.launch>?1 AND j.core_id=?2 ORDER BY h.launch LIMIT 200",
            )
            .and_then(|mut rows| {
                rows.query_map(params![cursor, hello.core.id], |row| {
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
                .collect()
            })
            .unwrap_or_default();
        let mut passed = cursor;
        let mut unbroken = true;
        for (launch, name, parent, key, task, state, answered) in helpers {
            let runs = state == "pending"
                || agents.iter().any(|agent| {
                    agent.launch_key() == Some(key.as_str()) && agent.require_live().is_ok()
                });
            if runs {
                // It may still answer: everything from here on is looked at again.
                unbroken = false;
                continue;
            }
            if unbroken {
                passed = launch;
            }
            // One that never got a terminal never ran, and the agent that asked for it was told so then.
            if answered || state == "never_ran" {
                continue;
            }
            if let Ok(Who::Bot(bot)) = super::of_launch(&db, &parent) {
                flags.push((
                    "helper",
                    format!("helper:{launch}"),
                    format!(
                        "The helper {name} of the bot {} stopped without an answer to its task: \"{}\".",
                        notes::line(&bot.name),
                        plans::one_line(&task, 200)
                    ),
                ));
            }
        }
        if passed != cursor && cursor != i64::MAX {
            let _ = db.execute(
                "UPDATE bot_state SET value=?1 WHERE key='helper_cursor'",
                [passed.to_string()],
            );
        }
    }

    // Project servers, every third look.
    if seen.round.is_multiple_of(3) {
        let with_projects = crate::projects::names_by_machine(&w.history).unwrap_or_default();
        if !with_projects.is_empty()
            && let Ok(machines) = w.core.machines().await
        {
            let mut down = BTreeSet::new();
            for machine in machines {
                let Some(projects) = with_projects.get(&machine.name) else {
                    continue;
                };
                if !matches!(
                    machine.state.as_str(),
                    "unreachable" | "needs_login" | "needs_update"
                ) {
                    continue;
                }
                down.insert(machine.name.clone());
                let looks = seen.unreachable.entry(machine.name.clone()).or_insert(0);
                *looks += 1;
                if *looks == 2 {
                    flags.push((
                        "machine",
                        format!("machine:{}:{}", machine.name, machine.since_ms.unwrap_or(0)),
                        format!(
                            "The project server {} cannot be reached ({}{}). Projects on it: {}.",
                            machine.name,
                            machine.state.replace('_', " "),
                            machine
                                .why
                                .as_deref()
                                .map_or_else(String::new, |why| format!(
                                    ": {}",
                                    plans::one_line(why, 120)
                                )),
                            projects.join(", ")
                        ),
                    ));
                }
            }
            seen.unreachable.retain(|name, _| down.contains(name));
        }
    }
    if flags.is_empty() {
        return;
    }
    let _ = super::write(&w.history, |ctx| {
        for (kind, key, text) in &flags {
            plans::flag(ctx, kind, key, text)?;
        }
        Ok(())
    });
    kick();
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::{Settings, plans::When, testing};

    #[test]
    fn only_an_agent_that_has_read_nothing_yet_is_sent_its_bots_instructions() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        // Started with a task of the person: the app sent the instructions with it.
        let tasked = testing::session(&history, "Jarvis", "t7");
        assert!(!uninstructed(&history, &tasked));
        // Started ahead of its first message, with nothing: whoever writes first sends them.
        let (_, warm) = crate::warm::start(&history, "core", "jarvis-jarvis", None, "{}", "", &[])
            .unwrap()
            .unwrap();
        assert!(uninstructed(&history, &warm));
        // Started by the workspace itself, which gave the instructions to go with the first task.
        let (_, own) = crate::warm::start(
            &history,
            "core",
            "jarvis-jarvis",
            None,
            "{}",
            "Be brief.",
            &[],
        )
        .unwrap()
        .unwrap();
        assert!(!uninstructed(&history, &own));
        assert_eq!(
            notes::instructed(
                "Be brief.",
                "[Message from the bot Infra, passed on by SwarmHub] ask #1\nHi"
            ),
            "Standing instructions for this whole conversation:\nBe brief.\n\n[Message from the bot Infra, passed on by SwarmHub] ask #1\nHi"
        );
    }

    #[test]
    fn a_helper_and_an_agent_of_no_bot_are_refused_and_a_bot_runs_every_command() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra"]);
        let (jarvis, infra) = (
            testing::session(&history, "Jarvis", "t7"),
            testing::session(&history, "Infra", "t8"),
        );
        let (_, stranger) = history
            .start_launch("core", "stranger-123456", "Hi", None, "{}", "")
            .unwrap()
            .unwrap();
        {
            let db = history.db().unwrap();
            db.execute(
                "INSERT INTO journal (launch_key,core_id,agent,kind,state,text,at_ms) VALUES ('helperkey','core','easy-1-t7','task','sent','Count',1)",
                [],
            )
            .unwrap();
            db.execute(
                "INSERT INTO helpers (launch,parent_key,name,difficulty,template,model)
                 SELECT id,?1,'easy-1','easy','fixture','small' FROM journal WHERE launch_key='helperkey'",
                [&jarvis],
            )
            .unwrap();
        }
        let set = Settings {
            timezone: "UTC".into(),
            ..Settings::default()
        };
        let run = |key: &str, ask: Ask| {
            testing::at(&history, 1_794_830_400_000, &set, |ctx| {
                perform(ctx, key, ask)
            })
        };
        let send = |kind: &str| Ask::Send {
            kind: kind.into(),
            to: "Infra".into(),
            text: "Hello".into(),
        };
        // A helper talks only to the agent that started it: every command is refused, and nothing is written.
        for ask in [
            send("ask"),
            Ask::List,
            Ask::Reply {
                id: 1,
                text: "x".into(),
            },
            Ask::Checkin {
                when: When::In { seconds: 600 },
                what: "x".into(),
            },
            Ask::Promise {
                by: When::In { seconds: 600 },
                what: "x".into(),
            },
        ] {
            assert_eq!(run("helperkey", ask), Err(HELPER.to_owned()));
        }
        assert_eq!(run(&stranger, send("ask")), Err(UNKNOWN_BOT.to_owned()));
        assert_eq!(
            run("no-such-launch", Ask::List),
            Err(UNKNOWN_BOT.to_owned())
        );
        let rows: i64 = history
            .db()
            .unwrap()
            .query_row(
                "SELECT (SELECT count(*) FROM bot_messages)+(SELECT count(*) FROM bot_checkins)+(SELECT count(*) FROM bot_promises)",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(rows, 0);

        // A bot's own agent: the three kinds, and the three ways to close.
        assert!(
            run(&jarvis, send("ask"))
                .unwrap()
                .starts_with("Sent ask #1 to \"Infra\".")
        );
        assert!(
            run(&jarvis, send("tell"))
                .unwrap()
                .starts_with("Sent tell #2 to \"Infra\".")
        );
        assert!(
            run(&jarvis, send("handoff"))
                .unwrap()
                .starts_with("Sent hand-off #3 to \"Infra\".")
        );
        assert!(run(&jarvis, send("shout")).is_err());
        assert!(
            run(
                &infra,
                Ask::Reply {
                    id: 1,
                    text: "5432".into()
                }
            )
            .unwrap()
            .contains("Answered ask #1")
        );
        assert!(
            run(&infra, Ask::Accept { id: 3 })
                .unwrap()
                .contains("the work is yours now")
        );
        assert!(
            run(
                &infra,
                Ask::Decline {
                    id: 3,
                    reason: "After all, no.".into()
                }
            )
            .unwrap()
            .contains("Declined hand-off #3")
        );
        assert!(
            run(&infra, Ask::List)
                .unwrap()
                .contains("\"Jarvis\" (the main bot)")
        );
        // The message started with the person: the session's newest task is theirs.
        let origin: String = history
            .db()
            .unwrap()
            .query_row("SELECT origin FROM bot_work WHERE id=1", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(origin, "person");

        let planned = run(
            &jarvis,
            Ask::Checkin {
                when: When::In { seconds: 1_800 },
                what: "Check the deploy.".into(),
            },
        )
        .unwrap();
        assert!(
            planned
                .starts_with("Planned check-in #1: once, on 16 Nov 12:30, next on 16 Nov 12:30."),
            "{planned}"
        );
        assert!(planned.contains("what you find then is shown to the person"));
        let recurring = run(
            &jarvis,
            Ask::Checkin {
                when: When::Daily {
                    hour: 9,
                    minute: 0,
                    weekdays: true,
                },
                what: "Read the alerts.".into(),
            },
        )
        .unwrap();
        assert!(
            recurring.starts_with(
                "Planned check-in #2: every weekday at 09:00 (UTC), next on 17 Nov 09:00."
            ),
            "{recurring}"
        );
        assert!(
            run(&jarvis, Ask::Checkins)
                .unwrap()
                .contains("#1 · once, on 16 Nov 12:30")
        );
        assert_eq!(
            run(&infra, Ask::CancelCheckin { id: 1 }).unwrap_err(),
            "You have no planned check-in #1. See yours with: swarmhub-herdr checkin list"
        );
        assert_eq!(
            run(&jarvis, Ask::CancelCheckin { id: 1 }).unwrap(),
            "Cancelled check-in #1."
        );
        let promised = run(
            &jarvis,
            Ask::Promise {
                by: When::At {
                    hour: 17,
                    minute: 30,
                },
                what: "Send the report.".into(),
            },
        )
        .unwrap();
        assert!(
            promised.starts_with("Recorded promise #1, due 16 Nov 17:30."),
            "{promised}"
        );
        assert!(
            run(&jarvis, Ask::Promises)
                .unwrap()
                .contains("#1 · by 16 Nov 17:30 · Send the report.")
        );
        assert!(run(&infra, Ask::PromiseDone { id: 1, note: None }).is_err());
        assert_eq!(
            run(
                &jarvis,
                Ask::PromiseDone {
                    id: 1,
                    note: Some("Sent.".into())
                }
            )
            .unwrap(),
            "Closed promise #1."
        );
        assert_eq!(
            run(&jarvis, Ask::Promises).unwrap(),
            "You have no open promises."
        );
    }
}
