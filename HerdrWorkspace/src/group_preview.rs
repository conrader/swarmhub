//! A transient group preview is keyed by the exact authenticated delivery.
use crate::{
    groups::DRAFT_BYTES,
    history::{History, StoreError},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use ring::hmac;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};

const MAX_ACTIVE: usize = 64;
const LIFETIME: Duration = Duration::from_secs(120);
const DOMAIN: &[u8] = b"swarmhub-opencode-group-preview-v1\0";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Binding {
    pub delivery: i64,
    proof: String,
}

impl Binding {
    pub fn new(launch: &str, delivery: i64, token: &str) -> Option<Self> {
        let (key, data) = Self::material(launch, delivery, token)?;
        let proof = URL_SAFE_NO_PAD.encode(hmac::sign(&key, &data).as_ref());
        Some(Self { delivery, proof })
    }

    fn material(launch: &str, delivery: i64, token: &str) -> Option<(hmac::Key, Vec<u8>)> {
        if delivery <= 0
            || launch.len() != 32
            || !launch.bytes().all(|byte| byte.is_ascii_hexdigit())
            || token.len() != 32
            || !token.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return None;
        }
        let key = hmac::Key::new(hmac::HMAC_SHA256, token.as_bytes());
        let mut data = DOMAIN.to_vec();
        data.extend_from_slice(launch.as_bytes());
        data.extend_from_slice(&delivery.to_be_bytes());
        Some((key, data))
    }

    pub fn valid_shape(&self) -> bool {
        self.delivery > 0
            && self.proof.len() == 43
            && self
                .proof
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
    }

    fn valid(&self, launch: &str, token: &str) -> bool {
        let Some((key, data)) = Self::material(launch, self.delivery, token) else {
            return false;
        };
        URL_SAFE_NO_PAD
            .decode(&self.proof)
            .is_ok_and(|proof| hmac::verify(&key, &data, &proof).is_ok())
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Update {
    pub key: String,
    pub group_preview: Binding,
    pub draft_id: String,
    pub draft_text: String,
}

impl Update {
    pub fn valid(&self) -> bool {
        self.group_preview.valid_shape()
            && self.key.len() == 32
            && self.key.bytes().all(|byte| byte.is_ascii_hexdigit())
            && crate::opencode_agent::valid_reply_id(&self.draft_id)
            && !self.draft_text.trim().is_empty()
            && self.draft_text.len() <= DRAFT_BYTES
    }
}

struct Target {
    group: i64,
    task_id: i64,
    author: String,
    task: String,
    token: String,
}

fn target(
    history: &History,
    delivery: i64,
    launch: &str,
    group: Option<i64>,
) -> Result<Option<Target>, StoreError> {
    Ok(history.db()?.query_row(
        "SELECT task.group_id, task.id, d.name, substr(task.text, 1, 160), d.token
         FROM group_deliveries d
         JOIN group_messages task ON task.id=d.message_id
         JOIN group_members member ON member.group_id=task.group_id
          AND member.address=d.address AND member.created_ms=d.created_ms AND member.launch_key=d.launch_key
         WHERE d.id=?1 AND d.launch_key=?2 AND (?3 IS NULL OR task.group_id=?3)
          AND d.state!='not_sent' AND NOT EXISTS(SELECT 1 FROM group_messages reply WHERE reply.delivery_id=d.id)",
        params![delivery, launch, group],
        |row| Ok(Target { group: row.get(0)?, task_id: row.get(1)?, author: row.get(2)?, task: row.get(3)?, token: row.get(4)? }),
    ).optional()?)
}

pub(crate) fn group(history: &History, launch: &str, binding: &Binding) -> Option<i64> {
    target(history, binding.delivery, launch, None)
        .ok()
        .flatten()
        .filter(|target| binding.valid(launch, &target.token))
        .map(|target| target.group)
}

#[derive(Clone)]
struct Entry {
    source: u64,
    launch: String,
    group: i64,
    updated: Instant,
    text: String,
}

#[derive(Default)]
pub(crate) struct Previews(HashMap<i64, Entry>);

#[derive(Serialize)]
pub struct Draft {
    pub delivery_id: i64,
    pub task_id: i64,
    pub author: String,
    pub task: String,
    pub text: String,
}

impl Previews {
    pub fn update(&mut self, group: i64, source: u64, update: Update) {
        self.0.retain(|_, entry| entry.updated.elapsed() < LIFETIME);
        let delivery = update.group_preview.delivery;
        if self
            .0
            .get(&delivery)
            .is_some_and(|entry| entry.source > source)
            || !self.0.contains_key(&delivery) && self.0.len() >= MAX_ACTIVE
        {
            return;
        }
        self.0.insert(
            delivery,
            Entry {
                source,
                launch: update.key,
                group,
                updated: Instant::now(),
                text: update.draft_text,
            },
        );
    }

    pub fn close(&mut self, delivery: i64, source: u64) {
        if self
            .0
            .get(&delivery)
            .is_some_and(|entry| entry.source == source)
        {
            self.0.remove(&delivery);
        }
    }

    pub fn snapshot(&self, group: i64) -> Vec<(i64, String, String)> {
        self.0
            .iter()
            .filter(|(_, entry)| entry.group == group && entry.updated.elapsed() < LIFETIME)
            .map(|(delivery, entry)| (*delivery, entry.launch.clone(), entry.text.clone()))
            .collect()
    }
}

pub(crate) fn feed(
    history: &History,
    group: i64,
    mut entries: Vec<(i64, String, String)>,
) -> Result<Vec<Draft>, StoreError> {
    entries.sort_by_key(|(delivery, _, _)| *delivery);
    let mut drafts = Vec::new();
    for (delivery_id, launch, text) in entries {
        if let Some(target) = target(history, delivery_id, &launch, Some(group))? {
            drafts.push(Draft {
                delivery_id,
                task_id: target.task_id,
                author: target.author,
                task: target.task,
                text,
            });
        }
    }
    Ok(drafts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_preview_proof_binds_the_launch_delivery_and_reply_authority() {
        const LAUNCH: &str = "00112233445566778899aabbccddeeff";
        const TOKEN: &str = "ffeeddccbbaa99887766554433221100";
        let mut marker = Binding::new(LAUNCH, 7, TOKEN).unwrap();
        assert!(marker.valid_shape() && marker.valid(LAUNCH, TOKEN));
        assert!(!marker.valid(TOKEN, LAUNCH));
        assert!(!marker.valid(LAUNCH, LAUNCH));
        marker.delivery += 1;
        assert!(!marker.valid(LAUNCH, TOKEN));
    }
}
