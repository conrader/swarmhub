//! The whole library, for an app's library screen: every skill, agent, MCP server, plugin and hook with what a
//! sync would do for it (`/api/skillshare/library`), a check for newer versions, a preview of one item, what a sync
//! would change file by file, the switch of one item, and the sync of everything.
//!
//! A reading asks skillshare six things at once: its status, its list, its diff, and its MCP, plugin and hook
//! plans. A part that fails does not take the others with it: the answer names it in `unread`, and what depends on
//! it is `unknown`, never "in sync". The one thing remembered between requests is what the last check for newer
//! versions found (`CHECKS`), because that check asks every origin over the network.

use super::{
    CHANGE_TIMEOUT, NAME_SHAPE, READ_TIMEOUT, READS, SYNC_TIMEOUT, Scope, alone, described, inside,
    mcp::{self, Setting},
    parse::{self, Status, Synced, Target},
    program,
    read::{self, Item, Kind, Parts, State, Updates},
    refused, run_at, status_at,
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
use serde::{Deserialize, Serialize, Serializer};
use std::{
    collections::BTreeMap,
    fs,
    io::Read,
    path::{Path, PathBuf},
    sync::Mutex,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// The plugin list asks each agent program for its version, which takes longer than the other readings.
const PLUGINS_TIMEOUT: Duration = Duration::from_secs(30);
/// A preview carries this much of one file, and this many file names.
const MAX_TEXT: usize = 60_000;
const MAX_FILES: usize = 200;
/// A skill's folder is walked this far when its files are listed.
const MAX_WALK: usize = 5_000;
const MAX_DEPTH: usize = 12;
const MAX_MCP_FILE: u64 = 512 * 1024;
const MAX_DIFF: usize = 60_000;

const ID_SHAPE: &str = "Send id: an item's id as the library gives it, such as skills:code-review.";
const GONE: &str = "The library has nothing with this id. Load the library again.";

/// What the last check for newer versions found, for each library that was checked since the workspace started.
static CHECKS: Mutex<BTreeMap<String, Updates>> = Mutex::new(BTreeMap::new());

pub(super) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/skillshare/library", get(show))
        .route("/api/skillshare/check", post(check))
        .route("/api/skillshare/preview", get(preview))
        .route("/api/skillshare/diff", get(diff))
}

/// One reading that failed, and why.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub(super) struct Unread {
    part: &'static str,
    problem: String,
}

#[derive(Clone, Debug, Serialize)]
struct TargetState {
    #[serde(flatten)]
    target: Target,
    /// How many items wait for this Target.
    waiting: usize,
}

/// Everything a library screen shows.
#[derive(Default, Serialize)]
pub(super) struct Library {
    installed: bool,
    version: Option<String>,
    /// Why the rest is missing, in words for the workspace's owner; `null` when the library was read.
    problem: Option<String>,
    scope: &'static str,
    project: Option<String>,
    source: Option<String>,
    /// How many items of each kind; `null` for a kind that could not be read.
    counts: BTreeMap<&'static str, Option<usize>>,
    item_count: usize,
    #[serde(serialize_with = "first")]
    pub(super) items: Vec<Item>,
    targets: Vec<TargetState>,
    /// How many items wait for a sync.
    waiting: usize,
    sync_blocked: Option<String>,
    unread: Vec<Unread>,
    updates_checked: Option<u64>,
    /// What the items were made from, for a preview.
    #[serde(skip)]
    parts: Parts,
}

fn first<S: Serializer>(items: &[Item], serializer: S) -> Result<S::Ok, S::Error> {
    serializer.collect_seq(items.iter().take(read::MAX_ITEMS))
}

/// Runs one of skillshare's reading commands with `--json` for this library, and takes its answer with `read`.
async fn part<T>(
    program: &Path,
    scope: &Scope,
    arguments: &[&str],
    limit: Duration,
    read: impl FnOnce(&str) -> Option<T>,
) -> Result<T, String> {
    let mut all = arguments.to_vec();
    all.extend(["--json", scope.flag()]);
    let ran = run_at(program, scope, &all, limit)
        .await
        .map_err(|trouble| trouble.text())?;
    read(&ran.out)
        .filter(|_| ran.ok)
        .ok_or_else(|| ran.failure())
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |since| since.as_secs())
}

fn remembered(scope: &Scope) -> Option<Updates> {
    CHECKS.lock().ok()?.get(&scope.key()).cloned()
}

/// The start of a file, at most `limit` bytes of it, when it is an ordinary file.
fn head(file: &Path, limit: u64) -> Option<Vec<u8>> {
    if !fs::symlink_metadata(file).is_ok_and(|found| found.is_file()) {
        return None;
    }
    let mut bytes = Vec::new();
    fs::File::open(file)
        .ok()?
        .take(limit)
        .read_to_end(&mut bytes)
        .ok()?;
    Some(bytes)
}

/// The file the MCP servers are written in, as text.
fn mcp_file(parts: &Parts) -> Option<String> {
    let file = PathBuf::from(parts.mcp.as_ref()?.file.as_ref()?);
    if !file.is_absolute() {
        return None;
    }
    // A link is followed here: skillshare itself named this file as the one it reads.
    let file = fs::canonicalize(file).ok()?;
    Some(String::from_utf8_lossy(&head(&file, MAX_MCP_FILE)?).into_owned())
}

/// What each item says about itself in its own file: a skill's and an agent's description, and for an MCP server
/// what it runs or where it connects to. In the order of `items`.
fn described_items(parts: &Parts, items: &[Item]) -> Vec<Option<String>> {
    let status = parts.status.as_ref();
    let skills = status
        .and_then(|status| status.source.as_deref())
        .map(Path::new);
    let agents = status
        .and_then(|status| status.agents_source.as_deref())
        .map(Path::new);
    let servers = items
        .iter()
        .any(|item| item.kind == Kind::Mcp)
        .then(|| mcp_file(parts))
        .flatten();
    items
        .iter()
        .take(read::MAX_ITEMS)
        .map(|item| match (item.kind, item.path.as_deref()) {
            (Kind::Skills, Some(path)) => described(skills?, path, Some("SKILL.md")),
            (Kind::Agents, Some(path)) => described(agents?, path, None),
            (Kind::Mcp, _) => mcp::summary(&mcp::server(servers.as_deref()?, &item.name)?),
            _ => None,
        })
        .collect()
}

impl Library {
    pub(super) fn unusable(installed: bool, problem: String) -> Self {
        Self {
            installed,
            problem: Some(problem),
            scope: "global",
            ..Self::default()
        }
    }

    /// Reads the library. Skills, agents and MCP servers get their descriptions unless `bare`, which a change asks
    /// for when it only needs to know what is there.
    pub(super) async fn read(program: &Path, scope: &Scope, bare: bool) -> Self {
        let Ok(_turn) = READS.acquire().await else {
            return Self::unusable(true, "The workspace is shutting down.".into());
        };
        let ((status, version), listed, drift, servers, plugins, hooks) = tokio::join!(
            status_at(program, scope),
            part(
                program,
                scope,
                &["list", "--all"],
                READ_TIMEOUT,
                read::listed
            ),
            part(program, scope, &["diff"], READ_TIMEOUT, read::drift),
            part(program, scope, &["mcp", "list"], READ_TIMEOUT, read::mcp),
            part(
                program,
                scope,
                &["plugin", "list"],
                PLUGINS_TIMEOUT,
                read::plugins
            ),
            part(
                program,
                scope,
                &["hooks", "list"],
                READ_TIMEOUT,
                read::hooks
            ),
        );
        let mut unread = Vec::new();
        let mut taken = |part: &'static str, problem: String| unread.push(Unread { part, problem });
        let mut parts = Parts::default();
        let problem = match status {
            Ok(status) => {
                parts.status = Some(status);
                None
            }
            Err(problem) => Some(problem),
        };
        match listed {
            Ok(listed) => parts.listed = Some(listed),
            Err(problem) => taken("list", problem),
        }
        match drift {
            Ok(drift) => parts.drift = Some(drift),
            Err(problem) => taken("diff", problem),
        }
        match servers {
            Ok(servers) => parts.mcp = Some(servers),
            Err(problem) => taken("mcp", problem),
        }
        match plugins {
            Ok(plugins) => parts.plugins = Some(plugins),
            Err(problem) => taken("plugins", problem),
        }
        match hooks {
            Ok(hooks) => parts.hooks = Some(hooks),
            Err(problem) => taken("hooks", problem),
        }
        // Without a status nothing else was read either, for the same reason: one sentence says it.
        if problem.is_some() {
            unread.clear();
        }
        let updates = remembered(scope);
        let mut items = read::items(&parts, updates.as_ref());
        if !bare {
            let read = tokio::task::spawn_blocking(move || {
                let said = described_items(&parts, &items);
                (parts, items, said)
            });
            let Ok((read_parts, mut read_items, said)) = read.await else {
                return Self::unusable(
                    true,
                    "The workspace could not read the library's files.".into(),
                );
            };
            for (item, said) in read_items.iter_mut().zip(said) {
                if said.is_some() {
                    item.description = said;
                }
            }
            (parts, items) = (read_parts, read_items);
        }
        Self::built(
            scope,
            version,
            problem,
            parts,
            items,
            unread,
            updates.map(|updates| updates.at),
        )
    }

    fn built(
        scope: &Scope,
        version: Option<String>,
        problem: Option<String>,
        parts: Parts,
        items: Vec<Item>,
        unread: Vec<Unread>,
        updates_checked: Option<u64>,
    ) -> Self {
        let count = |kind: Kind, read: bool| {
            read.then(|| items.iter().filter(|item| item.kind == kind).count())
        };
        let counts = BTreeMap::from([
            ("skills", count(Kind::Skills, parts.listed.is_some())),
            ("agents", count(Kind::Agents, parts.listed.is_some())),
            ("mcp", count(Kind::Mcp, parts.mcp.is_some())),
            ("plugins", count(Kind::Plugins, parts.plugins.is_some())),
            ("hooks", count(Kind::Hooks, parts.hooks.is_some())),
        ]);
        let status = parts.status.as_ref();
        let targets = status
            .map(|status| status.targets.clone())
            .unwrap_or_default()
            .into_iter()
            .map(|target| TargetState {
                waiting: items
                    .iter()
                    .filter(|item| item.waiting.iter().any(|waits| waits.target == target.name))
                    .count(),
                target,
            })
            .collect();
        let sync_blocked = parts
            .hooks
            .as_ref()
            .and_then(|hooks| hooks.blocked.clone())
            .or_else(|| {
                parts
                    .mcp
                    .as_ref()
                    .filter(|servers| servers.blocked)
                    .map(|_| {
                        "An MCP server conflicts with one an agent program already has.".to_owned()
                    })
            })
            .map(|why| {
                format!("{why} skillshare will not sync until that is settled on the server.")
            });
        let source = status.and_then(|status| status.source.clone());
        let problem = problem.or_else(|| {
            let status = status?;
            let source = status.source.as_ref()?;
            (!status.source_exists)
                .then(|| format!("skillshare's source folder, {source}, does not exist."))
        });
        Self {
            installed: true,
            version,
            problem,
            scope: scope.name(),
            project: scope.project(),
            source,
            counts,
            item_count: items.len(),
            waiting: items
                .iter()
                .filter(|item| item.state == State::Waiting)
                .count(),
            items,
            targets,
            sync_blocked,
            unread,
            updates_checked,
            parts,
        }
    }

    pub(super) fn item(&self, id: &str) -> Option<&Item> {
        self.items.iter().find(|item| item.id == id)
    }

    /// Why nothing can be changed in this library, when it could not be read well enough to check a change.
    pub(super) fn unreadable(&self) -> Option<String> {
        self.problem.clone().or_else(|| {
            self.unread
                .iter()
                .find(|unread| unread.part == "list")
                .map(|unread| unread.problem.clone())
        })
    }

    fn status(&self) -> Option<&Status> {
        self.parts.status.as_ref()
    }
}

/// The program and the library a request is about, or the answer that says why there is none.
pub(super) fn opened(project: Option<&str>) -> Result<(PathBuf, Scope), (StatusCode, String)> {
    let program = program().map_err(|problem| (StatusCode::SERVICE_UNAVAILABLE, problem))?;
    let scope =
        Scope::of(project).map_err(|problem| (StatusCode::UNPROCESSABLE_ENTITY, problem))?;
    Ok((program, scope))
}

#[derive(Default, Deserialize)]
#[serde(default)]
struct Asked {
    project: Option<String>,
    id: Option<String>,
    file: Option<String>,
    what: Option<String>,
}

async fn show(Query(asked): Query<Asked>) -> Json<Library> {
    Json(match opened(asked.project.as_deref()) {
        Ok((program, scope)) => Library::read(&program, &scope, false).await,
        Err((status, problem)) => {
            Library::unusable(status != StatusCode::SERVICE_UNAVAILABLE, problem)
        }
    })
}

/// Asks where every installed skill and agent came from whether there is something newer, and remembers it.
async fn check(body: Bytes) -> Response {
    #[derive(Default, Deserialize)]
    #[serde(deny_unknown_fields, default)]
    struct Wanted {
        project: Option<String>,
    }
    let wanted = if body.iter().all(u8::is_ascii_whitespace) {
        Wanted::default()
    } else if let Ok(wanted) = serde_json::from_slice(&body) {
        wanted
    } else {
        return refused(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Send nothing, or project: a skillshare project's folder.",
        );
    };
    let (program, scope) = match opened(wanted.project.as_deref()) {
        Ok(opened) => opened,
        Err((status, problem)) => return refused(status, &problem),
    };
    // A check fetches into tracked checkouts, so it takes its turn with the changes.
    alone(async move {
        let mut updates = Updates {
            at: now(),
            ..Updates::default()
        };
        let skills = part(&program, &scope, &["check"], SYNC_TIMEOUT, |json| {
            read::checked(json, &mut updates)
        })
        .await;
        if let Err(problem) = skills {
            return refused(StatusCode::BAD_GATEWAY, &problem);
        }
        // An older skillshare has no agents to check: the skills' answer stands on its own.
        let agents = part(
            &program,
            &scope,
            &["check", "agents"],
            SYNC_TIMEOUT,
            |json| read::checked_agents(json, &mut updates),
        )
        .await;
        let found = updates.count();
        if let Ok(mut checks) = CHECKS.lock() {
            checks.insert(scope.key(), updates);
        }
        let library = Library::read(&program, &scope, false).await;
        Json(serde_json::json!({ "library": library, "updates": found, "problem": agents.err() }))
            .into_response()
    })
    .await
}

#[derive(Serialize)]
struct Row {
    key: String,
    value: String,
}

#[derive(Serialize)]
struct TargetLine {
    name: String,
    /// `waiting`, `in_sync`, `off`, or `unknown` when the reading that would say failed.
    state: &'static str,
    action: Option<String>,
}

/// What there is to read about one item.
#[derive(Default, Serialize)]
struct Preview {
    id: String,
    kind: Option<Kind>,
    name: String,
    folder: Option<String>,
    files: Vec<String>,
    file_count: usize,
    file: Option<String>,
    meta: Vec<Row>,
    text: Option<String>,
    truncated: bool,
    settings: Vec<Setting>,
    targets: Vec<TargetLine>,
}

/// The names of the files in a skill's folder, `SKILL.md` first, and how many there are. Links are not followed
/// and `.git` is left out.
fn files(folder: &Path) -> (Vec<String>, usize) {
    let mut names = Vec::new();
    let mut walked = 0;
    let mut waiting = vec![(folder.to_owned(), String::new(), 0)];
    while let Some((folder, prefix, depth)) = waiting.pop() {
        let Ok(entries) = fs::read_dir(&folder) else {
            continue;
        };
        for entry in entries.flatten() {
            walked += 1;
            if walked > MAX_WALK {
                break;
            }
            let Ok(name) = entry.file_name().into_string() else {
                continue;
            };
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let path = format!("{prefix}{name}");
            if kind.is_dir() {
                if name != ".git" && depth < MAX_DEPTH {
                    waiting.push((entry.path(), format!("{path}/"), depth + 1));
                }
            } else if kind.is_file() && parse::printable(&path, parse::MAX_PATH) {
                names.push(path);
            }
        }
    }
    names.sort_by_key(|name| (name != "SKILL.md", name.clone()));
    let count = names.len();
    names.truncate(MAX_FILES);
    (names, count)
}

/// The start of a file as text, and whether there is more of it. `None` for a file that is not text.
fn text(file: &Path) -> Option<(String, bool)> {
    let mut bytes = head(file, MAX_TEXT as u64 + 1)?;
    let truncated = bytes.len() > MAX_TEXT;
    bytes.truncate(MAX_TEXT);
    if bytes.contains(&0) {
        return None;
    }
    match String::from_utf8(bytes) {
        Ok(text) => Some((text, truncated)),
        // The cut went through a character: what is before it is the text.
        Err(error) if truncated && error.utf8_error().error_len().is_none() => {
            let valid = error.utf8_error().valid_up_to();
            let mut bytes = error.into_bytes();
            bytes.truncate(valid);
            String::from_utf8(bytes).ok().map(|text| (text, true))
        }
        Err(_) => None,
    }
}

impl Preview {
    /// Reads one file of a skill or an agent into the preview.
    fn open(&mut self, root: &Path, file: &str) {
        self.file = Some(file.to_owned());
        let Some((read, truncated)) = text(&root.join(file)) else {
            return;
        };
        self.truncated = truncated;
        if file.to_ascii_lowercase().ends_with(".md") {
            let (rows, body) = read::front_matter(&read);
            self.meta = rows
                .into_iter()
                .map(|(key, value)| Row { key, value })
                .collect();
            self.text = Some(body.to_owned());
        } else {
            self.text = Some(read);
        }
    }
}

/// The preview of `item`, read from the library's files. `Err` names a file that was asked for and is not there.
fn previewed(library: &Library, item: &Item, file: Option<&str>) -> Result<Preview, &'static str> {
    let mut preview = Preview {
        id: item.id.clone(),
        kind: Some(item.kind),
        name: item.name.clone(),
        ..Preview::default()
    };
    let mut targets = item.targets.clone();
    for waits in &item.waiting {
        if !targets.contains(&waits.target) {
            targets.push(waits.target.clone());
        }
    }
    preview.targets = targets
        .into_iter()
        .map(|name| {
            let waits = item.waiting.iter().find(|waits| waits.target == name);
            TargetLine {
                state: match (item.state, waits) {
                    (State::Unknown, _) => "unknown",
                    (_, Some(_)) => "waiting",
                    (State::Off, None) => "off",
                    (_, None) => "in_sync",
                },
                action: waits.map(|waits| waits.action.clone()),
                name,
            }
        })
        .collect();
    let status = library.status();
    match (item.kind, item.path.as_deref()) {
        (Kind::Skills, Some(path)) => {
            let source = status
                .and_then(|status| status.source.as_deref())
                .map(Path::new);
            let Some(source) = source.filter(|source| source.is_absolute() && inside(path)) else {
                return Ok(preview);
            };
            let folder = source.join(path);
            preview.folder = Some(folder.to_string_lossy().into_owned());
            (preview.files, preview.file_count) = files(&folder);
            let file = file.unwrap_or("SKILL.md");
            if !inside(file) {
                return Err("Send file: a file's name as the preview lists it.");
            }
            preview.open(&folder, file);
        }
        (Kind::Agents, Some(path)) => {
            let source = status
                .and_then(|status| status.agents_source.as_deref())
                .map(Path::new);
            let Some(source) = source.filter(|source| source.is_absolute() && inside(path)) else {
                return Ok(preview);
            };
            preview.folder = Some(source.to_string_lossy().into_owned());
            preview.files = vec![path.to_owned()];
            preview.file_count = 1;
            preview.open(source, path);
        }
        (Kind::Mcp, _) => {
            preview.settings = mcp_file(&library.parts)
                .and_then(|file| mcp::server(&file, &item.name))
                .unwrap_or_default();
        }
        (Kind::Plugins, _) => {
            let plugin = library
                .parts
                .plugins
                .iter()
                .flatten()
                .find(|plugin| plugin.name == item.name);
            if let Some(plugin) = plugin {
                if let Some(source) = &plugin.source {
                    preview
                        .settings
                        .push(Setting::shown("source", source.as_str()));
                }
                if let Some(version) = &plugin.version {
                    preview
                        .settings
                        .push(Setting::shown("version", version.as_str()));
                }
                for (agent, waits, version) in &plugin.bindings {
                    let mut line = agent.clone();
                    if let Some(version) = version {
                        line = format!("{line} {version}");
                    }
                    if *waits {
                        line.push_str(", waiting");
                    }
                    preview.settings.push(Setting::shown("agent", line));
                }
            }
        }
        (Kind::Hooks, _) => {
            let hook = library
                .parts
                .hooks
                .iter()
                .flat_map(|hooks| &hooks.entries)
                .find(|hook| hook.name == item.name);
            if let Some(hook) = hook {
                if let Some(description) = &hook.description {
                    preview
                        .settings
                        .push(Setting::shown("description", description.as_str()));
                }
                // The events it listens to, never the commands it runs: those can hold what is private.
                for (agent, events) in &hook.agents {
                    let line = if events.is_empty() {
                        agent.clone()
                    } else {
                        format!("{agent}: {}", events.join(", "))
                    };
                    preview.settings.push(Setting::shown("agent", line));
                }
            }
        }
        _ => {}
    }
    Ok(preview)
}

async fn preview(Query(asked): Query<Asked>) -> Response {
    let Some(id) = asked.id.filter(|id| Kind::of(id).is_some()) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, ID_SHAPE);
    };
    let (program, scope) = match opened(asked.project.as_deref()) {
        Ok(opened) => opened,
        Err((status, problem)) => return refused(status, &problem),
    };
    let library = Library::read(&program, &scope, true).await;
    if let Some(problem) = library.unreadable() {
        return refused(StatusCode::BAD_GATEWAY, &problem);
    }
    let read = tokio::task::spawn_blocking(move || {
        let item = library.item(&id).ok_or((StatusCode::NOT_FOUND, GONE))?;
        previewed(&library, item, asked.file.as_deref())
            .map_err(|shape| (StatusCode::UNPROCESSABLE_ENTITY, shape))
    });
    match tokio::time::timeout(READ_TIMEOUT, read).await {
        Ok(Ok(Ok(preview))) => Json(preview).into_response(),
        Ok(Ok(Err((status, problem)))) => refused(status, problem),
        _ => refused(
            StatusCode::GATEWAY_TIMEOUT,
            "The workspace could not read this item's files in time.",
        ),
    }
}

/// What a sync would change, file by file, for the skills or the agents; or with `what=edits` what was edited in
/// one installed skill since it was installed.
async fn diff(Query(asked): Query<Asked>) -> Response {
    let Some(id) = asked.id.filter(|id| Kind::of(id).is_some()) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, ID_SHAPE);
    };
    let edits = match asked.what.as_deref() {
        None | Some("sync") => false,
        Some("edits") => true,
        Some(_) => {
            return refused(
                StatusCode::UNPROCESSABLE_ENTITY,
                "Send what: sync or edits.",
            );
        }
    };
    let (program, scope) = match opened(asked.project.as_deref()) {
        Ok(opened) => opened,
        Err((status, problem)) => return refused(status, &problem),
    };
    let library = Library::read(&program, &scope, true).await;
    if let Some(problem) = library.unreadable() {
        return refused(StatusCode::BAD_GATEWAY, &problem);
    }
    let Some(item) = library.item(&id) else {
        return refused(StatusCode::NOT_FOUND, GONE);
    };
    let (title, arguments): (&str, Vec<&str>) = match (item.kind, edits, item.path.as_deref()) {
        (Kind::Skills, true, Some(path)) if parse::plain_path(path) => (
            "Edited on the server since it was installed",
            vec!["check", path, "--diff", scope.flag()],
        ),
        (Kind::Skills, false, _) => (
            "What a sync would change in the skills",
            vec!["diff", "--stat", "--no-tui", scope.flag()],
        ),
        (Kind::Agents, false, _) => (
            "What a sync would change in the agents",
            vec!["diff", "agents", "--stat", "--no-tui", scope.flag()],
        ),
        _ => {
            return refused(
                StatusCode::UNPROCESSABLE_ENTITY,
                "There is no such comparison for this item: a sync is compared for skills and agents, edits for one skill.",
            );
        }
    };
    match run_at(&program, &scope, &arguments, READ_TIMEOUT).await {
        Err(trouble) => trouble.refusal(),
        Ok(ran) if !ran.ok => refused(StatusCode::BAD_GATEWAY, &ran.failure()),
        Ok(ran) => Json(serde_json::json!({
            "id": id,
            "title": title,
            "text": parse::plain(&ran.out, &ran.err, MAX_DIFF),
        }))
        .into_response(),
    }
}

/// What a change answers with: the library as it is afterwards, and what the change says about itself.
pub(super) fn changed(library: Library, more: serde_json::Value) -> Response {
    let mut answer = serde_json::json!({ "library": library });
    if let (Some(answer), serde_json::Value::Object(more)) = (answer.as_object_mut(), more) {
        answer.extend(more);
    }
    Json(answer).into_response()
}

/// Turns one skill, agent or hook on or off in the source. Targets follow at the next sync.
pub(super) async fn switch(body: &[u8], on: bool) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        id: String,
        project: Option<String>,
    }
    let Ok(Wanted { id, project }) = serde_json::from_slice(body) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, NAME_SHAPE);
    };
    let (program, scope) = match opened(project.as_deref()) {
        Ok(opened) => opened,
        Err((status, problem)) => return refused(status, &problem),
    };
    let verb = if on { "enable" } else { "disable" };
    alone(async move {
        let before = Library::read(&program, &scope, true).await;
        if let Some(problem) = before.unreadable() {
            return refused(StatusCode::BAD_GATEWAY, &problem);
        }
        let Some(item) = before.item(&id) else {
            return refused(StatusCode::NOT_FOUND, GONE);
        };
        let mut output = String::new();
        if item.enabled != on {
            if !item.actions.contains(&verb) {
                return refused(
                    StatusCode::UNPROCESSABLE_ENTITY,
                    "The workspace cannot turn this item on or off: its kind has no switch, or its name has characters skillshare would read as a pattern. Use skillshare on the server.",
                );
            }
            let flag = scope.flag();
            let arguments: Vec<&str> = match (item.kind, item.path.as_deref()) {
                (Kind::Skills, Some(path)) => vec![verb, path, flag],
                (Kind::Agents, Some(path)) => vec![verb, path, "--kind", "agent", flag],
                (Kind::Hooks, _) => vec!["hooks", verb, item.name.as_str(), flag],
                _ => return refused(StatusCode::UNPROCESSABLE_ENTITY, ID_SHAPE),
            };
            match run_at(&program, &scope, &arguments, CHANGE_TIMEOUT).await {
                Err(trouble) => return trouble.refusal(),
                Ok(ran) if !ran.ok => return refused(StatusCode::BAD_GATEWAY, &ran.failure()),
                Ok(ran) => output = ran.said(),
            }
        }
        let after = Library::read(&program, &scope, false).await;
        // skillshare reports success once its own line is written; another rule can still decide the other way.
        if after.item(&id).is_some_and(|item| item.enabled != on) {
            return refused(
                StatusCode::CONFLICT,
                &format!("skillshare did not {verb} this; another rule in its ignore file may decide it. skillshare said: {output}"),
            );
        }
        let changed_ids: Vec<&str> = after
            .items
            .iter()
            .filter(|item| before.item(&item.id).is_some_and(|was| was.enabled != item.enabled))
            .map(|item| item.id.as_str())
            .take(read::MAX_ITEMS)
            .collect();
        let more = serde_json::json!({ "changed": changed_ids, "output": output });
        changed(after, more)
    })
    .await
}

#[derive(Serialize)]
struct SyncDone {
    #[serde(flatten)]
    synced: Synced,
    /// The Targets as they are after the sync.
    targets: Vec<Target>,
    problem: Option<String>,
    output: String,
    library: Library,
}

/// A sync of one library: with `all` every kind, plugins too when one waits; without, the skills.
pub(super) async fn sync(scope: Scope, all: bool, dry_run: bool) -> Response {
    alone(async move {
        let program = match program() {
            Ok(program) => program,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, &problem),
        };
        // Plugins are not part of `sync --all`; they get their own run when one waits.
        let plugins_wait = all
            && !dry_run
            && part(
                &program,
                &scope,
                &["plugin", "list"],
                PLUGINS_TIMEOUT,
                read::plugins,
            )
            .await
            .is_ok_and(|plugins| {
                plugins
                    .iter()
                    .any(|plugin| plugin.bindings.iter().any(|(_, waits, _)| *waits))
            });
        let mut arguments = vec!["sync"];
        if all {
            arguments.push("--all");
        }
        arguments.extend(["--json", scope.flag()]);
        if dry_run {
            arguments.push("--dry-run");
        }
        let ran = match run_at(&program, &scope, &arguments, SYNC_TIMEOUT).await {
            Ok(ran) => ran,
            Err(trouble) => return trouble.refusal(),
        };
        let Some(synced) = parse::synced(&ran.out).filter(|_| ran.ok) else {
            return refused(StatusCode::BAD_GATEWAY, &ran.failure());
        };
        let mut problem = None;
        if plugins_wait {
            let plugins = ["sync", "plugins", "--json", scope.flag()];
            problem = match run_at(&program, &scope, &plugins, SYNC_TIMEOUT).await {
                Ok(ran) if ran.ok => None,
                Ok(ran) => Some(format!(
                    "Everything but the plugins was synced. {}",
                    ran.failure()
                )),
                Err(trouble) => Some(format!(
                    "Everything but the plugins was synced. {}",
                    trouble.text()
                )),
            };
        }
        let library = Library::read(&program, &scope, false).await;
        Json(SyncDone {
            synced,
            targets: library
                .targets
                .iter()
                .map(|state| state.target.clone())
                .collect(),
            problem: problem.or_else(|| library.problem.clone()),
            output: parse::said("", &ran.err),
            library,
        })
        .into_response()
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn library() -> Library {
        let parts = Parts {
            status: parse::status(include_str!("fixtures/status.json")),
            listed: read::listed(include_str!("fixtures/list.json")),
            drift: read::drift(include_str!("fixtures/diff.json")),
            mcp: read::mcp(include_str!("fixtures/mcp.json")),
            plugins: None,
            hooks: read::hooks(include_str!("fixtures/hooks.json")),
        };
        let items = read::items(&parts, None);
        let unread = vec![Unread {
            part: "plugins",
            problem: "skillshare took longer than 30 seconds and was stopped.".into(),
        }];
        Library::built(
            &Scope::default(),
            Some("0.30.8".into()),
            None,
            parts,
            items,
            unread,
            None,
        )
    }

    #[test]
    fn a_library_counts_each_kind_and_what_waits_for_each_target() {
        let library = library();
        let sent = serde_json::to_value(&library).unwrap();
        assert_eq!(sent["installed"], true);
        assert_eq!(sent["scope"], "global");
        assert_eq!(sent["project"], serde_json::Value::Null);
        assert_eq!(sent["source"], "/home/me/.config/skillshare/skills");
        assert_eq!(
            sent["counts"],
            serde_json::json!({"skills": 4, "agents": 1, "mcp": 2, "plugins": null, "hooks": 1})
        );
        assert_eq!(sent["item_count"], 8);
        assert_eq!(sent["items"].as_array().unwrap().len(), 8);
        // alpha, nested, pdf-tools, the agent, two servers and the hook wait; beta is off.
        assert_eq!(sent["waiting"], 7);
        let targets: Vec<_> = sent["targets"]
            .as_array()
            .unwrap()
            .iter()
            .map(|target| {
                (
                    target["name"].as_str().unwrap(),
                    target["waiting"].as_u64().unwrap(),
                )
            })
            .collect();
        assert_eq!(targets, [("claude", 7), ("universal", 3)]);
        assert_eq!(sent["unread"][0]["part"], "plugins");
        assert_eq!(sent["sync_blocked"], serde_json::Value::Null);
        assert_eq!(sent["updates_checked"], serde_json::Value::Null);
        let alpha = &sent["items"][1];
        assert_eq!(alpha["id"], "skills:alpha");
        assert_eq!(alpha["state"], "waiting");
        assert_eq!(alpha["kind"], "skills");
        assert!(alpha.get("updates_as").is_none());
        assert!(sent.get("parts").is_none());
    }

    #[test]
    fn a_library_sends_only_so_many_items_and_counts_them_all() {
        let listed: Vec<_> = (0..read::MAX_ITEMS + 7)
            .map(|index| format!(r#"{{"name":"s{index}","kind":"skill","relPath":"s{index}"}}"#))
            .collect();
        let parts = Parts {
            listed: read::listed(&format!("[{}]", listed.join(","))),
            ..Parts::default()
        };
        let items = read::items(&parts, None);
        let library = Library::built(
            &Scope::default(),
            None,
            None,
            parts,
            items,
            Vec::new(),
            Some(7),
        );
        let sent = serde_json::to_value(&library).unwrap();
        assert_eq!(sent["item_count"], read::MAX_ITEMS + 7);
        assert_eq!(sent["items"].as_array().unwrap().len(), read::MAX_ITEMS);
        assert_eq!(sent["updates_checked"], 7);
        assert!(
            library
                .item(&format!("skills:s{}", read::MAX_ITEMS + 6))
                .is_some()
        );
    }

    #[test]
    fn a_sync_of_everything_is_read_like_a_sync_of_the_skills() {
        let synced = parse::synced(include_str!("fixtures/sync-all.json")).unwrap();
        assert!(synced.dry_run);
        assert_eq!((synced.linked, synced.pruned, synced.ignored), (6, 0, 1));
        let targets: Vec<_> = synced
            .details
            .iter()
            .map(|target| (target.name.as_str(), target.linked))
            .collect();
        assert_eq!(targets, [("claude", 3), ("universal", 3)]);
    }

    #[test]
    fn a_blocked_plan_says_that_a_sync_would_be_refused() {
        let parts = Parts {
            mcp: read::mcp(
                r#"{"blocked":true,"changes":[{"target":"claude","name":"docs","action":"conflict"}]}"#,
            ),
            ..Parts::default()
        };
        let library = Library::built(
            &Scope::default(),
            None,
            None,
            parts,
            Vec::new(),
            Vec::new(),
            None,
        );
        assert_eq!(
            library.sync_blocked.as_deref(),
            Some(
                "An MCP server conflicts with one an agent program already has. skillshare will not sync until that is settled on the server."
            )
        );
    }

    #[test]
    fn a_skill_preview_lists_its_files_and_reads_one() {
        let folder = tempfile::tempdir().unwrap();
        let source = folder.path().join("skills");
        fs::create_dir_all(source.join("alpha/scripts")).unwrap();
        fs::create_dir_all(source.join("alpha/.git")).unwrap();
        fs::write(
            source.join("alpha/SKILL.md"),
            "---\nname: alpha\ndescription: Use when testing.\n---\n\n# Alpha\n",
        )
        .unwrap();
        fs::write(source.join("alpha/scripts/run.sh"), "echo hi\n").unwrap();
        fs::write(source.join("alpha/.git/config"), "[core]\n").unwrap();
        fs::write(source.join("alpha/logo.bin"), [0u8, 159, 146, 150]).unwrap();
        fs::write(folder.path().join("outside.txt"), "private\n").unwrap();
        std::os::unix::fs::symlink(
            folder.path().join("outside.txt"),
            source.join("alpha/link.txt"),
        )
        .unwrap();
        let mut library = library();
        if let Some(status) = &mut library.parts.status {
            status.source = Some(source.to_string_lossy().into_owned());
        }
        let alpha = library.item("skills:alpha").unwrap().clone();

        let preview = previewed(&library, &alpha, None).unwrap();
        assert_eq!(preview.files, ["SKILL.md", "logo.bin", "scripts/run.sh"]);
        assert_eq!(preview.file_count, 3);
        assert_eq!(preview.file.as_deref(), Some("SKILL.md"));
        assert_eq!(preview.meta.len(), 2);
        assert_eq!(preview.text.as_deref(), Some("\n# Alpha\n"));
        assert!(!preview.truncated);
        let lines: Vec<_> = preview
            .targets
            .iter()
            .map(|line| (line.name.as_str(), line.state, line.action.as_deref()))
            .collect();
        assert_eq!(
            lines,
            [
                ("claude", "waiting", Some("add")),
                ("universal", "waiting", Some("add"))
            ]
        );

        let script = previewed(&library, &alpha, Some("scripts/run.sh")).unwrap();
        assert_eq!(script.text.as_deref(), Some("echo hi\n"));
        assert!(script.meta.is_empty());
        // Not text, a link out of the folder, and a file that is not there: named, never read.
        for file in ["logo.bin", "link.txt", "missing.md"] {
            let preview = previewed(&library, &alpha, Some(file)).unwrap();
            assert_eq!(
                (preview.file.as_deref(), preview.text),
                (Some(file), None),
                "{file}"
            );
        }
        for file in ["../outside.txt", "/etc/passwd", ""] {
            assert!(previewed(&library, &alpha, Some(file)).is_err(), "{file}");
        }
    }

    #[test]
    fn a_long_file_is_cut_at_a_whole_character() {
        let folder = tempfile::tempdir().unwrap();
        let file = folder.path().join("long.txt");
        fs::write(&file, format!("{}é and more", "x".repeat(MAX_TEXT - 1))).unwrap();
        let (read, truncated) = text(&file).unwrap();
        assert!(truncated);
        assert_eq!(read.len(), MAX_TEXT - 1);
        fs::write(&file, "short").unwrap();
        assert_eq!(text(&file), Some(("short".to_owned(), false)));
        fs::write(&file, [0xff, 0xfe, 0x41]).unwrap();
        assert_eq!(text(&file), None);
    }

    #[test]
    fn hook_and_server_previews_carry_settings_and_no_commands() {
        let library = library();
        let hook = library.item("hooks:check").unwrap();
        let preview = previewed(&library, hook, None).unwrap();
        let settings: Vec<_> = preview
            .settings
            .iter()
            .map(|setting| (setting.key.as_str(), setting.value.as_str()))
            .collect();
        assert_eq!(
            settings,
            [
                ("description", "Run the check after the agent finishes"),
                ("agent", "claude: Stop")
            ]
        );
        let sent = serde_json::to_string(&preview).unwrap();
        assert!(!sent.contains("make check"), "{sent}");
        assert!(preview.files.is_empty() && preview.text.is_none());
        // The file skillshare names is not on this machine: the server's preview is empty, not an error.
        let server = library.item("mcp:docs").unwrap();
        assert!(
            previewed(&library, server, None)
                .unwrap()
                .settings
                .is_empty()
        );
    }
}
