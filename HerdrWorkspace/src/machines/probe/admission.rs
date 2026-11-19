use super::*;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub(crate) enum Reason {
    Uncommissioned,
    PolicyUnavailable,
    EvidenceUnavailable,
    IdentityMismatch,
    InvalidProbe,
    ProjectNotEnrolled,
    MachineOffline,
    Portable,
    LightWorkOnly,
    ProbeMissing,
    ProbeStale,
    UnsupportedReadings,
    DiskStop,
    DiskAdmission,
    WorkDiskNotBacked,
    Ram,
    Swap,
    Load,
    Io,
    HeavySlots,
    ProviderSlots,
    Runtime,
    LoginStale,
    Toolchain,
    Signing,
}

impl Reason {
    pub(crate) fn message(self) -> &'static str {
        match self {
            Self::Uncommissioned => "This server has no enrolled fixture worker.",
            Self::PolicyUnavailable => "The signed worker policy is unavailable.",
            Self::EvidenceUnavailable => "The workspace could not read worker evidence.",
            Self::IdentityMismatch => "The worker identity does not match the signed enrollment.",
            Self::InvalidProbe => "The worker probe has invalid evidence.",
            Self::ProjectNotEnrolled => "The project and folder are not pinned to this worker.",
            Self::MachineOffline => "The project server is offline.",
            Self::Portable => "This MacBook or portable worker is excluded from heavy work.",
            Self::LightWorkOnly => "This worker is enrolled for light work only.",
            Self::ProbeMissing => "No probe has been recorded for this enrollment.",
            Self::ProbeStale => "The last worker probe is stale.",
            Self::UnsupportedReadings => "Required worker readings are unavailable or unsupported.",
            Self::DiskStop => "Disk STOP. Free space is below the hard floor.",
            Self::DiskAdmission => "Disk admission is held at the normal free-space or usage threshold.",
            Self::WorkDiskNotBacked => "The project needs a work directory on a supported disk filesystem.",
            Self::Ram => "Available RAM is at or below the configured minimum.",
            Self::Swap => "Swap usage is at or above the configured limit.",
            Self::Load => "Load is at or above the configured limit.",
            Self::Io => "I/O busy time is at or above the configured limit.",
            Self::HeavySlots => "All heavy work slots are occupied or disabled.",
            Self::ProviderSlots => "The provider has reached its configured concurrency limit.",
            Self::Runtime => "The required runtime or version is unavailable.",
            Self::LoginStale => "Provider login readiness is missing or stale.",
            Self::Toolchain => "The required toolchain is unavailable.",
            Self::Signing => "The worker lacks the required signing capability.",
        }
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum Status {
    Eligible,
    Hold,
    Stop,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(crate) struct DiskEvidence {
    path: String,
    free_bytes: u64,
    limit_bytes: u64,
}

#[derive(Clone, Debug, Serialize)]
pub(crate) struct Admission {
    status: Status,
    reason: Option<Reason>,
    pub message: Option<&'static str>,
    disk: Option<DiskEvidence>,
}

impl Admission {
    fn eligible() -> Self {
        Self { status: Status::Eligible, reason: None, message: None, disk: None }
    }


}

impl From<Reason> for Admission {
    fn from(reason: Reason) -> Self {
        Self { status: Status::Hold, reason: Some(reason), message: Some(reason.message()), disk: None }
    }
}

#[derive(Serialize)]
pub(crate) struct ProjectEvidence {
    pub project_id: i64,
    pub admission: Admission,
}

#[derive(Serialize)]
pub(crate) struct Card {
    worker_id: Option<String>,
    host_fingerprint: Option<String>,
    power_class: Option<PowerClass>,
    workload_class: Option<WorkloadClass>,
    allowed_roots: Vec<String>,
    policy: Option<PolicyRef>,
    thresholds: Option<Thresholds>,
    probe: Option<Report>,
    pub admission: Admission,
    projects: Vec<ProjectEvidence>,
}

impl Card {
    pub(in crate::machines) fn held(reason: Reason) -> Self {
        Self {
            worker_id: None,
            host_fingerprint: None,
            power_class: None,
            workload_class: None,
            allowed_roots: vec![],
            policy: None,
            thresholds: None,
            probe: None,
            admission: reason.into(),
            projects: vec![],
        }
    }

    pub(in crate::machines) fn enrolled(
        machine: &crate::core::Machine,
        enrolled: &Enrollment,
        policy: &PolicyRef,
        projects: &[crate::projects::Project],
        reading: Result<Option<Report>, Reason>,
        now: i64,
    ) -> Self {
        let reading = if enrolled.target != machine.target || machine.via || machine.temporary {
            Err(Reason::IdentityMismatch)
        } else {
            reading
        };
        let for_project = |project: Option<&crate::projects::Project>| match &reading {
            Ok(report) => heavy_admission(
                enrolled,
                report.as_ref(),
                project.and_then(|project| project.worker_pin(enrolled)),
                machine.state == "connected",
                now,
            ),
            Err(reason) => (*reason).into(),
        };
        let evidence: Vec<_> = projects.iter().map(|project| ProjectEvidence {
            project_id: project.id(),
            admission: for_project(Some(project)),
        }).collect();
        let admission = evidence.iter().find(|project| project.admission.status == Status::Stop)
            .or_else(|| evidence.iter().find(|project| project.admission.status == Status::Hold))
            .or_else(|| evidence.first())
            .map_or_else(|| for_project(None), |project| project.admission.clone());
        Self {
            worker_id: Some(enrolled.id.clone()),
            host_fingerprint: Some(enrolled.fingerprint()),
            power_class: Some(enrolled.power_class),
            workload_class: Some(enrolled.workload_class),
            allowed_roots: enrolled.roots.clone(),
            policy: Some(policy.clone()),
            thresholds: Some(enrolled.thresholds.clone()),
            probe: reading.ok().flatten(),
            admission,
            projects: evidence,
        }
    }
}

pub(super) fn heavy_admission(
    worker: &Enrollment,
    report: Option<&Report>,
    project: Option<&ProjectPin>,
    connected: bool,
    now: i64,
) -> Admission {
    let current = fresh_report(worker, report, now);
    if let Ok(report) = current {
        if let Some(disk) = disk_stop(worker, report, project.map(|pin| pin.folder.as_str())) {
            return Admission {
                status: Status::Stop,
                disk: Some(disk),
                ..Admission::from(Reason::DiskStop)
            };
        }
    }
    assess(worker, current, project, connected, now, false)
        .map_or_else(Admission::from, |()| Admission::eligible())
}

pub(crate) fn disk_stop(
    worker: &Enrollment,
    report: &Report,
    workdir: Option<&str>,
) -> Option<DiskEvidence> {
    let mut floor = worker.thresholds.disk_stop_free_bytes;
    if worker.machine == "ovh" || worker.id.eq_ignore_ascii_case("ovh") {
        floor = floor.max(8_000_000_000);
    }
    let work = workdir.and_then(|path| Some((path, report.work_disks.get(path)?)));
    [report.root_disk.as_ref().map(|disk| ("/", disk)), work]
        .into_iter()
        .flatten()
        .find(|(_, disk)| disk.free_bytes < floor)
        .map(|(path, disk)| DiskEvidence {
            path: path.into(), free_bytes: disk.free_bytes, limit_bytes: floor,
        })
}

pub(crate) fn fresh_report<'a>(worker: &Enrollment, report: Option<&'a Report>, now: i64) -> Result<&'a Report, Reason> {
    let report = report.ok_or(Reason::ProbeMissing)?;
    if !(1..=now).contains(&report.observed_ms) || now - report.observed_ms > worker.thresholds.max_probe_age_ms {
        return Err(Reason::ProbeStale);
    }
    if report.platform == Platform::Unsupported {
        return Err(Reason::UnsupportedReadings);
    }
    Ok(report)
}

pub(crate) fn assess(
    worker: &Enrollment,
    current: Result<&Report, Reason>,
    project: Option<&ProjectPin>,
    connected: bool,
    now: i64,
    except_pressure: bool,
) -> Result<(), Reason> {
    use Reason::*;
    let t = &worker.thresholds;
    if worker.power_class == PowerClass::Portable
        || worker.id.eq_ignore_ascii_case("macbook-m4")
        || worker.machine.eq_ignore_ascii_case("macbook-m4")
    {
        return Err(Portable);
    }
    if worker.workload_class == WorkloadClass::LightOnly {
        return Err(LightWorkOnly);
    }
    let project = project.ok_or(ProjectNotEnrolled)?;
    let requirements = &project.requirements;
    if !connected {
        return Err(MachineOffline);
    }
    let report = current?;
    let work = report.work_disks.get(&project.folder);
    let (root, work) = report.root_disk.as_ref().zip(work).ok_or(UnsupportedReadings)?;
    for disk in [root, work] {
        if !disk.supported() {
            return Err(WorkDiskNotBacked);
        }
        if !except_pressure && (disk.free_bytes < t.disk_admit_free_bytes || disk.used_at_least(t.disk_admit_used_bps)) {
            return Err(DiskAdmission);
        }
    }
    let ram = report.ram_available_bytes.ok_or(UnsupportedReadings)?;
    let swap = report.swap_used_bps.ok_or(UnsupportedReadings)?;
    let load = report.load_milli.ok_or(UnsupportedReadings)?;
    let io = report.io_busy_bps.ok_or(UnsupportedReadings)?;
    let heavy = report.heavy_running.ok_or(UnsupportedReadings)?;
    for (blocked, reason) in [
        (!except_pressure && ram <= t.ram_available_bytes, Ram),
        (!except_pressure && swap >= t.swap_used_bps, Swap),
        (!except_pressure && load >= t.load_milli, Load),
        (!except_pressure && io >= t.io_busy_bps, Io),
        (heavy >= t.heavy_slots, HeavySlots),
        (requirements.toolchain.as_deref().is_some_and(|tool| !report.toolchains.contains(tool)), Toolchain),
        (requirements.signing && !report.signing, Signing),
    ] {
        if blocked {
            return Err(reason);
        }
    }
    provider_admission(worker, report, now, requirements)
}

fn provider_admission(
    worker: &Enrollment,
    report: &Report,
    now: i64,
    requirements: &Requirements,
) -> Result<(), Reason> {
    let mut reason = Reason::Runtime;
    for (provider, slots) in &worker.thresholds.provider_slots {
        if requirements.provider.is_some_and(|required| required != *provider) {
            continue;
        }
        let Some(runtime) = report.runtimes.get(provider) else { continue };
        if requirements.runtime_version.as_deref().is_some_and(|version| version != runtime.version) {
            continue;
        }
        if !runtime.ready_ms.is_some_and(|at| now - at <= worker.thresholds.max_readiness_age_ms) {
            reason = Reason::LoginStale;
            continue;
        }
        match report.provider_running.get(provider) {
            Some(running) if running < slots => return Ok(()),
            Some(_) => reason = Reason::ProviderSlots,
            None => reason = Reason::UnsupportedReadings,
        }
    }
    Err(reason)
}
