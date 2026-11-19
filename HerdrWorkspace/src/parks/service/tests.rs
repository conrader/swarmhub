use super::*;

#[test]
fn gapplan_05_unit_classifier_matrix_and_escalation() {
    let mut manifest = crate::parks::tests::manifest();
    let staging = Operation::AdvanceStagingRef { reference: "refs/heads/staging".into(), rollback: true };
    for (operation, reviewed, want, destructive, irreversible) in [
        (staging.clone(), true, Class::ReviewedReversible, Some(false), Some(false)),
        (staging, false, Class::StagingNeedsReview, Some(false), Some(false)),
        (Operation::SpendMoney, true, Class::Money, Some(false), Some(true)),
        (Operation::UseSecret, true, Class::Secrets, Some(false), Some(true)),
        (Operation::Delete, true, Class::Delete, Some(true), Some(true)),
        (Operation::OutsideMessage, true, Class::OutsideMessage, Some(false), Some(true)),
        (Operation::Unknown { action: "future_action".into() }, true, Class::Unknown, None, None),
        (manifest.operation.clone(), true, Class::Unknown, None, None),
    ] {
        manifest.operation = operation;
        let result = classify(&manifest, reviewed);
        assert_eq!(result.class, want);
        assert_eq!(result.scope.owner, manifest.owner);
        assert_eq!(result.scope.project, manifest.project);
        assert_eq!(result.scope.host, manifest.host);
        assert_eq!(result.scope.action, manifest.operation.action());
        assert_eq!(result.destructive, destructive);
        assert_eq!(result.irreversible, irreversible);
        assert!(result.required_signers.contains(&Signer::Operator));
        if want == Class::ReviewedReversible {
            assert_eq!(result.escalation_target, Signer::EnrolledDelegate);
        } else {
            assert_eq!(result.escalation_target, Signer::Operator);
            assert_eq!(result.required_signers, &[Signer::Operator]);
        }
    }
}

#[test]
fn gapplan_05_unit_staging_ref_and_oid_syntax() {
    assert!(staging_ref::valid_ref("refs/heads/staging/project-a"));
    for bad in ["HEAD", "refs/tags/staging", "refs/heads/", "refs/heads/.hiding",
        "refs/heads/a.lock", "refs/heads/a..b", "refs/heads/a//b", "refs/heads/a@{b"] {
        assert!(!staging_ref::valid_ref(bad), "{bad}");
    }
    assert!(staging_ref::valid_oid(&"f".repeat(40)));
    assert!(staging_ref::valid_oid(&"f".repeat(64)));
    assert!(!staging_ref::valid_oid(&"0".repeat(40)));
    assert!(!staging_ref::valid_oid(&"F".repeat(40)));
    assert!(!staging_ref::valid_oid(&"f".repeat(39)));
}
