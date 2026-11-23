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

pub mod first_task;
pub mod follow_up;
pub mod models;

const PACKAGE: &str =
    r#"{"name":"swarmhub-opencode","version":"0.1.0","type":"module","exports":"./reply.js"}"#;
const REPLY: &str = include_str!("opencode-reply.js");
const APPROVALS: &str = include_str!("opencode-approvals.js");

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
    let mut args = env::args_os().skip(2).collect::<Vec<_>>();
    let approvals = args
        .first()
        .is_some_and(|arg| arg == "--workspace-approvals");
    if approvals {
        args.remove(0);
    }
    let api_first_task = first_task::take_flag(&mut args);
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
        cmd.env_remove(crate::runtimes::MODEL_ENV)
            .env_remove(first_task::ENV)
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
                if approvals { "1" } else { "" },
            );
        cmd
    };
    if let Some(handoff) = handoff {
        let model = args.get(2).map(|id| id.to_string_lossy().into_owned());
        first_task::run(command(), command(), handoff, model)?;
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
