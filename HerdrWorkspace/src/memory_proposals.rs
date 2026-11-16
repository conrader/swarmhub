use crate::{
    ApiError, Workspace, agent,
    core::Failure,
    history::{self, StoreError, now},
    profiles::validate_instructions,
};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::header,
    routing::{get, post},
};
use ring::digest::{SHA256, digest};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Deserialize)]
struct Location {
    core: String,
    id: String,
    created: u64,
    message: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Review {
    profile_id: i64,
    text: String,
}

#[derive(Serialize)]
struct Profile {
    id: i64,
    name: String,
    remaining_bytes: usize,
}

#[derive(Serialize)]
struct Proposal {
    text: Option<String>,
    state: String,
    profile: Option<Profile>,
    #[serde(skip)]
    revision: Option<i64>,
    #[serde(skip)]
    instructions: Option<String>,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/memory-proposals.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/memory-proposals.js"),
                )
            }),
        )
        .route(
            "/api/history/{core}/{id}/{created}/memory-proposals/{message}",
            get(read).post(save),
        )
        .route(
            "/api/history/{core}/{id}/{created}/memory-proposals/{message}/dismiss",
            post(dismiss),
        )
}

fn proposal(db: &Connection, source: &Location) -> Result<Proposal, ApiError> {
    db.query_row(
        "SELECT m.text,m.state,m.saved_revision,p.id,p.name,p.instructions
           FROM memory_proposals m JOIN journal j ON j.id=m.message
           JOIN journal l ON l.launch_key=m.launch LEFT JOIN profiles p ON p.id=l.profile_id
          WHERE j.id=?1 AND j.core_id=?2 AND j.address=?3 AND j.created_ms=?4",
        params![source.message, source.core, source.id, source.created],
        |row| {
            let instructions: Option<String> = row.get(5)?;
            let profile = if let Some(id) = row.get(3)? {
                let size = instructions.as_deref().unwrap_or("").trim().len();
                Some(Profile {
                    id,
                    name: row.get(4)?,
                    remaining_bytes: (6 * 1024_usize).saturating_sub(if size == 0 {
                        0
                    } else {
                        size + 2
                    }),
                })
            } else {
                None
            };
            Ok(Proposal {
                text: row.get(0)?,
                state: row.get(1)?,
                profile,
                revision: row.get(2)?,
                instructions,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)?
    .ok_or(ApiError::NotFound)
}

async fn read(
    State(w): State<Workspace>,
    Path(source): Path<Location>,
) -> Result<Json<Proposal>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(proposal(&db, &source)?))
}

fn validate(input: &str) -> Result<&str, Failure> {
    let text = input.trim();
    if text.is_empty() || input.len() > 512 || input.chars().any(char::is_control) {
        return Err(Failure::Input(
            "Enter one line of plain text up to 512 bytes.",
        ));
    }
    let lower = text.to_ascii_lowercase();
    // These checks catch common credential shapes. This helper only accepts
    // text supplied by the caller; it never reads secrets from other sources.
    if (lower.contains("-----begin ") && lower.contains("private key-----"))
        || [
            "authorization: bearer ",
            "password=",
            "password:",
            "client_secret=",
            "client_secret:",
            "api_key=",
            "api_key:",
        ]
        .iter()
        .any(|pattern| lower.contains(pattern))
        || lower
            .split(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '-' | '_')))
            .any(|part| {
                ["sk-", "ghp_", "github_pat_", "xoxb-", "xoxp-", "aiza"]
                    .iter()
                    .any(|prefix| {
                        part.strip_prefix(prefix)
                            .is_some_and(|rest| rest.len() >= 16)
                    })
            })
    {
        return Err(Failure::Input(
            "Leave passwords, private keys, and tokens out of a memory suggestion.",
        ));
    }
    Ok(text)
}

async fn save(
    State(w): State<Workspace>,
    Path(source): Path<Location>,
    Json(body): Json<Review>,
) -> Result<Json<Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let current = proposal(&tx, &source)?;
    let profile = current.profile.ok_or(ApiError::Conflict(
        "This suggestion is waiting for its saved agent profile.",
    ))?;
    if body.profile_id != profile.id {
        return Err(ApiError::Conflict(
            "This suggestion belongs to a different agent profile.",
        ));
    }
    if let Some(revision) = current.revision {
        return Ok(Json(json!({"profile_id":profile.id,"revision":revision})));
    }
    if current.state != "pending" {
        return Err(ApiError::Conflict("This memory suggestion was dismissed."));
    }
    let text = validate(&body.text)?;
    let instructions = current.instructions.as_deref().unwrap_or("").trim();
    let appended = if instructions.is_empty() {
        text.to_owned()
    } else {
        format!("{instructions}\n\n{text}")
    };
    validate_instructions(&appended).map_err(|_| Failure::Input(
        "This would exceed the 6 KiB limit for standing instructions. Shorten the suggestion or edit the profile first.",
    ))?;
    let revision: i64 = tx.query_row(
        "UPDATE profiles SET instructions=?2,revision=revision+1 WHERE id=?1 RETURNING revision",
        params![profile.id, appended], |row| row.get(0),
    ).map_err(StoreError::from)?;
    tx.execute(
        "UPDATE memory_proposals SET state='saved',text=NULL,saved_revision=?2 WHERE message=?1",
        params![source.message, revision],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"profile_id":profile.id,"revision":revision})))
}

async fn dismiss(
    State(w): State<Workspace>,
    Path(source): Path<Location>,
) -> Result<Json<Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    if proposal(&tx, &source)?.revision.is_some() {
        return Err(ApiError::Conflict(
            "This suggestion has already been saved to the profile.",
        ));
    }
    tx.execute(
        "UPDATE memory_proposals SET state='dismissed',text=NULL WHERE message=?1",
        [source.message],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"dismissed":true})))
}

fn publish_error(error: rusqlite::Error) -> &'static str {
    let _ = StoreError::from(error);
    "Could not save the memory suggestion."
}

pub fn publish() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args_os().nth(2).is_some() {
        return Err("Usage: swarmhub-herdr propose-memory < memory.txt".into());
    }
    let (path, launch) = agent::session()?;
    let input = agent::read_input(516)?;
    let text = validate(input.trim_end_matches(['\r', '\n']))
        .map_err(|_| "Suggest one line of plain text up to 512 bytes, without credentials.")?;
    let fingerprint = digest(&SHA256, text.as_bytes());
    let mut db = history::connection(&path).map_err(publish_error)?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(publish_error)?;
    if tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM memory_proposals WHERE launch=?1 AND fingerprint=?2)",
            params![launch, fingerprint.as_ref()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(publish_error)?
    {
        println!("This memory suggestion is already in the conversation.");
        return Ok(());
    }
    if tx
        .query_row(
            "SELECT count(*) FROM memory_proposals WHERE launch=?1 AND state='pending'",
            [&launch],
            |row| row.get::<_, i64>(0),
        )
        .map_err(publish_error)?
        >= 12
    {
        return Err("Review an existing memory suggestion before adding more.".into());
    }
    // The journal binds an early proposal once the terminal address is known.
    // Keep the proposed text out of the transcript and excerpts.
    let message: i64 = tx.query_row(
        "INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms)
         SELECT launch_key,core_id,address,created_ms,agent,'reply','received','A memory was suggested.','Memory suggestion',?2
           FROM journal WHERE launch_key=?1 RETURNING id",
        params![launch,now()], |row| row.get(0),
    ).optional().map_err(publish_error)?.ok_or("The receiving agent session is unavailable.")?;
    tx.execute(
        "INSERT INTO memory_proposals (message,launch,text,fingerprint) VALUES (?1,?2,?3,?4)",
        params![message, launch, text, fingerprint.as_ref()],
    )
    .map_err(publish_error)?;
    tx.commit().map_err(publish_error)?;
    println!("Memory suggestion sent for review.");
    Ok(())
}
