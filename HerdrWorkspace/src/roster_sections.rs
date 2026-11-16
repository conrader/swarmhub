use crate::{ApiError, Workspace, core::Failure, history::StoreError};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{StatusCode, header},
    response::IntoResponse,
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Serialize)]
struct Section {
    id: i64,
    name: String,
    revision: i64,
}

const SECTION_CHANGED: ApiError =
    ApiError::Conflict("This section changed. Reopen the editor to see its latest settings.");
const PROFILE_CHANGED: ApiError =
    ApiError::Conflict("This profile changed. Reopen Move to section and try again.");
const NAME_TAKEN: ApiError = ApiError::Conflict("A section already uses that name.");

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NewSection {
    name: String,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum EditSection {
    Rename { name: String, revision: i64 },
    Remove { revision: i64 },
}

#[derive(Deserialize)]
#[serde(tag = "destination", rename_all = "snake_case", deny_unknown_fields)]
enum MoveProfile {
    Unsectioned { revision: i64 },
    Existing { id: i64, revision: i64 },
    New { name: String, revision: i64 },
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/roster-sections.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/roster-sections.js"),
                )
            }),
        )
        .route("/api/roster-sections", get(list).post(create))
        .route("/api/roster-sections/{id}", post(edit))
        .route("/api/profiles/{id}/section", post(move_profile))
}

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Section> {
    Ok(Section {
        id: row.get(0)?,
        name: row.get(1)?,
        revision: row.get(2)?,
    })
}

fn name(raw: &str) -> Result<&str, Failure> {
    let name = raw.trim();
    if name.is_empty() || name.chars().count() > 48 || raw.chars().any(char::is_control) {
        return Err(Failure::Input("Enter a section name up to 48 characters."));
    }
    if matches!(name.to_ascii_lowercase().as_str(), "pinned" | "unsectioned") {
        return Err(Failure::Input(
            "Choose a name other than Pinned or Unsectioned.",
        ));
    }
    Ok(name)
}

fn add(db: &Connection, name: &str) -> Result<Section, ApiError> {
    db.query_row(
        "INSERT INTO roster_sections(name) VALUES (?1) ON CONFLICT(name) DO NOTHING
         RETURNING id,name,revision",
        [name],
        row,
    )
    .optional()
    .map_err(StoreError::from)?
    .ok_or(NAME_TAKEN)
}

async fn list(State(w): State<Workspace>) -> Result<Json<Vec<Section>>, StoreError> {
    let db = w.history.db()?;
    let mut query = db.prepare("SELECT id,name,revision FROM roster_sections ORDER BY name,id")?;
    Ok(Json(
        query.query_map([], row)?.collect::<rusqlite::Result<_>>()?,
    ))
}

async fn create(
    State(w): State<Workspace>,
    Json(body): Json<NewSection>,
) -> Result<impl IntoResponse, ApiError> {
    let name = name(&body.name)?;
    let db = w.history.db()?;
    Ok((StatusCode::CREATED, Json(add(&db, name)?)))
}

async fn edit(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<EditSection>,
) -> Result<impl IntoResponse, ApiError> {
    let mut db = w.history.db()?;
    let txn = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let expected = match &body {
        EditSection::Rename { revision, .. } | EditSection::Remove { revision } => *revision,
    };
    let revision: i64 = txn
        .query_row(
            "SELECT revision FROM roster_sections WHERE id=?1",
            [id],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    if revision != expected {
        return Err(SECTION_CHANGED);
    }
    match body {
        EditSection::Rename { name: raw, .. } => {
            let name = name(&raw)?;
            let count = txn
                .execute(
                    "UPDATE OR IGNORE roster_sections SET name=?2,revision=revision+1 WHERE id=?1",
                    params![id, name],
                )
                .map_err(StoreError::from)?;
            if count == 0 {
                return Err(NAME_TAKEN);
            }
        }
        EditSection::Remove { .. } => {
            txn.execute(
                "UPDATE profiles SET revision=revision+1 WHERE section_id=?1",
                [id],
            )
            .map_err(StoreError::from)?;
            txn.execute("DELETE FROM roster_sections WHERE id=?1", [id])
                .map_err(StoreError::from)?;
        }
    }
    txn.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"saved":true})))
}

async fn move_profile(
    State(w): State<Workspace>,
    Path(profile): Path<i64>,
    Json(body): Json<MoveProfile>,
) -> Result<impl IntoResponse, ApiError> {
    let mut db = w.history.db()?;
    let txn = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let (section, revision) = match body {
        MoveProfile::Unsectioned { revision } => (None, revision),
        MoveProfile::Existing { id, revision } => {
            let exists: bool = txn
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM roster_sections WHERE id=?1)",
                    [id],
                    |row| row.get(0),
                )
                .map_err(StoreError::from)?;
            if !exists {
                return Err(ApiError::Conflict(
                    "This section was removed. Choose another destination.",
                ));
            }
            (Some(id), revision)
        }
        MoveProfile::New {
            name: raw,
            revision,
        } => (Some(add(&txn, name(&raw)?)?.id), revision),
    };
    if txn
        .execute(
            "UPDATE profiles SET section_id=?2,revision=revision+1 WHERE id=?1 AND revision=?3",
            params![profile, section, revision],
        )
        .map_err(StoreError::from)?
        == 0
    {
        return Err(PROFILE_CHANGED);
    }
    txn.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"section_id":section})))
}
