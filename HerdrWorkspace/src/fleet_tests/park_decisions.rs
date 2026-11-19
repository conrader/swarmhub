use super::{fleet_authority::registered_launch, job_delivery::{ORIGIN, TestApi, workspace}, reopen_journal, WAIT};
use crate::{
    Workspace, bots,
    fleet_policy::{self, PolicyRef, Rule, RuleKind, principals::{Principal, Purpose, Signed, Target},
        tests::{Fixture, JARVIS, WORKSPACE, envelope, grant, policy}},
    parks::{self, GitFixture, Manifest, Operation, ParkRef, State, View},
};
use reqwest::{Response, StatusCode};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use tempfile::TempDir;
use tokio::{sync::{Barrier, Notify}, time::timeout};

const PARK: &str = "fixture-staging-park";

struct Harness {
    root: TempDir,
    w: Workspace,
    signing: Fixture,
    git: Arc<GitFixture>,
    owner: String,
    judge: String,
}

impl Harness {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let git = Arc::new(GitFixture::new(root.path()));
        let signing = Fixture::new(root.path(), WORKSPACE, true);
        let history = reopen_journal(&root.path().join("journal"));
        let (_, owner) = registered_launch(&history, &git.manifest.owner, "Owner");
        let (_, judge) = registered_launch(&history, JARVIS, "Jarvis");
        let mut w = workspace(root.path(), history);
        w.fleet_policy = Ok(Some(signing.authority.clone()));
        w.parks = parks::Service::fixture(&git.directory, git.manifest.clone());
        Self { root, w, signing, git, owner, judge }
    }

    fn api(&self) -> TestApi {
        TestApi::start(self.root.path(), &self.w)
    }

    fn publish(&self, rules: Vec<Rule>) -> PolicyRef {
        self.signing.publish(self.signing.publication(policy(1, rules), WORKSPACE)).unwrap()
    }

    fn sign(&self, park: &ParkRef, manifest: &Manifest, reference: &PolicyRef, purpose: Purpose, nonce: &str) -> Signed {
        let principal = match nonce {
            nonce if nonce.starts_with("delegate-") => Principal::Bot { id: JARVIS.into(), launch: self.judge.clone() },
            _ => Principal::Operator,
        };
        self.signing.sign_decision(envelope(WORKSPACE, principal, purpose, Target::Park {
            park: park.pin(manifest), policy: reference.clone(),
        }, nonce))
    }

    async fn file(&self, manifest: &Manifest) -> ParkRef {
        let text = bot(&self.w, &self.owner, parks::Command::File { id: PARK.into(), manifest: Box::new(manifest.clone()) }).await.unwrap();
        let pin: Value = serde_json::from_str(&text).unwrap();
        assert_eq!(pin["id"], PARK);
        assert_eq!(pin["revision"], manifest.revision);
        ParkRef { id: PARK.into(), manifest_digest: pin["manifest_digest"].as_str().unwrap().into() }
    }
}

fn staging_grant(safe: bool) -> Rule {
    let mut rule = grant();
    rule.scope.action = Some(parks::STAGING_ACTION.into());
    if safe {
        rule.id = "fixture-safe-staging".into();
        rule.rule = RuleKind::SafeClassGrant;
    }
    rule
}

async fn bot(w: &Workspace, launch: &str, command: parks::Command) -> Result<String, String> {
    bots::answer(w, Ok("fixture-core".into()), launch, bots::Ask::Park { command: Box::new(command) }).await
}

async fn submit(api: &TestApi, w: &Workspace, body: Value) -> Response {
    api.client.post(format!("{ORIGIN}/api/parks/decide")).bearer_auth(&w.token)
        .header("Origin", ORIGIN).header("Content-Type", "application/json").body(body.to_string()).send().await.unwrap()
}

fn submission(park: &ParkRef, signed: &Signed) -> Value {
    json!({ "park": park, "purpose": signed.envelope.purpose, "evidence": { "signed": signed } })
}

async fn json_response(response: Response, want: StatusCode) -> Value {
    let status = response.status();
    let body = response.text().await.unwrap();
    assert_eq!(status, want, "{body}");
    serde_json::from_str(&body).unwrap()
}

#[tokio::test]
async fn gapplan_05_int_filing_hold_release_judge_human_race_and_verified_effect() {
    let mut h = Harness::new();
    let reached = Arc::new(Notify::new());
    let (resume, wait) = std::sync::mpsc::channel();
    let wait = Mutex::new(wait);
    h.w.parks.after_claim = Some(Arc::new({
        let reached = reached.clone();
        move || {
            reached.notify_one();
            wait.lock().unwrap().recv_timeout(WAIT).unwrap();
        }
    }));
    let api = h.api();
    let policy = h.publish(vec![staging_grant(false), staging_grant(true)]);
    let manifest = &h.git.manifest;
    assert!(bot(&h.w, &h.judge, parks::Command::File { id: PARK.into(), manifest: Box::new(manifest.clone()) }).await.is_err());
    let park = h.file(manifest).await;
    assert_eq!(h.file(manifest).await, park);
    assert_eq!(api.status("/api/attention").await["parks"][0]["state"], "pending");
    let hold = h.sign(&park, manifest, &policy, Purpose::Hold, "human-hold");
    let execute = h.sign(&park, manifest, &policy, Purpose::Execute, "human-execute");
    let judge = h.sign(&park, manifest, &policy, Purpose::Execute, "delegate-judge");
    let backstop = h.sign(&park, manifest, &policy, Purpose::AutoExecute, "delegate-backstop");
    assert_eq!(
        submit(&api, &h.w, json!({"park":park, "purpose":"execute"})).await.status(),
        StatusCode::UNPROCESSABLE_ENTITY,
    );
    assert_eq!(json_response(submit(&api, &h.w, submission(&park, &hold)).await, StatusCode::OK).await["view"]["status"], "held");
    assert_eq!(api.status("/api/attention").await["parks"][0]["state"], "held");
    assert_eq!(json_response(submit(&api, &h.w, submission(&park, &execute)).await, StatusCode::OK).await["view"]["status"], "held");
    let release = h.sign(&park, manifest, &policy, Purpose::Release, "human-release");
    let nonce = h.signing.import_decision(release).unwrap();
    let imported = json!({ "park": park, "purpose": "release", "evidence": {"imported":nonce} });
    assert_eq!(json_response(submit(&api, &h.w, imported).await, StatusCode::OK).await["view"]["status"], "pending");
    assert_eq!(submit(&api, &h.w, submission(&park, &hold)).await.status(), StatusCode::CONFLICT);

    let won = {
        let start = Barrier::new(2);
        let judge_entry = async {
            start.wait().await;
            let result = bot(&h.w, &h.judge, parks::Command::Judge {
                park: park.clone(),
                signed: judge,
            }).await.unwrap();
            serde_json::from_str::<Value>(&result).unwrap()
        };
        let human_entry = async {
            start.wait().await;
            json_response(submit(&api, &h.w, submission(&park, &execute)).await, StatusCode::OK).await
        };
        tokio::pin!(judge_entry, human_entry);
        timeout(WAIT, async {
            let (lost, judge_won) = tokio::select! {
                view = &mut judge_entry => (view, false),
                view = &mut human_entry => (view, true),
            };
            reached.notified().await;
            assert_eq!(lost["view"]["status"], "executing");
            assert_eq!(h.git.head(), manifest.precondition);
            resume.send(()).unwrap();
            if judge_won { judge_entry.await } else { human_entry.await }
        }).await.unwrap()
    };
    assert_eq!(won["view"]["receipt"][0], "verified");
    assert_eq!(won["view"]["receipt"][1]["after_apply"]["revision"], manifest.expected_postcondition);
    assert_eq!(h.git.head(), manifest.expected_postcondition);
    let retried = bot(&h.w, &h.judge, parks::Command::Backstop { park: park.clone(), signed: backstop }).await.unwrap();
    assert_eq!(serde_json::from_str::<Value>(&retried).unwrap(), won);
    let saved = api.status(&format!("/api/parks/{PARK}")).await;
    assert_eq!(saved["detail"]["view"], won["view"]);
    assert_eq!(saved["detail"]["decision"]["policy"]["digest"], policy.digest);
    assert_eq!(saved["detail"]["decision"]["classifier"]["class"], "reviewed_reversible");

    let db = h.w.history.db().unwrap();
    let records: (i64, i64, i64) = db.query_row(
        "SELECT (SELECT count(*) FROM park_executions),
                (SELECT count(*) FROM park_decisions WHERE action='claim'),
                (SELECT count(*) FROM park_decisions d JOIN fleet_policy_versions v
                    ON json_extract(d.policy_version,'$.workspace')=v.workspace
                    AND json_extract(d.policy_version,'$.digest')=v.digest
                    AND json_extract(d.policy_version,'$.generation')=v.generation)",
        [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    ).unwrap();
    assert_eq!(records, (1, 1, 3));
    drop(db);
    drop(api);
    let Harness { root, w, .. } = h;
    drop(w);
    let directory = root.path().join("journal");
    let reopened = tokio::task::spawn_blocking(move || reopen_journal(&directory)).await.unwrap();
    let db = reopened.db().unwrap();
    assert!(matches!(parks::status(&db, &park).unwrap(), View::Receipt(State::Verified, _)));
}

#[tokio::test]
async fn gapplan_05_int_backstop_needs_exact_safe_class_grant() {
    let h = Harness::new();
    let reference = h.publish(vec![staging_grant(false)]);
    let manifest = &h.git.manifest;
    let park = h.file(manifest).await;
    let auto = h.sign(&park, manifest, &reference, Purpose::AutoExecute, "delegate-no-safe-grant");
    assert_eq!(bot(&h.w, &h.judge, parks::Command::Backstop { park: park.clone(), signed: auto }).await.unwrap_err(),
        fleet_policy::Error::NoGrant.to_string());
    let current = h.signing.publish(h.signing.publication(policy(2, vec![staging_grant(true)]), WORKSPACE)).unwrap();
    let signed = h.sign(&park, manifest, &current, Purpose::AutoExecute, "delegate-safe-run");
    let result = bot(&h.w, &h.judge, parks::Command::Backstop { park: park.clone(), signed: signed.clone() }).await.unwrap();
    assert_eq!(serde_json::from_str::<Value>(&result).unwrap()["view"]["receipt"][0], "verified");
    assert_eq!(h.git.head(), manifest.expected_postcondition);
    // An independent reset to the original head still cannot replay this park.
    h.git.set_head(&manifest.precondition);
    let replay = bot(&h.w, &h.judge, parks::Command::Backstop { park, signed }).await.unwrap();
    assert_eq!(replay, result);
    assert_eq!(h.git.head(), manifest.precondition);
    let db = h.w.history.db().unwrap();
    let basis: (String, String) = db.query_row(
        "SELECT source,json_extract(basis,'$.rule') FROM park_decisions WHERE action='claim'",
        [], |r| Ok((r.get(0)?, r.get(1)?)),
    ).unwrap();
    assert_eq!(basis, ("backstop".into(), "fixture-safe-staging".into()));
}

#[tokio::test]
async fn gapplan_05_int_revoke_after_claim_holds_without_effect_or_nonce_replay() {
    let mut h = Harness::new();
    let reference = h.publish(vec![staging_grant(false)]);
    let mut revoked = policy(2, vec![staging_grant(false)]);
    revoked.revoked.insert("fixture-grant".into());
    let publication = Mutex::new(Some(h.signing.publication(revoked, WORKSPACE)));
    let root = h.root.path().join(WORKSPACE);
    h.w.parks.after_claim = Some(Arc::new(move || {
        let authority = fleet_policy::Authority::fixture(&root, WORKSPACE);
        authority.publish_fixture(publication.lock().unwrap().take().unwrap()).unwrap();
    }));
    let api = h.api();
    let park = h.file(&h.git.manifest).await;
    let signed = h.sign(&park, &h.git.manifest, &reference, Purpose::Execute, "delegate-revoked");
    let held = bot(&h.w, &h.judge, parks::Command::Judge { park: park.clone(), signed: signed.clone() }).await.unwrap();
    assert_eq!(serde_json::from_str::<Value>(&held).unwrap()["reason"], "authorization_changed");
    assert_eq!(h.git.head(), h.git.manifest.precondition);
    assert!(matches!(parks::status(&h.w.history.db().unwrap(), &park).unwrap(), View::Status(State::Held)));
    let current = match h.signing.authority.inspect() {
        fleet_policy::Inspection::Current { reference, .. } => reference,
        _ => panic!("revoked policy was not published"),
    };
    let release = h.sign(&park, &h.git.manifest, &current, Purpose::Release, "human-release-revoked");
    assert_eq!(submit(&api, &h.w, submission(&park, &release)).await.status(), StatusCode::OK);
    assert_eq!(bot(&h.w, &h.judge, parks::Command::Judge { park: park.clone(), signed }).await.unwrap_err(),
        fleet_policy::Error::StalePolicy.to_string());
    let fresh = h.sign(&park, &h.git.manifest, &current, Purpose::Execute, "delegate-revoked-fresh");
    assert_eq!(bot(&h.w, &h.judge, parks::Command::Judge { park: park.clone(), signed: fresh }).await.unwrap_err(),
        fleet_policy::Error::NoGrant.to_string());
    let mut grant = staging_grant(false);
    grant.id = "fixture-replacement-grant".into();
    let mut regrant = policy(3, vec![grant]);
    regrant.revoked.insert("fixture-grant".into());
    let current = h.signing.publish(h.signing.publication(regrant, WORKSPACE)).unwrap();
    let replay = h.sign(&park, &h.git.manifest, &current, Purpose::Execute, "delegate-revoked");
    assert_eq!(bot(&h.w, &h.judge, parks::Command::Judge { park, signed: replay }).await.unwrap_err(),
        fleet_policy::Error::Replay.to_string());
    assert_eq!(h.git.head(), h.git.manifest.precondition);
}

#[tokio::test]
async fn gapplan_05_int_drift_or_changed_review_pins_holds_without_effect() {
    for scenario in ["already-drifted", "drift-after-claim", "tampered-reverse-pin"] {
        let mut h = Harness::new();
        let mut manifest = h.git.manifest.clone();
        match scenario {
            "already-drifted" => h.git.advance_externally(),
            "drift-after-claim" => {
                let git = h.git.clone();
                h.w.parks.after_claim = Some(Arc::new(move || git.advance_externally()));
            }
            _ => manifest.reverse_pin = "unreviewed-reverse".into(),
        }
        let reference = h.publish(vec![]);
        let api = h.api();
        let park = h.file(&manifest).await;
        let signed = h.sign(&park, &manifest, &reference, Purpose::Execute, "human-stale-pins");
        let held = json_response(submit(&api, &h.w, submission(&park, &signed)).await, StatusCode::OK).await;
        assert_eq!(held["reason"], "pins", "{scenario}");
        let expected = if scenario == "tampered-reverse-pin" { &manifest.precondition } else { &h.git.other };
        assert_eq!(&h.git.head(), expected);
        assert_eq!(api.status("/api/attention").await["parks"][0]["state"], "held");
    }
}

#[tokio::test]
async fn gapplan_05_int_unknown_escalates_and_supersession_binds_the_replacement() {
    let h = Harness::new();
    let mut broad = staging_grant(false);
    broad.scope.action = Some("unknown".into());
    let policy = h.publish(vec![broad]);
    let api = h.api();
    let manifest = Manifest { operation: Operation::Unknown { action: "future_action".into() }, ..h.git.manifest.clone() };
    let park = h.file(&manifest).await;
    let route = format!("/api/parks/{PARK}");
    let detail = api.status(&route).await;
    let owned = bot(&h.w, &h.owner, parks::Command::Status { id: PARK.into() }).await.unwrap();
    assert_eq!(serde_json::from_str::<Value>(&owned).unwrap(), detail);
    assert_eq!(detail["classification"]["class"], "unknown");
    assert_eq!(detail["classification"]["escalation_target"], "operator");
    let delegated = h.sign(&park, &manifest, &policy, Purpose::Execute, "delegate-unknown");
    assert_eq!(bot(&h.w, &h.judge, parks::Command::Judge { park: park.clone(), signed: delegated }).await.unwrap_err(),
        fleet_policy::Error::HumanScope.to_string());
    let execute = h.sign(&park, &manifest, &policy, Purpose::Execute, "human-unknown");
    assert_eq!(json_response(submit(&api, &h.w, submission(&park, &execute)).await, StatusCode::OK).await["reason"], "human_review");

    let replacement = Manifest { revision: "park-v2".into(), ..h.git.manifest.clone() };
    let replacement_pin = parks::pin_for("next-park", &replacement).unwrap();
    let signed = h.signing.sign_decision(envelope(WORKSPACE, Principal::Operator, Purpose::Supersede, Target::Supersession {
        park: park.pin(&manifest), policy: policy.clone(), replacement: replacement_pin,
    }, "human-supersede"));
    let mut body = submission(&park, &signed);
    body["replacement"] = json!({"id":"next-park", "manifest": &replacement});
    let mut altered = body.clone();
    altered["replacement"]["manifest"]["reverse_pin"] = json!("different-reverse-pin");
    assert_eq!(submit(&api, &h.w, altered).await.status(), StatusCode::FORBIDDEN);
    assert_eq!(json_response(submit(&api, &h.w, body).await, StatusCode::OK).await["result"], "superseded");
    assert_eq!(api.status(&route).await["detail"]["superseded_by"], "next-park");
    let next_park = ParkRef { id: "next-park".into(), manifest_digest: parks::pin_for("next-park", &replacement).unwrap().manifest_digest };
    let hold = h.sign(&next_park, &replacement, &policy, Purpose::Hold, "human-hold-next");
    assert_eq!(submit(&api, &h.w, submission(&next_park, &hold)).await.status(), StatusCode::OK);
    let deny = h.sign(&next_park, &replacement, &policy, Purpose::Deny, "human-deny");
    assert_eq!(json_response(submit(&api, &h.w, submission(&next_park, &deny)).await, StatusCode::OK).await["view"]["status"], "denied");
    assert_eq!(api.status("/api/parks/next-park").await["detail"]["view"]["status"], "denied");
    assert_eq!(h.git.head(), h.git.manifest.precondition);
}

#[tokio::test]
async fn gapplan_05_int_bad_authority_configuration_reports_held() {
    let mut h = Harness::new();
    h.w.fleet_policy = Err(fleet_policy::Error::Invalid);
    let api = h.api();
    assert_eq!(api.status("/api/bots/fleet-policy").await, json!({"status":"held","reason":"invalid"}));
    let response = api.client.get(format!("{ORIGIN}/api/parks")).send().await.unwrap();
    assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
}

#[test]
fn gapplan_05_int_rollback_requires_authorization_and_preserves_concurrent_ref() {
    parks::verify_rollback(false, true);
    parks::verify_rollback(true, true);
    parks::verify_rollback(false, false);
}


#[tokio::test]
async fn gapplan_05_int_default_bridge_holds_even_an_operator_signed_staging_update() {
    let mut h = Harness::new();
    h.w.parks = parks::Service::default();
    let reference = h.publish(vec![]);
    let park = h.file(&h.git.manifest).await;
    let signed = h.sign(&park, &h.git.manifest, &reference, Purpose::Execute, "human-fixture-gate");
    let api = h.api();
    let result = json_response(submit(&api, &h.w, submission(&park, &signed)).await, StatusCode::OK).await;
    assert_eq!(result["reason"], "fixture_only");
    assert_eq!(h.git.head(), h.git.manifest.precondition);
}

#[tokio::test]
async fn gapplan_06_int_post_claim_write_errors_preserve_attempt_for_reconciliation() {
    for (field, expected_effect) in [("observed_before", false), ("receipt", true)] {
        let h = Harness::new();
        let reference = h.publish(vec![staging_grant(false)]);
        let manifest = &h.git.manifest;
        let park = h.file(manifest).await;
        h.w.history.db().unwrap().execute_batch(&format!(
            "CREATE TRIGGER fixture_abort BEFORE UPDATE OF {field} ON park_executions
             BEGIN SELECT RAISE(ABORT, 'fixture write failure'); END;"
        )).unwrap();
        let execute = h.sign(&park, manifest, &reference, Purpose::Execute, "delegate-post-claim");
        let decide = || bot(&h.w, &h.judge, parks::Command::Judge {
            park: park.clone(),
            signed: execute.clone(),
        });
        let result = decide().await.unwrap();
        assert_eq!(serde_json::from_str::<Value>(&result).unwrap()["view"]["status"], "reconciliation");
        let (attempt, apply): (String, Option<String>) = h.w.history.db().unwrap().query_row(
            "SELECT attempt,apply_step FROM park_executions WHERE park_id=?1 AND receipt IS NULL",
            [&park.id], |row| Ok((row.get(0)?, row.get(1)?)),
        ).unwrap();
        assert_eq!(apply.as_deref(), expected_effect.then_some(r#"{"Exit":0}"#));
        if expected_effect {
            assert_eq!(h.git.head(), manifest.expected_postcondition);
            h.git.set_head(&manifest.precondition);
        }
        assert_eq!(decide().await.unwrap(), result);
        assert_eq!(h.git.head(), manifest.precondition);
        let db = h.w.history.db().unwrap();
        assert_eq!(db.query_row("SELECT attempt FROM park_executions", [], |r| r.get::<_, String>(0)).unwrap(), attempt);
    }
}

#[tokio::test]
async fn gapplan_06_int_policy_store_busy_after_claim_reports_policy_busy() {
    let mut h = Harness::new();
    let reference = h.publish(vec![staging_grant(false)]);
    let lock_path = h.root.path().join(WORKSPACE).join("policy.lock");
    let guard = Arc::new(Mutex::new(None));
    let held = guard.clone();
    h.w.parks.after_claim = Some(Arc::new(move || {
        let file = std::fs::File::open(&lock_path).unwrap();
        file.try_lock().unwrap();
        *held.lock().unwrap() = Some(file);
    }));
    let park = h.file(&h.git.manifest).await;
    let signed = h.sign(&park, &h.git.manifest, &reference, Purpose::Execute, "delegate-policy-busy");
    let result = bot(&h.w, &h.judge, parks::Command::Judge { park: park.clone(), signed }).await.unwrap();
    drop(guard.lock().unwrap().take());
    assert_eq!(serde_json::from_str::<Value>(&result).unwrap()["reason"], "policy_busy");
    assert_eq!(h.git.head(), h.git.manifest.precondition);
    let db = h.w.history.db().unwrap();
    assert_eq!(parks::status(&db, &park).unwrap(), View::Status(State::Held));
    let reason: String = db.query_row(
        "SELECT json_extract(basis,'$.blocker') FROM park_decisions WHERE action='hold'",
        [], |row| row.get(0),
    ).unwrap();
    assert_eq!(reason, "policy_busy");
}

#[tokio::test]
async fn gapplan_06_int_invalid_policy_evidence_after_claim_holds_with_its_own_reason() {
    let mut h = Harness::new();
    let reference = h.publish(vec![staging_grant(false)]);
    let policy_path = h.root.path().join(WORKSPACE).join("policy-1.json");
    h.w.parks.after_claim = Some(Arc::new(move || {
        std::fs::write(&policy_path, b"bad fixture policy").unwrap();
    }));
    let park = h.file(&h.git.manifest).await;
    let signed = h.sign(&park, &h.git.manifest, &reference, Purpose::Execute, "delegate-policy-invalid");
    let result = bot(&h.w, &h.judge, parks::Command::Judge { park, signed }).await.unwrap();
    assert_eq!(serde_json::from_str::<Value>(&result).unwrap()["reason"], "policy_evidence_invalid");
    assert_eq!(h.git.head(), h.git.manifest.precondition);
}

#[test]
fn gapplan_06_int_startup_quarantines_unfinished_park_attempts() {
    let temp = tempfile::tempdir().unwrap();
    let history = reopen_journal(&temp.path().join("journal"));
    let mut db = history.db().unwrap();
    let park = parks::file(&db, "abandoned", &parks::tests::manifest()).unwrap();
    let tx = db.transaction().unwrap();
    let attempt = "fixture-abandoned-attempt";
    tx.execute("UPDATE parks SET state='executing' WHERE id=?1", [&park.id]).unwrap();
    tx.execute(
        "INSERT INTO park_executions(park_id,attempt,claimed_ms) VALUES (?1,?2,1)",
        (&park.id, attempt),
    ).unwrap();
    tx.commit().unwrap();
    drop(db);
    drop(history);
    let history = reopen_journal(&temp.path().join("journal"));
    let db = history.db().unwrap();
    parks::recover_interrupted(&db).unwrap();
    assert_eq!(parks::status(&db, &park).unwrap(), View::Status(State::Reconciliation));
    let saved: (String, Option<String>) = db.query_row(
        "SELECT attempt,observed_before FROM park_executions WHERE park_id=?1", [&park.id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap();
    assert_eq!(saved, (attempt.into(), None));
}
