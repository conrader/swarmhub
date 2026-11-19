use crate::{
    ApiError, Workspace, agent, bots,
    outbound::{self, Email, Payload, Version}, parks,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    staged: Option<Version>,
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
            "/api/history/{core}/{id}/{created}/email-drafts/{message}/stage",
            post(stage).layer(DefaultBodyLimit::max(REQUEST_LIMIT)),
        )
        .route(
            "/api/history/{core}/{id}/{created}/email-drafts/{message}/staged-download",
            post(staged_download),
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
                staged: None,
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
) -> Result<Json<Suggestion>, parks::Error> {
    let mut db = w.history.db()?;
    let tx = db.transaction()?;
    let mut result = suggestion(&tx, &at).map_err(park_error)?;
    result.staged = outbound::latest_legacy(&tx, at.message)?;
    Ok(Json(result))
}

fn park_error(error: ApiError) -> parks::Error {
    match error {
        ApiError::NotFound => parks::Error::Missing,
        _ => parks::Error::Store(StoreError),
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Stage {
    revision: i64,
    version: i64,
    email: Email,
}

async fn stage(
    State(w): State<Workspace>, Path(at): Path<Location>, Json(input): Json<Stage>,
) -> Result<Json<Version>, parks::Error> {
    let mut db = w.history.db()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let current = suggestion(&tx, &at).map_err(park_error)?;
    if current.state == "dismissed" || current.revision != input.revision {
        return Err(parks::Error::Conflict);
    }
    let (launch, owner_entry): (String, i64) = tx.query_row(
        "SELECT d.launch,j.id FROM email_drafts d JOIN journal j ON j.launch_key=d.launch
         WHERE d.message=?1",
        [at.message], |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let owner = match bots::of_launch(&tx, &launch)? {
        bots::Who::Bot(bot) if bot.noted_launch.as_deref() == Some(&launch) => bot.id,
        _ => format!("session:{owner_entry}"),
    };
    let staged = outbound::stage_legacy(&tx, at.message, &owner, input.version, Payload::Email(input.email))?;
    tx.commit()?;
    Ok(Json(staged))
}


pub(crate) fn control(c: char) -> bool {
    c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')
}

pub(crate) fn mailbox(address: &str) -> bool {
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

pub(crate) fn address_header(message: &mut String, label: &str, addresses: &str) {
    if !addresses.is_empty() {
        message.push_str(label);
        message.push_str(": ");
        message.push_str(&addresses.replace(", ", ",\r\n "));
        message.push_str("\r\n");
    }
}

fn eml(draft: &Draft) -> Vec<u8> {
    let mut headers = String::from("X-Unsent: 1\r\n");
    address_header(&mut headers, "To", &draft.to);
    plain_eml(headers, &draft.subject, &draft.body)
}

fn staged_eml(email: &Email) -> Vec<u8> {
    let mut headers = String::from("X-Unsent: 1\r\n");
    address_header(&mut headers, "From", &email.sender);
    address_header(&mut headers, "To", &email.to.join(", "));
    address_header(&mut headers, "Cc", &email.cc.join(", "));
    address_header(&mut headers, "Bcc", &email.bcc.join(", "));
    if let Some(reply) = &email.in_reply_to {
        address_header(&mut headers, "In-Reply-To", reply);
    }
    plain_eml(headers, &email.subject, &email.body)
}

pub(crate) fn plain_eml(mut message: String, subject: &str, body: &str) -> Vec<u8> {
    message.push_str("Subject:");
    let mut remaining = subject;
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
    let body = STANDARD.encode(body.replace('\n', "\r\n"));
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
        if outbound::latest_legacy(&tx, at.message).map_err(|_| StoreError)?.is_some() {
            return Err(ApiError::Conflict("Open the staged draft to download its saved revision."));
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
    let mut response = eml_download(eml(&draft));
    response.headers_mut().insert("x-swarmhub-email-revision", revision.into());
    Ok(response)
}

fn eml_download(bytes: Vec<u8>) -> Response {
    let mut response = file_download_response(FILENAME, bytes);
    response.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static("message/rfc822"),
    );
    response
}

async fn staged_download(
    State(w): State<Workspace>, Path(at): Path<Location>, Json(input): Json<Dismiss>,
) -> Result<Response, parks::Error> {
    let mut db = w.history.db()?;
    let tx = db.transaction()?;
    suggestion(&tx, &at).map_err(park_error)?;
    let version = outbound::latest_legacy(&tx, at.message)?.ok_or(parks::Error::Missing)?;
    if input.revision != version.version {
        return Err(parks::Error::Conflict);
    }
    let Payload::Email(email) = version.payload else { return Err(parks::Error::Conflict) };
    Ok(eml_download(staged_eml(&email)))
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
    if outbound::latest_legacy(&tx, at.message).map_err(|_| StoreError)?.is_some() {
        return Err(ApiError::Conflict("Manage the staged draft from Approvals."));
    }
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
