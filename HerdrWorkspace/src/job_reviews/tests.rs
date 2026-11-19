use super::*;
use crate::fleet_policy::{RuleKind, Scope as RuleScope, tests::policy};

fn runtime(provider: &str, model: Option<&str>, family: Option<&str>) -> jobs::Runtime {
    jobs::Runtime { provider: provider.into(), model: model.map(str::to_owned),
        family: family.map(str::to_owned), effort: Some("high".into()), account_ref: Some("fixture-account".into()) }
}

#[test]
fn gapplan_11_unit_sonnet_reviews_sol_but_aliases_and_same_family_do_not_qualify() {
    let sonnet = runtime("claude", Some("claude-sonnet-5"), Some("claude"));
    let opus = runtime("claude", Some("claude-opus-5"), Some("claude"));
    let sol = runtime("codex", Some("gpt-6.1-sol"), Some("codex"));
    let sonnet = Identity::observed(&sonnet).unwrap();
    let opus = Identity::observed(&opus).unwrap();
    let sol = Identity::observed(&sol).unwrap();
    assert!(sonnet.independent_of(&sol, false));
    assert!(!sonnet.independent_of(&opus, false));
    assert!(!sonnet.independent_of(&opus, true));
    assert!(Identity::observed(&runtime("codex", None, Some("codex"))).is_none());
    assert!(Identity::observed(&runtime("codex", Some("sol"), Some("codex"))).is_none());
    assert!(Identity::observed(&runtime("codex", Some("gpt-6.1-sol"), Some("claude"))).is_none());
    assert!(Identity::observed(&runtime("claude", Some("claude-sonnet-5"), None)).is_none());
}

fn report(verdict: Verdict, severities: &[Severity]) -> Artifact {
    Artifact::Reviewer {
        lineage: "fixture-lineage".into(), round: 2, producer_digest: "a".repeat(64),
        revisions: Revisions { code: "a".repeat(40), apply: "apply-v1".into(), reverse: "reverse-v1".into() },
        tests: Tests { reference: "fixture-tests".into(), digest: "b".repeat(64), passed: 3 },
        verdict, findings: severities.iter().map(|severity| Finding { severity: *severity, summary: "fixture finding".into() }).collect(),
    }
}

#[test]
fn gapplan_11_unit_changes_and_serious_findings_never_allow_advancement() {
    assert_eq!(verdict_permission(&report(Verdict::Pass, &[]), 0), Some(None));
    for round in [0, 1, 2, 3] {
        for findings in [
            vec![Severity::P0], vec![Severity::P1, Severity::P2], vec![Severity::P3],
        ] {
            assert_eq!(verdict_permission(&report(Verdict::Concerns, &findings), round), None);
        }
        assert_eq!(verdict_permission(&report(Verdict::Changes, &[Severity::P2]), round), None);
    }
    let p2 = report(Verdict::Concerns, &[Severity::P2]);
    assert_eq!(verdict_permission(&p2, 1), None);
    assert_eq!(verdict_permission(&p2, 2), Some(Some(ReviewPermission::ResidualP2)));
}

#[test]
fn gapplan_11_unit_typed_evidence_requires_tests_and_all_wrapper_pins() {
    let valid = report(Verdict::Pass, &[]);
    assert!(valid.valid());
    assert!(!report(Verdict::Pass, &[Severity::P1]).valid());
    assert!(serde_json::from_str::<Artifact>("\"PASS\"").is_err());
    let mut payload = serde_json::to_value(valid).unwrap();
    payload["tests"]["passed"] = 0.into();
    assert!(!serde_json::from_value::<Artifact>(payload.clone()).unwrap().valid());
    payload["tests"]["passed"] = 1.into();
    payload["revisions"]["reverse"] = "".into();
    assert!(!serde_json::from_value::<Artifact>(payload).unwrap().valid());
}

#[test]
fn gapplan_11_unit_exhausted_budget_needs_a_named_dated_grant_for_the_exact_round() {
    let scope = Scope { lineage: "fixture-lineage", owner: "fixture-owner", project: 1 };
    let mut rule = Rule {
        id: "extra-round".into(), decision_ref: "fixture-signoff".into(), effective_ms: 100, expires_ms: 200,
        scope: RuleScope { action: Some(STAGING_ACTION.into()), project: Some("1".into()),
            owner: Some(scope.owner.into()), principal: None },
        rule: RuleKind::ReviewException { lineage: scope.lineage.into(), permission: ReviewPermission::ExtraRound(3) },
    };
    let mut signed_policy = policy(1, vec![rule.clone()]);
    assert!(signed_policy.reference().is_ok());
    for (name, round, time) in [("extra-round", 2, 101), ("extra-round", 4, 101), ("another", 3, 101),
        ("extra-round", 3, 99), ("extra-round", 3, 200)] {
        assert!(scope.exception(&signed_policy, name, ReviewPermission::ExtraRound(round), time).is_none());
    }
    assert!(scope.exception(&signed_policy, "extra-round", ReviewPermission::ExtraRound(3), 100).is_some());
    signed_policy.revoked.insert(rule.id.clone());
    assert!(scope.exception(&signed_policy, "extra-round", ReviewPermission::ExtraRound(3), 101).is_none());
    rule.scope.project = None;
    assert!(policy(1, vec![rule]).reference().is_err());
}
