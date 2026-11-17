//! The library's Git repository and skillshare on this server: what is committed, pushed and pulled, the pull, the
//! push and both in one, a choice per file when a pull meets changes on both sides, skillshare's own health report,
//! and its update.
//!
//! skillshare has no report of the repository's state, so that comes from Git itself. The pull and the push are
//! skillshare's own commands. When its pull stops because this server and the remote changed the same file,
//! skillshare undoes the merge and leaves the rest to Git. The workspace then repeats that merge to learn which
//! files it is about, undoes it again, and sends both versions of each. `resolve` repeats the merge once more and
//! takes, for each file, the side the request names. The request's own text never reaches a command line: a path
//! is passed to Git only when Git itself just listed it as in conflict. skillshare's record of what is installed,
//! `.metadata.json`, is never asked about: it is merged entry by entry, by the rule skillshare's own pull follows.
//!
//! These routes are about the server account's own library, never a project's. Pushing, both ways, resolving and
//! updating skillshare happen only when the request says `confirm`.

use super::{
    CHANGE_TIMEOUT, READ_TIMEOUT, Ran, SYNC_TIMEOUT, Scope, Trouble, alone, health, inside,
    library::Library,
    parse, program, project_config,
    read::{self},
    refused, run, run_tool, status,
};
use crate::Workspace;
use axum::{
    Json, Router,
    body::Bytes,
    extract::Query,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

const FETCH_TIMEOUT: Duration = Duration::from_secs(60);
/// Replacing the skillshare program downloads a release.
const UPGRADE_TIMEOUT: Duration = Duration::from_secs(300);
const MAX_CHANGED: usize = 200;
/// How much of each side of a file in conflict is sent, and how many files.
const MAX_SIDE: usize = 16_000;
const MAX_CONFLICTS: usize = 50;
const MAX_MESSAGE: usize = 200;
const MAX_FOLDERS: usize = 50;
const MESSAGE: &str = "Update skills from SwarmHub";

const NO_REPOSITORY: &str = "The library is not in a Git repository, so there is nothing to pull or push. Set one up on the server with `skillshare init --remote <address>`.";
const NO_REMOTE: &str = "The library's repository has no remote to pull from or push to. Add one on the server with `skillshare init --remote <address>`.";
const UNSAVED: &str = "The library has changes that are not saved to its repository yet, and a pull would not know what to do with them. Sync both ways instead: that saves them first.";
const PUSH_SHAPE: &str =
    "Send confirm: true, and message: one line that says what changed, or leave it out.";
const RESOLVE_SHAPE: &str = "Send confirm: true, push: whether to push afterwards, and choices: mine or theirs for every file of the conflict.";
const UPGRADE_SHAPE: &str = "Send confirm: true. This replaces the skillshare program on this server with its newest release.";

pub(super) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/skillshare/source", get(show))
        .route("/api/skillshare/source/pull", post(pull))
        .route("/api/skillshare/source/push", post(push))
        .route("/api/skillshare/source/sync", post(both_ways))
        .route("/api/skillshare/source/resolve", post(resolve))
        .route("/api/skillshare/machine", get(machine))
        .route("/api/skillshare/upgrade", post(upgrade))
        .route("/api/skillshare/projects", get(projects))
}

/// One file with a change that is not committed.
#[derive(Clone, Debug, PartialEq, Serialize)]
struct Changed {
    /// Git's own short code: `M` changed, `A` added, `D` deleted, `R` renamed, `?` new and not yet known to Git.
    code: String,
    path: String,
}

/// The state of the repository the source is in.
#[derive(Clone, Debug, Default, PartialEq, Serialize)]
struct Source {
    repo: bool,
    folder: Option<String>,
    branch: Option<String>,
    upstream: Option<String>,
    /// Where it is pushed to, without anything that signs in.
    remote: Option<String>,
    ahead: u64,
    behind: u64,
    files: Vec<Changed>,
    file_count: usize,
    problem: Option<String>,
    /// The top folder of the repository, for the commands that follow.
    #[serde(skip)]
    top: Option<PathBuf>,
}

/// What `git status --porcelain=v1 --branch` prints, read into `source`. `false` when the text is not that.
fn read_status(text: &str, source: &mut Source) -> bool {
    let mut lines = text.lines();
    let Some(head) = lines.next().and_then(|line| line.strip_prefix("## ")) else {
        return false;
    };
    let (names, counts) = match head.split_once(" [") {
        Some((names, counts)) => (names, counts.trim_end_matches(']')),
        None => (head, ""),
    };
    let names = names.strip_prefix("No commits yet on ").unwrap_or(names);
    let (branch, upstream) = match names.split_once("...") {
        Some((branch, upstream)) => (branch, Some(upstream)),
        None => (names, None),
    };
    let shown = |name: &str| parse::printable(name, parse::MAX_NAME).then(|| name.to_owned());
    // Not on a branch: Git says "HEAD (no branch)".
    source.branch = shown(branch).filter(|branch| !branch.starts_with("HEAD ("));
    source.upstream = upstream.and_then(shown);
    for count in counts.split(", ") {
        let number = |text: &str| text.trim().parse().unwrap_or(0);
        if let Some(ahead) = count.strip_prefix("ahead ") {
            source.ahead = number(ahead);
        } else if let Some(behind) = count.strip_prefix("behind ") {
            source.behind = number(behind);
        }
    }
    source.files.clear();
    source.file_count = 0;
    for line in lines.filter(|line| line.len() > 3) {
        source.file_count += 1;
        let (code, path) = line.split_at(3);
        if source.files.len() < MAX_CHANGED && parse::printable(path, parse::MAX_PATH) {
            let code = code.trim();
            source.files.push(Changed {
                code: if code.starts_with('?') {
                    "?".into()
                } else {
                    code.to_owned()
                },
                path: path.to_owned(),
            });
        }
    }
    true
}

/// Git's settings for a repository command that stops instead of asking.
fn git_env() -> Vec<(&'static str, String)> {
    vec![
        ("GIT_TERMINAL_PROMPT", "0".into()),
        (
            "GIT_SSH_COMMAND",
            "ssh -o BatchMode=yes -o ConnectTimeout=15".into(),
        ),
        ("LC_ALL", "C".into()),
    ]
}

async fn git(top: &Path, arguments: &[&str], limit: Duration) -> Result<Ran, Trouble> {
    let mut all = vec!["-c".to_owned(), "core.quotePath=false".to_owned()];
    all.extend(arguments.iter().map(|&argument| argument.to_owned()));
    run_tool("git", all, git_env(), limit, top.to_owned(), None).await
}

/// The last thing Git said, for a sentence.
fn git_said(result: &Result<Ran, Trouble>) -> String {
    match result {
        Ok(ran) => {
            let said = parse::said(&ran.out, &ran.err);
            said.lines()
                .last()
                .unwrap_or("Git gave no reason.")
                .trim()
                .to_owned()
        }
        Err(Trouble::Start) => {
            "Git is not installed on this server, or the workspace cannot find it.".into()
        }
        Err(trouble) => trouble.text().replace("skillshare", "Git"),
    }
}

/// Reads the repository the library's source is in. With `fetch`, asks the remote what is new first.
async fn read_source(program: &Path, fetch: bool) -> Source {
    let mut source = Source::default();
    let folder = match status(program).await.0 {
        Ok(status) => status.source.filter(|_| status.source_exists),
        Err(problem) => {
            source.problem = Some(problem);
            return source;
        }
    };
    let Some(folder) = folder
        .map(PathBuf::from)
        .filter(|folder| folder.is_absolute())
    else {
        source.problem = Some("skillshare's source folder does not exist.".into());
        return source;
    };
    source.folder = Some(folder.to_string_lossy().into_owned());
    let top = match git(&folder, &["rev-parse", "--show-toplevel"], READ_TIMEOUT).await {
        Ok(ran) if ran.ok => PathBuf::from(ran.out.trim()),
        // Not a repository is an answer, not a problem.
        Ok(_) => return source,
        Err(trouble) => {
            source.problem = Some(git_said(&Err(trouble)));
            return source;
        }
    };
    if !top.is_absolute() {
        return source;
    }
    source.repo = true;
    if fetch {
        let fetched = git(&top, &["fetch", "--quiet"], FETCH_TIMEOUT).await;
        if !fetched.as_ref().is_ok_and(|ran| ran.ok) {
            source.problem = Some(format!(
                "The workspace could not ask the remote what is new, so this is what was known before: {}",
                git_said(&fetched)
            ));
        }
    }
    let arguments = [
        "status",
        "--porcelain=v1",
        "--branch",
        "--untracked-files=all",
    ];
    let read = git(&top, &arguments, READ_TIMEOUT).await;
    if !read
        .as_ref()
        .is_ok_and(|ran| ran.ok && read_status(&ran.out, &mut source))
    {
        source.problem = Some(format!(
            "Git could not report the repository's state: {}",
            git_said(&read)
        ));
    }
    // The remote the branch follows, or the only one there is.
    let name = match source
        .upstream
        .as_deref()
        .and_then(|upstream| upstream.split_once('/'))
    {
        Some((remote, _)) => Some(remote.to_owned()),
        None => git(&top, &["remote"], READ_TIMEOUT)
            .await
            .ok()
            .and_then(|ran| ran.out.lines().next().map(str::to_owned)),
    };
    if let Some(name) =
        name.filter(|name| parse::agent_name(&name.to_lowercase()) || parse::plain_path(name))
        && let Ok(ran) = git(&top, &["remote", "get-url", &name], READ_TIMEOUT).await
        && ran.ok
    {
        source.remote = Some(read::safe_url(ran.out.trim()))
            .filter(|address| parse::printable(address, parse::MAX_PATH));
    }
    source.top = Some(top);
    source
}

async fn show(Query(asked): Query<BTreeMap<String, String>>) -> Json<Source> {
    let fetch = asked
        .get("fetch")
        .is_some_and(|fetch| fetch == "true" || fetch == "1");
    Json(match program() {
        Ok(program) => read_source(&program, fetch).await,
        Err(problem) => Source {
            problem: Some(problem),
            ..Source::default()
        },
    })
}

/// One file both sides changed, as each side has it. `None` for a side that deleted it.
#[derive(Clone, Debug, PartialEq, Serialize)]
struct Disputed {
    path: String,
    mine: Option<String>,
    theirs: Option<String>,
    /// A side was longer than what is sent.
    cut: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
struct Conflict {
    /// The pull that stopped was part of a sync both ways, so resolving it should push too.
    push: bool,
    files: Vec<Disputed>,
}

/// What a pull that stopped turned out to be.
enum Stopped {
    /// Only skillshare's own record was changed on both sides: it is merged and committed.
    Merged,
    Conflict(Conflict),
}

fn is_record(path: &str) -> bool {
    path == ".metadata.json" || path.ends_with("/.metadata.json")
}

/// Repeats the merge skillshare undid and lists the files both sides changed. The merge stays in progress.
async fn conflicts(top: &Path) -> Result<Vec<String>, String> {
    let _ = git(top, &["merge", "--abort"], CHANGE_TIMEOUT).await;
    // This ends in failure when there is a conflict, which is what is being looked for.
    let _ = git(
        top,
        &["merge", "--no-ff", "--no-commit", "@{u}"],
        CHANGE_TIMEOUT,
    )
    .await;
    let listed = git(
        top,
        &["diff", "--name-only", "--diff-filter=U", "-z"],
        READ_TIMEOUT,
    )
    .await;
    match &listed {
        Ok(ran) if ran.ok => Ok(ran
            .out
            .split('\0')
            .filter(|path| !path.is_empty())
            .map(str::to_owned)
            .collect()),
        _ => Err(git_said(&listed)),
    }
}

async fn abort(top: &Path) {
    let _ = git(top, &["merge", "--abort"], CHANGE_TIMEOUT).await;
}

/// One side of a file at a revision, as much of it as is sent, and whether there was more.
async fn side(top: &Path, revision: &str, path: &str) -> (Option<String>, bool) {
    let named = format!("{revision}:{path}");
    if !git(top, &["cat-file", "-e", &named], READ_TIMEOUT)
        .await
        .is_ok_and(|ran| ran.ok)
    {
        return (None, false);
    }
    match git(top, &["show", &named], READ_TIMEOUT).await {
        Ok(ran) if ran.ok => {
            let cut = ran.out.len() > MAX_SIDE;
            let mut end = ran.out.len().min(MAX_SIDE);
            while !ran.out.is_char_boundary(end) {
                end -= 1;
            }
            (Some(ran.out[..end].to_owned()), cut)
        }
        // Too long for the workspace to read at all, or not text.
        _ => (Some(String::new()), true),
    }
}

/// skillshare's rule for its record of installed skills, when both sides changed the file: an entry changed on
/// one side takes that side; changed on both, the one installed later wins, and the remote on a tie; an entry
/// removed here that the remote left alone stays removed.
fn merge_record(base: &str, ours: &str, theirs: &str) -> Result<String, String> {
    let parsed = |text: &str, side: &str| -> Result<Map<String, Value>, String> {
        if text.trim().is_empty() {
            return Ok(Map::new());
        }
        match serde_json::from_str(text) {
            Ok(Value::Object(record)) => Ok(record),
            _ => Err(format!(
                "skillshare's record of installed skills could not be read on the {side} side."
            )),
        }
    };
    let entries = |record: &Map<String, Value>| -> Map<String, Value> {
        record
            .get("entries")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default()
    };
    let installed = |entry: &Value| {
        entry
            .get("installed_at")
            .and_then(Value::as_str)
            .and_then(|at| chrono::DateTime::parse_from_rfc3339(at).ok())
    };
    let (base, ours, mut merged) = (
        parsed(base, "common")?,
        parsed(ours, "server's")?,
        parsed(theirs, "remote's")?,
    );
    let (old, mine, mut theirs) = (entries(&base), entries(&ours), entries(&merged));
    for (name, entry) in &mine {
        if old.get(name) == Some(entry) {
            continue;
        }
        let takes = match theirs.get(name) {
            None => true,
            Some(remote) => old.get(name) == Some(remote) || installed(entry) > installed(remote),
        };
        if takes {
            theirs.insert(name.clone(), entry.clone());
        }
    }
    let removed_here: Vec<String> = theirs
        .iter()
        .filter(|(name, entry)| !mine.contains_key(*name) && old.get(*name) == Some(*entry))
        .map(|(name, _)| name.clone())
        .collect();
    for name in removed_here {
        theirs.remove(&name);
    }
    merged.insert("entries".into(), Value::Object(theirs));
    serde_json::to_string_pretty(&Value::Object(merged))
        .map(|text| text + "\n")
        .map_err(|_| "skillshare's record of installed skills could not be written.".to_owned())
}

/// Merges every record file of the merge in progress and stages it.
async fn merge_records(top: &Path, files: &[String]) -> Result<(), String> {
    for path in files.iter().filter(|path| is_record(path)) {
        if !inside(path) {
            return Err("Git named a file outside the repository.".into());
        }
        let mut stages = Vec::new();
        for stage in ["1", "2", "3"] {
            let shown = git(top, &["show", &format!(":{stage}:{path}")], READ_TIMEOUT).await;
            stages.push(
                shown
                    .ok()
                    .filter(|ran| ran.ok)
                    .map(|ran| ran.out)
                    .unwrap_or_default(),
            );
        }
        let merged = merge_record(&stages[0], &stages[1], &stages[2])?;
        let file = top.join(path);
        // A link is not written through: the record is an ordinary file wherever skillshare made it.
        if fs::symlink_metadata(&file).is_ok_and(|found| !found.is_file())
            || fs::write(&file, merged).is_err()
        {
            return Err(
                "The workspace could not write skillshare's record of installed skills.".into(),
            );
        }
        let added = git(top, &["add", "--", path], CHANGE_TIMEOUT).await;
        if !added.as_ref().is_ok_and(|ran| ran.ok) {
            return Err(git_said(&added));
        }
    }
    Ok(())
}

async fn commit_merge(top: &Path) -> Result<(), String> {
    let committed = git(top, &["commit", "--quiet", "--no-edit"], CHANGE_TIMEOUT).await;
    if committed.as_ref().is_ok_and(|ran| ran.ok) {
        Ok(())
    } else {
        Err(git_said(&committed))
    }
}

/// After skillshare's pull stopped: reads what it stopped on and puts the repository back as it was, or, when
/// only skillshare's record was in the way, merges that and commits. `None` when nothing is in conflict.
async fn stopped(top: &Path, push: bool) -> Result<Option<Stopped>, String> {
    let all = match conflicts(top).await {
        Ok(all) => all,
        Err(problem) => {
            abort(top).await;
            return Err(problem);
        }
    };
    let files: Vec<&String> = all.iter().filter(|path| !is_record(path)).collect();
    if files.is_empty() && !all.is_empty() {
        let merged = match merge_records(top, &all).await {
            Ok(()) => commit_merge(top).await,
            Err(problem) => Err(problem),
        };
        return match merged {
            Ok(()) => Ok(Some(Stopped::Merged)),
            Err(problem) => {
                abort(top).await;
                Err(problem)
            }
        };
    }
    abort(top).await;
    let mut disputed = Vec::new();
    for path in files.into_iter().take(MAX_CONFLICTS) {
        if !parse::printable(path, parse::MAX_PATH) {
            return Err("A file both sides changed has a name the workspace cannot send. Resolve this with Git on the server.".into());
        }
        let (mine, cut_mine) = side(top, "HEAD", path).await;
        let (theirs, cut_theirs) = side(top, "@{u}", path).await;
        disputed.push(Disputed {
            path: path.clone(),
            mine,
            theirs,
            cut: cut_mine || cut_theirs,
        });
    }
    Ok(
        (!disputed.is_empty()).then_some(Stopped::Conflict(Conflict {
            push,
            files: disputed,
        })),
    )
}

/// Whether a skillshare command that has no `--json` failed, and the line that says why. It marks a failure with
/// a cross and does not always end with a failure code.
fn failed(ran: &Ran) -> Option<String> {
    let said = ran.said();
    let crossed = said.lines().rev().find_map(|line| {
        line.trim()
            .strip_prefix('✗')
            .map(|rest| rest.trim().to_owned())
    });
    match crossed {
        Some(line) => Some(line),
        None if ran.ok => None,
        None => Some(
            said.lines()
                .last()
                .unwrap_or("skillshare gave no reason.")
                .to_owned(),
        ),
    }
}

fn conflict_like(ran: &Ran) -> bool {
    let said = ran.said().to_lowercase();
    ["both changed", "merge was undone", "conflict"]
        .iter()
        .any(|sign| said.contains(sign))
}

/// What a pull, a push or both answer with: the repository and the library as they are now.
async fn answered(program: &Path, output: String, conflict: Option<Conflict>) -> Response {
    let source = read_source(program, false).await;
    let library = Library::read(program, &Scope::default(), false).await;
    Json(json!({ "source": source, "library": library, "output": output, "conflict": conflict }))
        .into_response()
}

/// The repository, when it is one that can be pulled into and pushed from; otherwise the refusal.
async fn remote_repository(program: &Path) -> Result<(Source, PathBuf), (StatusCode, String)> {
    let source = read_source(program, false).await;
    if let (false, Some(problem)) = (source.repo, &source.problem) {
        return Err((StatusCode::BAD_GATEWAY, problem.clone()));
    }
    let Some(top) = source.top.clone().filter(|_| source.repo) else {
        return Err((StatusCode::CONFLICT, NO_REPOSITORY.into()));
    };
    if source.remote.is_none() {
        return Err((StatusCode::CONFLICT, NO_REMOTE.into()));
    }
    Ok((source, top))
}

/// Brings the remote's changes into the library and syncs the Targets.
async fn pull(_body: Bytes) -> Response {
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let (source, top) = match remote_repository(&program).await {
            Ok(found) => found,
            Err((status, why)) => return refused(status, &why),
        };
        if source.file_count > 0 {
            return refused(StatusCode::CONFLICT, UNSAVED);
        }
        let ran = match run(&program, &["pull"], SYNC_TIMEOUT).await {
            Ok(ran) => ran,
            Err(trouble) => return trouble.refusal(),
        };
        let Some(why) = failed(&ran) else {
            return answered(&program, ran.said(), None).await;
        };
        if !conflict_like(&ran) {
            return refused(StatusCode::BAD_GATEWAY, &format!("skillshare said: {why}"));
        }
        match stopped(&top, false).await {
            Ok(Some(Stopped::Conflict(conflict))) => {
                answered(
                    &program,
                    "Nothing was changed: this server and the remote changed the same files."
                        .into(),
                    Some(conflict),
                )
                .await
            }
            // Only skillshare's record differed: it is merged, so the Targets can follow.
            Ok(Some(Stopped::Merged)) => synced(&program, false).await,
            Ok(None) => refused(StatusCode::BAD_GATEWAY, &format!("skillshare said: {why}")),
            Err(problem) => refused(StatusCode::BAD_GATEWAY, &problem),
        }
    })
    .await
}

/// After a merge the workspace finished itself: the Targets get the result, and with `push` the remote too.
async fn synced(program: &Path, push: bool) -> Response {
    let arguments: &[&str] = if push {
        &["push", "--pull", "-m", MESSAGE]
    } else {
        &["sync", "--all", "--json", "-g"]
    };
    match run(program, arguments, SYNC_TIMEOUT).await {
        Err(trouble) => trouble.refusal(),
        Ok(ran) => match (push, failed(&ran)) {
            (true, Some(why)) => refused(
                StatusCode::BAD_GATEWAY,
                &format!(
                    "The merge is done on this server, and the push after it failed. skillshare said: {why}"
                ),
            ),
            (false, _) if !ran.ok => refused(
                StatusCode::BAD_GATEWAY,
                &format!(
                    "The merge is done on this server, and the sync after it failed. {}",
                    ran.failure()
                ),
            ),
            _ => {
                answered(
                    program,
                    if push {
                        ran.said()
                    } else {
                        "Merged, and your bots have the result.".into()
                    },
                    None,
                )
                .await
            }
        },
    }
}

#[derive(Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
struct Outward {
    confirm: bool,
    message: Option<String>,
}

/// The commit message of a request, or the default; `None` for one that is not a plain line.
fn message(wanted: &Outward) -> Option<String> {
    match wanted.message.as_deref().map(str::trim) {
        None | Some("") => Some(MESSAGE.to_owned()),
        Some(message) => (message.chars().count() <= MAX_MESSAGE
            && !message.starts_with('-')
            && !message.chars().any(char::is_control))
        .then(|| message.to_owned()),
    }
}

fn outward(body: &[u8]) -> Option<String> {
    let wanted: Outward = if body.iter().all(u8::is_ascii_whitespace) {
        Outward::default()
    } else {
        serde_json::from_slice(body).ok()?
    };
    wanted.confirm.then(|| message(&wanted)).flatten()
}

/// Commits what is uncommitted and pushes.
async fn push(body: Bytes) -> Response {
    let Some(message) = outward(&body) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, PUSH_SHAPE);
    };
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        if let Err((status, why)) = remote_repository(&program).await {
            return refused(status, &why);
        }
        match run(&program, &["push", "-m", &message], SYNC_TIMEOUT).await {
            Err(trouble) => trouble.refusal(),
            Ok(ran) => match failed(&ran) {
                Some(why) => refused(StatusCode::BAD_GATEWAY, &format!("skillshare said: {why}")),
                None => answered(&program, ran.said(), None).await,
            },
        }
    })
    .await
}

/// Commits, pulls, pushes and syncs the Targets: both ways.
async fn both_ways(body: Bytes) -> Response {
    let Some(message) = outward(&body) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, PUSH_SHAPE);
    };
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let top = match remote_repository(&program).await {
            Ok((_, top)) => top,
            Err((status, why)) => return refused(status, &why),
        };
        let ran = match run(&program, &["push", "--pull", "-m", &message], SYNC_TIMEOUT).await {
            Ok(ran) => ran,
            Err(trouble) => return trouble.refusal(),
        };
        let Some(why) = failed(&ran) else {
            return answered(&program, ran.said(), None).await;
        };
        if !conflict_like(&ran) {
            return refused(StatusCode::BAD_GATEWAY, &format!("skillshare said: {why}"));
        }
        match stopped(&top, true).await {
            Ok(Some(Stopped::Conflict(conflict))) => {
                answered(&program, "Your changes are saved on this server. Nothing was pushed: this server and the remote changed the same files.".into(), Some(conflict)).await
            }
            Ok(Some(Stopped::Merged)) => synced(&program, true).await,
            Ok(None) => refused(StatusCode::BAD_GATEWAY, &format!("skillshare said: {why}")),
            Err(problem) => refused(StatusCode::BAD_GATEWAY, &problem),
        }
    })
    .await
}

/// Repeats the pull that stopped, with the request's choice for each file.
async fn resolve(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        #[serde(default)]
        confirm: bool,
        #[serde(default)]
        push: bool,
        choices: BTreeMap<String, String>,
    }
    let wanted = match serde_json::from_slice::<Wanted>(&body) {
        Ok(wanted)
            if wanted.confirm
                && !wanted.choices.is_empty()
                && wanted.choices.len() <= MAX_CONFLICTS
                && wanted
                    .choices
                    .values()
                    .all(|side| side == "mine" || side == "theirs") =>
        {
            wanted
        }
        _ => return refused(StatusCode::UNPROCESSABLE_ENTITY, RESOLVE_SHAPE),
    };
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let top = match remote_repository(&program).await {
            Ok((_, top)) => top,
            Err((status, why)) => return refused(status, &why),
        };
        let all = match conflicts(&top).await {
            Ok(all) => all,
            Err(problem) => {
                abort(&top).await;
                return refused(StatusCode::BAD_GATEWAY, &problem);
            }
        };
        let files: Vec<&String> = all.iter().filter(|path| !is_record(path)).collect();
        if all.is_empty() {
            abort(&top).await;
            return refused(StatusCode::CONFLICT, "There is no stopped pull to finish any more. Load the repository's state again.");
        }
        // The remote moved since the choices were made: other files are in conflict now. Ask again, guess nothing.
        if files.iter().any(|path| !wanted.choices.contains_key(*path)) {
            return match stopped(&top, wanted.push).await {
                Ok(Some(Stopped::Conflict(conflict))) => {
                    answered(&program, "The remote changed since you chose, and other files are in the way now. Nothing was changed. Choose again.".into(), Some(conflict)).await
                }
                Ok(_) => refused(StatusCode::CONFLICT, "The remote changed since you chose. Nothing was changed. Load the repository's state again."),
                Err(problem) => refused(StatusCode::BAD_GATEWAY, &problem),
            };
        }
        let mut done = merge_records(&top, &all).await;
        for path in &files {
            if done.is_err() {
                break;
            }
            // Git listed this path itself; the request only decides the side.
            let side = if wanted.choices.get(*path).is_some_and(|side| side == "theirs") { "--theirs" } else { "--ours" };
            let taken = git(&top, &["checkout", side, "--", path], CHANGE_TIMEOUT).await;
            let staged = if taken.is_ok_and(|ran| ran.ok) {
                git(&top, &["add", "--", path], CHANGE_TIMEOUT).await
            } else {
                // The chosen side deleted the file.
                git(&top, &["rm", "--quiet", "--", path], CHANGE_TIMEOUT).await
            };
            if !staged.as_ref().is_ok_and(|ran| ran.ok) {
                done = Err(git_said(&staged));
            }
        }
        if done.is_ok() {
            let left = git(&top, &["diff", "--name-only", "--diff-filter=U"], READ_TIMEOUT).await;
            done = match &left {
                Ok(ran) if ran.ok && ran.out.trim().is_empty() => commit_merge(&top).await,
                Ok(ran) if ran.ok => Err("A file is still in conflict.".into()),
                _ => Err(git_said(&left)),
            };
        }
        if let Err(problem) = done {
            abort(&top).await;
            return refused(StatusCode::BAD_GATEWAY, &format!("The choices could not be applied, and nothing was changed. {problem}"));
        }
        synced(&program, wanted.push).await
    })
    .await
}

/// This server's name, as the system knows it.
fn host() -> Option<String> {
    let mut name = [0u8; 256];
    // The buffer is ours and one byte longer than what is asked for, so the name always ends inside it.
    let named = unsafe { libc::gethostname(name.as_mut_ptr().cast(), name.len() - 1) } == 0;
    let end = name.iter().position(|byte| *byte == 0)?;
    let name = String::from_utf8_lossy(&name[..end]).into_owned();
    let short = name.split('.').next().unwrap_or(&name).to_owned();
    (named && parse::printable(&short, parse::MAX_NAME)).then_some(short)
}

/// skillshare on this server: its version, the repository, the Targets and what waits, and its own health report.
async fn machine(Query(asked): Query<BTreeMap<String, String>>) -> Json<Value> {
    let check = asked
        .get("check")
        .is_some_and(|check| check == "true" || check == "1");
    let program = match program() {
        Ok(program) => program,
        Err(problem) => {
            return Json(json!({ "installed": false, "host": host(), "problem": problem }));
        }
    };
    let scope = Scope::default();
    let (library, source, doctor) = tokio::join!(
        Library::read(&program, &scope, true),
        read_source(&program, false),
        // The report ends with a failure code when it found an error, and still prints.
        run(&program, &["doctor", "--json", "-g"], READ_TIMEOUT),
    );
    let doctor = doctor.ok().and_then(|ran| health::doctor(&ran.out));
    let newest = if check {
        run(&program, &["updates", "check", "--json"], READ_TIMEOUT)
            .await
            .ok()
            .and_then(|ran| health::newest(&ran.out))
    } else {
        None
    };
    let mut answer = serde_json::to_value(&library).unwrap_or_default();
    let take =
        |answer: &mut Value, key: &str| answer.get_mut(key).map(Value::take).unwrap_or_default();
    let version = doctor
        .as_ref()
        .and_then(|doctor| doctor.version.clone())
        .map(Value::String)
        .unwrap_or_else(|| take(&mut answer, "version"));
    Json(json!({
        "installed": true,
        "version": version,
        "latest": newest.as_ref().map(|(latest, _)| latest),
        "update_available": newest.as_ref().map(|(_, available)| available),
        "host": host(),
        "problem": take(&mut answer, "problem"),
        "source": source,
        "targets": take(&mut answer, "targets"),
        "waiting": take(&mut answer, "waiting"),
        "doctor": doctor,
    }))
}

/// Replaces the skillshare program on this server with its newest release.
async fn upgrade(body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        confirm: bool,
    }
    if !serde_json::from_slice::<Wanted>(&body).is_ok_and(|wanted| wanted.confirm) {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, UPGRADE_SHAPE);
    }
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        let ran = match run(&program, &["upgrade", "--cli", "--force"], UPGRADE_TIMEOUT).await {
            Ok(ran) => ran,
            Err(trouble) => return trouble.refusal(),
        };
        if let Some(why) = failed(&ran) {
            return refused(StatusCode::BAD_GATEWAY, &format!("skillshare said: {why}"));
        }
        let version = run(&program, &["version"], READ_TIMEOUT)
            .await
            .ok()
            .and_then(|ran| parse::version(&ran.out));
        Json(json!({ "version": version, "output": ran.said() })).into_response()
    })
    .await
}

/// Which of the folders a request names hold a skillshare project.
async fn projects(Query(asked): Query<Vec<(String, String)>>) -> Json<Value> {
    let folders: Vec<String> = asked
        .into_iter()
        .filter(|(key, _)| key == "folder")
        .map(|(_, folder)| folder)
        .take(MAX_FOLDERS)
        .collect();
    let found = tokio::task::spawn_blocking(move || {
        folders
            .into_iter()
            .filter_map(|folder| {
                let config = project_config(&folder)?;
                Some(json!({ "folder": folder, "config": config.to_string_lossy() }))
            })
            .collect::<Vec<_>>()
    })
    .await
    .unwrap_or_default();
    Json(json!({ "projects": found }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(text: &str) -> Source {
        let mut source = Source::default();
        assert!(read_status(text, &mut source), "{text}");
        source
    }

    #[test]
    fn the_branch_line_gives_what_is_ahead_and_behind() {
        let source = read(
            "## main...origin/main [ahead 1, behind 2]\n M alpha/SKILL.md\n?? new skill/SKILL.md\nR  old.md -> new.md\nD  gone.md\n",
        );
        assert_eq!(
            (source.branch.as_deref(), source.upstream.as_deref()),
            (Some("main"), Some("origin/main"))
        );
        assert_eq!((source.ahead, source.behind, source.file_count), (1, 2, 4));
        let files: Vec<_> = source
            .files
            .iter()
            .map(|file| (file.code.as_str(), file.path.as_str()))
            .collect();
        assert_eq!(
            files,
            [
                ("M", "alpha/SKILL.md"),
                ("?", "new skill/SKILL.md"),
                ("R", "old.md -> new.md"),
                ("D", "gone.md")
            ]
        );
        let clean = read("## master...origin/master\n");
        assert_eq!(
            (
                clean.ahead,
                clean.behind,
                clean.file_count,
                clean.upstream.as_deref()
            ),
            (0, 0, 0, Some("origin/master"))
        );
        let behind = read("## main...origin/main [behind 3]");
        assert_eq!((behind.ahead, behind.behind), (0, 3));
        let local = read("## main\n");
        assert_eq!(
            (local.branch.as_deref(), local.upstream.as_deref()),
            (Some("main"), None)
        );
        let new = read("## No commits yet on main\n?? .skillignore\n");
        assert_eq!((new.branch.as_deref(), new.file_count), (Some("main"), 1));
        assert_eq!(read("## HEAD (no branch)\n").branch, None);
        let mut source = Source::default();
        for text in ["", "fatal: not a git repository", " M alpha/SKILL.md\n"] {
            assert!(!read_status(text, &mut source), "{text}");
        }
    }

    #[test]
    fn many_changed_files_are_counted_and_only_so_many_sent() {
        let lines: Vec<_> = (0..MAX_CHANGED + 20)
            .map(|index| format!("?? file{index}"))
            .collect();
        let source = read(&format!("## main\n{}\n", lines.join("\n")));
        assert_eq!(
            (source.files.len(), source.file_count),
            (MAX_CHANGED, MAX_CHANGED + 20)
        );
    }

    fn record(entries: &[(&str, &str, &str)]) -> String {
        let entries: Map<String, Value> = entries
            .iter()
            .map(|(name, version, at)| {
                (
                    (*name).to_owned(),
                    json!({ "version": version, "installed_at": at }),
                )
            })
            .collect();
        json!({ "version": 1, "entries": entries }).to_string()
    }

    fn versions(merged: &str) -> Vec<(String, String)> {
        let merged: Value = serde_json::from_str(merged).unwrap();
        merged["entries"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(name, entry)| (name.clone(), entry["version"].as_str().unwrap().to_owned()))
            .collect()
    }

    #[test]
    fn the_record_of_installed_skills_is_merged_entry_by_entry() {
        let early = "2026-11-01T10:00:00+01:00";
        let late = "2026-11-02T10:00:00Z";
        let base = record(&[
            ("same", "1", early),
            ("mine", "1", early),
            ("theirs", "1", early),
            ("both", "1", early),
            ("gone-here", "1", early),
            ("gone-there", "1", early),
        ]);
        let ours = record(&[
            ("same", "1", early),
            ("mine", "2", late),
            ("theirs", "1", early),
            ("both", "2", late),
            ("gone-there", "1", early),
            ("new-here", "1", late),
        ]);
        let theirs = record(&[
            ("same", "1", early),
            ("mine", "1", early),
            ("theirs", "2", late),
            ("both", "3", early),
            ("gone-here", "1", early),
            ("new-there", "1", late),
        ]);
        let merged = merge_record(&base, &ours, &theirs).unwrap();
        assert!(merged.ends_with("}\n") && merged.contains("\n  \"entries\": {"));
        let pair = |name: &str, version: &str| (name.to_owned(), version.to_owned());
        assert_eq!(
            versions(&merged),
            [
                // Changed on both sides: the later install wins.
                pair("both", "2"),
                // Removed on the remote and untouched here: the remote's file is the start, so it stays gone.
                pair("mine", "2"),
                pair("new-here", "1"),
                pair("new-there", "1"),
                pair("same", "1"),
                pair("theirs", "2"),
            ]
        );
        // A tie goes to the remote, and an edit here beats a removal there.
        let tie = merge_record(
            &record(&[("a", "1", early)]),
            &record(&[("a", "2", late)]),
            &record(&[("a", "3", late)]),
        )
        .unwrap();
        assert_eq!(versions(&tie), [pair("a", "3")]);
        let edited = merge_record(
            &record(&[("a", "1", early)]),
            &record(&[("a", "2", late)]),
            &record(&[]),
        )
        .unwrap();
        assert_eq!(versions(&edited), [pair("a", "2")]);
        // No common ancestor had the file.
        let fresh = merge_record(
            "",
            &record(&[("a", "1", early)]),
            &record(&[("b", "1", early)]),
        )
        .unwrap();
        assert_eq!(versions(&fresh), [pair("a", "1"), pair("b", "1")]);
        // What else the remote's record holds is kept.
        let extra = merge_record(
            "",
            "{}",
            r#"{"version":1,"entries":{},"audit_accepted":{"x":["f"]}}"#,
        )
        .unwrap();
        assert!(extra.contains("audit_accepted"));
        assert!(merge_record("", "not json", "{}").is_err());
        assert!(merge_record("", "{}", "[]").is_err());
    }

    #[test]
    fn only_the_record_file_is_merged_without_asking() {
        for path in [".metadata.json", "skills/.metadata.json"] {
            assert!(is_record(path), "{path}");
        }
        for path in [
            "metadata.json",
            "alpha/SKILL.md",
            ".metadata.json.bak",
            "x.metadata.json",
        ] {
            assert!(!is_record(path), "{path}");
        }
    }

    fn ran(ok: bool, out: &str, err: &str) -> Ran {
        Ran {
            ok,
            out: out.into(),
            err: err.into(),
        }
    }

    #[test]
    fn a_cross_marks_a_failed_pull_or_push_whatever_the_exit_code() {
        let dirty = ran(
            true,
            "✗ Local changes detected\n  Run: skillshare push\n\n✗ local changes must be pushed or stashed before pulling\n",
            "",
        );
        assert_eq!(
            failed(&dirty).as_deref(),
            Some("local changes must be pushed or stashed before pulling")
        );
        assert!(!conflict_like(&dirty));
        let stopped = ran(
            false,
            "✓ Commit    1 file · mine\n✗ git pull failed\npull stopped: this machine and the remote both changed alpha/SKILL.md; the merge was undone, resolve it with git in /x\n",
            "",
        );
        assert!(failed(&stopped).is_some() && conflict_like(&stopped));
        assert_eq!(
            failed(&ran(
                true,
                "✓ Commit    6 files · first\n✓ Push      to origin/main · 2.5s\n",
                ""
            )),
            None
        );
        assert_eq!(
            failed(&ran(false, "", "exit status 1\n")).as_deref(),
            Some("exit status 1")
        );
        assert_eq!(
            failed(&ran(false, "", "")).as_deref(),
            Some("skillshare gave no reason.")
        );
    }

    #[test]
    fn a_commit_message_is_one_plain_line() {
        let wanted = |message: Option<&str>| Outward {
            confirm: true,
            message: message.map(str::to_owned),
        };
        assert_eq!(message(&wanted(None)).as_deref(), Some(MESSAGE));
        assert_eq!(message(&wanted(Some("  "))).as_deref(), Some(MESSAGE));
        assert_eq!(
            message(&wanted(Some(" Add the PDF skill "))).as_deref(),
            Some("Add the PDF skill")
        );
        for text in ["-m sneaky", "two\nlines", "tab\there"] {
            assert_eq!(message(&wanted(Some(text))), None, "{text}");
        }
        assert_eq!(message(&wanted(Some(&"x".repeat(MAX_MESSAGE + 1)))), None);
        // Nothing outward without the request saying so.
        assert_eq!(outward(b""), None);
        assert_eq!(outward(br#"{"message":"x"}"#), None);
        assert_eq!(outward(br#"{"confirm":false}"#), None);
        assert_eq!(outward(br#"{"confirm":true,"force":true}"#), None);
        assert_eq!(outward(br#"{"confirm":true}"#).as_deref(), Some(MESSAGE));
        assert_eq!(
            outward(br#"{"confirm":true,"message":"Tidy"}"#).as_deref(),
            Some("Tidy")
        );
    }

    #[test]
    fn this_server_has_a_name() {
        assert!(host().is_some_and(|name| !name.is_empty() && !name.contains('.')));
    }
}
