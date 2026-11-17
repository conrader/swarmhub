//! Codex's review of the hooks `run-codex` gives it, answered at launch.
//!
//! Codex asks a person to review every hook it has not seen before ("Hooks need review"), in its terminal, where
//! no chat shows the question. It remembers the answer per hook as a digest of the hook's definition, and it
//! reads such answers from the flags a session is started with as well as from its own settings file. So
//! `run-codex` asks Codex itself, once, for the digests of exactly the hooks it is about to pass (`hooks/list` on
//! Codex's app server, which only reads), and passes them along at every start as one more `-c` value. Nothing is
//! written into Codex's settings, no other hook is trusted, and a hook whose command changes has another digest.
//!
//! It does this only where a person agreed to it when the computer was set up (`first_time`). Without that, and
//! whenever Codex does not answer as expected, nothing is passed and Codex asks as it always did.

use super::models::AppServer;
use serde::Deserialize;
use serde_json::json;
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::Command,
};

const CACHE: &str = "codex-hook-trust.json";

#[derive(Deserialize)]
struct Listed {
    data: Vec<Folder>,
}

#[derive(Deserialize)]
struct Folder {
    hooks: Vec<Hook>,
}

#[derive(Deserialize)]
struct Hook {
    key: String,
    source: String,
    command: Option<String>,
    #[serde(rename = "currentHash")]
    hash: String,
}

/// The `-c` value that tells Codex the hooks with these commands are trusted, from what Codex lists for a start
/// with them. `None` unless all `count` of them are listed, as hooks given on the command line.
fn flag_from(listed: &Listed, commands: &[String], count: usize) -> Option<String> {
    let plain = |text: &str| {
        !text.is_empty()
            && !text
                .chars()
                .any(|c| c.is_control() || c == '"' || c == '\\')
    };
    let digest = |text: &str| {
        text.strip_prefix("sha256:")
            .is_some_and(|hex| hex.len() == 64 && hex.bytes().all(|byte| byte.is_ascii_hexdigit()))
    };
    let own: Vec<&Hook> = listed
        .data
        .iter()
        .flat_map(|folder| &folder.hooks)
        .filter(|hook| {
            hook.source == "sessionFlags"
                && hook
                    .command
                    .as_ref()
                    .is_some_and(|command| commands.contains(command))
        })
        .collect();
    let mut entries: Vec<String> = Vec::new();
    for hook in &own {
        if !plain(&hook.key) || !digest(&hook.hash) {
            return None;
        }
        let entry = format!("\"{}\"={{trusted_hash=\"{}\"}}", hook.key, hook.hash);
        if !entries.contains(&entry) {
            entries.push(entry);
        }
    }
    (count > 0 && entries.len() == count).then(|| format!("hooks.state={{{}}}", entries.join(",")))
}

/// Asks Codex what it makes of `hooks` (the `-c` values `run-codex` passes) and returns the flag for them.
/// Read-only for Codex: one `initialize` and one `hooks/list`.
pub(crate) fn ask(mut codex: Command, hooks: &[String], commands: &[String]) -> Option<String> {
    for hook in hooks {
        codex.arg("-c").arg(hook);
    }
    let mut server = AppServer::start(codex).ok()?;
    server
        .send(json!({"id":1,"method":"initialize","params":{"clientInfo":{
            "name":"swarmhub-herdr","version":env!("CARGO_PKG_VERSION")
        }}}))
        .ok()?;
    let _: serde::de::IgnoredAny = server.result(1).ok()?;
    server.send(json!({"method":"initialized"})).ok()?;
    let here = env::current_dir().ok()?;
    server
        .send(json!({"id":2,"method":"hooks/list","params":{"cwds":[here]}}))
        .ok()?;
    let listed: Listed = server.result(2).ok()?;
    flag_from(&listed, commands, hooks.len())
}

/// What the cached flag was made for: these hooks, and this Codex (its program file as it is now).
fn made_for(hooks: &[String]) -> String {
    let program = env::var_os("SWARMHUB_CODEX_BIN").unwrap_or_else(|| "codex".into());
    let found: Option<PathBuf> = if Path::new(&program).is_absolute() {
        Some(program.clone().into())
    } else {
        env::var_os("PATH").and_then(|folders| {
            env::split_paths(&folders)
                .map(|folder| folder.join(&program))
                .find(|path| path.is_file())
        })
    };
    let file = found.and_then(|path| path.canonicalize().ok());
    let stamp = file
        .as_ref()
        .and_then(|path| fs::metadata(path).ok())
        .map(|meta| {
            let changed = meta
                .modified()
                .ok()
                .and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok())
                .map_or(0, |since| since.as_nanos());
            format!("{}:{changed}", meta.len())
        })
        .unwrap_or_default();
    let mut digest = Sha256::new();
    digest.update(b"swarmhub-codex-hook-trust-v1\0");
    digest.update(
        file.map(|path| path.to_string_lossy().into_owned())
            .unwrap_or_default(),
    );
    digest.update(b"\0");
    digest.update(stamp);
    for hook in hooks {
        digest.update(b"\0");
        digest.update(hook);
    }
    digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

#[derive(Deserialize)]
struct Cached {
    made_for: String,
    flag: String,
}

/// The flag for these hooks when the person agreed to it for this server (`journal`'s folder holds the record),
/// from the last answer Codex gave for the same hooks and the same Codex, or from asking it now.
pub(super) fn flag(
    journal: &Path,
    codex: Command,
    hooks: &[String],
    commands: &[String],
) -> Option<String> {
    let data = journal.parent()?;
    if !crate::first_time::codex_hooks_agreed(data) {
        return None;
    }
    let made_for = made_for(hooks);
    let file = data.join(CACHE);
    let cached: Option<Cached> = fs::read(&file)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok());
    if let Some(cached) = cached
        .filter(|cached| cached.made_for == made_for && cached.flag.starts_with("hooks.state={"))
    {
        return Some(cached.flag);
    }
    let flag = ask(codex, hooks, commands)?;
    let _ = fs::write(
        &file,
        json!({"made_for": made_for, "flag": flag}).to_string(),
    );
    Some(flag)
}

/// Forgets the cached answer, so the next start asks Codex again (or passes nothing, once the agreement is gone).
pub(crate) fn forget(data: &Path) {
    let _ = fs::remove_file(data.join(CACHE));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn listed(text: &str) -> Listed {
        serde_json::from_str(text).unwrap()
    }

    const HASH_A: &str = "sha256:48db35e12c3034e0e1a0c43fd36db15307cf4839fcd32a6a78e73218c402fcca";
    const HASH_B: &str = "sha256:b8ae17fb60c89ffd2af2a68d0e47317389bc99a62757f41a74d57e7f7e90adaf";

    #[test]
    fn trusts_exactly_the_hooks_it_passes_and_no_other() {
        let answer = format!(
            r#"{{"data":[{{"cwd":"/bots","hooks":[
              {{"key":"/<session-flags>/config.toml:pre_tool_use:0:0","source":"sessionFlags","command":"'/x/swarmhub-herdr' tool-activity","currentHash":"{HASH_A}","trustStatus":"untrusted"}},
              {{"key":"/<session-flags>/config.toml:stop:0:0","source":"sessionFlags","command":"'/x/swarmhub-herdr' capture-codex-reply","currentHash":"{HASH_B}","trustStatus":"modified"}},
              {{"key":"plugin@you:hooks.json:stop:0:0","source":"plugin","command":"python3 other.py","currentHash":"{HASH_A}","trustStatus":"untrusted"}},
              {{"key":"/bots/.codex/hooks.json:stop:0:0","source":"project","command":"'/x/swarmhub-herdr' capture-codex-reply","currentHash":"{HASH_A}","trustStatus":"untrusted"}}
            ],"warnings":[],"errors":[]}}]}}"#
        );
        let commands = [
            "'/x/swarmhub-herdr' capture-codex-reply".to_owned(),
            "'/x/swarmhub-herdr' tool-activity".to_owned(),
        ];
        let flag = flag_from(&listed(&answer), &commands, 2).unwrap();
        assert_eq!(
            flag,
            format!(
                "hooks.state={{\"/<session-flags>/config.toml:pre_tool_use:0:0\"={{trusted_hash=\"{HASH_A}\"}},\"/<session-flags>/config.toml:stop:0:0\"={{trusted_hash=\"{HASH_B}\"}}}}"
            )
        );
        // The value is one TOML table, as Codex reads a `-c` value.
        assert!(!flag.contains("plugin") && !flag.contains("/bots/.codex"));
        // One of the hooks is not listed: nothing is passed, and Codex asks as it always did.
        assert_eq!(flag_from(&listed(&answer), &commands, 3), None);
        assert_eq!(flag_from(&listed(&answer), &[], 0), None);
    }

    #[test]
    fn an_answer_that_is_not_as_expected_gives_no_flag() {
        let odd = |key: &str, hash: &str| {
            listed(&format!(
                r#"{{"data":[{{"hooks":[{{"key":"{key}","source":"sessionFlags","command":"c","currentHash":"{hash}"}}]}}]}}"#
            ))
        };
        let commands = ["c".to_owned()];
        assert!(flag_from(&odd("k:stop:0:0", HASH_A), &commands, 1).is_some());
        assert_eq!(flag_from(&odd("k:stop:0:0", "md5:abc"), &commands, 1), None);
        assert_eq!(
            flag_from(&odd("k\\\"},x={y=\\\"", HASH_A), &commands, 1),
            None
        );
        assert_eq!(flag_from(&odd("", HASH_A), &commands, 1), None);
        assert!(serde_json::from_str::<Listed>(r#"{"hooks":[]}"#).is_err());
    }

    #[test]
    fn nothing_is_passed_without_the_persons_agreement_and_an_answer_is_kept() {
        let scratch = tempfile::tempdir().unwrap();
        let journal = scratch.path().join("workspace.sqlite3");
        let hooks = ["hooks.Stop=[]".to_owned()];
        let commands = ["c".to_owned()];
        // No agreement: Codex is not even asked (the command would fail to start).
        assert_eq!(
            flag(
                &journal,
                Command::new("/nonexistent/codex"),
                &hooks,
                &commands
            ),
            None
        );
        assert!(!scratch.path().join(CACHE).exists());
        crate::first_time::agree_codex_hooks(scratch.path(), true).unwrap();
        // Agreed, but Codex does not answer: nothing is passed and nothing is kept.
        assert_eq!(
            flag(
                &journal,
                Command::new("/nonexistent/codex"),
                &hooks,
                &commands
            ),
            None
        );
        // An answer kept for these hooks and this Codex is used without asking again.
        let kept = json!({"made_for": made_for(&hooks), "flag": "hooks.state={\"k\"={trusted_hash=\"x\"}}"});
        fs::write(scratch.path().join(CACHE), kept.to_string()).unwrap();
        assert_eq!(
            flag(
                &journal,
                Command::new("/nonexistent/codex"),
                &hooks,
                &commands
            )
            .as_deref(),
            Some("hooks.state={\"k\"={trusted_hash=\"x\"}}")
        );
        // Other hooks: the kept answer is not theirs.
        assert_eq!(
            flag(
                &journal,
                Command::new("/nonexistent/codex"),
                &["other".to_owned()],
                &commands
            ),
            None
        );
        forget(scratch.path());
        assert!(!scratch.path().join(CACHE).exists());
    }
}
