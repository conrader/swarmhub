//! `/api/skillshare`: the server's skillshare library, for an app's settings screen.
//!
//! skillshare (<https://skillshare.runkids.cc>) is a command-line program that keeps one source folder of agent
//! skills and links it into each agent program's own skills folder, a Target. This is not the workspace's Skills
//! library (`skills`, `/api/skills`), which keeps private Markdown instructions in the journal; the two share
//! nothing.
//!
//! Everything here asks the `skillshare` program and keeps nothing itself. The program comes from
//! `SWARMHUB_SKILLSHARE` or `PATH`; without it every route says "not installed". A command gets fixed arguments
//! and no shell, runs off the server's thread with a time limit, and is killed when it passes it. The one piece
//! of text from a request that reaches a command line, a skill's folder or an agent program's name, is first
//! found in what skillshare itself just listed (`parse`).
//!
//! The first six routes are about skills only and are as old as the workspace's API. The rest came with API
//! level 2: the whole library with its five kinds, previews and switches (`library`), installing from a repository
//! after an audit, updating and removing (`install`), and the library's Git repository and the state of skillshare
//! on this server (`source`). `read` turns what skillshare prints for those into what the workspace sends.

use crate::Workspace;
use axum::{
    Json, Router,
    body::Bytes,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use parse::{Skill, Status, Synced, Target};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    env, fs,
    io::{self, Read},
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Component, Path, PathBuf},
    process::{Command, Stdio},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, Semaphore};

mod health;
mod install;
mod library;
mod mcp;
mod outcome;
mod parse;
mod read;
mod source;

const ENV: &str = "SWARMHUB_SKILLSHARE";
const READ_TIMEOUT: Duration = Duration::from_secs(20);
const CHANGE_TIMEOUT: Duration = Duration::from_secs(60);
const SYNC_TIMEOUT: Duration = Duration::from_secs(120);
/// Installing and updating fetch from the network and audit what they fetched.
const INSTALL_TIMEOUT: Duration = Duration::from_secs(180);
/// How long a finished command's output may take to arrive before it is given up on.
const PIPE_GRACE: Duration = Duration::from_secs(2);
const MAX_OUTPUT: usize = 2 * 1024 * 1024;
/// A `SKILL.md` is read this far for its description.
const SKILL_FILE_HEAD: u64 = 8 * 1024;

const MISSING: &str = "skillshare is not installed on this server, or the workspace cannot find it. Install it where the workspace's PATH reaches, or set SWARMHUB_SKILLSHARE to the program's path, then restart the workspace.";
const NOT_SET_UP: &str = "skillshare is installed but not set up on this server yet. Run `skillshare init` there, then load this again.";
const NAME_SHAPE: &str = "Send name: a skill's name as the skillshare list gives it, or id: an item's id as the library gives it.";
const AGENT_SHAPE: &str = "Send agent: an agent program's name as skillshare lists it under agents that can be added, such as claude.";
const SYNC_SHAPE: &str = "Send nothing, or dry_run: true to see what a sync would do, all: true to sync every kind, and project: a skillshare project's folder.";
const TOO_OLD: &str = "The skillshare on this server is too old for this. Update it there with `skillshare upgrade`, then try again.";
const NOT_A_PROJECT: &str = "Send project: the full path of a folder on this server that holds a skillshare project (a .skillshare/config.yaml).";

/// One change at a time: skillshare rewrites its own files and the Targets' folders.
static CHANGES: Mutex<()> = Mutex::const_new(());
/// Readings of skillshare's state that may run at once; more wait their turn.
static READS: Semaphore = Semaphore::const_new(4);

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/skillshare", get(show))
        .route("/api/skillshare/enable", post(enable))
        .route("/api/skillshare/disable", post(disable))
        .route("/api/skillshare/sync", post(sync))
        .route("/api/skillshare/targets", get(targets).post(add_target))
        .route("/api/skillshare/targets/addable", get(addable))
        .merge(library::routes())
        .merge(install::routes())
        .merge(source::routes())
}

/// Which library a request is about: the server account's global one, or the one of a project folder.
#[derive(Clone, Debug, Default, PartialEq)]
pub(crate) struct Scope {
    project: Option<PathBuf>,
}

impl Scope {
    /// The global library, or the project in `folder`. A folder must be a full path to a directory that holds a
    /// skillshare project; anything else is refused in words for the app's user.
    fn of(folder: Option<&str>) -> Result<Self, String> {
        let Some(folder) = folder.filter(|folder| !folder.is_empty()) else {
            return Ok(Self::default());
        };
        project_config(folder)
            .map(|_| Self {
                project: fs::canonicalize(folder).ok(),
            })
            .filter(|scope| scope.project.is_some())
            .ok_or_else(|| NOT_A_PROJECT.to_owned())
    }

    /// The flag every skillshare command takes to say which library it is about.
    fn flag(&self) -> &'static str {
        if self.project.is_some() { "-p" } else { "-g" }
    }

    /// Where a command starts: the project's folder, or away from any folder with a project setup of its own.
    fn folder(&self) -> &Path {
        self.project.as_deref().unwrap_or(Path::new("/"))
    }

    fn name(&self) -> &'static str {
        if self.project.is_some() {
            "project"
        } else {
            "global"
        }
    }

    fn project(&self) -> Option<String> {
        self.project
            .as_ref()
            .map(|folder| folder.to_string_lossy().into_owned())
    }

    /// The key the workspace remembers things about this library under.
    fn key(&self) -> String {
        self.project().unwrap_or_default()
    }
}

/// The project configuration in `folder`, when `folder` is a full path to a skillshare project.
fn project_config(folder: &str) -> Option<PathBuf> {
    let folder = Path::new(folder);
    if !folder.is_absolute() || folder.as_os_str().len() > 4_096 {
        return None;
    }
    [".skillshare/config.yaml", "skillshare/config.yaml"]
        .into_iter()
        .map(|file| folder.join(file))
        .find(|file| fs::metadata(file).is_ok_and(|file| file.is_file()))
}

/// The skillshare program this workspace runs, or why there is none, in words for the workspace's owner.
fn program() -> Result<PathBuf, String> {
    let runnable = |path: &Path| {
        fs::metadata(path)
            .is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0)
    };
    match env::var_os(ENV).filter(|path| !path.is_empty()) {
        Some(path) => Some(PathBuf::from(path))
            .filter(|path| runnable(path))
            .ok_or_else(|| {
                format!("{ENV} does not name a program this workspace can run. Set it to skillshare's full path, or unset it to use PATH, then restart the workspace.")
            }),
        None => found("skillshare").ok_or_else(|| MISSING.to_owned()),
    }
}

/// A program of this name in one of the workspace's `PATH` folders.
fn found(name: &str) -> Option<PathBuf> {
    env::var_os("PATH").and_then(|folders| {
        env::split_paths(&folders)
            .filter(|folder| folder.is_absolute())
            .map(|folder| folder.join(name))
            .find(|path| {
                fs::metadata(path)
                    .is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0)
            })
    })
}

/// A skillshare command that ran to its end.
pub(crate) struct Ran {
    pub(crate) ok: bool,
    pub(crate) out: String,
    pub(crate) err: String,
}

impl Ran {
    fn said(&self) -> String {
        parse::said(&self.out, &self.err)
    }

    /// Why this command's answer cannot be used, in words for the workspace's owner.
    fn failure(&self) -> String {
        let said = read::error(&self.out).unwrap_or_else(|| self.said());
        if said.contains("config not found") {
            NOT_SET_UP.into()
        } else if ["unknown option", "unknown flag", "unknown command"]
            .iter()
            .any(|sign| said.contains(sign))
        {
            format!("{TOO_OLD} skillshare said: {said}")
        } else if said.is_empty() {
            "skillshare failed without saying why.".into()
        } else {
            format!("skillshare said: {said}")
        }
    }
}

/// Why a skillshare command has no answer.
pub(crate) enum Trouble {
    Start,
    Slow(Duration),
    Flood,
}

impl Trouble {
    /// The answer to a request for a change that this stopped.
    fn refusal(&self) -> Response {
        match self {
            Self::Slow(_) => refused(
                StatusCode::GATEWAY_TIMEOUT,
                &format!(
                    "{} Its work may be half done; load the list again to see what changed.",
                    self.text()
                ),
            ),
            Self::Start | Self::Flood => refused(StatusCode::BAD_GATEWAY, &self.text()),
        }
    }

    fn text(&self) -> String {
        match self {
            Self::Start => "The workspace could not start skillshare.".into(),
            Self::Slow(limit) => format!(
                "skillshare took longer than {} seconds and was stopped.",
                limit.as_secs()
            ),
            Self::Flood => {
                "skillshare printed more than the workspace reads, so its answer was dropped."
                    .into()
            }
        }
    }
}

/// Reads a pipe on its own thread, keeping the start and letting the rest go by so that the program can end.
fn collect(mut pipe: impl Read + Send + 'static) -> mpsc::Receiver<Vec<u8>> {
    let (send, receive) = mpsc::channel();
    thread::spawn(move || {
        let mut bytes = Vec::new();
        let _ = pipe
            .by_ref()
            .take(MAX_OUTPUT as u64 + 1)
            .read_to_end(&mut bytes);
        let _ = io::copy(&mut pipe, &mut io::sink());
        let _ = send.send(bytes);
    });
    receive
}

/// Runs skillshare with exactly `arguments`, no shell and no input, and waits at most `limit` for it.
fn run_blocking(
    program: &Path,
    arguments: &[String],
    limit: Duration,
    folder: &Path,
) -> Result<Ran, Trouble> {
    // The second one: no call home for a newer version on the way. The third: Git never stops to ask.
    let quiet = [
        ("NO_COLOR", "1"),
        ("SKILLSHARE_AUTO_UPDATE_CHECK", "false"),
        ("GIT_TERMINAL_PROMPT", "0"),
    ];
    run_in(program, arguments, &quiet, limit, folder, None)
}

/// Runs a program the way skillshare is run, for the other server tools the workspace asks (`machines`): exactly
/// `arguments`, no shell, no input, `env` on top of the workspace's own, at most `limit`, and killed with
/// everything it started when it passes it.
pub(crate) fn run_program(
    program: &Path,
    arguments: &[String],
    env: &[(&str, &str)],
    limit: Duration,
) -> Result<Ran, Trouble> {
    // Away from any folder with a project setup of its own.
    run_in(program, arguments, env, limit, Path::new("/"), None)
}

/// `run_program` started in `folder`. With `largest_file`, the program and what it starts cannot write a file
/// longer than that many bytes: the system ends them when they try (a download that must stay small).
fn run_in(
    program: &Path,
    arguments: &[String],
    env: &[(&str, &str)],
    limit: Duration,
    folder: &Path,
    largest_file: Option<u64>,
) -> Result<Ran, Trouble> {
    let mut command = Command::new(program);
    command
        .args(arguments)
        .current_dir(folder)
        .envs(env.iter().copied())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    if let Some(bytes) = largest_file {
        let limit = libc::rlimit {
            rlim_cur: bytes as libc::rlim_t,
            rlim_max: bytes as libc::rlim_t,
        };
        // Between fork and exec only this one system call runs, and it allocates nothing.
        unsafe {
            command.pre_exec(move || {
                if libc::setrlimit(libc::RLIMIT_FSIZE, &limit) == 0 {
                    Ok(())
                } else {
                    Err(io::Error::last_os_error())
                }
            });
        }
    }
    let mut child = command.spawn().map_err(|_| Trouble::Start)?;
    let out = child.stdout.take().map(collect);
    let err = child.stderr.take().map(collect);
    let deadline = Instant::now() + limit;
    let mut pause = Duration::from_millis(2);
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if Instant::now() < deadline => {
                thread::sleep(pause);
                pause = (pause * 2).min(Duration::from_millis(50));
            }
            _ => break None,
        }
    };
    let Some(status) = status else {
        if let Ok(group) = libc::pid_t::try_from(child.id()) {
            // The child is not reaped yet, so its ID, which is also its process group's, is still its own.
            unsafe { libc::kill(-group, libc::SIGKILL) };
        }
        let _ = child.kill();
        let _ = child.wait();
        return Err(Trouble::Slow(limit));
    };
    let read = |pipe: Option<mpsc::Receiver<Vec<u8>>>| {
        pipe.and_then(|pipe| pipe.recv_timeout(PIPE_GRACE).ok())
    };
    let (Some(out), Some(err)) = (read(out), read(err)) else {
        return Err(Trouble::Slow(limit));
    };
    if out.len() > MAX_OUTPUT || err.len() > MAX_OUTPUT {
        return Err(Trouble::Flood);
    }
    Ok(Ran {
        ok: status.success(),
        out: String::from_utf8_lossy(&out).into_owned(),
        err: String::from_utf8_lossy(&err).into_owned(),
    })
}

async fn run(program: &Path, arguments: &[&str], limit: Duration) -> Result<Ran, Trouble> {
    run_at(program, &Scope::default(), arguments, limit).await
}

/// Runs skillshare for one library: started in the project's folder for a project, and away from any for the
/// global one. The caller puts `scope.flag()` among the arguments of commands that take it.
async fn run_at(
    program: &Path,
    scope: &Scope,
    arguments: &[&str],
    limit: Duration,
) -> Result<Ran, Trouble> {
    let program = program.to_owned();
    let folder = scope.folder().to_owned();
    let arguments: Vec<String> = arguments.iter().map(|&argument| argument.into()).collect();
    tokio::task::spawn_blocking(move || run_blocking(&program, &arguments, limit, &folder))
        .await
        .unwrap_or(Err(Trouble::Start))
}

/// Runs a skillshare command that only reads, and takes its answer with `read`. An error is the problem in words
/// for the workspace's owner.
async fn ask<T>(
    program: &Path,
    arguments: &[&str],
    read: impl FnOnce(&str) -> Option<T>,
) -> Result<T, String> {
    let ran = run(program, arguments, READ_TIMEOUT)
        .await
        .map_err(|trouble| trouble.text())?;
    read(&ran.out)
        .filter(|_| ran.ok)
        .ok_or_else(|| ran.failure())
}

/// Runs another program of the server (Git) off the server's thread, the way skillshare is run.
async fn run_tool(
    tool: &'static str,
    arguments: Vec<String>,
    env: Vec<(&'static str, String)>,
    limit: Duration,
    folder: PathBuf,
    largest_file: Option<u64>,
) -> Result<Ran, Trouble> {
    tokio::task::spawn_blocking(move || {
        let program = found(tool).ok_or(Trouble::Start)?;
        let env: Vec<_> = env
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect();
        run_in(&program, &arguments, &env, limit, &folder, largest_file)
    })
    .await
    .unwrap_or(Err(Trouble::Start))
}

/// What `skillshare status` reports, and skillshare's version whether or not it could report.
async fn status(program: &Path) -> (Result<Status, String>, Option<String>) {
    status_at(program, &Scope::default()).await
}

async fn status_at(program: &Path, scope: &Scope) -> (Result<Status, String>, Option<String>) {
    let ran = match run_at(
        program,
        scope,
        &["status", scope.flag(), "--json"],
        READ_TIMEOUT,
    )
    .await
    {
        Ok(ran) => ran,
        Err(trouble) => return (Err(trouble.text()), None),
    };
    match parse::status(&ran.out).filter(|_| ran.ok) {
        Some(mut status) => {
            let version = status.version.take();
            (Ok(status), version)
        }
        // skillshare answered, so it can still say which version it is.
        None => (
            Err(ran.failure()),
            ask(program, &["version"], parse::version).await.ok(),
        ),
    }
}

async fn listed(program: &Path) -> Result<Vec<Skill>, String> {
    ask(program, &["list", "-g", "--json"], parse::skills).await
}

/// The agent programs skillshare finds on this server and does not link into yet.
async fn offered(program: &Path) -> Result<Vec<String>, String> {
    // Without a setup, `init --discover` is a first `init`. Ask only where `status` finds one.
    status(program).await.0?;
    ask(
        program,
        &["init", "--discover", "--dry-run"],
        parse::addable,
    )
    .await
}

/// The description in each skill's `SKILL.md`, in the order of `paths`.
fn descriptions(source: &Path, paths: &[String]) -> Vec<Option<String>> {
    paths
        .iter()
        .map(|path| described(source, path, Some("SKILL.md")))
        .collect()
}

/// Whether `path` names something inside a folder: plain parts only, nothing that climbs out or starts anew.
fn inside(path: &str) -> bool {
    !path.is_empty()
        && Path::new(path)
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
}

/// The description in the front matter of one file under `source`: `path/file`, or `path` itself without `file`.
fn described(source: &Path, path: &str, file: Option<&str>) -> Option<String> {
    if !source.is_absolute() || !inside(path) {
        return None;
    }
    let file = match file {
        Some(file) => source.join(path).join(file),
        None => source.join(path),
    };
    if !fs::metadata(&file).is_ok_and(|file| file.is_file()) {
        return None;
    }
    let mut head = Vec::new();
    fs::File::open(file)
        .ok()?
        .take(SKILL_FILE_HEAD)
        .read_to_end(&mut head)
        .ok()?;
    parse::description(&String::from_utf8_lossy(&head))
}

/// Everything a settings screen shows about skillshare on this server.
#[derive(Default, Serialize)]
struct Library {
    installed: bool,
    version: Option<String>,
    /// Why the rest is missing or may be incomplete, in words for the workspace's owner; `null` when all is well.
    problem: Option<String>,
    /// The folder skillshare keeps the skills in.
    source: Option<String>,
    /// Skills in the source. `skills` holds the first of them when there are more than an answer carries.
    skill_count: usize,
    skills: Vec<Skill>,
    targets: Vec<Target>,
}

impl Library {
    fn unusable(problem: String) -> Self {
        Self {
            problem: Some(problem),
            ..Self::default()
        }
    }

    /// Reads skillshare's state. `all` gets every listed skill, without descriptions, for checking a change.
    async fn read(program: &Path, all: Option<&mut Vec<Skill>>) -> Self {
        let Ok(_turn) = READS.acquire().await else {
            return Self::unusable("The workspace is shutting down.".into());
        };
        let ((status, version), skills) = tokio::join!(status(program), listed(program));
        let (status, mut problem) = match status {
            Ok(status) => (status, None),
            Err(problem) => (Status::default(), Some(problem)),
        };
        let mut skills = skills.unwrap_or_else(|unlisted| {
            problem.get_or_insert(unlisted);
            Vec::new()
        });
        if let Some(all) = all {
            all.clone_from(&skills);
        }
        let skill_count = skills.len();
        skills.truncate(parse::MAX_SKILLS);
        if let Some(source) = &status.source {
            if !status.source_exists {
                problem.get_or_insert_with(|| {
                    format!("skillshare's source folder, {source}, does not exist.")
                });
            }
            let source = PathBuf::from(source);
            let paths: Vec<_> = skills.iter().map(|skill| skill.path.clone()).collect();
            let read = tokio::task::spawn_blocking(move || descriptions(&source, &paths));
            if let Ok(Ok(read)) = tokio::time::timeout(READ_TIMEOUT, read).await {
                for (skill, description) in skills.iter_mut().zip(read) {
                    skill.description = description;
                }
            }
        }
        Self {
            installed: true,
            version,
            problem,
            source: status.source,
            skill_count,
            skills,
            targets: status.targets,
        }
    }
}

/// The Targets alone.
#[derive(Default, Serialize)]
struct Targets {
    installed: bool,
    version: Option<String>,
    problem: Option<String>,
    targets: Vec<Target>,
}

impl Targets {
    async fn read(program: &Path) -> Self {
        let Ok(_turn) = READS.acquire().await else {
            return Self::default();
        };
        let (status, version) = status(program).await;
        let (targets, problem) = match status {
            Ok(status) => (status.targets, None),
            Err(problem) => (Vec::new(), Some(problem)),
        };
        Self {
            installed: true,
            version,
            problem,
            targets,
        }
    }
}

#[derive(Serialize)]
struct Switched {
    #[serde(flatten)]
    library: Library,
    /// Every skill this turned on or off. One rule in `.skillignore` can decide more than one skill.
    changed: Vec<String>,
    /// What skillshare said; empty when the skill already was as asked and nothing ran.
    output: String,
}

#[derive(Serialize)]
struct SyncDone {
    #[serde(flatten)]
    synced: Synced,
    /// The Targets as they are after the sync.
    targets: Vec<Target>,
    problem: Option<String>,
}

#[derive(Serialize)]
struct Added {
    #[serde(flatten)]
    targets: Targets,
    added: String,
    output: String,
}

fn refused(status: StatusCode, error: &str) -> Response {
    (status, Json(json!({ "error": error }))).into_response()
}

/// Runs one change to its end, also when the request that asked for it goes away, and never beside another.
async fn alone(change: impl Future<Output = Response> + Send + 'static) -> Response {
    tokio::spawn(async move {
        let _turn = CHANGES.lock().await;
        change.await
    })
    .await
    .unwrap_or_else(|_| {
        refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            "The workspace could not finish this. Load the list again to see what changed.",
        )
    })
}

async fn show() -> Json<Library> {
    Json(match program() {
        Ok(program) => Library::read(&program, None).await,
        Err(problem) => Library::unusable(problem),
    })
}

async fn targets() -> Json<Targets> {
    Json(match program() {
        Ok(program) => Targets::read(&program).await,
        Err(problem) => Targets {
            problem: Some(problem),
            ..Targets::default()
        },
    })
}

async fn addable() -> Json<serde_json::Value> {
    let (installed, agents, problem) = match program() {
        Err(problem) => (false, Vec::new(), Some(problem)),
        Ok(program) => match offered(&program).await {
            Ok(agents) => (true, agents, None),
            Err(problem) => (true, Vec::new(), Some(problem)),
        },
    };
    Json(json!({ "installed": installed, "problem": problem, "agents": agents }))
}

async fn enable(body: Bytes) -> Response {
    switch(body, true).await
}

async fn disable(body: Bytes) -> Response {
    switch(body, false).await
}

/// Turns the named skill on or off in the source. Targets follow at the next sync.
async fn switch(body: Bytes, on: bool) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Named {
        name: String,
    }
    let Ok(Named { name }) = serde_json::from_slice(&body) else {
        // Not a skill by its name: an item of the library by its id, or neither.
        return library::switch(&body, on).await;
    };
    let verb = if on { "enable" } else { "disable" };
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let before = match listed(&program).await {
            Ok(skills) => skills,
            Err(problem) => return refused(StatusCode::BAD_GATEWAY, &problem),
        };
        let mut named = before.iter().filter(|skill| skill.name == name);
        let skill = match (named.next(), named.next()) {
            (Some(skill), None) => skill,
            (None, _) => {
                return refused(
                    StatusCode::NOT_FOUND,
                    "skillshare lists no skill with this name. Load the list again.",
                );
            }
            (Some(_), Some(_)) => {
                return refused(
                    StatusCode::CONFLICT,
                    "skillshare lists more than one skill with this name, so the workspace cannot tell which one is meant. Use skillshare on the server.",
                );
            }
        };
        if !parse::plain_path(&skill.path) {
            return refused(
                StatusCode::UNPROCESSABLE_ENTITY,
                "This skill's folder name has characters skillshare would read as a pattern or an option, so the workspace will not pass it on. Use skillshare on the server.",
            );
        }
        let mut output = String::new();
        if skill.enabled != on {
            match run(&program, &[verb, "-g", &skill.path], CHANGE_TIMEOUT).await {
                Err(trouble) => return trouble.refusal(),
                Ok(ran) if !ran.ok => return refused(StatusCode::BAD_GATEWAY, &ran.failure()),
                Ok(ran) => output = ran.said(),
            }
        }
        let mut after = Vec::new();
        let library = Library::read(&program, Some(&mut after)).await;
        if after
            .iter()
            .any(|skill| skill.name == name && skill.enabled != on)
        {
            return refused(
                StatusCode::CONFLICT,
                &format!(
                    "skillshare did not {verb} this skill; another rule in its .skillignore may decide it. skillshare said: {output}"
                ),
            );
        }
        let changed = after
            .iter()
            .filter(|skill| {
                before
                    .iter()
                    .any(|was| was.path == skill.path && was.enabled != skill.enabled)
            })
            .map(|skill| skill.name.clone())
            .take(parse::MAX_SKILLS)
            .collect();
        Json(Switched {
            library,
            changed,
            output,
        })
        .into_response()
    })
    .await
}

/// Links the enabled skills into every Target and removes the links of disabled ones, or with `dry_run` only
/// counts what that would do.
async fn sync(body: Bytes) -> Response {
    #[derive(Default, Deserialize)]
    #[serde(deny_unknown_fields, default)]
    struct Wanted {
        dry_run: bool,
        all: bool,
        project: Option<String>,
    }
    let wanted = if body.iter().all(u8::is_ascii_whitespace) {
        Wanted::default()
    } else if let Ok(wanted) = serde_json::from_slice(&body) {
        wanted
    } else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, SYNC_SHAPE);
    };
    if wanted.all || wanted.project.is_some() {
        return match Scope::of(wanted.project.as_deref()) {
            Ok(scope) => library::sync(scope, wanted.all, wanted.dry_run).await,
            Err(problem) => refused(StatusCode::UNPROCESSABLE_ENTITY, &problem),
        };
    }
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let mut arguments = vec!["sync", "-g", "--json"];
        if wanted.dry_run {
            arguments.push("--dry-run");
        }
        let ran = match run(&program, &arguments, SYNC_TIMEOUT).await {
            Ok(ran) => ran,
            Err(trouble) => return trouble.refusal(),
        };
        let Some(synced) = parse::synced(&ran.out).filter(|_| ran.ok) else {
            return refused(StatusCode::BAD_GATEWAY, &ran.failure());
        };
        let Targets {
            targets, problem, ..
        } = Targets::read(&program).await;
        Json(SyncDone {
            synced,
            targets,
            problem,
        })
        .into_response()
    })
    .await
}

/// Makes one agent program that skillshare finds on this server a Target. This only writes skillshare's
/// configuration: nothing is linked into the program's folder until the next sync.
async fn add_target(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        agent: String,
    }
    let agent = match serde_json::from_slice(&body) {
        Ok(Wanted { agent }) if parse::agent_name(&agent) => agent,
        _ => return refused(StatusCode::UNPROCESSABLE_ENTITY, AGENT_SHAPE),
    };
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let before = Targets::read(&program).await;
        if let Some(problem) = before.problem {
            return refused(StatusCode::BAD_GATEWAY, &problem);
        }
        if before.targets.iter().any(|target| target.name == agent) {
            return refused(
                StatusCode::CONFLICT,
                &format!("{agent} is already a Target."),
            );
        }
        let offered = match offered(&program).await {
            Ok(offered) => offered,
            Err(problem) => return refused(StatusCode::BAD_GATEWAY, &problem),
        };
        if !offered.contains(&agent) {
            let offer = if offered.is_empty() {
                "It finds no agent program to add.".into()
            } else {
                format!("It offers: {}.", offered.join(", "))
            };
            return refused(
                StatusCode::UNPROCESSABLE_ENTITY,
                &format!(
                    "skillshare does not offer {agent} on this server. {offer} An agent program is offered once its own folder exists."
                ),
            );
        }
        let ran = match run(
            &program,
            &["init", "--discover", "--select", &agent],
            CHANGE_TIMEOUT,
        )
        .await
        {
            Ok(ran) if ran.ok => ran,
            Ok(ran) => return refused(StatusCode::BAD_GATEWAY, &ran.failure()),
            Err(trouble) => return trouble.refusal(),
        };
        let targets = Targets::read(&program).await;
        if targets.problem.is_none() && !targets.targets.iter().any(|target| target.name == agent) {
            return refused(
                StatusCode::BAD_GATEWAY,
                &format!("skillshare did not add {agent}. {}", ran.failure()),
            );
        }
        Json(Added {
            targets,
            added: agent,
            output: ran.said(),
        })
        .into_response()
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn shell(script: &str, limit: Duration) -> Result<Ran, Trouble> {
        run_blocking(
            Path::new("/bin/sh"),
            &["-c".into(), script.into()],
            limit,
            Path::new("/"),
        )
    }

    #[test]
    fn a_command_gives_both_streams_and_whether_it_succeeded() {
        let Ok(ran) = shell("echo out; echo err >&2; exit 3", READ_TIMEOUT) else {
            panic!("the command did not run");
        };
        assert!(!ran.ok);
        assert_eq!((ran.out.as_str(), ran.err.as_str()), ("out\n", "err\n"));
        assert!(shell("true", READ_TIMEOUT).is_ok_and(|ran| ran.ok));
    }

    #[test]
    fn a_command_gets_no_input_and_starts_outside_any_project_folder() {
        let Ok(ran) = shell("cat; pwd", READ_TIMEOUT) else {
            panic!("the command did not run");
        };
        assert_eq!(ran.out, "/\n");
    }

    #[test]
    fn a_command_that_takes_too_long_is_stopped_with_what_it_started() {
        let started = Instant::now();
        // The sleep in the background would keep the pipes open after the shell itself is killed.
        let result = shell("sleep 60 & sleep 60", Duration::from_millis(200));
        assert!(matches!(result, Err(Trouble::Slow(_))));
        assert!(started.elapsed() < Duration::from_secs(20));
    }

    #[test]
    fn more_output_than_the_workspace_reads_is_dropped() {
        let result = shell("head -c 3000000 /dev/zero", READ_TIMEOUT);
        assert!(matches!(result, Err(Trouble::Flood)));
    }

    #[test]
    fn a_program_cannot_write_a_file_past_its_limit() {
        let folder = tempfile::tempdir().unwrap();
        let write = |bytes: u64| {
            let script = format!("head -c {bytes} /dev/zero > out && echo done");
            let arguments = ["-c".to_owned(), script];
            run_in(
                Path::new("/bin/sh"),
                &arguments,
                &[],
                READ_TIMEOUT,
                folder.path(),
                Some(4_096),
            )
        };
        assert!(write(4_096).is_ok_and(|ran| ran.ok && ran.out == "done\n"));
        assert!(write(1_000_000).is_ok_and(|ran| !ran.ok && ran.out.is_empty()));
        assert!(fs::metadata(folder.path().join("out")).unwrap().len() <= 4_096);
    }

    #[test]
    fn a_program_that_is_not_there_does_not_start() {
        let result = run_blocking(
            Path::new("/nonexistent/skillshare"),
            &[],
            READ_TIMEOUT,
            Path::new("/"),
        );
        assert!(matches!(result, Err(Trouble::Start)));
    }

    #[test]
    fn descriptions_come_only_from_skill_files_inside_the_source() {
        let folder = tempfile::tempdir().unwrap();
        let source = folder.path().join("skills");
        fs::create_dir_all(source.join("group/nested")).unwrap();
        fs::create_dir_all(source.join("plain")).unwrap();
        fs::write(
            source.join("group/nested/SKILL.md"),
            "---\nname: nested\ndescription: Use when nested.\n---\n",
        )
        .unwrap();
        fs::write(source.join("plain/SKILL.md"), "# No front matter\n").unwrap();
        fs::write(
            folder.path().join("SKILL.md"),
            "---\ndescription: Outside the source.\n---\n",
        )
        .unwrap();
        let paths = ["group/nested", "plain", "missing", "..", "/etc"].map(String::from);
        assert_eq!(
            descriptions(&source, &paths),
            [Some("Use when nested.".to_owned()), None, None, None, None]
        );
        assert_eq!(
            descriptions(Path::new("skills"), &paths),
            vec![None::<String>; 5]
        );
    }
}
