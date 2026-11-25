use crate::{Workspace, history::StoreError};
use axum::{
    Json, Router,
    extract::{Path, State},
    http::{StatusCode, header},
    routing::{get, post},
};
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

#[derive(Serialize)]
struct CiFailure {
    id: i64,
    bot: String,
    pull_request: String,
    check_run: String,
    agent_name: String,
    notifications: bool,
}

fn ci_failures(db: &rusqlite::Connection) -> rusqlite::Result<Vec<CiFailure>> {
    db.prepare(
        "SELECT c.id, b.name, json_extract(c.schedule,'$.url'), json_extract(c.schedule,'$.failure'), b.agent_name, b.notifications
         FROM bot_checkins c JOIN bots b ON b.id=c.bot
         WHERE c.ci_reviewed=0 AND json_extract(c.schedule,'$.kind')='ci'
           AND json_extract(c.schedule,'$.failure') IS NOT NULL AND b.removed_ms IS NULL
         ORDER BY c.id DESC LIMIT 101",
    )?.query_map([], |row| Ok(CiFailure {
        id: row.get(0)?, bot: row.get(1)?, pull_request: row.get(2)?, check_run: row.get(3)?,
        agent_name: row.get(4)?, notifications: row.get(5)?,
    }))?.collect()
}

async fn review_ci(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<(StatusCode, Json<serde_json::Value>), StoreError> {
    let db = w.history.db()?;
    let changed = mark_ci_reviewed(&db, id)?;
    Ok(if changed {
        (StatusCode::OK, Json(json!({"reviewed":true})))
    } else {
        (
            StatusCode::NOT_FOUND,
            Json(json!({"error":"This failed check is unavailable."})),
        )
    })
}

fn mark_ci_reviewed(db: &rusqlite::Connection, id: i64) -> rusqlite::Result<bool> {
    Ok(db.execute(
        "UPDATE bot_checkins SET ci_reviewed=1 WHERE id=?1 AND json_extract(schedule,'$.kind')='ci'
           AND json_extract(schedule,'$.failure') IS NOT NULL
           AND EXISTS (SELECT 1 FROM bots WHERE bots.id=bot_checkins.bot AND removed_ms IS NULL)",
        [id],
    )? == 1)
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
        .route("/api/attention/ci/{id}/review", post(review_ci))
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
    let mut completions = crate::bots::completions::attention(&db)?;
    let mut parks = crate::parks::summaries(&db)?;
    let mut ci_failures = ci_failures(&db)?;
    let more = ci_failures.len() > 100
        || requests.len() > 100
        || webhook_reviews.len() > 100
        || completions.len() > 100
        || parks.len() > 100;
    ci_failures.truncate(100);
    parks.truncate(100);
    completions.truncate(100);
    requests.truncate(100);
    webhook_reviews.truncate(100);
    Ok(Json(
        json!({"ci_failures":ci_failures, "approvals":approvals, "requests":requests, "webhook_reviews":webhook_reviews, "completions":completions, "parks":parks, "more":more}),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rusqlite::params;

    #[test]
    fn ci_review_survives_reopen_and_leaves_the_wake_for_its_bot() {
        let (scratch, history) = crate::bots::testing::journal(&["Reviewer", "Retired"]);
        let db = history.db().unwrap();
        let pr = "https://github.com/example/repo/pull/42";
        let failure = "https://github.com/example/repo/runs/987";
        for (id, bot, link) in [
            (1, "reviewer-id", Some(failure)),
            (2, "reviewer-id", None),
            (3, "retired-id", Some(failure)),
        ] {
            db.execute("INSERT INTO bot_checkins (id,bot,what,schedule,next_ms,created_ms) VALUES (?1,?2,'inspect',?3,12345,1234)",
                params![id, bot, json!({"kind":"ci","url":pr,"failure":link}).to_string()]).unwrap();
        }
        db.execute("UPDATE bots SET removed_ms=10 WHERE id='retired-id'", [])
            .unwrap();
        let entries = ci_failures(&db).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(
            (
                &entries[0].id,
                entries[0].bot.as_str(),
                entries[0].check_run.as_str()
            ),
            (&1, "Reviewer", failure)
        );
        assert!(!mark_ci_reviewed(&db, 2).unwrap());
        assert!(!mark_ci_reviewed(&db, 3).unwrap());
        assert!(mark_ci_reviewed(&db, 1).unwrap());
        assert!(mark_ci_reviewed(&db, 1).unwrap());
        drop(db);
        drop(history);
        let history = crate::history::History::open_at(&scratch.path().join("workspace")).unwrap();
        let db = history.db().unwrap();
        assert!(ci_failures(&db).unwrap().is_empty());
        let state = db.query_row("SELECT state,next_ms,json_extract(schedule,'$.failure') FROM bot_checkins WHERE id=1", [],
            |r| Ok((r.get::<_,String>(0)?,r.get::<_,i64>(1)?,r.get::<_,String>(2)?))).unwrap();
        assert_eq!(state, ("planned".into(), 12345, failure.into()));
    }
}
