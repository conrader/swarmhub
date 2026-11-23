use crate::{
    ApiError, Workspace,
    agent::shell_quote,
    core::Failure,
    deliver_task, file_download_response,
    history::{StoreError, connection, now},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{HeaderValue, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use rusqlite::{OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};

pub const MAX_MARKDOWN: usize = 96 * 1024;
const FIELDS: &str = "id,title,markdown,revision,updated_ms,owner_launch IS NOT NULL";
const CONFLICT: ApiError =
    ApiError::Conflict("This page changed. Copy your edits before opening the latest revision.");

#[derive(Serialize)]
struct Summary {
    id: i64,
    title: String,
    revision: i64,
    updated_ms: i64,
}

#[derive(Serialize)]
struct LibrarySummary {
    #[serde(flatten)]
    page: Summary,
    pinned: bool,
}

#[derive(Serialize)]
struct Page {
    #[serde(flatten)]
    summary: Summary,
    markdown: String,
    html: String,
    agent_owned: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    current_revision: Option<i64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Draft {
    title: String,
    markdown: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Edit {
    title: String,
    markdown: String,
    revision: i64,
}

#[derive(Deserialize)]
struct Export {
    revision: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChecklistChange {
    revision: i64,
    index: usize,
    checked: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Restore {
    current_revision: i64,
}

#[derive(Serialize)]
struct RevisionSummary {
    revision: i64,
    title: String,
    updated_ms: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Task {
    revision: i64,
    text: String,
}

#[derive(Serialize)]
struct Owner {
    core: String,
    address: String,
    created_ms: u64,
    name: String,
    #[serde(skip_serializing)]
    launch: String,
}

#[derive(Serialize)]
struct TaskRow {
    id: i64,
    text: String,
    revision: i64,
    state: String,
    detail: Option<String>,
    at_ms: i64,
}

fn owner(db: &rusqlite::Connection, id: i64) -> rusqlite::Result<Option<Owner>> {
    db.query_row(
        "SELECT j.core_id,j.address,j.created_ms,j.agent,j.launch_key
         FROM workspace_pages p JOIN journal j ON j.launch_key=p.owner_launch
         WHERE p.id=?1 AND j.address IS NOT NULL AND j.created_ms IS NOT NULL",
        [id],
        |row| {
            Ok(Owner {
                core: row.get(0)?,
                address: row.get(1)?,
                created_ms: row.get(2)?,
                name: row.get(3)?,
                launch: row.get(4)?,
            })
        },
    )
    .optional()
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/page-charts.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/page-charts.js"),
                )
            }),
        )
        .route(
            "/pages.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/pages.js"),
                )
            }),
        )
        .route(
            "/api/pages",
            get(list)
                .post(create)
                .layer(DefaultBodyLimit::max(640 * 1024)),
        )
        .route(
            "/api/pages/{id}",
            get(get_page)
                .post(edit)
                .layer(DefaultBodyLimit::max(640 * 1024)),
        )
        .route("/api/pages/{id}/download", get(download))
        .route("/api/pages/{id}/download/html", get(download_html))
        .route("/api/pages/{id}/revisions", get(revisions))
        .route("/api/pages/{id}/revisions/{revision}", get(get_revision))
        .route(
            "/api/pages/{id}/revisions/{revision}/restore",
            axum::routing::post(restore),
        )
        .route("/api/pages/{id}/checklist", axum::routing::post(checklist))
        .route("/api/pages/{id}/tasks", get(tasks).post(send_task))
}

async fn tasks(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, ApiError> {
    let db = w.history.db()?;
    let revision: i64 = db
        .query_row(
            "SELECT revision FROM workspace_pages WHERE id=?1",
            [id],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    let sender = owner(&db, id).map_err(StoreError::from)?;
    let mut q = db
        .prepare(
            "SELECT id,text,page_revision,state,detail,at_ms FROM journal
         WHERE page_id=?1 AND page_revision IS NOT NULL ORDER BY id DESC LIMIT 20",
        )
        .map_err(StoreError::from)?;
    let mut rows = q
        .query_map([id], |row| {
            Ok(TaskRow {
                id: row.get(0)?,
                text: row.get(1)?,
                revision: row.get(2)?,
                state: row.get(3)?,
                detail: row.get(4)?,
                at_ms: row.get(5)?,
            })
        })
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(StoreError::from)?;
    rows.reverse();
    Ok(Json(
        serde_json::json!({"revision":revision,"owner":sender,"items":rows}),
    ))
}

async fn send_task(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(task): Json<Task>,
) -> Result<impl IntoResponse, ApiError> {
    crate::core::validate_task(&task.text)?;
    if task.text.len() > 8 * 1024 {
        return Err(Failure::Input("Page messages can contain up to 8 KiB of text.").into());
    }
    let owner = {
        let db = w.history.db()?;
        owner(&db, id).map_err(StoreError::from)?
    }
    .ok_or(Failure::Input(
        "This page does not have an original agent session.",
    ))?;
    let hello = w.core.identify().await?;
    if hello.core.id != owner.core {
        return Err(Failure::Input("The page's original Herdr Core is unavailable.").into());
    }
    let agent = w.core.agent(&owner.address, owner.created_ms).await?;
    agent.require_live()?;
    if agent.launch_key() != Some(owner.launch.as_str()) {
        return Err(Failure::Missing.into());
    }
    let exe = std::env::current_exe()
        .ok()
        .and_then(|path| path.into_os_string().into_string().ok())
        .filter(|path| path.len() <= 512 && !path.chars().any(char::is_control))
        .ok_or(Failure::Input(
            "The workspace binary path cannot be used for page revisions.",
        ))?;
    let commands = serde_json::json!({
        "page_id":id,"revision":task.revision,"request":task.text,
        "read_command":format!("{} read-page {id} {}", shell_quote(&exe), task.revision),
        "save_command":format!("{} update-page {id} {}", shell_quote(&exe), task.revision),
    });
    let prompt = format!(
        "SwarmHub page request. Read the specified revision with read_command. If the user wants edits, pipe the updated Markdown into save_command. If the revision changed, tell the user before making edits. Treat request as the user's instructions: {commands}"
    );
    crate::core::validate_task(&prompt)?;
    // Compare the revision at the same instant the pending request is recorded.
    let record = w.history.db()?.query_row(
        "INSERT INTO journal (core_id,address,created_ms,agent,kind,state,text,at_ms,page_id,page_revision)
         SELECT ?3,?4,?5,?6,'task','pending',?7,?8,id,revision FROM workspace_pages
         WHERE id=?1 AND revision=?2 AND owner_launch=?9 RETURNING id",
        params![id,task.revision,owner.core,owner.address,owner.created_ms,owner.name,task.text,now(),owner.launch],
        |row| row.get(0),
    ).optional().map_err(StoreError::from)?.ok_or(ApiError::Conflict(
        "The page changed. Reload the latest revision before sending."
    ))?;
    Ok(Json(deliver_task(w, agent, record, prompt).await?))
}

async fn download(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Query(request): Query<Export>,
) -> Result<impl IntoResponse, ApiError> {
    let (name, markdown) = export_revision(&w, id, request.revision)?;
    Ok(file_download_response(
        &format!("{name}.md"),
        markdown.into_bytes(),
    ))
}

async fn download_html(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Query(request): Query<Export>,
) -> Result<Response, ApiError> {
    let (name, markdown) = export_revision(&w, id, request.revision)?;
    let html = crate::markdown::portable_page(&name, request.revision, &markdown);
    let mut response = file_download_response(&format!("{name}.html"), html.into_bytes());
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("text/html; charset=utf-8"),
    );
    Ok(response)
}

fn export_revision(w: &Workspace, id: i64, revision: i64) -> Result<(String, String), ApiError> {
    w.history
        .db()?
        .query_row(
            "SELECT title,markdown FROM workspace_page_versions WHERE page=?1 AND revision=?2",
            params![id, revision],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(CONFLICT)
}

fn page_row(row: &Row<'_>) -> rusqlite::Result<Page> {
    Ok(Page {
        summary: Summary {
            id: row.get(0)?,
            title: row.get(1)?,
            revision: row.get(3)?,
            updated_ms: row.get(4)?,
        },
        markdown: row.get(2)?,
        agent_owned: row.get(5)?,
        html: String::new(),
        current_revision: None,
    })
}

impl Page {
    fn rendered(mut self) -> Json<Self> {
        self.html = crate::markdown::page(&self.markdown);
        Json(self)
    }
}

async fn list(State(w): State<Workspace>) -> Result<Json<Vec<LibrarySummary>>, ApiError> {
    let db = w.history.db()?;
    let mut q = db
        .prepare(
            "SELECT p.id,p.title,p.revision,p.updated_ms,l.item_id IS NOT NULL AS pinned
        FROM workspace_pages p LEFT JOIN library_pins l ON l.item_id=p.id AND l.kind='page'
        ORDER BY pinned DESC,p.updated_ms DESC,p.id DESC LIMIT 200",
        )
        .map_err(StoreError::from)?;
    let rows = q
        .query_map([], |row| {
            Ok(LibrarySummary {
                page: Summary {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    revision: row.get(2)?,
                    updated_ms: row.get(3)?,
                },
                pinned: row.get(4)?,
            })
        })
        .and_then(|rows| rows.collect::<Result<_, _>>())
        .map_err(StoreError::from)?;
    Ok(Json(rows))
}

async fn get_page(State(w): State<Workspace>, Path(id): Path<i64>) -> Result<Json<Page>, ApiError> {
    let page = w
        .history
        .db()?
        .query_row(
            &format!("SELECT {FIELDS} FROM workspace_pages WHERE id=?1"),
            [id],
            page_row,
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    Ok(page.rendered())
}

async fn revisions(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let db = w.history.db()?;
    let mut query = db
        .prepare(
            "SELECT v.revision,v.title,v.updated_ms,p.revision FROM workspace_page_versions v
         JOIN workspace_pages p ON p.id=v.page WHERE v.page=?1 ORDER BY v.revision DESC",
        )
        .map_err(StoreError::from)?;
    let rows = query
        .query_map([id], |row| {
            Ok((
                RevisionSummary {
                    revision: row.get(0)?,
                    title: row.get(1)?,
                    updated_ms: row.get(2)?,
                },
                row.get::<_, i64>(3)?,
            ))
        })
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(StoreError::from)?;
    let current_revision = rows.first().ok_or(ApiError::NotFound)?.1;
    let items: Vec<_> = rows.into_iter().map(|(summary, _)| summary).collect();
    Ok(Json(
        serde_json::json!({"current_revision":current_revision,"items":items}),
    ))
}

async fn get_revision(
    State(w): State<Workspace>,
    Path((id, revision)): Path<(i64, i64)>,
) -> Result<Json<Page>, ApiError> {
    let page = w.history.db()?.query_row(
        "SELECT p.id,v.title,v.markdown,v.revision,v.updated_ms,p.owner_launch IS NOT NULL,p.revision
         FROM workspace_page_versions v JOIN workspace_pages p ON p.id=v.page WHERE v.page=?1 AND v.revision=?2",
        params![id,revision], |row| {
            let mut page = page_row(row)?;
            page.current_revision = Some(row.get(6)?);
            Ok(page)
        },
    ).optional().map_err(StoreError::from)?.ok_or(ApiError::NotFound)?;
    Ok(page.rendered())
}

async fn restore(
    State(w): State<Workspace>,
    Path((id, revision)): Path<(i64, i64)>,
    Json(body): Json<Restore>,
) -> Result<Json<Page>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let current: i64 = tx
        .query_row(
            "SELECT revision FROM workspace_pages WHERE id=?1",
            [id],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    if current != body.current_revision {
        return Err(ApiError::Conflict(
            "This page changed. Reload the latest revision before restoring.",
        ));
    }
    if revision >= current {
        return Err(Failure::Input("Choose an earlier saved revision to restore.").into());
    }
    let (title, markdown): (String, String) = tx
        .query_row(
            "SELECT title,markdown FROM workspace_page_versions WHERE page=?1 AND revision=?2",
            params![id, revision],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    let page = tx.query_row(
        &format!("UPDATE workspace_pages SET title=?2,markdown=?3,updated_ms=?4,revision=revision+1 WHERE id=?1 RETURNING {FIELDS}"),
        params![id,title,markdown,now()],page_row,
    ).map_err(StoreError::from)?;
    tx.commit().map_err(StoreError::from)?;
    Ok(page.rendered())
}

async fn create(
    State(w): State<Workspace>,
    Json(draft): Json<Draft>,
) -> Result<impl IntoResponse, ApiError> {
    let title = title(&draft.title).map_err(Failure::Input)?;
    validate_body(&draft.markdown).map_err(Failure::Input)?;
    let page = w.history.db()?.query_row(
        &format!("INSERT INTO workspace_pages (title,markdown,updated_ms) VALUES (?1,?2,?3) RETURNING {FIELDS}"),
        params![title,draft.markdown,now()], page_row,
    ).map_err(StoreError::from)?;
    Ok((StatusCode::CREATED, page.rendered()))
}

async fn edit(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<Edit>,
) -> Result<Json<Page>, ApiError> {
    let title = title(&body.title).map_err(Failure::Input)?;
    validate_body(&body.markdown).map_err(Failure::Input)?;
    let page = w.history.db()?.query_row(
        &format!("UPDATE workspace_pages SET title=?2,markdown=?3,updated_ms=?4,revision=revision+1 WHERE id=?1 AND revision=?5 RETURNING {FIELDS}"),
        params![id,title,body.markdown,now(),body.revision], page_row,
    ).optional().map_err(StoreError::from)?.ok_or(CONFLICT)?;
    Ok(page.rendered())
}

async fn checklist(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<ChecklistChange>,
) -> Result<Json<Page>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let mut page = tx
        .query_row(
            &format!("SELECT {FIELDS} FROM workspace_pages WHERE id=?1"),
            [id],
            page_row,
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    if page.summary.revision != body.revision {
        return Err(ApiError::Conflict(
            "This page changed. Reload the latest revision before checking an item.",
        ));
    }
    let changed = crate::markdown::check_task(&mut page.markdown, body.index, body.checked)
        .ok_or(Failure::Input("This checklist item is not in the page."))?;
    if changed {
        page = tx.query_row(
            &format!("UPDATE workspace_pages SET markdown=?2,updated_ms=?3,revision=revision+1 WHERE id=?1 RETURNING {FIELDS}"),
            params![id,page.markdown,now()],page_row,
        ).map_err(StoreError::from)?;
    }
    tx.commit().map_err(StoreError::from)?;
    Ok(page.rendered())
}

fn title(input: &str) -> Result<&str, &'static str> {
    let value = input.trim();
    if value.is_empty() || value.chars().count() > 100 || input.chars().any(char::is_control) {
        return Err("Enter a page title up to 100 characters.");
    }
    Ok(value)
}

fn validate_body(body: &str) -> Result<(), &'static str> {
    if body.trim().is_empty()
        || body.len() > MAX_MARKDOWN
        || body
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\r' | '\n' | '\t'))
    {
        return Err("Enter up to 96 KiB of Markdown text.");
    }
    Ok(())
}

fn can_access_page(db: &rusqlite::Connection, id: i64, launch: &str) -> rusqlite::Result<bool> {
    let owner_launch: Option<Option<String>> = db
        .query_row(
            "SELECT owner_launch FROM workspace_pages WHERE id=?1",
            [id],
            |row| row.get(0),
        )
        .optional()?;
    let Some(Some(owner_key)) = owner_launch else {
        return Ok(false);
    };
    if owner_key == launch {
        return Ok(true);
    }
    match (
        crate::bots::of_launch(db, &owner_key)?,
        crate::bots::of_launch(db, launch)?,
    ) {
        (crate::bots::Who::Bot(owner), crate::bots::Who::Bot(caller)) => {
            return Ok(owner.id == caller.id);
        }
        (crate::bots::Who::Helper, _) | (_, crate::bots::Who::Helper) => return Ok(false),
        _ => {}
    }
    db.query_row(
        "SELECT EXISTS(
            SELECT 1 FROM journal o, journal c
            WHERE o.launch_key=?1 AND c.launch_key=?2
              AND o.parent_bot_id != '' AND o.parent_bot_id = c.parent_bot_id
        )",
        params![owner_key, launch],
        |row| row.get(0),
    )
}

pub fn run(command: &str) -> Result<(), Box<dyn std::error::Error>> {
    let (journal, launch) = crate::agent::session()?;
    let mut args = std::env::args_os().skip(2);
    let first = args.next().and_then(|arg| arg.into_string().ok());
    let mut db = connection(&journal)?;
    run_with_db(command, first, &mut args, &mut db, &launch)
}

fn run_with_db(
    command: &str,
    first: Option<String>,
    args: &mut impl Iterator<Item = std::ffi::OsString>,
    db: &mut rusqlite::Connection,
    launch: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    match command {
        "publish-page" => {
            let name = first
                .as_deref()
                .filter(|_| args.next().is_none())
                .ok_or("Usage: swarmhub-herdr publish-page TITLE < document.md")?;
            let name = title(name)?;
            let body = crate::agent::read_input(MAX_MARKDOWN)?;
            validate_body(&body)?;
            let txn = db.transaction()?;
            let id: i64 = txn
                .query_row(
                    "INSERT INTO workspace_pages (owner_launch,title,markdown,updated_ms)
                 SELECT launch_key,?2,?3,?4 FROM journal WHERE launch_key=?1 RETURNING id",
                    params![launch, name, body, now()],
                    |row| row.get(0),
                )
                .optional()?
                .ok_or("This launch is not registered in the workspace.")?;
            txn.execute(
                "INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms,page_id)
                 SELECT launch_key,core_id,address,created_ms,agent,'artifact','saved','',?2,?3,?4 FROM journal WHERE launch_key=?1",
                params![launch,name,now(),id],
            )?;
            txn.commit()?;
            println!("Published page {id} (revision 1).");
        }
        "read-page" => {
            let id = first
                .as_deref()
                .and_then(|id| id.parse::<i64>().ok())
                .ok_or("Usage: swarmhub-herdr read-page PAGE_ID [REVISION]")?;
            let expected = args
                .next()
                .map(|value| {
                    value
                        .to_str()
                        .and_then(|value| value.parse::<i64>().ok())
                        .ok_or("Enter a valid page revision.")
                })
                .transpose()?;
            if args.next().is_some() {
                return Err("Usage: swarmhub-herdr read-page PAGE_ID [REVISION]".into());
            }
            if !can_access_page(db, id, launch)? {
                return Err("This page is not available to this agent session or its revision changed.".into());
            }
            let (revision, text): (i64, String) = db
                .query_row(
                    "SELECT revision,markdown FROM workspace_pages WHERE id=?1 AND (?2 IS NULL OR revision=?2)",
                    params![id, expected],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .optional()?
                .ok_or("This page is not available to this agent session or its revision changed.")?;
            eprintln!("Page {id}, revision {revision}.");
            print!("{text}");
        }
        "update-page" => {
            let id = first.as_deref().and_then(|id| id.parse::<i64>().ok());
            let revision = args
                .next()
                .and_then(|arg| arg.to_str()?.parse::<i64>().ok());
            let (id, revision) = id
                .zip(revision)
                .filter(|_| args.next().is_none())
                .ok_or("Usage: swarmhub-herdr update-page PAGE_ID REVISION < document.md")?;
            let body = crate::agent::read_input(MAX_MARKDOWN)?;
            validate_body(&body)?;
            let txn = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
            if !can_access_page(&txn, id, launch)? {
                return Err("The page is unavailable to this session or its revision changed.".into());
            }
            let revision: i64 = txn
                .query_row(
                    "UPDATE workspace_pages SET owner_launch=?3,markdown=?4,updated_ms=?5,revision=revision+1
                 WHERE id=?1 AND revision=?2 RETURNING revision",
                    params![id, revision, launch, body, now()],
                    |row| row.get(0),
                )
                .optional()?
                .ok_or("The page is unavailable to this session or its revision changed.")?;
            txn.commit()?;
            println!("Updated page {id} to revision {revision}.");
        }
        _ => return Err("Unknown page command.".into()),
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bot_keeps_access_to_its_own_pages_across_restarted_sessions_while_other_bots_cannot_read_them() {
        let scratch = tempfile::tempdir().unwrap();
        let history = crate::history::History::open_at(&scratch.path().join("data")).unwrap();
        let (_, old_launch) = history
            .start_launch("core", "gamedev-d68a68", "First", None, "{}", "")
            .unwrap()
            .unwrap();
        let (_, new_launch) = history
            .start_launch("core", "gamedev-d68a68", "Switched", None, "{}", "")
            .unwrap()
            .unwrap();
        let (_, other_bot) = history
            .start_launch("core", "jarvis-96d41f", "Other", None, "{}", "")
            .unwrap()
            .unwrap();
        let (_, unowned) = history
            .start_launch("core", "plain", "Plain", None, "{}", "")
            .unwrap()
            .unwrap();

        let mut db = connection(history.file()).unwrap();
        db.execute(
            "INSERT INTO bots (id,name,agent_name,main,template,model,instructions,projects,may_message,takes_messages,takes_initiative,notifications,created_ms,updated_ms)
             VALUES ('d68a68f9-532e-4154-9f7e-344413a57490','GameDev','gamedev-d68a68',0,'','','','[]',1,1,1,1,1,1),
                    ('96d41fba-b64c-4bbb-b242-43cfe48767c6','Jarvis','jarvis-96d41f',1,'','','','[]',1,1,1,1,1,1)",
            [],
        )
        .unwrap();
        db.execute(
            "INSERT INTO workspace_pages (id, owner_launch, title, markdown, revision, updated_ms)
             VALUES (1, ?1, 'Servo Release', '# v0.1.1', 1, 100)",
            params![old_launch],
        )
        .unwrap();

        let mut empty = std::iter::empty();
        run_with_db("read-page", Some("1".into()), &mut empty, &mut db, &new_launch).unwrap();

        let mut empty = std::iter::empty();
        assert!(run_with_db("read-page", Some("1".into()), &mut empty, &mut db, &other_bot).is_err());

        let mut empty = std::iter::empty();
        assert!(run_with_db("read-page", Some("1".into()), &mut empty, &mut db, &unowned).is_err());
    }
}
