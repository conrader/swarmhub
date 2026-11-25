//! What the workspace remembers about helpers: who started each one, on which difficulty and model, and where it
//! stands now. The `helpers` table holds the first part; Herdr Core's terminal list and the saved replies the rest.

use super::policy::{Difficulty, Policy};
use crate::{
    core::{self, Terminal},
    history::{History, StoreError, now},
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Serialize;
use std::collections::{HashMap, HashSet};

/// How many recent launches to keep alongside the live helpers.
pub(super) const RECENT_LAUNCHES: usize = 50;

/// A turn that ended without a saved reply counts as over this long after its task was sent.
const QUIET_MS: i64 = 20_000;

#[derive(Clone, Serialize)]
pub(crate) struct ParentRef {
    pub(crate) address: String,
    pub(crate) created_ms: u64,
}

#[derive(Serialize)]
pub(super) struct SavedReply {
    id: i64,
    text: String,
    at_ms: i64,
    truncated: bool,
}

/// A helper as the HTTP API and the agent commands report it.
#[derive(Serialize)]
pub(super) struct View {
    pub(super) address: String,
    pub(super) created_ms: u64,
    pub(super) name: String,
    /// The terminal's name in Herdr Core.
    terminal: String,
    pub(super) template: String,
    pub(super) model: String,
    /// The catalog's label for the model ("Sonnet 5.5"), when it lists the model.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) model_label: Option<String>,
    difficulty: String,
    task: String,
    /// A follow-up assignment. The original task stays available to existing clients.
    #[serde(skip_serializing_if = "Option::is_none")]
    current_task: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) open_task: Option<bool>,
    started_ms: i64,
    /// `live` in the HTTP list. For the agent's commands also `finished`, `gone` (Core no longer has the
    /// terminal), `starting` (no terminal yet) and `failed` (it never got one).
    state: String,
    status: Option<core::Status>,
    reason: Option<String>,
    /// Whether a reply was saved after its latest task.
    answered: bool,
    /// The latest saved reply; `/api/history/{core}/{address}/{created_ms}` has every reply in full.
    reply: Option<SavedReply>,
    #[serde(skip)]
    delivered: bool,
    #[serde(skip)]
    task_at_ms: i64,
    /// Why the launch failed, when Core said.
    #[serde(skip)]
    detail: Option<String>,
}

impl View {
    pub(super) fn live(&self) -> bool {
        self.state == "live"
    }

    fn status_word(&self) -> Option<&str> {
        self.status.as_ref().map(|status| status.state.as_str())
    }

    /// Running, or about to: what counts toward the limit.
    fn holds_a_place(&self) -> bool {
        self.live() || self.state == "starting"
    }

    pub(super) fn working(&self) -> bool {
        self.state == "starting"
            || !settled(
                self.live(),
                self.status_word(),
                self.answered,
                self.delivered,
                now() - self.task_at_ms,
            )
    }

    /// A few words on where the helper stands.
    fn phase(&self) -> String {
        if self.state == "starting" {
            return "starting".into();
        }
        if self.state == "failed" {
            return match &self.detail {
                Some(why) => format!("could not be started: {why}"),
                None => "could not be started".into(),
            };
        }
        if !self.live() {
            let ended = if self.state == "gone" {
                "gone"
            } else if self.reason.as_deref() == Some("killed") {
                "stopped"
            } else {
                "ended"
            };
            return if self.answered {
                format!("{ended}, answered")
            } else if self.reply.is_some() {
                format!("{ended} without an answer to its latest task")
            } else {
                format!("{ended} without an answer")
            };
        }
        match self.status_word() {
            Some("blocked") => "blocked: it is waiting for a person".into(),
            Some("error") => "stopped on an error".into(),
            _ if self.answered => "answered".into(),
            _ if !self.delivered => "running, but its task was not delivered".into(),
            Some("working") => "working".into(),
            Some(word) => format!("{word}, no answer yet"),
            None => "starting".into(),
        }
    }
}

/// Whether there is nothing left to wait for: it ended, answered, got stuck, or went quiet.
fn settled(
    live: bool,
    status: Option<&str>,
    answered: bool,
    delivered: bool,
    task_age_ms: i64,
) -> bool {
    !live
        || answered
        || !delivered
        || matches!(status, Some("blocked" | "error"))
        || (status == Some("done") && task_age_ms > QUIET_MS)
}

pub(super) fn one_line(text: &str, limit: usize) -> String {
    let mut words = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if words.chars().count() > limit {
        words = words.chars().take(limit - 1).collect();
        words.push('…');
    }
    words
}

#[derive(Debug)]
pub(super) struct Admitted {
    pub(super) record: i64,
    pub(super) key: String,
    pub(super) name: String,
    pub(super) terminal: String,
}

pub(super) struct Wanted<'a> {
    pub(super) core: &'a str,
    pub(super) parent_key: &'a str,
    pub(super) parent_address: &'a str,
    pub(super) name: Option<&'a str>,
    pub(super) difficulty: Difficulty,
    pub(super) template: &'a str,
    pub(super) model: &'a str,
    pub(super) runtime: &'a str,
    pub(super) task: &'a str,
}

/// Counts this agent's running helpers and records one more, in one transaction. `live` holds the launch keys of
/// the terminals Core reports as running; a launch that is still being started counts as running too.
pub(super) fn admit(
    db: &mut Connection,
    policy: &Policy,
    live: &HashSet<&str>,
    wanted: &Wanted<'_>,
) -> Result<Result<Admitted, String>, StoreError> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let mine: Vec<(String, String, String)> = tx
        .prepare(
            "SELECT j.launch_key,j.state,h.name FROM helpers h JOIN journal j ON j.id=h.launch
             WHERE h.parent_key=?1",
        )?
        .query_map([wanted.parent_key], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        })?
        .collect::<Result<_, _>>()?;
    let running: Vec<&str> = mine
        .iter()
        .filter(|(key, state, _)| state == "pending" || live.contains(key.as_str()))
        .map(|(_, _, name)| name.as_str())
        .collect();
    if let Err(refusal) = policy.admit(running.len()) {
        return Ok(Err(refusal));
    }
    let name = match wanted.name {
        Some(name) => name.to_owned(),
        None => format!("{}-{}", wanted.difficulty.name(), mine.len() + 1),
    };
    if running.contains(&name.as_str()) {
        return Ok(Err(format!(
            "A helper named {name} is still running. Choose another --name, or stop it first."
        )));
    }
    // The parent's address comes last, so the name never looks like another agent's.
    let terminal = format!("{name}-{}", wanted.parent_address);
    if !core::valid_name(&terminal) {
        return Ok(Err("Choose a shorter helper name.".into()));
    }
    let (record, key): (i64, String) = tx.query_row(
        "INSERT INTO journal (launch_key,core_id,agent,kind,state,text,at_ms,launch_runtime,launch_template)
         VALUES (lower(hex(randomblob(16))),?1,?2,'task','pending',?3,?4,?5,?6) RETURNING id,launch_key",
        params![wanted.core, terminal, wanted.task, now(), wanted.runtime, wanted.template],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    tx.execute(
        "INSERT INTO helpers (launch,parent_key,name,difficulty,template,model) VALUES (?1,?2,?3,?4,?5,?6)",
        params![
            record,
            wanted.parent_key,
            name,
            wanted.difficulty.name(),
            wanted.template,
            wanted.model
        ],
    )?;
    tx.commit()?;
    Ok(Ok(Admitted {
        record,
        key,
        name,
        terminal,
    }))
}

/// The newest helpers `parent_key` started on this Core, with what Core says about each terminal now.
pub(super) fn views(
    history: &History,
    core_id: &str,
    parent_key: &str,
    agents: &[Terminal],
    reply_chars: usize,
    recent_launches: usize,
) -> Result<Vec<View>, StoreError> {
    let db = history.db()?;
    let live_keys: Vec<_> = agents
        .iter()
        .filter(|agent| agent.state == "live")
        .filter_map(Terminal::launch_key)
        .collect();
    let live_keys = serde_json::to_string(&live_keys).map_err(|_| StoreError)?;
    let mut rows = db.prepare(
        "WITH recent AS (
             SELECT h.launch FROM helpers h JOIN journal j ON j.id=h.launch
             WHERE h.parent_key=?1 AND j.core_id=?2 ORDER BY h.launch DESC LIMIT ?3
         )
         SELECT j.id,j.launch_key,j.address,j.created_ms,j.agent,j.text,j.at_ms,j.state,
                h.name,h.difficulty,h.template,h.model,j.detail
         FROM helpers h JOIN journal j ON j.id=h.launch
         WHERE h.parent_key=?1 AND j.core_id=?2 AND h.launch IN (
             SELECT launch FROM recent UNION SELECT id FROM journal WHERE launch_key IN (SELECT value FROM json_each(?4))
         ) ORDER BY h.launch DESC",
    )?;
    let mut latest_task = db.prepare(
        "SELECT at_ms,state,
                (SELECT text FROM journal sent WHERE sent.kind='task' AND sent.id>?1
                 AND sent.core_id=?2 AND sent.address=?3 AND sent.created_ms=?4
                 AND sent.state!='not_sent' ORDER BY sent.id DESC LIMIT 1)
         FROM journal
         WHERE kind='task' AND (id=?1 OR (core_id=?2 AND address=?3 AND created_ms=?4))
         ORDER BY id DESC LIMIT 1",
    )?;
    let mut latest_reply = db.prepare(
        "SELECT id,text,at_ms,
                id>(SELECT coalesce(max(id),0) FROM journal task
                    WHERE task.kind='task' AND task.core_id=?2 AND task.address=?3 AND task.created_ms=?4)
         FROM journal WHERE reply_for=?1 AND kind='reply' ORDER BY id DESC LIMIT 1",
    )?;
    let mut helpers = Vec::new();
    let mut found = rows.query(params![parent_key, core_id, recent_launches as i64, live_keys])?;
    while let Some(row) = found.next()? {
        let launch: i64 = row.get(0)?;
        let key: String = row.get(1)?;
        let terminal = agents
            .iter()
            .find(|agent| agent.launch_key() == Some(key.as_str()));
        let saved: Option<(String, u64)> = row
            .get::<_, Option<String>>(2)?
            .zip(row.get::<_, Option<u64>>(3)?);
        let launch_state: String = row.get(7)?;
        // Without a terminal: a launch that has not happened yet, or one that failed.
        let (address, created_ms) = terminal
            .map(|terminal| (terminal.address.clone(), terminal.created_ms))
            .or(saved)
            .unwrap_or_default();
        let state = match terminal {
            Some(terminal) => terminal.state.clone(),
            None if !address.is_empty() => "gone".into(),
            None if launch_state == "pending" => "starting".into(),
            None => "failed".into(),
        };
        let (task_at_ms, task_state, current_task): (i64, String, Option<String>) = latest_task
            .query_row(params![launch, core_id, address, created_ms], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })?;
        let reply = latest_reply
            .query_row(params![key, core_id, address, created_ms], |row| {
                let text: String = row.get(1)?;
                let truncated = text.chars().count() > reply_chars;
                Ok((
                    SavedReply {
                        id: row.get(0)?,
                        text: if truncated {
                            text.chars().take(reply_chars).collect()
                        } else {
                            text
                        },
                        at_ms: row.get(2)?,
                        truncated,
                    },
                    row.get::<_, bool>(3)?,
                ))
            })
            .optional()?;
        let answered = reply.as_ref().is_some_and(|(_, newest)| *newest);
        helpers.push(View {
            address,
            created_ms,
            name: row.get(8)?,
            terminal: row.get(4)?,
            template: row.get(10)?,
            model: row.get(11)?,
            model_label: None,
            difficulty: row.get(9)?,
            task: row.get(5)?,
            current_task,
            open_task: None,
            started_ms: row.get(6)?,
            state,
            status: terminal
                .and_then(|terminal| terminal.status.as_ref())
                .map(|status| core::Status {
                    state: status.state.clone(),
                    kind: status.kind.clone(),
                }),
            reason: terminal.and_then(|terminal| terminal.reason.clone()),
            answered,
            reply: reply.map(|(reply, _)| reply),
            delivered: task_state != "not_sent",
            task_at_ms,
            detail: row.get(12)?,
        });
    }
    Ok(helpers)
}

/// For the workspace roster: which of `agents` are helpers, by launch key, and the agent that started each.
pub(crate) fn parents(
    history: &History,
    core_id: &str,
    agents: &[Terminal],
) -> Result<HashMap<String, Option<ParentRef>>, StoreError> {
    let db = history.db()?;
    let mut parent = db.prepare_cached(
        "SELECT p.address,p.created_ms FROM helpers h
         JOIN journal j ON j.id=h.launch LEFT JOIN journal p ON p.launch_key=h.parent_key
         WHERE j.launch_key=?1 AND j.core_id=?2",
    )?;
    let mut helpers = HashMap::new();
    for key in agents.iter().filter_map(Terminal::launch_key) {
        let found = parent
            .query_row(params![key, core_id], |row| {
                Ok(row
                    .get::<_, Option<String>>(0)?
                    .zip(row.get::<_, Option<u64>>(1)?))
            })
            .optional()?;
        if let Some(found) = found {
            helpers.insert(
                key.to_owned(),
                found.map(|(address, created_ms)| ParentRef {
                    address,
                    created_ms,
                }),
            );
        }
    }
    Ok(helpers)
}

/// Whether any helper was ever started, so a workspace without helpers asks Core nothing for them.
pub(super) fn any(history: &History) -> Result<bool, StoreError> {
    Ok(history
        .db()?
        .query_row("SELECT EXISTS(SELECT 1 FROM helpers)", [], |row| row.get(0))?)
}

/// The running helpers among `agents` whose time is up: the ones to stop. One that answered its latest task
/// before `answered_before_ms` and is not working again; or one that was given its latest task before
/// `asked_before_ms` and has not answered it, whether it is stuck at a prompt or still working. A follow-up is a
/// new task, so both times count again from it.
pub(super) fn overdue<'a>(
    history: &History,
    core_id: &str,
    agents: &'a [Terminal],
    answered_before_ms: i64,
    asked_before_ms: i64,
) -> Result<Vec<&'a Terminal>, StoreError> {
    let db = history.db()?;
    let mut helper = db.prepare_cached(
        "SELECT j.id FROM helpers h JOIN journal j ON j.id=h.launch
         WHERE j.launch_key=?1 AND j.core_id=?2",
    )?;
    let mut latest_task = db.prepare_cached(
        "SELECT id,at_ms FROM journal
         WHERE kind='task' AND (id=?1 OR (core_id=?2 AND address=?3 AND created_ms=?4))
         ORDER BY id DESC LIMIT 1",
    )?;
    let mut answer = db.prepare_cached(
        "SELECT at_ms FROM journal WHERE reply_for=?1 AND kind='reply' AND id>?2
         ORDER BY id DESC LIMIT 1",
    )?;
    let mut due = Vec::new();
    for agent in agents {
        let Some(key) = agent.launch_key().filter(|_| agent.require_live().is_ok()) else {
            continue;
        };
        let launch: Option<i64> = helper
            .query_row(params![key, core_id], |row| row.get(0))
            .optional()?;
        let Some(launch) = launch else {
            continue;
        };
        let (task, asked_ms): (i64, i64) = latest_task.query_row(
            params![launch, core_id, agent.address, agent.created_ms],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        let answered_ms: Option<i64> = answer
            .query_row(params![key, task], |row| row.get(0))
            .optional()?;
        let working = agent
            .status
            .as_ref()
            .is_some_and(|status| status.state == "working");
        let up = match answered_ms {
            Some(answered_ms) => !working && answered_ms <= answered_before_ms,
            None => asked_ms <= asked_before_ms,
        };
        if up {
            due.push(agent);
        }
    }
    Ok(due)
}

/// `helper list` for the agent: the running helpers, then the names of ended ones whose answers it can still read.
pub(super) fn list_text(helpers: &[View], limit: Option<usize>, stop_after_seconds: u64) -> String {
    if helpers.is_empty() {
        return "You have no helpers. Start one with: swarmhub-herdr helper start --difficulty easy|medium|hard TASK".into();
    }
    let running: Vec<&View> = helpers
        .iter()
        .rev()
        .filter(|helper| helper.holds_a_place())
        .collect();
    let limit = limit.map_or_else(String::new, |limit| format!(" of the {limit} allowed"));
    let mut text = format!(
        "Running helpers: {}{limit}. A helper is stopped {stop_after_seconds} seconds after it answers unless you send it a follow-up; its answer stays readable.",
        running.len()
    );
    for helper in running {
        text.push_str(&format!(
            "\n{} · {} · {} · {} · {} · {}",
            helper.name,
            helper.difficulty,
            helper.model,
            helper.address,
            helper.phase(),
            one_line(&helper.task, 80)
        ));
    }
    // A name read back gives its newest helper, so one that runs again is not also listed as ended.
    let mut ended: Vec<&View> = Vec::new();
    for helper in helpers {
        let runs = helpers
            .iter()
            .any(|other| other.holds_a_place() && other.name == helper.name);
        if !runs && ended.len() < 12 && ended.iter().all(|seen| seen.name != helper.name) {
            ended.push(helper);
        }
    }
    ended.reverse();
    let names = |answered: bool| {
        ended
            .iter()
            .filter(|helper| helper.answered == answered)
            .map(|helper| helper.name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    };
    if !names(true).is_empty() {
        text.push_str(&format!(
            "\nEnded (read an answer with `swarmhub-herdr helper read NAME`): {}",
            names(true)
        ));
    }
    if !names(false).is_empty() {
        text.push_str(&format!("\nStopped without an answer: {}", names(false)));
    }
    text
}

/// `helper read` for the agent. `unanswered_seconds` is how long the workspace lets a helper go without answering.
pub(super) fn read_text(
    helper: &View,
    screen: Option<(usize, &str)>,
    unanswered_seconds: u64,
) -> String {
    let mut text = format!(
        "{} ({}, {} {}, {}): {}\nTask: {}\n",
        helper.name,
        helper.difficulty,
        helper.template,
        helper.model,
        helper.address,
        helper.phase(),
        one_line(&helper.task, 300)
    );
    if let Some((lines, screen)) = screen {
        let shown: Vec<&str> = screen.lines().map(str::trim_end).collect();
        let shown = &shown[..shown
            .iter()
            .rposition(|line| !line.is_empty())
            .map_or(0, |last| last + 1)];
        text.push_str(&format!("Its terminal screen, last {lines} lines:\n"));
        text.push_str(&shown[shown.len().saturating_sub(lines)..].join("\n"));
        return text;
    }
    let gave_up = format!(
        "The workspace stops a helper that has not answered {unanswered_seconds} seconds after its task was sent."
    );
    match &helper.reply {
        Some(reply) => {
            if helper.answered {
                text.push_str("Answer:\n");
            } else if helper.holds_a_place() {
                text.push_str("No answer to its latest task yet. Its previous answer:\n");
            } else {
                text.push_str(&format!(
                    "It was stopped without an answer to its latest task. {gave_up} Its previous answer:\n"
                ));
            }
            text.push_str(&reply.text);
            if reply.truncated {
                text.push_str(
                    "\n[The answer is longer; ask the helper to write long results to a file.]",
                );
            }
        }
        None if helper.working() => text.push_str(&format!(
            "No answer saved yet. Wait with: swarmhub-herdr helper wait {}",
            helper.name
        )),
        None if helper.holds_a_place() => text.push_str(&format!(
            "No answer was saved. See its screen with: swarmhub-herdr helper read {} --lines 30",
            helper.name
        )),
        None if helper.state == "failed" => text.push_str("It never ran, so there is no answer."),
        None => text.push_str(&format!(
            "It was stopped without an answer. {gave_up} Its last screen: swarmhub-herdr helper read {} --lines 30",
            helper.name
        )),
    }
    text
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::State as DeliveryState;

    const POLICY: &str =
        r#"{"max_running":2,"difficulties":{"easy":{"template":"fixture","model":"small"}}}"#;

    fn wanted<'a>(parent_key: &'a str, name: Option<&'a str>) -> Wanted<'a> {
        Wanted {
            core: "core",
            parent_key,
            parent_address: "t7",
            name,
            difficulty: Difficulty::Easy,
            template: "fixture",
            model: "small",
            runtime: "{}",
            task: "Count the files",
        }
    }

    fn terminal(address: &str, key: &str, state: &str, status: Option<&str>) -> Terminal {
        serde_json::from_value(serde_json::json!({
            "address":address,"name":null,"state":state,"status":status.map(|state| serde_json::json!({"state":state})),
            "template":"fixture","created_ms":42,"exit_code":null,
            "reason":(state != "live").then_some("killed"),"first_message":null,
            "labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        }))
        .unwrap()
    }

    #[test]
    fn the_workspace_counts_running_helpers_per_parent_and_records_each_one() {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        let policy = Policy::parse(POLICY.as_bytes()).unwrap();
        let (parent_record, parent) = history
            .start_launch("core", "lead", "Lead", None, "{}", "")
            .unwrap()
            .unwrap();
        let (_, other) = history
            .start_launch("core", "other", "Other", None, "{}", "")
            .unwrap()
            .unwrap();
        let admit = |live: &[&str], wanted: &Wanted<'_>| {
            let live: HashSet<&str> = live.iter().copied().collect();
            admit(&mut history.db().unwrap(), &policy, &live, wanted).unwrap()
        };
        let finish = |admitted: &Admitted, address: &str| {
            history
                .finish(
                    admitted.record,
                    DeliveryState::Sent,
                    None,
                    Some(&terminal(address, &admitted.key, "live", Some("working"))),
                )
                .unwrap();
        };

        let first = admit(&[], &wanted(&parent, None)).unwrap();
        assert_eq!(
            (first.name.as_str(), first.terminal.as_str()),
            ("easy-1", "easy-1-t7")
        );
        // A launch that is still starting holds its place and its name.
        assert!(
            admit(&[], &wanted(&parent, Some("easy-1")))
                .unwrap_err()
                .contains("still running")
        );
        let second = admit(&[], &wanted(&parent, Some("tests"))).unwrap();
        assert!(
            admit(&[], &wanted(&parent, None))
                .unwrap_err()
                .contains("limit is 2")
        );
        finish(&first, "t8");
        finish(&second, "t9");
        // Core says both run: still full. Another agent has its own count.
        let both = [first.key.as_str(), second.key.as_str()];
        assert!(admit(&both, &wanted(&parent, None)).is_err());
        assert!(admit(&both, &wanted(&other, None)).is_ok());
        // One ended: a place is free, and its name can be used again.
        let third = admit(&[second.key.as_str()], &wanted(&parent, Some("easy-1"))).unwrap();
        assert_eq!(third.terminal, "easy-1-t7");
        assert!(
            admit(&[], &wanted(&parent, Some(&"x".repeat(32))))
                .unwrap_err()
                .contains("shorter")
        );

        // The saved record carries the parent, difficulty, model and task; the newest comes first.
        let agents = [
            terminal("t8", &first.key, "finished", None),
            terminal("t9", &second.key, "live", Some("working")),
        ];
        let listed = views(&history, "core", &parent, &agents, 5, RECENT_LAUNCHES).unwrap();
        // `third` has no terminal yet: the agent's commands see it starting, and the HTTP list leaves it out.
        assert_eq!(listed.len(), 3);
        assert_eq!(
            (
                listed[0].name.as_str(),
                listed[0].state.as_str(),
                listed[0].phase().as_str()
            ),
            ("easy-1", "starting", "starting")
        );
        assert!(listed[0].working() && !listed[0].live());
        history
            .finish(
                third.record,
                DeliveryState::NotSent,
                Some("no such template"),
                None,
            )
            .unwrap();
        let mut listed = views(&history, "core", &parent, &agents, 5, RECENT_LAUNCHES).unwrap();
        assert_eq!(listed[0].phase(), "could not be started: no such template");
        assert!(!listed[0].working() && !listed[0].holds_a_place());
        listed.remove(0);
        let tests = &listed[0];
        assert_eq!(
            (
                tests.name.as_str(),
                tests.address.as_str(),
                tests.created_ms,
                tests.difficulty.as_str(),
                tests.model.as_str(),
                tests.task.as_str(),
                tests.state.as_str(),
            ),
            (
                "tests",
                "t9",
                42,
                "easy",
                "small",
                "Count the files",
                "live"
            )
        );
        assert!(tests.working() && tests.reply.is_none() && !tests.answered);
        assert!(tests.current_task.is_none());
        assert_eq!(listed[1].phase(), "stopped without an answer");
        assert_eq!(
            read_text(&listed[1], None, 1800).lines().last().unwrap(),
            "It was stopped without an answer. The workspace stops a helper that has not answered 1800 seconds after its task was sent. Its last screen: swarmhub-herdr helper read easy-1 --lines 30"
        );
        assert!(!listed[1].working());

        // A saved reply answers the task; the list carries a bounded copy of it.
        assert!(
            crate::history::publish_reply(
                history.file(),
                &second.key,
                "Agent",
                "Seven files",
                None
            )
            .unwrap()
        );
        let mut listed = views(&history, "core", &parent, &agents, 5, RECENT_LAUNCHES).unwrap();
        listed.remove(0);
        let reply = listed[0].reply.as_ref().unwrap();
        assert_eq!((reply.text.as_str(), reply.truncated), ("Seven", true));
        assert!(listed[0].answered && !listed[0].working());
        assert_eq!(listed[0].phase(), "answered");
        let text = read_text(&listed[0], None, 1800);
        assert!(text.starts_with(
            "tests (easy, fixture small, t9): answered\nTask: Count the files\nAnswer:\nSeven"
        ));
        assert_eq!(
            list_text(&listed, Some(2), 60),
            "Running helpers: 1 of the 2 allowed. A helper is stopped 60 seconds after it answers unless you send it a follow-up; its answer stays readable.\n\
             tests · easy · small · t9 · answered · Count the files\n\
             Stopped without an answer: easy-1"
        );
        assert_eq!(
            read_text(&listed[0], Some((2, "one\ntwo  \nthree\n\n")), 1800)
                .lines()
                .skip(2)
                .collect::<Vec<_>>(),
            ["Its terminal screen, last 2 lines:", "two", "three"]
        );

        // Helpers are found under their parent only, and marked with it for the roster.
        let of_other = views(&history, "core", &other, &agents, 5, RECENT_LAUNCHES).unwrap();
        assert_eq!(of_other.len(), 1);
        assert_eq!(of_other[0].state, "starting");
        assert!(
            views(&history, "elsewhere", &parent, &agents, 5, RECENT_LAUNCHES)
                .unwrap()
                .is_empty()
        );
        let everyone = [
            terminal("t8", &first.key, "finished", None),
            terminal("t9", &second.key, "live", Some("done")),
            terminal("t7", &parent, "live", None),
        ];
        // The parent's own launch has no terminal recorded yet: its helpers are known as helpers all the same.
        let marked = parents(&history, "core", &everyone).unwrap();
        assert_eq!(marked.len(), 2);
        assert!(marked[&second.key].is_none());
        history
            .finish(parent_record, DeliveryState::Sent, None, Some(&everyone[2]))
            .unwrap();
        let marked = parents(&history, "core", &everyone).unwrap();
        let of_second = marked[&second.key].as_ref().unwrap();
        assert_eq!(
            (of_second.address.as_str(), of_second.created_ms),
            ("t7", 42)
        );
        assert!(marked.contains_key(&first.key) && !marked.contains_key(&parent));
        assert!(
            parents(&history, "elsewhere", &everyone)
                .unwrap()
                .is_empty()
        );

        // An answered, idle helper is due once its answer is old enough. The parent and an ended helper never are.
        assert!(any(&history).unwrap());
        let answered_at = listed[0].reply.as_ref().unwrap().at_ms;
        let due = |agents: &[Terminal], answered_before: i64, asked_before: i64| -> Vec<String> {
            overdue(&history, "core", agents, answered_before, asked_before)
                .unwrap()
                .iter()
                .map(|agent| agent.address.clone())
                .collect()
        };
        const NEVER: i64 = i64::MIN;
        assert!(due(&everyone, answered_at - 1, NEVER).is_empty());
        assert_eq!(due(&everyone, answered_at, NEVER), ["t9"]);
        // It answered, so the time allowed without an answer does not apply to it, however long ago it was asked.
        assert!(due(&everyone, NEVER, now() + 1_000).is_empty());
        // It is working again: left alone.
        assert!(due(&agents, answered_at, NEVER).is_empty());
        // A follow-up it has not answered: its earlier answer no longer counts, and the other clock starts.
        let (follow_up, _) = history
            .start_task("core", &everyone[1], "And the folders?", None, false, &[])
            .unwrap();
        let asked_at: i64 = history
            .db()
            .unwrap()
            .query_row(
                "SELECT at_ms FROM journal WHERE id=?1",
                [follow_up],
                |row| row.get(0),
            )
            .unwrap();
        assert!(due(&everyone, now() + 1_000, asked_at - 1).is_empty());
        // Too long without an answer: stopped, also while it still works.
        assert_eq!(due(&everyone, NEVER, asked_at), ["t9"]);
        assert_eq!(due(&agents, NEVER, asked_at), ["t9"]);
        let unanswered = views(&history, "core", &parent, &agents[..1], 50, RECENT_LAUNCHES).unwrap();
        let gone = unanswered
            .iter()
            .find(|helper| helper.name == "tests")
            .unwrap();
        assert_eq!(gone.phase(), "gone without an answer to its latest task");
        assert_eq!(gone.current_task.as_deref(), Some("And the folders?"));
        assert_eq!(gone.task, "Count the files");
        assert!(read_text(gone, None, 600).contains(
            "It was stopped without an answer to its latest task. The workspace stops a helper that has not answered 600 seconds after its task was sent. Its previous answer:\nSeven files"
        ));
        // The delay after an answer counts again from its next answer.
        assert!(
            crate::history::publish_reply(history.file(), &second.key, "Agent", "Two", None)
                .unwrap()
        );
        assert_eq!(due(&everyone, now() + 1_000, NEVER), ["t9"]);
        assert!(due(&everyone, answered_at, now() + 1_000).is_empty());

        // The HTTP listing includes every live helper, even with a newer, ended launch.
        let listed = views(&history, "core", &parent, &everyone, 50, 0).unwrap();
        assert_eq!(listed.len(), 1);
        assert!(listed[0].live() && listed[0].name == "tests");
        let (missed, _) = history
            .start_task("core", &everyone[1], "Undelivered follow-up", None, false, &[])
            .unwrap();
        history.db().unwrap().execute("UPDATE journal SET state='not_sent' WHERE id=?1", [missed]).unwrap();
        let listed = views(&history, "core", &parent, &everyone, 50, 0).unwrap();
        assert_eq!(listed[0].current_task.as_deref(), Some("And the folders?"));
    }

    #[test]
    fn a_workspace_without_helpers_has_nothing_to_stop() {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        assert!(!any(&history).unwrap());
        assert_eq!(
            list_text(&[], Some(3), 60),
            "You have no helpers. Start one with: swarmhub-herdr helper start --difficulty easy|medium|hard TASK"
        );
    }

    #[test]
    fn a_helper_is_settled_once_it_answered_ended_or_got_stuck() {
        assert_eq!(one_line("  a\n b\tc ", 20), "a b c");
        assert_eq!(one_line("abcdef", 4), "abc…");
        // live, status, answered, delivered, task age
        assert!(!settled(true, Some("working"), false, true, 90_000));
        assert!(!settled(true, None, false, true, 90_000));
        // A slow start reports idle long before its first turn.
        assert!(!settled(true, Some("idle"), false, true, 90_000));
        assert!(settled(true, Some("done"), true, true, 1_000));
        assert!(settled(false, None, false, true, 1_000));
        assert!(settled(true, Some("idle"), false, false, 1_000));
        assert!(settled(true, Some("blocked"), false, true, 1_000));
        assert!(settled(true, Some("error"), false, true, 1_000));
        // "done" just after a follow-up was sent is the previous turn's word.
        assert!(!settled(true, Some("done"), false, true, 1_000));
        assert!(settled(true, Some("done"), false, true, QUIET_MS + 1));
    }
}
