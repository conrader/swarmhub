//! An agent started before its first task, so that the first message goes to a running agent.
//!
//! `POST /api/agents` with `"warm": true` and no `task` starts the template's program and types nothing. The
//! launch is recorded like any other (profile, model, projects, results folder, labels), so the session has its
//! history, its event stream and its place in `/api/workspace` from the start. Its launch row holds no text and
//! stays out of the conversation until the first message arrives, which then becomes that row.
//!
//! What a launch with a task would have typed around the task (standing instructions, the notes about results and
//! projects) is kept here and goes with the first task that reaches the agent, by whichever route: a message, a
//! group task, a routine.
//!
//! Until the program has reported its status once, the agent is not ready: Core would type into whatever it is
//! showing. A task sent before that waits here and is typed when the agent is ready. A message is accepted at
//! once and typed later (`queued`); a group task or a routine holds its caller. Either is given up with the kind
//! `not_ready` if the program has not reported in time. An agent that is never written to is ended after
//! `SWARMHUB_WARM_IDLE_MINUTES`.

use crate::{
    Workspace,
    core::{self, Delivery, Failure, Terminal},
    history::{History, StoreError, now},
};
use rusqlite::{OptionalExtension, Transaction, params};
use serde::Serialize;
use std::{collections::BTreeMap, sync::Arc, time::Duration};
use tokio::time::{Instant, sleep};

/// The note a launch that collects results gives its agent.
pub(crate) const RESULTS_HINT: &str = "To share a finished file, move it into the folder named by the SWARMHUB_RESULTS environment variable after writing it. SwarmHub will add it to this conversation.";
/// Rows of agents that wait for their first message: left out wherever a conversation is listed.
pub(crate) const SHOWN: &str =
    "journal.id NOT IN (SELECT launch FROM warm_launches WHERE first_task_ms IS NULL)";
/// What a refused task says its reason is, in `kind`.
pub(crate) const NOT_READY: &str = "not_ready";

/// How long after its start a warm agent may take to report, in seconds: `SWARMHUB_WARM_START_WAIT`, within
/// these bounds. A queued message waits that long at most. On a server whose disk is busy, Codex has taken
/// more than three minutes to report; Core gives a launch's first task 60 seconds.
const START_WAIT: &str = "SWARMHUB_WARM_START_WAIT";
const START_WAIT_SECONDS: u64 = 300;
const START_WAIT_BOUNDS: std::ops::RangeInclusive<u64> = 30..=1800;
/// A caller that is held meanwhile (a group task, a routine) waits no longer than this after the agent's start.
const HELD_WAIT: Duration = Duration::from_secs(75);

/// Who waits for a warm agent to be ready.
#[derive(Clone, Copy, PartialEq, Debug)]
pub(crate) enum Wait {
    /// The caller, which is answered once the task is typed.
    Held,
    /// Nobody: the caller was told that the task is queued.
    Queued,
    Outbox { id: i64, task: i64 },
}
impl Wait {
    pub(crate) fn check_outbox(self, history: &History) -> Result<(), Failure> {
        if let Self::Outbox { id, task } = self {
            let ready = history.db().is_ok_and(|db| {
                db.query_row(
                    "SELECT EXISTS(SELECT 1 FROM bot_outbox o JOIN bots b ON b.id=o.bot
                     WHERE o.id=?1 AND o.task=?2 AND o.state='typing' AND o.give_up_ms>?3
                       AND b.removed_ms IS NULL AND b.takes_messages
                       AND (o.cause='outcome' OR NOT EXISTS (
                           SELECT 1 FROM bot_work WHERE id=o.work AND state='stopped')))",
                    params![id, task, now()],
                    |row| row.get::<_, bool>(0),
                ).unwrap_or(false)
            });
            if !ready {
                return Err(Failure::Input("The pending delivery is no longer available."));
            }
        }
        Ok(())
    }
}
/// After how many minutes without any task a warm agent is ended: `SWARMHUB_WARM_IDLE_MINUTES`. `0` keeps it.
const IDLE: &str = "SWARMHUB_WARM_IDLE_MINUTES";
const IDLE_MINUTES: u64 = 30;
const IDLE_MOST: u64 = 7 * 24 * 60;
const SWEEP: Duration = Duration::from_secs(60);
const LOOK: Duration = Duration::from_millis(200);
/// Core's answer while a young program's screen is still changing. Nothing was typed.
const SETTLING: &str = "is still starting: its output has not settled";

/// One warm delivery or one sweep per launch at a time: two first tasks must not both carry the instructions,
/// and an agent must not be ended while its first task is on the way.
static GATES: std::sync::Mutex<BTreeMap<String, Arc<tokio::sync::Mutex<()>>>> =
    std::sync::Mutex::new(BTreeMap::new());

fn gate(key: &str) -> Arc<tokio::sync::Mutex<()>> {
    let mut gates = GATES
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    if gates.len() >= 256 {
        gates.retain(|_, gate| Arc::strong_count(gate) > 1);
    }
    gates.entry(key.to_owned()).or_default().clone()
}

fn start_wait(asked: Option<&str>, wait: Wait) -> Duration {
    let seconds = asked
        .and_then(|seconds| seconds.trim().parse::<u64>().ok())
        .map_or(START_WAIT_SECONDS, |seconds| {
            seconds.clamp(*START_WAIT_BOUNDS.start(), *START_WAIT_BOUNDS.end())
        });
    match wait {
        Wait::Queued | Wait::Outbox { .. } => Duration::from_secs(seconds),
        Wait::Held => HELD_WAIT.min(Duration::from_secs(seconds)),
    }
}

/// The idle limit in milliseconds, or `None` when warm agents are kept.
fn idle_limit(asked: Option<&str>) -> Option<i64> {
    let minutes = asked
        .and_then(|minutes| minutes.trim().parse::<u64>().ok())
        .map_or(IDLE_MINUTES, |minutes| minutes.min(IDLE_MOST));
    (minutes > 0).then_some((minutes * 60_000) as i64)
}

fn idle_limit_now() -> Option<i64> {
    idle_limit(std::env::var(IDLE).ok().as_deref())
}

/// A hint that starts like this is a note of several lines (`bots`): it goes after everything else, on lines of
/// its own, and is left out of a first task that has no room for it.
pub(crate) const NOTE_LEAD: &str = "[SwarmHub notes";

/// The first task as the agent reads it: the task, with the standing instructions and the workspace's notes.
pub(crate) fn first_message(
    task: &str,
    instructions: &str,
    hints: &[&str],
) -> Result<String, Failure> {
    let (notes, hints): (Vec<&str>, Vec<&str>) =
        hints.iter().partition(|hint| hint.starts_with(NOTE_LEAD));
    let plain = with_hints(task, instructions, &hints)?;
    if notes.is_empty() {
        return Ok(plain);
    }
    let noted = if instructions.is_empty() {
        let message = format!("{plain}\n\n{}", notes.join("\n\n"));
        core::validate_task(&message).map(|()| message)
    } else {
        let all: Vec<&str> = hints.iter().chain(&notes).copied().collect();
        crate::profiles::launch_message(task, &format!("{instructions}\n\n{}", all.join("\n\n")))
    };
    Ok(noted.unwrap_or(plain))
}

fn with_hints(task: &str, instructions: &str, hints: &[&str]) -> Result<String, Failure> {
    if hints.is_empty() {
        return crate::profiles::launch_message(task, instructions);
    }
    if instructions.is_empty() {
        let message = format!("{task} | {}", hints.join(" "));
        core::validate_task(&message).map_err(|_| {
            Failure::Input(if hints.contains(&RESULTS_HINT) {
                "Leave a little room in the first task for the results folder instructions."
            } else {
                "Leave a little room in the first task for the note about this agent's projects."
            })
        })?;
        return Ok(message);
    }
    crate::profiles::launch_message(task, &format!("{instructions}\n\n{}", hints.join("\n\n")))
}

/// Records a launch without a task. `None` when a session for this profile is already starting.
pub(crate) fn start(
    history: &History,
    core_id: &str,
    name: &str,
    profile: Option<i64>,
    runtime: &str,
    instructions: &str,
    hints: &[&str],
) -> Result<Option<(i64, String)>, StoreError> {
    let hints = serde_json::to_string(hints).map_err(|_| StoreError)?;
    let mut db = history.db()?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let at = now();
    let launch: Option<(i64, String)> = tx
        .query_row(
            "INSERT INTO journal (launch_key, core_id, agent, kind, state, text, at_ms, profile_id, launch_runtime, launch_instructions)
             SELECT lower(hex(randomblob(16))), ?1, ?2, 'task', 'pending', '', ?3, ?4, ?5, NULLIF(?6,'')
             WHERE ?4 IS NULL OR NOT EXISTS (
                SELECT 1 FROM journal WHERE profile_id=?4 AND core_id=?1 AND state='pending'
                   AND launch_key IS NOT NULL
             )
             RETURNING id, launch_key",
            params![core_id, name, at, profile, runtime, instructions],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    if let Some((id, _)) = &launch {
        tx.execute(
            "INSERT INTO warm_launches (launch, started_ms, instructions, hints) VALUES (?1, ?2, ?3, ?4)",
            params![id, at, instructions, hints],
        )?;
    }
    tx.commit()?;
    Ok(launch)
}

/// Makes a session's first message its launch row, as it would be had the agent started with it. `None` when
/// the session did not start warm, already has its first message, or has other rows by now (a reply to
/// something typed in its terminal): the message is then recorded as a row of its own.
pub(crate) fn take_first_task(
    tx: &Transaction<'_>,
    core_id: &str,
    agent: &Terminal,
    task: &str,
    at: i64,
) -> rusqlite::Result<Option<i64>> {
    let launch: Option<i64> = tx
        .query_row(
            "UPDATE journal SET text=?4, at_ms=?5, state='pending', detail=NULL
             WHERE id=(SELECT w.launch FROM warm_launches w JOIN journal j ON j.id=w.launch
                       WHERE j.core_id=?1 AND j.address=?2 AND j.created_ms=?3 AND w.first_task_ms IS NULL)
               AND state!='pending'
               AND NOT EXISTS (SELECT 1 FROM journal other
                               WHERE other.core_id=?1 AND other.address=?2 AND other.created_ms=?3
                                 AND other.id!=journal.id)
             RETURNING id",
            params![core_id, agent.address, agent.created_ms, task, at],
            |row| row.get(0),
        )
        .optional()?;
    if let Some(launch) = launch {
        tx.execute(
            "UPDATE warm_launches SET first_task_ms=?2 WHERE launch=?1",
            params![launch, at],
        )?;
    }
    Ok(launch)
}

/// What still has to go with the first task of the session with this launch key.
struct Waiting {
    launch: i64,
    instructions: String,
    hints: Vec<String>,
}

fn waiting(history: &History, key: &str) -> Result<Option<Waiting>, StoreError> {
    let found: Option<(i64, String, String)> = history
        .db()?
        .query_row(
            "SELECT w.launch, w.instructions, w.hints FROM warm_launches w JOIN journal j ON j.id=w.launch
             WHERE j.launch_key=?1 AND w.delivered_ms IS NULL",
            [key],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    Ok(found.map(|(launch, instructions, hints)| Waiting {
        launch,
        instructions,
        hints: serde_json::from_str(&hints).unwrap_or_default(),
    }))
}

fn mark(history: &History, launch: i64, column: &str) -> Result<(), StoreError> {
    history.db()?.execute(
        &format!("UPDATE warm_launches SET {column}=coalesce({column},?2) WHERE launch=?1"),
        params![launch, now()],
    )?;
    Ok(())
}

/// How far an agent's start has come, as `/api/workspace`, the event stream and the answer to a launch say it.
#[derive(Serialize, Default, Debug, PartialEq)]
pub(crate) struct Start {
    /// A task sent now is typed at once. `false` only for a warm agent whose program has not reported yet.
    ready: bool,
    /// Started without a task, and none has reached it yet.
    pub(crate) warm: bool,
    /// When the workspace ends this warm agent unless a task is sent first.
    #[serde(skip_serializing_if = "Option::is_none")]
    warm_ends_ms: Option<i64>,
}

impl Start {
    pub(crate) fn of(history: &History, terminal: &Terminal) -> Self {
        if terminal.require_live().is_err() {
            return Self::default();
        }
        let waits: Option<(i64, bool)> = terminal.launch_key().and_then(|key| {
            history
                .db()
                .ok()?
                .query_row(
                    "SELECT w.started_ms, w.tried_ms IS NULL FROM warm_launches w JOIN journal j ON j.id=w.launch
                     WHERE j.launch_key=?1 AND w.delivered_ms IS NULL",
                    [key],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()
                .ok()?
        });
        match waits {
            None => Self {
                ready: true,
                ..Self::default()
            },
            Some((started, untried)) => Self {
                ready: terminal.reported(),
                warm: true,
                warm_ends_ms: idle_limit_now()
                    .filter(|_| untried)
                    .map(|limit| started.saturating_add(limit)),
            },
        }
    }
}

fn not_ready() -> Failure {
    Failure::Rejected(
        NOT_READY.into(),
        "This agent is still starting and has not said that it is ready, so the task was not sent. Open its terminal: it may be waiting at a prompt.".into(),
    )
}

/// Whether a task for this agent would have to wait: it started warm, has had no task, and has not reported.
pub(crate) fn starting(history: &History, agent: &Terminal) -> bool {
    let start = Start::of(history, agent);
    start.warm && !start.ready
}

/// Waits until the agent's program has reported its status once, as Core does before a launch's first task.
async fn ready(w: &Workspace, agent: &Terminal, wait: Wait) -> Result<Terminal, Failure> {
    let wait = start_wait(std::env::var(START_WAIT).ok().as_deref(), wait);
    let age = Duration::from_millis((now().max(0) as u64).saturating_sub(agent.created_ms));
    let until = Instant::now() + wait.saturating_sub(age);
    loop {
        let current = w.core.agent(&agent.address, agent.created_ms).await?;
        if current.launch_key() != agent.launch_key() {
            return Err(Failure::Missing);
        }
        current.require_live()?;
        if current.reported() {
            return Ok(current);
        }
        if Instant::now() >= until {
            return Err(not_ready());
        }
        sleep(LOOK).await;
    }
}

/// Types a task into an agent that takes its tasks through its terminal. A warm agent's first task waits until
/// the agent is ready and carries what the launch kept for it; every other task goes straight to Core.
pub(crate) async fn send(
    w: &Workspace,
    agent: &Terminal,
    prompt: String,
    wait: Wait,
) -> Result<Delivery, Failure> {
    let Some(key) = agent.launch_key() else {
        return send_prompt(w, agent, prompt, None, wait).await;
    };
    let lookup =
        |_| Failure::Input("The workspace could not read this session. The task was not sent.");
    if waiting(&w.history, key).map_err(lookup)?.is_none() {
        return send_prompt(w, agent, prompt, None, wait).await;
    }
    let gate = gate(key);
    let _one = gate.lock().await;
    // Another task may have been the first while this one waited its turn.
    let Some(waiting) = waiting(&w.history, key).map_err(lookup)? else {
        return send_prompt(w, agent, prompt, None, wait).await;
    };
    core::validate_task(&prompt)?;
    let hints: Vec<&str> = waiting.hints.iter().map(String::as_str).collect();
    let prompt = first_message(&prompt, &waiting.instructions, &hints)?;
    let agent = ready(w, agent, wait).await?;
    // From here on the agent may have been written to, so it is never ended for being idle.
    mark(&w.history, waiting.launch, "tried_ms").map_err(lookup)?;
    send_prompt(w, &agent, prompt, Some(waiting.launch), wait).await
}

async fn send_prompt(
    w: &Workspace,
    agent: &Terminal,
    prompt: String,
    warm_launch: Option<i64>,
    wait: Wait,
) -> Result<Delivery, Failure> {
    let typed = crate::person_profile::prompt(&w.history, agent.display_name(), prompt.clone())?;
    let settling_until = warm_launch.map(|_| Instant::now() + Duration::from_secs(10));
    loop {
        wait.check_outbox(&w.history)?;
        match w.core.send(agent, &typed).await {
            Ok(sent) => {
                let outcome = if matches!(wait, Wait::Outbox { .. }) {
                    Ok(sent.delivery)
                } else { w.core.recover_send(agent, &typed, &prompt, sent).await };
                if let Some(launch) = warm_launch
                    && outcome.as_ref().is_ok_and(|delivery| delivery.started != Some(false))
                {
                    let _ = mark(&w.history, launch, "delivered_ms");
                }
                return outcome;
            }
            Err(Failure::Rejected(kind, message))
                if kind == "unavailable"
                    && message.ends_with(SETTLING)
                    && settling_until.is_some_and(|until| Instant::now() < until) =>
            {
                sleep(LOOK).await;
            }
            // Not typed, or not known to be: the next task carries the instructions again.
            Err(error) => return Err(error),
        }
    }
}

/// Sends a guarded completion, with the same first-message envelope used for a warm launch.
pub(crate) async fn send_completion(
    w: &Workspace, core: &str, agent: &Terminal, key: &str, prompt: String,
) -> Result<Delivery, Failure> {
    let gate = gate(key);
    let _one = gate.lock().await;
    let lookup = |_| Failure::Input("The workspace could not read this session. The task was not sent.");
    let waiting = waiting(&w.history, key).map_err(lookup)?;
    let prompt = if let Some(waiting) = &waiting {
        let hints: Vec<&str> = waiting.hints.iter().map(String::as_str).collect();
        let text = first_message(&prompt, &waiting.instructions, &hints)?;
        let ended: bool = w.history.db().and_then(|db| Ok(db.query_row(
            "SELECT ended_ms IS NOT NULL FROM warm_launches WHERE launch=?1",
            [waiting.launch], |row| row.get(0),
        )?)).map_err(lookup)?;
        if ended {
            return Err(Failure::Missing);
        }
        mark(&w.history, waiting.launch, "tried_ms").map_err(lookup)?;
        text
    } else {
        prompt
    };
    let prompt = crate::person_profile::prompt(&w.history, agent.display_name(), prompt)?;
    let delivery = w.core.send_completion(core, agent, prompt).await?;
    if let Some(waiting) = waiting
        && delivery.started != Some(false)
    {
        let _ = mark(&w.history, waiting.launch, "delivered_ms");
    }
    Ok(delivery)
}

/// Ends warm agents nobody wrote to within the idle limit.
pub(crate) fn start_sweeping(w: Workspace) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(SWEEP);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            if let Some(limit) = idle_limit_now() {
                let _ = end_idle(&w, limit).await;
            }
        }
    });
}

struct Idle {
    launch: i64,
    key: String,
    core: String,
    address: String,
    created: u64,
}

/// Warm launches that started before `before` and that nothing was typed into through the workspace, and no
/// reply was saved for.
fn idle(history: &History, before: i64) -> Result<Vec<Idle>, StoreError> {
    let db = history.db()?;
    let mut rows = db.prepare(
        "SELECT w.launch, j.launch_key, j.core_id, j.address, j.created_ms
         FROM warm_launches w JOIN journal j ON j.id=w.launch
         WHERE w.tried_ms IS NULL AND w.delivered_ms IS NULL AND w.ended_ms IS NULL AND w.first_task_ms IS NULL
           AND w.started_ms<?1 AND j.address IS NOT NULL AND j.created_ms IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM routine_transfers t JOIN routines r ON r.id=t.routine
               WHERE r.core=j.core_id AND r.address=j.address AND r.created_ms=j.created_ms
               AND (t.phase IN ('held','staged','suspended') OR r.state!='archived'))
           AND NOT EXISTS (SELECT 1 FROM journal reply WHERE reply.reply_for=j.launch_key)
         ORDER BY w.launch LIMIT 64",
    )?;
    Ok(rows
        .query_map([before], |row| {
            Ok(Idle {
                launch: row.get(0)?,
                key: row.get(1)?,
                core: row.get(2)?,
                address: row.get(3)?,
                created: row.get(4)?,
            })
        })?
        .collect::<Result<_, _>>()?)
}

/// Whether the program is as it started: no turn has begun in it, by whatever route. Starting counts as a
/// turn for some programs (Codex reports `working` while it loads), so one finished turn is allowed. A turn
/// someone typed in the terminal is the second, and its saved reply rules the agent out besides (`idle`).
fn untouched(agent: &Terminal) -> bool {
    agent.turn() <= 1
        && agent
            .status
            .as_ref()
            .is_none_or(|status| !matches!(status.state.as_str(), "working" | "blocked"))
}

async fn end_idle(w: &Workspace, limit: i64) -> Result<(), Failure> {
    let lookup = |_| Failure::Uncertain;
    if idle(&w.history, now() - limit).map_err(lookup)?.is_empty() {
        return Ok(());
    }
    // Asked only when there is something to end: an idle workspace does not call Core every minute.
    let hello = w.core.identify().await?;
    for launch in idle(&w.history, now() - limit).map_err(lookup)? {
        // An agent on another Core cannot be asked about here. It is left alone.
        if launch.core != hello.core.id {
            continue;
        }
        let gate = gate(&launch.key);
        let _one = gate.lock().await;
        // A first task may have set out while this sweep waited for its turn.
        if !idle(&w.history, now() - limit)
            .map_err(lookup)?
            .iter()
            .any(|still| still.launch == launch.launch)
        {
            continue;
        }
        let column = match w.core.agent(&launch.address, launch.created).await {
            Ok(agent)
                if agent.launch_key() == Some(launch.key.as_str())
                    && agent.require_live().is_ok() =>
            {
                if !untouched(&agent) {
                    // Someone used its terminal: it has had a task, so it stays.
                    "tried_ms"
                } else if w.core.end(&agent).await.is_ok() {
                    "ended_ms"
                } else {
                    continue;
                }
            }
            // It ended on its own, or Core no longer has it.
            Ok(_) | Err(Failure::Missing) => "ended_ms",
            Err(Failure::Rejected(kind, _)) if kind == "not_found" => "ended_ms",
            // Core is busy or away: ask again at the next sweep.
            Err(_) => continue,
        };
        mark(&w.history, launch.launch, column).map_err(lookup)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    const INSTRUCTIONS: &str = "Answer in one line.";
    const PROJECTS: &str = "You may work on these projects on other machines: site (on web).";

    #[test]
    fn a_retry_checks_its_own_attempt_and_can_deliver_a_stopped_exchanges_outcome() {
        let (_dir, history) = crate::bots::testing::journal(&["Infra"]);
        {
            let db = history.db().unwrap();
            db.execute_batch(
                "INSERT INTO bot_work(id,started_by,owner,origin,chain,started_ms)
                 VALUES(1,'infra-id','infra-id','person','[]',0);
                 INSERT INTO bot_outbox(id,bot,text,cause,work,state,created_ms,give_up_ms,task)
                 VALUES(1,'infra-id','question','message',1,'typing',0,9223372036854775807,10),
                       (2,'infra-id','result','outcome',1,'typing',0,9223372036854775807,20);"
            ).unwrap();
        }
        let first = Wait::Outbox { id: 1, task: 10 };
        let outcome = Wait::Outbox { id: 2, task: 20 };
        assert!(first.check_outbox(&history).is_ok());
        history.db().unwrap().execute("UPDATE bot_outbox SET task=11 WHERE id=1", []).unwrap();
        let retry = Wait::Outbox { id: 1, task: 11 };
        assert!(first.check_outbox(&history).is_err());
        assert!(retry.check_outbox(&history).is_ok());
        history.db().unwrap().execute("UPDATE bot_work SET state='stopped' WHERE id=1", []).unwrap();
        assert!(retry.check_outbox(&history).is_err());
        assert!(outcome.check_outbox(&history).is_ok());
        history.db().unwrap().execute("UPDATE bot_outbox SET give_up_ms=0 WHERE id=2", []).unwrap();
        assert!(outcome.check_outbox(&history).is_err());
    }

    fn terminal(address: &str, key: &str, reported: bool, turn: u64) -> Terminal {
        serde_json::from_value(serde_json::json!({
            "address":address,"name":"bot","state":"live","status":null,"template":"fixture",
            "created_ms":42,"exit_code":null,"reason":null,"first_message":null,
            "reported":reported,"turn":turn,
            "labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        }))
        .unwrap()
    }

    fn started(history: &History, hints: &[&str]) -> (i64, String, Terminal) {
        let (launch, key) = start(history, "core", "bot", None, "{}", INSTRUCTIONS, hints)
            .unwrap()
            .unwrap();
        let agent = terminal("t7", &key, false, 0);
        history
            .finish(launch, crate::history::State::Sent, None, Some(&agent))
            .unwrap();
        (launch, key, agent)
    }

    fn texts(history: &History) -> Vec<(i64, String)> {
        let page = history.page("core", "t7", 42, None).unwrap();
        serde_json::to_value(&page.items)
            .unwrap()
            .as_array()
            .unwrap()
            .iter()
            .map(|item| {
                (
                    item["id"].as_i64().unwrap(),
                    item["text"].as_str().unwrap().to_owned(),
                )
            })
            .collect()
    }

    #[test]
    fn a_warm_launch_stays_out_of_the_conversation_until_its_first_message_becomes_its_row() {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        let (launch, key, agent) = started(&history, &[]);
        // The session exists: replies, the live reply and the event stream find it by its launch.
        assert_eq!(
            crate::live_reply::launch_key(&history, "core", "t7", 42).unwrap(),
            Some(key.clone())
        );
        assert!(texts(&history).is_empty());
        assert!(history.conversations().unwrap().is_empty());
        assert_eq!(
            Start::of(&history, &agent),
            Start {
                ready: false,
                warm: true,
                warm_ends_ms: Start::of(&history, &agent).warm_ends_ms
            }
        );
        assert!(starting(&history, &agent));
        assert!(Start::of(&history, &terminal("t7", &key, true, 0)).ready);
        assert!(!starting(&history, &terminal("t7", &key, true, 0)));

        let (first, _) = history
            .start_task("core", &agent, "hi", None, false, &[])
            .unwrap();
        assert_eq!(first, launch, "the first message is the launch row");
        assert_eq!(texts(&history), vec![(launch, "hi".to_owned())]);
        history
            .finish(first, crate::history::State::Sent, None, None)
            .unwrap();
        // The next message is a row of its own, and a reply is saved for the same launch.
        let (second, _) = history
            .start_task("core", &agent, "and again", None, false, &[])
            .unwrap();
        assert!(second > launch);
        assert!(
            crate::history::publish_reply(history.file(), &key, "Codex", "Hello.", None).unwrap()
        );
        assert_eq!(texts(&history).len(), 3);
        assert_eq!(history.conversations().unwrap().len(), 1);
    }

    #[test]
    fn a_reply_before_the_first_message_keeps_the_order_it_was_written_in() {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        let (launch, key, agent) = started(&history, &[]);
        // Someone typed into the agent's terminal, and its hook saved the answer.
        assert!(
            crate::history::publish_reply(history.file(), &key, "Codex", "Typed.", None).unwrap()
        );
        let (first, _) = history
            .start_task("core", &agent, "hi", None, false, &[])
            .unwrap();
        assert!(first > launch);
        let shown = texts(&history);
        assert_eq!(shown.len(), 2);
        assert_eq!(shown[0].1, "Typed.");
        assert_eq!(shown[1], (first, "hi".to_owned()));
        // That agent has had a turn, so it is not one to end for being idle.
        assert!(idle(&history, i64::MAX).unwrap().is_empty());
    }

    #[test]
    fn the_first_task_carries_what_a_launch_with_a_task_types_and_only_the_first() {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        let (launch, key, _) = started(&history, &[RESULTS_HINT, PROJECTS]);
        let kept = waiting(&history, &key).unwrap().unwrap();
        let hints: Vec<&str> = kept.hints.iter().map(String::as_str).collect();
        assert_eq!(hints, [RESULTS_HINT, PROJECTS]);
        assert_eq!(
            first_message("hi", &kept.instructions, &hints).unwrap(),
            first_message("hi", INSTRUCTIONS, &[RESULTS_HINT, PROJECTS]).unwrap()
        );
        let typed = first_message("hi", INSTRUCTIONS, &[RESULTS_HINT, PROJECTS]).unwrap();
        assert!(typed.contains("standing_instructions") && typed.contains("SWARMHUB_RESULTS"));
        assert!(typed.contains(PROJECTS) && typed.contains(r#""current_task":"hi""#));
        assert_eq!(first_message("hi", "", &[]).unwrap(), "hi");
        assert_eq!(
            first_message("hi", "", &[PROJECTS]).unwrap(),
            format!("hi | {PROJECTS}")
        );
        assert!(first_message(&"x".repeat(16_380), "", &[PROJECTS]).is_err());
        // A note for a bot goes last, on its own lines, and is left out when it does not fit.
        let note =
            format!("{NOTE_LEAD} for the bot \"Infra\"] Offer first.\n- Ask before deleting.");
        assert_eq!(
            first_message("hi", "", &[PROJECTS, &note]).unwrap(),
            format!("hi | {PROJECTS}\n\n{note}")
        );
        assert_eq!(
            first_message("hi", "", &[&note]).unwrap(),
            format!("hi\n\n{note}")
        );
        let both = first_message("hi", INSTRUCTIONS, &[PROJECTS, &note]).unwrap();
        assert!(
            both.contains("Offer first.") && both.contains(PROJECTS) && both.contains(INSTRUCTIONS)
        );
        let long = "x".repeat(16_380);
        assert_eq!(first_message(&long, "", &[&note]).unwrap(), long);
        let long = "x".repeat(16_200);
        assert_eq!(
            first_message(&long, INSTRUCTIONS, &[&note]).unwrap(),
            first_message(&long, INSTRUCTIONS, &[]).unwrap()
        );

        mark(&history, launch, "tried_ms").unwrap();
        assert!(
            waiting(&history, &key).unwrap().is_some(),
            "not confirmed yet"
        );
        mark(&history, launch, "delivered_ms").unwrap();
        assert!(waiting(&history, &key).unwrap().is_none());
        let agent = terminal("t7", &key, true, 1);
        assert_eq!(
            Start::of(&history, &agent),
            Start {
                ready: true,
                warm: false,
                warm_ends_ms: None
            }
        );
        // An agent that did not start warm is ready as soon as it runs, whatever it reports.
        let (_, other) = history
            .start_launch("core", "other", "Read this", None, "{}", "")
            .unwrap()
            .unwrap();
        assert!(Start::of(&history, &terminal("t8", &other, false, 0)).ready);
    }

    #[test]
    fn only_an_agent_nobody_wrote_to_is_ended_and_the_limits_stay_within_bounds() {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        let (launch, key, agent) = started(&history, &[]);
        assert!(idle(&history, 0).unwrap().is_empty(), "not old enough");
        let due = idle(&history, i64::MAX).unwrap();
        assert_eq!(due.len(), 1);
        assert_eq!(
            (
                due[0].launch,
                due[0].key.as_str(),
                due[0].address.as_str(),
                due[0].created
            ),
            (launch, key.as_str(), "t7", 42)
        );
        assert!(untouched(&agent));
        assert!(
            untouched(&terminal("t7", &key, true, 1)),
            "Codex's own start"
        );
        assert!(!untouched(&terminal("t7", &key, true, 2)));
        let working: Terminal = serde_json::from_value(serde_json::json!({
            "address":"t7","name":"bot","state":"live","status":{"state":"working"},"template":"fixture",
            "created_ms":42,"exit_code":null,"reason":null,"first_message":null,"reported":true,"turn":0,
            "labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        }))
        .unwrap();
        assert!(!untouched(&working));
        // A task on its way, even one Core never confirmed, keeps the agent.
        mark(&history, launch, "tried_ms").unwrap();
        assert!(idle(&history, i64::MAX).unwrap().is_empty());
        assert!(Start::of(&history, &agent).warm_ends_ms.is_none());

        assert_eq!(idle_limit(None), Some(30 * 60_000));
        assert_eq!(idle_limit(Some("0")), None);
        assert_eq!(idle_limit(Some(" 5 ")), Some(5 * 60_000));
        assert_eq!(idle_limit(Some("soon")), Some(30 * 60_000));
        assert_eq!(start_wait(None, Wait::Queued), Duration::from_secs(300));
        assert_eq!(start_wait(Some("1"), Wait::Queued), Duration::from_secs(30));
        assert_eq!(
            start_wait(Some("9000"), Wait::Queued),
            Duration::from_secs(1800)
        );
        // A caller that is held is not kept for minutes.
        assert_eq!(start_wait(None, Wait::Held), HELD_WAIT);
        assert_eq!(start_wait(Some("40"), Wait::Held), Duration::from_secs(40));
    }
}
