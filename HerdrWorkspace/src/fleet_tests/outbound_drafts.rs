use super::{
    fleet_authority::registered_launch,
    job_delivery::{AUTH, ORIGIN, TestApi, workspace},
    reopen_journal, schema,
};
use crate::{
    Workspace,
    fleet_policy::tests::{Fixture, WORKSPACE, envelope, grant, policy},
    fleet_policy::principals::{ParkPin, Principal, Purpose, Signed, Target},
    history::{self, History},
    outbound::Payload,
    parks::{self, ParkRef},
};
use reqwest::{Response, StatusCode};
use rusqlite::{Connection, params};
use serde_json::{Value, json};
use tempfile::TempDir;

const LEGACY: &str = "/api/history/fixture-core/t1/17/email-drafts/";

fn email(body: &str) -> Value {
    json!({
        "sender": "owner@example.test",
        "to": ["to@example.test"], "cc": ["cc@example.test"], "bcc": ["bcc@example.test"],
        "subject": "Reviewed draft", "in_reply_to": "<before@example.test>", "thread_id": "t-123", "body": body
    })
}

fn seed_legacy(db: &Connection, launch: &str) -> i64 {
    let id = db.query_row(
        "INSERT INTO journal(reply_for,core_id,address,created_ms,agent,kind,state,text,at_ms)
         VALUES(?1,'fixture-core','t1',17,'review-owner','reply','received','Email draft attached',1)
         RETURNING id", [launch], |row| row.get(0),
    ).unwrap();
    db.execute(
        "INSERT INTO email_drafts(message,launch,recipients,subject,body,fingerprint)
         VALUES(?1,?2,'to@example.test','Reviewed draft','Original copy',x'01')",
        params![id, launch],
    ).unwrap();
    id
}

fn request(api: &TestApi, path: &str, body: Value) -> reqwest::RequestBuilder {
    api.client.post(format!("{ORIGIN}{path}")).header("Origin", ORIGIN).bearer_auth(AUTH)
        .header("Content-Type", "application/json").body(body.to_string())
}

async fn response(raw: Response, status: StatusCode) -> Value {
    let actual = raw.status();
    let text = raw.text().await.unwrap();
    assert_eq!(actual, status, "{text}");
    serde_json::from_str(&text).unwrap()
}

struct Harness {
    _scratch: TempDir,
    journal: History,
    workspace: Workspace,
    api: TestApi,
    signer: Fixture,
    owner_launch: String,
}

impl Harness {
    fn new() -> Self {
        let scratch = tempfile::tempdir().unwrap();
        let journal = reopen_journal(&scratch.path().join("journal"));
        let (_, owner_launch) = registered_launch(&journal, "review-owner", "Review Owner");
        let signer = Fixture::new(scratch.path(), WORKSPACE, true);
        let mut workspace = workspace(scratch.path(), journal.clone());
        workspace.fleet_policy = Ok(Some(signer.authority.clone()));
        let api = TestApi::start(scratch.path(), &workspace);
        Self { _scratch: scratch, journal, workspace, api, signer, owner_launch }
    }
}

fn submission(pin: &ParkPin, signed: &Signed) -> Value {
    json!({"park":{"id":pin.id,"manifest_digest":pin.manifest_digest},
        "purpose":signed.envelope.purpose,"evidence":{"signed":signed}})
}

#[tokio::test]
async fn gapplan_13_int_reviewed_download_staging_group_review_and_signed_approval_race() {
    let h = Harness::new();
    let policy = h.signer.publish(h.signer.publication(policy(1, vec![]), WORKSPACE)).unwrap();
    let id = seed_legacy(&h.journal.db().unwrap(), &h.owner_launch);
    let base = format!("{LEGACY}{id}");
    let download = request(&h.api, &format!("{base}/download"), json!({
        "revision": 1, "draft": {"to":"to@example.test","subject":"Reviewed draft","body":"Original copy"}
    })).send().await.unwrap();
    assert_eq!(download.status(), StatusCode::OK);
    assert_eq!(download.headers()["x-swarmhub-email-revision"], "2");
    assert!(download.text().await.unwrap().starts_with("X-Unsent: 1\r\n"));
    let legacy = h.api.status(&base).await;
    assert_eq!(legacy["state"], "reviewed");
    assert!(legacy["staged"].is_null());
    assert_eq!(h.api.status("/api/parks").await["parks"], json!([]));

    let stage = format!("{base}/stage");
    let initial = response(request(&h.api, &stage, json!({
        "revision":2,"version":0,"email":email("Original copy")
    })).send().await.unwrap(), StatusCode::OK).await;
    assert!(initial["approval"].is_null());
    let path = format!("/api/parks/{}", initial["park"]["id"].as_str().unwrap());
    let preview = h.api.status(&path).await;
    let pin: ParkPin = serde_json::from_value(preview["pin"].clone()).unwrap();
    assert_eq!(preview["detail"]["manifest"]["owner"], "review-owner");
    assert_eq!(preview["outbound"]["version"]["payload"]["bcc"], json!(["bcc@example.test"]));
    assert_eq!(preview["outbound"]["sending_enabled"], false);
    let staged_eml = request(&h.api, &format!("{base}/staged-download"), json!({"revision":1}))
        .send().await.unwrap();
    assert_eq!(staged_eml.status(), StatusCode::OK);
    let staged_eml = staged_eml.text().await.unwrap();
    assert!(staged_eml.contains("Bcc: bcc@example.test\r\n"));
    assert!(staged_eml.contains("In-Reply-To: <before@example.test>\r\n"));

    let question = preview["outbound"]["review_question"].as_str().unwrap();
    let (group, answer) = {
        let db = h.journal.db().unwrap();
        let group: i64 = db.query_row("INSERT INTO groups(core,name,created_at)
            VALUES('fixture-core','Text Review',1) RETURNING id", [], |row| row.get(0)).unwrap();
        let form = json!({"title":question,"fields":[
            {"key":"verdict","label":"Verdict","choices":["Approve copy","Revise"]}
        ]}).to_string();
        assert!(crate::group_forms::Form::parse(&form).is_ok());
        let q: i64 = db.query_row("INSERT INTO group_messages(group_id,text,author,at_ms,is_question,form_json)
            VALUES(?1,?2,'Fixture reviewer',1,1,?3) RETURNING id",
            params![group, question, form], |row| row.get(0)).unwrap();
        let answer: i64 = db.query_row("INSERT INTO group_messages(group_id,text,at_ms,in_reply_to)
            VALUES(?1,?2,2,?3) RETURNING id", params![group,r#"Form response: {"verdict":"Approve copy"}"#,q],
            |row| row.get(0)).unwrap();
        (group, answer)
    };
    assert_eq!(request(&h.api, &format!("/api/groups/{group}/outbound-text-review"),
        json!({"park":pin.id,"answer":answer})).send().await.unwrap().status(), StatusCode::OK);
    let with_review = h.api.status(&path).await;
    assert_eq!(with_review["outbound"]["text_review"]["answer"], answer);
    assert!(with_review["outbound"]["version"]["approval"].is_null());

    let sign = |purpose, nonce| h.signer.sign_decision(envelope(WORKSPACE, Principal::Operator,
        purpose, Target::Park { park: pin.clone(), policy: policy.clone() }, nonce));
    let original_approval = sign(Purpose::AuthorizeOutbound, "outbound-approval");
    let accepted = response(request(&h.api, "/api/parks/decide", submission(&pin, &original_approval))
        .send().await.unwrap(), StatusCode::OK).await;
    assert_eq!(accepted["result"], "outbound_approved");
    let approval = sign(Purpose::AuthorizeOutbound, "outbound-reapproval");
    let body = submission(&pin, &approval);
    let (approved, edited) = tokio::join!(
        request(&h.api, "/api/parks/decide", body.clone()).send(),
        request(&h.api, &stage, json!({"revision":2,"version":1,"email":email("Replacement copy")})).send(),
    );
    let approval_response = approved.unwrap();
    assert!(matches!(approval_response.status(), StatusCode::OK | StatusCode::CONFLICT), "{approval_response:?}");
    let approved_first = approval_response.status() == StatusCode::OK;
    let replacement = response(edited.unwrap(), StatusCode::OK).await;
    assert_eq!(replacement["version"], 2);
    assert!(replacement["approval"].is_null());
    let old = h.api.status(&path).await;
    assert_eq!(old["detail"]["view"]["status"], "superseded");
    assert_eq!(old["detail"]["superseded_by"], replacement["park"]["id"]);
    let recorded = if approved_first { &approval } else { &original_approval };
    assert_eq!(old["outbound"]["version"]["approval"], serde_json::to_value(recorded).unwrap());
    let next = h.api.status(&format!("/api/parks/{}", replacement["park"]["id"].as_str().unwrap())).await;
    let parsed: Payload = serde_json::from_value(replacement["payload"].clone()).unwrap();
    let expected = parsed.digest().unwrap();
    assert_ne!(initial["payload_digest"], expected);
    assert_eq!(next["detail"]["manifest"]["artifact_pin"], expected);
    assert_eq!(next["detail"]["manifest"]["operation"]["DeliverOutbound"]["payload_digest"], expected);
    assert_eq!(next["outbound"]["version"]["payload_digest"], expected);
    assert!(next["outbound"]["text_review"].is_null());
    assert!(next["outbound"]["version"]["approval"].is_null());
    assert_eq!(request(&h.api, "/api/parks/decide", body).send().await.unwrap().status(), StatusCode::CONFLICT);
    let next_pin: ParkPin = serde_json::from_value(next["pin"].clone()).unwrap();
    assert_eq!(request(&h.api, "/api/parks/decide", submission(&next_pin, &approval))
        .send().await.unwrap().status(), StatusCode::FORBIDDEN);
    let execution_count: i64 = h.journal.db().unwrap().query_row(
        "SELECT count(*) FROM park_executions", [], |row| row.get(0),
    ).unwrap();
    assert_eq!(execution_count, 0);
    let db = h.journal.db().unwrap();
    assert!(db.execute("UPDATE outbound_versions SET payload='{}' WHERE park_id=?1", [&pin.id]).is_err());
    assert!(db.execute("DELETE FROM outbound_approvals WHERE park_id=?1", [&pin.id]).is_err());
}

#[tokio::test]
async fn gapplan_13_int_deployment_with_customer_copy_needs_same_operator_evidence_and_stays_off() {
    use crate::{bots, fleet_policy::tests::JARVIS};
    let h = Harness::new();
    let (_, delegate) = registered_launch(&h.journal, JARVIS, "Fixture reviewer");
    let mut grant = grant();
    grant.scope.action = Some("outside_message".into());
    grant.scope.project = Some("fixture-deploy".into());
    grant.scope.owner = Some("workspace:operator".into());
    let policy = h.signer.publish(h.signer.publication(policy(1, vec![grant]), WORKSPACE)).unwrap();
    let staged = response(request(&h.api, "/api/outbound/stage", json!({
        "version":0, "project":"fixture-deploy", "payload":{
            "channel":"deployment","sender":"fixture-release-account","destination":"fixture-customer-portal",
            "release_revision":"a".repeat(40),"body":"Customer-facing release copy"
        }
    })).send().await.unwrap(), StatusCode::OK).await;
    let path = format!("/api/parks/{}", staged["park"]["id"].as_str().unwrap());
    let preview = h.api.status(&path).await;
    assert_eq!(preview["classification"]["class"], "outside_message");
    assert_eq!(preview["classification"]["required_signers"], json!(["operator"]));
    let pin: ParkPin = serde_json::from_value(preview["pin"].clone()).unwrap();
    let target = Target::Park { park: pin.clone(), policy };
    let park: ParkRef = serde_json::from_value(staged["park"].clone()).unwrap();
    let reviewer = h.signer.sign_decision(envelope(WORKSPACE,
        Principal::Bot { id: JARVIS.into(), launch: delegate.clone() }, Purpose::Execute, target.clone(), "reviewer-deploy",
    ));
    let blocked = bots::answer(&h.workspace, Ok("fixture-core".into()), &delegate, bots::Ask::Park {
        command: Box::new(parks::Command::Judge { park: park.clone(), signed: reviewer })
    }).await.unwrap_err();
    assert!(blocked.contains("operator decision"), "{blocked}");
    let approve = h.signer.sign_decision(envelope(WORKSPACE,
        Principal::Operator, Purpose::AuthorizeOutbound, target.clone(), "operator-deploy",
    ));
    for _ in 0..2 {
        let decision = response(request(&h.api, "/api/parks/decide", submission(&pin, &approve))
            .send().await.unwrap(), StatusCode::OK).await;
        assert_eq!(decision["result"], "outbound_approved");
    }
    let human = h.signer.sign_decision(envelope(WORKSPACE,
        Principal::Operator, Purpose::Execute, target, "operator-execute-deploy",
    ));
    let run = response(request(&h.api, "/api/parks/decide", submission(&pin, &human))
        .send().await.unwrap(), StatusCode::OK).await;
    assert_eq!(run, json!({"result":"held","reason":"outbound_disabled"}));
    let db = h.journal.db().unwrap();
    assert_eq!(parks::status(&db, &park).unwrap(), parks::View::Status(parks::State::Pending));
    let counts: (i64, i64) = db.query_row(
        "SELECT (SELECT count(*) FROM outbound_approvals),(SELECT count(*) FROM park_executions)",
        [], |row| Ok((row.get(0)?, row.get(1)?)),
    ).unwrap();
    assert_eq!(counts, (1, 0));
}

#[tokio::test]
async fn gapplan_13_int_edit_keeps_an_in_flight_snapshot_and_opens_a_new_park() {
    let h = Harness::new();
    let base = format!("{LEGACY}{}", seed_legacy(&h.journal.db().unwrap(), &h.owner_launch));
    let stage = format!("{base}/stage");
    let first = response(request(&h.api, &stage, json!({"revision":1,"version":0,"email":email("In flight")}))
        .send().await.unwrap(), StatusCode::OK).await;
    let old = first["park"]["id"].as_str().unwrap();
    h.journal.db().unwrap().execute("UPDATE parks SET state='executing' WHERE id=?1", [old]).unwrap();
    let next = response(request(&h.api, &stage, json!({"revision":1,"version":1,"email":email("Later edit")}))
        .send().await.unwrap(), StatusCode::OK).await;
    assert_eq!(next["in_flight"], json!([{"version":1,"park":old,"state":"executing"}]));
    assert_eq!(next["state"], "pending");
    assert!(next["approval"].is_null());
    let original = h.api.status(&format!("/api/parks/{old}")).await;
    assert_eq!(original["outbound"]["version"]["payload"]["body"], "In flight");
    assert!(original["detail"]["superseded_by"].is_null());
}

#[test]
fn gapplan_13_int_v59_fresh_upgrade_and_two_reopens_preserve_legacy_draft() {
    use std::{fs, os::unix::fs::{DirBuilderExt, OpenOptionsExt}};
    let scratch = tempfile::tempdir().unwrap();
    let seeded = scratch.path().join("seeded");
    fs::DirBuilder::new().mode(0o700).create(&seeded).unwrap();
    let path = seeded.join("workspace.sqlite3");
    fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).unwrap();
    let old = history::connection(&path).unwrap();
    for migration in &history::migrations()[..58] {
        old.execute_batch(migration).unwrap();
    }
    assert_eq!(schema(&old), 58);
    let launch: String = old.query_row(
        "INSERT INTO journal(launch_key,core_id,agent,kind,state,text,at_ms)
         VALUES('fixture-launch','fixture-core','review-owner','task','pending','fixture',1)
         RETURNING launch_key", [], |row| row.get(0),
    ).unwrap();
    let id = seed_legacy(&old, &launch);
    old.execute("UPDATE email_drafts SET state='reviewed',revision=2 WHERE message=?1", [id]).unwrap();
    let park = parks::file(&old, "preexisting-v58-park", &super::manifest()).unwrap();
    drop(old);
    for (path, seeded) in [(seeded, true), (scratch.path().join("fresh"), false)] {
        for _ in 0..3 {
            let journal = reopen_journal(&path);
            let db = journal.db().unwrap();
            assert_eq!(schema(&db), 59);
            for table in ["outbound_drafts", "outbound_versions", "outbound_approvals", "outbound_text_reviews", "job_review_closures"] {
                let count: i64 = db.query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get(0)).unwrap();
                assert_eq!(count, 0, "{table}");
            }
            if seeded {
                let state: (String, i64, String) = db.query_row(
                    "SELECT state,revision,body FROM email_drafts WHERE message=?1", [id],
                    |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
                ).unwrap();
                assert_eq!(state, ("reviewed".into(), 2, "Original copy".into()));
                assert_eq!(parks::status(&db, &park).unwrap(), parks::View::Status(parks::State::Pending));
            }
        }
    }
}
