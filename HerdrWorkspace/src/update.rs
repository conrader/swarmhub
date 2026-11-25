//! `/api/update` and the `version`, `update-probe` and `update-watch` commands: which workspace server this is, and
//! how it replaces itself with a newer release without ending anyone's agents.
//!
//! What an app needs to know is in `info()`, which `/api/workspace` also carries: the server's version, the level
//! of the API it serves (`API`) and the oldest app level it still serves (`API_MIN`). An app compares numbers; it
//! does not guess from missing routes.
//!
//! An update is one signed manifest and one program file. The manifest names the release, its API levels and, per
//! machine type, the program's name, size and SHA-256. Its signature is Ed25519 over the manifest's bytes, checked
//! against `RELEASE_KEY`, the same public key the Mac app carries for its own updates. That key is compiled in; no
//! request and no setting can name another. The server fetches both from the releases page itself (`apply`), or an
//! app that has them hands them over (`upload`) when the server has no way out to the internet. Either way the
//! server checks the signature and the digest itself, and refuses a release that is not newer than it is.
//!
//! Nothing is replaced until the new program has shown that it runs here: it must report the manifest's version,
//! and it must open a copy of the journal, which runs its migrations there. Then the journal is already backed up,
//! the running program is kept beside the new one as `swarmhub-herdr.previous`, the new one takes its name in one
//! rename, and this process becomes the new program (`exec`): the same process id, in the same terminal, with the
//! same settings. Agents run in Herdr Core, not here, so they keep running; open event streams reconnect.
//!
//! A new program that fails to start puts the previous one back and starts it (`failed_start`). A watcher started
//! from the previous program does the same when the new one ends or hangs before it serves (`cli_watch`). The
//! journal is put back from the backup only when the new program had changed its layout.
//!
//! Herdr Core and its helper on project servers are Herdr's to update: `core` and `machine` run `hc update` and
//! `hc machine update NAME` and pass on what they said.

use crate::{
    Workspace, history,
    skillshare::{Ran, Trouble, run_program},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Multipart},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    env, fs,
    io::Write,
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Mutex, OnceLock},
    time::Duration,
};

/// This server's version. A release build takes it from `Cargo.toml`; a check build may be given another.
pub(crate) const VERSION: &str = match option_env!("SWARMHUB_BRIDGE_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};
/// The level of the API this server serves. It goes up by one whenever an app would have to know that something
/// was added or changed. Level 1 is the first published server: it says what it is, can update itself, and holds
/// the bots an app registers (`bots`). Level 2 adds the whole skillshare library: its five kinds, previews, installing
/// after an audit, updating and removing, its Git repository, and project libraries (`skillshare`).
/// Level 3 adds scoped Codex steering, detached activity and routine transfers.
pub(crate) const API: u32 = 3;
/// The oldest app level this server still serves. It goes up only when something an older app relies on is removed.
pub(crate) const API_MIN: u32 = 1;
/// The release key (Ed25519, base64): the Mac app's `SUPublicEDKey`. A check build may be given a throwaway one.
const RELEASE_KEY: &str = match option_env!("SWARMHUB_UPDATE_PUBLIC_KEY") {
    Some(key) => key,
    None => "uqOCQdP4qfiw0rOKsjX65T+AaH7LKkTswhjeU22eju4=",
};
/// Check builds only: `start` fails every start of the server, `hang` never finishes one.
const FAULT: Option<&str> = option_env!("SWARMHUB_BRIDGE_TEST_FAULT");
/// Where the newest manifest and its signature are published.
const FEED: &str = "https://github.com/conrader/swarmhub/releases/latest/download/";
/// The only place a manifest from `FEED` may send the server for the program itself.
const ASSETS: &str = "https://github.com/conrader/swarmhub/releases/download/";
const MANIFEST: &str = "workspace-manifest.json";
const MAX_MANIFEST: usize = 64 * 1024;
const MAX_PROGRAM: u64 = 512 * 1024 * 1024;
/// How long a new program has to start serving before the watcher puts the previous one back.
const TRIAL_SECONDS: u64 = 90;
const BACKUPS_KEPT: usize = 3;

/// The machine type a program file is built for, as manifests name it: `x86_64-linux`, `aarch64-macos`.
pub(crate) fn target() -> String {
    format!("{}-{}", env::consts::ARCH, env::consts::OS)
}

pub(crate) fn info() -> Value {
    json!({"version": VERSION, "api": API, "api_min": API_MIN, "target": target(), "updates": true,
           "unsupported": crate::platform::unsupported()})
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/update", get(status))
        .route("/api/update/check", post(check))
        .route("/api/update/apply", post(apply))
        .route(
            "/api/update/upload",
            post(upload).layer(DefaultBodyLimit::max(MAX_PROGRAM as usize + MAX_MANIFEST)),
        )
        .route("/api/update/rollback", post(rollback))
        .route("/api/update/core", post(core_update))
        .route("/api/update/machine", post(machine_update))
}

/// Why a request ends without an update, with a word (`kind`) an app can act on.
#[derive(Debug)]
struct Stop {
    status: StatusCode,
    kind: &'static str,
    message: String,
}

impl Stop {
    fn new(status: StatusCode, kind: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            kind,
            message: message.into(),
        }
    }

    fn broken(message: impl Into<String>) -> Self {
        Self::new(StatusCode::INTERNAL_SERVER_ERROR, "failed", message)
    }
}

impl IntoResponse for Stop {
    fn into_response(self) -> Response {
        (
            self.status,
            Json(json!({"error": self.message, "kind": self.kind})),
        )
            .into_response()
    }
}

// MARK: Versions

fn parse(version: &str) -> Option<[u64; 3]> {
    let mut parts = version.split('.');
    let mut numbers = [0; 3];
    for number in &mut numbers {
        let part = parts.next()?;
        if part.is_empty() || part.len() > 9 || !part.bytes().all(|byte| byte.is_ascii_digit()) {
            return None;
        }
        *number = part.parse().ok()?;
    }
    parts.next().is_none().then_some(numbers)
}

/// Only a release that is strictly newer is ever installed, so an old signed release cannot be replayed.
fn newer(candidate: &str, than: &str) -> bool {
    matches!((parse(candidate), parse(than)), (Some(candidate), Some(than)) if candidate > than)
}

// MARK: The manifest

#[derive(Clone, Debug, Deserialize)]
struct Manifest {
    product: String,
    version: String,
    api: u32,
    api_min: u32,
    #[serde(default)]
    released: String,
    #[serde(default)]
    notes: String,
    /// The folder of the release the program files are in; it must be under `ASSETS`.
    #[serde(default)]
    base: String,
    assets: Vec<Asset>,
}

#[derive(Clone, Debug, Deserialize)]
struct Asset {
    target: String,
    name: String,
    size: u64,
    sha256: String,
}

impl Manifest {
    fn asset(&self) -> Option<&Asset> {
        let target = target();
        self.assets.iter().find(|asset| asset.target == target)
    }

    fn view(&self) -> Value {
        json!({"version": self.version, "api": self.api, "api_min": self.api_min, "released": self.released,
               "notes": self.notes, "installable": self.asset().is_some()})
    }
}

/// The manifest, once its signature over exactly these bytes is the release key's and its contents are sane.
fn verified(manifest: &[u8], signature: &str, key: &str) -> Result<Manifest, Stop> {
    let unsigned = || {
        Stop::new(
            StatusCode::BAD_GATEWAY,
            "signature",
            "The update is not signed with the SwarmHub release key, so it was not installed.",
        )
    };
    let decode = |text: &str| base64::engine::general_purpose::STANDARD.decode(text.trim());
    let key = decode(key).map_err(|_| unsigned())?;
    let signature = decode(signature).map_err(|_| unsigned())?;
    ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key)
        .verify(manifest, &signature)
        .map_err(|_| unsigned())?;
    let unreadable = || {
        Stop::new(
            StatusCode::BAD_GATEWAY,
            "manifest",
            "The update's description could not be read, so it was not installed.",
        )
    };
    let manifest: Manifest = serde_json::from_slice(manifest).map_err(|_| unreadable())?;
    let sane = manifest.product == "swarmhub-herdr"
        && parse(&manifest.version).is_some()
        && manifest.api >= manifest.api_min
        && manifest.assets.iter().all(|asset| {
            !asset.name.is_empty()
                && asset.name.len() <= 128
                && !asset.name.starts_with('.')
                && asset
                    .name
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
                && (1..=MAX_PROGRAM).contains(&asset.size)
                && asset.sha256.len() == 64
                && asset.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        });
    if sane {
        Ok(manifest)
    } else {
        Err(unreadable())
    }
}

// MARK: The feed

struct Feed {
    base: String,
    /// Set by whoever starts the server (`SWARMHUB_UPDATE_FEED`): a mirror, or a check's local folder. The program
    /// file is then read from the same place. The signature is checked all the same.
    mirror: bool,
}

fn feed() -> Result<Feed, Stop> {
    feed_from(env::var("SWARMHUB_UPDATE_FEED").ok().as_deref())
}

fn feed_from(setting: Option<&str>) -> Result<Feed, Stop> {
    let Some(setting) = setting.filter(|value| !value.is_empty()) else {
        return Ok(Feed {
            base: FEED.into(),
            mirror: false,
        });
    };
    let local = ["http://127.0.0.1:", "http://localhost:"]
        .iter()
        .any(|prefix| setting.starts_with(prefix));
    if !(local || setting.starts_with("https://")) || setting.contains(['?', '#', '@', ' ']) {
        return Err(Stop::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "feed",
            "SWARMHUB_UPDATE_FEED must be an https address, or http on 127.0.0.1.",
        ));
    }
    Ok(Feed {
        base: format!("{}/", setting.trim_end_matches('/')),
        mirror: true,
    })
}

fn program_address(feed: &Feed, manifest: &Manifest, asset: &Asset) -> Result<String, Stop> {
    if feed.mirror {
        return Ok(format!("{}{}", feed.base, asset.name));
    }
    if manifest.base.starts_with(ASSETS)
        && manifest.base.ends_with('/')
        && !manifest.base.contains("..")
    {
        return Ok(format!("{}{}", manifest.base, asset.name));
    }
    Err(Stop::new(
        StatusCode::BAD_GATEWAY,
        "manifest",
        "The update points somewhere other than the SwarmHub releases, so it was not installed.",
    ))
}

fn unreachable(what: &str) -> Stop {
    Stop::new(
        StatusCode::BAD_GATEWAY,
        "feed_unreachable",
        format!("This server could not download {what} from the SwarmHub releases."),
    )
}

fn client(address: &str) -> Result<reqwest::Client, Stop> {
    let mut builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(20))
        .timeout(Duration::from_secs(900));
    if address.starts_with("http://") {
        builder = builder.no_proxy();
    }
    builder
        .build()
        .map_err(|_| Stop::broken("The server could not prepare the download."))
}

async fn fetch(address: &str, limit: usize, what: &str) -> Result<Vec<u8>, Stop> {
    let mut response = client(address)?
        .get(address)
        .send()
        .await
        .ok()
        .filter(|response| response.status().is_success())
        .ok_or_else(|| unreachable(what))?;
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| unreachable(what))? {
        if body.len() + chunk.len() > limit {
            return Err(unreachable(what));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

async fn latest(feed: &Feed) -> Result<Manifest, Stop> {
    let address = format!("{}{MANIFEST}", feed.base);
    let manifest = fetch(&address, MAX_MANIFEST, "the update's description").await?;
    let signature = fetch(&format!("{address}.sig"), 1024, "the update's signature").await?;
    verified(&manifest, &String::from_utf8_lossy(&signature), RELEASE_KEY)
}

/// A program file being written beside the running one, with its size and digest as they arrive.
struct Staging {
    file: fs::File,
    path: PathBuf,
    size: u64,
    digest: Sha256,
}

impl Staging {
    fn begin(path: &Path) -> Result<Self, Stop> {
        let _ = fs::remove_file(path);
        let file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o700)
            .open(path)
            .map_err(|_| not_writable(path))?;
        Ok(Self {
            file,
            path: path.into(),
            size: 0,
            digest: Sha256::new(),
        })
    }

    fn add(&mut self, bytes: &[u8], asset: &Asset) -> Result<(), Stop> {
        self.size += bytes.len() as u64;
        if self.size > asset.size {
            return Err(mismatch());
        }
        self.digest.update(bytes);
        self.file
            .write_all(bytes)
            .map_err(|_| not_writable(&self.path))
    }

    fn finish(self, asset: &Asset) -> Result<(), Stop> {
        let digest: String = self
            .digest
            .finalize()
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        if self.size != asset.size || !digest.eq_ignore_ascii_case(&asset.sha256) {
            return Err(mismatch());
        }
        self.file.sync_all().map_err(|_| not_writable(&self.path))
    }
}

fn mismatch() -> Stop {
    Stop::new(
        StatusCode::BAD_GATEWAY,
        "digest",
        "The downloaded program is not the one the signed release describes, so it was not installed.",
    )
}

fn not_writable(path: &Path) -> Stop {
    Stop::new(
        StatusCode::CONFLICT,
        "not_writable",
        format!(
            "The workspace cannot write to {}. Update it the way it was installed there.",
            path.parent().unwrap_or(path).display()
        ),
    )
}

// MARK: Where things are

static EXE: OnceLock<Option<PathBuf>> = OnceLock::new();

/// Called as the server starts: remembers the program file this process runs, which a later rename would hide.
pub(crate) fn init() -> Result<(), Box<dyn std::error::Error>> {
    EXE.get_or_init(|| {
        env::current_exe()
            .ok()
            .and_then(|path| path.canonicalize().ok())
    });
    match FAULT {
        Some("start") => Err("This check build never starts.".into()),
        Some("hang") => loop {
            std::thread::sleep(Duration::from_secs(3600));
        },
        _ => Ok(()),
    }
}

fn exe() -> Result<PathBuf, Stop> {
    EXE.get()
        .cloned()
        .flatten()
        .ok_or_else(|| Stop::broken("The workspace does not know which program file it runs."))
}

fn beside(exe: &Path, suffix: &str) -> PathBuf {
    let mut name = exe.file_name().unwrap_or_default().to_os_string();
    name.push(suffix);
    exe.with_file_name(name)
}

fn data() -> Option<PathBuf> {
    history::private_directory().ok()
}

fn journal_layout(file: &Path) -> Option<i64> {
    rusqlite::Connection::open_with_flags(file, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
        .ok()?
        .query_row("PRAGMA user_version", [], |row| row.get(0))
        .ok()
}

// MARK: The record of the last update

#[derive(Clone, Debug, Deserialize, Serialize)]
struct Record {
    /// `trial` while the new program has not served yet, then `done`, `rolled_back` or `failed`.
    state: String,
    from: String,
    to: String,
    at_ms: i64,
    exe: PathBuf,
    previous: PathBuf,
    backup: Option<PathBuf>,
    journal: PathBuf,
    journal_layout: i64,
    pid: u32,
    error: Option<String>,
}

impl Record {
    fn file(data: &Path) -> PathBuf {
        data.join("update.json")
    }

    fn load() -> Option<Self> {
        Self::load_from(&data()?)
    }

    fn load_from(data: &Path) -> Option<Self> {
        serde_json::from_slice(&fs::read(Self::file(data)).ok()?).ok()
    }

    fn save(&self) -> std::io::Result<()> {
        let data = self.journal.parent().unwrap_or(Path::new("."));
        let draft = data.join("update.json.new");
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&draft)?;
        file.write_all(&serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?)?;
        file.sync_all()?;
        fs::rename(draft, Self::file(data))
    }

    fn view(&self) -> Value {
        json!({"state": self.state, "from": self.from, "to": self.to, "at_ms": self.at_ms, "error": self.error,
               "backup": self.backup})
    }
}

// MARK: Replacing the program

/// Copies the journal as it is now, for a new program's migrations to be tried on and to go back to.
fn back_up(journal: &Path, to: &str) -> Result<PathBuf, Stop> {
    fn failed<E>(_: E) -> Stop {
        Stop::broken("The journal could not be backed up, so nothing was changed.")
    }
    let folder = journal.parent().unwrap_or(Path::new(".")).join("backups");
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&folder)
        .map_err(failed)?;
    let copy = folder.join(format!("workspace-before-{to}-{}.sqlite3", history::now()));
    let db = history::connection(journal).map_err(failed)?;
    db.execute("VACUUM INTO ?1", [copy.to_string_lossy()])
        .map_err(failed)?;
    fs::set_permissions(&copy, fs::Permissions::from_mode(0o600)).map_err(failed)?;
    let mut copies: Vec<_> = fs::read_dir(&folder)
        .map_err(failed)?
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("workspace-before-"))
        })
        .collect();
    copies.sort_by_key(|path| fs::metadata(path).and_then(|file| file.modified()).ok());
    for old in copies.iter().rev().skip(BACKUPS_KEPT) {
        let _ = fs::remove_file(old);
    }
    Ok(copy)
}

fn said(ran: &Result<Ran, Trouble>) -> String {
    match ran {
        Ok(ran) => ran
            .out
            .lines()
            .chain(ran.err.lines())
            .map(str::trim)
            .rfind(|line| !line.is_empty())
            .unwrap_or("it ended without saying why")
            .chars()
            .take(300)
            .collect(),
        Err(Trouble::Start) => "it could not be started on this machine".into(),
        Err(Trouble::Slow(limit)) => format!("it did not finish in {} seconds", limit.as_secs()),
        Err(Trouble::Flood) => "it printed more than the workspace reads".into(),
    }
}

/// Tries the staged program, backs the journal up, keeps the running program as `.previous` and puts the staged one
/// in its place. Until the last rename nothing the running server uses has changed.
fn swap(exe: &Path, staged: &Path, journal: &Path, to: &str) -> Result<Record, Stop> {
    let refused = |why: String| {
        Stop::new(
            StatusCode::BAD_GATEWAY,
            "does_not_run",
            format!("The new version does not run on this server ({why}), so nothing was changed."),
        )
    };
    fs::set_permissions(staged, fs::Permissions::from_mode(0o755))
        .map_err(|_| not_writable(staged))?;
    let words = |words: &[&str]| {
        words
            .iter()
            .map(|word| word.to_string())
            .collect::<Vec<_>>()
    };
    let ran = run_program(
        staged,
        &words(&["version", "--json"]),
        &[],
        Duration::from_secs(30),
    );
    let reported = ran
        .as_ref()
        .ok()
        .filter(|ran| ran.ok)
        .and_then(|ran| serde_json::from_str::<Value>(&ran.out).ok())
        .and_then(|value| value["version"].as_str().map(str::to_owned));
    if reported.as_deref() != Some(to) {
        return Err(refused(match reported {
            Some(other) => format!("it says it is {other}"),
            None => said(&ran),
        }));
    }
    let layout = journal_layout(journal).unwrap_or(0);
    let backup = back_up(journal, to)?;
    let data = journal.parent().unwrap_or(Path::new("."));
    let trial = tempfile::Builder::new()
        .prefix("update-trial-")
        .tempdir_in(data)
        .map_err(|_| {
            Stop::broken("The journal's copy could not be made, so nothing was changed.")
        })?;
    // The server only opens a journal in a folder no one else can read.
    fs::set_permissions(trial.path(), fs::Permissions::from_mode(0o700))
        .and_then(|_| fs::copy(&backup, trial.path().join("workspace.sqlite3")))
        .map_err(|_| {
            Stop::broken("The journal's copy could not be made, so nothing was changed.")
        })?;
    let ran = run_program(
        staged,
        &words(&["update-probe", &trial.path().to_string_lossy()]),
        &[],
        Duration::from_secs(180),
    );
    if !ran.as_ref().is_ok_and(|ran| ran.ok) {
        return Err(refused(format!(
            "opening a copy of the journal failed: {}",
            said(&ran)
        )));
    }
    let previous = beside(exe, ".previous");
    let draft = beside(exe, ".previous.new");
    fs::copy(exe, &draft)
        .and_then(|_| fs::rename(&draft, &previous))
        .map_err(|_| not_writable(exe))?;
    let mut record = Record {
        state: "trial".into(),
        from: VERSION.into(),
        to: to.into(),
        at_ms: history::now(),
        exe: exe.into(),
        previous: previous.clone(),
        backup: Some(backup),
        journal: journal.into(),
        journal_layout: layout,
        pid: std::process::id(),
        error: None,
    };
    record
        .save()
        .map_err(|_| Stop::broken("The update could not be recorded, so nothing was changed."))?;
    if fs::rename(staged, exe).is_err() {
        record.state = "failed".into();
        record.error = Some("The new program could not be put in place.".into());
        let _ = record.save();
        return Err(not_writable(exe));
    }
    // The watcher detaches itself at once (`cli_watch`), so this wait is short and leaves no child behind.
    if let Ok(mut watcher) = Command::new(&previous)
        .arg("update-watch")
        .arg(record.pid.to_string())
        .arg(TRIAL_SECONDS.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        let _ = watcher.wait();
    }
    Ok(record)
}

/// Puts the previous program back under the server's name, and the journal's backup when the new program had
/// changed the journal's layout (the previous one cannot read a newer layout). The changed journal is kept beside it.
fn undo(record: &mut Record, why: &str) -> std::io::Result<()> {
    if let Some(backup) = record.backup.as_ref().filter(|backup| backup.exists())
        && journal_layout(&record.journal) != Some(record.journal_layout)
    {
        let aside = beside(&record.journal, &format!(".failed-{}", record.to));
        fs::rename(&record.journal, aside)?;
        for suffix in ["-wal", "-shm"] {
            let _ = fs::remove_file(beside(&record.journal, suffix));
        }
        fs::copy(backup, &record.journal)?;
        fs::set_permissions(&record.journal, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(&record.previous, &record.exe)?;
    record.state = "rolled_back".into();
    record.error = Some(why.chars().take(500).collect());
    record.save()
}

/// Called when the server is about to serve: a new program on trial has started.
pub(crate) fn started() {
    if let Some(mut record) = Record::load()
        && record.state == "trial"
        && record.to == VERSION
    {
        record.state = "done".into();
        let _ = record.save();
    }
}

/// Called when the server could not start. If this process is a new program on trial, the previous program is put
/// back and takes this process over; otherwise nothing happens and the error is the caller's to report.
pub(crate) fn failed_start(error: &str) {
    let Some(mut record) = Record::load() else {
        return;
    };
    if record.state != "trial" || record.to != VERSION || record.pid != std::process::id() {
        return;
    }
    eprintln!(
        "SwarmHub {VERSION} could not start ({error}). Going back to {}.",
        record.from
    );
    if undo(&mut record, error).is_ok() {
        let error = Command::new(&record.exe).exec();
        eprintln!("The previous version could not be started: {error}");
    }
}

/// Becomes the program now under the server's name. Returns only when that failed.
fn restart(mut record: Record) {
    let error = Command::new(&record.exe).exec();
    eprintln!("The new version could not be started: {error}");
    let _ = undo(
        &mut record,
        &format!("The new version could not be started: {error}"),
    );
}

// MARK: Routes

static RUNNING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
static APP: Mutex<Option<(String, Option<u32>)>> = Mutex::new(None);

fn busy() -> Stop {
    Stop::new(
        StatusCode::CONFLICT,
        "busy",
        "An update of this workspace is already running.",
    )
}

/// Remembers the app that last asked (`X-SwarmHub-App: 0.7.0 (34)`, `X-SwarmHub-Api: 1`), for `status`.
pub(crate) fn seen(headers: &HeaderMap) {
    let Some(app) = headers
        .get("x-swarmhub-app")
        .and_then(|value| value.to_str().ok())
    else {
        return;
    };
    let app: String = app
        .chars()
        .filter(|character| character.is_ascii_alphanumeric() || " .()-".contains(*character))
        .take(40)
        .collect();
    let level = headers
        .get("x-swarmhub-api")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.parse().ok());
    if let Ok(mut last) = APP.lock() {
        *last = Some((app, level));
    }
}

async fn status() -> Json<Value> {
    let exe = exe().ok();
    let writable = exe
        .as_deref()
        .and_then(Path::parent)
        .is_some_and(|folder| tempfile::NamedTempFile::new_in(folder).is_ok());
    let app = APP.lock().ok().and_then(|last| last.clone());
    Json(json!({
        "bridge": info(),
        "pid": std::process::id(),
        "can_update": writable,
        "previous": exe.as_deref().is_some_and(|exe| beside(exe, ".previous").exists()),
        "last": Record::load().map(|record| record.view()),
        "app": app.map(|(version, api)| json!({"version": version, "api": api})),
    }))
}

async fn check() -> Response {
    let found = async { latest(&feed()?).await }.await;
    match found {
        Ok(manifest) => Json(
            json!({"current": VERSION, "available": newer(&manifest.version, VERSION),
                                    "latest": manifest.view()}),
        )
        .into_response(),
        Err(stop) => stop.into_response(),
    }
}

#[derive(Deserialize)]
struct Want {
    /// The version the person was shown. A release that changed since is not installed in its place.
    version: Option<String>,
}

fn wanted<'a>(manifest: &'a Manifest, want: Option<&str>) -> Result<Option<&'a Asset>, Stop> {
    if !newer(&manifest.version, VERSION) {
        return Ok(None);
    }
    if want.is_some_and(|want| want != manifest.version) {
        return Err(Stop::new(
            StatusCode::CONFLICT,
            "changed",
            format!(
                "The newest release is now {}. Check again.",
                manifest.version
            ),
        ));
    }
    manifest.asset().map(Some).ok_or_else(|| {
        Stop::new(
            StatusCode::CONFLICT,
            "no_build",
            format!(
                "Release {} has no program for this kind of machine ({}).",
                manifest.version,
                target()
            ),
        )
    })
}

fn current() -> Response {
    Json(json!({"state": "current", "version": VERSION})).into_response()
}

async fn apply(
    axum::extract::State(w): axum::extract::State<Workspace>,
    Json(want): Json<Want>,
) -> Response {
    let Ok(_turn) = RUNNING.try_lock() else {
        return busy().into_response();
    };
    let staged = async {
        let exe = exe()?;
        let feed = feed()?;
        let manifest = latest(&feed).await?;
        let Some(asset) = wanted(&manifest, want.version.as_deref())? else {
            return Ok(None);
        };
        let address = program_address(&feed, &manifest, asset)?;
        let path = beside(&exe, ".staged");
        let mut staging = Staging::begin(&path)?;
        let mut response = client(&address)?
            .get(&address)
            .send()
            .await
            .ok()
            .filter(|response| response.status().is_success())
            .ok_or_else(|| unreachable("the new program"))?;
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| unreachable("the new program"))?
        {
            staging.add(&chunk, asset)?;
        }
        staging.finish(asset)?;
        Ok(Some((exe, path, manifest.version)))
    }
    .await;
    finish(&w, staged).await
}

/// The same update handed over by an app: `manifest`, `signature`, then `program`, in that order.
async fn upload(
    axum::extract::State(w): axum::extract::State<Workspace>,
    mut form: Multipart,
) -> Response {
    let Ok(_turn) = RUNNING.try_lock() else {
        return busy().into_response();
    };
    let staged = receive(&mut form).await;
    if !matches!(staged, Ok(Some(_))) {
        // Read what is still on its way, so the app gets the refusal instead of a broken connection.
        while let Ok(Some(mut rest)) = form.next_field().await {
            while let Ok(Some(_)) = rest.chunk().await {}
        }
    }
    finish(&w, staged).await
}

async fn receive(form: &mut Multipart) -> Result<Option<(PathBuf, PathBuf, String)>, Stop> {
    let malformed = || {
        Stop::new(
            StatusCode::BAD_REQUEST,
            "malformed",
            "Send the manifest, its signature and the program, in that order.",
        )
    };
    let exe = exe()?;
    let mut manifest = None;
    let mut signature = None;
    while let Some(mut field) = form.next_field().await.map_err(|_| malformed())? {
        let name = field.name().map(str::to_owned);
        match name.as_deref() {
            Some("manifest") => {
                let bytes = field.bytes().await.map_err(|_| malformed())?;
                if bytes.len() > MAX_MANIFEST {
                    return Err(malformed());
                }
                manifest = Some(bytes);
            }
            Some("signature") => signature = Some(field.text().await.map_err(|_| malformed())?),
            Some("program") => {
                let (Some(manifest), Some(signature)) = (&manifest, &signature) else {
                    return Err(malformed());
                };
                let manifest = verified(manifest, signature, RELEASE_KEY)?;
                let Some(asset) = wanted(&manifest, None)? else {
                    return Ok(None);
                };
                let path = beside(&exe, ".staged");
                let mut staging = Staging::begin(&path)?;
                while let Some(chunk) = field.chunk().await.map_err(|_| malformed())? {
                    staging.add(&chunk, asset)?;
                }
                staging.finish(asset)?;
                return Ok(Some((exe, path, manifest.version)));
            }
            _ => return Err(malformed()),
        }
    }
    Err(malformed())
}

async fn finish(
    w: &Workspace,
    staged: Result<Option<(PathBuf, PathBuf, String)>, Stop>,
) -> Response {
    let (exe, path, to) = match staged {
        Ok(Some(staged)) => staged,
        Ok(None) => return current(),
        Err(stop) => {
            if let Ok(exe) = exe() {
                let _ = fs::remove_file(beside(&exe, ".staged"));
            }
            return stop.into_response();
        }
    };
    let journal = w.history.file().to_path_buf();
    let swapped = tokio::task::spawn_blocking(move || {
        let swapped = swap(&exe, &path, &journal, &to);
        let _ = fs::remove_file(&path);
        swapped
    })
    .await;
    match swapped {
        Ok(Ok(record)) => {
            let answer = Json(json!({"state": "restarting", "from": record.from, "to": record.to}));
            // After the answer has gone out, this process becomes the new program.
            tokio::spawn(async move {
                tokio::time::sleep(Duration::from_millis(600)).await;
                restart(record);
            });
            answer.into_response()
        }
        Ok(Err(stop)) => stop.into_response(),
        Err(_) => {
            Stop::broken("The update stopped unexpectedly. Nothing was changed.").into_response()
        }
    }
}

/// Goes back to the program the last update replaced, while the journal still has the layout it knew.
async fn rollback() -> Response {
    let Ok(_turn) = RUNNING.try_lock() else {
        return busy().into_response();
    };
    let nothing = || {
        Stop::new(
            StatusCode::CONFLICT,
            "no_previous",
            "There is no previous version to go back to.",
        )
    };
    let Some(mut record) = Record::load().filter(|record| record.previous.exists()) else {
        return nothing().into_response();
    };
    if Some(record.exe.clone()) != exe().ok() || record.state != "done" {
        return nothing().into_response();
    }
    if journal_layout(&record.journal) != Some(record.journal_layout) {
        return Stop::new(
            StatusCode::CONFLICT,
            "journal_changed",
            format!(
                "Version {} changed the journal, and {} cannot read it. To go back, stop the workspace and restore the backup {} by hand; what was saved since the update is not in it.",
                record.to,
                record.from,
                record.backup.as_deref().map(|path| path.display().to_string()).unwrap_or_default()
            ),
        )
        .into_response();
    }
    let (from, to) = (record.to.clone(), record.from.clone());
    if undo(&mut record, "Rolled back on request.").is_err() {
        return Stop::broken("The previous version could not be put back.").into_response();
    }
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(600)).await;
        let error = Command::new(&record.exe).exec();
        eprintln!("The previous version could not be started: {error}");
    });
    Json(json!({"state": "restarting", "from": from, "to": to})).into_response()
}

async fn core_update() -> Response {
    hc(&["update", "--json"]).await
}

#[derive(Deserialize)]
struct Machine {
    name: String,
}

async fn machine_update(Json(machine): Json<Machine>) -> Response {
    let name = machine.name;
    let plain = !name.is_empty()
        && name.len() <= 64
        && !name.starts_with('-')
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte));
    if !plain {
        return Stop::new(StatusCode::BAD_REQUEST, "malformed", "Name one machine.")
            .into_response();
    }
    hc(&["machine", "update", &name, "--json"]).await
}

/// Runs Herdr's own updater and passes on what it said. Core restarts itself; its terminals keep running.
async fn hc(arguments: &[&str]) -> Response {
    let _turn = RUNNING.lock().await;
    let arguments: Vec<String> = arguments.iter().map(|word| word.to_string()).collect();
    let ran = tokio::task::spawn_blocking(move || {
        let program = crate::machines::hc().map_err(|_| Trouble::Start)?;
        run_program(&program, &arguments, &[], Duration::from_secs(600))
    })
    .await
    .unwrap_or(Err(Trouble::Start));
    match &ran {
        Ok(done) if done.ok => Json(json!({"ok": true,
            "result": serde_json::from_str::<Value>(&done.out).unwrap_or(Value::Null)}))
        .into_response(),
        _ => Stop::new(
            StatusCode::BAD_GATEWAY,
            "hc_failed",
            format!("Herdr's own update did not finish: {}.", said(&ran)),
        )
        .into_response(),
    }
}

// MARK: Commands

type Done = Result<(), Box<dyn std::error::Error>>;

/// `swarmhub-herdr version [--json]`
pub(crate) fn cli_version() -> Done {
    if env::args().nth(2).as_deref() == Some("--json") {
        println!("{}", info());
    } else {
        println!(
            "swarmhub-herdr {VERSION} (workspace API {API}, {})",
            target()
        );
    }
    Ok(())
}

/// `swarmhub-herdr update-probe FOLDER`: opens the journal copy in FOLDER as the server would, migrations included.
pub(crate) fn cli_probe() -> Done {
    let folder = env::args_os()
        .nth(2)
        .ok_or("Usage: swarmhub-herdr update-probe FOLDER")?;
    let journal = history::History::open_at(Path::new(&folder))?;
    println!(
        "{}",
        json!({"version": VERSION, "journal_layout": journal_layout(journal.file())})
    );
    Ok(())
}

/// `swarmhub-herdr update-watch PID SECONDS`, run from the previous program as an update swaps it out. While the
/// record says `trial` it waits; if the new program ends, or has not served when the time is up, it puts the
/// previous program back and starts it with the settings the server had.
pub(crate) fn cli_watch() -> Done {
    let usage = "Usage: swarmhub-herdr update-watch PID SECONDS";
    let pid: i32 = env::args()
        .nth(2)
        .and_then(|pid| pid.parse().ok())
        .ok_or(usage)?;
    let seconds: u64 = env::args()
        .nth(3)
        .and_then(|time| time.parse().ok())
        .ok_or(usage)?;
    if crate::platform::detach().is_err() {
        return Err("The watcher could not detach.".into());
    }
    // SAFETY: signal 0 only asks whether the process is there.
    let alive = || unsafe { libc::kill(pid, 0) } == 0;
    let mut waited = 0;
    let why = loop {
        std::thread::sleep(Duration::from_secs(1));
        waited += 1;
        match Record::load() {
            Some(record) if record.state == "trial" && record.pid == pid as u32 => {}
            _ => return Ok(()),
        }
        if !alive() {
            break "The new version ended while it was starting.";
        }
        if waited >= seconds {
            break "The new version did not start serving in time.";
        }
    };
    let Some(mut record) = Record::load().filter(|record| record.state == "trial") else {
        return Ok(());
    };
    // A server that launchd keeps running is started by launchd, which would start the new program again the
    // moment it ended. So that one is only held still while the previous program is put back, and then launchd
    // is asked to end whatever it runs for the job and start the program that is back under the name.
    let supervisor = crate::service::supervised();
    if alive() {
        // SAFETY: the process is the server this watcher was started for.
        unsafe {
            libc::kill(
                pid,
                if supervisor.is_some() {
                    libc::SIGSTOP
                } else {
                    libc::SIGKILL
                },
            )
        };
        for _ in 0..50 {
            if supervisor.is_some() || !alive() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    undo(&mut record, why)?;
    if let Some(label) = supervisor {
        return if crate::service::restart_job(&label) {
            Ok(())
        } else {
            Err("launchd did not restart the previous version.".into())
        };
    }
    let log = |name: &str| {
        fs::OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(record.journal.with_file_name(name))
            .map(Stdio::from)
            .unwrap_or_else(|_| Stdio::null())
    };
    Command::new(&record.exe)
        .stdin(Stdio::null())
        .stdout(log("update-restart.log"))
        .stderr(log("update-restart.log"))
        .process_group(0)
        .spawn()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    fn encode(bytes: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(bytes)
    }

    fn pair() -> Ed25519KeyPair {
        let document = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();
        Ed25519KeyPair::from_pkcs8(document.as_ref()).unwrap()
    }

    fn manifest(version: &str, name: &str) -> Vec<u8> {
        json!({"product": "swarmhub-herdr", "version": version, "api": 2, "api_min": 1,
               "base": format!("{ASSETS}v9.9.9/"),
               "assets": [{"target": target(), "name": name, "size": 3, "sha256": "ab".repeat(32)}]})
        .to_string()
        .into_bytes()
    }

    #[test]
    fn versions_compare_by_number_and_only_plain_ones_count() {
        assert!(newer("0.10.0", "0.9.9") && newer("1.0.0", "0.99.99") && newer("0.2.1", "0.2.0"));
        assert!(!newer("0.2.0", "0.2.0") && !newer("0.1.9", "0.2.0"));
        for odd in [
            "",
            "1",
            "1.2",
            "1.2.3.4",
            "v1.2.3",
            "1.2.3-beta",
            "1..3",
            "1.2.x",
            "1.2.9999999999",
        ] {
            assert!(!newer(odd, "0.0.1") && !newer("9.9.9", odd), "{odd}");
        }
    }

    #[test]
    fn a_manifest_counts_only_with_the_release_keys_signature_over_its_exact_bytes() {
        let (signer, other) = (pair(), pair());
        let key = encode(signer.public_key().as_ref());
        let body = manifest("9.9.9", "swarmhub-herdr-9.9.9-x");
        let signature = encode(signer.sign(&body).as_ref());
        let read = verified(&body, &format!("{signature}\n"), &key).unwrap();
        assert_eq!(
            (read.version.as_str(), read.api, read.asset().unwrap().size),
            ("9.9.9", 2, 3)
        );
        let mut changed = body.clone();
        *changed.last_mut().unwrap() = b' ';
        assert_eq!(
            verified(&changed, &signature, &key).unwrap_err().kind,
            "signature"
        );
        let forged = encode(other.sign(&body).as_ref());
        assert_eq!(
            verified(&body, &forged, &key).unwrap_err().kind,
            "signature"
        );
        assert_eq!(verified(&body, "", &key).unwrap_err().kind, "signature");
        assert_eq!(
            verified(&body, &signature, "not a key").unwrap_err().kind,
            "signature"
        );
    }

    #[test]
    fn a_signed_manifest_that_names_odd_things_is_refused() {
        let signer = pair();
        let key = encode(signer.public_key().as_ref());
        let sign = |body: &[u8]| encode(signer.sign(body).as_ref());
        for name in ["../swarmhub-herdr", "a/b", ".hidden", "", "with space"] {
            let body = manifest("9.9.9", name);
            assert_eq!(
                verified(&body, &sign(&body), &key).unwrap_err().kind,
                "manifest",
                "{name}"
            );
        }
        let body = manifest("9.9", "ok");
        assert_eq!(
            verified(&body, &sign(&body), &key).unwrap_err().kind,
            "manifest"
        );
        let body = String::from_utf8(manifest("9.9.9", "ok"))
            .unwrap()
            .replace("swarmhub-herdr\"", "other\"");
        assert_eq!(
            verified(body.as_bytes(), &sign(body.as_bytes()), &key)
                .unwrap_err()
                .kind,
            "manifest"
        );
    }

    #[test]
    fn an_update_is_only_a_newer_release_with_a_program_for_this_machine() {
        let signer = pair();
        let key = encode(signer.public_key().as_ref());
        let read =
            |body: Vec<u8>| verified(&body, &encode(signer.sign(&body).as_ref()), &key).unwrap();
        assert!(
            wanted(&read(manifest(VERSION, "ok")), None)
                .unwrap()
                .is_none()
        );
        assert!(
            wanted(&read(manifest("0.0.1", "ok")), None)
                .unwrap()
                .is_none()
        );
        let next = read(manifest("999.0.0", "ok"));
        assert_eq!(wanted(&next, Some("999.0.0")).unwrap().unwrap().name, "ok");
        assert_eq!(wanted(&next, Some("998.0.0")).unwrap_err().kind, "changed");
        let mut elsewhere = next.clone();
        elsewhere.assets[0].target = "pdp11-unix".into();
        assert_eq!(wanted(&elsewhere, None).unwrap_err().kind, "no_build");
    }

    #[test]
    fn the_program_comes_from_the_releases_or_from_the_mirror_the_owner_set() {
        let signer = pair();
        let key = encode(signer.public_key().as_ref());
        let body = manifest("9.9.9", "prog");
        let mut read = verified(&body, &encode(signer.sign(&body).as_ref()), &key).unwrap();
        let asset = read.assets[0].clone();
        let own = feed_from(None).unwrap();
        assert_eq!(
            program_address(&own, &read, &asset).unwrap(),
            format!("{ASSETS}v9.9.9/prog")
        );
        for base in [
            "https://example.com/",
            "https://github.com/conrader/swarmhub/releases/download/../../x/",
            "",
        ] {
            read.base = base.into();
            assert_eq!(
                program_address(&own, &read, &asset).unwrap_err().kind,
                "manifest",
                "{base}"
            );
        }
        let mirror = feed_from(Some("http://127.0.0.1:9000/feed")).unwrap();
        assert_eq!(
            program_address(&mirror, &read, &asset).unwrap(),
            "http://127.0.0.1:9000/feed/prog"
        );
        assert!(feed_from(Some("https://mirror.example/x/")).is_ok());
        for odd in [
            "http://example.com/",
            "file:///tmp/x",
            "https://user@host/x",
            "ftp://x",
        ] {
            assert!(feed_from(Some(odd)).is_err(), "{odd}");
        }
    }

    #[test]
    fn a_staged_program_must_have_the_size_and_digest_the_manifest_gives() {
        let folder = tempfile::tempdir().unwrap();
        let path = folder.path().join("staged");
        let digest: String = Sha256::digest(b"abc")
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect();
        let asset = |size, sha256: &str| Asset {
            target: target(),
            name: "p".into(),
            size,
            sha256: sha256.into(),
        };
        let stage = |bytes: &[u8], asset: &Asset| {
            let mut staging = Staging::begin(&path)?;
            staging.add(bytes, asset)?;
            staging.finish(asset)
        };
        assert!(stage(b"abc", &asset(3, &digest)).is_ok());
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert_eq!(
            stage(b"abd", &asset(3, &digest)).unwrap_err().kind,
            "digest"
        );
        assert_eq!(
            stage(b"abcd", &asset(3, &digest)).unwrap_err().kind,
            "digest"
        );
        assert_eq!(stage(b"ab", &asset(3, &digest)).unwrap_err().kind, "digest");
    }

    fn journal(folder: &Path, layout: i64) -> PathBuf {
        let file = folder.join("workspace.sqlite3");
        let db = rusqlite::Connection::open(&file).unwrap();
        db.execute_batch(&format!("CREATE TABLE IF NOT EXISTS t (x); INSERT INTO t VALUES ({layout}); PRAGMA user_version={layout};"))
            .unwrap();
        file
    }

    fn record(folder: &Path, layout: i64) -> Record {
        let (exe, previous) = (
            folder.join("swarmhub-herdr"),
            folder.join("swarmhub-herdr.previous"),
        );
        fs::write(&exe, "new").unwrap();
        fs::write(&previous, "old").unwrap();
        Record {
            state: "trial".into(),
            from: "1.0.0".into(),
            to: "1.1.0".into(),
            at_ms: 0,
            exe,
            previous,
            backup: None,
            journal: journal(folder, layout),
            journal_layout: layout,
            pid: 1,
            error: None,
        }
    }

    #[test]
    fn going_back_restores_the_program_and_leaves_an_unchanged_journal_alone() {
        let folder = tempfile::tempdir().unwrap();
        let mut record = record(folder.path(), 4);
        record.backup = Some(back_up(&record.journal, "1.1.0").unwrap());
        rusqlite::Connection::open(&record.journal)
            .unwrap()
            .execute("INSERT INTO t VALUES (99)", [])
            .unwrap();
        undo(&mut record, "it failed").unwrap();
        assert_eq!(fs::read_to_string(&record.exe).unwrap(), "old");
        assert!(!record.previous.exists());
        let rows: i64 = rusqlite::Connection::open(&record.journal)
            .unwrap()
            .query_row("SELECT count(*) FROM t", [], |row| row.get(0))
            .unwrap();
        assert_eq!(rows, 2, "a row written after the backup is still there");
        let saved = Record::load_from(folder.path()).unwrap();
        assert_eq!(
            (saved.state.as_str(), saved.error.as_deref()),
            ("rolled_back", Some("it failed"))
        );
    }

    #[test]
    fn going_back_restores_the_journal_when_the_new_program_changed_its_layout() {
        let folder = tempfile::tempdir().unwrap();
        let mut record = record(folder.path(), 4);
        record.backup = Some(back_up(&record.journal, "1.1.0").unwrap());
        journal(folder.path(), 5);
        undo(&mut record, "it failed").unwrap();
        assert_eq!(journal_layout(&record.journal), Some(4));
        assert_eq!(
            journal_layout(&folder.path().join("workspace.sqlite3.failed-1.1.0")),
            Some(5)
        );
        assert_eq!(fs::read_to_string(&record.exe).unwrap(), "old");
    }

    #[test]
    fn only_the_newest_journal_backups_are_kept() {
        let folder = tempfile::tempdir().unwrap();
        let file = journal(folder.path(), 1);
        for round in 0..5 {
            back_up(&file, &format!("1.0.{round}")).unwrap();
            std::thread::sleep(Duration::from_millis(20));
        }
        let kept: Vec<_> = fs::read_dir(folder.path().join("backups"))
            .unwrap()
            .flatten()
            .map(|entry| entry.file_name().into_string().unwrap())
            .collect();
        assert_eq!(kept.len(), BACKUPS_KEPT, "{kept:?}");
        assert!(
            kept.iter().any(|name| name.contains("1.0.4"))
                && !kept.iter().any(|name| name.contains("1.0.0"))
        );
    }
}
