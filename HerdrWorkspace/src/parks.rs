//! Immutable park lifecycle. Managed callers use the common decision service.
mod service;
mod staging_ref;

pub(crate) use service::{Command, Service, routes, summaries};
#[cfg(test)]
pub(crate) use staging_ref::tests::{GitFixture, verify_rollback};

use crate::history::{self, StoreError};
use rusqlite::{
    Connection, OptionalExtension, Transaction, TransactionBehavior, params,
    types::{FromSql, FromSqlError, FromSqlResult, ValueRef},
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use sha2::{Digest, Sha256};
use std::io;

#[derive(Debug)]
pub(crate) enum Error {
    Store(StoreError),
    Conflict,
    InvalidManifest,
    InvalidDecision,
    Missing,
    Authority(crate::fleet_policy::Error),
    Blocked(Blocker),
}

impl From<crate::fleet_policy::Error> for Error {
    fn from(error: crate::fleet_policy::Error) -> Self {
        Self::Authority(error)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Blocker {
    HumanReview,
    OutboundDisabled,
    OutboundApproval,
    OutboundSender,
    FixtureOnly,
    Pins,
    ReviewEvidence,
    AuthorizationChanged,
    PolicyBusy,
    PolicyUnavailable,
    PolicyAuditUnavailable,
    PolicyEvidenceInvalid,
}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Self::Store(error.into())
    }
}

impl From<StoreError> for Error {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ParkRef {
    pub id: String,
    pub manifest_digest: String,
}

impl ParkRef {
    pub(crate) fn pin(&self, manifest: &Manifest) -> crate::fleet_policy::principals::ParkPin {
        crate::fleet_policy::principals::ParkPin {
            id: self.id.clone(),
            revision: manifest.revision.clone(),
            manifest_digest: self.manifest_digest.clone(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Manifest {
    pub revision: String,
    pub owner: String,
    pub project: String,
    pub host: String,
    pub operation: Operation,
    pub artifact_pin: String,
    pub apply_pin: String,
    pub reverse_pin: String,
    pub precondition: String,
    pub expected_postcondition: String,
    pub review_ref: String,
    pub dry_run_ref: String,
    pub rollback_plan: String,
}

pub(crate) const STAGING_ACTION: &str = "advance_staging_ref";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) enum Operation {
    SetRevisionMarker { revision: String },
    AdvanceStagingRef { reference: String, rollback: bool },
    SpendMoney,
    UseSecret,
    UseWorkloadSecret { grant_digest: String },
    Delete,
    OutsideMessage,
    DeliverOutbound { draft: String, version: i64, payload_digest: String },
    Unknown { action: String },
}

impl Operation {
    pub(crate) fn action(&self) -> &str {
        match self {
            Self::SetRevisionMarker { .. } => "set_revision_marker",
            Self::AdvanceStagingRef { .. } => STAGING_ACTION,
            Self::SpendMoney => "spend_money",
            Self::UseSecret | Self::UseWorkloadSecret { .. } => "use_secret",
            Self::Delete => "delete",
            Self::OutsideMessage | Self::DeliverOutbound { .. } => "outside_message",
            Self::Unknown { .. } => "unknown",
        }
    }
}

impl Manifest {
    fn encode(&self) -> Result<String, Error> {
        let valid_operation = match &self.operation {
            Operation::SetRevisionMarker { revision } => revision == &self.expected_postcondition,
            Operation::AdvanceStagingRef { reference, .. } => {
                staging_ref::valid_ref(reference)
                    && staging_ref::valid_oid(&self.precondition)
                    && staging_ref::valid_oid(&self.expected_postcondition)
                    && self.precondition.len() == self.expected_postcondition.len()
            }
            Operation::Unknown { action } => valid_text(action),
            Operation::DeliverOutbound { draft, version, payload_digest } => {
                crate::fleet_policy::principals::hex(draft, 32) && *version > 0
                    && crate::fleet_policy::principals::hex(payload_digest, 64)
                    && self.artifact_pin == *payload_digest
                    && self.revision == format!("{draft}-{version}")
            }
            Operation::UseWorkloadSecret { grant_digest } => {
                crate::fleet_policy::principals::hex(grant_digest, 64)
            }
            _ => true,
        };
        if self.precondition == self.expected_postcondition
            || !valid_operation
            || [
                &self.revision,
                &self.owner,
                &self.project,
                &self.host,
                &self.artifact_pin,
                &self.apply_pin,
                &self.reverse_pin,
                &self.precondition,
                &self.expected_postcondition,
                &self.review_ref,
                &self.dry_run_ref,
                &self.rollback_plan,
            ]
            .iter()
            .any(|field| !valid_text(field))
        {
            return Err(Error::InvalidManifest);
        }
        encode(self)
    }
}

fn valid_text(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 512 && !value.chars().any(char::is_control)
}

#[derive(Clone, Copy)]
pub(crate) enum Source {
    Human,
    Judge,
    Backstop,
}

pub(crate) struct Decision<'a> {
    pub actor: &'a str,
    pub source: Source,
    pub basis: &'a str,
}

pub(crate) enum Change<'a> {
    Hold,
    Release,
    Deny,
    Supersede { id: &'a str, manifest: &'a Manifest },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum State {
    Pending,
    Held,
    Denied,
    Superseded,
    Executing,
    Verified,
    Failed,
    Reconciliation,
}

impl FromSql for State {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        match value.as_str()? {
            "pending" => Ok(Self::Pending),
            "held" => Ok(Self::Held),
            "denied" => Ok(Self::Denied),
            "superseded" => Ok(Self::Superseded),
            "executing" => Ok(Self::Executing),
            "verified" => Ok(Self::Verified),
            "failed" => Ok(Self::Failed),
            "reconciliation" => Ok(Self::Reconciliation),
            _ => Err(FromSqlError::InvalidType),
        }
    }
}

#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum View {
    Busy,
    Status(State),
    Receipt(State, Receipt),
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Marker {
    pub revision: String,
    pub attempt: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum Step {
    Exit(i32),
    Drift,
    Unavailable,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum Outcome {
    Verified,
    Failed,
    Reconciliation,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) enum Reason {
    InitialReadUnavailable,
    PreconditionDrift,
    ApplyFailed,
    VerificationFailed,
    Interrupted,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Receipt {
    pub attempt: String,
    pub outcome: Outcome,
    pub reason: Option<Reason>,
    pub before: Option<Marker>,
    pub apply: Option<Step>,
    pub after_apply: Option<Marker>,
    // Absent means there was no rollback intent. A present rollback can have an unknown exit.
    pub rollback: Option<Rollback>,
    pub restart_observation: Option<Marker>,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Rollback {
    pub step: Option<Step>,
    pub after: Option<Marker>,
}

#[derive(Serialize, Deserialize)]
struct RollbackIntent {
    after_apply: Option<Marker>,
}

/// Compare and replace must guard the write against the complete expected marker.
/// Observation reads the project independently of the apply or rollback result.
/// A drift result certifies that the adapter performed no write.
pub(crate) trait Adapter {
    fn observe(&self) -> io::Result<Marker>;
    fn apply(&self, expected: &Marker, replacement: &Marker) -> Step;
    fn rollback(&self, expected: &Marker, replacement: &Marker) -> Step;
}

#[cfg(test)]
pub(crate) fn file(db: &Connection, id: &str, manifest: &Manifest) -> Result<ParkRef, Error> {
    insert_park(db, id, manifest, None)
}

pub(crate) fn pin_for(id: &str, manifest: &Manifest) -> Result<crate::fleet_policy::principals::ParkPin, Error> {
    if !service::valid_id(id) {
        return Err(Error::InvalidManifest);
    }
    Ok(ParkRef { id: id.into(), manifest_digest: digest(&manifest.encode()?) }.pin(manifest))
}

fn insert_park(
    db: &Connection,
    id: &str,
    manifest: &Manifest,
    supersedes: Option<&str>,
) -> Result<ParkRef, Error> {
    if !valid_text(id) {
        return Err(Error::InvalidManifest);
    }
    let stored = manifest.encode()?;
    let manifest_digest = digest(&stored);
    db.execute(
        "INSERT INTO parks(id,manifest_digest,manifest,state,supersedes,created_ms)
         VALUES (?1,?2,?3,'pending',?4,?5)",
        params![id, manifest_digest, stored, supersedes, history::now()],
    )?;
    Ok(ParkRef {
        id: id.into(),
        manifest_digest,
    })
}

#[cfg(test)]
pub(crate) fn decide(
    db: &mut Connection,
    park: &ParkRef,
    decision: Decision<'_>,
    change: Change<'_>,
) -> Result<Option<ParkRef>, Error> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let replacement = transition(&tx, park, decision, change, None)?;
    tx.commit()?;
    Ok(replacement)
}

pub(crate) fn stage_outbound(
    tx: &Transaction<'_>,
    previous: Option<&ParkRef>,
    manifest: &Manifest,
) -> Result<ParkRef, Error> {
    if !matches!(manifest.operation, Operation::DeliverOutbound { .. }) {
        return Err(Error::InvalidManifest);
    }
    let id = format!("outbound-{}", manifest.revision);
    if let Some(previous) = previous
        && matches!(status(tx, previous)?,
            View::Status(State::Pending | State::Held) | View::Receipt(State::Pending | State::Held, _))
    {
        if has_execution(tx, previous)? {
            return Err(Error::Conflict);
        }
        return transition(tx, previous, Decision {
            actor: "workspace", source: Source::Backstop, basis: "outbound draft edited in the workspace",
        }, Change::Supersede { id: &id, manifest }, None)?.ok_or(Error::Conflict);
    }
    insert_park(tx, &id, manifest, None)
}

fn transition(
    tx: &Transaction<'_>,
    park: &ParkRef,
    decision: Decision<'_>,
    change: Change<'_>,
    audit: Option<&Audit>,
) -> Result<Option<ParkRef>, Error> {
    let outbound = matches!(change, Change::Hold | Change::Release | Change::Deny)
        && matches!(manifest_for(tx, park)?.operation, Operation::DeliverOutbound { .. });
    let can_retry = outbound && tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM outbound_receipts WHERE park_id=?1 AND status='not_submitted')",
        [&park.id], |row| row.get::<_, bool>(0),
    )?;
    let (action, allowed, next) = match change {
        Change::Hold => ("hold", "pending", "held"),
        Change::Release if matches!(decision.source, Source::Human) =>
            ("release", "held", if can_retry { "failed" } else { "pending" }),
        Change::Release => return Err(Error::InvalidDecision),
        Change::Deny => ("deny", "pending", "denied"),
        Change::Supersede { .. } => ("supersede", "pending", "superseded"),
    };
    let allow_from_failed = next == "superseded" || (can_retry && matches!(action, "hold" | "deny"));
    let changed = tx.execute(
        "UPDATE parks SET state=?1 WHERE id=?2 AND manifest_digest=?3
         AND (state=?4 OR (state='held' AND ?1 IN ('denied','superseded'))
                       OR (state='failed' AND ?5))",
        params![next, park.id, park.manifest_digest, allowed, allow_from_failed],
    )?;
    if changed != 1 {
        return Err(Error::Conflict);
    }
    let replacement = if let Change::Supersede { id, manifest } = change {
        let original = manifest_for(tx, park)?;
        if manifest.revision == original.revision
            || manifest.owner != original.owner
            || manifest.project != original.project
            || manifest.host != original.host
            || !crate::job_reviews::keeps_lineage(tx, &original, manifest)?
        {
            return Err(Error::InvalidManifest);
        }
        Some(insert_park(tx, id, manifest, Some(&park.id))?)
    } else {
        None
    };
    record_decision(tx, park, action, decision, audit)?;
    if action == "hold" && outbound {
        tx.execute(
            "INSERT OR IGNORE INTO outbound_approval_revocations(approval_id, hold_decision_id)
             SELECT id,?2 FROM outbound_approvals WHERE park_id=?1",
            params![park.id, tx.last_insert_rowid()],
        )?;
    }
    Ok(replacement)
}

struct Audit {
    classifier_output: String,
    policy_version: String,
}

fn record_decision(
    tx: &Transaction<'_>,
    park: &ParkRef,
    action: &str,
    decision: Decision<'_>,
    audit: Option<&Audit>,
) -> Result<(), Error> {
    if decision.actor.trim().is_empty() || decision.basis.trim().is_empty() {
        return Err(Error::InvalidDecision);
    }
    let source = match decision.source {
        Source::Human => "human",
        Source::Judge => "judge",
        Source::Backstop => "backstop",
    };
    tx.execute(
        "INSERT INTO park_decisions(park_id,action,actor,source,basis,classifier_output,policy_version,at_ms)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8)",
        params![park.id, action, decision.actor, source, decision.basis,
            audit.map(|audit| &audit.classifier_output), audit.map(|audit| &audit.policy_version), history::now()],
    )?;
    Ok(())
}

pub(crate) fn status(db: &Connection, park: &ParkRef) -> Result<View, Error> {
    let row: Option<(String, State, Option<String>)> = db
        .query_row(
            "SELECT p.manifest_digest,p.state,e.receipt FROM parks p
             LEFT JOIN park_executions e ON e.park_id=p.id WHERE p.id=?1",
            [&park.id],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .optional()?;
    let (digest, state, receipt) = row.ok_or(Error::Missing)?;
    if digest != park.manifest_digest {
        return Err(Error::Conflict);
    }
    match receipt {
        Some(receipt) => Ok(View::Receipt(state, decode(&receipt)?)),
        None => Ok(View::Status(state)),
    }
}

#[cfg(test)]
pub(crate) fn execute(
    db: &mut Connection,
    park: &ParkRef,
    decision: Decision<'_>,
    adapter: &impl Adapter,
) -> Result<View, Error> {
    let Some(tx) = history::background_write(db)? else {
        return Ok(View::Busy);
    };
    if status(&tx, park)? != View::Status(State::Pending) {
        return status(&tx, park);
    }
    let manifest = manifest_for(&tx, park)?;
    let attempt = claim(&tx, park, decision, None)?;
    tx.commit()?;
    run(db, park, &manifest, attempt, adapter)
}

pub(crate) fn has_execution(db: &Connection, park: &ParkRef) -> rusqlite::Result<bool> {
    db.query_row("SELECT EXISTS(SELECT 1 FROM park_executions WHERE park_id=?1)",
        [&park.id], |row| row.get(0))
}

fn claim(
    tx: &Transaction<'_>,
    park: &ParkRef,
    decision: Decision<'_>,
    audit: Option<&Audit>,
) -> Result<String, Error> {
    let changed = tx.execute(
        "UPDATE parks SET state='executing'
         WHERE id=?1 AND manifest_digest=?2 AND state='pending'",
        params![park.id, park.manifest_digest],
    )?;
    if changed != 1 {
        return Err(Error::Conflict);
    }
    record_decision(tx, park, "claim", decision, audit)?;
    Ok(tx.query_row(
        "INSERT INTO park_executions(park_id,attempt,claimed_ms)
         VALUES (?1,lower(hex(randomblob(16))),?2) RETURNING attempt",
        params![park.id, history::now()],
        |row| row.get(0),
    )?)
}

fn run(
    db: &mut Connection,
    park: &ParkRef,
    manifest: &Manifest,
    attempt: String,
    adapter: &impl Adapter,
) -> Result<View, Error> {
    let before = adapter.observe().ok();
    let mut receipt = Receipt {
        attempt,
        outcome: Outcome::Failed,
        reason: None,
        before,
        apply: None,
        after_apply: None,
        rollback: None,
        restart_observation: None,
    };
    let Some(before) = &receipt.before else {
        receipt.reason = Some(Reason::InitialReadUnavailable);
        return finish(db, park, receipt);
    };
    if before.revision != manifest.precondition {
        receipt.reason = Some(Reason::PreconditionDrift);
        return finish(db, park, receipt);
    }
    // The pre-effect observation is durable before touching the marker.
    let prepared = db.execute(
        "UPDATE park_executions SET observed_before=?1
         WHERE park_id=?2 AND attempt=?3 AND receipt IS NULL",
        params![encode(before)?, park.id, receipt.attempt],
    )?;
    if prepared != 1 {
        return Err(Error::Conflict);
    }
    let expected = effect_marker(manifest, &receipt.attempt);
    let apply = adapter.apply(before, &expected);
    // Record the adapter return before readback or rollback can fail.
    let recorded = db.execute(
        "UPDATE park_executions SET apply_step=?1 WHERE park_id=?2 AND attempt=?3 AND receipt IS NULL",
        params![encode(&apply)?, park.id, receipt.attempt],
    )?;
    if recorded != 1 {
        return Err(Error::Conflict);
    }
    receipt.apply = Some(apply);
    receipt.after_apply = adapter.observe().ok();
    if apply == Step::Exit(0) && receipt.after_apply.as_ref() == Some(&expected) {
        receipt.outcome = Outcome::Verified;
        return finish(db, park, receipt);
    }
    receipt.reason = Some(match apply {
        Step::Exit(0) => Reason::VerificationFailed,
        Step::Drift => Reason::PreconditionDrift,
        _ => Reason::ApplyFailed,
    });
    if apply == Step::Drift || receipt.after_apply.as_ref() == Some(before) {
        return finish(db, park, receipt);
    }
    let rollback_authorized = match manifest.operation {
        // A ref readback has no attempt tag. Without a successful Git update,
        // this caller has no evidence that it owns the observed new value.
        Operation::AdvanceStagingRef { rollback, .. } => rollback && apply == Step::Exit(0),
        _ => true,
    };
    if rollback_authorized
        && (receipt.after_apply.is_none() || receipt.after_apply.as_ref() == Some(&expected))
    {
        let intent = RollbackIntent {
            after_apply: receipt.after_apply.clone(),
        };
        let prepared = db.execute(
            "UPDATE park_executions SET rollback_intent=?1
             WHERE park_id=?2 AND attempt=?3 AND receipt IS NULL",
            params![encode(&intent)?, park.id, receipt.attempt],
        )?;
        if prepared != 1 {
            return Err(Error::Conflict);
        }
        let step = adapter.rollback(&expected, before);
        let after = adapter.observe().ok();
        if after.as_ref() != Some(before) {
            receipt.outcome = Outcome::Reconciliation;
        }
        receipt.rollback = Some(Rollback { step: Some(step), after });
    } else {
        receipt.outcome = Outcome::Reconciliation;
    }
    finish(db, park, receipt)
}

fn reconcile_claim(db: &Connection, park: &ParkRef, attempt: &str, basis: &str) -> Result<View, Error> {
    let tx = Transaction::new_unchecked(db, TransactionBehavior::Immediate)?;
    if tx.execute(
        "UPDATE parks SET state='reconciliation'
         WHERE id=?1 AND manifest_digest=?2 AND state='executing'
           AND EXISTS (SELECT 1 FROM park_executions
                       WHERE park_id=?1 AND attempt=?3 AND receipt IS NULL)",
        params![park.id, park.manifest_digest, attempt],
    )? == 1 {
        record_decision(&tx, park, "hold", Decision {
            actor: "workspace", source: Source::Backstop, basis,
        }, None)?;
    }
    let view = status(&tx, park)?;
    tx.commit()?;
    Ok(view)
}

/// Startup recovery requires the former executor to be gone. It only reads the
/// effect and will never issue a new apply or rollback.
#[cfg(test)]
pub(crate) fn reconcile_after_restart(
    db: &mut Connection,
    park: &ParkRef,
    adapter: &impl Adapter,
) -> Result<View, Error> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let view = status(&tx, park)?;
    if view != View::Status(State::Executing) {
        return Ok(view);
    }
    let manifest = manifest_for(&tx, park)?;
    let (attempt, before, apply, rollback_intent): (
        String,
        Option<String>,
        Option<String>,
        Option<String>,
    ) = tx.query_row(
        "SELECT attempt,observed_before,apply_step,rollback_intent
         FROM park_executions WHERE park_id=?1",
        [&park.id],
        |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
    )?;
    let before: Option<Marker> = before.as_deref().map(decode).transpose()?;
    let apply: Option<Step> = apply.as_deref().map(decode).transpose()?;
    let intent: Option<RollbackIntent> = rollback_intent.as_deref().map(decode).transpose()?;
    let observed = adapter.observe().ok();
    let outcome = match (&before, &observed) {
        (Some(before), Some(observed)) if before == observed => Outcome::Failed,
        (Some(_), Some(observed))
            if intent.is_none()
                && matches!(apply, None | Some(Step::Exit(0)))
                && observed.attempt.as_deref() == Some(attempt.as_str())
                && *observed == effect_marker(&manifest, &attempt) =>
        {
            Outcome::Verified
        }
        _ => Outcome::Reconciliation,
    };
    let receipt = Receipt {
        attempt,
        outcome,
        reason: Some(Reason::Interrupted),
        before,
        apply,
        after_apply: intent.as_ref().and_then(|intent| intent.after_apply.clone()),
        rollback: intent.map(|_| Rollback {
            step: None,
            after: observed.clone(),
        }),
        restart_observation: observed,
    };
    let state = store_receipt(&tx, park, &receipt)?;
    tx.commit()?;
    Ok(View::Receipt(state, receipt))
}

fn effect_marker(manifest: &Manifest, attempt: &str) -> Marker {
    Marker {
        revision: manifest.expected_postcondition.clone(),
        attempt: matches!(manifest.operation, Operation::SetRevisionMarker { .. })
            .then(|| attempt.to_owned()),
    }
}

fn finish(db: &mut Connection, park: &ParkRef, receipt: Receipt) -> Result<View, Error> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let state = store_receipt(&tx, park, &receipt)?;
    tx.commit()?;
    Ok(View::Receipt(state, receipt))
}

fn store_receipt(tx: &Transaction<'_>, park: &ParkRef, receipt: &Receipt) -> Result<State, Error> {
    let (state, stored_state) = match receipt.outcome {
        Outcome::Verified => (State::Verified, "verified"),
        Outcome::Failed => (State::Failed, "failed"),
        Outcome::Reconciliation => (State::Reconciliation, "reconciliation"),
    };
    let changed = tx.execute(
        "UPDATE parks SET state=?1 WHERE id=?2 AND manifest_digest=?3 AND state='executing'",
        params![stored_state, park.id, park.manifest_digest],
    )?;
    let stored = tx.execute(
        "UPDATE park_executions SET receipt=?1,apply_step=coalesce(apply_step,?2)
         WHERE park_id=?3 AND attempt=?4 AND receipt IS NULL",
        params![encode(receipt)?, receipt.apply.as_ref().map(encode).transpose()?, park.id, receipt.attempt],
    )?;
    if changed != 1 || stored != 1 {
        return Err(Error::Conflict);
    }
    if state == State::Reconciliation {
        record_decision(tx, park, "hold", Decision {
            actor: "workspace", source: Source::Backstop,
            basis: "reconciliation: execution receipt requires review",
        }, None)?;
    }
    Ok(state)
}

pub(crate) fn manifest_for(db: &Connection, park: &ParkRef) -> Result<Manifest, Error> {
    let stored: String = db.query_row("SELECT manifest FROM parks WHERE id=?1", [&park.id], |r| {
        r.get(0)
    }).optional()?.ok_or(Error::Missing)?;
    if digest(&stored) != park.manifest_digest {
        return Err(Error::Conflict);
    }
    decode(&stored)
}

fn digest(stored: &str) -> String {
    format!("{:x}", Sha256::digest(stored.as_bytes()))
}

fn encode(value: &impl Serialize) -> Result<String, Error> {
    serde_json::to_string(value).map_err(|_| Error::Store(StoreError))
}

fn decode<T: DeserializeOwned>(value: &str) -> Result<T, Error> {
    serde_json::from_str(value).map_err(|_| Error::Store(StoreError))
}

#[cfg(test)]
pub(crate) mod tests;
