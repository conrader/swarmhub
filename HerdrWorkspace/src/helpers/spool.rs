//! The requests of `helpers.sock` as files, for an agent whose shell commands may not open a socket.
//!
//! Codex runs shell commands in a sandbox that refuses every connection but lets them write in the agent's working
//! folder. `swarmhub-herdr helper` then leaves its request as a file in `.swarmhub-helpers` in that folder, and the
//! workspace, which looks there a few times a second, answers with a file beside it.
//!
//! Every agent that works in the folder can read and write these files, so a request never holds the launch key.
//! It names the launch by a hash of the key and is signed with the key, and the workspace signs its answer the same
//! way. The workspace takes a request once, by renaming it; refuses one that is old; and remembers its random name,
//! so a copy cannot run again.

use super::{
    Action, Deferred, REPLY_LIMIT, REQUEST_LIMIT, Reply, Request, UNREGISTERED, explain, perform,
};
use crate::{Workspace, core::Terminal, history::now};
use rustix::fs::{AtFlags, Dir, Mode, OFlags, fstat, open, openat, renameat, unlinkat};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{self, DirBuilder, File, OpenOptions},
    io::{self, Read, Write},
    os::{
        fd::OwnedFd,
        unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt},
    },
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::sync::Semaphore;

pub(crate) const DIR: &str = ".swarmhub-helpers";
/// Set for every agent the workspace starts, so the command finds the folder from wherever it runs.
pub(crate) const ENV: &str = "SWARMHUB_HELPER_SPOOL";
/// How long a request may lie untaken before the command concludes that the workspace is not running.
pub(crate) const PICKUP: Duration = Duration::from_secs(5);
const FILE_LIMIT: u64 = (REPLY_LIMIT + 1024) as u64;
const WATCH: Duration = Duration::from_millis(250);
const POLL: Duration = Duration::from_millis(100);
/// How long the workspace waits for a command to read its answer before it gives up on a deferred start.
const COLLECT: Duration = Duration::from_secs(20);
/// The pause between the command reading its answer and the helper's launch, for the command to exit.
const SETTLE: Duration = Duration::from_millis(100);
const FRESH_MS: i64 = 60_000;
const STALE_SECONDS: i64 = 600;
const ENTRIES: usize = 256;

const DIRECTORY: OFlags = OFlags::RDONLY
    .union(OFlags::DIRECTORY)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);
const READ: OFlags = OFlags::RDONLY
    .union(OFlags::NONBLOCK)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);
const CREATE: OFlags = OFlags::WRONLY
    .union(OFlags::CREATE)
    .union(OFlags::EXCL)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);

const UNSIGNED: &str = "-";
const GARBLED: &str =
    "The workspace could not verify this helper command, so nothing was started or changed.";
const OLD: &str = "The workspace received this helper command too late to trust it, so nothing was started or changed. Run it again.";

/// The signed part of a request file.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Asked {
    nonce: String,
    at_ms: i64,
    action: Action,
}

/// Names a launch without giving its key away.
fn launch_id(key: &str) -> String {
    hex(&Sha256::digest(format!("swarmhub helper launch {key}")))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    (text.len().is_multiple_of(2) && text.bytes().all(|byte| byte.is_ascii_hexdigit())).then(|| {
        (0..text.len())
            .step_by(2)
            .filter_map(|at| u8::from_str_radix(&text[at..at + 2], 16).ok())
            .collect()
    })
}

fn valid_nonce(nonce: &str) -> bool {
    nonce.len() == 32
        && nonce
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// What is signed: the direction, the request's name and the body, so an answer cannot pass for a request or
/// for the answer to another request.
fn signing(key: &str, kind: &str, nonce: &str, body: &[u8]) -> (ring::hmac::Key, Vec<u8>) {
    let mut message = format!("{kind}\n{nonce}\n").into_bytes();
    message.extend_from_slice(body);
    (
        ring::hmac::Key::new(ring::hmac::HMAC_SHA256, key.as_bytes()),
        message,
    )
}

fn sign(key: &str, kind: &str, nonce: &str, body: &[u8]) -> String {
    let (key, message) = signing(key, kind, nonce, body);
    hex(ring::hmac::sign(&key, &message).as_ref())
}

fn signed(key: &str, kind: &str, nonce: &str, body: &[u8], mac: &str) -> bool {
    let (key, message) = signing(key, kind, nonce, body);
    unhex(mac).is_some_and(|mac| ring::hmac::verify(&key, &message, &mac).is_ok())
}

/// A file is two short lines, who and the signature, then the JSON body.
fn seal(who: &str, mac: &str, body: &[u8]) -> Vec<u8> {
    let mut bytes = format!("{who}\n{mac}\n").into_bytes();
    bytes.extend_from_slice(body);
    bytes
}

fn unseal(bytes: &[u8]) -> Option<(&str, &str, &[u8])> {
    let mut parts = bytes.splitn(3, |byte| *byte == b'\n');
    let who = std::str::from_utf8(parts.next()?).ok()?;
    let mac = std::str::from_utf8(parts.next()?).ok()?;
    Some((who, mac, parts.next()?))
}

// ---- The command's side. It runs inside the agent's sandbox, as the agent.

/// The helper folder for a command running in `cwd`: the one the workspace named at launch, or the one in this
/// folder or a folder above it, for an agent started before the workspace named it.
pub(crate) fn find(named: Option<PathBuf>, cwd: Option<&Path>) -> Option<PathBuf> {
    let named = named.filter(|path| path.is_absolute());
    let is_folder = |path: &PathBuf| fs::symlink_metadata(path).is_ok_and(|meta| meta.is_dir());
    named.filter(is_folder).or_else(|| {
        cwd?.ancestors()
            .take(12)
            .map(|folder| folder.join(DIR))
            .find(is_folder)
    })
}

/// Leaves `action` in `dir` and waits for the workspace's signed answer. `Err(None)` means the folder could not be
/// written, so nothing was asked.
pub(crate) fn ask(
    dir: &Path,
    key: &str,
    action: Action,
    pickup: Duration,
    patience: Duration,
) -> Result<Reply, Option<&'static str>> {
    let mut random = [0_u8; 16];
    ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut random)
        .map_err(|_| None)?;
    let nonce = hex(&random);
    let body = serde_json::to_vec(&Asked {
        nonce: nonce.clone(),
        at_ms: now(),
        action,
    })
    .map_err(|_| None)?;
    if body.len() > REQUEST_LIMIT {
        return Err(Some(super::cli::TOO_LONG));
    }
    let bytes = seal(&launch_id(key), &sign(key, "request", &nonce, &body), &body);
    let file = |ending: &str| dir.join(format!("{nonce}.{ending}"));
    // Written under another name first: the workspace must never read half a request.
    let written = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(file("new"))
        .and_then(|mut fresh| fresh.write_all(&bytes))
        .and_then(|()| fs::rename(file("new"), file("req")));
    if written.is_err() {
        let _ = fs::remove_file(file("new"));
        return Err(None);
    }
    let started = Instant::now();
    let mut taken = false;
    loop {
        if let Some(reply) = collect(&file("rep"), key, &nonce) {
            return Ok(reply);
        }
        if !taken && started.elapsed() >= pickup {
            // Taking the request back settles it: either it is gone for good, or the workspace has it.
            match fs::remove_file(file("req")) {
                Ok(()) => return Err(Some(super::cli::OFFLINE)),
                Err(error) if error.kind() == io::ErrorKind::NotFound => taken = true,
                Err(_) => return Err(Some(super::cli::SILENT)),
            }
        }
        if started.elapsed() >= patience {
            return Err(Some(super::cli::SILENT));
        }
        std::thread::sleep(POLL);
    }
}

/// The workspace's answer to `nonce`, once it is there and its signature holds. Only a refusal may come unsigned:
/// the workspace cannot sign for a launch it does not know.
fn collect(path: &Path, key: &str, nonce: &str) -> Option<Reply> {
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .ok()?;
    let mut bytes = Vec::new();
    let read = file.metadata().is_ok_and(|meta| meta.is_file())
        && file.take(FILE_LIMIT + 1).read_to_end(&mut bytes).is_ok()
        && bytes.len() as u64 <= FILE_LIMIT;
    let _ = fs::remove_file(path);
    let (_, mac, body) = unseal(&bytes).filter(|_| read)?;
    let reply: Reply = serde_json::from_slice(body).ok()?;
    let trusted = if mac == UNSIGNED {
        reply.error.is_some()
    } else {
        signed(key, "reply", nonce, body, mac)
    };
    trusted.then_some(reply)
}

// ---- The workspace's side.

/// Request names the workspace has taken, with when, so a copy of a request is refused.
#[derive(Default)]
struct Seen(HashMap<String, i64>);

impl Seen {
    fn first(&mut self, nonce: &str, now_ms: i64) -> bool {
        self.0.retain(|_, at| now_ms - *at <= 2 * FRESH_MS);
        self.0.insert(nonce.to_owned(), now_ms).is_none()
    }
}

/// Checks a request file's signature, name, age and newness, and gives the action it asks for.
fn accept(
    key: &str,
    nonce: &str,
    mac: &str,
    body: &[u8],
    now_ms: i64,
    seen: &mut Seen,
) -> Result<Action, &'static str> {
    if !signed(key, "request", nonce, body, mac) {
        return Err(GARBLED);
    }
    let asked: Asked = serde_json::from_slice(body).map_err(|_| GARBLED)?;
    if asked.nonce != nonce {
        return Err(GARBLED);
    }
    if (now_ms - asked.at_ms).abs() > FRESH_MS || !seen.first(nonce, now_ms) {
        return Err(OLD);
    }
    Ok(asked.action)
}

/// Where the workspace looks for request files: in the folder it starts agents in.
pub(crate) fn directory() -> Option<PathBuf> {
    crate::core::agent_cwd()
        .ok()
        .flatten()
        .map(|folder| Path::new(&folder).join(DIR))
}

/// The helper folder, made if it is missing. A symbolic link or a folder of another user in its place is refused.
fn open_folder(path: &Path, owner: u32) -> io::Result<OwnedFd> {
    let dir = match open(path, DIRECTORY, Mode::empty()) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            DirBuilder::new().mode(0o700).create(path)?;
            open(path, DIRECTORY, Mode::empty())?
        }
        other => other?,
    };
    if fstat(&dir)?.st_uid != owner {
        return Err(io::Error::other(
            "The helper folder belongs to another user",
        ));
    }
    Ok(dir)
}

/// Takes every waiting request by renaming it, and gives their names. With `sweep`, also removes files nobody
/// came back for. Only files with a request's random name are ever touched.
fn take(dir: &OwnedFd, sweep: bool) -> Vec<String> {
    let Ok(entries) = Dir::read_from(dir) else {
        return Vec::new();
    };
    let mut taken = Vec::new();
    for entry in entries.flatten().take(ENTRIES) {
        let Ok(name) = entry.file_name().to_str() else {
            continue;
        };
        let Some((nonce, ending)) = name
            .rsplit_once('.')
            .filter(|(nonce, _)| valid_nonce(nonce))
        else {
            continue;
        };
        if ending == "req" {
            if renameat(dir, name, dir, format!("{nonce}.run")).is_ok() {
                taken.push(nonce.to_owned());
            }
        } else if sweep
            && matches!(ending, "new" | "run" | "tmp" | "rep")
            && openat(dir, name, READ, Mode::empty())
                .map(File::from)
                .ok()
                .and_then(|file| file.metadata().ok())
                .is_some_and(|meta| now() / 1000 - meta.mtime() > STALE_SECONDS)
        {
            let _ = unlinkat(dir, name, AtFlags::empty());
        }
    }
    taken
}

/// Reads a taken request and removes it.
fn read_taken(dir: &OwnedFd, nonce: &str) -> Option<Vec<u8>> {
    let name = format!("{nonce}.run");
    let file = openat(dir, &name, READ, Mode::empty()).map(File::from);
    let _ = unlinkat(dir, &name, AtFlags::empty());
    let file = file.ok()?;
    let mut bytes = Vec::new();
    // Two short lines come before the body.
    let limit = REQUEST_LIMIT + 512;
    (file.metadata().is_ok_and(|meta| meta.is_file())
        && file.take(limit as u64 + 1).read_to_end(&mut bytes).is_ok()
        && bytes.len() <= limit)
        .then_some(bytes)
}

/// Writes the answer under another name, then gives it the name the command waits for.
fn write_reply(dir: &OwnedFd, nonce: &str, key: Option<&str>, reply: &Reply) -> io::Result<()> {
    let body = serde_json::to_vec(reply).map_err(io::Error::other)?;
    let mac = key.map_or_else(
        || UNSIGNED.to_owned(),
        |key| sign(key, "reply", nonce, &body),
    );
    let fresh = format!("{nonce}.tmp");
    let mut file = File::from(openat(dir, &fresh, CREATE, Mode::RUSR | Mode::WUSR)?);
    file.write_all(&seal(UNSIGNED, &mac, &body))?;
    Ok(renameat(dir, &fresh, dir, format!("{nonce}.rep"))?)
}

fn refusal(error: impl Into<String>) -> Reply {
    Reply {
        error: Some(error.into()),
        ..Reply::default()
    }
}

async fn serve(w: Workspace, dir: Arc<OwnedFd>, nonce: String, seen: Arc<Mutex<Seen>>) {
    let Some(bytes) = read_taken(&dir, &nonce) else {
        return;
    };
    let (key, reply, start) = answer(&w, &bytes, &nonce, &seen).await;
    let written = write_reply(&dir, &nonce, key.as_deref(), &reply);
    let Some(start) = start else {
        return;
    };
    // While a sandboxed command runs, Codex keeps placeholder folders such as `.git` in the agent's folder, and a
    // Codex started beside them asks whether to trust a project. So a helper is launched only after the command
    // that asked for it has read the answer and exited, and then at once: the agent's next command brings the
    // placeholders back. A launch half a second after the answer was read lost to a next command a second later.
    if written.is_ok() && collected(&dir, &nonce).await {
        tokio::time::sleep(SETTLE).await;
        start.launch();
    } else {
        let _ = unlinkat(&*dir, format!("{nonce}.rep"), AtFlags::empty());
        start.cancel(&w);
    }
}

/// Whether the command took its answer file away in time.
async fn collected(dir: &OwnedFd, nonce: &str) -> bool {
    let name = format!("{nonce}.rep");
    let until = Instant::now() + COLLECT;
    while Instant::now() < until {
        if openat(dir, &name, READ, Mode::empty())
            .is_err_and(|error| error.kind() == io::ErrorKind::NotFound)
        {
            return true;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    false
}

async fn answer(
    w: &Workspace,
    bytes: &[u8],
    nonce: &str,
    seen: &Mutex<Seen>,
) -> (Option<String>, Reply, Option<Deferred>) {
    let Some((launch, mac, body)) = unseal(bytes) else {
        return (None, refusal(GARBLED), None);
    };
    let agents = match w.core.agents().await {
        Ok(agents) => agents,
        Err(error) => return (None, refusal(explain(error)), None),
    };
    // Only a running agent can be asking, so only their keys are tried.
    let Some(key) = agents
        .iter()
        .filter(|agent| agent.require_live().is_ok())
        .filter_map(Terminal::launch_key)
        .find(|key| launch_id(key) == launch)
        .map(str::to_owned)
    else {
        return (None, refusal(UNREGISTERED), None);
    };
    let accepted = match seen.lock() {
        Ok(mut seen) => accept(&key, nonce, mac, body, now(), &mut seen),
        Err(_) => Err(GARBLED),
    };
    let action = match accepted {
        Ok(action) => action,
        // Unsigned: whoever wrote the file did not prove it holds the key.
        Err(why) => return (None, refusal(why), None),
    };
    let request = Request {
        launch: key.clone(),
        action,
    };
    match perform(w, request, true).await {
        Ok((reply, start)) => (Some(key), reply, start),
        Err(error) => (Some(key), refusal(error), None),
    }
}

/// Starts looking for request files. Without a folder for agents (`SWARMHUB_AGENT_CWD`) there is nowhere to look,
/// and helper commands work over the socket only.
pub(crate) fn listen(w: Workspace) -> io::Result<()> {
    let Some(path) = directory() else {
        return Ok(());
    };
    listen_at(w, path)?;
    Ok(())
}

pub(super) fn listen_at(w: Workspace, path: PathBuf) -> io::Result<tokio::task::JoinHandle<()>> {
    let owner = w.history.file().metadata()?.uid();
    open_folder(&path, owner)?;
    Ok(tokio::spawn(async move {
        let seen = Arc::new(Mutex::new(Seen::default()));
        let slots = Arc::new(Semaphore::new(8));
        let mut tick = tokio::time::interval(WATCH);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        let mut round = 0_u32;
        loop {
            tick.tick().await;
            let Ok(dir) = open_folder(&path, owner) else {
                continue;
            };
            let dir = Arc::new(dir);
            // About once a minute, clear out what nobody came back for.
            for nonce in take(&dir, round.is_multiple_of(240)) {
                let Ok(slot) = slots.clone().try_acquire_owned() else {
                    let _ = unlinkat(&*dir, format!("{nonce}.run"), AtFlags::empty());
                    continue;
                };
                let (w, dir, seen) = (w.clone(), dir.clone(), seen.clone());
                tokio::spawn(async move {
                    let _slot = slot;
                    serve(w, dir, nonce, seen).await;
                });
            }
            round = round.wrapping_add(1);
        }
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY: &str = "00112233445566778899aabbccddeeff";
    const OTHER: &str = "ffeeddccbbaa99887766554433221100";

    fn folder() -> (tempfile::TempDir, OwnedFd) {
        let scratch = tempfile::tempdir().unwrap();
        let owner = scratch.path().metadata().unwrap().uid();
        let dir = open_folder(&scratch.path().join(DIR), owner).unwrap();
        (scratch, dir)
    }

    /// The workspace's part for one request, with `handle` in place of the real work.
    fn serve_one(dir: &OwnedFd, seen: &mut Seen, handle: impl Fn(Action) -> Reply) -> bool {
        let Some(nonce) = take(dir, false).pop() else {
            return false;
        };
        let bytes = read_taken(dir, &nonce).unwrap();
        let (launch, mac, body) = unseal(&bytes).unwrap();
        assert_eq!(launch, launch_id(KEY));
        match accept(KEY, &nonce, mac, body, now(), seen) {
            Ok(action) => write_reply(dir, &nonce, Some(KEY), &handle(action)).unwrap(),
            Err(why) => write_reply(dir, &nonce, None, &refusal(why)).unwrap(),
        }
        true
    }

    #[test]
    fn a_request_file_is_answered_once_and_only_for_the_launch_that_signed_it() {
        let (scratch, dir) = folder();
        let path = scratch.path().join(DIR);
        let asking = {
            let path = path.clone();
            std::thread::spawn(move || {
                ask(
                    &path,
                    KEY,
                    Action::Stop { name: "one".into() },
                    Duration::from_secs(20),
                    Duration::from_secs(30),
                )
            })
        };
        let mut seen = Seen::default();
        let mut copy = None;
        let served = (0..400).any(|_| {
            std::thread::sleep(Duration::from_millis(25));
            // Another agent in the folder copies the request before the workspace takes it.
            for entry in fs::read_dir(&path).unwrap().flatten() {
                if entry
                    .path()
                    .extension()
                    .is_some_and(|ending| ending == "req")
                {
                    copy = Some((entry.path(), fs::read(entry.path()).unwrap()));
                }
            }
            copy.is_some()
                && serve_one(&dir, &mut seen, |action| {
                    assert_eq!(action, Action::Stop { name: "one".into() });
                    Reply {
                        text: "Stopped one.".into(),
                        ..Reply::default()
                    }
                })
        });
        assert!(served);
        assert_eq!(asking.join().unwrap().unwrap().text, "Stopped one.");
        // Nothing is left behind, and the file never held the key.
        assert_eq!(fs::read_dir(&path).unwrap().count(), 0);
        let (request, bytes) = copy.unwrap();
        assert!(!String::from_utf8_lossy(&bytes).contains(KEY));

        // The copy, put back under its name, is taken but not run a second time.
        fs::write(&request, &bytes).unwrap();
        assert!(serve_one(&dir, &mut seen, |_| panic!(
            "a copied request ran"
        )));
        let nonce = request.file_stem().unwrap().to_str().unwrap().to_owned();
        let refused = collect(&path.join(format!("{nonce}.rep")), KEY, &nonce).unwrap();
        assert_eq!(refused.error.as_deref(), Some(OLD));

        // A changed body, another launch's signature, another name or an old request is not accepted either.
        let (_, mac, body) = unseal(&bytes).unwrap();
        let mut fresh = Seen::default();
        assert!(accept(KEY, &nonce, mac, body, now(), &mut fresh).is_ok());
        let mut fresh = Seen::default();
        let changed = String::from_utf8_lossy(body).replace("one", "two");
        assert_eq!(
            accept(KEY, &nonce, mac, changed.as_bytes(), now(), &mut fresh),
            Err(GARBLED)
        );
        assert_eq!(
            accept(OTHER, &nonce, mac, body, now(), &mut fresh),
            Err(GARBLED)
        );
        let renamed = "0".repeat(32);
        assert_eq!(
            accept(KEY, &renamed, mac, body, now(), &mut fresh),
            Err(GARBLED)
        );
        assert_eq!(
            accept(KEY, &nonce, mac, body, now() + FRESH_MS + 5_000, &mut fresh),
            Err(OLD)
        );
        assert!(fresh.0.is_empty());
    }

    #[test]
    fn the_command_trusts_only_a_signed_answer_or_an_unsigned_refusal() {
        let (scratch, dir) = folder();
        let path = scratch.path().join(DIR);
        let nonce = "ab".repeat(16);
        let reply = path.join(format!("{nonce}.rep"));
        let done = Reply {
            text: "Started helper easy-1.".into(),
            ..Reply::default()
        };
        write_reply(&dir, &nonce, Some(KEY), &done).unwrap();
        assert_eq!(
            collect(&reply, KEY, &nonce).unwrap().text,
            "Started helper easy-1."
        );
        assert!(!reply.exists());
        // Signed for another launch, or for another request of the same launch.
        write_reply(&dir, &nonce, Some(OTHER), &done).unwrap();
        assert!(collect(&reply, KEY, &nonce).is_none());
        write_reply(&dir, &"cd".repeat(16), Some(KEY), &done).unwrap();
        fs::rename(path.join(format!("{}.rep", "cd".repeat(16))), &reply).unwrap();
        assert!(collect(&reply, KEY, &nonce).is_none());
        // Unsigned good news is somebody else's file; an unsigned refusal is believed.
        write_reply(&dir, &nonce, None, &done).unwrap();
        assert!(collect(&reply, KEY, &nonce).is_none());
        write_reply(&dir, &nonce, None, &refusal(UNREGISTERED)).unwrap();
        assert_eq!(
            collect(&reply, KEY, &nonce).unwrap().error.as_deref(),
            Some(UNREGISTERED)
        );
        fs::write(&reply, "not a reply").unwrap();
        assert!(collect(&reply, KEY, &nonce).is_none() && !reply.exists());
    }

    #[test]
    fn a_request_nobody_takes_is_withdrawn_and_reported_as_the_workspace_being_down() {
        let (scratch, _dir) = folder();
        let path = scratch.path().join(DIR);
        let result = ask(
            &path,
            KEY,
            Action::List,
            Duration::from_millis(300),
            Duration::from_secs(5),
        );
        assert_eq!(result.err(), Some(Some(super::super::cli::OFFLINE)));
        assert_eq!(fs::read_dir(&path).unwrap().count(), 0);
        // A folder that cannot be written means nothing was asked at all.
        let missing = scratch.path().join("missing");
        let result = ask(&missing, KEY, Action::List, Duration::ZERO, Duration::ZERO);
        assert_eq!(result.err(), Some(None));
    }

    #[test]
    fn the_workspace_touches_only_request_files_in_a_real_folder_of_its_own() {
        let (scratch, dir) = folder();
        let path = scratch.path().join(DIR);
        let nonce = "1a".repeat(16);
        for name in [
            "notes.req".to_owned(),
            format!("{nonce}.txt"),
            format!("{}.req", nonce.to_uppercase()),
        ] {
            fs::write(path.join(name), "kept").unwrap();
        }
        fs::write(path.join(format!("{nonce}.rep")), "fresh answer").unwrap();
        assert!(take(&dir, true).is_empty());
        assert_eq!(fs::read_dir(&path).unwrap().count(), 4);
        // A symbolic link where the folder should be is not followed.
        let owner = scratch.path().metadata().unwrap().uid();
        let link = scratch.path().join("link");
        std::os::unix::fs::symlink(&path, &link).unwrap();
        assert!(open_folder(&link, owner).is_err());
        assert!(open_folder(&path, owner + 1).is_err());
        // The command finds the folder from below it, and only when it is a real folder.
        let below = scratch.path().join("a/b");
        fs::create_dir_all(&below).unwrap();
        assert_eq!(find(None, Some(&below)), Some(path.clone()));
        assert_eq!(find(Some(path.clone()), None), Some(path.clone()));
        assert_eq!(find(Some(link), Some(&below)), Some(path));
        assert_eq!(find(None, Some(Path::new("/proc"))), None);
        assert!(valid_nonce(&nonce) && !valid_nonce("12") && !valid_nonce(&"g".repeat(32)));
        assert_eq!(unhex("0aff"), Some(vec![10, 255]));
        assert_eq!(unhex("0af"), None);
    }
}
