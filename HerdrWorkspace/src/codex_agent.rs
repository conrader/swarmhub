use crate::{
    agent::{read_input, session, shell_quote},
    history,
};
use serde::Deserialize;
use serde_json::json;
use std::{env, os::unix::process::CommandExt, process::Command};

mod models;
pub(crate) use models::Catalog as ModelCatalog;

fn executable() -> Command {
    Command::new(env::var_os("SWARMHUB_CODEX_BIN").unwrap_or_else(|| "codex".into()))
}

pub fn models() -> Result<(), Box<dyn std::error::Error>> {
    if env::args_os().nth(2).is_some() {
        return Err("Model discovery does not take arguments.".into());
    }
    let catalog = models::discover(executable())?;
    println!("{}", serde_json::to_string(&catalog)?);
    Ok(())
}

#[derive(Deserialize)]
struct Stop {
    hook_event_name: String,
    turn_id: Option<String>,
    last_assistant_message: Option<String>,
}

pub fn launch() -> Result<(), Box<dyn std::error::Error>> {
    session()?;
    let path = env::current_exe()?;
    let path = path
        .to_str()
        .filter(|path| !path.chars().any(char::is_control))
        .ok_or("The workspace binary needs a UTF-8 path without control characters.")?;
    let mut args: Vec<_> = env::args_os().skip(2).collect();
    let approvals = args
        .first()
        .is_some_and(|arg| arg == "--workspace-approvals");
    if approvals {
        args.remove(0);
    }
    crate::runtimes::ModelAgent::Codex.add_model_arg(&mut args)?;
    let mut cmd = executable();
    cmd.env_remove(crate::runtimes::MODEL_ENV);
    cmd.args([
        "-c",
        &handler(
            path,
            "Stop",
            "capture-codex-reply",
            crate::agent::REPLY_HOOK_SECONDS,
        ),
    ]);
    if approvals {
        cmd.args([
            "-c",
            &handler(path, "PermissionRequest", "review-codex-permission", 55),
        ]);
    }
    // Leave hook trust, authentication, sandboxing and approval policy to Codex.
    Err(cmd.args(args).exec().into())
}

fn handler(path: &str, event: &str, helper: &str, timeout: u32) -> String {
    let command = json!(format!("{} {helper}", shell_quote(path)));
    format!("hooks.{event}=[{{hooks=[{{type=\"command\",command={command},timeout={timeout}}}]}}]")
}

pub fn capture_reply() {
    if record_reply().is_err() {
        println!(
            "{}",
            json!({"systemMessage":"SwarmHub could not save this reply."})
        );
    } else {
        println!("{{}}");
    }
}

fn record_reply() -> Result<(), Box<dyn std::error::Error>> {
    let event: Stop = serde_json::from_str(&read_input(1024 * 1024)?)?;
    if event.hook_event_name != "Stop" {
        return Ok(());
    }
    // An unbound hook may have been installed in a shared configuration. Do not
    // record anything from Codex outside a SwarmHub-started Herdr session.
    let Ok((journal, launch)) = session() else {
        return Ok(());
    };
    let Some(text) = event
        .last_assistant_message
        .filter(|value| !value.trim().is_empty())
    else {
        return Ok(());
    };
    if text.len() > 128 * 1024 {
        return Err("The reply exceeds 128 KiB.".into());
    }
    let turn = event
        .turn_id
        .filter(|id| !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control))
        .map(|id| format!("codex:{id}"));
    if !history::publish_reply(&journal, &launch, "Codex", &text, turn.as_deref())
        .map_err(|_| "Could not save the reply.")?
    {
        return Err("Unknown launch or unavailable history.".into());
    }
    Ok(())
}
