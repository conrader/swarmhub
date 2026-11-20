use super::{job_delivery::{AUTH, ORIGIN, TestApi, workspace}, reopen_journal, schema};
use crate::{
    Workspace,
    fleet_policy::{PolicyRef, principals::{ParkPin, Principal, Purpose, Signed, Target},
        tests::{Fixture as Signer, WORKSPACE, envelope, policy}},
    history::{self, History},
    outbound::{Executor, gmail::Account},
    parks::{self, ParkRef, State, View},
    vault::workload::outbound::{Counts, Fixture, Mode},
};
use reqwest::StatusCode;
use rusqlite::params;
use serde_json::{Value, json};
use std::{path::Path, sync::{Arc, Mutex, mpsc}, time::Duration};
use tempfile::TempDir;

const SENDER: &str = "owner@example.test";

fn account() -> Account {
    Account { sender: SENDER.into(), send: true, lookup: true }
}

fn draft() -> Value {
    json!({"version":0,"project":"fixture","payload":{
        "channel":"email","sender":SENDER,"to":["to@example.test"],"cc":["cc@example.test"],
        "bcc":["bcc@example.test"],"subject":"Fixture","in_reply_to":"<prior@example.test>",
        "thread_id":"thread-1","body":"Approved copy\nCafé"
    }})
}

async fn post(api: &TestApi, path: &str, body: Value, expected: StatusCode) -> Value {
    let response = api.client.post(format!("{ORIGIN}{path}")).header("Origin", ORIGIN)
        .bearer_auth(AUTH).header("Content-Type", "application/json").body(body.to_string())
        .send().await.unwrap();
    let status = response.status();
    let text = response.text().await.unwrap();
    assert_eq!(status, expected, "{text}");
    serde_json::from_str(&text).unwrap()
}

struct Bridge {
    journal: History,
    workspace: Workspace,
    api: TestApi,
}

impl Bridge {
    fn new(root: &Path, signer: &Signer, executor: Executor) -> Self {
        Self::with_journal(root, signer, executor, reopen_journal(&root.join("journal")))
    }

    fn with_journal(root: &Path, signer: &Signer, executor: Executor, journal: History) -> Self {
        let mut workspace = workspace(root, journal.clone());
        workspace.fleet_policy = Ok(Some(signer.authority.clone()));
        workspace.parks = workspace.parks.with_outbound_fixture(executor);
        let api = TestApi::start(root, &workspace);
        Self { journal, workspace, api }
    }

    fn after_claim(&mut self, root: &Path, hook: impl Fn() + Send + Sync + 'static) {
        self.workspace.parks.after_claim = Some(Arc::new(hook));
        std::fs::remove_file(root.join("api.sock")).unwrap();
        self.api = TestApi::start(root, &self.workspace);
    }

    async fn stage(&self, body: Value) -> (ParkRef, ParkPin, Value) {
        let staged = post(&self.api, "/api/outbound/stage", body, StatusCode::OK).await;
        let park: ParkRef = serde_json::from_value(staged["park"].clone()).unwrap();
        let preview = self.preview(&park).await;
        let pin = serde_json::from_value(preview["pin"].clone()).unwrap();
        (park, pin, staged)
    }

    async fn preview(&self, park: &ParkRef) -> Value {
        self.api.status(&format!("/api/parks/{}", park.id)).await
    }

    async fn decide(&self, park: &ParkRef, signed: &Signed, expected: StatusCode) -> Value {
        post(&self.api, "/api/parks/decide", json!({
            "park":park,"purpose":signed.envelope.purpose,"evidence":{"signed":signed},
        }), expected).await
    }

    async fn reconcile(&self, park: &ParkRef) -> Value {
        post(&self.api, "/api/outbound/reconcile", json!(park), StatusCode::OK).await
    }

    fn state(&self, park: &ParkRef) -> View {
        parks::status(&self.journal.db().unwrap(), park).unwrap()
    }
}

struct Harness {
    root: TempDir,
    signer: Signer,
    policy: PolicyRef,
    executor: Executor,
    provider: Arc<Fixture>,
}

impl Harness {
    fn new(account: Account) -> Self {
        let root = tempfile::tempdir().unwrap();
        let signer = Signer::new(root.path(), WORKSPACE, true);
        let policy = signer.publish(signer.publication(policy(1, vec![]), WORKSPACE)).unwrap();
        let (executor, provider) = Fixture::start(account).unwrap();
        Self { root, signer, policy, executor, provider }
    }

    fn bridge(&self) -> Bridge {
        Bridge::new(self.root.path(), &self.signer, self.executor.clone())
    }

    fn sign(&self, pin: &ParkPin, purpose: Purpose, nonce: &str) -> Signed {
        self.signer.sign_decision(envelope(WORKSPACE, Principal::Operator, purpose,
            Target::Park { park: pin.clone(), policy: self.policy.clone() }, nonce))
    }

    async fn approve(&self, bridge: &Bridge, park: &ParkRef, pin: &ParkPin) {
        let approval = self.sign(pin, Purpose::AuthorizeOutbound, "approve");
        assert_eq!(bridge.decide(park, &approval, StatusCode::OK).await["result"], "outbound_approved");
    }
}

#[tokio::test]
async fn gapplan_14_int_racing_signed_callers_share_a_reservation_and_receipt() {
    let h = Harness::new(account());
    let mut bridge = h.bridge();
    let (park, pin, staged) = bridge.stage(draft()).await;
    h.approve(&bridge, &park, &pin).await;
    let (entered, wait_for_claim) = mpsc::channel();
    let (release, wait_for_release) = mpsc::channel();
    let wait_for_release = Mutex::new(wait_for_release);
    bridge.after_claim(h.root.path(), move || {
        entered.send(()).unwrap();
        wait_for_release.lock().unwrap().recv_timeout(Duration::from_secs(5)).unwrap();
    });
    let first = h.sign(&pin, Purpose::Execute, "execute-first");
    let second = h.sign(&pin, Purpose::Execute, "execute-second");
    let race = async {
        tokio::task::spawn_blocking(move || wait_for_claim.recv_timeout(Duration::from_secs(5)))
            .await.unwrap().unwrap();
        let losing = bridge.decide(&park, &second, StatusCode::OK).await;
        let counts_before_release = h.provider.counts();
        release.send(()).unwrap();
        assert_eq!(losing["receipt"]["status"], "submitting");
        assert_eq!(counts_before_release.submission_attempts, 0);
        losing
    };
    let (winner, loser) = tokio::join!(bridge.decide(&park, &first, StatusCode::OK), race);
    let receipt = &winner["receipt"];
    assert_eq!(receipt["status"], "accepted");
    assert_eq!(receipt["attempt"], loser["receipt"]["attempt"]);
    assert_eq!(receipt["message_id"], loser["receipt"]["message_id"]);
    assert_eq!(receipt["payload_digest"], staged["payload_digest"]);
    assert_eq!(receipt["provider_account"], SENDER);
    assert_eq!(receipt["provider_id"], "fixture-message-1");
    assert!(receipt["accepted_ms"].as_i64().unwrap() >= receipt["reserved_ms"].as_i64().unwrap());
    assert_eq!(bridge.state(&park), View::Status(State::Verified));
    assert_eq!(bridge.preview(&park).await["outbound"]["version"]["receipt"], *receipt);
    assert_eq!(bridge.decide(&park, &second, StatusCode::OK).await["receipt"], *receipt);
    assert_eq!(h.provider.counts(), Counts { submission_attempts: 1, ..Counts::default() });

    let mut edit = draft();
    edit["id"] = staged["draft_id"].clone();
    edit["version"] = json!(1);
    edit["payload"]["body"] = json!("Later copy");
    let (_, _, staged) = bridge.stage(edit).await;
    assert_eq!(staged["in_flight"][0]["receipt"], *receipt);
}

#[tokio::test]
async fn gapplan_14_int_lost_reply_checks_sent_before_returning_a_receipt() {
    let h = Harness::new(account());
    h.provider.mode(Mode::LoseReply);
    let bridge = h.bridge();
    let (park, pin, _) = bridge.stage(draft()).await;
    h.approve(&bridge, &park, &pin).await;
    let execute = h.sign(&pin, Purpose::Execute, "execute");
    let receipt = bridge.decide(&park, &execute, StatusCode::OK).await["receipt"].clone();
    assert_eq!(receipt["status"], "accepted");
    assert_eq!(receipt["provider_id"], "fixture-message-1");
    assert_eq!(bridge.state(&park), View::Status(State::Verified));
    assert_eq!(h.provider.counts(), Counts { submission_attempts: 1, searches: 1, readbacks: 1 });
}

#[tokio::test]
async fn gapplan_14_int_lost_provider_reply_and_bridge_restart_reconcile_without_resend() {
    let h = Harness::new(account());
    h.provider.mode(Mode::LoseReply);
    let (park, pin, receipt) = {
        let bridge = h.bridge();
        let (park, pin, _) = bridge.stage(draft()).await;
        h.approve(&bridge, &park, &pin).await;
        // Fail the receipt commit after the executor accepted and lost the reply.
        bridge.journal.db().unwrap().execute_batch(
            "CREATE TRIGGER fixture_crash BEFORE UPDATE ON outbound_receipts
             BEGIN SELECT RAISE(ABORT, 'fixture settlement interruption'); END;"
        ).unwrap();
        let execute = h.sign(&pin, Purpose::Execute, "execute");
        bridge.decide(&park, &execute, StatusCode::INTERNAL_SERVER_ERROR).await;
        let receipt = bridge.preview(&park).await["outbound"]["version"]["receipt"].clone();
        assert_eq!(receipt["status"], "submitting");
        assert_eq!(bridge.state(&park), View::Status(State::Executing));
        (park, pin, receipt)
    };
    std::fs::remove_file(h.root.path().join("api.sock")).unwrap();
    let journal_path = h.root.path().join("journal");
    let journal = tokio::task::spawn_blocking(move || reopen_journal(&journal_path)).await.unwrap();
    let bridge = Bridge::with_journal(h.root.path(), &h.signer, h.executor.clone(), journal);
    bridge.journal.db().unwrap().execute_batch("DROP TRIGGER fixture_crash").unwrap();
    h.provider.mode(Mode::DelayIndex);
    for _ in 0..2 {
        let pending = bridge.reconcile(&park).await;
        assert_eq!(pending["status"], "reconciliation");
        assert_eq!(pending["message_id"], receipt["message_id"]);
    }
    assert_eq!(bridge.state(&park), View::Status(State::Reconciliation));
    let replay = h.sign(&pin, Purpose::Execute, "new-execute");
    assert_eq!(bridge.decide(&park, &replay, StatusCode::OK).await["receipt"]["status"], "reconciliation");
    for mode in [Mode::Revoke, Mode::MultipleMatches, Mode::ChangedCopy, Mode::WrongAccount] {
        h.provider.mode(mode);
        assert_eq!(bridge.reconcile(&park).await["status"], "reconciliation");
        assert_eq!(h.provider.counts().submission_attempts, 1);
    }
    h.provider.mode(Mode::Accept);
    let accepted = bridge.reconcile(&park).await;
    assert_eq!(accepted["provider_id"], "fixture-message-1");
    assert_eq!(accepted["status"], "accepted");
    assert_eq!(accepted["message_id"], receipt["message_id"]);
    assert_eq!(accepted["attempt"], receipt["attempt"]);
    assert_eq!(bridge.state(&park), View::Status(State::Verified));
    assert_eq!(bridge.reconcile(&park).await, accepted);
    assert_eq!(h.provider.counts(), Counts { submission_attempts: 1, searches: 6, readbacks: 3 });
}

#[tokio::test]
async fn gapplan_14_int_revoked_credential_requires_fresh_execute_after_proven_non_submission() {
    let h = Harness::new(account());
    h.provider.mode(Mode::Revoke);
    let bridge = h.bridge();
    let (park, pin, _) = bridge.stage(draft()).await;
    h.approve(&bridge, &park, &pin).await;
    let execute = h.sign(&pin, Purpose::Execute, "execute-revoked");
    let failed = bridge.decide(&park, &execute, StatusCode::OK).await["receipt"].clone();
    assert_eq!(failed["status"], "not_submitted");
    assert_eq!(bridge.state(&park), View::Status(State::Failed));
    assert_eq!(h.provider.counts().submission_attempts, 0);
    h.provider.mode(Mode::Accept);
    assert_eq!(bridge.reconcile(&park).await, failed);
    bridge.decide(&park, &execute, StatusCode::CONFLICT).await;
    assert_eq!(h.provider.counts().submission_attempts, 0);
    bridge.decide(&park, &h.sign(&pin, Purpose::Hold, "hold-failed"), StatusCode::OK).await;
    assert_eq!(bridge.state(&park), View::Status(State::Held));
    bridge.decide(&park, &h.sign(&pin, Purpose::Release, "release-failed"), StatusCode::OK).await;
    assert_eq!(bridge.state(&park), View::Status(State::Failed));
    let fresh = h.sign(&pin, Purpose::Execute, "execute-after-restore");
    assert_eq!(bridge.decide(&park, &fresh, StatusCode::OK).await["reason"], "outbound_approval");
    bridge.decide(&park, &h.sign(&pin, Purpose::AuthorizeOutbound, "approve-retry"), StatusCode::OK).await;
    let accepted = bridge.decide(&park, &fresh, StatusCode::OK).await["receipt"].clone();
    assert_eq!(accepted["status"], "accepted");
    assert_eq!(accepted["attempt"], failed["attempt"]);
    assert_eq!(accepted["message_id"], failed["message_id"]);
    assert_eq!(h.provider.counts().submission_attempts, 1);
}

#[tokio::test]
async fn gapplan_14_int_hold_release_rejects_revoked_approval_and_stale_edits() {
    let h = Harness::new(account());
    let bridge = h.bridge();
    let (park, pin, staged) = bridge.stage(draft()).await;
    h.approve(&bridge, &park, &pin).await;
    for (purpose, nonce) in [(Purpose::Hold, "hold"), (Purpose::Release, "release")] {
        bridge.decide(&park, &h.sign(&pin, purpose, nonce), StatusCode::OK).await;
    }
    assert_eq!(bridge.preview(&park).await["outbound"]["version"]["approval_revoked"], true);
    let execute = h.sign(&pin, Purpose::Execute, "execute");
    assert_eq!(bridge.decide(&park, &execute, StatusCode::OK).await["reason"], "outbound_approval");
    bridge.decide(&park, &h.sign(&pin, Purpose::AuthorizeOutbound, "approve"), StatusCode::CONFLICT).await;

    let fresh = h.sign(&pin, Purpose::AuthorizeOutbound, "approve-fresh");
    bridge.decide(&park, &fresh, StatusCode::OK).await;
    assert_eq!(bridge.preview(&park).await["outbound"]["version"]["approval_revoked"], false);
    let mut edit = draft();
    edit["id"] = staged["draft_id"].clone();
    edit["version"] = json!(1);
    edit["payload"]["body"] = json!("Replacement");
    let (_, next_pin, replacement) = bridge.stage(edit).await;
    assert_eq!(replacement["version"], 2);
    assert!(replacement["approval"].is_null());
    bridge.decide(&park, &execute, StatusCode::CONFLICT).await;
    assert_eq!(bridge.state(&park), View::Status(State::Superseded));
    let next = serde_json::from_value(replacement["park"].clone()).unwrap();
    let next_execute = h.sign(&next_pin, Purpose::Execute, "execute-next");
    assert_eq!(bridge.decide(&next, &next_execute, StatusCode::OK).await["reason"], "outbound_approval");
    assert_eq!(h.provider.counts(), Counts::default());
}

#[tokio::test]
async fn gapplan_14_int_pending_with_existing_execution_blocks_edits_and_claim() {
    let h = Harness::new(account());
    let bridge = h.bridge();
    let (park, pin, staged) = bridge.stage(draft()).await;
    h.approve(&bridge, &park, &pin).await;
    bridge.journal.db().unwrap().execute(
        "INSERT INTO park_executions(park_id,attempt,claimed_ms) VALUES(?1,'prior-fixture-attempt',1)", [&park.id]
    ).unwrap();
    let mut edit = draft();
    edit["id"] = staged["draft_id"].clone();
    edit["version"] = json!(1);
    edit["payload"]["body"] = json!("Replacement");
    post(&bridge.api, "/api/outbound/stage", edit, StatusCode::CONFLICT).await;
    bridge.decide(&park, &h.sign(&pin, Purpose::Execute, "execute"), StatusCode::CONFLICT).await;
    let counts: (i64, i64) = bridge.journal.db().unwrap().query_row(
        "SELECT (SELECT count(*) FROM outbound_versions),(SELECT count(*) FROM outbound_receipts)",
        [], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap();
    assert_eq!(counts, (1, 0));
    assert_eq!(h.provider.counts(), Counts::default());
}

#[tokio::test]
async fn gapplan_14_int_sender_mismatch_and_missing_lookup_make_no_reservation() {
    for options in [
        Account { sender: "other@example.test".into(), ..account() },
        Account { lookup: false, ..account() },
    ] {
        let h = Harness::new(options);
        let bridge = h.bridge();
        let (park, pin, _) = bridge.stage(draft()).await;
        h.approve(&bridge, &park, &pin).await;
        let execute = h.sign(&pin, Purpose::Execute, "execute");
        assert_eq!(bridge.decide(&park, &execute, StatusCode::OK).await["reason"], "outbound_sender");
        assert_eq!(bridge.state(&park), View::Status(State::Pending));
        assert!(bridge.preview(&park).await["outbound"]["version"]["receipt"].is_null());
        assert_eq!(h.provider.counts(), Counts::default());
    }
}

#[tokio::test]
async fn gapplan_14_int_policy_change_blocks_approval_at_claim_and_at_effect() {
    let mut h = Harness::new(account());
    let mut bridge = h.bridge();
    let (park, pin, _) = bridge.stage(draft()).await;
    h.approve(&bridge, &park, &pin).await;
    h.policy = h.signer.publish(h.signer.publication(policy(2, vec![]), WORKSPACE)).unwrap();
    let execute = h.sign(&pin, Purpose::Execute, "execute");
    bridge.decide(&park, &execute, StatusCode::FORBIDDEN).await;
    assert_eq!(bridge.state(&park), View::Status(State::Pending));
    assert!(bridge.preview(&park).await["outbound"]["version"]["receipt"].is_null());

    let fresh = h.sign(&pin, Purpose::AuthorizeOutbound, "approve-policy-two");
    bridge.decide(&park, &fresh, StatusCode::OK).await;
    let publication = Mutex::new(Some(h.signer.publication(policy(3, vec![]), WORKSPACE)));
    let authority = h.signer.authority.clone();
    bridge.after_claim(h.root.path(), move || {
        authority.publish_fixture(publication.lock().unwrap().take().unwrap()).unwrap();
    });
    assert_eq!(bridge.decide(&park, &execute, StatusCode::OK).await["receipt"]["status"], "not_submitted");
    assert_eq!(bridge.state(&park), View::Status(State::Failed));
    assert_eq!(h.provider.counts(), Counts::default());
}

#[test]
fn gapplan_14_int_v60_fresh_upgrade_and_reopens_preserve_approvals_and_backfill_holds() {
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let scratch = tempfile::tempdir().unwrap();
    let seeded = scratch.path().join("seeded");
    std::fs::DirBuilder::new().mode(0o700).create(&seeded).unwrap();
    let path = seeded.join("workspace.sqlite3");
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).unwrap();
    let old = history::connection(&path).unwrap();
    for migration in &history::migrations()[..59] {
        old.execute_batch(migration).unwrap();
    }
    assert_eq!(schema(&old), 59);
    let park = parks::file(&old, "fixture-pre-v60", &super::manifest()).unwrap();
    let id = "a".repeat(32);
    old.execute("INSERT INTO outbound_drafts(id,owner,project) VALUES(?1,'owner','fixture')", [&id]).unwrap();
    old.execute("INSERT INTO outbound_versions VALUES(?1,1,'{}',?2,?3,1)",
        params![id, "b".repeat(64), park.id]).unwrap();
    for (nonce, at) in [("old-approval", 1), ("new-approval", 3)] {
        old.execute(
            "INSERT INTO outbound_approvals(park_id,workspace,nonce,signed,recorded_ms) VALUES(?1,'fixture',?2,'{}',?3)",
            params![park.id, nonce, at],
        ).unwrap();
    }
    old.execute(
        "INSERT INTO park_decisions(park_id,action,actor,source,basis,at_ms)
         VALUES(?1,'hold','operator','human','hold',1),(?1,'release','operator','human','release',2)",
        [&park.id],
    ).unwrap();
    drop(old);
    for (root, count) in [(seeded, 2), (scratch.path().join("fresh"), 0)] {
        for _ in 0..3 {
            let journal = reopen_journal(&root);
            let db = journal.db().unwrap();
            assert_eq!(schema(&db), history::migrations().len());
            let counts: (i64, i64, i64) = db.query_row(
                "SELECT (SELECT count(*) FROM outbound_receipts),(SELECT count(*) FROM outbound_approvals),
                        (SELECT count(*) FROM outbound_approval_revocations)",
                [], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            ).unwrap();
            assert_eq!(counts, (0, count, count));
            if count > 0 {
                let hold: i64 = db.query_row(
                    "SELECT count(*) FROM outbound_approval_revocations r JOIN park_decisions p
                       ON p.id=r.hold_decision_id WHERE p.action='hold'",
                    [], |row| row.get(0),
                ).unwrap();
                assert_eq!(hold, 2);
                assert_eq!(parks::status(&db, &park).unwrap(), View::Status(State::Pending));
            }
        }
    }
}
