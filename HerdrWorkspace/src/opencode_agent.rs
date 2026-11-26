use crate::{
    agent::{read_input, session},
    history,
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    env,
    ffi::{CStr, OsString},
    fs,
    io::Write,
    os::unix::{ffi::OsStrExt, fs::DirBuilderExt, process::CommandExt},
    path::Path,
    process::{Command, Stdio},
};

mod children;
pub(crate) mod spend;
pub(crate) use children::{capture as capture_child, interrupt};
pub mod first_task;
pub mod follow_up;
pub mod models;

const PACKAGE: &str =
    r#"{"name":"swarmhub-opencode","version":"0.1.0","type":"module","exports":"./reply.js"}"#;
const USAGE_ROOT: &str = "SWARMHUB_OPENCODE_USAGE_ROOT";
const REPLY: &str = include_str!("opencode-reply.js");
const APPROVALS: &str = include_str!("opencode-approvals.js");

/// Add only denials to the session. The user's existing rules still govern file reads.
/// The private plugin supplies the allowlist for built-in, third-party and future tools.
fn document_permissions() -> Value {
    Value::Array(["bash", "edit", "write", "apply_patch", "task", "skill"].map(|action|
        json!({"action": action, "resource": "*", "effect": "deny"})
    ).into())
}

fn opencode() -> Command {
    crate::service::agent_command("opencode", "SWARMHUB_OPENCODE_BIN")
}

pub fn models() -> Result<(), Box<dyn std::error::Error>> {
    if env::args_os().nth(2).is_some() {
        return Err("Model discovery does not take arguments.".into());
    }
    Err(opencode()
        .args(["--standalone", "models"])
        .stdin(Stdio::null())
        .exec()
        .into())
}

pub fn launch() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let (cap, read_only): (Option<i64>, bool) = rusqlite::Connection::open_with_flags(&journal, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?
        .query_row("SELECT session_cap_cents,document_read_only FROM journal WHERE launch_key=?1", [&key], |row| Ok((row.get(0)?, row.get(1)?)))?;
    let mut args = env::args_os().skip(2).collect::<Vec<_>>();
    let approvals = args
        .first()
        .is_some_and(|arg| arg == "--workspace-approvals");
    if approvals {
        args.remove(0);
    }
    let api_first_task = first_task::take_flag(&mut args);
    if read_only && !api_first_task {
        return Err("Document review requires a private OpenCode API session.".into());
    }
    if cap.is_some() && !api_first_task {
        return Err("A capped OpenCode session requires the private API launcher.".into());
    }
    let handoff = if api_first_task {
        if args.len() != 1 || args[0] != "mini" {
            return Err("--api-first-task requires a plain Mini template.".into());
        }
        Some(first_task::Handoff::claim(&journal, &key)?)
    } else {
        if env::var_os(first_task::ENV).is_some_and(|path| !path.is_empty()) {
            return Err("The OpenCode template changed during the launch.".into());
        }
        None
    };
    if args.iter().any(|arg| {
        arg.to_str().is_some_and(|arg| {
            matches!(arg, "--server" | "--attach")
                || arg.starts_with("--server=")
                || arg.starts_with("--attach=")
        })
    }) {
        return Err(
            "run-opencode uses a private OpenCode V2 server. Remove --server or --attach.".into(),
        );
    }
    crate::runtimes::ModelAgent::OpenCode.add_model_arg(&mut args)?;
    let root = journal.parent().ok_or("No workspace directory.")?;
    let plugin = root.join("opencode-plugin");
    fs::DirBuilder::new()
        .mode(0o700)
        .recursive(true)
        .create(&plugin)?;
    write_plugin(&plugin, "reply.js", REPLY)?;
    write_plugin(&plugin, "spend.js", include_str!("opencode-spend.js"))?;
    write_plugin(&plugin, "child-control.js", include_str!("opencode-child-control.js"))?;
    write_plugin(&plugin, "children.js", include_str!("opencode-children.js"))?;
    write_plugin(&plugin, "approvals.js", APPROVALS)?;
    write_plugin(&plugin, "package.json", PACKAGE)?;

    let mut config = match env::var("OPENCODE_CONFIG_CONTENT") {
        Ok(contents) => serde_json::from_str::<Value>(&contents).map_err(
            |_| "Use a JSON object for OPENCODE_CONFIG_CONTENT or use an OpenCode config file.",
        )?,
        Err(env::VarError::NotPresent) => json!({}),
        Err(error) => return Err(error.into()),
    };
    let plugins = config
        .as_object_mut()
        .ok_or("OPENCODE_CONFIG_CONTENT must be a JSON object.")?
        .entry("plugins")
        .or_insert_with(|| json!([]))
        .as_array_mut()
        .ok_or("OpenCode V2 plugins must be a list.")?;
    let entry = Value::String(
        plugin
            .to_str()
            .ok_or("The workspace path must be UTF-8.")?
            .into(),
    );
    if !plugins.contains(&entry) {
        plugins.push(entry);
    }
    let executable = env::current_exe()?;
    let config = serde_json::to_string(&config)?;
    let tty = terminal_path().unwrap_or_default();
    let command = || {
        let mut cmd = opencode();
        cmd.env("SWARMHUB_OPENCODE_CAP_CENTS", cap.map(|c| c.to_string()).unwrap_or_default())
            .env("SWARMHUB_OPENCODE_DOCUMENT_REVIEW", if read_only { "1" } else { "" })
            .env_remove(crate::runtimes::MODEL_ENV)
            .env_remove(first_task::ENV)
            .env_remove(USAGE_ROOT)
            .env("OPENCODE_CONFIG_CONTENT", &config)
            .env("SWARMHUB_OPENCODE_CAPTURE_BIN", &executable)
            .env("SWARMHUB_REPLY_SOCKET", root.join("replies.sock"))
            .env("SWARMHUB_STATUS_TTY", &tty)
            .env(
                "SWARMHUB_OPENCODE_GROUP_PREVIEW",
                if api_first_task { "1" } else { "" },
            )
            .env(
                "SWARMHUB_OPENCODE_APPROVALS",
                if approvals && !crate::bot_agent_settings::project_auto() {
                    "1"
                } else {
                    ""
                },
            );
        cmd
    };
    if let Some(handoff) = handoff {
        let model = args.get(2).map(|id| id.to_string_lossy().into_owned());
        first_task::run(command(), command(), handoff, model, cap.is_some(), read_only)?;
        return Ok(());
    }
    Err(command().arg("--standalone").args(args).exec().into())
}

pub(crate) fn terminal_path() -> Option<OsString> {
    for fd in [libc::STDOUT_FILENO, libc::STDIN_FILENO, libc::STDERR_FILENO] {
        let mut path = [0 as libc::c_char; 512];
        // ttyname_r fills a caller-owned, NUL-terminated buffer on success.
        if unsafe { libc::ttyname_r(fd, path.as_mut_ptr(), path.len()) } == 0 {
            let path = unsafe { CStr::from_ptr(path.as_ptr()) };
            return Some(std::ffi::OsStr::from_bytes(path.to_bytes()).to_owned());
        }
    }
    None
}

fn write_plugin(directory: &Path, name: &str, contents: &str) -> std::io::Result<()> {
    let path = directory.join(name);
    if fs::read(&path).is_ok_and(|bytes| bytes == contents.as_bytes()) {
        return Ok(());
    }
    let mut file = tempfile::NamedTempFile::new_in(directory)?;
    file.write_all(contents.as_bytes())?;
    file.persist(path)?;
    Ok(())
}

#[derive(Deserialize)]
struct Reply {
    id: String,
    text: String,
}

#[derive(Deserialize)]
struct UsageSnapshot {
    session: String,
    cost: f64,
    total_tokens: i64,
}

pub fn capture_usage() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, launch) = session()?;
    let snapshot: UsageSnapshot = serde_json::from_str(&read_input(1024)?)?;
    if !first_task::valid_session(&snapshot.session)
        || !snapshot.cost.is_finite()
        || snapshot.cost < 0.0
        || snapshot.total_tokens < 0
    {
        return Err("Invalid OpenCode session usage.".into());
    }
    let report = crate::session_usage::SessionUsage {
        context_tokens: None,
        window_tokens: None,
        total_tokens: snapshot.total_tokens,
        opencode_cost_usd: Some(snapshot.cost),
    };
    let db = rusqlite::Connection::open_with_flags(
        journal, rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE,
    )?;
    db.busy_timeout(std::time::Duration::from_millis(600))?;
    db.execute(
        "UPDATE journal SET usage_thread=?2, session_usage=?3 WHERE launch_key=?1",
        rusqlite::params![launch, snapshot.session, serde_json::to_string(&report)?],
    )?;
    Ok(())
}

pub fn capture_reply() -> Result<(), Box<dyn std::error::Error>> {
    let Ok((journal, launch)) = session() else {
        return Ok(());
    };
    let event: Reply = serde_json::from_str(&read_input(1024 * 1024)?)?;
    if !valid_reply_id(&event.id) || event.text.len() > 128 * 1024 {
        return Err("Invalid OpenCode reply.".into());
    }
    if !event.text.trim().is_empty()
        && !history::publish_reply(
            &journal,
            &launch,
            "OpenCode",
            &event.text,
            Some(&format!("opencode:{}", event.id)),
        )
        .map_err(|_| "Could not save the OpenCode reply.")?
    {
        return Err("Unknown workspace launch.".into());
    }
    Ok(())
}

pub fn valid_reply_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 128
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
}
