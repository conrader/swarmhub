//! The fixture controller provisions an executor process over an anonymous socket.
use super::{FIXTURE_ENTRY, super::{Vault, requests::run_workload, version}};
use crate::{
    fleet_policy::{
        Authority, Policy, Verified, WorkerDecision,
        principals::{Actor, Purpose, Signed, hex, identifier},
    },
    history,
    parks::{self, Manifest, Operation, ParkRef},
};
use ring::rand::{SecureRandom, SystemRandom};
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

const FRAME_LIMIT: usize = 8192;
const MAX_USES: i64 = 32;
// These streams deliberately contain both the literal and a transformed value.
// The sole durable effect is a fixed marker in the executor's private cwd.
const SCRIPT: &str = r#"IFS= read -r value && [[ -n "$value" ]] || exit 2
printf 'ran\n' >> effects || exit 3
printf '%s\n' "$value"
printf '%s\n' "${value#?}" >&2
"#;
const UNAVAILABLE: &str = "The fixture workload executor is unavailable.";
const DENIED: &str = "The workload grant does not authorize this invocation.";
const LEDGER: &str = "uses.sqlite3";
const LEDGER_V1: &str = "
CREATE TABLE invocations (
    grant_id TEXT NOT NULL,
    invocation TEXT NOT NULL,
    terms_digest TEXT NOT NULL,
    reserved_ms INTEGER NOT NULL,
    outcome TEXT CHECK (outcome IN ('succeeded','failed')),
    PRIMARY KEY (grant_id, invocation)
) WITHOUT ROWID;
PRAGMA user_version=1;
";

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct CommandPin {
    pub executable: PathBuf,
    pub executable_sha256: String,
    pub argv: Vec<String>,
    pub cwd: PathBuf,
}

pub(crate) fn command_pin(root: &Path) -> Result<CommandPin> {
    // The system interpreter and its canonical path are protected by the OS.
    let executable = Path::new("/bin/bash").canonicalize()?;
    let metadata = fs::metadata(&executable)?;
    if !metadata.is_file() || metadata.uid() != 0 || metadata.mode() & 0o022 != 0 {
        return Err(UNAVAILABLE.into());
    }
    Ok(CommandPin {
        executable_sha256: sha(&fs::read(&executable)?),
        executable,
        argv: vec!["-c".into(), SCRIPT.into()],
        cwd: root.canonicalize()?,
    })
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Terms {
    pub id: String,
    pub job_id: String,
    pub attempt: i64,
    pub manifest_digest: String,
    pub host_id: String,
    pub host_fingerprint: String,
    pub command: CommandPin,
    pub entry_id: String,
    pub entry_revision: i64,
    pub not_before_ms: i64,
    pub expires_ms: i64,
    pub use_limit: i64,
}

impl Terms {
    pub(crate) fn digest(&self) -> String {
        sha(&serde_json::to_vec(&("swarmhub-workload-grant-v1", self)).expect("fixture grant is serializable"))
    }

    fn active(&self, at: i64) -> bool {
        (self.not_before_ms..self.expires_ms).contains(&at)
    }

    fn valid(&self, signed: &Signed) -> bool {
        hex(&self.id, 32) && identifier(&self.job_id) && self.attempt > 0
            && hex(&self.manifest_digest, 64) && hex(&self.entry_id, 32) && self.entry_revision > 0
            && (1..=MAX_USES).contains(&self.use_limit)
            && signed.envelope.issued_ms <= self.not_before_ms
            && self.not_before_ms < self.expires_ms && self.expires_ms <= signed.envelope.expires_ms
    }

    fn consent_current(&self, signed: &Signed, policy: &Policy, at: i64) -> bool {
        self.valid(signed) && self.active(at) && !policy.revoked.contains(&self.id)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Invocation {
    pub terms: Terms,
    pub park: ParkRef,
    pub signed: Signed,
    pub id: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Outcome {
    Denied,
    Exhausted,
    Uncertain,
    Succeeded,
    Failed,
}

fn sha(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn authorize(
    db: &Connection, call: &Invocation, manifest: &Manifest, proof: &Verified,
) -> Result<()> {
    let terms = &call.terms;
    let match_attempt: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM job_attempts a JOIN jobs j ON j.id=a.job_id
         WHERE a.job_id=?1 AND a.attempt=?2 AND a.host_id=?3 AND a.lease_id=?4
         AND a.status IN ('dispatching','running')
         AND json_extract(a.requested_runtime,'$.cancel_requested') IS NOT 1
         AND CAST(j.project AS TEXT)=?5 AND j.owner_bot_id=?6)",
        params![terms.job_id, terms.attempt, terms.host_id, terms.manifest_digest, manifest.project, manifest.owner],
        |row| row.get(0),
    )?;
    let worker_enrolled = proof.review_policy.workers.iter().any(|worker| {
        worker.id == terms.host_id && worker.fingerprint() == terms.host_fingerprint
            && worker.projects.iter().any(|project| project.id.to_string() == manifest.project)
    });
    let worker_allowed = manifest.project.parse().is_ok_and(|project| {
        matches!(proof.review_policy.worker_decision(&terms.job_id, project, &manifest.owner, history::now()),
            WorkerDecision::Admit(_))
    });
    if proof.actor != Actor::Operator || !terms.consent_current(&call.signed, &proof.review_policy, history::now())
        || manifest.operation != (Operation::UseWorkloadSecret { grant_digest: terms.digest() })
        || manifest.host != terms.host_id || !match_attempt || !worker_enrolled || !worker_allowed
        || parks::status(db, &call.park).map_err(|_| DENIED)? != parks::View::Status(parks::State::Pending)
    {
        return Err(DENIED.into());
    }
    Ok(())
}

/// Add a fixture grant to the bridge journal under the existing operator lock.
pub(crate) fn issue(db: &mut Connection, authority: &Authority, call: &Invocation) -> Result<()> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    authority.with_park_decision(tx, &call.park, Purpose::AuthorizeWorkload,
        crate::fleet_policy::Evidence::OperatorSignature(&call.signed), None, |db, proof| {
            let manifest = parks::manifest_for(&db, &call.park).map_err(|_| DENIED)?;
            authorize(&db, call, &manifest, &proof)?;
            if recorded(&db, call, &proof)? {
                return Ok(());
            }
            proof.audit(&db)?;
            let terms = &call.terms;
            db.execute(
                "INSERT INTO vault_workload_grants(id,park_id,park_manifest_digest,job_id,attempt,
                   manifest_digest,host_id,host_fingerprint,command_pin,entry_id,entry_revision,
                   approver,workspace,consent_nonce,not_before_ms,expires_ms,use_limit)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
                params![terms.id,call.park.id,call.park.manifest_digest,terms.job_id,terms.attempt,
                    terms.manifest_digest,terms.host_id,terms.host_fingerprint,serde_json::to_string(&terms.command)?,
                    terms.entry_id,terms.entry_revision,proof.signer_fingerprint,proof.workspace,proof.nonce,
                    terms.not_before_ms,terms.expires_ms,terms.use_limit],
            )?;
            db.commit()?;
            Ok::<_, Box<dyn std::error::Error>>(())
        })?
}

fn recorded(db: &Connection, call: &Invocation, proof: &Verified) -> Result<bool> {
    // The signed park pins the terms. The journal additionally proves that the
    // bridge activated this grant and still records it as authorized.
    Ok(db.query_row(
        "SELECT EXISTS(SELECT 1 FROM vault_workload_grants
         WHERE id=?1 AND park_id=?2 AND park_manifest_digest=?3 AND workspace=?4
           AND consent_nonce=?5 AND approver=?6 AND disposition='authorized')",
        params![call.terms.id, call.park.id, call.park.manifest_digest, proof.workspace,
            proof.nonce, proof.signer_fingerprint],
        |row| row.get(0),
    )?)
}

struct Ledger(Connection);

enum Reservation {
    Fresh,
    Existing(Outcome),
}

impl Ledger {
    fn open(root: &Path) -> Result<Self> {
        let path = root.canonicalize()?.join(LEDGER);
        let file = OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK).open(&path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file() || metadata.nlink() != 1 || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            return Err(UNAVAILABLE.into());
        }
        let mut db = Connection::open_with_flags(
            &path, OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        db.busy_timeout(Duration::from_secs(3))?;
        db.execute_batch("PRAGMA synchronous=FULL;")?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        match tx.query_row("PRAGMA user_version", [], |row| row.get::<_, u32>(0))? {
            0 => tx.execute_batch(LEDGER_V1)?,
            1 => (),
            _ => return Err(UNAVAILABLE.into()),
        }
        tx.commit()?;
        Ok(Self(db))
    }

    fn reserve(&mut self, terms: &Terms, invocation: &str, at: i64) -> Result<Reservation> {
        let tx = self.0.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if !terms.active(at) || !terms.active(history::now()) {
            return Ok(Reservation::Existing(Outcome::Denied));
        }
        let digest = terms.digest();
        let count: i64 = tx.query_row(
            "SELECT count(*) FROM invocations WHERE grant_id=?1", [&terms.id], |row| row.get(0),
        )?;
        let existing: Option<(String, Option<String>)> = tx.query_row(
            "SELECT terms_digest,outcome FROM invocations WHERE grant_id=?1 AND invocation=?2",
            params![terms.id, invocation], |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?;
        if let Some((saved, outcome)) = existing {
            let outcome = if saved != digest {
                Outcome::Denied
            } else {
                match outcome.as_deref() {
                    Some("succeeded") => Outcome::Succeeded,
                    Some("failed") => Outcome::Failed,
                    _ => Outcome::Uncertain,
                }
            };
            return Ok(Reservation::Existing(outcome));
        }
        let changed: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM invocations WHERE grant_id=?1 AND terms_digest!=?2)",
            params![terms.id, digest], |row| row.get(0),
        )?;
        if changed || count >= terms.use_limit {
            return Ok(Reservation::Existing(if changed { Outcome::Denied } else { Outcome::Exhausted }));
        }
        tx.execute(
            "INSERT INTO invocations(grant_id,invocation,terms_digest,reserved_ms) VALUES (?1,?2,?3,?4)",
            params![terms.id, invocation, digest, history::now()],
        )?;
        tx.commit()?;
        Ok(Reservation::Fresh)
    }

    fn settle(&mut self, call: &Invocation, success: bool) -> Result<Outcome> {
        let (state, outcome) = if success { ("succeeded", Outcome::Succeeded) } else { ("failed", Outcome::Failed) };
        let updated = self.0.execute(
            "UPDATE invocations SET outcome=?3 WHERE grant_id=?1 AND invocation=?2 AND outcome IS NULL",
            params![call.terms.id, call.id, state],
        )?;
        if updated != 1 {
            return Err(UNAVAILABLE.into());
        }
        Ok(outcome)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Crash {
    BeforeCommand,
    AfterCommand,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Setup {
    pub journal: PathBuf,
    pub policy_dir: PathBuf,
    pub workspace: String,
    pub host_id: String,
    pub host_fingerprint: String,
    pub entry_id: String,
    pub entry_revision: i64,
    pub crash: Option<Crash>,
}

struct Executor {
    setup: Setup,
    command: CommandPin,
    authority: Authority,
    bridge: Connection,
    vault: Vault,
    entries: Connection,
    ledger: Ledger,
}

impl Executor {
    fn open(root: &Path, setup: Setup, value: String) -> Result<Self> {
        let metadata = fs::symlink_metadata(root)?;
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } || metadata.mode() & 0o077 != 0 {
            return Err(UNAVAILABLE.into());
        }
        let command = command_pin(root)?;
        let authority = Authority::fixture(&setup.policy_dir, &setup.workspace);
        let bridge = Connection::open_with_flags(
            setup.journal.canonicalize()?, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        let entries = Connection::open_in_memory()?;
        entries.execute_batch(include_str!("../../migrate-vault.sql"))?;
        let vault = Vault::fixture_with_key(random()?);
        let sealed = vault.seal(&setup.entry_id, setup.entry_revision, FIXTURE_ENTRY, value).map_err(|_| UNAVAILABLE)?;
        entries.execute(
            "INSERT INTO vault_secrets(id,name,revision,updated_ms,nonce,ciphertext)
             VALUES (?1,?2,?3,?4,?5,?6)",
            params![setup.entry_id, FIXTURE_ENTRY, setup.entry_revision, history::now(), sealed.nonce, sealed.bytes],
        )?;
        sealed.commit();
        Ok(Self { setup, command, authority, bridge, vault, entries, ledger: Ledger::open(root)? })
    }

    fn execute(&mut self, call: &Invocation) -> Outcome {
        let terms = &call.terms;
        if !identifier(&call.id) || terms.host_id != self.setup.host_id
            || terms.host_fingerprint != self.setup.host_fingerprint || terms.command != self.command
        {
            return Outcome::Denied;
        }
        let authority = self.authority.clone();
        authority.with_park_decision(&self.bridge, &call.park, Purpose::AuthorizeWorkload,
            crate::fleet_policy::Evidence::OperatorSignature(&call.signed), None, |bridge, proof| {
                let authorized = (|| {
                    let manifest = parks::manifest_for(bridge, &call.park).map_err(|_| DENIED)?;
                    authorize(bridge, call, &manifest, &proof)?;
                    if !recorded(bridge, call, &proof)? {
                        return Err(DENIED.into());
                    }
                    // A rotated or missing entry must leave the ledger untouched.
                    let entry = version(&self.entries, &terms.entry_id, terms.entry_revision)
                        .map_err(|_| DENIED)?;
                    Ok::<_, Box<dyn std::error::Error>>((manifest, entry))
                })();
                let Ok((manifest, entry)) = authorized else { return Outcome::Denied };
                match self.ledger.reserve(terms, &call.id, history::now()) {
                    Ok(Reservation::Existing(outcome)) => return outcome,
                    Ok(Reservation::Fresh) => (),
                    Err(_) => return Outcome::Uncertain,
                }
                if matches!(self.setup.crash, Some(Crash::BeforeCommand)) {
                    std::process::exit(81);
                }
                if authorize(bridge, call, &manifest, &proof).is_err()
                    || !recorded(bridge, call, &proof).unwrap_or(false)
                {
                    return Outcome::Uncertain;
                }
                let Ok(secret) = self.vault.open(&entry) else { return Outcome::Uncertain };
                let status = run_workload(&self.command.executable, &self.command.argv, &self.command.cwd, secret.as_bytes());
                if matches!(self.setup.crash, Some(Crash::AfterCommand)) {
                    std::process::exit(82);
                }
                status.ok().and_then(|success| self.ledger.settle(call, success).ok()).unwrap_or(Outcome::Uncertain)
            }).unwrap_or(Outcome::Denied)
    }
}

pub(crate) fn serve(
    root: &Path, mut worker: impl Read + Write, mut controller: impl Read,
) -> io::Result<()> {
    let setup = read_frame(&mut controller)?;
    let mut seed = [0; 32];
    controller.read_exact(&mut seed)?;
    drop(controller);
    let value = sentinel(&seed);
    seed.fill(0);
    let mut executor = Executor::open(root, setup, value).map_err(|_| io::Error::other(UNAVAILABLE))?;
    let outcome = match read_frame(&mut worker) {
        Ok(call) => executor.execute(&call),
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
        Err(_) => Outcome::Denied,
    };
    write_frame(&mut worker, &outcome)
}

pub(crate) fn random<const N: usize>() -> Result<[u8; N]> {
    let mut bytes = [0; N];
    SystemRandom::new().fill(&mut bytes).map_err(|_| UNAVAILABLE)?;
    Ok(bytes)
}

pub(crate) fn sentinel(seed: &[u8]) -> String {
    seed.iter().map(|byte| format!("{byte:02x}")).collect()
}

pub(crate) fn read_frame<T: DeserializeOwned>(stream: &mut impl Read) -> io::Result<T> {
    let mut size = [0; 4];
    stream.read_exact(&mut size)?;
    let size = u32::from_be_bytes(size) as usize;
    if size > FRAME_LIMIT {
        return Err(io::Error::other(UNAVAILABLE));
    }
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes)?;
    serde_json::from_slice(&bytes).map_err(|_| io::Error::other(UNAVAILABLE))
}

pub(crate) fn write_frame(stream: &mut impl Write, value: &impl Serialize) -> io::Result<()> {
    let bytes = serde_json::to_vec(value).map_err(|_| io::Error::other(UNAVAILABLE))?;
    if bytes.len() > FRAME_LIMIT {
        return Err(io::Error::other(UNAVAILABLE));
    }
    stream.write_all(&(bytes.len() as u32).to_be_bytes())?;
    stream.write_all(&bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fleet_policy::principals::{Envelope, Principal, Target};
    use std::{sync::{Arc, Barrier}, thread};

    fn terms() -> Terms {
        let at = history::now();
        Terms {
            id: "1".repeat(32),
            job_id: "fixture-job".into(),
            attempt: 1,
            manifest_digest: "2".repeat(64),
            host_id: "fixture-host".into(),
            host_fingerprint: "fixture-fingerprint".into(),
            command: CommandPin {
                executable: "/fixture/command".into(),
                executable_sha256: "3".repeat(64),
                argv: vec!["--fixed".into()],
                cwd: "/fixture/cwd".into(),
            },
            entry_id: "4".repeat(32),
            entry_revision: 1,
            not_before_ms: at - 1000,
            expires_ms: at + 30_000,
            use_limit: 1,
        }
    }

    #[test]
    fn gapplan_12_unit_park_digest_binds_each_grant_field() {
        let terms = terms();
        let original = terms.digest();
        for change in [
            |t: &mut Terms| t.id = "9".repeat(32),
            |t: &mut Terms| t.job_id.push('x'),
            |t: &mut Terms| t.attempt += 1,
            |t: &mut Terms| t.manifest_digest = "0".repeat(64),
            |t: &mut Terms| t.host_id.push('x'),
            |t: &mut Terms| t.host_fingerprint.push('x'),
            |t: &mut Terms| t.command.executable.push("x"),
            |t: &mut Terms| t.command.executable_sha256 = "0".repeat(64),
            |t: &mut Terms| t.command.argv.push("x".into()),
            |t: &mut Terms| t.command.cwd.push("x"),
            |t: &mut Terms| t.entry_id = "0".repeat(32),
            |t: &mut Terms| t.entry_revision += 1,
            |t: &mut Terms| t.not_before_ms += 1,
            |t: &mut Terms| t.expires_ms += 1,
            |t: &mut Terms| t.use_limit += 1,
        ] {
            let mut different = terms.clone();
            change(&mut different);
            assert_ne!(different.digest(), original);
        }
    }

    #[test]
    fn gapplan_12_unit_validity_is_exclusive_and_consent_must_cover_the_grant_window() {
        let mut terms = terms();
        let mut policy = crate::fleet_policy::tests::policy(1, vec![]);
        let signed = Signed {
            envelope: Envelope {
                workspace: "fixture-workspace".into(),
                principal: Principal::Operator,
                purpose: Purpose::AuthorizeWorkload,
                target: Target::Policy { policy: policy.reference().unwrap() },
                nonce: "fixture-nonce".into(),
                issued_ms: terms.not_before_ms,
                expires_ms: terms.expires_ms,
            },
            signature: String::new(),
        };
        assert!(!terms.consent_current(&signed, &policy, terms.not_before_ms - 1));
        assert!(terms.consent_current(&signed, &policy, terms.not_before_ms));
        assert!(terms.consent_current(&signed, &policy, terms.expires_ms - 1));
        assert!(!terms.consent_current(&signed, &policy, terms.expires_ms));
        policy.revoked.insert(terms.id.clone());
        assert!(!terms.consent_current(&signed, &policy, terms.not_before_ms));
        terms.expires_ms += 1;
        assert!(!terms.valid(&signed));
        terms.expires_ms -= 1;
        terms.not_before_ms -= 1;
        assert!(!terms.valid(&signed));
        terms.not_before_ms += 1;
        terms.use_limit = MAX_USES + 1;
        assert!(!terms.valid(&signed));
    }

    #[test]
    fn gapplan_12_unit_concurrent_reservation_counts_spent_and_pending_uses() {
        let scratch = tempfile::tempdir().unwrap();
        let first = Ledger::open(scratch.path()).unwrap();
        let second = Ledger::open(scratch.path()).unwrap();
        let terms = terms();
        let barrier = Arc::new(Barrier::new(2));
        let counts = thread::scope(|scope| {
            let mut callers = Vec::new();
            for (mut ledger, id) in [(first, "first"), (second, "second")] {
                let barrier = Arc::clone(&barrier);
                let terms = &terms;
                callers.push(scope.spawn(move || {
                    barrier.wait();
                    match ledger.reserve(terms, id, history::now()).unwrap() {
                        Reservation::Fresh => [1, 0],
                        Reservation::Existing(Outcome::Exhausted) => [0, 1],
                        _ => panic!("unexpected reservation outcome"),
                    }
                }));
            }
            callers.into_iter().map(|caller| caller.join().unwrap()).collect::<Vec<_>>()
        });
        assert_eq!(counts.iter().map(|count| count[0]).sum::<i32>(), 1);
        assert_eq!(counts.iter().map(|count| count[1]).sum::<i32>(), 1);
        let mut ledger = Ledger::open(scratch.path()).unwrap();
        assert!(matches!(ledger.reserve(&terms, "third", history::now()).unwrap(),
            Reservation::Existing(Outcome::Exhausted)));
        let id: String = ledger.0.query_row("SELECT invocation FROM invocations", [], |row| row.get(0)).unwrap();
        assert!(matches!(ledger.reserve(&terms, &id, history::now()).unwrap(),
            Reservation::Existing(Outcome::Uncertain)));
        assert!(matches!(ledger.reserve(&terms, &id, terms.expires_ms).unwrap(),
            Reservation::Existing(Outcome::Denied)));
    }

    #[test]
    fn gapplan_12_unit_protocol_accepts_only_bounded_typed_executor_outcomes() {
        let mut bytes = vec![];
        write_frame(&mut bytes, &Outcome::Succeeded).unwrap();
        assert_eq!(read_frame::<Outcome>(&mut bytes.as_slice()).unwrap(), Outcome::Succeeded);
        for extra in [serde_json::json!({"outcome":"succeeded","stdout":"free text"}), serde_json::json!("other")] {
            bytes.clear();
            write_frame(&mut bytes, &extra).unwrap();
            assert!(read_frame::<Outcome>(&mut bytes.as_slice()).is_err());
        }
        let oversized = ((FRAME_LIMIT + 1) as u32).to_be_bytes();
        assert!(read_frame::<Outcome>(&mut oversized.as_slice()).is_err());
    }
}
