//! Viewer links are separate capabilities for a single page. Their URLs never reach the server.
use crate::{
    ApiError, Workspace,
    history::{History, StoreError, now},
};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode, header},
    response::{Html, IntoResponse, Response},
    routing::get,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::{
    digest,
    rand::{SecureRandom, SystemRandom},
};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use std::time::Duration;

const LIFETIME: i64 = 7 * 24 * 60 * 60 * 1000;

pub(crate) fn start_cleanup(history: History) {
    tokio::spawn(async move {
        let mut clock = tokio::time::interval(Duration::from_secs(15 * 60));
        clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            clock.tick().await; // The initial tick also clears links that expired during downtime.
            if remove_expired(&history).is_err() {
                eprintln!("Could not clear expired Page viewer links.");
            }
        }
    });
}

fn remove_expired(history: &History) -> Result<(), StoreError> {
    history
        .db()?
        .execute("DELETE FROM page_shares WHERE expires_ms<=?1", [now()])?;
    Ok(())
}

#[derive(Serialize)]
struct Link {
    id: String,
    revision: i64,
    follow_latest: bool,
    expires_ms: i64,
}

impl Link {
    fn row(row: &Row<'_>) -> rusqlite::Result<Self> {
        Ok(Self {
            id: row.get(0)?,
            revision: row.get(1)?,
            follow_latest: row.get(2)?,
            expires_ms: row.get(3)?,
        })
    }
}

#[derive(Serialize)]
struct Status {
    link: Option<Link>,
}

#[derive(Serialize)]
struct Created {
    link: Link,
    token: String,
}

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Change {
    Create { revision: i64, follow_latest: bool },
    Revoke { id: String },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Cursor {
    after: Option<i64>,
}

#[derive(Serialize)]
struct SharedPage {
    revision: i64,
    title: String,
    html: String,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/pages/{id}/share", get(status).post(change))
        .route(
            "/page-share.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_str!("../web/page-share.js"),
                )
            }),
        )
        .route(
            "/page-tables.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_str!("../web/page-tables.js"),
                )
            }),
        )
        .route(
            "/view/page",
            get(|| async {
                (
                    [
                        (header::REFERRER_POLICY, "no-referrer"),
                        (
                            "x-robots-tag".parse().expect("static header"),
                            "noindex, nofollow",
                        ),
                    ],
                    Html(include_str!("../web/shared-page.html")),
                )
            }),
        )
        .route(
            "/view/page/viewer.js",
            get(|| async {
                asset(
                    "text/javascript; charset=utf-8",
                    include_str!("../web/shared-page.js"),
                )
            }),
        )
        .route(
            "/view/page/viewer.css",
            get(|| async {
                asset(
                    "text/css; charset=utf-8",
                    concat!(
                        include_str!("../web/page-export.css"),
                        "\n",
                        include_str!("../web/shared-page.css")
                    ),
                )
            }),
        )
        .route("/view/page/content", get(content))
}

fn asset(kind: &'static str, body: &'static str) -> impl IntoResponse {
    ([(header::CONTENT_TYPE, kind)], body)
}

async fn status(
    State(w): State<Workspace>,
    Path(page): Path<i64>,
) -> Result<Json<Status>, ApiError> {
    let db = w.history.db()?;
    if !db
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM workspace_pages WHERE id=?1)",
            [page],
            |row| row.get::<_, bool>(0),
        )
        .map_err(StoreError::from)?
    {
        return Err(ApiError::NotFound);
    }
    let link = db.query_row("SELECT link_id,revision,follow_latest,expires_ms FROM page_shares WHERE page=?1 AND expires_ms>?2", params![page, now()], Link::row)
        .optional().map_err(StoreError::from)?;
    Ok(Json(Status { link }))
}

async fn change(
    State(w): State<Workspace>,
    Path(page): Path<i64>,
    Json(body): Json<Change>,
) -> Result<Response, ApiError> {
    let mut db = w.history.db()?;
    let time = now();
    match body {
        Change::Create {
            revision,
            follow_latest,
        } => {
            let mut token = [0; 32];
            SystemRandom::new()
                .fill(&mut token)
                .map_err(|_| StoreError)?;
            let digest = digest::digest(&digest::SHA256, &token);
            let id = URL_SAFE_NO_PAD.encode(&digest.as_ref()[..16]);
            let expires_ms = time + LIFETIME;
            let tx = db.transaction().map_err(StoreError::from)?;
            tx.execute(
                "DELETE FROM page_shares WHERE page=?1 AND expires_ms<=?2",
                params![page, time],
            )
            .map_err(StoreError::from)?;
            let added = tx.execute(
                "INSERT INTO page_shares (page,link_id,token_digest,revision,title,markdown,follow_latest,expires_ms)
                 SELECT id,?2,?3,revision,title,CASE WHEN ?5 THEN '' ELSE markdown END,?5,?6 FROM workspace_pages
                 WHERE id=?1 AND revision=?4 ON CONFLICT(page) DO NOTHING",
                params![page, id, digest.as_ref(), revision, follow_latest, expires_ms],
            ).map_err(StoreError::from)?;
            if added != 1 {
                return Err(ApiError::Conflict(
                    "The Page or its viewer link changed. Reopen sharing to review the current state.",
                ));
            }
            tx.commit().map_err(StoreError::from)?;
            Ok((
                StatusCode::CREATED,
                Json(Created {
                    link: Link {
                        id,
                        revision,
                        follow_latest,
                        expires_ms,
                    },
                    token: URL_SAFE_NO_PAD.encode(token),
                }),
            )
                .into_response())
        }
        Change::Revoke { id } => {
            if id.len() != 22
                || db
                    .execute(
                        "DELETE FROM page_shares WHERE page=?1 AND link_id=?2 AND expires_ms>?3",
                        params![page, id, time],
                    )
                    .map_err(StoreError::from)?
                    != 1
            {
                return Err(ApiError::Conflict(
                    "The viewer link changed or expired. Reopen sharing to check it.",
                ));
            }
            Ok(Json(Status { link: None }).into_response())
        }
    }
}

async fn content(
    State(w): State<Workspace>,
    headers: HeaderMap,
    Query(cursor): Query<Cursor>,
) -> Result<Response, ApiError> {
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("PageLink "))
        .filter(|value| value.len() == 43)
        .and_then(|value| URL_SAFE_NO_PAD.decode(value).ok())
        .filter(|value| value.len() == 32)
        .ok_or(ApiError::NotFound)?;
    let digest = digest::digest(&digest::SHA256, &token);
    // Check the link, its expiry and the page content in the same read, even for an unchanged revision.
    let (revision, title, markdown) = w.history.db()?.query_row(
        "WITH shared(revision,title,markdown) AS (
           SELECT CASE WHEN s.follow_latest THEN p.revision ELSE s.revision END,
                  CASE WHEN s.follow_latest THEN p.title ELSE s.title END,
                  CASE WHEN s.follow_latest THEN p.markdown ELSE s.markdown END
           FROM page_shares s JOIN workspace_pages p ON p.id=s.page WHERE s.token_digest=?1 AND s.expires_ms>?2
         ) SELECT revision, CASE WHEN revision=?3 THEN NULL ELSE title END,
                            CASE WHEN revision=?3 THEN NULL ELSE markdown END FROM shared",
        params![digest.as_ref(), now(), cursor.after],
        |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?, row.get::<_, Option<String>>(2)?)),
    ).optional().map_err(StoreError::from)?.ok_or(ApiError::NotFound)?;
    if cursor.after == Some(revision) {
        return Ok(StatusCode::NO_CONTENT.into_response());
    }
    Ok(Json(SharedPage {
        revision,
        title: title.ok_or(StoreError)?,
        html: crate::markdown::page(&markdown.ok_or(StoreError)?),
    })
    .into_response())
}
