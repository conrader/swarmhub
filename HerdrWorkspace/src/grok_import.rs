use crate::{
    ApiError, Workspace,
    core::{Failure, MAX_FILE, valid_filename},
    file_download_response,
    history::{History, StoreError, connection, now},
};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Multipart, Path, State},
    http::header,
    response::Response,
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

mod skill_drafts;

pub const ARCHIVE_CORE: &str = "import:grok-bot";
const FORMAT: &str = "agentapp-bot-bundle/v1";
const LIMIT: usize = 16 * 1024 * 1024;

#[derive(Deserialize)]
struct Bundle {
    format: String,
    source_id: String,
    name: Option<String>,
    slug: Option<String>,
    instructions: Option<String>,
    description: Option<String>,
    #[serde(default)]
    is_group: bool,
    avatar: Option<OriginalAvatar>,
    #[serde(default)]
    messages: Vec<Message>,
    #[serde(default)]
    routines: Vec<Value>,
    #[serde(default)]
    skills: Vec<Value>,
    #[serde(default)]
    connectors: Vec<Value>,
}

#[derive(Deserialize)]
struct OriginalAvatar {
    shape: Option<String>,
}

#[derive(Deserialize)]
struct Message {
    id: Option<String>,
    seq: Option<i64>,
    role: String,
    author: Option<String>,
    text: Option<String>,
    timestamp: Option<String>,
    #[serde(default)]
    hidden: bool,
    #[serde(default)]
    attachments: Vec<Value>,
}

#[derive(Serialize)]
struct Preview {
    name: String,
    is_group: bool,
    instructions: String,
    visible_messages: usize,
    skipped_messages: usize,
    shortened_messages: usize,
    routines: usize,
    skipped_routines: usize,
    connectors: usize,
    skills: usize,
    attachments: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    attachment_names: Vec<String>,
    already_saved: bool,
}

struct Prepared {
    key: String,
    slug: String,
    avatar: &'static str,
    label: String,
    preview: Preview,
    messages: Vec<Line>,
    routines: Vec<crate::routine_drafts::Imported>,
}

struct Line {
    source: Option<String>,
    seq: i64,
    role: String,
    author: String,
    text: String,
    at_ms: i64,
    attachment_count: usize,
    filenames: HashSet<String>,
}

#[derive(Serialize)]
pub struct Archive {
    core: &'static str,
    address: String,
    created_ms: u64,
    agent: String,
    at_ms: i64,
    is_group: bool,
    profile_id: Option<i64>,
}

#[derive(Serialize)]
struct Saved {
    archive: Archive,
    added: usize,
    routine_drafts: usize,
    #[serde(skip_serializing_if = "is_zero")]
    added_files: usize,
}

fn is_zero(count: &usize) -> bool {
    *count == 0
}

#[derive(Serialize)]
pub struct Page {
    items: Vec<Row>,
    before: Option<i64>,
}

#[derive(Serialize)]
struct Row {
    id: i64,
    kind: &'static str,
    detail: String,
    text: String,
    at_ms: i64,
    #[serde(skip)]
    attachment_count: usize,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    attachments: Vec<String>,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .merge(skill_drafts::routes())
        .route(
            "/grok-import.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/grok-import.js"),
                )
            }),
        )
        .route(
            "/api/grok-imports",
            get(list).post(save).layer(DefaultBodyLimit::max(LIMIT)),
        )
        .route(
            "/api/grok-imports/export-helper",
            get(|| async {
                crate::file_download_response(
                    "swarmhub-grok-export.pyz",
                    include_bytes!(concat!(env!("OUT_DIR"), "/swarmhub-grok-export.pyz")).to_vec(),
                )
            }),
        )
        .route(
            "/api/grok-imports/preview",
            post(preview).layer(DefaultBodyLimit::max(LIMIT)),
        )
        .route(
            "/api/grok-imports/with-files",
            post(save_with_files).layer(DefaultBodyLimit::max(LIMIT + MAX_FILE + 128 * 1024)),
        )
        .route(
            "/api/grok-imports/{archive}/attachments/{name}",
            get(download_attachment),
        )
}

fn field(text: &str, chars: usize, bytes: usize, multiline: bool) -> String {
    let mut result = String::new();
    for c in text
        .trim()
        .chars()
        .filter(|&c| !c.is_control() || (multiline && matches!(c, '\n' | '\t')))
        .take(chars)
    {
        if result.len() + c.len_utf8() > bytes {
            break;
        }
        result.push(c);
    }
    result
}

fn prepare(bytes: &[u8]) -> Result<Prepared, ApiError> {
    let bytes = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    let bundle: Bundle = serde_json::from_slice(bytes).map_err(|_| {
        Failure::Input("Choose a Grok Bot bundle.json file from the export folder.")
    })?;
    if bundle.format != FORMAT
        || !(8..=160).contains(&bundle.source_id.len())
        || !bundle
            .source_id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(&c))
    {
        return Err(Failure::Input("This file is not a supported Grok Bot export bundle.").into());
    }
    if bundle.messages.len() > 30_000 {
        return Err(Failure::Input("This export has more than 30,000 messages.").into());
    }
    let mut name = field(bundle.name.as_deref().unwrap_or(""), 60, 240, false);
    if name.is_empty() {
        name = "Grok Bot conversation".into();
    }
    let label = field(bundle.description.as_deref().unwrap_or(""), 80, 320, false);
    let instructions = if bundle.is_group {
        String::new()
    } else {
        field(
            bundle
                .instructions
                .as_deref()
                .or(bundle.description.as_deref())
                .unwrap_or(""),
            usize::MAX,
            6144,
            true,
        )
    };
    let slug: String = bundle
        .slug
        .as_deref()
        .unwrap_or("bot")
        .bytes()
        .map(|ch| ch.to_ascii_lowercase())
        .filter(|ch| ch.is_ascii_alphanumeric() || *ch == b'-')
        .take(12)
        .map(char::from)
        .collect();
    let avatar = match bundle.avatar.and_then(|avatar| avatar.shape).as_deref() {
        Some("star" | "spark" | "sparkle") => "spark",
        Some("gem" | "diamond" | "stack") => "layers",
        Some("circle" | "target") => "target",
        _ => "initial",
    };
    let routine_count = bundle.routines.len();
    let routines = if bundle.is_group {
        Vec::new()
    } else {
        crate::routine_drafts::from_export(bundle.routines)
    };
    let mut summary = Preview {
        name,
        is_group: bundle.is_group,
        instructions,
        visible_messages: 0,
        skipped_messages: 0,
        shortened_messages: 0,
        routines: routines.len(),
        skipped_routines: routine_count - routines.len(),
        skills: bundle.skills.len(),
        connectors: bundle.connectors.len(),
        attachments: 0,
        attachment_names: vec![],
        already_saved: false,
    };
    let mut lines = Vec::new();
    let mut seen = HashSet::new();
    let mut seen_ids = HashSet::new();
    let mut attachment_names = HashSet::new();
    for entry in bundle.messages {
        let Some(seq) = entry
            .seq
            .filter(|seq| (0..9_007_199_254_740_990).contains(seq))
        else {
            summary.skipped_messages += 1;
            continue;
        };
        if entry.hidden || !matches!(entry.role.as_str(), "user" | "assistant" | "system") {
            summary.skipped_messages += 1;
            continue;
        }
        let raw = entry.text.as_deref().unwrap_or("");
        let mut text = field(raw, usize::MAX, 128 * 1024, true);
        let shortened = raw.trim().len() > 128 * 1024;
        if shortened {
            text.push_str("\n\n[Message shortened during import]");
        }
        let files = entry.attachments.len();
        if files > 0 {
            if !text.is_empty() {
                text.push_str("\n\n");
            }
            text.push_str(&missing_marker(files));
        }
        let source = entry
            .id
            .filter(|id| !id.is_empty() && id.len() <= 256 && !id.chars().any(char::is_control));
        if text.is_empty()
            || seen.contains(&seq)
            || source.as_ref().is_some_and(|id| seen_ids.contains(id))
        {
            summary.skipped_messages += 1;
            continue;
        }
        seen.insert(seq);
        if let Some(id) = &source {
            seen_ids.insert(id.clone());
        }
        summary.attachments += files;
        let filenames: HashSet<String> = entry
            .attachments
            .iter()
            .filter_map(|attachment| {
                attachment
                    .get("file")?
                    .as_str()?
                    .strip_prefix("attachments/")
            })
            .filter(|name| valid_filename(name) && !name.starts_with('.'))
            .map(str::to_owned)
            .collect();
        for name in &filenames {
            if attachment_names.len() < 256 {
                attachment_names.insert(name.clone());
            }
        }
        summary.shortened_messages += usize::from(shortened);
        let mut author = field(entry.author.as_deref().unwrap_or(""), 80, 320, false);
        if author.is_empty() {
            author = match entry.role.as_str() {
                "user" => "You".into(),
                "system" => "Grok Bot notice".into(),
                _ => summary.name.clone(),
            };
        }
        let at_ms = entry
            .timestamp
            .as_deref()
            .and_then(|stamp| chrono::DateTime::parse_from_rfc3339(stamp).ok())
            .map(|stamp| stamp.timestamp_millis())
            .filter(|at| *at > 0)
            .unwrap_or(0);
        lines.push(Line {
            source,
            seq,
            role: entry.role,
            author,
            text,
            at_ms,
            attachment_count: files,
            filenames,
        });
    }
    summary.attachment_names = attachment_names.into_iter().collect();
    summary.attachment_names.sort_unstable();
    summary.visible_messages = lines.len();
    Ok(Prepared {
        key: bundle.source_id,
        slug,
        avatar,
        label,
        preview: summary,
        messages: lines,
        routines,
    })
}

fn archive_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Archive> {
    let id: i64 = row.get(0)?;
    let name: String = row.get(1)?;
    Ok(Archive {
        core: ARCHIVE_CORE,
        address: format!("archive-{id}"),
        created_ms: 0,
        agent: name,
        at_ms: row.get(2)?,
        is_group: row.get(3)?,
        profile_id: row.get(4)?,
    })
}

const ARCHIVE_FIELDS: &str = "id,name,updated_ms,is_group,profile";

async fn list(State(w): State<Workspace>) -> Result<Json<Vec<Archive>>, StoreError> {
    let db = w.history.db()?;
    let mut query = db.prepare(&format!(
        "SELECT {ARCHIVE_FIELDS} FROM grok_imports ORDER BY updated_ms DESC,id DESC"
    ))?;
    Ok(Json(
        query
            .query_map([], archive_row)?
            .collect::<rusqlite::Result<_>>()?,
    ))
}

pub fn for_profiles(db: &Connection) -> Result<HashMap<i64, Archive>, StoreError> {
    let mut query = db.prepare(&format!(
        "SELECT {ARCHIVE_FIELDS} FROM grok_imports WHERE profile IS NOT NULL"
    ))?;
    let mut archives = HashMap::new();
    for item in query.query_map([], archive_row)? {
        let item = item?;
        if let Some(profile) = item.profile_id {
            archives.insert(profile, item);
        }
    }
    Ok(archives)
}

async fn preview(State(w): State<Workspace>, bytes: Bytes) -> Result<Json<Preview>, ApiError> {
    tokio::task::spawn_blocking(move || {
        let mut item = prepare(&bytes)?;
        item.preview.already_saved = w
            .history
            .db()?
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM grok_imports WHERE source_id=?1)",
                [item.key],
                |row| row.get(0),
            )
            .map_err(StoreError::from)?;
        Ok(Json(item.preview))
    })
    .await
    .map_err(|_| StoreError)?
}

async fn save(State(w): State<Workspace>, bytes: Bytes) -> Result<Json<Saved>, ApiError> {
    tokio::task::spawn_blocking(move || {
        let prepared = prepare(&bytes)?;
        save_bundle(&w.history, prepared, HashMap::new()).map(Json)
    })
    .await
    .map_err(|_| StoreError)?
}

async fn save_with_files(
    State(w): State<Workspace>,
    mut form: Multipart,
) -> Result<Json<Saved>, ApiError> {
    let mut bundle = None;
    let mut files = HashMap::new();
    let mut remaining = MAX_FILE;
    while let Some(field) = form.next_field().await.map_err(multipart_error)? {
        match field.name() {
            Some("bundle") if bundle.is_none() => {
                let bytes = field.bytes().await.map_err(multipart_error)?;
                if bytes.len() > LIMIT {
                    return Err(ApiError::PayloadTooLarge(
                        "The bundle must be 16 MiB or less.",
                    ));
                }
                bundle = Some(bytes);
            }
            Some("file") if files.len() < 32 => {
                let name = field
                    .file_name()
                    .filter(|name| valid_filename(name) && !name.starts_with('.'))
                    .ok_or(Failure::Input("Choose attachments with valid filenames."))?
                    .to_owned();
                let data = field.bytes().await.map_err(multipart_error)?;
                remaining = remaining
                    .checked_sub(data.len())
                    .ok_or(ApiError::PayloadTooLarge(
                        "Archive attachments must total 8 MiB or less.",
                    ))?;
                if files.insert(name, data).is_some() {
                    return Err(Failure::Input(
                        "Choose at most one local copy of each attachment.",
                    )
                    .into());
                }
            }
            _ => {
                return Err(Failure::Input("Choose one bundle and at most 32 attachments.").into());
            }
        }
    }
    let bundle = bundle.ok_or(Failure::Input("Choose a Grok Bot bundle.json file."))?;
    tokio::task::spawn_blocking(move || {
        let prepared = prepare(&bundle)?;
        if files.keys().any(|name| {
            !prepared
                .messages
                .iter()
                .any(|line| line.filenames.contains(name))
        }) {
            return Err(Failure::Input(
                "An attachment is not referenced by a visible message in this bundle.",
            )
            .into());
        }
        save_bundle(&w.history, prepared, files).map(Json)
    })
    .await
    .map_err(|_| StoreError)?
}

fn multipart_error(error: axum::extract::multipart::MultipartError) -> ApiError {
    if error.status() == axum::http::StatusCode::PAYLOAD_TOO_LARGE {
        ApiError::PayloadTooLarge("The bundle or its attachments exceed the import limit.")
    } else {
        Failure::Input("Could not read the bundle upload.").into()
    }
}

async fn download_attachment(
    State(w): State<Workspace>,
    Path((archive, name)): Path<(i64, String)>,
) -> Result<Response, ApiError> {
    let data: Vec<u8> = w
        .history
        .db()?
        .query_row(
            "SELECT data FROM grok_files WHERE archive=?1 AND name=?2",
            params![archive, name],
            |row| row.get(0),
        )
        .optional()
        .map_err(StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    Ok(file_download_response(&name, data))
}

fn missing_marker(count: usize) -> String {
    format!(
        "[{count} attachment{} unavailable in the export]",
        if count == 1 { "" } else { "s" }
    )
}

pub(crate) fn restore_attachment_marker(text: &mut String, count: usize, available: usize) {
    if count == 0 || available == 0 {
        return;
    }
    let marker = missing_marker(count);
    if let Some(before) = text.strip_suffix(&marker) {
        let mut updated = before.trim_end().to_owned();
        let missing = count.saturating_sub(available);
        if missing > 0 {
            if !updated.is_empty() {
                updated.push_str("\n\n");
            }
            updated.push_str(&missing_marker(missing));
        }
        *text = updated;
    }
}

fn save_bundle(
    history: &History,
    prepared: Prepared,
    files: HashMap<String, Bytes>,
) -> Result<Saved, ApiError> {
    let mut db = connection(history.file()).map_err(StoreError::from)?;
    let txn = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let existing: Option<(i64, bool, Option<i64>)> = txn
        .query_row(
            "SELECT id,is_group,profile FROM grok_imports WHERE source_id=?1",
            [&prepared.key],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()
        .map_err(StoreError::from)?;
    let summary = prepared.preview;
    let (id, profile) = if let Some((id, is_group, profile)) = existing {
        if is_group != summary.is_group {
            return Err(ApiError::Conflict(
                "This export identifies an existing archive of a different type.",
            ));
        }
        (id, profile)
    } else {
        let profile: Option<i64> = if summary.is_group {
            None
        } else {
            Some(txn.query_row(
                "INSERT INTO profiles(runtime_name,name,subtitle,avatar,instructions)
                 VALUES ('grok-' || ?1 || '-' || lower(hex(randomblob(5))),?2,?3,?4,?5) RETURNING id",
                params![prepared.slug,summary.name,prepared.label,prepared.avatar,summary.instructions], |row| row.get(0),
            ).map_err(StoreError::from)?)
        };
        let id = txn.query_row(
            "INSERT INTO grok_imports(source_id,profile,name,is_group,updated_ms) VALUES (?1,?2,?3,?4,?5) RETURNING id",
            params![prepared.key,profile,summary.name,summary.is_group,now()], |row| row.get(0),
        ).map_err(StoreError::from)?;
        (id, profile)
    };
    let added = {
        let mut insert = txn
            .prepare_cached(
                "INSERT INTO grok_messages(archive,seq,source_id,role,author,text,at_ms,attachment_count)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT DO NOTHING",
            )
            .map_err(StoreError::from)?;
        let mut count = 0;
        for line in &prepared.messages {
            count += insert
                .execute(params![
                    id,
                    line.seq,
                    line.source,
                    line.role,
                    line.author,
                    line.text,
                    line.at_ms,
                    line.attachment_count
                ])
                .map_err(StoreError::from)?;
        }
        count
    };
    let mut links = Vec::new();
    for line in &prepared.messages {
        if !line.filenames.iter().any(|name| files.contains_key(name)) {
            continue;
        }
        let seq: Option<i64> = txn.query_row(
            "SELECT seq FROM grok_messages WHERE archive=?1 AND
                ((?2 IS NOT NULL AND source_id=?2) OR (?2 IS NULL AND source_id IS NULL AND seq=?3))",
            params![id,line.source,line.seq], |row| row.get(0),
        ).optional().map_err(StoreError::from)?;
        if let Some(seq) = seq {
            links.push((seq, line));
        }
    }
    let used: HashSet<&str> = links
        .iter()
        .flat_map(|(_, line)| line.filenames.iter().map(String::as_str))
        .collect();
    let mut added_files = 0;
    for (name, data) in files
        .iter()
        .filter(|(name, _)| used.contains(name.as_str()))
    {
        added_files += txn.execute(
            "INSERT INTO grok_files(archive,name,data) VALUES (?1,?2,?3) ON CONFLICT DO NOTHING",
            params![id,name,data.as_ref()],
        ).map_err(StoreError::from)?;
    }
    let mut added_links = 0;
    for (seq, line) in links {
        txn.execute(
            "UPDATE grok_messages SET attachment_count=?3 WHERE archive=?1 AND seq=?2 AND attachment_count=0",
            params![id,seq,line.attachment_count],
        ).map_err(StoreError::from)?;
        for name in line
            .filenames
            .iter()
            .filter(|name| files.contains_key(*name))
        {
            added_links += txn.execute(
                "INSERT INTO grok_message_files(archive,seq,name) VALUES (?1,?2,?3) ON CONFLICT DO NOTHING",
                params![id,seq,name],
            ).map_err(StoreError::from)?;
        }
    }
    let routine_drafts = if profile.is_some() {
        crate::routine_drafts::stage(&txn, id, prepared.routines)?
    } else {
        0
    };
    if (added > 0 || routine_drafts > 0 || added_links > 0) && existing.is_some() {
        txn.execute(
            "UPDATE grok_imports SET updated_ms=?2 WHERE id=?1",
            params![id, now()],
        )
        .map_err(StoreError::from)?;
    }
    let archive = txn
        .query_row(
            &format!("SELECT {ARCHIVE_FIELDS} FROM grok_imports WHERE id=?1"),
            [id],
            archive_row,
        )
        .map_err(StoreError::from)?;
    txn.commit().map_err(StoreError::from)?;
    Ok(Saved {
        archive,
        added,
        routine_drafts,
        added_files,
    })
}

pub fn page(
    history: &History,
    address: &str,
    created: u64,
    before: Option<i64>,
) -> Result<Page, StoreError> {
    let Some(id) = address
        .strip_prefix("archive-")
        .and_then(|key| key.parse::<i64>().ok())
        .filter(|_| created == 0)
    else {
        return Ok(Page {
            items: Vec::new(),
            before: None,
        });
    };
    let db = history.db()?;
    let mut query = db.prepare(
        "SELECT seq,role,author,text,at_ms,attachment_count FROM grok_messages WHERE archive=?1 AND seq<?2 ORDER BY seq DESC LIMIT 31"
    )?;
    let mut items = query
        .query_map(params![id, before.unwrap_or(i64::MAX)], |row| {
            let role: String = row.get(1)?;
            Ok(Row {
                id: row.get(0)?,
                kind: if role == "assistant" { "reply" } else { "task" },
                detail: row.get(2)?,
                text: row.get(3)?,
                at_ms: row.get(4)?,
                attachment_count: row.get(5)?,
                attachments: vec![],
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let before = if items.len() > 30 {
        items.pop();
        items.last().map(|item| item.id)
    } else {
        None
    };
    let mut files = db.prepare_cached(
        "SELECT name FROM grok_message_files WHERE archive=?1 AND seq=?2 ORDER BY name",
    )?;
    for item in &mut items {
        if item.attachment_count == 0 {
            continue;
        }
        item.attachments = files
            .query_map(params![id, item.id], |row| row.get(0))?
            .collect::<Result<_, _>>()?;
        restore_attachment_marker(
            &mut item.text,
            item.attachment_count,
            item.attachments.len(),
        );
    }
    items.reverse();
    Ok(Page { items, before })
}
