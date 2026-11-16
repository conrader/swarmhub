use crate::{
    ApiError, Workspace, agent,
    history::{self, StoreError},
    skills::{Draft, validate},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::get,
};
use ring::digest::{SHA256, digest};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct Target {
    core: String,
    id: String,
    created: u64,
    message: i64,
}

#[derive(Serialize)]
struct Proposal {
    name: String,
    summary: String,
    instructions: String,
    state: String,
    skill: Option<i64>,
}

fn proposal(db: &Connection, target: &Target) -> Result<Proposal, ApiError> {
    db.query_row("SELECT p.name,p.summary,p.instructions,p.state,p.skill FROM skill_proposals p
        JOIN journal j ON j.id=p.message WHERE j.id=?1 AND j.core_id=?2 AND j.address=?3 AND j.created_ms=?4",
        params![target.message,target.core,target.id,target.created],
        |row| Ok(Proposal{name:row.get(0)?,summary:row.get(1)?,instructions:row.get(2)?,state:row.get(3)?,skill:row.get(4)?}))
        .optional().map_err(StoreError::from)?.ok_or(ApiError::NotFound)
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/history/{core}/{id}/{created}/skill-proposals/{message}",
            get(read).post(save),
        )
        .route(
            "/api/history/{core}/{id}/{created}/skill-proposals/{message}/dismiss",
            axum::routing::post(dismiss),
        )
}

async fn read(
    State(w): State<Workspace>,
    Path(target): Path<Target>,
) -> Result<Json<Proposal>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(proposal(&db, &target)?))
}

async fn save(
    State(w): State<Workspace>,
    Path(target): Path<Target>,
    Json(draft): Json<Draft>,
) -> Result<Json<serde_json::Value>, ApiError> {
    validate(&draft)?;
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let current = proposal(&tx, &target)?;
    if current.state == "saved" {
        return Ok(Json(serde_json::json!({"id":current.skill})));
    }
    if current.state != "pending" {
        return Err(ApiError::Conflict("This skill proposal was dismissed."));
    }
    let id = crate::skills::create_skill(&tx, &draft)?;
    tx.execute(
        "UPDATE skill_proposals SET state='saved',skill=?2 WHERE message=?1",
        params![target.message, id],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(serde_json::json!({"id":id})))
}

async fn dismiss(
    State(w): State<Workspace>,
    Path(target): Path<Target>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    if proposal(&tx, &target)?.state == "saved" {
        return Err(ApiError::Conflict(
            "This proposal has already been saved as a skill.",
        ));
    }
    tx.execute(
        "UPDATE skill_proposals SET state='dismissed' WHERE message=?1",
        [target.message],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(serde_json::json!({"dismissed":true})))
}

fn publish_error(error: rusqlite::Error) -> &'static str {
    let _ = StoreError::from(error);
    "Could not save the skill proposal."
}

pub fn publish() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args_os().nth(2).is_some() {
        return Err("Usage: swarmhub-herdr propose-skill < skill.json".into());
    }
    let (path, launch) = agent::session()?;
    let input = agent::read_input(65_536)?;
    let draft: Draft = serde_json::from_str(&input)
        .map_err(|_| "Use JSON with name, summary, and instructions.")?;
    validate(&draft)
        .map_err(|_| "Invalid skill proposal. Check the name, description, and instructions.")?;
    let fingerprint = digest(
        &SHA256,
        &serde_json::to_vec(&(draft.name.trim(), draft.summary.trim(), &draft.instructions))?,
    );
    let mut db = history::connection(&path).map_err(publish_error)?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(publish_error)?;
    if tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM skill_proposals WHERE launch=?1 AND fingerprint=?2)",
            params![launch, fingerprint.as_ref()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(publish_error)?
    {
        println!("This skill proposal is already in the conversation.");
        return Ok(());
    }
    if tx
        .query_row(
            "SELECT count(*) FROM skill_proposals WHERE launch=?1 AND state='pending'",
            [&launch],
            |row| row.get::<_, i64>(0),
        )
        .map_err(publish_error)?
        >= 12
    {
        return Err("Review an existing skill proposal before adding more.".into());
    }
    let id:i64 = tx.query_row("INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms)
       SELECT launch_key,core_id,address,created_ms,agent,'reply','received',?2,'Skill proposal',?3
         FROM journal WHERE launch_key=?1 RETURNING id",
        params![launch,draft.name.trim(),history::now()],|row|row.get(0)).optional().map_err(publish_error)?
        .ok_or("The receiving agent session is unavailable.")?;
    tx.execute("INSERT INTO skill_proposals (message,launch,name,summary,instructions,fingerprint) VALUES (?1,?2,?3,?4,?5,?6)",
       params![id,launch,draft.name.trim(),draft.summary.trim(),draft.instructions,fingerprint.as_ref()]).map_err(publish_error)?;
    tx.commit().map_err(publish_error)?;
    println!("Skill proposal sent for review.");
    Ok(())
}
