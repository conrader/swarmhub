use serde_json::Value;
use std::{env, fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

fn cli(dir: &Path, name: &str, model: &str) {
    let path = dir.join(name);
    fs::write(
        &path,
        format!("#!/bin/sh\n[ \"$1 $2\" = '--standalone models' ] || exit 2\necho {model}\n"),
    )
    .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

#[test]
fn inventory_and_model_list_prefer_the_version_two_cli_and_honor_launch_overrides() {
    let home = tempfile::tempdir().unwrap();
    let first = home.path().join("legacy");
    let second = home.path().join("current");
    fs::create_dir(&first).unwrap();
    fs::create_dir(&second).unwrap();
    let path = env::join_paths([&first, &second]).unwrap();
    let command = || {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_swarmhub-herdr"));
        cmd.env_clear()
            .env("HOME", home.path())
            .env("PATH", &path)
            .env("SWARMHUB_SERVICE_PATH", &path);
        cmd
    };
    let inventory = || {
        let result = command()
            .args(["service", "status", "--json"])
            .output()
            .unwrap();
        assert!(result.status.success());
        let status: Value = serde_json::from_slice(&result.stdout).unwrap();
        status["programs"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["id"] == "opencode")
            .unwrap()
            .clone()
    };
    let models = |mut cmd: Command| {
        let result = cmd.arg("opencode-models").output().unwrap();
        assert!(result.status.success());
        String::from_utf8(result.stdout).unwrap()
    };
    cli(&second, "opencode2", "test/v2");
    assert_eq!(
        inventory()["path"],
        second.join("opencode2").to_str().unwrap()
    );
    cli(&first, "opencode", "test/unversioned");
    assert_eq!(
        inventory()["path"],
        second.join("opencode2").to_str().unwrap()
    );
    assert_eq!(models(command()), "test/v2\n");
    let mut custom = command();
    custom.env("SWARMHUB_OPENCODE_BIN", first.join("opencode"));
    assert_eq!(models(custom), "test/unversioned\n");
    fs::remove_file(second.join("opencode2")).unwrap();
    assert_eq!(models(command()), "test/unversioned\n");
}
