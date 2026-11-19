//! Fleet decision authority. Only the protected operator store can supply current policy.

pub(crate) mod principals;
mod store;
#[cfg(test)]
pub(crate) mod tests;

use crate::{history, parks};
use principals::{Actor, Envelope, ParkPin, Principal, Purpose, Signed, Target};
use rusqlite::{Connection, params};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{cmp::Reverse, collections::BTreeSet, fmt, io::Write as _};
pub(crate) use store::{Authority, Role};

pub(crate) const USAGE: &str =
    "Fleet policy: fleet-policy digest|park-pin|payload|import-policy|import-decision|inspect|audit";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Error {
    Unavailable,
    Busy,
    Invalid,
    Signature,
    Binding,
    Expired,
    StalePolicy,
    Principal,
    Stopped,
    OwnerSignoff,
    NoGrant,
    SelfApproval,
    HumanScope,
    Replay,
    Audit,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Self::Unavailable => "The protected operator policy or decision is unavailable.",
            Self::Busy => "The operator store is busy. Retry the decision.",
            Self::Invalid => "The fleet policy or decision is invalid.",
            Self::Signature => "The decision signature did not verify against the enrolled key.",
            Self::Binding => "The decision does not match this workspace, purpose or park revision.",
            Self::Expired => "The signed decision is outside its validity interval.",
            Self::StalePolicy => "The decision does not name the current policy generation.",
            Self::Principal => "The requesting principal could not be verified.",
            Self::Stopped => "An applicable fleet policy STOP is active.",
            Self::OwnerSignoff => "A required project-owner sign-off is missing.",
            Self::NoGrant => "There is no effective grant for this bot and operation.",
            Self::SelfApproval => "A bot cannot approve its own park.",
            Self::HumanScope => "This operation requires an operator decision.",
            Self::Replay => "This decision nonce has already been used.",
            Self::Audit => "The workspace journal could not record or read fleet policy evidence.",
        })
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(_: rusqlite::Error) -> Self {
        Self::Audit
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PolicyRef {
    pub generation: i64,
    pub digest: String,
}

impl PolicyRef {
    fn valid(&self) -> bool {
        self.generation > 0 && principals::hex(&self.digest, 64)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Policy {
    pub generation: i64,
    pub rules: Vec<Rule>,
    pub revoked: BTreeSet<String>,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Scope {
    pub action: Option<String>,
    pub project: Option<String>,
    pub owner: Option<String>,
    pub principal: Option<Actor>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum RuleKind {
    Grant,
    SafeClassGrant,
    Stop,
    RequireOwnerSignoff { signer: String },
    OwnerSignoff { signer: String, park: ParkPin },
    Exception { park: ParkPin },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Rule {
    pub id: String,
    pub scope: Scope,
    pub decision_ref: String,
    pub effective_ms: i64,
    pub expires_ms: i64,
    pub rule: RuleKind,
}

impl Scope {
    fn valid(&self) -> bool {
        [&self.action, &self.project, &self.owner]
            .into_iter()
            .all(|field| field.as_deref().is_none_or(principals::text))
            && match &self.principal {
                Some(Actor::Bot { id }) => crate::bots::valid_id(id),
                _ => true,
            }
    }

    fn applies(&self, request: &Request<'_>, actor: &Actor) -> bool {
        self.action.as_deref().is_none_or(|value| value == request.action)
            && self.project.as_deref().is_none_or(|value| value == request.project)
            && self.owner.as_deref().is_none_or(|value| value == request.owner)
            && self.principal.as_ref().is_none_or(|value| value == actor)
    }

    fn specificity(&self) -> usize {
        [
            self.action.is_some(),
            self.project.is_some(),
            self.owner.is_some(),
            self.principal.is_some(),
        ]
        .into_iter()
        .filter(|field| *field)
        .count()
    }
}

impl Rule {
    fn valid(&self) -> bool {
        principals::identifier(&self.id)
            && principals::text(&self.decision_ref)
            && principals::interval(self.effective_ms, self.expires_ms)
            && self.scope.valid()
            && match &self.rule {
                RuleKind::Grant => self.delegated_scope(),
                RuleKind::SafeClassGrant => self.delegated_scope()
                    && self.scope.action.as_deref() == Some(parks::STAGING_ACTION)
                    && self.scope.project.is_some(),
                RuleKind::Exception { park } => self.delegated_scope() && park.valid(),
                RuleKind::RequireOwnerSignoff { signer } => principals::text(signer),
                RuleKind::OwnerSignoff { signer, park } => principals::text(signer) && park.valid(),
                RuleKind::Stop => true,
            }
    }

    fn delegated_scope(&self) -> bool {
        self.scope.action.is_some() && matches!(self.scope.principal, Some(Actor::Bot { .. }))
    }
}

struct Request<'a> {
    park: ParkPin,
    action: &'a str,
    project: &'a str,
    owner: &'a str,
}

impl Policy {
    pub(crate) fn reference(&self) -> Result<PolicyRef, Error> {
        let mut ids = BTreeSet::new();
        if self.generation <= 0
            || !self.rules.iter().all(|rule| rule.valid() && ids.insert(&rule.id))
            || !self.revoked.iter().all(|id| principals::identifier(id))
        {
            return Err(Error::Invalid);
        }
        let bytes = serde_json::to_vec(self).map_err(|_| Error::Invalid)?;
        Ok(PolicyRef {
            generation: self.generation,
            digest: format!("{:x}", Sha256::digest(bytes)),
        })
    }

    fn allows(
        &self,
        request: &Request<'_>,
        actor: &Actor,
        purpose: Purpose,
        now: i64,
    ) -> Result<Option<&Rule>, Error> {
        if matches!(purpose, Purpose::Hold | Purpose::Deny | Purpose::Supersede) {
            return Ok(None);
        }
        let active = || {
            self.rules.iter().filter(|rule| {
                !self.revoked.contains(&rule.id)
                    && (rule.effective_ms..rule.expires_ms).contains(&now)
                    && rule.scope.applies(request, actor)
            })
        };
        if active().any(|rule| matches!(rule.rule, RuleKind::Stop)) {
            return Err(Error::Stopped);
        }
        for rule in active() {
            if let RuleKind::RequireOwnerSignoff { signer } = &rule.rule
                && !active().any(|rule| {
                    matches!(
                        &rule.rule,
                        RuleKind::OwnerSignoff { signer: approved, park }
                            if approved == signer && park == &request.park
                    )
                })
            {
                return Err(Error::OwnerSignoff);
            }
        }
        let Actor::Bot { id } = actor else {
            return Ok(None);
        };
        if id == request.owner {
            return Err(Error::SelfApproval);
        }
        active()
            .filter_map(|rule| {
                let exception = match &rule.rule {
                    RuleKind::Exception { park } if purpose != Purpose::AutoExecute && park == &request.park => true,
                    RuleKind::Grant if purpose != Purpose::AutoExecute => false,
                    RuleKind::SafeClassGrant if purpose == Purpose::AutoExecute => false,
                    _ => return None,
                };
                Some(((exception, rule.scope.specificity(), Reverse(&rule.id)), rule))
            })
            .max_by_key(|(rank, _)| *rank)
            .map(|(_, rule)| Some(rule))
            .ok_or(Error::NoGrant)
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Publication {
    pub policy: Policy,
    pub signed: Signed,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Published {
    pub published_ms: i64,
    pub publication: Publication,
}

impl Publication {
    fn verify(&self, trust: &store::Trust, now: i64) -> Result<PolicyRef, Error> {
        let reference = self.policy.reference()?;
        self.signed.verify(&trust.operator_key, &trust.workspace, now)?;
        if self.signed.envelope.purpose != Purpose::PublishPolicy
            || self.signed.envelope.target != (Target::Policy { policy: reference.clone() })
        {
            return Err(Error::Binding);
        }
        Ok(reference)
    }
}

#[derive(Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub(crate) enum Inspection {
    Unconfigured,
    Held {
        reason: Error,
    },
    Current {
        workspace: String,
        reference: PolicyRef,
        published_ms: i64,
        policy: Policy,
    },
}

/// The callers in slice 5 supply the checked request's launch, or the nonce of a locally imported
/// operator decision. A shared bearer or a chat response can only supply unverified evidence.
#[derive(Clone, Copy)]
pub(crate) enum Evidence<'a> {
    Operator(&'a str),
    OperatorSignature(&'a Signed),
    Bot {
        launch: &'a str,
        signed: &'a Signed,
    },
    #[cfg(test)]
    Unverified,
}

pub(crate) struct Verified {
    pub actor: Actor,
    pub workspace: String,
    pub policy: PolicyRef,
    pub nonce: String,
    pub rule_id: Option<String>,
    pub decision_ref: Option<String>,
    published_ms: i64,
    signed_policy: String,
}

impl Verified {
    pub(crate) fn audit(&self, db: &Connection) -> Result<(), Error> {
        audit_version(db, &self.workspace, &self.policy, self.published_ms, &self.signed_policy)
    }
}

fn audit_version(
    db: &Connection, workspace: &str, reference: &PolicyRef, published_ms: i64, signed_policy: &str,
) -> Result<(), Error> {
    db.execute(
        "INSERT INTO fleet_policy_versions (workspace,generation,digest,published_ms,signed_policy)
         SELECT ?1,?2,?3,?4,?5 WHERE NOT EXISTS (
            SELECT 1 FROM fleet_policy_versions WHERE workspace=?1 AND generation=?2
         )",
        params![workspace, reference.generation, reference.digest, published_ms, signed_policy],
    )?;
    let matches: bool = db.query_row(
        "SELECT digest=?3 AND published_ms=?4 AND signed_policy=?5
         FROM fleet_policy_versions WHERE workspace=?1 AND generation=?2",
        params![workspace, reference.generation, reference.digest, published_ms, signed_policy],
        |row| row.get(0),
    )?;
    if !matches {
        return Err(Error::Audit);
    }
    Ok(())
}

impl Authority {
    #[cfg(test)]
    pub(crate) fn publish_fixture(&self, publication: Publication) -> Result<PolicyRef, Error> {
        self.import_policy(publication)
    }

    #[cfg(test)]
    pub(crate) fn at_effect<T>(
        &self,
        db: &mut Connection,
        park: &parks::ParkRef,
        purpose: Purpose,
        evidence: Evidence<'_>,
        effect: impl FnOnce(&mut Connection, Verified) -> T,
    ) -> Result<T, Error> {
        self.with_park_decision(db, park, purpose, evidence, None, effect)
    }

    /// The shared operator lock spans verification and the caller's effect.
    pub(crate) fn with_park_decision<D: std::ops::Deref<Target = Connection>, T>(
        &self,
        db: D,
        park: &parks::ParkRef,
        purpose: Purpose,
        evidence: Evidence<'_>,
        replacement: Option<&ParkPin>,
        use_decision: impl FnOnce(D, Verified) -> T,
    ) -> Result<T, Error> {
        self.with_snapshot(|snapshot| {
            let (reference, published) = snapshot.current()?;
            let connection = &*db;
            let manifest = parks::manifest_for(connection, park).map_err(|_| Error::Binding)?;
            let request = Request {
                park: park.pin(&manifest),
                action: manifest.operation.action(),
                project: &manifest.project,
                owner: &manifest.owner,
            };
            let imported;
            let (actor, signed, key) = match evidence {
                Evidence::Operator(nonce) => {
                    imported = snapshot.operator_decision(nonce)?;
                    (Actor::Operator, &imported, &snapshot.trust.operator_key)
                }
                Evidence::OperatorSignature(signed) if signed.envelope.principal == Principal::Operator =>
                    (Actor::Operator, signed, &snapshot.trust.operator_key),
                Evidence::OperatorSignature(_) => return Err(Error::Principal),
                Evidence::Bot { launch, signed } => {
                    let actor = principals::registered_bot(connection, launch, &signed.envelope.principal)?;
                    let key = snapshot.trust.delegate_key(&actor)?;
                    (actor, signed, key)
                }
                #[cfg(test)]
                Evidence::Unverified => return Err(Error::Principal),
            };

            let now = history::now();
            signed.verify(key, &snapshot.trust.workspace, now)?;
            if signed.envelope.purpose != purpose {
                return Err(Error::Binding);
            }
            let policy = match &signed.envelope.target {
                Target::Park { park, policy } if *park == request.park && replacement.is_none() => policy,
                Target::Supersession { park, policy, replacement: signed_replacement }
                    if *park == request.park && replacement == Some(signed_replacement) => policy,
                _ => return Err(Error::Binding),
            };
            if *policy != reference {
                return Err(Error::StalePolicy);
            }
            let rule = published.publication.policy.allows(&request, &actor, purpose, now)?;
            let verified = Verified {
                actor,
                workspace: snapshot.trust.workspace.clone(),
                policy: reference,
                nonce: signed.envelope.nonce.clone(),
                rule_id: rule.map(|rule| rule.id.clone()),
                decision_ref: rule.map(|rule| rule.decision_ref.clone()),
                published_ms: published.published_ms,
                signed_policy: serde_json::to_string(&published.publication).map_err(|_| Error::Invalid)?,
            };
            Ok(use_decision(db, verified))
        })
    }

    pub(crate) fn inspect(&self) -> Inspection {
        self.inspect_snapshot(|snapshot| {
            let (reference, stored) = snapshot.current()?;
            Ok(Inspection::Current {
                workspace: snapshot.trust.workspace.clone(),
                reference,
                published_ms: stored.published_ms,
                policy: stored.publication.policy,
            })
        })
        .unwrap_or_else(|reason| Inspection::Held { reason })
    }

    /// A bridge that was offline can copy all intervening protected versions on restart.
    pub(crate) fn audit(&self, db: &mut Connection) -> Result<(), Error> {
        self.with_snapshot(|snapshot| {
            let tx = db.transaction()?;
            let workspace = &snapshot.trust.workspace;
            for generation in snapshot.generations()? {
                let (reference, stored) = snapshot.version(generation)?;
                let signed_policy =
                    serde_json::to_string(&stored.publication).map_err(|_| Error::Invalid)?;
                audit_version(&tx, workspace, &reference, stored.published_ms, &signed_policy)?;
            }
            tx.commit()?;
            Ok(())
        })
    }
}

pub(crate) fn cli() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(2);
    let verb = args.next();
    if args.next().is_some() {
        return Err(USAGE.into());
    }
    fn input<T: serde::de::DeserializeOwned>() -> Result<T, Box<dyn std::error::Error>> {
        Ok(serde_json::from_str(&crate::agent::read_input(store::LIMIT)?)?)
    }
    match verb.as_deref() {
        Some("digest") => println!("{}", serde_json::to_string(&input::<Policy>()?.reference()?)?),
        Some("park-pin") => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct ParkManifest {
                id: String,
                manifest: parks::Manifest,
            }
            let ParkManifest { id, manifest } = input()?;
            let pin = parks::pin_for(&id, &manifest).map_err(|error| error.message())?;
            println!("{}", serde_json::to_string(&pin)?);
        }
        Some("payload") => std::io::stdout().lock().write_all(&input::<Envelope>()?.canonical()?)?,
        Some("import-policy") => {
            let store = Authority::configured(Role::Operator)?.ok_or(Error::Unavailable)?;
            println!("{}", serde_json::to_string(&store.import_policy(input()?)?)?);
        }
        Some("import-decision") => {
            let store = Authority::configured(Role::Operator)?.ok_or(Error::Unavailable)?;
            println!("{}", store.import_decision(input()?)?);
        }
        Some("inspect") => {
            let view = match Authority::configured(Role::Inspect) {
                Ok(Some(store)) => store.inspect(),
                Ok(None) => Inspection::Unconfigured,
                Err(reason) => Inspection::Held { reason },
            };
            println!("{}", serde_json::to_string(&view)?);
        }
        Some("audit") => {
            let store = Authority::configured(Role::Bridge)?.ok_or(Error::Unavailable)?;
            let path = history::private_directory()?.join("workspace.sqlite3");
            store.audit(&mut history::connection(&path)?)?;
        }
        _ => return Err(USAGE.into()),
    }
    Ok(())
}
