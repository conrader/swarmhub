//! What `skillshare doctor` and `skillshare updates check` say about skillshare on this server, turned into what
//! the workspace sends. Nothing here runs a program or reads a file.

use super::{
    parse::shortened,
    read::{named, sentence},
};
use serde::{Deserialize, Serialize};

const MAX_NOTES: usize = 50;

/// One thing `skillshare doctor` warns about.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct Note {
    pub status: String,
    pub name: String,
    pub message: String,
    pub details: Vec<String>,
}

/// What `skillshare doctor --json` found wrong: the counts, and each warning and error.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub(super) struct Doctor {
    pub errors: u64,
    pub warnings: u64,
    pub notes: Vec<Note>,
    #[serde(skip)]
    pub version: Option<String>,
}

pub(super) fn doctor(json: &str) -> Option<Doctor> {
    #[derive(Deserialize)]
    struct Report {
        checks: Vec<Check>,
        #[serde(default)]
        summary: Summary,
        version: Option<Version>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Check {
        name: String,
        status: String,
        message: String,
        details: Option<Vec<String>>,
    }
    #[derive(Default, Deserialize)]
    #[serde(default)]
    struct Summary {
        warnings: u64,
        errors: u64,
    }
    #[derive(Deserialize)]
    struct Version {
        current: Option<String>,
    }
    let report: Report = serde_json::from_str(json.trim()).ok()?;
    let mut notes: Vec<Note> = report
        .checks
        .into_iter()
        .filter(|check| matches!(check.status.as_str(), "warning" | "error"))
        .map(|check| Note {
            status: check.status,
            name: shortened(&sentence(&check.name), 80),
            message: sentence(&check.message),
            details: check
                .details
                .unwrap_or_default()
                .iter()
                .map(|detail| sentence(detail))
                .filter(|detail| !detail.is_empty())
                .take(8)
                .collect(),
        })
        .collect();
    // Errors first; skillshare's own order within each.
    notes.sort_by_key(|note| note.status != "error");
    notes.truncate(MAX_NOTES);
    Some(Doctor {
        errors: report.summary.errors,
        warnings: report.summary.warnings,
        notes,
        version: report
            .version
            .and_then(|version| named(version.current, 40)),
    })
}

/// `skillshare updates check --json`: the newest release, and whether it is newer than the one installed.
pub(super) fn newest(json: &str) -> Option<(String, bool)> {
    #[derive(Deserialize)]
    struct Report {
        #[serde(rename = "LatestVersion")]
        latest: String,
        #[serde(rename = "UpdateAvailable", default)]
        available: bool,
    }
    let report: Report = serde_json::from_str(json.trim()).ok()?;
    let version = report.latest.trim_start_matches('v');
    let shaped = !version.is_empty()
        && version.len() <= 40
        && version
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'+'));
    shaped.then(|| (version.to_owned(), report.available))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_doctor_report_keeps_what_is_wrong() {
        let doctor = doctor(include_str!("fixtures/doctor.json")).unwrap();
        assert_eq!(doctor.version.as_deref(), Some("0.30.8"));
        assert!(doctor.warnings >= 1);
        assert!(!doctor.notes.is_empty());
        assert!(
            doctor
                .notes
                .iter()
                .all(|note| matches!(note.status.as_str(), "warning" | "error"))
        );
        let git = doctor
            .notes
            .iter()
            .find(|note| note.name == "git_status")
            .unwrap();
        assert!(git.message.starts_with("Git: "), "{}", git.message);
        // Errors come first.
        let first_warning = doctor
            .notes
            .iter()
            .position(|note| note.status == "warning")
            .unwrap();
        assert!(
            doctor.notes[first_warning..]
                .iter()
                .all(|note| note.status == "warning")
        );
        assert!(super::doctor("{}").is_none());
    }

    #[test]
    fn the_newest_release_is_read_from_the_update_check() {
        let (latest, available) = newest(include_str!("fixtures/updates.json")).unwrap();
        assert!(available);
        assert!(
            latest.starts_with("0.") && !latest.starts_with('v'),
            "{latest}"
        );
        assert_eq!(
            newest(r#"{"LatestVersion":"v1.2.3"}"#),
            Some(("1.2.3".into(), false))
        );
        assert!(newest(r#"{"LatestVersion":"<b>"}"#).is_none());
        assert!(newest("{}").is_none());
    }
}
