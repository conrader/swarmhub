use super::*;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use ring::{rand::SystemRandom, signature::{Ed25519KeyPair, KeyPair}};
use std::{fs, path::Path};

pub(crate) const WORKSPACE: &str = "fixture-workspace";
pub(crate) const JARVIS: &str = "fixture-jarvis";
const LAUNCH: &str = "01010101010101010101010101010101";

fn key() -> Ed25519KeyPair {
    let document = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
    Ed25519KeyPair::from_pkcs8(document.as_ref()).unwrap()
}

fn sign(key: &Ed25519KeyPair, envelope: Envelope) -> Signed {
    let signature = STANDARD.encode(key.sign(&envelope.canonical().unwrap()).as_ref());
    Signed { envelope, signature }
}

pub(crate) struct Fixture {
    pub authority: Authority,
    operator: Ed25519KeyPair,
    delegate: Ed25519KeyPair,
    directory: std::path::PathBuf,
}

impl Fixture {
    pub(crate) fn new(root: &Path, workspace: &str, delegate_enrolled: bool) -> Self {
        let directory = root.join(workspace);
        fs::create_dir(&directory).unwrap();
        let operator = key();
        let delegate = key();
        fs::write(directory.join("policy.lock"), []).unwrap();
        fs::write(directory.join("trust.json"), serde_json::json!({
            "workspace": workspace,
            "operator_key": STANDARD.encode(operator.public_key()),
            "delegate": delegate_enrolled.then(|| serde_json::json!({
                "bot_id": JARVIS, "key": STANDARD.encode(delegate.public_key()),
            })),
        }).to_string()).unwrap();
        let authority = Authority::fixture(&directory, workspace);
        Self { authority, operator, delegate, directory }
    }

    pub(crate) fn restart(&self, workspace: &str) -> Authority {
        Authority::fixture(&self.directory, workspace)
    }

    pub(crate) fn peer(&self, root: &Path, workspace: &str) -> Authority {
        let directory = root.join(workspace);
        fs::create_dir(&directory).unwrap();
        fs::write(directory.join("policy.lock"), []).unwrap();
        let mut trust: serde_json::Value = serde_json::from_slice(
            &fs::read(self.directory.join("trust.json")).unwrap(),
        ).unwrap();
        trust["workspace"] = workspace.into();
        fs::write(directory.join("trust.json"), trust.to_string()).unwrap();
        let authority = Authority::fixture(&directory, workspace);
        authority.import_policy(self.publication(policy(1, vec![]), workspace)).unwrap();
        authority
    }

    pub(crate) fn publication(&self, policy: Policy, workspace: &str) -> Publication {
        let reference = policy.reference().unwrap();
        let signed = sign(&self.operator, envelope(
            workspace,
            Principal::Operator,
            Purpose::PublishPolicy,
            Target::Policy { policy: reference },
            "policy-import",
        ));
        Publication { policy, signed }
    }

    pub(crate) fn publish(&self, document: Publication) -> Result<PolicyRef, Error> {
        self.authority.import_policy(document)
    }

    pub(crate) fn import_decision(&self, decision: Signed) -> Result<String, Error> {
        self.authority.import_decision(decision)
    }

    pub(crate) fn sign_decision(&self, envelope: Envelope) -> Signed {
        match envelope.principal {
            Principal::Operator => sign(&self.operator, envelope),
            Principal::Bot { .. } => sign(&self.delegate, envelope),
        }
    }
}

pub(crate) fn policy(generation: i64, rules: Vec<Rule>) -> Policy {
    Policy { generation, rules, revoked: BTreeSet::new() }
}

pub(crate) fn grant() -> Rule {
    let manifest = parks::tests::manifest();
    Rule {
        id: "fixture-grant".into(),
        scope: Scope {
            action: Some("set_revision_marker".into()),
            project: Some(manifest.project),
            owner: Some(manifest.owner),
            principal: Some(Actor::Bot { id: JARVIS.into() }),
        },
        decision_ref: "fixture-decision-ref".into(),
        effective_ms: 0,
        expires_ms: i64::MAX,
        rule: RuleKind::Grant,
    }
}

pub(crate) fn envelope(
    workspace: &str,
    principal: Principal,
    purpose: Purpose,
    target: Target,
    nonce: &str,
) -> Envelope {
    let now = history::now();
    Envelope {
        workspace: workspace.into(),
        principal,
        purpose,
        target,
        nonce: nonce.into(),
        issued_ms: now - 60_000,
        expires_ms: now + 60_000,
    }
}

fn pin() -> ParkPin {
    ParkPin {
        id: "park-a".into(),
        revision: "fixture-v2".into(),
        manifest_digest: "e".repeat(64),
    }
}

fn fixture_request() -> Request<'static> {
    Request {
        park: pin(),
        action: "set_revision_marker",
        project: "fixture-project",
        owner: "fixture-bot",
    }
}

fn operator_envelope() -> Envelope {
    envelope(
        WORKSPACE,
        Principal::Operator,
        Purpose::Execute,
        Target::Park { park: pin(), policy: policy(1, vec![]).reference().unwrap() },
        "nonce-a",
    )
}

#[test]
fn gapplan_04_unit_signature_binds_all_envelope_fields() {
    let key = key();
    let public = key.public_key().as_ref().try_into().unwrap();
    let original = sign(&key, operator_envelope());
    let now = history::now();
    assert_eq!(original.verify(public, WORKSPACE, now), Ok(()));
    assert_eq!(original.verify(&[0; 32], WORKSPACE, now), Err(Error::Signature));

    type Edit = fn(&mut Envelope);
    let edits: [Edit; 6] = [
        |e| e.workspace = "workspace-b".into(),
        |e| e.purpose = Purpose::Release,
        |e| e.nonce = "nonce-b".into(),
        |e| e.issued_ms -= 1,
        |e| e.expires_ms += 1,
        |e| e.principal = Principal::Bot { id: JARVIS.into(), launch: LAUNCH.into() },
    ];
    for edit in edits {
        let mut tampered = original.clone();
        edit(&mut tampered.envelope);
        assert_eq!(tampered.verify(public, &tampered.envelope.workspace, now), Err(Error::Signature));
    }

    type EditTarget = fn(&mut ParkPin, &mut PolicyRef);
    let edits: [EditTarget; 5] = [
        |park, _| park.id = "park-b".into(),
        |park, _| park.revision = "new-revision".into(),
        |park, _| park.manifest_digest = "f".repeat(64),
        |_, reference| reference.generation += 1,
        |_, reference| reference.digest = "f".repeat(64),
    ];
    for edit in edits {
        let mut tampered = original.clone();
        let Target::Park { park, policy } = &mut tampered.envelope.target else { unreachable!() };
        edit(park, policy);
        assert_eq!(tampered.verify(public, WORKSPACE, now), Err(Error::Signature));
    }

    let mut bot = operator_envelope();
    bot.principal = Principal::Bot { id: JARVIS.into(), launch: LAUNCH.into() };
    let mut signed = sign(&key, bot);
    signed.envelope.principal = Principal::Bot { id: JARVIS.into(), launch: "f".repeat(32) };
    assert_eq!(signed.verify(public, WORKSPACE, now), Err(Error::Signature));
}

#[test]
fn gapplan_04_unit_expiry_and_effective_intervals_are_half_open() {
    let key = key();
    let now = 42;
    let public = key.public_key().as_ref().try_into().unwrap();
    let mut envelope = operator_envelope();
    envelope.issued_ms = now;
    envelope.expires_ms = 2 * now;
    let signed = sign(&key, envelope);
    let mut grant = grant();
    grant.effective_ms = now;
    grant.expires_ms = 2 * now;
    let policy = policy(1, vec![grant]);
    let request = fixture_request();
    let bot = Actor::Bot { id: JARVIS.into() };
    for time in [now - 1, 2 * now] {
        assert_eq!(signed.verify(public, WORKSPACE, time), Err(Error::Expired));
        assert_eq!(policy.allows(&request, &bot, Purpose::Execute, time).unwrap_err(), Error::NoGrant);
    }
    for time in [now, 2 * now - 1] {
        assert!(signed.verify(public, WORKSPACE, time).is_ok());
        assert!(policy.allows(&request, &bot, Purpose::Execute, time).unwrap().is_some());
    }
}

#[test]
fn gapplan_04_unit_grant_requires_every_dimension_and_explicit_bot() {
    let bot = Actor::Bot { id: JARVIS.into() };
    let request = fixture_request();
    assert_eq!(policy(1, vec![]).allows(&request, &bot, Purpose::Execute, 1).unwrap_err(), Error::NoGrant);
    let allowed = policy(1, vec![grant()]);
    assert_eq!(allowed.allows(&request, &bot, Purpose::Execute, 1).unwrap().unwrap().id, "fixture-grant");
    for other in [
        Request { action: "unknown", ..fixture_request() },
        Request { project: "other-project", ..fixture_request() },
        Request { owner: "someone-else", ..fixture_request() },
    ] {
        assert_eq!(allowed.allows(&other, &bot, Purpose::Execute, 1).unwrap_err(), Error::NoGrant);
    }
    let unrelated = Actor::Bot { id: "other".into() };
    assert_eq!(allowed.allows(&request, &unrelated, Purpose::Execute, 1).unwrap_err(), Error::NoGrant);
    let mut self_grant = grant();
    self_grant.scope.owner = Some(JARVIS.into());
    let owned = Request { owner: JARVIS, ..request };
    assert_eq!(policy(1, vec![self_grant]).allows(&owned, &bot, Purpose::Execute, 1).unwrap_err(), Error::SelfApproval);

    let mut wildcard = grant();
    wildcard.scope.principal = None;
    assert_eq!(policy(1, vec![wildcard]).reference(), Err(Error::Invalid));
}

#[test]
fn gapplan_04_unit_stop_and_signoff_take_precedence_over_named_exception() {
    let request = fixture_request();
    let bot = Actor::Bot { id: JARVIS.into() };
    let mut broad = grant();
    broad.id = "broad".into();
    broad.scope.project = None;
    let mut exception = broad.clone();
    exception.id = "named-exception".into();
    exception.rule = RuleKind::Exception { park: pin() };
    let mut chosen = policy(1, vec![broad, exception, grant()]);
    let allowed = |policy: &Policy| policy.allows(&request, &bot, Purpose::Execute, 1)
        .map(|rule| rule.map(|rule| rule.id.clone()));
    assert_eq!(allowed(&chosen), Ok(Some("named-exception".into())));
    let mut generic = grant();
    generic.scope.principal = None;
    generic.id = "owner-required".into();
    generic.rule = RuleKind::RequireOwnerSignoff { signer: "named-partner".into() };
    chosen.rules.push(generic.clone());
    assert_eq!(allowed(&chosen), Err(Error::OwnerSignoff));
    generic.id = "approval".into();
    let mut another_park = pin();
    another_park.manifest_digest = "b".repeat(64);
    generic.rule = RuleKind::OwnerSignoff { signer: "named-partner".into(), park: another_park };
    chosen.rules.push(generic.clone());
    assert_eq!(allowed(&chosen), Err(Error::OwnerSignoff));
    generic.rule = RuleKind::OwnerSignoff { signer: "named-partner".into(), park: pin() };
    *chosen.rules.last_mut().unwrap() = generic.clone();
    assert_eq!(allowed(&chosen), Ok(Some("named-exception".into())));
    generic.id = "project-stop".into();
    generic.scope = Scope { project: Some(request.project.into()), ..Scope::default() };
    generic.rule = RuleKind::Stop;
    chosen.rules.push(generic);
    assert_eq!(allowed(&chosen), Err(Error::Stopped));
    assert_eq!(chosen.allows(&request, &Actor::Operator, Purpose::Execute, 1).unwrap_err(), Error::Stopped);
    chosen.revoked.insert("project-stop".into());
    chosen.revoked.insert("named-exception".into());
    assert_eq!(allowed(&chosen), Ok(Some("fixture-grant".into())));
    chosen.revoked.insert("approval".into());
    assert_eq!(allowed(&chosen), Err(Error::OwnerSignoff));
}
