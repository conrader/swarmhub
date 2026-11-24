//! `swarmhub-herdr service …`: the workspace server as something a Mac keeps running by itself.
//!
//! A person who has only the Mac app picks **This Mac**. The app fetches this program from the signed release,
//! checks it, puts it in `~/.local/bin` and runs `service install`. Everything after that is here, so that it can
//! be run, read and tested without the app:
//!
//! - `service status` says what is on this computer: Herdr Core, the agent programs, the access key, the job that
//!   keeps the server running. It changes nothing.
//! - `service install` gets Herdr Core when it is missing (from Herdr's own releases, and only a build signed by
//!   Herdr's Apple team), makes the access key, writes one starter template per agent program it finds, and has
//!   launchd start the server now and at every login (a per-user agent in `~/Library/LaunchAgents`).
//! - `service run` is what launchd starts: it finds the person's own `PATH`, starts Herdr Core when it is not
//!   running, and becomes the server. It keeps looking after Core while it runs.
//! - `service remove` stops the server and takes away what `install` put there. Conversations stay.
//!
//! `run` needs nothing of macOS, and replaces the start script on Linux too. `install` and `remove` are macOS
//! only; elsewhere they say so.
//!
//! Every command prints one JSON object with `--json`: `ok`, and on a refusal `error` (a sentence a person can
//! read) and `kind` (a word an app can act on): `not_macos`, `no_session`, `port_busy`, `core_download`,
//! `core_signature`, `core_install`, `not_started`, `failed`.

use crate::{
    history,
    skillshare::{Ran, Trouble, run_program},
    update,
};
use ring::rand::{SecureRandom, SystemRandom};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    env,
    ffi::OsString,
    fs,
    io::{self, Write},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// The launchd job, unless `--label` (or the job's own setting) names another.
const LABEL: &str = "com.konrad.agentapp.service";
/// Set in the job, so the server knows who restarts it (`supervised`).
pub(crate) const LABEL_ENV: &str = "SWARMHUB_SERVICE_LABEL";
/// Names the folders to look for programs in, in place of asking the person's shell: for an account whose shell
/// cannot be asked, and for checks.
const PATH_ENV: &str = "SWARMHUB_SERVICE_PATH";
/// The `PATH` every agent is started with, when the server was started by `service run`.
pub(crate) const AGENT_PATH_ENV: &str = "SWARMHUB_AGENT_PATH";
const DEFAULT_PORT: u16 = 8787;
/// Settings the job keeps from the command that installed it, so a server set up with them starts with them.
const CARRIED: [&str; 9] = [
    PATH_ENV,
    "XDG_CONFIG_HOME",
    "XDG_STATE_HOME",
    "SWARMHUB_DATA_DIR",
    "SWARMHUB_AGENT_CWD",
    "SWARMHUB_UPDATE_FEED",
    "HC_SESSION",
    "HC_SOCKET",
    "HERDR_RELEASES_URL",
];
/// Herdr's own releases, and the signature every macOS build of Herdr Core from there carries.
const CORE_RELEASES: &str = "https://releases.herdr.dev";
const CORE_SIGNED_BY: &str = "identifier \"dev.herdr.core\" and anchor apple generic and certificate leaf[subject.OU] = \"2W9652Q7QR\"";
const CORE_BUNDLE: &str = "Herdr Core.app";
const MAX_CORE: usize = 256 * 1024 * 1024;

type Failed = Box<dyn std::error::Error>;

/// Why a command ends without doing what was asked.
#[derive(Debug)]
struct Stop {
    kind: &'static str,
    message: String,
}

impl Stop {
    fn new(kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            kind,
            message: message.into(),
        }
    }

    fn failed(message: impl Into<String>) -> Self {
        Self::new("failed", message)
    }
}

// MARK: The agent programs

/// An agent program the workspace has a wrapper for, and the starter template it gets.
struct Program {
    id: &'static str,
    /// What people call it, and its full name.
    name: &'static str,
    full: &'static str,
    /// The command it is started by.
    bin: &'static str,
    template: &'static str,
    /// What follows this program's path in the template's command.
    wrapper: &'static str,
    description: &'static str,
    /// What to do when it is not on this computer.
    how: &'static str,
    /// What it asks a person the first time it starts for this server, and what the answer allows. `{folder}` is
    /// the folder the bots work in. Only the person answers; the server never does.
    first_time: &'static str,
}

const PROGRAMS: [Program; 5] = [
    Program {
        id: "claude",
        name: "Claude",
        full: "Claude Code",
        bin: "claude",
        template: "swarmhub-claude",
        wrapper: "run-claude --workspace-approvals --workspace-preview",
        description: "Claude Code with replies saved to SwarmHub",
        how: "Install Claude Code from claude.com/claude-code, then open Terminal, type claude, and sign in.",
        first_time: "SwarmHub prepares Claude Code’s folder trust for each private workspace it creates.",
    },
    Program {
        id: "codex",
        name: "Codex",
        full: "Codex",
        bin: "codex",
        template: "swarmhub-codex",
        wrapper: "run-codex --workspace-approvals",
        description: "Codex with replies saved to SwarmHub",
        how: "Install Codex from developers.openai.com/codex, then open Terminal, type codex, and sign in.",
        first_time: "The first time, Codex asks you to review three small commands that SwarmHub adds so the app can show Codex’s steps and save its replies. They only report what Codex does. “Trust all and continue” lets Codex run them.",
    },
    Program {
        id: "opencode",
        name: "OpenCode",
        full: "OpenCode",
        bin: "opencode",
        template: "swarmhub-opencode",
        wrapper: "run-opencode --workspace-approvals --api-first-task mini",
        description: "OpenCode with your configured API provider",
        how: "Install OpenCode V2.3 or later, connect your provider in OpenCode, then run opencode models to see its model IDs.",
        first_time: "Configure and try your provider in OpenCode on this computer first.",
    },
    // In beta, and last: a program earlier in this list is the one chosen by default.
    Program {
        id: "gemini",
        name: "Gemini (beta)",
        full: "Gemini CLI",
        bin: "gemini",
        template: "swarmhub-gemini",
        wrapper: "run-gemini",
        description: "Gemini CLI (beta) with replies saved to SwarmHub",
        how: "Install Gemini CLI with npm install -g @google/gemini-cli, then open Terminal, type gemini, and sign in.",
        first_time: "Sign in to Gemini CLI in Terminal before its first chat; a bot cannot answer the sign-in question. SwarmHub keeps a small settings file, .gemini/settings.json, in each private workspace it creates, so the app can show Gemini’s steps and save its replies. Gemini CLI mentions these hooks once in its terminal and runs them; they only report what Gemini does.",
    },
    Program {
        id: "antigravity",
        name: "Gemini (Antigravity)",
        full: "Antigravity CLI",
        bin: "agy",
        template: "swarmhub-antigravity",
        wrapper: "run-antigravity",
        description: "Gemini through Google Antigravity CLI",
        how: "Install Antigravity CLI from antigravity.google and sign in with agy in Terminal.",
        first_time: "Sign in to Antigravity CLI on this Mac before starting a chat. Permissions appear in its terminal.",
    },
];

/// The model list a fresh install starts with (`runtime-catalog.json`, which the person may edit): Codex is asked
/// for its own models; Claude Code has no way to ask, so its model names are listed. Gemini CLI's are its own
/// short names for "the current one of this kind", so the list does not go stale with each model.
const STARTER_CATALOG: &str = r#"{
  "swarmhub-claude": {
    "harness": "Claude Code",
    "provider": "Anthropic",
    "models": [
      {"id": "sonnet", "label": "Sonnet 5.5", "provider": "Anthropic"},
      {"id": "fable", "label": "Fable 5.2", "provider": "Anthropic"},
      {"id": "opus", "label": "Opus 5.5", "provider": "Anthropic"},
      {"id": "haiku", "label": "Haiku 5.5", "provider": "Anthropic"}
    ]
  },
  "swarmhub-antigravity": {"harness":"Antigravity CLI","provider":"Google","discover_models":true},
  "swarmhub-opencode": {
    "harness": "OpenCode",
    "discover_models": true
  },
  "swarmhub-codex": {
    "harness": "Codex",
    "provider": "OpenAI",
    "discover_models": true
  },
  "swarmhub-gemini": {
    "harness": "Gemini CLI",
    "provider": "Google",
    "models": [
      {"id": "auto", "label": "Auto", "provider": "Google"},
      {"id": "pro", "label": "Pro", "provider": "Google"},
      {"id": "flash", "label": "Flash", "provider": "Google"},
      {"id": "flash-lite", "label": "Flash-Lite", "provider": "Google"}
    ]
  }
}
"#;

fn executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0)
}

fn find(name: &str, folders: &[PathBuf]) -> Option<PathBuf> {
    folders
        .iter()
        .map(|folder| folder.join(name))
        .find(|path| executable(path))
}

/// The template file's text. The command is this program's own path and a wrapper, with nothing a shell would
/// have to interpret, so the workspace recognises the agent program and can pass it a model.
fn template_text(program: &Program, exe: &Path) -> String {
    let exe = exe.to_string_lossy();
    let plain = exe
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b"/._-+@".contains(&byte));
    let exe = if plain {
        exe.into_owned()
    } else {
        crate::agent::shell_quote(&exe)
    };
    format!(
        "---\ndescription: {}\ncommand: {exe} {}\n---\n",
        program.description, program.wrapper
    )
}

// MARK: Where things are

struct Places {
    home: PathBuf,
    exe: PathBuf,
    token: PathBuf,
    templates: PathBuf,
    data: PathBuf,
    agents: PathBuf,
}

fn setting(name: &str) -> Option<OsString> {
    env::var_os(name).filter(|value| !value.is_empty())
}

impl Places {
    fn from_env() -> Result<Self, Stop> {
        let home = setting("HOME")
            .map(PathBuf::from)
            .filter(|home| home.is_absolute())
            .ok_or_else(|| Stop::failed("HOME is not set, so there is no place to set up."))?;
        let config = setting("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .filter(|folder| folder.is_absolute())
            .unwrap_or_else(|| home.join(".config"));
        let exe = env::current_exe()
            .and_then(|path| path.canonicalize())
            .map_err(|_| Stop::failed("This program cannot tell where it is installed."))?;
        Ok(Self {
            token: config.join("swarmhub-herdr/token"),
            templates: config.join("herdr-core/templates"),
            data: history::private_directory().map_err(|error| Stop::failed(error.to_string()))?,
            agents: setting("SWARMHUB_AGENT_CWD")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("swarmhub-agents")),
            home,
            exe,
        })
    }

    fn job(&self, label: &str) -> PathBuf {
        self.home
            .join("Library/LaunchAgents")
            .join(format!("{label}.plist"))
    }

    fn log(&self) -> PathBuf {
        self.data.join("service.log")
    }
}

/// Herdr Core's socket, by Core's own rule: `HC_SOCKET`; else `<session>.sock` in `$XDG_RUNTIME_DIR/herdr-core`,
/// in `/run/user/<uid>/herdr-core` where that folder exists, or in the session's state folder (macOS).
fn core_socket(
    home: &Path,
    get: impl Fn(&str) -> Option<OsString>,
    run_user: Option<PathBuf>,
) -> PathBuf {
    if let Some(socket) = get("HC_SOCKET") {
        return socket.into();
    }
    let session = core_session(&get);
    let name = format!("{session}.sock");
    if let Some(run) = get("XDG_RUNTIME_DIR").map(PathBuf::from).or(run_user) {
        return run.join("herdr-core").join(name);
    }
    core_state_directory(home, &get, &session).join(name)
}

fn core_session(get: &impl Fn(&str) -> Option<OsString>) -> String {
    get("HC_SESSION")
        .and_then(|session| session.into_string().ok())
        .map(|session| session.trim().to_owned())
        .filter(|session| !session.is_empty())
        .unwrap_or_else(|| "default".into())
}

fn core_state_directory(home: &Path, get: &impl Fn(&str) -> Option<OsString>, session: &str) -> PathBuf {
    get("XDG_STATE_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| home.join(".local/state"))
        .join("herdr-core")
        .join(session)
}

/// Core stores attachments in its session's state directory, even with a custom socket path.
pub(crate) fn core_files_directory() -> Option<PathBuf> {
    let home = PathBuf::from(setting("HOME")?);
    let session = core_session(&setting);
    if session == "." || session == ".." || session.contains('/') {
        return None;
    }
    let state = core_state_directory(&home, &setting, &session);
    if !state.is_absolute() || !fs::symlink_metadata(&state).is_ok_and(|meta| meta.is_dir()) {
        return None;
    }
    let files = state.join("files");
    // A warm bot may start before the first upload, when Core hasn't created this directory yet.
    match fs::DirBuilder::new().mode(0o700).create(&files) {
        Ok(()) => Some(files),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            fs::symlink_metadata(&files).ok()?.is_dir().then_some(files)
        }
        Err(_) => None,
    }
}

fn core_socket_here(home: &Path) -> PathBuf {
    // SAFETY: the call only reads this process's user id.
    let run = PathBuf::from(format!("/run/user/{}", unsafe { libc::getuid() }));
    core_socket(home, setting, run.is_dir().then_some(run))
}

// MARK: The person's PATH

const PATH_MARK: &str = "__SWARMHUB_PATH__";

/// Where programs a person installs for themselves usually are, for when their shell cannot be asked.
fn usual_folders(home: &Path) -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = [
        ".local/bin",
        "bin",
        ".bun/bin",
        ".npm-global/bin",
        ".volta/bin",
        ".cargo/bin",
        ".claude/local",
        ".opencode/bin",
    ]
    .iter()
    .map(|folder| home.join(folder))
    .collect();
    folders.extend(
        [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        .iter()
        .map(PathBuf::from),
    );
    folders
}

/// The account's own shell, from the account: a job started by launchd has no `SHELL`.
fn login_shell() -> Option<PathBuf> {
    account(|entry| entry.pw_shell)
        .or_else(|| setting("SHELL").map(PathBuf::from))
        .filter(|shell| shell.is_absolute() && executable(shell))
}

/// One path of the account's own record (its shell, its home folder).
fn account(field: impl Fn(&libc::passwd) -> *mut libc::c_char) -> Option<PathBuf> {
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut text = vec![0 as libc::c_char; 16 * 1024];
    let mut found = std::ptr::null_mut();
    // SAFETY: each pointer is to a live buffer of the size given, and the entry is read only when one was found.
    unsafe {
        let status = libc::getpwuid_r(
            libc::getuid(),
            entry.as_mut_ptr(),
            text.as_mut_ptr(),
            text.len(),
            &mut found,
        );
        if status != 0 || found.is_null() {
            return None;
        }
        let value = field(&*found);
        (!value.is_null()).then(|| {
            PathBuf::from(
                std::ffi::CStr::from_ptr(value)
                    .to_string_lossy()
                    .into_owned(),
            )
        })
    }
}

/// The `PATH` the person's shell has when they open a terminal, read by asking that shell once. `None` when it
/// does not answer in time or says nothing usable.
fn shell_path() -> Option<String> {
    let shell = login_shell()?;
    let print = if shell.file_name().is_some_and(|name| name == "fish") {
        format!("printf '{PATH_MARK}%s{PATH_MARK}' (string join : $PATH)")
    } else {
        format!("printf '{PATH_MARK}%s{PATH_MARK}' \"$PATH\"")
    };
    let arguments = ["-l".to_owned(), "-i".to_owned(), "-c".to_owned(), print];
    let ran = run_program(&shell, &arguments, &[], Duration::from_secs(10)).ok()?;
    marked_path(&ran.out)
}

/// What the shell printed between the marks, when it is a list of absolute folders.
fn marked_path(output: &str) -> Option<String> {
    let path = output.split(PATH_MARK).nth(1)?;
    let sane = !path.is_empty()
        && path.len() <= 16 * 1024
        && !path.chars().any(char::is_control)
        && path.split(':').any(|folder| folder.starts_with('/'));
    sane.then(|| path.to_owned())
}

/// The shell's folders first and in its order, then the usual ones it did not name. Only absolute folders, once.
fn merged_path(shell: Option<&str>, usual: &[PathBuf]) -> Vec<PathBuf> {
    let mut folders: Vec<PathBuf> = Vec::new();
    let named = shell
        .into_iter()
        .flat_map(|path| path.split(':'))
        .map(PathBuf::from);
    for folder in named.chain(usual.iter().cloned()) {
        if folder.is_absolute() && !folders.contains(&folder) {
            folders.push(folder);
        }
    }
    folders
}

fn search_folders(home: &Path) -> Vec<PathBuf> {
    if let Some(chosen) = setting(PATH_ENV).and_then(|path| path.into_string().ok()) {
        return merged_path(Some(&chosen), &[]);
    }
    merged_path(shell_path().as_deref(), &usual_folders(home))
}

/// A program added after the service started may live in a newly installed shell PATH entry.
pub(crate) fn agent_command(name: &str, setting_name: &str) -> std::process::Command {
    if let Some(exe) = setting(setting_name) { return std::process::Command::new(exe); }
    let mut command = std::process::Command::new(name);
    if setting("SWARMHUB_LAUNCH_KEY").is_some() && let Some(path) = env::var_os("PATH")
        && !env::split_paths(&path).any(|dir| executable(&dir.join(name)))
        && let Some(home) = setting("HOME") {
        let folders = search_folders(Path::new(&home));
        if find(name, &folders).is_some() { command.env("PATH", joined(&folders)); }
    }
    command
}

fn joined(folders: &[PathBuf]) -> String {
    env::join_paths(folders)
        .ok()
        .and_then(|path| path.into_string().ok())
        .unwrap_or_default()
}

// MARK: Herdr Core

fn hc(folders: &[PathBuf]) -> Option<PathBuf> {
    find("hc", folders).or_else(|| find("herdr-core", folders))
}

fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| word.to_string()).collect()
}

fn said(ran: &Result<Ran, Trouble>) -> String {
    match ran {
        Ok(ran) => ran
            .err
            .lines()
            .chain(ran.out.lines())
            .map(str::trim)
            .rfind(|line| !line.is_empty())
            .unwrap_or("it ended without saying why")
            .chars()
            .take(300)
            .collect(),
        Err(Trouble::Start) => "it could not be started".into(),
        Err(Trouble::Slow(limit)) => format!("it did not finish in {} seconds", limit.as_secs()),
        Err(Trouble::Flood) => "it printed more than is read".into(),
    }
}

fn core_listens(socket: &Path) -> bool {
    std::os::unix::net::UnixStream::connect(socket).is_ok()
}

/// Starts Herdr Core unless it listens already, and waits until it does. Core keeps running by itself after that.
fn start_core(hc: &Path, socket: &Path, path: &str) -> Result<(), Stop> {
    if core_listens(socket) {
        return Ok(());
    }
    let ran = run_program(
        hc,
        &words(&["server", "start", "--json"]),
        &[("PATH", path), (crate::vault::KEY_FILE, "")],
        Duration::from_secs(60),
    );
    let until = Instant::now() + Duration::from_secs(15);
    while !core_listens(socket) {
        if Instant::now() >= until {
            return Err(Stop::new(
                "core_start",
                format!(
                    "Herdr Core did not start listening at {} ({}).",
                    socket.display(),
                    said(&ran)
                ),
            ));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Ok(())
}

fn core_version(hc: &Path) -> Option<String> {
    let ran = run_program(hc, &words(&["--version"]), &[], Duration::from_secs(15)).ok()?;
    let version = ran.out.trim().strip_prefix("hc ").unwrap_or(ran.out.trim());
    (ran.ok && !version.is_empty() && version.len() <= 40).then(|| version.to_owned())
}

/// The part of Herdr's release description that is read: where this machine's archive is, and its digest.
#[derive(Deserialize)]
struct CoreRelease {
    version: String,
    targets: BTreeMap<String, CoreArchive>,
}

#[derive(Debug, Deserialize)]
struct CoreArchive {
    url: String,
    sha256: String,
}

/// Herdr's name for this kind of machine: `macos-aarch64`, `linux-x86_64`.
fn core_target() -> String {
    format!("{}-{}", env::consts::OS, env::consts::ARCH)
}

fn core_archive(
    manifest: &[u8],
    releases: &str,
    target: &str,
) -> Result<(String, CoreArchive), Stop> {
    let unreadable = || {
        Stop::new(
            "core_download",
            "Herdr's release description could not be read, so Herdr Core was not installed.",
        )
    };
    let mut release: CoreRelease = serde_json::from_slice(manifest).map_err(|_| unreadable())?;
    let archive = release.targets.remove(target).ok_or_else(|| {
        Stop::new(
            "core_download",
            format!("Herdr Core has no build for this kind of machine ({target})."),
        )
    })?;
    let plain = archive.sha256.len() == 64
        && archive.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        && archive
            .url
            .starts_with(&format!("{}/", releases.trim_end_matches('/')))
        && !archive.url.contains("..")
        && !release.version.is_empty()
        && release.version.len() <= 40;
    if plain {
        Ok((release.version, archive))
    } else {
        Err(unreadable())
    }
}

async fn download(address: &str, limit: usize) -> Result<Vec<u8>, Stop> {
    let unreachable = || {
        Stop::new(
            "core_download",
            format!(
                "This Mac could not download Herdr Core from {address}. Check the internet connection and try again."
            ),
        )
    };
    let mut builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(600));
    if address.starts_with("http://") {
        builder = builder.no_proxy();
    }
    let mut response = builder
        .build()
        .map_err(|_| unreachable())?
        .get(address)
        .send()
        .await
        .ok()
        .filter(|response| response.status().is_success())
        .ok_or_else(unreachable)?;
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| unreachable())? {
        if body.len() + chunk.len() > limit {
            return Err(unreachable());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Installs Herdr Core the way Herdr's own installer does for a person's account, with one check more before
/// anything of it runs: the archive must have the digest Herdr's release names, and the app inside must be signed
/// by Herdr's Apple team. Returns the version and where `hc` now is.
async fn install_core(home: &Path) -> Result<(String, PathBuf), Stop> {
    if env::consts::OS != "macos" {
        return Err(Stop::new(
            "core_install",
            "Herdr Core is not installed. Install it with Herdr's own installer (curl -fsSL https://releases.herdr.dev/core/install.sh | sh), then try again.",
        ));
    }
    let releases = setting("HERDR_RELEASES_URL")
        .and_then(|value| value.into_string().ok())
        .unwrap_or_else(|| CORE_RELEASES.into());
    let own = releases.trim_end_matches('/') == CORE_RELEASES;
    if !(own || releases.starts_with("http://127.0.0.1:")) {
        return Err(Stop::new(
            "core_download",
            "HERDR_RELEASES_URL must be Herdr's own releases, or http on 127.0.0.1 for a check.",
        ));
    }
    let manifest = download(
        &format!("{}/core/latest.json", releases.trim_end_matches('/')),
        256 * 1024,
    )
    .await?;
    let (version, archive) = core_archive(&manifest, &releases, &core_target())?;
    let bytes = download(&archive.url, MAX_CORE).await?;
    let digest: String = Sha256::digest(&bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    if !digest.eq_ignore_ascii_case(&archive.sha256) {
        return Err(Stop::new(
            "core_signature",
            "The Herdr Core download is not the file Herdr's release describes, so it was not installed.",
        ));
    }
    let broken = |what: &str| {
        Stop::new(
            "core_install",
            format!("Herdr Core could not be installed: {what}."),
        )
    };
    let scratch = tempfile::Builder::new()
        .prefix("swarmhub-core-")
        .tempdir()
        .map_err(|_| broken("no temporary folder"))?;
    let packed = scratch.path().join("core.tar.gz");
    fs::write(&packed, &bytes).map_err(|_| broken("the download could not be saved"))?;
    let folder = scratch.path().join("core");
    fs::create_dir(&folder).map_err(|_| broken("no temporary folder"))?;
    let unpack = run_program(
        Path::new("/usr/bin/tar"),
        &[
            "-xzf".into(),
            packed.to_string_lossy().into_owned(),
            "-C".into(),
            folder.to_string_lossy().into_owned(),
        ],
        &[],
        Duration::from_secs(120),
    );
    if !unpack.as_ref().is_ok_and(|ran| ran.ok) {
        return Err(broken(&format!(
            "the archive could not be unpacked ({})",
            said(&unpack)
        )));
    }
    let bundle = folder.join(CORE_BUNDLE);
    let program = bundle.join("Contents/MacOS/herdr-core");
    if !executable(&program) {
        return Err(broken("this release has no Herdr Core app in it"));
    }
    // Herdr's own releases are signed by Herdr's Apple team, and nothing of them runs before that is checked.
    // A check's local folder holds an ad-hoc build, which must still be an intact one with Herdr Core's name.
    let requirement = if own {
        format!("={CORE_SIGNED_BY}")
    } else {
        "=identifier \"dev.herdr.core\"".to_owned()
    };
    if !matches_core_signature(&bundle, &requirement) {
        return Err(Stop::new(
            "core_signature",
            "The Herdr Core download is not signed by Herdr, so it was not installed.",
        ));
    }
    let bin = home.join(".local/bin");
    fs::create_dir_all(&bin).map_err(|_| broken("~/.local/bin could not be made"))?;
    let installed = bin.join("herdr-core");
    // The step Herdr's installer takes for a new install: the app installs itself and leaves its command here.
    let ran = run_program(
        &program,
        &[
            "--hc-install-bundle".into(),
            program.to_string_lossy().into_owned(),
            installed.to_string_lossy().into_owned(),
        ],
        &[],
        Duration::from_secs(180),
    );
    if !ran.as_ref().is_ok_and(|ran| ran.ok) || !executable(&installed) {
        return Err(broken(&said(&ran)));
    }
    let short = bin.join("hc");
    if fs::symlink_metadata(&short).is_err() {
        let _ = std::os::unix::fs::symlink("herdr-core", &short);
    }
    Ok((version, installed))
}

fn matches_core_signature(path: &Path, requirement: &str) -> bool {
    run_program(
        Path::new("/usr/bin/codesign"),
        &[
            "--verify".into(),
            "--strict".into(),
            "-R".into(),
            requirement.into(),
            path.to_string_lossy().into_owned(),
        ],
        &[],
        Duration::from_secs(30),
    )
    .is_ok_and(|ran| ran.ok)
}

// MARK: The access key, the templates, the model list

fn random_hex(bytes: usize) -> Result<String, Stop> {
    let mut random = vec![0_u8; bytes];
    SystemRandom::new()
        .fill(&mut random)
        .map_err(|_| Stop::failed("This computer gave no random numbers for the access key."))?;
    Ok(random.iter().map(|byte| format!("{byte:02x}")).collect())
}

fn valid_token(token: &str) -> bool {
    token.len() == 64 && token.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn private_folder(folder: &Path) -> std::io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(folder)
}

/// Writes a file in one step, for the account alone, replacing what was there.
fn write_private(path: &Path, text: &str, mode: u32) -> std::io::Result<()> {
    let draft = path.with_extension("new");
    let _ = fs::remove_file(&draft);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .open(&draft)?;
    file.write_all(text.as_bytes())?;
    file.sync_all()?;
    fs::rename(draft, path)
}

/// The starter model list, and in a list written earlier the entries of the programs that came later
/// (`added`, by template name) when it has none for them. What the person wrote is kept.
fn install_catalog(file: &Path, added: &[&str]) -> std::io::Result<bool> {
    if !file.exists() {
        write_private(file, STARTER_CATALOG, 0o600)?;
        return Ok(true);
    }
    if added.is_empty() || !file.symlink_metadata()?.is_file() {
        return Ok(false);
    }
    let mut catalog: Value = serde_json::from_slice(&fs::read(file)?)?;
    let Some(entries) = catalog.as_object_mut() else {
        return Ok(false);
    };
    let starter: Value = serde_json::from_str(STARTER_CATALOG)?;
    let mut changed = false;
    for template in added {
        if !entries.contains_key(*template)
            && let Some(entry) = starter.get(*template)
        {
            entries.insert((*template).to_owned(), entry.clone());
            changed = true;
        }
    }
    if changed {
        write_private(file, &serde_json::to_string_pretty(&catalog)?, 0o600)?;
    }
    Ok(changed)
}

/// The access key in its file; made when the file is missing or does not hold one. True when it was made now.
fn ensure_token(file: &Path) -> Result<(String, bool), Stop> {
    let kept = fs::read_to_string(file)
        .ok()
        .map(|text| text.trim().to_owned())
        .filter(|token| valid_token(token));
    if let Some(token) = kept {
        return Ok((token, false));
    }
    let unwritable = |_| {
        Stop::failed(format!(
            "The access key could not be saved in {}.",
            file.display()
        ))
    };
    private_folder(file.parent().unwrap_or(Path::new("/"))).map_err(unwritable)?;
    let token = random_hex(32)?;
    write_private(file, &format!("{token}\n"), 0o600).map_err(unwritable)?;
    Ok((token, true))
}

/// Install missing starters and upgrade the exact previous stock templates. Preserve custom templates.
fn write_templates(places: &Places, found: &[(&Program, PathBuf)]) -> Result<Vec<String>, Stop> {
    let mut written = Vec::new();
    for (program, _) in found {
        let file = places.templates.join(format!("{}.md", program.template));
        let text = template_text(program, &places.exe);
        if let Ok(meta) = file.symlink_metadata() {
            let previous = text.replacen(" --workspace-approvals", "", 1);
            if !meta.is_file() || !fs::read_to_string(&file).is_ok_and(|old| old == previous) {
                continue;
            }
        }
        fs::create_dir_all(&places.templates)
            .and_then(|_| write_private(&file, &text, 0o644))
            .map_err(|_| {
                Stop::failed(format!(
                    "The starter template could not be written to {}.",
                    file.display()
                ))
            })?;
        written.push(program.template.to_owned());
    }
    Ok(written)
}

/// Register one installed program without reinstalling the service or touching any running terminal.
fn add_ai(places: &Places, id: &str, folders: &[PathBuf]) -> Result<(), Stop> {
    let program = PROGRAMS.iter().find(|p| p.id == id)
        .ok_or_else(|| Stop::failed("Choose a supported AI program."))?;
    find(program.bin, folders).ok_or_else(|| Stop::new("not_installed", program.how))?;
    private_folder(&places.data).map_err(|e| Stop::failed(e.to_string()))?;
    let lock = fs::OpenOptions::new().write(true).create(true).truncate(false).mode(0o600)
        .open(places.data.join("add-ai.lock")).map_err(|e| Stop::failed(e.to_string()))?;
    lock.lock().map_err(|e| Stop::failed(e.to_string()))?;
    install_catalog(&places.data.join("runtime-catalog.json"), &[program.template])
        .map_err(|e| Stop::failed(format!("Could not update the AI catalog: {e}")))?;
    fs::create_dir_all(&places.templates).map_err(|e| Stop::failed(e.to_string()))?;
    let dest = places.templates.join(format!("{}.md", program.template));
    let mut draft = tempfile::NamedTempFile::new_in(&places.templates).map_err(|e| Stop::failed(e.to_string()))?;
    draft.write_all(template_text(program, &places.exe).as_bytes()).map_err(|e| Stop::failed(e.to_string()))?;
    match draft.persist_noclobber(&dest) {
        Ok(_) => {}
        Err(e) if e.error.kind() == std::io::ErrorKind::AlreadyExists && dest.is_file() => {}
        Err(e) => return Err(Stop::failed(format!("Could not add {}: {e}", program.name))),
    }
    if id == "codex" {
        let _ = first_time(places, folders);
    }
    Ok(())
}

/// Whether a template file is one `install` wrote and nobody changed since: only those are removed.
fn own_template(file: &Path, program: &Program, exe: &Path) -> bool {
    let current = template_text(program, exe);
    fs::read_to_string(file).is_ok_and(|text| {
        text == current || text == current.replacen(" --workspace-approvals", "", 1)
    })
}

// MARK: launchd

fn xml(text: &str) -> String {
    text.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

/// The job: this program with `service run`, started at login and again whenever it ends.
fn job_text(label: &str, exe: &Path, log: &Path, settings: &BTreeMap<String, String>) -> String {
    let mut env = String::new();
    for (name, value) in settings {
        env.push_str(&format!(
            "\t\t<key>{}</key>\n\t\t<string>{}</string>\n",
            xml(name),
            xml(value)
        ));
    }
    let (exe, log) = (xml(&exe.to_string_lossy()), xml(&log.to_string_lossy()));
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>{label}</string>
	<key>ProgramArguments</key>
	<array>
		<string>{exe}</string>
		<string>service</string>
		<string>run</string>
	</array>
	<key>EnvironmentVariables</key>
	<dict>
{env}	</dict>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>ThrottleInterval</key>
	<integer>10</integer>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardOutPath</key>
	<string>{log}</string>
	<key>StandardErrorPath</key>
	<string>{log}</string>
</dict>
</plist>
"#,
        label = xml(label)
    )
}

fn valid_label(label: &str) -> bool {
    (1..=100).contains(&label.len())
        && !label.starts_with('.')
        && label
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b".-_".contains(&byte))
}

fn launchctl(arguments: &[&str]) -> Result<Ran, Trouble> {
    run_program(
        Path::new("/bin/launchctl"),
        &words(arguments),
        &[],
        Duration::from_secs(30),
    )
}

/// The job as launchd names it for this account's desktop session.
fn job_target(label: &str) -> String {
    // SAFETY: the call only reads this process's user id.
    format!("gui/{}/{label}", unsafe { libc::getuid() })
}

fn job_domain() -> String {
    // SAFETY: the call only reads this process's user id.
    format!("gui/{}", unsafe { libc::getuid() })
}

/// What launchd says about the job: `None` when it does not know it, else the process it runs now, if any.
fn job_state(label: &str) -> Option<Option<u32>> {
    let ran = launchctl(&["print", &job_target(label)]).ok()?;
    ran.ok.then(|| printed_pid(&ran.out))
}

/// The `pid = 123` line of `launchctl print`.
fn printed_pid(text: &str) -> Option<u32> {
    text.lines()
        .filter_map(|line| line.trim().strip_prefix("pid = "))
        .find_map(|pid| pid.trim().parse().ok())
}

fn unload(label: &str) {
    if job_state(label).is_none() {
        return;
    }
    let _ = launchctl(&["bootout", &job_target(label)]);
    let until = Instant::now() + Duration::from_secs(20);
    while job_state(label).is_some() && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(200));
    }
}

fn load(job: &Path) -> Result<(), Stop> {
    let job = job.to_string_lossy();
    let mut ran = launchctl(&["bootstrap", &job_domain(), &job]);
    // Just after a job of this name was unloaded, launchd can refuse once.
    for _ in 0..5 {
        if ran.as_ref().is_ok_and(|ran| ran.ok) {
            return Ok(());
        }
        std::thread::sleep(Duration::from_secs(1));
        ran = launchctl(&["bootstrap", &job_domain(), &job]);
    }
    if ran.as_ref().is_ok_and(|ran| ran.ok) {
        return Ok(());
    }
    let why = said(&ran);
    if why.contains("Could not find domain") || why.contains("not supported") {
        return Err(Stop::new(
            "no_session",
            "The service is kept running by your login on this Mac. Log in at the Mac itself (not only over SSH), then try again.",
        ));
    }
    Err(Stop::failed(format!(
        "macOS did not accept the background service ({why})."
    )))
}

/// Whether anything answers HTTP on this machine's port.
fn answers(port: u16) -> bool {
    use std::io::Read;
    let address = std::net::SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, port));
    let Ok(mut stream) = std::net::TcpStream::connect_timeout(&address, Duration::from_secs(2))
    else {
        return false;
    };
    let _ = stream.set_read_timeout(Some(Duration::from_secs(3)));
    let request = format!("GET / HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n");
    let mut start = [0_u8; 5];
    stream.write_all(request.as_bytes()).is_ok()
        && stream.read_exact(&mut start).is_ok()
        && &start == b"HTTP/"
}

fn port_free(port: u16) -> bool {
    std::net::TcpListener::bind((std::net::Ipv4Addr::LOCALHOST, port)).is_ok()
}

// MARK: The commands

struct Asked {
    json: bool,
    /// The person agreed that the agent programs' first-time questions are answered for them (`first_time`).
    answer: bool,
    /// `prepare --undo`: take those answers back.
    undo: bool,
    port: Option<u16>,
    label: String,
}

fn asked(arguments: impl Iterator<Item = OsString>) -> Result<Asked, Stop> {
    const USAGE: &str = "Usage: swarmhub-herdr service status|install|run|remove|prepare|add-ai PROGRAM [--port N] [--label NAME] [--answer-first-time] [--undo] [--json]";
    let mut asked = Asked {
        json: false,
        answer: false,
        undo: false,
        port: None,
        label: setting(LABEL_ENV)
            .and_then(|label| label.into_string().ok())
            .unwrap_or_else(|| LABEL.into()),
    };
    let mut arguments = arguments.map(|argument| argument.to_string_lossy().into_owned());
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--json" => asked.json = true,
            "--answer-first-time" => asked.answer = true,
            "--undo" => asked.undo = true,
            "--port" => {
                asked.port = Some(
                    arguments
                        .next()
                        .and_then(|port| port.parse().ok())
                        .filter(|port| *port != 0)
                        .ok_or_else(|| Stop::failed(USAGE))?,
                )
            }
            "--label" => {
                asked.label = arguments
                    .next()
                    .filter(|label| valid_label(label))
                    .ok_or_else(|| Stop::failed(USAGE))?
            }
            _ => return Err(Stop::failed(USAGE)),
        }
    }
    Ok(asked)
}

/// The port the installed job starts the server on, read back from its file.
fn job_port(job: &Path) -> Option<u16> {
    let text = fs::read_to_string(job).ok()?;
    let after = text.split("<key>SWARMHUB_PORT</key>").nth(1)?;
    after
        .split("<string>")
        .nth(1)?
        .split("</string>")
        .next()?
        .trim()
        .parse()
        .ok()
}

/// What is on this computer. Reads only.
fn look(places: &Places, asked: &Asked, folders: &[PathBuf]) -> Value {
    let job = places.job(&asked.label);
    let installed = job.is_file();
    let state = if env::consts::OS == "macos" {
        job_state(&asked.label)
    } else {
        None
    };
    let port = asked
        .port
        .or_else(|| job_port(&job))
        .unwrap_or(DEFAULT_PORT);
    let hc = hc(folders);
    let socket = core_socket_here(&places.home);
    let programs: Vec<Value> = PROGRAMS
        .iter()
        .map(|program| {
            let path = find(program.bin, folders);
            json!({
                "id": program.id, "name": program.name, "full_name": program.full,
                "installed": path.is_some(), "path": path,
                "template": program.template,
                "template_written": places.templates.join(format!("{}.md", program.template)).is_file(),
                "how": program.how,
                "first_time": program.first_time.replace("{folder}", &places.agents.to_string_lossy()),
            })
        })
        .collect();
    json!({
        "version": update::VERSION,
        "target": update::target(),
        "can_add_ai": true,
        "can_install": env::consts::OS == "macos",
        "program": places.exe,
        "port": port,
        "service": {"installed": installed, "loaded": state.is_some(), "pid": state.flatten(),
                    "answers": answers(port), "label": asked.label, "job": job, "log": places.log()},
        "core": {"installed": hc.is_some(), "path": hc, "version": hc.as_deref().and_then(core_version),
                 "running": core_listens(&socket), "socket": socket},
        "programs": programs,
        "access_key": fs::read_to_string(&places.token).is_ok_and(|token| valid_token(token.trim())),
        "access_key_file": places.token,
        "agents_folder": places.agents,
        "data_folder": places.data,
    })
}

async fn install(places: &Places, asked: &Asked) -> Result<Value, Stop> {
    if env::consts::OS != "macos" {
        return Err(Stop::new(
            "not_macos",
            "service install sets up a Mac. On Linux, start the server with `swarmhub-herdr service run` from whatever keeps your programs running.",
        ));
    }
    let port = asked.port.unwrap_or(DEFAULT_PORT);
    let mut did: Vec<String> = Vec::new();
    let mut folders = search_folders(&places.home);
    if let Some(core) = hc(&folders) {
        // An explicitly supplied service PATH also supports development tools and smoke-test stand-ins.
        if setting("SWARMHUB_SERVICE_PATH").is_none()
            && !core
                .canonicalize()
                .is_ok_and(|path| matches_core_signature(&path, &format!("={CORE_SIGNED_BY}")))
        {
            return Err(Stop::new(
                "core_signature",
                format!(
                    "The Herdr Core command at {} could not be verified. Reinstall Herdr Core and try again.",
                    core.display()
                ),
            ));
        }
    } else {
        let (version, installed) = install_core(&places.home).await?;
        did.push(format!("Installed Herdr Core {version}."));
        // Herdr Core's command is in a folder of its own choosing: look there too from now on, and nowhere new.
        if let Some(folder) = installed.parent().map(Path::to_path_buf)
            && !folders.contains(&folder)
        {
            folders.push(folder);
        }
    }
    // Leave any existing service alone until the Core download and verification have completed.
    unload(&asked.label);
    if !port_free(port) {
        return Err(Stop::new(
            "port_busy",
            format!("Another program on this Mac already uses port {port}. Choose another port."),
        ));
    }
    if ensure_token(&places.token)?.1 {
        did.push("Made the access key.".into());
    }
    fs::create_dir_all(&places.agents).map_err(|_| {
        Stop::failed(format!(
            "The folder for your bots' work could not be made at {}.",
            places.agents.display()
        ))
    })?;
    private_folder(&places.data).map_err(|_| {
        Stop::failed(format!(
            "The folder for conversations could not be made at {}.",
            places.data.display()
        ))
    })?;
    let found: Vec<(&Program, PathBuf)> = PROGRAMS
        .iter()
        .filter_map(|program| Some((program, find(program.bin, &folders)?)))
        .collect();
    for template in write_templates(places, &found)? {
        did.push(format!("Wrote the starter template {template}."));
    }
    let catalog = places.data.join("runtime-catalog.json");
    // The programs that came after the first starter list.
    let later: Vec<&str> = found
        .iter()
        .filter(|(program, _)| matches!(program.id, "opencode" | "gemini" | "antigravity"))
        .map(|(program, _)| program.template)
        .collect();
    match install_catalog(&catalog, &later) {
        Ok(true) => did.push("Wrote the starter model list.".into()),
        Ok(false) => {}
        Err(_) => did.push("Could not update runtime-catalog.json. Check its JSON and permissions to enable model discovery.".into()),
    }
    let mut settings = BTreeMap::from([
        ("SWARMHUB_PORT".to_owned(), port.to_string()),
        (LABEL_ENV.to_owned(), asked.label.clone()),
    ]);
    for name in CARRIED {
        if let Some(value) = setting(name).and_then(|value| value.into_string().ok()) {
            settings.insert(name.to_owned(), value);
        }
    }
    // A home folder that is not the account's own (a check's scratch home) has to be the job's too.
    if account(|entry| entry.pw_dir).is_some_and(|home| home != places.home) {
        settings.insert(
            "HOME".to_owned(),
            places.home.to_string_lossy().into_owned(),
        );
    }
    let job = places.job(&asked.label);
    fs::create_dir_all(job.parent().unwrap_or(Path::new("/")))
        .and_then(|_| {
            write_private(
                &job,
                &job_text(&asked.label, &places.exe, &places.log(), &settings),
                0o644,
            )
        })
        .map_err(|_| {
            Stop::failed(format!(
                "The background service could not be saved in {}.",
                job.display()
            ))
        })?;
    // With the person's agreement, the questions the agent programs would ask the first time are answered now,
    // before the first agent starts. Only the programs that are here, and never more than the one bots' folder.
    let answered = asked.answer.then(|| {
        let said = first_time(places, &folders);
        did.extend(did_lines(&said));
        said
    });
    load(&job)?;
    did.push("Started the SwarmHub service. It starts again when you log in.".into());
    let until = Instant::now() + Duration::from_secs(45);
    while !answers(port) {
        if Instant::now() >= until {
            let log = fs::read_to_string(places.log()).unwrap_or_default();
            let last = log
                .lines()
                .rev()
                .find(|line| !line.trim().is_empty())
                .unwrap_or("it has written nothing yet");
            return Err(Stop::new(
                "not_started",
                format!(
                    "The service was installed but does not answer on port {port} yet. Its last line: {}",
                    last.chars().take(300).collect::<String>()
                ),
            ));
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    let mut status = look(places, asked, &folders);
    status["did"] = json!(did);
    if let Some(answered) = answered {
        status["first_time"] = answered;
    }
    Ok(status)
}

/// End only live Core instances whose launch key and identity belong to this service's journal.
async fn end_agents(places: &Places) -> usize {
    let file = places.data.join("workspace.sqlite3");
    if !file.is_file() {
        return 0;
    }
    let Ok(db) = history::connection(&file) else {
        return 0;
    };
    let core = crate::core::Core(core_socket_here(&places.home));
    let Ok(hello) = core.identify().await else {
        return 0;
    };
    let Ok(agents) = core.agents().await else {
        return 0;
    };
    let mut ended = 0;
    for agent in agents.iter().filter(|agent| agent.state == "live") {
        let Some(key) = agent.launch_key() else {
            continue;
        };
        if !owned_launch(&db, key, &hello.core.id, &agent.address, agent.created_ms) {
            continue;
        }
        if !core
            .identify()
            .await
            .is_ok_and(|current| current.core.id == hello.core.id)
        {
            break;
        }
        if let Ok(current) = core.agent(&agent.address, agent.created_ms).await
            && current.launch_key() == Some(key)
            && core.end(&current).await.is_ok()
        {
            ended += 1;
        }
    }
    ended
}

fn owned_launch(
    db: &rusqlite::Connection,
    key: &str,
    core: &str,
    address: &str,
    created: u64,
) -> bool {
    db.query_row(
        "SELECT EXISTS(SELECT 1 FROM journal WHERE launch_key=?1 AND core_id=?2 AND address=?3 AND created_ms=?4)",
        rusqlite::params![key, core, address, created],
        |row| row.get(0),
    ).unwrap_or(false)
}

async fn remove(places: &Places, asked: &Asked) -> Result<Value, Stop> {
    if env::consts::OS != "macos" {
        return Err(Stop::new(
            "not_macos",
            "service remove undoes service install, which sets up a Mac.",
        ));
    }
    let mut did: Vec<String> = Vec::new();
    let job = places.job(&asked.label);
    let was_loaded = job_state(&asked.label).is_some();
    if was_loaded || job.exists() {
        let ended = end_agents(places).await;
        if ended > 0 {
            did.push(format!("Ended {ended} running bot agents."));
        }
    }
    unload(&asked.label);
    if was_loaded {
        did.push("Stopped the SwarmHub service.".into());
    }
    // What the agent programs were told to trust on SwarmHub's word is taken back.
    did.extend(crate::first_time::undo(&places.data));
    if fs::remove_file(&job).is_ok() {
        did.push("Removed the background service, so it no longer starts at login.".into());
    }
    for program in &PROGRAMS {
        let file = places.templates.join(format!("{}.md", program.template));
        if own_template(&file, program, &places.exe) && fs::remove_file(&file).is_ok() {
            did.push(format!(
                "Removed the starter template {}.",
                program.template
            ));
        }
    }
    if fs::remove_file(&places.token).is_ok() {
        did.push("Removed the access key.".into());
        let _ = fs::remove_dir(places.token.parent().unwrap_or(Path::new("/")));
    }
    // The program itself goes last; this process keeps running from the file it was started from.
    let mut name = places.exe.file_name().unwrap_or_default().to_os_string();
    name.push(".previous");
    let _ = fs::remove_file(places.exe.with_file_name(name));
    if fs::remove_file(&places.exe).is_ok() {
        did.push("Removed the SwarmHub service program.".into());
    }
    Ok(json!({
        "did": did,
        "kept": [
            format!("Your conversations, in {}.", places.data.display()),
            format!("Your bots' files, in {}.", places.agents.display()),
            "Herdr Core, which other apps may use.",
        ],
    }))
}

fn print(json: bool, result: Result<Value, Stop>) -> Result<(), Failed> {
    match result {
        Ok(mut value) => {
            if json {
                value["ok"] = true.into();
                println!("{value}");
            } else {
                for line in value["did"].as_array().into_iter().flatten() {
                    println!("{}", line.as_str().unwrap_or_default());
                }
                if value["did"].is_null() {
                    println!("{}", serde_json::to_string_pretty(&value)?);
                }
                for line in value["kept"].as_array().into_iter().flatten() {
                    println!("Kept: {}", line.as_str().unwrap_or_default());
                }
            }
            Ok(())
        }
        Err(stop) => {
            if json {
                println!(
                    "{}",
                    json!({"ok": false, "error": stop.message, "kind": stop.kind})
                );
                std::process::exit(1);
            }
            Err(stop.message.into())
        }
    }
}

/// Answers the agent programs' first-time questions ahead (`first_time`), for the programs found in `folders`.
fn first_time(places: &Places, folders: &[PathBuf]) -> Value {
    let _ = fs::create_dir_all(&places.agents);
    let _ = private_folder(&places.data);
    let codex = find("codex", folders).map(|codex| {
        let mut command = std::process::Command::new(codex);
        command
            .env("PATH", joined(folders))
            .current_dir(&places.agents);
        command
    });
    let mut answers = crate::first_time::prepare(
        &places.home,
        &places.data,
        &places.agents,
        &places.exe,
        false,
        codex,
    );
    if find("claude", folders).is_some()
        && let Some(items) = answers.as_array_mut()
    {
        items.push(json!({"id":"claude","done":true,"changed":false,
            "what":"Claude Code trusts each bot’s private folder when SwarmHub creates it."}));
    }
    answers
}

/// What was done about each program's first-time question, one sentence each.
fn did_lines(said: &Value) -> Vec<String> {
    said.as_array()
        .into_iter()
        .flatten()
        .filter_map(|answer| answer["what"].as_str().or(answer["why"].as_str()))
        .map(str::to_owned)
        .collect()
}

/// `swarmhub-herdr service status|install|remove`. (`run` is taken before this: it becomes the server.)
pub(crate) async fn cli() -> Result<(), Failed> {
    let mut arguments = env::args_os().skip(2);
    let verb = arguments.next().unwrap_or_default();
    let program = (verb == "add-ai").then(|| arguments.next()).flatten();
    let json = env::args_os().any(|argument| argument == "--json");
    let asked = match asked(arguments) {
        Ok(asked) => asked,
        Err(stop) => return print(json, Err(stop)),
    };
    let places = match Places::from_env() {
        Ok(places) => places,
        Err(stop) => return print(json, Err(stop)),
    };
    let result = match verb.to_str() {
        Some("status") => Ok(look(&places, &asked, &search_folders(&places.home))),
        Some("add-ai") => {
            let folders = search_folders(&places.home);
            let id = program.as_deref().and_then(|id| id.to_str()).unwrap_or("");
            add_ai(&places, id, &folders).map(|()| look(&places, &asked, &folders))
        }
        Some("install") => install(&places, &asked).await,
        Some("remove") => remove(&places, &asked).await,
        Some("prepare") if asked.undo => Ok(json!({"did": crate::first_time::undo(&places.data)})),
        Some("prepare") => {
            let folders = search_folders(&places.home);
            let said = first_time(&places, &folders);
            Ok(json!({"first_time": said, "did": did_lines(&said)}))
        }
        _ => Err(Stop::failed(
            "Usage: swarmhub-herdr service status|install|run|remove|prepare|add-ai PROGRAM [--port N] [--label NAME] [--answer-first-time] [--undo] [--json]",
        )),
    };
    print(json, result)
}

/// `swarmhub-herdr service run`: gives this process everything the server reads from its environment, with Herdr
/// Core running, and returns for the server to start. It waits while Herdr Core is not installed, so that
/// installing it is all it takes.
pub(crate) fn prepare_run() -> Result<(), Failed> {
    let places = Places::from_env().map_err(|stop| stop.message)?;
    let folders = search_folders(&places.home);
    let path = joined(&folders);
    let (token, _) = ensure_token(&places.token).map_err(|stop| stop.message)?;
    fs::create_dir_all(&places.agents)?;
    let socket = core_socket_here(&places.home);
    let mut told = false;
    let hc = loop {
        if let Some(hc) = hc(&folders) {
            break hc;
        }
        if core_listens(&socket) {
            break PathBuf::new();
        }
        if !told {
            eprintln!(
                "Herdr Core is not installed. Waiting for it: curl -fsSL https://releases.herdr.dev/core/install.sh | sh"
            );
            told = true;
        }
        std::thread::sleep(Duration::from_secs(15));
    };
    if !hc.as_os_str().is_empty() {
        start_core(&hc, &socket, &path).map_err(|stop| stop.message)?;
    }
    // SAFETY: the server has not started yet, and nothing else in this process reads the environment meanwhile.
    unsafe {
        env::set_var("PATH", &path);
        env::set_var(AGENT_PATH_ENV, &path);
        env::set_var("SWARMHUB_ACCESS_TOKEN", token);
        env::set_var("HC_SOCKET", &socket);
        if setting("SWARMHUB_AGENT_CWD").is_none() {
            env::set_var("SWARMHUB_AGENT_CWD", &places.agents);
        }
    }
    eprintln!(
        "SwarmHub {}: http://127.0.0.1:{}, Herdr Core at {}",
        update::VERSION,
        setting("SWARMHUB_PORT")
            .and_then(|port| port.into_string().ok())
            .unwrap_or_else(|| DEFAULT_PORT.to_string()),
        socket.display()
    );
    Ok(())
}

/// While the server runs for `service run`: Herdr Core is started again when it has stopped listening. Core
/// keeps its terminals through that; nothing else on this computer would start it.
pub(crate) fn keep_core_running() {
    if setting(AGENT_PATH_ENV).is_none() {
        return;
    }
    let Some(socket) = setting("HC_SOCKET").map(PathBuf::from) else {
        return;
    };
    let Some(home) = setting("HOME").map(PathBuf::from) else {
        return;
    };
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(Duration::from_secs(20));
            if core_listens(&socket) {
                continue;
            }
            let path = setting("PATH")
                .and_then(|path| path.into_string().ok())
                .unwrap_or_default();
            let folders = merged_path(Some(&path), &usual_folders(&home));
            if let Some(hc) = hc(&folders)
                && let Err(stop) = start_core(&hc, &socket, &path)
            {
                eprintln!("{}", stop.message);
            }
        }
    });
}

/// The launchd job that restarts this server when it ends, if one does (`LABEL_ENV`).
pub(crate) fn supervised() -> Option<String> {
    setting(LABEL_ENV)
        .and_then(|label| label.into_string().ok())
        .filter(|label| valid_label(label))
}

/// Has launchd end whatever it runs for the job now and start the program that is under its name.
pub(crate) fn restart_job(label: &str) -> bool {
    launchctl(&["kickstart", "-k", &job_target(label)]).is_ok_and(|ran| ran.ok)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn none(_: &str) -> Option<OsString> {
        None
    }

    #[test]
    fn finds_herdr_cores_socket_by_cores_own_rule() {
        let home = Path::new("/Users/ada");
        // macOS: no runtime folder, so the socket is in the session's state folder.
        assert_eq!(
            core_socket(home, none, None),
            Path::new("/Users/ada/.local/state/herdr-core/default/default.sock")
        );
        let session = |name: &str| (name == "HC_SESSION").then(|| OsString::from(" check "));
        assert_eq!(
            core_socket(home, session, None),
            Path::new("/Users/ada/.local/state/herdr-core/check/check.sock")
        );
        // Linux with a login session: the runtime folder.
        assert_eq!(
            core_socket(home, none, Some("/run/user/1000".into())),
            Path::new("/run/user/1000/herdr-core/default.sock")
        );
        let runtime = |name: &str| match name {
            "XDG_RUNTIME_DIR" => Some(OsString::from("/tmp/run")),
            "XDG_STATE_HOME" => Some(OsString::from("/tmp/state")),
            _ => None,
        };
        assert_eq!(
            core_socket(home, runtime, Some("/run/user/1000".into())),
            Path::new("/tmp/run/herdr-core/default.sock")
        );
        let state = |name: &str| (name == "XDG_STATE_HOME").then(|| OsString::from("/tmp/state"));
        assert_eq!(
            core_socket(home, state, None),
            Path::new("/tmp/state/herdr-core/default/default.sock")
        );
        let chosen = |name: &str| (name == "HC_SOCKET").then(|| OsString::from("/tmp/own.sock"));
        assert_eq!(core_socket(home, chosen, None), Path::new("/tmp/own.sock"));
    }

    #[test]
    fn reads_the_shells_path_between_the_marks_and_adds_the_usual_folders_once() {
        let noisy =
            format!("Welcome back!\n{PATH_MARK}/opt/tools/bin:/usr/bin:relative{PATH_MARK}\n");
        assert_eq!(
            marked_path(&noisy).as_deref(),
            Some("/opt/tools/bin:/usr/bin:relative")
        );
        assert_eq!(marked_path("no marks"), None);
        assert_eq!(marked_path(&format!("{PATH_MARK}{PATH_MARK}")), None);
        assert_eq!(
            marked_path(&format!("{PATH_MARK}bin:sbin{PATH_MARK}")),
            None
        );
        let usual = [
            PathBuf::from("/usr/bin"),
            PathBuf::from("/opt/homebrew/bin"),
        ];
        assert_eq!(
            merged_path(
                Some("/opt/tools/bin:/usr/bin:relative:/opt/tools/bin"),
                &usual
            ),
            [
                PathBuf::from("/opt/tools/bin"),
                PathBuf::from("/usr/bin"),
                PathBuf::from("/opt/homebrew/bin")
            ]
        );
        assert_eq!(merged_path(None, &usual), usual);
        assert!(
            usual_folders(Path::new("/Users/ada"))
                .contains(&PathBuf::from("/Users/ada/.local/bin"))
        );
    }

    #[test]
    fn a_starter_template_is_one_the_workspace_recognises() {
        let exe = Path::new("/Users/ada/.local/bin/swarmhub-herdr");
        for program in &PROGRAMS {
            let text = template_text(program, exe);
            let command = text
                .lines()
                .find_map(|line| line.strip_prefix("command: "))
                .unwrap();
            assert!(text.starts_with("---\n") && text.ends_with("---\n"));
            let template = crate::core::Template {
                name: program.template.into(),
                description: String::new(),
                error: None,
                command: command.into(),
            };
            let catalog = crate::runtimes::Catalog::default();
            // The agent program is recognised from the command, and can be given a model.
            let shown = serde_json::to_value(catalog.choice(template)).unwrap();
            assert_eq!(shown["runtime"]["harness"], program.full);
            assert_eq!(shown["runtime"]["display_name"], program.name);
            assert_eq!(shown["model_agent"], program.full);
            assert!(crate::core::valid_name(program.template));
        }
        // A path a shell would split is quoted, so the agent still starts.
        let spaced = template_text(&PROGRAMS[0], Path::new("/Users/Ada L/bin/swarmhub-herdr"));
        assert!(spaced.contains("command: '/Users/Ada L/bin/swarmhub-herdr' run-claude"));
    }

    #[test]
    fn the_starter_model_list_is_one_the_workspace_reads() {
        let scratch = tempfile::tempdir().unwrap();
        fs::write(scratch.path().join("runtime-catalog.json"), STARTER_CATALOG).unwrap();
        let catalog = crate::runtimes::Catalog::load(&scratch.path().join("workspace.sqlite3"));
        assert!(catalog.warning.is_none());
        let named: Value = serde_json::from_str(STARTER_CATALOG).unwrap();
        for program in &PROGRAMS {
            assert_eq!(named[program.template]["harness"], program.full);
        }
    }

    #[test]
    fn adding_opencode_to_an_existing_catalog_preserves_custom_providers() {
        let scratch = tempfile::tempdir().unwrap();
        let file = scratch.path().join("runtime-catalog.json");
        let old = r#"{"custom":{"harness":"My CLI","provider":"Local"}}"#;
        fs::write(&file, old).unwrap();
        assert!(!install_catalog(&file, &[]).unwrap());
        assert!(install_catalog(&file, &["swarmhub-opencode"]).unwrap());
        let upgraded: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        assert_eq!(upgraded["custom"]["provider"], "Local");
        assert_eq!(upgraded["swarmhub-opencode"]["discover_models"], true);
        assert!(upgraded.get("swarmhub-gemini").is_none());
        assert!(!install_catalog(&file, &["swarmhub-opencode"]).unwrap());
        // Gemini CLI installed later gets its short model names, and the rest stays.
        assert!(install_catalog(&file, &["swarmhub-opencode", "swarmhub-gemini"]).unwrap());
        let upgraded: Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
        assert_eq!(upgraded["custom"]["provider"], "Local");
        assert_eq!(upgraded["swarmhub-gemini"]["harness"], "Gemini CLI");
        assert_eq!(upgraded["swarmhub-gemini"]["models"][0]["id"], "auto");
        assert!(crate::runtimes::Catalog::load(&scratch.path().join("workspace.sqlite3"))
            .warning
            .is_none());
        let override_json =
            r#"{"swarmhub-opencode":{"harness":"OpenCode","discover_models":false}}"#;
        fs::write(&file, override_json).unwrap();
        assert!(!install_catalog(&file, &["swarmhub-opencode"]).unwrap());
        assert_eq!(fs::read_to_string(file).unwrap(), override_json);
    }

    #[test]
    fn makes_an_access_key_once_and_keeps_it_private() {
        let scratch = tempfile::tempdir().unwrap();
        let file = scratch.path().join("swarmhub-herdr/token");
        let (token, made) = ensure_token(&file).unwrap();
        assert!(made && valid_token(&token));
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        assert_eq!(
            fs::metadata(file.parent().unwrap())
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o700
        );
        assert_eq!(ensure_token(&file).unwrap(), (token.clone(), false));
        // A file that holds no key gets one.
        fs::write(&file, "not a key\n").unwrap();
        let (again, made) = ensure_token(&file).unwrap();
        assert!(made && again != token && valid_token(&again));
    }

    fn places(root: &Path) -> Places {
        Places {
            home: root.into(),
            exe: root.join("bin/swarmhub-herdr"),
            token: root.join("config/swarmhub-herdr/token"),
            templates: root.join("config/herdr-core/templates"),
            data: root.join("state"),
            agents: root.join("agents"),
        }
    }

    #[test]
    fn adds_only_the_selected_installed_ai_and_keeps_custom_templates() {
        let scratch = tempfile::tempdir().unwrap();
        let places = places(scratch.path());
        let bin = scratch.path().join("tools");
        fs::create_dir_all(&bin).unwrap();
        for tool in ["agy", "codex"] {
            let file = bin.join(tool);
            fs::write(&file, "#!/bin/sh\nexit 99").unwrap();
            fs::set_permissions(file, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let folders = [bin];
        assert!(add_ai(&places, "gemini", &folders).is_err());
        add_ai(&places, "antigravity", &folders).unwrap();
        let added = places.templates.join("swarmhub-antigravity.md");
        assert!(fs::read_to_string(&added).unwrap().contains("run-antigravity"));
        fs::write(&added, "my custom template").unwrap();
        add_ai(&places, "antigravity", &folders).unwrap();
        assert_eq!(fs::read_to_string(&added).unwrap(), "my custom template");
        assert!(!places.templates.join("swarmhub-codex.md").exists());
        assert!(!places.job(LABEL).exists());
    }

    #[test]
    fn writes_templates_for_the_programs_found_and_leaves_a_persons_own_alone() {
        let scratch = tempfile::tempdir().unwrap();
        let places = places(scratch.path());
        let bin = scratch.path().join("tools");
        fs::create_dir_all(&bin).unwrap();
        fs::write(bin.join("codex"), "#!/bin/sh\n").unwrap();
        fs::write(bin.join("claude"), "not executable").unwrap();
        fs::set_permissions(bin.join("codex"), fs::Permissions::from_mode(0o755)).unwrap();
        let found: Vec<(&Program, PathBuf)> = PROGRAMS
            .iter()
            .filter_map(|program| Some((program, find(program.bin, &[bin.clone()])?)))
            .collect();
        assert_eq!(found.len(), 1);
        assert_eq!(
            write_templates(&places, &found).unwrap(),
            ["swarmhub-codex"]
        );
        let codex = places.templates.join("swarmhub-codex.md");
        assert!(own_template(&codex, &PROGRAMS[1], &places.exe));
        assert!(!places.templates.join("swarmhub-claude.md").exists());
        let previous =
            template_text(&PROGRAMS[1], &places.exe).replacen(" --workspace-approvals", "", 1);
        fs::write(&codex, previous).unwrap();
        assert_eq!(
            write_templates(&places, &found).unwrap(),
            ["swarmhub-codex"]
        );
        assert!(
            fs::read_to_string(&codex)
                .unwrap()
                .contains("run-codex --workspace-approvals")
        );
        // Written once: a second install changes nothing, and a template someone edited is theirs.
        assert!(write_templates(&places, &found).unwrap().is_empty());
        fs::write(&codex, "---\ncommand: codex --my-own-way\n---\n").unwrap();
        assert!(write_templates(&places, &found).unwrap().is_empty());
        assert!(!own_template(&codex, &PROGRAMS[1], &places.exe));
        assert_eq!(
            fs::read_to_string(&codex).unwrap(),
            "---\ncommand: codex --my-own-way\n---\n"
        );
    }

    #[test]
    fn the_job_starts_this_program_at_login_and_keeps_it_running() {
        let settings = BTreeMap::from([
            ("SWARMHUB_PORT".to_owned(), "8790".to_owned()),
            (LABEL_ENV.to_owned(), "com.example.check".to_owned()),
            ("XDG_STATE_HOME".to_owned(), "/tmp/a&b".to_owned()),
        ]);
        let text = job_text(
            "com.example.check",
            Path::new("/Users/ada/.local/bin/swarmhub-herdr"),
            Path::new("/Users/ada/.local/state/swarmhub-herdr/service.log"),
            &settings,
        );
        for part in [
            "<key>Label</key>\n\t<string>com.example.check</string>",
            "<string>/Users/ada/.local/bin/swarmhub-herdr</string>\n\t\t<string>service</string>\n\t\t<string>run</string>",
            "<key>RunAtLoad</key>\n\t<true/>",
            "<key>KeepAlive</key>\n\t<true/>",
            "<key>SWARMHUB_PORT</key>\n\t\t<string>8790</string>",
            "<string>/tmp/a&amp;b</string>",
        ] {
            assert!(text.contains(part), "{part}\n{text}");
        }
        let scratch = tempfile::tempdir().unwrap();
        let job = scratch.path().join("job.plist");
        fs::write(&job, &text).unwrap();
        assert_eq!(job_port(&job), Some(8790));
        assert_eq!(job_port(&scratch.path().join("none.plist")), None);
        assert!(
            valid_label("com.example.check")
                && !valid_label("a b")
                && !valid_label("")
                && !valid_label("../x")
        );
    }

    #[test]
    fn reads_what_launchd_prints_and_what_was_asked() {
        let printed =
            "gui/501/com.example.check = {\n\tstate = running\n\n\tprogram = /x\n\tpid = 4242\n}\n";
        assert_eq!(printed_pid(printed), Some(4242));
        assert_eq!(printed_pid("state = waiting\n"), None);
        let args = |list: &[&str]| {
            asked(
                list.iter()
                    .map(OsString::from)
                    .collect::<Vec<_>>()
                    .into_iter(),
            )
        };
        let plain = args(&["--json", "--port", "8790", "--label", "com.example.check"]).unwrap();
        assert!(plain.json && plain.port == Some(8790) && plain.label == "com.example.check");
        assert!(
            args(&["--port", "0"]).is_err()
                && args(&["--label", "a b"]).is_err()
                && args(&["--nope"]).is_err()
        );
    }

    #[test]
    fn takes_only_an_archive_herdrs_own_releases_name() {
        let releases = "https://releases.herdr.dev";
        let manifest = br#"{"version":"0.1.21","generation":1,"targets":{
            "macos-aarch64":{"url":"https://releases.herdr.dev/core/0.1.21/herdr-core-macos-aarch64.tar.gz",
                             "sha256":"1ab38dd9270f63a8f794d6d60e8702eb0d1c85a72bda85d735e5eea43f05ffed"},
            "macos-x86_64":{"url":"https://elsewhere.example/core.tar.gz",
                            "sha256":"1ab38dd9270f63a8f794d6d60e8702eb0d1c85a72bda85d735e5eea43f05ffed"}}}"#;
        let (version, archive) = core_archive(manifest, releases, "macos-aarch64").unwrap();
        assert_eq!(version, "0.1.21");
        assert!(archive.url.ends_with("herdr-core-macos-aarch64.tar.gz"));
        // An archive somewhere else, a machine with no build, and a description that is not one.
        assert_eq!(
            core_archive(manifest, releases, "macos-x86_64")
                .unwrap_err()
                .kind,
            "core_download"
        );
        assert!(
            core_archive(manifest, releases, "plan9-mips")
                .unwrap_err()
                .message
                .contains("plan9-mips")
        );
        assert!(core_archive(b"<html>", releases, "macos-aarch64").is_err());
        assert_eq!(
            core_target(),
            format!("{}-{}", env::consts::OS, env::consts::ARCH)
        );
    }

    #[test]
    fn removal_requires_the_exact_service_launch_identity() {
        let db = rusqlite::Connection::open_in_memory().unwrap();
        db.execute_batch(
            "CREATE TABLE journal (launch_key TEXT, core_id TEXT, address TEXT, created_ms INTEGER);
             INSERT INTO journal VALUES ('managed', 'core-a', 't7', 11);"
        ).unwrap();
        assert!(owned_launch(&db, "managed", "core-a", "t7", 11));
        assert!(!owned_launch(&db, "external", "core-a", "t7", 11));
        assert!(!owned_launch(&db, "managed", "core-b", "t7", 11));
        assert!(!owned_launch(&db, "managed", "core-a", "t7", 12));
        assert!(!owned_launch(&db, "managed", "core-a", "t8", 11));
    }

    #[tokio::test]
    async fn install_and_remove_are_for_macs_and_say_so_elsewhere() {
        if env::consts::OS == "macos" {
            return;
        }
        let scratch = tempfile::tempdir().unwrap();
        let places = places(scratch.path());
        let asked = Asked {
            json: true,
            answer: false,
            undo: false,
            port: None,
            label: LABEL.into(),
        };
        assert_eq!(remove(&places, &asked).await.unwrap_err().kind, "not_macos");
    }
}
