use crate::{
    ApiError, Workspace,
    core::Failure,
    history::{History, StoreError, now},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
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
    sync::Arc,
};

#[derive(Clone)]
pub struct Vault {
    key: Arc<aead::LessSafeKey>,
    fingerprint: digest::Digest,
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
            key: Arc::new(aead::LessSafeKey::new(key)),
            fingerprint: digest::digest(&digest::SHA256, &raw),
        }
    }
    pub fn configured() -> Result<Option<Self>, Box<dyn std::error::Error>> {
        let Some(path) = std::env::var_os("SWARMHUB_VAULT_KEY_FILE") else {
            return Ok(None);
        };
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
        Ok(Some(Self {
            key: Arc::new(aead::LessSafeKey::new(key)),
            fingerprint,
        }))
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
    ) -> Result<([u8; 12], Vec<u8>), StoreError> {
        let mut nonce = [0; 12];
        SystemRandom::new()
            .fill(&mut nonce)
            .map_err(|_| StoreError)?;
        let mut box_bytes = value.into_bytes();
        self.key
            .seal_in_place_append_tag(
                aead::Nonce::assume_unique_for_key(nonce),
                aead::Aad::from(scope(id, revision, name)),
                &mut box_bytes,
            )
            .map_err(|_| StoreError)?;
        Ok((nonce, box_bytes))
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
        let row = db
            .query_row(
                "SELECT id,name,revision,nonce,ciphertext FROM vault_secrets WHERE name=?1",
                [name],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                        row.get::<_, Vec<u8>>(3)?,
                        row.get::<_, Vec<u8>>(4)?,
                    ))
                },
            )
            .optional()
            .map_err(StoreError::from)?;
        let Some((id, name, revision, nonce, mut bytes)) = row else {
            return Ok(None);
        };
        let nonce = aead::Nonce::try_assume_unique_for_key(&nonce).map_err(|_| StoreError)?;
        let data = self
            .key
            .open_in_place(
                nonce,
                aead::Aad::from(scope(&id, revision, &name)),
                &mut bytes,
            )
            .map_err(|_| StoreError)?;
        let text = std::str::from_utf8(data).map_err(|_| StoreError)?;
        Ok(Some((text.into(), id, revision)))
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
        self.check(&tx)?;
        tx.execute(
            "INSERT INTO vault_key VALUES (1,?1) ON CONFLICT(singleton) DO NOTHING",
            [self.fingerprint.as_ref()],
        )
        .map_err(StoreError::from)?;
        let existing = tx
            .query_row(
                "SELECT id,name,revision FROM vault_secrets WHERE name=?1",
                [name],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, i64>(2)?,
                    ))
                },
            )
            .optional()
            .map_err(StoreError::from)?;
        let (id, name, revision) = if let Some((id, name, revision)) = existing {
            (id, name, revision.checked_add(1).ok_or(StoreError)?)
        } else {
            (
                tx.query_row("SELECT lower(hex(randomblob(16)))", [], |row| row.get(0))
                    .map_err(StoreError::from)?,
                name.to_owned(),
                1,
            )
        };
        let (nonce, data) = self.seal(&id, revision, &name, value)?;
        tx.execute("INSERT INTO vault_secrets (id,name,revision,updated_ms,nonce,ciphertext) VALUES (?1,?2,?3,?4,?5,?6)
            ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,updated_ms=excluded.updated_ms,nonce=excluded.nonce,ciphertext=excluded.ciphertext",
            params![id,name,revision,now(),nonce.as_slice(),data]).map_err(StoreError::from)?;
        tx.commit().map_err(StoreError::from)?;
        Ok(())
    }

    pub(crate) fn remove_connector(&self, history: &History, name: &str) -> Result<(), ApiError> {
        let db = history.db()?;
        self.check(&db)?;
        db.execute("DELETE FROM vault_secrets WHERE name=?1", [name])
            .map_err(StoreError::from)?;
        Ok(())
    }
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
        .route("/api/vault/{id}/remove", post(remove))
        .layer(DefaultBodyLimit::max(32 * 1024))
}

async fn list(State(w): State<Workspace>) -> Result<Json<serde_json::Value>, ApiError> {
    let Some(vault) = w.vault else {
        return Ok(Json(serde_json::json!({"configured":false,"entries":[]})));
    };
    let db = w.history.db()?;
    vault.check(&db)?;
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

async fn create(
    State(w): State<Workspace>,
    Json(body): Json<Create>,
) -> Result<(StatusCode, Json<Entry>), ApiError> {
    let vault = w.vault.ok_or(DISABLED)?;
    let name = body.name.trim();
    if !valid_name(name) {
        return Err(Failure::Input(
            "Use a name of 1–80 letters, numbers, spaces, dots, dashes, or underscores.",
        )
        .into());
    }
    validate_value(&body.value)?;
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    vault.check(&tx)?;
    tx.execute(
        "INSERT INTO vault_key VALUES (1,?1) ON CONFLICT(singleton) DO NOTHING",
        [vault.fingerprint.as_ref()],
    )
    .map_err(StoreError::from)?;
    let id: String = tx
        .query_row("SELECT lower(hex(randomblob(16)))", [], |row| row.get(0))
        .map_err(StoreError::from)?;
    let (nonce, data) = vault.seal(&id, 1, name, body.value)?;
    let row = tx.query_row(
        "INSERT INTO vault_secrets (id,name,revision,updated_ms,nonce,ciphertext) VALUES (?1,?2,1,?3,?4,?5)
         ON CONFLICT(name) DO NOTHING RETURNING id,name,revision,updated_ms",
         params![id,name,now(),nonce.as_slice(),data],entry,
    ).optional().map_err(StoreError::from)?.ok_or(ApiError::Conflict("That name is already in the vault."))?;
    tx.commit().map_err(StoreError::from)?;
    Ok((StatusCode::CREATED, Json(row)))
}

async fn replace(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    Json(body): Json<Replace>,
) -> Result<Json<Entry>, ApiError> {
    let vault = w.vault.ok_or(DISABLED)?;
    validate_value(&body.value)?;
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    vault.check(&tx)?;
    let name: String = tx
        .query_row(
            "SELECT name FROM vault_secrets WHERE id=?1 AND revision=?2",
            params![id, body.revision],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(CHANGED)?;
    let revision = body.revision.checked_add(1).ok_or(StoreError)?;
    let (nonce, data) = vault.seal(&id, revision, &name, body.value)?;
    let row = tx
        .query_row(
            "UPDATE vault_secrets SET revision=?2,updated_ms=?3,nonce=?4,ciphertext=?5 WHERE id=?1
         RETURNING id,name,revision,updated_ms",
            params![id, revision, now(), nonce.as_slice(), data],
            entry,
        )
        .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(row))
}

async fn remove(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    Json(body): Json<Remove>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let vault = w.vault.ok_or(DISABLED)?;
    let db = w.history.db()?;
    vault.check(&db)?;
    if db
        .execute(
            "DELETE FROM vault_secrets WHERE id=?1 AND revision=?2",
            params![id, body.revision],
        )
        .map_err(StoreError::from)?
        != 1
    {
        return Err(CHANGED);
    }
    Ok(Json(serde_json::json!({"removed":true})))
}
