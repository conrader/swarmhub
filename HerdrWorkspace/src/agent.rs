use crate::{
    core::MAX_FILE,
    groups::{MAX_FILES, Upload},
    history,
};
use serde::Deserialize;
use serde_json::json;
use std::{
    env,
    ffi::OsStr,
    fs::OpenOptions,
    io::{self, Read},
    os::unix::fs::OpenOptionsExt,
    os::unix::process::CommandExt,
    path::{Path, PathBuf},
    process::Command,
};

pub(crate) mod claude_preview;

const MAX_TEXT: usize = 128 * 1024;
/// How long an agent waits for its Stop hook to save the reply before giving up on it.
pub(crate) const REPLY_HOOK_SECONDS: u32 = 30;
/// The activity hook only writes one line to a local socket; a slow start must not hold a tool back for long.
pub(crate) const TOOL_HOOK_SECONDS: u32 = 5;
const MAX_HOOK: usize = 1024 * 1024;

#[derive(Deserialize)]
struct ClaudeEvent {
    hook_event_name: String,
    last_assistant_message: Option<String>,
    session_id: Option<String>,
}

pub fn run(command: &OsStr) -> Result<(), Box<dyn std::error::Error>> {
    match command.to_str() {
        Some("run-claude") => launch_claude(),
        Some("run-codex") => crate::codex_agent::launch(),
        Some("run-opencode") => crate::opencode_agent::launch(),
        Some("run-gemini") => crate::gemini_agent::launch(),
        Some("gemini-hook") => {
            crate::gemini_agent::hook();
            Ok(())
        }
        Some("opencode-models") => crate::opencode_agent::models(),
        Some("codex-models") => crate::codex_agent::models(),
        Some("run-desktop") => crate::desktop::run(),
        Some("github-read") => crate::github_project::access::cli(),
        Some("capture-opencode-reply") => crate::opencode_agent::capture_reply(),
        Some("capture-codex-reply") => {
            crate::codex_agent::capture_reply();
            Ok(())
        }
        Some("capture-claude-reply") => capture_claude(),
        Some("claude-preview-hook") => {
            claude_preview::hook();
            Ok(())
        }
        Some("review-claude-permission") => {
            crate::approvals::permission_hook(crate::approvals::Provider::Claude);
            Ok(())
        }
        Some("review-codex-permission") => {
            crate::approvals::permission_hook(crate::approvals::Provider::Codex);
            Ok(())
        }
        Some("tool-activity") => {
            crate::tool_activity::hook();
            Ok(())
        }
        Some("capture-reply") => publish("Agent", &read_input(MAX_TEXT)?),
        Some("thread-reply") => thread_reply(),
        Some("routine-result") => routine_result(),
        Some("propose-skill") => crate::skill_proposals::publish(),
        Some("propose-routine") => crate::routine_proposals::publish(),
        Some("propose-memory") => crate::memory_proposals::publish(),
        Some("propose-email") => crate::email_drafts::publish(),
        Some("worker-probe") => crate::machines::probe::cli(),
        Some("job-worker") => crate::job_worker::cli(&env::args_os().skip(2).collect::<Vec<_>>()),
        Some("fleet-policy") => crate::fleet_policy::cli(),
        Some("vault") => crate::vault::cli(),
        Some("drive-list") => crate::drive_access::cli(false),
        Some("drive-read") => crate::drive_access::cli(true),
        Some("version" | "--version") => crate::update::cli_version(),
        Some("update-probe") => crate::update::cli_probe(),
        Some("update-watch") => crate::update::cli_watch(),
        Some("publish-file") => publish_file(),
        Some(command @ ("publish-page" | "read-page" | "update-page")) => {
            crate::pages::run(command)
        }
        Some("group-reply") => group_reply(),
        Some("group-handoff") => crate::group_handoffs::publish(),
        Some("helper") => crate::helpers::cli::run(),
        Some("project") => crate::projects::cli::run(),
        Some(family @ ("bot" | "checkin" | "promise")) => crate::bots::cli::run(family),
        Some("--help" | "-h") => {
            println!(
                "swarmhub-herdr [(run-claude|run-codex) [--workspace-approvals] [AGENT_ARGS...] | capture-reply | publish-file PATH | group-reply TOKEN [--draft | --question | --form] [--file PATH]...]"
            );
            println!("OpenCode V2: run-opencode [OPENCODE_ARGS...]");
            println!("Gemini CLI (beta): run-gemini [GEMINI_ARGS...]");
            println!("This program: version [--json]");
            println!("Direct threads: thread-reply TOKEN (answer on standard input)");
            println!("Groups: group-handoff TOKEN (to and task JSON on standard input)");
            println!("Routines: routine-result TOKEN succeeded|failed (outcome on standard input)");
            println!(
                "Proposals: propose-routine (name, task, and schedule JSON on standard input)"
            );
            println!("Google Drive (granted sessions): drive-list [FOLDER] | drive-read FILE");
            println!("Memory: propose-memory (one preference or instruction on standard input)");
            println!("Email drafts: propose-email (to, subject, and body JSON on standard input)");
            println!(
                "Skills: propose-skill (name, summary, and instructions JSON on standard input)"
            );
            println!("Pages: publish-page TITLE, read-page PAGE_ID, update-page PAGE_ID REVISION");
            println!("{}", crate::fleet_policy::USAGE);
            println!("{}", crate::machines::probe::USAGE);
            println!("{}", crate::job_worker::USAGE);
            println!("{}", crate::vault::USAGE);
            println!("{}", crate::helpers::cli::USAGE);
            println!("{}", crate::projects::cli::USAGE);
            println!("{}", crate::bots::cli::USAGE);
            Ok(())
        }
        _ => Err("Unknown command. Run swarmhub-herdr --help.".into()),
    }
}

fn routine_result() -> Result<(), Box<dyn std::error::Error>> {
    use crate::routines::Outcome;
    const USAGE: &str = "Usage: swarmhub-herdr routine-result TOKEN succeeded|failed";
    let (journal, launch) = session()?;
    let mut args = env::args_os().skip(2);
    let token = args
        .next()
        .and_then(|token| token.into_string().ok())
        .filter(|token| token.len() == 32 && token.bytes().all(|c| c.is_ascii_hexdigit()))
        .ok_or(USAGE)?;
    let outcome = match args.next().as_deref().and_then(OsStr::to_str) {
        Some("succeeded") => Outcome::Succeeded,
        Some("failed") => Outcome::Failed,
        _ => return Err(USAGE.into()),
    };
    if args.next().is_some() {
        return Err(USAGE.into());
    }
    let text = read_input(MAX_TEXT)?;
    if text.trim().is_empty() {
        return Err("Enter a routine outcome on standard input.".into());
    }
    if !crate::routines::publish_result(&journal, &launch, &token, outcome, &text)
        .map_err(|_| "Could not save the routine outcome.")?
    {
        return Err("This routine result link is unavailable, or has already been used.".into());
    }
    println!("Routine outcome saved.");
    Ok(())
}

fn thread_reply() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, launch) = session()?;
    let mut args = env::args_os().skip(2);
    let token = args
        .next()
        .and_then(|token| token.into_string().ok())
        .filter(|token| {
            args.next().is_none()
                && token.len() == 32
                && token.bytes().all(|c| c.is_ascii_hexdigit())
        })
        .ok_or("Usage: swarmhub-herdr thread-reply TOKEN")?;
    let text = read_input(MAX_TEXT)?;
    if text.trim().is_empty() {
        return Err("Enter the thread answer on standard input.".into());
    }
    if !history::publish_thread_answer(&journal, &launch, &token, &text)
        .map_err(|_| "Could not save the thread answer.")?
    {
        return Err("This thread reply link is unavailable, or has already been used.".into());
    }
    println!("Answer posted to the SwarmHub thread.");
    Ok(())
}

fn group_reply() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let mut args = env::args_os().skip(2);
    let token = args
        .next()
        .and_then(|token| token.into_string().ok())
        .filter(|token| token.len() == 32 && token.bytes().all(|c| c.is_ascii_hexdigit()))
        .ok_or("A workspace group reply token is required.")?;
    let mut paths = Vec::new();
    let mut question = false;
    let mut form = false;
    let mut draft = false;
    while let Some(flag) = args.next() {
        match flag.to_str() {
            Some("--question") if !question => question = true,
            Some("--form") if !form => form = true,
            Some("--draft") if !draft => draft = true,
            Some("--file") if paths.len() < MAX_FILES => {
                paths.push(PathBuf::from(args.next().ok_or("Provide a file path after --file.")?));
            }
            _ => return Err("Usage: swarmhub-herdr group-reply TOKEN [--draft | --question | --form] [--file PATH]... (up to four files)".into()),
        }
    }
    if draft {
        if question || form || !paths.is_empty() {
            return Err("Use --draft by itself to post a progress update.".into());
        }
        let text = read_input(crate::groups::DRAFT_BYTES)?;
        if text.trim().is_empty()
            || text
                .chars()
                .any(|c| c.is_control() && !matches!(c, '\n' | '\t' | '\r'))
        {
            return Err("Write a plain-text progress update on standard input.".into());
        }
        if !crate::groups::publish_group_draft(&journal, &key, &token, text.trim())
            .map_err(|_| "Could not post the group progress update.")?
        {
            return Err("This reply link is not available for this agent.".into());
        }
        println!("Progress update posted to the SwarmHub group.");
        return Ok(());
    }
    if form && (question || !paths.is_empty()) {
        return Err("A group form is a separate reply. Use --form without other options.".into());
    }
    let text = read_input(if form {
        8192
    } else if question {
        1024
    } else {
        MAX_TEXT
    })?;
    let form = form
        .then(|| crate::group_forms::Form::parse(&text))
        .transpose()?;
    if question && text.trim().is_empty() {
        return Err("Enter the question on standard input.".into());
    }
    if text.trim().is_empty() && paths.is_empty() {
        return Err("Enter a group reply on standard input or attach a file.".into());
    }
    let mut remaining = MAX_FILE;
    let mut files = Vec::with_capacity(paths.len());
    for path in paths {
        let file = read_artifact(&path, remaining)?;
        remaining -= file.data.len();
        files.push(file);
    }
    let reply = form
        .as_ref()
        .map(|form| form.title.as_str())
        .unwrap_or_else(|| if text.trim().is_empty() { "" } else { &text });
    let form_json = form.as_ref().map(serde_json::to_string).transpose()?;
    if !crate::groups::publish_group_reply(
        &journal,
        &key,
        &token,
        reply,
        &files,
        question || form.is_some(),
        form_json.as_deref(),
    )
    .map_err(|_| "Could not save the group reply.")?
    {
        return Err("This reply link is not available for this agent.".into());
    }
    println!("Reply posted to the SwarmHub group.");
    Ok(())
}

fn publish_file() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let mut args = env::args_os().skip(2);
    let path = args
        .next()
        .map(PathBuf::from)
        .filter(|_| args.next().is_none())
        .ok_or("Usage: swarmhub-herdr publish-file PATH")?;
    let file = read_artifact(&path, MAX_FILE)?;
    if history::publish_artifact(&journal, &key, &file.name, &file.data)
        .map_err(|_| "Could not save the file.")?
        .is_none()
    {
        return Err("This agent launch is no longer registered in the workspace.".into());
    }
    println!("Published {} to the SwarmHub Library.", file.name);
    Ok(())
}

fn read_artifact(path: &Path, limit: usize) -> Result<Upload, Box<dyn std::error::Error>> {
    let name = path
        .file_name()
        .and_then(OsStr::to_str)
        .filter(|name| crate::core::valid_filename(name))
        .ok_or("Use a file with a valid UTF-8 name of up to 180 bytes.")?;
    // Reject symbolic links and avoid hanging on FIFOs before fstat.
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    let limit = limit as u64;
    if !metadata.is_file() {
        return Err("Only regular files can be published.".into());
    }
    if metadata.len() > limit {
        return Err("The files exceed the 8 MiB limit.".into());
    }
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("The files exceed the 8 MiB limit.".into());
    }
    Ok(Upload {
        name: name.into(),
        data: bytes.into(),
    })
}

fn launch_claude() -> Result<(), Box<dyn std::error::Error>> {
    let (_, launch_key) = session()?;
    let path = env::current_exe()?;
    let executable = path
        .to_str()
        .ok_or("The workspace binary path must be UTF-8.")?;
    let hook = format!("{} capture-claude-reply", shell_quote(executable));
    let mut settings = json!({
        "hooks": {
            "Stop": [{
                // Saving the reply waits on the journal's disk; a busy disk has taken longer than 5 s.
                "hooks":[{ "type":"command","command":hook,"timeout":REPLY_HOOK_SECONDS }]
            }]
        }
    });
    // Tool calls show as activity while the reply is still being written (`tool_activity`).
    let activity = format!("{} tool-activity", shell_quote(executable));
    for event in ["PreToolUse", "PostToolUse", "PostToolUseFailure"] {
        settings["hooks"][event] = json!([{
            "hooks":[{"type":"command","command":activity,"timeout":TOOL_HOOK_SECONDS}]
        }]);
    }
    let mut args: Vec<_> = env::args_os().skip(2).collect();
    if args
        .first()
        .is_some_and(|arg| arg == "--workspace-approvals")
    {
        args.remove(0);
        let command = format!("{} review-claude-permission", shell_quote(executable));
        settings["hooks"]["PermissionRequest"] =
            json!([{"hooks":[{"type":"command","command":command,"timeout":55}]}]);
    }
    let preview = args.first().is_some_and(|arg| arg == claude_preview::FLAG);
    if preview {
        args.remove(0);
    }
    if args.iter().any(|arg| {
        arg == "--settings"
            || arg
                .to_str()
                .is_some_and(|arg| arg.starts_with("--settings="))
    }) {
        return Err("run-claude reserves --settings for its reply hook. Use Claude's normal config files for other settings.".into());
    }
    // Custom templates can supply their own launch and permission arguments.
    if crate::bot_agent_settings::project_auto() && args.is_empty() {
        settings["permissions"]["defaultMode"] = json!("acceptEdits");
        settings["sandbox"] = json!({"enabled": true, "autoAllowBashIfSandboxed": true});
    }
    crate::runtimes::ModelAgent::Claude.add_model_arg(&mut args)?;
    let mut command =
        Command::new(env::var_os("SWARMHUB_CLAUDE_BIN").unwrap_or_else(|| "claude".into()));
    claude_preview::configure(
        preview,
        executable,
        &launch_key,
        &mut settings,
        &mut args,
        &mut command,
    );
    Err(command
        .env_remove(crate::runtimes::MODEL_ENV)
        .args(["--settings", &settings.to_string()])
        .args(args)
        .exec()
        .into())
}

fn capture_claude() -> Result<(), Box<dyn std::error::Error>> {
    let payload: ClaudeEvent = serde_json::from_str(&read_input(MAX_HOOK)?)?;
    if payload.hook_event_name == "Stop" {
        let result = payload
            .last_assistant_message
            .as_deref()
            .map_or(Ok(()), |text| publish("Claude Code", text));
        if let Some(session_id) = payload.session_id {
            claude_preview::clear(session_id);
        }
        result?;
    }
    Ok(())
}

pub(crate) fn session() -> Result<(PathBuf, String), Box<dyn std::error::Error>> {
    let path = env::var_os("SWARMHUB_JOURNAL")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or("Launch this agent from the SwarmHub workspace.")?;
    let key = env::var("SWARMHUB_LAUNCH_KEY")?;
    if key.len() != 32 || !key.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err("A valid workspace launch identity is required.".into());
    }
    Ok((path, key))
}

fn publish(source: &str, text: &str) -> Result<(), Box<dyn std::error::Error>> {
    if text.trim().is_empty() {
        return Ok(());
    }
    if text.len() > MAX_TEXT {
        return Err("The reply exceeds 128 KiB and remains available in the agent.".into());
    }
    let (path, key) = session()?;
    if !history::publish_reply(&path, &key, source, text, None)
        .map_err(|_| "Could not save the agent reply.")?
    {
        return Err("This agent launch is no longer registered in the workspace.".into());
    }
    Ok(())
}

pub(crate) fn read_input(limit: usize) -> Result<String, Box<dyn std::error::Error>> {
    let mut value = String::new();
    io::stdin()
        .lock()
        .take((limit + 1) as u64)
        .read_to_string(&mut value)?;
    if value.len() > limit {
        return Err("The reply hook input is too large.".into());
    }
    Ok(value)
}

pub(crate) fn shell_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', "'\"'\"'"))
}
