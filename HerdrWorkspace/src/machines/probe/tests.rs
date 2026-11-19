use super::{admission::heavy_admission, *};
use ring::{rand::SystemRandom, signature::{Ed25519KeyPair, KeyPair}};

pub(crate) const FOLDER: &str = "/fixture/work/project";
pub(crate) const GB: u64 = 1_000_000_000;
const GIB: u64 = 1 << 30;
// 2026-11-19T12:00:00Z. Limits follow the dated Nov 10–19 fleet decisions.
pub(crate) const OBSERVED: i64 = 1_795_089_600_000;

pub(crate) fn key() -> Ed25519KeyPair {
    let document = Ed25519KeyPair::generate_pkcs8(&SystemRandom::new()).unwrap();
    Ed25519KeyPair::from_pkcs8(document.as_ref()).unwrap()
}

pub(crate) fn signed(report: Report, key: &Ed25519KeyPair) -> SignedProbe {
    let signature = STANDARD.encode(key.sign(&report.canonical().unwrap()).as_ref());
    SignedProbe { report, signature }
}

pub(crate) fn enrolled(machine: &str, id: i64, key: &Ed25519KeyPair) -> Enrollment {
    let (power_class, ram_available_bytes, load_milli, heavy_slots, provider_slots) = match machine {
        "ovh" => (PowerClass::SharedProduction, 3 * GIB, 10_000, 2, 2),
        "dmt" => (PowerClass::SharedProduction, 4 * GIB, 16_000, 2, 2),
        "box" => (PowerClass::Headless, 3 * GIB, 10_000, 4, 3),
        "mini-m4" => (PowerClass::Headless, 4 * GIB, 10_000, 1, 1),
        "macbook-m4" => (PowerClass::Portable, 4 * GIB, 10_000, 1, 1),
        _ => panic!("unrecognized dated fixture"),
    };
    Enrollment {
        id: format!("fixture-{machine}"),
        machine: machine.into(),
        target: format!("fixture@{machine}.invalid"),
        host_public_key: STANDARD.encode(key.public_key()),
        roots: vec!["/fixture/work".into()],
        projects: vec![ProjectPin { id, created_ms: OBSERVED, folder: FOLDER.into(), requirements: Requirements::default() }],
        power_class,
        workload_class: if power_class == PowerClass::Portable { WorkloadClass::LightOnly } else { WorkloadClass::Heavy },
        accounts: BTreeMap::from([(Provider::Codex, "fixture-shared-account".into())]),
        thresholds: Thresholds {
            max_probe_age_ms: 60_000,
            max_readiness_age_ms: 300_000,
            disk_stop_free_bytes: 8 * GB,
            disk_admit_free_bytes: 10 * GB,
            disk_admit_used_bps: 9000,
            ram_available_bytes,
            swap_used_bps: 9000,
            load_milli,
            io_busy_bps: 8000, // Synthetic cutoff for the I/O hold fixture.
            heavy_slots,
            provider_slots: BTreeMap::from([(Provider::Codex, provider_slots)]),
        },
    }
}

pub(crate) fn project(db: &rusqlite::Connection, worker: &Enrollment) -> crate::projects::Project {
    let pin = &worker.projects[0];
    db.execute(
        "INSERT INTO projects(id,name,machine,folder,created_ms) VALUES (?1,?2,?3,?4,?5)",
        rusqlite::params![pin.id, format!("{} fixture", worker.machine), worker.machine, pin.folder, pin.created_ms],
    ).unwrap();
    crate::projects::one(db, pin.id).unwrap().unwrap()
}

pub(crate) fn report(worker: &Enrollment, policy: &PolicyRef, observed_ms: i64) -> Report {
    let darwin = matches!(worker.machine.as_str(), "mini-m4" | "macbook-m4");
    let root_disk = Disk { filesystem: if darwin { "apfs" } else { "ext4" }.into(), free_bytes: 16 * GB, used_bytes: 84 * GB };
    Report {
        protocol: PROTOCOL,
        workspace: crate::fleet_policy::tests::WORKSPACE.into(),
        policy: policy.clone(),
        worker_id: worker.id.clone(),
        observed_ms,
        platform: if darwin { Platform::Darwin } else { Platform::Linux },
        root_disk: Some(root_disk.clone()),
        work_disks: BTreeMap::from([(FOLDER.into(), root_disk)]),
        ram_available_bytes: Some(8 * GIB),
        swap_used_bps: Some(2500),
        load_milli: Some(5000),
        io_busy_bps: Some(3500),
        heavy_running: Some(0),
        provider_running: BTreeMap::from([(Provider::Codex, 0)]),
        runtimes: BTreeMap::from([(Provider::Codex, Runtime { version: "fixture-1.0".into(), ready_ms: Some(observed_ms - 100) })]),
        toolchains: if darwin { BTreeSet::from(["xcode".into()]) } else { BTreeSet::new() },
        signing: darwin,
    }
}

struct Case {
    worker: Enrollment,
    project: crate::projects::Project,
    report: Report,
}

impl Case {
    fn new(machine: &str) -> Self {
        let worker = enrolled(machine, 1, &key());
        let db = rusqlite::Connection::open_in_memory().unwrap();
        db.execute_batch(include_str!("../../migrate-projects.sql")).unwrap();
        let project = project(&db, &worker);
        let policy = PolicyRef { generation: 1, digest: "a".repeat(64) };
        let report = report(&worker, &policy, OBSERVED);
        Self { worker, project, report }
    }

    fn evaluate(&self, now: i64) -> serde_json::Value {
        serde_json::to_value(heavy_admission(
            &self.worker, Some(&self.report), self.project.worker_pin(&self.worker), true, now,
        )).unwrap()
    }

    fn reason(&self, want: Option<&str>) {
        let evidence = self.evaluate(OBSERVED);
        assert_eq!(evidence["reason"].as_str(), want, "{evidence}");
        assert_eq!(evidence["status"], if want.is_none() { "eligible" } else { "hold" });
    }
}

#[test]
fn gapplan_06_unit_current_stale_future_and_unsupported_readings() {
    let mut fixture = Case::new("ovh");
    fixture.reason(None);
    let stale = |case: &Case, now: i64| {
        assert_eq!(case.evaluate(now)["reason"], "probe_stale");
    };
    stale(&fixture, OBSERVED + fixture.worker.thresholds.max_probe_age_ms + 1);
    stale(&fixture, OBSERVED - 1);
    fixture.report.platform = Platform::Unsupported;
    fixture.reason(Some("unsupported_readings"));
    fixture.report.platform = Platform::Linux;
    fixture.report.io_busy_bps = None;
    fixture.reason(Some("unsupported_readings"));
    assert_eq!(serde_json::to_value(heavy_admission(
        &fixture.worker, None, fixture.project.worker_pin(&fixture.worker), true, OBSERVED
    )).unwrap()["reason"], "probe_missing");
}

#[test]
fn gapplan_06_unit_ovh_distinguishes_normal_admission_from_hard_floor() {
    let mut fixture = Case::new("ovh");
    fixture.reason(None);
    {
        let root = fixture.report.root_disk.as_mut().unwrap();
        root.free_bytes = 10 * GB;
        root.used_bytes = 90 * GB;
    }
    fixture.reason(Some("disk_admission"));
    {
        let root = fixture.report.root_disk.as_mut().unwrap();
        root.free_bytes = 8 * GB;
        root.used_bytes = 32 * GB;
    }
    fixture.reason(Some("disk_admission"));
    // The documented stricter admission threshold is configurable independently.
    fixture.worker.thresholds.disk_admit_free_bytes = 8 * GB;
    fixture.reason(None);
    fixture.report.root_disk.as_mut().unwrap().free_bytes = 8 * GB - 1;
    fixture.report.io_busy_bps = None;
    let stop = fixture.evaluate(OBSERVED);
    assert_eq!(stop["status"], "stop");
    assert_eq!(stop["reason"], "disk_stop");
    assert_eq!(stop["disk"], serde_json::json!({"path":"/","free_bytes":8 * GB - 1,"limit_bytes":8 * GB}));
    fixture.report.root_disk.as_mut().unwrap().free_bytes = 12 * GB;
    fixture.report.work_disks.get_mut(FOLDER).unwrap().filesystem = "tmpfs".into();
    fixture.reason(Some("work_disk_not_backed"));
}

#[test]
fn gapplan_06_unit_dmt_load_ram_swap_and_io_holds() {
    let mut fixture = Case::new("dmt");
    fixture.reason(None);
    fixture.report.load_milli = Some(16_000);
    fixture.reason(Some("load"));
    fixture.report.load_milli = Some(15_999);
    fixture.report.ram_available_bytes = Some(4 * GIB);
    fixture.reason(Some("ram"));
    fixture.report.ram_available_bytes = Some(4 * GIB + 1);
    fixture.report.swap_used_bps = Some(9000);
    fixture.reason(Some("swap"));
    fixture.report.swap_used_bps = Some(8999);
    fixture.report.io_busy_bps = Some(8000);
    fixture.reason(Some("io"));
}

#[test]
fn gapplan_06_unit_box_mini_and_macbook_capacity() {
    let mut box_host = Case::new("box");
    box_host.report.provider_running.insert(Provider::Codex, 2);
    box_host.reason(None);
    box_host.report.provider_running.insert(Provider::Codex, 3);
    box_host.reason(Some("provider_slots"));
    box_host.worker.workload_class = WorkloadClass::LightOnly;
    box_host.reason(Some("light_work_only"));

    let mut mini = Case::new("mini-m4");
    mini.reason(None);
    mini.report.heavy_running = Some(1);
    mini.reason(Some("heavy_slots"));

    let mut laptop = Case::new("macbook-m4");
    laptop.reason(Some("portable"));
    laptop.worker.power_class = PowerClass::Headless;
    laptop.worker.workload_class = WorkloadClass::Heavy;
    laptop.reason(Some("portable"));
}

#[test]
fn gapplan_06_unit_runtime_login_toolchain_signing_and_project_pin() {
    let mut mini = Case::new("mini-m4");
    mini.worker.projects[0].requirements = Requirements {
        provider: Some(Provider::Codex),
        runtime_version: Some("fixture-1.0".into()),
        toolchain: Some("xcode".into()),
        signing: true,
    };
    mini.reason(None);
    mini.worker.projects[0].requirements.runtime_version = Some("fixture-2.0".into());
    mini.reason(Some("runtime"));
    mini.worker.projects[0].requirements.runtime_version = Some("fixture-1.0".into());
    mini.worker.projects[0].requirements.toolchain = Some("android".into());
    mini.reason(Some("toolchain"));
    mini.worker.projects[0].requirements.toolchain = Some("xcode".into());
    mini.report.signing = false;
    mini.reason(Some("signing"));
    mini.report.signing = true;
    mini.report.runtimes.get_mut(&Provider::Codex).unwrap().ready_ms =
        Some(OBSERVED - mini.worker.thresholds.max_readiness_age_ms - 1);
    mini.reason(Some("login_stale"));
    mini.worker.projects[0].created_ms -= 1;
    mini.reason(Some("project_not_enrolled"));
    mini.worker.projects[0].folder = "/fixture/work-sibling/project".into();
    assert!(!valid_enrollments(&[mini.worker]));
}

#[test]
fn gapplan_09_unit_disk_stop_threshold_comes_from_enrollment() {
    let mut other = Case::new("mini-m4");
    other.worker.thresholds.disk_stop_free_bytes = 12 * GB;
    other.worker.thresholds.disk_admit_free_bytes = 13 * GB;
    other.report.root_disk.as_mut().unwrap().free_bytes = 11 * GB;
    let held = other.evaluate(OBSERVED);
    assert_eq!(held["status"], "stop");
    assert_eq!(held["disk"]["limit_bytes"], 12 * GB);
}
