use crate::{
    ApiError, Workspace, agent,
    core::{Failure, validate_task},
    groups::Target,
    history::{self, StoreError, now},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{StatusCode, header},
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const MAX_TASK: usize = 4 * 1024;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Suggestion {
    to: String,
    task: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Review {
    revision: i64,
    task: String,
}

#[derive(Serialize)]
struct Proposal {
    recipient: String,
    author: String,
    source: i64,
    excerpt: String,
    approved: Option<i64>,
    task: Option<String>,
    eligible: bool,
    revision: i64,
    core: String,
    target: Target,
    #[serde(skip)]
    target_launch: String,
    #[serde(skip)]
    author_launch: String,
    #[serde(skip)]
    token: String,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/group-handoffs.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/group-handoffs.js"),
                )
            }),
        )
        .route("/api/groups/{group}/handoffs/{message}", get(read))
        .route(
            "/api/groups/{group}/handoffs/{message}/approve",
            post(approve),
        )
        .route(
            "/api/groups/{group}/handoffs/{message}/dismiss",
            post(dismiss),
        )
}

fn proposal(db: &Connection, group: i64, message: i64) -> rusqlite::Result<Option<Proposal>> {
    db.query_row(
        "SELECT h.recipient,m.author,source.id,substr(source.text,1,320),approved.sent_message,h.task,g.revision,
                g.core,h.address,h.created_ms,h.launch_key,d.launch_key,d.token,
               (EXISTS(SELECT 1 FROM group_members a WHERE a.group_id=g.id AND a.address=d.address
                    AND a.created_ms=d.created_ms AND a.launch_key=d.launch_key)
                AND EXISTS(SELECT 1 FROM group_members t WHERE t.group_id=g.id AND t.address=h.address
                    AND t.created_ms=h.created_ms AND t.launch_key=h.launch_key))
           FROM group_handoffs h JOIN group_messages m ON m.id=h.message
           JOIN group_deliveries d ON d.id=m.delivery_id JOIN group_messages source ON source.id=d.message_id
           JOIN groups g ON g.id=m.group_id
           LEFT JOIN group_handoff_dispatches approved ON approved.proposal=m.id
          WHERE g.id=?1 AND m.id=?2",
        params![group,message],
        |r| Ok(Proposal {
            recipient: r.get(0)?, author: r.get(1)?, source: r.get(2)?, excerpt: r.get(3)?,
            approved: r.get(4)?, task: r.get(5)?, revision: r.get(6)?, core: r.get(7)?,
            target: Target { address: r.get(8)?, created_ms: r.get(9)? }, target_launch: r.get(10)?,
            author_launch: r.get(11)?, token: r.get(12)?, eligible: r.get(13)?,
        }),
    ).optional()
}

fn load(db: &Connection, group: i64, message: i64) -> Result<Proposal, ApiError> {
    proposal(db, group, message)
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)
}

async fn read(
    State(w): State<Workspace>,
    Path((group, message)): Path<(i64, i64)>,
) -> Result<Json<Proposal>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(load(&db, group, message)?))
}

fn validate(text: &str) -> Result<&str, Failure> {
    if text.len() > MAX_TASK {
        return Err(Failure::Input("Enter a follow-up up to 4 KiB."));
    }
    validate_task(text)?;
    Ok(text.trim())
}

fn shares_key(text: &str, keys: [&str; 3]) -> bool {
    let lower = text.to_ascii_lowercase();
    keys.into_iter()
        .any(|key| !key.is_empty() && lower.contains(&key.to_ascii_lowercase()))
}

async fn approve(
    State(w): State<Workspace>,
    Path((group, message)): Path<(i64, i64)>,
    Json(review): Json<Review>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let current = {
        let db = w.history.db()?;
        load(&db, group, message)?
    };
    if let Some(id) = current.approved {
        return Ok((StatusCode::ACCEPTED, Json(json!({"id":id}))));
    }
    if current.task.is_none() || !current.eligible {
        return Err(ApiError::Conflict(
            "This handoff is no longer available for this group.",
        ));
    }
    let task = validate(&review.task)?;
    if shares_key(
        task,
        [
            &current.token,
            &current.author_launch,
            &current.target_launch,
        ],
    ) {
        return Err(Failure::Input(
            "Remove the group reply token and session keys from the handoff.",
        )
        .into());
    }
    if w.core.identify().await?.core.id != current.core {
        return Err(ApiError::Conflict(
            "Reconnect this group’s Herdr Core before sending.",
        ));
    }
    let agent = w
        .core
        .agent(&current.target.address, current.target.created_ms)
        .await?;
    agent.require_live()?;
    if agent.launch_key() != Some(current.target_launch.as_str()) {
        return Err(ApiError::Conflict(
            "The proposed recipient’s session changed.",
        ));
    }
    crate::group_routes::send_handoff(
        w,
        group,
        message,
        review.revision,
        task.to_owned(),
        current.target,
    )
    .await
}

async fn dismiss(
    State(w): State<Workspace>,
    Path((group, message)): Path<(i64, i64)>,
) -> Result<Json<Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let current = load(&tx, group, message)?;
    if current.approved.is_some() {
        return Err(ApiError::Conflict("This handoff was already approved."));
    }
    tx.execute(
        "UPDATE group_handoffs SET task=NULL WHERE message=?1",
        [message],
    )
    .map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(json!({"dismissed":true})))
}

pub(crate) enum QueueGate {
    Ready,
    Already(i64),
    Unavailable,
}

pub(crate) fn queue_gate(
    db: &Connection,
    group: i64,
    message: i64,
    targets: &[Target],
    text: &str,
) -> rusqlite::Result<QueueGate> {
    let Some(current) = proposal(db, group, message)? else {
        return Ok(QueueGate::Unavailable);
    };
    if let Some(id) = current.approved {
        return Ok(QueueGate::Already(id));
    }
    Ok(
        if current.eligible
            && current.task.is_some()
            && targets == [current.target]
            && !shares_key(
                text,
                [
                    &current.token,
                    &current.author_launch,
                    &current.target_launch,
                ],
            )
        {
            QueueGate::Ready
        } else {
            QueueGate::Unavailable
        },
    )
}

pub(crate) struct Candidate {
    pub(crate) address: String,
    created_ms: u64,
    launch: String,
    pub(crate) name: String,
}

impl Candidate {
    pub(crate) fn choice(&self) -> String {
        format!("{} [{}]", self.name, self.address)
    }
}

pub(crate) fn candidates(db: &Connection, group: i64) -> rusqlite::Result<Vec<Candidate>> {
    db.prepare(
        "SELECT m.address,m.created_ms,m.launch_key,coalesce(p.name,m.name)
           FROM group_members m LEFT JOIN journal l ON l.launch_key=m.launch_key
           LEFT JOIN profiles p ON p.id=l.profile_id WHERE m.group_id=?1 ORDER BY m.address",
    )?
    .query_map([group], |r| {
        Ok(Candidate {
            address: r.get(0)?,
            created_ms: r.get(1)?,
            launch: r.get(2)?,
            name: r.get(3)?,
        })
    })?
    .collect()
}

fn publish_error(error: rusqlite::Error) -> &'static str {
    let _ = StoreError::from(error);
    "Could not save the group handoff."
}

pub fn publish() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, launch) = agent::session()?;
    let token = std::env::args_os()
        .nth(2)
        .and_then(|value| value.into_string().ok())
        .filter(|value| value.len() == 32 && value.bytes().all(|b| b.is_ascii_hexdigit()))
        .filter(|_| std::env::args_os().nth(3).is_none())
        .ok_or("Usage: swarmhub-herdr group-handoff TOKEN < handoff.json")?;
    let raw = agent::read_input(32 * 1024)?;
    let body: Suggestion = serde_json::from_str(&raw).map_err(|_| "Use JSON with to and task.")?;
    let name = body.to.trim();
    if name.is_empty() || name.len() > 320 || name.chars().any(char::is_control) {
        return Err("Choose one named current group member.".into());
    }
    let task =
        validate(&body.task).map_err(|_| "Enter one follow-up in plain text up to 4 KiB.")?;
    let mut db = history::connection(&journal).map_err(publish_error)?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(publish_error)?;
    let (delivery, group, address, author) = tx
        .query_row(
            "SELECT d.id,m.group_id,d.address,coalesce(p.name,d.name)
          FROM group_deliveries d JOIN group_messages m ON m.id=d.message_id
          JOIN group_members a ON a.group_id=m.group_id AND a.address=d.address
                AND a.created_ms=d.created_ms AND a.launch_key=d.launch_key
          LEFT JOIN journal l ON l.launch_key=d.launch_key LEFT JOIN profiles p ON p.id=l.profile_id
          WHERE d.token=?1 AND d.launch_key=?2 AND d.state!='not_sent'
            AND NOT EXISTS(SELECT 1 FROM group_handoff_dispatches sent WHERE sent.sent_message=m.id)",
            params![token, launch],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, i64>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                ))
            },
        )
        .optional()
        .map_err(publish_error)?
        .ok_or("This group delivery cannot propose a handoff.")?;
    if let Some(is_handoff) = tx.query_row(
        "SELECT h.message IS NOT NULL FROM group_messages m LEFT JOIN group_handoffs h ON h.message=m.id WHERE m.delivery_id=?1",
        [delivery],|r| r.get::<_,bool>(0),
    ).optional().map_err(publish_error)? {
        if is_handoff { println!("This delivery already has a handoff in the group."); return Ok(()); }
        return Err("This delivery already has a final reply.".into());
    }
    let available = candidates(&tx, group).map_err(publish_error)?;
    let mut named = available
        .iter()
        .filter(|item| item.address != address && (item.name == name || item.choice() == name));
    let target = named
        .next()
        .filter(|_| named.next().is_none())
        .ok_or("Use one unambiguous name from the current group, other than yourself.")?;
    if shares_key(task, [&token, &launch, &target.launch]) {
        return Err("Remove reply tokens and session keys from the handoff.".into());
    }
    let message: i64 = tx
        .query_row(
            "INSERT INTO group_messages(group_id,author,text,at_ms,delivery_id)
         VALUES (?1,?2,'A handoff was suggested.',?3,?4) RETURNING id",
            params![group, author, now(), delivery],
            |r| r.get(0),
        )
        .map_err(publish_error)?;
    tx.execute(
        "INSERT INTO group_handoffs(message,address,created_ms,launch_key,recipient,task) VALUES(?1,?2,?3,?4,?5,?6)",
        params![message,target.address,target.created_ms,target.launch,target.name,task],
    ).map_err(publish_error)?;
    tx.execute(
        "UPDATE group_deliveries SET draft_text=NULL,draft_ms=NULL WHERE id=?1",
        [delivery],
    )
    .map_err(publish_error)?;
    tx.commit().map_err(publish_error)?;
    println!("Handoff suggested for user review. No task was sent.");
    Ok(())
}
