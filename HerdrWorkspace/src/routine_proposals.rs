use crate::{
    ApiError, Workspace, agent,
    groups::Target,
    history::{self, StoreError, now},
    routine_routes::validate,
    routines::{Schedule, encode},
};
use axum::{
    Json, Router,
    extract::{Path, State},
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

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Draft {
    name: String,
    task: String,
    schedule: Schedule,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Adopt {
    name: String,
    task: String,
    schedule: Schedule,
    target: Target,
}

#[derive(Serialize)]
struct Proposal {
    #[serde(flatten)]
    draft: Draft,
    state: String,
    routine: Option<i64>,
    profile_id: Option<i64>,
    #[serde(skip)]
    launch: String,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/history/{core}/{id}/{created}/routine-proposals/{message}",
            get(read).post(adopt),
        )
        .route(
            "/api/history/{core}/{id}/{created}/routine-proposals/{message}/dismiss",
            post(dismiss),
        )
}

fn proposal(db: &Connection, source: &Location) -> Result<Proposal, ApiError> {
    let (name, task, stored, state, routine, profile_id, launch) = db
        .query_row(
            "SELECT p.name,p.task,p.schedule,p.state,p.routine,l.profile_id,p.launch
              FROM routine_proposals p JOIN journal j ON j.id=p.message
              JOIN journal l ON l.launch_key=p.launch
             WHERE j.id=?1 AND j.core_id=?2 AND j.address=?3 AND j.created_ms=?4",
            params![source.message, source.core, source.id, source.created],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get::<_, String>(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                ))
            },
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    let schedule = serde_json::from_str(&stored).map_err(|_| StoreError)?;
    Ok(Proposal {
        draft: Draft {
            name,
            task,
            schedule,
        },
        state,
        routine,
        profile_id,
        launch,
    })
}

async fn read(
    State(w): State<Workspace>,
    Path(source): Path<Location>,
) -> Result<Json<Proposal>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(proposal(&db, &source)?))
}

fn id_if_saved(item: &Proposal) -> Result<Option<i64>, ApiError> {
    if item.state == "dismissed" {
        return Err(ApiError::Conflict("This routine proposal was dismissed."));
    }
    Ok(item.routine)
}

async fn adopt(
    State(w): State<Workspace>,
    Path(source): Path<Location>,
    Json(body): Json<Adopt>,
) -> Result<Json<Value>, ApiError> {
    {
        let db = w.history.db()?;
        if let Some(id) = id_if_saved(&proposal(&db, &source)?)? {
            return Ok(Json(json!({"id":id})));
        }
    }
    validate(&body.name, &body.task, &body.schedule)?;
    let core = w.core.identify().await?.core.id;
    let agent = w
        .core
        .agent(&body.target.address, body.target.created_ms)
        .await?;
    agent.require_live()?;
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let current = proposal(&tx, &source)?;
    if let Some(id) = id_if_saved(&current)? {
        return Ok(Json(json!({"id":id})));
    }
    let eligible = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM journal WHERE launch_key=?1 AND core_id=?2 AND address=?3 AND created_ms=?4
            AND (launch_key=?5 OR (profile_id=?6 AND launch_template IS NOT NULL)))",
        params![agent.launch_key(), core, agent.address, agent.created_ms, current.launch, current.profile_id],
        |row| row.get::<_, bool>(0),
    ).map_err(StoreError::from)?;
    if !eligible {
        return Err(ApiError::Conflict(
            "Choose the originating running session or a running session on the same agent profile.",
        ));
    }
    let id: i64 = tx
        .query_row(
            "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state)
         VALUES (?1,?2,?3,?4,?5,?6,?7,'paused') RETURNING id",
            params![
                core,
                agent.address,
                agent.created_ms,
                agent.display_name(),
                body.name.trim(),
                body.task,
                encode(&body.schedule)?
            ],
            |row| row.get(0),
        )
        .map_err(StoreError::from)?;
    tx.execute(
        "UPDATE routine_proposals SET state='saved',routine=?2 WHERE message=?1",
        params![source.message, id],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"id":id})))
}

async fn dismiss(
    State(w): State<Workspace>,
    Path(source): Path<Location>,
) -> Result<Json<Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    if proposal(&tx, &source)?.routine.is_some() {
        return Err(ApiError::Conflict(
            "This proposal has already been saved as a routine.",
        ));
    }
    tx.execute(
        "UPDATE routine_proposals SET state='dismissed' WHERE message=?1",
        [source.message],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"dismissed":true})))
}

fn publish_error(error: rusqlite::Error) -> &'static str {
    let _ = StoreError::from(error);
    "Could not save the routine proposal."
}

pub fn publish() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args_os().nth(2).is_some() {
        return Err("Usage: swarmhub-herdr propose-routine < routine.json".into());
    }
    let (path, launch) = agent::session()?;
    let input = agent::read_input(96 * 1024)?;
    let mut draft: Draft = serde_json::from_str(&input)
        .map_err(|_| "Use JSON with name, task, and a supported schedule.")?;
    validate(&draft.name, &draft.task, &draft.schedule)
        .map_err(|_| "Invalid routine proposal. Check the name, instructions, and schedule.")?;
    draft.name = draft.name.trim().to_owned();
    let fingerprint = digest(&SHA256, &serde_json::to_vec(&draft)?);
    let schedule = serde_json::to_string(&draft.schedule)?;
    let mut db = history::connection(&path).map_err(publish_error)?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(publish_error)?;
    if tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM routine_proposals WHERE launch=?1 AND fingerprint=?2)",
            params![launch, fingerprint.as_ref()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(publish_error)?
    {
        println!("This routine proposal is already in the conversation.");
        return Ok(());
    }
    if tx
        .query_row(
            "SELECT count(*) FROM routine_proposals WHERE launch=?1 AND state='pending'",
            [&launch],
            |row| row.get::<_, i64>(0),
        )
        .map_err(publish_error)?
        >= 12
    {
        return Err("Review an existing routine proposal before adding more.".into());
    }
    // Like other agent replies, an early proposal is bound by the journal
    // trigger once the originating terminal's address becomes known.
    let message: i64 = tx.query_row(
        "INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms)
         SELECT launch_key,core_id,address,created_ms,agent,'reply','received',?2,'Routine proposal',?3
           FROM journal WHERE launch_key=?1 RETURNING id",
        params![launch,draft.name,now()],
        |row| row.get(0),
    ).optional().map_err(publish_error)?.ok_or("The receiving agent session is unavailable.")?;
    tx.execute(
        "INSERT INTO routine_proposals (message,launch,name,task,schedule,fingerprint) VALUES (?1,?2,?3,?4,?5,?6)",
        params![message,launch,draft.name,draft.task,schedule,fingerprint.as_ref()],
    ).map_err(publish_error)?;
    tx.commit().map_err(publish_error)?;
    println!("Routine proposal sent for review.");
    Ok(())
}
