use super::{WAIT, jobs_fixture, reopen_journal, schema};
use crate::{
    history, jobs,
    job_worker::tests::{Inputs, command, live, subprocess_entry},
};
use rusqlite::Connection;
use serde_json::Value;
use std::{
    fs::{self, File},
    io::{Read, Seek},
    path::{Path, PathBuf},
    process::{Child, Output, Stdio},
    sync::Barrier,
    thread,
    time::{Duration, Instant},
};

pub(super) struct Worker {
    pub(super) root: PathBuf,
    request: Value,
    pub(super) inputs: Inputs,
}

impl Worker {
    pub(super) fn new(scratch: &Path, id: &str, attempt: i64) -> Self {
        Self::on(scratch, "mini-m4", id, attempt, vec![])
    }

    fn on(scratch: &Path, machine: &str, id: &str, attempt: i64, rules: Vec<crate::fleet_policy::Rule>) -> Self {
        use std::os::unix::fs::DirBuilderExt;
        let root = scratch.join("worker");
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let inputs = Inputs::new(&root, machine, rules);
        Self { request: inputs.started_request(id, attempt), root, inputs }
    }

    fn input(&self, fixture: Option<&str>) -> Value {
        let mut input = self.request.clone();
        if let Some(fixture) = fixture {
            input["fixture"] = fixture.into();
        } else {
            input.as_object_mut().unwrap().remove("manifest");
        }
        input
    }

    fn send_with_launch_pipe(&self, fixture: &str) -> Child {
        command(&self.root, "start")
            .stdin(request_file(&self.input(Some(fixture))))
            .stdout(Stdio::piped())
            .spawn().unwrap()
    }

    fn run(&self, verb: &str, input: &Value) -> Output {
        // Concurrent Darwin spawns can inherit another launcher pipe before
        // close-on-exec is set. A detached process must not control fixture EOF.
        let mut stdout = tempfile::tempfile().unwrap();
        let mut stderr = tempfile::tempfile().unwrap();
        let status = command(&self.root, verb)
            .stdin(request_file(input))
            .stdout(stdout.try_clone().unwrap())
            .stderr(stderr.try_clone().unwrap())
            .status().unwrap();
        let contents = |file: &mut File| {
            let mut bytes = Vec::new();
            file.rewind().unwrap();
            file.read_to_end(&mut bytes).unwrap();
            bytes
        };
        Output { status, stdout: contents(&mut stdout), stderr: contents(&mut stderr) }
    }

    fn call(&self, verb: &str, fixture: Option<&str>) -> Value {
        response(self.run(verb, &self.input(fixture)))
    }

    pub(super) fn pause(&self, checkpoint: &str) -> PathBuf {
        let pause = self.root.join(format!("pause-{checkpoint}"));
        fs::write(&pause, []).unwrap();
        pause
    }

    pub(super) fn checkpoint(&self, checkpoint: &str) -> Value {
        let marker = self.root.join(format!("{checkpoint}.json"));
        until(|| fs::read(&marker).ok().map(|data| serde_json::from_slice(&data).unwrap()))
    }

    fn state(&self, status: &str) -> Value {
        until(|| {
            let view = self.call("status", None);
            assert!(
                view["status"] == status || !matches!(view["status"].as_str(), Some("stopped" | "unknown" | "held")),
                "expected {status}, got {view}",
            );
            (view["status"] == status).then_some(view)
        })
    }

    pub(super) fn db(&self) -> Connection {
        history::connection(&self.root.join("attempts.sqlite3")).unwrap()
    }
}

fn request_file(input: &Value) -> File {
    let mut file = tempfile::tempfile().unwrap();
    serde_json::to_writer(&file, input).unwrap();
    file.rewind().unwrap();
    file
}

fn response(output: Output) -> Value {
    assert!(
        output.status.success(),
        "worker command failed: {} {}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr),
    );
    let mut values = std::str::from_utf8(&output.stdout).unwrap().lines()
        .filter(|line| line.starts_with('{'));
    let value = serde_json::from_str(values.next().expect("worker JSON")).unwrap();
    assert!(values.next().is_none());
    value
}

fn until<T>(mut check: impl FnMut() -> Option<T>) -> T {
    let deadline = Instant::now() + WAIT;
    loop {
        if let Some(value) = check() {
            return value;
        }
        assert!(Instant::now() < deadline, "timed out waiting for worker fixture");
        thread::sleep(Duration::from_millis(20));
    }
}

fn identities(db: &Connection) -> (Value, Option<Value>, String) {
    db.query_row("SELECT supervisor,child,start_token FROM attempts", [], |row| {
        let supervisor: String = row.get(0)?;
        let child: Option<String> = row.get(1)?;
        Ok((serde_json::from_str(&supervisor).unwrap(), child.map(|child| serde_json::from_str(&child).unwrap()), row.get(2)?))
    }).unwrap()
}

#[test]
fn gapplan_07_int_closed_launch_pipe_keeps_one_detached_attempt() {
    if subprocess_entry() {
        return;
    }
    let scratch = tempfile::tempdir().unwrap();
    let journal_dir = scratch.path().join("journal");
    let journal = reopen_journal(&journal_dir);
    let mut db = journal.db().unwrap();
    crate::bots::register(&db, &crate::bots::Registration {
        id: jobs_fixture::OWNER.into(),
        name: Some("Fixture owner".into()),
        ..Default::default()
    }, 1).unwrap().unwrap();
    let job = jobs_fixture::submit_fixture(&mut db, "detached-job");
    let attempt = jobs_fixture::ATTEMPT;
    let worker = Worker::new(scratch.path(), &job.id, attempt);
    let id = worker.request["worker"]["id"].as_str().unwrap();
    assert_eq!(jobs::record_dispatch(&mut db, &job.id, attempt, id, "fixture-lease").unwrap(), jobs::Dispatch::Recorded);
    drop(db);
    drop(journal);

    let pause = worker.pause("fixture-released");
    let first = worker.send_with_launch_pipe("success");
    let child_identity = worker.checkpoint("fixture-released");
    // Closing the launch pipe and reaping the caller happens while the fixture
    // is still waiting. The next status call is a different process.
    let mut first = first;
    drop(first.stdout.take());
    let _ = first.wait().unwrap();
    assert!(live(&child_identity));
    let (supervisor, saved_child, token) = identities(&worker.db());
    assert_eq!(saved_child.as_ref(), Some(&child_identity));
    assert_eq!(supervisor["group"], supervisor["pid"]);
    assert_ne!(supervisor["group"], child_identity["group"]);

    let barrier = Barrier::new(2);
    thread::scope(|scope| {
        for _ in 0..2 {
            scope.spawn(|| {
                barrier.wait();
                let duplicate = worker.call("start", Some("success"));
                assert_eq!(duplicate["status"], "running");
                assert!(duplicate["manifest_digest"].as_str().is_some_and(|digest| digest.len() == 64));
            });
        }
    });
    assert_eq!(identities(&worker.db()), (supervisor, saved_child, token));
    let conflict = worker.run("start", &worker.input(Some("nonzero")));
    assert!(!conflict.status.success());
    assert!(String::from_utf8_lossy(&conflict.stderr).contains("different manifest"));
    assert!(worker.call("collect", None).get("result").is_none());
    fs::remove_file(pause).unwrap();
    let status = worker.state("exited");
    assert_eq!(status["exit_code"], 0);
    assert_eq!(status["result_ref"], "result");
    assert!(!live(&child_identity));
    assert!(status.get("result").is_none());
    let collect = worker.call("collect", None);
    assert_eq!(collect["log"], "fixture completed");
    assert_eq!(collect["result"], "fixture result\n");
    assert!(collect["result_digest"].as_str().is_some_and(|digest| digest.len() == 64));
    assert_eq!(worker.call("collect", None), collect);

    let journal = reopen_journal(&journal_dir);
    let db = journal.db().unwrap();
    assert_eq!(schema(&db), crate::history::migrations().len());
    assert_eq!(jobs::status(&db, &job.id).unwrap().unwrap().status, "dispatching");
}

#[test]
fn gapplan_07_int_cancel_ends_the_whole_fixture_process_group() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-group", 1);
    let _pause = worker.pause("group-ready");
    worker.call("start", Some("group"));
    let member = worker.checkpoint("group-ready");
    let (_, child, _) = identities(&worker.db());
    let child = child.unwrap();
    assert_eq!(child["pid"], child["group"]);
    assert_eq!(member["group"], child["group"]);
    assert_ne!(member["pid"], child["pid"]);
    assert!(live(&child) && live(&member));
    assert_eq!(worker.call("cancel", None)["cancel_requested"], true);
    let cancelled = worker.state("cancelled");
    assert_eq!(cancelled["exit_signal"], libc::SIGKILL);
    assert!(cancelled["result_ref"].is_null());
    until(|| (!live(&child) && !live(&member)).then_some(()));
    let collect = worker.call("collect", None);
    assert_eq!(serde_json::from_str::<Value>(collect["log"].as_str().unwrap()).unwrap(), member);
    assert_eq!(worker.call("cancel", None), cancelled);
}

#[test]
fn gapplan_07_int_concurrent_first_starts_share_one_manifest_and_child() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-racing-starts", 1);
    let registration = worker.pause("after-supervisor-pin");
    let release = worker.pause("fixture-released");
    let barrier = Barrier::new(2);
    let (first, second) = thread::scope(|scope| {
        let start = || {
            barrier.wait();
            worker.call("start", Some("success"))
        };
        let first = scope.spawn(start);
        let second = scope.spawn(start);
        (first.join().unwrap(), second.join().unwrap())
    });
    for response in [&first, &second] {
        assert!(response.get("reason").is_none(), "unexpected unknown_reason or blocker: {response}");
        assert_eq!(response["status"], "dispatching", "full response: {response}");
    }
    assert_eq!(first["manifest_digest"], second["manifest_digest"]);
    let supervisor = worker.checkpoint("after-supervisor-pin");
    // Both launchers have exited while the supervisor is still behind the test checkpoint.
    assert_eq!(worker.call("status", None), first);
    assert_eq!(worker.call("start", Some("success")), first);
    let (pinned, child, token) = identities(&worker.db());
    assert_eq!(pinned, supervisor);
    assert!(child.is_none());
    fs::remove_file(registration).unwrap();

    let child = worker.checkpoint("fixture-released");
    let before = identities(&worker.db());
    assert_eq!(before, (supervisor, Some(child), token));
    fs::remove_file(release).unwrap();
    worker.state("exited");
    assert_eq!(identities(&worker.db()), before);
}

fn assert_exit_without_result(fixture: &str, exit: i32, truncated: bool, log: &str) {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-results", 1);
    worker.call("start", Some(fixture));
    let status = worker.state("exited");
    assert_eq!(status["exit_code"], exit);
    assert!(status["exit_signal"].is_null());
    assert_eq!(status["result_truncated"], truncated);
    assert_eq!(status["log_ref"], "log");
    assert!(status["result_ref"].is_null());
    assert!(status["result_digest"].is_null());
    let collect = worker.call("collect", None);
    assert_eq!(collect["log"], log);
    assert!(collect.get("result").is_none());
    assert_eq!(worker.call("cancel", None), status);
}

#[test]
fn gapplan_07_int_nonzero_result_preserves_the_exit() {
    assert_exit_without_result("nonzero", 17, false, "fixture exited nonzero");
}

#[test]
fn gapplan_07_int_megabyte_result_is_drained_and_preserves_successful_exit() {
    assert_exit_without_result("oversized", 0, true, "fixture emitted an oversized result");
}

#[test]
fn gapplan_07_int_supervisor_death_before_child_registration_stays_unknown() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-ambiguous", 1);
    let _registration = worker.pause("before-child-registration");
    let _release = worker.pause("fixture-released");
    worker.call("start", Some("success"));
    let gated_child = worker.checkpoint("before-child-registration");
    let (supervisor, child, token) = identities(&worker.db());
    assert!(child.is_none());
    assert!(live(&supervisor) && live(&gated_child));
    let pid = supervisor["pid"].as_i64().unwrap() as i32;
    // SAFETY: the checkpoint and live birth identity identify this test's
    // detached supervisor. No unrelated process is the target.
    assert_eq!(unsafe { libc::kill(pid, libc::SIGKILL) }, 0);
    until(|| (!live(&gated_child) && !live(&supervisor)).then_some(()));

    let unknown = worker.state("unknown");
    assert_eq!(unknown["reason"], "start_unconfirmed");
    assert_eq!(worker.call("start", Some("success")), unknown);
    assert_eq!(worker.call("cancel", None), unknown);
    assert_eq!(worker.call("collect", None), unknown);
    assert_eq!(identities(&worker.db()), (supervisor, None, token));
    assert!(!worker.root.join("fixture-released.json").exists());
}

#[test]
fn gapplan_07_int_reused_supervisor_pid_is_not_a_live_attempt() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-reused-pid", 1);
    assert_eq!(worker.call("status", None)["status"], "missing");

    // Model a crashed supervisor's PID being assigned to this live test
    // process. Its stored birth identity belongs to the former process.
    let reused = serde_json::json!({
        "pid": std::process::id(),
        "group": unsafe { libc::getpgrp() },
        "birth": "a previous process"
    }).to_string();
    let db = worker.db();
    db.execute(
        "INSERT INTO attempts(job_id,attempt,manifest_digest,fixture,start_token,launcher,supervisor,child,status)
         VALUES('job-reused-pid',1,'digest','\"success\"','token',?1,?1,?1,'running')",
        [&reused],
    ).unwrap();
    let view = worker.call("cancel", None);
    assert_eq!(view["status"], "unknown");
    assert_eq!(view["reason"], "exit_unconfirmed");
    assert_eq!(view["cancel_requested"], false);
    assert_eq!(worker.call("status", None), view);
    let persisted: String = db.query_row("SELECT status FROM attempts", [], |row| row.get(0)).unwrap();
    assert_eq!(persisted, "unknown");
}

#[test]
fn gapplan_08_int_mini_races_managed_jobs_and_macbook_cannot_take_the_loser() {
    let scratch = tempfile::tempdir().unwrap();
    let mut worker = Worker::new(scratch.path(), "job-race-a", 1);
    let hold = worker.pause("fixture-released");
    let barrier = Barrier::new(2);
    let (a, b) = thread::scope(|scope| {
        let start = |id| {
            barrier.wait();
            let mut input = worker.inputs.started_request(id, 1);
            input["fixture"] = "success".into();
            response(worker.run("start", &input))
        };
        let a = scope.spawn(move || start("job-race-a"));
        let b = scope.spawn(move || start("job-race-b"));
        (a.join().unwrap(), b.join().unwrap())
    });
    for view in [&a, &b] {
        assert!(matches!(view["status"].as_str(), Some("queued" | "dispatching" | "running")), "{view}");
    }
    let (winner, loser, queued) = if a["status"] == "queued" {
        ("job-race-b", "job-race-a", a)
    } else {
        ("job-race-a", "job-race-b", b)
    };
    assert_eq!(queued["status"], "queued", "{queued}");
    assert_eq!(queued["reason"], "heavy_slots");
    let child = worker.checkpoint("fixture-released");
    assert!(live(&child));
    worker.request = worker.inputs.started_request(winner, 1);
    assert_eq!(worker.call("status", None)["status"], "running");
    let active = |sql| worker.db().query_row(sql, [], |row| row.get::<_, i64>(0)).unwrap();
    assert_eq!(active("SELECT count(*) FROM attempts WHERE status='running'"), 1);
    assert_eq!(active("SELECT count(*) FROM leases"), 1);

    let portable = tempfile::tempdir().unwrap();
    let fallback = Worker::on(portable.path(), "macbook-m4", loser, 1, vec![]);
    let refused = fallback.call("start", Some("success"));
    assert_eq!(refused["status"], "held");
    assert_eq!(refused["reason"], "portable");
    assert_eq!(fallback.db().query_row("SELECT count(*) FROM attempts", [], |row| row.get::<_, i64>(0)).unwrap(), 0);

    fs::remove_file(hold).unwrap();
    worker.state("exited");
    assert_eq!(active("SELECT count(*) FROM leases"), 0);
    worker.request = worker.inputs.started_request(loser, 1);
    assert_eq!(worker.call("status", None), queued);
    worker.call("start", Some("success"));
    let next = worker.state("exited");
    assert_eq!(next["runtime"]["provider"], "codex");
    assert_eq!(next["runtime"]["account_ref"], "fixture-shared-account");
    assert!(next["runtime"]["observed_model"].is_null());
    assert_eq!(next["runtime"]["result_digest"], next["result_digest"]);
}

#[test]
fn gapplan_08_int_stale_login_holds_until_readiness_is_fresh() {
    use crate::machines::probe::Provider;

    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-stale", 1);
    let mut probe = worker.inputs.report();
    let limit = worker.inputs.enrollment.thresholds.max_readiness_age_ms;
    probe.runtimes.get_mut(&Provider::Codex).unwrap().ready_ms = Some(probe.observed_ms - limit - 1);
    worker.inputs.update(probe);
    let held = worker.call("start", Some("success"));
    assert_eq!(held["status"], "held");
    assert_eq!(held["reason"], "login_stale");
    assert_eq!(worker.call("status", None), held);
    worker.inputs.update(worker.inputs.report());
    worker.call("start", Some("success"));
    assert_eq!(worker.state("exited")["exit_code"], 0);
}

#[test]
fn gapplan_08_int_ovh_rejects_ram_backed_workdirs_and_records_disk_stop() {
    use crate::machines::probe::tests::GB;

    let scratch = tempfile::tempdir().unwrap();
    let mut worker = Worker::on(scratch.path(), "ovh", "job-ovh", 1, vec![]);
    let workdir = &worker.inputs.enrollment.projects[0].folder;
    let mut probe = worker.inputs.report();
    let disk = probe.work_disks.get_mut(workdir).unwrap();
    disk.filesystem = "tmpfs".into();
    disk.free_bytes = 8 * GB - 1;
    worker.inputs.update(probe.clone());
    let stop = worker.call("start", Some("success"));
    assert_eq!(stop["status"], "stopped");
    assert_eq!(stop["reason"], "disk_stop");
    assert_eq!(stop["admission"]["disk"], serde_json::json!({
        "path": workdir, "free_bytes": 8 * GB - 1, "limit_bytes": 8 * GB,
    }));
    assert_eq!(worker.call("status", None), stop);

    probe.work_disks.get_mut(workdir).unwrap().free_bytes = 16 * GB;
    worker.inputs.update(probe);
    let ram = worker.call("start", Some("success"));
    assert_eq!(ram["status"], "held");
    assert_eq!(ram["reason"], "work_disk_not_backed");

    worker.request = worker.inputs.started_request("job-dev-shm", 1);
    worker.request["manifest"]["workdir"] = "/dev/shm/fixture-only".into();
    worker.inputs.update(worker.inputs.report());
    assert_eq!(worker.call("start", Some("success"))["reason"], "work_disk_not_backed");
    assert_eq!(worker.db().query_row("SELECT count(*) FROM leases", [], |row| row.get::<_, i64>(0)).unwrap(), 0);
}

#[test]
fn gapplan_08_int_reprobes_the_resolved_workdir_between_reservation_and_spawn() {
    use std::os::unix::fs::symlink;

    let scratch = tempfile::tempdir().unwrap();
    let mut worker = Worker::on(scratch.path(), "ovh", "job-resolved", 1, vec![]);
    let workdir = &worker.inputs.enrollment.projects[0].folder;
    let project_parent = Path::new(workdir).parent().unwrap();
    let alias = project_parent.join("workdir-alias");
    symlink(workdir, &alias).unwrap();
    worker.request["manifest"]["workdir"] = alias.to_str().unwrap().into();
    let pause = worker.pause("after-supervisor-pin");
    worker.call("start", Some("success"));
    worker.checkpoint("after-supervisor-pin");
    fs::remove_file(&alias).unwrap();
    symlink(project_parent, &alias).unwrap();
    fs::remove_file(pause).unwrap();
    let stopped = worker.state("stopped");
    assert_eq!(stopped["reason"], "project_not_enrolled");
    assert!(identities(&worker.db()).1.is_none());
}

#[test]
fn gapplan_08_int_disconnected_supervisor_stops_the_whole_group_on_disk_floor() {
    use crate::machines::probe::tests::GB;

    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::on(scratch.path(), "ovh", "job-live-floor", 1, vec![]);
    let _pause = worker.pause("group-ready");
    let mut first = worker.send_with_launch_pipe("group");
    let member = worker.checkpoint("group-ready");
    drop(first.stdout.take());
    first.wait().unwrap();
    let (_, child, _) = identities(&worker.db());
    let child = child.unwrap();
    assert!(live(&member) && live(&child));

    let mut probe = worker.inputs.report();
    let workdir = &worker.inputs.enrollment.projects[0].folder;
    probe.work_disks.get_mut(workdir).unwrap().free_bytes = 8 * GB - 1;
    worker.inputs.update(probe);
    // The group must stop without a bridge connection or a status/cancel call.
    until(|| (!live(&member) && !live(&child)).then_some(()));
    let stopped = worker.state("stopped");
    assert_eq!(stopped["reason"], "disk_stop");
    assert_eq!(stopped["admission"]["disk"]["path"], workdir.as_str());
    assert_eq!(stopped["exit_signal"], libc::SIGKILL);
    assert_eq!(worker.db().query_row("SELECT count(*) FROM leases", [], |row| row.get::<_, i64>(0)).unwrap(), 0);
}

#[test]
fn gapplan_08_int_disconnected_supervisor_stops_when_policy_heartbeat_is_lost() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-policy-heartbeat", 1);
    let _pause = worker.pause("fixture-released");
    worker.call("start", Some("success"));
    let child = worker.checkpoint("fixture-released");
    let db = worker.db();
    let initial_heartbeat = || db.query_row("SELECT heartbeat_ms FROM leases", [], |row| row.get::<_, i64>(0)).unwrap();
    let first = initial_heartbeat();
    until(|| (initial_heartbeat() > first).then_some(()));
    assert!(live(&child));
    worker.inputs.heartbeat(history::now() - 1);
    until(|| (!live(&child)).then_some(()));
    let stopped = worker.state("stopped");
    assert_eq!(stopped["reason"], "policy_heartbeat_lost");
    assert_eq!(stopped["exit_signal"], libc::SIGKILL);
}

#[test]
fn gapplan_08_int_restart_retains_an_expired_slot_until_the_surviving_group_ends() {
    let scratch = tempfile::tempdir().unwrap();
    let mut worker = Worker::new(scratch.path(), "job-survivor", 1);
    let pause = worker.pause("fixture-released");
    worker.call("start", Some("success"));
    let child = worker.checkpoint("fixture-released");
    let (supervisor, _, old_token) = identities(&worker.db());
    assert!(live(&supervisor) && live(&child));
    // SAFETY: the checkpoint and birth identity identify this fixture's supervisor.
    assert_eq!(unsafe { libc::kill(supervisor["pid"].as_i64().unwrap() as i32, libc::SIGKILL) }, 0);
    until(|| (!live(&supervisor)).then_some(()));
    let db = worker.db();
    db.execute("UPDATE leases SET expires_ms=heartbeat_ms", []).unwrap();
    drop(db);
    let unknown = worker.call("status", None);
    assert_eq!(unknown["status"], "unknown");
    assert_eq!(unknown["reason"], "exit_unconfirmed");
    assert!(live(&child));

    worker.request = worker.inputs.started_request("job-replacement", 1);
    let queue = worker.call("start", Some("success"));
    assert_eq!(queue["status"], "queued");
    assert_eq!(queue["reason"], "heavy_slots");
    assert!(live(&child));
    assert_eq!(identities(&worker.db()).2, old_token);

    fs::remove_file(pause).unwrap();
    until(|| (!live(&child)).then_some(()));
    until(|| {
        let view = worker.call("start", Some("success"));
        (view["status"] != "queued").then_some(())
    });
    assert_eq!(worker.state("exited")["exit_code"], 0);
    worker.request = worker.inputs.started_request("job-survivor", 1);
    assert_eq!(worker.call("status", None), unknown);
}

#[test]
fn gapplan_08_int_supervisor_waits_for_the_durable_pin_during_store_contention() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "job-pin-contention", 1);
    let pin = worker.pause("before-launcher-pin");
    let registration = worker.pause("after-supervisor-pin");
    let result = thread::scope(|scope| {
        let first = scope.spawn(|| worker.call("start", Some("success")));
        worker.checkpoint("before-launcher-pin");
        let mut db = worker.db();
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).unwrap();
        fs::remove_file(pin).unwrap();
        let marker = worker.root.join("after-supervisor-pin.json");
        assert!(!marker.exists());
        let status: (String, Option<String>) = tx.query_row(
            "SELECT status,supervisor FROM attempts", [], |row| Ok((row.get(0)?, row.get(1)?)),
        ).unwrap();
        assert_eq!(status, ("dispatching".into(), None));
        tx.commit().unwrap();
        first.join().unwrap()
    });

    assert_eq!(result["status"], "dispatching", "{result}");
    assert!(result.get("reason").is_none(), "{result}");
    let supervisor = worker.checkpoint("after-supervisor-pin");
    assert_eq!(identities(&worker.db()).0, supervisor);
    fs::remove_file(registration).unwrap();
    assert_eq!(worker.state("exited")["exit_code"], 0);
}

pub(super) const FIXTURE_BRIEF: &str = "--literal\n$(exit 91)\nreview this fixture";
const PRIVATE_DIAGNOSTIC: &str = "fixture-private-diagnostic";

pub(super) fn fake_profile(worker: &Worker, provider: &str, outcome: &str, timeout_ms: u64) {
    use sha2::{Digest, Sha256};
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

    let profiles = worker.root.join("fixture-runtimes");
    let review = outcome == "review-evidence";
    let profile = profiles.join(if review { provider } else { "local" });
    for path in [&profiles, &profile, &profile.join("home")] {
        if !path.exists() {
            fs::DirBuilder::new().mode(0o700).create(path).unwrap();
        }
    }
    fs::write(profile.join("home/synthetic-login"), "fixture-login").unwrap();
    let mut script = format!(r#"#!/bin/sh
set -eu
outcome='{outcome}'
[ "$(/bin/cat "$HOME/synthetic-login")" = fixture-login ]
[ -z "${{COORDINATOR_FIXTURE_SENTINEL+x}}" ]
[ "$(/bin/pwd -P)" = '{workdir}' ]
if [ "$outcome" = workload-gate ]; then
    umask 077
    /usr/bin/env > "$HOME/workload-env"
    printf '%s\0' "$0" "$@" > "$HOME/workload-argv"
    /bin/cat > "$HOME/workload-stdin"
    brief=$(/bin/cat "$HOME/workload-stdin")
    exec 3>&1 4>&2
    exec > "$HOME/workload-stdout" 2> "$HOME/workload-stderr"
    trap '/bin/cat "$HOME/workload-stdout" >&3; /bin/cat "$HOME/workload-stderr" >&4' EXIT
else
    brief=$(/bin/cat)
fi
if [ "$outcome" != review-evidence ]; then [ "$brief" = '{FIXTURE_BRIEF}' ]; fi
printf '%s\n' '{PRIVATE_DIAGNOSTIC}' >&2
printf '%s\n' "started" >> "$HOME/invocations"
case "$outcome" in
    timeout) /bin/sleep 20 ;;
    wait_for_release) while [ ! -f "$HOME/release" ]; do /bin/sleep 0.05; done ;;
    first_holds) if [ "$(/usr/bin/wc -l < "$HOME/invocations" | /usr/bin/tr -d ' ')" = 1 ]; then /bin/sleep 20; fi ;;
    workload-gate) while [ ! -f "$FIXTURE_WORKLOAD_OUTCOME" ]; do /bin/sleep 0.05; done
        /bin/cp "$FIXTURE_WORKLOAD_OUTCOME" "$HOME/workload-received"
        [ "$(/bin/cat "$HOME/workload-received")" = '"succeeded"' ]
        while [ ! -f "$HOME/workload-finish" ]; do /bin/sleep 0.05; done ;;
    large_file) /usr/bin/head -c 131072 /dev/zero > "$HOME/large-transcript" ;;
    flood) /usr/bin/head -c 131072 /dev/zero >&2 ;;
    flood_stdout) /usr/bin/head -c 131072 /dev/zero ;;
    malformed) printf '%s\n' 'broken fixture json'; exit 0 ;;
    inherited) /bin/sleep 20 & ;;
esac
"#, workdir = worker.inputs.enrollment.projects[0].folder);
    if provider == "claude" {
        script.push_str(r#"
[ "$*" = '--print --output-format stream-json --verbose --permission-mode plan --model claude-opus-5 --effort medium' ]
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-sonnet-5","effort":"high","claude_code_version":"fixture-1.0"}'
if [ "$outcome" = missing ]; then
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false}'
elif [ "$outcome" = review-evidence ]; then
    escaped=$(printf '%s' "$brief" | /usr/bin/sed 's/"/\\"/g')
    printf '{"type":"result","subtype":"success","is_error":false,"result":"%s"}\n' "$escaped"
else
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"Claude fixture result"}'
fi
"#);
    } else {
        script.push_str(r#"
[ "$1 $2 $3 $4 $5 $6 $7 $8" = 'exec --json --sandbox read-only --color never --skip-git-repo-check --output-last-message' ]
artifact="$9"
shift 9
[ "$*" = '--model gpt-6.1-sol -c model_reasoning_effort="medium" -' ]
printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}' '{"type":"turn.started"}'
if [ "$outcome" = unknown ]; then
    printf '%s\n' '{"type":"runtime.observed","model":"fixture-unknown","cli_version":"fixture-1.0"}'
fi
case "$outcome" in
    missing) ;;
    oversized) /usr/bin/head -c 8192 /dev/zero > "$artifact" ;;
    linked) /bin/ln -s "$HOME/synthetic-login" "$artifact" ;;
    forged-observation)
        umask 077
        printf '%s' "$brief" > "$artifact"
        printf '%s' '{"model":"gpt-6.1-sol","effort":"high","cli_version":"fixture-1.0"}' > "${artifact%/*}/fixture-observed-runtime.json" ;;
    *) printf '%s\n' 'Codex fixture result' > "$artifact" ;;
esac
printf '%s\n' '{"type":"turn.completed"}'
"#);
        if review {
            script = include_str!("fixtures/codex-review-runner.sh").into();
        }
    }
    let runner = profile.join("runner");
    fs::write(&runner, script.as_bytes()).unwrap();
    fs::set_permissions(runner, fs::Permissions::from_mode(0o700)).unwrap();
    crate::job_worker::tests::write_local(&profile, "profile.json", &serde_json::json!({
        "provider": provider,
        "account_ref": if provider == "claude" { "fixture-claude-account" } else { "fixture-shared-account" },
        "cli_version": "fixture-1.0",
        "executable_sha256": format!("{:x}", Sha256::digest(script.as_bytes())),
        "timeout_ms": timeout_ms,
        "fixture_codex_observation": provider == "codex" && (review || outcome == "forged-observation"),
    }));
}

fn provider_request(worker: &Worker, provider: &str) -> Value {
    let mut input = worker.request.clone();
    input["manifest"]["provider"] = provider.into();
    input["manifest"]["requested_model"] = if provider == "claude" { "claude-opus-5" } else { "gpt-6.1-sol" }.into();
    input["manifest"]["provider_run"] = serde_json::json!({"profile":"local","brief":FIXTURE_BRIEF});
    input
}

fn durable_receipt(worker: &Worker) -> Value {
    let receipt: String = worker.db().query_row("SELECT receipt FROM attempts", [], |row| row.get(0)).unwrap();
    serde_json::from_str(&receipt).unwrap()
}

#[test]
fn gapplan_09_int_claude_and_codex_collect_observed_identity_and_safe_references() {
    use sha2::{Digest, Sha256};

    for (provider, requested, observed, result, account) in [
        ("claude", "claude-opus-5", Some("claude-sonnet-5"), "Claude fixture result", "fixture-claude-account"),
        ("codex", "gpt-6.1-sol", None, "Codex fixture result\n", "fixture-shared-account"),
    ] {
        let scratch = tempfile::tempdir().unwrap();
        let journal_dir = scratch.path().join("journal");
        let journal = reopen_journal(&journal_dir);
        let mut db = journal.db().unwrap();
        crate::bots::register(&db, &crate::bots::Registration {
            id: jobs_fixture::OWNER.into(), name: Some("Fixture owner".into()), ..Default::default()
        }, 1).unwrap().unwrap();
        let mut submission = jobs_fixture::submission();
        submission.runtime.provider = provider.into();
        submission.runtime.model = Some(requested.into());
        submission.brief = FIXTURE_BRIEF.into();
        let job = jobs::submit(&mut db, jobs_fixture::OWNER, "provider-job", &submission).unwrap();
        let worker = Worker::new(scratch.path(), &job.id, 1);
        let input = provider_request(&worker, provider);
        fake_profile(&worker, provider, "success", 5000);
        let host = worker.request["worker"]["id"].as_str().unwrap();
        jobs::record_dispatch(&mut db, &job.id, 1, host, "fixture-lease").unwrap();

        let pause = worker.pause("before-child-registration");
        let mut stdout = tempfile::tempfile().unwrap();
        let mut launcher = command(&worker.root, "start")
            .env("COORDINATOR_FIXTURE_SENTINEL", "synthetic-coordinator-value")
            .stdin(request_file(&input)).stdout(stdout.try_clone().unwrap()).spawn().unwrap();
        assert!(launcher.wait().unwrap().success());
        stdout.rewind().unwrap();
        let mut reply = String::new();
        stdout.read_to_string(&mut reply).unwrap();
        assert!(reply.contains("dispatching"), "{reply}");
        let child = worker.checkpoint("before-child-registration");
        fs::remove_file(pause).unwrap();

        let status = worker.state("exited");
        assert!(!live(&child));
        let collect = worker.call("collect", None);
        assert_eq!(collect, status);
        assert_eq!(collect["exit_code"], 0);
        assert_eq!(collect["log_ref"], "log");
        assert_eq!(collect["result_ref"], "result", "{collect}");
        assert_eq!(collect["result_digest"], format!("{:x}", Sha256::digest(result.as_bytes())));
        assert!(collect.get("log").is_none() && collect.get("result").is_none());
        assert!(!collect.to_string().contains(PRIVATE_DIAGNOSTIC));
        let runtime = &collect["runtime"];
        assert_eq!(runtime["provider"], provider);
        assert_eq!(runtime["account_ref"], account);
        assert_eq!(runtime["requested_model"], requested);
        assert_eq!(runtime["observed_model"].as_str(), observed);
        assert_eq!(runtime["observed_family"].as_str(), observed.map(|_| provider));
        assert_eq!(runtime["requested_effort"], "medium");
        assert_eq!(runtime["observed_effort"].as_str(), observed.map(|_| "high"));
        assert_eq!(runtime["cli_version"].as_str(), observed.map(|_| "fixture-1.0"));
        assert_eq!(runtime["review_eligible"], observed.is_some());
        assert_eq!(runtime["verdict"], "succeeded");
        assert_eq!(runtime["result_digest"], collect["result_digest"]);
        let private = durable_receipt(&worker);
        assert!(private["log"].as_str().unwrap().contains(PRIVATE_DIAGNOSTIC));
        assert_eq!(private["result"], result);
        assert_eq!(response(worker.run("start", &input)), collect);
        let mut different = input.clone();
        different["manifest"]["provider_run"]["brief"] = "different brief".into();
        assert!(!worker.run("start", &different).status.success());

        // Feed the opaque receipt into the existing v53 journal contract.
        let str_field = |key: &str| runtime[key].as_str().map(str::to_owned);
        let report = jobs::Report {
            exit: jobs::Exit::Exited(0),
            observed_runtime: Some(jobs::Runtime {
                provider: str_field("provider").unwrap(), account_ref: str_field("account_ref"),
                model: str_field("observed_model"), family: str_field("observed_family"), effort: str_field("observed_effort"),
            }),
            observed_cli_version: str_field("cli_version"),
            log_ref: Some(collect["log_ref"].as_str().unwrap().into()),
            result: Some(jobs::Artifact {
                reference: collect["result_ref"].as_str().unwrap().into(),
                digest: collect["result_digest"].as_str().unwrap().into(),
            }),
        };
        jobs::finish(&mut db, &job.id, 1, &report).unwrap();
        drop(db);
        drop(journal);
        let journal = reopen_journal(&journal_dir);
        let db = journal.db().unwrap();
        assert_eq!(schema(&db), crate::history::migrations().len());
        let saved = jobs::status(&db, &job.id).unwrap().unwrap();
        assert_eq!(saved.requested_runtime.model.as_deref(), Some(requested));
        assert_eq!(saved.observed_runtime, report.observed_runtime);
        assert_eq!(saved.observed_cli_version, report.observed_cli_version);
        assert_eq!(saved.completion.unwrap().exit.result, report.result);
    }
}

#[test]
fn gapplan_09_int_expired_login_and_changed_pin_block_the_provider_before_exec() {
    use crate::machines::probe::Provider;

    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "provider-readiness", 1);
    fake_profile(&worker, "codex", "success", 5000);
    let input = provider_request(&worker, "codex");
    let mut probe = worker.inputs.report();
    probe.runtimes.get_mut(&Provider::Codex).unwrap().ready_ms =
        Some(probe.observed_ms - worker.inputs.enrollment.thresholds.max_readiness_age_ms - 1);
    worker.inputs.update(probe);
    let held = response(worker.run("start", &input));
    assert_eq!(held["status"], "held");
    assert_eq!(held["reason"], "login_stale");
    assert_eq!(worker.db().query_row("SELECT count(*) FROM attempts", [], |row| row.get::<_, i64>(0)).unwrap(), 0);

    worker.inputs.update(worker.inputs.report());
    let gate = worker.pause("after-supervisor-pin");
    assert_eq!(response(worker.run("start", &input))["status"], "dispatching");
    worker.checkpoint("after-supervisor-pin");
    fake_profile(&worker, "codex", "missing", 5000);
    fs::remove_file(gate).unwrap();
    let stopped = worker.state("stopped");
    assert_eq!(stopped["reason"], "runtime_profile_changed");
    assert_eq!(stopped["runtime"]["verdict"], "interrupted");
    assert!(identities(&worker.db()).1.is_none());

    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "provider-stale-at-release", 1);
    fake_profile(&worker, "codex", "success", 5000);
    let gate = worker.pause("before-child-registration");
    response(worker.run("start", &provider_request(&worker, "codex")));
    let child = worker.checkpoint("before-child-registration");
    let mut probe = worker.inputs.report();
    probe.runtimes.get_mut(&Provider::Codex).unwrap().ready_ms = None;
    worker.inputs.update(probe);
    fs::remove_file(gate).unwrap();
    let stopped = worker.state("stopped");
    assert_eq!(stopped["reason"], "login_stale");
    assert!(stopped["log_ref"].is_null());
    assert!(!live(&child));
}

#[test]
fn gapplan_09_int_malformed_missing_oversized_or_unsafe_artifacts_cannot_succeed() {
    for (provider, outcome, reason) in [
        ("claude", "malformed", "malformed_runtime_output"),
        ("claude", "missing", "missing_result"),
        ("codex", "missing", "missing_result"),
        ("codex", "oversized", "result_truncated"),
        ("codex", "linked", "missing_result"),
    ] {
        let scratch = tempfile::tempdir().unwrap();
        let worker = Worker::new(scratch.path(), "provider-artifact", 1);
        fake_profile(&worker, provider, outcome, 5000);
        response(worker.run("start", &provider_request(&worker, provider)));
        let settled = worker.state("exited");
        assert_eq!(settled["exit_code"], 0, "{provider} {outcome}: {settled}");
        assert_eq!(settled["runtime"]["verdict"], "failed", "{provider} {outcome}: {settled}");
        assert_eq!(settled["runtime"]["review_eligible"], false);
        assert_eq!(settled["reason"], reason, "{provider} {outcome}: {settled}");
        assert_eq!(settled["result_truncated"], outcome == "oversized");
        assert!(settled["result_ref"].is_null() && settled["result_digest"].is_null());
    }
}

#[test]
fn gapplan_09_int_unknown_model_has_a_result_but_cannot_supply_review_evidence() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "provider-unknown", 1);
    fake_profile(&worker, "codex", "unknown", 5000);
    response(worker.run("start", &provider_request(&worker, "codex")));
    let settled = worker.state("exited");
    assert!(settled["runtime"]["observed_model"].is_null());
    assert!(settled["runtime"]["observed_family"].is_null());
    assert_eq!(settled["runtime"]["review_eligible"], false);
    assert_eq!(settled["runtime"]["verdict"], "succeeded", "{settled}");
    assert_eq!(settled["result_ref"], "result");
}

#[test]
fn gapplan_09_int_runtime_timeout_kills_the_group_and_releases_capacity() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "provider-timeout", 1);
    fake_profile(&worker, "codex", "timeout", 500);
    response(worker.run("start", &provider_request(&worker, "codex")));
    let settled = worker.state("stopped");
    assert_eq!(settled["reason"], "runtime_timeout");
    assert_eq!(settled["runtime"]["verdict"], "interrupted");
    assert_eq!(settled["exit_signal"], libc::SIGKILL);
    assert!(settled["result_ref"].is_null());
    assert_eq!(worker.db().query_row("SELECT count(*) FROM leases", [], |row| row.get::<_, i64>(0)).unwrap(), 0);
}

#[test]
fn gapplan_09_int_inherited_provider_sockets_and_large_stderr_do_not_hold_collection() {
    for outcome in ["inherited", "flood"] {
        let scratch = tempfile::tempdir().unwrap();
        let worker = Worker::new(scratch.path(), "provider-output", 1);
        fake_profile(&worker, "codex", outcome, 5000);
        response(worker.run("start", &provider_request(&worker, "codex")));
        let settled = worker.state("exited");
        assert_eq!(settled["runtime"]["verdict"], "succeeded", "{settled}");
        assert_eq!(settled["result_ref"], "result");
        assert_eq!(worker.db().query_row("SELECT count(*) FROM leases", [], |row| row.get::<_, i64>(0)).unwrap(), 0);
        let receipt = durable_receipt(&worker);
        let log = receipt["log"].as_str().unwrap();
        assert!(log.len() <= 1024);
        if outcome == "flood" {
            assert_eq!(log.len(), 1024);
        }
    }
}

#[test]
fn gapplan_09_int_running_stop_retries_policy_and_database_contention() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "provider-contention", 1);
    let pause = worker.pause("fixture-released");
    worker.call("start", Some("success"));
    let child = worker.checkpoint("fixture-released");
    let mut db = worker.db();
    let heartbeat = |db: &Connection| db.query_row("SELECT heartbeat_ms FROM leases", [], |row| row.get::<_, i64>(0)).unwrap();
    let policy_lock = File::open(worker.inputs.policy_root.join("policy.lock")).unwrap();

    policy_lock.lock().unwrap();
    // A probe that completed policy validation just before the lock can still write its renewal.
    thread::sleep(Duration::from_millis(150));
    let previous = heartbeat(&db);
    thread::sleep(Duration::from_millis(375));
    assert!(live(&child));
    assert_eq!(heartbeat(&db), previous);
    policy_lock.unlock().unwrap();
    until(|| (heartbeat(&db) > previous).then_some(()));

    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).unwrap();
    let previous = heartbeat(&tx);
    thread::sleep(Duration::from_millis(650));
    assert!(live(&child));
    assert_eq!(heartbeat(&tx), previous);
    tx.commit().unwrap();
    until(|| (heartbeat(&db) > previous).then_some(()));
    assert!(live(&child));
    fs::remove_file(pause).unwrap();
    assert_eq!(worker.state("exited")["exit_code"], 0);
}

#[test]
fn gapplan_09_int_running_stop_fences_a_new_policy_even_for_unrelated_rules() {
    let scratch = tempfile::tempdir().unwrap();
    let mut worker = Worker::new(scratch.path(), "provider-fenced", 1);
    let _pause = worker.pause("fixture-released");
    worker.call("start", Some("success"));
    let child = worker.checkpoint("fixture-released");
    worker.inputs.republish(vec![crate::fleet_policy::tests::grant()]);
    let stopped = worker.state("stopped");
    assert_eq!(stopped["reason"], "policy_changed");
    assert_eq!(stopped["exit_signal"], libc::SIGKILL);
    assert!(!live(&child));
}

#[test]
fn gapplan_09_int_running_stop_ends_when_policy_contention_outlasts_the_lease() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "provider-lease-expiry", 1);
    let _pause = worker.pause("fixture-released");
    worker.call("start", Some("success"));
    let child = worker.checkpoint("fixture-released");
    let policy_lock = File::open(worker.inputs.policy_root.join("policy.lock")).unwrap();
    policy_lock.lock().unwrap();
    let stopped = worker.state("stopped");
    assert_eq!(stopped["reason"], "policy_busy");
    assert_eq!(stopped["exit_signal"], libc::SIGKILL);
    assert!(!live(&child));
}


#[test]
fn gapplan_10_int_capture_limits_leave_provider_files_writable() {
    for outcome in ["large_file", "flood_stdout"] {
        let scratch = tempfile::tempdir().unwrap();
        let worker = Worker::new(scratch.path(), "bounded-streams", 1);
        fake_profile(&worker, "codex", outcome, 5000);
        response(worker.run("start", &provider_request(&worker, "codex")));
        let settled = worker.state("exited");
        if outcome == "large_file" {
            assert_eq!(settled["runtime"]["verdict"], "succeeded", "{settled}");
            assert_eq!(fs::metadata(worker.root.join("fixture-runtimes/local/home/large-transcript")).unwrap().len(), 131_072);
        } else {
            assert_eq!(settled["reason"], "malformed_runtime_output");
            assert!(settled["result_ref"].is_null());
        }
    }
}

#[test]
fn gapplan_10_int_abandoned_pinned_supervisor_without_child_releases_its_expired_slot() {
    let scratch = tempfile::tempdir().unwrap();
    let worker = Worker::new(scratch.path(), "abandoned-before-pin", 1);
    let hold = worker.pause("before-child-registration");
    let mut start = worker.send_with_launch_pipe("success");
    assert!(start.wait().unwrap().success());
    let child = worker.checkpoint("before-child-registration");
    let (supervisor, recorded_child, _) = identities(&worker.db());
    assert!(recorded_child.is_none());
    assert_eq!(unsafe { libc::kill(supervisor["pid"].as_i64().unwrap() as i32, libc::SIGKILL) }, 0);
    until(|| (!live(&child)).then_some(()));
    fs::remove_file(hold).unwrap();
    worker.db().execute("UPDATE leases SET expires_ms=heartbeat_ms", []).unwrap();

    let mut next = worker.input(Some("success"));
    next["attempt"]["job_id"] = "after-abandoned-pin".into();
    let reply = response(worker.run("start", &next));
    assert!(matches!(reply["status"].as_str(), Some("dispatching" | "running" | "exited")), "{reply}");
    let mut query = next;
    query.as_object_mut().unwrap().remove("manifest");
    query.as_object_mut().unwrap().remove("fixture");
    until(|| {
        let view = response(worker.run("status", &query));
        (view["status"] == "exited").then_some(())
    });
    // The legacy protocol keeps the lost observation visible.
    assert_eq!(worker.call("status", None)["status"], "unknown");
}
