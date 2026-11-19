use super::*;
use crate::history::History;
use std::cell::{Cell, RefCell};

pub(crate) fn manifest() -> Manifest {
    Manifest {
        revision: "park-v1".into(),
        owner: "fixture-bot".into(),
        project: "fixture-project".into(),
        host: "fixture-host".into(),
        operation: Operation::SetRevisionMarker {
            revision: "new".into(),
        },
        artifact_pin: "fixture-artifact".into(),
        apply_pin: "fixture-apply".into(),
        reverse_pin: "fixture-reverse".into(),
        precondition: "old".into(),
        expected_postcondition: "new".into(),
        review_ref: "fixture-review".into(),
        dry_run_ref: "fixture-dry-run".into(),
        rollback_plan: "Restore the previous marker if this attempt still owns it".into(),
    }
}

pub(crate) fn decision(source: Source) -> Decision<'static> {
    Decision {
        actor: match source {
            Source::Human => "fixture-human",
            Source::Judge => "fixture-judge",
            Source::Backstop => "fixture-backstop",
        },
        source,
        basis: "fixture-only decision",
    }
}

pub(crate) fn marker(revision: &str) -> Marker {
    Marker {
        revision: revision.into(),
        attempt: None,
    }
}

pub(crate) fn receipt(view: View, expected: State) -> Receipt {
    let View::Receipt(state, receipt) = view else {
        panic!("expected a receipt, got {view:?}");
    };
    assert_eq!(state, expected);
    receipt
}

struct Fixture {
    marker: RefCell<Marker>,
    reads: Cell<usize>,
    applies: Cell<usize>,
    apply_step: Step,
    write: bool,
    unreadable_after_apply: bool,
    rollback_step: Step,
}

impl Default for Fixture {
    fn default() -> Self {
        Self {
            marker: RefCell::new(marker("old")),
            reads: Cell::new(0),
            applies: Cell::new(0),
            apply_step: Step::Exit(0),
            write: true,
            unreadable_after_apply: false,
            rollback_step: Step::Exit(0),
        }
    }
}

impl Adapter for Fixture {
    fn observe(&self) -> io::Result<Marker> {
        self.reads.set(self.reads.get() + 1);
        if self.unreadable_after_apply && self.reads.get() == 2 {
            return Err(io::Error::other("fixture read failed"));
        }
        Ok(self.marker.borrow().clone())
    }

    fn apply(&self, expected: &Marker, replacement: &Marker) -> Step {
        assert_eq!(&*self.marker.borrow(), expected);
        self.applies.set(self.applies.get() + 1);
        if self.write {
            self.marker.replace(replacement.clone());
        }
        self.apply_step
    }

    fn rollback(&self, expected: &Marker, replacement: &Marker) -> Step {
        assert_eq!(&*self.marker.borrow(), expected);
        if self.rollback_step == Step::Exit(0) {
            self.marker.replace(replacement.clone());
        }
        self.rollback_step
    }
}

fn journal() -> (tempfile::TempDir, History, Connection) {
    let scratch = tempfile::tempdir().unwrap();
    let history = History::open_at(&scratch.path().join("journal")).unwrap();
    let db = history::connection(history.file()).unwrap();
    (scratch, history, db)
}

#[test]
fn gapplan_01_unit_decisions_and_immutable_revisions() {
    let (_scratch, _history, mut db) = journal();
    let original = manifest();
    let park = file(&db, "park", &original).unwrap();
    let adapter = Fixture::default();
    assert!(db.execute("UPDATE parks SET manifest='{}'", []).is_err());
    assert!(matches!(
        decide(&mut db, &park, decision(Source::Human), Change::Release),
        Err(Error::Conflict)
    ));
    decide(&mut db, &park, decision(Source::Judge), Change::Hold).unwrap();
    assert_eq!(
        execute(&mut db, &park, decision(Source::Human), &adapter).unwrap(),
        View::Status(State::Held)
    );
    assert!(matches!(
        decide(&mut db, &park, decision(Source::Backstop), Change::Release),
        Err(Error::InvalidDecision)
    ));
    decide(&mut db, &park, decision(Source::Human), Change::Release).unwrap();
    assert_eq!(status(&db, &park).unwrap(), View::Status(State::Pending));

    let replacement = Manifest {
        revision: "park-v2".into(),
        ..original
    };
    let replaced = decide(
        &mut db,
        &park,
        decision(Source::Human),
        Change::Supersede {
            id: "replacement",
            manifest: &replacement,
        },
    )
    .unwrap()
    .unwrap();
    assert_ne!(park.manifest_digest, replaced.manifest_digest);
    let parent: String = db
        .query_row("SELECT supersedes FROM parks WHERE id='replacement'", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(parent, park.id);
    for (key, state) in [(&park, State::Superseded), (&replaced, State::Denied)] {
        if state == State::Denied {
            decide(&mut db, key, decision(Source::Human), Change::Deny).unwrap();
        }
        assert_eq!(
            execute(&mut db, key, decision(Source::Backstop), &adapter).unwrap(),
            View::Status(state)
        );
        assert!(matches!(
            decide(&mut db, key, decision(Source::Human), Change::Release),
            Err(Error::Conflict)
        ));
    }
    let decisions: Vec<(String, String, String, String)> = db
        .prepare("SELECT action,actor,source,basis FROM park_decisions ORDER BY id")
        .unwrap()
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    assert_eq!(
        decisions,
        [
            ("hold", "fixture-judge", "judge"),
            ("release", "fixture-human", "human"),
            ("supersede", "fixture-human", "human"),
            ("deny", "fixture-human", "human")
        ]
        .map(|(action, actor, source)| (
            action.into(),
            actor.into(),
            source.into(),
            "fixture-only decision".into(),
        ))
    );
    assert_eq!(adapter.applies.get(), 0);
}

#[test]
fn gapplan_01_unit_drift_requires_a_new_park() {
    let (_scratch, _history, mut db) = journal();
    let manifest = manifest();
    let park = file(&db, "park", &manifest).unwrap();
    let adapter = Fixture {
        marker: RefCell::new(marker("drifted")),
        ..Fixture::default()
    };
    let observed = receipt(
        execute(&mut db, &park, decision(Source::Judge), &adapter).unwrap(),
        State::Failed,
    );
    assert_eq!(observed.reason, Some(Reason::PreconditionDrift));
    assert_eq!(observed.before, Some(marker("drifted")));
    assert_eq!(observed.apply, None);
    assert_eq!(adapter.applies.get(), 0);
    assert_eq!(
        execute(&mut db, &park, decision(Source::Human), &adapter).unwrap(),
        status(&db, &park).unwrap()
    );
    let replacement = Manifest {
        revision: "park-v2".into(),
        precondition: "drifted".into(),
        ..manifest
    };
    let successor = decide(
        &mut db,
        &park,
        decision(Source::Human),
        Change::Supersede {
            id: "replacement",
            manifest: &replacement,
        },
    )
    .unwrap()
    .unwrap();
    assert_eq!(status(&db, &successor).unwrap(), View::Status(State::Pending));
    assert_eq!(
        status(&db, &park).unwrap(),
        View::Receipt(State::Superseded, observed)
    );
}

#[test]
fn gapplan_01_unit_busy_and_stale_claims_cannot_run() {
    let (_scratch, history, mut db) = journal();
    let park = file(&db, "park", &manifest()).unwrap();
    let adapter = Fixture::default();
    let mut competing = history::connection(history.file()).unwrap();
    let lock = competing
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .unwrap();
    db.busy_timeout(std::time::Duration::ZERO).unwrap();
    assert_eq!(
        execute(&mut db, &park, decision(Source::Judge), &adapter).unwrap(),
        View::Busy
    );
    lock.rollback().unwrap();
    let stale = ParkRef {
        manifest_digest: "stale".into(),
        ..park.clone()
    };
    assert!(matches!(
        execute(&mut db, &stale, decision(Source::Judge), &adapter),
        Err(Error::Conflict)
    ));
    assert_eq!(adapter.applies.get(), 0);
    assert_eq!(status(&db, &park).unwrap(), View::Status(State::Pending));
}

#[test]
fn gapplan_01_unit_zero_exit_without_the_effect_is_failed() {
    let (_scratch, _history, mut db) = journal();
    let park = file(&db, "park", &manifest()).unwrap();
    let adapter = Fixture {
        write: false,
        ..Fixture::default()
    };
    let observed = receipt(
        execute(&mut db, &park, decision(Source::Judge), &adapter).unwrap(),
        State::Failed,
    );
    assert_eq!(observed.apply, Some(Step::Exit(0)));
    assert_eq!(observed.reason, Some(Reason::VerificationFailed));
    assert_eq!(observed.after_apply, Some(marker("old")));
    assert_eq!(observed.rollback, None);
}

#[test]
fn gapplan_01_unit_failed_verification_requires_independent_rollback_readback() {
    let (_scratch, _history, mut db) = journal();
    let park = file(&db, "park", &manifest()).unwrap();
    let adapter = Fixture {
        unreadable_after_apply: true,
        ..Fixture::default()
    };
    let observed = receipt(
        execute(&mut db, &park, decision(Source::Judge), &adapter).unwrap(),
        State::Failed,
    );
    assert_eq!(observed.reason, Some(Reason::VerificationFailed));
    assert_eq!(observed.after_apply, None);
    assert_eq!(
        observed.rollback,
        Some(Rollback {
            step: Some(Step::Exit(0)),
            after: Some(marker("old")),
        })
    );
}

#[test]
fn gapplan_01_unit_rollback_failure_leaves_the_effect_in_reconciliation() {
    let (_scratch, _history, mut db) = journal();
    let park = file(&db, "park", &manifest()).unwrap();
    let adapter = Fixture {
        apply_step: Step::Exit(1),
        rollback_step: Step::Exit(2),
        ..Fixture::default()
    };
    let observed = receipt(
        execute(&mut db, &park, decision(Source::Judge), &adapter).unwrap(),
        State::Reconciliation,
    );
    assert_eq!(observed.apply, Some(Step::Exit(1)));
    assert_eq!(observed.reason, Some(Reason::ApplyFailed));
    assert_eq!(
        observed.rollback,
        Some(Rollback {
            step: Some(Step::Exit(2)),
            after: observed.after_apply.clone(),
        })
    );
    assert_eq!(observed.after_apply.as_ref().unwrap().revision, "new");
    assert_eq!(
        reconcile_after_restart(&mut db, &park, &adapter).unwrap(),
        View::Receipt(State::Reconciliation, observed)
    );
    assert_eq!(adapter.applies.get(), 1);
}

#[test]
fn gapplan_01_unit_reservation_failure_rolls_back_claim_and_decision() {
    let (_scratch, _history, mut db) = journal();
    let park = file(&db, "park", &manifest()).unwrap();
    let adapter = Fixture::default();
    db.execute_batch(
        "CREATE TEMP TRIGGER fail_reservation BEFORE INSERT ON park_executions
         BEGIN SELECT RAISE(ABORT, 'fixture reservation error'); END;",
    )
    .unwrap();
    assert!(matches!(
        execute(&mut db, &park, decision(Source::Judge), &adapter),
        Err(Error::Store(_))
    ));
    assert_eq!(status(&db, &park).unwrap(), View::Status(State::Pending));
    assert_eq!(adapter.applies.get(), 0);
    let decisions: i64 = db
        .query_row("SELECT count(*) FROM park_decisions", [], |r| r.get(0))
        .unwrap();
    assert_eq!(decisions, 0);
    db.execute_batch("DROP TRIGGER fail_reservation;").unwrap();
    let observed = receipt(
        execute(&mut db, &park, decision(Source::Human), &adapter).unwrap(),
        State::Verified,
    );
    assert_eq!(observed.apply, Some(Step::Exit(0)));
    assert_eq!(adapter.applies.get(), 1);
}

#[test]
fn gapplan_11_unit_failed_park_can_be_superseded_with_a_new_claim() {
    let (_scratch, _history, mut db) = journal();
    let original = manifest();
    let park = file(&db, "old-park", &original).unwrap();
    let adapter = Fixture { write: false, ..Fixture::default() };
    assert!(matches!(execute(&mut db, &park, decision(Source::Human), &adapter).unwrap(),
        View::Receipt(State::Failed, _)));
    let replacement = Manifest { revision: "fixture-next".into(), ..original };
    let next = decide(&mut db, &park, decision(Source::Human),
        Change::Supersede { id: "next-park", manifest: &replacement }).unwrap().unwrap();
    assert!(matches!(status(&db, &park).unwrap(), View::Receipt(State::Superseded, _)));
    assert_eq!(status(&db, &next).unwrap(), View::Status(State::Pending));
    assert_eq!(adapter.applies.get(), 1);
}
