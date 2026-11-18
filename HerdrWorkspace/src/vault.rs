use crate::{
    ApiError, Workspace,
    core::Failure,
    history::{History, StoreError, now},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State, rejection::JsonRejection},
    http::{StatusCode, header},
    routing::{get, post},
};
use ring::{
    aead, digest,
    rand::{SecureRandom, SystemRandom},
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::{
    fs::OpenOptions,
    io::Read,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::Path as FilePath,
    sync::Arc,
};

#[cfg(any(target_os = "macos", test))]
mod keychain;
mod requests;
pub(crate) use requests::{NOTE, SESSION_ENV, USAGE, cli, listen};

pub(crate) const KEY_FILE: &str = "SWARMHUB_VAULT_KEY_FILE";

#[derive(Clone)]
enum Backend {
    File(Arc<aead::LessSafeKey>),
    #[cfg(any(target_os = "macos", test))]
    Keychain(keychain::Keychain),
}

#[derive(Clone)]
pub struct Vault {
    backend: Backend,
    fingerprint: digest::Digest,
    requests: requests::Desk,
}

const LOCKED: ApiError = ApiError::Conflict("The vault key does not match the saved vault.");
const DISABLED: ApiError = ApiError::Conflict("Configure a vault key on the workspace host first.");
const CHANGED: ApiError = ApiError::Conflict("This entry changed. Reopen it before trying again.");
const MASTER_HINT: &str = "The vault key file must contain 64 hexadecimal characters.";
const SECRET_LIMIT: usize = 4096;

impl Vault {
    #[cfg(test)]
    pub(crate) fn fixture() -> Self {
        let raw = [1u8; 32];
        let key = aead::UnboundKey::new(&aead::AES_256_GCM, &raw).expect("fixture key");
        Self {
            backend: Backend::File(Arc::new(aead::LessSafeKey::new(key))),
            fingerprint: digest::digest(&digest::SHA256, &raw),
            requests: requests::Desk::new().expect("fixture Vault requests"),
        }
    }
    pub fn configured(_journal: &FilePath) -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let Some(path) = std::env::var_os(KEY_FILE).filter(|path| !path.is_empty()) else {
            #[cfg(target_os = "macos")]
            {
                let keychain = keychain::Keychain::for_workspace(_journal);
                return Ok(Some(Self {
                    fingerprint: digest::digest(&digest::SHA256, keychain.service().as_bytes()),
                    backend: Backend::Keychain(keychain),
                    requests: requests::Desk::new()?,
                }));
            }
            #[cfg(not(target_os = "macos"))]
            return Ok(None);
        };
        Self::from_file(FilePath::new(&path)).map(Some)
    }

    fn from_file(path: &FilePath) -> Result<Self, Box<dyn std::error::Error>> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(path)
            .map_err(|_| "Could not read the vault key file.")?;
        let metadata = file
            .metadata()
            .map_err(|_| "Could not inspect the vault key file.")?;
        if !metadata.is_file() || metadata.permissions().mode() & 0o077 != 0 {
            return Err("Use a private regular file for the vault key (mode 0600).".into());
        }
        let mut input = String::new();
        file.take(67)
            .read_to_string(&mut input)
            .map_err(|_| MASTER_HINT)?;
        if input.len() > 66 {
            return Err(MASTER_HINT.into());
        }
        let input = input.trim_end_matches(['\r', '\n']);
        if input.len() != 64 || !input.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err(MASTER_HINT.into());
        }
        let mut raw = [0; 32];
        for (i, byte) in raw.iter_mut().enumerate() {
            *byte = u8::from_str_radix(&input[i * 2..i * 2 + 2], 16).map_err(|_| MASTER_HINT)?;
        }
        let fingerprint = digest::digest(&digest::SHA256, &raw);
        let key = aead::UnboundKey::new(&aead::AES_256_GCM, &raw).map_err(|_| MASTER_HINT)?;
        Ok(Self {
            backend: Backend::File(Arc::new(aead::LessSafeKey::new(key))),
            fingerprint,
            requests: requests::Desk::new()?,
        })
    }

    pub(crate) fn session(&self, launch: &str, bot: &str) -> Option<String> {
        self.requests.issue(launch, bot)
    }

    fn check(&self, db: &Connection) -> Result<(), ApiError> {
        let saved = db
            .query_row(
                "SELECT fingerprint FROM vault_key WHERE singleton=1",
                [],
                |row| row.get::<_, Vec<u8>>(0),
            )
            .optional()
            .map_err(StoreError::from)?;
        if saved
            .as_deref()
            .is_some_and(|saved| saved != self.fingerprint.as_ref())
        {
            return Err(LOCKED);
        }
        Ok(())
    }

    fn seal(
        &self,
        id: &str,
        revision: i64,
        name: &str,
        value: String,
    ) -> Result<Sealed, StoreError> {
        let mut nonce = [0; 12];
        SystemRandom::new()
            .fill(&mut nonce)
            .map_err(|_| StoreError)?;
        match &self.backend {
            Backend::File(key) => {
                let mut bytes = value.into_bytes();
                key.seal_in_place_append_tag(
                    aead::Nonce::assume_unique_for_key(nonce),
                    aead::Aad::from(scope(id, revision, name)),
                    &mut bytes,
                )
                .map_err(|_| StoreError)?;
                Ok(Sealed::encrypted(nonce, bytes))
            }
            #[cfg(any(target_os = "macos", test))]
            Backend::Keychain(keychain) => {
                let payload = format!("{}\0{value}", scope(id, revision, name));
                let account = keychain.add(id, &nonce, &payload)?;
                Ok(Sealed {
                    nonce,
                    bytes: keychain::MARKER.to_vec(),
                    pending: Some((keychain.clone(), account)),
                })
            }
        }
    }

    fn open(&self, stored: &Stored) -> Result<String, StoreError> {
        match &self.backend {
            Backend::File(key) => {
                let mut bytes = stored.bytes.clone();
                let nonce = aead::Nonce::try_assume_unique_for_key(&stored.nonce)
                    .map_err(|_| StoreError)?;
                let data = key
                    .open_in_place(
                        nonce,
                        aead::Aad::from(scope(&stored.id, stored.revision, &stored.name)),
                        &mut bytes,
                    )
                    .map_err(|_| StoreError)?;
                Ok(std::str::from_utf8(data)
                    .map_err(|_| StoreError)?
                    .to_owned())
            }
            #[cfg(any(target_os = "macos", test))]
            Backend::Keychain(keychain) if stored.bytes == keychain::MARKER => {
                let payload = keychain.read(&stored.id, &stored.nonce)?;
                let (bound, value) = payload.split_once('\0').ok_or(StoreError)?;
                if bound != scope(&stored.id, stored.revision, &stored.name) {
                    return Err(StoreError);
                }
                Ok(value.to_owned())
            }
            #[cfg(any(target_os = "macos", test))]
            Backend::Keychain(keychain) if stored.bytes == keychain::LEGACY_MARKER => {
                keychain.read(&stored.id, &stored.nonce)
            }
            #[cfg(any(target_os = "macos", test))]
            Backend::Keychain(_) => Err(StoreError),
        }
    }

    fn check_exec_entry(&self, stored: &Stored) -> Result<(), ApiError> {
        #[cfg(any(target_os = "macos", test))]
        if matches!(&self.backend, Backend::Keychain(_)) && stored.bytes == keychain::LEGACY_MARKER {
            return Err(ApiError::Conflict("Replace the value in Vault settings before allowing agent access to this entry."));
        }
        self.open(stored).map(drop).map_err(ApiError::from)
    }

    fn schedule_retirement(&self, _db: &Connection, _stored: &Stored) -> Result<(), StoreError> {
        #[cfg(any(target_os = "macos", test))]
        if matches!(&self.backend, Backend::Keychain(_)) {
            _db.execute(
                "INSERT OR IGNORE INTO vault_keychain_retirements (account) VALUES (?1)",
                [keychain::account(&_stored.id, &_stored.nonce)],
            )?;
        }
        Ok(())
    }

    pub(crate) fn finish_retirements(&self, _db: &Connection) {
        #[cfg(any(target_os = "macos", test))]
        if let Backend::Keychain(keychain) = &self.backend {
            let remove = || -> Result<(), ApiError> {
                self.check(_db)?;
                let mut statement = _db
                    .prepare("SELECT account FROM vault_keychain_retirements")
                    .map_err(StoreError::from)?;
                let accounts = statement
                    .query_map([], |row| row.get::<_, String>(0))
                    .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
                    .map_err(StoreError::from)?;
                for account in accounts {
                    if keychain.remove(&account).is_ok() {
                        _db.execute(
                            "DELETE FROM vault_keychain_retirements WHERE account=?1",
                            [account],
                        )
                        .map_err(StoreError::from)?;
                    }
                }
                Ok(())
            };
            // Failed retirements remain queued for a later retry.
            let _ = remove();
        }
    }

    fn register(&self, db: &Connection) -> Result<(), ApiError> {
        self.check(db)?;
        db.execute(
            "INSERT INTO vault_key VALUES (1,?1) ON CONFLICT(singleton) DO NOTHING",
            [self.fingerprint.as_ref()],
        )
        .map_err(StoreError::from)?;
        Ok(())
    }

    pub fn lookup(&self, history: &History, name: &str) -> Result<Option<String>, ApiError> {
        Ok(self
            .lookup_versioned(history, name)?
            .map(|(secret, _, _)| secret))
    }

    pub(crate) fn lookup_versioned(
        &self,
        history: &History,
        name: &str,
    ) -> Result<Option<(String, String, i64)>, ApiError> {
        let db = history.db()?;
        self.check(&db)?;
        saved(&db, name)?
            .map(|stored| Ok((self.open(&stored)?, stored.id, stored.revision)))
            .transpose()
    }

    pub(crate) fn put_connector(
        &self,
        history: &History,
        name: &str,
        value: String,
    ) -> Result<(), ApiError> {
        validate_value(&value)?;
        let mut db = history.db()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(StoreError::from)?;
        let old = saved(&tx, name)?;
        let (_, sealed) = match &old {
            Some(old) => self.update(&tx, old, &old.name, value)?,
            None => self.create(&tx, name, value)?,
        };
        if let Some(old) = &old {
            self.schedule_retirement(&tx, old)?;
        }
        tx.commit().map_err(StoreError::from)?;
        sealed.commit();
        if let Some(old) = &old {
            self.requests.invalidate(old);
        }
        self.finish_retirements(&db);
        Ok(())
    }

    pub(crate) fn remove_connector(&self, history: &History, name: &str) -> Result<(), ApiError> {
        let mut db = history.db()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(StoreError::from)?;
        self.check(&tx)?;
        let old = saved(&tx, name)?;
        if let Some(old) = &old {
            tx.execute("DELETE FROM vault_secrets WHERE id=?1", [&old.id])
                .map_err(StoreError::from)?;
            self.schedule_retirement(&tx, old)?;
        }
        tx.commit().map_err(StoreError::from)?;
        if let Some(old) = &old {
            self.requests.invalidate(old);
        }
        self.finish_retirements(&db);
        Ok(())
    }

    fn create(
        &self,
        db: &Connection,
        name: &str,
        value: String,
    ) -> Result<(Entry, Sealed), ApiError> {
        self.register(db)?;
        if saved(db, name)?.is_some() {
            return Err(ApiError::Conflict("That name is already in the vault."));
        }
        let id: String = db
            .query_row("SELECT lower(hex(randomblob(16)))", [], |row| row.get(0))
            .map_err(StoreError::from)?;
        let sealed = self.seal(&id, 1, name, value)?;
        let row = db.query_row(
            "INSERT INTO vault_secrets (id,name,revision,updated_ms,nonce,ciphertext) VALUES (?1,?2,1,?3,?4,?5)
             RETURNING id,name,revision,updated_ms",
            params![id,name,now(),sealed.nonce.as_slice(),sealed.bytes],entry,
        ).map_err(StoreError::from)?;
        Ok((row, sealed))
    }

    fn update(
        &self,
        db: &Connection,
        old: &Stored,
        name: &str,
        value: String,
    ) -> Result<(Entry, Sealed), ApiError> {
        self.check(db)?;
        if saved(db, name)?.is_some_and(|existing| existing.id != old.id) {
            return Err(ApiError::Conflict("That name is already in the vault."));
        }
        let revision = old.revision.checked_add(1).ok_or(StoreError)?;
        let sealed = self.seal(&old.id, revision, name, value)?;
        let row = db.query_row(
            "UPDATE vault_secrets SET name=?2,revision=?3,updated_ms=?4,nonce=?5,ciphertext=?6 WHERE id=?1
             RETURNING id,name,revision,updated_ms",
            params![old.id,name,revision,now(),sealed.nonce.as_slice(),sealed.bytes],entry,
        ).map_err(StoreError::from)?;
        Ok((row, sealed))
    }
}

struct Sealed {
    nonce: [u8; 12],
    bytes: Vec<u8>,
    #[cfg(any(target_os = "macos", test))]
    pending: Option<(keychain::Keychain, String)>,
}

impl Sealed {
    fn encrypted(nonce: [u8; 12], bytes: Vec<u8>) -> Self {
        Self {
            nonce,
            bytes,
            #[cfg(any(target_os = "macos", test))]
            pending: None,
        }
    }

    #[cfg(not(any(target_os = "macos", test)))]
    fn commit(self) {}

    #[cfg(any(target_os = "macos", test))]
    fn commit(mut self) {
        self.pending = None;
    }
}

#[cfg(any(target_os = "macos", test))]
impl Drop for Sealed {
    fn drop(&mut self) {
        if let Some((keychain, account)) = self.pending.take() {
            let _ = keychain.remove(&account);
        }
    }
}

#[derive(PartialEq, Eq)]
struct Stored {
    id: String,
    name: String,
    revision: i64,
    nonce: Vec<u8>,
    bytes: Vec<u8>,
}

fn stored(row: &rusqlite::Row<'_>) -> rusqlite::Result<Stored> {
    Ok(Stored {
        id: row.get(0)?,
        name: row.get(1)?,
        revision: row.get(2)?,
        nonce: row.get(3)?,
        bytes: row.get(4)?,
    })
}

fn saved(db: &Connection, name: &str) -> Result<Option<Stored>, StoreError> {
    Ok(db
        .query_row(
            "SELECT id,name,revision,nonce,ciphertext FROM vault_secrets WHERE name=?1",
            [name],
            stored,
        )
        .optional()?)
}

fn version(db: &Connection, id: &str, revision: i64) -> Result<Stored, ApiError> {
    db.query_row(
        "SELECT id,name,revision,nonce,ciphertext FROM vault_secrets WHERE id=?1 AND revision=?2",
        params![id, revision],
        stored,
    )
    .optional()
    .map_err(StoreError::from)?
    .ok_or(CHANGED)
}

fn scope(id: &str, revision: i64, name: &str) -> String {
    format!("swarmhub-vault/v1:{id}:{revision}:{name}")
}

pub(crate) fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name.trim() == name
        && name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b" ._-".contains(&c))
}

fn validate_value(value: &str) -> Result<(), Failure> {
    if value.is_empty() || value.len() > SECRET_LIMIT || value.chars().any(char::is_control) {
        return Err(Failure::Input("Enter a value of 1–4096 bytes on one line."));
    }
    Ok(())
}

#[derive(Serialize)]
struct Entry {
    id: String,
    name: String,
    revision: i64,
    updated_ms: i64,
}

#[derive(Serialize)]
struct Binding {
    name: String,
    used_by: Vec<&'static str>,
    present: bool,
}

fn entry(row: &rusqlite::Row<'_>) -> rusqlite::Result<Entry> {
    Ok(Entry {
        id: row.get(0)?,
        name: row.get(1)?,
        revision: row.get(2)?,
        updated_ms: row.get(3)?,
    })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create {
    name: String,
    value: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Replace {
    value: String,
    revision: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Remove {
    revision: i64,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/vault.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/vault.js"),
                )
            }),
        )
        .route("/api/vault", get(list).post(create))
        .route("/api/vault/{id}/replace", post(replace))
        .route("/api/vault/{id}/rename", post(rename))
        .route("/api/vault/{id}/remove", post(remove))
        .merge(requests::routes())
        .layer(DefaultBodyLimit::max(32 * 1024))
}

async fn list(State(w): State<Workspace>) -> Result<Json<serde_json::Value>, ApiError> {
    let Some(vault) = w.vault else {
        return Ok(Json(serde_json::json!({"configured":false,"entries":[]})));
    };
    let db = w.history.db()?;
    vault.check(&db)?;
    vault.finish_retirements(&db);
    let mut rows = db
        .prepare(
            "SELECT id,name,revision,updated_ms FROM vault_secrets ORDER BY name COLLATE NOCASE",
        )
        .map_err(StoreError::from)?;
    let values = rows
        .query_map([], entry)
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(StoreError::from)?;
    let mut bindings: Vec<Binding> = Vec::new();
    for (name, consumer) in [
        (
            w.drive_files
                .as_ref()
                .and_then(crate::drive_files::Drive::vault_entry),
            "Google Drive",
        ),
        (
            w.connected_files
                .as_ref()
                .and_then(crate::webdav::Folder::vault_entry),
            "Connected files",
        ),
        (
            w.slack
                .as_ref()
                .and_then(crate::slack_events::Signing::vault_entry),
            "Slack events",
        ),
    ] {
        let Some(name) = name else {
            continue;
        };
        if let Some(entry) = bindings
            .iter_mut()
            .find(|entry| entry.name.eq_ignore_ascii_case(name))
        {
            entry.used_by.push(consumer);
        } else {
            bindings.push(Binding {
                name: name.to_owned(),
                used_by: vec![consumer],
                present: values
                    .iter()
                    .any(|entry| entry.name.eq_ignore_ascii_case(name)),
            });
        }
    }
    Ok(Json(
        serde_json::json!({"configured":true,"entries":values,"bindings":bindings}),
    ))
}

fn secret_body<T>(body: Result<Json<T>, JsonRejection>) -> Result<T, ApiError> {
    body.map(|Json(body)| body)
        .map_err(|_| Failure::Input("The vault request is invalid.").into())
}

async fn create(
    State(w): State<Workspace>,
    body: Result<Json<Create>, JsonRejection>,
) -> Result<(StatusCode, Json<Entry>), ApiError> {
    let body = secret_body(body)?;
    let vault = w.vault.ok_or(DISABLED)?;
    let name = checked_name(&body.name)?;
    validate_value(&body.value)?;
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let (row, sealed) = vault.create(&tx, name, body.value)?;
    tx.commit().map_err(StoreError::from)?;
    sealed.commit();
    Ok((StatusCode::CREATED, Json(row)))
}

fn checked_name(name: &str) -> Result<&str, Failure> {
    let name = name.trim();
    if !valid_name(name) {
        return Err(Failure::Input(
            "Use a name of 1–80 letters, numbers, spaces, dots, dashes, or underscores.",
        ));
    }
    Ok(name)
}

async fn replace(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    body: Result<Json<Replace>, JsonRejection>,
) -> Result<Json<Entry>, ApiError> {
    let body = secret_body(body)?;
    validate_value(&body.value)?;
    change(&w, &id, body.revision, None, Some(body.value)).map(Json)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Rename {
    name: String,
    revision: i64,
}

async fn rename(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    body: Result<Json<Rename>, JsonRejection>,
) -> Result<Json<Entry>, ApiError> {
    let body = secret_body(body)?;
    change(
        &w,
        &id,
        body.revision,
        Some(checked_name(&body.name)?),
        None,
    )
    .map(Json)
}

fn change(
    w: &Workspace,
    id: &str,
    revision: i64,
    name: Option<&str>,
    value: Option<String>,
) -> Result<Entry, ApiError> {
    let vault = w.vault.as_ref().ok_or(DISABLED)?;
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    vault.check(&tx)?;
    let old = version(&tx, id, revision)?;
    let value = match value {
        Some(value) => value,
        None => vault.open(&old)?,
    };
    let (row, sealed) = vault.update(&tx, &old, name.unwrap_or(&old.name), value)?;
    vault.schedule_retirement(&tx, &old)?;
    tx.commit().map_err(StoreError::from)?;
    sealed.commit();
    vault.requests.invalidate(&old);
    vault.finish_retirements(&db);
    Ok(row)
}

async fn remove(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    body: Result<Json<Remove>, JsonRejection>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let body = secret_body(body)?;
    let vault = w.vault.ok_or(DISABLED)?;
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    vault.check(&tx)?;
    let old = version(&tx, &id, body.revision)?;
    tx.execute("DELETE FROM vault_secrets WHERE id=?1", [&id])
        .map_err(StoreError::from)?;
    vault.schedule_retirement(&tx, &old)?;
    tx.commit().map_err(StoreError::from)?;
    vault.requests.invalidate(&old);
    vault.finish_retirements(&db);
    Ok(Json(serde_json::json!({"removed":true})))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encrypted_entries_survive_reopen_and_rename_binds_ciphertext_to_new_revision() {
        let dir = tempfile::tempdir().unwrap();
        let history = History::open_at(dir.path()).unwrap();
        let vault = Vault::fixture();
        let value = "synthetic-secret-fixture";
        vault
            .put_connector(&history, "Example", value.into())
            .unwrap();
        let db = history.db().unwrap();
        let old = saved(&db, "example").unwrap().unwrap();
        assert_eq!(old.bytes.len(), value.len() + 16);
        assert!(
            !old.bytes
                .windows(value.len())
                .any(|part| part == value.as_bytes())
        );
        let (new, sealed) = vault
            .update(&db, &old, "Renamed", vault.open(&old).unwrap())
            .unwrap();
        sealed.commit();
        assert_eq!(new.id, old.id);
        assert_eq!(new.revision, 2);
        assert!(version(&db, &old.id, old.revision).is_err());
        let mut tampered = saved(&db, "Renamed").unwrap().unwrap();
        tampered.bytes = old.bytes;
        tampered.nonce = old.nonce;
        assert!(vault.open(&tampered).is_err());
        drop(db);
        drop(history);
        let history = History::open_at(dir.path()).unwrap();
        assert!(vault.lookup(&history, "Example").unwrap().is_none());
        assert_eq!(
            vault.lookup(&history, "Renamed").unwrap().as_deref(),
            Some(value)
        );
        vault.remove_connector(&history, "Renamed").unwrap();
        assert!(vault.lookup(&history, "Renamed").unwrap().is_none());
    }

    #[test]
    fn keychain_backend_scopes_items_and_retires_revisions_with_a_fake_keychain() {
        let dir = tempfile::tempdir().unwrap();
        let other = tempfile::tempdir().unwrap();
        let history = History::open_at(dir.path()).unwrap();
        let keychain = keychain::Keychain::fixture(history.file());
        assert_ne!(keychain.service(), keychain::Keychain::for_workspace(&other.path().join("workspace.sqlite3")).service());
        let vault = Vault {
            fingerprint: digest::digest(&digest::SHA256, keychain.service().as_bytes()),
            backend: Backend::Keychain(keychain.clone()),
            requests: requests::Desk::new().unwrap(),
        };
        let value = "synthetic-keychain-value";
        vault.put_connector(&history, "Example", value.into()).unwrap();
        let db = history.db().unwrap();
        let mut old = saved(&db, "Example").unwrap().unwrap();
        assert_eq!(old.bytes, keychain::MARKER);
        assert_eq!(vault.open(&old).unwrap(), value);
        vault.check_exec_entry(&old).unwrap();
        old.name = "Forged".into();
        assert!(vault.check_exec_entry(&old).is_err());
        old.name = "Example".into();
        old.bytes = keychain::LEGACY_MARKER.to_vec();
        assert!(vault.check_exec_entry(&old).is_err());

        let staged = vault.seal("staged", 1, "Example", value.into()).unwrap();
        assert!(keychain.read("staged", &staged.nonce).is_ok());
        let nonce = staged.nonce;
        drop(staged);
        assert!(keychain.read("staged", &nonce).is_err());

        vault.put_connector(&history, "Example", "synthetic-replacement".into()).unwrap();
        assert!(keychain.read(&old.id, &old.nonce).is_err());
        let new = saved(&db, "Example").unwrap().unwrap();
        assert_eq!(vault.open(&new).unwrap(), "synthetic-replacement");
        vault.remove_connector(&history, "Example").unwrap();
        assert!(keychain.read(&new.id, &new.nonce).is_err());
    }

    #[test]
    fn key_file_rejects_public_modes_and_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("fixture-key");
        let key = "00".repeat(32);
        std::fs::write(&path, key).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(Vault::from_file(&path).is_err());
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        assert!(Vault::from_file(&path).is_ok());
        let alias = dir.path().join("alias");
        std::os::unix::fs::symlink(&path, &alias).unwrap();
        assert!(Vault::from_file(&alias).is_err());
    }
}
