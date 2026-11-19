use super::*;
use crate::history::History;

pub(crate) const OWNER: &str = "job-owner";
pub(crate) const ATTEMPT: i64 = 1;

pub(crate) fn journal(directory: &std::path::Path) -> History {
    let history = History::open_at(directory).unwrap();
    register(&history.db().unwrap(), OWNER);
    history
}

fn register(db: &Connection, id: &str) {
    let registration = bots::Registration {
        id: id.into(),
        name: Some(id.into()),
        ..Default::default()
    };
    bots::register(db, &registration, 1).unwrap().unwrap();
}

pub(crate) fn submission() -> Submission {
    Submission {
        project: 42,
        brief: "Run the deterministic fixture".into(),
        workdir: "/fixture/project".into(),
        runtime: Runtime {
            provider: "codex".into(),
            account_ref: Some("fixture-requested".into()),
            model: Some("fixture-model".into()),
            family: None,
            effort: Some("medium".into()),
        },
    }
}

pub(crate) fn submit_fixture(db: &mut Connection, key: &str) -> Job {
    submit(db, OWNER, key, &submission()).unwrap()
}

pub(crate) fn report(exit: Exit) -> Report {
    Report {
        exit,
        observed_runtime: Some(Runtime {
            provider: "codex".into(),
            account_ref: Some("fixture-observed".into()),
            model: Some("fixture-resolved-model".into()),
            family: Some("codex".into()),
            effort: Some("high".into()),
        }),
        observed_cli_version: Some("fixture-cli 1.2.3".into()),
        log_ref: Some("fixture-log".into()),
        result: None,
    }
}

pub(crate) fn success() -> Report {
    Report {
        result: Some(Artifact {
            reference: "fixture-result".into(),
            digest: "a".repeat(64),
        }),
        ..report(Exit::Exited(0))
    }
}

pub(crate) fn dispatch(db: &mut Connection, job: &Job) -> Dispatch {
    record_dispatch(db, &job.id, ATTEMPT, "fixture-host", "fixture-lease").unwrap()
}

pub(crate) fn finish_after_update(
    db: &mut Connection,
    job_id: &str,
    after_update: impl FnOnce(),
) -> Result<Completion, Error> {
    finish_inner(db, job_id, ATTEMPT, &success(), None, after_update)
}

fn fixture() -> (tempfile::TempDir, History) {
    let scratch = tempfile::tempdir().unwrap();
    let history = journal(&scratch.path().join("journal"));
    (scratch, history)
}

#[test]
fn gapplan_02_unit_duplicate_submission_is_scoped_to_the_registered_owner() {
    let (_scratch, h) = fixture();
    let mut db = h.db().unwrap();
    let job = submit_fixture(&mut db, "key");
    assert_eq!(submit_fixture(&mut db, "key"), job);
    let other = "other-owner";
    register(&db, other);
    let other_job = submit(&mut db, other, "key", &submission()).unwrap();
    assert_ne!(other_job.id, job.id);
    assert_eq!(other_job.payload_digest, job.payload_digest);
    assert_eq!(status(&db, &job.id).unwrap().unwrap().owner_bot_id, OWNER);
    assert_eq!(status(&db, &other_job.id).unwrap().unwrap().owner_bot_id, other);
    assert!(matches!(
        submit(&mut db, "unregistered", "key", &submission()),
        Err(Error::UnknownOwner)
    ));
    db.execute("UPDATE bots SET removed_ms=2 WHERE id=?1", [other]).unwrap();
    assert!(matches!(
        submit(&mut db, other, "new-key", &submission()),
        Err(Error::UnknownOwner)
    ));
    assert_eq!(submit(&mut db, other, "key", &submission()).unwrap(), other_job);
    let counts = db.query_row(
        "SELECT (SELECT count(*) FROM jobs),(SELECT count(*) FROM job_attempts)",
        [],
        |r| Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?)),
    ).unwrap();
    assert_eq!(counts, (2, 2));
}

#[test]
fn gapplan_02_unit_changed_submission_conflicts_and_preserves_the_original() {
    let (_scratch, h) = fixture();
    let mut db = h.db().unwrap();
    let job = submit_fixture(&mut db, "key");
    let changes: [fn(&mut Submission); 4] = [
        |job| job.project += 1,
        |job| job.brief.push_str(" again"),
        |job| job.workdir.push_str("-alternate"),
        |job| job.runtime.effort = None,
    ];
    for change in changes {
        let mut changed = submission();
        change(&mut changed);
        assert!(matches!(submit(&mut db, OWNER, "key", &changed), Err(Error::Conflict)));
    }
    assert_eq!(submit_fixture(&mut db, "key"), job);
    assert!(db.execute("UPDATE jobs SET project=99 WHERE id=?1", [&job.id]).is_err());
}

#[test]
fn gapplan_02_unit_bounds_submissions_and_rejects_unsafe_references() {
    let (_scratch, h) = fixture();
    let mut db = h.db().unwrap();
    let mut wanted = submission();
    wanted.brief = "é".repeat(BRIEF_MAX / 2 + 1);
    assert!(matches!(submit(&mut db, OWNER, "key", &wanted), Err(Error::InvalidInput)));
    wanted = submission();
    wanted.workdir = "a".repeat(WORKDIR_MAX + 1);
    assert!(matches!(submit(&mut db, OWNER, "key", &wanted), Err(Error::InvalidInput)));

    let job = submit_fixture(&mut db, "key");
    assert_eq!(dispatch(&mut db, &job), Dispatch::Recorded);
    for reference in ["..", "../result", "/tmp/result", "https://fixture.invalid/result", "%2f"] {
        let mut report = success();
        report.result.as_mut().unwrap().reference = reference.into();
        assert!(matches!(finish(&mut db, &job.id, ATTEMPT, &report), Err(Error::InvalidInput)));
    }
    let mut report = success();
    report.result.as_mut().unwrap().digest = "bad-digest".into();
    assert!(matches!(finish(&mut db, &job.id, ATTEMPT, &report), Err(Error::InvalidInput)));
    let mut report = success();
    report.log_ref = Some("../fixture-log".into());
    assert!(matches!(finish(&mut db, &job.id, ATTEMPT, &report), Err(Error::InvalidInput)));
    let saved = status(&db, &job.id).unwrap().unwrap();
    assert_eq!(saved.status, "dispatching");
    assert!(saved.completion.is_none());
}

#[test]
fn gapplan_02_unit_nonzero_exit_records_failure_even_with_a_result() {
    let (_scratch, h) = fixture();
    let mut db = h.db().unwrap();
    let job = submit_fixture(&mut db, "key");
    dispatch(&mut db, &job);
    assert!(record_running(&db, &job.id, ATTEMPT).unwrap());

    let report = Report { exit: Exit::Exited(7), ..success() };
    let event = finish(&mut db, &job.id, ATTEMPT, &report).unwrap();
    assert_eq!(event.exit.status, "exited");
    assert_eq!(event.exit.code, Some(7));
    assert_eq!(event.exit.reason, "nonzero_exit");
    assert_eq!(event.exit.verdict, "failed");
    assert_eq!(event.exit.result, report.result);
    assert_eq!(event.expected_next_action, "inspect_failure");
}

#[test]
fn gapplan_02_unit_confirmed_interruption_is_terminal() {
    let (_scratch, h) = fixture();
    let mut db = h.db().unwrap();
    let job = submit_fixture(&mut db, "key");
    dispatch(&mut db, &job);
    let event = finish(&mut db, &job.id, ATTEMPT, &report(Exit::Interrupted)).unwrap();
    assert_eq!(event.exit.status, "interrupted");
    assert_eq!(event.exit.reason, "interrupted");
    assert_eq!(event.exit.code, None);
    assert_eq!(event.exit.verdict, "interrupted");
    assert_eq!(event.expected_next_action, "review_interruption");
    assert!(!record_unknown(&db, &job.id, ATTEMPT).unwrap());
    assert!(!record_running(&db, &job.id, ATTEMPT).unwrap());
    assert_eq!(status(&db, &job.id).unwrap().unwrap().completion, Some(event));
}

#[test]
fn gapplan_02_unit_zero_exit_without_result_is_a_terminal_failure() {
    let (_scratch, h) = fixture();
    let mut db = h.db().unwrap();
    let job = submit_fixture(&mut db, "key");
    dispatch(&mut db, &job);
    let event = finish(&mut db, &job.id, ATTEMPT, &report(Exit::Exited(0))).unwrap();
    assert_eq!(event.exit.status, "exited");
    assert_eq!(event.exit.code, Some(0));
    assert_eq!(event.exit.reason, "missing_result");
    assert_eq!(event.exit.verdict, "failed");
    assert!(event.exit.result.is_none());
    assert_eq!(event.expected_next_action, "inspect_failure");
}

#[test]
fn gapplan_02_unit_cancelled_jobs_cannot_dispatch_or_accept_a_late_exit() {
    let (_scratch, h) = fixture();
    let mut db = h.db().unwrap();
    for (key, started) in [("queued", false), ("dispatching", true)] {
        let job = submit_fixture(&mut db, key);
        if started {
            assert_eq!(dispatch(&mut db, &job), Dispatch::Recorded);
        }
        let report = Report {
            exit: Exit::Cancelled,
            observed_runtime: None,
            observed_cli_version: None,
            log_ref: None,
            result: None,
        };
        let event = finish(&mut db, &job.id, ATTEMPT, &report).unwrap();
        assert_eq!(event.exit.status, "cancelled");
        assert_eq!(event.exit.verdict, "cancelled");
        assert_eq!(event.exit.code, None);
        assert_eq!(event.expected_next_action, "review_cancellation");
        assert_eq!(finish(&mut db, &job.id, ATTEMPT, &report).unwrap(), event);
        assert!(matches!(finish(&mut db, &job.id, ATTEMPT, &success()), Err(Error::Conflict)));
        match record_dispatch(&mut db, &job.id, ATTEMPT, "fixture-host", "fixture-lease") {
            Ok(Dispatch::AlreadyRecorded) if started => {}
            Err(Error::Conflict) if !started => {}
            other => panic!("unexpected dispatch result: {other:?}"),
        }
    }
}


#[test]
fn gapplan_10_unit_confirmed_exit_and_cancellation_cannot_overwrite_each_other() {
    let (_temp, journal) = fixture();
    let mut db = journal.db().unwrap();
    for (key, first, later) in [
        ("exit-first", success(), report(Exit::Cancelled)),
        ("cancel-first", report(Exit::Cancelled), success()),
    ] {
        let job = submit_fixture(&mut db, key);
        assert_eq!(dispatch(&mut db, &job), Dispatch::Recorded);
        let done = finish_inner(&mut db, &job.id, ATTEMPT, &first,
            Some(FinishEvidence { worker_reason: None, review_eligible: false }), || {}).unwrap();
        assert!(matches!(finish(&mut db, &job.id, ATTEMPT, &later), Err(Error::Conflict)));
        assert_eq!(finish(&mut db, &job.id, ATTEMPT, &first).unwrap(), done);
        assert_eq!(status(&db, &job.id).unwrap().unwrap().completion, Some(done));
    }
}

#[test]
fn gapplan_10_unit_managed_replay_binds_profile_and_payload() {
    use crate::machines::probe::Provider;
    let (_temp, journal) = fixture();
    let mut db = journal.db().unwrap();
    let mut placement = Placement {
        host_id: "fixture-worker".into(), fingerprint: "fixture-pin".into(),
        machine: "mini-m4".into(), target: "worker@mini-m4.invalid".into(), project_created_ms: 1,
        provider: Provider::Codex, account_ref: "fixture-account".into(), profile: "local".into(),
    };
    let mut submission = submission();
    let first = submit_with_placement(&mut db, OWNER, "stable", &submission, Some(&placement)).unwrap();
    assert_eq!(submit_with_placement(&mut db, OWNER, "stable", &submission, Some(&placement)).unwrap(), first);
    placement.profile = "other".into();
    assert!(matches!(submit_with_placement(&mut db, OWNER, "stable", &submission, Some(&placement)), Err(Error::Conflict)));
    placement.profile = "local".into();
    submission.brief.push('!');
    assert!(matches!(submit_with_placement(&mut db, OWNER, "stable", &submission, Some(&placement)), Err(Error::Conflict)));
}
