use super::{ApiError, Failure, ListingQuery, StoreError, Workspace};
use axum::{
    Json,
    extract::{Path, Query, State},
};
use rusqlite::{OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Value, json};

struct Child {
    launch_key: String,
    parent: String,
    state: String,
    active_turn: Option<String>,
    transcript: String,
    details: Option<String>,
}

impl Child {
    fn load(
        w: &Workspace,
        core: &str,
        address: &str,
        created: u64,
        thread: &str,
        runtime: &str,
    ) -> Result<Self, ApiError> {
        w.history.db()?.query_row(
            "SELECT p.launch_key, json_extract(c.summary,'$.parent'), json_extract(c.summary,'$.state'),
                    json_extract(c.summary,'$.active_turn'), c.transcript,
                    coalesce(json_extract(c.summary,'$.details'),
                        (SELECT json_object('task',json_extract(record,'$.task'),'reply',json_extract(record,'$.reply'),
                                            'steps',json_extract(record,'$.steps'),'terminal',json_extract(record,'$.terminal'))
                         FROM claude_children WHERE c.runtime='claude' AND launch=c.launch AND thread=c.thread
                         AND json_type(record,'$.steps')='array'))
             FROM native_children c JOIN journal p ON p.id=c.launch
             WHERE p.core_id=?1 AND p.address=?2 AND p.created_ms=?3 AND c.thread=?4 AND c.runtime=?5",
            params![core, address, created, thread, runtime],
            |r| Ok(Self { launch_key: r.get(0)?, parent: r.get(1)?, state: r.get(2)?,
                          active_turn: r.get(3)?, transcript: r.get(4)?, details: r.get(5)? }),
        ).optional().map_err(StoreError::from)?.ok_or_else(|| Failure::Missing.into())
    }

    async fn owner_is_live(
        &self,
        w: &Workspace,
        core: &str,
        address: &str,
        created: u64,
    ) -> Result<bool, ApiError> {
        if w.core.identify().await?.core.id != core {
            return Ok(false);
        }
        match w.core.agent(address, created).await {
            Ok(agent) => Ok(agent.state == "live" && agent.launch_key() == Some(&self.launch_key)),
            Err(Failure::Missing) => Ok(false),
            Err(error) => Err(error.into()),
        }
    }
}

pub(super) async fn read_codex(
    State(w): State<Workspace>,
    Path((address, created, thread)): Path<(String, u64, String)>,
    Query(query): Query<ListingQuery>,
) -> Result<Json<Value>, ApiError> {
    activity(w, address, created, thread, query, "codex").await
}

pub(super) async fn read_claude(
    State(w): State<Workspace>,
    Path((address, created, thread)): Path<(String, u64, String)>,
    Query(query): Query<ListingQuery>,
) -> Result<Json<Value>, ApiError> {
    activity(w, address, created, thread, query, "claude").await
}

pub(super) async fn read_opencode(
    State(w): State<Workspace>,
    Path((address, created, thread)): Path<(String, u64, String)>,
    Query(query): Query<ListingQuery>,
) -> Result<Json<Value>, ApiError> {
    activity(w, address, created, thread, query, "opencode").await
}

async fn activity(
    w: Workspace,
    address: String,
    created: u64,
    thread: String,
    query: ListingQuery,
    runtime: &str,
) -> Result<Json<Value>, ApiError> {
    let core = query.core.ok_or(Failure::Missing)?;
    let mut child = Child::load(&w, &core, &address, created, &thread, runtime)?;
    if child.state == "working" {
        match child.owner_is_live(&w, &core, &address, created).await {
            Ok(true) => {}
            Ok(false) => {
                child.active_turn = None;
                child.state = "stopped".into();
            }
            Err(_) => {
                child.active_turn = None;
                child.state = "unavailable".into();
            }
        }
    }
    let details = child.details.as_deref().map(serde_json::from_str::<Value>)
        .transpose().map_err(|_| StoreError)?;
    Ok(Json(
        json!({"details":details,"transcript":child.transcript, "state":child.state, "active_turn":child.active_turn}),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Interrupt {
    turn: String,
}

pub(super) async fn interrupt_codex(
    State(w): State<Workspace>,
    Path((address, created, thread)): Path<(String, u64, String)>,
    Query(query): Query<ListingQuery>,
    Json(request): Json<Interrupt>,
) -> Result<Json<Value>, ApiError> {
    interrupt(w, address, created, thread, query, request, "codex").await
}

pub(super) async fn interrupt_opencode(
    State(w): State<Workspace>,
    Path((address, created, thread)): Path<(String, u64, String)>,
    Query(query): Query<ListingQuery>,
    Json(request): Json<Interrupt>,
) -> Result<Json<Value>, ApiError> {
    interrupt(w, address, created, thread, query, request, "opencode").await
}

async fn interrupt(
    w: Workspace,
    address: String,
    created: u64,
    thread: String,
    query: ListingQuery,
    request: Interrupt,
    runtime: &str,
) -> Result<Json<Value>, ApiError> {
    let core = query.core.ok_or(Failure::Missing)?;
    let child = Child::load(&w, &core, &address, created, &thread, runtime)?;
    if child.state != "working"
        || child.active_turn.as_deref() != Some(request.turn.as_str())
        || !child.owner_is_live(&w, &core, &address, created).await?
    {
        return Err(ApiError::Conflict("This helper turn is no longer running."));
    }
    if runtime == "opencode" {
        crate::opencode_agent::interrupt(&child.launch_key, &thread, &child.parent, &request.turn)
            .await?;
    } else {
        crate::codex_agent::stream::interrupt_child(
            w.history.file(),
            &child.launch_key,
            &thread,
            &child.parent,
            &request.turn,
        )
        .await?;
    }
    Ok(Json(json!({"interrupted_turn": request.turn})))
}
