use crate::{
    ApiError, Workspace,
    core::{Failure, validate_task},
    groups::Target,
    history::{StoreError, now},
};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{StatusCode, header},
    response::IntoResponse,
    routing::{get, post},
};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::json;

#[derive(Default, Deserialize)]
struct Scope {
    core: Option<String>,
    address: Option<String>,
    created_ms: Option<u64>,
}

#[derive(Serialize)]
struct Summary {
    id: i64,
    name: String,
    summary: String,
    version: i64,
    archived: bool,
    enabled: bool,
}

#[derive(Serialize)]
struct Detail {
    #[serde(flatten)]
    skill: Summary,
    instructions: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Draft {
    pub name: String,
    pub summary: String,
    pub instructions: String,
    version: Option<i64>,
}

impl Draft {
    pub(crate) fn imported(name: String, instructions: String) -> Self {
        Self {
            name,
            instructions,
            summary: String::new(),
            version: None,
        }
    }
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/skills.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/skills.js"),
                )
            }),
        )
        .route("/api/skills", get(list).post(create))
        .route("/api/skills/{id}", get(detail).post(edit))
        .route("/api/skills/{id}/archive", post(archive))
        .route("/api/skills/{id}/availability", post(availability))
}

async fn list(
    State(w): State<Workspace>,
    Query(scope): Query<Scope>,
) -> Result<Json<Vec<Summary>>, ApiError> {
    let db = w.history.db()?;
    let mut q = db
        .prepare(
            "SELECT skills.id,name,summary,version,archived,(disabled_skills.skill IS NULL)
         FROM skills LEFT JOIN disabled_skills ON disabled_skills.skill=skills.id
           AND core=?1 AND address=?2 AND created_ms=?3
         ORDER BY archived, updated_ms DESC,id DESC",
        )
        .map_err(StoreError::from)?;
    let rows = q
        .query_map(
            params![scope.core, scope.address, scope.created_ms],
            row_summary,
        )
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(StoreError::from)?;
    Ok(Json(rows))
}

async fn detail(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Query(scope): Query<Scope>,
) -> Result<Json<Detail>, ApiError> {
    read(&w, id, &scope).map(Json)
}

fn read(w: &Workspace, id: i64, scope: &Scope) -> Result<Detail, ApiError> {
    let db = w.history.db()?;
    db.query_row(
        "SELECT skills.id,name,summary,version,archived,(disabled_skills.skill IS NULL),instructions
         FROM skills LEFT JOIN disabled_skills ON disabled_skills.skill=skills.id
           AND core=?2 AND address=?3 AND created_ms=?4 WHERE skills.id=?1",
        params![id, scope.core, scope.address, scope.created_ms],
        |row| Ok(Detail { skill: row_summary(row)?, instructions: row.get(6)? }),
    ).optional().map_err(StoreError::from)?.ok_or(ApiError::NotFound)
}

fn row_summary(row: &rusqlite::Row<'_>) -> rusqlite::Result<Summary> {
    Ok(Summary {
        id: row.get(0)?,
        name: row.get(1)?,
        summary: row.get(2)?,
        version: row.get(3)?,
        archived: row.get(4)?,
        enabled: row.get(5)?,
    })
}

pub(crate) fn validate(draft: &Draft) -> Result<(), Failure> {
    if draft.name.trim().is_empty()
        || draft.name.trim().chars().count() > 80
        || draft.name.chars().any(char::is_control)
    {
        return Err(Failure::Input("Enter a skill name up to 80 characters."));
    }
    if draft.summary.trim().chars().count() > 240 || draft.summary.chars().any(char::is_control) {
        return Err(Failure::Input(
            "The description must fit on one line, up to 240 characters.",
        ));
    }
    validate_task(&draft.instructions)?;
    if draft.instructions.len() > 10 * 1024 {
        return Err(Failure::Input(
            "Skill instructions can contain up to 10 KiB.",
        ));
    }
    Ok(())
}

async fn create(
    State(w): State<Workspace>,
    Json(body): Json<Draft>,
) -> Result<impl IntoResponse, ApiError> {
    validate(&body)?;
    let id = {
        let db = w.history.db()?;
        create_skill(&db, &body)?
    };
    Ok((StatusCode::CREATED, Json(read(&w, id, &Scope::default())?)))
}

pub(crate) fn create_skill(db: &rusqlite::Connection, body: &Draft) -> Result<i64, StoreError> {
    db.query_row(
        "INSERT INTO skills (name,summary,instructions,version,updated_ms) VALUES (?1,?2,?3,1,?4) RETURNING id",
        params![body.name.trim(),body.summary.trim(),body.instructions,now()], |row| row.get(0),
    ).map_err(StoreError::from)
}

async fn edit(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<Draft>,
) -> Result<impl IntoResponse, ApiError> {
    validate(&body)?;
    let version = body
        .version
        .ok_or(Failure::Input("Reload this skill before saving."))?;
    let updated = w
        .history
        .db()?
        .execute(
            "UPDATE skills SET name=?2,summary=?3,instructions=?4,version=version+1,updated_ms=?5
         WHERE id=?1 AND version=?6 AND archived=0",
            params![
                id,
                body.name.trim(),
                body.summary.trim(),
                body.instructions,
                now(),
                version
            ],
        )
        .map_err(StoreError::from)?;
    if updated == 0 {
        return Ok((
            StatusCode::CONFLICT,
            Json(json!({"error":"This skill changed or was archived. Reopen it before editing."})),
        ));
    }
    Ok((
        StatusCode::OK,
        Json(json!(read(&w, id, &Scope::default())?)),
    ))
}

async fn archive(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(archived): Json<bool>,
) -> Result<impl IntoResponse, ApiError> {
    let count = w
        .history
        .db()?
        .execute(
            "UPDATE skills SET archived=?2, updated_ms=?3 WHERE id=?1",
            params![id, archived, now()],
        )
        .map_err(StoreError::from)?;
    if count == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(Json(read(&w, id, &Scope::default())?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Availability {
    core: String,
    target: Target,
    enabled: bool,
}

async fn availability(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<Availability>,
) -> Result<impl IntoResponse, ApiError> {
    read(&w, id, &Scope::default())?;
    if w.core.identify().await?.core.id != body.core {
        return Err(Failure::Input("Connect the agent's Herdr Core to manage its skills.").into());
    }
    w.core
        .agent(&body.target.address, body.target.created_ms)
        .await?;
    let db = w.history.db()?;
    if body.enabled {
        db.execute(
            "DELETE FROM disabled_skills WHERE skill=?1 AND core=?2 AND address=?3 AND created_ms=?4",
            params![id,body.core,body.target.address,body.target.created_ms],
        )
    } else {
        db.execute(
            "INSERT OR IGNORE INTO disabled_skills(skill,core,address,created_ms) VALUES (?1,?2,?3,?4)",
            params![id,body.core,body.target.address,body.target.created_ms],
        )
    }.map_err(StoreError::from)?;
    Ok(Json(json!({"enabled":body.enabled})))
}
