use crate::{
    ApiError, Workspace,
    core::Failure,
    history::StoreError,
    skills::{Draft, create_skill, validate},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    routing::{get, post},
};
use ring::digest::{SHA256, digest};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Stage {
    file: String,
    name: String,
    instructions: String,
}

#[derive(Serialize)]
struct Summary {
    id: i64,
    name: String,
    source_file: String,
    state: String,
}

#[derive(Serialize)]
struct Review {
    #[serde(flatten)]
    summary: Summary,
    instructions: Option<String>,
    skill: Option<i64>,
}

pub(super) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/grok-imports/skill-drafts",
            get(list)
                .post(stage)
                .layer(DefaultBodyLimit::max(96 * 1024)),
        )
        .route("/api/grok-imports/skill-drafts/{id}", get(read).post(adopt))
        .route("/api/grok-imports/skill-drafts/{id}/dismiss", post(dismiss))
}

fn valid_file(path: &str) -> bool {
    let Some(folder) = path
        .strip_prefix("skills/")
        .and_then(|path| path.strip_suffix("/SKILL.md"))
    else {
        return false;
    };
    !folder.is_empty()
        && folder.len() <= 160
        && folder == folder.trim()
        && !matches!(folder, "." | "..")
        && !folder.chars().any(|c| {
            c.is_control() || matches!(c, '/' | '\\' | ':' | '%' | '\u{2028}' | '\u{2029}')
        })
}

fn row_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<Summary> {
    Ok(Summary {
        id: row.get(0)?,
        name: row.get(1)?,
        source_file: row.get(2)?,
        state: row.get(3)?,
    })
}

fn load(db: &Connection, id: i64) -> Result<Review, ApiError> {
    db.query_row(
        "SELECT id,name,source_file,state,instructions,skill FROM grok_skill_drafts WHERE id=?1",
        [id],
        |row| {
            Ok(Review {
                summary: row_summary(row)?,
                instructions: row.get(4)?,
                skill: row.get(5)?,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)?
    .ok_or(ApiError::NotFound)
}

async fn list(State(w): State<Workspace>) -> Result<Json<Vec<Summary>>, ApiError> {
    let db = w.history.db()?;
    let mut statement = db
        .prepare(
            "SELECT id,name,source_file,state FROM grok_skill_drafts WHERE state='pending'
        ORDER BY id DESC LIMIT 200",
        )
        .map_err(StoreError::from)?;
    let rows = statement
        .query_map([], row_summary)
        .and_then(|rows| rows.collect::<Result<_, _>>())
        .map_err(StoreError::from)?;
    Ok(Json(rows))
}

async fn stage(
    State(w): State<Workspace>,
    Json(body): Json<Stage>,
) -> Result<Json<Summary>, ApiError> {
    if !valid_file(&body.file) {
        return Err(Failure::Input(
            "Choose a local skills/<name>/SKILL.md file listed in the Grok export.",
        )
        .into());
    }
    if body.name.chars().any(char::is_control) {
        return Err(Failure::Input("Choose one line of plain text for the skill name.").into());
    }
    let draft = Draft::imported(
        body.name.trim().to_owned(),
        body.instructions.replace("\r\n", "\n"),
    );
    validate(&draft)?;
    let serial = serde_json::to_vec(&(&draft.name, &draft.instructions)).map_err(|_| StoreError)?;
    let fingerprint = digest(&SHA256, &serial);
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let already = tx
        .query_row(
            "SELECT id,name,source_file,state FROM grok_skill_drafts WHERE fingerprint=?1",
            [fingerprint.as_ref()],
            row_summary,
        )
        .optional()
        .map_err(StoreError::from)?;
    if let Some(already) = already {
        return Ok(Json(already));
    }
    if tx
        .query_row(
            "SELECT count(*) FROM grok_skill_drafts WHERE state='pending'",
            [],
            |row| row.get::<_, i64>(0),
        )
        .map_err(StoreError::from)?
        >= 200
    {
        return Err(ApiError::Conflict(
            "Review or dismiss existing imported Grok skills before adding more.",
        ));
    }
    let result = tx.query_row(
        "INSERT INTO grok_skill_drafts(fingerprint,source_file,name,instructions) VALUES(?1,?2,?3,?4)
         RETURNING id,name,source_file,state",
        params![fingerprint.as_ref(),body.file,draft.name,draft.instructions], row_summary
    ).map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(result))
}

async fn read(State(w): State<Workspace>, Path(id): Path<i64>) -> Result<Json<Review>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(load(&db, id)?))
}

async fn adopt(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(draft): Json<Draft>,
) -> Result<Json<Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let existing = load(&tx, id)?;
    if let Some(skill) = existing.skill {
        return Ok(Json(json!({"id":skill})));
    }
    if existing.summary.state != "pending" {
        return Err(ApiError::Conflict("This imported skill was dismissed."));
    }
    validate(&draft)?;
    let skill = create_skill(&tx, &draft)?;
    tx.execute(
        "UPDATE grok_skill_drafts SET state='saved',instructions=NULL,skill=?2 WHERE id=?1",
        params![id, skill],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"id":skill})))
}

async fn dismiss(State(w): State<Workspace>, Path(id): Path<i64>) -> Result<Json<Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    if load(&tx, id)?.skill.is_some() {
        return Err(ApiError::Conflict(
            "This draft was already saved as a skill.",
        ));
    }
    tx.execute(
        "UPDATE grok_skill_drafts SET state='dismissed',instructions=NULL WHERE id=?1",
        [id],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"dismissed":true})))
}
