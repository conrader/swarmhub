//! Worker-side admission from protected policy and local fixture captures.

use super::{Result, Worker, store::private_file};
use crate::{
    fleet_policy::{Authority, Error as PolicyError, PolicyRef, Role, WorkerDecision},
    history,
    machines::probe::{
        Provider, SignedProbe,
        admission::{self, DiskEvidence, Reason},
    },
};
use rustix::fs::{Mode, OFlags, openat};
use serde::{Deserialize, Serialize};
use std::{
    fs::File,
    io::Read,
    os::{fd::AsRawFd, unix::fs::MetadataExt},
    path::{Component, Path, PathBuf},
};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Manifest {
    pub project_id: i64,
    pub project_created_ms: i64,
    pub workdir: String,
    pub owner_bot_id: String,
    pub provider: Provider,
    pub requested_model: Option<String>,
    pub requested_effort: Option<String>,
}

impl Manifest {
    pub(super) fn valid(&self) -> bool {
        self.project_id > 0
            && self.project_created_ms > 0
            && Path::new(&self.workdir).is_absolute()
            && !self.workdir.chars().any(char::is_control)
            && crate::bots::valid_id(&self.owner_bot_id)
            && [&self.requested_model, &self.requested_effort].into_iter().flatten()
                .all(|value| !value.trim().is_empty() && value.len() <= 128 && !value.chars().any(char::is_control))
    }
}

#[derive(Debug, Default, Deserialize, Serialize)]
pub(super) struct RuntimeReceipt {
    pub provider: Option<Provider>,
    pub account_ref: Option<String>,
    pub observed_model: Option<String>,
    pub observed_family: Option<String>,
    pub observed_effort: Option<String>,
    pub cli_version: Option<String>,
    pub verdict: Option<String>,
    pub result_digest: Option<String>,
}

#[derive(Debug, Deserialize, Serialize)]
pub(super) struct Exception {
    pub rule_id: String,
    pub decision_ref: String,
    pub expires_ms: i64,
}

#[derive(Debug)]
pub(super) struct Grant {
    pub policy: PolicyRef,
    pub heartbeat_deadline: i64,
    pub exception: Option<Exception>,
    pub heavy_slots: u16,
    pub provider_slots: u16,
    pub account_ref: String,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum Disposition {
    Queued,
    Held,
    Stopped,
}

impl Disposition {
    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Queued => "queued",
            Self::Held => "held",
            Self::Stopped => "stopped",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(super) struct Blocker {
    pub disposition: Disposition,
    pub reason: String,
    pub disk: Option<DiskEvidence>,
}

impl Blocker {
    pub(super) fn hold(reason: &str) -> Self {
        Self { disposition: Disposition::Held, reason: reason.into(), disk: None }
    }

    pub(super) fn queue(reason: &str) -> Self {
        Self { disposition: Disposition::Queued, ..Self::hold(reason) }
    }

    pub(super) fn stop(reason: &str) -> Self {
        Self { disposition: Disposition::Stopped, ..Self::hold(reason) }
    }

    fn disk_stop(disk: DiskEvidence) -> Self {
        Self { disk: Some(disk), ..Self::stop("disk_stop") }
    }

    fn from_probe(reason: Reason) -> Self {
        let name = serde_json::to_value(reason).expect("probe reason is serializable");
        let name = name.as_str().expect("probe reason is a string");
        match reason {
            Reason::HeavySlots | Reason::ProviderSlots => Self::queue(name),
            _ => Self::hold(name),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Configuration {
    policy_dir: PathBuf,
    workspace: String,
    operator_uid: u32,
}

pub(super) struct Admission {
    authority: Authority,
    root: PathBuf,
}

impl Admission {
    pub(super) fn open(root: &Path) -> Result<Self> {
        let config: Configuration = read_local(root, "admission.json", 4096)?;
        #[cfg(test)]
        let authority = Authority::fixture(&config.policy_dir, &config.workspace);
        #[cfg(not(test))]
        let authority = Authority::enrolled(config.policy_dir, config.workspace, config.operator_uid, Role::Bridge)?;
        #[cfg(test)]
        let _ = (config.operator_uid, Role::Bridge);
        Ok(Self { root: root.into(), authority })
    }

    pub(super) fn check(
        &self,
        identity: &Worker,
        job_id: &str,
        manifest: &Manifest,
        running: Option<&PolicyRef>,
    ) -> std::result::Result<(Grant, File), Blocker> {
        let outcome = self.authority.with_worker_policy(|workspace, reference, policy, heartbeat| {
            let now = history::now();
            if running.is_some_and(|expected| expected != reference) {
                return Err(Blocker::stop("policy_changed"));
            }
            let worker = policy.workers.iter().find(|worker| {
                worker.id == identity.id && worker.fingerprint() == identity.host_fingerprint
            }).ok_or_else(|| Blocker::hold("identity_mismatch"))?;
            let project = worker.projects.iter().find(|project| {
                project.id == manifest.project_id && project.created_ms == manifest.project_created_ms
            }).ok_or_else(|| Blocker::hold("project_not_enrolled"))?;
            let probe = (|| {
                let probe: SignedProbe = read_local(&self.root, "probe.json", 128 * 1024)
                    .map_err(|_| Blocker::hold("probe_missing"))?;
                probe.verify(workspace, reference, worker).map_err(Blocker::from_probe)?;
                admission::fresh_report(worker, Some(&probe.report), now).map_err(Blocker::from_probe)?;
                Ok::<_, Blocker>(probe)
            })();

            // A hard floor yields disk evidence even when that filesystem is unsupported.
            if let Ok(probe) = &probe
                && let Some(disk) = admission::disk_stop(worker, &probe.report, Some(&project.folder))
            {
                return Err(Blocker::disk_stop(disk));
            }
            let heartbeat_deadline = heartbeat.filter(|&deadline| now < deadline)
                .ok_or_else(|| Blocker::stop("policy_heartbeat_lost"))?;
            let probe = probe?;
            let report = &probe.report;
            let rule = match policy.worker_decision(job_id, project.id, &manifest.owner_bot_id, now) {
                WorkerDecision::Stop => return Err(Blocker::stop("policy_stop")),
                WorkerDecision::Hold => return Err(Blocker::hold("owner_signoff")),
                WorkerDecision::Admit(rule) => rule,
            };
            let directory = work_directory(&manifest.workdir, &project.folder, &worker.roots)?;
            let work = report.work_disks.get(&project.folder);
            let (root, work) = report.root_disk.as_ref().zip(work)
                .ok_or_else(|| Blocker::hold("unsupported_readings"))?;
            if !root.supported() || !work.supported() {
                return Err(Blocker::hold("work_disk_not_backed"));
            }

            let account_ref = worker.accounts.get(&manifest.provider)
                .ok_or_else(|| Blocker::hold("runtime"))?.clone();
            let provider_slots = *worker.thresholds.provider_slots.get(&manifest.provider)
                .ok_or_else(|| Blocker::hold("runtime"))?;
            let mut exception = None;
            if running.is_none() {
                let mut project = project.clone();
                if project.requirements.provider.is_some_and(|provider| provider != manifest.provider) {
                    return Err(Blocker::hold("runtime"));
                }
                project.requirements.provider = Some(manifest.provider);
                let assess = |except| admission::assess(worker, Ok(report), Some(&project), true, now, except);
                let normal = assess(false);
                match (normal, rule) {
                    (Err(Reason::DiskAdmission | Reason::Ram | Reason::Swap | Reason::Load | Reason::Io), Some(rule)) => {
                        assess(true).map_err(Blocker::from_probe)?;
                        exception = Some(Exception {
                            rule_id: rule.id.clone(),
                            decision_ref: rule.decision_ref.clone(),
                            expires_ms: rule.expires_ms,
                        });
                    }
                    (result, _) => result.map_err(Blocker::from_probe)?,
                }
            }
            Ok((Grant {
                policy: reference.clone(),
                heartbeat_deadline,
                exception,
                heavy_slots: worker.thresholds.heavy_slots,
                provider_slots,
                account_ref,
            }, directory))
        });
        let outcome = match outcome {
            Ok(outcome) => outcome,
            Err(PolicyError::Busy) => Err(Blocker::hold("policy_busy")),
            Err(_) if running.is_some() => Err(Blocker::stop("policy_heartbeat_lost")),
            Err(_) => Err(Blocker::hold("policy_unavailable")),
        };
        outcome.map_err(|blocker| {
            if running.is_some() {
                Blocker { disposition: Disposition::Stopped, ..blocker }
            } else {
                blocker
            }
        })
    }
}

pub(super) fn same_directory(left: &File, right: &File) -> bool {
    left.metadata().ok().zip(right.metadata().ok())
        .is_some_and(|(left, right)| (left.dev(), left.ino()) == (right.dev(), right.ino()))
}

fn work_directory(request: &str, project: &str, roots: &[String]) -> std::result::Result<File, Blocker> {
    let unsafe_path = |path: &Path| path.starts_with("/dev/shm");
    let requested = Path::new(request);
    if unsafe_path(requested) {
        return Err(Blocker::hold("work_disk_not_backed"));
    }
    let resolved = requested.canonicalize().map_err(|_| Blocker::hold("workdir_unavailable"))?;
    if unsafe_path(&resolved) {
        return Err(Blocker::hold("work_disk_not_backed"));
    }
    if resolved != Path::new(project) || !roots.iter().any(|root| resolved.starts_with(root)) {
        return Err(Blocker::hold("project_not_enrolled"));
    }
    let unavailable = |_| Blocker::hold("workdir_unavailable");
    let mut dir = File::open("/").map_err(|_| Blocker::hold("workdir_unavailable"))?;
    let flags = OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC;
    // Walk the canonical path without following a link inserted after resolution.
    for component in resolved.components() {
        if let Component::Normal(name) = component {
            dir = File::from(openat(&dir, name, flags, Mode::empty()).map_err(unavailable)?);
        }
    }
    match ram_backed(&dir) {
        Some(false) => Ok(dir),
        Some(true) => Err(Blocker::hold("work_disk_not_backed")),
        None => Err(Blocker::hold("workdir_unavailable")),
    }
}

fn ram_backed(dir: &File) -> Option<bool> {
    let mut stat = std::mem::MaybeUninit::<libc::statfs>::uninit();
    // SAFETY: fstatfs writes a statfs value to the supplied pointer on success.
    if unsafe { libc::fstatfs(dir.as_raw_fd(), stat.as_mut_ptr()) } != 0 {
        return None;
    }
    let stat = unsafe { stat.assume_init() };
    #[cfg(target_os = "macos")]
    {
        // SAFETY: Darwin fills f_fstypename with a NUL-terminated name.
        let name = unsafe { std::ffi::CStr::from_ptr(stat.f_fstypename.as_ptr()) }.to_bytes();
        Some(matches!(name, b"tmpfs" | b"ramfs"))
    }
    #[cfg(target_os = "linux")]
    {
        const RAMFS_MAGIC: libc::c_long = 0x8584_58f6;
        Some(matches!(stat.f_type, libc::TMPFS_MAGIC | RAMFS_MAGIC))
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    {
        let _ = stat;
        None
    }
}

fn read_local<T: serde::de::DeserializeOwned>(root: &Path, name: &str, limit: u64) -> Result<T> {
    // SAFETY: geteuid has no memory preconditions.
    let file = private_file(&root.join(name), unsafe { libc::geteuid() }, false)?;
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err("Worker admission file exceeds its size limit.".into());
    }
    Ok(serde_json::from_slice(&bytes)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        fleet_policy::{Rule, RuleKind, Scope},
        job_worker::tests::Inputs,
        machines::probe::tests::GB,
    };

    fn manifest(inputs: &Inputs) -> Manifest {
        serde_json::from_value(inputs.started_request("one-job", 1)["manifest"].clone()).unwrap()
    }

    fn check(inputs: &Inputs, root: &Path, job_id: &str) -> std::result::Result<Grant, Blocker> {
        let identity = serde_json::from_value(inputs.identity.clone()).unwrap();
        Admission::open(root).unwrap().check(&identity, job_id, &manifest(inputs), None)
            .map(|(grant, _)| grant)
    }

    fn exception(expires_ms: i64) -> Rule {
        Rule {
            id: "pressure-for-one-job".into(),
            scope: Scope {
                action: Some("start_heavy_job".into()),
                project: Some("1".into()),
                owner: Some("fixture-owner".into()),
                ..Scope::default()
            },
            decision_ref: "approved-fixture-exception".into(),
            effective_ms: 1,
            expires_ms,
            rule: RuleKind::WorkerException { job_id: "one-job".into() },
        }
    }

    #[test]
    fn gapplan_08_unit_admission_queues_capacity_and_stops_on_the_floor() {
        let root = tempfile::tempdir().unwrap();
        let inputs = Inputs::new(root.path(), "ovh", vec![]);
        let mut report = inputs.report();
        report.heavy_running = Some(inputs.enrollment.thresholds.heavy_slots);
        inputs.update(report.clone());
        let queued = check(&inputs, root.path(), "one-job").unwrap_err();
        assert_eq!(queued.disposition.as_str(), "queued");
        assert_eq!(queued.reason, "heavy_slots");
        report.root_disk.as_mut().unwrap().free_bytes = 8 * GB - 1;
        report.root_disk.as_mut().unwrap().filesystem = "unknown".into();
        inputs.update(report);
        let stop = check(&inputs, root.path(), "one-job").unwrap_err();
        assert_eq!(stop.disposition.as_str(), "stopped");
        assert_eq!(stop.reason, "disk_stop");
        assert!(stop.disk.is_some());
    }

    #[test]
    fn gapplan_08_unit_exception_covers_one_job_and_cannot_bypass_hard_rules() {
        let root = tempfile::tempdir().unwrap();
        let inputs = Inputs::new(root.path(), "ovh", vec![exception(history::now() + 60_000)]);
        let mut report = inputs.report();
        report.load_milli = Some(inputs.enrollment.thresholds.load_milli);
        inputs.update(report.clone());
        let grant = check(&inputs, root.path(), "one-job").unwrap();
        assert_eq!(grant.exception.unwrap().rule_id, "pressure-for-one-job");
        assert_eq!(check(&inputs, root.path(), "other-job").unwrap_err().reason, "load");
        report.root_disk.as_mut().unwrap().free_bytes = 8 * GB - 1;
        inputs.update(report);
        assert_eq!(check(&inputs, root.path(), "one-job").unwrap_err().reason, "disk_stop");

        let root = tempfile::tempdir().unwrap();
        let portable = Inputs::new(root.path(), "macbook-m4", vec![exception(history::now() + 60_000)]);
        assert_eq!(check(&portable, root.path(), "one-job").unwrap_err().reason, "portable");
    }

    #[test]
    fn gapplan_08_unit_expired_exception_and_policy_heartbeat_cannot_grant_capacity() {
        let root = tempfile::tempdir().unwrap();
        let inputs = Inputs::new(root.path(), "ovh", vec![exception(history::now())]);
        let mut report = inputs.report();
        report.load_milli = Some(inputs.enrollment.thresholds.load_milli);
        inputs.update(report);
        assert_eq!(check(&inputs, root.path(), "one-job").unwrap_err().reason, "load");
        inputs.heartbeat(history::now() - 1);
        assert_eq!(check(&inputs, root.path(), "one-job").unwrap_err().reason, "policy_heartbeat_lost");
    }
}
