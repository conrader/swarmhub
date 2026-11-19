use super::*;
use crate::{
    fleet_policy::{principals::{Principal, Purpose, Target}, tests::{WORKSPACE, envelope}},
    history,
    job_worker::tests::workload_child,
    parks::{self, Operation, ParkRef},
    vault::{self, workload::{self, Crash, Invocation, Outcome, Setup, Terms}},
};
use std::{
    io::Write,
    os::unix::net::UnixStream,
    process::Child,
};

struct Workload {
    fleet: Fixture,
    executor: PathBuf,
    seed: [u8; 32],
    job: String,
    entry: String,
}

impl Workload {
    async fn new(profile: &str) -> Self {
        let fleet = Fixture::new(Provider::Codex, profile);
        let job = fleet.submit("workload-job", Provider::Codex).await;
        fleet.poll_until(&job, "running").await;
        let executor = fleet.temp.path().join("executor");
        fs::DirBuilder::new().mode(0o700).create(&executor).unwrap();
        let seed = workload::random().unwrap();
        let entry = workload::sentinel(&workload::random::<16>().unwrap());
        Self { fleet, executor, seed, job, entry }
    }

    fn terms(&self, uses: i64) -> Terms {
        let db = self.fleet.bridge.history.db().unwrap();
        let digest = db.query_row("SELECT lease_id FROM job_attempts WHERE job_id=?1 AND attempt=1",
            [&self.job], |row| row.get(0)).unwrap();
        let worker = &self.fleet.worker.inputs.enrollment;
        Terms {
            id: workload::sentinel(&workload::random::<16>().unwrap()),
            job_id: self.job.clone(),
            attempt: 1,
            manifest_digest: digest,
            host_id: worker.id.clone(),
            host_fingerprint: worker.fingerprint(),
            command: workload::command_pin(&self.executor).unwrap(),
            entry_id: self.entry.clone(),
            entry_revision: 1,
            not_before_ms: history::now() - 1_000,
            expires_ms: history::now() + 30_000,
            use_limit: uses,
        }
    }

    async fn signed(&self, terms: Terms) -> Invocation {
        let mut manifest = super::super::manifest();
        manifest.owner = OWNER.into();
        manifest.project = self.fleet.input(Provider::Codex).project.to_string();
        manifest.host = terms.host_id.clone();
        manifest.operation = Operation::UseWorkloadSecret { grant_digest: terms.digest() };
        let id = format!("workload-{}", terms.id);
        let filed = bots::answer(&self.fleet.bridge, Ok("core".into()), key(&self.fleet.owner), Ask::Park {
            command: Box::new(parks::Command::File { id: id.clone(), manifest: Box::new(manifest.clone()) }),
        }).await.unwrap();
        let filed: Value = serde_json::from_str(&filed).unwrap();
        let park = ParkRef { id, manifest_digest: filed["manifest_digest"].as_str().unwrap().into() };
        let signed = self.fleet.worker.inputs.signing().sign_decision(envelope(
            WORKSPACE, Principal::Operator, Purpose::AuthorizeWorkload, Target::Park {
                park: park.pin(&manifest), policy: self.fleet.worker.inputs.reference.clone(),
            }, &format!("consent-{}", terms.id),
        ));
        Invocation { terms, park, signed, id: "call-1".into() }
    }

    fn issue(&self, request: &Invocation) -> Result<(), Box<dyn std::error::Error>> {
        workload::issue(&mut self.fleet.bridge.history.db().unwrap(),
            self.fleet.bridge.fleet_policy.as_ref().unwrap().as_ref().unwrap(), request)
    }

    fn setup(&self) -> Setup {
        let inputs = &self.fleet.worker.inputs;
        Setup {
            journal: self.fleet.bridge.history.file().into(),
            policy_dir: inputs.policy_root.clone(),
            workspace: WORKSPACE.into(),
            host_id: inputs.enrollment.id.clone(),
            host_fingerprint: inputs.enrollment.fingerprint(),
            entry_id: self.entry.clone(),
            entry_revision: 1,
            crash: None,
            authorization_time_ms: None,
        }
    }

    fn executor(&self, root: &Path, setup: &Setup) -> (Child, UnixStream) {
        let (worker, service) = pair();
        let (mut controller, bootstrap) = pair();
        let child = workload_child(root, "_workload-executor", service, bootstrap).unwrap();
        workload::write_frame(&mut controller, setup).unwrap();
        controller.write_all(&self.seed).unwrap();
        (child, worker)
    }

    fn via_worker(&self, call: &Invocation, crash: Option<Crash>) -> (Outcome, i32) {
        let mut setup = self.setup();
        setup.crash = crash;
        let (mut executor, service) = self.executor(&self.executor, &setup);
        let (mut bridge, worker) = pair();
        let mut relay = workload_child(&self.fleet.worker.root, "_workload", worker, service).unwrap();
        workload::write_frame(&mut bridge, call).unwrap();
        let outcome = self.read_outcome(&mut bridge, &self.fleet.worker.root);
        assert!(relay.wait().unwrap().success());
        (outcome, executor.wait().unwrap().code().unwrap())
    }

    fn directly(&self, root: &Path, setup: &Setup, call: &Invocation) -> Outcome {
        let (mut executor, mut service) = self.executor(root, setup);
        workload::write_frame(&mut service, call).unwrap();
        let outcome = self.read_outcome(&mut service, root);
        assert!(executor.wait().unwrap().success());
        outcome
    }

    fn read_outcome(&self, stream: &mut UnixStream, root: &Path) -> Outcome {
        workload::read_frame(stream).unwrap_or_else(|error| {
            let diagnostics = fs::read(root.join("workload-fixture.log")).unwrap_or_default();
            assert_redacted(workload::sentinel(&self.seed).as_bytes(), &diagnostics);
            panic!("Missing fixture outcome ({error}). {}", String::from_utf8_lossy(&diagnostics));
        })
    }

    fn used(&self) -> i64 {
        let db = rusqlite::Connection::open_with_flags(self.executor.join("uses.sqlite3"),
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
        assert_eq!(super::super::schema(&db), 1);
        db.query_row("SELECT count(*) FROM invocations", [], |row| row.get(0)).unwrap()
    }

    fn effects(&self) -> usize {
        fs::read_to_string(self.executor.join("effects")).unwrap_or_default().lines().count()
    }

    async fn finish(&self) -> (JobStatus, String) {
        let fleet = &self.fleet;
        let completed = fleet.poll_until(&self.job, "exited").await;
        let result = job(&fleet.spool, &fleet.owner, Command::Result { id: self.job.clone(), reference: "result".into() })
            .await.unwrap();
        drain(&fleet.bridge).await;
        (completed, result)
    }

    async fn cancel(&self) {
        let fleet = &self.fleet;
        job(&fleet.spool, &fleet.owner, Command::Cancel { id: self.job.clone() }).await.unwrap();
        fleet.poll_until(&self.job, "cancelled").await;
    }
}

fn pair() -> (UnixStream, UnixStream) {
    let (first, second) = UnixStream::pair().unwrap();
    for socket in [&first, &second] {
        socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        socket.set_write_timeout(Some(Duration::from_secs(10))).unwrap();
    }
    (first, second)
}

fn assert_redacted(sentinel: &[u8], bytes: &[u8]) {
    for pattern in [sentinel, &sentinel[1..]] {
        assert!(!bytes.windows(pattern.len()).any(|window| window == pattern),
            "fixture value reached an observable surface");
    }
}

fn scan_dir(sentinel: &[u8], dir: &Path) {
    for entry in fs::read_dir(dir).unwrap() {
        let entry = entry.unwrap();
        let kind = entry.file_type().unwrap();
        if kind.is_dir() {
            scan_dir(sentinel, &entry.path());
        } else if kind.is_file() {
            let Ok(bytes) = fs::read(entry.path()) else { continue };
            assert_redacted(sentinel, &bytes);
        }
    }
}

#[tokio::test]
async fn gapplan_12_int_managed_worker_resolves_in_executor_and_only_outcome_reaches_provider() {
    let f = Workload::new("workload-gate").await;
    let call = f.signed(f.terms(1)).await;
    f.issue(&call).unwrap();
    f.issue(&call).unwrap();
    let (outcome, exit) = f.via_worker(&call, None);
    assert_eq!((outcome, exit), (Outcome::Succeeded, 0));
    assert_eq!(f.via_worker(&call, None), (Outcome::Succeeded, 0));
    assert_eq!(f.effects(), 1);
    assert_eq!(f.used(), 1);

    let outcome_bytes = serde_json::to_vec(&outcome).unwrap();
    let home = f.fleet.worker.root.join("fixture-runtimes/local/home");
    fs::write(home.join("workload-finish"), []).unwrap();
    let (completed, artifact) = f.finish().await;
    assert_eq!(completed.completion.as_ref().unwrap().exit.code, Some(0));
    assert_eq!(fs::read(home.join("workload-received")).unwrap(), outcome_bytes);
    assert_eq!(fs::read(home.join("workload-stdin")).unwrap(), FIXTURE_BRIEF.as_bytes());
    let sentinel = workload::sentinel(&f.seed);
    for channel in ["env", "argv", "stdin", "stdout", "stderr"] {
        let observed = fs::read(home.join(format!("workload-{channel}"))).unwrap();
        assert!(!observed.is_empty(), "missing provider {channel}");
        assert_redacted(sentinel.as_bytes(), &observed);
    }
    // Check the real provider result, the persisted callback-equivalent exit, and
    // the delivered chat/notification with the same redaction assertion.
    assert_eq!(f.fleet.ordinary.writes().len(), 1);
    assert_eq!(f.fleet.remote.calls("collect"), 1);
    let receipts = f.fleet.remote.state.lock().unwrap().collected.clone();
    assert_eq!(receipts.len(), 1);
    let notification = helpers::fixture::ask(&f.fleet.spool, key(&f.fleet.owner),
        Action::Bot(Ask::CompletionAck { id: format!("{}:1", f.job) })).await.unwrap();
    for bytes in [outcome_bytes, artifact.into_bytes(), serde_json::to_vec(&completed).unwrap(),
        serde_json::to_vec(&receipts).unwrap(), serde_json::to_vec(&f.fleet.ordinary.writes()).unwrap(),
        notification.into_bytes()] {
        assert_redacted(sentinel.as_bytes(), &bytes);
    }
    scan_dir(sentinel.as_bytes(), f.fleet.temp.path());
}

#[tokio::test]
async fn gapplan_12_int_other_host_changed_command_and_revoked_or_rotated_consent_are_denied() {
    let f = Workload::new("first_holds").await;
    let call = f.signed(f.terms(2)).await;
    f.issue(&call).unwrap();

    let host_b = f.fleet.temp.path().join("executor-b");
    fs::DirBuilder::new().mode(0o700).create(&host_b).unwrap();
    let mut setup_b = f.setup();
    setup_b.host_id = "host-b".into();
    setup_b.host_fingerprint = format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD
        .encode(workload::random::<32>().unwrap()));
    assert_eq!(f.directly(&host_b, &setup_b, &call), Outcome::Denied);
    assert_eq!(f.directly(&f.executor, &setup_b, &call), Outcome::Denied);
    assert!(!host_b.join("effects").exists());

    let mut rotated = f.setup();
    rotated.entry_revision += 1;
    assert_eq!(f.directly(&f.executor, &rotated, &call), Outcome::Denied);
    let mut forged = call.clone();
    forged.signed.signature = STANDARD.encode([0; 64]);
    assert_eq!(f.directly(&f.executor, &f.setup(), &forged), Outcome::Denied);
    let mut delegated = call.clone();
    delegated.signed.envelope.principal = Principal::Bot {
        id: "fixture-delegate".into(), launch: "a".repeat(32),
    };
    assert!(f.issue(&delegated).is_err());
    assert_eq!(f.directly(&f.executor, &f.setup(), &delegated), Outcome::Denied);
    let mut changed_attempt = call.clone();
    changed_attempt.terms.manifest_digest = "f".repeat(64);
    assert_eq!(f.via_worker(&changed_attempt, None), (Outcome::Denied, 0));

    for change in [
        |pin: &mut workload::CommandPin| pin.executable_sha256 = "f".repeat(64),
        |pin: &mut workload::CommandPin| pin.argv.push("unexpected".into()),
        |pin: &mut workload::CommandPin| pin.cwd.push("other"),
        |pin: &mut workload::CommandPin| pin.executable = "/bin/sh".into(),
    ] {
        let mut terms = f.terms(1);
        change(&mut terms.command);
        let other_command = f.signed(terms).await;
        f.issue(&other_command).unwrap();
        assert_eq!(f.directly(&f.executor, &f.setup(), &other_command), Outcome::Denied);
    }

    let held = f.signed(f.terms(1)).await;
    f.issue(&held).unwrap();
    parks::decide(&mut f.fleet.bridge.history.db().unwrap(), &held.park,
        parks::Decision { actor: "operator", source: parks::Source::Human, basis: "fixture hold" },
        parks::Change::Hold).unwrap();
    assert_eq!(f.directly(&f.executor, &f.setup(), &held), Outcome::Denied);
    assert_eq!(f.used(), 0);
    assert_eq!(f.effects(), 0);
    f.cancel().await;
}

#[tokio::test]
async fn gapplan_13_int_workload_expiry_at_executor_never_reserves_a_use() {
    let f = Workload::new("first_holds").await;
    let call = f.signed(f.terms(2)).await;
    f.issue(&call).unwrap();
    let mut setup = f.setup();
    setup.authorization_time_ms = Some(call.terms.expires_ms);
    assert_eq!(f.directly(&f.executor, &setup, &call), Outcome::Denied);
    assert_eq!(f.used(), 0);
    assert_eq!(f.effects(), 0);
    assert_eq!(f.directly(&f.executor, &f.setup(), &call), Outcome::Succeeded);
    assert_eq!(f.used(), 1);
    f.cancel().await;
}

#[tokio::test]
async fn gapplan_13_int_workload_policy_revocation_denies_even_fresh_signature() {
    let f = Workload::new("first_holds").await;
    let mut call = f.signed(f.terms(2)).await;
    f.issue(&call).unwrap();
    let mut next = f.fleet.worker.inputs.signing().authority.with_review_policy(Clone::clone).unwrap();
    next.generation += 1;
    next.revoked.insert(call.terms.id.clone());
    let signer = f.fleet.worker.inputs.signing();
    let deadline = std::time::Instant::now() + WAIT;
    let reference = loop {
        match signer.publish(signer.publication(next.clone(), WORKSPACE)) {
            Ok(reference) => break reference,
            Err(crate::fleet_policy::Error::Busy) if std::time::Instant::now() < deadline => {
                tokio::task::yield_now().await;
            }
            Err(error) => panic!("could not revoke workload policy: {error}"),
        }
    };
    assert_eq!(f.directly(&f.executor, &f.setup(), &call), Outcome::Denied);
    let mut envelope = call.signed.envelope.clone();
    let Target::Park { policy, .. } = &mut envelope.target else { unreachable!() };
    *policy = reference;
    call.signed = signer.sign_decision(envelope);
    let db = f.fleet.bridge.history.db().unwrap();
    let authority = &signer.authority;
    authority.with_park_decision(&*db, &call.park, Purpose::AuthorizeWorkload,
        crate::fleet_policy::Evidence::OperatorSignature(&call.signed), None, |_, proof| {
            assert!(proof.review_policy.revoked.contains(&call.terms.id));
        }).unwrap();
    drop(db);
    assert_eq!(f.directly(&f.executor, &f.setup(), &call), Outcome::Denied);
    assert_eq!(status(&f.fleet.bridge, &f.job).status, "running");
    assert_eq!(f.used(), 0);
    assert_eq!(f.effects(), 0);
    // Updating the current policy stops a running attempt pinned to the earlier generation.
    f.fleet.poll_until(&f.job, "interrupted").await;
}

#[tokio::test]
async fn gapplan_12_int_restart_preserves_spent_uses_on_both_sides_of_command() {
    let f = Workload::new("first_holds").await;
    let mut call = f.signed(f.terms(3)).await;
    f.issue(&call).unwrap();
    for (crash, code, effects) in [(Crash::BeforeCommand, 81, 0), (Crash::AfterCommand, 82, 1)] {
        assert_eq!(f.via_worker(&call, Some(crash)), (Outcome::Uncertain, code));
        assert_eq!(f.effects(), effects);
        assert_eq!(f.via_worker(&call, None), (Outcome::Uncertain, 0));
        assert_eq!(f.effects(), effects);
        call.id.push('x');
    }
    assert_eq!(f.via_worker(&call, None), (Outcome::Succeeded, 0));
    call.id.push('x');
    assert_eq!(f.via_worker(&call, None), (Outcome::Exhausted, 0));
    assert_eq!(f.used(), 3);
    assert_eq!(f.effects(), 2);
    let sentinel = workload::sentinel(&f.seed);
    scan_dir(sentinel.as_bytes(), f.fleet.temp.path());
    f.cancel().await;
}

#[tokio::test]
async fn gapplan_12_int_ordinary_launch_socket_cannot_request_or_exec_workload_entry() {
    let f = Workload::new("first_holds").await;
    let call = f.signed(f.terms(1)).await;
    f.issue(&call).unwrap();
    let mut bridge = f.fleet.bridge.clone();
    let vault = vault::Vault::fixture();
    let token = vault.session(key(&f.fleet.owner), OWNER).unwrap();
    bridge.vault = Some(vault);
    vault::listen(bridge.clone()).unwrap();
    for action in [
        json!({"Request": {"name":"swarmhub_workload_fixture","label":"Fixture","description":"Fixture"}}),
        json!({"Status": {"name":"SWARMHUB_WORKLOAD_FIXTURE"}}),
        json!({"Exec": {"names":["swarmhub_workload_fixture"]}}),
    ] {
        let mut socket = BufReader::new(tokio::net::UnixStream::connect(
            bridge.history.file().with_file_name("vault.sock")).await.unwrap());
        let message = json!({"session":token,"action":action});
        socket.get_mut().write_all(format!("{message}\n").as_bytes()).await.unwrap();
        let mut reply = String::new();
        socket.read_line(&mut reply).await.unwrap();
        assert_redacted(workload::sentinel(&f.seed).as_bytes(), reply.as_bytes());
        assert_eq!(serde_json::from_str::<Value>(&reply).unwrap(), "Unavailable");
    }
    assert!(!f.executor.join("uses.sqlite3").exists());
    f.cancel().await;
}

#[tokio::test]
async fn gapplan_12_int_unpinned_codex_profile_cannot_self_attest_review_identity() {
    let f = Fixture::new(Provider::Codex, "forged-observation");
    let id = f.submit("forged-review-identity", Provider::Codex).await;
    let settled = f.poll_until(&id, "exited").await;
    assert_eq!(settled.completion.unwrap().exit.code, Some(0));
    assert_eq!(settled.review_eligible, Some(false));
    assert!(settled.observed_runtime.unwrap().family.is_none());
}

#[test]
fn gapplan_12_int_v58_fresh_and_seeded_v57_reopen_preserve_rows() {
    let scratch = tempfile::tempdir().unwrap();
    let directory = scratch.path().join("seeded");
    fs::DirBuilder::new().mode(0o700).create(&directory).unwrap();
    let path = directory.join("workspace.sqlite3");
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&path).unwrap();
    let mut old = history::connection(&path).unwrap();
    for migration in &history::migrations()[..57] {
        old.execute_batch(migration).unwrap();
    }
    assert_eq!(super::super::schema(&old), 57);
    bots::register(&old, &bots::Registration {
        id: OWNER.into(), name: Some("Fixture owner".into()), ..Default::default()
    }, 1).unwrap().unwrap();
    let job = jobs_fixture::submit_fixture(&mut old, "existing-v57-job");
    let park = parks::file(&old, "existing-v57-park", &super::super::manifest()).unwrap();
    old.execute("INSERT INTO job_review_lineages VALUES (?1,?2,1,'advance_staging_ref')", params![job.id, OWNER]).unwrap();
    drop(old);
    for (path, seeded) in [(directory, true), (scratch.path().join("fresh"), false)] {
        for _ in 0..3 {
            let journal = reopen_journal(&path);
            let db = journal.db().unwrap();
            assert_eq!(super::super::schema(&db), history::migrations().len());
            let grants: i64 = db.query_row("SELECT count(*) FROM vault_workload_grants", [], |row| row.get(0)).unwrap();
            assert_eq!(grants, 0);
            if seeded {
                assert_eq!(jobs::status(&db, &job.id).unwrap().unwrap().status, "queued");
                assert_eq!(parks::status(&db, &park).unwrap(), parks::View::Status(parks::State::Pending));
                let count: i64 = db.query_row("SELECT count(*) FROM job_review_lineages", [], |row| row.get(0)).unwrap();
                assert_eq!(count, 1);
            }
        }
    }
}
