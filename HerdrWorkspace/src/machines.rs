//! `/api/machines`: the other machines this server's Herdr Core reaches over SSH, for an app's screen of servers
//! where projects live (`projects`).
//!
//! Core owns the machines. The list, a reconnect and a removal are Core's own calls (`machine.list`,
//! `machine.connect`, `machine.rm`). Adding one runs `hc machine add TARGET --install`, because copying Herdr's
//! helper program to the other machine is the command's work, not Core's. `hc` and the OpenSSH tools come from
//! the workspace's `PATH`; each gets fixed arguments and no shell, has a time limit, and never gets a terminal, so
//! nothing can stop to ask a question.
//!
//! SSH logs in with a key or not at all: no route takes a password or a code. A host that ssh on this server has
//! never connected to is not trusted silently. The first try answers `unknown_host_key` with the fingerprints the
//! host shows; a second try that names one of them in `accept_host_key` files that key in the account's
//! known-hosts file, and ssh then holds the host to it. A host whose key differs from the one on file is refused.

use crate::{
    Workspace,
    core::{self, Failure},
    skillshare::{Ran, Trouble, run_program},
};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use ssh::{HostKey, Resolved, Standing};
use std::{
    env,
    ffi::{CStr, OsStr},
    fs,
    os::unix::{
        ffi::OsStrExt,
        fs::{DirBuilderExt, PermissionsExt},
    },
    path::{Path, PathBuf},
    time::Duration,
};
use tokio::sync::Mutex;

mod ssh;

const ASK_TIMEOUT: Duration = Duration::from_secs(15);
const SCAN_TIMEOUT: Duration = Duration::from_secs(25);
/// Adding dials the machine, and may copy the helper program there and start it.
const ADD_TIMEOUT: Duration = Duration::from_secs(300);
const KEYGEN_TIMEOUT: Duration = Duration::from_secs(30);

const ADD_SHAPE: &str = "Send target: how ssh reaches the server, such as deploy@10.0.0.7 or deploy@10.0.0.7:2222. Optionally name (what to call it here) and accept_host_key (a fingerprint this route offered).";
const TARGET_SHAPE: &str = "Write the server the way ssh takes it, as one word: deploy@10.0.0.7, deploy@10.0.0.7:2222, or a Host from the Herdr server's ~/.ssh/config.";
const NAME_SHAPE: &str = "Use 1–32 lowercase letters, digits, dots, dashes or underscores for the name, starting with a letter or digit, and not a name like t7.";
const PRINT_SHAPE: &str =
    "Send accept_host_key exactly as this route gave it: SHA256: and 43 characters.";
const NAMED_SHAPE: &str = "Send name: a machine's name from the list.";
const WHERE_TO_PASTE: &str = "On the project server, add this line to ~/.ssh/authorized_keys of the account the Herdr server logs in as.";
const INSTALLS: &str = "Adding a server copies Herdr's helper program (herdr-core) to ~/.local/bin of that account there when it is missing or too old, and starts it. Nothing else is installed.";

/// One change at a time: the machines, the known-hosts file and the key pair.
static CHANGES: Mutex<()> = Mutex::const_new(());

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/machines", get(list).post(add))
        .route("/api/machines/remove", post(remove))
        .route("/api/machines/connect", post(connect))
        .route("/api/machines/ssh-key", get(keys).post(create_key))
}

fn refused(status: StatusCode, kind: &str, error: &str) -> Response {
    (status, Json(json!({ "error": error, "kind": kind }))).into_response()
}

/// An answer that ends a request early. Boxed: a response is large beside what the same calls return when all
/// is well.
type Refusal = Box<Response>;

fn boxed(status: StatusCode, kind: &str, error: &str) -> Refusal {
    Box::new(refused(status, kind, error))
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
            "interrupted",
            "The workspace could not finish this. Load the list again to see what changed.",
        )
    })
}

/// A program on the workspace's `PATH`.
fn tool(name: &str) -> Result<PathBuf, String> {
    env::var_os("PATH")
        .and_then(|folders| {
            env::split_paths(&folders)
                .filter(|folder| folder.is_absolute())
                .map(|folder| folder.join(name))
                .find(|path| {
                    fs::metadata(path)
                        .is_ok_and(|file| file.is_file() && file.permissions().mode() & 0o111 != 0)
                })
        })
        .ok_or_else(|| {
            format!(
                "The workspace cannot find `{name}` on its PATH. Install it on the Herdr server, or start the workspace with a PATH that reaches it."
            )
        })
}

/// Herdr Core's own command, under either of its names.
pub(crate) fn hc() -> Result<PathBuf, String> {
    tool("hc").or_else(|_| tool("herdr-core"))
}

/// The account's home folder as ssh finds it: from the account, not from `HOME`.
fn home() -> Option<PathBuf> {
    let mut entry = std::mem::MaybeUninit::<libc::passwd>::uninit();
    let mut text = vec![0 as libc::c_char; 16 * 1024];
    let mut found = std::ptr::null_mut();
    // SAFETY: each pointer is to a live buffer of the size given, and the entry is read only when the call found one.
    let folder = unsafe {
        let status = libc::getpwuid_r(
            libc::getuid(),
            entry.as_mut_ptr(),
            text.as_mut_ptr(),
            text.len(),
            &mut found,
        );
        (status == 0 && !found.is_null() && !(*found).pw_dir.is_null()).then(|| {
            PathBuf::from(OsStr::from_bytes(
                CStr::from_ptr((*found).pw_dir).to_bytes(),
            ))
        })
    };
    folder
        .or_else(|| env::var_os("HOME").map(PathBuf::from))
        .filter(|folder| folder.is_absolute())
}

async fn run(
    program: PathBuf,
    arguments: Vec<String>,
    env: Vec<(&'static str, String)>,
    limit: Duration,
) -> Result<Ran, Trouble> {
    tokio::task::spawn_blocking(move || {
        let env: Vec<(&str, &str)> = env
            .iter()
            .map(|(name, value)| (*name, value.as_str()))
            .collect();
        run_program(&program, &arguments, &env, limit)
    })
    .await
    .unwrap_or(Err(Trouble::Start))
}

fn words(arguments: &[&str]) -> Vec<String> {
    arguments.iter().map(|&word| word.to_owned()).collect()
}

/// `deploy@box:2222`, as people write a port, in the form ssh takes it. Core does the same to what it is given.
fn ssh_form(target: &str) -> String {
    let host = target.rsplit_once('@').map_or(target, |(_, host)| host);
    match host.split_once(':') {
        Some((name, port))
            if !target.starts_with("ssh://")
                && !name.is_empty()
                && !port.is_empty()
                && port.bytes().all(|b| b.is_ascii_digit()) =>
        {
            format!("ssh://{target}")
        }
        _ => target.to_owned(),
    }
}

/// What ssh on this server would do for `target`. An error is the reason in words for the workspace's owner.
async fn resolve(target: &str) -> Result<Resolved, String> {
    let home = home().ok_or("The workspace cannot find its account's home folder.")?;
    let asked = run(
        tool("ssh")?,
        words(&["-G", &ssh_form(target)]),
        Vec::new(),
        ASK_TIMEOUT,
    )
    .await;
    match asked {
        Ok(ran) if ran.ok => ssh::resolved(&ran.out, &home)
            .ok_or_else(|| format!("ssh could not say where {target} is.")),
        Ok(ran) => Err(last_line(&ran.err)
            .unwrap_or("ssh does not accept this target")
            .to_owned()),
        Err(_) => Err("ssh did not answer.".into()),
    }
}

fn last_line(text: &str) -> Option<&str> {
    text.lines().map(str::trim).rfind(|line| !line.is_empty())
}

/// How the host of `target` stands with ssh on this server: the keys on file for it against the keys it shows now.
async fn look(target: &str) -> Result<(Resolved, Standing), String> {
    let resolved = resolve(target).await?;
    if resolved.proxied {
        return Err(format!(
            "{target} is reached through another host, so its key cannot be read from here"
        ));
    }
    let name = resolved.known_name();
    let keygen = tool("ssh-keygen")?;
    let mut known: Vec<HostKey> = Vec::new();
    for file in resolved
        .user_known_hosts
        .iter()
        .chain(&resolved.global_known_hosts)
        .filter(|file| file.is_file())
    {
        let Some(file) = file.to_str() else {
            continue;
        };
        // It exits with 1 and prints nothing when the host is not in the file.
        if let Ok(ran) = run(
            keygen.clone(),
            words(&["-F", &name, "-f", file]),
            Vec::new(),
            ASK_TIMEOUT,
        )
        .await
        {
            known.extend(ssh::host_keys(&ran.out));
        }
    }
    let port = resolved.port.to_string();
    let scanned = run(
        tool("ssh-keyscan")?,
        words(&["-T", "8", "-p", &port, &resolved.hostname]),
        Vec::new(),
        SCAN_TIMEOUT,
    )
    .await
    .map_err(|_| format!("{} did not show its key in time", resolved.hostname))?;
    let shown = ssh::host_keys(&scanned.out);
    if shown.is_empty() {
        return Err(format!(
            "{} port {port} did not show a host key",
            resolved.hostname
        ));
    }
    let standing = ssh::standing(&known, &shown);
    Ok((resolved, standing))
}

fn prints(keys: &[HostKey]) -> Vec<Value> {
    keys.iter()
        .map(|key| json!({"type": key.kind, "fingerprint": key.fingerprint()}))
        .collect()
}

fn changed_key(resolved: &Resolved) -> Response {
    let name = resolved.known_name();
    refused(
        StatusCode::CONFLICT,
        "host_key_changed",
        &format!(
            "{name} shows a different host key from the one the Herdr server has on file for it. A reinstalled server does that, and so does someone in between. The workspace will not replace the key. If you know why it changed, run `ssh-keygen -R '{name}'` on the Herdr server, then add the server again."
        ),
    )
}

fn unknown_key(target: &str, resolved: &Resolved, keys: &[HostKey], lead: &str) -> Response {
    (
        StatusCode::CONFLICT,
        Json(json!({
            "kind": "unknown_host_key",
            "error": format!("{lead} Compare a fingerprint below with the server's own (on the server: ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub). If it matches, add {target} again with accept_host_key set to it."),
            "host": resolved.known_name(),
            "host_keys": prints(keys),
        })),
    )
        .into_response()
}

/// The answer when ssh refused a host's key while adding `target`.
async fn host_key_refusal(target: &str) -> Response {
    match look(target).await {
        Ok((resolved, Standing::Unknown(keys))) => unknown_key(
            target,
            &resolved,
            &keys,
            "The Herdr server has not connected to this server before, so it does not know its host key.",
        ),
        Ok((resolved, Standing::Changed)) => changed_key(&resolved),
        Ok((_, Standing::Trusted)) => refused(
            StatusCode::BAD_GATEWAY,
            "unreachable",
            &format!(
                "ssh refused the host key of {target}, although a key it shows is on file. Run `ssh {target}` on the Herdr server to see why."
            ),
        ),
        Err(why) => refused(
            StatusCode::CONFLICT,
            "unknown_host_key",
            &format!(
                "The Herdr server does not know the host key of {target}, and the workspace could not read it to show you: {why}. On the Herdr server, run `ssh {target}` once and answer ssh's question, then add the server again."
            ),
        ),
    }
}

/// Files the key with this fingerprint for the host of `target`, when the host shows it and no key is on file yet.
async fn trust(target: &str, print: &str) -> Result<(), Refusal> {
    let (resolved, standing) = look(target).await.map_err(|why| {
        boxed(
            StatusCode::BAD_GATEWAY,
            "unreachable",
            &format!("The workspace could not read the host key of {target}: {why}. Nothing was trusted or added."),
        )
    })?;
    let keys = match standing {
        Standing::Trusted => return Ok(()),
        Standing::Changed => return Err(Box::new(changed_key(&resolved))),
        Standing::Unknown(keys) => keys,
    };
    let Some(key) = keys.iter().find(|key| key.fingerprint() == print) else {
        return Err(Box::new(unknown_key(
            target,
            &resolved,
            &keys,
            "This server does not show a host key with the fingerprint you accepted. Nothing was trusted or added.",
        )));
    };
    let Some(file) = resolved.user_known_hosts.first().cloned() else {
        return Err(boxed(
            StatusCode::BAD_GATEWAY,
            "unknown_host_key",
            &format!(
                "ssh's configuration on the Herdr server names no known-hosts file the workspace can write for {target}. Run `ssh {target}` there once and answer ssh's question, then add the server again."
            ),
        ));
    };
    let (name, key) = (resolved.known_name(), key.clone());
    let written = {
        let file = file.clone();
        tokio::task::spawn_blocking(move || ssh::trust(&file, &name, &key)).await
    };
    match written {
        Ok(Ok(())) => Ok(()),
        _ => Err(boxed(
            StatusCode::INTERNAL_SERVER_ERROR,
            "unknown_host_key",
            &format!(
                "The workspace could not write {}. Nothing was trusted or added.",
                file.display()
            ),
        )),
    }
}

/// A machine as an app shows it.
#[derive(Serialize)]
struct View {
    name: String,
    /// How ssh reaches it, as it was added.
    target: String,
    /// What the machine calls itself.
    host: String,
    /// Its Herdr helper's version when last seen.
    version: String,
    session: Option<String>,
    /// Reached with a command of the owner's own instead of ssh (`hc machine add --via`).
    via: bool,
    temporary: bool,
    /// connecting, connected, needs_login, needs_update or unreachable.
    state: String,
    reachable: bool,
    /// Since when it is not connected, in milliseconds since 1970.
    since_ms: Option<u64>,
    /// Core's reason when it is unreachable.
    why: Option<String>,
    /// `false` when programs there stop at logout; `null` when Core does not know.
    keeps_running_after_logout: Option<bool>,
    /// What a person should know or do about this machine, in whole sentences.
    warnings: Vec<String>,
    /// The names of the projects on it.
    projects: Vec<String>,
}

impl View {
    fn new(machine: core::Machine, projects: Vec<String>) -> Self {
        let name = &machine.name;
        let mut warnings = Vec::new();
        match machine.state.as_str() {
            "needs_login" => warnings.push(format!(
                "{name} refuses the Herdr server's SSH key. Add the Herdr server's public key to ~/.ssh/authorized_keys of that account on {name}, then connect again. Herdr also tries again by itself, at first after 2 minutes."
            )),
            "needs_update" => warnings.push(format!(
                "Herdr's helper on {name} is too old to talk to. Run `hc machine update {name}` on the Herdr server."
            )),
            "unreachable" => {
                // Core's reason starts with its own "cannot reach TARGET: ".
                let said = machine.why.as_deref().map(|why| {
                    why.strip_prefix(&format!("cannot reach {}: ", machine.target))
                        .unwrap_or(why)
                });
                warnings.push(format!(
                    "{name} cannot be reached now{}. Herdr keeps trying.",
                    said.map(|said| format!(" ({said})")).unwrap_or_default()
                ));
            }
            _ => {}
        }
        if machine.keeps_running_after_logout == Some(false) {
            let user = machine.logout_linger_user.as_deref().unwrap_or("<user>");
            warnings.push(format!(
                "Programs started on {name} stop when the last login there ends. To keep them running, run this on {name} once: sudo loginctl enable-linger -- {user}"
            ));
        }
        Self {
            reachable: machine.state == "connected",
            name: machine.name,
            target: machine.target,
            host: machine.host,
            version: machine.version,
            session: machine.session,
            via: machine.via,
            temporary: machine.temporary,
            state: machine.state,
            since_ms: machine.since_ms,
            why: machine.why,
            keeps_running_after_logout: machine.keeps_running_after_logout,
            warnings,
            projects,
        }
    }
}

async fn views(w: &Workspace) -> Result<Vec<View>, Refusal> {
    let machines = w
        .core
        .machines()
        .await
        .map_err(|failure| Box::new(failure.into_response()))?;
    let mut projects = crate::projects::names_by_machine(&w.history)
        .map_err(|error| Box::new(error.into_response()))?;
    Ok(machines
        .into_iter()
        .map(|machine| {
            let projects = projects.remove(&machine.name).unwrap_or_default();
            View::new(machine, projects)
        })
        .collect())
}

/// Everything the machine list carries besides the machines.
fn listing(machines: Vec<View>) -> Value {
    // Why a server cannot be added from here as things are; `null` when it can.
    let problem = hc().and(tool("ssh")).err();
    json!({ "machines": machines, "can_add": problem.is_none(), "problem": problem, "adding": INSTALLS })
}

async fn list(State(w): State<Workspace>) -> Response {
    match views(&w).await {
        Ok(machines) => Json(listing(machines)).into_response(),
        Err(response) => *response,
    }
}

/// What `hc … --json` printed for a failure: Core's kind, message and hint.
fn hc_error(stderr: &str) -> Option<(String, String, String)> {
    stderr.lines().rev().find_map(|line| {
        let error = serde_json::from_str::<Value>(line).ok()?;
        let text = |field: &str| error["error"][field].as_str().map(str::to_owned);
        Some((
            text("kind")?,
            text("message")?,
            text("hint").unwrap_or_default(),
        ))
    })
}

/// Why a machine was not added, for the app to act on: a status, a kind and words for a person. `None` when the
/// host's key is the reason, which takes another look at the host.
fn add_refusal(
    target: &str,
    kind: &str,
    message: &str,
    hint: &str,
) -> Option<(StatusCode, &'static str, String)> {
    let said = |words: &str| message.contains(words);
    Some(match kind {
        "unreachable" if said("Host key verification failed") => return None,
        "unreachable" if said("Could not resolve hostname") => (
            StatusCode::BAD_GATEWAY,
            "unreachable",
            format!("The Herdr server finds no server by the name in {target}. Check the address."),
        ),
        "unreachable" => (
            StatusCode::BAD_GATEWAY,
            "unreachable",
            format!(
                "The Herdr server could not reach {target}. ssh said: {}",
                message
                    .strip_prefix(&format!("cannot reach {}: ", ssh_form(target)))
                    .unwrap_or(message)
            ),
        ),
        "needs_login" => (
            StatusCode::CONFLICT,
            "login_refused",
            format!(
                "{target} refused the Herdr server's SSH key. Add the Herdr server's public key to ~/.ssh/authorized_keys of that account there, then add the server again. Passwords and one-time codes are not used here."
            ),
        ),
        "hc_missing" | "incompatible" | "install_failed" => (
            StatusCode::BAD_GATEWAY,
            "helper_not_installed",
            format!(
                "The Herdr server logged in to {target}, but Herdr's helper program could not be installed there. Herdr said: {message}{}",
                if hint.is_empty() {
                    ".".to_owned()
                } else {
                    format!(" ({hint}).")
                }
            ),
        ),
        "name_taken" => (
            StatusCode::CONFLICT,
            "name_taken",
            "A machine with this name is already added. Choose another name.".into(),
        ),
        "already_added" => (
            StatusCode::CONFLICT,
            "already_added",
            format!("This server is already added: {message}."),
        ),
        "invalid_params" => (
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid",
            message.to_owned(),
        ),
        _ => (
            StatusCode::BAD_GATEWAY,
            "failed",
            format!("Herdr could not add {target}: {message}. {hint}"),
        ),
    })
}

async fn add(State(w): State<Workspace>, body: Bytes) -> Response {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Wanted {
        target: String,
        name: Option<String>,
        accept_host_key: Option<String>,
    }
    let invalid = |shape: &str| refused(StatusCode::UNPROCESSABLE_ENTITY, "invalid", shape);
    let Ok(wanted) = serde_json::from_slice::<Wanted>(&body) else {
        return invalid(ADD_SHAPE);
    };
    if !ssh::valid_target(&wanted.target) {
        return invalid(TARGET_SHAPE);
    }
    if wanted
        .name
        .as_deref()
        .is_some_and(|name| !ssh::valid_name(name))
    {
        return invalid(NAME_SHAPE);
    }
    if wanted.accept_host_key.as_deref().is_some_and(|print| {
        print.len() != 50
            || !print.starts_with("SHA256:")
            || !print[7..]
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/')
    }) {
        return invalid(PRINT_SHAPE);
    }
    alone(async move {
        let unavailable = |problem: String| refused(StatusCode::SERVICE_UNAVAILABLE, "unavailable", &problem);
        let hc = match hc() {
            Ok(hc) => hc,
            Err(problem) => return unavailable(problem),
        };
        let Some(socket) = w.core.0.to_str().map(str::to_owned) else {
            return unavailable("Herdr Core's socket path is not UTF-8.".into());
        };
        let target = wanted.target;
        if let Some(print) = &wanted.accept_host_key
            && let Err(response) = trust(&target, print).await
        {
            return *response;
        }
        let mut arguments = words(&["machine", "add", &target, "--install", "--json"]);
        if let Some(name) = &wanted.name {
            arguments.extend(words(&["--name", name]));
        }
        let ran = match run(hc, arguments, vec![("HC_SOCKET", socket)], ADD_TIMEOUT).await {
            Ok(ran) => ran,
            Err(Trouble::Slow(limit)) => {
                return refused(
                    StatusCode::GATEWAY_TIMEOUT,
                    "timeout",
                    &format!(
                        "Adding {target} took longer than {} seconds and was stopped. It may be half done: load the list again.",
                        limit.as_secs()
                    ),
                );
            }
            Err(_) => return unavailable("The workspace could not run `hc`.".into()),
        };
        if !ran.ok {
            let (kind, message, hint) = hc_error(&ran.err).unwrap_or_else(|| {
                (
                    "failed".into(),
                    last_line(&ran.err).unwrap_or("hc failed without saying why").to_owned(),
                    String::new(),
                )
            });
            return match add_refusal(&target, &kind, &message, &hint) {
                Some((status, kind, error)) => refused(status, kind, error.trim()),
                None => host_key_refusal(&target).await,
            };
        }
        let Ok(added) = serde_json::from_str::<core::Machine>(ran.out.trim()) else {
            return refused(
                StatusCode::BAD_GATEWAY,
                "failed",
                "Herdr added the server but did not say so in a way the workspace understands. Load the list again.",
            );
        };
        // The command says so when it copied the helper: "<target> now has <version>".
        let helper_installed = ran.err.lines().any(|line| line.contains(" now has "));
        let name = added.name.clone();
        // Core starts its own line to the machine after adding it. Wait for that, so the answer says how it went.
        let machine = w
            .core
            .dial_machine(&name)
            .await
            .unwrap_or_else(|_| core::Machine {
                state: "connecting".into(),
                ..added
            });
        let machine = View::new(machine, Vec::new());
        let message = if helper_installed {
            format!(
                "Added {name}. Herdr's helper program ({}) was copied to ~/.local/bin on it and started.",
                machine.version
            )
        } else {
            format!(
                "Added {name}. Herdr's helper program was already there ({}).",
                machine.version
            )
        };
        (
            StatusCode::CREATED,
            Json(json!({ "machine": machine, "helper_installed": helper_installed, "message": message })),
        )
            .into_response()
    })
    .await
}

fn named(body: &Bytes) -> Result<String, Refusal> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Named {
        name: String,
    }
    match serde_json::from_slice(body) {
        Ok(Named { name }) if ssh::valid_name(&name) => Ok(name),
        _ => Err(boxed(
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid",
            NAMED_SHAPE,
        )),
    }
}

fn no_such_machine(failure: Failure, name: &str) -> Response {
    match failure {
        Failure::Rejected(kind, _) if kind == "machine_unknown" => refused(
            StatusCode::NOT_FOUND,
            "machine_unknown",
            &format!("Herdr has no machine named {name}. Load the list again."),
        ),
        failure => failure.into_response(),
    }
}

/// Makes Herdr forget a machine. What runs there keeps running, and Herdr's helper stays installed there.
async fn remove(State(w): State<Workspace>, body: Bytes) -> Response {
    let name = match named(&body) {
        Ok(name) => name,
        Err(response) => return *response,
    };
    alone(async move {
        let projects = match crate::projects::names_by_machine(&w.history) {
            Ok(mut projects) => projects.remove(&name).unwrap_or_default(),
            Err(error) => return error.into_response(),
        };
        if !projects.is_empty() {
            return (
                StatusCode::CONFLICT,
                Json(json!({
                    "kind": "has_projects",
                    "error": format!("{name} still has projects: {}. Remove them or move them to another server first.", projects.join(", ")),
                    "projects": projects,
                })),
            )
                .into_response();
        }
        if let Err(failure) = w.core.forget_machine(&name).await {
            return no_such_machine(failure, &name);
        }
        match views(&w).await {
            Ok(machines) => {
                let mut listing = listing(machines);
                listing["removed"] = name.into();
                Json(listing).into_response()
            }
            Err(response) => *response,
        }
    })
    .await
}

/// Has Herdr dial a machine now instead of at its next try, for after its owner fixed the login.
async fn connect(State(w): State<Workspace>, body: Bytes) -> Response {
    let name = match named(&body) {
        Ok(name) => name,
        Err(response) => return *response,
    };
    let machine = match w.core.dial_machine(&name).await {
        Ok(machine) => machine,
        Err(failure) => return no_such_machine(failure, &name),
    };
    let projects = match crate::projects::names_by_machine(&w.history) {
        Ok(mut projects) => projects.remove(&name).unwrap_or_default(),
        Err(error) => return error.into_response(),
    };
    Json(json!({ "machine": View::new(machine, projects) })).into_response()
}

/// Whether this server has no key pair that ssh would try by itself, so that one may be made.
fn none_yet(folder: &Path) -> bool {
    ssh::default_identities(folder)
        .iter()
        .all(|file| !file.exists())
        && !folder.join("id_ed25519.pub").exists()
}

async fn shown_keys(target: Option<String>) -> Response {
    let Some(folder) = home().map(|home| home.join(".ssh")) else {
        return refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            "unavailable",
            "The workspace cannot find its account's home folder.",
        );
    };
    // For one target, the files ssh's configuration names for it; otherwise the ones ssh tries by itself.
    let (files, problem) = match &target {
        Some(target) => match resolve(target).await {
            Ok(resolved) => (resolved.identity_files, None),
            Err(why) => (
                ssh::default_identities(&folder),
                Some(format!(
                    "ssh could not say which key it would use for {target} ({why}), so these are the keys it uses by default."
                )),
            ),
        },
        None => (ssh::default_identities(&folder), None),
    };
    let read = {
        let folder = folder.clone();
        tokio::task::spawn_blocking(move || (ssh::public_keys(&files), none_yet(&folder))).await
    };
    let Ok((keys, none_yet)) = read else {
        return refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            "unavailable",
            "The workspace could not read the SSH keys.",
        );
    };
    Json(json!({
        "keys": keys,
        // True when this server has no key pair of its own yet and `POST` here would make one.
        "can_create": none_yet,
        "where_to_paste": WHERE_TO_PASTE,
        "problem": problem,
    }))
    .into_response()
}

/// The public keys the Herdr server offers when it logs in elsewhere. Never a private key: those files are only
/// looked for, not opened.
async fn keys(Query(query): Query<KeyQuery>) -> Response {
    match query.target {
        Some(target) if !ssh::valid_target(&target) => {
            refused(StatusCode::UNPROCESSABLE_ENTITY, "invalid", TARGET_SHAPE)
        }
        target => shown_keys(target).await,
    }
}

#[derive(Deserialize)]
struct KeyQuery {
    target: Option<String>,
}

fn host_name() -> String {
    let name: String = fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .filter(|name| !name.trim().is_empty())
        .unwrap_or_else(crate::platform::host_name)
        .trim()
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-'))
        .take(64)
        .collect();
    if name.is_empty() {
        "herdr".into()
    } else {
        name
    }
}

/// Makes an Ed25519 key pair without a passphrase in `folder` under the name ssh tries by itself, so that Core's
/// plain `ssh` uses it with no configuration. The private key is readable by the account alone.
fn create_pair(keygen: &Path, folder: &Path, comment: &str) -> Result<(), String> {
    if !none_yet(folder) {
        return Err("exists".into());
    }
    if !folder.exists() {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(folder)
            .map_err(|_| format!("The workspace could not make {}.", folder.display()))?;
    }
    let private = folder.join("id_ed25519");
    let file = private
        .to_str()
        .ok_or("The account's home folder is not UTF-8.")?;
    let made = run_program(
        keygen,
        &words(&["-q", "-t", "ed25519", "-N", "", "-C", comment, "-f", file]),
        &[],
        KEYGEN_TIMEOUT,
    );
    match made {
        Ok(ran) if ran.ok => fs::set_permissions(&private, fs::Permissions::from_mode(0o600))
            .map_err(|_| format!("The workspace could not protect {file}.")),
        Ok(ran) => Err(format!(
            "ssh-keygen could not make the key: {}",
            last_line(&ran.err).unwrap_or("it did not say why")
        )),
        Err(_) => Err("ssh-keygen did not finish.".into()),
    }
}

/// Makes this server's key pair when it has none, and answers like `GET`.
async fn create_key() -> Response {
    alone(async {
        let Some(folder) = home().map(|home| home.join(".ssh")) else {
            return refused(
                StatusCode::INTERNAL_SERVER_ERROR,
                "unavailable",
                "The workspace cannot find its account's home folder.",
            );
        };
        let keygen = match tool("ssh-keygen") {
            Ok(keygen) => keygen,
            Err(problem) => return refused(StatusCode::SERVICE_UNAVAILABLE, "unavailable", &problem),
        };
        let comment = format!("swarmhub@{}", host_name());
        let made =
            tokio::task::spawn_blocking(move || create_pair(&keygen, &folder, &comment)).await;
        match made {
            Ok(Ok(())) => {
                let mut response = shown_keys(None).await;
                *response.status_mut() = StatusCode::CREATED;
                response
            }
            Ok(Err(why)) if why == "exists" => refused(
                StatusCode::CONFLICT,
                "key_exists",
                "This server already has an SSH key of its own. Use that one; the workspace does not replace keys.",
            ),
            Ok(Err(why)) => refused(StatusCode::INTERNAL_SERVER_ERROR, "failed", &why),
            Err(_) => refused(
                StatusCode::INTERNAL_SERVER_ERROR,
                "failed",
                "The workspace could not make the key.",
            ),
        }
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_port_is_given_to_ssh_the_way_core_gives_it() {
        assert_eq!(
            ssh_form("deploy@10.0.0.7:2222"),
            "ssh://deploy@10.0.0.7:2222"
        );
        assert_eq!(ssh_form("box:2222"), "ssh://box:2222");
        for unchanged in [
            "box",
            "deploy@box",
            "ssh://deploy@box:2222",
            "me@fe80::1",
            "me@box:",
        ] {
            assert_eq!(ssh_form(unchanged), unchanged);
        }
    }

    #[test]
    fn reads_the_error_hc_prints_and_says_what_a_person_can_do() {
        let printed = "box now has hc 0.1.21\n{\"error\":{\"hint\":\"check that `ssh me@box` logs in without a password prompt (keys or an agent)\",\"kind\":\"unreachable\",\"message\":\"cannot reach me@box: ssh: connect to host box port 22: Connection refused\"}}\n";
        let (kind, message, hint) = hc_error(printed).unwrap();
        assert_eq!(kind, "unreachable");
        assert!(hint.starts_with("check that"));
        let (status, kind, error) = add_refusal("me@box", &kind, &message, &hint).unwrap();
        assert_eq!((status, kind), (StatusCode::BAD_GATEWAY, "unreachable"));
        assert_eq!(
            error,
            "The Herdr server could not reach me@box. ssh said: ssh: connect to host box port 22: Connection refused"
        );
        assert_eq!(hc_error("error: plain words\n"), None);

        let kind_of = |kind: &str, message: &str| {
            add_refusal("me@box", kind, message, "")
                .map(|(status, kind, _)| (status.as_u16(), kind))
        };
        // The host's key takes another look at the host before anything is said.
        assert_eq!(
            kind_of(
                "unreachable",
                "cannot reach me@box: Host key verification failed."
            ),
            None
        );
        assert_eq!(
            kind_of(
                "unreachable",
                "cannot reach me@box: ssh: Could not resolve hostname box: Name or service not known"
            ),
            Some((502, "unreachable"))
        );
        assert_eq!(
            kind_of(
                "needs_login",
                "me@box wants a login typed by a person (a password or a code)"
            ),
            Some((409, "login_refused"))
        );
        for kind in ["hc_missing", "incompatible", "install_failed"] {
            assert_eq!(kind_of(kind, "x"), Some((502, "helper_not_installed")));
        }
        let (_, _, error) = add_refusal(
            "me@box",
            "install_failed",
            "on me@box: this hc does not run there",
            "nothing was changed there",
        )
        .unwrap();
        assert!(error.ends_with(
            "Herdr said: on me@box: this hc does not run there (nothing was changed there)."
        ));
        assert_eq!(kind_of("name_taken", "x"), Some((409, "name_taken")));
        assert_eq!(kind_of("already_added", "x"), Some((409, "already_added")));
        assert_eq!(kind_of("invalid_params", "x"), Some((422, "invalid")));
        assert_eq!(kind_of("internal", "x"), Some((502, "failed")));
    }

    #[test]
    fn a_machine_view_carries_cores_warnings_in_words() {
        let machine = |state: &str, keeps: Option<bool>| -> core::Machine {
            serde_json::from_value(json!({
                "name": "box", "target": "deploy@10.0.0.7", "id": "c1", "host": "box-1", "version": "hc 0.1.21",
                "session": null, "state": state, "why": (state == "unreachable").then_some("cannot reach deploy@10.0.0.7: ssh: connect to host 10.0.0.7 port 22: Connection refused"),
                "since_ms": (state != "connected").then_some(5), "keeps_running_after_logout": keeps,
                "logout_linger_user": "deploy",
            }))
            .unwrap()
        };
        let fine = serde_json::to_value(View::new(
            machine("connected", Some(true)),
            vec!["shop".into()],
        ))
        .unwrap();
        assert_eq!(fine["reachable"], true);
        assert_eq!(fine["warnings"], json!([]));
        assert_eq!(fine["projects"], json!(["shop"]));
        assert_eq!(fine["target"], "deploy@10.0.0.7");

        let lingering = View::new(machine("connected", Some(false)), Vec::new());
        assert_eq!(lingering.warnings.len(), 1);
        assert!(lingering.warnings[0].ends_with("sudo loginctl enable-linger -- deploy"));

        let refused = View::new(machine("needs_login", None), Vec::new());
        assert!(!refused.reachable && refused.warnings[0].contains("authorized_keys"));
        let down = View::new(machine("unreachable", Some(false)), Vec::new());
        assert_eq!(
            down.warnings[0],
            "box cannot be reached now (ssh: connect to host 10.0.0.7 port 22: Connection refused). Herdr keeps trying."
        );
        assert_eq!((down.warnings.len(), down.since_ms), (2, Some(5)));
        // The answer to adding a machine has no state yet.
        let added: core::Machine = serde_json::from_value(json!({
            "name": "box", "target": "x", "id": "c1", "host": "h", "version": "v", "session": null
        }))
        .unwrap();
        assert_eq!(added.state, "");
    }

    #[test]
    fn makes_a_key_pair_only_where_there_is_none_and_keeps_the_private_half_private() {
        let Ok(keygen) = tool("ssh-keygen") else {
            return;
        };
        let scratch = tempfile::tempdir().unwrap();
        let folder = scratch.path().join(".ssh");
        assert!(none_yet(&folder));
        create_pair(&keygen, &folder, "swarmhub@test").unwrap();
        let mode = |path: &Path| fs::metadata(path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&folder), 0o700);
        assert_eq!(mode(&folder.join("id_ed25519")), 0o600);
        let private = fs::read_to_string(folder.join("id_ed25519")).unwrap();
        assert!(private.starts_with("-----BEGIN OPENSSH PRIVATE KEY-----"));
        // No passphrase: ssh must be able to use it without a person. This reads the key with an empty one.
        let file = folder.join("id_ed25519").to_str().unwrap().to_owned();
        let opened = run_program(
            &keygen,
            &words(&["-y", "-P", "", "-f", &file]),
            &[],
            KEYGEN_TIMEOUT,
        );
        assert!(opened.is_ok_and(|ran| ran.ok && ran.out.starts_with("ssh-ed25519 ")));
        let keys = ssh::public_keys(&ssh::default_identities(&folder));
        assert_eq!(keys.len(), 1);
        assert_eq!(
            (keys[0].kind.as_str(), keys[0].comment.as_str()),
            ("ssh-ed25519", "swarmhub@test")
        );
        assert!(keys[0].fingerprint.starts_with("SHA256:") && keys[0].fingerprint.len() == 50);
        assert!(
            !serde_json::to_string(&keys)
                .unwrap()
                .contains("PRIVATE KEY")
        );
        // A second call leaves the pair alone.
        assert!(!none_yet(&folder));
        assert_eq!(
            create_pair(&keygen, &folder, "other").unwrap_err(),
            "exists"
        );
        assert_eq!(
            fs::read_to_string(folder.join("id_ed25519")).unwrap(),
            private
        );
        // A key of another kind that ssh would use by itself also counts.
        let other = scratch.path().join("other");
        fs::create_dir(&other).unwrap();
        fs::write(other.join("id_rsa"), "x").unwrap();
        assert_eq!(create_pair(&keygen, &other, "c").unwrap_err(), "exists");
    }
}
