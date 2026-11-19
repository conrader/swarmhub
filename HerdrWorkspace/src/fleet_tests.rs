use crate::{
    history::{self, History},
    parks::{
        self, Adapter, Marker, Outcome, ParkRef, Reason, Source, State, Step, View,
        tests::{decision, manifest, marker, receipt},
    },
};
use rusqlite::Connection;
use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
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
    let schema = |db: &Connection| {
        db.pragma_query_value(None, "user_version", |r| r.get::<_, i32>(0))
            .unwrap()
    };
    assert_eq!(schema(&*fresh.db().unwrap()), 52);

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
        assert_eq!(schema(&db), 52);
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
