//! Installing skills from a repository after an audit, updating, and removing.
//!
//! An install is two requests. The first, `install/inspect`, downloads the repository into a scratch folder of the
//! workspace's own, asks skillshare which skills it would install from that source, and has `skillshare audit` read
//! each of them in the download. Nothing is installed, and nothing from the download is ever run: Git only fetches
//! and writes files, with hooks, links, templates and large-file downloads off, and skillshare's audit only reads.
//! The download has a time limit and two size limits: Git may not write a file past `MAX_PACK`, and the files are
//! written out only after their listed sizes are counted. The second request, `install`, names the first by its
//! ticket and installs the chosen skills with skillshare, which fetches the source itself and audits what it
//! fetched. A skill the audit blocks is installed only with `force`, and then at exactly the commit that was
//! shown, so what was reviewed is what arrives. A ticket lives for a quarter of an hour.
//!
//! Removing and forcing say so in the request (`confirm`, `force`): a plain request never does either.

use super::{
    CHANGE_TIMEOUT, INSTALL_TIMEOUT, READ_TIMEOUT, SYNC_TIMEOUT, Scope, Trouble, alone, described,
    inside,
    library::{self, Library},
    outcome::{self, Finding},
    parse, program,
    read::{self, Kind, State},
    refused, run_at, run_tool,
};
use crate::Workspace;
use axum::{
    Json, Router,
    body::Bytes,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::post,
};
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    fs,
    path::Path,
    sync::Mutex,
    time::{Duration, Instant},
};

const TICKET_LIFE: Duration = Duration::from_secs(15 * 60);
const MAX_TICKETS: usize = 4;
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(60);
const AUDIT_TIMEOUT: Duration = Duration::from_secs(60);
/// The largest file Git may write while it downloads: the one pack a shallow fetch arrives in.
const MAX_PACK: u64 = 100 * 1024 * 1024;
/// What the files of a download may add up to once written out, and how many there may be.
const MAX_BYTES: u64 = 50 * 1024 * 1024;
const MAX_FILES: usize = 5_000;
/// Skills of one source that are audited and offered.
const MAX_OFFERED: usize = 50;
const MAX_SOURCE: usize = 500;
/// How the workspace names its downloads in the temporary folder.
const SCRATCH: &str = "swarmhub-skill-check.";

const INSPECT_SHAPE: &str = "Send source: owner/repo, owner/repo/path/to/skill, or an https://, ssh://, git@ or file:// Git address; and project: a skillshare project's folder, to install into that project.";
const INSTALL_SHAPE: &str = "Send ticket: the ticket of a checked source; skills: the names to install, or leave it out for all; replace: true to install again what the library already has; force: true to install what the audit blocked.";
const NO_TICKET: &str = "This check is used up or older than 15 minutes. Check the source again.";
const NO_GIT: &str = "Git is not installed on this server, or the workspace cannot find it, so it cannot download a repository to check it.";
const TOO_LARGE: &str = "This repository is larger than the workspace downloads to check (50 MB and 5,000 files). Install it with skillshare on the server.";
const UPDATE_SHAPE: &str =
    "Send id: the id of a skill or agent as the library gives it, or all: true.";
const UNINSTALL_SHAPE: &str = "Send id: the id of a skill, an agent or a hook as the library gives it, and confirm: true. A removed skill or agent goes to skillshare's trash for 7 days.";

/// One download waiting for its install. Dropping it removes the download.
struct Ticket {
    id: String,
    made: Instant,
    scope: Scope,
    source: String,
    /// The repository alone, for an install at one commit.
    repository: Option<String>,
    commit: Option<String>,
    skills: Vec<Offered>,
    _download: tempfile::TempDir,
}

static TICKETS: Mutex<Vec<Ticket>> = Mutex::new(Vec::new());
/// One download at a time.
static INSPECTING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

pub(super) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/skillshare/install/inspect", post(inspect))
        .route("/api/skillshare/install/cancel", post(cancel))
        .route("/api/skillshare/install", post(install))
        .route("/api/skillshare/update", post(update))
        .route("/api/skillshare/uninstall", post(uninstall))
}

/// One skill a source holds, with what the audit of the download said about it.
#[derive(Clone, Debug, PartialEq, Serialize)]
struct Offered {
    name: String,
    path: String,
    description: Option<String>,
    /// The library already has a skill of this name: installing replaces it.
    installed: bool,
    /// The workspace audited it in its own download. skillshare audits again when it installs.
    audited: bool,
    blocked: bool,
    risk: String,
    score: u64,
    findings: Vec<Finding>,
}

/// Where to download a source from.
#[derive(Debug, PartialEq)]
struct Origin {
    address: String,
    branch: Option<String>,
}

fn word(text: &str) -> bool {
    !text.is_empty()
        && !text.starts_with(['-', '.'])
        && text
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

/// A skill's name as it may be handed to `skillshare install --skill`, which splits at commas and reads patterns.
fn plain_name(name: &str) -> bool {
    name.len() <= parse::MAX_NAME && word(name)
}

/// The Git address to download `source` from, and the branch a web address names. `Err` says, in words for the
/// app's user, why the workspace does not download this.
fn origin(source: &str) -> Result<Origin, String> {
    let shape = || INSPECT_SHAPE.to_owned();
    let no_sign_in = || {
        "Do not put a password or token in the address. Set up Git's sign-in on the server instead."
            .to_owned()
    };
    if source.is_empty()
        || source.len() > MAX_SOURCE
        || source.starts_with('-')
        || source.contains("..")
        || source
            .chars()
            .any(|character| character.is_whitespace() || character.is_control())
    {
        return Err(shape());
    }
    // `repo.git//folder` names a folder inside a repository: the repository is what is downloaded.
    let whole = match source.split_once(".git//") {
        Some((repository, _)) => format!("{repository}.git"),
        None => source.trim_end_matches('/').to_owned(),
    };
    let plain = |address: String| Origin {
        address,
        branch: None,
    };
    if whole.starts_with("http://") {
        return Err(
            "The workspace does not download over plain http. Give the https:// address.".into(),
        );
    }
    if let Some(path) = whole.strip_prefix("file://") {
        // A repository on this server, by its full path.
        return if path.starts_with('/') {
            Ok(plain(whole))
        } else {
            Err(shape())
        };
    }
    if let Some(rest) = whole.strip_prefix("ssh://") {
        let (machine, path) = rest.split_once('/').ok_or_else(shape)?;
        let (user, host) = machine.rsplit_once('@').unwrap_or(("git", machine));
        if user.contains(':') {
            return Err(no_sign_in());
        }
        let (name, port) = host.split_once(':').unwrap_or((host, "22"));
        let named = word(user) && word(name) && port.bytes().all(|byte| byte.is_ascii_digit());
        return if named && !path.is_empty() && !path.starts_with('-') {
            Ok(plain(whole))
        } else {
            Err(shape())
        };
    }
    // user@host:path, as Git writes an address it reaches over SSH.
    if let Some((machine, path)) = whole.split_once(':')
        && let Some((user, host)) = machine.split_once('@')
    {
        let named = word(user) && word(host) && !path.is_empty() && !path.starts_with(['-', '/']);
        return if named {
            Ok(plain(whole))
        } else {
            Err(shape())
        };
    }
    let web = whole.strip_prefix("https://");
    let rest = web.unwrap_or(&whole);
    if rest.contains('@') {
        return Err(no_sign_in());
    }
    let parts: Vec<&str> = rest.split('/').collect();
    let named = |parts: &[&str]| parts.iter().all(|part| word(part));
    let hosted = web.is_some() || (parts.len() >= 3 && parts[0].contains('.'));
    if !hosted {
        // owner/repo, or owner/repo/path/to/skill, on GitHub.
        return if parts.len() >= 2 && named(&parts) {
            Ok(plain(format!(
                "https://github.com/{}/{}",
                parts[0], parts[1]
            )))
        } else {
            Err(shape())
        };
    }
    let host_named = parts.first().is_some_and(|host| {
        let (name, port) = host.split_once(':').unwrap_or((host, "443"));
        word(name) && name.contains('.') && port.bytes().all(|byte| byte.is_ascii_digit())
    });
    if parts.len() < 3 || !host_named || !named(&parts[1..]) {
        return Err(shape());
    }
    // The repository ends at the part that says `.git`; without one, it is the two parts after the host.
    let end = parts
        .iter()
        .position(|part| part.ends_with(".git"))
        .map_or(3, |at| at + 1);
    let branch = match parts.get(end..) {
        Some(["tree" | "blob", branch, ..]) => Some((*branch).to_owned()),
        _ => None,
    };
    Ok(Origin {
        address: format!("https://{}", parts[..end].join("/")),
        branch,
    })
}

/// Git's settings for a download that runs nothing and stops instead of asking.
fn quiet_git(templates: &Path) -> Vec<(&'static str, String)> {
    vec![
        ("GIT_TERMINAL_PROMPT", "0".into()),
        ("GIT_LFS_SKIP_SMUDGE", "1".into()),
        (
            "GIT_SSH_COMMAND",
            "ssh -o BatchMode=yes -o ConnectTimeout=15".into(),
        ),
        ("GIT_ALLOW_PROTOCOL", "https:ssh:file".into()),
        ("GIT_TEMPLATE_DIR", templates.to_string_lossy().into_owned()),
    ]
}

/// Settings given to every Git command in a download: no hooks, links written as plain files, no helpers started.
const SAFE: [&str; 8] = [
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.symlinks=false",
    "-c",
    "core.fsmonitor=false",
    "-c",
    "protocol.ext.allow=never",
];

/// Why a Git command of a download has no result.
fn git_failure(result: Result<super::Ran, Trouble>, origin: &Origin) -> Result<super::Ran, String> {
    match result {
        Ok(ran) if ran.ok => Ok(ran),
        Ok(ran) => {
            let said = parse::said("", &ran.err);
            let last = said.lines().last().unwrap_or("Git gave no reason.");
            // Git names the address in what it says; nothing of a sign-in is in it, by `origin`.
            Err(format!(
                "The workspace could not download {}: {last}",
                read::safe_url(&origin.address)
            ))
        }
        Err(Trouble::Start) => Err(NO_GIT.into()),
        Err(Trouble::Slow(limit)) => Err(format!(
            "The download took longer than {} seconds and was stopped.",
            limit.as_secs()
        )),
        Err(Trouble::Flood) => Err(TOO_LARGE.into()),
    }
}

/// The total size and the number of the files in what `git ls-tree -r -l` lists.
fn listed_size(listing: &str) -> (u64, usize) {
    let mut bytes = 0u64;
    let mut files = 0;
    for line in listing.lines() {
        files += 1;
        let size = line
            .split('\t')
            .next()
            .and_then(|head| head.split_whitespace().nth(3));
        bytes = bytes.saturating_add(size.and_then(|size| size.parse().ok()).unwrap_or(0));
    }
    (bytes, files)
}

/// Downloads the repository into `folder/r` and returns the commit it is at.
async fn download(origin: &Origin, folder: &Path) -> Result<String, String> {
    let templates = folder.join("t");
    fs::create_dir(&templates)
        .map_err(|_| "The workspace could not make its scratch folder.".to_owned())?;
    let env = quiet_git(&templates);
    let git = |arguments: Vec<String>, limit, largest| {
        run_tool(
            "git",
            arguments,
            env.clone(),
            limit,
            folder.to_owned(),
            largest,
        )
    };
    let mut clone: Vec<String> = SAFE.iter().map(|&part| part.to_owned()).collect();
    clone.extend(
        [
            "clone",
            "--quiet",
            "--depth",
            "1",
            "--no-tags",
            "--single-branch",
            "--no-checkout",
        ]
        .map(String::from),
    );
    if let Some(branch) = &origin.branch {
        clone.extend(["--branch".to_owned(), branch.clone()]);
    }
    clone.extend(["--".to_owned(), origin.address.clone(), "r".to_owned()]);
    let cloned = git(clone, DOWNLOAD_TIMEOUT, Some(MAX_PACK)).await;
    // Ended by the system for writing past the limit (signal 25, "file size limit exceeded").
    if let Ok(ran) = &cloned
        && !ran.ok
        && (ran.err.contains("signal 25") || ran.err.to_lowercase().contains("file size limit"))
    {
        return Err(TOO_LARGE.into());
    }
    git_failure(cloned, origin)?;
    let within = |arguments: &[&str]| {
        let mut all: Vec<String> = SAFE.iter().map(|&part| part.to_owned()).collect();
        all.extend(["-C", "r"].map(String::from));
        all.extend(arguments.iter().map(|&part| part.to_owned()));
        all
    };
    // The sizes Git lists are counted before a single file is written out.
    let listing = git_failure(
        git(within(&["ls-tree", "-r", "-l", "HEAD"]), READ_TIMEOUT, None).await,
        origin,
    )?;
    let (bytes, files) = listed_size(&listing.out);
    if bytes > MAX_BYTES || files > MAX_FILES {
        return Err(TOO_LARGE.into());
    }
    git_failure(
        git(
            within(&["reset", "--hard", "--quiet"]),
            DOWNLOAD_TIMEOUT,
            Some(MAX_BYTES),
        )
        .await,
        origin,
    )?;
    let head = git_failure(
        git(within(&["rev-parse", "HEAD"]), READ_TIMEOUT, None).await,
        origin,
    )?;
    let commit = head.out.trim();
    (matches!(commit.len(), 40 | 64) && commit.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| commit.to_owned())
        .ok_or_else(|| "Git did not say which commit it downloaded.".to_owned())
}

fn ticket_id() -> Option<String> {
    let mut bytes = [0u8; 16];
    SystemRandom::new().fill(&mut bytes).ok()?;
    Some(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Removes tickets past their time, and the oldest when there are too many. Their downloads go with them.
fn kept(tickets: &mut Vec<Ticket>, room: usize) -> Vec<Ticket> {
    let mut dropped = Vec::new();
    let mut at = 0;
    while at < tickets.len() {
        if tickets[at].made.elapsed() >= TICKET_LIFE {
            dropped.push(tickets.remove(at));
        } else {
            at += 1;
        }
    }
    while tickets.len() + room > MAX_TICKETS && !tickets.is_empty() {
        dropped.push(tickets.remove(0));
    }
    dropped
}

/// Removes downloads off the server's thread.
fn discard(tickets: Vec<Ticket>) {
    if !tickets.is_empty() {
        tokio::task::spawn_blocking(move || drop(tickets));
    }
}

fn taken(id: &str) -> Option<Ticket> {
    let mut tickets = TICKETS.lock().ok()?;
    discard(kept(&mut tickets, 0));
    let at = tickets.iter().position(|ticket| ticket.id == id)?;
    Some(tickets.remove(at))
}

/// Removes downloads an earlier run of the workspace left behind: folders of the workspace's own name in the
/// temporary folder that nothing has touched for an hour. A ticket lives a quarter of that.
fn sweep(folder: &Path) {
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    for entry in entries.flatten() {
        let named = entry.file_name().to_string_lossy().starts_with(SCRATCH);
        // A link of that name is not followed, and a folder still in use is younger than this.
        let stale = fs::symlink_metadata(entry.path()).is_ok_and(|found| {
            found.is_dir()
                && found
                    .modified()
                    .ok()
                    .and_then(|changed| changed.elapsed().ok())
                    .is_some_and(|age| age > TICKET_LIFE * 4)
        });
        if named && stale {
            let _ = fs::remove_dir_all(entry.path());
        }
    }
}

/// Downloads a source, lists the skills skillshare would install from it, and audits them. Installs nothing.
async fn inspect(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        source: String,
        project: Option<String>,
    }
    let Ok(Wanted { source, project }) = serde_json::from_slice(&body) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, INSPECT_SHAPE);
    };
    let source = source.trim().to_owned();
    let origin = match origin(&source) {
        Ok(origin) => origin,
        Err(problem) => return refused(StatusCode::UNPROCESSABLE_ENTITY, &problem),
    };
    let (program, scope) = match library::opened(project.as_deref()) {
        Ok(opened) => opened,
        Err((status, problem)) => return refused(status, &problem),
    };
    // To its end also when the app goes away: a download left half done would stay on the disk.
    let inspected = tokio::spawn(async move {
        let _turn = INSPECTING.lock().await;
        inspected(&program, scope, source, origin).await
    });
    inspected.await.unwrap_or_else(|_| {
        refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            "The workspace could not finish checking this source.",
        )
    })
}

async fn inspected(program: &Path, scope: Scope, source: String, origin: Origin) -> Response {
    let _ = tokio::task::spawn_blocking(|| sweep(&std::env::temp_dir())).await;
    let Ok(folder) = tempfile::Builder::new().prefix(SCRATCH).tempdir() else {
        return refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            "The workspace could not make its scratch folder.",
        );
    };
    let downloaded = download(&origin, folder.path()).await;
    if let Err(problem) = &downloaded
        && (problem == TOO_LARGE || problem == NO_GIT)
    {
        discard_folder(folder);
        return refused(StatusCode::UNPROCESSABLE_ENTITY, problem);
    }
    // skillshare decides which folders are skills and what they are called; the workspace never guesses.
    let arguments = [
        "install",
        source.as_str(),
        "--dry-run",
        "--json",
        "--kind",
        "skill",
        scope.flag(),
    ];
    let planned = match run_at(program, &scope, &arguments, SYNC_TIMEOUT).await {
        Ok(ran) => outcome::plan(&ran.out),
        Err(trouble) => Err(trouble.text()),
    };
    let planned = match (planned, &downloaded) {
        (Ok(planned), _) => planned,
        // Neither Git nor skillshare reached it: Git's reason is the plainer one.
        (Err(_), Err(problem)) => {
            let problem = problem.clone();
            discard_folder(folder);
            return refused(StatusCode::BAD_GATEWAY, &problem);
        }
        (Err(problem), Ok(_)) => {
            discard_folder(folder);
            return refused(StatusCode::BAD_GATEWAY, &problem);
        }
    };
    let have: Vec<String> = match run_at(
        program,
        &scope,
        &["list", "--json", scope.flag()],
        READ_TIMEOUT,
    )
    .await
    {
        Ok(ran) => read::listed(&ran.out)
            .unwrap_or_default()
            .into_iter()
            .filter(|listed| listed.kind() == Kind::Skills)
            .flat_map(|listed| {
                [
                    listed
                        .bare()
                        .rsplit('/')
                        .next()
                        .unwrap_or_default()
                        .to_owned(),
                    listed.name,
                ]
            })
            .collect(),
        Err(_) => Vec::new(),
    };
    let root = folder.path().join("r");
    let commit = downloaded.ok();
    let mut skills = Vec::new();
    let mut threshold = String::new();
    for skill in planned
        .into_iter()
        .filter(|skill| plain_name(&skill.name))
        .take(MAX_OFFERED)
    {
        let whole = skill.path == "." || skill.path.is_empty();
        if !whole && !inside(&skill.path) {
            continue;
        }
        let place = if whole {
            root.clone()
        } else {
            root.join(&skill.path)
        };
        let mut offered = Offered {
            installed: have.contains(&skill.name),
            name: skill.name,
            path: if whole { ".".into() } else { skill.path },
            description: None,
            audited: false,
            blocked: false,
            risk: String::new(),
            score: 0,
            findings: Vec::new(),
        };
        // Only a folder that is in the download as skillshare named it is audited; a link is not followed.
        let there =
            commit.is_some() && fs::symlink_metadata(&place).is_ok_and(|found| found.is_dir());
        if there {
            let folder = place.to_string_lossy().into_owned();
            let arguments = ["audit", folder.as_str(), "--json", scope.flag()];
            // A blocked audit ends with a failure code and still prints its result.
            let audit = run_at(program, &scope, &arguments, AUDIT_TIMEOUT)
                .await
                .ok()
                .and_then(|ran| outcome::audit(&ran.out));
            if let Some(audit) = audit {
                offered.audited = true;
                offered.blocked = audit.blocked;
                offered.risk = audit.risk;
                offered.score = audit.score;
                offered.findings = audit.findings;
                if threshold.is_empty() {
                    threshold = audit.threshold;
                }
            }
            let read = place.clone();
            offered.description = tokio::task::spawn_blocking(move || {
                read.parent()
                    .zip(read.file_name().and_then(|name| name.to_str()))
                    .and_then(|(parent, name)| described(parent, name, Some("SKILL.md")))
            })
            .await
            .ok()
            .flatten();
        }
        skills.push(offered);
    }
    if skills.is_empty() {
        discard_folder(folder);
        return refused(
            StatusCode::BAD_GATEWAY,
            "skillshare finds no skill to install in this source.",
        );
    }
    let Some(id) = ticket_id() else {
        discard_folder(folder);
        return refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            "The workspace could not make a ticket for this check.",
        );
    };
    let blocked: Vec<&str> = skills
        .iter()
        .filter(|skill| skill.blocked)
        .map(|skill| skill.name.as_str())
        .collect();
    let answer = json!({
        "ticket": id,
        "source": read::safe_url(&source),
        "commit": commit,
        "expires_in": TICKET_LIFE.as_secs(),
        "threshold": threshold,
        "skills": skills,
        "blocked": blocked,
    });
    let ticket = Ticket {
        id,
        made: Instant::now(),
        scope,
        repository: commit.as_ref().map(|_| origin.address),
        source,
        commit,
        skills,
        _download: folder,
    };
    if let Ok(mut tickets) = TICKETS.lock() {
        discard(kept(&mut tickets, 1));
        tickets.push(ticket);
    }
    Json(answer).into_response()
}

fn discard_folder(folder: tempfile::TempDir) {
    tokio::task::spawn_blocking(move || drop(folder));
}

async fn cancel(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        ticket: String,
    }
    let Ok(Wanted { ticket }) = serde_json::from_slice(&body) else {
        return refused(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send ticket: the ticket of a checked source.",
        );
    };
    let found = taken(&ticket);
    let cancelled = found.is_some();
    discard(found.into_iter().collect());
    Json(json!({ "cancelled": cancelled })).into_response()
}

/// What an install request may do with a ticket, or the refusal that says what is missing.
fn chosen(
    ticket: &Ticket,
    names: Option<&[String]>,
    force: bool,
    replace: bool,
) -> Result<Vec<Offered>, Box<Response>> {
    let chosen: Vec<Offered> = match names {
        None => ticket.skills.clone(),
        Some(names) => {
            let mut chosen = Vec::new();
            for name in names {
                match ticket.skills.iter().find(|skill| &skill.name == name) {
                    Some(skill) if !chosen.contains(skill) => chosen.push(skill.clone()),
                    Some(_) => {}
                    None => {
                        return Err(Box::new(refused(
                            StatusCode::UNPROCESSABLE_ENTITY,
                            "Send skills: names from the checked source.",
                        )));
                    }
                }
            }
            chosen
        }
    };
    if chosen.is_empty() {
        return Err(Box::new(refused(
            StatusCode::UNPROCESSABLE_ENTITY,
            INSTALL_SHAPE,
        )));
    }
    let names = |which: fn(&Offered) -> bool| -> Vec<String> {
        chosen
            .iter()
            .filter(|skill| which(skill))
            .map(|skill| skill.name.clone())
            .collect()
    };
    let blocked = names(|skill| skill.blocked);
    if !blocked.is_empty() && !force {
        let error = format!(
            "The audit blocks {}. Nothing was installed. Send force: true to install anyway, at the version that was checked.",
            parse::shortened(&blocked.join(", "), 300)
        );
        let refusal = (
            StatusCode::CONFLICT,
            Json(json!({ "error": error, "blocked": blocked })),
        );
        return Err(Box::new(refusal.into_response()));
    }
    let installed = names(|skill| skill.installed);
    if !installed.is_empty() && !replace && !force {
        let error = format!(
            "The library already has {}. Nothing was installed. Send replace: true to install it again from this source.",
            parse::shortened(&installed.join(", "), 300)
        );
        let refusal = (
            StatusCode::CONFLICT,
            Json(json!({ "error": error, "installed": installed })),
        );
        return Err(Box::new(refusal.into_response()));
    }
    if force && (ticket.commit.is_none() || chosen.iter().any(|skill| !skill.audited)) {
        return Err(Box::new(refused(
            StatusCode::UNPROCESSABLE_ENTITY,
            "The workspace could not check this source itself, so it will not install it against skillshare's audit. Use skillshare on the server.",
        )));
    }
    Ok(chosen)
}

/// Installs skills of a checked source.
async fn install(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        ticket: String,
        skills: Option<Vec<String>>,
        #[serde(default)]
        force: bool,
        #[serde(default)]
        replace: bool,
    }
    let Ok(wanted) = serde_json::from_slice::<Wanted>(&body) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, INSTALL_SHAPE);
    };
    // A refusal leaves the ticket for a second request that says more; an install uses it up.
    let ticket = {
        let Ok(mut tickets) = TICKETS.lock() else {
            return refused(StatusCode::INTERNAL_SERVER_ERROR, NO_TICKET);
        };
        discard(kept(&mut tickets, 0));
        let Some(at) = tickets.iter().position(|ticket| ticket.id == wanted.ticket) else {
            return refused(StatusCode::NOT_FOUND, NO_TICKET);
        };
        if let Err(refusal) = chosen(
            &tickets[at],
            wanted.skills.as_deref(),
            wanted.force,
            wanted.replace,
        ) {
            return *refusal;
        }
        tickets.remove(at)
    };
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let Ok(chosen) = chosen(&ticket, wanted.skills.as_deref(), wanted.force, wanted.replace) else {
            return refused(StatusCode::NOT_FOUND, NO_TICKET);
        };
        let scope = ticket.scope.clone();
        let names: Vec<String> = chosen.iter().map(|skill| skill.name.clone()).collect();
        let picked = names.join(",");
        let pinned = wanted.force && chosen.iter().any(|skill| skill.blocked);
        let whole = ticket.skills.len() == 1 && ticket.skills[0].path == ".";
        let mut arguments = vec!["install"];
        match (pinned, &ticket.repository, &ticket.commit) {
            // Against the audit: the repository at the very commit that was checked, never what it holds by now.
            (true, Some(repository), Some(commit)) => {
                arguments.extend([repository.as_str(), "--force", "--branch", commit.as_str()]);
                if !whole {
                    arguments.extend(["--skill", picked.as_str()]);
                }
            }
            _ => {
                arguments.push(ticket.source.as_str());
                if ticket.skills.len() > 1 {
                    arguments.extend(["--skill", picked.as_str()]);
                }
                // Installing again what is there. skillshare still audits what it fetches, which `--force` would skip.
                if chosen.iter().any(|skill| skill.installed) {
                    arguments.push("--update");
                }
            }
        }
        arguments.extend(["--json", "--kind", "skill", scope.flag()]);
        let ran = match run_at(&program, &scope, &arguments, INSTALL_TIMEOUT).await {
            Ok(ran) => ran,
            Err(trouble) => return trouble.refusal(),
        };
        discard(vec![ticket]);
        let Some(done) = outcome::installed(&ran.out) else {
            return refused(StatusCode::BAD_GATEWAY, &ran.failure());
        };
        library::forget(&scope, &done.skills);
        if let Some(error) = &done.error {
            return if error.contains("use --force to overwrite") {
                refused(
                    StatusCode::CONFLICT,
                    "The library already has a different skill of this name. Remove that one first, then install this one.",
                )
            } else if error.contains("blocked by security audit") {
                refused(
                    StatusCode::CONFLICT,
                    "skillshare's own audit blocked this when it fetched the source to install it, so the source may have changed since it was checked. Nothing was installed. Check the source again.",
                )
            } else {
                refused(StatusCode::BAD_GATEWAY, &ran.failure())
            };
        }
        if !ran.ok || !done.failed.is_empty() || !done.skipped.is_empty() || done.skills.is_empty() {
            let mut said = Vec::new();
            for (what, names) in [
                ("Installed", &done.skills),
                ("Failed", &done.failed),
                ("Already there and left as it is", &done.skipped),
            ] {
                if !names.is_empty() {
                    said.push(format!("{what}: {}.", parse::shortened(&names.join(", "), 300)));
                }
            }
            if said.is_empty() {
                said.push("skillshare installed nothing and gave no reason.".into());
            }
            return refused(StatusCode::BAD_GATEWAY, &said.join(" "));
        }
        let library = Library::read(&program, &scope, false).await;
        library::changed(library, json!({ "installed": done.skills, "pinned": pinned, "output": parse::said("", &ran.err) }))
    })
    .await
}

/// Updates one skill or agent from where it was installed, or all of them.
async fn update(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        id: Option<String>,
        #[serde(default)]
        all: bool,
        project: Option<String>,
    }
    let wanted = match serde_json::from_slice::<Wanted>(&body) {
        Ok(wanted) if wanted.all != wanted.id.is_some() => wanted,
        _ => return refused(StatusCode::UNPROCESSABLE_ENTITY, UPDATE_SHAPE),
    };
    let (program, scope) = match library::opened(wanted.project.as_deref()) {
        Ok(opened) => opened,
        Err((status, problem)) => return refused(status, &problem),
    };
    alone(async move {
        let flag = scope.flag();
        let mut runs: Vec<Vec<String>> = Vec::new();
        let mut named = Vec::new();
        if let Some(id) = &wanted.id {
            let before = Library::read(&program, &scope, true).await;
            if let Some(problem) = before.unreadable() {
                return refused(StatusCode::BAD_GATEWAY, &problem);
            }
            let Some(item) = before.item(id) else {
                return refused(StatusCode::NOT_FOUND, "The library has nothing with this id. Load the library again.");
            };
            let from = item.updates_as.as_deref().filter(|_| item.origin.as_deref() != Some("local"));
            let (Some(from), Kind::Skills | Kind::Agents) = (from, item.kind) else {
                return refused(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "The workspace cannot update this: only a skill or an agent that was installed from somewhere has a newer version to get.",
                );
            };
            let mut run = vec!["update".to_owned()];
            if item.kind == Kind::Agents {
                run.push("agents".into());
            }
            run.extend([from.to_owned(), "--json".into(), flag.into()]);
            runs.push(run);
            named.extend([from.to_owned(), item.name.clone()]);
        } else {
            runs.push(["update", "--all", "--json", flag].map(String::from).to_vec());
            runs.push(["update", "agents", "--all", "--json", flag].map(String::from).to_vec());
        }
        let mut updated = 0;
        let mut blocked: Vec<String> = Vec::new();
        let mut output = Vec::new();
        for (at, run) in runs.iter().enumerate() {
            let arguments: Vec<&str> = run.iter().map(String::as_str).collect();
            let ran = match run_at(&program, &scope, &arguments, INSTALL_TIMEOUT).await {
                Ok(ran) => ran,
                Err(trouble) => return trouble.refusal(),
            };
            let Some(done) = outcome::updated(&ran.out) else {
                // With nothing to update skillshare says so as an error; for "all" that is no failure.
                let nothing = read::error(&ran.out).is_some_and(|error| error.contains("no valid") || error.contains("no skills") || error.contains("no agents"));
                if wanted.all && (nothing || at > 0) {
                    continue;
                }
                return refused(StatusCode::BAD_GATEWAY, &ran.failure());
            };
            if let Some((name, why)) = done.failed.first() {
                library::forget(&scope, &[]);
                return refused(StatusCode::BAD_GATEWAY, &format!("skillshare could not update {name}: {why}"));
            }
            updated += done.updated;
            if done.blocked.is_empty() && done.blocked_count > 0 {
                blocked.extend(named.last().cloned());
            }
            blocked.extend(done.blocked);
            output.push(parse::said("", &ran.err));
        }
        library::forget(&scope, &named);
        let library = Library::read(&program, &scope, false).await;
        output.retain(|said| !said.is_empty());
        library::changed(library, json!({ "updated": updated, "blocked": blocked, "output": output.join("\n") }))
    })
    .await
}

/// Removes one skill, agent or hook from the source, when the request says `confirm`.
async fn uninstall(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        id: String,
        #[serde(default)]
        confirm: bool,
        project: Option<String>,
    }
    let wanted = match serde_json::from_slice::<Wanted>(&body) {
        Ok(wanted) if wanted.confirm && Kind::of(&wanted.id).is_some() => wanted,
        _ => return refused(StatusCode::UNPROCESSABLE_ENTITY, UNINSTALL_SHAPE),
    };
    let (program, scope) = match library::opened(wanted.project.as_deref()) {
        Ok(opened) => opened,
        Err((status, problem)) => return refused(status, &problem),
    };
    alone(async move {
        let before = Library::read(&program, &scope, true).await;
        if let Some(problem) = before.unreadable() {
            return refused(StatusCode::BAD_GATEWAY, &problem);
        }
        let Some(item) = before.item(&wanted.id) else {
            return refused(StatusCode::NOT_FOUND, "The library has nothing with this id. Load the library again.");
        };
        if !item.actions.contains(&"uninstall") {
            return refused(
                StatusCode::UNPROCESSABLE_ENTITY,
                "The workspace cannot remove this: a sync handles MCP servers and plugins, a skill inside a tracked checkout goes with its checkout, and a name skillshare would read as a pattern is not passed on. Use skillshare on the server.",
            );
        }
        let flag = scope.flag();
        let bare = item.path.as_deref().map(|path| match item.kind {
            Kind::Agents => path.strip_suffix(".md").unwrap_or(path),
            _ => path,
        });
        let mut arguments: Vec<&str> = match (item.kind, bare) {
            (Kind::Skills, Some(path)) => vec!["uninstall", path, "--json", flag],
            (Kind::Agents, Some(path)) => vec!["uninstall", "agents", path, "--json", flag],
            (Kind::Hooks, _) => vec!["hooks", "remove", item.name.as_str(), flag],
            _ => return refused(StatusCode::UNPROCESSABLE_ENTITY, UNINSTALL_SHAPE),
        };
        // In a project skillshare asks before it removes; `--json` alone answers that only for the global library.
        if scope.project.is_some() && item.kind != Kind::Hooks {
            arguments.push("--force");
        }
        let ran = match run_at(&program, &scope, &arguments, CHANGE_TIMEOUT).await {
            Ok(ran) => ran,
            Err(trouble) => return trouble.refusal(),
        };
        let mut removed = vec![item.name.clone()];
        if item.kind == Kind::Hooks {
            if !ran.ok {
                return refused(StatusCode::BAD_GATEWAY, &ran.failure());
            }
        } else {
            let Some(done) = outcome::removed(&ran.out).filter(|_| ran.ok) else {
                return refused(StatusCode::BAD_GATEWAY, &ran.failure());
            };
            if !done.failed.is_empty() || done.removed.is_empty() {
                return refused(
                    StatusCode::BAD_GATEWAY,
                    &format!("skillshare could not remove {}.", parse::shortened(&item.name, 200)),
                );
            }
            removed = done.removed;
        }
        library::forget(&scope, &[item.name.clone(), bare.unwrap_or_default().to_owned()]);
        let after = Library::read(&program, &scope, false).await;
        if after.item(&wanted.id).is_some_and(|item| item.state != State::Unknown) && after.unreadable().is_none() && item.kind != Kind::Hooks {
            return refused(StatusCode::BAD_GATEWAY, "skillshare said it removed this, and the library still lists it. Load the library again.");
        }
        let output = if item.kind == Kind::Hooks { ran.said() } else { parse::said("", &ran.err) };
        library::changed(after, json!({ "removed": removed, "output": output }))
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(source: &str) -> (String, Option<String>) {
        let origin = origin(source).unwrap_or_else(|problem| panic!("{source}: {problem}"));
        (origin.address, origin.branch)
    }

    #[test]
    fn a_source_becomes_the_address_git_downloads() {
        for (source, address, branch) in [
            ("owner/repo", "https://github.com/owner/repo", None),
            (
                "owner/repo/skills/pdf",
                "https://github.com/owner/repo",
                None,
            ),
            (
                "github.com/owner/repo",
                "https://github.com/owner/repo",
                None,
            ),
            (
                "github.com/owner/repo/skills/pdf",
                "https://github.com/owner/repo",
                None,
            ),
            (
                "https://github.com/owner/repo",
                "https://github.com/owner/repo",
                None,
            ),
            (
                "https://github.com/owner/repo.git",
                "https://github.com/owner/repo.git",
                None,
            ),
            (
                "https://github.com/owner/repo/",
                "https://github.com/owner/repo",
                None,
            ),
            (
                "https://github.com/owner/repo/tree/dev",
                "https://github.com/owner/repo",
                Some("dev"),
            ),
            (
                "https://github.com/owner/repo/blob/v1.2/skills/pdf/SKILL.md",
                "https://github.com/owner/repo",
                Some("v1.2"),
            ),
            (
                "https://gitlab.example.com/group/sub/repo.git",
                "https://gitlab.example.com/group/sub/repo.git",
                None,
            ),
            (
                "https://example.com/me/good.git//skills/pdf-tools",
                "https://example.com/me/good.git",
                None,
            ),
            (
                "https://git.example.com:8443/owner/repo",
                "https://git.example.com:8443/owner/repo",
                None,
            ),
            (
                "git@github.com:owner/repo.git",
                "git@github.com:owner/repo.git",
                None,
            ),
            (
                "git@github.com:owner/repo",
                "git@github.com:owner/repo",
                None,
            ),
            (
                "ssh://git@host.example/owner/repo",
                "ssh://git@host.example/owner/repo",
                None,
            ),
            (
                "file:///srv/git/skills.git",
                "file:///srv/git/skills.git",
                None,
            ),
            (
                "file:///srv/git/skills.git//skills/pdf",
                "file:///srv/git/skills.git",
                None,
            ),
            ("file:///srv/git/checkout", "file:///srv/git/checkout", None),
            (
                "ssh://host.example:2222/owner/repo.git",
                "ssh://host.example:2222/owner/repo.git",
                None,
            ),
        ] {
            assert_eq!(
                found(source),
                (address.to_owned(), branch.map(str::to_owned)),
                "{source}"
            );
        }
    }

    #[test]
    fn a_source_the_workspace_does_not_download_is_refused() {
        for source in [
            "",
            "repo",
            "-o/repo",
            "owner/--upload-pack=x",
            "owner/repo name",
            "owner/repo\n",
            "../outside/repo",
            "owner/../repo",
            "~/skills",
            "/srv/skills",
            "./skills",
            "http://github.com/owner/repo",
            "https://token@github.com/owner/repo",
            "https://user:pass@github.com/owner/repo",
            "https://github.com/owner",
            "https://localhost/owner/repo",
            "ssh://git:password@host.example/owner/repo",
            "ssh://git@host.example/-oProxyCommand=x",
            "git@host.example:-oProxyCommand=x",
            "git@host.example:/etc/repo",
            "-x@host.example:owner/repo",
            "ext::sh -c id",
            "ext::sh",
            "file://relative/path",
            "file:///srv/../etc/repo.git",
            "git://host.example/owner/repo",
            "ftp://host.example/owner/repo",
        ] {
            assert!(origin(source).is_err(), "{source}");
        }
        assert!(origin(&format!("owner/{}", "r".repeat(MAX_SOURCE))).is_err());
    }

    #[test]
    fn only_plain_names_are_handed_to_the_install() {
        for name in ["pdf-tools", "a", "v1.2_x"] {
            assert!(plain_name(name), "{name}");
        }
        for name in [
            "",
            "a,b",
            "core-*",
            "-f",
            "--force",
            ".hidden",
            "two words",
            "a/b",
            "é",
        ] {
            assert!(!plain_name(name), "{name}");
        }
    }

    #[test]
    fn listed_sizes_are_added_up_before_anything_is_written() {
        let listing = "100644 blob 3b18e512dba79e4c8300dd08aeb37f8e728b8dad      12\tSKILL.md\n\
                       100755 blob 3b18e512dba79e4c8300dd08aeb37f8e728b8dad 1048576\tbin/tool with space\n\
                       160000 commit 3b18e512dba79e4c8300dd08aeb37f8e728b8dad       -\tvendor/sub\n";
        assert_eq!(listed_size(listing), (1_048_588, 3));
        assert_eq!(listed_size(""), (0, 0));
    }

    fn offered(name: &str, blocked: bool, installed: bool, audited: bool) -> Offered {
        Offered {
            name: name.into(),
            path: format!("skills/{name}"),
            description: None,
            installed,
            audited,
            blocked,
            risk: String::new(),
            score: 0,
            findings: Vec::new(),
        }
    }

    fn ticket(skills: Vec<Offered>, commit: Option<&str>) -> Ticket {
        Ticket {
            id: "t".into(),
            made: Instant::now(),
            scope: Scope::default(),
            source: "owner/repo".into(),
            repository: commit.map(|_| "https://github.com/owner/repo.git".into()),
            commit: commit.map(str::to_owned),
            skills,
            _download: tempfile::tempdir().unwrap(),
        }
    }

    fn names(chosen: Result<Vec<Offered>, Box<Response>>) -> Result<Vec<String>, StatusCode> {
        chosen
            .map(|skills| skills.into_iter().map(|skill| skill.name).collect())
            .map_err(|refusal| refusal.status())
    }

    #[test]
    fn a_blocked_or_installed_skill_needs_the_request_to_say_so() {
        let ticket = ticket(
            vec![
                offered("clean", false, false, true),
                offered("evil", true, false, true),
                offered("have", false, true, true),
            ],
            Some("18177eae04d78f46f6fbe8dce9b18c8dcad27837"),
        );
        let only = |names: &[&str]| {
            names
                .iter()
                .map(|&name| name.to_owned())
                .collect::<Vec<_>>()
        };
        let pick = |picked: &[&str], force, replace| {
            names(chosen(
                &ticket,
                Some(only(picked).as_slice()),
                force,
                replace,
            ))
        };
        assert_eq!(pick(&["clean"], false, false), Ok(only(&["clean"])));
        assert_eq!(
            pick(&["clean", "clean"], false, false),
            Ok(only(&["clean"]))
        );
        // Everything, which holds a blocked one: refused until the request says force.
        assert_eq!(
            names(chosen(&ticket, None, false, false)),
            Err(StatusCode::CONFLICT)
        );
        assert_eq!(
            names(chosen(&ticket, None, false, true)),
            Err(StatusCode::CONFLICT)
        );
        assert_eq!(
            names(chosen(&ticket, None, true, false)),
            Ok(only(&["clean", "evil", "have"]))
        );
        assert_eq!(pick(&["have"], false, false), Err(StatusCode::CONFLICT));
        assert_eq!(pick(&["have"], false, true), Ok(only(&["have"])));
        assert_eq!(
            pick(&["other"], true, true),
            Err(StatusCode::UNPROCESSABLE_ENTITY)
        );
        assert_eq!(pick(&[], true, true), Err(StatusCode::UNPROCESSABLE_ENTITY));
    }

    #[test]
    fn what_the_workspace_could_not_check_is_never_forced() {
        let unchecked = ticket(vec![offered("a", false, false, false)], None);
        assert_eq!(
            names(chosen(&unchecked, None, false, false)),
            Ok(vec!["a".to_owned()])
        );
        assert_eq!(
            names(chosen(&unchecked, None, true, false)),
            Err(StatusCode::UNPROCESSABLE_ENTITY)
        );
        let half = ticket(
            vec![offered("a", false, false, false)],
            Some("18177eae04d78f46f6fbe8dce9b18c8dcad27837"),
        );
        assert_eq!(
            names(chosen(&half, None, true, false)),
            Err(StatusCode::UNPROCESSABLE_ENTITY)
        );
    }

    #[test]
    fn downloads_left_behind_are_removed_and_nothing_else_is() {
        let folder = tempfile::tempdir().unwrap();
        let old = std::time::SystemTime::now() - TICKET_LIFE * 5;
        let aged = |name: &str| {
            let path = folder.path().join(name);
            fs::create_dir(&path).unwrap();
            fs::write(path.join("file"), "x").unwrap();
            fs::File::open(&path).unwrap().set_modified(old).unwrap();
            path
        };
        let left = aged(&format!("{SCRATCH}left"));
        let other = aged("someone-elses.folder");
        let fresh = folder.path().join(format!("{SCRATCH}fresh"));
        fs::create_dir(&fresh).unwrap();
        let outside = aged("outside");
        std::os::unix::fs::symlink(&outside, folder.path().join(format!("{SCRATCH}link"))).unwrap();
        sweep(folder.path());
        assert!(!left.exists());
        assert!(other.exists() && fresh.exists() && outside.join("file").exists());
    }

    #[test]
    fn tickets_past_their_time_and_the_oldest_of_too_many_go() {
        let mut tickets: Vec<Ticket> = (0..MAX_TICKETS)
            .map(|at| Ticket {
                id: at.to_string(),
                ..ticket(Vec::new(), None)
            })
            .collect();
        let folders: Vec<std::path::PathBuf> = tickets
            .iter()
            .map(|ticket| ticket._download.path().to_owned())
            .collect();
        if let Some(made) = Instant::now().checked_sub(TICKET_LIFE) {
            tickets[2].made = made;
        }
        let dropped = kept(&mut tickets, 1);
        let ids = |tickets: &[Ticket]| {
            tickets
                .iter()
                .map(|ticket| ticket.id.clone())
                .collect::<Vec<_>>()
        };
        assert_eq!(ids(&dropped), ["2"]);
        assert_eq!(ids(&tickets), ["0", "1", "3"]);
        let more = kept(&mut tickets, 2);
        assert_eq!(
            (ids(&more), ids(&tickets)),
            (vec!["0".to_owned()], vec!["1".to_owned(), "3".to_owned()])
        );
        drop((dropped, more));
        assert!(!folders[2].exists() && !folders[0].exists() && folders[1].exists());
        let id = ticket_id().unwrap();
        assert!(
            id.len() == 32
                && id.bytes().all(|byte| byte.is_ascii_hexdigit())
                && Some(id) != ticket_id()
        );
    }
}
