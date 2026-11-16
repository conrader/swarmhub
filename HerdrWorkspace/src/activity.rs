use crate::{ApiError, Workspace, history::StoreError};
use axum::{
    Json, Router,
    extract::{Query, State},
    http::header,
    routing::{get, post},
};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
struct Cursor {
    before: Option<i64>,
    #[serde(default)]
    unread: bool,
}

#[derive(Serialize)]
struct Entry {
    id: i64,
    message: i64,
    kind: String,
    name: String,
    excerpt: String,
    at_ms: i64,
    unread: bool,
    core: Option<String>,
    address: Option<String>,
    created_ms: Option<u64>,
    group_id: Option<i64>,
    group_name: Option<String>,
}

#[derive(Serialize)]
struct Page {
    items: Vec<Entry>,
    before: Option<i64>,
}

#[derive(Deserialize)]
struct Since {
    after: Option<i64>,
}

#[derive(Serialize)]
struct Signal {
    id: i64,
    message: i64,
    profile: Option<i64>,
    core: Option<String>,
    address: Option<String>,
    created_ms: Option<u64>,
    group_id: Option<i64>,
}

#[derive(Serialize)]
struct Signals {
    cursor: i64,
    items: Vec<Signal>,
}

#[derive(Serialize)]
struct Unread {
    count: i64,
    core: Option<String>,
    address: Option<String>,
    created_ms: Option<u64>,
    group_id: Option<i64>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Read {
    Item {
        id: i64,
    },
    Through {
        id: i64,
    },
    Direct {
        core: String,
        address: String,
        created_ms: u64,
        through: i64,
    },
    Group {
        group: i64,
        through: i64,
    },
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/activity.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/activity.js"),
                )
            }),
        )
        .route(
            "/desktop-notices.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/desktop-notices.js"),
                )
            }),
        )
        .route("/api/activity", get(list))
        .route("/api/activity/unread", get(summary))
        .route("/api/activity/signals", get(signals))
        .route("/api/activity/read", post(mark_read))
}

async fn signals(
    State(w): State<Workspace>,
    Query(query): Query<Since>,
) -> Result<Json<Signals>, ApiError> {
    let db = w.history.db()?;
    let cursor: i64 = db
        .query_row(
            "SELECT coalesce(max(id),0) FROM workspace_activity",
            [],
            |row| row.get(0),
        )
        .map_err(StoreError::from)?;
    let Some(after) = query.after.filter(|id| *id >= 0 && *id < cursor) else {
        return Ok(Json(Signals {
            cursor,
            items: Vec::new(),
        }));
    };
    let mut q = db.prepare_cached(
        "SELECT a.id,coalesce(j.id,m.id),launch.profile_id,j.core_id,j.address,j.created_ms,m.group_id
         FROM workspace_activity a
         LEFT JOIN journal j ON j.id=a.journal_id
         LEFT JOIN journal launch ON launch.launch_key=j.reply_for
         LEFT JOIN group_messages m ON m.id=a.group_message_id
         WHERE a.id>?1 AND a.id<=?2 AND a.unread=1
           AND (m.group_id IS NOT NULL OR (j.address IS NOT NULL AND j.created_ms IS NOT NULL))
         ORDER BY a.id DESC LIMIT 50"
    ).map_err(StoreError::from)?;
    let items = q
        .query_map(params![after, cursor], |row| {
            Ok(Signal {
                id: row.get(0)?,
                message: row.get(1)?,
                profile: row.get(2)?,
                core: row.get(3)?,
                address: row.get(4)?,
                created_ms: row.get(5)?,
                group_id: row.get(6)?,
            })
        })
        .and_then(|rows| rows.collect::<Result<_, _>>())
        .map_err(StoreError::from)?;
    Ok(Json(Signals { cursor, items }))
}

async fn list(
    State(w): State<Workspace>,
    Query(query): Query<Cursor>,
) -> Result<Json<Page>, ApiError> {
    let db = w.history.db()?;
    let sql = "SELECT a.id,coalesce(j.id,m.id),
                   CASE WHEN m.id IS NOT NULL THEN 'group' WHEN j.kind='reply' THEN 'reply'
                    WHEN j.page_id IS NOT NULL THEN 'page' ELSE 'file' END,
                   coalesce(p.name,j.agent,m.author),
                   substr(CASE WHEN j.kind='artifact' THEN coalesce(pg.title,j.detail,'Saved result')
                         WHEN m.id IS NOT NULL AND trim(m.text)='' THEN 'Shared files'
                         ELSE coalesce(j.text,m.text,'') END,1,220),
                   coalesce(j.at_ms,m.at_ms),a.unread,j.core_id,j.address,j.created_ms,g.id,g.name
                FROM workspace_activity a
                LEFT JOIN journal j ON j.id=a.journal_id
                LEFT JOIN journal launch ON launch.launch_key=j.reply_for
                LEFT JOIN profiles p ON p.id=launch.profile_id
                LEFT JOIN workspace_pages pg ON pg.id=j.page_id
                LEFT JOIN group_messages m ON m.id=a.group_message_id
                LEFT JOIN groups g ON g.id=m.group_id
                WHERE a.id<?1 AND (?2=0 OR a.unread=1)
                  AND (g.id IS NOT NULL OR (j.address IS NOT NULL AND j.created_ms IS NOT NULL))
                ORDER BY a.id DESC LIMIT 31";
    let mut q = db.prepare_cached(sql).map_err(StoreError::from)?;
    let mut items = q
        .query_map(
            params![query.before.unwrap_or(i64::MAX), query.unread],
            |row| {
                Ok(Entry {
                    id: row.get(0)?,
                    message: row.get(1)?,
                    kind: row.get(2)?,
                    name: row.get(3)?,
                    excerpt: row.get(4)?,
                    at_ms: row.get(5)?,
                    unread: row.get(6)?,
                    core: row.get(7)?,
                    address: row.get(8)?,
                    created_ms: row.get(9)?,
                    group_id: row.get(10)?,
                    group_name: row.get(11)?,
                })
            },
        )
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(StoreError::from)?;
    let before = (items.len() > 30)
        .then(|| {
            items.truncate(30);
            items.last().map(|item| item.id)
        })
        .flatten();
    Ok(Json(Page { items, before }))
}

fn unread(db: &Connection) -> Result<Vec<Unread>, StoreError> {
    let mut q = db.prepare_cached(
        "SELECT count(*),j.core_id,j.address,j.created_ms,m.group_id
         FROM workspace_activity a
         LEFT JOIN journal j ON j.id=a.journal_id LEFT JOIN group_messages m ON m.id=a.group_message_id
         WHERE a.unread=1 AND (m.group_id IS NOT NULL OR (j.address IS NOT NULL AND j.created_ms IS NOT NULL))
         GROUP BY j.core_id,j.address,j.created_ms,m.group_id",
    )?;
    Ok(q.query_map([], |row| {
        Ok(Unread {
            count: row.get(0)?,
            core: row.get(1)?,
            address: row.get(2)?,
            created_ms: row.get(3)?,
            group_id: row.get(4)?,
        })
    })?
    .collect::<Result<_, _>>()?)
}

async fn summary(State(w): State<Workspace>) -> Result<Json<Vec<Unread>>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(unread(&db)?))
}

async fn mark_read(
    State(w): State<Workspace>,
    Json(scope): Json<Read>,
) -> Result<Json<Vec<Unread>>, ApiError> {
    let db = w.history.db()?;
    match scope {
        Read::Item { id } => db.execute(
            "UPDATE workspace_activity SET unread=0 WHERE unread=1 AND id=?1",
            [id],
        ),
        Read::Through { id } => db.execute(
            "UPDATE workspace_activity SET unread=0 WHERE unread=1 AND id<=?1",
            [id],
        ),
        Read::Direct {
            core,
            address,
            created_ms,
            through,
        } => db.execute(
            "UPDATE workspace_activity SET unread=0 WHERE unread=1 AND journal_id IN
             (SELECT id FROM journal WHERE core_id=?1 AND address=?2 AND created_ms=?3 AND id<=?4)",
            params![core, address, created_ms, through],
        ),
        Read::Group { group, through } => db.execute(
            "UPDATE workspace_activity SET unread=0 WHERE unread=1 AND group_message_id IN
             (SELECT id FROM group_messages WHERE group_id=?1 AND id<=?2)",
            params![group, through],
        ),
    }
    .map_err(StoreError::from)?;
    Ok(Json(unread(&db)?))
}
