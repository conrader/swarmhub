use super::{ProcessIdentity, Worker, cancel_group, subprocess};
use crate::{
    fleet_policy::{PolicyRef, Rule, WorkerHeartbeat, tests::{Fixture, WORKSPACE, policy}},
    history,
    machines::probe::{Enrollment, Provider, Report, tests::{enrolled, key, report, signed}},
};
use ring::signature::Ed25519KeyPair;
use serde_json::{Value, json};
use std::{
    fs::{self, OpenOptions},
    io,
    os::unix::{fs::OpenOptionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::Command,
};

pub(crate) struct Inputs {
    pub enrollment: Enrollment,
    pub reference: PolicyRef,
    pub identity: Value,
    key: Ed25519KeyPair,
    root: PathBuf,
    pub policy_root: PathBuf,
    authority: Fixture,
}

impl Inputs {
    pub(crate) fn new(root: &Path, machine: &str, rules: Vec<Rule>) -> Self {
        let key = key();
        let mut enrollment = enrolled(machine, 1, &key);
        let project = root.join("project");
        fs::create_dir(&project).unwrap();
        let project = project.canonicalize().unwrap().into_os_string().into_string().unwrap();
        enrollment.accounts.insert(Provider::Claude, "fixture-claude-account".into());
        enrollment.thresholds.provider_slots.insert(Provider::Claude, 1);
        enrollment.roots = vec![project.clone()];
        enrollment.projects[0].folder = project;
        let worker = Worker { id: enrollment.id.clone(), host_fingerprint: enrollment.fingerprint() };
        let identity = serde_json::to_value(worker).unwrap();
        let policy_root = root.join(WORKSPACE);
        let fixture = Fixture::new(root, WORKSPACE, true);
        let mut policy = policy(1, rules);
        policy.workers.push(enrollment.clone());
        let reference = fixture.publish(fixture.publication(policy, WORKSPACE)).unwrap();
        write_local(root, "identity.json", &identity);
        write_local(root, "admission.json", &json!({
            "policy_dir": policy_root,
            "workspace": WORKSPACE,
            "operator_uid": unsafe { libc::getuid() },
        }));
        let inputs = Self { enrollment, reference, identity, key, root: root.into(), policy_root, authority: fixture };
        inputs.heartbeat(history::now() + 55_000);
        inputs.update(inputs.report());
        inputs
    }

    pub(crate) fn signing(&self) -> &Fixture {
        &self.authority
    }

    pub(crate) fn republish(&mut self, rules: Vec<Rule>) {
        self.publish_revocations(rules, Default::default());
    }

    pub(crate) fn publish_revocations(&mut self, rules: Vec<Rule>, revoked: std::collections::BTreeSet<String>) {
        let mut policy = policy(self.reference.generation + 1, rules);
        policy.workers.push(self.enrollment.clone());
        policy.revoked = revoked;
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        self.reference = loop {
            match self.authority.publish(self.authority.publication(policy.clone(), WORKSPACE)) {
                Ok(reference) => break reference,
                Err(crate::fleet_policy::Error::Busy) if std::time::Instant::now() < deadline => {
                    std::thread::yield_now();
                }
                Err(error) => panic!("{error:?}"),
            }
        };
        self.heartbeat(history::now() + 55_000);
        self.update(self.report());
    }

    pub(crate) fn report(&self) -> Report {
        let mut report = report(&self.enrollment, &self.reference, history::now());
        let project = &self.enrollment.projects[0].folder;
        report.runtimes.insert(Provider::Claude, report.runtimes[&Provider::Codex].clone());
        report.provider_running.insert(Provider::Claude, 0);
        report.work_disks = [(project.clone(), report.root_disk.clone().unwrap())].into();
        report
    }

    pub(crate) fn update(&self, report: Report) {
        write_local(&self.root, "probe.json", &signed(report, &self.key));
    }

    pub(crate) fn heartbeat(&self, expires_ms: i64) {
        let heartbeat = WorkerHeartbeat {
            policy: self.reference.clone(), issued_ms: history::now() - 1000, expires_ms,
        };
        write_local(&self.policy_root, "worker-heartbeat.json", &heartbeat);
    }

    pub(crate) fn started_request(&self, job_id: &str, number: i64) -> Value {
        let project = &self.enrollment.projects[0];
        let mut start = request(&self.identity, job_id, number);
        start["manifest"] = json!({
            "project_id": project.id, "project_created_ms": project.created_ms,
            "workdir": project.folder, "owner_bot_id": "fixture-owner", "provider": "codex",
            "requested_model": "fixture-model", "requested_effort": "medium",
        });
        start
    }
}

pub(crate) fn write_local(root: &Path, name: &str, value: &impl serde::Serialize) {
    let file = tempfile::NamedTempFile::new_in(root).unwrap();
    serde_json::to_writer(file.as_file(), value).unwrap();
    file.persist(root.join(name)).unwrap();
}

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
        "protocol": 2,
        "worker": worker,
        "attempt": { "job_id": job_id, "number": attempt },
    })
}

pub(crate) fn command(root: &Path, verb: &str) -> Command {
    subprocess([std::ffi::OsStr::new(verb), root.as_os_str()]).unwrap()
}

pub(crate) fn rpc_command(root: &Path, verb: &str) -> Command {
    subprocess([
        std::ffi::OsStr::new("rpc"), root.as_os_str(),
        std::ffi::OsStr::new(verb),
    ]).unwrap()
}

pub(crate) fn authority(inputs: &Inputs) -> crate::fleet_policy::Authority {
    inputs.authority.restart(WORKSPACE)
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

#[test]
fn gapplan_09_unit_capture_drains_a_socket_without_waiting_for_the_inherited_writer() {
    use std::{io::Write, os::unix::net::UnixStream};
    let (socket, mut writer) = UnixStream::pair().unwrap();
    socket.set_nonblocking(true).unwrap();
    let mut capture = super::Capture { socket, bytes: vec![], limit: 5 };
    writer.write_all(b"abcdef").unwrap();
    capture.drain();
    assert_eq!(capture.bytes, b"abcde");
    writer.write_all(b"still open").unwrap();
    capture.drain();
    assert_eq!(capture.bytes, b"abcde");
}

pub(crate) fn workload_child(
    root: &Path, verb: &str, input: std::os::unix::net::UnixStream,
    auxiliary: std::os::unix::net::UnixStream,
) -> io::Result<std::process::Child> {
    use std::{os::fd::{AsRawFd, OwnedFd}, process::Stdio};
    let fd = auxiliary.as_raw_fd().to_string();
    let mut command = subprocess([
        std::ffi::OsStr::new(verb), root.as_os_str(), std::ffi::OsStr::new(&fd),
    ])?;
    command.stdin(Stdio::from(OwnedFd::from(input)));
    let log = OpenOptions::new().create(true).append(true).mode(0o600)
        .open(root.join("workload-fixture.log"))?;
    command.stdout(log.try_clone()?).stderr(log);
    // SAFETY: fcntl changes the descriptor only in the fresh child. Holding
    // the socket in the closure keeps it open through spawn.
    unsafe {
        command.pre_exec(move || super::set_descriptor_flags(auxiliary.as_raw_fd(), 0));
    }
    command.spawn()
}

pub(crate) fn outbound_child(input: std::os::unix::net::UnixStream) -> io::Result<std::process::Child> {
    use std::{os::fd::OwnedFd, process::Stdio};
    subprocess(["_outbound-executor"])?.stdin(Stdio::from(OwnedFd::from(input))).spawn()
}
