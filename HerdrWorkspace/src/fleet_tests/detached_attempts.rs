use super::{WAIT, jobs_fixture, reopen_journal, schema};
use crate::{
    history, jobs,
    job_worker::tests::{command, init, live, request, subprocess_entry},
};
use rusqlite::Connection;
use serde_json::Value;
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Child, Output},
    sync::Barrier,
    thread,
    time::{Duration, Instant},
};

struct Worker {
    root: PathBuf,
    request: Value,
}

impl Worker {
    fn new(scratch: &Path, id: &str, attempt: i64) -> Self {
        use std::os::unix::fs::DirBuilderExt;
        let root = scratch.join("worker");
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let enrolled = init(&root);
        Self { request: request(&enrolled, id, attempt), root }
    }

    fn send(&self, verb: &str, fixture: Option<&str>) -> Child {
        let mut input = self.request.clone();
        if let Some(fixture) = fixture {
            input["fixture"] = fixture.into();
        }
        let mut child = command(&self.root, verb).spawn().unwrap();
        serde_json::to_writer(child.stdin.take().unwrap(), &input).unwrap();
        child
    }

    fn call(&self, verb: &str, fixture: Option<&str>) -> Value {
        response(self.send(verb, fixture).wait_with_output().unwrap())
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
            (view["status"] == status).then_some(view)
        })
    }

    fn db(&self) -> Connection {
        history::connection(&self.root.join("attempts.sqlite3")).unwrap()
    }
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
    let first = worker.send("start", Some("success"));
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
    let conflict = worker.send("start", Some("nonzero")).wait_with_output().unwrap();
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
    let pause = worker.pause("fixture-released");
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
        assert!(matches!(response["status"].as_str(), Some("dispatching" | "running")));
    }
    assert_eq!(first["manifest_digest"], second["manifest_digest"]);
    let child = worker.checkpoint("fixture-released");
    let before = identities(&worker.db());
    assert_eq!(before.1.as_ref(), Some(&child));
    fs::remove_file(pause).unwrap();
    worker.state("exited");
    assert_eq!(identities(&worker.db()), before);
}

#[test]
fn gapplan_07_int_nonzero_and_truncated_results_preserve_the_exit() {
    for (number, fixture, exit, truncated) in [
        (1, "nonzero", 17, false),
        (2, "oversized", 0, true),
    ] {
        let scratch = tempfile::tempdir().unwrap();
        let worker = Worker::new(scratch.path(), "job-results", number);
        worker.call("start", Some(fixture));
        let status = worker.state("exited");
        assert_eq!(status["exit_code"], exit);
        assert_eq!(status["result_truncated"], truncated);
        assert_eq!(status["log_ref"], "log");
        assert!(status["result_ref"].is_null());
        assert!(status["result_digest"].is_null());
        let collect = worker.call("collect", None);
        assert!(collect["log"].as_str().unwrap().starts_with("fixture "));
        assert!(collect.get("result").is_none());
        assert_eq!(worker.call("cancel", None), status);
    }
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
