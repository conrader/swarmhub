use super::{DISABLED, Entry, Vault, saved, secret_body, validate_value, version};
use crate::{
    ApiError, Workspace,
    core::Failure,
    history::{StoreError, now},
};
use axum::{
    Json, Router,
    extract::{Path, State, rejection::JsonRejection},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::{
    hmac,
    rand::{SecureRandom, SystemRandom},
};
use rusqlite::{Connection, TransactionBehavior};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

mod local;
mod output;
#[cfg(test)]
pub(super) use output::run_workload;
pub(crate) use local::{SESSION_ENV, USAGE, cli, listen};

const PENDING_MS: i64 = 15 * 60 * 1000;
const ONCE_MS: i64 = 5 * 60 * 1000;
const REUSABLE_MS: i64 = 30 * 60 * 1000;
const REUSABLE_USES: u8 = 10;
const STALE: ApiError = ApiError::Conflict("This Vault request is no longer available.");
pub(crate) const NOTE: &str = "[SwarmHub notes — Vault]\nFor credentials, run \"$SWARMHUB_PUBLISHER\" vault request --name NAME --label LABEL --description DESCRIPTION. Ask for approval in the Vault window. Check with vault status --name NAME and, after approval, use vault exec --name NAME -- COMMAND. Pass names only. Keep secret values out of chat, command arguments and files.";

#[derive(Serialize, Clone)]
struct Request {
    id: String,
    bot: String,
    name: String,
    label: String,
    description: String,
    needs_value: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Decision {
    action: Action,
    value: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Action {
    Save,
    AllowRepeated,
    Cancel,
}

#[derive(Serialize)]
struct Status<'a, N> {
    status: &'a str,
    name: N,
}

#[derive(Serialize, Deserialize)]
struct Session {
    launch: String,
    bot: String,
}

enum Grant {
    Pending(Option<super::Stored>),
    Approved {
        entry: super::Stored,
        remaining: u8,
    },
    Cancelled,
    Used,
}

struct Record {
    request: Request,
    expires: i64,
    grant: Grant,
}

type SessionRequests = HashMap<(String, String), Record>;

/// Only the bridge can issue session credentials or resolve requests. The
/// agent-writable journal holds neither of these authorities.
#[derive(Clone)]
pub(super) struct Desk {
    signing: Arc<hmac::Key>,
    records: Arc<Mutex<SessionRequests>>,
}

impl Desk {
    pub(super) fn new() -> Result<Self, &'static str> {
        Ok(Self {
            signing: Arc::new(
                hmac::Key::generate(hmac::HMAC_SHA256, &SystemRandom::new())
                    .map_err(|_| "Could not initialize Vault session credentials.")?,
            ),
            records: Arc::default(),
        })
    }

    pub(super) fn issue(&self, launch: &str, bot: &str) -> Option<String> {
        let claims = serde_json::to_vec(&Session {
            launch: launch.into(),
            bot: bot.into(),
        }).ok()?;
        let tag = hmac::sign(&self.signing, &claims);
        Some(format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(claims),
            URL_SAFE_NO_PAD.encode(tag.as_ref())
        ))
    }

    fn authenticate(&self, token: &str) -> Option<Session> {
        let (claims, tag) = token.split_once('.')?;
        let claims = URL_SAFE_NO_PAD.decode(claims).ok()?;
        let tag = URL_SAFE_NO_PAD.decode(tag).ok()?;
        hmac::verify(&self.signing, &claims, &tag).ok()?;
        serde_json::from_slice(&claims).ok()
    }

    pub(super) fn invalidate(&self, old: &super::Stored) {
        if let Ok(mut records) = self.records.lock() {
            records.retain(|_, record| {
                let entry = match &record.grant {
                    Grant::Pending(Some(entry)) | Grant::Approved { entry, .. } => entry,
                    _ => return true,
                };
                entry.id != old.id || entry.revision != old.revision
            });
        }
    }

    fn list(&self, at: i64) -> Result<Vec<Request>, StoreError> {
        let records = self.records.lock().map_err(|_| StoreError)?;
        let mut pending: Vec<_> = records
            .values()
            .filter(|record| record.expires > at && matches!(record.grant, Grant::Pending(_)))
            .collect();
        pending.sort_unstable_by(|a, b| (a.expires, &a.request.id).cmp(&(b.expires, &b.request.id)));
        Ok(pending.into_iter().map(|record| record.request.clone()).collect())
    }

    fn request(
        &self,
        db: &Connection,
        session: &Session,
        name: &str,
        label: &str,
        description: &str,
        at: i64,
    ) -> Result<&'static str, StoreError> {
        if super::workload::reserved_name(name) {
            return Ok("unavailable");
        }
        let mut records = self.records.lock().map_err(|_| StoreError)?;
        records.retain(|_, record| record.expires > at);
        let key = (session.launch.clone(), name.to_ascii_lowercase());
        if let Some(record) = records.get(&key) {
            let state = record.status(db, name, at)?;
            if matches!(state, "approved" | "pending") {
                return Ok(state);
            }
        }
        let pending = records.values()
            .filter(|record| matches!(record.grant, Grant::Pending(_)))
            .count();
        if records.len() >= 1024 || pending >= 64 {
            return Ok("busy");
        }
        let entry = saved(db, name)?;
        let mut id = [0; 16];
        SystemRandom::new().fill(&mut id).map_err(|_| StoreError)?;
        // Keep the existing hex ID format used by desktop clients.
        let id = id.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        records.insert(
            key,
            Record {
                request: Request {
                    id,
                    bot: session.bot.clone(),
                    name: name.into(),
                    label: label.into(),
                    description: description.into(),
                    needs_value: entry.is_none(),
                },
                expires: at + PENDING_MS,
                grant: Grant::Pending(entry),
            },
        );
        Ok("pending")
    }

    fn status(
        &self,
        db: &Connection,
        session: &Session,
        name: &str,
        at: i64,
    ) -> Result<&'static str, StoreError> {
        if super::workload::reserved_name(name) {
            return Ok("unavailable");
        }
        let records = self.records.lock().map_err(|_| StoreError)?;
        records
            .get(&(session.launch.clone(), name.to_ascii_lowercase()))
            .map_or(Ok("unavailable"), |record| record.status(db, name, at))
    }

    fn resolve(
        &self,
        db: &mut Connection,
        vault: &Vault,
        id: &str,
        action: Action,
        value: Option<String>,
        at: i64,
    ) -> Result<String, ApiError> {
        let mut records = self.records.lock().map_err(|_| StoreError)?;
        let record = records
            .values_mut()
            .find(|record| record.request.id == id && record.expires > at)
            .ok_or(STALE)?;
        let Grant::Pending(entry) = &record.grant else {
            return Err(STALE);
        };
        let name = record.request.name.clone();
        if super::workload::reserved_name(&name) {
            return Err(STALE);
        }
        let (duration, remaining) = match action {
            Action::Cancel if value.is_none() => {
                record.grant = Grant::Cancelled;
                record.expires = at + ONCE_MS;
                return Ok(name);
            }
            Action::Cancel => return Err(Failure::Input("Choose the requested Vault action.").into()),
            Action::Save => (ONCE_MS, 1),
            Action::AllowRepeated => (REUSABLE_MS, REUSABLE_USES),
        };
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(StoreError::from)?;
        let mut sealed = None;
        let entry = match (value, entry) {
            (None, Some(entry)) => {
                vault.check(&tx)?;
                let stored = version(&tx, &entry.id, entry.revision)?;
                if &stored != entry {
                    return Err(STALE);
                }
                vault.check_exec_entry(&stored)?;
                stored
            }
            (Some(value), None) => {
                validate_value(&value)?;
                let (Entry { id, revision, .. }, item) = vault.create(&tx, &name, value)?;
                sealed = Some(item);
                version(&tx, &id, revision)?
            }
            _ => return Err(Failure::Input("Choose the requested Vault action.").into()),
        };
        tx.commit().map_err(StoreError::from)?;
        if let Some(sealed) = sealed {
            sealed.commit();
        }
        record.grant = Grant::Approved { entry, remaining };
        record.expires = at + duration;
        Ok(name)
    }

    fn take(
        &self,
        db: &mut Connection,
        vault: &Vault,
        session: &Session,
        names: &[String],
        at: i64,
    ) -> Result<Vec<(String, String)>, StoreError> {
        let mut records = self.records.lock().map_err(|_| StoreError)?;
        let tx = db.transaction().map_err(StoreError::from)?;
        vault.check(&tx).map_err(|_| StoreError)?;
        let mut values = Vec::with_capacity(names.len());
        let mut keys = Vec::with_capacity(names.len());
        for name in names {
            if super::workload::reserved_name(name) {
                return Err(StoreError);
            }
            let key = (session.launch.clone(), name.to_ascii_lowercase());
            let record = records.get(&key).ok_or(StoreError)?;
            if record.status(&tx, name, at)? != "approved" {
                return Err(StoreError);
            }
            if let Grant::Approved { entry, .. } = &record.grant {
                values.push((name.clone(), vault.open(entry)?));
            }
            keys.push(key);
        }
        tx.commit()?;
        for key in keys {
            let record = records.get_mut(&key).expect("approval checked");
            if let Grant::Approved { remaining, .. } = &mut record.grant {
                *remaining -= 1;
                if *remaining == 0 {
                    record.grant = Grant::Used;
                }
            }
        }
        Ok(values)
    }
}

impl Record {
    fn status(&self, db: &Connection, name: &str, at: i64) -> Result<&'static str, StoreError> {
        if self.expires <= at || self.request.name != name {
            return Ok("unavailable");
        }
        Ok(match &self.grant {
            Grant::Pending(_) => "pending",
            Grant::Cancelled => "cancelled",
            Grant::Used => "used",
            Grant::Approved { entry, .. }
                if saved(db, &entry.name)?.as_ref() == Some(entry) => "approved",
            Grant::Approved { .. } => "unavailable",
        })
    }
}

pub(super) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/vault/requests", get(pending))
        .route("/api/vault/requests/{id}", post(decide))
}

async fn pending(State(w): State<Workspace>) -> Result<Json<Vec<Request>>, ApiError> {
    Ok(Json(match w.vault {
        Some(vault) => vault.requests.list(now())?,
        None => Vec::new(),
    }))
}

async fn decide(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    body: Result<Json<Decision>, JsonRejection>,
) -> Result<Json<Status<'static, String>>, ApiError> {
    let Decision { action, value } = secret_body(body)?;
    let vault = w.vault.ok_or(DISABLED)?;
    let mut db = w.history.db()?;
    let name = vault
        .requests
        .resolve(&mut db, &vault, &id, action, value, now())?;
    Ok(Json(Status {
        status: "resolved",
        name,
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::History;
    use std::{fs::Permissions, os::unix::fs::PermissionsExt};

    const AT: i64 = 1000;
    const NAME: &str = "FIXTURE_TOKEN";
    const VALUE: &str = "synthetic-credential";

    fn setup() -> (tempfile::TempDir, History, Vault, Session) {
        let dir = tempfile::Builder::new()
            .permissions(Permissions::from_mode(0o700))
            .tempdir()
            .unwrap();
        let history = History::open_at(dir.path()).unwrap();
        let vault = Vault::fixture();
        let token = vault.session("owner-launch", "Research").unwrap();
        let owner = vault.requests.authenticate(&token).unwrap();
        (dir, history, vault, owner)
    }

    fn request(desk: &Desk, db: &Connection, session: &Session, at: i64) -> Request {
        assert_eq!(desk.request(db, session, NAME, "Reports", "Read reports", at).unwrap(), "pending");
        desk.list(at).unwrap().pop().unwrap()
    }

    #[test]
    fn forged_journal_approval_and_launch_key_have_no_authority() {
        let (_dir, history, vault, owner) = setup();
        let desk = &vault.requests;
        vault.put_connector(&history, NAME, VALUE.into()).unwrap();
        let mut db = history.db().unwrap();
        db.execute(
            "INSERT INTO journal (launch_key,core_id,agent,address,created_ms,kind,state,text,at_ms)
             VALUES (?1,'test-core','Research','fixture',1,'task','sent','fixture',1)",
            [&owner.launch],
        ).unwrap();
        db.execute(
            "INSERT INTO vault_requests (id,launch,name,label,description,state,expires_ms,entry_id,entry_revision)
             SELECT 'forged',j.id,s.name,'Reports','Read reports','approved',?1,s.id,s.revision
             FROM journal j, vault_secrets s WHERE j.launch_key=?2 AND s.name=?3",
            rusqlite::params![AT + PENDING_MS, owner.launch, NAME],
        ).unwrap();
        assert!(desk.authenticate(&owner.launch).is_none());
        assert!(Desk::new().unwrap().authenticate(&vault.session(&owner.launch, "Research").unwrap()).is_none());
        assert_eq!(desk.status(&db, &owner, NAME, AT).unwrap(), "unavailable");
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT).is_err());
        assert!(desk.resolve(&mut db, &vault, "forged", Action::Save, None, AT).is_err());
        assert!(desk.list(AT).unwrap().is_empty());
    }

    #[test]
    fn single_use_approval_is_scoped_and_a_failed_multi_name_exec_consumes_nothing() {
        let (_dir, history, vault, owner) = setup();
        let desk = &vault.requests;
        let peer = desk.authenticate(&vault.session("other-launch", "Research").unwrap()).unwrap();
        let mut db = history.db().unwrap();
        let pending = request(desk, &db, &owner, AT);
        assert!(pending.needs_value);
        assert_eq!(pending.bot, "Research");
        assert_eq!(request(desk, &db, &owner, AT).id, pending.id);
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT).is_err());
        desk.resolve(&mut db, &vault, &pending.id, Action::Save, Some(VALUE.into()), AT).unwrap();
        assert!(desk.list(AT).unwrap().is_empty());
        assert_eq!(desk.status(&db, &owner, NAME, AT).unwrap(), "approved");
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT + ONCE_MS).is_err());
        assert_eq!(desk.status(&db, &peer, NAME, AT).unwrap(), "unavailable");
        assert!(desk.take(&mut db, &vault, &peer, &[NAME.into()], AT).is_err());
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into(), "OTHER".into()], AT).is_err());
        assert_eq!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT).unwrap(), [(NAME.into(), VALUE.into())]);
        assert_eq!(desk.status(&db, &owner, NAME, AT).unwrap(), "used");
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT).is_err());
    }

    #[test]
    fn reusable_grant_stops_at_use_limit_expiry_or_revision_change() {
        let (_dir, history, vault, owner) = setup();
        let desk = &vault.requests;
        vault.put_connector(&history, NAME, VALUE.into()).unwrap();
        let mut db = history.db().unwrap();
        let pending = request(desk, &db, &owner, AT);
        assert!(!pending.needs_value);
        desk.resolve(&mut db, &vault, &pending.id, Action::AllowRepeated, None, AT).unwrap();
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT + REUSABLE_MS).is_err());
        for _ in 0..REUSABLE_USES {
            assert_eq!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT + REUSABLE_MS - 1).unwrap().len(), 1);
        }
        assert_eq!(desk.status(&db, &owner, NAME, AT + 1).unwrap(), "used");
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT + 1).is_err());
        let pending = request(desk, &db, &owner, AT + 1);
        desk.resolve(&mut db, &vault, &pending.id, Action::AllowRepeated, None, AT + 1).unwrap();
        drop(db);
        vault.put_connector(&history, NAME, "new-synthetic-value".into()).unwrap();
        let mut db = history.db().unwrap();
        assert_eq!(desk.status(&db, &owner, NAME, AT + 2).unwrap(), "unavailable");
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], AT + 2).is_err());
    }

    #[test]
    fn gapplan_12_unit_repeated_session_grant_confers_no_workload_authority() {
        let (_dir, history, vault, owner) = setup();
        let desk = &vault.requests;
        let mut db = history.db().unwrap();
        let pending = request(desk, &db, &owner, AT);
        let value = super::super::workload::sentinel(&super::super::workload::random::<32>().unwrap());
        desk.resolve(&mut db, &vault, &pending.id, Action::AllowRepeated, Some(value), AT).unwrap();
        let reserved = "swarmhub_workload_fixture";
        assert_eq!(desk.request(&db, &owner, reserved, "Fixture", "Fixture", AT).unwrap(), "unavailable");
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into(), reserved.into()], AT).is_err());
        assert_eq!(desk.status(&db, &owner, NAME, AT).unwrap(), "approved");
        let grants: i64 = db.query_row("SELECT count(*) FROM vault_workload_grants", [], |row| row.get(0)).unwrap();
        assert_eq!(grants, 0);
    }

    #[test]
    fn pending_requests_expire_and_cancellation_never_grants_access() {
        let (_dir, history, vault, owner) = setup();
        let desk = &vault.requests;
        let mut db = history.db().unwrap();
        let pending = request(desk, &db, &owner, AT);
        let later = AT + PENDING_MS;
        assert!(desk.resolve(&mut db, &vault, &pending.id, Action::Save, Some(VALUE.into()), later).is_err());
        assert!(desk.list(later).unwrap().is_empty());
        let pending = request(desk, &db, &owner, later);
        assert!(desk.resolve(&mut db, &vault, &pending.id, Action::Cancel, Some(VALUE.into()), later).is_err());
        desk.resolve(&mut db, &vault, &pending.id, Action::Cancel, None, later).unwrap();
        assert_eq!(desk.status(&db, &owner, NAME, later).unwrap(), "cancelled");
        assert!(desk.take(&mut db, &vault, &owner, &[NAME.into()], later).is_err());
    }
}
