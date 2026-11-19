//! Coordinator journal for managed jobs. This slice wires only the read side to HTTP.
// Fixtures exercise the internal write entry points until dispatch is wired.
#![allow(dead_code)]

use crate::{
    ApiError, Workspace, bots,
    history::{StoreError, now},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::get,
};
use rusqlite::{
    Connection, OptionalExtension, TransactionBehavior, params,
    types::{FromSql, FromSqlError, FromSqlResult, ValueRef},
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const BRIEF_MAX: usize = 12_000;
const WORKDIR_MAX: usize = 4096;
const KEY_MAX: usize = 128;

#[derive(Debug)]
pub(crate) enum Error {
    Storage(StoreError),
    InvalidInput,
    UnknownOwner,
    MissingAttempt,
    Conflict,
}

impl From<rusqlite::Error> for Error {
    fn from(error: rusqlite::Error) -> Self {
        Self::Storage(error.into())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct Runtime {
    pub provider: String,
    pub account_ref: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl Runtime {
    fn valid(&self) -> bool {
        identifier(&self.provider, 64)
            && self.account_ref.as_deref().is_none_or(|s| identifier(s, 128))
            && [&self.model, &self.effort]
                .into_iter()
                .flatten()
                .all(|s| single_line(s, 160))
    }
}

impl FromSql for Runtime {
    fn column_result(value: ValueRef<'_>) -> FromSqlResult<Self> {
        serde_json::from_str(value.as_str()?).map_err(|error| FromSqlError::Other(Box::new(error)))
    }
}

#[derive(Clone, Serialize)]
pub(crate) struct Submission {
    pub project: i64,
    pub brief: String,
    pub workdir: String,
    pub runtime: Runtime,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Job {
    pub id: String,
    pub payload_digest: String,
}

pub(crate) fn submit(
    db: &mut Connection,
    owner_bot_id: &str,
    key: &str,
    job: &Submission,
) -> Result<Job, Error> {
    if job.project <= 0
        || !bounded(&job.brief, BRIEF_MAX)
        || job.brief.chars().any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
        || !single_line(&job.workdir, WORKDIR_MAX)
        || !single_line(key, KEY_MAX)
        || !job.runtime.valid()
    {
        return Err(Error::InvalidInput);
    }

    let payload = serde_json::to_vec(job).map_err(|_| Error::InvalidInput)?;
    let digest = format!("{:x}", Sha256::digest(payload));
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let prior = tx
        .query_row(
            "SELECT id,payload_digest FROM jobs WHERE owner_bot_id=?1 AND submit_key=?2",
            params![owner_bot_id, key],
            |r| {
                Ok(Job {
                    id: r.get(0)?,
                    payload_digest: r.get(1)?,
                })
            },
        )
        .optional()?;
    if let Some(prior) = prior {
        if prior.payload_digest != digest {
            return Err(Error::Conflict);
        }
        tx.commit()?;
        return Ok(prior);
    }
    let owner = bots::one(&tx, owner_bot_id)?.ok_or(Error::UnknownOwner)?;
    let runtime = serde_json::to_string(&job.runtime).map_err(|_| Error::InvalidInput)?;
    let id = tx.query_row(
        "INSERT INTO jobs (id,owner_bot_id,project,brief,workdir,requested_runtime,
                           submit_key,payload_digest,created_ms)
         VALUES (lower(hex(randomblob(16))),?1,?2,?3,?4,?5,?6,?7,?8)
         RETURNING id",
        params![owner.id, job.project, job.brief, job.workdir, runtime, key, digest, now()],
        |r| r.get(0),
    )?;
    tx.execute(
        "INSERT INTO job_attempts (job_id,attempt,status,requested_runtime)
         VALUES (?1,1,'queued',?2)",
        params![id, runtime],
    )?;
    tx.commit()?;
    Ok(Job {
        id,
        payload_digest: digest,
    })
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Dispatch {
    Recorded,
    AlreadyRecorded,
}

/// The caller may initiate transport only on Recorded, after this write commits.
pub(crate) fn record_dispatch(
    db: &mut Connection,
    job_id: &str,
    attempt: i64,
    host_id: &str,
    lease_id: &str,
) -> Result<Dispatch, Error> {
    if !single_line(host_id, 128) || !single_line(lease_id, 128) {
        return Err(Error::InvalidInput);
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let changed = tx.execute(
        "UPDATE job_attempts SET status='dispatching',host_id=?3,lease_id=?4
         WHERE job_id=?1 AND attempt=?2 AND status='queued'",
        params![job_id, attempt, host_id, lease_id],
    )?;
    if changed == 1 {
        tx.commit()?;
        return Ok(Dispatch::Recorded);
    }
    let same = tx
        .query_row(
            "SELECT host_id IS ?3 AND lease_id IS ?4 FROM job_attempts WHERE job_id=?1 AND attempt=?2",
            params![job_id, attempt, host_id, lease_id],
            |r| r.get(0),
        )
        .optional()?
        .ok_or(Error::MissingAttempt)?;
    if same {
        tx.commit()?;
        Ok(Dispatch::AlreadyRecorded)
    } else {
        Err(Error::Conflict)
    }
}

pub(crate) fn record_running(db: &Connection, job_id: &str, attempt: i64) -> Result<bool, Error> {
    Ok(db.execute(
        "UPDATE job_attempts SET status='running'
         WHERE job_id=?1 AND attempt=?2 AND status='dispatching'",
        params![job_id, attempt],
    )? == 1)
}

/// A start or exit that could not be confirmed has no completion event yet.
pub(crate) fn record_unknown(db: &Connection, job_id: &str, attempt: i64) -> Result<bool, Error> {
    Ok(db.execute(
        "UPDATE job_attempts SET status='unknown',
           exit_reason=CASE status WHEN 'dispatching' THEN 'start_unconfirmed' ELSE 'exit_unconfirmed' END
         WHERE job_id=?1 AND attempt=?2 AND status IN ('dispatching','running')",
        params![job_id, attempt],
    )? == 1)
}

#[derive(Clone, Copy)]
pub(crate) enum Exit {
    Exited(i32),
    Cancelled,
    Interrupted,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Artifact {
    pub reference: String,
    pub digest: String,
}

pub(crate) struct Report {
    // Only confirmed outcomes are terminal. Use record_unknown for missing evidence of exit.
    pub exit: Exit,
    pub observed_runtime: Option<Runtime>,
    pub observed_cli_version: Option<String>,
    pub log_ref: Option<String>,
    pub result: Option<Artifact>,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct ExitDetails {
    pub status: String,
    pub code: Option<i32>,
    pub reason: String,
    pub verdict: String,
    pub log_ref: Option<String>,
    pub result: Option<Artifact>,
}

impl Report {
    fn outcome(&self) -> Result<(ExitDetails, &'static str), Error> {
        if !self.observed_runtime.as_ref().is_none_or(Runtime::valid)
            || !self.observed_cli_version.as_deref().is_none_or(|s| single_line(s, 160))
            || !self.log_ref.as_deref().is_none_or(|s| identifier(s, 128))
            || !self.result.as_ref().is_none_or(|result| {
                identifier(&result.reference, 128)
                    && result.digest.len() == 64
                    && result.digest.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
            })
        {
            return Err(Error::InvalidInput);
        }

        let (status, code, reason, verdict, action) = match self.exit {
            Exit::Exited(0) if self.result.is_some() => {
                ("exited", Some(0), "completed", "succeeded", "review_result")
            }
            Exit::Exited(0) => {
                ("exited", Some(0), "missing_result", "failed", "inspect_failure")
            }
            Exit::Exited(code) => {
                ("exited", Some(code), "nonzero_exit", "failed", "inspect_failure")
            }
            Exit::Cancelled => (
                "cancelled",
                None,
                "cancelled",
                "cancelled",
                "review_cancellation",
            ),
            Exit::Interrupted => (
                "interrupted",
                None,
                "interrupted",
                "interrupted",
                "review_interruption",
            ),
        };
        Ok((
            ExitDetails {
                status: status.into(),
                code,
                reason: reason.into(),
                verdict: verdict.into(),
                log_ref: self.log_ref.clone(),
                result: self.result.clone(),
            },
            action,
        ))
    }
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Completion {
    pub job_id: String,
    pub attempt: i64,
    pub owner_bot_id: String,
    pub created_ms: i64,
    pub exit: ExitDetails,
    pub expected_next_action: String,
}

#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct JobStatus {
    pub id: String,
    pub owner_bot_id: String,
    pub project: i64,
    pub attempt: i64,
    pub status: String,
    pub exit_reason: Option<String>,
    pub requested_runtime: Runtime,
    pub observed_runtime: Option<Runtime>,
    pub observed_cli_version: Option<String>,
    pub completion: Option<Completion>,
}

pub(crate) fn finish(
    db: &mut Connection,
    job_id: &str,
    attempt: i64,
    report: &Report,
) -> Result<Completion, Error> {
    finish_inner(db, job_id, attempt, report, || {})
}

fn finish_inner(
    db: &mut Connection,
    job_id: &str,
    attempt: i64,
    report: &Report,
    after_update: impl FnOnce(),
) -> Result<Completion, Error> {
    let (exit, action) = report.outcome()?;
    let runtime = report
        .observed_runtime
        .as_ref()
        .map(serde_json::to_string)
        .transpose()
        .map_err(|_| Error::InvalidInput)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let changed = tx.execute(
        "UPDATE job_attempts SET status=?3,exit_code=?4,exit_reason=?5,verdict=?6,log_ref=?7,
           result_ref=?8,result_digest=?9,observed_runtime=?10,observed_cli_version=?11
         WHERE job_id=?1 AND attempt=?2
           AND (status IN ('dispatching','running','unknown') OR (status='queued' AND ?3='cancelled'))",
        params![
            job_id, attempt, exit.status, exit.code, exit.reason, exit.verdict, exit.log_ref,
            exit.result.as_ref().map(|r| &r.reference), exit.result.as_ref().map(|r| &r.digest),
            runtime, report.observed_cli_version,
        ],
    )?;
    if changed == 0 {
        let prior = read_status(&tx, job_id, Some(attempt))?.ok_or(Error::MissingAttempt)?;
        let event = prior.completion.ok_or(Error::Conflict)?;
        if event.exit != exit
            || prior.observed_runtime != report.observed_runtime
            || prior.observed_cli_version != report.observed_cli_version
        {
            return Err(Error::Conflict);
        }
        tx.commit()?;
        return Ok(event);
    }

    after_update();
    let at = now();
    let owner_bot_id = tx.query_row(
        "INSERT INTO job_completions (job_id,attempt,owner_bot_id,expected_next_action,created_ms)
         SELECT id,?2,owner_bot_id,?3,?4 FROM jobs WHERE id=?1
         RETURNING owner_bot_id",
        params![job_id, attempt, action, at],
        |r| r.get(0),
    )?;
    tx.commit()?;
    Ok(Completion {
        job_id: job_id.into(),
        attempt,
        owner_bot_id,
        created_ms: at,
        exit,
        expected_next_action: action.into(),
    })
}

pub(crate) fn status(db: &Connection, id: &str) -> rusqlite::Result<Option<JobStatus>> {
    read_status(db, id, None)
}

fn read_status(db: &Connection, id: &str, attempt: Option<i64>) -> rusqlite::Result<Option<JobStatus>> {
    db.query_row(
        "SELECT j.id,j.owner_bot_id,j.project,a.attempt,a.status,a.exit_reason,a.requested_runtime,
                a.observed_runtime,a.observed_cli_version,c.created_ms,c.owner_bot_id AS event_owner,
                c.expected_next_action,a.exit_code,a.verdict,a.log_ref,a.result_ref,a.result_digest
         FROM jobs j JOIN job_attempts a ON a.job_id=j.id
         LEFT JOIN job_completions c ON c.job_id=a.job_id AND c.attempt=a.attempt
         WHERE j.id=?1 AND (?2 IS NULL OR a.attempt=?2)
         ORDER BY a.attempt DESC LIMIT 1",
        params![id, attempt],
        |r| {
            let completion = if let Some(created_ms) = r.get::<_, Option<i64>>("created_ms")? {
                let result = if let Some(reference) = r.get("result_ref")? {
                    Some(Artifact {
                        reference,
                        digest: r.get("result_digest")?,
                    })
                } else {
                    None
                };
                Some(Completion {
                    job_id: r.get("id")?,
                    attempt: r.get("attempt")?,
                    owner_bot_id: r.get("event_owner")?,
                    created_ms,
                    expected_next_action: r.get("expected_next_action")?,
                    exit: ExitDetails {
                        status: r.get("status")?,
                        code: r.get("exit_code")?,
                        reason: r.get("exit_reason")?,
                        verdict: r.get("verdict")?,
                        log_ref: r.get("log_ref")?,
                        result,
                    },
                })
            } else {
                None
            };
            Ok(JobStatus {
                id: r.get("id")?,
                owner_bot_id: r.get("owner_bot_id")?,
                project: r.get("project")?,
                attempt: r.get("attempt")?,
                status: r.get("status")?,
                exit_reason: r.get("exit_reason")?,
                requested_runtime: r.get("requested_runtime")?,
                observed_runtime: r.get("observed_runtime")?,
                observed_cli_version: r.get("observed_cli_version")?,
                completion,
            })
        },
    )
    .optional()
}

fn bounded(value: &str, max: usize) -> bool {
    value.len() <= max && !value.trim().is_empty()
}

fn single_line(value: &str, max: usize) -> bool {
    bounded(value, max) && !value.chars().any(char::is_control)
}

// References are opaque tokens. They cannot represent paths, URLs or encoded separators.
fn identifier(value: &str, max: usize) -> bool {
    (1..=max).contains(&value.len())
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route("/api/jobs/{id}", get(job_status))
}

async fn job_status(
    State(w): State<Workspace>,
    Path(id): Path<String>,
) -> Result<Json<JobStatus>, ApiError> {
    let db = w.history.db()?;
    status(&db, &id)
        .map_err(StoreError::from)?
        .map(Json)
        .ok_or(ApiError::NotFound)
}

#[cfg(test)]
pub(crate) mod tests;
