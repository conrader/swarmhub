use super::{
    Attempt, Fixture, Launch, ProcessIdentity, Receipt, Result, Worker, digest,
    admission::{Blocker, Exception, Grant, Manifest, RuntimeReceipt},
};
use crate::{fleet_policy::PolicyRef, history};
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Row, TransactionBehavior, params,
    types::Type,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{
    fs::{self, File, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::Duration,
};

const DB: &str = "attempts.sqlite3";
const SCHEMA: &str = "
    CREATE TABLE worker_identity (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        worker TEXT NOT NULL
    );
    CREATE TABLE attempts (
        job_id TEXT NOT NULL,
        attempt INTEGER NOT NULL CHECK (attempt > 0),
        manifest_digest TEXT NOT NULL,
        fixture TEXT NOT NULL,
        start_token TEXT NOT NULL UNIQUE,
        launcher TEXT NOT NULL,
        supervisor TEXT,
        child TEXT,
        status TEXT NOT NULL CHECK (status IN (
            'dispatching','running','unknown','exited','cancelled','interrupted'
        )),
        cancel_requested INTEGER NOT NULL DEFAULT 0 CHECK (cancel_requested IN (0, 1)),
        unknown_reason TEXT,
        receipt TEXT,
        PRIMARY KEY (job_id, attempt),
        CHECK ((status = 'unknown') = (unknown_reason IS NOT NULL)),
        CHECK ((status IN ('exited','cancelled','interrupted')) = (receipt IS NOT NULL)),
        CHECK (status != 'running' OR (supervisor IS NOT NULL AND child IS NOT NULL))
    ) WITHOUT ROWID;
    PRAGMA user_version = 1;
";

const SCHEMA_V2: &str = "
    CREATE TABLE attempt_admission (
        job_id TEXT NOT NULL,
        attempt INTEGER NOT NULL CHECK (attempt > 0),
        manifest_digest TEXT NOT NULL,
        manifest TEXT NOT NULL,
        blocker TEXT,
        policy TEXT,
        account_ref TEXT,
        exception TEXT,
        PRIMARY KEY (job_id, attempt)
    ) WITHOUT ROWID;
    CREATE TABLE leases (
        worker_id TEXT NOT NULL,
        class TEXT NOT NULL CHECK (class = 'heavy'),
        slot INTEGER NOT NULL CHECK (slot >= 0),
        job_id TEXT NOT NULL,
        attempt INTEGER NOT NULL,
        token TEXT NOT NULL UNIQUE REFERENCES attempts(start_token),
        provider TEXT NOT NULL,
        heartbeat_ms INTEGER NOT NULL,
        expires_ms INTEGER NOT NULL CHECK (expires_ms >= heartbeat_ms),
        policy_generation INTEGER NOT NULL CHECK (policy_generation > 0),
        UNIQUE (job_id, attempt),
        PRIMARY KEY (worker_id, class, slot),
        FOREIGN KEY (job_id, attempt) REFERENCES attempts(job_id, attempt)
    ) WITHOUT ROWID;
    PRAGMA user_version = 2;
";

pub(super) const LEASE_MS: i64 = 2_000;

pub(super) struct Run {
    pub launch: Launch,
    pub job_id: String,
    pub manifest: Manifest,
    pub policy: PolicyRef,
    pub account_ref: String,
    pub exception: Option<Exception>,
    pub lease_deadline: i64,
}

pub(super) struct Store {
    pub(super) root: PathBuf,
    db: Connection,
    pub(super) worker: Worker,
}

#[derive(Deserialize, Serialize)]
pub(crate) struct View {
    pub(crate) status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) manifest_digest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) reason: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    admission: Option<Blocker>,
    #[serde(skip_serializing_if = "Option::is_none")]
    policy: Option<PolicyRef>,
    #[serde(skip_serializing_if = "Option::is_none")]
    exception: Option<Exception>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) runtime: Option<RuntimeReceipt>,
    pub(crate) cancel_requested: bool,
    pub(crate) exit_code: Option<i32>,
    pub(crate) exit_signal: Option<i32>,
    pub(crate) log_ref: Option<String>,
    pub(crate) result_ref: Option<String>,
    pub(crate) result_digest: Option<String>,
    result_truncated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    log: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) result: Option<String>,
}

struct Stored {
    manifest_digest: String,
    status: String,
    launcher: ProcessIdentity,
    supervisor: Option<ProcessIdentity>,
    child: Option<ProcessIdentity>,
    cancel_requested: bool,
    unknown_reason: Option<String>,
    receipt: Option<Receipt>,
    admission: Option<Blocker>,
    policy: Option<PolicyRef>,
    exception: Option<Exception>,
}

impl Store {
    pub(super) fn open(root: &Path, expected: Option<&Worker>) -> Result<Self> {
        let root = root.canonicalize()?;
        // SAFETY: geteuid has no memory preconditions.
        let owner = unsafe { libc::geteuid() };
        let dir = fs::metadata(&root)?;
        if !dir.is_dir() || dir.uid() != owner || dir.mode() & 0o077 != 0 {
            return Err("The job worker state directory must belong to this account and be private.".into());
        }
        let file = private_file(&root.join("identity.json"), owner, false)?;
        let mut bytes = Vec::new();
        file.take(1025).read_to_end(&mut bytes)?;
        if bytes.len() > 1024 {
            return Err("Worker identity exceeds 1024 bytes.".into());
        }
        let identity: Worker = serde_json::from_slice(&bytes)?;
        if !identity.valid() || expected.is_some_and(|expected| expected != &identity) {
            return Err("Job worker identity mismatch.".into());
        }

        let path = root.join(DB);
        private_file(&path, owner, expected.is_some())?;
        let mut db = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        db.busy_timeout(Duration::from_secs(5))?;
        db.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
        if version(&db)? < 2 && expected.is_some() {
            let setup = private_file(&root.join("schema.lock"), owner, true)?;
            setup.lock()?;
            // Only public commands initialize or upgrade the ledger. A detached
            // supervisor opens the committed schema after the launcher pins it.
            if version(&db)? < 2 {
                let mode: String = db.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
                if mode != "wal" {
                    return Err("Job worker store could not enable WAL.".into());
                }
            }
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if version(&tx)? == 0 {
                tx.execute_batch(SCHEMA)?;
                tx.execute(
                    "INSERT INTO worker_identity VALUES (1, ?1)",
                    [serde_json::to_string(&identity)?],
                )?;
            }
            if version(&tx)? == 1 {
                tx.execute_batch(SCHEMA_V2)?;
            }
            tx.commit()?;
        }
        if version(&db)? != 2 {
            return Err("Unsupported job worker store schema.".into());
        }
        let stored: Worker = db.query_row(
            "SELECT worker FROM worker_identity WHERE singleton=1",
            [],
            |row| json(row, 0),
        )?;
        if stored != identity {
            return Err("Job worker store belongs to a different worker identity.".into());
        }
        if expected.is_none() {
            db.busy_timeout(Duration::from_millis(250))?;
        }
        Ok(Self { root, db, worker: identity })
    }

    pub(super) fn reserve(
        &mut self,
        attempt: &Attempt,
        manifest_digest: &str,
        manifest: &Manifest,
        launcher: &ProcessIdentity,
        check: impl FnOnce(&Path, &Worker) -> std::result::Result<(Grant, Launch), Blocker>,
    ) -> Result<Option<String>> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing = tx.query_row(
            "SELECT manifest_digest, true FROM attempts WHERE job_id=?1 AND attempt=?2
             UNION ALL SELECT manifest_digest, false FROM attempt_admission WHERE job_id=?1 AND attempt=?2
             LIMIT 1",
            params![attempt.job_id, attempt.number],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, bool>(1)?)),
        ).optional()?;
        if let Some((digest, admitted)) = existing {
            if digest != manifest_digest {
                return Err("Attempt already exists with a different manifest.".into());
            }
            if admitted {
                return Ok(None);
            }
        }

        tx.execute(
            "INSERT INTO attempt_admission(job_id,attempt,manifest_digest,manifest)
             VALUES (?1,?2,?3,?4) ON CONFLICT(job_id,attempt) DO UPDATE
             SET blocker=NULL,policy=NULL,account_ref=NULL,exception=NULL",
            params![attempt.job_id, attempt.number, manifest_digest, serde_json::to_string(manifest)?],
        )?;
        let grant = check(&self.root, &self.worker);
        let reservation = grant.and_then(|(grant, launch)| {
            let now = history::now();
            if grant.heartbeat_deadline <= now {
                return Err(Blocker::stop("policy_heartbeat_lost"));
            }
            if grant.exception.as_ref().is_some_and(|exception| exception.expires_ms <= now) {
                return Err(Blocker::hold("exception_expired"));
            }
            Ok((grant, launch, now))
        });
        let (grant, launch, now) = match reservation {
            Ok(reservation) => reservation,
            Err(blocker) => {
                save_blocker(&tx, attempt, &blocker)?;
                tx.commit()?;
                return Ok(None);
            }
        };

        prune_expired(&tx, now)?;
        let provider = serde_json::to_string(&manifest.provider)?;
        let slots: Vec<(u16, bool)> = tx.prepare(
            "SELECT slot, provider=?2 FROM leases WHERE worker_id=?1 AND class='heavy'",
        )?.query_map(params![self.worker.id, provider], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let slot = (0..grant.heavy_slots).find(|slot| !slots.iter().any(|(used, _)| used == slot));
        let capacity = if legacy_live(&tx)? || slots.len() >= usize::from(grant.heavy_slots) || slot.is_none() {
            Err(Blocker::queue("heavy_slots"))
        } else if slots.iter().filter(|(_, same_provider)| *same_provider).count() >= usize::from(grant.provider_slots) {
            Err(Blocker::queue("provider_slots"))
        } else {
            Ok(slot.expect("available slot"))
        };
        tx.execute(
            "UPDATE attempt_admission SET blocker=NULL,policy=?3,account_ref=?4,exception=?5
             WHERE job_id=?1 AND attempt=?2",
            params![attempt.job_id, attempt.number, serde_json::to_string(&grant.policy)?,
                grant.account_ref, grant.exception.as_ref().map(serde_json::to_string).transpose()?],
        )?;
        let slot = match capacity {
            Ok(slot) => slot,
            Err(blocker) => {
                save_blocker(&tx, attempt, &blocker)?;
                tx.commit()?;
                return Ok(None);
            }
        };
        let token = insert_attempt(&tx, attempt, manifest_digest, launch, launcher)?;
        tx.execute(
            "INSERT INTO leases(worker_id,class,slot,job_id,attempt,token,provider,heartbeat_ms,expires_ms,policy_generation)
             VALUES (?1,'heavy',?2,?3,?4,?5,?6,?7,?8,?9)",
            params![self.worker.id, slot, attempt.job_id, attempt.number, token, provider, now,
                lease_until(now, grant.heartbeat_deadline, grant.exception.as_ref()), grant.policy.generation],
        )?;
        tx.commit()?;
        Ok(Some(token))
    }

    pub(super) fn fence_missing(&mut self, attempt: &Attempt, pin: &str, cancel: bool) -> Result<()> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let exists: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM attempts WHERE job_id=?1 AND attempt=?2
                 UNION ALL SELECT 1 FROM attempt_admission WHERE job_id=?1 AND attempt=?2)",
            params![attempt.job_id, attempt.number], |row| row.get(0),
        )?;
        if !exists {
            let token = insert_attempt(&tx, attempt, pin, Fixture::Success, &ProcessIdentity::current()?)?;
            let mut receipt = Receipt::without_child(cancel);
            receipt.runtime_failure = Some(if cancel { "missing_attempt_cancelled" } else { "start_lost" }.into());
            tx.execute(
                "UPDATE attempts SET status=?2,cancel_requested=?3,receipt=?4 WHERE start_token=?1",
                params![token, if cancel { "cancelled" } else { "interrupted" }, cancel, serde_json::to_string(&receipt)?],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub(super) fn observe(&mut self, attempt: &Attempt, cancel: bool, collect: bool) -> Result<View> {
        Ok(self.observe_bound(attempt, cancel, collect, None, None)?.expect("unbound view"))
    }

    #[cfg(test)]
    pub(super) fn workload_admitted(&mut self, attempt: &Attempt, digest: &str) -> Result<bool> {
        let Some(view) = self.observe_bound(attempt, false, false, Some(digest), None)?
            .filter(|view| view.status == "running" && !view.cancel_requested) else {
            return Ok(false);
        };
        let admitted = self.db.query_row(
            "SELECT b.manifest FROM attempt_admission b JOIN leases l USING(job_id,attempt)
             WHERE l.job_id=?1 AND l.attempt=?2 AND l.expires_ms>?3",
            params![attempt.job_id, attempt.number, history::now()],
            |row| json::<Manifest>(row, 0),
        ).optional()?;
        Ok(admitted.zip(view.policy).is_some_and(|(manifest, policy)| {
            super::Admission::open(&self.root).is_ok_and(|admission| {
                admission.check(&self.worker, &attempt.job_id, &manifest, Some(&policy)).is_ok()
            })
        }))
    }

    pub(super) fn observe_bound(
        &mut self, attempt: &Attempt, cancel: bool, collect: bool,
        expected: Option<&str>, result_digest: Option<&str>,
    ) -> Result<Option<View>> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stored = tx.query_row(
            "SELECT a.manifest_digest,a.status,a.launcher,a.supervisor,a.cancel_requested,
                    a.unknown_reason,a.receipt,b.blocker,b.policy,b.exception,a.child
             FROM attempts a LEFT JOIN attempt_admission b USING(job_id,attempt)
             WHERE a.job_id=?1 AND a.attempt=?2",
            params![attempt.job_id, attempt.number],
            |row| {
                Ok(Stored {
                    manifest_digest: row.get(0)?,
                    status: row.get(1)?,
                    launcher: json(row, 2)?,
                    supervisor: optional_json(row, 3)?,
                    cancel_requested: row.get(4)?,
                    unknown_reason: row.get(5)?,
                    receipt: optional_json(row, 6)?,
                    admission: optional_json(row, 7)?,
                    policy: optional_json(row, 8)?,
                    exception: optional_json(row, 9)?,
                    child: optional_json(row, 10)?,
                })
            },
        ).optional()?;
        let Some(mut stored) = stored else {
            let pending = tx.query_row(
                "SELECT manifest_digest,blocker,policy FROM attempt_admission WHERE job_id=?1 AND attempt=?2",
                params![attempt.job_id, attempt.number],
                |row| Ok((row.get::<_, String>(0)?, json::<Blocker>(row, 1)?, optional_json::<PolicyRef>(row, 2)?)),
            ).optional()?;
            let mut view = View::new(None, collect);
            if let Some((digest, blocker, policy)) = pending {
                if expected.is_some_and(|pin| pin != digest) {
                    return Ok(None);
                }
                if cancel && expected.is_some() {
                    // Pending admission has no start intent. Fence a later start
                    // for this exact manifest before acknowledging cancellation.
                    let token = insert_attempt(&tx, attempt, &digest, Fixture::Success, &ProcessIdentity::current()?)?;
                    let receipt = Receipt::without_child(true);
                    tx.execute(
                        "UPDATE attempts SET status='cancelled',cancel_requested=1,receipt=?2 WHERE start_token=?1",
                        params![token, serde_json::to_string(&receipt)?],
                    )?;
                    tx.execute(
                        "UPDATE attempt_admission SET blocker=NULL WHERE job_id=?1 AND attempt=?2",
                        params![attempt.job_id, attempt.number],
                    )?;
                    tx.commit()?;
                    view.status = "cancelled".into();
                    view.manifest_digest = Some(digest);
                    view.cancel_requested = true;
                    view.policy = policy;
                    return Ok(Some(view));
                }
                view.status = blocker.disposition.as_str().into();
                view.manifest_digest = Some(digest);
                view.reason = Some(blocker.reason.clone());
                view.admission = Some(blocker);
                view.policy = policy;
            }
            return Ok(Some(view));
        };
        if expected.is_some_and(|pin| pin != stored.manifest_digest) {
            return Ok(None);
        }
        if expected.is_some() && stored.child.is_none() && stored.receipt.is_none()
            && stored.supervisor.as_ref().is_some_and(ProcessIdentity::group_ended)
        {
            // The child cannot cross its gate without a durable child pin.
            // The departed supervisor is the only process that could release it.
            let receipt = Receipt::without_child(false);
            tx.execute(
                "UPDATE attempts SET status='interrupted',unknown_reason=NULL,receipt=?3
                 WHERE job_id=?1 AND attempt=?2",
                params![attempt.job_id, attempt.number, serde_json::to_string(&receipt)?],
            )?;
            tx.execute("DELETE FROM leases WHERE job_id=?1 AND attempt=?2", params![attempt.job_id, attempt.number])?;
            stored.status = "interrupted".into();
            stored.unknown_reason = None;
            stored.receipt = Some(receipt);
        }
        if matches!(stored.status.as_str(), "dispatching" | "running") {
            let owner = stored.supervisor.as_ref().unwrap_or(&stored.launcher);
            if !owner.live() {
                let reason = if stored.status == "dispatching" { "start_unconfirmed" } else { "exit_unconfirmed" };
                tx.execute(
                    "UPDATE attempts SET status='unknown',unknown_reason=?3 WHERE job_id=?1 AND attempt=?2",
                    params![attempt.job_id, attempt.number, reason],
                )?;
                stored.status = "unknown".into();
                stored.unknown_reason = Some(reason.into());
            } else if cancel && !stored.cancel_requested {
                tx.execute(
                    "UPDATE attempts SET cancel_requested=1 WHERE job_id=?1 AND attempt=?2",
                    params![attempt.job_id, attempt.number],
                )?;
                stored.cancel_requested = true;
            }
        }
        let result = result_digest.and_then(|expected| {
            let receipt = stored.receipt.as_ref()?;
            let text = receipt.result.as_ref()?;
            (expected == digest(text.as_bytes())).then(|| text.clone())
        });
        tx.commit()?;
        let mut view = View::new(Some(stored), collect);
        if result_digest.is_some() {
            view.result = result;
        }
        Ok(Some(view))
    }

    pub(super) fn start_unconfirmed(&self, token: &str, reason: &str) -> Result<()> {
        self.db.execute(
            "UPDATE attempts SET status='unknown',unknown_reason=?2
             WHERE start_token=?1 AND status='dispatching' AND supervisor IS NULL",
            params![token, reason],
        )?;
        Ok(())
    }

    pub(super) fn run(&self, token: &str, supervisor: &ProcessIdentity) -> Result<Option<Run>> {
        Ok(self.db.query_row(
            "SELECT a.fixture,a.job_id,b.manifest,b.policy,b.account_ref,b.exception,l.expires_ms
             FROM attempts a JOIN attempt_admission b USING(job_id,attempt)
             JOIN leases l ON a.start_token=l.token
             WHERE l.token=?1 AND a.status='dispatching' AND a.supervisor=?2",
            params![token, serde_json::to_string(supervisor)?],
            |row| Ok(Run {
                launch: json(row, 0)?,
                job_id: row.get(1)?,
                manifest: json(row, 2)?,
                policy: json(row, 3)?,
                account_ref: row.get(4)?,
                exception: optional_json(row, 5)?,
                lease_deadline: row.get(6)?,
            }),
        ).optional()?)
    }

    pub(super) fn renew(&mut self, token: &str, run: &Run, grant: &Grant) -> rusqlite::Result<Option<i64>> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let now = history::now();
        let until = lease_until(now, grant.heartbeat_deadline, run.exception.as_ref());
        if until <= now {
            return Ok(None);
        }
        let updated = tx.execute(
            "UPDATE leases SET heartbeat_ms=?2,expires_ms=?3
             WHERE token=?1 AND policy_generation=?4 AND expires_ms>?2 AND heartbeat_ms<=?2",
            params![token, now, until, run.policy.generation],
        )? == 1;
        tx.commit()?;
        Ok(updated.then_some(until))
    }

    pub(super) fn register_supervisor(&mut self, token: &str, identity: &ProcessIdentity) -> Result<Option<Launch>> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // Once pinned, only that supervisor can use the token to load the launch.
        let launch = tx.query_row(
            "UPDATE attempts SET supervisor=?2
             WHERE start_token=?1 AND status='dispatching' AND (supervisor IS NULL OR supervisor=?2)
             RETURNING fixture",
            params![token, serde_json::to_string(identity)?],
            |row| json(row, 0),
        ).optional()?;
        tx.commit()?;
        Ok(launch)
    }

    pub(super) fn register_child(&mut self, token: &str, identity: &ProcessIdentity) -> Result<Option<bool>> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let cancelled = tx.query_row(
            "UPDATE attempts SET child=?2,status='running'
             WHERE start_token=?1 AND status='dispatching' AND supervisor IS NOT NULL
             RETURNING cancel_requested",
            params![token, serde_json::to_string(identity)?],
            |row| row.get(0),
        ).optional()?;
        tx.commit()?;
        Ok(cancelled)
    }

    pub(super) fn cancel_pending(&self, token: &str) -> rusqlite::Result<bool> {
        self.db.query_row(
            "SELECT cancel_requested FROM attempts WHERE start_token=?1",
            [token],
            |row| row.get(0),
        )
    }

    pub(super) fn record_stop(&self, token: &str, reason: &Blocker) {
        // Never leave the fixture running because the ledger is temporarily busy.
        // Finalization records the same evidence again, together with the receipt.
        let _ = write_stop(&self.db, token, reason);
    }

    pub(super) fn finish(
        &mut self, token: &str, receipt: &Receipt, stop: Option<&Blocker>, group_ended: bool,
    ) -> Result<()> {
        let status = if stop.is_some() {
            "interrupted"
        } else if receipt.cancelled {
            "cancelled"
        } else if receipt.signal.is_some() {
            "interrupted"
        } else {
            "exited"
        };
        self.db.busy_timeout(Duration::from_secs(5))?;
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "UPDATE attempts SET status=?2,receipt=?3,unknown_reason=NULL
             WHERE start_token=?1 AND status IN ('dispatching','running','unknown')",
            params![token, status, serde_json::to_string(receipt)?],
        )?;
        if changed != 1 {
            return Err("The fixture supervisor lost ownership of this attempt.".into());
        }
        if let Some(stop) = stop {
            write_stop(&tx, token, stop)?;
        }
        if group_ended {
            tx.execute("DELETE FROM leases WHERE token=?1", [token])?;
        }
        tx.commit()?;
        Ok(())
    }
}

fn write_stop(db: &Connection, token: &str, stop: &Blocker) -> Result<()> {
    db.execute(
        "UPDATE attempt_admission SET blocker=?2 WHERE (job_id,attempt)=(
            SELECT job_id,attempt FROM attempts WHERE start_token=?1
        )",
        params![token, serde_json::to_string(stop)?],
    )?;
    Ok(())
}

fn insert_attempt(
    tx: &Connection, attempt: &Attempt, manifest_digest: &str, launch: impl Into<Launch>, launcher: &ProcessIdentity,
) -> Result<String> {
    Ok(tx.query_row(
        "INSERT INTO attempts(job_id,attempt,manifest_digest,fixture,start_token,launcher,status)
         VALUES (?1,?2,?3,?4,lower(hex(randomblob(16))),?5,'dispatching')
         RETURNING start_token",
        params![attempt.job_id, attempt.number, manifest_digest, serde_json::to_string(&launch.into())?,
            serde_json::to_string(launcher)?],
        |row| row.get(0),
    )?)
}

fn save_blocker(tx: &Connection, attempt: &Attempt, blocker: &Blocker) -> Result<()> {
    tx.execute(
        "UPDATE attempt_admission SET blocker=?3 WHERE job_id=?1 AND attempt=?2",
        params![attempt.job_id, attempt.number, serde_json::to_string(blocker)?],
    )?;
    Ok(())
}

fn lease_until(now: i64, heartbeat: i64, exception: Option<&Exception>) -> i64 {
    (now + LEASE_MS).min(heartbeat).min(exception.map_or(i64::MAX, |exception| exception.expires_ms))
}

fn legacy_live(tx: &Connection) -> Result<bool> {
    let mut query = tx.prepare(
        "SELECT a.launcher,a.supervisor,a.child FROM attempts a
         LEFT JOIN attempt_admission b USING(job_id,attempt)
         WHERE b.job_id IS NULL AND a.status IN ('dispatching','running','unknown')",
    )?;
    let active = query.query_map([], group_owners)?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(active.into_iter().any(|owners| group_unconfirmed(&owners)))
}

fn prune_expired(tx: &Connection, now: i64) -> Result<()> {
    let mut query = tx.prepare(
        "SELECT a.launcher,a.supervisor,a.child,l.token FROM leases l
         JOIN attempts a ON a.start_token=l.token WHERE l.expires_ms<=?1",
    )?;
    let expired = query.query_map([now], |row| Ok((group_owners(row)?, row.get::<_, String>(3)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (owners, token) in expired {
        // A child without a pin cannot have crossed its launch gate. For a
        // pinned supervisor, require proof that its group ended as well.
        let (_, supervisor, child) = &owners;
        if !group_unconfirmed(&owners)
            && (child.is_some() || supervisor.as_ref().is_none_or(ProcessIdentity::group_ended))
        {
            tx.execute("DELETE FROM leases WHERE token=?1", [token])?;
        }
    }
    Ok(())
}

type GroupOwners = (ProcessIdentity, Option<ProcessIdentity>, Option<ProcessIdentity>);

fn group_owners(row: &Row<'_>) -> rusqlite::Result<GroupOwners> {
    Ok((json(row, 0)?, optional_json(row, 1)?, optional_json(row, 2)?))
}

fn group_unconfirmed((launcher, supervisor, child): &GroupOwners) -> bool {
    supervisor.as_ref().unwrap_or(launcher).live()
        || child.as_ref().is_some_and(|child| !child.group_ended())
}

impl View {
    fn new(mut stored: Option<Stored>, collect: bool) -> Self {
        let receipt = stored.as_ref().and_then(|stored| stored.receipt.as_ref());
        let log = receipt.and_then(|receipt| receipt.log.as_ref());
        let result = receipt.and_then(|receipt| receipt.result.as_ref());
        let status = stored.as_ref().map_or("missing", |stored| stored.status.as_str());
        let admission = stored.as_ref().and_then(|stored| stored.admission.clone());
        let stop = admission.as_ref().filter(|_| status == "interrupted");
        let include_text = collect && !receipt.is_some_and(Receipt::provider_run);
        let mut view = Self {
            status: if stop.is_some() { "stopped".into() } else { status.into() },
            manifest_digest: stored.as_ref().map(|stored| stored.manifest_digest.clone()),
            reason: stored.as_ref().and_then(|stored| stored.unknown_reason.clone())
                .or_else(|| stop.map(|blocker| blocker.reason.clone()))
                .or_else(|| receipt.and_then(|receipt| receipt.runtime_failure.clone())),
            admission,
            policy: None,
            exception: None,
            runtime: None,
            cancel_requested: stored.as_ref().is_some_and(|stored| stored.cancel_requested),
            exit_code: receipt.and_then(|receipt| receipt.code),
            exit_signal: receipt.and_then(|receipt| receipt.signal),
            log_ref: log.map(|_| "log".into()),
            result_ref: result.map(|_| "result".into()),
            result_digest: result.map(|text| digest(text.as_bytes())),
            result_truncated: receipt.is_some_and(|receipt| receipt.result_truncated),
            log: log.filter(|_| include_text).cloned(),
            result: result.filter(|_| include_text).cloned(),
        };
        if let Some(stored) = stored.take() {
            view.policy = stored.policy;
            view.exception = stored.exception;
            view.runtime = stored.receipt.and_then(|receipt| receipt.runtime);
        }
        view
    }
}

pub(super) fn private_file(path: &Path, owner: u32, create: bool) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(create)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() || metadata.uid() != owner || metadata.mode() & 0o077 != 0 {
        return Err("Job worker files must belong to this account and be private regular files.".into());
    }
    Ok(file)
}

fn version(db: &Connection) -> rusqlite::Result<u32> {
    db.pragma_query_value(None, "user_version", |row| row.get(0))
}

fn json<T: DeserializeOwned>(row: &Row<'_>, index: usize) -> rusqlite::Result<T> {
    let text: String = row.get(index)?;
    decode(&text, index)
}

fn optional_json<T: DeserializeOwned>(row: &Row<'_>, index: usize) -> rusqlite::Result<Option<T>> {
    let text: Option<String> = row.get(index)?;
    text.as_deref().map(|text| decode(text, index)).transpose()
}

fn decode<T: DeserializeOwned>(text: &str, index: usize) -> rusqlite::Result<T> {
    serde_json::from_str(text)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(index, Type::Text, Box::new(error)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::job_worker::Fixture;
    use crate::job_worker::tests::{Inputs, init};
    use std::os::unix::{fs::PermissionsExt, process::ExitStatusExt};

    fn root() -> tempfile::TempDir {
        tempfile::Builder::new()
            .permissions(fs::Permissions::from_mode(0o700))
            .tempdir()
            .unwrap()
    }

    fn attempt() -> Attempt {
        Attempt { job_id: "fixture-job".into(), number: 1 }
    }

    #[test]
    fn gapplan_07_unit_reservation_replays_only_the_same_manifest() {
        let root = root();
        let input = Inputs::new(root.path(), "mini-m4", vec![]);
        let worker: Worker = serde_json::from_value(input.identity.clone()).unwrap();
        let start = input.started_request("fixture-job", 1);
        let manifest: Manifest = serde_json::from_value(start["manifest"].clone()).unwrap();
        let check = |root: &Path, worker: &Worker| super::super::admission::Admission::open(root).unwrap()
            .check(worker, "fixture-job", &manifest, None).map(|(grant, _)| (grant, Launch::Fixture(Fixture::Success)));
        let mut first = Store::open(root.path(), Some(&worker)).unwrap();
        let mut second = Store::open(root.path(), None).unwrap();
        let launcher = ProcessIdentity::current().unwrap();
        let attempt = attempt();
        let token = first.reserve(&attempt, "manifest-a", &manifest, &launcher, check).unwrap().unwrap();
        assert!(second.reserve(&attempt, "manifest-a", &manifest, &launcher, check).unwrap().is_none());
        assert!(second.reserve(&attempt, "manifest-b", &manifest, &launcher, check).is_err());
        assert!(first.register_supervisor(&token, &launcher).unwrap().is_some());
        let other = ProcessIdentity { birth: "previous process".into(), ..launcher };
        assert!(second.register_supervisor(&token, &other).unwrap().is_none());
        assert!(second.register_supervisor(&token, &launcher).unwrap().is_some());
        assert_eq!(first.register_child(&token, &launcher).unwrap(), Some(false));
        assert_eq!(second.register_child(&token, &launcher).unwrap(), None);
    }

    #[test]
    fn gapplan_07_unit_cancel_after_exit_preserves_the_receipt() {
        let root = root();
        let worker: Worker = serde_json::from_value(init(root.path())).unwrap();
        let mut store = Store::open(root.path(), Some(&worker)).unwrap();
        let process = ProcessIdentity::current().unwrap();
        let attempt = attempt();
        let token = insert_attempt(&store.db, &attempt, "manifest", Fixture::Success, &process).unwrap();
        store.register_supervisor(&token, &process).unwrap();
        store.register_child(&token, &process).unwrap();
        let exit = std::process::ExitStatus::from_raw(0);
        let output = crate::job_worker::Output { log: Some("log".into()), result: Some("result".into()), result_truncated: false };
        store.finish(&token, &Receipt::new(exit, false, output), None, true).unwrap();
        let before = serde_json::to_value(store.observe(&attempt, false, true).unwrap()).unwrap();
        let after = serde_json::to_value(store.observe(&attempt, true, true).unwrap()).unwrap();
        assert_eq!(before, after);
        assert_eq!(after["status"], "exited");
        assert_eq!(after["cancel_requested"], false);
        assert_eq!(after["result"], "result");
    }

    #[test]
    fn gapplan_07_unit_worker_store_reopens_and_checks_identity_and_version() {
        let root = root();
        let worker: Worker = serde_json::from_value(init(root.path())).unwrap();
        let mut store = Store::open(root.path(), Some(&worker)).unwrap();
        assert_eq!(version(&store.db).unwrap(), 2);
        let attempt = attempt();
        assert_eq!(store.observe(&attempt, false, false).unwrap().status, "missing");
        insert_attempt(&store.db, &attempt, "manifest", Fixture::Success, &ProcessIdentity::current().unwrap()).unwrap();
        drop(store);
        for _ in 0..2 {
            let mut reopened = Store::open(root.path(), Some(&worker)).unwrap();
            assert_eq!(reopened.observe(&attempt, false, false).unwrap().status, "dispatching");
        }
        let wrong = Worker { id: "another-worker".into(), ..worker };
        assert!(Store::open(root.path(), Some(&wrong)).is_err());
        // Replacing a local identity file must not rebind an existing ledger.
        fs::write(root.path().join("identity.json"), serde_json::to_vec(&wrong).unwrap()).unwrap();
        assert!(Store::open(root.path(), Some(&wrong)).is_err());
        let db = Connection::open(root.path().join(DB)).unwrap();
        db.pragma_update(None, "user_version", 3).unwrap();
        assert!(Store::open(root.path(), None).err().unwrap().to_string().contains("schema"));
    }
    #[test]
    fn gapplan_08_unit_worker_store_upgrades_v1_and_preserves_its_receipt() {
        let root = root();
        let worker: Worker = serde_json::from_value(init(root.path())).unwrap();
        let owner = unsafe { libc::geteuid() };
        let path = root.path().join(DB);
        private_file(&path, owner, true).unwrap();
        let mut db = Connection::open(&path).unwrap();
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate).unwrap();
        tx.execute_batch(SCHEMA).unwrap();
        tx.execute("INSERT INTO worker_identity VALUES (1,?1)", [serde_json::to_string(&worker).unwrap()]).unwrap();
        let process = ProcessIdentity::current().unwrap();
        let attempt = attempt();
        let token = insert_attempt(&tx, &attempt, "old-manifest", Fixture::Success, &process).unwrap();
        tx.execute(
            "UPDATE attempts SET status='exited',receipt=?2 WHERE start_token=?1",
            params![token, r#"{"code":0,"signal":null,"cancelled":false,"log":"old log","result":"old result","result_truncated":false}"#],
        ).unwrap();
        assert_eq!(version(&tx).unwrap(), 1);
        tx.commit().unwrap();
        drop(db);

        for _ in 0..3 {
            let mut store = Store::open(root.path(), Some(&worker)).unwrap();
            let view = store.observe(&attempt, false, true).unwrap();
            assert_eq!(version(&store.db).unwrap(), 2);
            assert_eq!(view.status, "exited");
            assert_eq!(view.result.as_deref(), Some("old result"));
            assert_eq!(view.manifest_digest.as_deref(), Some("old-manifest"));
            assert!(view.runtime.is_none());
            for table in ["leases", "attempt_admission"] {
                let rows: i64 = store.db.query_row(&format!("SELECT count(*) FROM {table}"), [], |row| row.get(0)).unwrap();
                assert_eq!(rows, 0);
            }
        }
    }

}
