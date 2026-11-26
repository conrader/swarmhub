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
    requested_at: Option<i64>,
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
                         AND json_type(record,'$.steps')='array')),
                    (SELECT json_extract(record,'$.requested_at') FROM claude_children
                     WHERE c.runtime='claude' AND launch=c.launch AND thread=c.thread)
             FROM native_children c JOIN journal p ON p.id=c.launch
             WHERE p.core_id=?1 AND p.address=?2 AND p.created_ms=?3 AND c.thread=?4 AND c.runtime=?5",
            params![core, address, created, thread, runtime],
            |r| Ok(Self { launch_key: r.get(0)?, parent: r.get(1)?, state: r.get(2)?,
                          active_turn: r.get(3)?, transcript: r.get(4)?, details: r.get(5)?, requested_at: r.get(6)? }),
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

pub(super) async fn read_gemini(
    State(w): State<Workspace>,
    Path((address, created, thread)): Path<(String, u64, String)>,
    Query(query): Query<ListingQuery>,
) -> Result<Json<Value>, ApiError> {
    activity(w, address, created, thread, query, "gemini").await
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
            Ok(true) if runtime == "gemini" => {
                crate::gemini_agent::children::refresh_live(w.history.file(), &child.launch_key).await;
                child = Child::load(&w, &core, &address, created, &thread, runtime)?;
            }
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
    let stop_requested = child.active_turn.is_some() && child.requested_at.is_some_and(|t| crate::history::now() - t < STOP_RETRY_MS);
    Ok(Json(
        json!({"stop_requested":stop_requested,"details":details,"transcript":child.transcript, "state":child.state, "active_turn":child.active_turn}),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Interrupt {
    turn: String,
}

// A second window or a retry after a lost response must not enqueue another copy immediately.
use crate::agent::claude_control::RETRY_MS as STOP_RETRY_MS;

pub(super) async fn request_claude_stop(
    State(w): State<Workspace>,
    Path((address, created, thread)): Path<(String, u64, String)>,
    Query(query): Query<ListingQuery>,
    Json(request): Json<Interrupt>,
) -> Result<Json<Value>, ApiError> {
    let core = query.core.ok_or(Failure::Missing)?;
    let child = Child::load(&w, &core, &address, created, &thread, "claude")?;
    if child.active_turn.as_deref() != Some(&request.turn) || child.state != "working"
        || !child.owner_is_live(&w, &core, &address, created).await?
    {
        return Err(ApiError::Conflict("This Claude helper run is no longer available."));
    }
    let now = crate::history::now();
    let claimed = w.history.db()?.execute(
        "UPDATE claude_children SET record=json_set(record,'$.requested_at',?1,'$.requested_prompt',NULL)
         WHERE launch=(SELECT id FROM journal WHERE launch_key=?2) AND thread=?3
         AND json_extract(summary,'$.active_turn')=?4 AND json_extract(summary,'$.state')='working'
         AND coalesce(json_extract(record,'$.requested_at'),0)<=?5",
        params![now, child.launch_key, thread, request.turn, now - STOP_RETRY_MS],
    ).map_err(StoreError::from)?;
    if claimed == 1 {
        let message = crate::Message {
            text: crate::agent::claude_control::message(&thread, &request.turn),
            expected_core: Some(core), turn_reference: None, reply_to: None,
        };
        if let Err(error) = crate::send_message(w.clone(), address, created, message, vec![]).await {
            if !matches!(error, ApiError::Core(Failure::Uncertain) | ApiError::Storage(_)) {
                w.history.db()?.execute(
                    "UPDATE claude_children SET record=json_remove(record,'$.requested_at')
                     WHERE launch=(SELECT id FROM journal WHERE launch_key=?) AND thread=?
                     AND json_extract(summary,'$.active_turn')=? AND json_extract(record,'$.requested_at')=?",
                    params![child.launch_key, thread, request.turn, now],
                ).map_err(StoreError::from)?;
            }
            return Err(error);
        }
    } else {
        let current = Child::load(&w, &core, &address, created, &thread, "claude")?;
        if current.active_turn.as_deref() != Some(&request.turn) || current.state != "working" {
            return Err(ApiError::Conflict("This Claude helper run already ended."));
        }
    }
    Ok(Json(json!({"requested_turn":request.turn})))
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
