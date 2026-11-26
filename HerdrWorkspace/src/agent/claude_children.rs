//! Claude's Agent tool can launch a background task and return before its start hook.
//! Merge its receipt and lifecycle records by child ID inside the owning workspace launch.
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
    steps: Vec<Step>,
}

#[derive(Deserialize, Serialize)]
struct Step {
    call: String,
    text: String,
    state: String,
}

fn identifier(value: &str) -> bool {
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
        json!({
            "id":thread, "runtime":"claude", "parent":self.parent_agent.as_deref().unwrap_or(&self.session),
            "name":name, "model":self.model, "created_ms":self.created, "completed_ms":self.ended,
            "state":if self.ended.is_none() {"working"} else if self.reply.is_empty() {"finished"} else {"answered"},
            "task":self.task.chars().take(300).collect::<String>(), "reply":self.reply.chars().take(300).collect::<String>()
        })
    }

    fn transcript(&self) -> String {
        let mut parts = Vec::new();
        if !self.task.is_empty() {
            parts.push(format!("Task {}", self.task));
        }
        for step in &self.steps {
            parts.push(format!("{} · {}", step.state, step.text));
        }
        if !self.reply.is_empty() {
            parts.push(format!("Claude {}", self.reply));
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
                    if e["hook_event_name"] == "SubagentStop" {
                        row.ended.get_or_insert_with(history::now);
                        if let Some(reply) = text(&e["last_assistant_message"], 24_000) {
                            row.reply = reply;
                        }
                    }
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
                    if let Some(task) =
                        text(&input["prompt"], 8_000).or_else(|| text(&result["prompt"], 8_000))
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
            if state != "Running" {
                step.state = state.into();
            }
        } else {
            if r.steps.len() >= 64 {
                r.steps.remove(0);
            }
            r.steps.push(Step {
                call: call.into(),
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
