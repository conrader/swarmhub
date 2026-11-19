use super::{
    Artifact, Dispatch, Error, Exit, FinishEvidence, Job, JobStatus, Report, Runtime, Submission,
    finish_inner, identifier, queue, read_status, record_dispatch, status, submission_digest, submit_with_placement,
};
use crate::{
    Core, Workspace, bots, helpers,
    history::StoreError,
    job_worker::bridge::{Placement, Ticket, Verb, WorkerView},
    machines::probe::Provider,
    projects,
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{fs, os::unix::fs::{FileTypeExt, MetadataExt}, path::Path, time::Duration};
use tokio::{sync::Notify, task::JoinSet};

const STORAGE: &str = "The workspace could not use its managed job journal.";
const NO_JOB: &str = "No job with that ID belongs to this owner.";
const NO_PROJECT: &str = "This session has no grant for the selected project.";
const NO_PLACEMENT: &str = "The project, workdir and runtime have no enrolled fixture worker.";
const INTERVAL: Duration = Duration::from_secs(2);
const CONCURRENT: usize = 8;
static WAKE: Notify = Notify::const_new();

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Submit {
    pub project: i64,
    pub workdir: String,
    pub brief: String,
    pub provider: Provider,
    pub profile: String,
    pub model: Option<String>,
    pub effort: Option<String>,
}

impl Submit {
    pub(crate) fn submission(&self) -> Submission {
        Submission {
            project: self.project,
            workdir: self.workdir.clone(),
            brief: self.brief.clone(),
            runtime: Runtime {
                provider: provider_name(self.provider).into(),
                account_ref: None,
                model: self.model.clone(),
                family: None,
                effort: self.effort.clone(),
            },
        }
    }
}

fn provider_name(provider: Provider) -> &'static str {
    match provider {
        Provider::Claude => "claude",
        Provider::Codex => "codex",
    }
}

#[derive(Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(tag = "verb", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Command {
    Submit { key: String, input: Submit },
    List,
    Status { id: String },
    Cancel { id: String },
    Result { id: String, reference: String },
}

#[cfg(any(test, feature = "fleet-test-fixture"))]
pub(crate) fn configured_core(ordinary: &Path) -> Option<Core> {
    let path = std::path::PathBuf::from(std::env::var_os("SWARMHUB_FIXTURE_WORKER_CORE")?);
    if !path.is_absolute() {
        return None;
    }
    let path = path.parent()?.canonicalize().ok()?.join(path.file_name()?);
    match protected_core(&path, ordinary) {
        Ok(()) | Err("host_unreachable") => Some(Core(path)),
        Err(_) => None,
    }
}

#[cfg(not(any(test, feature = "fleet-test-fixture")))]
pub(crate) fn configured_core(_ordinary: &Path) -> Option<Core> {
    None
}

fn protected_core(path: &Path, ordinary: &Path) -> Result<(), &'static str> {
    const UNSAFE: &str = "worker_core_unprotected";
    if path == ordinary {
        return Err(UNSAFE);
    }
    let parent = fs::symlink_metadata(path.parent().ok_or(UNSAFE)?).map_err(|_| UNSAFE)?;
    // SAFETY: geteuid returns the bridge account's effective UID.
    let owner = unsafe { libc::geteuid() };
    if !parent.is_dir() || parent.uid() != owner || parent.mode() & 0o077 != 0 {
        return Err(UNSAFE);
    }
    let socket = fs::symlink_metadata(path).map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound { "host_unreachable" } else { UNSAFE }
    })?;
    let aliases_ordinary = fs::metadata(ordinary).is_ok_and(|file| {
        (file.dev(), file.ino()) == (socket.dev(), socket.ino())
    });
    if socket.uid() != owner || !socket.file_type().is_socket() || aliases_ordinary {
        return Err(UNSAFE);
    }
    Ok(())
}

pub(crate) async fn current_owner(w: &Workspace, core: &str, launch: &str, helper: bool) -> Result<String, String> {
    if !w.core.agents().await.map_err(helpers::explain)?.iter().any(|agent| {
        agent.launch_key() == Some(launch) && agent.require_live().is_ok()
    }) {
        return Err("Use a live registered session to manage jobs.".into());
    }
    let db = w.history.db().map_err(|_| STORAGE)?;
    helpers::policy::job_owner(&db, core, launch, helper).map_err(|_| STORAGE)?
        .map(|owner| owner.id)
        .ok_or_else(|| "Use the current owner session, or one of its helpers to submit a job.".into())
}

pub(crate) fn wake() {
    WAKE.notify_one();
}

pub(crate) async fn answer(w: &Workspace, core: &str, launch: &str, command: Command) -> Result<String, String> {
    let owner = current_owner(w, core, launch, matches!(command, Command::Submit { .. })).await?;
    match command {
        Command::Submit { key, input } => {
            let job = submit(w, &owner, launch, &key, &input)?;
            WAKE.notify_one();
            json(&job)
        }
        Command::List => {
            let db = w.history.db().map_err(|_| STORAGE)?;
            let ids = db.prepare(
                "SELECT id FROM jobs WHERE owner_bot_id=?1 ORDER BY created_ms DESC,id LIMIT 100",
            ).and_then(|mut rows| rows.query_map([&owner], |row| row.get::<_, String>(0))?.collect::<rusqlite::Result<Vec<_>>>())
                .map_err(|_| STORAGE)?;
            let jobs = ids.iter().map(|id| owned(&db, &owner, id)).collect::<Result<Vec<_>, _>>()?;
            json(&jobs)
        }
        Command::Status { id } => {
            let db = w.history.db().map_err(|_| STORAGE)?;
            json(&owned(&db, &owner, &id)?)
        }
        Command::Cancel { id } => {
            let db = w.history.db().map_err(|_| STORAGE)?;
            let job = owned(&db, &owner, &id)?;
            db.execute(
                "UPDATE job_attempts SET requested_runtime=json_set(requested_runtime,'$.cancel_requested',1)
                 WHERE job_id=?1 AND attempt=?2 AND status IN ('queued','dispatching','running','unknown')",
                params![job.id, job.attempt],
            ).map_err(|_| STORAGE)?;
            WAKE.notify_one();
            json(&owned(&db, &owner, &id)?)
        }
        Command::Result { id, reference } => result(w, &owner, &id, &reference).await,
    }
}

fn json(value: &impl Serialize) -> Result<String, String> {
    serde_json::to_string(value).map_err(|_| STORAGE.into())
}

fn owned(db: &Connection, owner: &str, id: &str) -> Result<JobStatus, String> {
    if !identifier(id, 128) {
        return Err(NO_JOB.into());
    }
    status(db, id).map_err(|_| STORAGE)?
        .filter(|job| job.owner_bot_id == owner)
        .ok_or_else(|| NO_JOB.into())
}

fn submit(w: &Workspace, owner: &str, launch: &str, key: &str, input: &Submit) -> Result<Job, String> {
    let mut db = w.history.db().map_err(|_| STORAGE)?;
    if !projects::can_use(&db, launch, input.project).map_err(|_| STORAGE)? {
        return Err(NO_PROJECT.into());
    }
    let submission = input.submission();
    let payload = submission_digest(&submission, Some(&input.profile)).map_err(|_| STORAGE)?;
    if let Some(job) = existing_submission(&db, owner, key, &payload)? {
        if crate::job_reviews::reserved_key(key) && db.query_row(
            "SELECT EXISTS(SELECT 1 FROM job_review_rounds WHERE producer_job=?1 AND round>0)",
            [&job.id], |row| row.get(0),
        ).map_err(|_| STORAGE)? {
            return Err("Use bot job review to retry a fix reservation.".into());
        }
        return Ok(job);
    }
    if crate::job_reviews::reserved_key(key) {
        return Err("Use bot job review to reserve a fix round.".into());
    }
    let placement = enrolled(w, &db, input).map_err(str::to_owned)?;
    validate_ticket(&placement, owner, &submission, &payload)?;
    submit_with_placement(&mut db, owner, key, &submission, Some(&placement)).map_err(explain)
}

fn existing_submission(db: &Connection, owner: &str, key: &str, digest: &str) -> Result<Option<Job>, String> {
    let prior = db.query_row(
        "SELECT id,payload_digest FROM jobs WHERE owner_bot_id=?1 AND submit_key=?2",
        params![owner, key], |row| Ok(Job { id: row.get(0)?, payload_digest: row.get(1)? }),
    ).optional().map_err(|_| STORAGE)?;
    match prior {
        Some(job) if job.payload_digest != digest => Err(explain(Error::Conflict)),
        prior => Ok(prior),
    }
}

fn validate_ticket(placement: &Placement, owner: &str, submission: &Submission, digest: &str) -> Result<(), String> {
    Ticket::new(placement, "00000000000000000000000000000000", 1, owner, submission, digest)
        .map(|_| ()).ok_or_else(|| explain(Error::InvalidInput))
}

pub(crate) fn queue_review_fix(
    tx: &rusqlite::Transaction<'_>, owner: &str, key: &str, input: &Submit,
    policy: &crate::fleet_policy::Policy, reserved_job: Option<&str>,
) -> Result<Job, String> {
    let submission = input.submission();
    let digest = submission_digest(&submission, Some(&input.profile)).map_err(explain)?;
    let prior = existing_submission(tx, owner, key, &digest)?;
    if let Some(job) = prior {
        return (reserved_job == Some(job.id.as_str())).then_some(job).ok_or_else(|| explain(Error::Conflict));
    }
    if reserved_job.is_some() {
        return Err(STORAGE.into());
    }
    let project = projects::one(tx, input.project).map_err(|_| STORAGE)?.ok_or(NO_PLACEMENT)?;
    let placement = projects::fixture_placement(&project, policy, input).ok_or(NO_PLACEMENT)?;
    validate_ticket(&placement, owner, &submission, &digest)?;
    queue(tx, owner, key, &submission, Some(&placement)).map_err(explain)
}

fn explain(error: Error) -> String {
    match error {
        Error::InvalidInput => "Use a bounded fixture brief, profile, model, effort and submission key.",
        Error::Conflict => "This submission key belongs to a different job payload.",
        _ => STORAGE,
    }.into()
}

fn enrolled(w: &Workspace, db: &Connection, input: &Submit) -> Result<Placement, &'static str> {
    let project = projects::one(db, input.project).map_err(|_| STORAGE)?.ok_or(NO_PLACEMENT)?;
    let authority = w.fleet_policy.as_ref().ok().and_then(Option::as_ref).ok_or(NO_PLACEMENT)?;
    authority.with_worker_policy(|_, _, policy, _| projects::fixture_placement(&project, policy, input))
        .map_err(|_| NO_PLACEMENT)?
        .ok_or(NO_PLACEMENT)
}

struct Pending {
    status: JobStatus,
    placement: Placement,
    input: Submit,
    ticket: Ticket,
    dispatched: bool,
}

impl Pending {
    fn load(db: &Connection, id: &str, attempt: i64) -> Result<Option<Self>, StoreError> {
        let Some(status) = read_status(db, id, Some(attempt))? else {
            return Ok(None);
        };
        let saved = db.query_row(
            "SELECT j.brief,j.workdir,j.payload_digest,j.requested_runtime,
                    json_extract(j.requested_runtime,'$.placement'),a.lease_id
             FROM jobs j JOIN job_attempts a ON a.job_id=j.id
             WHERE j.id=?1 AND a.attempt=?2 AND json_type(j.requested_runtime,'$.placement')='object'",
            params![id, attempt],
            |row| Ok((
                row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?,
                row.get::<_, Runtime>(3)?, row.get::<_, String>(4)?, row.get::<_, Option<String>>(5)?,
            )),
        ).optional()?;
        let Some((brief, workdir, payload, runtime, placement, pin)) = saved else {
            return Ok(None);
        };
        let Ok(placement) = serde_json::from_str::<Placement>(&placement) else {
            return Ok(None);
        };
        let input = Submit {
            project: status.project,
            workdir,
            brief,
            provider: placement.provider,
            profile: placement.profile.clone(),
            model: runtime.model.clone(),
            effort: runtime.effort.clone(),
        };
        let submission = input.submission();
        if submission.runtime != runtime
            || submission_digest(&submission, Some(&input.profile)).as_deref().ok() != Some(payload.as_str())
        {
            return Ok(None);
        }
        let Some(ticket) = Ticket::new(&placement, id, attempt, &status.owner_bot_id, &submission, &payload) else {
            return Ok(None);
        };
        if pin.as_ref().is_some_and(|pin| pin != &ticket.manifest_digest)
            || status.host_id.as_ref().is_some_and(|host| host != &placement.host_id)
        {
            return Ok(None);
        }
        Ok(Some(Self { status, placement, input, ticket, dispatched: pin.is_some() }))
    }

    async fn core<'a>(&self, w: &'a Workspace) -> Result<&'a Core, &'static str> {
        let core = w.worker_core.as_ref().ok_or("worker_core_unconfigured")?;
        protected_core(&core.0, &w.core.0)?;
        let machines = core.machines().await.map_err(|_| "host_unreachable")?;
        let host = machines.iter().find(|host| host.name.eq_ignore_ascii_case(&self.placement.machine))
            .ok_or("host_unreachable")?;
        if host.target != self.placement.target || host.temporary || host.via {
            return Err("worker_identity_mismatch");
        }
        if host.state != "connected" {
            return Err("host_unreachable");
        }
        Ok(core)
    }

    async fn call(&self, core: &Core, verb: Verb, result: Option<&str>) -> Result<WorkerView, &'static str> {
        self.ticket.request(core, &self.placement.machine, verb, result).await
    }
}

pub(crate) fn start_serving(w: Workspace) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            if poll(&w).await {
                let _ = tokio::time::timeout(INTERVAL, WAKE.notified()).await;
            } else {
                // Submitting a job or reserving a review fix wakes this loop after commit.
                WAKE.notified().await;
            }
        }
    })
}

/// Returns whether work or a journal error needs another timed poll.
pub(crate) async fn poll(w: &Workspace) -> bool {
    let pending = (|| {
        let db = w.history.db()?;
        let mut rows = db.prepare(
            "SELECT a.job_id,a.attempt FROM job_attempts a JOIN jobs j ON j.id=a.job_id
             WHERE a.status IN ('queued','dispatching','running','unknown')
               AND json_type(j.requested_runtime,'$.placement')='object'
             ORDER BY j.created_ms,j.id,a.attempt",
        )?;
        Ok::<_, StoreError>(rows.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)))?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    })();
    let Ok(pending) = pending else { return true };
    if pending.is_empty() {
        return false;
    }
    let mut tasks = JoinSet::new();
    for (id, number) in pending {
        if tasks.len() >= CONCURRENT {
            let _ = tasks.join_next().await;
        }
        let w = w.clone();
        tasks.spawn(async move {
            if let Err(error) = reconcile(&w, &id, number).await {
                eprintln!("Managed job {id}:{number} journal reconciliation failed: {error:?}");
            }
        });
    }
    while tasks.join_next().await.is_some() {}
    true
}

async fn reconcile(w: &Workspace, id: &str, number: i64) -> Result<(), Error> {
    let loaded = {
        let db = w.history.db()?;
        Pending::load(&db, id, number)?
    };
    let Some(mut pending) = loaded else { return Ok(()) };
    if pending.status.completion.is_some() {
        return Ok(());
    }
    if !pending.dispatched && pending.status.cancel_requested {
        return settle(w, &pending, &Report {
            exit: Exit::Cancelled, observed_runtime: None, observed_cli_version: None, log_ref: None, result: None,
        }, None, false);
    }
    let core = match pending.core(w).await {
        Ok(core) => core,
        Err(reason) => return unavailable(w, &pending, reason),
    };
    let verb = if pending.status.cancel_requested { Verb::Cancel } else { Verb::Status };
    let view = match pending.call(core, verb, None).await {
        Ok(view) => view,
        Err(reason) => return unavailable(w, &pending, reason),
    };
    let startable = unadmitted(&view) || (!pending.dispatched && view.status == "missing");
    let should_start = pending.status.status == "queued" && !pending.status.cancel_requested && startable;
    if should_start {
        let recorded = {
            let mut db = w.history.db()?;
            let Some(authority) = w.fleet_policy.as_ref().ok().and_then(Option::as_ref) else {
                drop(db);
                return update(w, &pending, "queued", Some("placement_changed"));
            };
            let reason = authority.with_worker_policy(|_, _, policy, _| {
                let project = projects::one(&db, pending.input.project).ok().flatten();
                if project.and_then(|project| projects::fixture_placement(&project, policy, &pending.input))
                    .as_ref() != Some(&pending.placement)
                {
                    return Some("placement_changed");
                }
                match crate::job_reviews::fix_dispatch_allowed(
                    &db, id, pending.input.project, &pending.status.owner_bot_id, policy,
                ) {
                    Ok(true) => None,
                    _ => Some("review_exception_inactive"),
                }
            }).unwrap_or(Some("placement_changed"));
            if let Some(reason) = reason {
                drop(db);
                return update(w, &pending, "queued", Some(reason));
            }
            record_dispatch(&mut db, id, number, &pending.placement.host_id, &pending.ticket.manifest_digest)?
        };
        if recorded != Dispatch::Recorded {
            return Ok(());
        }
        pending.dispatched = true;
        pending.status.status = "dispatching".into();
        let view = match pending.call(core, Verb::Start, None).await {
            Ok(view) => view,
            Err(reason) => return unavailable(w, &pending, reason),
        };
        return apply(w, &pending, core, view).await;
    }
    if !pending.dispatched {
        // A restored journal may lag the worker. Adopt its matching immutable
        // intent before applying the observed state.
        let mut db = w.history.db()?;
        record_dispatch(&mut db, id, number, &pending.placement.host_id, &pending.ticket.manifest_digest)?;
        pending.dispatched = true;
        pending.status.status = "dispatching".into();
    }
    if view.status == "missing" && pending.dispatched && !pending.status.cancel_requested {
        let fenced = match pending.call(core, Verb::FenceMissing, None).await {
            Ok(view) => view,
            Err(reason) => return unavailable(w, &pending, reason),
        };
        return apply(w, &pending, core, fenced).await;
    }
    apply(w, &pending, core, view).await
}

fn unadmitted(view: &WorkerView) -> bool {
    matches!(view.status.as_str(), "queued" | "held") || (view.status == "stopped" && view.runtime.is_none())
}

async fn apply(w: &Workspace, pending: &Pending, core: &Core, view: WorkerView) -> Result<(), Error> {
    match view.status.as_str() {
        "missing" => unavailable(w, pending, "unknown_attempt"),
        "unknown" => update(w, pending, "unknown", safe_reason(&view)),
        "dispatching" | "running" => update(w, pending, &view.status, None),
        _ if unadmitted(&view) => update(w, pending, "queued", safe_reason(&view)),
        "exited" | "cancelled" | "interrupted" | "stopped" => {
            let collected = match pending.call(core, Verb::Collect, None).await {
                Ok(collected) if collected.status == view.status => collected,
                Ok(_) => return unavailable(w, pending, "worker_receipt_changed"),
                Err(reason) => return unavailable(w, pending, reason),
            };
            let Some((report, review)) = report(pending, &collected) else {
                return unavailable(w, pending, "worker_receipt_invalid");
            };
            settle(w, pending, &report, safe_reason(&collected), review)
        }
        _ => unavailable(w, pending, "worker_incompatible"),
    }
}

fn safe_reason(view: &WorkerView) -> Option<&str> {
    view.reason.as_deref().filter(|reason| identifier(reason, 64))
}

fn unavailable(w: &Workspace, pending: &Pending, reason: &str) -> Result<(), Error> {
    let status = if pending.dispatched { "unknown" } else { "queued" };
    update(w, pending, status, Some(reason))
}

fn update(w: &Workspace, pending: &Pending, status: &str, reason: Option<&str>) -> Result<(), Error> {
    w.history.db()?.execute(
        "UPDATE job_attempts SET status=?3,
           exit_reason=CASE WHEN ?3='unknown' THEN
             CASE WHEN status='running' OR exit_reason='exit_unconfirmed' THEN 'exit_unconfirmed' ELSE 'start_unconfirmed' END
             END,
           requested_runtime=json_set(requested_runtime,'$.worker_reason',?4)
         WHERE job_id=?1 AND attempt=?2 AND status=?5 AND status IN ('queued','dispatching','running','unknown')
           AND (host_id IS NOT NULL)=?6",
        params![pending.status.id, pending.status.attempt, status, reason, pending.status.status, pending.dispatched],
    )?;
    Ok(())
}

fn report(pending: &Pending, view: &WorkerView) -> Option<(Report, bool)> {
    let exit = match view.status.as_str() {
        "exited" if view.exit_signal.is_none() => Exit::Exited(view.exit_code?),
        "cancelled" => Exit::Cancelled,
        "interrupted" | "stopped" => Exit::Interrupted,
        _ => return None,
    };
    let result = match (&view.result_ref, &view.result_digest) {
        (Some(reference), Some(digest)) if reference == "result" =>
            Some(Artifact { reference: reference.clone(), digest: digest.clone() }),
        (None, None) => None,
        _ => return None,
    };
    let verdict = match exit {
        Exit::Exited(0) if result.is_some() => "succeeded",
        Exit::Exited(_) => "failed",
        Exit::Cancelled => "cancelled",
        Exit::Interrupted => "interrupted",
    };
    if view.log_ref.as_deref().is_some_and(|reference| reference != "log")
        || (!matches!(exit, Exit::Exited(0)) && result.is_some())
    {
        return None;
    }
    let (observed_runtime, observed_cli_version, review) = match &view.runtime {
        Some(runtime) => {
            if runtime.provider != Some(pending.placement.provider)
                || runtime.account_ref.as_deref() != Some(&pending.placement.account_ref)
                || runtime.result_digest != view.result_digest
                || runtime.requested_model != pending.input.model
                || runtime.requested_effort != pending.input.effort
                || runtime.profile.as_deref() != Some(&pending.placement.profile)
                || runtime.verdict.as_deref() != Some(verdict)
            {
                return None;
            }
            let review = runtime.review_eligible == Some(true) && result.is_some() && matches!(exit, Exit::Exited(0))
                && runtime.observed_family.is_some() && runtime.observed_model.is_some() && runtime.cli_version.is_some();
            (Some(Runtime {
                provider: provider_name(pending.placement.provider).into(),
                account_ref: runtime.account_ref.clone(),
                model: runtime.observed_model.clone(),
                family: runtime.observed_family.clone(),
                effort: runtime.observed_effort.clone(),
            }), runtime.cli_version.clone(), review)
        }
        None if !matches!(exit, Exit::Exited(_)) && result.is_none() => (None, None, false),
        None => return None,
    };
    let report = Report { exit, observed_runtime, observed_cli_version, log_ref: view.log_ref.clone(), result };
    report.outcome().ok()?;
    Some((report, review))
}

fn settle(w: &Workspace, pending: &Pending, report: &Report, reason: Option<&str>, review: bool) -> Result<(), Error> {
    let mut db = w.history.db()?;
    finish_inner(&mut db, &pending.status.id, pending.status.attempt, report,
        Some(FinishEvidence { worker_reason: reason, review_eligible: review }), || {})?;
    bots::desk::kick();
    Ok(())
}

async fn result(w: &Workspace, owner: &str, id: &str, reference: &str) -> Result<String, String> {
    let (pending, artifact) = {
        let db = w.history.db().map_err(|_| STORAGE)?;
        let job = owned(&db, owner, id)?;
        let artifact = job.completion.and_then(|event| event.exit.result)
            .filter(|artifact| artifact.reference == reference)
            .ok_or("No result with that reference belongs to this job.")?;
        let pending = Pending::load(&db, id, job.attempt).map_err(|_| STORAGE)?.ok_or(NO_JOB)?;
        (pending, artifact)
    };
    let core = pending.core(w).await.map_err(str::to_owned)?;
    let view = pending.call(core, Verb::Result, Some(&artifact.digest)).await.map_err(str::to_owned)?;
    view.result.filter(|result| result.len() <= 4096 && !result.contains('\0')
        && format!("{:x}", Sha256::digest(result.as_bytes())) == artifact.digest)
        .ok_or_else(|| "The worker could not verify that result.".into())
}
