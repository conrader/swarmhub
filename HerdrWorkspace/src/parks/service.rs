//! The authenticated bridge and bot desk share this service.

use super::*;
use crate::{
    Workspace, bots, job_reviews,
    fleet_policy::{
        self, Authority, Evidence, Verified,
        principals::{Actor, Purpose, Signed},
    },
};
use axum::{
    Json, Router,
    extract::{Path, State as AxumState},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde_json::json;
use std::sync::{Arc, Mutex};

#[derive(Clone, Default)]
pub(crate) struct Service {
    project: Option<staging_ref::Project>,
    unsettled: Arc<Mutex<Vec<Unsettled>>>,
    #[cfg(test)]
    legacy_fixture_review: bool,
    #[cfg(test)]
    pub(crate) after_claim: Option<std::sync::Arc<dyn Fn() + Send + Sync>>,
}

#[derive(Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Command {
    File { id: String, manifest: Box<Manifest> },
    Status { id: String },
    Judge { park: ParkRef, signed: Signed },
    Backstop { park: ParkRef, signed: Signed },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Submission {
    park: ParkRef,
    purpose: Purpose,
    evidence: OperatorEvidence,
    replacement: Option<Replacement>,
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum OperatorEvidence {
    Signed(Signed),
    Imported(String),
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Replacement {
    id: String,
    manifest: Manifest,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Class {
    ReviewedReversible,
    StagingNeedsReview,
    Money,
    Secrets,
    Delete,
    OutsideMessage,
    Unknown,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Signer {
    Operator,
    EnrolledDelegate,
}

#[derive(Serialize)]
struct Classification<'a> {
    class: Class,
    scope: Scope<'a>,
    destructive: Option<bool>,
    irreversible: Option<bool>,
    required_signers: &'static [Signer],
    escalation_target: Signer,
}

#[derive(Serialize)]
struct Scope<'a> {
    action: &'a str,
    project: &'a str,
    host: &'a str,
    owner: &'a str,
}

fn classify(manifest: &Manifest, reviewed: bool) -> Classification<'_> {
    use Class::*;
    let (class, destructive, irreversible) = match &manifest.operation {
        Operation::AdvanceStagingRef { .. } if reviewed => (ReviewedReversible, Some(false), Some(false)),
        Operation::AdvanceStagingRef { .. } => (StagingNeedsReview, Some(false), Some(false)),
        Operation::SpendMoney => (Money, Some(false), Some(true)),
        Operation::UseSecret => (Secrets, Some(false), Some(true)),
        Operation::Delete => (Delete, Some(true), Some(true)),
        Operation::OutsideMessage => (OutsideMessage, Some(false), Some(true)),
        Operation::Unknown { .. } | Operation::SetRevisionMarker { .. } => (Unknown, None, None),
    };
    let (required_signers, escalation_target) = if class == ReviewedReversible {
        (&[Signer::EnrolledDelegate, Signer::Operator][..], Signer::EnrolledDelegate)
    } else {
        (&[Signer::Operator][..], Signer::Operator)
    };
    Classification {
        class,
        scope: Scope {
            action: manifest.operation.action(),
            project: &manifest.project,
            host: &manifest.host,
            owner: &manifest.owner,
        },
        destructive,
        irreversible,
        required_signers,
        escalation_target,
    }
}

#[derive(Serialize)]
struct PolicyVersion<'a> {
    workspace: &'a str,
    #[serde(flatten)]
    reference: &'a fleet_policy::PolicyRef,
}

#[derive(Serialize)]
struct Basis<'a> {
    decision: &'a str,
    nonce_digest: &'a str,
    rule: Option<&'a str>,
    decision_ref: Option<&'a str>,
    blocker: Option<Blocker>,
    #[serde(skip_serializing_if = "Option::is_none")]
    review: Option<&'a job_reviews::Accepted>,
}

#[derive(Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
enum DecisionResult {
    View { view: View },
    Held { reason: Blocker },
    Superseded { replacement: ParkRef },
}

impl From<View> for DecisionResult {
    fn from(view: View) -> Self {
        Self::View { view }
    }
}

struct Recorded {
    actor: String,
    source: Source,
    basis: String,
    audit: Audit,
}

impl Recorded {
    fn new(
        tx: &Transaction<'_>,
        verified: &Verified,
        purpose: Purpose,
        classification: &Classification<'_>,
        review: Option<&job_reviews::Accepted>,
    ) -> Result<Self, Error> {
        let (actor, source) = match &verified.actor {
            Actor::Operator => ("operator".to_owned(), Source::Human),
            Actor::Bot { id } if purpose == Purpose::AutoExecute => (id.clone(), Source::Backstop),
            Actor::Bot { id } => (id.clone(), Source::Judge),
        };
        let nonce_digest = digest(&encode(&(&verified.workspace, &verified.actor, &verified.nonce))?);
        let used: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM park_decisions
             WHERE json_extract(CASE WHEN json_valid(basis) THEN basis END,'$.nonce_digest')=?1)",
            [&nonce_digest],
            |row| row.get(0),
        )?;
        if used {
            return Err(fleet_policy::Error::Replay.into());
        }
        verified.audit(tx)?;
        let basis = encode(&Basis {
            decision: match purpose {
                Purpose::Execute => "execute",
                Purpose::AutoExecute => "auto_execute",
                Purpose::Hold => "hold",
                Purpose::Release => "release",
                Purpose::Deny => "deny",
                Purpose::Supersede => "supersede",
                Purpose::PublishPolicy => return Err(Error::InvalidDecision),
            },
            nonce_digest: &nonce_digest,
            rule: verified.rule_id.as_deref(),
            decision_ref: verified.decision_ref.as_deref(),
            blocker: None,
            review,
        })?;
        Ok(Self {
            actor,
            source,
            basis,
            audit: Audit {
                classifier_output: encode(classification)?,
                policy_version: encode(&PolicyVersion {
                    workspace: &verified.workspace,
                    reference: &verified.policy,
                })?,
            },
        })
    }

    fn decision(&self) -> Decision<'_> {
        Decision { actor: &self.actor, source: self.source, basis: &self.basis }
    }

    fn blocked(&mut self, reason: Blocker) -> Result<(), Error> {
        let mut basis: serde_json::Value = decode(&self.basis)?;
        basis["blocker"] = json!(reason);
        self.basis = encode(&basis)?;
        Ok(())
    }
}

struct Unsettled {
    park: ParkRef,
    attempt: String,
    basis: &'static str,
}

enum Reservation {
    Finished(DecisionResult),
    Claimed { attempt: String, recorded: Recorded, review: Option<job_reviews::Accepted> },
}

impl Service {
    #[cfg(test)]
    pub(crate) fn fixture(git_dir: &std::path::Path, reviewed: Manifest) -> Self {
        Self { project: Some(staging_ref::Project::fixture(git_dir, reviewed)), ..Self::default() }
    }

    #[cfg(test)]
    pub(crate) fn fixture_with_prevalidated_review(git_dir: &std::path::Path, reviewed: Manifest) -> Self {
        Self { legacy_fixture_review: true, ..Self::fixture(git_dir, reviewed) }
    }

    fn reviewed(&self, _manifest: &Manifest, review: Option<&job_reviews::Accepted>) -> bool {
        #[cfg(test)]
        if self.legacy_fixture_review {
            return self.project.as_ref().is_some_and(|project| project.reviewed(_manifest));
        }
        review.is_some()
    }

    fn file(
        &self,
        db: &mut Connection,
        launch: &str,
        id: &str,
        manifest: &Manifest,
    ) -> Result<ParkRef, Error> {
        if matches!(manifest.operation, Operation::SetRevisionMarker { .. }) {
            return Err(Error::InvalidManifest);
        }
        let pin = pin_for(id, manifest)?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if owner(&tx, launch)? != manifest.owner {
            return Err(fleet_policy::Error::Principal.into());
        }
        let park = ParkRef { id: pin.id, manifest_digest: pin.manifest_digest };
        match status(&tx, &park) {
            Ok(_) => return Ok(park),
            Err(Error::Missing) => {}
            Err(error) => return Err(error),
        }
        let park = insert_park(&tx, id, manifest, None)?;
        tx.commit()?;
        Ok(park)
    }

    fn decide(
        &self,
        db: &mut Connection,
        authority: &Authority,
        park: &ParkRef,
        purpose: Purpose,
        evidence: Evidence<'_>,
        replacement: Option<&Replacement>,
    ) -> Result<DecisionResult, Error> {
        let replacement_pin = match (purpose, replacement) {
            (Purpose::Supersede, Some(next))
                if valid_id(&next.id) && !matches!(next.manifest.operation, Operation::SetRevisionMarker { .. }) =>
            {
                Some(pin_for(&next.id, &next.manifest)?)
            }
            (Purpose::Supersede | Purpose::PublishPolicy, _) | (_, Some(_)) => return Err(Error::InvalidDecision),
            _ => None,
        };
        let execute = matches!(purpose, Purpose::Execute | Purpose::AutoExecute);
        // Retry reads the existing attempt or terminal state. The conditional
        // claim and the unique attempt row fence all callers before an effect.
        let Some(tx) = history::background_write(db)? else {
            return Ok(View::Busy.into());
        };
        let manifest = manifest_for(&tx, park)?;
        let reserved = authority.with_park_decision(&*tx, park, purpose, evidence,
            replacement_pin.as_ref(), |_, verified| {
                let tx = &tx;
                let view = status(tx, park)?;
                if execute && view != View::Status(State::Pending) {
                    return Ok(Reservation::Finished(view.into()));
                }
                let review = job_reviews::accepted(tx, &manifest, &verified.review_policy, history::now())?;
                let reviewed = self.reviewed(&manifest, review.as_ref());
                let classification = classify(&manifest, reviewed);
                let mut recorded = Recorded::new(tx, &verified, purpose, &classification, review.as_ref())?;
                if !execute {
                    let change = match (purpose, replacement) {
                        (Purpose::Hold, _) => Change::Hold,
                        (Purpose::Release, _) => Change::Release,
                        (Purpose::Deny, _) => Change::Deny,
                        (Purpose::Supersede, Some(next)) =>
                            Change::Supersede { id: &next.id, manifest: &next.manifest },
                        _ => return Err(Error::InvalidDecision),
                    };
                    let next = transition(tx, park, recorded.decision(), change, Some(&recorded.audit))?;
                    let result = match next {
                        Some(replacement) => DecisionResult::Superseded { replacement },
                        None => status(tx, park)?.into(),
                    };
                    return Ok(Reservation::Finished(result));
                }
                if matches!(verified.actor, Actor::Bot { .. })
                    && !matches!(classification.class, Class::ReviewedReversible | Class::StagingNeedsReview)
                {
                    return Err(fleet_policy::Error::HumanScope.into());
                }
                if let Err(reason) = self.check(&manifest, reviewed) {
                    recorded.blocked(reason)?;
                    transition(tx, park, recorded.decision(), Change::Hold, Some(&recorded.audit))?;
                    return Ok(Reservation::Finished(DecisionResult::Held { reason }));
                }
                let attempt = claim(tx, park, recorded.decision(), Some(&recorded.audit))?;
                Ok(Reservation::Claimed { attempt, recorded, review })
            })??;
        tx.commit()?;
        let (attempt, mut recorded, review) = match reserved {
            Reservation::Claimed { attempt, recorded, review } => (attempt, recorded, review),
            Reservation::Finished(result) => return Ok(result),
        };

        #[cfg(test)]
        if let Some(after_claim) = &self.after_claim {
            after_claim();
        }
        let effect = authority.with_park_decision(&mut *db, park, purpose, evidence, None, |db, verified| {
            let current = job_reviews::accepted(db, &manifest, &verified.review_policy, history::now())?;
            if current != review {
                return Err(Error::Blocked(Blocker::ReviewEvidence));
            }
            let adapter = self.check(&manifest, self.reviewed(&manifest, current.as_ref())).map_err(Error::Blocked)?;
            let reserved: bool = db.query_row(
                "SELECT EXISTS(SELECT 1 FROM parks p JOIN park_executions e ON e.park_id=p.id
                 WHERE p.id=?1 AND p.manifest_digest=?2 AND p.state='executing' AND e.attempt=?3
                 AND e.observed_before IS NULL AND e.receipt IS NULL)",
                params![park.id, park.manifest_digest, attempt],
                |row| row.get(0),
            )?;
            if !reserved {
                return Err(Error::Conflict);
            }
            run(db, park, &manifest, attempt.clone(), adapter)
        });
        // Return to held only when this reservation never reached the adapter.
        let reason = match effect {
            Ok(Err(Error::Blocked(reason))) => reason,
            Err(fleet_policy::Error::Busy) => Blocker::PolicyBusy,
            Err(fleet_policy::Error::Unavailable) => Blocker::PolicyUnavailable,
            Err(fleet_policy::Error::Audit) => Blocker::PolicyAuditUnavailable,
            Err(fleet_policy::Error::Invalid | fleet_policy::Error::Signature | fleet_policy::Error::Binding) => {
                Blocker::PolicyEvidenceInvalid
            }
            Err(_) => Blocker::AuthorizationChanged,
            Ok(Ok(view)) => return Ok(view.into()),
            Ok(Err(error)) => {
                eprintln!("SwarmHub park execution needs reconciliation: {error:?}");
                return self.quarantine(db, park, &attempt, "reconciliation: execution evidence could not be settled");
            }
        };
        let held = (|| {
            let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let discarded = tx.execute(
                "DELETE FROM park_executions WHERE park_id=?1 AND attempt=?2
                 AND observed_before IS NULL AND receipt IS NULL",
                params![park.id, attempt],
            )?;
            if discarded != 1 || tx.execute(
                "UPDATE parks SET state='held' WHERE id=?1 AND manifest_digest=?2 AND state='executing'",
                params![park.id, park.manifest_digest],
            )? != 1
            {
                return Err(Error::Conflict);
            }
            recorded.blocked(reason)?;
            record_decision(&tx, park, "hold", recorded.decision(), Some(&recorded.audit))?;
            tx.commit()?;
            Ok(DecisionResult::Held { reason })
        })();
        match held {
            Ok(result) => Ok(result),
            Err(error) => {
                eprintln!("SwarmHub park hold needs reconciliation: {error:?}");
                self.quarantine(db, park, &attempt, "reconciliation: pre-effect hold could not be recorded")
            }
        }
    }

    fn quarantine(
        &self, db: &mut Connection, park: &ParkRef, attempt: &str, basis: &'static str,
    ) -> Result<DecisionResult, Error> {
        let result = reconcile_claim(db, park, attempt, basis);
        if result.is_err() {
            self.unsettled.lock().unwrap_or_else(|error| error.into_inner()).push(Unsettled {
                park: park.clone(), attempt: attempt.into(), basis,
            });
        }
        result.map(Into::into)
    }

    pub(crate) async fn retry_reconciliation(&self, history: &crate::History) {
        if self.unsettled.lock().unwrap_or_else(|error| error.into_inner()).is_empty() {
            return;
        }
        let service = self.clone();
        let history = history.clone();
        let _ = tokio::task::spawn_blocking(move || {
            let Ok(db) = history::connection(history.file()) else { return };
            let mut pending = {
                let mut queue = service.unsettled.lock().unwrap_or_else(|error| error.into_inner());
                std::mem::take(&mut *queue)
            };
            pending.retain(|item| reconcile_claim(&db, &item.park, &item.attempt, item.basis).is_err());
            service.unsettled.lock().unwrap_or_else(|error| error.into_inner()).extend(pending);
        }).await;
    }

    fn check(&self, manifest: &Manifest, reviewed: bool) -> Result<&staging_ref::Project, Blocker> {
        if !matches!(manifest.operation, Operation::AdvanceStagingRef { .. }) {
            return Err(Blocker::HumanReview);
        }
        let project = self.project.as_ref().ok_or(Blocker::FixtureOnly)?;
        if project.check(manifest).is_err()
            || !project.observe().is_ok_and(|marker| marker.revision == manifest.precondition)
        {
            return Err(Blocker::Pins);
        }
        if !reviewed {
            return Err(Blocker::ReviewEvidence);
        }
        Ok(project)
    }

    fn describe(
        &self, db: &Connection, authority: &Result<Option<Authority>, fleet_policy::Error>, detail: Detail,
    ) -> Result<serde_json::Value, Error> {
        let review = configured(authority).ok()
            .and_then(|store| store.with_review_policy(|policy| job_reviews::accepted(db, &detail.manifest, policy, history::now())).ok())
            .transpose()?.flatten();
        let classification = classify(&detail.manifest, self.reviewed(&detail.manifest, review.as_ref()));
        let pin = detail.park.pin(&detail.manifest);
        Ok(json!({ "detail": detail, "pin": pin, "classification": classification, "review": review }))
    }

    pub(crate) fn command(
        &self,
        db: &mut Connection,
        authority: &Result<Option<Authority>, fleet_policy::Error>,
        launch: &str,
        command: Command,
    ) -> Result<String, Error> {
        match command {
            Command::File { id, manifest } => {
                let park = self.file(db, launch, &id, &manifest)?;
                encode(&park.pin(&manifest))
            }
            Command::Status { id } => {
                let who = owner(db, launch)?;
                let detail = detail(db, &id)?;
                if detail.manifest.owner != who {
                    return Err(fleet_policy::Error::Principal.into());
                }
                encode(&self.describe(db, authority, detail)?)
            }
            Command::Judge { park, signed } => encode(&self.decide(
                db, configured(authority)?, &park, Purpose::Execute,
                Evidence::Bot { launch, signed: &signed }, None,
            )?),
            Command::Backstop { park, signed } => encode(&self.decide(
                db, configured(authority)?, &park, Purpose::AutoExecute,
                Evidence::Bot { launch, signed: &signed }, None,
            )?),
        }
    }
}

fn owner(db: &Connection, launch: &str) -> Result<String, Error> {
    match bots::of_launch(db, launch)? {
        bots::Who::Bot(bot) if bot.noted_launch.as_deref() == Some(launch) => Ok(bot.id),
        _ => Err(fleet_policy::Error::Principal.into()),
    }
}

pub(super) fn valid_id(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte))
}

fn configured(authority: &Result<Option<Authority>, fleet_policy::Error>) -> Result<&Authority, Error> {
    match authority {
        Ok(Some(store)) => Ok(store),
        Ok(None) => Err(fleet_policy::Error::Unavailable.into()),
        Err(reason) => Err(reason.clone().into()),
    }
}

#[derive(Serialize)]
pub(crate) struct Summary {
    id: String,
    owner: String,
    project: String,
    state: State,
}

pub(crate) fn summaries(db: &Connection) -> rusqlite::Result<Vec<Summary>> {
    db.prepare(
        "SELECT id,json_extract(manifest,'$.owner'),json_extract(manifest,'$.project'),state
         FROM parks WHERE state IN ('pending','held','executing','reconciliation')
         ORDER BY created_ms DESC,id LIMIT 101",
    )?
    .query_map([], |row| {
        Ok(Summary {
            id: row.get(0)?,
            owner: row.get(1)?,
            project: row.get(2)?,
            state: row.get(3)?,
        })
    })?
    .collect()
}

#[derive(Serialize)]
struct Detail {
    park: ParkRef,
    manifest: Manifest,
    view: View,
    supersedes: Option<String>,
    superseded_by: Option<String>,
    decision: Option<serde_json::Value>,
}

fn detail(db: &Connection, id: &str) -> Result<Detail, Error> {
    let (manifest_digest, supersedes, superseded_by) = db.query_row(
        "SELECT p.manifest_digest,p.supersedes,(SELECT id FROM parks WHERE supersedes=p.id)
         FROM parks p WHERE p.id=?1",
        [id], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
    ).optional()?.ok_or(Error::Missing)?;
    let park = ParkRef { id: id.into(), manifest_digest };
    let manifest = manifest_for(db, &park)?;
    let decision = db.query_row(
        "SELECT json_object('action',action,'actor',actor,'source',source,
                    'basis',CASE WHEN json_valid(basis) THEN json(basis) ELSE basis END,
                    'classifier',json(classifier_output),'policy',json(policy_version),'at_ms',at_ms)
         FROM park_decisions WHERE park_id=?1 ORDER BY id DESC LIMIT 1",
        [id], |row| row.get::<_, String>(0),
    ).optional()?.as_deref().map(decode).transpose()?;
    Ok(Detail { view: status(db, &park)?, park, manifest, supersedes, superseded_by, decision })
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/parks", get(list))
        .route("/api/parks/decide", post(decide))
        .route("/api/parks/{id}", get(get_park))
}

async fn list(AxumState(w): AxumState<Workspace>) -> Result<Json<serde_json::Value>, Error> {
    let db = w.history.db()?;
    let mut rows = db.prepare("SELECT id,state FROM parks ORDER BY created_ms DESC,id LIMIT 101")?;
    let rows = rows.query_map([], |row| Ok(json!({"id":row.get::<_, String>(0)?, "state":row.get::<_, State>(1)?})))?
        .collect::<Result<Vec<_>,_>>()?;
    Ok(Json(json!({ "parks": rows.iter().take(100).collect::<Vec<_>>(), "more": rows.len() > 100 })))
}

async fn get_park(
    AxumState(w): AxumState<Workspace>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, Error> {
    let db = w.history.db()?;
    Ok(Json(w.parks.describe(&db, &w.fleet_policy, detail(&db, &id)?)?))
}

async fn decide(
    AxumState(w): AxumState<Workspace>,
    Json(submission): Json<Submission>,
) -> Result<Json<DecisionResult>, Error> {
    tokio::task::spawn_blocking(move || {
        let evidence = match &submission.evidence {
            OperatorEvidence::Signed(signed) => Evidence::OperatorSignature(signed),
            OperatorEvidence::Imported(nonce) => Evidence::Operator(nonce),
        };
        let mut db = history::connection(w.history.file())?;
        let result = w.parks.decide(
            &mut db, configured(&w.fleet_policy)?, &submission.park,
            submission.purpose, evidence, submission.replacement.as_ref(),
        )?;
        Ok(Json(result))
    }).await.map_err(|_| Error::Store(StoreError))?
}

impl Error {
    pub(crate) fn message(&self) -> String {
        match self {
            Self::Store(_) => "The workspace journal could not record or read the park.".into(),
            Self::Conflict => "The park revision or decision state has changed.".into(),
            Self::InvalidManifest => "The park manifest or replacement is invalid.".into(),
            Self::InvalidDecision => "The park decision is invalid.".into(),
            Self::Missing => "The park was not found.".into(),
            Self::Authority(error) => error.to_string(),
            Self::Blocked(_) => "The staging project or its pins could not be verified.".into(),
        }
    }
}

impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let status = match self {
            Self::Store(_) => StatusCode::INTERNAL_SERVER_ERROR,
            Self::Conflict | Self::Authority(fleet_policy::Error::Replay) => StatusCode::CONFLICT,
            Self::Missing => StatusCode::NOT_FOUND,
            Self::InvalidManifest | Self::InvalidDecision => StatusCode::BAD_REQUEST,
            Self::Authority(fleet_policy::Error::Busy) => StatusCode::SERVICE_UNAVAILABLE,
            Self::Authority(_) | Self::Blocked(_) => StatusCode::FORBIDDEN,
        };
        (status, Json(json!({"error": self.message()}))).into_response()
    }
}

#[cfg(test)]
mod tests;
