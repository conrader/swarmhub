use super::{Attempt, Fixture, ProcessIdentity, Receipt, Result, Worker, digest};
use rusqlite::{
    Connection, OpenFlags, OptionalExtension, Row, TransactionBehavior, params,
    types::Type,
};
use serde::{Serialize, de::DeserializeOwned};
use std::{
    fs::{self, File, OpenOptions},
    io::Read,
    os::unix::fs::{MetadataExt, OpenOptionsExt},
    path::{Path, PathBuf},
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

pub(super) struct Store {
    pub(super) root: PathBuf,
    db: Connection,
}

#[derive(Serialize)]
pub(super) struct View {
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    manifest_digest: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reason: Option<String>,
    cancel_requested: bool,
    exit_code: Option<i32>,
    exit_signal: Option<i32>,
    log_ref: Option<&'static str>,
    result_ref: Option<&'static str>,
    result_digest: Option<String>,
    result_truncated: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    log: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<String>,
}

struct Stored {
    manifest_digest: String,
    status: String,
    launcher: ProcessIdentity,
    supervisor: Option<ProcessIdentity>,
    cancel_requested: bool,
    unknown_reason: Option<String>,
    receipt: Option<Receipt>,
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
        private_file(&path, owner, true)?;
        let mut db = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        db.busy_timeout(std::time::Duration::from_secs(2))?;
        db.execute_batch("PRAGMA synchronous=FULL;")?;
        if version(&db)? == 0 {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            if version(&tx)? == 0 {
                tx.execute_batch(SCHEMA)?;
                tx.execute(
                    "INSERT INTO worker_identity VALUES (1, ?1)",
                    [serde_json::to_string(&identity)?],
                )?;
            }
            tx.commit()?;
        }
        if version(&db)? != 1 {
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
        Ok(Self { root, db })
    }

    pub(super) fn reserve(
        &mut self,
        attempt: &Attempt,
        manifest_digest: &str,
        fixture: Fixture,
        launcher: &ProcessIdentity,
    ) -> Result<Option<String>> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let token = tx.query_row(
            "INSERT INTO attempts(job_id,attempt,manifest_digest,fixture,start_token,launcher,status)
             VALUES (?1,?2,?3,?4,lower(hex(randomblob(16))),?5,'dispatching')
             ON CONFLICT(job_id,attempt) DO NOTHING RETURNING start_token",
            params![attempt.job_id, attempt.number, manifest_digest, serde_json::to_string(&fixture)?,
                serde_json::to_string(launcher)?],
            |row| row.get(0),
        ).optional()?;
        if token.is_none() {
            let existing: String = tx.query_row(
                "SELECT manifest_digest FROM attempts WHERE job_id=?1 AND attempt=?2",
                params![attempt.job_id, attempt.number],
                |row| row.get(0),
            )?;
            if existing != manifest_digest {
                return Err("Attempt already exists with a different manifest.".into());
            }
        }
        tx.commit()?;
        Ok(token)
    }

    pub(super) fn observe(&mut self, attempt: &Attempt, cancel: bool, collect: bool) -> Result<View> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let stored = tx.query_row(
            "SELECT manifest_digest,status,launcher,supervisor,cancel_requested,unknown_reason,receipt
             FROM attempts WHERE job_id=?1 AND attempt=?2",
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
                })
            },
        ).optional()?;
        let Some(mut stored) = stored else {
            return Ok(View::new(None, collect));
        };
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
        tx.commit()?;
        Ok(View::new(Some(stored), collect))
    }

    pub(super) fn supervisor_registered(&self, token: &str) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT supervisor IS NOT NULL OR status!='dispatching' FROM attempts WHERE start_token=?1",
            [token],
            |row| row.get(0),
        )?)
    }

    pub(super) fn start_unconfirmed(&self, token: &str) -> Result<()> {
        self.db.execute(
            "UPDATE attempts SET status='unknown',unknown_reason='start_unconfirmed'
             WHERE start_token=?1 AND status='dispatching' AND supervisor IS NULL",
            [token],
        )?;
        Ok(())
    }

    pub(super) fn register_supervisor(&mut self, token: &str, identity: &ProcessIdentity) -> Result<Option<Fixture>> {
        let tx = self.db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let fixture = tx.query_row(
            "UPDATE attempts SET supervisor=?2
             WHERE start_token=?1 AND status='dispatching' AND supervisor IS NULL RETURNING fixture",
            params![token, serde_json::to_string(identity)?],
            |row| json(row, 0),
        ).optional()?;
        tx.commit()?;
        Ok(fixture)
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

    pub(super) fn cancel_pending(&self, token: &str) -> Result<bool> {
        Ok(self.db.query_row(
            "SELECT cancel_requested FROM attempts WHERE start_token=?1",
            [token],
            |row| row.get(0),
        )?)
    }

    pub(super) fn finish(&self, token: &str, receipt: &Receipt) -> Result<()> {
        let status = if receipt.cancelled {
            "cancelled"
        } else if receipt.signal.is_some() {
            "interrupted"
        } else {
            "exited"
        };
        let changed = self.db.execute(
            "UPDATE attempts SET status=?2,receipt=?3,unknown_reason=NULL
             WHERE start_token=?1 AND status IN ('running','unknown') AND child IS NOT NULL",
            params![token, status, serde_json::to_string(receipt)?],
        )?;
        if changed != 1 {
            return Err("The fixture supervisor lost ownership of this attempt.".into());
        }
        Ok(())
    }
}

impl View {
    fn new(stored: Option<Stored>, collect: bool) -> Self {
        let receipt = stored.as_ref().and_then(|stored| stored.receipt.as_ref());
        let log = receipt.and_then(|receipt| receipt.log.as_ref());
        let result = receipt.and_then(|receipt| receipt.result.as_ref());
        Self {
            status: stored.as_ref().map_or_else(|| "missing".into(), |stored| stored.status.clone()),
            manifest_digest: stored.as_ref().map(|stored| stored.manifest_digest.clone()),
            reason: stored.as_ref().and_then(|stored| stored.unknown_reason.clone()),
            cancel_requested: stored.as_ref().is_some_and(|stored| stored.cancel_requested),
            exit_code: receipt.and_then(|receipt| receipt.code),
            exit_signal: receipt.and_then(|receipt| receipt.signal),
            log_ref: log.map(|_| "log"),
            result_ref: result.map(|_| "result"),
            result_digest: result.map(|text| digest(text.as_bytes())),
            result_truncated: receipt.is_some_and(|receipt| receipt.result_truncated),
            log: log.filter(|_| collect).cloned(),
            result: result.filter(|_| collect).cloned(),
        }
    }
}

fn private_file(path: &Path, owner: u32, create: bool) -> Result<File> {
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
    use crate::job_worker::tests::init;
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
        init(root.path());
        let mut first = Store::open(root.path(), None).unwrap();
        let mut second = Store::open(root.path(), None).unwrap();
        let launcher = ProcessIdentity::current().unwrap();
        let attempt = attempt();
        let token = first.reserve(&attempt, "manifest-a", Fixture::Success, &launcher).unwrap().unwrap();
        assert!(second.reserve(&attempt, "manifest-a", Fixture::Success, &launcher).unwrap().is_none());
        assert!(second.reserve(&attempt, "manifest-b", Fixture::Nonzero, &launcher).is_err());
        assert!(first.register_supervisor(&token, &launcher).unwrap().is_some());
        assert!(second.register_supervisor(&token, &launcher).unwrap().is_none());
        assert_eq!(first.register_child(&token, &launcher).unwrap(), Some(false));
        assert_eq!(second.register_child(&token, &launcher).unwrap(), None);
    }

    #[test]
    fn gapplan_07_unit_cancel_after_exit_preserves_the_receipt() {
        let root = root();
        init(root.path());
        let mut store = Store::open(root.path(), None).unwrap();
        let process = ProcessIdentity::current().unwrap();
        let attempt = attempt();
        let token = store.reserve(&attempt, "manifest", Fixture::Success, &process).unwrap().unwrap();
        store.register_supervisor(&token, &process).unwrap();
        store.register_child(&token, &process).unwrap();
        let exit = std::process::ExitStatus::from_raw(0);
        let output = crate::job_worker::Output { log: Some("log".into()), result: Some("result".into()), result_truncated: false };
        store.finish(&token, &Receipt::new(exit, false, output)).unwrap();
        let before = serde_json::to_value(store.observe(&attempt, false, true).unwrap()).unwrap();
        let after = serde_json::to_value(store.observe(&attempt, true, true).unwrap()).unwrap();
        assert_eq!(before, after);
        assert_eq!(after["status"], "exited");
        assert_eq!(after["cancel_requested"], false);
        assert_eq!(after["result"], "result");
    }

    #[test]
    fn gapplan_07_unit_worker_store_v1_reopens_and_checks_identity_and_version() {
        let root = root();
        let worker: Worker = serde_json::from_value(init(root.path())).unwrap();
        let mut store = Store::open(root.path(), Some(&worker)).unwrap();
        assert_eq!(version(&store.db).unwrap(), 1);
        let attempt = attempt();
        assert_eq!(store.observe(&attempt, false, false).unwrap().status, "missing");
        store.reserve(&attempt, "manifest", Fixture::Success, &ProcessIdentity::current().unwrap()).unwrap();
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
        db.pragma_update(None, "user_version", 2).unwrap();
        assert!(Store::open(root.path(), None).err().unwrap().to_string().contains("schema"));
    }
}
