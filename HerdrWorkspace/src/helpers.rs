//! Helper agents: a running agent hands one task to another agent that the workspace starts for it.
//!
//! The agent runs `swarmhub-herdr helper start --difficulty easy|medium|hard TASK` in its terminal (`cli`). That
//! command only asks: it sends one line to `helpers.sock`, next to the journal, or leaves a file where a sandboxed
//! command may write (`spool`), and the workspace decides. The template and the model come from
//! `helper-policy.json` (`policy`, `settings`), never from the request; a helper cannot start helpers; and one
//! agent can have only so many running. A helper is an ordinary managed launch, so its replies, tool activity,
//! output and history work like any other agent's. The `helpers` table adds who started it and why (`record`).
//! A helper that has answered and stays idle is stopped after the policy's delay, and one that has ended is no
//! longer listed; its conversation stays in the history.

use crate::{
    ApiError, Workspace,
    core::{self, Failure, Terminal},
    history::{State as DeliveryState, StoreError},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::get,
};
use policy::{Difficulty, Policy, Tier, Unusable};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet, fs, io, os::unix::fs::FileTypeExt, path::PathBuf, sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
    time::timeout,
};

pub(crate) mod cli;
mod policy;
mod record;
mod settings;
mod spool;

use record::{Admitted, View, Wanted, admit, list_text, one_line, read_text, views};
pub(crate) use record::{ParentRef, parents};
pub(crate) use spool::{ENV as SPOOL_ENV, directory as spool_directory};

/// Room for a file an agent writes on a project's machine (`projects`); a helper's task is held to `TASK_LIMIT`.
pub(crate) const REQUEST_LIMIT: usize = 256 * 1024;
pub(crate) const REPLY_LIMIT: usize = 256 * 1024;
const TASK_LIMIT: usize = 12 * 1024;
const NAME_LIMIT: usize = 20;
/// How much of a saved reply the HTTP list carries; the history route has all of it.
const LIST_REPLY_CHARS: usize = 4_000;
const READ_REPLY_CHARS: usize = 48_000;
const SCREEN_LINES: usize = 200;
/// How often the workspace looks for helpers that answered long enough ago to be stopped.
const SWEEP: Duration = Duration::from_secs(5);
pub(crate) const UNREGISTERED: &str =
    "This terminal is not a SwarmHub agent session, so it has no helpers. Do the task yourself.";
const NESTED: &str = "Helpers cannot start helpers. Do the task yourself, or say in your answer that it should be split.";
const STORAGE: &str = "The workspace could not use its saved history. Nothing was changed.";
const BRIEF: &str = "You are a helper agent, started by another agent for one task. Do only that task, do not start other agents, and end with one complete final answer: the agent that started you reads only that answer. Answer only when the whole task is done and nothing is left running in the background: you are stopped soon after you answer.";

/// One line from `swarmhub-herdr helper …` to the workspace. The launch key says which agent is asking.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Request {
    launch: String,
    action: Action,
}

#[derive(Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, tag = "do", rename_all = "lowercase")]
pub(crate) enum Action {
    Start {
        difficulty: String,
        name: Option<String>,
        task: String,
        /// With `--here`, the folder the command ran in. Without it the helper starts where the workspace
        /// starts every agent.
        cwd: Option<String>,
    },
    List,
    Read {
        name: String,
        lines: Option<usize>,
    },
    Send {
        name: String,
        text: String,
    },
    Stop {
        name: String,
    },
    /// `swarmhub-herdr project …` (`projects`): the same road to the workspace, another desk.
    Project(crate::projects::Ask),
    /// `swarmhub-herdr bot|checkin|promise …` (`bots`).
    Bot(crate::bots::Ask),
}

/// The workspace's answer: text for the agent to read, or why nothing was done.
#[derive(Default, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Reply {
    text: String,
    error: Option<String>,
    /// The named helper has not answered its task yet (`helper wait` asks again).
    working: bool,
    /// For a command run on a project's machine: what it wrote to standard error, and its exit code.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    stderr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    exit: Option<i32>,
}

#[derive(Serialize)]
pub(crate) struct Listing {
    core: String,
    parent: ParentRef,
    /// Running helpers the policy allows this agent at once; `null` without a usable policy.
    limit: Option<usize>,
    /// Seconds after its answer at which an idle helper is stopped and leaves this list.
    stop_after_seconds: u64,
    /// Seconds after its latest task at which a helper that has not answered is stopped.
    stop_unanswered_after_seconds: u64,
    /// Running helpers only, newest first.
    helpers: Vec<View>,
}

/// A helper that was admitted and recorded but not launched yet (`spool`): its launch waits until the command
/// that asked has read the answer and gone.
pub(super) struct Deferred {
    record: i64,
    launch: std::pin::Pin<Box<dyn Future<Output = ()> + Send>>,
}

impl Deferred {
    pub(super) fn launch(self) {
        tokio::spawn(self.launch);
    }

    /// The asking command never read its answer, so the agent does not know of this helper: it is not started.
    pub(super) fn cancel(self, w: &Workspace) {
        let _ = w.history.finish(
            self.record,
            DeliveryState::NotSent,
            Some("The command that asked for this helper did not wait for the workspace's answer."),
            None,
        );
    }
}

/// Why a policy's choice for a difficulty cannot be started.
enum Unfit {
    Template,
    Model,
}

/// The installed template a policy names and how it takes the policy's model.
fn fit<'a>(
    templates: &'a [core::Template],
    catalog: &crate::runtimes::Catalog,
    tier: &Tier,
) -> Result<(&'a core::Template, crate::runtimes::ModelTarget), Unfit> {
    let template = templates
        .iter()
        .find(|template| template.name == tier.template && template.error.is_none())
        .filter(|template| !crate::opencode_agent::first_task::OptIn::requested(template))
        .ok_or(Unfit::Template)?;
    let target = catalog
        .model_target(template)
        .filter(|target| target.accepts(&tier.model))
        .ok_or(Unfit::Model)?;
    Ok((template, target))
}

fn valid_helper_name(name: &str) -> bool {
    (1..=NAME_LIMIT).contains(&name.len())
        && name.as_bytes()[0].is_ascii_alphanumeric()
        && name
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"_-".contains(&b))
}

fn valid_folder(path: &str) -> bool {
    path.len() <= 1024
        && !path.chars().any(char::is_control)
        && std::path::Path::new(path).is_absolute()
        && std::path::Path::new(path).is_dir()
}

pub(crate) fn explain(failure: Failure) -> String {
    match failure {
        Failure::Unreachable => "Herdr Core is not reachable. Nothing was changed.".into(),
        Failure::Missing => "This agent session is no longer available.".into(),
        Failure::Input(message) => message.into(),
        Failure::Rejected(_, message) => message,
        Failure::Protocol | Failure::Uncertain => {
            "Herdr Core did not confirm the action. Run `swarmhub-herdr helper list` before trying again.".into()
        }
    }
}

fn stored<T>(result: Result<T, StoreError>) -> Result<T, String> {
    result.map_err(|_| STORAGE.to_owned())
}

pub(crate) fn socket_path(journal: &std::path::Path) -> PathBuf {
    journal.with_file_name("helpers.sock")
}

/// Starts everything helpers need from a running workspace: the socket and the folder agents ask through, and
/// the sweep that stops helpers which answered a while ago.
pub(crate) fn start_serving(w: Workspace) {
    if let Err(error) = listen(w.clone()) {
        eprintln!("SwarmHub helper agents are unavailable to agents outside a sandbox: {error}");
    }
    if let Err(error) = spool::listen(w.clone()) {
        eprintln!("SwarmHub helper agents are unavailable to sandboxed agents: {error}");
    }
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(SWEEP);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            stop_answered(&w).await;
        }
    });
}

/// Stops each helper whose time is up under the policy: it answered a while ago and is idle, or it has gone too
/// long without answering. It goes by the saved tasks and replies and Core's terminal list alone, so a workspace
/// restart changes nothing.
async fn stop_answered(w: &Workspace) {
    if !record::any(&w.history).unwrap_or(false) {
        return;
    }
    let (Ok(hello), Ok(agents)) = (w.core.identify().await, w.core.agents().await) else {
        return;
    };
    let (answered, unanswered) = Policy::delays(w.history.file());
    let before = |seconds: u64| {
        crate::history::now()
            .saturating_sub(i64::try_from(seconds.saturating_mul(1000)).unwrap_or(i64::MAX))
    };
    let Ok(due) = record::overdue(
        &w.history,
        &hello.core.id,
        &agents,
        before(answered),
        before(unanswered),
    ) else {
        return;
    };
    for helper in due {
        let _ = w.core.end(helper).await;
    }
}

fn listen(w: Workspace) -> io::Result<()> {
    let path = socket_path(w.history.file());
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_socket() => fs::remove_file(&path)?,
        Ok(_) => return Err(io::Error::other("Helper socket path is not a socket")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    // The journal directory is private and held by the workspace's exclusive lock.
    let listener = UnixListener::bind(path)?;
    let slots = Arc::new(Semaphore::new(8));
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let Ok(slot) = slots.clone().try_acquire_owned() else {
                continue;
            };
            let workspace = w.clone();
            tokio::spawn(async move {
                let _slot = slot;
                serve(workspace, stream).await;
            });
        }
    });
    Ok(())
}

async fn serve(w: Workspace, stream: UnixStream) {
    let mut stream = BufReader::new(stream);
    let mut line = Vec::new();
    let read = async {
        (&mut stream)
            .take(REQUEST_LIMIT as u64 + 1)
            .read_until(b'\n', &mut line)
            .await
    };
    if !matches!(timeout(Duration::from_secs(3), read).await, Ok(Ok(_)))
        || line.last() != Some(&b'\n')
    {
        return;
    }
    let reply = match serde_json::from_slice::<Request>(&line) {
        Ok(request) => match perform(&w, request, false).await {
            Ok((reply, _)) => reply,
            Err(error) => Reply {
                error: Some(error),
                ..Reply::default()
            },
        },
        Err(_) => Reply {
            error: Some("The workspace did not understand this helper command. Use the same swarmhub-herdr build as the running workspace.".into()),
            ..Reply::default()
        },
    };
    let Ok(mut bytes) = serde_json::to_vec(&reply) else {
        return;
    };
    bytes.push(b'\n');
    let _ = timeout(Duration::from_secs(5), stream.get_mut().write_all(&bytes)).await;
}

/// Does what `request` asks. With `defer`, a start is admitted and recorded but its launch is handed back to run
/// later; otherwise the answer comes once the helper is running.
async fn perform(
    w: &Workspace,
    request: Request,
    defer: bool,
) -> Result<(Reply, Option<Deferred>), String> {
    let action = match request.action {
        Action::Start {
            difficulty,
            name,
            task,
            cwd,
        } => {
            let wanted = (difficulty.as_str(), name, task, cwd);
            return start(w, request.launch, wanted, defer).await;
        }
        Action::Project(ask) => {
            let core_id = registered(w, &request.launch).await;
            let said = crate::projects::answer(w, core_id, &request.launch, ask).await?;
            let reply = Reply {
                text: said.text,
                stderr: said.stderr,
                exit: said.exit,
                ..Reply::default()
            };
            return Ok((reply, None));
        }
        Action::Bot(ask) => {
            let core_id = registered(w, &request.launch).await;
            let text = crate::bots::answer(w, core_id, &request.launch, ask).await?;
            let reply = Reply {
                text,
                ..Reply::default()
            };
            return Ok((reply, None));
        }
        action => action,
    };
    manage(w, request.launch, action)
        .await
        .map(|reply| (reply, None))
}

async fn registered(w: &Workspace, key: &str) -> Result<String, String> {
    if key.len() != 32 || !key.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err(UNREGISTERED.into());
    }
    let core_id = w.core.identify().await.map_err(explain)?.core.id;
    let registered = stored(w.history.db())?
        .query_row(
            "SELECT 1 FROM journal WHERE launch_key=?1 AND core_id=?2",
            params![key, core_id],
            |_| Ok(()),
        )
        .optional()
        .map_err(|_| STORAGE)?
        .is_some();
    if !registered {
        return Err(UNREGISTERED.into());
    }
    Ok(core_id)
}

/// Everything an agent can do with the helpers it has.
async fn manage(w: &Workspace, key: String, action: Action) -> Result<Reply, String> {
    let core_id = registered(w, &key).await?;
    let agents = w.core.agents().await.map_err(explain)?;
    let mut helpers = stored(views(&w.history, &core_id, &key, &agents, READ_REPLY_CHARS))?;
    let find = |helpers: &[View], name: &str| {
        helpers
            .iter()
            .position(|helper| helper.name == name)
            .ok_or_else(|| {
                format!(
                    "You have no helper named {:?}. See yours with `swarmhub-herdr helper list`.",
                    one_line(name, 40)
                )
            })
    };
    match action {
        Action::Start { .. } | Action::Project(_) | Action::Bot(_) => unreachable!("handled above"),
        Action::List => Ok(Reply {
            text: list_text(
                &helpers,
                Policy::load(w.history.file())
                    .ok()
                    .map(|policy| policy.max_running),
                Policy::delays(w.history.file()).0,
            ),
            ..Reply::default()
        }),
        Action::Read { name, lines } => {
            let helper = &helpers[find(&helpers, &name)?];
            let screen = match lines {
                Some(lines) => {
                    let terminal = agents
                        .iter()
                        .find(|agent| {
                            agent.address == helper.address && agent.created_ms == helper.created_ms
                        })
                        .ok_or("This helper's terminal is no longer in Herdr Core.")?;
                    Some((
                        lines.clamp(1, SCREEN_LINES),
                        w.core.output(terminal).await.map_err(explain)?.text,
                    ))
                }
                None => None,
            };
            Ok(Reply {
                text: read_text(
                    helper,
                    screen.as_ref().map(|(lines, text)| (*lines, &**text)),
                    Policy::delays(w.history.file()).1,
                ),
                working: helper.working(),
                ..Reply::default()
            })
        }
        Action::Send { name, text } => {
            let helper = helpers.swap_remove(find(&helpers, &name)?);
            if text.len() > TASK_LIMIT || core::validate_task(&text).is_err() {
                return Err("Write a message of up to 12 KB of plain text.".into());
            }
            if !helper.live() {
                return Err(format!(
                    "{name} has ended, so it cannot take a follow-up. Its answer is still readable with `swarmhub-herdr helper read {name}`; start a new helper for more work."
                ));
            }
            let terminal = terminal_of(agents, &helper)?;
            terminal.require_live().map_err(explain)?;
            let (record, _) =
                stored(
                    w.history
                        .start_task(&core_id, &terminal, &text, None, false, &[]),
                )?;
            crate::deliver_task(w.clone(), terminal, record, text)
                .await
                .map_err(explain)?;
            Ok(Reply {
                text: format!(
                    "Sent to {name}. Wait for its answer with: swarmhub-herdr helper wait {name}"
                ),
                ..Reply::default()
            })
        }
        Action::Stop { name } => {
            let helper = helpers.swap_remove(find(&helpers, &name)?);
            if !helper.live() {
                return Ok(Reply {
                    text: format!("{name} has already ended. Its answer stays readable."),
                    ..Reply::default()
                });
            }
            let terminal = terminal_of(agents, &helper)?;
            w.core.end(&terminal).await.map_err(explain)?;
            Ok(Reply {
                text: format!("Stopped {name}. Its answer stays readable."),
                ..Reply::default()
            })
        }
    }
}

fn terminal_of(agents: Vec<Terminal>, helper: &View) -> Result<Terminal, String> {
    agents
        .into_iter()
        .find(|agent| agent.address == helper.address && agent.created_ms == helper.created_ms)
        .ok_or_else(|| "This helper's terminal is no longer in Herdr Core.".to_owned())
}

async fn start(
    w: &Workspace,
    key: String,
    (difficulty, name, task, cwd): (&str, Option<String>, String, Option<String>),
    defer: bool,
) -> Result<(Reply, Option<Deferred>), String> {
    let core_id = registered(w, &key).await?;
    let nested = stored(w.history.db())?
        .query_row(
            "SELECT 1 FROM helpers h JOIN journal j ON j.id=h.launch WHERE j.launch_key=?1",
            [&key],
            |_| Ok(()),
        )
        .optional()
        .map_err(|_| STORAGE)?
        .is_some();
    if nested {
        return Err(NESTED.into());
    }
    let difficulty = Difficulty::parse(difficulty)?;
    let policy = Policy::load(w.history.file()).map_err(Unusable::for_agent)?;
    let tier = policy.tier(difficulty)?;
    let task = task.trim().to_owned();
    if task.len() > TASK_LIMIT || core::validate_task(&task).is_err() {
        return Err("Give the helper a task of up to 12 KB of plain text.".into());
    }
    if name.as_deref().is_some_and(|name| !valid_helper_name(name)) {
        return Err(
            "Use 1–20 lowercase letters, digits, dashes or underscores for --name, starting with a letter or digit."
                .into(),
        );
    }
    if cwd.as_deref().is_some_and(|path| !valid_folder(path)) {
        return Err("A helper cannot start in this folder. Leave out --here to start it in the workspace's agent folder.".into());
    }
    let folder = cwd
        .clone()
        .or_else(|| core::agent_cwd().ok().flatten())
        .map_or_else(String::new, |folder| format!(" in {folder}"));
    let templates = w.core.templates().await.map_err(explain)?;
    let catalog = crate::runtimes::Catalog::load(w.history.file());
    let (template, target) = fit(&templates, &catalog, tier).map_err(|unfit| {
        let (what, why) = match unfit {
            Unfit::Template => (&tier.template, "Herdr cannot start that template".to_owned()),
            Unfit::Model => (
                &tier.model,
                format!("the template {} cannot take that model", tier.template),
            ),
        };
        format!(
            "The workspace's helper policy names {what} for {} helpers, and {why}. Do the task yourself and tell the user.",
            difficulty.name()
        )
    })?;
    let preset = catalog
        .models(template)
        .and_then(|(_, models)| models.into_iter().find(|model| model.id == tier.model));
    let runtime = match preset {
        Some(preset) => catalog.runtime(template).with_model(target, preset),
        None => catalog.runtime(template).with_model_id(target, &tier.model),
    };
    let runtime = serde_json::to_string(&runtime).map_err(|_| STORAGE)?;
    let model = target.selection(&tier.model);
    let message = format!("{BRIEF} Task: {task}");
    core::validate_task(&message).map_err(explain)?;

    // No awaits between Core's list of running terminals and the record of this launch: two requests cannot
    // both take the last free place.
    let agents = w.core.agents().await.map_err(explain)?;
    let parent = agents
        .iter()
        .find(|agent| agent.launch_key() == Some(key.as_str()) && agent.require_live().is_ok())
        .ok_or("Only a running SwarmHub agent can start helpers.")?;
    let live: HashSet<&str> = agents
        .iter()
        .filter(|agent| agent.require_live().is_ok())
        .filter_map(Terminal::launch_key)
        .collect();
    let admitted = stored(admit(
        &mut *stored(w.history.db())?,
        &policy,
        &live,
        &Wanted {
            core: &core_id,
            parent_key: &key,
            parent_address: &parent.address,
            name: name.as_deref(),
            difficulty,
            template: &template.name,
            model: &tier.model,
            runtime: &runtime,
            task: &task,
        },
    ))??;
    let parent_address = parent.address.clone();
    let Admitted {
        record,
        key: helper_key,
        name,
        terminal: terminal_name,
    } = admitted;
    let described = format!(
        "{name} ({}: {}, model {})",
        difficulty.name(),
        template.name,
        tier.model
    );
    let template_name = template.name.clone();
    let stays = format!(
        "It is stopped {} seconds after it answers unless you send it a follow-up first, or after {} seconds without an answer; an answer stays readable.",
        policy.stop_after_seconds, policy.stop_unanswered_after_seconds
    );
    let w = w.clone();
    let launch = async move {
        let journal = w
            .history
            .file()
            .to_str()
            .ok_or("The workspace data directory must have a UTF-8 path.")?;
        let approval_socket = crate::approvals::socket_path(&w.history);
        let launched = w
            .core
            .launch(
                terminal_name,
                core::LaunchSource::Template(template_name, message),
                core::LaunchEnv {
                    key: &helper_key,
                    journal,
                    approval_socket: approval_socket.to_str().unwrap_or_default(),
                    model: Some(&model),
                    results: None,
                    opencode_first_task: None,
                    helper: Some(core::HelperOf {
                        parent: &parent_address,
                        cwd: cwd.as_deref(),
                    }),
                },
            )
            .await;
        match launched {
            Ok(terminal) => {
                let (state, detail) = match &terminal.first_message {
                    Some(core::FirstMessage { sent: true, .. }) => (DeliveryState::Sent, None),
                    Some(first) => (DeliveryState::NotSent, first.reason.as_deref()),
                    None => (DeliveryState::Unconfirmed, None),
                };
                let undelivered = matches!(state, DeliveryState::NotSent).then(|| {
                    detail
                        .unwrap_or("Herdr could not tell that it was ready")
                        .to_owned()
                });
                stored(w.history.finish(record, state, detail, Some(&terminal)))?;
                Ok::<_, String>((terminal.address, undelivered))
            }
            Err(error) => {
                let _ = crate::record_failure(&w.history, record, &error);
                Err(format!(
                    "The helper could not be started: {}",
                    explain(error)
                ))
            }
        }
    };
    if defer {
        let text = format!(
            "Starting helper {described}{folder}. It starts as soon as this command has returned.\nWait for its answer with: swarmhub-herdr helper wait {name}\n{stays}"
        );
        let deferred = Deferred {
            record,
            launch: Box::pin(async move {
                let _ = launch.await;
            }),
        };
        return Ok((
            Reply {
                text,
                ..Reply::default()
            },
            Some(deferred),
        ));
    }
    // Its own task, so the launch is recorded even when the asking command gives up waiting.
    let (address, undelivered) = tokio::spawn(launch)
        .await
        .map_err(|_| "The helper launch was interrupted. Run `swarmhub-herdr helper list`.")??;
    let text = match undelivered {
        None => format!(
            "Started helper {described} as {address}{folder}.\nWait for its answer with: swarmhub-herdr helper wait {name}\n{stays}"
        ),
        Some(reason) => format!(
            "Started helper {described} as {address}{folder}, but its task was not delivered: {reason}.\nIt still counts as running. Look at it with: swarmhub-herdr helper read {name} --lines 30\nIf it waits at a prompt only a person should answer, stop it with `swarmhub-herdr helper stop {name}` and tell the user. Otherwise send the task again with `swarmhub-herdr helper send {name} TEXT`."
        ),
    };
    Ok((
        Reply {
            text,
            ..Reply::default()
        },
        None,
    ))
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/agents/{id}/{created}/helpers", get(list))
        .merge(settings::routes())
}

async fn list(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<Json<Listing>, ApiError> {
    let core_id = w.core.identify().await?.core.id;
    let key = crate::live_reply::launch_key(&w.history, &core_id, &id, created)?
        .ok_or(Failure::Missing)?;
    let parent = ParentRef {
        address: id,
        created_ms: created,
    };
    Ok(Json(listing(&w, core_id, &key, parent).await?))
}

/// The running helpers of the agent with this launch key: what `GET …/helpers` answers and what an event
/// stream sends when it changes (`events`).
pub(crate) async fn listing(
    w: &Workspace,
    core_id: String,
    key: &str,
    parent: ParentRef,
) -> Result<Listing, ApiError> {
    // An agent that never started a helper has none running: no need to ask Core for its terminals.
    let any: bool = w
        .history
        .db()?
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM helpers WHERE parent_key=?1)",
            [key],
            |row| row.get(0),
        )
        .map_err(StoreError::from)?;
    let mut helpers = if any {
        let agents = w.core.agents().await?;
        views(&w.history, &core_id, key, &agents, LIST_REPLY_CHARS)?
    } else {
        Vec::new()
    };
    helpers.retain(View::live);
    if !helpers.is_empty() {
        let catalog = crate::runtimes::Catalog::load(w.history.file());
        for helper in &mut helpers {
            helper.model_label = catalog.model_label(&helper.template, &helper.model);
        }
    }
    let (stop_after_seconds, stop_unanswered_after_seconds) = Policy::delays(w.history.file());
    Ok(Listing {
        core: core_id,
        parent,
        limit: Policy::load(w.history.file())
            .ok()
            .map(|policy| policy.max_running),
        stop_after_seconds,
        stop_unanswered_after_seconds,
        helpers,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_folders_and_requests_are_checked() {
        for name in ["a", "easy-1", "fix_tests", "9lives"] {
            assert!(valid_helper_name(name), "{name}");
        }
        for name in [
            "",
            "-x",
            "_x",
            "Tests",
            "a b",
            "a.b",
            "a/b",
            &"x".repeat(NAME_LIMIT + 1),
        ] {
            assert!(!valid_helper_name(name), "{name}");
        }
        assert!(valid_folder("/tmp") && !valid_folder("tmp") && !valid_folder("/no/such/folder"));

        let request: Request = serde_json::from_str(
            r#"{"launch":"k","action":{"do":"start","difficulty":"easy","name":null,"task":"t","cwd":null}}"#,
        )
        .unwrap();
        assert!(matches!(request.action, Action::Start { .. }));
        // The request has no place for a template or a model.
        for refused in [
            r#"{"launch":"k","action":{"do":"start","difficulty":"easy","name":null,"task":"t","cwd":null,"model":"big"}}"#,
            r#"{"launch":"k","action":{"do":"start","difficulty":"easy","name":null,"task":"t","cwd":null,"template":"x"}}"#,
            r#"{"launch":"k","model":"big","action":{"do":"list"}}"#,
            r#"{"launch":"k","action":{"do":"launch"}}"#,
        ] {
            assert!(
                serde_json::from_str::<Request>(refused).is_err(),
                "{refused}"
            );
        }
    }
}
