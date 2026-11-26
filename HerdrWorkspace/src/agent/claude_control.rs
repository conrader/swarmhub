//! A stop request is a normal message to the interactive parent. Bind that prompt's
//! tools to the observed child run; only Claude's TaskStop receipt confirms the stop.
use super::claude_children::identifier;
use crate::history;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fs, io,
    path::{Path, PathBuf},
};

pub(crate) const ENABLED: &str = "SWARMHUB_CLAUDE_STOP_REQUESTS";
const PREFIX: &str = "[SwarmHub stop request] ";

pub(crate) fn message(thread: &str, run: &str) -> String {
    format!(
        "{PREFIX}{thread} {run}\nStop only Claude subagent {thread} now using TaskStop with task_id {thread}. If the tool is deferred, use ToolSearch to select TaskStop. Report its result."
    )
}

#[derive(Serialize, Deserialize)]
struct Target {
    session: String,
    thread: String,
    run: String,
}

impl Target {
    fn is_working(&self, journal: &Path, key: &str) -> rusqlite::Result<bool> {
        let db = history::connection(journal)?;
        Ok(db.query_row("SELECT 1 FROM claude_children c JOIN journal j ON j.id=c.launch
            WHERE j.launch_key=? AND c.thread=? AND json_extract(c.record,'$.session')=?
            AND json_extract(c.summary,'$.active_turn')=? AND json_extract(c.summary,'$.state')='working'",
            params![key, self.thread, self.session, self.run], |_| Ok(())).optional()?.is_some())
    }
}

fn guard_path(journal: &Path, key: &str, prompt: &str) -> Option<PathBuf> {
    identifier(prompt).then(|| {
        journal
            .with_file_name("claude-stop-prompts")
            .join(format!("{key}-{prompt}"))
    })
}

pub(super) fn prompt() -> Result<(), Box<dyn std::error::Error>> {
    let e: Value = serde_json::from_str(&super::read_input(super::MAX_HOOK)?)?;
    let Some(text) = e["prompt"].as_str().and_then(|s| s.strip_prefix(PREFIX)) else {
        return Ok(());
    };
    let register = || -> Result<(), Box<dyn std::error::Error>> {
        let (thread, run) = text
            .lines()
            .next()
            .and_then(|line| line.split_once(' '))
            .ok_or("Invalid stop request.")?;
        let session = e["session_id"].as_str().ok_or("Missing Claude session.")?;
        let prompt = e["prompt_id"]
            .as_str()
            .ok_or("This Claude version cannot scope the stop request.")?;
        if ![session, thread, run].into_iter().all(identifier) {
            return Err("Invalid stop target.".into());
        }
        let (journal, key) = super::session()?;
        let target = Target {
            session: session.into(),
            thread: thread.into(),
            run: run.into(),
        };
        if !target.is_working(&journal, &key)? {
            return Err("This helper run already ended.".into());
        }
        let path = guard_path(&journal, &key, prompt).ok_or("Invalid prompt identity.")?;
        fs::create_dir_all(path.parent().unwrap())?;
        fs::write(path, serde_json::to_vec(&target)?)?;
        Ok(())
    };
    if let Err(error) = register() {
        println!(
            "{}",
            json!({"decision":"block","reason":format!("SwarmHub could not start the stop request. {error}")})
        );
    }
    Ok(())
}

pub(crate) fn deny_tool(
    journal: &Path,
    key: &str,
    session: &str,
    prompt: &str,
    tool: &str,
    input: Option<&Value>,
) -> bool {
    let Some(path) = guard_path(journal, key, prompt) else {
        return false;
    };
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => return error.kind() != io::ErrorKind::NotFound,
    };
    let Ok(target) = serde_json::from_slice::<Target>(&bytes) else {
        return true;
    };
    if target.session != session {
        return true;
    }
    if tool == "ToolSearch" {
        return false;
    }
    !(tool == "TaskStop"
        && input.and_then(|i| i["task_id"].as_str()) == Some(target.thread.as_str())
        && target.is_working(journal, key).unwrap_or(false))
}

pub(super) fn finished(journal: &Path, key: &str, prompt: &str) {
    if let Some(path) = guard_path(journal, key, prompt) {
        let _ = fs::remove_file(path);
    }
}
