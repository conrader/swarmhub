use crate::{
    history::{self, History},
    jobs::{self, tests as jobs_fixture},
    parks::{
        self, Adapter, Marker, Outcome, ParkRef, Reason, Source, State, Step, View,
        tests::{decision, manifest, marker, receipt},
    },
};
use rusqlite::Connection;
use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt},
        process::ExitStatusExt,
    },
    path::Path,
    process::{Command, Stdio},
    sync::{Barrier, Mutex, mpsc},
    thread,
    time::{Duration, Instant},
};

const WAIT: Duration = Duration::from_secs(10);
const CRASH_ROOT: &str = "SWARMHUB_GAPPLAN_01_CRASH_FIXTURE_ROOT";

struct MarkerFile<'a, F> {
    project: &'a Path,
    after_apply: F,
}

fn write_marker(project: &Path, marker: &Marker) -> io::Result<()> {
    let mut next = tempfile::NamedTempFile::new_in(project)?;
    serde_json::to_writer(&mut next, marker)?;
    next.as_file().sync_all()?;
    next.persist(project.join("revision"))?;
    Ok(())
}

impl<F> MarkerFile<'_, F> {
    fn replace(&self, expected: &Marker, replacement: &Marker, apply: bool) -> io::Result<Step> {
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.project.join("marker.lock"))?;
        lock.lock()?;
        let observed: Marker = serde_json::from_slice(&fs::read(self.project.join("revision"))?)?;
        if observed != *expected {
            return Ok(Step::Drift);
        }
        if apply {
            let mut log = OpenOptions::new()
                .create(true)
                .append(true)
                .open(self.project.join("applies"))?;
            writeln!(log, "apply")?;
            log.sync_all()?;
        }
        write_marker(self.project, replacement)?;
        Ok(Step::Exit(0))
    }

    fn apply_count(&self) -> usize {
        fs::read_to_string(self.project.join("applies"))
            .unwrap()
            .lines()
            .count()
    }
}

impl<F: Fn()> Adapter for MarkerFile<'_, F> {
    fn observe(&self) -> io::Result<Marker> {
        Ok(serde_json::from_slice(&fs::read(self.project.join("revision"))?)?)
    }

    fn apply(&self, expected: &Marker, replacement: &Marker) -> Step {
        let step = self
            .replace(expected, replacement, true)
            .unwrap_or(Step::Unavailable);
        if step == Step::Exit(0) {
            (self.after_apply)();
        }
        step
    }

    fn rollback(&self, expected: &Marker, replacement: &Marker) -> Step {
        self.replace(expected, replacement, false)
            .unwrap_or(Step::Unavailable)
    }
}

fn setup(root: &Path) -> (History, ParkRef) {
    let project = root.join("project");
    fs::create_dir(&project).unwrap();
    write_marker(&project, &marker("old")).unwrap();
    let history = reopen_journal(&root.join("journal"));
    let park = parks::file(&history.db().unwrap(), "park", &manifest()).unwrap();
    (history, park)
}

#[test]
fn gapplan_01_int_judge_and_human_race_one_durable_claim() {
    let scratch = tempfile::tempdir().unwrap();
    let (history, park) = setup(scratch.path());
    let project = scratch.path().join("project");
    let start = Barrier::new(3);
    let (resume_tx, resume_rx) = mpsc::channel();
    let (result_tx, result_rx) = mpsc::channel();
    let resume_rx = Mutex::new(resume_rx);
    let adapter = MarkerFile {
        project: &project,
        after_apply: || resume_rx.lock().unwrap().recv_timeout(WAIT).unwrap(),
    };
    let mut backstop = history::connection(history.file()).unwrap();
    thread::scope(|scope| {
        for source in [Source::Judge, Source::Human] {
            let mut db = history::connection(history.file()).unwrap();
            let result_tx = result_tx.clone();
            let (start, park, adapter) = (&start, &park, &adapter);
            scope.spawn(move || {
                start.wait();
                result_tx
                    .send(parks::execute(&mut db, park, decision(source), adapter).unwrap())
                    .unwrap();
            });
        }
        start.wait();
        assert_eq!(
            result_rx.recv_timeout(WAIT).unwrap(),
            View::Status(State::Executing)
        );
        let counts = |db: &Connection| {
            db.query_row(
                "SELECT (SELECT count(*) FROM park_executions),
                        (SELECT count(*) FROM park_decisions WHERE action='claim')",
                [],
                |r| Ok((r.get::<_, i32>(0)?, r.get::<_, i32>(1)?)),
            )
            .unwrap()
        };
        assert_eq!(counts(&backstop), (1, 1));
        assert_eq!(
            parks::execute(&mut backstop, &park, decision(Source::Backstop), &adapter).unwrap(),
            View::Status(State::Executing)
        );
        resume_tx.send(()).unwrap();
        let observed = receipt(result_rx.recv_timeout(WAIT).unwrap(), State::Verified);
        let readback = adapter.observe().unwrap();
        assert_eq!(observed.before, Some(marker("old")));
        assert_eq!(observed.apply, Some(Step::Exit(0)));
        assert_eq!(observed.after_apply.as_ref(), Some(&readback));
        assert_eq!(readback.revision, "new");
        assert_eq!(readback.attempt.as_ref(), Some(&observed.attempt));
        assert_eq!(
            parks::execute(&mut backstop, &park, decision(Source::Backstop), &adapter).unwrap(),
            View::Receipt(State::Verified, observed)
        );
        assert_eq!(counts(&backstop), (1, 1));
        assert_eq!(adapter.apply_count(), 1);
    });
}

#[test]
fn gapplan_01_int_killed_executor_recovers_without_replay() {
    if let Some(root) = std::env::var_os(CRASH_ROOT) {
        let root = Path::new(&root);
        let history = reopen_journal(&root.join("journal"));
        let mut db = history::connection(history.file()).unwrap();
        let park = ParkRef {
            id: "park".into(),
            manifest_digest: db
                .query_row("SELECT manifest_digest FROM parks WHERE id='park'", [], |r| {
                    r.get(0)
                })
                .unwrap(),
        };
        let project = root.join("project");
        let adapter = MarkerFile {
            project: &project,
            after_apply: || {
                let _ = io::stdin().read_exact(&mut [0]);
                panic!("the fixture executor should have been killed while waiting");
            },
        };
        parks::execute(&mut db, &park, decision(Source::Human), &adapter).unwrap();
        panic!("the fixture executor returned before the parent killed it");
    }

    for owned in [true, false] {
        let scratch = tempfile::tempdir().unwrap();
        let (history, park) = setup(scratch.path());
        let journal_dir = scratch.path().join("journal");
        let project = scratch.path().join("project");
        let adapter = MarkerFile {
            project: &project,
            after_apply: || {},
        };
        let reader = history::connection(history.file()).unwrap();
        drop(history);
        let mut child = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "fleet_tests::gapplan_01_int_killed_executor_recovers_without_replay",
            ])
            .env(CRASH_ROOT, scratch.path())
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + WAIT;
        let observed = loop {
            let current = adapter.observe().unwrap();
            if current.revision == "new" {
                break Some(current);
            }
            if child.try_wait().unwrap().is_some() || Instant::now() >= deadline {
                break None;
            }
            thread::sleep(Duration::from_millis(10));
        };
        let killed = child.kill();
        let exit = child.wait().unwrap();
        killed.unwrap();
        assert!(!exit.success());
        let observed = observed.expect("executor never changed the fixture marker");
        assert_eq!(
            parks::status(&reader, &park).unwrap(),
            View::Status(State::Executing)
        );
        drop(reader);
        assert_eq!(adapter.apply_count(), 1);
        if !owned {
            write_marker(&project, &marker("new")).unwrap();
        }
        // This test-only reconciler reads the fixture's marker after SIGKILL.
        // Normal bridge startup instead quarantines partial execution evidence.
        let mut db = history::connection(&journal_dir.join("workspace.sqlite3")).unwrap();
        assert_eq!(
            parks::execute(&mut db, &park, decision(Source::Backstop), &adapter).unwrap(),
            View::Status(State::Executing)
        );
        let (state, outcome, expected_marker) = if owned {
            (State::Verified, Outcome::Verified, observed)
        } else {
            (State::Reconciliation, Outcome::Reconciliation, marker("new"))
        };
        let recovered = receipt(
            parks::reconcile_after_restart(&mut db, &park, &adapter).unwrap(),
            state,
        );
        assert_eq!(recovered.outcome, outcome);
        assert_eq!(recovered.reason, Some(Reason::Interrupted));
        assert_eq!(recovered.before, Some(marker("old")));
        assert_eq!(recovered.apply, None);
        assert_eq!(recovered.restart_observation, Some(expected_marker));
        if owned {
            assert_eq!(
                recovered.restart_observation.as_ref().unwrap().attempt.as_ref(),
                Some(&recovered.attempt)
            );
        }
        assert_eq!(
            parks::execute(&mut db, &park, decision(Source::Backstop), &adapter).unwrap(),
            View::Receipt(state, recovered)
        );
        assert_eq!(adapter.apply_count(), 1);
    }
}

#[test]
fn gapplan_01_int_journal_v52_fresh_upgrade_and_reopen() {
    let scratch = tempfile::tempdir().unwrap();
    let fresh = History::open_at(&scratch.path().join("fresh")).unwrap();
    let current_version = history::migrations().len();
    assert_eq!(schema(&fresh.db().unwrap()), current_version);

    let data = scratch.path().join("upgrade");
    fs::DirBuilder::new().mode(0o700).create(&data).unwrap();
    let seed = scratch.path().join("v51.sqlite3");
    OpenOptions::new()
        .create_new(true)
        .write(true)
        .mode(0o600)
        .open(&seed)
        .unwrap();
    let old = Connection::open(&seed).unwrap();
    for migration in &history::migrations()[..51] {
        old.execute_batch(migration).unwrap();
    }
    assert_eq!(schema(&old), 51);
    old.execute(
        "INSERT INTO vault_keychain_retirements(account) VALUES ('fixture-entry')",
        [],
    )
    .unwrap();
    drop(old);
    fs::copy(seed, data.join("workspace.sqlite3")).unwrap();
    for _ in 0..3 {
        let reopened = reopen_journal(&data);
        let db = reopened.db().unwrap();
        assert_eq!(schema(&db), current_version);
        let existing: String = db
            .query_row("SELECT account FROM vault_keychain_retirements", [], |r| r.get(0))
            .unwrap();
        assert_eq!(existing, "fixture-entry");
        for table in ["parks", "park_decisions", "park_executions"] {
            let count: i64 = db
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(count, 0);
        }
    }
}

fn schema(db: &Connection) -> usize {
    db.pragma_query_value(None, "user_version", |r| r.get(0))
        .unwrap()
}

fn job_writes(db: &Connection, id: &str) -> (i64, i64) {
    db.query_row(
        "SELECT (SELECT count(*) FROM job_completions WHERE job_id=?1),
                (SELECT count(*) FROM job_attempts WHERE job_id=?1
                   AND (result_ref IS NOT NULL OR result_digest IS NOT NULL OR log_ref IS NOT NULL))",
        [id],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )
    .unwrap()
}

fn reopen_journal(directory: &Path) -> History {
    const LOCK_BUSY: &str = "Another workspace server may already be using this data directory.";
    // A concurrently spawned child can briefly inherit the lock before exec.
    let deadline = Instant::now() + WAIT;
    loop {
        match History::open_at(directory) {
            Ok(history) => return history,
            Err(error) => {
                if error.to_string() != LOCK_BUSY || Instant::now() >= deadline {
                    panic!(
                        "could not reopen journal at {}: {error}",
                        directory.display()
                    );
                }
                thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

#[test]
fn gapplan_02_int_exit_and_replay_in_either_order_commit_one_event() {
    use jobs_fixture::{ATTEMPT, OWNER};

    let scratch = tempfile::tempdir().unwrap();
    let h = jobs_fixture::journal(&scratch.path().join("journal"));
    let mut callback = history::connection(h.file()).unwrap();
    let mut poller = history::connection(h.file()).unwrap();
    for callback_first in [true, false] {
        let job = jobs_fixture::submit_fixture(&mut callback, &format!("job-{callback_first}"));
        assert_eq!(jobs_fixture::dispatch(&mut callback, &job), jobs::Dispatch::Recorded);
        assert_eq!(jobs::status(&poller, &job.id).unwrap().unwrap().status, "dispatching");
        assert_eq!(jobs_fixture::dispatch(&mut poller, &job), jobs::Dispatch::AlreadyRecorded);
        assert!(matches!(
            jobs::record_dispatch(&mut poller, &job.id, ATTEMPT, "different-host", "different-lease"),
            Err(jobs::Error::Conflict)
        ));

        let (first, second) = if callback_first {
            (&mut callback, &mut poller)
        } else {
            (&mut poller, &mut callback)
        };
        let report = jobs_fixture::success();
        let event = jobs::finish(first, &job.id, ATTEMPT, &report).unwrap();
        let observed = jobs::status(second, &job.id).unwrap().unwrap();
        assert_eq!(observed.completion.as_ref(), Some(&event));
        assert_eq!(event.owner_bot_id, OWNER);
        assert_eq!(event.exit.verdict, "succeeded");
        assert_eq!(event.exit.result, report.result);
        assert_eq!(event.exit.log_ref, report.log_ref);
        assert_eq!(event.expected_next_action, "review_result");
        assert_eq!(observed.requested_runtime, jobs_fixture::submission().runtime);
        assert_eq!(observed.observed_runtime, report.observed_runtime);
        assert_eq!(observed.observed_cli_version, report.observed_cli_version);
        assert_eq!(jobs::finish(second, &job.id, ATTEMPT, &jobs_fixture::success()).unwrap(), event);
        assert!(matches!(
            jobs::finish(second, &job.id, ATTEMPT, &jobs_fixture::report(jobs::Exit::Exited(1))),
            Err(jobs::Error::Conflict)
        ));
        assert!(!jobs::record_running(second, &job.id, ATTEMPT).unwrap());
        assert_eq!(job_writes(second, &job.id), (1, 1));
        assert_eq!(jobs::status(second, &job.id).unwrap().unwrap().completion, Some(event));
    }
}

#[test]
fn gapplan_02_int_concurrent_finish_callbacks_commit_one_event() {
    use jobs_fixture::ATTEMPT;

    let scratch = tempfile::tempdir().unwrap();
    let h = jobs_fixture::journal(&scratch.path().join("journal"));
    let job = {
        let mut db = h.db().unwrap();
        let job = jobs_fixture::submit_fixture(&mut db, "concurrent-finish");
        assert_eq!(
            jobs_fixture::dispatch(&mut db, &job),
            jobs::Dispatch::Recorded
        );
        job
    };
    let writers = [
        history::connection(h.file()).unwrap(),
        history::connection(h.file()).unwrap(),
    ];
    let start = Barrier::new(writers.len());
    let report = jobs_fixture::success();
    let (first, second) = thread::scope(|scope| {
        let [first, second] = writers.map(|mut db| {
            let (start, id, report) = (&start, &job.id, &report);
            scope.spawn(move || {
                start.wait();
                jobs::finish(&mut db, id, ATTEMPT, report).unwrap()
            })
        });
        (first.join().unwrap(), second.join().unwrap())
    });

    assert_eq!(first, second);
    let db = h.db().unwrap();
    assert_eq!(job_writes(&db, &job.id), (1, 1));
    let status = jobs::status(&db, &job.id).unwrap().unwrap();
    assert_eq!(status.status, "exited");
    assert_eq!(status.completion, Some(first));
}

#[tokio::test]
async fn gapplan_02_int_http_job_status_returns_completion_or_not_found() {
    use axum::http::StatusCode;
    use jobs_fixture::ATTEMPT;

    let scratch = tempfile::tempdir().unwrap();
    let history = jobs_fixture::journal(&scratch.path().join("journal"));
    let (job, event) = {
        let mut db = history.db().unwrap();
        let job = jobs_fixture::submit_fixture(&mut db, "http-status");
        assert_eq!(
            jobs_fixture::dispatch(&mut db, &job),
            jobs::Dispatch::Recorded
        );
        let event = jobs::finish(&mut db, &job.id, ATTEMPT, &jobs_fixture::success()).unwrap();
        (job, event)
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let token = "a".repeat(64);
    let app = crate::workspace_router(crate::Workspace {
        core: crate::Core(scratch.path().join("core.sock")),
        history,
        worker_core: None,
        fleet_policy: Ok(None),
        parks: crate::parks::Service::default(),
        approvals: Default::default(),
        drafts: Default::default(),
        connected_files: None,
        drive_access: Default::default(),
        drive_files: None,
        github_project: None,
        vault: None,
        slack: None,
        port,
        token: token.clone(),
    });
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(WAIT)
        .build()
        .unwrap();
    let get = |id: &str| {
        client
            .get(format!("http://127.0.0.1:{port}/api/jobs/{id}"))
            .bearer_auth(&token)
            .send()
    };

    let known = get(&job.id).await.unwrap();
    assert_eq!(known.status(), StatusCode::OK);
    let body: serde_json::Value = serde_json::from_slice(&known.bytes().await.unwrap()).unwrap();
    assert_eq!(body["id"], job.id);
    assert_eq!(body["status"], "exited");
    assert_eq!(body["completion"], serde_json::to_value(event).unwrap());
    assert_eq!(
        get("unknown-job").await.unwrap().status(),
        StatusCode::NOT_FOUND
    );
    server.abort();
}

#[test]
fn gapplan_02_int_event_insert_failure_rolls_back_terminal_write_and_can_retry() {
    use jobs_fixture::ATTEMPT;

    let scratch = tempfile::tempdir().unwrap();
    let h = jobs_fixture::journal(&scratch.path().join("journal"));
    let mut writer = history::connection(h.file()).unwrap();
    let observer = history::connection(h.file()).unwrap();
    let job = jobs_fixture::submit_fixture(&mut writer, "injected");
    jobs_fixture::dispatch(&mut writer, &job);
    assert!(jobs::record_running(&writer, &job.id, ATTEMPT).unwrap());
    writer.execute_batch(
        "CREATE TEMP TRIGGER fail_job_completion BEFORE INSERT ON job_completions
         BEGIN SELECT RAISE(ABORT, 'injected completion insert failure'); END;",
    ).unwrap();

    assert!(matches!(
        jobs::finish(&mut writer, &job.id, ATTEMPT, &jobs_fixture::success()),
        Err(jobs::Error::Storage(_))
    ));
    let observed = jobs::status(&observer, &job.id).unwrap().unwrap();
    assert_eq!(observed.status, "running");
    assert!(observed.observed_runtime.is_none());
    assert!(observed.observed_cli_version.is_none());
    assert!(observed.completion.is_none());
    assert_eq!(job_writes(&observer, &job.id), (0, 0));

    writer.execute_batch("DROP TRIGGER fail_job_completion").unwrap();
    let event = jobs::finish(&mut writer, &job.id, ATTEMPT, &jobs_fixture::success()).unwrap();
    assert_eq!(jobs::status(&observer, &job.id).unwrap().unwrap().completion, Some(event));
    assert_eq!(job_writes(&observer, &job.id), (1, 1));
}

#[test]
fn gapplan_02_int_killed_between_writes_leaves_no_exit_event_or_result() {
    const JOB_CRASH_ROOT: &str = "SWARMHUB_GAPPLAN_02_CRASH_FIXTURE_ROOT";
    use jobs_fixture::ATTEMPT;

    if let Some(root) = std::env::var_os(JOB_CRASH_ROOT) {
        let root = Path::new(&root);
        let h = reopen_journal(&root.join("journal"));
        let mut db = history::connection(h.file()).unwrap();
        let id: String = db.query_row("SELECT id FROM jobs", [], |r| r.get(0)).unwrap();
        jobs_fixture::finish_after_update(&mut db, &id, || {
            fs::write(root.join("after-update"), b"ready").unwrap();
            let _ = io::stdin().read_exact(&mut [0]);
            panic!("fixture writer must be killed between the two writes");
        }).unwrap();
        panic!("fixture writer returned before it was killed");
    }

    let scratch = tempfile::tempdir().unwrap();
    let directory = scratch.path().join("journal");
    let h = jobs_fixture::journal(&directory);
    let job = jobs_fixture::submit_fixture(&mut h.db().unwrap(), "killed");
    jobs_fixture::dispatch(&mut h.db().unwrap(), &job);
    let reader = history::connection(h.file()).unwrap();
    drop(h);
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "fleet_tests::gapplan_02_int_killed_between_writes_leaves_no_exit_event_or_result",
        ])
        .env(JOB_CRASH_ROOT, scratch.path())
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + WAIT;
    let ready = loop {
        if scratch.path().join("after-update").is_file() {
            break true;
        }
        if child.try_wait().unwrap().is_some() || Instant::now() >= deadline {
            break false;
        }
        thread::sleep(Duration::from_millis(10));
    };
    let during = jobs::status(&reader, &job.id);
    let during_writes = job_writes(&reader, &job.id);
    let killed = child.kill();
    let exit = child.wait().unwrap();
    assert!(ready, "fixture never reached the point between the two writes");
    killed.unwrap();
    assert_eq!(exit.signal(), Some(libc::SIGKILL));
    let during = during.unwrap().unwrap();
    assert_eq!(during.status, "dispatching");
    assert!(during.completion.is_none());
    assert_eq!(during_writes, (0, 0));
    drop(reader);

    let reopened = reopen_journal(&directory);
    let mut db = reopened.db().unwrap();
    assert_eq!(jobs::status(&db, &job.id).unwrap().unwrap(), during);
    assert_eq!(job_writes(&db, &job.id), (0, 0));
    let event = jobs::finish(&mut db, &job.id, ATTEMPT, &jobs_fixture::success()).unwrap();
    assert_eq!(jobs::status(&db, &job.id).unwrap().unwrap().completion, Some(event));
    assert_eq!(job_writes(&db, &job.id), (1, 1));
}

#[test]
fn gapplan_02_int_unresolved_status_survives_restarts_until_reconciled() {
    use jobs_fixture::{ATTEMPT, OWNER};

    let scratch = tempfile::tempdir().unwrap();
    let directory = scratch.path().join("journal");
    let h = jobs_fixture::journal(&directory);
    let (start, exit) = {
        let mut db = h.db().unwrap();
        let start = jobs_fixture::submit_fixture(&mut db, "lost-start");
        let exit = jobs_fixture::submit_fixture(&mut db, "lost-exit");
        let queued = jobs::status(&db, &start.id).unwrap().unwrap();
        assert_eq!(queued.status, "queued");
        assert!(queued.completion.is_none());
        assert!(matches!(
            jobs::finish(&mut db, &start.id, ATTEMPT, &jobs_fixture::success()),
            Err(jobs::Error::Conflict)
        ));
        jobs_fixture::dispatch(&mut db, &start);
        jobs_fixture::dispatch(&mut db, &exit);
        assert!(jobs::record_running(&db, &exit.id, ATTEMPT).unwrap());
        assert!(jobs::record_unknown(&db, &start.id, ATTEMPT).unwrap());
        assert!(jobs::record_unknown(&db, &exit.id, ATTEMPT).unwrap());
        db.execute("UPDATE bots SET removed_ms=2 WHERE id=?1", [OWNER]).unwrap();
        (start, exit)
    };
    drop(h);

    let reopened = reopen_journal(&directory);
    let event = {
        let mut db = reopened.db().unwrap();
        for (job, reason) in [(&start, "start_unconfirmed"), (&exit, "exit_unconfirmed")] {
            let unresolved = jobs::status(&db, &job.id).unwrap().unwrap();
            assert_eq!(unresolved.status, "unknown");
            assert_eq!(unresolved.exit_reason.as_deref(), Some(reason));
            assert_eq!(unresolved.owner_bot_id, OWNER);
            assert!(unresolved.completion.is_none());
            assert_eq!(job_writes(&db, &job.id), (0, 0));
            assert_eq!(jobs_fixture::dispatch(&mut db, job), jobs::Dispatch::AlreadyRecorded);
        }
        jobs::finish(&mut db, &exit.id, ATTEMPT, &jobs_fixture::success()).unwrap()
    };
    drop(reopened);

    let reopened = reopen_journal(&directory);
    let db = reopened.db().unwrap();
    assert_eq!(jobs::status(&db, &exit.id).unwrap().unwrap().completion, Some(event));
    assert_eq!(job_writes(&db, &exit.id), (1, 1));
    assert_eq!(jobs::status(&db, &start.id).unwrap().unwrap().status, "unknown");
    assert_eq!(job_writes(&db, &start.id), (0, 0));
}

#[test]
fn gapplan_02_int_journal_v53_fresh_upgrade_and_reopen() {
    fn assert_v53_tables(db: &Connection) {
        for table in ["jobs", "job_attempts", "job_completions"] {
            let count: i64 = db
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(count, 0);
        }
    }

    let scratch = tempfile::tempdir().unwrap();
    let fresh = History::open_at(&scratch.path().join("fresh")).unwrap();
    assert_eq!(schema(&fresh.db().unwrap()), history::migrations().len());
    assert_v53_tables(&fresh.db().unwrap());

    let seed = scratch.path().join("v52.sqlite3");
    let old = Connection::open(&seed).unwrap();
    for migration in &history::migrations()[..52] {
        old.execute_batch(migration).unwrap();
    }
    assert_eq!(schema(&old), 52);
    let park = parks::file(&old, "preexisting-park", &manifest()).unwrap();
    old.execute(
        "INSERT INTO bots (id,name,agent_name,created_ms,updated_ms)
         VALUES ('preexisting-bot','Fixture Bot','fixture-bot',1,1)",
        [],
    ).unwrap();
    drop(old);

    let directory = scratch.path().join("upgrade");
    fs::DirBuilder::new().mode(0o700).create(&directory).unwrap();
    fs::copy(seed, directory.join("workspace.sqlite3")).unwrap();
    fs::set_permissions(
        directory.join("workspace.sqlite3"),
        std::os::unix::fs::PermissionsExt::from_mode(0o600),
    ).unwrap();
    for _ in 0..3 {
        let reopened = reopen_journal(&directory);
        let db = reopened.db().unwrap();
        assert_eq!(schema(&db), history::migrations().len());
        assert_v53_tables(&db);
        assert_eq!(parks::status(&db, &park).unwrap(), View::Status(State::Pending));
        let name: String = db.query_row(
            "SELECT name FROM bots WHERE id='preexisting-bot'", [], |r| r.get(0),
        ).unwrap();
        assert_eq!(name, "Fixture Bot");
    }
}

mod job_delivery {
    use super::*;
    use crate::{Core, Workspace, bots::{self, Ask, desk}, core::{COMPLETION_SEND, COMPLETION_START}};
    use axum::http::StatusCode;
    use serde_json::{Value, json};
    use std::sync::Arc;
    use tokio::{
        io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
        net::UnixListener,
        sync::Notify,
        task::JoinHandle,
        time::timeout,
    };

    const OWNER: &str = jobs_fixture::OWNER;
    const CRASH_JOURNAL: &str = "SWARMHUB_GAPPLAN_03_CRASH_JOURNAL";
    const CRASH_ACK: &str = "SWARMHUB_GAPPLAN_03_CRASH_ACK";
    const CRASH_TEST: &str =
        "fleet_tests::job_delivery::gapplan_03_int_killed_during_transport_reconciles_and_ack_retry_resumes";
    pub(super) const AUTH: &str = "fixture-workspace-token";
    pub(super) const ORIGIN: &str = "http://localhost:41053";

    #[derive(Default)]
    struct CoreState {
        agents: Vec<Value>,
        machines: Vec<Value>,
        writes: Vec<Value>,
        launches: usize,
        hold_reply: Option<Arc<Notify>>,
        before_guarded_write: Option<Value>,
        unsupported: bool,
    }

    pub(super) struct FakeCore {
        state: Arc<Mutex<CoreState>>,
        wrote: Arc<Notify>,
        task: JoinHandle<()>,
    }

    impl Drop for FakeCore {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    impl FakeCore {
        pub(super) fn start(path: &Path) -> Self {
            let listener = UnixListener::bind(path).unwrap();
            let state = Arc::new(Mutex::new(CoreState::default()));
            let wrote = Arc::new(Notify::new());
            let fake = state.clone();
            let signal = wrote.clone();
            let task = tokio::spawn(async move {
                while let Ok((socket, _)) = listener.accept().await {
                    let fake = fake.clone();
                    let signal = signal.clone();
                    tokio::spawn(async move {
                        let mut socket = BufReader::new(socket);
                        let mut line = String::new();
                        socket.read_line(&mut line).await.unwrap();
                        let q: Value = serde_json::from_str(&line).unwrap();
                        let (outcome, hold) = fake.lock().unwrap().reply(&q, &signal);
                        if let Some(hold) = hold {
                            hold.notified().await;
                        }
                        let reply = match outcome {
                            Ok(data) => json!({"jsonrpc":"2.0","id":q["id"],"result":data}),
                            Err(kind) => json!({"jsonrpc":"2.0","id":q["id"],"error":{
                                "message":"Fixture rejected the write.","data":{"kind":kind}
                            }}),
                        };
                        let _ = socket.get_mut().write_all(format!("{reply}\n").as_bytes()).await;
                    });
                }
            });
            Self { state, wrote, task }
        }

        pub(super) fn agents(&self, agents: Vec<Value>) {
            self.state.lock().unwrap().agents = agents;
        }

        pub(super) fn machines(&self, machines: Vec<Value>) {
            self.state.lock().unwrap().machines = machines;
        }

        pub(super) fn writes(&self) -> Vec<Value> {
            self.state.lock().unwrap().writes.clone()
        }
    }

    impl CoreState {
        fn reply(&mut self, q: &Value, wrote: &Notify) -> (Result<Value, &'static str>, Option<Arc<Notify>>) {
            let p = &q["params"];
            let method = q["method"].as_str().unwrap();
            let data = match method {
                "hello" => {
                    let mut methods = vec!["templates.list", "terminal.get", "terminal.list", "terminal.run",
                        "terminal.read", "terminal.send", "terminal.interrupt", "terminal.kill"];
                    if !self.unsupported {
                        methods.extend([COMPLETION_SEND, COMPLETION_START]);
                    }
                    json!({"generation":1,"version":"fixture","core":{"id":"core"},"methods":methods})
                }
                "machine.list" => json!({"machines":self.machines}),
                "terminal.list" => json!({"terminals":self.agents}),
                "terminal.get" => {
                    let Some(agent) = self.agents.iter().find(|agent| agent["address"] == p["terminal"]) else {
                        return (Err("not_found"), None);
                    };
                    agent.clone()
                }
                "templates.list" => json!({"templates":[{"name":"fixture","description":"Offline fixture"}]}),
                COMPLETION_START => {
                    assert_eq!(p["core"], "core");
                    assert_eq!(p["argv"], json!(["fixture"]));
                    assert!(p["env"]["SWARMHUB_VAULT_SESSION"].is_null());
                    self.launches += 1;
                    let agent = terminal(
                        p["name"].as_str().unwrap(),
                        p["labels"]["swarmhub.launch"].as_str().unwrap(),
                        "t9", 100 + self.launches as u64, "idle",
                    );
                    self.agents.push(agent.clone());
                    agent
                }
                COMPLETION_SEND | "terminal.send" => {
                    if method == COMPLETION_SEND && let Some(status) = self.before_guarded_write.take() {
                        self.agents[0]["status"] = status;
                    }
                    let Some(agent) = self.agents.iter_mut().find(|agent| agent["address"] == p["terminal"]) else {
                        return (Err("status_mismatch"), None);
                    };
                    if method == COMPLETION_SEND && (p["core"] != "core"
                        || p["created_ms"] != agent["created_ms"]
                        || p["launch"] != agent["labels"]["swarmhub.launch"]
                        || p["turn"] != agent["turn"]
                        || !matches!(agent["status"]["state"].as_str(), Some("idle" | "done")))
                    {
                        return (Err("status_mismatch"), None);
                    }
                    agent["status"] = json!({"state":"working"});
                    self.writes.push(p.clone());
                    wrote.notify_one();
                    return (Ok(json!({"status":"working","started":true})), self.hold_reply.take());
                }
                _ => panic!("unexpected fixture Core method {method}"),
            };
            (Ok(data), None)
        }
    }

    pub(super) fn workspace(root: &Path, history: History) -> Workspace {
        Workspace {
            core: Core(root.join("core.sock")),
            history,
            worker_core: None,
            fleet_policy: Ok(None),
            parks: crate::parks::Service::default(),
            approvals: Default::default(),
            drafts: Default::default(),
            connected_files: None,
            drive_access: Default::default(),
            drive_files: None,
            github_project: None,
            vault: None,
            slack: None,
            port: 41053,
            token: AUTH.into(),
        }
    }

    pub(super) struct TestApi {
        pub(super) client: reqwest::Client,
        task: JoinHandle<()>,
    }

    impl Drop for TestApi {
        fn drop(&mut self) {
            self.task.abort();
        }
    }

    impl TestApi {
        pub(super) fn start(root: &Path, w: &Workspace) -> Self {
            let path = root.join("api.sock");
            let listener = UnixListener::bind(&path).unwrap();
            let app = crate::workspace_router(w.clone());
            let task = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
            let client = reqwest::Client::builder().unix_socket(path).timeout(WAIT).build().unwrap();
            Self { client, task }
        }

        pub(super) async fn status(&self, path: &str) -> Value {
            let response = self.client.get(format!("{ORIGIN}{path}")).bearer_auth(AUTH)
                .send().await.unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            serde_json::from_slice(&response.bytes().await.unwrap()).unwrap()
        }

        async fn webhook(&self, routine: i64, sentinel: &str, key: &str, body: &Value) -> u64 {
            let response = self.client.post(format!("{ORIGIN}/hooks/routines/{routine}"))
                .bearer_auth(sentinel).header("Idempotency-Key", key)
                .header("content-type", "application/json").body(body.to_string()).send().await.unwrap();
            assert_eq!(response.status(), StatusCode::ACCEPTED);
            let value: Value = serde_json::from_slice(&response.bytes().await.unwrap()).unwrap();
            value["id"].as_u64().unwrap()
        }
    }

    pub(super) fn terminal(name: &str, key: &str, address: &str, created: u64, status: &str) -> Value {
        json!({
            "address":address,"created_ms":created,"name":name,"state":"live","template":"fixture",
            "status":{"state":status},"turn":0,
            "labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        })
    }

    pub(super) fn session(history: &History, bot: &str, address: &str, created: u64, status: &str) -> Value {
        let name = bots::one(&history.db().unwrap(), bot).unwrap().unwrap().agent_name;
        let (launch, key) = history.start_launch("core", &name, "Fixture first task", None, "{}", "")
            .unwrap().unwrap();
        let agent = terminal(&name, &key, address, created, status);
        history.finish(launch, history::State::Sent, None,
            Some(&serde_json::from_value(agent.clone()).unwrap())).unwrap();
        agent
    }

    fn new_job(db: &mut Connection, key: &str, report: &jobs::Report) -> String {
        let job = jobs_fixture::submit_fixture(db, key);
        assert_eq!(jobs_fixture::dispatch(db, &job), jobs::Dispatch::Recorded);
        jobs::finish(db, &job.id, jobs_fixture::ATTEMPT, report).unwrap();
        job.id
    }

    fn event_id(job: &str) -> String {
        format!("{job}:{}", jobs_fixture::ATTEMPT)
    }

    fn new_fixture() -> (tempfile::TempDir, Workspace, FakeCore) {
        let temp = tempfile::tempdir().unwrap();
        let history = jobs_fixture::journal(&temp.path().join("journal"));
        let w = workspace(temp.path(), history);
        let core = FakeCore::start(&w.core.0);
        (temp, w, core)
    }

    fn state(history: &History, job: &str) -> (String, Option<String>) {
        history.db().unwrap().query_row(
            "SELECT state,blocker FROM job_deliveries WHERE job_id=?1", [job],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap()
    }

    fn ready(history: &History) {
        history.db().unwrap().execute(
            "UPDATE job_deliveries SET retry_ms=0 WHERE state!='acknowledged'", [],
        ).unwrap();
    }

    async fn finish_drain(tasks: Vec<JoinHandle<()>>) {
        for task in tasks {
            timeout(WAIT, task).await.unwrap().unwrap();
        }
    }

    pub(super) async fn drain(w: &Workspace) {
        finish_drain(desk::drain(w)).await;
    }

    async fn command(w: &Workspace, agent: &Value, ask: Ask) -> Result<String, String> {
        let key = agent["labels"]["swarmhub.launch"].as_str().unwrap();
        bots::answer(w, Ok("core".into()), key, ask).await
    }

    #[tokio::test]
    async fn gapplan_03_int_busy_owner_and_provider_prompt_defer_until_idle() {
        let (_temp, w, core) = new_fixture();
        let mut db = w.history.db().unwrap();
        let job = new_job(&mut db, "busy-owner", &jobs_fixture::success());
        drop(db);
        let mut agent = session(&w.history, OWNER, "t1", 1, "working");
        core.agents(vec![agent.clone()]);
        drain(&w).await;
        assert_eq!(state(&w.history, &job), ("pending".into(), Some("Owner has an active turn.".into())));
        assert!(core.writes().is_empty());

        agent["status"] = json!({"state":"blocked","kind":"permission"});
        core.agents(vec![agent.clone()]);
        ready(&w.history);
        drain(&w).await;
        assert_eq!(state(&w.history, &job).1.as_deref(), Some("Owner is waiting at a provider prompt."));
        assert!(core.writes().is_empty());

        agent["status"] = json!({"state":"idle"});
        core.agents(vec![agent.clone()]);
        core.state.lock().unwrap().before_guarded_write = Some(json!({"state":"blocked","kind":"auth"}));
        ready(&w.history);
        drain(&w).await;
        assert!(core.writes().is_empty(), "a prompt appeared just before Core accepted the write");
        assert_eq!(state(&w.history, &job).0, "pending");

        core.agents(vec![agent]);
        ready(&w.history);
        drain(&w).await;
        assert_eq!(state(&w.history, &job), ("offered".into(), None));
        assert_eq!(core.writes().len(), 1);
        assert!(core.writes()[0]["text"].as_str().unwrap().contains(&event_id(&job)));
    }

    #[tokio::test]
    async fn prerelease_second_send_is_saved_during_a_busy_terminal_turn() {
        let (_temp, w, core) = new_fixture();
        core.agents(vec![session(&w.history, OWNER, "t1", 1, "idle")]);
        let hold = Arc::new(Notify::new());
        core.state.lock().unwrap().hold_reply = Some(hold.clone());
        let send = |text| tokio::spawn(crate::send_message(
            w.clone(), "t1".into(), 1,
            serde_json::from_value(json!({"text":text})).unwrap(), vec![],
        ));
        let first = send("First task, still sending.");
        timeout(WAIT, core.wrote.notified()).await.unwrap();
        let second = send("Second task, waiting for the turn.");
        timeout(WAIT, async {
            loop {
                let saved = w.history.db().unwrap().query_row(
                    "SELECT EXISTS (SELECT 1 FROM journal WHERE kind='task' AND state='pending' AND text=?1)",
                    ["Second task, waiting for the turn."], |row| row.get::<_, bool>(0),
                ).unwrap();
                if saved {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        }).await.expect("the second task must be saved before the first send finishes");
        assert_eq!(core.writes().len(), 1);
        hold.notify_one();
        assert!(timeout(WAIT, first).await.unwrap().unwrap().is_ok());
        assert!(timeout(WAIT, second).await.unwrap().unwrap().is_ok());
        assert_eq!(core.writes().len(), 2);
    }

    #[tokio::test]
    async fn gapplan_03_int_two_drainers_serialize_with_a_foreground_task() {
        let (_temp, w, core) = new_fixture();
        let agent = session(&w.history, OWNER, "t1", 1, "idle");
        core.agents(vec![agent.clone()]);
        let job = new_job(&mut *w.history.db().unwrap(), "two-drainers", &jobs_fixture::success());
        let hold = Arc::new(Notify::new());
        core.state.lock().unwrap().hold_reply = Some(hold.clone());
        let foreground = tokio::spawn(crate::send_message(
            w.clone(), "t1".into(), 1,
            serde_json::from_value(json!({"text":"A foreground task."})).unwrap(), vec![],
        ));
        timeout(WAIT, core.wrote.notified()).await.unwrap();
        let first = desk::drain(&w);
        assert_eq!(first.len(), 1);
        assert!(desk::drain(&w).is_empty());
        assert_eq!(core.writes().len(), 1);
        hold.notify_one();
        assert!(timeout(WAIT, foreground).await.unwrap().unwrap().is_ok());
        finish_drain(first).await;
        assert_eq!(state(&w.history, &job).1.as_deref(), Some("Owner has an active turn."));

        core.agents(vec![agent]);
        ready(&w.history);
        let hold = Arc::new(Notify::new());
        core.state.lock().unwrap().hold_reply = Some(hold.clone());
        let first = desk::drain(&w);
        timeout(WAIT, core.wrote.notified()).await.unwrap();
        let evidence = Connection::open(w.history.file()).unwrap().query_row(
            "SELECT o.state,j.state,launch.launch_key
             FROM job_deliveries d JOIN bot_outbox o ON o.id=d.outbox
             JOIN job_delivery_offers f ON f.task=o.task AND f.outbox=o.id
             JOIN journal j ON j.id=f.task JOIN journal launch ON launch.id=f.launch
             WHERE d.job_id=?1", [&job],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?)),
        ).unwrap();
        assert_eq!(evidence.0, "typing");
        assert_eq!(evidence.1, "pending");
        assert_eq!(evidence.2, core.writes()[1]["launch"]);
        assert!(desk::drain(&w).is_empty());
        hold.notify_one();
        finish_drain(first).await;
        assert_eq!(state(&w.history, &job).0, "offered");
        assert_eq!(core.writes().len(), 2);
    }

    #[tokio::test]
    async fn gapplan_03_int_closed_client_starts_owner_and_replacement_recovers_safe_result() {
        use sha2::{Digest, Sha256};

        let (temp, w, core) = new_fixture();
        let result = b"deterministic fixture result\n";
        let path = temp.path().join("fixture-result");
        fs::write(&path, result).unwrap();
        let report = jobs::Report {
            result: Some(jobs::Artifact {
                reference: "fixture-result".into(), digest: format!("{:x}", Sha256::digest(result)),
            }),
            ..jobs_fixture::success()
        };
        let job = new_job(&mut *w.history.db().unwrap(), "closed-client", &report);
        // No API or GUI client is running. The desk starts the registered bot.
        drain(&w).await;
        assert_eq!(core.state.lock().unwrap().launches, 1);
        let previous = core.state.lock().unwrap().agents[0].clone();
        let owner_name = previous["name"].as_str().unwrap().to_owned();
        let routine = w.history.db().unwrap().query_row(
            "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state)
             VALUES ('core',?1,?2,?3,'Fixture webhook','Process fixture event','{\"kind\":\"webhook\"}','active')
             RETURNING id",
            rusqlite::params![previous["address"].as_str(), previous["created_ms"].as_u64(), owner_name],
            |r| r.get::<_, i64>(0),
        ).unwrap();
        let (sentinel, _) = w.history.rotate_webhook(routine, "fixture-master").unwrap().unwrap();
        let api = TestApi::start(temp.path(), &w);
        let mut idle = previous.clone();
        idle["status"] = json!({"state":"idle"});
        core.agents(vec![idle]);
        let run = api.webhook(routine, &sentinel, "old-webhook", &json!({"fixture_credential":sentinel})).await;
        timeout(WAIT, async {
            // The completion also signals, so wait until the ordinary webhook has actually typed.
            while core.writes().len() < 2 {
                core.wrote.notified().await;
            }
        }).await.unwrap();
        assert!(core.writes()[1]["text"].as_str().unwrap().contains(&sentinel));
        assert!(run > 0);
        let replacement = session(&w.history, OWNER, "t2", 200, "idle");
        core.agents(vec![replacement.clone()]);
        let id = event_id(&job);
        assert!(command(&w, &previous, Ask::CompletionAck { id: id.clone() }).await.is_err());
        let inbox = command(&w, &replacement, Ask::CompletionInbox { id: None }).await.unwrap();
        let inbox_items: Value = serde_json::from_str(&inbox).unwrap();
        assert_eq!(inbox_items[0]["id"], id);
        assert_eq!(inbox_items[0]["result_ref"], "fixture-result");

        ready(&w.history);
        drain(&w).await;
        let writes = core.writes();
        assert_eq!(writes.len(), 3);
        let replacement_payload = writes[2]["text"].as_str().unwrap();
        assert_eq!(writes[2]["launch"], replacement["labels"]["swarmhub.launch"]);
        assert!(replacement_payload.contains(&id));
        assert!(replacement_payload.contains("fixture-result"));
        let status = api.status(&format!("/api/jobs/{job}")).await;
        assert_eq!(status["completion_delivery"]["id"], id);
        let reference = status["completion"]["exit"]["result"]["reference"].as_str().unwrap();
        assert_eq!(reference, "fixture-result");
        let delivered_result = fs::read_to_string(temp.path().join(reference)).unwrap();
        assert_eq!(delivered_result.as_bytes(), result);
        assert_eq!(status["completion"]["exit"]["result"]["digest"], format!("{:x}", Sha256::digest(&delivered_result)));
        for surface in [&inbox, replacement_payload, &status.to_string(), &delivered_result] {
            assert!(!surface.contains(&sentinel));
        }
        let token = command(&w, &replacement, Ask::CompletionAck { id: id.clone() }).await.unwrap();
        assert_eq!(command(&w, &replacement, Ask::CompletionAck { id }).await.unwrap(), token);
        assert_eq!(api.status("/api/attention").await["completions"], json!([]));
    }

    fn crash_child(journal: &Path) -> Command {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command.args(["--exact", CRASH_TEST]).env(CRASH_JOURNAL, journal)
            .stdout(Stdio::null()).stderr(Stdio::null());
        command
    }

    fn kill_fixture(child: &mut std::process::Child) {
        let killed = child.kill();
        let exit = child.wait().unwrap();
        killed.unwrap();
        assert_eq!(exit.signal(), Some(libc::SIGKILL));
    }

    #[tokio::test]
    async fn gapplan_03_int_offer_link_failure_rolls_back_the_task_before_any_send() {
        let (_temp, w, core) = new_fixture();
        core.agents(vec![session(&w.history, OWNER, "t1", 1, "idle")]);
        let mut db = w.history.db().unwrap();
        let job = new_job(&mut db, "offer-rollback", &jobs_fixture::success());
        db.execute_batch(
            "CREATE TRIGGER fault BEFORE INSERT ON job_delivery_offers
             BEGIN SELECT RAISE(ABORT, 'fixture failed to link the offer'); END;",
        ).unwrap();
        drop(db);

        drain(&w).await;
        assert!(core.writes().is_empty());
        assert_eq!(state(&w.history, &job), ("pending".into(), None));
        let db = w.history.db().unwrap();
        let evidence: (i64, Option<i64>) = db.query_row(
            "SELECT (SELECT COUNT(*) FROM journal WHERE kind='task' AND state='pending'), task
             FROM bot_outbox", [], |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap();
        assert_eq!(evidence, (0, None));
        db.execute_batch("DROP TRIGGER fault;").unwrap();
        drop(db);
        drain(&w).await;
        assert_eq!(core.writes().len(), 1);
        assert_eq!(state(&w.history, &job).0, "offered");
    }

    #[tokio::test]
    async fn gapplan_03_int_killed_during_transport_reconciles_and_ack_retry_resumes() {
        if let Some(directory) = std::env::var_os(CRASH_JOURNAL) {
            let directory = std::path::PathBuf::from(directory);
            let root = directory.parent().unwrap();
            let w = workspace(root, reopen_journal(&directory));
            if let Ok(id) = std::env::var(CRASH_ACK) {
                let agents = w.core.agents().await.unwrap();
                let key = agents[0].launch_key().unwrap();
                bots::answer(&w, Ok("core".into()), key, Ask::CompletionAck { id }).await.unwrap();
                // Simulate a process that lost its response after the ACK committed.
                std::future::pending::<()>().await;
            } else {
                drain(&w).await;
            }
            panic!("fixture should be killed before replying");
        }

        let (temp, w, core) = new_fixture();
        let agent = session(&w.history, OWNER, "t1", 10, "idle");
        core.agents(vec![agent.clone()]);
        let job = new_job(&mut *w.history.db().unwrap(), "crash-delivery", &jobs_fixture::success());
        let journal = temp.path().join("journal");
        drop(w);
        let hold = Arc::new(Notify::new());
        core.state.lock().unwrap().hold_reply = Some(hold.clone());
        let mut child = crash_child(&journal).spawn().unwrap();
        let received = timeout(WAIT, core.wrote.notified()).await;
        kill_fixture(&mut child);
        received.expect("fixture reached Core before the crash");
        hold.notify_one();

        let w = workspace(temp.path(), reopen_journal(&journal));
        desk::recover_outbox(&w.history);
        let evidence: (String, String) = w.history.db().unwrap().query_row(
            "SELECT o.state,j.state FROM bot_outbox o JOIN journal j ON j.id=o.task", [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap();
        assert_eq!(evidence, ("typing".into(), "unconfirmed".into()));
        core.agents(vec![agent.clone()]);
        drain(&w).await;
        let (status, blocker) = state(&w.history, &job);
        assert_eq!(status, "uncertain");
        assert!(blocker.unwrap().contains("recover by ID"));
        ready(&w.history);
        drain(&w).await;
        assert_eq!(core.writes().len(), 1);

        let id = event_id(&job);
        let recovered = command(&w, &agent, Ask::CompletionInbox { id: Some(id.clone()) }).await.unwrap();
        assert_eq!(serde_json::from_str::<Value>(&recovered).unwrap()["id"], id);
        drop(w);

        let mut child = crash_child(&journal).env(CRASH_ACK, &id).spawn().unwrap();
        let db = history::connection(&journal.join("workspace.sqlite3")).unwrap();
        let committed = timeout(WAIT, async {
            loop {
                let token: Option<String> = db.query_row(
                    "SELECT next_step_token FROM job_deliveries WHERE job_id=?1", [&job],
                    |r| r.get(0),
                ).unwrap();
                if let Some(token) = token {
                    break token;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await;
        kill_fixture(&mut child);
        let token = committed.expect("fixture committed ACK before the crash");
        drop(db);

        // The durable ACK was committed before the owner could submit the managed next step.
        let w = workspace(temp.path(), reopen_journal(&journal));
        let replacement = session(&w.history, OWNER, "t2", 11, "idle");
        core.agents(vec![replacement.clone()]);
        let resumed = command(&w, &replacement, Ask::CompletionAck { id }).await.unwrap();
        assert_eq!(resumed, token);
        let mut db = w.history.db().unwrap();
        let next = jobs_fixture::submit_fixture(&mut db, &resumed);
        let retry = jobs_fixture::submit_fixture(&mut db, &token);
        assert_eq!(retry.id, next.id);
        let counts: (i64, i64) = db.query_row(
            "SELECT (SELECT count(*) FROM job_deliveries WHERE job_id=?1 AND next_step_token=?2),
                    (SELECT count(*) FROM jobs WHERE owner_bot_id=?3 AND submit_key=?2)",
            rusqlite::params![job, token, OWNER], |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap();
        assert_eq!(counts, (1, 1));
        drop(db);
        drain(&w).await;
        assert_eq!(core.writes().len(), 1);
    }

    #[tokio::test]
    async fn gapplan_03_int_removed_owner_keeps_completion_and_existing_webhook_skips_busy() {
        let (temp, w, core) = new_fixture();
        let agent = session(&w.history, OWNER, "t1", 1, "working");
        core.agents(vec![agent]);
        let job = new_job(&mut *w.history.db().unwrap(), "removed-owner", &jobs_fixture::success());
        drain(&w).await;
        let routine = w.history.db().unwrap().query_row(
            "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state)
             VALUES ('core','t1',1,'Owner','Fixture webhook','Process event','{\"kind\":\"webhook\"}','active')
             RETURNING id", [], |r| r.get::<_, i64>(0),
        ).unwrap();
        let (sentinel, _) = w.history.rotate_webhook(routine, "fixture-master").unwrap().unwrap();
        let api = TestApi::start(temp.path(), &w);
        let run = api.webhook(routine, &sentinel, "busy-webhook", &json!({"event":"fixture"})).await;
        timeout(WAIT, async {
            loop {
                let (state, task): (String, Option<i64>) = w.history.db().unwrap().query_row(
                    "SELECT state,task_id FROM routine_runs WHERE id=?1", [run], |r| Ok((r.get(0)?, r.get(1)?)),
                ).unwrap();
                if state != "pending" {
                    assert_eq!(state, "skipped");
                    assert!(task.is_none());
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.unwrap();

        let removed = api.client.post(format!("{ORIGIN}/api/bots/{OWNER}/remove"))
            .bearer_auth(AUTH).header("origin", ORIGIN).send().await.unwrap();
        assert_eq!(removed.status(), StatusCode::OK);
        ready(&w.history);
        drain(&w).await;
        let attention = api.status("/api/attention").await;
        assert_eq!(attention["completions"][0]["id"], event_id(&job));
        assert_eq!(attention["completions"][0]["owner_bot_id"], OWNER);
        assert_eq!(attention["completions"][0]["blocker"], "Owner was removed.");
        let outbox: (String, String) = w.history.db().unwrap().query_row(
            "SELECT o.cause,o.state FROM bot_outbox o JOIN job_deliveries d ON d.outbox=o.id WHERE d.job_id=?1",
            [&job], |r| Ok((r.get(0)?, r.get(1)?)),
        ).unwrap();
        assert_eq!(outbox, ("outcome".into(), "pending".into()));
        assert!(core.writes().is_empty());
    }

    #[tokio::test]
    async fn gapplan_03_int_core_unavailable_and_unmapped_owner_stay_recoverable() {
        let (temp, w, core) = new_fixture();
        let job = new_job(&mut *w.history.db().unwrap(), "core-unavailable", &jobs_fixture::success());
        let mut offline = w.clone();
        offline.core = Core(temp.path().join("offline.sock"));
        drain(&offline).await;
        assert_eq!(state(&w.history, &job).1.as_deref(), Some("Herdr Core is unavailable."));
        ready(&w.history);
        core.state.lock().unwrap().unsupported = true;
        drain(&w).await;
        assert_eq!(state(&w.history, &job).1.as_deref(), Some("Herdr Core has no guarded completion delivery."));
        ready(&w.history);
        core.state.lock().unwrap().unsupported = false;
        let name = bots::one(&w.history.db().unwrap(), OWNER).unwrap().unwrap().agent_name;
        core.agents(vec![terminal(&name, "unregistered", "t1", 1, "idle")]);
        drain(&w).await;
        assert_eq!(state(&w.history, &job).1.as_deref(), Some("Owner has no eligible session mapping."));
        assert!(core.writes().is_empty());
        assert_eq!(core.state.lock().unwrap().launches, 0);
    }

    #[test]
    fn gapplan_03_int_journal_v54_fresh_upgrade_and_reopen() {
        fn assert_delivery_schema(db: &Connection) {
            assert_eq!(schema(db), history::migrations().len());
            for table in ["job_deliveries", "job_delivery_offers"] {
                let count: i64 = db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap();
                assert_eq!(count, 0);
            }
        }

        let temp = tempfile::tempdir().unwrap();
        let fresh = History::open_at(&temp.path().join("fresh")).unwrap();
        assert_delivery_schema(&fresh.db().unwrap());

        let dir = temp.path().join("upgrade");
        fs::DirBuilder::new().mode(0o700).create(&dir).unwrap();
        let seed = dir.join("workspace.sqlite3");
        OpenOptions::new().create_new(true).write(true).mode(0o600).open(&seed).unwrap();
        let mut old = Connection::open(&seed).unwrap();
        for migration in &history::migrations()[..53] {
            old.execute_batch(migration).unwrap();
        }
        old.execute(
            "INSERT INTO bots(id,name,agent_name,created_ms,updated_ms) VALUES (?1,'Owner','fixture-owner',1,1)",
            [OWNER],
        ).unwrap();
        let job = new_job(&mut old, "v53-existing", &jobs_fixture::success());
        assert_eq!(schema(&old), 53);
        drop(old);
        for _ in 0..3 {
            let reopened = reopen_journal(&dir);
            let db = reopened.db().unwrap();
            assert_delivery_schema(&db);
            let event = jobs::status(&db, &job).unwrap().unwrap().completion.unwrap();
            assert_eq!(event.owner_bot_id, OWNER);
            assert_eq!(event.exit.result.unwrap().reference, "fixture-result");
        }
    }
}

mod fleet_authority {
    use super::*;
    use crate::{
        bots,
        fleet_policy::{
            Error, Evidence, Inspection, PolicyRef,
            principals::{Actor, ParkPin, Principal, Purpose, Signed, Target},
            tests::{Fixture, JARVIS, WORKSPACE, envelope, grant, policy},
        },
    };
    use reqwest::StatusCode;
    use rusqlite::params;

    fn sign(
        fixture: &Fixture,
        park: &ParkRef,
        reference: &PolicyRef,
        principal: Principal,
        purpose: Purpose,
        nonce: &str,
    ) -> Signed {
        fixture.sign_decision(envelope(
            WORKSPACE,
            principal,
            purpose,
            Target::Park {
                park: ParkPin {
                    id: park.id.clone(),
                    revision: manifest().revision,
                    manifest_digest: park.manifest_digest.clone(),
                },
                policy: reference.clone(),
            },
            nonce,
        ))
    }

    pub(super) fn registered_launch(history: &History, id: &str, name: &str) -> (i64, String) {
        let (bot, _) = bots::register(
            &history.db().unwrap(),
            &bots::Registration {
                id: id.into(),
                name: Some(name.into()),
                main: Some(true),
                ..Default::default()
            },
            history::now(),
        ).unwrap().unwrap();
        let (launch, key) = history.start_launch("fixture-core", &bot.agent_name, "fixture", None, "{}", "")
            .unwrap().unwrap();
        bots::noted(history, id, &key).unwrap();
        (launch, key)
    }

    #[test]
    fn gapplan_04_int_import_restart_and_revoke_use_protected_generation() {
        let scratch = tempfile::tempdir().unwrap();
        let (h, park) = setup(scratch.path());
        let fixture = Fixture::new(scratch.path(), WORKSPACE, true);
        let first = fixture.publish(fixture.publication(policy(1, vec![grant()]), WORKSPACE)).unwrap();
        let (_, launch) = registered_launch(&h, JARVIS, "Jarvis");
        let principal = Principal::Bot { id: JARVIS.into(), launch: launch.clone() };
        let signed = sign(&fixture, &park, &first, principal.clone(), Purpose::Execute, "delegate-1");
        let evidence = || Evidence::Bot { launch: &launch, signed: &signed };

        let mut revoked = policy(2, vec![grant()]);
        revoked.revoked.insert("fixture-grant".into());
        {
            let mut db = h.db().unwrap();
            fixture.authority.audit(&mut db).unwrap();
            fixture.authority.at_effect(&mut db, &park, Purpose::Execute, evidence(), |_, verified| {
                assert_eq!(verified.actor, Actor::Bot { id: JARVIS.into() });
                assert_eq!(verified.policy, first);
                assert_eq!(verified.rule_id.as_deref(), Some("fixture-grant"));
                assert_eq!(verified.decision_ref.as_deref(), Some("fixture-decision-ref"));
                assert_eq!(verified.nonce, "delegate-1");
                assert_eq!(fixture.publish(fixture.publication(revoked.clone(), WORKSPACE)), Err(Error::Busy));
            }).unwrap();
        }

        let second = fixture.publish(fixture.publication(revoked, WORKSPACE)).unwrap();
        assert_eq!(fixture.publish(fixture.publication(policy(1, vec![]), WORKSPACE)), Err(Error::StalePolicy));
        assert_eq!(fixture.publish(fixture.publication(policy(3, vec![grant()]), WORKSPACE)), Err(Error::Invalid));
        drop(h);

        // The bridge was offline when the operator revoked the grant. The copy it
        // reopens still has the old generation and has acquired a bogus higher row.
        let h = reopen_journal(&scratch.path().join("journal"));
        let trusted = fixture.restart(WORKSPACE);
        let mut db = h.db().unwrap();
        db.execute(
            "INSERT INTO fleet_policy_versions SELECT workspace,99,?1,published_ms,signed_policy
             FROM fleet_policy_versions WHERE generation=1",
            ["0".repeat(64)],
        ).unwrap();
        assert!(matches!(trusted.inspect(), Inspection::Current { reference, .. } if reference == second));
        assert_eq!(trusted.at_effect(&mut db, &park, Purpose::Execute, evidence(), |_, _| {
            panic!("revoked evidence reached the effect")
        }), Err(Error::StalePolicy));
        let renewed = sign(&fixture, &park, &second, principal, Purpose::Execute, "delegate-2");
        assert_eq!(trusted.at_effect(&mut db, &park, Purpose::Execute,
            Evidence::Bot { launch: &launch, signed: &renewed }, |_, _| {
                panic!("revoked rule granted execution")
            }), Err(Error::NoGrant));
        trusted.audit(&mut db).unwrap();
        trusted.audit(&mut db).unwrap();
        let digest: String = db.query_row(
            "SELECT digest FROM fleet_policy_versions WHERE generation=2", [], |row| row.get(0),
        ).unwrap();
        assert_eq!(digest, second.digest);
        assert!(db.execute("DELETE FROM fleet_policy_versions WHERE generation=1", []).is_err());
        assert!(db.execute("UPDATE fleet_policy_versions SET published_ms=0", []).is_err());
        assert!(db.execute("INSERT OR REPLACE INTO fleet_policy_versions SELECT * FROM fleet_policy_versions", []).is_err());
        assert!(matches!(parks::status(&db, &park).unwrap(), View::Status(State::Pending)));
    }

    #[test]
    fn gapplan_04_int_operator_decision_cannot_replay_on_another_park_workspace_or_purpose() {
        let scratch = tempfile::tempdir().unwrap();
        let (h, park) = setup(scratch.path());
        let fixture = Fixture::new(scratch.path(), WORKSPACE, false);
        let current = fixture.publish(fixture.publication(policy(1, vec![]), WORKSPACE)).unwrap();
        let signed = sign(&fixture, &park, &current, Principal::Operator, Purpose::Execute, "human-1");
        let mut wrong_workspace = signed.envelope.clone();
        wrong_workspace.workspace = "other-workspace".into();
        let wrong_workspace = fixture.sign_decision(wrong_workspace);
        assert_eq!(fixture.import_decision(wrong_workspace), Err(Error::Binding));
        let nonce = fixture.import_decision(signed.clone()).unwrap();
        assert_eq!(fixture.import_decision(signed), Ok(nonce.clone()));

        let mut db = h.db().unwrap();
        let other = parks::file(&db, "other-park", &manifest()).unwrap();
        assert_eq!(other.manifest_digest, park.manifest_digest);
        assert_eq!(fixture.import_decision(sign(&fixture, &other, &current, Principal::Operator,
            Purpose::Execute, &nonce)), Err(Error::Binding));
        for (target, purpose) in [(&other, Purpose::Execute), (&park, Purpose::Release)] {
            assert_eq!(fixture.authority.at_effect(&mut db, target, purpose, Evidence::Operator(&nonce), |_, _| {
                panic!("replayed decision reached the effect")
            }), Err(Error::Binding));
        }
        let peer_workspace = "other-workspace";
        let peer = fixture.peer(scratch.path(), peer_workspace);
        fs::copy(
            scratch.path().join(WORKSPACE).join("decision-human-1.json"),
            scratch.path().join(peer_workspace).join("decision-human-1.json"),
        ).unwrap();
        assert!(matches!(peer.inspect(), Inspection::Current { reference, .. } if reference == current));
        assert_eq!(peer.at_effect(&mut db, &park, Purpose::Execute, Evidence::Operator(&nonce), |_, _| {
            panic!("cross-workspace replay reached the effect even with the same operator key")
        }), Err(Error::Binding));
        let project = scratch.path().join("project");
        let adapter = MarkerFile { project: &project, after_apply: || () };
        assert_eq!(adapter.observe().unwrap(), marker("old"));
        assert!(!project.join("applies").exists());
        let result = fixture.authority.at_effect(&mut db, &park, Purpose::Execute, Evidence::Operator(&nonce),
            |db, verified| {
                assert_eq!(verified.actor, Actor::Operator);
                parks::execute(db, &park, parks::Decision {
                    actor: "operator", source: Source::Human, basis: &verified.nonce,
                }, &adapter).unwrap()
            },
        ).unwrap();
        assert_eq!(receipt(result, State::Verified).outcome, Outcome::Verified);
        assert_eq!(adapter.apply_count(), 1);
    }

    #[test]
    fn gapplan_04_int_jarvis_name_main_flag_and_helper_cannot_supply_delegation() {
        let scratch = tempfile::tempdir().unwrap();
        let (h, park) = setup(scratch.path());
        let fixture = Fixture::new(scratch.path(), WORKSPACE, true);
        let current = fixture.publish(fixture.publication(policy(1, vec![grant()]), WORKSPACE)).unwrap();
        let (helper_row, helper) = registered_launch(&h, JARVIS, "Jarvis");
        let (_, launch) = registered_launch(&h, JARVIS, "Jarvis");
        let (_, impostor) = registered_launch(&h, "other-bot", "Jarvis");
        let mut db = h.db().unwrap();
        db.execute(
            "INSERT INTO helpers(launch,parent_key,name,difficulty,template,model)
             VALUES (?1,?2,'helper','easy','fixture','fixture')",
            params![helper_row, launch],
        ).unwrap();
        assert!(bots::one(&db, "other-bot").unwrap().unwrap().main);
        let signed = |id: &str, launch: &str| sign(&fixture, &park, &current, Principal::Bot {
            id: id.into(), launch: launch.into(),
        }, Purpose::Execute, "delegated-park");
        let valid = signed(JARVIS, &launch);
        for (key, document, error) in [
            (&helper, signed(JARVIS, &helper), Error::Principal),
            (&impostor, signed("other-bot", &impostor), Error::Principal),
            (&impostor, valid.clone(), Error::Principal),
            (&launch, Signed { signature: "forged".into(), ..valid.clone() }, Error::Signature),
        ] {
            assert_eq!(fixture.authority.at_effect(&mut db, &park, Purpose::Execute, Evidence::Bot {
                launch: key, signed: &document,
            }, |_, _| panic!("unverified bot reached the effect")), Err(error));
        }
        // Even when recorded under the delegated bot's exact current launch key,
        // the helper row must be excluded.
        drop(db);
        bots::noted(&h, JARVIS, &helper).unwrap();
        let mut db = h.db().unwrap();
        assert_eq!(fixture.authority.at_effect(&mut db, &park, Purpose::Execute, Evidence::Bot {
            launch: &helper, signed: &signed(JARVIS, &helper),
        }, |_, _| panic!("helper inherited the parent's scope")), Err(Error::Principal));
        assert_eq!(fixture.authority.at_effect(&mut db, &park, Purpose::Execute, Evidence::Bot {
            launch: &launch, signed: &valid,
        }, |_, _| panic!("obsolete launch reached the effect")), Err(Error::Principal));
    }

    #[tokio::test]
    async fn gapplan_04_int_shared_bearer_can_inspect_but_cannot_claim_human_consent() {
        use super::job_delivery::{AUTH, ORIGIN, TestApi, workspace};
        let scratch = tempfile::tempdir().unwrap();
        let (h, park) = setup(scratch.path());
        let fixture = Fixture::new(scratch.path(), WORKSPACE, false);
        let current = fixture.publish(fixture.publication(policy(1, vec![]), WORKSPACE)).unwrap();
        let mut w = workspace(scratch.path(), h);
        w.fleet_policy = Ok(Some(fixture.authority.clone()));
        let api = TestApi::start(scratch.path(), &w);
        const PATH: &str = "/api/bots/fleet-policy";
        let read = api.client.get(format!("{ORIGIN}{PATH}")).send().await.unwrap();
        assert_eq!(read.status(), StatusCode::UNAUTHORIZED);
        let view = api.status(PATH).await;
        assert_eq!(view["status"], "current");
        assert_eq!(view["reference"]["digest"], current.digest);
        assert!(view.get("operator_key").is_none());
        let write = api.client.post(format!("{ORIGIN}{PATH}"))
            .bearer_auth(AUTH).header("Origin", ORIGIN)
            .body(r#"{"principal":"operator","purpose":"execute"}"#).send().await.unwrap();
        assert_eq!(write.status(), StatusCode::METHOD_NOT_ALLOWED);
        let mut db = w.history.db().unwrap();
        assert_eq!(fixture.authority.at_effect(&mut db, &park, Purpose::Execute, Evidence::Unverified, |_, _| {
            panic!("shared bearer reached the effect")
        }), Err(Error::Principal));
        assert!(matches!(parks::status(&db, &park).unwrap(), View::Status(State::Pending)));
    }

    #[test]
    fn gapplan_04_int_missing_signer_and_writable_trust_hold_the_effect() {
        use std::os::unix::fs::PermissionsExt;
        let scratch = tempfile::tempdir().unwrap();
        let (h, park) = setup(scratch.path());
        let fixture = Fixture::new(scratch.path(), WORKSPACE, false);
        let current = fixture.publish(fixture.publication(policy(1, vec![grant()]), WORKSPACE)).unwrap();
        let (_, launch) = registered_launch(&h, JARVIS, "Jarvis");
        let signed = sign(&fixture, &park, &current, Principal::Bot { id: JARVIS.into(), launch: launch.clone() },
            Purpose::Execute, "no-enrollment");
        let mut db = h.db().unwrap();
        assert_eq!(fixture.authority.at_effect(&mut db, &park, Purpose::Execute, Evidence::Bot {
            launch: &launch, signed: &signed,
        }, |_, _| panic!("unenrolled delegate reached the effect")), Err(Error::Principal));
        let trust = scratch.path().join(WORKSPACE).join("trust.json");
        fs::set_permissions(trust, fs::Permissions::from_mode(0o666)).unwrap();
        assert!(matches!(fixture.authority.inspect(), Inspection::Held { reason: Error::Unavailable }));
    }

    #[test]
    fn gapplan_04_int_journal_v55_fresh_upgrade_and_reopen() {
        fn assert_v55(db: &Connection) {
            assert_eq!(schema(db), history::migrations().len());
            let versions: i64 = db.query_row("SELECT count(*) FROM fleet_policy_versions", [], |r| r.get(0)).unwrap();
            assert_eq!(versions, 0);
        }
        let scratch = tempfile::tempdir().unwrap();
        let fresh = History::open_at(&scratch.path().join("fresh")).unwrap();
        assert_v55(&fresh.db().unwrap());

        let data = scratch.path().join("upgrade");
        fs::DirBuilder::new().mode(0o700).create(&data).unwrap();
        let file = data.join("workspace.sqlite3");
        OpenOptions::new().create_new(true).write(true).mode(0o600).open(&file).unwrap();
        let mut old = history::connection(&file).unwrap();
        for migration in &history::migrations()[..54] {
            old.execute_batch(migration).unwrap();
        }
        assert_eq!(schema(&old), 54);
        let park = parks::file(&old, "seed-park", &manifest()).unwrap();
        bots::register(&old, &bots::Registration {
            id: jobs_fixture::OWNER.into(),
            name: Some("Fixture owner".into()),
            ..Default::default()
        }, 1).unwrap().unwrap();
        let job = jobs_fixture::submit_fixture(&mut old, "seed-v54");
        assert_eq!(jobs_fixture::dispatch(&mut old, &job), jobs::Dispatch::Recorded);
        let event = jobs::finish(&mut old, &job.id, jobs_fixture::ATTEMPT, &jobs_fixture::success()).unwrap();
        let outbox: i64 = old.query_row(
            "INSERT INTO bot_outbox(bot,text,cause,created_ms,give_up_ms)
             VALUES (?1,'Fixture completion','outcome',1,2) RETURNING id",
            [jobs_fixture::OWNER],
            |row| row.get(0),
        ).unwrap();
        old.execute(
            "INSERT INTO job_deliveries(job_id,attempt,outbox,state,blocker)
             VALUES (?1,?2,?3,'uncertain','fixture blocker')",
            params![job.id, jobs_fixture::ATTEMPT, outbox],
        ).unwrap();
        drop(old);

        // Exercise the same bounded lock-contention retry used by the crash fixtures.
        let lock = OpenOptions::new().create_new(true).write(true).mode(0o600)
            .open(data.join("workspace.lock")).unwrap();
        lock.lock().unwrap();
        assert!(History::open_at(&data).is_err());
        let release = thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            drop(lock);
        });
        for _ in 0..3 {
            let reopened = reopen_journal(&data);
            let db = reopened.db().unwrap();
            assert_v55(&db);
            assert!(matches!(parks::status(&db, &park).unwrap(), View::Status(State::Pending)));
            let existing = jobs::status(&db, &job.id).unwrap().unwrap().completion.unwrap();
            assert_eq!(existing.owner_bot_id, event.owner_bot_id);
            assert_eq!(existing.exit.result.unwrap().reference, "fixture-result");
            let delivery: (i64, String) = db.query_row(
                "SELECT outbox,blocker FROM job_deliveries WHERE job_id=?1 AND state='uncertain'",
                [&job.id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            ).unwrap();
            assert_eq!(delivery, (outbox, "fixture blocker".into()));
        }
        release.join().unwrap();
    }
}

mod park_decisions;

mod worker_hosts;

mod detached_attempts;

mod managed_jobs;

#[test]
fn gapplan_11_int_v57_fresh_and_seeded_v56_reopen_preserve_rows() {
    let scratch = tempfile::tempdir().unwrap();
    let directory = scratch.path().join("upgrade");
    fs::DirBuilder::new().mode(0o700).create(&directory).unwrap();
    let db_file = directory.join("workspace.sqlite3");
    OpenOptions::new().create_new(true).write(true).mode(0o600).open(&db_file).unwrap();
    let mut old = history::connection(&db_file).unwrap();
    for migration in &history::migrations()[..56] {
        old.execute_batch(migration).unwrap();
    }
    assert_eq!(schema(&old), 56);
    crate::bots::register(&old, &crate::bots::Registration {
        id: jobs_fixture::OWNER.into(), name: Some("Fixture owner".into()), ..Default::default()
    }, 1).unwrap().unwrap();
    let job = jobs_fixture::submit_fixture(&mut old, "existing-v56-job");
    let park = parks::file(&old, "existing-v56-park", &manifest()).unwrap();
    parks::decide(&mut old, &park, decision(Source::Human), parks::Change::Hold).unwrap();
    drop(old);
    for (path, seeded) in [(scratch.path().join("fresh"), false), (directory, true)] {
        for _ in 0..3 {
            let history = reopen_journal(&path);
            let db = history.db().unwrap();
            assert_eq!(schema(&db), history::migrations().len());
            for table in ["job_review_lineages", "job_review_rounds", "job_review_evidence"] {
                assert_eq!(db.query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get::<_, i64>(0)).unwrap(), 0);
            }
            if seeded {
                assert_eq!(jobs::status(&db, &job.id).unwrap().unwrap().status, "queued");
                assert_eq!(parks::status(&db, &park).unwrap(), View::Status(State::Held));
                assert!(db.execute("DELETE FROM parks WHERE id=?1", [&park.id]).is_err());
                assert!(db.execute("DELETE FROM park_decisions WHERE park_id=?1", [&park.id]).is_err());
                assert!(db.execute(
                    "INSERT OR REPLACE INTO park_decisions SELECT * FROM park_decisions WHERE park_id=?1",
                    [&park.id],
                ).is_err());
            }
        }
    }
}

#[test]
fn gapplan_11_int_killed_during_rollback_preserves_intent_without_replay() {
    const ROLLBACK_FIXTURE: &str = "SWARMHUB_GAPPLAN_11_ROLLBACK_FIXTURE_ROOT";
    if let Some(root) = std::env::var_os(ROLLBACK_FIXTURE) {
        let root = Path::new(&root);
        let history = reopen_journal(&root.join("journal"));
        let mut db = history::connection(history.file()).unwrap();
        let park = ParkRef {
            id: "park".into(),
            manifest_digest: db.query_row("SELECT manifest_digest FROM parks WHERE id='park'", [], |row| row.get(0)).unwrap(),
        };
        struct CrashRollback<'a> {
            marker: MarkerFile<'a, fn()>,
            applied: std::cell::Cell<bool>,
        }
        impl Adapter for CrashRollback<'_> {
            fn observe(&self) -> io::Result<Marker> {
                if self.applied.get() {
                    return Err(io::Error::other("fixture lost readback"));
                }
                self.marker.observe()
            }

            fn apply(&self, expected: &Marker, replacement: &Marker) -> Step {
                let step = self.marker.apply(expected, replacement);
                self.applied.set(true);
                step
            }

            fn rollback(&self, expected: &Marker, replacement: &Marker) -> Step {
                assert_eq!(self.marker.rollback(expected, replacement), Step::Exit(0));
                fs::write(self.marker.project.join("rolling-back"), []).unwrap();
                let _ = io::stdin().read_exact(&mut [0]);
                panic!("the executor should have been killed");
            }
        }
        let adapter = CrashRollback {
            marker: MarkerFile { project: &root.join("project"), after_apply: || {} },
            applied: std::cell::Cell::new(false),
        };
        parks::execute(&mut db, &park, decision(Source::Human), &adapter).unwrap();
        panic!("the executor returned before it was killed");
    }

    let scratch = tempfile::tempdir().unwrap();
    let (history, park) = setup(scratch.path());
    drop(history);
    let project = scratch.path().join("project");
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "fleet_tests::gapplan_11_int_killed_during_rollback_preserves_intent_without_replay"])
        .env(ROLLBACK_FIXTURE, scratch.path())
        .stdin(Stdio::piped()).stdout(Stdio::null()).spawn().unwrap();
    let deadline = Instant::now() + WAIT;
    while !project.join("rolling-back").exists()
        && Instant::now() < deadline && child.try_wait().unwrap().is_none()
    {
        thread::sleep(Duration::from_millis(10));
    }
    let killed = child.kill();
    let exit = child.wait().unwrap();
    killed.unwrap();
    assert_eq!(exit.signal(), Some(libc::SIGKILL));
    assert!(project.join("rolling-back").exists());
    let history = reopen_journal(&scratch.path().join("journal"));
    let mut db = history.db().unwrap();
    let (apply, intent, receipt): (String, String, Option<String>) = db.query_row(
        "SELECT apply_step,rollback_intent,receipt FROM park_executions WHERE park_id=?1",
        [&park.id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    ).unwrap();
    assert_eq!(apply, r#"{"Exit":0}"#);
    assert_eq!(intent, r#"{"after_apply":null}"#);
    assert_eq!(receipt, None);
    let adapter = MarkerFile { project: &project, after_apply: || {} };
    assert_eq!(adapter.observe().unwrap(), marker("old"));
    assert_eq!(parks::execute(&mut db, &park, decision(Source::Backstop), &adapter).unwrap(),
        View::Status(State::Reconciliation));
    assert_eq!(adapter.apply_count(), 1);
}

mod outbound_drafts;
#[path = "fleet_tests/outbound_delivery.rs"]
mod outbound_delivery;

mod team_registration;
mod bot_final_status;
