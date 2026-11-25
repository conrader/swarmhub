//! Codex replies as they are written.
//!
//! Codex has no hook for unfinished text, but its app server sends every client of a conversation the text a
//! message gains (`item/agentMessage/delta`), and its terminal UI can run against an app server
//! (`codex --remote`). So `run-codex` starts a private app server for the session, with the hook settings it would
//! otherwise have given the UI, and starts the UI against it. This process stays beside them: it joins the UI's
//! conversation as a second client and passes the text of the message being written to the workspace's live
//! socket, the one OpenCode's plugin writes to. `/draft` and the event streams read it from there.
//!
//! The terminal still shows Codex's own UI, and everything a person or the workspace does goes through it as
//! before: tasks, steering, the stop key, approvals. This client only listens. It never answers a request the
//! server sends, so the UI stays the one that decides.
//!
//! If the app server does not come up, `run-codex` starts Codex the way it did before and the reply appears whole.

use crate::agent::session;
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    env,
    ffi::OsString,
    fs::{self, DirBuilder},
    io::{self, Write},
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
    process::{Command, Stdio},
    time::Duration,
};
use tokio::{
    io::AsyncWriteExt,
    net::UnixStream,
    sync::oneshot,
    time::{Instant, interval, sleep_until, timeout},
};
use tokio_tungstenite::{WebSocketStream, tungstenite::Message};

/// `SWARMHUB_CODEX_STREAM=off` starts Codex without the app server.
const SWITCH: &str = "SWARMHUB_CODEX_STREAM";
const LOG: &str = "SWARMHUB_CODEX_STREAM_LOG";
pub(crate) const COMMAND: &str = "codex-stream";
/// How long `run-codex` waits for the app server to listen before it starts Codex without one, in seconds:
/// `SWARMHUB_CODEX_STREAM_WAIT`, within these bounds.
///
/// The server listens in under a second while Codex's own files are in memory, however busy the processor is.
/// When the machine has dropped them (its saved-session databases are some hundred megabytes) and the disk is
/// busy, listening took 2 to 17 seconds, and the terminal UI reported its status about 40 seconds after the
/// start whenever the server had listened in time. Herdr Core holds the first task for 60 seconds from the
/// start. A server that has not listened by now is given up, which leaves the old start the rest of them.
const WAIT: &str = "SWARMHUB_CODEX_STREAM_WAIT";
const WAIT_SECONDS: u64 = 20;
const WAIT_BOUNDS: std::ops::RangeInclusive<u64> = 1..=45;
/// How often `run-codex` looks whether the server listens.
const LOOK: Duration = Duration::from_millis(20);
/// A note on why a session started without the app server is kept this long.
const NOTE_KEPT: Duration = Duration::from_secs(30 * 24 * 60 * 60);
/// The workspace keeps at most this much of a reply so far (`live_reply`).
const TEXT_LIMIT: usize = 32 * 1024;
/// Text is passed on at most this often, however fast it arrives.
const PACE: Duration = Duration::from_millis(60);
const FEED_WAIT: Duration = Duration::from_millis(200);
/// A conversation can only be joined once its first turn is on disk, a moment after it turns active.
const JOIN_AGAIN: Duration = Duration::from_millis(150);
const JOIN_TRIES: u8 = 40;
const RECONNECT: Duration = Duration::from_secs(2);
/// Until the server has answered once, ask more often.
const FIRST_CONNECT: Duration = Duration::from_millis(100);
const REMEMBERED: usize = 256;

/// Notifications this client has no use for. Leaving them out keeps a long command's output off the socket.
const UNUSED: &[&str] = &[
    "item/commandExecution/outputDelta",
    "item/commandExecution/terminalInteraction",
    "item/fileChange/outputDelta",
    "item/fileChange/patchUpdated",
    "item/reasoning/summaryTextDelta",
    "item/reasoning/summaryPartAdded",
    "item/reasoning/textDelta",
    "item/plan/delta",
    "item/mcpToolCall/progress",
    "turn/diff/updated",
    "turn/plan/updated",
    "turn/moderationMetadata",
    "hook/started",
    "hook/completed",
    "thread/tokenUsage/updated",
    "account/rateLimits/updated",
];

type Failed = Box<dyn std::error::Error>;
type Connection = WebSocketStream<UnixStream>;

fn address(socket: &Path) -> String {
    format!("unix://{}", socket.display())
}

fn wait(asked: Option<&str>) -> Duration {
    let seconds = asked
        .and_then(|seconds| seconds.trim().parse::<u64>().ok())
        .map_or(WAIT_SECONDS, |seconds| {
            seconds.clamp(*WAIT_BOUNDS.start(), *WAIT_BOUNDS.end())
        });
    Duration::from_secs(seconds)
}

fn folder(journal: &Path) -> PathBuf {
    journal.with_file_name("codex-stream")
}

/// The file that says why the session with this launch key shows its replies whole. The name is a digest:
/// the launch key itself stays out of file names.
fn note_path(journal: &Path, key: &str) -> PathBuf {
    let digest = Sha256::new()
        .chain_update(b"swarmhub-codex-stream-v1\0")
        .chain_update(key.as_bytes())
        .finalize();
    let name: String = digest[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect();
    folder(journal).join(format!("{name}.whole"))
}

/// Why this session's replies arrive whole, when it started without the app server. The workspace shows it
/// with the agent (`reply_arrives_whole`), so the question can be answered after the fact.
pub(crate) fn whole_reason(journal: &Path, key: &str) -> Option<String> {
    let reason = fs::read_to_string(note_path(journal, key)).ok()?;
    let reason: String = reason
        .trim()
        .chars()
        .filter(|c| !c.is_control())
        .take(300)
        .collect();
    (!reason.is_empty()).then_some(reason)
}

/// Leaves the reason where the workspace finds it, and in the log when there is one.
pub(super) fn starts_whole(journal: &Path, key: &str, reason: &str) {
    let folder = folder(journal);
    if DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&folder)
        .is_ok()
    {
        let _ = fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(note_path(journal, key))
            .and_then(|mut file| file.write_all(reason.as_bytes()));
    }
    logged(&format!("replies arrive whole: {reason}"));
}

/// One line in the file `SWARMHUB_CODEX_STREAM_LOG` names, from `run-codex` itself.
fn logged(text: &str) {
    let Some(path) = env::var_os(LOG).filter(|path| Path::new(path).is_absolute()) else {
        return;
    };
    if let Ok(mut file) = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)
    {
        let _ = writeln!(file, "run-codex {}: {text}", std::process::id());
    }
}

/// Whether the app server takes connections at this path yet. Codex leaves a link there to the socket itself.
fn listening(socket: &Path) -> bool {
    fs::canonicalize(socket)
        .and_then(std::os::unix::net::UnixStream::connect)
        .is_ok()
}

/// Starts the app server and this follower for a session. Returns the address the terminal UI connects to,
/// or `None` when Codex has to start the old way; why is then left for the workspace (`whole_reason`).
pub(super) fn start(journal: &Path, key: &str, exe: &str, hooks: &[String]) -> Option<String> {
    if env::var(SWITCH).as_deref() == Ok("off") {
        starts_whole(
            journal,
            key,
            "the template turns live replies off (SWARMHUB_CODEX_STREAM=off).",
        );
        return None;
    }
    let begun = std::time::Instant::now();
    let fail = |reason: &str| {
        starts_whole(journal, key, reason);
        None
    };
    let folder = folder(journal);
    if DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(&folder)
        .is_err()
    {
        return fail("the workspace's data folder could not hold the app server's socket.");
    }
    let launcher = std::process::id();
    forget_ended(&folder);
    let socket = note_path(journal, key).with_extension("sock");
    if socket
        .to_str()
        .is_none_or(|path| path.contains(char::is_whitespace))
    {
        return fail(
            "the workspace's data folder has a name Codex cannot be given as a socket address.",
        );
    }
    let Ok(mut follower) = Command::new(exe)
        .arg(COMMAND)
        .arg(launcher.to_string())
        .arg(&socket)
        .args(hooks)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log())
        // Its own group: the terminal's foreground group stays Codex's UI alone.
        .process_group(0)
        .spawn()
    else {
        return fail("the follower beside Codex could not be started.");
    };
    // The terminal UI only needs the server to listen. The follower joins on its own, a moment later.
    let wait = wait(env::var(WAIT).ok().as_deref());
    let reason = loop {
        if listening(&socket) {
            logged(&format!(
                "the app server listened after {} ms",
                begun.elapsed().as_millis()
            ));
            return Some(address(&socket));
        }
        if !matches!(follower.try_wait(), Ok(None)) {
            break "Codex's app server ended before it listened.".to_owned();
        }
        if begun.elapsed() >= wait {
            break format!(
                "Codex's app server did not listen within {} seconds, so Codex was started without it.",
                wait.as_secs()
            );
        }
        std::thread::sleep(LOOK);
    };
    let _ = follower.kill();
    let _ = follower.wait();
    let _ = fs::remove_file(&socket);
    fail(&reason)
}

/// Where the follower and its app server may write why something failed: the file `SWARMHUB_CODEX_STREAM_LOG`
/// names, or nowhere.
fn log() -> Stdio {
    env::var_os(LOG)
        .filter(|path| Path::new(path).is_absolute())
        .and_then(|path| {
            fs::OpenOptions::new()
                .create(true)
                .append(true)
                .mode(0o600)
                .open(path)
                .ok()
        })
        .map_or_else(Stdio::null, Stdio::from)
}

/// Removes the socket names of sessions whose process is gone (one that was killed could not remove its own)
/// and the notes of sessions long over.
fn forget_ended(folder: &Path) {
    for entry in fs::read_dir(folder).into_iter().flatten().flatten() {
        let name = entry.file_name();
        let pid = name
            .to_str()
            .and_then(|name| name.strip_suffix(".sock"))
            .and_then(|pid| pid.parse::<libc::pid_t>().ok());
        if let Some(pid) = pid.filter(|pid| *pid > 0)
            && unsafe { libc::kill(pid, 0) } != 0
            && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
        {
            let _ = fs::remove_file(entry.path());
        }
        let old_note = name.to_str().is_some_and(|name| name.ends_with(".whole"))
            && entry
                .metadata()
                .and_then(|file| file.modified())
                .is_ok_and(|at| at.elapsed().is_ok_and(|age| age > NOTE_KEPT));
        if old_note {
            let _ = fs::remove_file(entry.path());
        }
    }
}

/// Ends the app server with this process, and removes the socket's name.
struct Server {
    pid: libc::pid_t,
    socket: PathBuf,
}

impl Drop for Server {
    fn drop(&mut self) {
        unsafe { libc::kill(self.pid, libc::SIGTERM) };
        let _ = fs::remove_file(&self.socket);
    }
}

/// Linux ends this process, and the app server it starts, when their parent ends. macOS has no such call: there
/// this process looks every second whether `run-codex` is still its parent (`orphaned`), and ends the app server
/// when it is told to end itself (`platform::end_on_signal`).
fn end_with_parent() -> io::Result<()> {
    crate::platform::end_with_parent(libc::SIGTERM)
}

/// `swarmhub-herdr codex-stream LAUNCHER SOCKET HOOK...`: the process beside Codex's terminal UI.
pub async fn run() -> Result<(), Failed> {
    const USAGE: &str = "run-codex starts this command. It is not meant to be run by hand.";
    let (journal, key) = session()?;
    let mut args = env::args_os().skip(2);
    let launcher: libc::pid_t = args
        .next()
        .and_then(|pid| pid.to_str()?.parse().ok())
        .ok_or(USAGE)?;
    let socket = args.next().map(PathBuf::from).ok_or(USAGE)?;
    let hooks: Vec<OsString> = args.collect();
    // `run-codex` becomes the terminal UI. When that ends, so does this process and the app server.
    end_with_parent()?;
    let orphaned = || unsafe { libc::getppid() } != launcher;
    if orphaned() || !socket.is_absolute() {
        return Err(USAGE.into());
    }
    let _ = fs::remove_file(&socket);
    let mut command = super::executable();
    command.env_remove(crate::runtimes::MODEL_ENV);
    for hook in &hooks {
        command.arg("-c").arg(hook);
    }
    command
        .args(["app-server", "--listen"])
        .arg(address(&socket))
        .stdin(Stdio::null())
        .stdout(Stdio::null());
    unsafe { command.pre_exec(end_with_parent) };
    let mut process = command.spawn()?;
    let _server = Server {
        pid: process.id() as libc::pid_t,
        socket: socket.clone(),
    };
    crate::platform::end_on_signal(process.id() as libc::pid_t);
    let (exited, mut ended) = oneshot::channel();
    std::thread::spawn(move || {
        let _ = process.wait();
        let _ = exited.send(());
    });

    let mut follower = Follower::default();
    let mut feed = Feed {
        path: journal.with_file_name("replies.sock"),
        key,
        socket: None,
    };
    let mut alive = interval(Duration::from_secs(1));
    let mut flush_at: Option<Instant> = None;
    // `run-codex` starts the terminal UI as soon as the server listens. This client joins when the server
    // answers it, however long that takes: a conversation that began meanwhile is joined from the list.
    let mut connection: Option<Connection> = None;
    let mut connect_again = FIRST_CONNECT;
    let mut reconnect_at = Instant::now();
    loop {
        let join_at = follower.retries.first().map(|(at, _, _)| *at);
        tokio::select! {
            _ = &mut ended => return Ok(()),
            _ = alive.tick() => if orphaned() { return Ok(()) },
            message = next(&mut connection) => {
                let requests = match message {
                    Some(text) => {
                        let requests = follower.heard(&text);
                        if follower.reviewer.is_some() || follower.review_event.is_some() || follower.sandbox.is_some() || follower.policy.is_some() {
                            save_review(&journal, &feed.key, follower.reviewer.take(), follower.review_event.take(), follower.sandbox.take(), follower.policy.take());
                        }
                        if let Some((turn, answer)) = follower.completed.take()
                            && let Err(error) = super::save_reply(&journal, &feed.key, Some(&turn), &answer)
                        {
                            note(&format!("Could not save completed Codex turn: {error}"));
                        }
                        requests
                    }
                    None => {
                        // The UI may still be using the server: leave it running and try to listen again.
                        connection = None;
                        reconnect_at = Instant::now() + RECONNECT;
                        flush_at = None;
                        follower = Follower::default();
                        feed.show(None).await;
                        Vec::new()
                    }
                };
                send_all(&mut connection, requests).await;
            }
            () = wait_until(join_at) => {
                let requests = follower.join_again();
                send_all(&mut connection, requests).await;
            }
            () = wait_until(flush_at) => {
                flush_at = None;
                follower.changed = false;
                feed.show(follower.reply.as_ref()).await;
            }
            () = sleep_until(reconnect_at), if connection.is_none() => {
                connection = connect(&socket).await;
                reconnect_at = Instant::now() + connect_again;
                if connection.is_some() {
                    connect_again = RECONNECT;
                    let requests = follower.list_threads();
                    send_all(&mut connection, requests).await;
                }
            }
        }
        if follower.changed && flush_at.is_none() {
            flush_at = Some(Instant::now() + PACE);
        }
    }
}

async fn wait_until(at: Option<Instant>) {
    match at {
        Some(at) => sleep_until(at).await,
        None => std::future::pending().await,
    }
}

/// The next text message, or `None` when the connection is over (or there is none: then this never returns).
async fn next(connection: &mut Option<Connection>) -> Option<String> {
    let Some(open) = connection else {
        return std::future::pending().await;
    };
    loop {
        match open.next().await? {
            Ok(Message::Text(text)) => return Some(text.as_str().to_owned()),
            Ok(Message::Close(_)) | Err(_) => return None,
            // Pings are answered by the library; nothing else carries a message.
            Ok(_) => {}
        }
    }
}

async fn send_all(connection: &mut Option<Connection>, requests: Vec<Value>) {
    for request in requests {
        let Some(open) = connection else {
            return;
        };
        if open.send(Message::text(request.to_string())).await.is_err() {
            *connection = None;
        }
    }
}

/// Connects and introduces this client. `None` while the server is not ready.
async fn connect(socket: &Path) -> Option<Connection> {
    let hello = async {
        // Codex puts the socket itself under a short name and leaves a link at the path it was given.
        let stream = UnixStream::connect(fs::canonicalize(socket)?).await?;
        let (mut connection, _) =
            tokio_tungstenite::client_async("ws://localhost/", stream).await?;
        // A server that does not know one of the names to leave out still gets a client: ask again without them.
        for leave_out in [Some(UNUSED), None] {
            let request = json!({"id":0,"method":"initialize","params":{
                "clientInfo":{"name":"swarmhub-herdr","title":"SwarmHub","version":env!("CARGO_PKG_VERSION")},
                "capabilities":{"experimentalApi":false,"requestAttestation":false,
                                "optOutNotificationMethods":leave_out},
            }});
            connection.send(Message::text(request.to_string())).await?;
            let accepted = loop {
                let message = connection.next().await.ok_or("closed")??;
                let Message::Text(text) = message else {
                    continue;
                };
                let answer: Value = serde_json::from_str(text.as_str())?;
                if answer["id"] == 0 && answer.get("method").is_none() {
                    break answer.get("result").is_some();
                }
            };
            if accepted {
                let ready = json!({"method":"initialized"});
                connection.send(Message::text(ready.to_string())).await?;
                return Ok::<_, Failed>(connection);
            }
        }
        Err("Codex's app server refused this client.".into())
    };
    match timeout(Duration::from_secs(5), hello).await {
        Ok(Ok(connection)) => Some(connection),
        Ok(Err(error)) => {
            // Until the server has made its socket there is nothing to say.
            let starting = error
                .downcast_ref::<io::Error>()
                .is_some_and(|error| error.kind() == io::ErrorKind::NotFound);
            if !starting {
                note(&error.to_string());
            }
            None
        }
        Err(_) => {
            note("Codex's app server did not answer the greeting.");
            None
        }
    }
}

/// The client puts a unique reference in the first user input of its turn. A follow-up
/// may only address that same input on this launch's private app server.
fn matching_turn<'a>(thread: &'a Value, reference: &str) -> Option<&'a str> {
    if other_conversation(thread) { return None; }
    let turn = thread["turns"].as_array()?.last()?;
    let marker = format!("[SwarmHub turn {reference}]");
    let first = turn["items"].as_array()?.iter().find(|item| item["type"] == "userMessage")?;
    (turn["status"] == "inProgress" && first["content"].as_array()?.iter().any(|part|
        part["text"].as_str().is_some_and(|text| text.lines().any(|line| line == marker))))
        .then(|| turn["id"].as_str()).flatten()
}

async fn rpc(connection: &mut Connection, id: u64, method: &str, params: Value) -> Result<Value, crate::ApiError> {
    use crate::{ApiError, core::Failure};
    connection.send(Message::text(json!({"id":id,"method":method,"params":params}).to_string()))
        .await.map_err(|_| Failure::Uncertain)?;
    while let Some(Ok(message)) = connection.next().await {
        if let Message::Text(text) = message
            && let Ok(reply) = serde_json::from_str::<Value>(&text)
            && reply.get("method").is_none() && reply["id"] == id {
            return reply.get("result").cloned().ok_or(ApiError::Conflict("The current turn refused the follow-up."));
        }
    }
    Err(Failure::Uncertain.into())
}

pub(crate) async fn steer(journal: &Path, key: &str, reference: &str, text: &str) -> Result<(), crate::ApiError> {
    use crate::{ApiError, core::Failure};
    timeout(Duration::from_secs(15), async {
        let socket = note_path(journal, key).with_extension("sock");
        let mut connection = connect(&socket).await.ok_or(ApiError::Conflict("This launch cannot receive live guidance."))?;
        let threads = rpc(&mut connection, 1, "thread/loaded/list", json!({})).await?;
        for thread in threads["data"].as_array().into_iter().flatten().filter_map(Value::as_str) {
            let read = rpc(&mut connection, 2, "thread/read", json!({"threadId":thread,"includeTurns":true})).await?;
            if let Some(turn) = matching_turn(&read["thread"], reference) {
                let result = rpc(&mut connection, 3, "turn/steer", json!({
                    "threadId":thread,"expectedTurnId":turn,"input":[{"type":"text","text":text}]
                })).await?;
                return if result["turnId"] == turn { Ok(()) } else { Err(Failure::Uncertain.into()) };
            }
        }
        Err(ApiError::Conflict("The intended turn is no longer available."))
    }).await.map_err(|_| Failure::Uncertain)?
}

/// A line for whoever set `SWARMHUB_CODEX_STREAM_LOG`; otherwise standard error goes nowhere.
fn note(text: &str) {
    eprintln!("codex-stream {}: {text}", std::process::id());
}

/// The message Codex is writing.
#[derive(Debug, PartialEq)]
struct Reply {
    thread: String,
    item: String,
    text: String,
    /// Heard from its first word. A message joined halfway is shown once it is complete.
    whole: bool,
}

#[derive(Default)]
struct Follower {
    last_id: u64,
    sandbox: Option<&'static str>,
    policy: Option<&'static str>,
    reviewer: Option<&'static str>,
    review_event: Option<&'static str>,
    /// Requests to join a conversation that have no answer yet, by request id, with the tries so far.
    joining: HashMap<u64, (String, u8)>,
    joined: HashSet<String>,
    /// Conversations that are not the person's: Codex's own short-lived ones, and those of its sub-agents.
    skipped: HashSet<String>,
    retries: Vec<(Instant, String, u8)>,
    listing: Option<u64>,
    // A completed final message can precede turn/completed, whose items are often empty.
    // Keep it separate from the preview, which can also contain partial text or commentary.
    // Providers may omit `phase` (`null`), so track whether `final_answer` was explicit.
    final_by_thread: HashMap<String, (String, String, bool)>,
    completed: Option<(String, String)>,
    reply: Option<Reply>,
    /// The reply changed since it was last shown.
    changed: bool,
}

#[derive(Deserialize)]
struct Heard {
    id: Option<Value>,
    method: Option<String>,
    #[serde(default)]
    params: Value,
    result: Option<Value>,
    error: Option<Value>,
}

#[derive(Default, serde::Serialize)]
pub(crate) struct ReviewStatus {
    auto_restart_pending: bool,
    codex_sandbox: Option<String>,
    codex_policy: Option<String>,
    codex_reviewer: Option<String>,
    codex_review_event: Option<String>,
}

pub(crate) fn review_status(history: &crate::history::History, key: Option<&str>) -> ReviewStatus {
    let Some(key) = key else { return ReviewStatus::default(); };
    let Ok(db) = history.db() else { return ReviewStatus::default(); };
    let Ok(settings) = crate::bot_agent_settings::for_launch(&db, key) else { return ReviewStatus::default(); };
    db.query_row(
        "SELECT coalesce(launch_auto != ?2,
                    ?2 OR coalesce(at_ms < ?3, 0)),
                codex_sandbox,codex_policy,codex_reviewer,codex_review_event
         FROM journal WHERE launch_key=?1",
        rusqlite::params![key, settings.auto_mode, settings.auto_changed_ms], |row| Ok(ReviewStatus {
            auto_restart_pending: row.get(0)?,
            codex_sandbox: row.get(1)?,
            codex_policy: row.get(2)?,
            codex_reviewer: row.get(3)?,
            codex_review_event: row.get(4)?,
        }),
    ).unwrap_or_default()
}

// Store only classifications derived from Codex's authenticated session, never command arguments or reasons.
fn save_review(journal: &Path, key: &str, reviewer: Option<&str>, event: Option<&str>, sandbox: Option<&str>, policy: Option<&str>) {
    if let Ok(db) = rusqlite::Connection::open_with_flags(journal,rusqlite::OpenFlags::SQLITE_OPEN_READ_WRITE) {
        let _ = db.execute("UPDATE journal SET codex_reviewer=coalesce(?2,codex_reviewer),
            codex_review_event=coalesce(?3,codex_review_event),codex_sandbox=coalesce(?4,codex_sandbox),
            codex_policy=coalesce(?5,codex_policy) WHERE launch_key=?1",
            rusqlite::params![key,reviewer,event,sandbox,policy]);
    }
}

fn other_conversation(thread: &Value) -> bool {
    thread["ephemeral"] == true || !thread["parentThreadId"].is_null()
}

fn final_text(item: &Value) -> Option<(&str, bool)> {
    if item["type"] != "agentMessage" {
        return None;
    }
    let text = item["text"]
        .as_str()
        .filter(|s| !s.trim().is_empty() && s.len() <= super::MAX_REPLY_BYTES)?;
    match item.get("phase") {
        Some(Value::String(phase)) if phase == "final_answer" => Some((text, true)),
        None | Some(Value::Null) => Some((text, false)),
        _ => None,
    }
}

fn final_from_items(items: &[Value]) -> Option<&str> {
    if let Some(explicit) = items
        .iter()
        .rev()
        .find_map(|item| final_text(item).and_then(|(text, explicit)| explicit.then_some(text)))
    {
        return Some(explicit);
    }
    // Legacy models/providers leave `phase` null; accept an agentMessage only when no tool item followed it.
    let terminal = items
        .iter()
        .rev()
        .find(|item| !matches!(item["type"].as_str(), Some("reasoning" | "plan")))?;
    final_text(terminal).map(|(text, _)| text)
}

impl Follower {
    fn request(&mut self, method: &str, params: Value) -> (u64, Value) {
        self.last_id += 1;
        (
            self.last_id,
            json!({"id":self.last_id,"method":method,"params":params}),
        )
    }

    fn join(&mut self, thread: &str, tries: u8) -> Vec<Value> {
        if self.joined.contains(thread)
            || self.skipped.contains(thread)
            || self.joining.values().any(|(joining, _)| joining == thread)
            || self.retries.iter().any(|(_, waiting, _)| waiting == thread)
        {
            return Vec::new();
        }
        // Joining a running conversation changes nothing in it: no settings are sent, and no history is asked for.
        let (id, request) = self.request(
            "thread/resume",
            json!({"threadId":thread,"excludeTurns":true}),
        );
        self.joining.insert(id, (thread.to_owned(), tries));
        vec![request]
    }

    fn join_again(&mut self) -> Vec<Value> {
        let now = Instant::now();
        let due: Vec<_> = self
            .retries
            .extract_if(.., |(at, _, _)| *at <= now)
            .collect();
        due.into_iter()
            .flat_map(|(_, thread, tries)| self.join(&thread, tries))
            .collect()
    }

    /// After a lost connection: the conversations the server has open, to join the running ones again.
    fn list_threads(&mut self) -> Vec<Value> {
        let (id, request) = self.request("thread/loaded/list", json!({}));
        self.listing = Some(id);
        vec![request]
    }

    fn skip(&mut self, thread: &str) {
        if self.skipped.len() >= REMEMBERED {
            self.skipped.clear();
        }
        self.skipped.insert(thread.to_owned());
    }

    fn clear(&mut self, thread: &str) {
        if self
            .reply
            .as_ref()
            .is_some_and(|reply| reply.thread == thread)
        {
            self.reply = None;
            self.changed = true;
        }
    }

    /// Takes one message from the server and returns the requests to send in answer.
    fn heard(&mut self, text: &str) -> Vec<Value> {
        let Ok(message) = serde_json::from_str::<Heard>(text) else {
            return Vec::new();
        };
        let Some(method) = message.method else {
            return self.answered(message.id, message.result, message.error);
        };
        if message.id.is_some() {
            if self.joined.contains(message.params["threadId"].as_str().unwrap_or(""))
                && matches!(method.as_str(), "item/commandExecution/requestApproval" | "item/permissions/requestApproval") {
                self.review_event = Some("human_requested");
            }
            // A question for the person (an approval, a form). The terminal UI answers it.
            return Vec::new();
        }
        let params = message.params;
        let thread = params["threadId"].as_str().unwrap_or_default();
        match method.as_str() {
            "item/autoApprovalReview/completed" if self.joined.contains(thread) && params["decisionSource"] == "agent" => {
                self.review_event = match params["review"]["status"].as_str() {
                    Some("approved") => Some("auto_approved"),
                    Some("denied") => Some("auto_denied"),
                    Some("timedOut" | "aborted") => Some("auto_incomplete"),
                    _ => None,
                };
            }
            "thread/started" => {
                if let Some(id) = params["thread"]["id"].as_str()
                    && other_conversation(&params["thread"])
                {
                    self.skip(id);
                }
            }
            "thread/status/changed" if params["status"]["type"] == "active" => {
                return self.join(thread, 0);
            }
            "thread/closed" => {
                self.joined.remove(thread);
                self.final_by_thread.remove(thread);
                self.clear(thread);
            }
            "turn/started" if self.joined.contains(thread) => {
                self.final_by_thread.remove(thread);
                self.clear(thread);
            }
            "turn/completed" if self.joined.contains(thread) => {
                let candidate = self.final_by_thread.remove(thread);
                let turn = &params["turn"];
                if turn["status"] == "completed"
                    && let Some(id) = turn["id"].as_str().filter(|id| super::valid_turn(id))
                {
                    self.completed = turn["items"]
                        .as_array()
                        .and_then(|items| final_from_items(items.as_slice()))
                        .map(|text| (id.to_owned(), text.to_owned()))
                        .or_else(|| {
                            candidate
                                .filter(|(seen, _, _)| seen == id)
                                .map(|(seen, text, _)| (seen, text))
                        });
                }
                self.clear(thread);
            }
            "item/started" if self.joined.contains(thread) => {
                let item = &params["item"];
                if !matches!(
                    item["type"].as_str(),
                    Some("agentMessage" | "reasoning" | "plan")
                ) && self
                    .final_by_thread
                    .get(thread)
                    .is_some_and(|(_, _, explicit)| !*explicit)
                {
                    self.final_by_thread.remove(thread);
                }
                if item["type"] == "agentMessage"
                    && let Some(id) = item["id"].as_str()
                {
                    self.reply = Some(Reply {
                        thread: thread.to_owned(),
                        item: id.to_owned(),
                        text: item["text"].as_str().unwrap_or_default().to_owned(),
                        whole: true,
                    });
                    self.changed = true;
                }
            }
            "item/agentMessage/delta" if self.joined.contains(thread) => {
                let (Some(id), Some(delta)) = (params["itemId"].as_str(), params["delta"].as_str())
                else {
                    return Vec::new();
                };
                match &mut self.reply {
                    Some(reply) if reply.item == id => {
                        if reply.whole && reply.text.len() <= TEXT_LIMIT {
                            reply.text.push_str(delta);
                            self.changed = true;
                        }
                    }
                    // Joined in the middle of this message: its beginning was not heard.
                    _ => {
                        self.reply = Some(Reply {
                            thread: thread.to_owned(),
                            item: id.to_owned(),
                            text: String::new(),
                            whole: false,
                        });
                        self.changed = true;
                    }
                }
            }
            "item/completed" if self.joined.contains(thread) => {
                let item = &params["item"];
                if let Some((text, explicit)) = final_text(item)
                    && let Some(id) = params["turnId"].as_str().filter(|id| super::valid_turn(id))
                {
                    let keep_existing = !explicit
                        && self
                            .final_by_thread
                            .get(thread)
                            .is_some_and(|(seen, _, was_explicit)| seen == id && *was_explicit);
                    if !keep_existing {
                        self.final_by_thread.insert(
                            thread.to_owned(),
                            (id.to_owned(), text.to_owned(), explicit),
                        );
                    }
                }
                if item["type"] == "agentMessage"
                    && let (Some(id), Some(text)) = (item["id"].as_str(), item["text"].as_str())
                    && self.reply.as_ref().is_none_or(|reply| reply.item == id)
                {
                    self.reply = Some(Reply {
                        thread: thread.to_owned(),
                        item: id.to_owned(),
                        text: text.to_owned(),
                        whole: true,
                    });
                    self.changed = true;
                }
            }
            _ => {}
        }
        Vec::new()
    }

    fn answered(
        &mut self,
        id: Option<Value>,
        result: Option<Value>,
        error: Option<Value>,
    ) -> Vec<Value> {
        let Some(id) = id.as_ref().and_then(Value::as_u64) else {
            return Vec::new();
        };
        if self.listing == Some(id) {
            self.listing = None;
            let threads: Vec<String> = result
                .as_ref()
                .and_then(|result| result["data"].as_array())
                .into_iter()
                .flatten()
                .filter_map(|thread| thread.as_str().map(str::to_owned))
                .take(REMEMBERED)
                .collect();
            return threads
                .iter()
                .flat_map(|thread| self.join(thread, JOIN_TRIES - 1))
                .collect();
        }
        let Some((thread, tries)) = self.joining.remove(&id) else {
            return Vec::new();
        };
        match result {
            Some(result) if other_conversation(&result["thread"]) => {
                self.skip(&thread);
                let (_, leave) = self.request("thread/unsubscribe", json!({"threadId":thread}));
                vec![leave]
            }
            Some(result) => {
                self.sandbox = match result["sandbox"]["type"].as_str() {
                    Some("readOnly") => Some("read-only"),
                    Some("workspaceWrite") => Some("workspace-write"),
                    Some("dangerFullAccess") => Some("danger-full-access"),
                    _ => None,
                };
                self.policy = match result["approvalPolicy"].as_str() {
                    Some("on-request") => Some("on-request"),
                    Some("never") => Some("never"),
                    Some("untrusted") => Some("untrusted"),
                    _ if result["approvalPolicy"].get("granular").is_some() => Some("granular"),
                    _ => None,
                };
                self.reviewer = match result["approvalsReviewer"].as_str() {
                    Some("user") => Some("user"),
                    Some("auto_review" | "guardian_subagent") => Some("auto_review"),
                    _ => None,
                };
                if self.joined.len() >= REMEMBERED {
                    self.joined.clear();
                    self.final_by_thread.clear();
                }
                self.joined.insert(thread);
                Vec::new()
            }
            // Not on disk yet, or not a conversation that can be joined.
            None if error.is_some() && tries + 1 < JOIN_TRIES => {
                self.retries
                    .push((Instant::now() + JOIN_AGAIN, thread, tries + 1));
                Vec::new()
            }
            None => Vec::new(),
        }
    }
}

/// The workspace's live socket: one connection while a reply is being written. Closing it takes the reply
/// so far away again, which is what the end of a turn means.
struct Feed {
    path: PathBuf,
    key: String,
    socket: Option<UnixStream>,
}

/// A message id as the workspace accepts it (`opencode_agent::valid_reply_id`).
fn reply_id(item: &str) -> String {
    let id: String = item
        .chars()
        .take(128)
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' {
                c
            } else {
                '-'
            }
        })
        .collect();
    if id.is_empty() { "reply".into() } else { id }
}

impl Feed {
    async fn show(&mut self, reply: Option<&Reply>) {
        let Some(reply) = reply.filter(|reply| reply.whole && !reply.text.trim().is_empty()) else {
            // Nothing to show: an empty message keeps what was there until text arrives or the turn ends.
            if reply.is_none() {
                self.socket = None;
            }
            return;
        };
        if reply.text.len() > TEXT_LIMIT {
            return;
        }
        let Ok(mut line) = serde_json::to_vec(
            &json!({"key":self.key,"id":reply_id(&reply.item),"text":reply.text}),
        ) else {
            return;
        };
        line.push(b'\n');
        let write = async {
            if self.socket.is_none() {
                self.socket = Some(UnixStream::connect(&self.path).await?);
            }
            match &mut self.socket {
                Some(socket) => socket.write_all(&line).await,
                None => Ok(()),
            }
        };
        // The workspace may be restarting. The next change tries again.
        if !matches!(timeout(FEED_WAIT, write).await, Ok(Ok(()))) {
            self.socket = None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const THREAD: &str = "01a1e5a6-7873-7061-a779-4d9011c1989e";

    fn note(method: &str, params: Value) -> String {
        json!({"method":method,"params":params}).to_string()
    }

    fn joined() -> Follower {
        let mut follower = Follower::default();
        let asked = follower.heard(&note(
            "thread/status/changed",
            json!({"threadId":THREAD,"status":{"type":"active","activeFlags":[]}}),
        ));
        assert_eq!(asked[0]["method"], "thread/resume");
        assert_eq!(
            asked[0]["params"],
            json!({"threadId":THREAD,"excludeTurns":true})
        );
        let id = asked[0]["id"].clone();
        let none = follower.heard(&json!({"id":id,"result":{"thread":{"id":THREAD,"ephemeral":false,"parentThreadId":null}}}).to_string());
        assert!(none.is_empty() && follower.joined.contains(THREAD));
        follower
    }

    #[tokio::test]
    async fn archive_listing_prompt_and_followup_use_separate_rpc_messages() {
        let (_dir, history) = crate::bots::testing::journal(&["Doc"]);
        let key = crate::bots::testing::session(&history, "Doc", "fixture");
        let owner = crate::bots::testing::id_of("Doc");
        {
            let db = history.db().unwrap();
            db.execute("INSERT INTO bot_agent_settings(bot,auto_mode) VALUES(?,1)", [&owner]).unwrap();
            db.execute("UPDATE journal SET parent_bot_id=?1,launch_auto=0 WHERE launch_key=?2",
                rusqlite::params![owner, key]).unwrap();
        }
        let mut observed = Follower::default();
        let join = observed.join("doc", 0);
        observed.heard(&json!({"id":join[0]["id"],"result":{"thread":{"id":"doc"},
            "sandbox":{"type":"readOnly"},"approvalPolicy":"on-request","approvalsReviewer":"user"}}).to_string());
        let approval = json!({"id":99,"method":"item/commandExecution/requestApproval",
            "params":{"threadId":"doc","turnId":"running","itemId":"item","startedAtMs":1,
                      "command":"fixture SSH listing of one archived project directory","cwd":"/fixture","time":"10:49:13"}});
        assert!(observed.heard(&approval.to_string()).is_empty());
        save_review(history.file(), &key, observed.reviewer, observed.review_event, observed.sandbox, observed.policy);
        let current = review_status(&history, Some(&key));
        assert!(current.auto_restart_pending);
        assert_eq!(current.codex_review_event.as_deref(), Some("human_requested"));
        let (next, _) = crate::codex_agent::auto_configs(true, &[]);
        assert!(next.iter().any(|setting| setting == r#"approvals_reviewer="auto_review""#));
        let short = tempfile::tempdir_in("/tmp").unwrap();
        let path = short.path().join("test.sock");
        let socket = tokio::net::UnixListener::bind(&path).unwrap();
        fs::create_dir_all(folder(history.file())).unwrap();
        std::os::unix::fs::symlink(&path, note_path(history.file(), &key).with_extension("sock")).unwrap();
        let server = tokio::spawn(async move {
            let (stream, _) = socket.accept().await.unwrap();
            let mut peer = tokio_tungstenite::accept_async(stream).await.unwrap();
            let mut calls = Vec::new();
            while let Some(Ok(Message::Text(msg))) = peer.next().await {
                let req: Value = serde_json::from_str(&msg).unwrap();
                let method = req["method"].as_str().unwrap();
                calls.push(method.to_owned());
                let result = match method {
                    "initialize" => json!({}),
                    "initialized" => continue,
                    "thread/loaded/list" => json!({"data":["doc"]}),
                    "thread/read" => {
                        peer.send(Message::text(approval.to_string())).await.unwrap();
                        json!({"thread":{"turns":[{"id":"running","status":"inProgress","items":[
                            {"type":"userMessage","content":[{"text":"[SwarmHub turn fixture]\nCheck the archive"}]}]}]}})
                    }
                    "turn/steer" => {
                        assert_eq!(req["params"], json!({"threadId":"doc","expectedTurnId":"running",
                            "input":[{"type":"text","text":"Include the manifest"}]}));
                        json!({"turnId":"running"})
                    }
                    _ => panic!("Unexpected RPC: {method}"),
                };
                peer.send(Message::text(json!({"id":req["id"],"result":result}).to_string())).await.unwrap();
                if method == "turn/steer" { break; }
            }
            calls
        });
        steer(history.file(), &key, "fixture", "Include the manifest").await.unwrap();
        let after = review_status(&history, Some(&key));
        assert!(after.auto_restart_pending);
        assert_eq!(after.codex_reviewer.as_deref(), Some("user"));
        assert_eq!(after.codex_review_event.as_deref(), Some("human_requested"));
        assert_eq!(server.await.unwrap().last().unwrap(), "turn/steer");
    }

    #[test]
    fn saved_auto_is_pending_on_a_legacy_launch_and_respects_the_effective_reviewer_after_restart() {
        let (_dir, history) = crate::bots::testing::journal(&["Vised"]);
        let key = crate::bots::testing::session(&history, "Vised", "fixture");
        let bot = crate::bots::testing::id_of("Vised");
        history.db().unwrap().execute("INSERT INTO bot_agent_settings(bot,auto_mode) VALUES(?,1)", [&bot]).unwrap();
        assert!(review_status(&history, Some(&key)).auto_restart_pending);
        history.db().unwrap().execute("UPDATE journal SET parent_bot_id=?1,launch_auto=1,codex_reviewer='user',codex_sandbox='read-only',codex_policy='on-request'
            WHERE launch_key=?2", rusqlite::params![bot,key]).unwrap();
        let current = review_status(&history, Some(&key));
        assert!(!current.auto_restart_pending);
        assert_eq!(current.codex_reviewer.as_deref(), Some("user"));
        assert_eq!(current.codex_policy.as_deref(), Some("on-request"));
        assert_eq!(current.codex_sandbox.as_deref(), Some("read-only"));
        history.db().unwrap().execute("UPDATE journal SET codex_reviewer='auto_review',
            codex_sandbox='workspace-write',codex_policy='granular' WHERE launch_key=?", [&key]).unwrap();
        assert!(!review_status(&history, Some(&key)).auto_restart_pending);
        history.db().unwrap().execute("UPDATE bot_agent_settings SET auto_mode=0 WHERE bot=?", [&bot]).unwrap();
        assert!(review_status(&history, Some(&key)).auto_restart_pending);
        history.db().unwrap().execute("UPDATE journal SET launch_auto=0 WHERE launch_key=?", [&key]).unwrap();
        let off = review_status(&history, Some(&key));
        assert!(!off.auto_restart_pending);
        assert_eq!(off.codex_reviewer.as_deref(), Some("auto_review"));
    }

    #[test]
    fn mock_ovh_job_reports_actual_reviewer_and_never_answers_the_request() {
        for reviewer in ["user", "auto_review"] {
            let mut follower = Follower::default();
            let join = follower.join(THREAD, 0);
            follower.heard(&json!({"id":join[0]["id"],"result":{"thread":{"id":THREAD},"approvalsReviewer":reviewer}}).to_string());
            assert_eq!(follower.reviewer, Some(reviewer));
            let command = "fixture: SSH sb-codejob on OVH";
            let request = json!({"threadId":THREAD,"turnId":"turn","itemId":"item","startedAtMs":1,
                "command":command,"cwd":"/fixture","reason":"Retry a scoped remote job"});
            if reviewer == "user" {
                assert!(follower.heard(&json!({"method":"item/commandExecution/requestApproval","id":9,"params":request}).to_string()).is_empty());
                assert_eq!(follower.review_event, Some("human_requested"));
            } else {
                let event = json!({"threadId":THREAD,"turnId":"turn","reviewId":"review",
                    "startedAtMs":1,"completedAtMs":2,"decisionSource":"agent","review":{"status":"denied"},
                    "action":{"type":"command","source":"shell","command":command,"cwd":"/fixture"}});

                assert!(follower.heard(&note("item/autoApprovalReview/completed",event)).is_empty());
                assert_eq!(follower.review_event, Some("auto_denied"));
            }
        }
    }

    fn text(follower: &Follower) -> Option<&str> {
        follower
            .reply
            .as_ref()
            .filter(|reply| reply.whole)
            .map(|reply| reply.text.as_str())
    }

    #[test]
    fn follows_a_message_from_its_first_word_to_the_end_of_the_turn() {
        let mut follower = joined();
        follower.heard(&note(
            "turn/started",
            json!({"threadId":THREAD,"turn":{"id":"t1"}}),
        ));
        follower.heard(&note(
            "item/started",
            json!({"threadId":THREAD,"turnId":"t1","item":{"type":"agentMessage","id":"msg_1","text":"","phase":"commentary"}}),
        ));
        for delta in ["Sun", "light", " looks"] {
            follower.heard(&note(
                "item/agentMessage/delta",
                json!({"threadId":THREAD,"turnId":"t1","itemId":"msg_1","delta":delta}),
            ));
        }
        assert_eq!(text(&follower), Some("Sunlight looks"));
        // The finished message is the server's own text, whatever was heard before.
        follower.heard(&note(
            "item/completed",
            json!({"threadId":THREAD,"turnId":"t1","item":{"type":"agentMessage","id":"msg_1","text":"Sunlight looks white."}}),
        ));
        assert_eq!(text(&follower), Some("Sunlight looks white."));
        // A tool call in between leaves it; the next message replaces it.
        follower.heard(&note(
            "item/started",
            json!({"threadId":THREAD,"turnId":"t1","item":{"type":"commandExecution","id":"exec-1","command":"date"}}),
        ));
        assert_eq!(text(&follower), Some("Sunlight looks white."));
        follower.heard(&note(
            "item/started",
            json!({"threadId":THREAD,"turnId":"t1","item":{"type":"agentMessage","id":"msg_2","text":""}}),
        ));
        assert_eq!(text(&follower), Some(""));
        follower.changed = false;
        follower.heard(&note(
            "turn/completed",
            json!({"threadId":THREAD,"turn":{"id":"t1"}}),
        ));
        assert!(follower.reply.is_none() && follower.changed);
    }

    #[test]
    fn only_a_successful_matching_turn_commits_its_final_message() {
        let item = |phase: Option<&str>| match phase {
            Some(phase) => json!({"type":"agentMessage","id":"msg","text":"Answer","phase":phase}),
            None => json!({"type":"agentMessage","id":"msg","text":"Answer","phase":null}),
        };
        for (thread, phase, turn, status, expected) in [
            (THREAD, Some("final_answer"), "t1", "completed", true),
            (THREAD, None, "t1", "completed", true),
            (THREAD, Some("commentary"), "t1", "completed", false),
            (THREAD, Some("partial_answer"), "t1", "completed", false),
            (THREAD, Some("final_answer"), "t1", "failed", false),
            (THREAD, Some("final_answer"), "t1", "interrupted", false),
            (THREAD, Some("final_answer"), "old", "completed", false),
            ("child", Some("final_answer"), "t1", "completed", false),
        ] {
            let mut follower = joined();
            follower.heard(&note(
                "item/completed",
                json!({"threadId":thread,"turnId":turn,"item":item(phase)}),
            ));
            assert!(follower.completed.is_none());
            follower.heard(&note(
                "turn/completed",
                json!({"threadId":THREAD,"turn":{"id":"t1","status":status,"items":[]}}),
            ));
            assert_eq!(
                follower.completed.take(),
                expected.then(|| ("t1".into(), "Answer".into()))
            );
        }
        // A phaseless message followed by a tool call and no final answer is pre-tool commentary, not the final reply.
        let mut tool_after = joined();
        tool_after.heard(&note(
            "item/completed",
            json!({"threadId":THREAD,"turnId":"t1","item":item(None)}),
        ));
        tool_after.heard(&note(
            "item/started",
            json!({"threadId":THREAD,"turnId":"t1","item":{"type":"commandExecution","id":"exec-1","command":"ls"}}),
        ));
        tool_after.heard(&note(
            "turn/completed",
            json!({"threadId":THREAD,"turn":{"id":"t1","status":"completed","items":[]}}),
        ));
        assert!(tool_after.completed.is_none());

        let mut follower = joined();
        follower.heard(&note("turn/completed", json!({"threadId":THREAD,"turn":{"id":"t2","status":"completed","items":[item(Some("commentary")),item(Some("final_answer"))]}})));
        assert_eq!(
            follower.completed.take(),
            Some(("t2".into(), "Answer".into()))
        );
        let mut legacy = joined();
        legacy.heard(&note("turn/completed", json!({"threadId":THREAD,"turn":{"id":"t3","status":"completed","items":[item(None),{"type":"commandExecution","id":"e1"}]}})));
        assert!(legacy.completed.is_none());
        legacy.heard(&note("turn/completed", json!({"threadId":THREAD,"turn":{"id":"t4","status":"completed","items":[item(None),{"type":"reasoning","id":"r1"}]}})));
        assert_eq!(
            legacy.completed.take(),
            Some(("t4".into(), "Answer".into()))
        );
    }

    #[test]
    fn a_message_joined_halfway_waits_for_its_full_text() {
        let mut follower = joined();
        follower.heard(&note(
            "item/agentMessage/delta",
            json!({"threadId":THREAD,"turnId":"t1","itemId":"msg_1","delta":" the end"}),
        ));
        follower.heard(&note(
            "item/agentMessage/delta",
            json!({"threadId":THREAD,"turnId":"t1","itemId":"msg_1","delta":"."}),
        ));
        assert_eq!(text(&follower), None);
        follower.heard(&note(
            "item/completed",
            json!({"threadId":THREAD,"turnId":"t1","item":{"type":"agentMessage","id":"msg_1","text":"From the start to the end."}}),
        ));
        assert_eq!(text(&follower), Some("From the start to the end."));
    }

    #[test]
    fn joins_only_the_persons_conversation_and_never_answers_the_server() {
        let mut follower = Follower::default();
        // Codex's own short conversation (it names the session) and a sub-agent's are not followed.
        follower.heard(&note(
            "thread/started",
            json!({"thread":{"id":"own","ephemeral":true,"parentThreadId":null}}),
        ));
        let active = |id: &str| {
            note(
                "thread/status/changed",
                json!({"threadId":id,"status":{"type":"active"}}),
            )
        };
        assert!(follower.heard(&active("own")).is_empty());
        let asked = follower.heard(&active("child"));
        let left = follower.heard(
            &json!({"id":asked[0]["id"],"result":{"thread":{"id":"child","ephemeral":false,"parentThreadId":THREAD}}}).to_string(),
        );
        assert_eq!(left[0]["method"], "thread/unsubscribe");
        assert!(follower.heard(&active("child")).is_empty() && follower.joined.is_empty());

        // Before its first turn is on disk a conversation cannot be joined: ask again shortly after.
        let asked = follower.heard(&active(THREAD));
        assert!(
            follower.heard(&active(THREAD)).is_empty(),
            "one request at a time"
        );
        let none = follower.heard(
            &json!({"id":asked[0]["id"],"error":{"code":-32600,"message":"no rollout found"}})
                .to_string(),
        );
        assert!(none.is_empty() && follower.retries.len() == 1 && follower.joined.is_empty());

        // An approval request is the terminal UI's to answer.
        let request = json!({"id":0,"method":"item/commandExecution/requestApproval","params":{"threadId":THREAD}});
        assert!(follower.heard(&request.to_string()).is_empty());
        // Text of a conversation that was not joined is not shown.
        follower.heard(&note(
            "item/started",
            json!({"threadId":"child","item":{"type":"agentMessage","id":"m","text":"hidden"}}),
        ));
        assert!(follower.reply.is_none());
    }

    #[test]
    fn the_wait_is_adjustable_within_bounds_and_a_fallback_leaves_its_reason() {
        assert_eq!(wait(None), Duration::from_secs(WAIT_SECONDS));
        assert_eq!(wait(Some(" 12 ")), Duration::from_secs(12));
        assert_eq!(wait(Some("0")), Duration::from_secs(1));
        assert_eq!(wait(Some("600")), Duration::from_secs(45));
        assert_eq!(wait(Some("soon")), Duration::from_secs(WAIT_SECONDS));

        let scratch = tempfile::tempdir().unwrap();
        let journal = scratch.path().join("workspace.sqlite3");
        let (key, other) = (
            "00112233445566778899aabbccddeeff",
            "ffeeddccbbaa99887766554433221100",
        );
        assert_eq!(whole_reason(&journal, key), None);
        starts_whole(
            &journal,
            key,
            "Codex's app server did not listen within 30 seconds.\n",
        );
        assert_eq!(
            whole_reason(&journal, key).as_deref(),
            Some("Codex's app server did not listen within 30 seconds.")
        );
        assert_eq!(whole_reason(&journal, other), None);
        // The launch key is not in the file's name.
        let name = note_path(&journal, key);
        assert!(!name.to_str().unwrap().contains(key) && name.ends_with(name.file_name().unwrap()));
        assert!(!listening(&folder(&journal).join("1.sock")));
    }

    #[test]
    fn message_ids_fit_the_live_socket() {
        assert_eq!(reply_id("msg_006ea1e3612b"), "msg_006ea1e3612b");
        assert_eq!(reply_id("a b/c"), "a-b-c");
        assert_eq!(reply_id(""), "reply");
        assert!(crate::opencode_agent::valid_reply_id(&reply_id(
            &"é".repeat(300)
        )));
    }

    #[tokio::test]
    async fn feed_closes_the_live_socket_when_cleared() {
        use tokio::io::AsyncReadExt;

        let scratch = tempfile::tempdir().unwrap();
        let path = scratch.path().join("replies.sock");
        let listener = tokio::net::UnixListener::bind(&path).unwrap();
        let mut feed = Feed {
            path,
            key: "00112233445566778899aabbccddeeff".into(),
            socket: None,
        };
        let draft = Reply {
            thread: THREAD.into(),
            item: "msg_1".into(),
            text: "Partial answer".into(),
            whole: true,
        };
        feed.show(Some(&draft)).await;
        assert!(feed.socket.is_some());
        let (mut accepted, _) = listener.accept().await.unwrap();
        feed.show(None).await;
        assert!(feed.socket.is_none());
        let mut received = String::new();
        accepted.read_to_string(&mut received).await.unwrap();
        assert!(received.contains("\"Partial answer\""));
    }
}
