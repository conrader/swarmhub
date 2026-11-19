//! A managed job's verified result binds review evidence to its completed attempt.
use crate::{
    Workspace, history, jobs,
    fleet_policy::{Authority, Policy, PolicyRef, ReviewPermission, Rule, principals},
    parks::{self, Manifest, STAGING_ACTION},
    projects,
    runtimes::{self, ModelAgent},
};
use axum::{Json, Router, extract::State, routing::post};
use rusqlite::{Connection, OptionalExtension, Transaction, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

const AUTOMATIC_ROUNDS: i64 = 2;
const FIX_KEY_PREFIX: &str = "review-fix:";
const STORAGE: &str = "The workspace could not use its review journal.";
type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

#[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "verb", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Command {
    Record { job: String, attempt: i64, artifact: String, same_provider_exception: Option<String> },
    Fix { lineage: String, after_round: i64, input: jobs::Submit, exception: Option<String> },
    Status { lineage: String },
    Abandon { lineage: String, reason: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Revisions {
    code: String,
    apply: String,
    reverse: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Tests {
    reference: String,
    digest: String,
    passed: u32,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Severity { P0, P1, P2, P3 }

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Finding {
    severity: Severity,
    summary: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Verdict { Pass, Concerns, Changes }

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "role", rename_all = "snake_case", deny_unknown_fields)]
enum Artifact {
    Author { revisions: Revisions, tests: Tests },
    Fixer { lineage: String, round: i64, revisions: Revisions, tests: Tests },
    Reviewer {
        lineage: String, round: i64, producer_digest: String, revisions: Revisions,
        tests: Tests, verdict: Verdict, findings: Vec<Finding>,
    },
}

impl Artifact {
    fn role(&self) -> &'static str {
        match self {
            Self::Author { .. } => "author",
            Self::Fixer { .. } => "fixer",
            Self::Reviewer { .. } => "reviewer",
        }
    }

    fn pins(&self) -> (&Revisions, &Tests) {
        match self {
            Self::Author { revisions, tests }
            | Self::Fixer { revisions, tests, .. }
            | Self::Reviewer { revisions, tests, .. } => (revisions, tests),
        }
    }

    fn valid(&self) -> bool {
        let (pins, tests) = self.pins();
        let text = |s: &str| !s.trim().is_empty() && s.len() <= 512 && !s.chars().any(char::is_control);
        [40, 64].contains(&pins.code.len()) && principals::hex(&pins.code, pins.code.len())
            && text(&pins.apply) && text(&pins.reverse)
            && principals::identifier(&tests.reference) && principals::hex(&tests.digest, 64)
            && tests.passed > 0
            && match self {
                Self::Author { .. } => true,
                Self::Fixer { lineage, round, .. } => principals::identifier(lineage) && *round > 0,
                Self::Reviewer { lineage, round, producer_digest, verdict, findings, .. } => {
                    principals::identifier(lineage) && *round >= 0 && principals::hex(producer_digest, 64)
                        && findings.len() <= 32 && findings.iter().all(|finding| text(&finding.summary))
                        && (*verdict == Verdict::Pass) == findings.is_empty()
                }
            }
    }
}

#[derive(Debug, Eq, PartialEq)]
struct Identity<'a> {
    provider: &'a str,
    family: &'a str,
}

impl<'a> Identity<'a> {
    fn observed(runtime: &'a jobs::Runtime) -> Option<Self> {
        let provider = runtime.provider.as_str();
        let agent = match provider {
            "claude" => ModelAgent::Claude,
            "codex" => ModelAgent::Codex,
            _ => return None,
        };
        let model = runtime.model.as_deref()?;
        let family = runtime.family.as_deref()?;
        (runtimes::observed_provider_family(agent, model) == Some(family))
            .then_some(Self { provider, family })
    }

    fn independent_of(&self, producer: &Self, same_provider_granted: bool) -> bool {
        self.family != producer.family && (self.provider != producer.provider || same_provider_granted)
    }
}

#[derive(Clone, Debug, Deserialize, PartialEq, Eq, Serialize)]
struct Exception {
    id: String,
    decision_ref: String,
    effective_ms: i64,
    expires_ms: i64,
}

impl From<&Rule> for Exception {
    fn from(rule: &Rule) -> Self {
        Self { id: rule.id.clone(), decision_ref: rule.decision_ref.clone(),
            effective_ms: rule.effective_ms, expires_ms: rule.expires_ms }
    }
}

struct Scope<'a> {
    lineage: &'a str,
    owner: &'a str,
    project: i64,
}

impl Scope<'_> {
    fn exception(&self, policy: &Policy, id: &str, permission: ReviewPermission, now: i64) -> Option<Exception> {
        policy.review_exception(id, self.lineage, &self.project.to_string(), self.owner, permission, now)
            .map(Exception::from)
    }
}

struct PolicyContext<'a> {
    workspace: &'a str,
    policy: &'a Policy,
    reference: &'a PolicyRef,
    now: i64,
}

#[derive(Serialize)]
struct Round {
    round: i64,
    producer_job: String,
    exception: Option<Exception>,
}

fn from_json<T: serde::de::DeserializeOwned>(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<T> {
    serde_json::from_str(&row.get::<_, String>(index)?)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(index, rusqlite::types::Type::Text, Box::new(error)))
}

fn latest(db: &Connection, scope: &Scope<'_>) -> rusqlite::Result<Option<Round>> {
    db.query_row(
        "SELECT r.round,r.producer_job,COALESCE(r.exception,'null')
         FROM job_review_rounds r JOIN job_review_lineages l ON l.id=r.lineage
         WHERE l.id=?1 AND l.owner_bot_id=?2 AND l.project=?3 AND l.action=?4
         ORDER BY r.round DESC LIMIT 1",
        params![scope.lineage, scope.owner, scope.project, STAGING_ACTION],
        |row| Ok(Round { round: row.get(0)?, producer_job: row.get(1)?, exception: from_json(row, 2)? }),
    ).optional()
}

#[derive(Serialize)]
struct Evidence {
    runtime: jobs::Runtime,
    artifact: Artifact,
    digest: String,
    exception: Option<Exception>,
    job: String,
    attempt: i64,
}

fn evidence(db: &Connection, lineage: &str, round: i64, role: &str) -> rusqlite::Result<Option<Evidence>> {
    db.query_row(
        "SELECT runtime,artifact,digest,COALESCE(exception,'null'),job_id,attempt
         FROM job_review_evidence WHERE lineage=?1 AND round=?2 AND role=?3",
        params![lineage, round, role], |row| Ok(Evidence {
            runtime: from_json(row, 0)?, artifact: from_json(row, 1)?, digest: row.get(2)?,
            exception: from_json(row, 3)?, job: row.get(4)?, attempt: row.get(5)?,
        }),
    ).optional()
}

fn producer(db: &Connection, lineage: &str, round: i64) -> rusqlite::Result<Option<Evidence>> {
    evidence(db, lineage, round, if round == 0 { "author" } else { "fixer" })
}

fn add_round(
    tx: &Transaction<'_>, lineage: &str, round: i64, job: &str,
    ctx: &PolicyContext<'_>, exception: Option<&Exception>,
) -> Result<()> {
    tx.execute(
        "INSERT INTO job_review_rounds(lineage,round,producer_job,workspace,generation,exception)
         VALUES (?1,?2,?3,?4,?5,?6)",
        params![lineage, round, job, ctx.workspace, ctx.reference.generation,
            exception.map(serde_json::to_string).transpose()?],
    )?;
    Ok(())
}

// The staging adapter enrolls one target per managed project. Each owner
// keeps one active lineage on that target across edits to the reviewed pins.
const VERIFIED_LINEAGE: &str = "EXISTS (
    SELECT 1 FROM parks p WHERE p.state='verified'
      AND json_type(p.manifest,'$.operation.AdvanceStagingRef')='object'
      AND json_extract(p.manifest,'$.review_ref')=l.id
      AND json_extract(p.manifest,'$.owner')=l.owner_bot_id
      AND json_extract(p.manifest,'$.project')=CAST(l.project AS TEXT))";

const ABANDONED_LINEAGE: &str = "EXISTS (
    SELECT 1 FROM job_review_closures c WHERE c.lineage=l.id)";

fn active_lineage(db: &Connection, owner: &str, project: i64) -> rusqlite::Result<bool> {
    let query = format!("SELECT EXISTS(SELECT 1 FROM job_review_lineages l
        WHERE l.owner_bot_id=?1 AND l.project=?2 AND l.action=?3
          AND NOT {VERIFIED_LINEAGE} AND NOT {ABANDONED_LINEAGE})");
    db.query_row(&query, params![owner, project, STAGING_ACTION], |row| row.get(0))
}

fn closed(db: &Connection, scope: &Scope<'_>, include_verified: bool) -> rusqlite::Result<bool> {
    let query = format!("SELECT EXISTS(SELECT 1 FROM job_review_lineages l
        WHERE l.id=?1 AND l.owner_bot_id=?2 AND l.project=?3 AND l.action=?4
          AND ({ABANDONED_LINEAGE} OR (?5 AND {VERIFIED_LINEAGE})))");
    db.query_row(&query, params![scope.lineage, scope.owner, scope.project, STAGING_ACTION, include_verified], |row| row.get(0))
}

fn abandon(
    tx: &Transaction<'_>, owner: &str, launch: &str, lineage: &str, reason: &str,
    operator_decision: Option<&principals::Signed>,
) -> Result<()> {
    let reason = reason.trim();
    if reason.is_empty() || reason.len() > 512 || reason.chars().any(char::is_control) {
        return Err("Give a one-line reason for abandoning the review lineage.".into());
    }
    let project = lineage_project(tx, owner, lineage)?;
    let scope = Scope { lineage, owner, project };
    let prior = closure(tx, lineage)?;
    if let Some((prior_reason, _)) = prior {
        return if prior_reason == reason { Ok(()) } else { Err("This review lineage is already closed.".into()) };
    }
    let blocked: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM parks p WHERE p.state IN ('executing','reconciliation')
          AND json_type(p.manifest,'$.operation.AdvanceStagingRef')='object'
          AND json_extract(p.manifest,'$.review_ref')=?1
          AND json_extract(p.manifest,'$.owner')=?2
          AND json_extract(p.manifest,'$.project')=?3)",
        params![lineage, owner, project.to_string()], |row| row.get(0),
    )?;
    if blocked || closed(tx, &scope, true)? {
        return Err("A verified or unsettled execution prevents abandoning this lineage.".into());
    }
    let proof = operator_decision.map(serde_json::to_string).transpose()?;
    tx.execute(
        "INSERT INTO job_review_closures(lineage,owner_bot_id,launch,reason,closed_ms,operator_decision)
         VALUES(?1,?2,?3,?4,?5,?6)",
        params![lineage, owner, launch, reason, history::now(), proof],
    )?;
    Ok(())
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route("/api/job-reviews/abandon", post(abandon_by_operator))
}

async fn abandon_by_operator(
    State(w): State<Workspace>, Json(signed): Json<principals::Signed>,
) -> std::result::Result<Json<serde_json::Value>, parks::Error> {
    tokio::task::spawn_blocking(move || {
        let authority = w.fleet_policy.as_ref().map_err(Clone::clone)?.as_ref()
            .ok_or(crate::fleet_policy::Error::Unavailable)?;
        let mut db = history::connection(w.history.file())?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let result = authority.with_review_closure(&tx, &signed, |lineage, reason| {
            let owner: String = tx.query_row("SELECT owner_bot_id FROM job_review_lineages WHERE id=?1",
                [lineage], |row| row.get(0)).optional()?.ok_or(parks::Error::Missing)?;
            abandon(&tx, &owner, "operator", lineage, reason, Some(&signed)).map_err(|_| parks::Error::Conflict)?;
            Ok(serde_json::json!({ "status": "abandoned", "lineage": lineage }))
        })?;
        tx.commit()?;
        Ok(Json(result))
    }).await.map_err(|_| parks::Error::Store(history::StoreError))?
}

fn closure(db: &Connection, lineage: &str) -> rusqlite::Result<Option<(String, i64)>> {
    db.query_row("SELECT reason,closed_ms FROM job_review_closures WHERE lineage=?1", [lineage],
        |row| Ok((row.get(0)?, row.get(1)?))).optional()
}

fn record(
    tx: &Transaction<'_>, owner: &str, job: &str, attempt: i64, raw: &str, grant: Option<&str>,
    ctx: &PolicyContext<'_>,
) -> Result<()> {
    const RESULT: &str = "Use the exact successful, identity-verified managed job result.";
    if raw.len() > 4096 || !principals::identifier(job) || attempt <= 0 {
        return Err(RESULT.into());
    }
    let status = jobs::read_status(tx, job, Some(attempt))?.filter(|status| {
        status.owner_bot_id == owner && status.review_eligible == Some(true)
            && status.host_id.is_some() && status.observed_cli_version.is_some()
    }).ok_or(RESULT)?;
    let digest = format!("{:x}", Sha256::digest(raw.as_bytes()));
    let completion = status.completion.as_ref().filter(|event| {
        event.exit.code == Some(0) && event.exit.verdict == "succeeded"
            && event.exit.result.as_ref().is_some_and(|result| result.digest == digest)
    }).ok_or(RESULT)?;
    let runtime = status.observed_runtime.as_ref().ok_or(RESULT)?;
    let identity = Identity::observed(runtime).ok_or(RESULT)?;
    let artifact: Artifact = serde_json::from_str(raw).map_err(|_| "Use a typed review evidence result.")?;
    if !artifact.valid() {
        return Err("Evidence needs complete revision pins, passing tests and a consistent verdict.".into());
    }
    let (lineage, round) = match &artifact {
        Artifact::Author { .. } => (job, 0),
        Artifact::Fixer { lineage, round, .. } | Artifact::Reviewer { lineage, round, .. } => (lineage.as_str(), *round),
    };
    if let Some(saved) = evidence(tx, lineage, round, artifact.role())? {
        if saved.job == job && saved.attempt == attempt && saved.digest == digest
            && saved.exception.as_ref().map(|exception| exception.id.as_str()) == grant
        {
            return Ok(());
        }
        return Err("This role already has evidence for the round.".into());
    }
    let scope = Scope { lineage, owner, project: status.project };
    let exception = if let Artifact::Author { .. } = &artifact {
        if grant.is_some() {
            return Err("A review exception belongs to a reviewer result.".into());
        }
        if active_lineage(tx, owner, status.project)? {
            return Err("An unresolved author lineage already owns the project staging target.".into());
        }
        tx.execute("INSERT INTO job_review_lineages VALUES (?1,?2,?3,?4)",
            params![lineage, owner, status.project, STAGING_ACTION])?;
        add_round(tx, lineage, 0, job, ctx, None)?;
        None
    } else {
        if closed(tx, &scope, true)? {
            return Err("This review lineage is closed.".into());
        }
        let active = latest(tx, &scope)?.filter(|current| current.round == round)
            .ok_or("This result does not belong to the active round.")?;
        match &artifact {
            Artifact::Fixer { .. } if active.producer_job == job && grant.is_none() => None,
            Artifact::Reviewer { revisions, producer_digest, .. } => {
                let author = producer(tx, lineage, 0)?.ok_or(RESULT)?;
                let current = producer(tx, lineage, round)?.ok_or("Record the fix result first.")?;
                let producer_exit = jobs::read_status(tx, &current.job, Some(current.attempt))?
                    .and_then(|status| status.completion).ok_or(RESULT)?;
                if producer_digest != &current.digest || revisions != current.artifact.pins().0
                    || completion.created_ms < producer_exit.created_ms
                {
                    return Err("The review must bind the current producer result and all three revision pins.".into());
                }
                let exception = grant.map(|id| scope.exception(ctx.policy, id, ReviewPermission::SameProvider, ctx.now)
                    .ok_or("The named same-provider exception is inactive or out of scope.")).transpose()?;
                for prior in [&author, &current] {
                    let producer = Identity::observed(&prior.runtime).ok_or(RESULT)?;
                    if !identity.independent_of(&producer, exception.is_some()) {
                        return Err("Review requires a different observed model family from the author and fixer.".into());
                    }
                }
                exception
            }
            _ => return Err("The fix result must come from the job reserved for this round.".into()),
        }
    };
    tx.execute(
        "INSERT INTO job_review_evidence(lineage,round,role,job_id,attempt,runtime,artifact,digest,workspace,generation,exception)
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
        params![lineage, round, artifact.role(), job, attempt, serde_json::to_string(runtime)?, raw, digest,
            ctx.workspace, ctx.reference.generation, exception.as_ref().map(serde_json::to_string).transpose()?],
    )?;
    Ok(())
}

fn fix(
    tx: &Transaction<'_>, scope: &Scope<'_>, after_round: i64, grant: Option<&str>,
    ctx: &PolicyContext<'_>, queue: impl FnOnce(&Transaction<'_>, &str, Option<&str>) -> Result<jobs::Job>,
) -> Result<serde_json::Value> {
    let current = latest(tx, scope)?.ok_or("No review lineage belongs to this owner and project.")?;
    if closed(tx, scope, true)? {
        return Err("This review lineage is closed.".into());
    }
    let next = after_round.checked_add(1).filter(|next| *next > 0).ok_or("Invalid fix round.")?;
    let key = format!("{FIX_KEY_PREFIX}{}:{next}", scope.lineage);
    if current.round == next && current.exception.as_ref().map(|exception| exception.id.as_str()) == grant {
        let job = queue(tx, &key, Some(&current.producer_job))?;
        return Ok(serde_json::json!({ "status": "queued", "round": next, "job": job }));
    }
    if current.round != after_round {
        return Err("The requested fix does not follow the current round.".into());
    }
    let review = evidence(tx, scope.lineage, current.round, "reviewer")?
        .ok_or("Record the independent review before requesting a fix.")?;
    if let Some(saved) = review.exception
        && scope.exception(ctx.policy, &saved.id, ReviewPermission::SameProvider, ctx.now).as_ref() != Some(&saved)
    {
        return Err("The review exception is no longer active.".into());
    }
    if matches!(review.artifact, Artifact::Reviewer { verdict: Verdict::Pass, .. }) {
        return Err("The current review has no findings to fix.".into());
    }
    let exception = if next > AUTOMATIC_ROUNDS {
        let Some(grant) = grant else {
            return Ok(serde_json::json!({ "status": "escalate", "round": current.round }));
        };
        Some(scope.exception(ctx.policy, grant, ReviewPermission::ExtraRound(next), ctx.now)
            .ok_or("The named extra-round exception is inactive or out of scope.")?)
    } else {
        if grant.is_some() {
            return Err("The automatic round does not use an exception.".into());
        }
        None
    };
    let applying: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM parks WHERE state='executing'
            AND json_extract(manifest,'$.review_ref')=?1
            AND json_extract(manifest,'$.owner')=?2 AND json_extract(manifest,'$.project')=?3
            AND json_type(manifest,'$.operation.AdvanceStagingRef')='object')",
        params![scope.lineage, scope.owner, scope.project.to_string()], |row| row.get(0),
    )?;
    if applying {
        return Err("A park is executing for this review lineage.".into());
    }
    let job = queue(tx, &key, None)?;
    add_round(tx, scope.lineage, next, &job.id, ctx, exception.as_ref())?;
    Ok(serde_json::json!({ "status": "queued", "round": next, "job": job }))
}

/// A claim records the accepted evidence. The same lineage is fenced against
/// new fix rounds until the executing claim is settled.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub(crate) struct Accepted {
    lineage: String,
    round: i64,
    author: String,
    producer: String,
    review: String,
    exceptions: Vec<Exception>,
}

fn verdict_permission(artifact: &Artifact, round: i64) -> Option<Option<ReviewPermission>> {
    match artifact {
        Artifact::Reviewer { verdict: Verdict::Pass, findings, .. } if findings.is_empty() => Some(None),
        Artifact::Reviewer { verdict: Verdict::Concerns, findings, .. }
            if round >= AUTOMATIC_ROUNDS && !findings.is_empty()
                && findings.iter().all(|finding| finding.severity == Severity::P2) =>
            Some(Some(ReviewPermission::ResidualP2)),
        _ => None,
    }
}

pub(crate) fn accepted(
    db: &Connection, manifest: &Manifest, policy: &Policy, now: i64,
) -> rusqlite::Result<Option<Accepted>> {
    let Ok(project) = manifest.project.parse::<i64>() else { return Ok(None) };
    if project.to_string() != manifest.project || manifest.operation.action() != STAGING_ACTION {
        return Ok(None);
    }
    let scope = Scope { lineage: &manifest.review_ref, owner: &manifest.owner, project };
    if closed(db, &scope, false)? { return Ok(None) }
    let Some(current) = latest(db, &scope)? else { return Ok(None) };
    let Some(author) = producer(db, scope.lineage, 0)? else { return Ok(None) };
    let Some(producer) = producer(db, scope.lineage, current.round)? else { return Ok(None) };
    let Some(review) = evidence(db, scope.lineage, current.round, "reviewer")? else { return Ok(None) };
    let (revision, tests) = producer.artifact.pins();
    if revision.code != manifest.expected_postcondition || revision.code != manifest.artifact_pin
        || revision.apply != manifest.apply_pin || revision.reverse != manifest.reverse_pin
        || tests.digest != manifest.dry_run_ref
        || !matches!(&review.artifact, Artifact::Reviewer { revisions, producer_digest, .. }
            if revisions == revision && producer_digest == &producer.digest)
    {
        return Ok(None);
    }
    let Some(mut exceptions) = extra_rounds(db, &scope, current.round, policy, now)? else {
        return Ok(None);
    };
    if let Some(saved) = review.exception {
        if scope.exception(policy, &saved.id, ReviewPermission::SameProvider, now).as_ref() != Some(&saved) {
            return Ok(None);
        }
        exceptions.push(saved);
    }
    match verdict_permission(&review.artifact, current.round) {
        None => return Ok(None),
        Some(Some(permission)) => {
            let Some(exception) = policy.rules.iter()
                .filter_map(|rule| scope.exception(policy, &rule.id, permission, now))
                .min_by(|a, b| a.id.cmp(&b.id))
            else { return Ok(None) };
            exceptions.push(exception);
        }
        Some(None) => {}
    }
    Ok(Some(Accepted { lineage: scope.lineage.into(), round: current.round, author: author.digest,
        producer: producer.digest, review: review.digest, exceptions }))
}

fn extra_rounds(
    db: &Connection, scope: &Scope<'_>, through: i64, policy: &Policy, now: i64,
) -> rusqlite::Result<Option<Vec<Exception>>> {
    let mut exceptions = Vec::new();
    let mut extra = db.prepare(
        "SELECT round,exception FROM job_review_rounds WHERE lineage=?1 AND round>?2 AND round<=?3 ORDER BY round",
    )?;
    let rows = extra.query_map(params![scope.lineage, AUTOMATIC_ROUNDS, through],
        |row| Ok((row.get::<_, i64>(0)?, from_json::<Exception>(row, 1)?)))?;
    for row in rows {
        let (round, saved) = row?;
        if scope.exception(policy, &saved.id, ReviewPermission::ExtraRound(round), now).as_ref() != Some(&saved) {
            return Ok(None);
        }
        exceptions.push(saved);
    }
    Ok(Some(exceptions))
}

pub(crate) fn fix_dispatch_allowed(
    db: &Connection, job: &str, project: i64, owner: &str, policy: &Policy,
) -> rusqlite::Result<bool> {
    let bound = db.query_row(
        "SELECT r.lineage,r.round FROM jobs j JOIN job_review_rounds r ON r.producer_job=j.id
         WHERE j.id=?1 AND j.owner_bot_id=?2 AND j.project=?3 AND r.round>0",
        params![job, owner, project],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
    ).optional()?;
    let Some((lineage, round)) = bound else { return Ok(true) };
    let scope = Scope { lineage: &lineage, owner, project };
    Ok(!closed(db, &scope, true)?
        && (round <= AUTOMATIC_ROUNDS || extra_rounds(db, &scope, round, policy, history::now())?.is_some()))
}

/// Superseding a reviewed staging park keeps the same repair budget.
pub(crate) fn keeps_lineage(db: &Connection, old: &Manifest, new: &Manifest) -> rusqlite::Result<bool> {
    if old.operation.action() != STAGING_ACTION { return Ok(true) }
    let bound: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM job_review_lineages WHERE id=?1 AND owner_bot_id=?2 AND CAST(project AS TEXT)=?3
           AND NOT EXISTS(SELECT 1 FROM job_review_closures WHERE lineage=?1))",
        params![old.review_ref, old.owner, old.project], |row| row.get(0),
    )?;
    Ok(!bound || old.review_ref == new.review_ref)
}

pub(crate) fn reserved_key(key: &str) -> bool {
    key.starts_with(FIX_KEY_PREFIX)
}

pub(crate) async fn answer(w: &Workspace, core: &str, launch: &str, command: Command) -> std::result::Result<String, String> {
    let owner = jobs::current_owner(w, core, launch, false).await?;
    let (w, core, launch) = (w.clone(), core.to_owned(), launch.to_owned());
    tokio::task::spawn_blocking(move || answer_verified(&w, &core, &launch, &owner, command))
        .await.map_err(|_| STORAGE.to_owned())?
}

fn answer_verified(
    w: &Workspace, core: &str, launch: &str, owner: &str, command: Command,
) -> std::result::Result<String, String> {
    let mut db = history::connection(w.history.file()).map_err(|_| STORAGE)?;
    match &command {
        Command::Status { lineage } => return inspect(&db, owner, lineage).map_err(|error| error.to_string()),
        Command::Abandon { lineage, reason } => {
            let mut close = || -> Result<String> {
                let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
                if !crate::helpers::policy::job_owner(&tx, core, launch, false)?.is_some_and(|bot| bot.id == owner) {
                    return Err("Use the current registered owner session.".into());
                }
                abandon(&tx, owner, launch, lineage, reason, None)?;
                tx.commit()?;
                Ok(serde_json::json!({ "status": "abandoned", "lineage": lineage }).to_string())
            };
            return close().map_err(|error| error.to_string());
        }
        _ => {}
    }
    let authority: &Authority = w.fleet_policy.as_ref().ok().and_then(Option::as_ref)
        .ok_or("The protected review policy is unavailable.")?;
    let result = authority.with_audited_policy(&mut db, |tx, workspace, policy, reference| {
        if !crate::helpers::policy::job_owner(tx, core, launch, false)?.is_some_and(|bot| bot.id == owner) {
            return Err("Use the current registered owner session.".into());
        }
        let ctx = PolicyContext { workspace, policy, reference, now: history::now() };
        match command {
            Command::Record { job, attempt, artifact, same_provider_exception } => {
                record(tx, owner, &job, attempt, &artifact, same_provider_exception.as_deref(), &ctx)?;
                Ok(serde_json::json!({ "status": "recorded" }))
            }
            Command::Fix { lineage, after_round, input, exception } => {
                if !projects::can_use(tx, launch, input.project)? {
                    return Err("This session has no grant for the selected project.".into());
                }
                let scope = Scope { lineage: &lineage, owner, project: input.project };
                fix(tx, &scope, after_round, exception.as_deref(), &ctx, |tx, key, reserved_job| {
                    jobs::queue_review_fix(tx, owner, key, &input, policy, reserved_job).map_err(Into::into)
                })
            }
            Command::Status { .. } | Command::Abandon { .. } => unreachable!(),
        }
    }).map_err(|error| error.to_string())?;
    jobs::wake();
    Ok(result.to_string())
}

fn lineage_project(db: &Connection, owner: &str, lineage: &str) -> Result<i64> {
    Ok(db.query_row(
        "SELECT project FROM job_review_lineages WHERE id=?1 AND owner_bot_id=?2",
        params![lineage, owner], |row| row.get(0),
    ).optional()?.ok_or("No review lineage belongs to this owner.")?)
}

fn inspect(db: &Connection, owner: &str, lineage: &str) -> Result<String> {
    let project = lineage_project(db, owner, lineage)?;
    let scope = Scope { lineage, owner, project };
    let round = latest(db, &scope)?.ok_or(STORAGE)?;
    let producer = producer(db, lineage, round.round)?;
    let review = evidence(db, lineage, round.round, "reviewer")?;
    let closure = closure(db, lineage)?.map(|(reason, at_ms)| serde_json::json!({ "reason": reason, "at_ms": at_ms }));
    Ok(serde_json::json!({ "lineage": lineage, "project": project, "round": round, "closure": closure,
        "producer": producer, "review": review, "automatic_fix_limit": AUTOMATIC_ROUNDS }).to_string())
}

#[cfg(test)]
mod tests;
