use crate::{ApiError, Workspace, core::Failure, history::StoreError};
use axum::{
    Json, Router,
    extract::{Query, State},
    http::header,
    routing::get,
};
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use std::time::Duration;
use tokio::sync::Semaphore;

static QUERIES: Semaphore = Semaphore::const_new(2);

#[derive(Deserialize)]
struct Search {
    q: String,
    kind: Option<String>,
}

#[derive(Serialize)]
struct Hit {
    kind: &'static str,
    id: i64,
    title: String,
    excerpt: String,
    core: Option<String>,
    address: Option<String>,
    created_ms: Option<u64>,
    group_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    task_id: Option<i64>,
}

// Search saved content directly. Each query has its own result limit so a
// busy conversation cannot crowd out Pages or files in the combined view.
const MATCHES: &[(&str, &str, &str)] = &[
    ("agents", "agent", "SELECT p.id,p.name,
           trim(p.subtitle || CASE WHEN p.hidden THEN ' · Hidden' ELSE '' END ||
                coalesce(' · ' || s.name,''),' ·'),NULL,NULL,NULL,NULL
         FROM profiles p LEFT JOIN roster_sections s ON s.id=p.section_id
         WHERE instr(lower(p.name || ' ' || p.runtime_name || ' ' || p.subtitle || coalesce(' ' || s.name,'')),lower(?1))>0
         ORDER BY (lower(p.name)=lower(?1)) DESC,p.pinned DESC,p.id DESC LIMIT ?2"),
    ("groups", "group", "SELECT id,name,'',NULL,NULL,NULL,NULL
         FROM groups WHERE instr(lower(name),lower(?1))>0
         ORDER BY (lower(name)=lower(?1)) DESC,id DESC LIMIT ?2"),
    ("skills", "skill", "SELECT id,name,
           (CASE WHEN archived THEN 'Archived · ' ELSE '' END) ||
           (CASE WHEN instr(lower(instructions),lower(?1))>0
                THEN substr(instructions,max(1,instr(lower(instructions),lower(?1))-45),190)
                ELSE summary END),NULL,NULL,NULL,NULL
         FROM skills WHERE instr(lower(name),lower(?1))>0 OR instr(lower(summary),lower(?1))>0
           OR instr(lower(instructions),lower(?1))>0
         ORDER BY (lower(name)=lower(?1)) DESC,archived,updated_ms DESC,id DESC LIMIT ?2"),
    ("routines", "routine", "SELECT id,name,
           (CASE state WHEN 'paused' THEN 'Paused' WHEN 'archived' THEN 'Archived' ELSE 'Active' END) ||
           ' · ' || substr(task,max(1,instr(lower(task),lower(?1))-45),190),NULL,NULL,NULL,NULL
         FROM routines WHERE instr(lower(name),lower(?1))>0 OR instr(lower(task),lower(?1))>0
         ORDER BY (lower(name)=lower(?1)) DESC,(state='archived'),id DESC LIMIT ?2"),
    ("routines", "routine-draft", "SELECT d.id,d.name,
           'Imported · Needs setup' || CASE WHEN length(d.task)>0 THEN ' · ' || substr(d.task,max(1,instr(lower(d.task),lower(?1))-45),190) ELSE '' END,
           NULL,NULL,NULL,NULL FROM grok_routine_drafts d JOIN grok_imports i ON i.id=d.archive
           JOIN profiles p ON p.id=i.profile
         WHERE d.dismissed=0 AND d.routine_id IS NULL
           AND (instr(lower(d.name),lower(?1))>0 OR instr(lower(d.task),lower(?1))>0)
         ORDER BY (lower(d.name)=lower(?1)) DESC,d.id DESC LIMIT ?2"),
    ("pages", "page", "SELECT id,title,substr(markdown,max(1,instr(lower(markdown),lower(?1))-45),190),NULL,NULL,NULL,NULL
         FROM workspace_pages WHERE instr(lower(title),lower(?1))>0 OR instr(lower(markdown),lower(?1))>0
         ORDER BY (lower(title)=lower(?1)) DESC,(instr(lower(title),lower(?1))>0) DESC,updated_ms DESC,id DESC LIMIT ?2"),
    ("files", "file", "SELECT j.id,j.detail,j.agent,NULL,NULL,NULL,NULL
         FROM journal j JOIN artifacts a ON a.id=j.id
         WHERE j.kind='artifact' AND instr(lower(j.detail),lower(?1))>0
         ORDER BY (lower(j.detail)=lower(?1)) DESC,j.id DESC LIMIT ?2"),
    ("files", "group-file", "SELECT f.id,f.name,g.name,NULL,NULL,NULL,g.id
         FROM group_attachments f JOIN group_messages m ON m.id=f.message_id JOIN groups g ON g.id=m.group_id
         WHERE instr(lower(f.name),lower(?1))>0 ORDER BY (lower(f.name)=lower(?1)) DESC,f.id DESC LIMIT ?2"),
    ("files", "task-file", "SELECT f.id,f.name,j.agent,j.core_id,j.address,j.created_ms,NULL,j.id
         FROM direct_task_files f JOIN journal j ON j.id=f.task_id
         WHERE j.address IS NOT NULL AND j.created_ms IS NOT NULL AND instr(lower(f.name),lower(?1))>0
         ORDER BY (lower(f.name)=lower(?1)) DESC,f.id DESC LIMIT ?2"),
    ("snapshots", "snapshot", "SELECT id,detail,agent,NULL,NULL,NULL,NULL
         FROM journal WHERE kind='snapshot' AND instr(lower(detail),lower(?1))>0
         ORDER BY (lower(detail)=lower(?1)) DESC,id DESC LIMIT ?2"),
    ("messages", "message", "SELECT id,title,substr(text,max(1,instr(lower(text),lower(?1))-45),190),core,address,created,NULL FROM (
           SELECT id,agent AS title,text,core_id AS core,address,created_ms AS created,at_ms
           FROM journal WHERE kind IN ('task','reply') AND address IS NOT NULL AND created_ms IS NOT NULL
           UNION ALL
           SELECT m.seq,i.name,m.text,'import:grok-bot','archive-' || i.id,0,m.at_ms
           FROM grok_messages m JOIN grok_imports i ON i.id=m.archive
         ) WHERE instr(lower(text),lower(?1))>0 ORDER BY at_ms DESC,id DESC LIMIT ?2"),
    ("messages", "group-message", "SELECT m.id,coalesce(m.author,'You') || ' · ' || g.name,
           substr(m.text,max(1,instr(lower(m.text),lower(?1))-45),190),NULL,NULL,NULL,g.id
         FROM group_messages m JOIN groups g ON g.id=m.group_id
         WHERE instr(lower(m.text),lower(?1))>0 ORDER BY m.at_ms DESC,m.id DESC LIMIT ?2"),
];

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/search.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/search.js"),
                )
            }),
        )
        .route("/api/search", get(search))
}

async fn search(
    State(w): State<Workspace>,
    Query(query): Query<Search>,
) -> Result<Json<Vec<Hit>>, ApiError> {
    let term = query.q.trim();
    if term.chars().count() > 120 || term.chars().any(char::is_control) {
        return Err(Failure::Input("Enter a search up to 120 characters.").into());
    }
    let kind = query.kind.as_deref();
    if kind.is_some_and(|kind| !MATCHES.iter().any(|(category, _, _)| *category == kind)) {
        return Err(Failure::Input("Choose a search category.").into());
    }
    if term.is_empty() {
        return Ok(Json(Vec::new()));
    }
    let permit = tokio::time::timeout(Duration::from_secs(1), QUERIES.acquire())
        .await
        .map_err(|_| ApiError::Conflict("Search is busy. Try again in a moment."))?
        .map_err(|_| StoreError)?;
    let path = w.history.file().to_path_buf();
    let term = term.to_owned();
    let result = tokio::task::spawn_blocking(move || {
        let _permit = permit;
        // Read independently of the live journal so searches don't hold up delivery commits.
        let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        db.busy_timeout(Duration::from_secs(2))?;
        collect(&db, &term, query.kind.as_deref())
    })
    .await
    .map_err(|_| StoreError)?;
    Ok(Json(result.map_err(StoreError::from)?))
}

fn collect(db: &Connection, term: &str, kind: Option<&str>) -> rusqlite::Result<Vec<Hit>> {
    let mut hits = Vec::new();
    for (category, label, sql) in MATCHES {
        if kind.is_some_and(|kind| kind != *category) {
            continue;
        }
        let limit = if kind.is_some() { 40 } else { 8 };
        let mut q = db.prepare_cached(sql)?;
        let rows = q
            .query_map(params![term, limit], |row| {
                Ok(Hit {
                    kind: label,
                    id: row.get(0)?,
                    title: row.get(1)?,
                    excerpt: row.get(2)?,
                    core: row.get(3)?,
                    address: row.get(4)?,
                    created_ms: row.get(5)?,
                    group_id: row.get(6)?,
                    task_id: if *label == "task-file" {
                        Some(row.get(7)?)
                    } else {
                        None
                    },
                })
            })
            .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())?;
        hits.extend(rows);
    }
    Ok(hits)
}
