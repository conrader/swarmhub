use super::*;

fn email() -> Email {
    Email {
        sender: "sender@example.test".into(),
        to: vec!["to@example.test".into(), "other@example.test".into()],
        cc: vec!["cc@example.test".into()],
        bcc: vec!["bcc@example.test".into()],
        subject: "Café".into(),
        in_reply_to: Some("<prior@example.test>".into()),
        thread_id: Some("thread-1".into()),
        body: "Café\nsecond\n".into(),
    }
}

#[test]
fn gapplan_14_unit_gmail_sends_exact_plain_text_mime_and_thread() {
    let message = Message::from_snapshot(&email(), "<outbound@example.test>", 0).unwrap();
    let expected = concat!(
        "Message-ID: <outbound@example.test>\r\n",
        "Date: Thu, 1 Jan 1970 00:00:00 +0000\r\n",
        "From: sender@example.test\r\n",
        "To: to@example.test,\r\n other@example.test\r\n",
        "Cc: cc@example.test\r\n",
        "Bcc: bcc@example.test\r\n",
        "In-Reply-To: <prior@example.test>\r\n",
        "References: <prior@example.test>\r\n",
        "Subject: =?UTF-8?B?Q2Fmw6k=?=\r\n",
        "MIME-Version: 1.0\r\n",
        "Content-Type: text/plain; charset=UTF-8\r\n",
        "Content-Transfer-Encoding: base64\r\n\r\n",
        "Q2Fmw6kNCnNlY29uZA0K\r\n",
    );
    assert_eq!(URL_SAFE_NO_PAD.decode(&message.raw).unwrap(), expected.as_bytes());
    assert_eq!(serde_json::to_value(&message).unwrap(), serde_json::json!({
        "raw": URL_SAFE_NO_PAD.encode(expected), "threadId": "thread-1",
    }));
    let mut email = email();
    email.thread_id = None;
    let message = Message::from_snapshot(&email, "<outbound@example.test>", 0).unwrap();
    assert_eq!(serde_json::to_value(&message).unwrap(), serde_json::json!({"raw": message.raw}));
}

#[test]
fn gapplan_14_unit_gmail_requires_exact_sender_and_both_capabilities() {
    let email = email();
    for (sender, send, lookup, allowed) in [
        ("sender@example.test", true, true, true),
        ("other@example.test", true, true, false),
        ("Sender@example.test", true, true, false),
        ("sender@example.test", false, true, false),
        ("sender@example.test", true, false, false),
        ("", true, true, false),
    ] {
        assert_eq!(Account { sender: sender.into(), send, lookup }.permits(&email), allowed);
    }
}

#[test]
fn gapplan_14_unit_gmail_only_settles_definite_provider_outcomes() {
    let response = |status, id: Option<&str>| SendReply::Response { status, id: id.map(str::to_owned) };
    assert!(matches!(Submission::from(response(200, Some("provider-1"))),
        Submission::Accepted(id) if id == "provider-1"));
    assert!(matches!(Submission::from(SendReply::NotSubmitted), Submission::NotSubmitted));
    for reply in [
        response(200, None), response(200, Some("bad id")), response(202, None),
        response(401, None), response(429, None), response(500, None), SendReply::Uncertain,
    ] {
        assert!(matches!(Submission::from(reply), Submission::Reconciliation));
    }
}
