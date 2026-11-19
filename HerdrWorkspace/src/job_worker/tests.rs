use super::{ProcessIdentity, Worker, cancel_group, subprocess};
use crate::machines::probe::tests::{enrolled, key};
use serde_json::{Value, json};
use std::{
    fs::OpenOptions,
    io,
    os::unix::{fs::OpenOptionsExt, process::CommandExt},
    path::Path,
    process::{Command, Stdio},
};

pub(crate) fn init(root: &Path) -> Value {
    let enrollment = enrolled("mini-m4", 1, &key());
    let worker = Worker { id: enrollment.id.clone(), host_fingerprint: enrollment.fingerprint() };
    let identity = OpenOptions::new().write(true).create_new(true).mode(0o600)
        .open(root.join("identity.json")).unwrap();
    serde_json::to_writer(identity, &worker).unwrap();
    serde_json::to_value(worker).unwrap()
}

pub(crate) fn request(worker: &Value, job_id: &str, attempt: i64) -> Value {
    json!({
        "protocol": 1,
        "worker": worker,
        "attempt": { "job_id": job_id, "number": attempt },
    })
}

pub(crate) fn command(root: &Path, verb: &str) -> Command {
    let mut command = subprocess([std::ffi::OsStr::new(verb), root.as_os_str()]).unwrap();
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
    command
}

pub(crate) fn live(identity: &Value) -> bool {
    serde_json::from_value::<ProcessIdentity>(identity.clone()).unwrap().live()
}

pub(crate) fn subprocess_entry() -> bool {
    if std::env::var_os("SWARMHUB_TEST_JOB_WORKER").is_none() {
        return false;
    }
    let args: Vec<_> = (0..)
        .map_while(|index| std::env::var_os(format!("SWARMHUB_TEST_JOB_WORKER_ARG_{index}")))
        .collect();
    super::cli(&args).unwrap();
    true
}

#[test]
fn gapplan_07_unit_process_group_signal_requires_birth_identity() -> io::Result<()> {
    let mut child = subprocess(["_fixture-member"])?.process_group(0).spawn()?;
    let actual = ProcessIdentity::read(child.id() as i32).unwrap();
    let wrong = ProcessIdentity { birth: "previous process".into(), ..actual };
    let signalled = cancel_group(&child, &wrong);
    let survived = child.try_wait()?.is_none();
    if survived {
        child.kill()?;
        child.wait()?;
    }
    assert!(!signalled?);
    assert!(survived);
    Ok(())
}
