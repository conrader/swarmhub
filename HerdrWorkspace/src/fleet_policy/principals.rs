//! Signed evidence binds a decision to a workspace, purpose, principal and immutable target.

use super::{Error, PolicyRef};
use crate::bots::{self, Who};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use ring::signature::{ED25519, UnparsedPublicKey};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Actor {
    Operator,
    Bot { id: String },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Principal {
    Operator,
    Bot { id: String, launch: String },
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Purpose {
    PublishPolicy,
    Execute,
    AutoExecute,
    Supersede,
    Release,
    Hold,
    Deny,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ParkPin {
    pub id: String,
    pub revision: String,
    pub manifest_digest: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Target {
    Policy {
        policy: PolicyRef,
    },
    Park {
        park: ParkPin,
        policy: PolicyRef,
    },
    Supersession {
        park: ParkPin,
        policy: PolicyRef,
        replacement: ParkPin,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Envelope {
    pub workspace: String,
    pub principal: Principal,
    pub purpose: Purpose,
    pub target: Target,
    pub nonce: String,
    pub issued_ms: i64,
    pub expires_ms: i64,
}

impl Envelope {
    /// Fixed field order, UTF-8, domain prefix, and no trailing newline.
    pub(super) fn canonical(&self) -> Result<Vec<u8>, Error> {
        if !identifier(&self.workspace)
            || !identifier(&self.nonce)
            || !interval(self.issued_ms, self.expires_ms)
        {
            return Err(Error::Invalid);
        }
        match (&self.principal, self.purpose, &self.target) {
            (Principal::Operator, Purpose::PublishPolicy, Target::Policy { policy })
                if policy.valid() => {}
            (Principal::Operator, Purpose::Execute | Purpose::Hold | Purpose::Release | Purpose::Deny, Target::Park { park, policy })
                if park.valid() && policy.valid() => {}
            (Principal::Operator, Purpose::Supersede, Target::Supersession { park, policy, replacement })
                if park.valid() && policy.valid() && replacement.valid() && park.id != replacement.id => {}
            (Principal::Bot { id, launch }, Purpose::Execute | Purpose::AutoExecute, Target::Park { park, policy })
                if bots::valid_id(id) && hex(launch, 32) && park.valid() && policy.valid() => {}
            _ => return Err(Error::Invalid),
        }
        let mut bytes = b"swarmhub-fleet-decision-v1\n".to_vec();
        serde_json::to_writer(&mut bytes, self).map_err(|_| Error::Invalid)?;
        Ok(bytes)
    }
}

impl ParkPin {
    pub(super) fn valid(&self) -> bool {
        text(&self.id) && text(&self.revision) && hex(&self.manifest_digest, 64)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Signed {
    pub envelope: Envelope,
    pub signature: String,
}

impl Signed {
    pub(super) fn verify(
        &self,
        key: &[u8; 32],
        workspace: &str,
        now: i64,
    ) -> Result<(), Error> {
        let payload = self.envelope.canonical()?;
        if self.envelope.workspace != workspace {
            return Err(Error::Binding);
        }
        let signature = STANDARD.decode(&self.signature).map_err(|_| Error::Signature)?;
        UnparsedPublicKey::new(&ED25519, key)
            .verify(&payload, &signature)
            .map_err(|_| Error::Signature)?;
        if !(self.envelope.issued_ms..self.envelope.expires_ms).contains(&now) {
            return Err(Error::Expired);
        }
        Ok(())
    }
}

/// A session label is a routing hint. It must agree with the signed launch and the
/// current registry binding, and helpers never inherit the parent bot's authority.
pub(super) fn registered_bot(
    db: &Connection,
    launch: &str,
    signed: &Principal,
) -> Result<Actor, Error> {
    let Principal::Bot { id, launch: signed_launch } = signed else {
        return Err(Error::Principal);
    };
    if launch != signed_launch {
        return Err(Error::Principal);
    }
    match bots::of_launch(db, launch)? {
        Who::Bot(bot) if bot.id == *id && bot.noted_launch.as_deref() == Some(launch) => {
            Ok(Actor::Bot { id: bot.id })
        }
        _ => Err(Error::Principal),
    }
}

pub(crate) fn identifier(value: &str) -> bool {
    (1..=128).contains(&value.len())
        && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

pub(super) fn text(value: &str) -> bool {
    !value.trim().is_empty() && value.len() <= 512 && !value.chars().any(char::is_control)
}

pub(crate) fn hex(value: &str, length: usize) -> bool {
    value.len() == length && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

pub(super) fn interval(start: i64, end: i64) -> bool {
    start >= 0 && start < end
}
