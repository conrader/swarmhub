use crate::{Workspace, history::StoreError};
use axum::{Json, Router, extract::State, http::header, routing::get};
use serde::Serialize;
use serde_json::json;

#[derive(Serialize)]
struct Request {
    id: i64,
    group: i64,
    group_name: String,
    core: String,
    address: String,
    created_ms: u64,
    agent: String,
    text: String,
    form: bool,
}

#[derive(Serialize)]
struct WebhookReview {
    id: i64,
    routine: i64,
    name: String,
    agent: String,
    at_ms: i64,
    terminal: (String, String, u64),
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/attention.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/attention.js"),
                )
            }),
        )
        .route("/api/attention", get(inbox))
}

async fn inbox(State(w): State<Workspace>) -> Result<Json<serde_json::Value>, StoreError> {
    let approvals = w.approvals.summary(&w.history)?;
    let db = w.history.db()?;
    let mut statement = db.prepare(
        "SELECT q.id, g.id, g.name, g.core, member.address, member.created_ms,
                q.author, substr(q.text,1,300), q.form_json IS NOT NULL
           FROM group_messages q
           JOIN groups g ON g.id=q.group_id
           JOIN group_deliveries origin ON origin.id=q.delivery_id
           JOIN group_members member ON member.group_id=g.id AND member.address=origin.address
             AND member.created_ms=origin.created_ms AND origin.message_id>member.joined_after
          WHERE q.is_question=1 AND q.author IS NOT NULL
            AND NOT EXISTS (
              SELECT 1 FROM group_messages answer
              JOIN group_deliveries delivery ON delivery.message_id=answer.id
              WHERE answer.in_reply_to=q.id AND delivery.state!='not_sent'
            )
          ORDER BY q.id DESC LIMIT 101",
    )?;
    let mut requests = statement
        .query_map([], |row| {
            Ok(Request {
                id: row.get(0)?,
                group: row.get(1)?,
                group_name: row.get(2)?,
                core: row.get(3)?,
                address: row.get(4)?,
                created_ms: row.get(5)?,
                agent: row.get(6)?,
                text: row.get(7)?,
                form: row.get(8)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut webhook_query = db.prepare(
        "SELECT w.id,r.id,r.name,r.agent,w.at_ms,r.core,r.address,r.created_ms
         FROM webhook_reviews w JOIN routines r ON r.id=w.routine
         WHERE w.dismissed=0 AND r.state!='archived'
         ORDER BY w.id DESC LIMIT 101",
    )?;
    let mut webhook_reviews = webhook_query
        .query_map([], |row| {
            Ok(WebhookReview {
                id: row.get(0)?,
                routine: row.get(1)?,
                name: row.get(2)?,
                agent: row.get(3)?,
                at_ms: row.get(4)?,
                terminal: (row.get(5)?, row.get(6)?, row.get(7)?),
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let more = requests.len() > 100 || webhook_reviews.len() > 100;
    requests.truncate(100);
    webhook_reviews.truncate(100);
    Ok(Json(
        json!({"approvals":approvals, "requests":requests, "webhook_reviews":webhook_reviews, "more":more}),
    ))
}
