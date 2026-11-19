//! A managed job's verified result binds review evidence to its completed attempt.
use crate::{
    Workspace, history, jobs,
    fleet_policy::{Authority, Policy, PolicyRef, ReviewPermission, Rule, principals},
    parks::{Manifest, STAGING_ACTION},
    projects,
    runtimes::{self, ModelAgent},
};
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

// The staging adapter enrolls one target per managed project. An unresolved
// lineage owns that target even if its author, commit or park changes.
const VERIFIED_LINEAGE: &str = "EXISTS (
    SELECT 1 FROM parks p WHERE p.state='verified'
      AND json_type(p.manifest,'$.operation.AdvanceStagingRef')='object'
      AND json_extract(p.manifest,'$.review_ref')=l.id
      AND json_extract(p.manifest,'$.owner')=l.owner_bot_id
      AND json_extract(p.manifest,'$.project')=CAST(l.project AS TEXT))";

fn lineage_exists(db: &Connection, project: i64, closed: Option<&str>) -> rusqlite::Result<bool> {
    let query = format!(
        "SELECT EXISTS(SELECT 1 FROM job_review_lineages l WHERE l.project=?1 AND l.action=?2 AND
          ((?3 IS NULL AND NOT {VERIFIED_LINEAGE}) OR (l.id=?3 AND {VERIFIED_LINEAGE})))"
    );
    db.query_row(&query, params![project, STAGING_ACTION, closed], |row| row.get(0))
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
        if lineage_exists(tx, status.project, None)? {
            return Err("An unresolved author lineage already owns the project staging target.".into());
        }
        tx.execute("INSERT INTO job_review_lineages VALUES (?1,?2,?3,?4)",
            params![lineage, owner, status.project, STAGING_ACTION])?;
        add_round(tx, lineage, 0, job, ctx, None)?;
        None
    } else {
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
    let next = after_round.checked_add(1).filter(|next| *next > 0).ok_or("Invalid fix round.")?;
    let key = format!("{FIX_KEY_PREFIX}{}:{next}", scope.lineage);
    if current.round == next && current.exception.as_ref().map(|exception| exception.id.as_str()) == grant {
        let job = queue(tx, &key, Some(&current.producer_job))?;
        return Ok(serde_json::json!({ "status": "queued", "round": next, "job": job }));
    }
    if lineage_exists(tx, scope.project, Some(scope.lineage))? {
        return Err("The staging target already verified this review lineage.".into());
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
         WHERE j.id=?1 AND j.owner_bot_id=?2 AND j.project=?3 AND r.round>?4",
        params![job, owner, project, AUTOMATIC_ROUNDS],
        |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)),
    ).optional()?;
    let Some((lineage, round)) = bound else { return Ok(true) };
    let scope = Scope { lineage: &lineage, owner, project };
    Ok(extra_rounds(db, &scope, round, policy, history::now())?.is_some())
}

/// Superseding a reviewed staging park keeps the same repair budget.
pub(crate) fn keeps_lineage(db: &Connection, old: &Manifest, new: &Manifest) -> rusqlite::Result<bool> {
    let bound: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM job_review_lineages WHERE id=?1 AND owner_bot_id=?2 AND CAST(project AS TEXT)=?3)",
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
    if let Command::Status { lineage } = command {
        return inspect(&db, owner, &lineage).map_err(|error| error.to_string());
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
            Command::Status { .. } => unreachable!(),
        }
    }).map_err(|error| error.to_string())?;
    jobs::wake();
    Ok(result.to_string())
}

fn inspect(db: &Connection, owner: &str, lineage: &str) -> Result<String> {
    let project = db.query_row(
        "SELECT project FROM job_review_lineages WHERE id=?1 AND owner_bot_id=?2",
        params![lineage, owner], |row| row.get(0),
    ).optional()?.ok_or("No review lineage belongs to this owner.")?;
    let scope = Scope { lineage, owner, project };
    let round = latest(db, &scope)?.ok_or(STORAGE)?;
    let producer = producer(db, lineage, round.round)?;
    let review = evidence(db, lineage, round.round, "reviewer")?;
    Ok(serde_json::json!({ "lineage": lineage, "project": project, "round": round,
        "producer": producer, "review": review, "automatic_fix_limit": AUTOMATIC_ROUNDS }).to_string())
}

#[cfg(test)]
mod tests;
