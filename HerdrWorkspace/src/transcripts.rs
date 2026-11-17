use crate::{ApiError, Workspace, file_download_response, grok_import, history::StoreError};
use axum::{
    Router,
    extract::{Path, State},
    response::Response,
    routing::get,
};
use rusqlite::{Connection, OpenFlags, OptionalExtension, Row, Transaction, params};
use std::{fmt::Write, time::Duration};

const LIMIT: usize = 16 * 1024 * 1024;
const TOO_LARGE: &str = "This conversation exceeds the 16 MiB transcript limit.";

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/history/{core}/{id}/{created}/transcript", get(direct))
        .route("/api/groups/{id}/transcript", get(group))
}

async fn direct(
    State(w): State<Workspace>,
    Path((core, id, created)): Path<(String, String, u64)>,
) -> Result<Response, ApiError> {
    download(w, move |db| {
        if core == grok_import::ARCHIVE_CORE {
            let archive = id
                .strip_prefix("archive-")
                .and_then(|id| id.parse::<i64>().ok())
                .filter(|_| created == 0)
                .ok_or(ApiError::NotFound)?;
            imported(db, archive)
        } else {
            direct_session(db, &core, &id, created)
        }
    })
    .await
}

async fn group(State(w): State<Workspace>, Path(id): Path<i64>) -> Result<Response, ApiError> {
    download(w, move |db| group_session(db, id)).await
}

async fn download(
    w: Workspace,
    render: impl FnOnce(&Transaction<'_>) -> Result<Transcript, ApiError> + Send + 'static,
) -> Result<Response, ApiError> {
    tokio::task::spawn_blocking(move || {
        let mut db =
            Connection::open_with_flags(w.history.file(), OpenFlags::SQLITE_OPEN_READ_ONLY)
                .map_err(StoreError::from)?;
        db.busy_timeout(Duration::from_secs(2))
            .map_err(StoreError::from)?;
        let txn = db.transaction().map_err(StoreError::from)?;
        let transcript = render(&txn)?;
        Ok(file_download_response(
            &filename(&transcript.title),
            transcript.output.into_bytes(),
        ))
    })
    .await
    .map_err(|_| StoreError)?
}

fn filename(title: &str) -> String {
    let stem: String = title
        .chars()
        .filter_map(|c| match c {
            'a'..='z' | 'A'..='Z' | '0'..='9' | '-' | '_' => Some(c),
            ' ' => Some('-'),
            _ => None,
        })
        .take(70)
        .collect();
    let stem = stem.trim_matches('-');
    format!(
        "{}.txt",
        if stem.is_empty() {
            "conversation"
        } else {
            stem
        }
    )
}

struct Transcript {
    title: String,
    output: String,
}

impl Transcript {
    fn new(title: String) -> Self {
        let output = format!("{}\nSwarmHub conversation transcript\n\n", one_line(&title));
        Self { title, output }
    }

    fn push(&mut self, row: RowText) -> Result<(), ApiError> {
        let timestamp = chrono::DateTime::from_timestamp_millis(row.at)
            .filter(|_| row.at > 0)
            .map(|at| at.format("%Y-%m-%d %H:%M:%S UTC").to_string());
        let mut block = format!("#{} {}", row.id, one_line(&row.author));
        if let Some(at) = timestamp {
            let _ = write!(block, " · {at}");
        }
        if let Some(related) = row.related {
            let _ = write!(block, " · reply to #{related}");
        }
        if let Some(state) = row.state {
            let _ = write!(block, " · {state}");
        }
        block.push('\n');
        if !row.text.is_empty() {
            block.extend(
                row.text
                    .chars()
                    .filter(|&c| !c.is_control() || matches!(c, '\n' | '\t')),
            );
            block.push('\n');
        }
        if let Some(files) = row.files {
            for name in files.lines() {
                let _ = writeln!(block, "File: {}", one_line(name));
            }
        }
        if self.output.len() + block.len() + 1 > LIMIT {
            return Err(ApiError::PayloadTooLarge(TOO_LARGE));
        }
        self.output.push_str(&block);
        self.output.push('\n');
        Ok(())
    }
}

fn one_line(text: &str) -> String {
    text.split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|c| !c.is_control())
        .collect()
}

struct RowText {
    id: i64,
    author: String,
    text: String,
    at: i64,
    related: Option<i64>,
    state: Option<&'static str>,
    files: Option<String>,
}

fn direct_row(row: &Row<'_>) -> rusqlite::Result<RowText> {
    let kind: String = row.get(1)?;
    let detail: Option<String> = row.get(5)?;
    let (author, text, state) = match kind.as_str() {
        "task" => (
            "You".into(),
            row.get(2)?,
            match row.get::<_, String>(4)?.as_str() {
                "pending" => Some("sending"),
                "not_sent" => Some("not sent"),
                "unconfirmed" => Some("delivery unconfirmed"),
                "start_not_observed" => Some("sent; start not observed"),
                _ => None,
            },
        ),
        "reply" => (row.get(6)?, row.get(2)?, None),
        _ => (kind, detail.unwrap_or_default(), None),
    };
    Ok(RowText {
        id: row.get(0)?,
        author,
        text,
        at: row.get(3)?,
        related: row.get(7)?,
        state,
        files: row.get(8)?,
    })
}

fn direct_session(
    db: &Transaction<'_>,
    core: &str,
    address: &str,
    created: u64,
) -> Result<Transcript, ApiError> {
    let title = db.query_row(
        "SELECT agent FROM journal WHERE core_id=?1 AND address=?2 AND created_ms=?3 ORDER BY id LIMIT 1",
        params![core,address,created], |row| row.get::<_, String>(0),
    ).optional().map_err(StoreError::from)?.ok_or(ApiError::NotFound)?;
    let mut transcript = Transcript::new(title);
    let mut stmt = db.prepare(&format!(
        "SELECT journal.id,CASE
                    WHEN kind='snapshot' THEN 'Terminal snapshot'
                    WHEN kind='attachment' THEN 'Attached file'
                    WHEN kind='artifact' AND page_id IS NOT NULL THEN 'Page'
                    WHEN kind='artifact' THEN 'Generated file' ELSE kind END,
                CASE WHEN kind IN ('task','reply') THEN journal.text ELSE '' END,
                at_ms,state,coalesce(workspace_pages.title,detail),agent,coalesce(in_reply_to,answers_task),
                (SELECT group_concat(name,char(10)) FROM
                 (SELECT name FROM direct_task_files WHERE task_id=journal.id ORDER BY id))
         FROM journal LEFT JOIN workspace_pages ON workspace_pages.id=journal.page_id
         WHERE core_id=?1 AND address=?2 AND created_ms=?3 AND {} ORDER BY journal.id",
        crate::warm::SHOWN
    )).map_err(StoreError::from)?;
    for item in stmt
        .query_map(params![core, address, created], direct_row)
        .map_err(StoreError::from)?
    {
        transcript.push(item.map_err(StoreError::from)?)?;
    }
    Ok(transcript)
}

fn group_session(db: &Transaction<'_>, id: i64) -> Result<Transcript, ApiError> {
    let title = db
        .query_row("SELECT name FROM groups WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    let mut transcript = Transcript::new(title);
    let mut stmt = db
        .prepare(
            "SELECT m.id,coalesce(m.author,'You'),m.text,m.at_ms,m.in_reply_to,m.is_question,
                (SELECT group_concat(name,char(10)) FROM
                    (SELECT name FROM group_attachments WHERE message_id=m.id ORDER BY id))
         FROM group_messages m WHERE group_id=?1 ORDER BY id",
        )
        .map_err(StoreError::from)?;
    for item in stmt
        .query_map([id], |row| {
            Ok(RowText {
                id: row.get(0)?,
                author: row.get(1)?,
                text: row.get(2)?,
                at: row.get(3)?,
                related: row.get(4)?,
                state: row.get::<_, bool>(5)?.then_some("input requested"),
                files: row.get(6)?,
            })
        })
        .map_err(StoreError::from)?
    {
        transcript.push(item.map_err(StoreError::from)?)?;
    }
    Ok(transcript)
}

fn imported(db: &Transaction<'_>, id: i64) -> Result<Transcript, ApiError> {
    let title = db
        .query_row("SELECT name FROM grok_imports WHERE id=?1", [id], |row| {
            row.get(0)
        })
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    let mut transcript = Transcript::new(title);
    let mut stmt = db.prepare(
        "SELECT m.seq,m.author,m.text,m.at_ms,m.attachment_count,
                (SELECT group_concat(name,char(10)) FROM
                    (SELECT name FROM grok_message_files WHERE archive=m.archive AND seq=m.seq ORDER BY name))
         FROM grok_messages m WHERE archive=?1 ORDER BY seq",
    ).map_err(StoreError::from)?;
    for item in stmt
        .query_map([id], |row| {
            let mut text = row.get::<_, String>(2)?;
            let files: Option<String> = row.get(5)?;
            grok_import::restore_attachment_marker(
                &mut text,
                row.get(4)?,
                files.as_deref().map_or(0, |names| names.lines().count()),
            );
            Ok(RowText {
                id: row.get(0)?,
                author: row.get(1)?,
                text,
                at: row.get(3)?,
                related: None,
                state: None,
                files,
            })
        })
        .map_err(StoreError::from)?
    {
        transcript.push(item.map_err(StoreError::from)?)?;
    }
    Ok(transcript)
}
