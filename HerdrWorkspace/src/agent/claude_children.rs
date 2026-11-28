//! Claude's Agent tool can launch a background task and return before its start hook.
//! Merge its receipt and lifecycle records by child ID inside the owning workspace launch.
use super::child_output::ChildCommandOutput;
use crate::history;
use rusqlite::{OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::path::Path;

#[derive(Default, Deserialize, Serialize)]
struct Record {
    session: String,
    parent_agent: Option<String>,
    role: String,
    name: String,
    model: Option<String>,
    task: String,
    reply: String,
    created: i64,
    ended: Option<i64>,
    #[serde(default)]
    stopped: bool,
    last_stop_call: Option<String>,
    #[serde(default)]
    stop_controls: bool,
    #[serde(default)]
    run_generation: u64,
    requested_at: Option<i64>,
    requested_prompt: Option<String>,
    steps: Vec<Step>,
    terminal: Option<ChildCommandOutput>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    previous_runs: String,
    prompt_id: Option<String>,
    pending_assignment: Option<Assignment>,
    #[serde(default)]
    awaiting_assignment: bool,
    last_resume_call: Option<String>,
}

#[derive(Deserialize, Serialize)]
struct Assignment {
    prompt_id: Option<String>,
    task: String,
}

#[derive(Deserialize, Serialize)]
struct Step {
    call: String,
    started_ms: Option<i64>,
    completed_ms: Option<i64>,
    text: String,
    state: String,
}

pub(super) fn identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

fn text(value: &Value, max: usize) -> Option<String> {
    value
        .as_str()
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(max).collect())
}

impl Record {
    fn summary(&self, thread: &str) -> Value {
        let name = if !self.name.is_empty() {
            &self.name
        } else if !self.role.is_empty() {
            &self.role
        } else {
            "Claude agent"
        };
        let sidebar = self.steps.last().filter(|_| self.ended.is_none() && !self.stopped).map(|step| {
            let (tool, path) = step.text.split_once(' ').unwrap_or((&step.text, ""));
            crate::tool_activity::sidebar_label(tool, Some(path))
        });
        json!({
            "sidebar_summary":sidebar, "id":thread, "runtime":"claude", "parent":self.parent_agent.as_deref().unwrap_or(&self.session),
            "name":name, "model":self.model, "created_ms":self.created, "completed_ms":self.ended,
            "active_turn":self.prompt_id.as_ref().filter(|_| self.stop_controls && self.ended.is_none()).map(|_| self.run_generation.to_string()),
            "state":if self.stopped {"stopped"} else if self.ended.is_none() {"working"} else if self.reply.is_empty() {"finished"} else {"answered"},
            "task":self.task.chars().take(300).collect::<String>(), "reply":self.reply.chars().take(300).collect::<String>()
        })
    }

    fn start(&mut self, prompt: Option<String>) {
        if self.ended.take().is_some() {
            let transcript = self.transcript();
            let start = transcript.ceil_char_boundary(transcript.len().saturating_sub(64 * 1024));
            self.previous_runs = transcript[start..].to_owned();
            self.run_generation += 1;
            self.stopped = false;
            self.requested_at = None;
            self.requested_prompt = None;
            self.task.clear();
            self.awaiting_assignment = true;
            self.created = history::now();
            self.reply.clear();
            self.steps.clear();
            self.terminal = None;
        }
        self.prompt_id = prompt;
        if let Some(assignment) = self.pending_assignment.take()
            && (self.prompt_id.is_none() || assignment.prompt_id.is_none() || assignment.prompt_id == self.prompt_id)
        {
            self.task = assignment.task;
            self.awaiting_assignment = false;
        }
    }

    fn stop(&mut self, call: &str) {
        if self.last_stop_call.as_deref() == Some(call) {
            return;
        }
        self.last_stop_call = Some(call.into());
        self.stopped = true;
        self.ended.get_or_insert_with(history::now);
        for step in &mut self.steps {
            if step.state == "Running" {
                step.state = "Stopped".into();
                step.completed_ms = self.ended;
            }
        }
    }

    fn resume_assignment(&mut self, assignment: Assignment, call: Option<String>) {
        if call.is_some() && self.last_resume_call == call {
            return;
        }
        self.last_resume_call = call;
        // The tool receipt may arrive just before Start, during work, or just after
        // Stop. A fast resumed run can still be waiting for its first assignment.
        if self.ended.is_some()
            && (!self.awaiting_assignment || self.prompt_id != assignment.prompt_id)
        {
            self.pending_assignment = Some(assignment);
        } else {
            self.task = assignment.task;
            self.awaiting_assignment = false;
        }
    }

    fn transcript(&self) -> String {
        let mut parts = Vec::new();
        if !self.previous_runs.is_empty() {
            parts.push(self.previous_runs.clone());
        }
        if !self.task.is_empty() {
            parts.push(format!("Task {}", self.task));
        }
        for step in &self.steps {
            parts.push(format!("{} · {}", step.state, step.text));
        }
        if let Some(terminal) = &self.terminal {
            parts.push(format!("$ {}\n{}", terminal.command, terminal.output));
        }
        if !self.reply.is_empty() {
            parts.push(format!("Claude {}", self.reply));
        }
        if self.stopped {
            parts.push("Stopped".into());
        }
        parts.join("\n\n")
    }
}

fn update(
    journal: &Path,
    key: &str,
    session: &str,
    child: &str,
    apply: impl FnOnce(&mut Record),
) -> rusqlite::Result<()> {
    if !identifier(session) || !identifier(child) || child == session {
        return Ok(());
    }
    let mut db = history::connection(journal)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let Some(launch) = tx
        .query_row("SELECT id FROM journal WHERE launch_key=?1", [key], |r| {
            r.get::<_, i64>(0)
        })
        .optional()?
    else {
        return Ok(());
    };
    let previous: Option<String> = tx
        .query_row(
            "SELECT record FROM claude_children WHERE launch=?1 AND thread=?2",
            params![launch, child],
            |r| r.get(0),
        )
        .optional()?;
    let mut record: Record = match previous.as_deref() {
        Some(raw) => serde_json::from_str(raw).map_err(|e| {
            rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e))
        })?,
        None => Record {
            session: session.into(),
            created: history::now(),
            ..Record::default()
        },
    };
    if record.session != session {
        return Ok(());
    }
    apply(&mut record);
    let saved = serde_json::to_string(&record).expect("Claude child record contains JSON values");
    if previous.as_deref() != Some(&saved) {
        tx.execute("INSERT INTO claude_children(launch,thread,record,summary,transcript) VALUES(?1,?2,?3,?4,?5)
            ON CONFLICT(launch,thread) DO UPDATE SET record=excluded.record,summary=excluded.summary,
            transcript=excluded.transcript,revision=claude_children.revision+1",
            params![launch,child,saved,record.summary(child).to_string(),record.transcript()])?;
    }
    tx.commit()
}

pub(super) fn hook() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = super::session()?;
    let e: Value = serde_json::from_str(&super::read_input(super::MAX_HOOK)?)?;
    let Some(session) = e["session_id"].as_str() else {
        return Ok(());
    };
    match e["hook_event_name"].as_str() {
        Some("SubagentStart" | "SubagentStop") => {
            if let Some(child) = e["agent_id"].as_str() {
                update(&journal, &key, session, child, |row| {
                    if let Some(role) = text(&e["agent_type"], 120) {
                        row.role = role;
                    }
                    if e["hook_event_name"] == "SubagentStart" {
                        row.stop_controls = std::env::var_os(super::claude_control::ENABLED).is_some();
                        row.start(text(&e["prompt_id"], 128));
                    } else {
                        row.ended.get_or_insert_with(history::now);
                        if let Some(reply) = text(&e["last_assistant_message"], 24_000) {
                            row.reply = reply;
                        }
                    }
                })?;
            }
        }
        Some("PostToolUse") if e["tool_name"] == "TaskStop" => {
            let result = &e["tool_response"];
            if result["task_type"] == "local_agent"
                && let Some(child) = result["task_id"].as_str()
                && e["tool_input"]["task_id"] == child
                && let Some(call) = e["tool_use_id"].as_str().filter(|id| identifier(id))
            {
                update(&journal, &key, session, child, |row| row.stop(call))?;
            }
        }
        Some("PostToolUse") if e["tool_name"] == "SendMessage" => {
            let result = &e["tool_response"];
            if result["success"] == true
                && let Some(child) = result["resumedAgentId"].as_str()
                && let Some(task) = text(&e["tool_input"]["message"], 8_000)
            {
                update(&journal, &key, session, child, |row| {
                    row.resume_assignment(Assignment { prompt_id: text(&e["prompt_id"], 128), task },
                                          text(&e["tool_use_id"], 128));
                })?;
            }
        }
        Some("PostToolUse") if matches!(e["tool_name"].as_str(), Some("Agent" | "Task")) => {
            let result = &e["tool_response"];
            let input = &e["tool_input"];
            if let Some(child) = result["agentId"].as_str() {
                update(&journal, &key, session, child, |row| {
                    if let Some(parent) = e["agent_id"]
                        .as_str()
                        .filter(|p| identifier(p) && *p != child)
                    {
                        row.parent_agent = Some(parent.into());
                    }
                    if row.previous_runs.is_empty()
                        && let Some(task) = text(&input["prompt"], 8_000).or_else(|| text(&result["prompt"], 8_000))
                    {
                        row.task = task;
                    }
                    if let Some(name) = text(&input["name"], 120)
                        .or_else(|| text(&result["description"], 120))
                        .or_else(|| text(&input["description"], 120))
                    {
                        row.name = name;
                    }
                    if let Some(model) = text(&result["resolvedModel"], 120) {
                        row.model = Some(model);
                    }
                })?;
            }
        }
        _ => {}
    }
    Ok(())
}

/// This hook only receives Bash completions. Other tool results can contain entire
/// documents and continue through the ordinary tool-activity hook without being read.
pub(super) fn shell() -> Result<(), Box<dyn std::error::Error>> {
    use std::io::Read;
    #[derive(Deserialize)]
    struct Input { command: String }
    #[derive(Deserialize)]
    struct Output { stdout: Option<String>, stderr: Option<String> }
    #[derive(Deserialize)]
    struct Event {
        agent_id: Option<String>,
        session_id: String,
        tool_input: Input,
        tool_response: Option<Output>,
        error: Option<String>,
    }
    let Ok(event) = serde_json::from_reader::<_, Event>(std::io::stdin().lock().take(64 * 1024 * 1024)) else { return Ok(()) };
    let Some(child) = event.agent_id else { return Ok(()) };
    let output = match event.tool_response {
        Some(response) => [response.stdout, response.stderr].into_iter().flatten()
            .filter(|part| !part.is_empty()).collect::<Vec<_>>().join("\n"),
        None => event.error.unwrap_or_default(),
    };
    if let Some(terminal) = ChildCommandOutput::new(&event.tool_input.command, &output) {
        let (journal, key) = super::session()?;
        update(&journal, &key, &event.session_id, &child, |record| record.terminal = Some(terminal))?;
    }
    Ok(())
}

pub(crate) fn step(
    journal: &Path,
    key: &str,
    session: &str,
    child: &str,
    call: &str,
    label: String,
    state: &str,
) {
    if !identifier(call) {
        return;
    }
    let _ = update(journal, key, session, child, |r| {
        if let Some(step) = r.steps.iter_mut().find(|s| s.call == call) {
            if state != "Running" && step.state == "Running" {
                step.state = state.into();
                step.completed_ms = Some(history::now());
            }
        } else {
            if r.steps.len() >= 64 {
                r.steps.remove(0);
            }
            r.steps.push(Step {
                call: call.into(),
                started_ms: (state == "Running").then(history::now),
                completed_ms: (state != "Running").then(history::now),
                text: label.chars().take(256).collect(),
                state: state.into(),
            });
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stopped_session_keeps_its_transcript_and_can_run_again() {
        let mut row = Record { task: "Review".into(), steps: vec![Step {
            call: "read".into(), started_ms: Some(1), completed_ms: None, text: "Read notes".into(), state: "Running".into(),
        }], ..Record::default() };
        row.stop_controls = true;
        row.start(Some("again".into()));
        let first_run = row.summary("child")["active_turn"].clone();
        row.stop("stop-one");
        let ended = row.ended;
        row.stop("stop-one");
        assert_eq!(row.ended, ended);
        assert_eq!(row.summary("child")["state"], "stopped");
        row.start(Some("again".into()));
        row.stop("stop-one");
        assert_eq!(row.summary("child")["state"], "working");
        assert_ne!(row.summary("child")["active_turn"], first_run);
        assert_eq!(row.transcript(), "Task Review\n\nStopped · Read notes\n\nStopped");
    }

    #[test]
    fn resume_receipt_can_precede_start_or_follow_a_fast_stop() {
        for early in [true, false] {
            let assignment = || Assignment { prompt_id: Some("resume".into()), task: "Next task".into() };
            let mut row = Record { task: "First task".into(), reply: "First answer".into(), ended: Some(10),
                                   ..Record::default() };
            if early {
                row.resume_assignment(assignment(), Some("call".into()));
                assert_eq!(row.task, "First task");
            }
            row.start(Some("resume".into()));
            assert!(row.ended.is_none() && row.reply.is_empty());
            row.ended = Some(20);
            row.reply = "Next answer".into();
            row.resume_assignment(assignment(), Some("call".into()));
            assert_eq!(row.task, "Next task");
            assert!(row.pending_assignment.is_none());
            assert_eq!(row.transcript(), "Task First task\n\nClaude First answer\n\nTask Next task\n\nClaude Next answer");
        }
    }

    #[test]
    fn each_launch_keeps_its_own_child_and_late_receipts_preserve_the_answer() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("journal");
        let db = rusqlite::Connection::open(&path).unwrap();
        db.execute_batch(
            "CREATE TABLE journal(id INTEGER PRIMARY KEY, launch_key TEXT UNIQUE);
                          INSERT INTO journal VALUES(1,'owner'),(2,'other');",
        )
        .unwrap();
        db.execute_batch(include_str!("../migrate-codex-children.sql"))
            .unwrap();
        db.execute_batch(include_str!("../migrate-claude-children.sql"))
            .unwrap();
        update(&path, "owner", "session", "child", |r| {
            r.reply = "original".into();
            r.ended = Some(5);
        })
        .unwrap();
        for _ in 0..2 {
            update(&path, "owner", "session", "child", |r| {
                r.task = "Late assignment".into()
            })
            .unwrap();
        }
        update(&path, "owner", "different-session", "child", |r| {
            r.reply = "wrong".into()
        })
        .unwrap();
        update(&path, "other", "session", "child", |r| {
            r.task = "Other task".into()
        })
        .unwrap();
        let saved: (String, String, i64) = db.query_row(
            "SELECT json_extract(summary,'$.state'),transcript,revision FROM native_children WHERE runtime='claude' AND launch=1",
            [],|row|Ok((row.get(0)?,row.get(1)?,row.get(2)?))).unwrap();
        assert_eq!(
            saved,
            (
                "answered".into(),
                "Task Late assignment\n\nClaude original".into(),
                2
            )
        );
        assert_eq!(
            db.query_row(
                "SELECT transcript FROM native_children WHERE launch=2",
                [],
                |r| r.get::<_, String>(0)
            )
            .unwrap(),
            "Task Other task"
        );
    }
}
