use crate::{
    agent::{read_input, session, shell_quote},
    history,
};
use serde::Deserialize;
use serde_json::json;
use std::{env, os::unix::process::CommandExt, path::Path, process::Command};

mod assignments;
mod models;
mod prefetch;
mod recovery;
pub(crate) use recovery::recover_sessions;
pub(crate) mod stream;
pub(crate) mod trust;
pub(crate) use models::Catalog as ModelCatalog;

fn executable() -> Command {
    crate::service::agent_command("codex", "SWARMHUB_CODEX_BIN")
}

pub(crate) fn account() -> std::io::Result<crate::runtime_account::Account> {
    models::account(executable())
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
    let (journal, key) = session()?;
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
    // Only a launch without arguments of its own gets the reply as it is written (`stream`): anything else
    // (a resumed session, a fixed sandbox) starts exactly as the template says.
    let plain = args.is_empty();
    let auto_enabled = plain && crate::bot_agent_settings::project_auto();
    crate::runtimes::ModelAgent::Codex.add_model_arg(&mut args)?;
    // In Auto mode, Codex's own `auto_review` guardian reviews escalated requests; registering
    // `PermissionRequest` here would intercept them first and stall for 45 s waiting in chat.
    let (mut hooks, commands) = hook_values(path, approvals && !auto_enabled);
    // Where the person agreed to it at setup, Codex is told at launch that these hooks, and no others, are
    // trusted, so it does not stop to ask in a terminal nobody is looking at (`trust`).
    if let Some(trusted) = trust::flag(&journal, executable(), &hooks, &commands) {
        hooks.push(trusted);
    }
    let (remote_auto, server_only_auto) = if auto_enabled {
        auto_configs(true, &crate::bot_agent_settings::auto_writable_dirs())
    } else {
        (Vec::new(), Vec::new())
    };
    let mut server_configs = hooks;
    server_configs.extend(remote_auto.iter().cloned());
    server_configs.extend(server_only_auto);
    let mut cmd = executable();
    // The terminal may be unattended. Leave optional upgrades to interactive launches outside SwarmHub.
    cmd.args(["-c", "check_for_update_on_startup=false"]);
    cmd.env_remove(crate::runtimes::MODEL_ENV);
    // Codex reads its state databases as it starts. Have them in memory by then (`prefetch`).
    prefetch::start();
    if !plain {
        stream::starts_whole(
            &journal,
            &key,
            "the template gives Codex arguments of its own, so it was started exactly as written.",
        );
    }
    match plain
        .then(|| stream::start(&journal, &key, path, &server_configs))
        .flatten()
    {
        // The hooks and writable roots run in the session's app server (`--remote` rejects
        // `writable_roots` on the client); policy and reviewer overrides go to both.
        Some(server) => cmd
            .args(remote_auto.iter().flat_map(|cfg| ["-c", cfg.as_str()]))
            .args(["--remote", &server]),
        None => cmd.args(server_configs.iter().flat_map(|hook| ["-c", hook.as_str()])),
    };
    // Codex enforces its sandbox and handles requests for broader access.
    Err(cmd.args(args).exec().into())
}

pub(crate) fn auto_configs(
    auto: bool,
    writable: &[std::path::PathBuf],
) -> (Vec<String>, Vec<String>) {
    if !auto {
        return (Vec::new(), Vec::new());
    }
    let remote = vec![
        r#"sandbox_mode="workspace-write""#.to_owned(),
        "approval_policy={granular={sandbox_approval=true,rules=true,skill_approval=false,request_permissions=false,mcp_elicitations=false}}".to_owned(),
        r#"approvals_reviewer="auto_review""#.to_owned(),
        r#"computer_use.default_app_access="allow""#.to_owned(),
    ];
    let mut server_only = Vec::new();
    let roots: Vec<&str> = writable.iter().filter_map(|p| p.to_str()).collect();
    if !roots.is_empty()
        && let Ok(encoded) = serde_json::to_string(&roots)
    {
        server_only.push(format!("sandbox_workspace_write.writable_roots={encoded}"));
    }
    (remote, server_only)
}

/// The hooks `run-codex` gives Codex, as `-c` values, and the command of each.
/// Codex remembers each of these definitions by its text and asks again when one changes. Keep them as they are.
pub(crate) fn hook_values(path: &str, approvals: bool) -> (Vec<String>, Vec<String>) {
    let mut wanted = vec![
        (
            "Stop",
            "capture-codex-reply",
            crate::agent::REPLY_HOOK_SECONDS,
        ),
        (
            "PreToolUse",
            "tool-activity",
            crate::agent::TOOL_HOOK_SECONDS,
        ),
        (
            "PostToolUse",
            "tool-activity",
            crate::agent::TOOL_HOOK_SECONDS,
        ),
    ];
    if approvals {
        wanted.push(("PermissionRequest", "review-codex-permission", 55));
    }
    let hooks = wanted
        .iter()
        .map(|(event, helper, timeout)| handler(path, event, helper, *timeout))
        .collect();
    let mut commands: Vec<String> = Vec::new();
    for (_, helper, _) in wanted {
        let command = hook_command(path, helper);
        if !commands.contains(&command) {
            commands.push(command);
        }
    }
    (hooks, commands)
}

fn hook_command(path: &str, helper: &str) -> String {
    format!("{} {helper}", shell_quote(path))
}

fn handler(path: &str, event: &str, helper: &str, timeout: u32) -> String {
    let command = json!(hook_command(path, helper));
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
    save_reply(&journal, &launch, event.turn_id.as_deref(), &text)
}

fn valid_turn(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && !id.chars().any(char::is_control)
}

const MAX_REPLY_BYTES: usize = 128 * 1024;

fn save_reply(
    journal: &Path,
    launch: &str,
    turn: Option<&str>,
    text: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    if text.len() > MAX_REPLY_BYTES {
        return Err("The reply exceeds 128 KiB.".into());
    }
    let turn = turn
        .filter(|id| valid_turn(id))
        .map(|id| format!("codex:{id}"));
    if !history::publish_reply(journal, launch, "Codex", text, turn.as_deref())
        .map_err(|_| "Could not save the reply.")?
    {
        return Err("Unknown launch or unavailable history.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::auto_configs;

    #[test]
    fn auto_configs_keep_writable_roots_server_only_for_remote_sessions() {
        assert_eq!(auto_configs(false, &[]), (Vec::new(), Vec::new()));
        assert_eq!(
            auto_configs(true, &[]),
            (
                vec![
                    r#"sandbox_mode="workspace-write""#.to_owned(),
                    "approval_policy={granular={sandbox_approval=true,rules=true,skill_approval=false,request_permissions=false,mcp_elicitations=false}}".to_owned(),
                    r#"approvals_reviewer="auto_review""#.to_owned(),
                    r#"computer_use.default_app_access="allow""#.to_owned(),
                ],
                Vec::new(),
            )
        );
        let scratch = tempfile::tempdir().unwrap();
        let spool = scratch.path().join(".swarmhub-helpers");
        let results = scratch.path().join("results");
        std::fs::create_dir_all(&spool).unwrap();
        std::fs::create_dir_all(&results).unwrap();
        let writable = crate::bot_agent_settings::auto_writable_dirs_from(
            Some(spool.clone().into_os_string()),
            Some(results.clone().into_os_string()),
        );
        let (remote, server_only) = auto_configs(true, &writable);
        assert_eq!(remote.len(), 4);
        assert!(remote.iter().all(|c| !c.contains("writable_roots")));
        assert_eq!(server_only.len(), 1);
        assert!(server_only[0].starts_with("sandbox_workspace_write.writable_roots=["));
        assert!(server_only[0].contains(spool.to_str().unwrap()));
        assert!(server_only[0].contains(results.to_str().unwrap()));
    }
}
