use super::{job_delivery::{FakeCore, ORIGIN, TestApi, workspace}, reopen_journal, schema};
use crate::{
    fleet_policy::tests::{Fixture, WORKSPACE, policy},
    history,
    machines::probe::{self, Provider, tests::{GB, enrolled, key, project, report, signed}},
};
use serde_json::json;
use std::{fs, fs::OpenOptions, os::unix::fs::{DirBuilderExt, OpenOptionsExt}, process::{Command, Stdio}};

const CHILD: &str = "SWARMHUB_GAPPLAN_06_PROBE_CHILD";
const SWIFT_FIXTURES: &str = "SWARMHUB_GAPPLAN_06_SWIFT_FIXTURES";

fn probe_process(signed: &probe::SignedProbe) -> probe::SignedProbe {
    let mut child = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "fleet_tests::worker_hosts::gapplan_06_int_worker_probe_to_machine_api", "--nocapture"])
        .env(CHILD, "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn().unwrap();
    serde_json::to_writer(child.stdin.take().unwrap(), signed).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let mut lines = std::str::from_utf8(&output.stdout).unwrap().lines().filter(|line| line.starts_with("{"));
    let report = serde_json::from_str(lines.next().expect("one JSON observation")).unwrap();
    assert!(lines.next().is_none());
    report
}

#[tokio::test]
async fn gapplan_06_int_worker_probe_to_machine_api() {
    if std::env::var_os(CHILD).is_some() {
        probe::emit(std::io::stdout().lock()).unwrap();
        return;
    }
    let temp = tempfile::tempdir().unwrap();
    let journal = temp.path().join("journal");
    let history = reopen_journal(&journal);
    let fixture = Fixture::new(temp.path(), WORKSPACE, false);
    let ovh_key = key();
    let ovh = enrolled("ovh", 1, &ovh_key);
    let mut mini = enrolled("mini-m4", 2, &key());
    mini.accounts.insert(Provider::Claude, "fixture-shared-account".into());
    let legacy = json!({"machines":[{"name":"old","target":"fixture@old.invalid","state":"connected","projects":[],"warnings":[]}]});
    let mut w = workspace(temp.path(), history);
    w.fleet_policy = Ok(Some(fixture.authority.clone()));
    let core = FakeCore::start(&temp.path().join("core.sock"));
    let machine = |target: &str| json!({"name":"ovh","target":target,"host":"display-name","state":"connected"});
    core.machines(vec![machine(&ovh.target), legacy["machines"][0].clone()]);
    {
        let db = w.history.db().unwrap();
        project(&db, &ovh);
    }
    let mut publication = policy(1, vec![]);
    publication.workers = vec![ovh.clone(), mini];
    let reference = fixture.publish(fixture.publication(publication, WORKSPACE)).unwrap();
    let api = TestApi::start(temp.path(), &w);
    assert_eq!(api.client.get(format!("{ORIGIN}/api/machines")).send().await.unwrap().status(), 401);
    let path = "/api/machines";
    let initial = api.status(path).await;
    assert_eq!(initial["machines"][0]["worker"]["admission"]["reason"], "probe_missing");
    assert_eq!(initial["machines"][1]["worker"]["admission"]["reason"], "uncommissioned");
    assert_eq!(initial["worker_quota_accounts"], json!([
        {"provider":"claude","account_ref":"fixture-shared-account","worker_ids":["fixture-mini-m4"]},
        {"provider":"codex","account_ref":"fixture-shared-account","worker_ids":["fixture-mini-m4","fixture-ovh"]}
    ]));

    let now = history::now();
    let mut low_disk = report(&ovh, &reference, now);
    low_disk.root_disk.as_mut().unwrap().free_bytes = 7 * GB;
    let captured = probe_process(&signed(low_disk, &ovh_key));
    {
        let mut db = w.history.db().unwrap();
        probe::record(&fixture.authority, &mut db, &captured, now).unwrap();
        probe::record(&fixture.authority, &mut db, &captured, now).unwrap();
        // An older fixture can arrive after STOP. Neither it nor a conflicting same-time
        // sample can replace the latest evidence.
        let older = signed(report(&ovh, &reference, now - 1), &ovh_key);
        probe::record(&fixture.authority, &mut db, &older, now).unwrap();
        let conflict = signed(report(&ovh, &reference, now), &ovh_key);
        assert!(probe::record(&fixture.authority, &mut db, &conflict, now).is_err());
        assert_eq!(db.query_row("SELECT count(*) FROM worker_probes", [], |r| r.get::<_, i64>(0)).unwrap(), 2);
    }
    let payload = api.status(path).await;
    let worker = &payload["machines"][0]["worker"];
    assert_eq!(worker["worker_id"], "fixture-ovh");
    assert_eq!(worker["workload_class"], "heavy");
    assert_eq!(worker["allowed_roots"], json!(["/fixture/work"]));
    assert!(worker["host_fingerprint"].as_str().unwrap().starts_with("SHA256:"));
    assert_eq!(worker["policy"]["digest"], reference.digest);
    assert_eq!(worker["probe"]["observed_ms"], now);
    assert_eq!(worker["probe"]["root_disk"]["filesystem"], "ext4");
    assert_eq!(worker["projects"][0]["project_id"], 1);
    assert_eq!(worker["projects"][0]["admission"], worker["admission"]);
    assert_eq!(worker["admission"]["status"], "stop");
    assert_eq!(worker["admission"]["disk"], json!({"path":"/","free_bytes":7 * GB,"limit_bytes":8 * GB}));
    assert_eq!(payload["machines"][0]["warnings"][0], worker["admission"]["message"]);
    assert!(!payload.to_string().contains(&captured.signature));
    if let Some(directory) = std::env::var_os(SWIFT_FIXTURES) {
        let directory = std::path::PathBuf::from(directory);
        fs::write(directory.join("worker.json"), payload.to_string()).unwrap();
        fs::write(directory.join("legacy.json"), legacy.to_string()).unwrap();
        fs::write(directory.join("probe.json"), serde_json::to_vec(&captured).unwrap()).unwrap();
    }

    core.machines(vec![machine("fixture@different.invalid")]);
    let changed = api.status(path).await;
    assert_eq!(changed["machines"][0]["worker"]["admission"]["reason"], "identity_mismatch");
    assert!(changed["machines"][0]["worker"]["probe"].is_null());

    core.machines(vec![machine(&ovh.target)]);
    let mut next = policy(2, vec![]);
    let other_key = key();
    let mut enrolled_next = enrolled("ovh", 1, &other_key);
    enrolled_next.projects[0].requirements.toolchain = Some("fixture-build-kit".into());
    next.workers = vec![enrolled_next];
    let new_policy = fixture.publish(fixture.publication(next, WORKSPACE)).unwrap();
    let mut db = w.history.db().unwrap();
    assert!(probe::record(&fixture.authority, &mut db, &captured, now).is_err());
    let newer = report(&ovh, &new_policy, now - 1);
    let impersonated = signed(newer.clone(), &ovh_key);
    assert!(probe::record(&fixture.authority, &mut db, &impersonated, now).is_err());
    let mut future = newer.clone();
    future.observed_ms = now + 1;
    assert!(probe::record(&fixture.authority, &mut db, &signed(future, &other_key), now).is_err());
    drop(db);
    assert_eq!(api.status(path).await["machines"][0]["worker"]["admission"]["reason"], "probe_missing");
    let incompatible = signed(newer.clone(), &other_key);
    probe::record(&fixture.authority, &mut w.history.db().unwrap(), &incompatible, now).unwrap();
    assert_eq!(api.status(path).await["machines"][0]["worker"]["admission"]["reason"], "toolchain");
    let mut compatible = newer;
    compatible.observed_ms += 1;
    compatible.toolchains.insert("fixture-build-kit".into());
    let fresh = signed(compatible, &other_key);
    probe::record(&fixture.authority, &mut w.history.db().unwrap(), &fresh, now).unwrap();
    assert_eq!(api.status(path).await["machines"][0]["worker"]["admission"]["status"], "eligible");

    // The journal is an audit copy. An edited observation cannot be shown as current evidence.
    w.history.db().unwrap().execute(
        "UPDATE worker_probes SET signed_probe=json_set(signed_probe,'$.report.signing',json('true'))
         WHERE policy_generation=?1 AND worker_id=?2 AND observed_ms=?3",
        rusqlite::params![new_policy.generation, ovh.id, fresh.report.observed_ms],
    ).unwrap();
    let rejected = api.status(path).await;
    assert_eq!(rejected["machines"][0]["worker"]["admission"]["reason"], "identity_mismatch");
    assert!(rejected["machines"][0]["worker"]["probe"].is_null());
}

#[test]
fn gapplan_06_int_v56_fresh_upgrade_and_reopen_preserve_v55_rows() {
    let temp = tempfile::tempdir().unwrap();
    let fresh = reopen_journal(&temp.path().join("fresh"));
    let before = |db: &rusqlite::Connection| {
        assert_eq!(schema(db), 56);
        for table in ["worker_hosts", "worker_probes"] {
            let count: i64 = db.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap();
            assert_eq!(count, 0);
        }
    };
    before(&fresh.db().unwrap());
    let data = temp.path().join("upgrade");
    fs::DirBuilder::new().mode(0o700).create(&data).unwrap();
    let file = data.join("workspace.sqlite3");
    OpenOptions::new().create_new(true).write(true).mode(0o600).open(&file).unwrap();
    let old = history::connection(&file).unwrap();
    for migration in &history::migrations()[..55] {
        old.execute_batch(migration).unwrap();
    }
    assert_eq!(schema(&old), 55);
    project(&old, &enrolled("ovh", 1, &key()));
    old.execute("INSERT INTO fleet_policy_versions VALUES ('seed-workspace',1,?1,1,'{}')", ["a".repeat(64)]).unwrap();
    let park = crate::parks::file(&old, "seed-park", &crate::parks::tests::manifest()).unwrap();
    old.execute(
        "INSERT INTO park_decisions(park_id,action,actor,source,basis,at_ms)
         VALUES (?1,'hold','operator','human','old plain-text basis',1)",
        [&park.id],
    ).unwrap();
    drop(old);
    for _ in 0..3 {
        let history = reopen_journal(&data);
        let db = history.db().unwrap();
        before(&db);
        assert_eq!(crate::projects::one(&db, 1).unwrap().unwrap().name(), "ovh fixture");
        let row: String = db.query_row("SELECT workspace FROM fleet_policy_versions", [], |r| r.get(0)).unwrap();
        assert_eq!(row, "seed-workspace");
        let basis: String = db.query_row("SELECT basis FROM park_decisions", [], |r| r.get(0)).unwrap();
        assert_eq!(basis, "old plain-text basis");
        let lookup: String = db.query_row(
            "EXPLAIN QUERY PLAN SELECT 1 FROM park_decisions
             WHERE json_extract(CASE WHEN json_valid(basis) THEN basis END,'$.nonce_digest')=?1",
            ["fixture-nonce"], |r| r.get(3),
        ).unwrap();
        assert!(lookup.contains("INDEX park_decisions_by_nonce"), "{lookup}");
    }
}
