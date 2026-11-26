//! Gemini CLI as an agent program (beta).
//!
//! Gemini CLI does not report its own status to Herdr the way Claude Code and Codex do, so `run-gemini` gives it
//! hooks that do: each one runs `swarmhub-herdr gemini-hook`, which writes the status to the terminal
//! (`status`), reports tool calls (`tool_activity`) and saves the reply when a turn ends.
//!
//! The hooks are a file in the bot's own folder, `.gemini/settings.json`. Gemini CLI reads a settings file from
//! three places: one that must belong to root (0.70.0 skips a "system defaults" file owned by anyone else), the
//! person's own, which this program never changes, and the folder it runs in. So `run-gemini` only starts in a
//! folder SwarmHub made for a bot, writes the file there, and tells Gemini CLI to trust that folder for this
//! session only. Nothing is saved about trust, and nothing under the person's own Gemini folder is written.
//!
//! Not in this first version: the reply as it is written, Allow and Deny in the chat, and asking Gemini CLI for
//! its models. Checked against Gemini CLI 0.70.0.

use crate::{
    agent::{session, shell_quote},
    history, tool_activity,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, Read, Write},
    os::unix::{fs::DirBuilderExt, process::CommandExt},
    path::Path,
    process::Command,
};

pub(crate) mod children;
mod sign_in;
pub(crate) mod startup;
pub(crate) mod status;

/// What follows this program's path in each hook's command.
const HOOK_VERB: &str = "gemini-hook";
/// The hooks, and how long Gemini CLI waits for each, in milliseconds. Saving a reply waits on the journal's disk.
const EVENTS: [(&str, u32); 7] = [
    ("SessionStart", crate::agent::TOOL_HOOK_SECONDS * 1000),
    ("SessionEnd", crate::agent::TOOL_HOOK_SECONDS * 1000),
    ("BeforeAgent", crate::agent::TOOL_HOOK_SECONDS * 1000),
    ("AfterAgent", crate::agent::REPLY_HOOK_SECONDS * 1000),
    ("BeforeTool", crate::agent::TOOL_HOOK_SECONDS * 1000),
    ("AfterTool", crate::agent::TOOL_HOOK_SECONDS * 1000),
    ("Notification", crate::agent::TOOL_HOOK_SECONDS * 1000),
];
/// What Gemini CLI gives as the reply of a turn that wrote no text.
const NO_REPLY: &str = "[no response text]";
const MAX_REPLY: usize = 128 * 1024;
/// A tool result can be a whole file. It is skipped while parsing, never held.
const HOOK_LIMIT: u64 = 64 * 1024 * 1024;
const MAX_SETTINGS: u64 = 1024 * 1024;

const NO_APPROVALS: &str = "Gemini CLI asks for permission in its own terminal, and SwarmHub cannot answer for it in the chat yet. Remove --workspace-approvals from this template.";
const NOT_A_BOT_FOLDER: &str = "Gemini (beta) only starts in a bot's own workspace folder made by SwarmHub. This folder is not one, so SwarmHub cannot add the hooks that report Gemini's status and save its replies.";
const SETTINGS_IN_THE_WAY: &str = "This bot's folder has a .gemini/settings.json that SwarmHub cannot replace. Move it away, then start the bot again.";

fn gemini() -> Command {
    crate::service::agent_command("gemini", "SWARMHUB_GEMINI_BIN")
}

/// `swarmhub-herdr run-gemini`: starts Gemini CLI in this terminal with the hooks that report to SwarmHub.
pub fn launch() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let mut args: Vec<OsString> = env::args_os().skip(2).collect();
    if args
        .first()
        .is_some_and(|arg| arg == "--workspace-approvals")
    {
        return Err(NO_APPROVALS.into());
    }
    crate::runtimes::ModelAgent::Gemini.add_model_arg(&mut args)?;
    let folder = env::current_dir()?;
    if !bridge_made(&folder) {
        return Err(NOT_A_BOT_FOLDER.into());
    }
    let exe = env::current_exe()?;
    let exe = exe
        .to_str()
        .filter(|path| !path.chars().any(char::is_control))
        .ok_or("The workspace binary needs a UTF-8 path without control characters.")?;
    install_hooks(&folder, exe)?;
    let tty = crate::opencode_agent::terminal_path().unwrap_or_default();
    startup::register(&journal, &key, Path::new(&tty));
    let mut command = gemini();
    command
        .env_remove(crate::runtimes::MODEL_ENV)
        // Only this session trusts the folder, and only because SwarmHub made it (`bridge_made`). Gemini CLI
        // runs no hook in a folder it does not trust, and would stop at a question nobody is there to answer.
        .env("GEMINI_CLI_TRUST_WORKSPACE", "true")
        .env(status::TTY_ENV, tty);
    // Leave signing in, permissions and sandboxing to Gemini CLI.
    let error = command.args(args).exec();
    startup::finish(&journal, &key);
    Err(error.into())
}

/// Whether SwarmHub made this folder for a bot: it carries the empty marker file (`core::bot_workspace`).
pub(crate) fn bridge_made(folder: &Path) -> bool {
    fs::symlink_metadata(folder.join(".swarmhub-workspace"))
        .is_ok_and(|meta| meta.is_file() && meta.len() == 0)
}

/// The settings file `run-gemini` keeps in a bot's folder: the hooks, and no updating in a terminal nobody
/// watches.
fn settings(exe: &str) -> Value {
    let command = format!("{} {HOOK_VERB}", shell_quote(exe));
    let hooks: serde_json::Map<String, Value> = EVENTS
        .iter()
        .map(|(event, timeout)| {
            let hook =
                json!({"type":"command","name":"swarmhub","command":command,"timeout":timeout});
            ((*event).to_owned(), json!([{"hooks":[hook]}]))
        })
        .collect();
    json!({"general":{"enableAutoUpdate":false},"hooks":hooks})
}

/// Writes `.gemini/settings.json` in the bot's folder. The file is SwarmHub's: it is written again whenever it
/// differs, so nothing an agent adds to it is in force at the next start. A file someone else wrote is kept
/// beside it once, as `settings.json.before-swarmhub`.
fn install_hooks(folder: &Path, exe: &str) -> Result<(), Box<dyn std::error::Error>> {
    let directory = folder.join(".gemini");
    match fs::symlink_metadata(&directory) {
        Ok(meta) if meta.is_dir() => (),
        // A link could lead into the person's own Gemini folder. Never write through one.
        Ok(_) => return Err(SETTINGS_IN_THE_WAY.into()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            fs::DirBuilder::new().mode(0o700).create(&directory)?;
        }
        Err(error) => return Err(error.into()),
    }
    let file = directory.join("settings.json");
    let text = serde_json::to_string_pretty(&settings(exe))?;
    match fs::symlink_metadata(&file) {
        Ok(meta) if !meta.is_file() || meta.len() > MAX_SETTINGS => {
            return Err(SETTINGS_IN_THE_WAY.into());
        }
        Ok(_) => {
            let old = fs::read(&file)?;
            if old == text.as_bytes() {
                return Ok(());
            }
            if !String::from_utf8_lossy(&old).contains(HOOK_VERB) {
                fs::rename(&file, directory.join("settings.json.before-swarmhub"))?;
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => (),
        Err(error) => return Err(error.into()),
    }
    let mut draft = tempfile::NamedTempFile::new_in(&directory)?;
    draft.write_all(text.as_bytes())?;
    draft.persist(file)?;
    Ok(())
}

/// What a hook tells on standard input. Everything else in it is skipped.
#[derive(Deserialize)]
struct Event {
    session_id: Option<String>,
    transcript_path: Option<String>,
    cwd: Option<String>,
    hook_event_name: String,
    tool_name: Option<String>,
    tool_input: Option<Value>,
    tool_response: Option<ToolResponse>,
    prompt_response: Option<String>,
    notification_type: Option<String>,
    reason: Option<String>,
}

#[derive(Deserialize)]
struct ToolResponse {
    #[serde(default)]
    error: Option<serde::de::IgnoredAny>,
}

/// The status a hook reports to Herdr, as `(state, kind)`; `None` when the hook says nothing about it.
///
/// Gemini CLI starts its session, and runs SessionStart, while it still shows its sign-in question. A first
/// message typed then would answer that question, so without a chosen sign-in it is `blocked`, never ready.
/// Nothing runs when a turn is cancelled or a permission refused; `status::after_stop` covers the app's Stop.
fn reported(event: &Event, signed_in: bool) -> Option<(&'static str, Option<&'static str>)> {
    match event.hook_event_name.as_str() {
        "SessionStart" if signed_in => Some(("idle", None)),
        "SessionStart" => Some(("blocked", Some("auth"))),
        "BeforeAgent" | "AfterTool" => Some(("working", None)),
        "BeforeTool" if event.tool_name.as_deref() == Some("ask_user") => {
            Some(("blocked", Some("question")))
        }
        "BeforeTool" => Some(("working", None)),
        "Notification" if event.notification_type.as_deref() == Some("ToolPermission") => {
            Some(("blocked", Some("permission")))
        }
        "AfterAgent" => Some(("done", None)),
        _ => None,
    }
}

/// The text of a finished turn worth saving: all the turn wrote, or nothing when it wrote no text.
fn reply(event: &Event) -> Option<&str> {
    event
        .prompt_response
        .as_deref()
        .filter(|text| !text.trim().is_empty() && text.trim() != NO_REPLY)
}

/// `swarmhub-herdr gemini-hook`: one command for every hook. It answers `{}` and succeeds whatever happens, so
/// it can never refuse a prompt, block a tool or ask Gemini CLI to try a turn again.
pub fn hook() {
    let answer = match handle() {
        Ok(()) => json!({}),
        Err(()) => json!({"systemMessage":"SwarmHub could not save this reply."}),
    };
    let _ = writeln!(io::stdout(), "{answer}");
}

/// Err only when a reply could not be saved.
fn handle() -> Result<(), ()> {
    // The hooks file may be read by a Gemini CLI someone started by hand in the bot's folder. Report nothing
    // from outside a session SwarmHub started.
    let Ok((journal, key)) = session() else {
        return Ok(());
    };
    let Ok(event) = serde_json::from_reader::<_, Event>(io::stdin().lock().take(HOOK_LIMIT)) else {
        return Ok(());
    };
    children::observe(&journal, &key, &event);
    let mut saved = Ok(());
    match event.hook_event_name.as_str() {
        "SessionStart" => {
            startup::finish(&journal, &key);
            status::remember(&journal, &key);
        }
        // Clearing the conversation ends a session and starts the next one in the same terminal.
        "SessionEnd" if event.reason.as_deref() != Some("clear") => {
            status::forget(&journal, &key);
        }
        "BeforeTool" | "AfterTool" => {
            if let Some(tool) = event.tool_name.as_deref().filter(|tool| !tool.is_empty()) {
                let phase = match (&event.tool_response, event.hook_event_name.as_str()) {
                    (_, "BeforeTool") => tool_activity::Phase::Started,
                    (Some(ToolResponse { error: Some(_) }), _) => tool_activity::Phase::Failed,
                    _ => tool_activity::Phase::Finished,
                };
                tool_activity::send(
                    &journal,
                    key.clone(),
                    phase,
                    tool,
                    event.tool_input.as_ref(),
                    None,
                );
            }
        }
        "AfterAgent" => {
            if let Some(text) = reply(&event) {
                saved = if text.len() > MAX_REPLY {
                    Err(())
                } else {
                    match history::publish_reply(
                        &journal,
                        &key,
                        crate::runtimes::GEMINI,
                        text,
                        None,
                    ) {
                        Ok(true) => Ok(()),
                        _ => Err(()),
                    }
                };
            }
        }
        _ => (),
    }
    // The reply is saved before the turn reads as done.
    let signed_in = event.hook_event_name != "SessionStart" || sign_in::chosen();
    if let Some((state, kind)) = reported(&event, signed_in) {
        status::report(state, kind);
    }
    saved
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(value: Value) -> Event {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn the_settings_file_gives_every_hook_the_same_quiet_command() {
        let settings = settings("/opt/swarm hub/swarmhub-herdr");
        assert_eq!(settings["general"]["enableAutoUpdate"], false);
        let hooks = settings["hooks"].as_object().unwrap();
        assert_eq!(hooks.len(), 7);
        for (name, timeout) in EVENTS {
            let hook = &hooks[name][0]["hooks"][0];
            assert_eq!(hook["type"], "command");
            assert_eq!(
                hook["command"],
                "'/opt/swarm hub/swarmhub-herdr' gemini-hook"
            );
            // Gemini CLI counts in milliseconds.
            assert_eq!(hook["timeout"], timeout);
            assert!(timeout >= 5000);
        }
        assert_eq!(hooks["AfterAgent"][0]["hooks"][0]["timeout"], 30_000);
        // Nothing here chooses an approval mode, a sandbox or a way to sign in.
        assert_eq!(settings.as_object().unwrap().len(), 2);
    }

    #[test]
    fn each_hook_reports_the_status_it_stands_for() {
        let status = |value: Value, signed_in| reported(&event(value), signed_in);
        let named = |name: &str| json!({"hook_event_name":name});
        assert_eq!(status(named("SessionStart"), true), Some(("idle", None)));
        // The sign-in question is on screen: never ready.
        assert_eq!(
            status(named("SessionStart"), false),
            Some(("blocked", Some("auth")))
        );
        assert_eq!(status(named("BeforeAgent"), true), Some(("working", None)));
        assert_eq!(
            status(
                json!({"hook_event_name":"BeforeTool","tool_name":"run_shell_command"}),
                true
            ),
            Some(("working", None))
        );
        assert_eq!(
            status(
                json!({"hook_event_name":"BeforeTool","tool_name":"ask_user"}),
                true
            ),
            Some(("blocked", Some("question")))
        );
        assert_eq!(
            status(
                json!({"hook_event_name":"Notification","notification_type":"ToolPermission",
                       "message":"Tool Confirm Shell Command requires execution",
                       "details":{"type":"exec","command":"touch a","rootCommand":"touch"}}),
                true
            ),
            Some(("blocked", Some("permission")))
        );
        assert_eq!(
            status(
                json!({"hook_event_name":"Notification","notification_type":"Other"}),
                true
            ),
            None
        );
        assert_eq!(status(named("AfterTool"), true), Some(("working", None)));
        assert_eq!(status(named("AfterAgent"), true), Some(("done", None)));
        assert_eq!(status(named("SessionEnd"), true), None);
        assert_eq!(status(named("BeforeModel"), true), None);
    }

    #[test]
    fn a_turn_without_text_saves_no_reply() {
        let text = |value: Value| reply(&event(value)).map(str::to_owned);
        let turn = |response: &str| json!({"hook_event_name":"AfterAgent","prompt":"Hi","prompt_response":response,"stop_hook_active":false});
        assert_eq!(
            text(turn("First.\nSecond.")).as_deref(),
            Some("First.\nSecond.")
        );
        assert_eq!(text(turn("[no response text]")), None);
        assert_eq!(text(turn("  \n")), None);
        assert_eq!(text(json!({"hook_event_name":"AfterAgent"})), None);
    }

    #[test]
    fn a_tool_result_is_read_only_for_whether_it_failed() {
        let failed = |value: Value| {
            matches!(
                event(value).tool_response,
                Some(ToolResponse { error: Some(_) })
            )
        };
        assert!(!failed(
            json!({"hook_event_name":"AfterTool","tool_name":"read_file",
            "tool_response":{"llmContent":"x".repeat(4096),"returnDisplay":[[{"text":"x"}]]}})
        ));
        assert!(failed(
            json!({"hook_event_name":"AfterTool","tool_name":"read_file",
            "tool_response":{"llmContent":"","error":{"message":"No such file"}}})
        ));
    }

    #[test]
    fn hooks_go_only_into_a_folder_swarmhub_made_and_never_through_a_link() {
        let root = tempfile::tempdir().unwrap();
        let folder = root.path().join("bot");
        fs::create_dir(&folder).unwrap();
        assert!(!bridge_made(&folder));
        fs::write(folder.join(".swarmhub-workspace"), b"").unwrap();
        assert!(bridge_made(&folder));
        // A marker with something in it is not the one SwarmHub writes.
        let other = root.path().join("other");
        fs::create_dir(&other).unwrap();
        fs::write(other.join(".swarmhub-workspace"), b"x").unwrap();
        assert!(!bridge_made(&other));

        install_hooks(&folder, "/usr/bin/swarmhub-herdr").unwrap();
        let file = folder.join(".gemini/settings.json");
        let written: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        assert_eq!(written, settings("/usr/bin/swarmhub-herdr"));
        // What an agent adds is gone at the next start, and SwarmHub's own older file leaves no copy.
        fs::write(&file, r#"{"hooks":{"BeforeTool":[{"hooks":[{"type":"command","command":"'/usr/bin/swarmhub-herdr' gemini-hook; touch /tmp/x"}]}]}}"#).unwrap();
        install_hooks(&folder, "/usr/bin/swarmhub-herdr").unwrap();
        let written: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        assert_eq!(written, settings("/usr/bin/swarmhub-herdr"));
        assert!(
            !folder
                .join(".gemini/settings.json.before-swarmhub")
                .exists()
        );
        // A file someone else wrote is kept beside it.
        fs::write(&file, r#"{"ui":{"theme":"Default"}}"#).unwrap();
        install_hooks(&folder, "/usr/bin/swarmhub-herdr").unwrap();
        assert_eq!(
            fs::read_to_string(folder.join(".gemini/settings.json.before-swarmhub")).unwrap(),
            r#"{"ui":{"theme":"Default"}}"#
        );

        // A linked settings folder could be the person's own. It is refused and left alone.
        let own = root.path().join("own-gemini");
        fs::create_dir(&own).unwrap();
        let linked = root.path().join("linked");
        fs::create_dir(&linked).unwrap();
        std::os::unix::fs::symlink(&own, linked.join(".gemini")).unwrap();
        assert!(install_hooks(&linked, "/usr/bin/swarmhub-herdr").is_err());
        assert!(fs::read_dir(&own).unwrap().next().is_none());
        fs::remove_file(&file).unwrap();
        std::os::unix::fs::symlink(own.join("settings.json"), &file).unwrap();
        assert!(install_hooks(&folder, "/usr/bin/swarmhub-herdr").is_err());
        assert!(fs::read_dir(&own).unwrap().next().is_none());
    }
}
