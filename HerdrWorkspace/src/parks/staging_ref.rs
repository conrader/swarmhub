//! The only constructor enrolls a private Git repository in a Rust test.

use super::{Adapter, Manifest, Marker, Operation, Step};
use std::{
    io,
    path::PathBuf,
    process::{Command, Output, Stdio},
};

const APPLY_PIN: &str = "builtin:git-update-ref:apply:v1";
const REVERSE_PIN: &str = "builtin:git-update-ref:reverse:v1";

#[derive(Clone)]
pub(super) struct Project {
    git_dir: PathBuf,
    reviewed: Manifest,
}

pub(super) fn valid_oid(value: &str) -> bool {
    matches!(value.len(), 40 | 64)
        && value.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        && value.bytes().any(|byte| byte != b'0')
}

pub(super) fn valid_ref(value: &str) -> bool {
    value.strip_prefix("refs/heads/").is_some_and(|name| {
        !name.is_empty()
            && !name.contains("..")
            && name.split('/').all(|part| {
                !part.is_empty()
                    && !part.starts_with('.')
                    && !part.ends_with('.')
                    && !part.ends_with(".lock")
                    && part.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
            })
    })
}

impl Project {
    #[cfg(test)]
    pub(super) fn fixture(git_dir: &std::path::Path, reviewed: Manifest) -> Self {
        assert!(reviewed.encode().is_ok());
        assert!(matches!(reviewed.operation, Operation::AdvanceStagingRef { .. }));
        Self { git_dir: git_dir.canonicalize().unwrap(), reviewed }
    }

    pub(super) fn enrolled(&self, manifest: &Manifest) -> bool {
        let original = &self.reviewed;
        manifest.owner == original.owner && manifest.project == original.project
            && manifest.host == original.host && manifest.operation == original.operation
            && manifest.precondition == original.precondition
            && manifest.rollback_plan == original.rollback_plan
    }

    #[cfg(test)]
    pub(super) fn reviewed(&self, manifest: &Manifest) -> bool {
        manifest == &self.reviewed
    }

    /// Revalidate that the configured ref is direct and both pins name real commits.
    pub(super) fn check(&self, manifest: &Manifest) -> io::Result<()> {
        let old = &manifest.precondition;
        let new = &manifest.expected_postcondition;
        if !self.enrolled(manifest)
            || &manifest.artifact_pin != new
            || manifest.apply_pin != APPLY_PIN
            || manifest.reverse_pin != REVERSE_PIN
        {
            return Err(io::Error::other("staging adapter or artifact pin does not match"));
        }
        for oid in [old, new] {
            let output = self.git(&["cat-file", "-t", oid])?;
            if !output.status.success() || output.stdout != b"commit\n" {
                return Err(io::Error::other("staging pin is not a commit"));
            }
        }
        if !self.git(&["merge-base", "--is-ancestor", old, new])?.status.success() {
            return Err(io::Error::other("staging pins do not advance the ref"));
        }
        Ok(())
    }

    fn reference(&self) -> &str {
        let Operation::AdvanceStagingRef { reference, .. } = &self.reviewed.operation else {
            unreachable!("fixture enrollment requires a staging ref");
        };
        reference
    }

    fn git(&self, args: &[&str]) -> io::Result<Output> {
        Command::new("/usr/bin/git")
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_NO_LAZY_FETCH", "1")
            .env("GIT_NO_REPLACE_OBJECTS", "1")
            .env("GIT_TERMINAL_PROMPT", "0")
            .arg("--git-dir")
            .arg(&self.git_dir)
            .args(["-c", "core.hooksPath=/dev/null", "-c", "protocol.allow=never"])
            .args(args)
            .stdin(Stdio::null())
            .output()
    }

    fn update(&self, expected: &Marker, replacement: &Marker) -> Step {
        // The old value is checked by Git under its ref lock. Never follow
        // a symbolic ref to update a different ref in the test repository.
        if self.observe().is_err() {
            return Step::Unavailable;
        }
        match self.git(&["update-ref", "--no-deref", self.reference(), &replacement.revision, &expected.revision]) {
            Ok(output) if output.status.success() => Step::Exit(0),
            Ok(output) => output.status.code().map_or(Step::Unavailable, Step::Exit),
            Err(_) => Step::Unavailable,
        }
    }
}

impl Adapter for Project {
    fn observe(&self) -> io::Result<Marker> {
        let symbolic = self.git(&["symbolic-ref", "--quiet", self.reference()])?;
        if symbolic.status.code() != Some(1) {
            return Err(io::Error::other("staging ref is not direct"));
        }
        let output = self.git(&["show-ref", "--verify", "--hash", self.reference()])?;
        let revision = String::from_utf8_lossy(&output.stdout).trim_end().to_owned();
        if !output.status.success() || !valid_oid(&revision) {
            return Err(io::Error::other("staging ref could not be resolved"));
        }
        Ok(Marker { revision, attempt: None })
    }

    fn apply(&self, expected: &Marker, replacement: &Marker) -> Step {
        self.update(expected, replacement)
    }

    fn rollback(&self, expected: &Marker, replacement: &Marker) -> Step {
        self.update(expected, replacement)
    }
}

#[cfg(test)]
pub(super) mod tests;
