use serde_json::{Value, json};
use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

fn claude(root: &Path) -> Command {
    let fixture = root.join("claude");
    fs::write(&fixture, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n").unwrap();
    fs::set_permissions(&fixture, fs::Permissions::from_mode(0o700)).unwrap();
    let workspace = root.join("bot workspace");
    fs::create_dir_all(&workspace).unwrap();
    let mut command = Command::new(env!("CARGO_BIN_EXE_swarmhub-herdr"));
    command
        .env_clear()
        .env("HOME", root)
        .env("SWARMHUB_CLAUDE_BIN", fixture)
        .env("SWARMHUB_JOURNAL", root.join("journal"))
        .env("SWARMHUB_LAUNCH_KEY", "0123456789abcdef0123456789abcdef")
        .current_dir(workspace)
        .args(["run-claude", "--workspace-approvals"]);
    command
}

fn launch(command: &mut Command) -> (Value, Vec<String>) {
    let output = command.output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let args: Vec<_> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    let index = args.iter().position(|arg| arg == "--settings").unwrap();
    let settings = serde_json::from_str(&args[index + 1]).unwrap();
    (settings, args)
}

fn expect_read_only_attachments(settings: &Value, files: &Path) {
    let files = files.to_str().unwrap();
    assert_eq!(
        settings["permissions"]["additionalDirectories"],
        json!([files])
    );
    assert_eq!(
        settings["permissions"]["deny"],
        json!([format!("Edit(/{files}/**)")])
    );
    assert_eq!(settings["sandbox"]["filesystem"]["denyWrite"], json!([files]));
    assert!(settings["permissions"].get("allow").is_none());
}

#[test]
fn claude_auto_launch_registers_the_attachment_directory_read_only() {
    let root = tempfile::tempdir().unwrap();
    let files = root.path().join(".local/state/herdr-core/default/files");
    fs::create_dir_all(files.parent().unwrap()).unwrap();
    let results = root.path().join("results");
    fs::create_dir(&results).unwrap();
    let mut command = claude(root.path());
    command
        .env("SWARMHUB_PROJECT_AUTO", "1")
        .env("SWARMHUB_RESULTS", &results);

    let (settings, args) = launch(&mut command);
    expect_read_only_attachments(&settings, &files);
    assert_eq!(&args[..2], ["--permission-mode", "auto"]);
    assert_eq!(settings["permissions"]["defaultMode"], "acceptEdits");
    assert_eq!(settings["sandbox"]["enabled"], true);
    assert_eq!(settings["sandbox"]["autoAllowBashIfSandboxed"], true);
    assert_eq!(
        settings["sandbox"]["filesystem"]["allowWrite"],
        json!([results])
    );
    assert!(settings["hooks"].get("PermissionRequest").is_none());
    assert_eq!(
        fs::metadata(&files).unwrap().permissions().mode() & 0o777,
        0o700
    );
    assert_eq!(launch(&mut command), (settings, args));
}

#[test]
fn claude_manual_launch_uses_the_core_session_state_directory() {
    let root = tempfile::tempdir().unwrap();
    let state = root.path().join("core state");
    let files = state.join("herdr-core/check/files");
    fs::create_dir_all(&files).unwrap();
    let mut command = claude(root.path());
    command
        .env("XDG_STATE_HOME", state)
        .env("HC_SESSION", "check")
        .env("HC_SOCKET", root.path().join("custom.sock"))
        .env("SWARMHUB_PROJECT_AUTO", "1")
        .args(["--permission-mode", "plan"]);

    let (settings, args) = launch(&mut command);
    expect_read_only_attachments(&settings, &files);
    assert_eq!(&args[2..], ["--permission-mode", "plan"]);
    assert!(settings["permissions"].get("defaultMode").is_none());
    assert!(settings["sandbox"].get("enabled").is_none());
    assert!(settings["hooks"].get("PermissionRequest").is_some());
}

#[test]
fn claude_does_not_trust_a_redirected_attachment_directory() {
    let root = tempfile::tempdir().unwrap();
    let state = root.path().join(".local/state/herdr-core/default");
    fs::create_dir_all(&state).unwrap();
    std::os::unix::fs::symlink(root.path(), state.join("files")).unwrap();

    let (settings, _) = launch(&mut claude(root.path()));
    assert!(settings.get("permissions").is_none());
    assert!(settings.get("sandbox").is_none());
}
