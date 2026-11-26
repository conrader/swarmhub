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

pub(crate) const RETRY_MS: i64 = 60_000;
const INSTRUCTION: &str = " Use TaskStop only for this task_id.";

pub(crate) fn message(thread: &str, run: &str) -> String {
    format!("{PREFIX}{thread} {run}.{INSTRUCTION}")
}

// Claude Code can wrap multiline terminal input in a pasted_content element.
fn content(text: &str) -> &str {
    let trimmed = text.trim_start();
    if trimmed.starts_with("<pasted_content id=\"")
        && let Some((_, body)) = trimmed.split_once('\n')
    {
        return body.trim_start();
    }
    trimmed
}

fn target_line(text: &str) -> Option<(&str, &str)> {
    let line = content(text).lines().next()?.strip_prefix(PREFIX)?;
    let (thread, run) = line
        .strip_suffix(&format!(".{INSTRUCTION}"))?
        .split_once(' ')?;
    (identifier(thread) && identifier(run)).then_some((thread, run))
}

pub(crate) fn is_control_message(text: &str) -> bool {
    target_line(text).is_some_and(|(thread, run)| message(thread, run) == text)
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
    let Some(text) = e["prompt"]
        .as_str()
        .filter(|s| content(s).starts_with(PREFIX))
    else {
        return Ok(());
    };
    let register = || -> Result<(), Box<dyn std::error::Error>> {
        let (thread, run) = target_line(text).ok_or("Invalid stop request.")?;
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
        history::connection(&journal)?.execute(
            "UPDATE claude_children SET record=json_set(record,'$.requested_prompt',?)
             WHERE launch=(SELECT id FROM journal WHERE launch_key=?) AND thread=?
             AND json_extract(summary,'$.active_turn')=?",
            params![prompt, key, thread, run],
        )?;
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

// An unrecognized paste or a missing prompt ID must not turn a pending stop into
// an unrestricted TaskStop. Ordinary, unrelated prompts can act once the request is bound.
fn unbound_stop(journal: &Path, key: &str, session: &str, tool: &str) -> bool {
    if tool != "TaskStop" {
        return false;
    }
    let pending = || -> rusqlite::Result<bool> {
        history::connection(journal)?.query_row(
            "SELECT EXISTS(SELECT 1 FROM claude_children c JOIN journal j ON j.id=c.launch
             WHERE j.launch_key=? AND json_extract(c.record,'$.session')=?
             AND json_extract(c.record,'$.requested_at')>?
             AND json_extract(c.record,'$.requested_prompt') IS NULL)",
            params![key, session, history::now() - RETRY_MS],
            |r| r.get(0),
        )
    };
    pending().unwrap_or(true)
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
        return unbound_stop(journal, key, session, tool);
    };
    let bytes = match fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => {
            return error.kind() != io::ErrorKind::NotFound
                || unbound_stop(journal, key, session, tool);
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recognizes_the_typed_command_and_claude_paste_wrapper() {
        let command = message("child", "2");
        assert!(is_control_message(&command));
        let pasted = format!(
            "\n\n<pasted_content id=\"512\">\n{command}\n\n[SwarmHub person profile] Example\n</pasted_content>"
        );
        assert_eq!(target_line(&pasted), Some(("child", "2")));
        assert!(!is_control_message(&pasted));
        assert_eq!(
            target_line(&format!("Please explain this:\n{command}")),
            None
        );
    }
}
