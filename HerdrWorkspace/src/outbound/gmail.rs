//! Gmail request and receipt contracts. The only transport is the executor fixture.
use super::Email;
use crate::email_drafts::mailbox;
#[cfg(test)]
use crate::email_drafts::{address_header, plain_eml};
#[cfg(test)]
use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use serde::{Deserialize, Serialize};

#[cfg(test)]
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Message {
    pub raw: String,
    #[serde(rename = "threadId", skip_serializing_if = "Option::is_none")]
    pub thread_id: Option<String>,
}

#[cfg(test)]
impl Message {
    pub(crate) fn from_snapshot(email: &Email, message_id: &str, reserved_ms: i64) -> Option<Self> {
        let date = chrono::DateTime::from_timestamp_millis(reserved_ms)?.to_rfc2822();
        let mut headers = format!("Message-ID: {message_id}\r\nDate: {date}\r\n");
        address_header(&mut headers, "From", &email.sender);
        address_header(&mut headers, "To", &email.to.join(", "));
        address_header(&mut headers, "Cc", &email.cc.join(", "));
        address_header(&mut headers, "Bcc", &email.bcc.join(", "));
        if let Some(reply) = &email.in_reply_to {
            address_header(&mut headers, "In-Reply-To", reply);
            address_header(&mut headers, "References", reply);
        }
        Some(Self {
            raw: URL_SAFE_NO_PAD.encode(plain_eml(headers, &email.subject, &email.body)),
            thread_id: email.thread_id.clone(),
        })
    }
}

/// An enrolled account must cover both submission and Sent-folder lookup.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Account {
    pub sender: String,
    pub send: bool,
    pub lookup: bool,
}

impl Account {
    pub(crate) fn permits(&self, email: &Email) -> bool {
        self.send && self.lookup && mailbox(&self.sender) && self.sender == email.sender
    }
}

#[derive(Debug, Deserialize, Serialize)]
pub(crate) enum SendReply {
    // The executor can prove that it never called the provider's send operation.
    NotSubmitted,
    Response { status: u16, id: Option<String> },
    Uncertain,
}

pub(super) enum Submission {
    Accepted(String),
    NotSubmitted,
    Reconciliation,
}

impl From<SendReply> for Submission {
    fn from(reply: SendReply) -> Self {
        match reply {
            SendReply::Response { status: 200, id: Some(id) } if provider_id(&id) => Self::Accepted(id),
            SendReply::NotSubmitted => Self::NotSubmitted,
            _ => Self::Reconciliation,
        }
    }
}

pub(super) fn provider_id(id: &str) -> bool {
    (1..=128).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[cfg(test)]
pub(crate) struct Search {
    pub account: String,
    pub query: String,
    pub label: String,
}

#[cfg(test)]
pub(crate) struct Found {
    pub account: String,
    pub id: String,
    pub sent: bool,
    pub message: Message,
}

#[cfg(test)]
pub(crate) trait Provider {
    fn send(&mut self, account: &str, message: &Message) -> SendReply;
    // An incomplete page or a failed lookup must return an error.
    fn list(&mut self, search: &Search) -> Result<Vec<String>, ()>;
    fn get_raw(&mut self, account: &str, id: &str) -> Result<Found, ()>;
}

#[cfg(test)]
pub(crate) fn find(
    provider: &mut dyn Provider, account: &str, message_id: &str, expected: &Message,
) -> Option<String> {
    let search = Search {
        account: account.into(),
        query: format!("rfc822msgid:{message_id}"),
        label: "SENT".into(),
    };
    let candidates = provider.list(&search).ok()?;
    let [id] = candidates.as_slice() else { return None };
    if !provider_id(id) {
        return None;
    }
    let found = provider.get_raw(account, id).ok()?;
    // Fail closed if the transport cannot read back all reviewed fields, including Bcc.
    (found.account == account && found.id == *id && found.sent
        && found.message.raw == expected.raw
        && expected.thread_id.as_ref().is_none_or(|thread| found.message.thread_id.as_ref() == Some(thread)))
        .then_some(found.id)
}

#[cfg(test)]
mod tests;
