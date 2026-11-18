use super::{DISABLED, Entry, Vault, saved, secret_body, validate_value, version};
use crate::{
    ApiError, Workspace, agent,
    core::Failure,
    history::{StoreError, connection, now},
};
use axum::{
    Json, Router,
    extract::{Path, State, rejection::JsonRejection},
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::{env, ffi::OsString, process};

mod output;

const PENDING_MS: i64 = 15 * 60 * 1000;
const APPROVED_MS: i64 = 5 * 60 * 1000;
const STALE: ApiError = ApiError::Conflict("This Vault request is no longer available.");
const DENIED: &str = "An approved Vault request for this agent and name is required.";
const CLI_UNAVAILABLE: &str = "Vault is unavailable in this agent session.";
pub(crate) const USAGE: &str = "Vault: swarmhub-herdr vault request --name NAME --label LABEL --description DESCRIPTION\n       swarmhub-herdr vault status --name NAME\n       swarmhub-herdr vault exec --name NAME [--name NAME ...] -- COMMAND [ARG ...]";
pub(crate) const NOTE: &str = "[SwarmHub notes — Vault]\nFor credentials, run \"$SWARMHUB_PUBLISHER\" vault request --name NAME --label LABEL --description DESCRIPTION. Ask for entry in the Vault window. Check with vault status --name NAME and, after approval, use vault exec --name NAME -- COMMAND. Pass names only. Keep secret values out of chat, command arguments and files.";

#[derive(Serialize)]
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
    Cancel,
}

#[derive(Serialize)]
struct Status<N> {
    status: &'static str,
    name: N,
}

pub(super) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/vault/requests", get(pending))
        .route("/api/vault/requests/{id}", post(decide))
}

async fn pending(State(w): State<Workspace>) -> Result<Json<Vec<Request>>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(list(&db, now())?))
}

fn list(db: &Connection, at: i64) -> Result<Vec<Request>, StoreError> {
    let mut query = db.prepare(
        "SELECT r.id, COALESCE(p.name,
           (SELECT b.name FROM bots b WHERE b.agent_name=j.agent AND b.removed_ms IS NULL ORDER BY b.updated_ms DESC LIMIT 1),
           j.agent), r.name, r.label, r.description, r.entry_id IS NULL
         FROM vault_requests r JOIN journal j ON j.id=r.launch LEFT JOIN profiles p ON p.id=j.profile_id
         WHERE r.state='pending' AND r.expires_ms>?1 ORDER BY r.expires_ms,r.id LIMIT 64",
    )?;
    Ok(query
        .query_map([at], |row| {
            Ok(Request {
                id: row.get(0)?,
                bot: row.get(1)?,
                name: row.get(2)?,
                label: row.get(3)?,
                description: row.get(4)?,
                needs_value: row.get(5)?,
            })
        })?
        .collect::<Result<_, _>>()?)
}

async fn decide(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    body: Result<Json<Decision>, JsonRejection>,
) -> Result<Json<Status<String>>, ApiError> {
    let Decision { action, value } = secret_body(body)?;
    let mut db = w.history.db()?;
    let name = resolve(&mut db, w.vault.as_ref(), &id, action, value, now())?;
    Ok(Json(Status {
        status: "resolved",
        name,
    }))
}

fn resolve(
    db: &mut Connection,
    vault: Option<&Vault>,
    id: &str,
    action: Action,
    value: Option<String>,
    at: i64,
) -> Result<String, ApiError> {
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let (name, entry): (String, Option<(String, i64)>) = tx
        .query_row(
            "SELECT name,entry_id,entry_revision FROM vault_requests
         WHERE id=?1 AND state='pending' AND expires_ms>?2",
            params![id, at],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get::<_, Option<String>>(1)?.zip(row.get(2)?),
                ))
            },
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(STALE)?;

    let mut sealed = None;
    let (state, entry) = match (action, value, entry) {
        (Action::Cancel, None, _) => ("cancelled", None),
        (Action::Save, None, Some((entry_id, revision))) => {
            let vault = vault.ok_or(DISABLED)?;
            vault.check(&tx)?;
            version(&tx, &entry_id, revision)?;
            ("approved", Some((entry_id, revision)))
        }
        (Action::Save, Some(value), None) => {
            validate_value(&value)?;
            let vault = vault.ok_or(DISABLED)?;
            let (Entry { id, revision, .. }, item) = vault.create(&tx, &name, value)?;
            sealed = Some(item);
            ("approved", Some((id, revision)))
        }
        _ => return Err(Failure::Input("Choose the requested Vault action.").into()),
    };
    let (entry_id, revision) = entry.unzip();
    tx.execute(
        "UPDATE vault_requests SET state=?2, expires_ms=?3, entry_id=?4, entry_revision=?5 WHERE id=?1",
        params![id, state, at + APPROVED_MS, entry_id, revision],
    ).map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    if let Some(sealed) = sealed {
        sealed.commit();
    }
    Ok(name)
}

fn env_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name
            .as_bytes()
            .first()
            .is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        && !["SWARMHUB_", "LD_", "DYLD_"]
            .iter()
            .any(|prefix| name.starts_with(prefix))
        && !matches!(name, "PATH" | "BASH_ENV" | "ENV")
}

fn metadata(text: &str, max: usize) -> bool {
    !text.trim().is_empty() && text.len() <= max && !text.chars().any(char::is_control)
}

fn launch(db: &Connection, key: &str) -> Result<Option<i64>, StoreError> {
    Ok(db
        .query_row(
            "SELECT id FROM journal WHERE launch_key=?1 AND kind='task' AND address IS NOT NULL
         AND state='sent' ORDER BY id LIMIT 1",
            [key],
            |row| row.get(0),
        )
        .optional()?)
}

fn request(
    db: &mut Connection,
    key: &str,
    name: &str,
    label: &str,
    description: &str,
    at: i64,
) -> Result<&'static str, StoreError> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let launch = launch(&tx, key)?.ok_or(StoreError)?;
    tx.execute("DELETE FROM vault_requests WHERE expires_ms <= ?1", [at])?;
    let status = status(&tx, launch, name, at)?;
    if matches!(status, "pending" | "approved") {
        tx.commit()?;
        return Ok(status);
    }
    let pending: usize = tx.query_row(
        "SELECT COUNT(*) FROM vault_requests WHERE state='pending'",
        [],
        |row| row.get(0),
    )?;
    if pending >= 64 {
        tx.commit()?;
        return Ok("busy");
    }
    let (entry_id, entry_revision) = saved(&tx, name)?
        .map(|entry| (entry.id, entry.revision))
        .unzip();
    tx.execute(
        "INSERT INTO vault_requests (id,launch,name,label,description,state,expires_ms,entry_id,entry_revision)
         VALUES (lower(hex(randomblob(16))),?1,?2,?3,?4,'pending',?5,?6,?7)
         ON CONFLICT(launch,name) DO UPDATE SET
           id=excluded.id, name=excluded.name, label=excluded.label, description=excluded.description,
           state=excluded.state, expires_ms=excluded.expires_ms,
           entry_id=excluded.entry_id, entry_revision=excluded.entry_revision",
        params![launch, name, label, description, at + PENDING_MS, entry_id, entry_revision],
    )?;
    tx.commit()?;
    Ok("pending")
}

fn status(db: &Connection, launch: i64, name: &str, at: i64) -> Result<&'static str, StoreError> {
    let found: Option<(String, bool)> = db
        .query_row(
            "SELECT r.state, s.id IS NOT NULL FROM vault_requests r
         LEFT JOIN vault_secrets s ON s.id=r.entry_id AND s.revision=r.entry_revision
         WHERE r.launch=?1 AND r.name=?2 COLLATE BINARY AND r.expires_ms>?3",
            params![launch, name, at],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    Ok(
        match found
            .as_ref()
            .map(|(state, valid)| (state.as_str(), *valid))
        {
            Some(("pending", _)) => "pending",
            Some(("approved", true)) => "approved",
            Some(("cancelled", _)) => "cancelled",
            Some(("used", _)) => "used",
            _ => "unavailable",
        },
    )
}

fn take(
    db: &mut Connection,
    vault: &Vault,
    key: &str,
    names: &[String],
    at: i64,
) -> Result<Vec<(String, String)>, StoreError> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let launch = launch(&tx, key)?.ok_or(StoreError)?;
    vault.check(&tx).map_err(|_| StoreError)?;
    let mut values = Vec::with_capacity(names.len());
    for name in names {
        let (reference, entry, revision): (String, String, i64) = tx.query_row(
            "UPDATE vault_requests SET state='used'
             WHERE launch=?1 AND name=?2 COLLATE BINARY AND state='approved' AND expires_ms>?3
             RETURNING name,entry_id,entry_revision",
            params![launch, name, at],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )?;
        let stored = version(&tx, &entry, revision).map_err(|_| StoreError)?;
        values.push((reference, vault.open(&stored)?));
    }
    tx.commit()?;
    Ok(values)
}

fn option(
    args: &mut impl Iterator<Item = OsString>,
    expected: &str,
) -> Result<String, &'static str> {
    if args.next().as_deref().is_some_and(|flag| flag == expected) {
        return args
            .next()
            .and_then(|value| value.into_string().ok())
            .ok_or(USAGE);
    }
    Err(USAGE)
}

pub(crate) fn cli() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(2).peekable();
    let command = args.next().ok_or(USAGE)?;
    let (journal, key) = agent::session().map_err(|_| CLI_UNAVAILABLE)?;
    let mut db = connection(&journal).map_err(|_| CLI_UNAVAILABLE)?;
    let name = option(&mut args, "--name")?;
    if !env_name(&name) {
        return Err("Use a Vault name suitable for an environment variable.".into());
    }
    let at = now();
    let state = match command.to_str() {
        Some("request") => {
            let label = option(&mut args, "--label")?;
            let description = option(&mut args, "--description")?;
            if args.next().is_some() || !metadata(&label, 120) || !metadata(&description, 500) {
                return Err(USAGE.into());
            }
            // Fail before opening a prompt when the configured store is unavailable.
            let vault = Vault::configured(&journal)
                .map_err(|_| CLI_UNAVAILABLE)?
                .ok_or(CLI_UNAVAILABLE)?;
            vault.check(&db).map_err(|_| CLI_UNAVAILABLE)?;
            request(&mut db, &key, &name, &label, &description, at).map_err(|_| CLI_UNAVAILABLE)?
        }
        Some("status") if args.next().is_none() => {
            let id = launch(&db, &key)
                .map_err(|_| CLI_UNAVAILABLE)?
                .ok_or(CLI_UNAVAILABLE)?;
            status(&db, id, &name, at).map_err(|_| CLI_UNAVAILABLE)?
        }
        Some("exec") => {
            let mut names = vec![name];
            while args.peek().is_some_and(|flag| flag == "--name") {
                let next = option(&mut args, "--name")?;
                if names.len() >= 8
                    || !env_name(&next)
                    || names.iter().any(|name| name.eq_ignore_ascii_case(&next))
                {
                    return Err(USAGE.into());
                }
                names.push(next);
            }
            if args
                .next()
                .as_deref()
                .is_none_or(|separator| separator != "--")
            {
                return Err(USAGE.into());
            }
            let program = args
                .next()
                .filter(|program| !program.is_empty())
                .ok_or(USAGE)?;
            let vault = Vault::configured(&journal)
                .map_err(|_| CLI_UNAVAILABLE)?
                .ok_or(CLI_UNAVAILABLE)?;
            let values = take(&mut db, &vault, &key, &names, at).map_err(|_| DENIED)?;
            drop(db);
            let exit = output::run(program, args, &values)
                .map_err(|_| "Vault could not run the command or capture its output.")?;
            process::exit(exit);
        }
        _ => return Err(USAGE.into()),
    };
    println!(
        "{}",
        serde_json::to_string(&Status {
            status: state,
            name: &name
        })?
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::history::History;

    const AT: i64 = 1000;
    const NAME: &str = "FIXTURE_TOKEN";

    fn launch_fixture(db: &Connection, bot: &str, key: &str) -> i64 {
        db.query_row(
            "INSERT INTO journal (launch_key,core_id,agent,address,created_ms,kind,state,text,at_ms)
             VALUES (?1,'test-core',?2,?2,1,'task','sent','fixture',1) RETURNING id",
            [key, bot], |row| row.get(0),
        ).unwrap()
    }

    #[test]
    fn request_has_only_metadata_and_approval_is_single_use_and_session_bound() {
        let dir = tempfile::tempdir().unwrap();
        let history = History::open_at(dir.path()).unwrap();
        let vault = Vault::fixture();
        let mut db = history.db().unwrap();
        let owner = launch_fixture(&db, "Research", "owner");
        let peer = launch_fixture(&db, "Builder", "peer");
        assert_eq!(
            request(&mut db, "owner", NAME, "Reporting", "Read reports", AT).unwrap(),
            "pending"
        );
        let pending = list(&db, AT).unwrap();
        let id = &pending[0].id;
        assert_eq!(pending[0].bot, "Research");
        assert!(pending[0].needs_value);
        assert_eq!(
            request(&mut db, "owner", NAME, "New label", "Changed", AT).unwrap(),
            "pending"
        );
        assert_eq!(list(&db, AT).unwrap()[0].id, *id);
        assert_eq!(status(&db, peer, NAME, AT).unwrap(), "unavailable");
        assert!(take(&mut db, &vault, "owner", &[NAME.into()], AT).is_err());

        let value = "fixture-only-credential";
        assert_eq!(
            resolve(
                &mut db,
                Some(&vault),
                id,
                Action::Save,
                Some(value.into()),
                AT
            )
            .unwrap(),
            NAME
        );
        assert!(list(&db, AT).unwrap().is_empty());
        assert!(resolve(&mut db, Some(&vault), id, Action::Cancel, None, AT).is_err());
        assert_eq!(status(&db, owner, NAME, AT).unwrap(), "approved");
        assert!(take(&mut db, &vault, "peer", &[NAME.into()], AT).is_err());
        assert!(take(&mut db, &vault, "owner", &[NAME.into(), "OTHER".into()], AT).is_err());
        assert_eq!(
            take(&mut db, &vault, "owner", &[NAME.into()], AT).unwrap(),
            [(NAME.into(), value.into())]
        );
        assert_eq!(status(&db, owner, NAME, AT).unwrap(), "used");
        assert!(take(&mut db, &vault, "owner", &[NAME.into()], AT).is_err());
    }

    #[test]
    fn expiry_cancel_and_entry_revision_require_a_new_approval() {
        let dir = tempfile::tempdir().unwrap();
        let history = History::open_at(dir.path()).unwrap();
        let vault = Vault::fixture();
        vault
            .put_connector(&history, NAME, "old-fixture".into())
            .unwrap();
        let mut db = history.db().unwrap();
        let owner = launch_fixture(&db, "Research", "owner");
        assert!(request(&mut db, "other", NAME, "Reporting", "Read reports", AT).is_err());
        request(&mut db, "owner", NAME, "Reporting", "Read reports", AT).unwrap();
        let pending = list(&db, AT).unwrap().pop().unwrap();
        assert!(!pending.needs_value);
        assert!(
            resolve(
                &mut db,
                Some(&vault),
                &pending.id,
                Action::Save,
                None,
                AT + PENDING_MS
            )
            .is_err()
        );
        assert!(list(&db, AT + PENDING_MS).unwrap().is_empty());

        let later = AT + PENDING_MS + 1;
        request(&mut db, "owner", NAME, "Reporting", "Read reports", later).unwrap();
        let pending = list(&db, later).unwrap().pop().unwrap();
        assert!(
            resolve(
                &mut db,
                None,
                &pending.id,
                Action::Cancel,
                Some("unused".into()),
                later
            )
            .is_err()
        );
        resolve(&mut db, None, &pending.id, Action::Cancel, None, later).unwrap();
        assert_eq!(status(&db, owner, NAME, later).unwrap(), "cancelled");

        request(&mut db, "owner", NAME, "Reporting", "Read reports", later).unwrap();
        let pending = list(&db, later).unwrap().pop().unwrap();
        resolve(
            &mut db,
            Some(&vault),
            &pending.id,
            Action::Save,
            None,
            later,
        )
        .unwrap();
        assert!(
            take(
                &mut db,
                &vault,
                "owner",
                &[NAME.into()],
                later + APPROVED_MS
            )
            .is_err()
        );
        drop(db);
        vault
            .put_connector(&history, NAME, "new-fixture".into())
            .unwrap();
        let mut db = history.db().unwrap();
        assert_eq!(status(&db, owner, NAME, later).unwrap(), "unavailable");
        assert!(take(&mut db, &vault, "owner", &[NAME.into()], later).is_err());
    }
}
