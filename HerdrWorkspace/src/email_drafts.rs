use crate::{
    ApiError, Workspace, agent,
    core::Failure,
    file_download_response,
    history::{self, StoreError, now},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    http::{HeaderValue, header},
    response::Response,
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::STANDARD};
use ring::digest::{SHA256, digest};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const BODY_LIMIT: usize = 24 * 1024;
const REQUEST_LIMIT: usize = 160 * 1024;
const FILENAME: &str = "swarmhub-email-draft.eml";
const CHANGED: ApiError = ApiError::Conflict(
    "This email draft changed. Close and reopen it to review the latest version.",
);

#[derive(Deserialize)]
struct Location {
    core: String,
    id: String,
    created: u64,
    message: i64,
}

#[derive(Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Draft {
    to: String,
    subject: String,
    body: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Review {
    revision: i64,
    draft: Draft,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Dismiss {
    revision: i64,
}

#[derive(Serialize)]
struct Suggestion {
    state: String,
    revision: i64,
    draft: Option<Draft>,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/email-drafts.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/email-drafts.js"),
                )
            }),
        )
        .route(
            "/api/history/{core}/{id}/{created}/email-drafts/{message}",
            get(read),
        )
        .route(
            "/api/history/{core}/{id}/{created}/email-drafts/{message}/download",
            post(download).layer(DefaultBodyLimit::max(REQUEST_LIMIT)),
        )
        .route(
            "/api/history/{core}/{id}/{created}/email-drafts/{message}/dismiss",
            post(dismiss),
        )
}

fn suggestion(db: &Connection, at: &Location) -> Result<Suggestion, ApiError> {
    db.query_row(
        "SELECT d.state,d.revision,d.recipients,d.subject,d.body FROM email_drafts d
         JOIN journal j ON j.id=d.message
         WHERE j.id=?1 AND j.core_id=?2 AND j.address=?3 AND j.created_ms=?4",
        params![at.message, at.core, at.id, at.created],
        |row| {
            let draft = if let Some(to) = row.get::<_, Option<String>>(2)? {
                Some(Draft {
                    to,
                    subject: row.get(3)?,
                    body: row.get(4)?,
                })
            } else {
                None
            };
            Ok(Suggestion {
                state: row.get(0)?,
                revision: row.get(1)?,
                draft,
            })
        },
    )
    .optional()
    .map_err(StoreError::from)?
    .ok_or(ApiError::NotFound)
}

async fn read(
    State(w): State<Workspace>,
    Path(at): Path<Location>,
) -> Result<Json<Suggestion>, ApiError> {
    let db = w.history.db()?;
    Ok(Json(suggestion(&db, &at)?))
}

fn control(c: char) -> bool {
    c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')
}

fn mailbox(address: &str) -> bool {
    let Some((local, domain)) = address.split_once('@') else {
        return false;
    };
    let atom = |b: u8| b.is_ascii_alphanumeric() || b"_+-".contains(&b);
    address.len() <= 254
        && !local.is_empty()
        && local.len() <= 64
        && local
            .split('.')
            .all(|part| !part.is_empty() && part.bytes().all(atom))
        && domain.contains('.')
        && domain.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

impl Draft {
    fn normalize(self) -> Result<Self, Failure> {
        if self.to.len() > 1024 || self.to.chars().any(control) {
            return Err(Failure::Input(
                "Enter up to ten email addresses separated by commas.",
            ));
        }
        let raw = self.to.trim();
        let addresses: Vec<_> = if raw.is_empty() {
            Vec::new()
        } else {
            raw.split(',').map(str::trim).collect()
        };
        if addresses.len() > 10 || !addresses.iter().all(|address| mailbox(address)) {
            return Err(Failure::Input(
                "Use simple email addresses separated by commas, without names or brackets.",
            ));
        }
        if self.subject.len() > 240 || self.subject.chars().any(control) {
            return Err(Failure::Input(
                "Use one line of plain text up to 240 bytes for the subject.",
            ));
        }
        let body = self.body.replace("\r\n", "\n");
        if body.trim().is_empty()
            || body.len() > BODY_LIMIT
            || body
                .chars()
                .any(|c| control(c) && !matches!(c, '\n' | '\t'))
        {
            return Err(Failure::Input(
                "Enter a plain-text email body up to 24 KiB.",
            ));
        }
        Ok(Self {
            to: addresses.join(", "),
            subject: self.subject.trim().to_owned(),
            body,
        })
    }
}

fn eml(draft: &Draft) -> Vec<u8> {
    // No sender or transport fields are invented. X-Unsent marks a local
    // draft for clients that recognize it; MIME carries the text verbatim.
    let mut message = String::from("X-Unsent: 1\r\n");
    if !draft.to.is_empty() {
        message.push_str("To: ");
        message.push_str(&draft.to.replace(", ", ",\r\n "));
        message.push_str("\r\n");
    }
    message.push_str("Subject:");
    let mut remaining = draft.subject.as_str();
    let mut first = true;
    while !remaining.is_empty() {
        let mut end = remaining.len().min(42);
        while !remaining.is_char_boundary(end) {
            end -= 1;
        }
        if !first {
            message.push_str("\r\n");
        }
        first = false;
        message.push_str(" =?UTF-8?B?");
        message.push_str(&STANDARD.encode(&remaining.as_bytes()[..end]));
        message.push_str("?=");
        remaining = &remaining[end..];
    }
    message.push_str("\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=UTF-8\r\nContent-Transfer-Encoding: base64\r\n\r\n");
    let body = STANDARD.encode(draft.body.replace('\n', "\r\n"));
    for line in body.as_bytes().chunks(76) {
        message.push_str(std::str::from_utf8(line).expect("base64 is ASCII"));
        message.push_str("\r\n");
    }
    message.into_bytes()
}

async fn download(
    State(w): State<Workspace>,
    Path(at): Path<Location>,
    Json(review): Json<Review>,
) -> Result<Response, ApiError> {
    let draft = review.draft.normalize()?;
    let revision = {
        let mut db = w.history.db()?;
        let tx = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(StoreError::from)?;
        let current = suggestion(&tx, &at)?;
        if current.state == "dismissed" {
            return Err(ApiError::Conflict("This email draft was dismissed."));
        }
        // A retry of the exact accepted contents always produces the same
        // file without changing the saved record, even with an older revision.
        if current.state == "reviewed" && current.draft.as_ref() == Some(&draft) {
            current.revision
        } else {
            if current.revision != review.revision {
                return Err(CHANGED);
            }
            let revision: i64 = tx.query_row(
                "UPDATE email_drafts SET recipients=?2,subject=?3,body=?4,state='reviewed',revision=revision+1
                 WHERE message=?1 RETURNING revision",
                params![at.message, draft.to, draft.subject, draft.body],
                |row| row.get(0),
            ).map_err(StoreError::from)?;
            tx.commit().map_err(StoreError::from)?;
            revision
        }
    };
    let mut response = file_download_response(FILENAME, eml(&draft));
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("message/rfc822"),
    );
    response
        .headers_mut()
        .insert("x-swarmhub-email-revision", revision.into());
    Ok(response)
}

async fn dismiss(
    State(w): State<Workspace>,
    Path(at): Path<Location>,
    Json(review): Json<Dismiss>,
) -> Result<Json<Value>, ApiError> {
    let mut db = w.history.db()?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    let current = suggestion(&tx, &at)?;
    if current.state != "dismissed" {
        if current.revision != review.revision {
            return Err(CHANGED);
        }
        tx.execute(
            "UPDATE email_drafts SET recipients=NULL,subject=NULL,body=NULL,state='dismissed',revision=revision+1 WHERE message=?1",
            [at.message],
        ).map_err(StoreError::from)?;
        tx.commit().map_err(StoreError::from)?;
    }
    Ok(Json(json!({"dismissed":true})))
}

fn publish_error(error: rusqlite::Error) -> &'static str {
    let _ = StoreError::from(error);
    "Could not keep the email draft."
}

pub fn publish() -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args_os().nth(2).is_some() {
        return Err("Usage: swarmhub-herdr propose-email < draft.json".into());
    }
    let (path, launch) = agent::session()?;
    let input = agent::read_input(REQUEST_LIMIT)?;
    let draft: Draft =
        serde_json::from_str(&input).map_err(|_| "Use JSON with to, subject, and body.")?;
    let draft = draft
        .normalize()
        .map_err(|_| "Check the draft addresses, subject, and plain-text body.")?;
    let fingerprint = digest(&SHA256, &serde_json::to_vec(&draft)?);
    let mut db = history::connection(&path).map_err(publish_error)?;
    let tx = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(publish_error)?;
    if tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM email_drafts WHERE launch=?1 AND fingerprint=?2)",
            params![launch, fingerprint.as_ref()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(publish_error)?
    {
        println!("This email draft is already in the conversation.");
        return Ok(());
    }
    if tx
        .query_row(
            "SELECT count(*) FROM email_drafts WHERE launch=?1 AND state='suggested'",
            [&launch],
            |row| row.get::<_, i64>(0),
        )
        .map_err(publish_error)?
        >= 12
    {
        return Err("Review an existing email draft before adding more.".into());
    }
    let message: i64 = tx.query_row(
        "INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms)
         SELECT launch_key,core_id,address,created_ms,agent,'reply','received','An email draft was suggested.','Email draft',?2
           FROM journal WHERE launch_key=?1 RETURNING id",
        params![launch, now()],
        |row| row.get(0),
    ).optional().map_err(publish_error)?.ok_or("The receiving agent session is unavailable.")?;
    tx.execute(
        "INSERT INTO email_drafts(message,launch,recipients,subject,body,fingerprint) VALUES(?1,?2,?3,?4,?5,?6)",
        params![message, launch, draft.to, draft.subject, draft.body, fingerprint.as_ref()],
    ).map_err(publish_error)?;
    tx.commit().map_err(publish_error)?;
    println!("Email draft added to the conversation for review. Nothing was sent.");
    Ok(())
}
