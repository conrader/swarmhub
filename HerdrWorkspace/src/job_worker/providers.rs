//! Fixed adapters for enrolled, local provider doubles.
use super::{Blocker, LOG_LIMIT, RESULT_LIMIT, RELEASE, Result, digest, store::private_file};
use crate::{fleet_policy::principals::identifier, machines::probe::Provider, results::bounded_regular_artifact, runtimes};
use serde::{Deserialize, Serialize};
use std::{
    os::fd::OwnedFd,
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    os::unix::{
        fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};

pub(super) const BRIEF_LIMIT: usize = 3000;
pub(super) const EVENTS_LIMIT: usize = 64 * 1024;
const EXECUTABLE_LIMIT: usize = 64 * 1024;
const RESULT: &str = "result.md";

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Request {
    pub profile: String,
    pub(super) brief: String,
}

impl Request {
    pub(super) fn valid(&self, provider: Provider, model: Option<&str>, effort: Option<&str>) -> bool {
        identifier(&self.profile)
            && self.profile.len() <= 64
            && self.brief.len() <= BRIEF_LIMIT
            && !self.brief.trim().is_empty()
            && !self.brief.contains('\0')
            && model.is_none_or(|model| runtimes::model_discovery::launchable_model(agent(provider), model))
            && effort.is_none_or(|effort| effort_supported(provider, effort))
    }
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Config {
    provider: Provider,
    account_ref: String,
    cli_version: String,
    executable_sha256: String,
    timeout_ms: u64,
}

pub(super) struct Profile {
    config: Config,
    runner: Vec<u8>,
    home: PathBuf,
}

impl Profile {
    pub(super) fn load(
        root: &Path, request: &Request, provider: Provider, account: &str, version: Option<&str>,
    ) -> std::result::Result<Self, Blocker> {
        Self::read(root, request, provider, account, version)
            .map_err(|_| Blocker::hold("runtime_profile_unavailable"))
    }

    fn read(root: &Path, request: &Request, provider: Provider, account: &str, version: Option<&str>) -> Result<Self> {
        // SAFETY: geteuid identifies the host account that owns this worker state.
        let owner = unsafe { libc::geteuid() };
        let profiles = root.join("fixture-runtimes");
        let profile = profiles.join(&request.profile);
        let home = profile.join("home");
        for path in [&profiles, &profile, &home] {
            let meta = fs::symlink_metadata(path)?;
            if !meta.is_dir() || meta.uid() != owner || meta.mode() & 0o077 != 0 {
                return Err("Fixture runtime directories must be private and account-owned.".into());
            }
        }
        let config: Config = serde_json::from_slice(&bounded(private_file(&profile.join("profile.json"), owner, false)?, 4096)?)?;
        if config.provider != provider || config.account_ref != account
            || Some(config.cli_version.as_str()) != version || !(1..=60_000).contains(&config.timeout_ms)
        {
            return Err("Fixture runtime profile does not match admission.".into());
        }
        let file = private_file(&profile.join("runner"), owner, false)?;
        let meta = file.metadata()?;
        if meta.nlink() != 1 || meta.mode() & 0o100 == 0 {
            return Err("Fixture runner must be a private executable.".into());
        }
        let runner = bounded(file, EXECUTABLE_LIMIT)?;
        if digest(&runner) != config.executable_sha256 {
            return Err("Fixture executable pin does not match.".into());
        }
        Ok(Self { config, runner, home })
    }

    pub(super) fn pin(&self) -> Result<String> {
        Ok(digest(&serde_json::to_vec(&self.config)?))
    }

    pub(super) fn stage(
        &self, root: &Path, request: &Request, model: Option<&str>, effort: Option<&str>,
    ) -> Result<Prepared> {
        let dir = tempfile::Builder::new()
            .prefix("provider-")
            .permissions(fs::Permissions::from_mode(0o700))
            .tempdir_in(root)?;
        write_private(&dir.path().join("runner"), 0o700, &self.runner)?;
        write_private(&dir.path().join("brief"), 0o600, request.brief.as_bytes())?;
        let invocation = Invocation {
            provider: self.config.provider,
            home: self.home.clone(),
            model: model.map(str::to_owned),
            effort: effort.map(str::to_owned),
        };
        write_private(&dir.path().join("invocation.json"), 0o600, &serde_json::to_vec(&invocation)?)?;
        Ok(Prepared {
            dir,
            provider: self.config.provider,
            version: self.config.cli_version.clone(),
            timeout: Duration::from_millis(self.config.timeout_ms),
        })
    }
}

fn bounded(file: File, limit: usize) -> io::Result<Vec<u8>> {
    let mut bytes = Vec::new();
    file.take((limit + 1) as u64).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        return Err(io::Error::other("Fixture runtime file exceeds its limit."));
    }
    Ok(bytes)
}

fn write_private(path: &Path, mode: u32, bytes: &[u8]) -> io::Result<()> {
    OpenOptions::new().write(true).create_new(true).mode(mode).open(path)?.write_all(bytes)
}

pub(super) struct Prepared {
    dir: tempfile::TempDir,
    provider: Provider,
    pub version: String,
    pub timeout: Duration,
}

impl Prepared {
    pub(super) fn path(&self) -> &Path {
        self.dir.path()
    }

    pub(super) fn collect(&self, events: &[u8], diagnostics: &[u8], success: bool) -> Collected {
        let mut output = Collected {
            log: (!diagnostics.is_empty()).then(|| bounded_log(String::from_utf8_lossy(diagnostics).into_owned())),
            ..Collected::default()
        };
        let Some((mut observed, final_result)) = parse(self.provider, events) else {
            output.failure = Some("malformed_runtime_output");
            return output;
        };
        if observed.version.as_deref().is_some_and(|version| version != self.version) {
            output.failure = Some("runtime_version_changed");
        }
        observed.family = observed.model.as_deref()
            .and_then(|model| runtimes::observed_provider_family(agent(self.provider), model));
        output.observed = observed;
        if !success {
            return output;
        }
        if output.failure.is_none() {
            match self.provider {
                Provider::Claude => output.result(final_result.map(String::into_bytes)),
                Provider::Codex => {
                    // A fixed artifact name scoped to this fresh, private attempt folder.
                    // SAFETY: geteuid identifies the account that owns the private artifact.
                    if let Ok(file) = private_file(&self.path().join(RESULT), unsafe { libc::geteuid() }, false)
                        && let Ok(meta) = file.metadata()
                    {
                        if bounded_regular_artifact(&meta, RESULT_LIMIT) {
                            output.result(bounded(file, RESULT_LIMIT + 1).ok());
                        } else if meta.nlink() == 1 && meta.len() > RESULT_LIMIT as u64 {
                            output.truncated = true;
                        }
                    }
                }
            }
            if output.result.is_none() {
                output.failure = Some(if output.truncated { "result_truncated" } else { "missing_result" });
            }
        }
        output
    }
}

#[derive(Default)]
pub(super) struct Observed {
    pub model: Option<String>,
    pub family: Option<&'static str>,
    pub effort: Option<String>,
    pub version: Option<String>,
}

#[derive(Default)]
pub(super) struct Collected {
    pub log: Option<String>,
    pub result: Option<String>,
    pub truncated: bool,
    pub failure: Option<&'static str>,
    pub observed: Observed,
}

impl Collected {
    fn result(&mut self, artifact: Option<Vec<u8>>) {
        self.truncated = artifact.as_ref().is_some_and(|bytes| bytes.len() > RESULT_LIMIT);
        if !self.truncated {
            self.result = artifact.and_then(|bytes| String::from_utf8(bytes).ok())
                .filter(|text| !text.trim().is_empty() && !text.contains('\0'));
        }
    }
}

#[derive(Deserialize, Serialize)]
struct Invocation {
    provider: Provider,
    home: PathBuf,
    model: Option<String>,
    effort: Option<String>,
}

impl Invocation {
    fn args(&self, dir: &Path) -> Vec<std::ffi::OsString> {
        let mut args: Vec<_> = match self.provider {
            Provider::Claude => ["--print", "--output-format", "stream-json", "--verbose", "--permission-mode", "plan"]
                .into_iter().map(Into::into).collect(),
            Provider::Codex => ["exec", "--json", "--sandbox", "read-only", "--color", "never", "--skip-git-repo-check", "--output-last-message"]
                .into_iter().map(Into::into).chain([dir.join(RESULT).into_os_string()]).collect(),
        };
        if let Some(model) = &self.model {
            args.extend(["--model".into(), model.into()]);
        }
        if let Some(effort) = &self.effort {
            match self.provider {
                Provider::Claude => args.extend(["--effort".into(), effort.into()]),
                Provider::Codex => args.extend(["-c".into(), format!("model_reasoning_effort=\"{effort}\"").into()]),
            }
        }
        if self.provider == Provider::Codex {
            args.push("-".into());
        }
        args
    }
}

pub(super) fn exec(dir: &Path, stdout: OwnedFd, stderr: OwnedFd) -> Result<()> {
    let mut release = [0];
    if io::stdin().read_exact(&mut release).is_err() || release != [RELEASE] {
        return Ok(());
    }
    // SAFETY: this gated child owns its process-wide mask.
    let owner = unsafe {
        libc::umask(0o077);
        libc::geteuid()
    };
    let invocation: Invocation = serde_json::from_slice(&bounded(private_file(&dir.join("invocation.json"), owner, false)?, 4096)?)?;
    let brief = private_file(&dir.join("brief"), owner, false)?;
    Err(Command::new(dir.join("runner"))
        .args(invocation.args(dir))
        .env_clear()
        .env("HOME", &invocation.home)
        .env("PATH", "/usr/bin:/bin")
        .env("LC_ALL", "C")
        .stdin(Stdio::from(brief))
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr))
        .exec().into())
}

#[derive(Deserialize)]
struct Event {
    #[serde(rename = "type")]
    kind: String,
    subtype: Option<String>,
    model: Option<String>,
    effort: Option<String>,
    claude_code_version: Option<String>,
    result: Option<String>,
    is_error: Option<bool>,
}

fn parse(provider: Provider, bytes: &[u8]) -> Option<(Observed, Option<String>)> {
    if bytes.len() > EVENTS_LIMIT {
        return None;
    }
    let mut observed = None;
    let mut terminal = false;
    let mut result = None;
    for line in std::str::from_utf8(bytes).ok()?.lines() {
        let event: Event = serde_json::from_str(line).ok()?;
        if terminal {
            return None;
        }
        match (provider, event.kind.as_str(), event.subtype.as_deref()) {
            (Provider::Claude, "system", Some("init")) => {
                if observed.is_some() {
                    return None;
                }
                observed = Some(Observed {
                    model: event.model.filter(|value| runtimes::model_discovery::launchable_model(agent(provider), value)),
                    effort: event.effort.filter(|value| effort_supported(provider, value)),
                    version: event.claude_code_version.filter(|value| value.len() <= 80 && identifier_version(value)),
                    family: None,
                });
            }
            (Provider::Claude, "result", _) => {
                if event.is_error != Some(false) || event.subtype.as_deref() != Some("success") {
                    return None;
                }
                result = event.result;
                terminal = true;
            }
            // Codex exec JSON has completion and usage events, but no
            // resolved model, reasoning effort or CLI version observation.
            (Provider::Codex, "turn.completed", _) => terminal = true,
            (Provider::Codex, "error" | "turn.failed", _) => return None,
            _ => {}
        }
    }
    terminal.then(|| (observed.unwrap_or_default(), result))
}

fn effort_supported(provider: Provider, effort: &str) -> bool {
    match provider {
        Provider::Claude => matches!(effort, "low" | "medium" | "high" | "max"),
        Provider::Codex => matches!(effort, "minimal" | "low" | "medium" | "high" | "xhigh"),
    }
}

fn identifier_version(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || b".-_+".contains(&byte))
}

fn agent(provider: Provider) -> runtimes::ModelAgent {
    match provider {
        Provider::Claude => runtimes::ModelAgent::Claude,
        Provider::Codex => runtimes::ModelAgent::Codex,
    }
}

// Keep log bytes bounded even when replacement characters expand invalid UTF-8.
fn bounded_log(mut text: String) -> String {
    let mut end = LOG_LIMIT.min(text.len());
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn args(provider: Provider, model: &str, effort: &str) -> Vec<String> {
        Invocation {
            provider,
            home: "/private/fixture-home".into(),
            model: Some(model.into()),
            effort: Some(effort.into()),
        }.args(Path::new("/private/attempt")).into_iter()
            .map(|word| word.into_string().unwrap()).collect()
    }

    #[test]
    fn gapplan_09_unit_claude_uses_fixed_arguments() {
        assert_eq!(args(Provider::Claude, "claude-sonnet-5", "high"), [
            "--print", "--output-format", "stream-json", "--verbose", "--permission-mode", "plan",
            "--model", "claude-sonnet-5", "--effort", "high",
        ]);
    }

    #[test]
    fn gapplan_09_unit_codex_uses_fixed_arguments_and_stdin() {
        assert_eq!(args(Provider::Codex, "gpt-6.1-sol", "xhigh"), [
            "exec", "--json", "--sandbox", "read-only", "--color", "never", "--skip-git-repo-check",
            "--output-last-message", "/private/attempt/result.md", "--model", "gpt-6.1-sol",
            "-c", "model_reasoning_effort=\"xhigh\"", "-",
        ]);
    }

    #[test]
    fn gapplan_09_unit_rejects_overlong_briefs_and_invalid_argument_values() {
        let mut request = Request { profile: "fixture".into(), brief: "a".repeat(BRIEF_LIMIT) };
        let valid = |request: &Request| request.valid(Provider::Codex, Some("gpt-6.1-sol"), Some("high"));
        assert!(valid(&request));
        request.brief.push('a');
        assert!(!valid(&request));
        request.brief = "--not-an-option\n$(literal data)".into();
        assert!(valid(&request));
        assert!(!request.valid(Provider::Codex, Some("--help"), Some("high")));
        assert!(!request.valid(Provider::Codex, None, Some("high\" --help")));
        request.profile = "../fixture".into();
        assert!(!valid(&request));
    }

    #[test]
    fn gapplan_09_unit_output_requires_a_complete_unambiguous_terminal_stream() {
        let output = |events: &[serde_json::Value]| {
            events.iter().map(serde_json::Value::to_string).collect::<Vec<_>>().join("\n")
        };
        let init = json!({"type":"system","subtype":"init","model":"claude-sonnet-5","claude_code_version":"1.2.3"});
        let done = json!({"type":"result","subtype":"success","is_error":false,"result":"fixture"});
        let good = output(&[init.clone(), done.clone()]);
        let (observed, result) = parse(Provider::Claude, good.as_bytes()).unwrap();
        assert_eq!(observed.model.as_deref(), Some("claude-sonnet-5"));
        assert_eq!(observed.version.as_deref(), Some("1.2.3"));
        assert_eq!(result.as_deref(), Some("fixture"));
        for events in [&[init.clone()][..], &[done.clone(), init.clone()], &[init.clone(), init, done]] {
            assert!(parse(Provider::Claude, output(events).as_bytes()).is_none());
        }
        assert!(parse(Provider::Codex, b"{\"type\":\"turn.completed\"}\n{}").is_none());
        assert!(parse(Provider::Codex, &vec![b' '; EVENTS_LIMIT + 1]).is_none());
        let (unknown, _) = parse(Provider::Codex, b"{\"type\":\"turn.completed\"}").unwrap();
        assert!(unknown.model.is_none());
        assert_eq!(bounded_log("🦀".repeat(LOG_LIMIT)).len(), LOG_LIMIT);
    }
}
