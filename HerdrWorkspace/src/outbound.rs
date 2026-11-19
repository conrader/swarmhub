//! Stages complete plain-text outbound payloads and records operator consent.
use crate::{
    Workspace, core::Failure,
    email_drafts::{control, mailbox},
    fleet_policy::{self, Verified, principals::{Actor, Signed, hex, identifier}},
    history::{self, StoreError},
    parks::{self, Manifest, Operation, ParkRef, State},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, State as AxumState},
    routing::post,
};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Email {
    pub sender: String,
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub bcc: Vec<String>,
    pub subject: String,
    pub in_reply_to: Option<String>,
    pub thread_id: Option<String>,
    pub body: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "channel", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Payload {
    Email(Email),
    Slack {
        sender: String,
        destination: String,
        thread_ts: Option<String>,
        body: String,
    },
    Whatsapp {
        sender: String,
        destination: String,
        reply_message_id: Option<String>,
        body: String,
    },
    Deployment {
        sender: String,
        destination: String,
        release_revision: String,
        body: String,
    },
}

const INVALID: Failure = Failure::Input(
    "Use a sending identity, valid destinations and reply fields, and one plain-text message up to 24 KiB.",
);
const WORKSPACE_OWNER: &str = "workspace:operator";
const BRIDGE: &str = "bridge";

fn token(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b))
}

fn message_id(value: &str) -> bool {
    value.strip_prefix('<').and_then(|v| v.strip_suffix('>')).is_some_and(mailbox)
}

fn phone(value: &str) -> bool {
    value.strip_prefix('+').is_some_and(|v| {
        (2..=15).contains(&v.len()) && !v.starts_with('0') && v.bytes().all(|b| b.is_ascii_digit())
    })
}

impl Payload {
    pub(crate) fn normalize(mut self) -> Result<Self, Failure> {
        let (valid, body) = match &mut self {
            Self::Email(email) => {
                let recipients = email.to.iter().chain(&email.cc).chain(&email.bcc);
                let count = recipients.clone().count();
                let valid = mailbox(&email.sender) && (1..=10).contains(&count)
                    && recipients.clone().all(|address| mailbox(address))
                    && recipients.map(|address| address.to_ascii_lowercase())
                        .collect::<std::collections::HashSet<_>>().len() == count
                    && email.subject.len() <= 240 && !email.subject.chars().any(control)
                    && email.in_reply_to.as_deref().is_none_or(message_id)
                    && email.thread_id.as_deref().is_none_or(token);
                (valid, &mut email.body)
            }
            Self::Slack { sender, destination, thread_ts, body } => (
                token(sender) && token(destination) && thread_ts.as_deref().is_none_or(|ts| {
                    ts.len() <= 32 && ts.split_once('.').is_some_and(|(seconds, fraction)| {
                        !seconds.is_empty() && fraction.len() == 6
                            && seconds.bytes().chain(fraction.bytes()).all(|b| b.is_ascii_digit())
                    })
                }),
                body,
            ),
            Self::Whatsapp { sender, destination, reply_message_id, body } => (
                phone(sender) && phone(destination) && reply_message_id.as_deref().is_none_or(token),
                body,
            ),
            Self::Deployment { sender, destination, release_revision, body } => (
                token(sender) && token(destination)
                    && (hex(release_revision, 40) || hex(release_revision, 64)),
                body,
            ),
        };
        *body = body.replace("\r\n", "\n");
        if !valid || body.trim().is_empty() || body.len() > 24 * 1024
            || body.chars().any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
        {
            return Err(INVALID);
        }
        Ok(self)
    }

    fn encode(&self) -> Result<String, parks::Error> {
        serde_json::to_string(self).map_err(|_| StoreError.into())
    }

    pub(crate) fn digest(&self) -> Result<String, parks::Error> {
        let payload = self.encode()?;
        let mut hash = Sha256::new();
        hash.update(b"swarmhub-outbound-payload-v1\n");
        hash.update(payload.as_bytes());
        Ok(format!("{:x}", hash.finalize()))
    }
}

#[derive(Serialize)]
pub(crate) struct Version {
    pub draft_id: String,
    pub version: i64,
    pub payload: Payload,
    pub payload_digest: String,
    pub park: ParkRef,
    pub state: State,
    pub approval: Option<Signed>,
    pub in_flight: Vec<Flight>,
}

#[derive(Serialize)]
pub(crate) struct Flight {
    version: i64,
    park: String,
    state: State,
}

#[derive(Serialize)]
struct TextReview {
    group: i64,
    question: i64,
    answer: i64,
    response: String,
}

pub(crate) fn latest_legacy(db: &Connection, message: i64) -> Result<Option<Version>, parks::Error> {
    let draft = db.query_row("SELECT id FROM outbound_drafts WHERE legacy_message=?1", [message],
        |row| row.get::<_, String>(0)).optional()?;
    draft.map(|id| latest(db, &id)).transpose().map(Option::flatten)
}

fn latest(db: &Connection, id: &str) -> Result<Option<Version>, parks::Error> {
    let park = db.query_row(
        "SELECT park_id FROM outbound_versions WHERE draft_id=?1 ORDER BY version DESC LIMIT 1",
        [id], |row| row.get::<_, String>(0),
    ).optional()?;
    park.map(|id| for_park(db, &id)).transpose().map(Option::flatten)
}

pub(crate) fn for_park(db: &Connection, id: &str) -> Result<Option<Version>, parks::Error> {
    let row = db.query_row(
        "SELECT v.draft_id,v.version,v.payload,v.payload_digest,p.manifest_digest,p.state,
                (SELECT a.signed FROM outbound_approvals a WHERE a.park_id=p.id ORDER BY a.id DESC LIMIT 1)
         FROM outbound_versions v JOIN parks p ON p.id=v.park_id WHERE v.park_id=?1",
        [id], |row| Ok((row.get::<_, String>(0)?, row.get(1)?, row.get::<_, String>(2)?,
            row.get::<_, String>(3)?, row.get(4)?, row.get(5)?, row.get::<_, Option<String>>(6)?)),
    ).optional()?;
    let Some((draft_id, version, encoded, payload_digest, manifest_digest, state, approval)) = row else {
        return Ok(None);
    };
    let payload: Payload = serde_json::from_str(&encoded).map_err(|_| StoreError)?;
    let park = ParkRef { id: id.into(), manifest_digest };
    let manifest = parks::manifest_for(db, &park)?;
    if payload.clone().normalize().ok().as_ref() != Some(&payload)
        || payload.digest()? != payload_digest || manifest.artifact_pin != payload_digest
        || manifest.operation != (Operation::DeliverOutbound {
            draft: draft_id.clone(), version, payload_digest: payload_digest.clone(),
        })
    {
        return Err(parks::Error::Conflict);
    }
    let approval = approval.map(|signed| serde_json::from_str(&signed)).transpose().map_err(|_| StoreError)?;
    let mut stmt = db.prepare(
        "SELECT v.version,p.id,p.state FROM outbound_versions v JOIN parks p ON p.id=v.park_id
         WHERE v.draft_id=?1 AND v.version!=?2 AND p.state IN ('executing','reconciliation')
         ORDER BY v.version",
    )?;
    let in_flight = stmt.query_map(params![draft_id, version], |row| Ok(Flight {
        version: row.get(0)?, park: row.get(1)?, state: row.get(2)?,
    }))?.collect::<Result<_, _>>()?;
    Ok(Some(Version { draft_id, version, payload, payload_digest, park, state, approval, in_flight }))
}

pub(crate) fn stage_legacy(
    tx: &Transaction<'_>, message: i64, owner: &str, expected: i64, payload: Payload,
) -> Result<Version, parks::Error> {
    let previous = latest_legacy(tx, message)?;
    stage(tx, previous, expected, owner, "email", Some(message), payload)
}

fn stage(
    tx: &Transaction<'_>, previous: Option<Version>, expected: i64, owner: &str, project: &str,
    legacy: Option<i64>, payload: Payload,
) -> Result<Version, parks::Error> {
    if previous.as_ref().map_or(0, |row| row.version) != expected {
        return Err(parks::Error::Conflict);
    }
    let payload = payload.normalize().map_err(|_| parks::Error::InvalidManifest)?;
    if let Some(previous) = &previous
        && previous.payload == payload && matches!(previous.state, State::Pending | State::Held)
    {
        return for_park(tx, &previous.park.id)?.ok_or(parks::Error::Missing);
    }
    let id = match &previous {
        Some(row) => row.draft_id.clone(),
        None => tx.query_row(
            "INSERT INTO outbound_drafts(id,owner,project,legacy_message)
             VALUES(lower(hex(randomblob(16))),?1,?2,?3) RETURNING id",
            params![owner, project, legacy], |row| row.get(0),
        )?,
    };
    let (owner, project): (String, String) = tx.query_row(
        "SELECT owner,project FROM outbound_drafts WHERE id=?1", [&id],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    let version = expected.checked_add(1).ok_or(parks::Error::Conflict)?;
    let digest = payload.digest()?;
    let manifest = Manifest {
        revision: format!("{id}-{version}"), owner: owner.clone(), project, host: BRIDGE.into(),
        operation: Operation::DeliverOutbound { draft: id.clone(), version, payload_digest: digest.clone() },
        artifact_pin: digest.clone(), apply_pin: "outbound-disabled".into(), reverse_pin: "none".into(),
        precondition: "unsent".into(), expected_postcondition: "provider-accepted".into(),
        review_ref: "optional-outbound-text-review".into(), dry_run_ref: "immutable-outbound-preview".into(),
        rollback_plan: "Outside delivery cannot be reversed.".into(),
    };
    let park = parks::stage_outbound(tx, previous.as_ref().map(|row| &row.park), &manifest)?;
    tx.execute(
        "INSERT INTO outbound_versions VALUES(?1,?2,?3,?4,?5,?6)",
        params![id, version, payload.encode()?, digest, park.id, history::now()],
    )?;
    for_park(tx, &park.id)?.ok_or(parks::Error::Missing)
}

pub(crate) fn authorize(tx: &Transaction<'_>, park: &ParkRef, verified: &Verified) -> Result<(), parks::Error> {
    if verified.actor != Actor::Operator {
        return Err(fleet_policy::Error::HumanScope.into());
    }
    let version = for_park(tx, &park.id)?.ok_or(parks::Error::InvalidDecision)?;
    if version.park != *park || version.state != State::Pending
        || latest(tx, &version.draft_id)?.map(|row| row.version) != Some(version.version)
    {
        return Err(parks::Error::Conflict);
    }
    if version.approval.as_ref() == Some(&verified.signed) {
        return Ok(());
    }
    let signed = serde_json::to_string(&verified.signed).map_err(|_| StoreError)?;
    verified.audit(tx)?;
    let changed = tx.execute(
        "INSERT INTO outbound_approvals(park_id,workspace,nonce,signed,recorded_ms)
         SELECT ?1,?2,?3,?4,?5 WHERE NOT EXISTS(
             SELECT 1 FROM outbound_approvals WHERE workspace=?2 AND nonce=?3)",
        params![park.id, verified.workspace, verified.nonce, signed, history::now()],
    )?;
    if changed != 1 {
        return Err(fleet_policy::Error::Replay.into());
    }
    Ok(())
}

pub(crate) fn attach_review(
    tx: &Transaction<'_>, group: i64, answer: i64, park: &str,
) -> Result<(), parks::Error> {
    let draft = for_park(tx, park)?.ok_or(parks::Error::Missing)?;
    if draft.state != State::Pending || latest(tx, &draft.draft_id)?.map(|row| row.version) != Some(draft.version) {
        return Err(parks::Error::Conflict);
    }
    let (question, text, form, response): (i64, String, String, String) = tx.query_row(
        "SELECT q.id,q.text,q.form_json,a.text FROM group_messages a
         JOIN group_messages q ON q.id=a.in_reply_to AND q.group_id=a.group_id
         WHERE a.group_id=?1 AND a.id=?2 AND a.author IS NULL AND q.author IS NOT NULL
           AND q.is_question=1 AND q.form_json IS NOT NULL",
        params![group, answer], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    ).optional()?.ok_or(parks::Error::Missing)?;
    let expected = review_question(&draft.park);
    if text != expected || !crate::group_forms::Form::parse(&form).is_ok_and(|form| form.title == expected && form.matches_response(&response)) {
        return Err(parks::Error::InvalidDecision);
    }
    if let Some(saved) = review_for(tx, park)? {
        return if saved.answer == answer { Ok(()) } else { Err(parks::Error::Conflict) };
    }
    tx.execute(
        "INSERT INTO outbound_text_reviews VALUES(?1,?2,?3,?4,?5,?6)",
        params![park, group, question, answer, response, history::now()],
    )?;
    Ok(())
}

fn review_for(db: &Connection, park: &str) -> rusqlite::Result<Option<TextReview>> {
    db.query_row(
        "SELECT group_id,question,answer,response FROM outbound_text_reviews WHERE park_id=?1",
        [park], |row| Ok(TextReview { group: row.get(0)?, question: row.get(1)?, answer: row.get(2)?, response: row.get(3)? }),
    ).optional()
}

fn review_question(park: &ParkRef) -> String {
    format!("Outbound text review {}", park.manifest_digest)
}

pub(crate) fn preview(db: &Connection, park: &str) -> Result<Option<serde_json::Value>, parks::Error> {
    let Some(version) = for_park(db, park)? else { return Ok(None) };
    let review = review_for(db, park)?;
    Ok(Some(serde_json::json!({
        "version": version,
        "sending_enabled": false,
        "text_review": review,
        "review_question": review_question(&version.park),
    })))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Stage {
    id: Option<String>,
    version: i64,
    project: String,
    payload: Payload,
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route("/api/outbound/stage", post(stage_generic).layer(DefaultBodyLimit::max(160 * 1024)))
}

async fn stage_generic(
    AxumState(w): AxumState<Workspace>, Json(input): Json<Stage>,
) -> Result<Json<Version>, parks::Error> {
    if !identifier(&input.project) {
        return Err(parks::Error::InvalidManifest);
    }
    let mut db = w.history.db()?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let previous = if let Some(id) = input.id {
        let scope: Option<(String, String)> = tx.query_row(
            "SELECT owner,project FROM outbound_drafts WHERE id=?1 AND legacy_message IS NULL",
            [&id], |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?;
        if !scope.is_some_and(|(owner, project)| owner == WORKSPACE_OWNER && project == input.project) {
            return Err(parks::Error::Missing);
        }
        Some(latest(&tx, &id)?.ok_or(parks::Error::Missing)?)
    } else {
        None
    };
    let version = stage(&tx, previous, input.version, WORKSPACE_OWNER, &input.project, None, input.payload)?;
    tx.commit()?;
    Ok(Json(version))
}

#[cfg(test)]
mod tests;
