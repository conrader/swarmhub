//! `helper-policy.json`, next to the workspace database: what a helper of each difficulty runs on.
//!
//! The workspace owner writes this file, by hand or through `/api/helper-policy` (`settings`). An agent names
//! only the difficulty; the template, the model, the number of helpers one agent may have running and how long an
//! answered helper stays come from here and are read again for every request.

use crate::core::valid_name;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::Path,
};

pub(crate) const FILE: &str = "helper-policy.json";
const MAX_FILE: u64 = 16 * 1024;
pub(crate) const MAX_RUNNING: usize = 16;
/// How long an answered helper stays before the workspace stops it, unless the file says otherwise.
pub(crate) const STOP_AFTER_SECONDS: u64 = 60;
pub(crate) const STOP_AFTER_RANGE: std::ops::RangeInclusive<u64> = 5..=86_400;

/// Why there is no policy to apply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Unusable {
    Missing,
    Invalid,
}

impl Unusable {
    /// For the agent that asked for a helper.
    pub(crate) fn for_agent(self) -> &'static str {
        match self {
            Self::Missing => {
                "Helpers are not enabled here: the workspace has no helper-policy.json. Do the task yourself."
            }
            Self::Invalid => {
                "Helpers are unavailable: the workspace's helper-policy.json is not a valid helper policy. Do the task yourself and tell the user."
            }
        }
    }

    /// For the person who owns the workspace.
    pub(crate) fn for_owner(self) -> &'static str {
        match self {
            Self::Missing => "No helper policy is saved, so agents cannot start helpers.",
            Self::Invalid => {
                "helper-policy.json is not a valid helper policy, so agents cannot start helpers. Saving a policy replaces the file."
            }
        }
    }
}

fn stop_after_default() -> u64 {
    STOP_AFTER_SECONDS
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Difficulty {
    Easy,
    Medium,
    Hard,
}

impl Difficulty {
    pub(crate) fn parse(value: &str) -> Result<Self, String> {
        match value {
            "easy" => Ok(Self::Easy),
            "medium" => Ok(Self::Medium),
            "hard" => Ok(Self::Hard),
            _ => Err(format!(
                "Unknown difficulty {:?}. Use easy, medium or hard.",
                value.chars().take(40).collect::<String>()
            )),
        }
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Easy => "easy",
            Self::Medium => "medium",
            Self::Hard => "hard",
        }
    }
}

#[derive(Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Tier {
    pub template: String,
    pub model: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Policy {
    /// How many helpers one agent may have running at once.
    pub max_running: usize,
    /// Seconds an idle helper stays after its answer was saved. Left out of the file: 60.
    #[serde(default = "stop_after_default")]
    pub stop_after_seconds: u64,
    difficulties: BTreeMap<Difficulty, Tier>,
}

impl Policy {
    pub(crate) fn load(journal: &Path) -> Result<Self, Unusable> {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(journal.with_file_name(FILE))
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Err(Unusable::Missing),
            Err(_) => return Err(Unusable::Invalid),
        };
        if !file.metadata().is_ok_and(|meta| meta.is_file()) {
            return Err(Unusable::Invalid);
        }
        let mut bytes = Vec::new();
        if file.take(MAX_FILE + 1).read_to_end(&mut bytes).is_err() || bytes.len() as u64 > MAX_FILE
        {
            return Err(Unusable::Invalid);
        }
        Self::parse(&bytes).ok_or(Unusable::Invalid)
    }

    /// The delay an answered helper gets, also when there is no usable policy to say so.
    pub(crate) fn stop_after(journal: &Path) -> u64 {
        Self::load(journal).map_or(STOP_AFTER_SECONDS, |policy| policy.stop_after_seconds)
    }

    /// Replaces the file in one step, in a form a person can still read and edit.
    pub(crate) fn save(&self, journal: &Path) -> io::Result<()> {
        let mut text = serde_json::to_vec_pretty(self).map_err(io::Error::other)?;
        text.push(b'\n');
        let fresh = journal.with_file_name(format!("{FILE}.new"));
        // A leftover from an interrupted save, or anything else put in its place.
        match fs::remove_file(&fresh) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => return Err(error),
            _ => {}
        }
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(&fresh)?;
        file.write_all(&text)?;
        file.sync_all()?;
        fs::rename(fresh, journal.with_file_name(FILE))
    }

    pub(crate) fn tiers(&self) -> impl Iterator<Item = (Difficulty, &Tier)> {
        self.difficulties.iter().map(|(level, tier)| (*level, tier))
    }

    pub(crate) fn parse(bytes: &[u8]) -> Option<Self> {
        let policy: Self = serde_json::from_slice(bytes).ok()?;
        let plain = |model: &str| {
            (1..=160).contains(&model.len())
                && !model.chars().any(|c| c.is_control() || c.is_whitespace())
        };
        (policy.max_running <= MAX_RUNNING
            && STOP_AFTER_RANGE.contains(&policy.stop_after_seconds)
            && policy
                .difficulties
                .values()
                .all(|tier| valid_name(&tier.template) && plain(&tier.model)))
        .then_some(policy)
    }

    pub(crate) fn tier(&self, difficulty: Difficulty) -> Result<&Tier, String> {
        self.difficulties.get(&difficulty).ok_or_else(|| {
            let allowed: Vec<_> = self.difficulties.keys().map(|level| level.name()).collect();
            if allowed.is_empty() {
                "The workspace's helper policy does not allow any helpers.".to_owned()
            } else {
                format!(
                    "The workspace's helper policy does not allow {} helpers. Allowed: {}.",
                    difficulty.name(),
                    allowed.join(", ")
                )
            }
        })
    }

    /// Whether an agent with `running` helpers may start one more.
    pub(crate) fn admit(&self, running: usize) -> Result<(), String> {
        if running < self.max_running {
            return Ok(());
        }
        Err(match self.max_running {
            0 => "The workspace's helper policy allows no running helpers.".to_owned(),
            limit => format!(
                "You already have {running} helpers running and the limit is {limit}. A helper is stopped {} seconds after it answers: wait for one, or stop one you no longer need with `swarmhub-herdr helper stop NAME`, then try again.",
                self.stop_after_seconds
            ),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"{"max_running":3,"difficulties":{
        "easy":{"template":"swarmhub-claude","model":"sonnet"},
        "medium":{"template":"swarmhub-codex","model":"gpt-6.1-sol"}}}"#;

    #[test]
    fn the_policy_decides_template_and_model_for_a_difficulty() {
        let policy = Policy::parse(SAMPLE.as_bytes()).unwrap();
        assert_eq!(
            policy.tier(Difficulty::Easy).unwrap(),
            &Tier {
                template: "swarmhub-claude".into(),
                model: "sonnet".into()
            }
        );
        assert_eq!(
            policy.tier(Difficulty::Medium).unwrap().model,
            "gpt-6.1-sol"
        );
        // A difficulty the owner left out is refused, and the message names what is allowed.
        let refused = policy.tier(Difficulty::Hard).unwrap_err();
        assert!(refused.contains("hard") && refused.contains("easy, medium"));
        assert_eq!(Difficulty::parse("hard"), Ok(Difficulty::Hard));
        for unknown in ["", "Easy", "extreme", "easy "] {
            assert!(
                Difficulty::parse(unknown)
                    .unwrap_err()
                    .contains("easy, medium or hard")
            );
        }
    }

    #[test]
    fn the_limit_counts_running_helpers() {
        let policy = Policy::parse(SAMPLE.as_bytes()).unwrap();
        assert!(policy.admit(0).is_ok() && policy.admit(2).is_ok());
        let full = policy.admit(3).unwrap_err();
        assert!(
            full.contains("limit is 3") && full.contains("stopped 60 seconds after it answers")
        );
        assert!(policy.admit(9).is_err());
        let closed = Policy::parse(br#"{"max_running":0,"difficulties":{}}"#).unwrap();
        assert!(closed.admit(0).is_err());
        assert!(closed.tier(Difficulty::Easy).is_err());
    }

    #[test]
    fn refuses_policies_it_does_not_fully_understand() {
        for bad in [
            "",
            "[]",
            r#"{"difficulties":{}}"#,
            r#"{"max_running":17,"difficulties":{}}"#,
            r#"{"max_running":-1,"difficulties":{}}"#,
            r#"{"max_running":1,"difficulties":{},"extra":true}"#,
            r#"{"max_running":1,"stop_after_seconds":4,"difficulties":{}}"#,
            r#"{"max_running":1,"stop_after_seconds":86401,"difficulties":{}}"#,
            r#"{"max_running":1,"stop_after_seconds":"60","difficulties":{}}"#,
            r#"{"max_running":1,"difficulties":{"extreme":{"template":"a","model":"b"}}}"#,
            r#"{"max_running":1,"difficulties":{"easy":{"template":"a"}}}"#,
            r#"{"max_running":1,"difficulties":{"easy":{"template":"Not Valid","model":"b"}}}"#,
            r#"{"max_running":1,"difficulties":{"easy":{"template":"a","model":"b c"}}}"#,
            r#"{"max_running":1,"difficulties":{"easy":{"template":"a","model":""}}}"#,
            r#"{"max_running":1,"difficulties":{"easy":{"template":"a","model":"b","args":"-x"}}}"#,
        ] {
            assert!(Policy::parse(bad.as_bytes()).is_none(), "{bad}");
        }
    }

    #[test]
    fn a_missing_or_broken_file_is_reported_as_such() {
        let scratch = tempfile::tempdir().unwrap();
        let journal = scratch.path().join("workspace.sqlite3");
        assert_eq!(Policy::load(&journal).unwrap_err(), Unusable::Missing);
        assert_eq!(Policy::stop_after(&journal), STOP_AFTER_SECONDS);
        std::fs::write(scratch.path().join(FILE), "{").unwrap();
        assert_eq!(Policy::load(&journal).unwrap_err(), Unusable::Invalid);
        std::fs::write(scratch.path().join(FILE), SAMPLE).unwrap();
        let loaded = Policy::load(&journal).unwrap();
        // A file written before the delay existed keeps working, with the default delay.
        assert_eq!((loaded.max_running, loaded.stop_after_seconds), (3, 60));
        std::fs::remove_file(scratch.path().join(FILE)).unwrap();
        std::os::unix::fs::symlink("/dev/null", scratch.path().join(FILE)).unwrap();
        assert_eq!(Policy::load(&journal).unwrap_err(), Unusable::Invalid);
    }

    #[test]
    fn a_saved_policy_reads_back_and_stays_editable_by_hand() {
        let scratch = tempfile::tempdir().unwrap();
        let journal = scratch.path().join("workspace.sqlite3");
        // Whatever sits at the two paths is replaced, a symbolic link included.
        std::os::unix::fs::symlink("/dev/null", scratch.path().join(FILE)).unwrap();
        std::fs::write(scratch.path().join(format!("{FILE}.new")), "left over").unwrap();
        let policy = Policy::parse(
            br#"{"max_running":2,"stop_after_seconds":90,"difficulties":{"hard":{"template":"a","model":"b"}}}"#,
        )
        .unwrap();
        policy.save(&journal).unwrap();
        let text = std::fs::read_to_string(scratch.path().join(FILE)).unwrap();
        assert_eq!(
            text,
            "{\n  \"max_running\": 2,\n  \"stop_after_seconds\": 90,\n  \"difficulties\": {\n    \"hard\": {\n      \"template\": \"a\",\n      \"model\": \"b\"\n    }\n  }\n}\n"
        );
        let loaded = Policy::load(&journal).unwrap();
        assert_eq!(
            (
                loaded.max_running,
                loaded.stop_after_seconds,
                loaded.tiers().count()
            ),
            (2, 90, 1)
        );
        assert!(!scratch.path().join(format!("{FILE}.new")).exists());
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(scratch.path().join(FILE))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0);
    }
}
