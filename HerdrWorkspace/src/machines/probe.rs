//! Admission evidence for fixture workers. The operator policy pins the identity
//! and project assignment. The worker signs observations under that identity.

pub(crate) mod admission;
mod store;
#[cfg(test)]
pub(crate) mod tests;

pub(super) use admission::{Card, Reason};
pub(super) use store::{latest, quota_accounts};
#[cfg(test)]
pub(crate) use store::{emit, record};
pub(crate) use store::{USAGE, cli};
use crate::fleet_policy::{PolicyRef, principals};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Component, Path},
};

const PROTOCOL: u32 = 1;
const LIMIT: usize = 128 * 1024;
const MAX_PERCENT: u32 = 10_000;

#[derive(Clone, Copy, Debug, Deserialize, Eq, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Provider {
    Claude,
    Codex,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum PowerClass {
    Headless,
    SharedProduction,
    Portable,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum WorkloadClass {
    LightOnly,
    Heavy,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ProjectPin {
    pub id: i64,
    pub created_ms: i64,
    pub folder: String,
    #[serde(default, skip_serializing_if = "Requirements::is_empty")]
    pub requirements: Requirements,
}

#[derive(Clone, Debug, Default, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Requirements {
    pub provider: Option<Provider>,
    pub runtime_version: Option<String>,
    pub toolchain: Option<String>,
    #[serde(default)]
    pub signing: bool,
}

impl Requirements {
    fn is_empty(&self) -> bool {
        self == &Self::default()
    }

    fn valid(&self) -> bool {
        self.runtime_version.as_deref().is_none_or(label)
            && self.toolchain.as_deref().is_none_or(label)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Enrollment {
    pub id: String,
    pub machine: String,
    pub target: String,
    pub host_public_key: String,
    pub roots: Vec<String>,
    pub projects: Vec<ProjectPin>,
    pub power_class: PowerClass,
    pub workload_class: WorkloadClass,
    pub accounts: BTreeMap<Provider, String>,
    pub thresholds: Thresholds,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Thresholds {
    pub max_probe_age_ms: i64,
    pub max_readiness_age_ms: i64,
    pub disk_stop_free_bytes: u64,
    pub disk_admit_free_bytes: u64,
    pub disk_admit_used_bps: u32,
    pub ram_available_bytes: u64,
    pub swap_used_bps: u32,
    pub load_milli: u32,
    pub io_busy_bps: u32,
    pub heavy_slots: u16,
    pub provider_slots: BTreeMap<Provider, u16>,
}

impl Thresholds {
    fn valid(&self) -> bool {
        self.max_probe_age_ms > 0
            && self.max_readiness_age_ms > 0
            && self.disk_stop_free_bytes > 0
            && self.disk_admit_free_bytes >= self.disk_stop_free_bytes
            && self.disk_admit_free_bytes <= i64::MAX as u64
            && [self.disk_admit_used_bps, self.swap_used_bps, self.io_busy_bps]
                .into_iter().all(|value| (1..=MAX_PERCENT).contains(&value))
            && self.ram_available_bytes > 0
            && self.load_milli > 0
            && self.provider_slots.values().all(|slots| *slots > 0)
    }
}

fn label(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

fn absolute_path(value: &str) -> bool {
    let path = Path::new(value);
    value.len() <= 4096
        && !value.chars().any(char::is_control)
        && path.is_absolute()
        && path.components().all(|part| matches!(part, Component::RootDir | Component::Normal(_)))
        && (value == "/" || value[1..].split('/').all(|part| !matches!(part, "" | "." | "..")))
}

fn within(path: &str, root: &str) -> bool {
    Path::new(path).starts_with(root)
}

impl Enrollment {
    fn key(&self) -> Option<[u8; 32]> {
        STANDARD.decode(&self.host_public_key).ok()?.try_into().ok()
    }

    pub(crate) fn fingerprint(&self) -> String {
        // Enrollment validation has already checked the key.
        let key = self.key().expect("validated worker key");
        format!("SHA256:{}", base64::engine::general_purpose::STANDARD_NO_PAD.encode(Sha256::digest(key)))
    }

    fn valid(&self) -> bool {
        label(&self.id)
            && crate::core::valid_name(&self.machine)
            && !self.target.is_empty()
            && self.target.len() <= 254
            && !self.target.chars().any(char::is_whitespace)
            && !self.target.chars().any(char::is_control)
            && self.key().is_some()
            && !self.roots.is_empty()
            && self.roots.iter().all(|path| absolute_path(path))
            && self.projects.iter().all(|project| {
                project.id > 0 && project.created_ms > 0 && absolute_path(&project.folder)
                    && project.requirements.valid()
                    && self.roots.iter().any(|root| within(&project.folder, root))
            })
            && self.accounts.values().all(|account| label(account))
            && self.thresholds.provider_slots.keys().all(|provider| self.accounts.contains_key(provider))
            && self.thresholds.valid()
    }
}

pub(crate) fn valid_enrollments(workers: &[Enrollment]) -> bool {
    let mut ids = BTreeSet::new();
    let mut machines = BTreeSet::new();
    let mut targets = BTreeSet::new();
    let mut keys = BTreeSet::new();
    let mut projects = BTreeSet::new();
    workers.iter().all(|worker| {
        worker.valid()
            && ids.insert(&worker.id)
            && machines.insert(worker.machine.to_ascii_lowercase())
            && targets.insert(&worker.target)
            && keys.insert(worker.key())
            && worker.projects.iter().all(|project| projects.insert(project.id))
    })
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct SignedProbe {
    pub report: Report,
    pub signature: String,
}

#[derive(Clone, Copy, Debug, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Platform {
    Darwin,
    Linux,
    Unsupported,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Disk {
    pub filesystem: String,
    pub free_bytes: u64,
    pub used_bytes: u64,
}

impl Disk {
    fn valid(&self) -> bool {
        label(&self.filesystem)
            && self.free_bytes.checked_add(self.used_bytes)
                .is_some_and(|total| (1..=i64::MAX as u64).contains(&total))
    }

    pub(crate) fn supported(&self) -> bool {
        matches!(self.filesystem.as_str(), "apfs" | "hfs" | "ext4" | "xfs" | "btrfs" | "zfs" | "ufs")
    }

    fn used_at_least(&self, bps: u32) -> bool {
        u128::from(self.used_bytes) * u128::from(MAX_PERCENT)
            >= (u128::from(self.used_bytes) + u128::from(self.free_bytes)) * u128::from(bps)
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Runtime {
    pub version: String,
    pub ready_ms: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Report {
    pub protocol: u32,
    pub workspace: String,
    pub policy: PolicyRef,
    pub worker_id: String,
    pub observed_ms: i64,
    pub platform: Platform,
    pub root_disk: Option<Disk>,
    pub work_disks: BTreeMap<String, Disk>,
    pub ram_available_bytes: Option<u64>,
    pub swap_used_bps: Option<u32>,
    pub load_milli: Option<u32>,
    pub io_busy_bps: Option<u32>,
    pub heavy_running: Option<u16>,
    pub provider_running: BTreeMap<Provider, u16>,
    pub runtimes: BTreeMap<Provider, Runtime>,
    pub toolchains: BTreeSet<String>,
    pub signing: bool,
}

impl Report {
    fn valid(&self) -> bool {
        self.protocol == PROTOCOL
            && principals::identifier(&self.workspace)
            && self.policy.valid()
            && label(&self.worker_id)
            && self.observed_ms > 0
            && self.root_disk.as_ref().is_none_or(Disk::valid)
            && self.work_disks.iter().all(|(path, disk)| absolute_path(path) && disk.valid())
            && [self.swap_used_bps, self.io_busy_bps].into_iter().flatten().all(|n| n <= MAX_PERCENT)
            && self.runtimes.values().all(|runtime| {
                label(&runtime.version) && runtime.ready_ms.is_none_or(|ms| (1..=self.observed_ms).contains(&ms))
            })
            && self.toolchains.iter().all(|name| label(name))
    }

    fn canonical(&self) -> Result<Vec<u8>, Reason> {
        if !self.valid() {
            return Err(Reason::InvalidProbe);
        }
        let mut bytes = b"swarmhub/fixture-worker-probe/v1\0".to_vec();
        bytes.extend(serde_json::to_vec(self).map_err(|_| Reason::InvalidProbe)?);
        Ok(bytes)
    }
}

impl SignedProbe {
    pub(crate) fn verify(&self, workspace: &str, policy: &PolicyRef, worker: &Enrollment) -> Result<(), Reason> {
        if self.report.workspace != workspace || &self.report.policy != policy || self.report.worker_id != worker.id {
            return Err(Reason::IdentityMismatch);
        }
        if self.report.work_disks.keys().any(|path| !worker.projects.iter().any(|project| &project.folder == path)) {
            return Err(Reason::InvalidProbe);
        }
        let key = worker.key().ok_or(Reason::IdentityMismatch)?;
        let signature = STANDARD.decode(&self.signature).map_err(|_| Reason::IdentityMismatch)?;
        UnparsedPublicKey::new(&ED25519, key)
            .verify(&self.report.canonical()?, &signature)
            .map_err(|_| Reason::IdentityMismatch)
    }
}
