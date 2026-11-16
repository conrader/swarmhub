//! `helper-policy.json`, next to the workspace database: what a helper of each difficulty runs on.
//!
//! The workspace owner writes this file. An agent names only the difficulty; the template, the model and the
//! number of helpers one agent may have running come from here and are read again for every request.

use crate::core::valid_name;
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap, fs::OpenOptions, io::Read, os::unix::fs::OpenOptionsExt, path::Path,
};

pub(crate) const FILE: &str = "helper-policy.json";
const MAX_FILE: u64 = 16 * 1024;
const MAX_RUNNING: usize = 16;

pub(crate) const MISSING: &str =
    "Helpers are not enabled here: the workspace has no helper-policy.json. Do the task yourself.";
pub(crate) const UNREADABLE: &str = "Helpers are unavailable: the workspace's helper-policy.json is not a valid helper policy. Do the task yourself and tell the user.";

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

#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub(crate) struct Tier {
    pub template: String,
    pub model: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Policy {
    /// How many helpers one agent may have running at once.
    pub max_running: usize,
    difficulties: BTreeMap<Difficulty, Tier>,
}

impl Policy {
    pub(crate) fn load(journal: &Path) -> Result<Self, &'static str> {
        let file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(journal.with_file_name(FILE))
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Err(MISSING),
            Err(_) => return Err(UNREADABLE),
        };
        if !file.metadata().is_ok_and(|meta| meta.is_file()) {
            return Err(UNREADABLE);
        }
        let mut bytes = Vec::new();
        if file.take(MAX_FILE + 1).read_to_end(&mut bytes).is_err() || bytes.len() as u64 > MAX_FILE
        {
            return Err(UNREADABLE);
        }
        Self::parse(&bytes).ok_or(UNREADABLE)
    }

    pub(crate) fn parse(bytes: &[u8]) -> Option<Self> {
        let policy: Self = serde_json::from_slice(bytes).ok()?;
        let plain = |model: &str| {
            (1..=160).contains(&model.len())
                && !model.chars().any(|c| c.is_control() || c.is_whitespace())
        };
        (policy.max_running <= MAX_RUNNING
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
                "You already have {running} helpers running and the limit is {limit}. Stop one you no longer need with `swarmhub-herdr helper stop NAME`, then try again."
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
        assert!(policy.admit(3).unwrap_err().contains("limit is 3"));
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
        assert_eq!(Policy::load(&journal).unwrap_err(), MISSING);
        std::fs::write(scratch.path().join(FILE), "{").unwrap();
        assert_eq!(Policy::load(&journal).unwrap_err(), UNREADABLE);
        std::fs::write(scratch.path().join(FILE), SAMPLE).unwrap();
        assert_eq!(Policy::load(&journal).unwrap().max_running, 3);
        std::fs::remove_file(scratch.path().join(FILE)).unwrap();
        std::os::unix::fs::symlink("/dev/null", scratch.path().join(FILE)).unwrap();
        assert_eq!(Policy::load(&journal).unwrap_err(), UNREADABLE);
    }
}
