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

/// The newest helpers of one agent that are listed.
const LISTED: usize = 50;

/// A turn that ended without a saved reply counts as over this long after its task was sent.
const QUIET_MS: i64 = 20_000;

#[derive(Clone, Serialize)]
pub(crate) struct ParentRef {
    pub(super) address: String,
    pub(super) created_ms: u64,
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
    template: String,
    model: String,
    difficulty: String,
    task: String,
    started_ms: i64,
    /// `live`, `finished`, or `gone` when Core no longer has the terminal.
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
}

impl View {
    pub(super) fn live(&self) -> bool {
        self.state == "live"
    }

    fn status_word(&self) -> Option<&str> {
        self.status.as_ref().map(|status| status.state.as_str())
    }

    pub(super) fn working(&self) -> bool {
        !settled(
            self.live(),
            self.status_word(),
            self.answered,
            self.delivered,
            now() - self.task_at_ms,
        )
    }

    /// A few words on where the helper stands.
    fn phase(&self) -> String {
        if !self.live() {
            let ended = if self.state == "gone" {
                "gone"
            } else if self.reason.as_deref() == Some("killed") {
                "stopped"
            } else {
                "ended"
            };
            return if self.reply.is_some() {
                format!("{ended}, answered")
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
) -> Result<Vec<View>, StoreError> {
    let db = history.db()?;
    let mut rows = db.prepare(
        "SELECT j.id,j.launch_key,j.address,j.created_ms,j.agent,j.text,j.at_ms,j.state,
                h.name,h.difficulty,h.template,h.model
         FROM helpers h JOIN journal j ON j.id=h.launch
         WHERE h.parent_key=?1 AND j.core_id=?2 ORDER BY h.launch DESC LIMIT ?3",
    )?;
    let mut latest_task = db.prepare(
        "SELECT at_ms,state FROM journal
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
    let mut found = rows.query(params![parent_key, core_id, LISTED as i64])?;
    while let Some(row) = found.next()? {
        let launch: i64 = row.get(0)?;
        let key: String = row.get(1)?;
        let terminal = agents
            .iter()
            .find(|agent| agent.launch_key() == Some(key.as_str()));
        let saved: Option<(String, u64)> = row
            .get::<_, Option<String>>(2)?
            .zip(row.get::<_, Option<u64>>(3)?);
        // A launch Core never confirmed has no terminal to show.
        let Some((address, created_ms)) = terminal
            .map(|terminal| (terminal.address.clone(), terminal.created_ms))
            .or(saved)
        else {
            continue;
        };
        let (task_at_ms, task_state): (i64, String) = latest_task
            .query_row(params![launch, core_id, address, created_ms], |row| {
                Ok((row.get(0)?, row.get(1)?))
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
            difficulty: row.get(9)?,
            task: row.get(5)?,
            started_ms: row.get(6)?,
            state: terminal.map_or_else(|| "gone".into(), |terminal| terminal.state.clone()),
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
        });
    }
    Ok(helpers)
}

/// For the workspace roster: each helper's launch key and the agent that started it.
pub(crate) fn parents(
    history: &History,
    core_id: &str,
) -> Result<HashMap<String, ParentRef>, StoreError> {
    let db = history.db()?;
    let mut rows = db.prepare_cached(
        "SELECT j.launch_key,p.address,p.created_ms FROM helpers h
         JOIN journal j ON j.id=h.launch JOIN journal p ON p.launch_key=h.parent_key
         WHERE j.core_id=?1 AND p.address IS NOT NULL AND p.created_ms IS NOT NULL
         ORDER BY h.launch DESC LIMIT 512",
    )?;
    rows.query_map([core_id], |row| {
        Ok((
            row.get(0)?,
            ParentRef {
                address: row.get(1)?,
                created_ms: row.get(2)?,
            },
        ))
    })?
    .collect::<Result<_, _>>()
    .map_err(StoreError::from)
}

pub(super) fn list_text(helpers: &[View], policy: Option<&Policy>) -> String {
    if helpers.is_empty() {
        return "You have no helpers. Start one with: swarmhub-herdr helper start --difficulty easy|medium|hard TASK".into();
    }
    let running = helpers.iter().filter(|helper| helper.live()).count();
    let limit = policy.map_or_else(String::new, |policy| {
        format!(" of the {} allowed", policy.max_running)
    });
    // An agent took "1 running" beside "answered" for a contradiction, so the line says what running means.
    let mut text = format!(
        "{} helper{}. Still running: {running}{limit}. A helper keeps running after it answers, until you stop it.",
        helpers.len(),
        if helpers.len() == 1 { "" } else { "s" }
    );
    for helper in helpers.iter().rev() {
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
    text
}

pub(super) fn read_text(helper: &View, screen: Option<(usize, &str)>) -> String {
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
    match &helper.reply {
        Some(reply) => {
            text.push_str(if helper.answered {
                "Answer:\n"
            } else {
                "No answer to its latest task yet. Its previous answer:\n"
            });
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
        None => text.push_str(&format!(
            "No answer was saved. See its screen with: swarmhub-herdr helper read {} --lines 30",
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
        let listed = views(&history, "core", &parent, &agents, 5).unwrap();
        // `third` never got a terminal, so there is nothing to show for it.
        assert_eq!(listed.len(), 2);
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
        assert_eq!(listed[1].phase(), "stopped without an answer");
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
        let listed = views(&history, "core", &parent, &agents, 5).unwrap();
        let reply = listed[0].reply.as_ref().unwrap();
        assert_eq!((reply.text.as_str(), reply.truncated), ("Seven", true));
        assert!(listed[0].answered && !listed[0].working());
        assert_eq!(listed[0].phase(), "answered");
        let text = read_text(&listed[0], None);
        assert!(text.starts_with(
            "tests (easy, fixture small, t9): answered\nTask: Count the files\nAnswer:\nSeven"
        ));
        assert!(
            list_text(&listed, Some(&policy))
                .starts_with("2 helpers. Still running: 1 of the 2 allowed. A helper keeps running after it answers, until you stop it.\neasy-1 · easy")
        );
        assert_eq!(
            read_text(&listed[0], Some((2, "one\ntwo  \nthree\n\n")))
                .lines()
                .skip(2)
                .collect::<Vec<_>>(),
            ["Its terminal screen, last 2 lines:", "two", "three"]
        );

        // Helpers are found under their parent only, and marked with it for the roster.
        assert!(
            views(&history, "core", &other, &agents, 5)
                .unwrap()
                .is_empty()
        );
        assert!(
            views(&history, "elsewhere", &parent, &agents, 5)
                .unwrap()
                .is_empty()
        );
        history
            .finish(
                parent_record,
                DeliveryState::Sent,
                None,
                Some(&terminal("t7", &parent, "live", None)),
            )
            .unwrap();
        let marked = parents(&history, "core").unwrap();
        assert_eq!(marked.len(), 3);
        assert_eq!(
            (
                marked[&second.key].address.as_str(),
                marked[&second.key].created_ms
            ),
            ("t7", 42)
        );
        assert!(!marked.contains_key(&parent));
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
