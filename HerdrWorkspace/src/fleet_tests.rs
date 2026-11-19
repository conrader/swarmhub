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
    let history = History::open_at(&root.join("journal")).unwrap();
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
        let history = History::open_at(&root.join("journal")).unwrap();
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
        let reopened = History::open_at(&journal_dir).unwrap();
        let mut db = history::connection(reopened.file()).unwrap();
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
        let reopened = History::open_at(&data).unwrap();
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
        let h = History::open_at(&root.join("journal")).unwrap();
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

    let reopened = History::open_at(&directory).unwrap();
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

    let reopened = History::open_at(&directory).unwrap();
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

    let reopened = History::open_at(&directory).unwrap();
    let db = reopened.db().unwrap();
    assert_eq!(jobs::status(&db, &exit.id).unwrap().unwrap().completion, Some(event));
    assert_eq!(job_writes(&db, &exit.id), (1, 1));
    assert_eq!(jobs::status(&db, &start.id).unwrap().unwrap().status, "unknown");
    assert_eq!(job_writes(&db, &start.id), (0, 0));
}

#[test]
fn gapplan_02_int_journal_v53_fresh_upgrade_and_reopen() {
    fn assert_v53(db: &Connection) {
        assert_eq!(schema(db), 53);
        for table in ["jobs", "job_attempts", "job_completions"] {
            let count: i64 = db
                .query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0))
                .unwrap();
            assert_eq!(count, 0);
        }
    }

    let scratch = tempfile::tempdir().unwrap();
    let fresh = History::open_at(&scratch.path().join("fresh")).unwrap();
    assert_v53(&fresh.db().unwrap());

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
        let reopened = History::open_at(&directory).unwrap();
        let db = reopened.db().unwrap();
        assert_v53(&db);
        assert_eq!(parks::status(&db, &park).unwrap(), View::Status(State::Pending));
        let name: String = db.query_row(
            "SELECT name FROM bots WHERE id='preexisting-bot'", [], |r| r.get(0),
        ).unwrap();
        assert_eq!(name, "Fixture Bot");
    }
}
