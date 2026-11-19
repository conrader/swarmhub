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

struct Worker {
    root: PathBuf,
    request: Value,
    inputs: Inputs,
}

impl Worker {
    fn new(scratch: &Path, id: &str, attempt: i64) -> Self {
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

    fn pause(&self, checkpoint: &str) -> PathBuf {
        let pause = self.root.join(format!("pause-{checkpoint}"));
        fs::write(&pause, []).unwrap();
        pause
    }

    fn checkpoint(&self, checkpoint: &str) -> Value {
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

    fn db(&self) -> Connection {
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
    assert_eq!(schema(&db), 56);
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
    let alias = scratch.path().join("workdir-alias");
    symlink(workdir, &alias).unwrap();
    worker.request["manifest"]["workdir"] = alias.to_str().unwrap().into();
    let pause = worker.pause("after-supervisor-pin");
    worker.call("start", Some("success"));
    worker.checkpoint("after-supervisor-pin");
    fs::remove_file(&alias).unwrap();
    symlink(scratch.path(), &alias).unwrap();
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
