use super::*;
use serde_json::{Value, json};

fn sample_email() -> Value {
    json!({
        "channel": "email",
        "sender": "sender@example.test",
        "to": ["to@example.test"],
        "cc": ["cc@example.test"],
        "bcc": ["bcc@example.test"],
        "subject": "Bardzo ważne",
        "in_reply_to": "<original@example.test>",
        "thread_id": "thread-1",
        "body": "Zażółć gęślą jaźń\nSecond line."
    })
}

fn hash(value: &Value) -> String {
    serde_json::from_value::<Payload>(value.clone()).unwrap().normalize().unwrap().digest().unwrap()
}

#[test]
fn gapplan_13_unit_every_supported_payload_field_changes_the_pin() {
    let cases = [
        (sample_email(), vec![
            ("sender", json!("other@example.test")), ("to", json!(["other@example.test"])),
            ("cc", json!([])), ("bcc", json!(["other@example.test"])),
            ("subject", json!("Different")), ("in_reply_to", Value::Null),
            ("thread_id", json!("thread-2")), ("body", json!("Another message")),
        ]),
        (json!({"channel":"slack","sender":"acct-1","destination":"C123","thread_ts":"123.456789","body":"Copy"}), vec![
            ("sender", json!("acct-2")), ("destination", json!("C456")),
            ("thread_ts", Value::Null), ("body", json!("Different")),
        ]),
        (json!({"channel":"whatsapp","sender":"+48123456789","destination":"+48987654321","reply_message_id":"reply-1","body":"Copy"}), vec![
            ("sender", json!("+48123456788")), ("destination", json!("+48987654322")),
            ("reply_message_id", Value::Null), ("body", json!("Different")),
        ]),
        (json!({"channel":"deployment","sender":"fixture-account","destination":"preview","release_revision":"d".repeat(40),"body":"Copy"}), vec![
            ("sender", json!("other-account")), ("destination", json!("production")),
            ("release_revision", json!("e".repeat(40))), ("body", json!("Different")),
        ]),
    ];
    let mut pins = std::collections::HashSet::new();
    for (base, edits) in cases {
        let original = hash(&base);
        assert!(pins.insert(original.clone()));
        for (field, value) in edits {
            let mut changed = base.clone();
            changed[field] = value;
            assert_ne!(original, hash(&changed), "{field}");
        }
    }
}

#[test]
fn gapplan_13_unit_unicode_is_preserved_and_crlf_is_canonical() {
    let mut email = sample_email();
    email["body"] = json!("Café\nZażółć\t😊");
    let pin = hash(&email);
    email["body"] = json!("Café\r\nZażółć\t😊");
    assert_eq!(hash(&email), pin);
    email["body"] = json!("Cafe\u{301}\nZażółć\t😊");
    assert_ne!(hash(&email), pin);
    email["body"] = json!("Café\rZażółć\t😊");
    assert!(serde_json::from_value::<Payload>(email).unwrap().normalize().is_err());
}

#[test]
fn gapplan_13_unit_header_injection_and_extra_payload_fields_are_rejected() {
    for (field, value) in [
        ("sender", json!("sender@example.test\r\nBcc: spy@example.test")),
        ("to", json!(["to@example.test,spy@example.test"])),
        ("cc", json!(["cc@example.test\nX-Extra: value"])),
        ("bcc", json!(["bcc@example.test\rX-Extra: value"])),
        ("subject", json!("Title\u{2028}Cc: spy@example.test")),
        ("in_reply_to", json!("<x@example.test>\r\nReply-To: spy@example.test")),
        ("thread_id", json!("id\nextra")),
    ] {
        let mut email = sample_email();
        email[field] = value;
        assert!(serde_json::from_value::<Payload>(email).unwrap().normalize().is_err(), "{field}");
    }
    for field in ["headers", "attachments", "html", "mime_type"] {
        let mut email = sample_email();
        email[field] = Value::Null;
        assert!(serde_json::from_value::<Payload>(email).is_err(), "{field}");
    }
}

#[test]
fn gapplan_13_unit_reviewer_has_no_authorize_outbound_signature_purpose() {
    use crate::fleet_policy::{
        principals::{Principal, Purpose, Target},
        tests::{JARVIS, WORKSPACE, envelope, policy},
    };
    let manifest = parks::tests::manifest();
    let decision = envelope(WORKSPACE,
        Principal::Bot { id: JARVIS.into(), launch: "a".repeat(32) },
        Purpose::AuthorizeOutbound,
        Target::Park {
            park: parks::pin_for("fixture", &manifest).unwrap(),
            policy: policy(1, vec![]).reference().unwrap(),
        },
        "reviewer-approval",
    );
    assert!(decision.canonical().is_err());
}
