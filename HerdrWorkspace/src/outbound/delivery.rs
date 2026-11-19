//! A durable reservation fences provider submission. Recovery only reads Sent.
use super::{Payload, Version, gmail, is_latest};
use crate::{
    fleet_policy::{Authority, Evidence, principals::Purpose},
    history,
    parks::{self, Blocker, Error, ParkRef, State},
};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::Serialize;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Executor {
    account: gmail::Account,
    adapter: Arc<dyn Adapter>,
}

pub(crate) trait Adapter: Send + Sync {
    fn submit(&self, email: &super::Email, message_id: &str, reserved_ms: i64) -> gmail::SendReply;
    fn lookup(&self, email: &super::Email, message_id: &str, reserved_ms: i64) -> Option<String>;
}

impl Executor {
    #[cfg(test)]
    pub(crate) fn fixture(account: gmail::Account, adapter: Arc<dyn Adapter>) -> Self {
        Self { account, adapter }
    }

    fn approved_email<'a>(&self, version: &'a Version) -> Result<&'a super::Email, Error> {
        let Payload::Email(email) = &version.payload else {
            return Err(Error::Blocked(Blocker::OutboundDisabled));
        };
        if !self.account.permits(email) {
            return Err(Error::Blocked(Blocker::OutboundSender));
        }
        Ok(email)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
enum SendStatus {
    Submitting,
    Reconciliation,
    NotSubmitted,
    Accepted,
}

impl rusqlite::types::FromSql for SendStatus {
    fn column_result(value: rusqlite::types::ValueRef<'_>) -> rusqlite::types::FromSqlResult<Self> {
        match value.as_str()? {
            "submitting" => Ok(Self::Submitting),
            "reconciliation" => Ok(Self::Reconciliation),
            "not_submitted" => Ok(Self::NotSubmitted),
            "accepted" => Ok(Self::Accepted),
            _ => Err(rusqlite::types::FromSqlError::InvalidType),
        }
    }
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Receipt {
    draft_id: String,
    version: i64,
    park_id: String,
    attempt: String,
    payload_digest: String,
    message_id: String,
    provider_account: String,
    provider_id: Option<String>,
    status: SendStatus,
    #[serde(skip)]
    approval_id: i64,
    reserved_ms: i64,
    updated_ms: i64,
    accepted_ms: Option<i64>,
}

pub(super) fn receipt_for(db: &Connection, park: &str) -> rusqlite::Result<Option<Receipt>> {
    db.query_row(
        "SELECT draft_id,version,park_id,attempt,payload_digest,message_id,
                provider_account,provider_id,status,reserved_ms,updated_ms,accepted_ms,approval_id
         FROM outbound_receipts WHERE park_id=?1",
        [park], |row| Ok(Receipt {
            draft_id: row.get(0)?, version: row.get(1)?, park_id: row.get(2)?, attempt: row.get(3)?,
            payload_digest: row.get(4)?, message_id: row.get(5)?, provider_account: row.get(6)?,
            provider_id: row.get(7)?, status: row.get(8)?, reserved_ms: row.get(9)?,
            updated_ms: row.get(10)?, accepted_ms: row.get(11)?, approval_id: row.get(12)?,
        }),
    ).optional()
}

pub(super) fn claimable(db: &Connection, version: &Version) -> Result<bool, Error> {
    Ok(match (&version.receipt, version.state) {
        (None, State::Pending) => !parks::has_execution(db, &version.park)?,
        (Some(receipt), State::Failed) if receipt.status == SendStatus::NotSubmitted => {
            check_binding(db, version, receipt)?;
            true
        }
        _ => false,
    })
}

fn check_binding(db: &Connection, version: &Version, receipt: &Receipt) -> Result<(), Error> {
    let bound: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM park_executions WHERE park_id=?1 AND attempt=?2)",
        params![version.park.id, receipt.attempt], |row| row.get(0),
    )?;
    if !bound || receipt.draft_id != version.draft_id || receipt.version != version.version
        || receipt.payload_digest != version.payload_digest
        || receipt.message_id != message_id(&receipt.attempt)
    {
        return Err(Error::Conflict);
    }
    Ok(())
}

fn message_id(attempt: &str) -> String {
    format!("<{attempt}@outbound.swarmhub.invalid>")
}

pub(crate) enum Reservation {
    Claimed,
    Existing(Receipt),
}

pub(crate) fn reserve(
    tx: &Transaction<'_>, park: &ParkRef, authority: &Authority, executor: &Executor,
    claim: impl FnOnce(bool) -> Result<String, Error>,
) -> Result<Reservation, Error> {
    let version = super::for_park(tx, &park.id)?.ok_or(Error::Missing)?;
    if version.park != *park {
        return Err(Error::Conflict);
    }
    let claimable = claimable(tx, &version)?;
    if !claimable {
        if let Some(receipt) = &version.receipt {
            check_binding(tx, &version, receipt)?;
            return Ok(Reservation::Existing(version.receipt.unwrap()));
        }
        return Err(Error::Conflict);
    }
    if !is_latest(tx, &version)? {
        return Err(Error::Conflict);
    }
    let approval = version.approval.as_ref().filter(|_| !version.approval_revoked)
        .ok_or(Error::Blocked(Blocker::OutboundApproval))?;
    executor.approved_email(&version)?;
    authority.with_park_decision(&**tx, park, Purpose::AuthorizeOutbound,
        Evidence::OperatorSignature(approval), None, |_, _| {
            let approval_id = version.approval_id.ok_or(Error::Conflict)?;
            let attempt = claim(version.receipt.is_some())?;
            let now = history::now();
            if let Some(receipt) = version.receipt {
                if receipt.attempt != attempt || receipt.provider_account != executor.account.sender
                    || tx.execute(
                        "UPDATE outbound_receipts SET status='submitting',approval_id=?2,updated_ms=?3
                         WHERE park_id=?1 AND status='not_submitted'",
                        params![park.id, approval_id, now],
                    )? != 1
                {
                    return Err(Error::Conflict);
                }
            } else {
                tx.execute(
                    "INSERT INTO outbound_receipts(park_id,draft_id,version,attempt,payload_digest,
                         message_id,provider_account,approval_id,status,reserved_ms,updated_ms)
                     VALUES(?1,?2,?3,?4,?5,?6,?7,?8,'submitting',?9,?9)",
                    params![park.id, version.draft_id, version.version, attempt, version.payload_digest,
                        message_id(&attempt), executor.account.sender, approval_id, now],
                )?;
            }
            Ok(Reservation::Claimed)
        })?
}

pub(crate) fn submit(
    db: &mut Connection, park: &ParkRef, authority: &Authority, evidence: Evidence<'_>,
    executor: &Executor,
) -> Result<Receipt, Error> {
    let version = super::for_park(db, &park.id)?.ok_or(Error::Missing)?;
    let receipt = version.receipt.as_ref().ok_or(Error::Conflict)?;
    if version.park != *park || receipt.provider_account != executor.account.sender
        || !matches!(version.state, State::Executing | State::Reconciliation)
        || !matches!(receipt.status, SendStatus::Submitting | SendStatus::Reconciliation)
        || version.approval_id != Some(receipt.approval_id)
    {
        return Err(Error::Conflict);
    }
    check_binding(db, &version, receipt)?;
    let approval = version.approval.as_ref().filter(|_| !version.approval_revoked)
        .ok_or(Error::Blocked(Blocker::OutboundApproval))?;
    let email = executor.approved_email(&version)?;
    // Both signatures and the protected policy are checked again at the effect boundary.
    // If authorization fails here, the provider was never called.
    let outcome = authority.with_park_decision(&*db, park, Purpose::Execute, evidence, None, |db, _| {
        authority.with_park_decision(db, park, Purpose::AuthorizeOutbound,
            Evidence::OperatorSignature(approval), None, |_, _| {
                executor.adapter.submit(email, &receipt.message_id, receipt.reserved_ms).into()
            })
    }).and_then(|result| result).unwrap_or(gmail::Submission::NotSubmitted);
    let result = settle(db, receipt, outcome)?;
    if result.status == SendStatus::Reconciliation {
        return reconcile(db, park, executor);
    }
    Ok(result)
}

pub(super) fn reconcile(db: &mut Connection, park: &ParkRef, executor: &Executor) -> Result<Receipt, Error> {
    let version = super::for_park(db, &park.id)?.ok_or(Error::Missing)?;
    if version.park != *park {
        return Err(Error::Conflict);
    }
    let receipt = version.receipt.as_ref().ok_or(Error::Missing)?;
    check_binding(db, &version, receipt)?;
    if matches!(receipt.status, SendStatus::Accepted | SendStatus::NotSubmitted) {
        return Ok(version.receipt.unwrap());
    }
    if receipt.provider_account != executor.account.sender {
        return Err(Error::Blocked(Blocker::OutboundSender));
    }
    let email = executor.approved_email(&version)?;
    let outcome = executor.adapter.lookup(email, &receipt.message_id, receipt.reserved_ms)
        .filter(|id| gmail::provider_id(id))
        .map_or(gmail::Submission::Reconciliation, gmail::Submission::Accepted);
    settle(db, receipt, outcome)
}

fn settle(
    db: &mut Connection, receipt: &Receipt, outcome: gmail::Submission,
) -> Result<Receipt, Error> {
    let (status, park_state, provider_id) = match outcome {
        gmail::Submission::Accepted(id) => ("accepted", "verified", Some(id)),
        gmail::Submission::NotSubmitted => ("not_submitted", "failed", None),
        gmail::Submission::Reconciliation => ("reconciliation", "reconciliation", None),
    };
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    if tx.execute(
        "UPDATE outbound_receipts SET status=?3,provider_id=?4,updated_ms=?5,
             accepted_ms=CASE WHEN ?4 IS NULL THEN NULL ELSE ?5 END
         WHERE park_id=?1 AND attempt=?2 AND status IN ('submitting','reconciliation')",
        params![receipt.park_id, receipt.attempt, status, provider_id, history::now()],
    )? == 1 && tx.execute(
        "UPDATE parks SET state=?2 WHERE id=?1 AND state IN ('executing','reconciliation')",
        params![receipt.park_id, park_state],
    )? != 1 {
        return Err(Error::Conflict);
    }
    let current = receipt_for(&tx, &receipt.park_id)?.ok_or(Error::Conflict)?;
    tx.commit()?;
    Ok(current)
}
