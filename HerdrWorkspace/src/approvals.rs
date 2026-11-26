use crate::{
    Workspace,
    agent::read_input,
    approval_rules::{ExactRead, Rules},
    history::{History, StoreError, now},
};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::{StatusCode, header},
    response::IntoResponse,
    routing::{get, post},
};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use serde_json::{json, value::RawValue};
use std::io::{Read, Write};
use std::{
    collections::BTreeMap,
    fs, io,
    os::unix::{fs::FileTypeExt, net::UnixStream as BlockingStream},
    path::{Path as FilePath, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::oneshot,
    time::timeout,
};

const MAX_MESSAGE: usize = 48 * 1024;
const MAX_PENDING: usize = 24;
const WAIT: Duration = Duration::from_secs(45);

#[derive(Clone, Default)]
pub struct Desk {
    pending: Arc<Mutex<BTreeMap<i64, Pending>>>,
    rules: Arc<Mutex<Rules>>,
}

struct Pending {
    info: Review,
    launch: String,
    until: Instant,
    answer: Option<oneshot::Sender<Decision>>,
}

#[derive(Serialize)]
pub(crate) struct ApprovalSummary {
    id: i64,
    agent: String,
    provider: &'static str,
    tool: String,
    terminal: Option<(String, String, u64)>,
    model: Option<String>,
}

impl Desk {
    pub(crate) fn waits_on(&self, key: &str) -> Result<bool, StoreError> {
        Ok(self.pending.lock().map_err(|_| StoreError)?.values()
            .any(|item| item.launch == key && item.answer.is_some() && Instant::now() < item.until))
    }

    pub(crate) fn summary(&self, history: &History) -> Result<Vec<ApprovalSummary>, StoreError> {
        let pending = self
            .pending
            .lock()
            .map_err(|_| StoreError)?
            .values()
            .filter(|item| item.answer.is_some() && Instant::now() < item.until)
            .map(|item| {
                (
                    ApprovalSummary {
                        id: item.info.id,
                        agent: item.info.agent.clone(),
                        provider: item.info.provider,
                        tool: item.info.tool.clone(),
                        terminal: None,
                        model: None,
                    },
                    item.launch.clone(),
                )
            })
            .collect::<Vec<_>>();
        if pending.is_empty() {
            return Ok(Vec::new());
        }
        let db = history.db()?;
        let mut terminal = db.prepare("SELECT core_id,address,created_ms,
            coalesce(json_extract(launch_runtime,'$.model'),json_extract(launch_runtime,'$.model_id')) FROM journal WHERE launch_key=?1 AND address IS NOT NULL AND created_ms IS NOT NULL")?;
        pending
            .into_iter()
            .map(|(mut item, launch)| {
                if let Some((target, model)) = terminal
                    .query_row([launch], |row| Ok(((row.get(0)?, row.get(1)?, row.get(2)?), row.get(3)?)))
                    .optional()? {
                    item.terminal = Some(target);
                    item.model = model;
                }
                Ok(item)
            })
            .collect()
    }
}

#[derive(Clone, Serialize)]
struct Review {
    id: i64,
    agent: String,
    tool: String,
    provider: &'static str,
    cwd: String,
    arguments: String,
    expires_ms: i64,
    can_remember_read: bool,
    can_remember_command: bool,
    can_remember_command_hour: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reviewer: Option<crate::command_reviewer::Advice>,
}

#[derive(Serialize)]
struct Record {
    id: i64,
    agent: String,
    tool: String,
    provider: String,
    requested_ms: i64,
    resolved_ms: Option<i64>,
    state: String,
    automatic: bool,
    unconfirmed: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    reviewer: Option<crate::command_reviewer::Advice>,
}

#[derive(Serialize, Deserialize)]
struct HookRequest {
    key: String,
    tool: String,
    provider: Provider,
    cwd: String,
    input: Box<RawValue>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    native_session: Option<String>,
}

#[derive(Deserialize)]
struct Permission {
    hook_event_name: String,
    tool_name: String,
    tool_input: Box<RawValue>,
    cwd: String,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Provider {
    Claude,
    ClaudeTool,
    Codex,
    OpenCode,
}

impl Provider {
    fn name(self) -> &'static str {
        match self {
            Self::Claude | Self::ClaudeTool => "Claude Code",
            Self::Codex => "Codex",
            Self::OpenCode => "OpenCode",
        }
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Decision {
    Approve,
    RememberRead,
    RememberCommand,
    RememberCommandHour,
    Deny,
    Terminal,
}

impl Decision {
    fn remembers_command(self) -> bool {
        matches!(self, Self::RememberCommand | Self::RememberCommandHour)
    }

    fn reply(self) -> u8 {
        match self {
            Self::Approve | Self::RememberRead | Self::RememberCommand | Self::RememberCommandHour => b'A',
            Self::Deny => b'D',
            Self::Terminal => b'T',
        }
    }
    fn audit(self) -> &'static str {
        match self {
            Self::Approve | Self::RememberRead | Self::RememberCommand | Self::RememberCommandHour => "approved",
            Self::Deny => "denied",
            Self::Terminal => "terminal",
        }
    }
}

pub fn socket_path(history: &History) -> PathBuf {
    history.file().with_file_name("approval.sock")
}

pub fn listen(w: Workspace) -> io::Result<()> {
    let path = socket_path(&w.history);
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_socket() => fs::remove_file(&path)?,
        Ok(_) => return Err(io::Error::other("Approval socket path is not a socket")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    // History already holds the workspace's exclusive lock, and its directory is private.
    let listener = UnixListener::bind(path)?;
    tokio::spawn(async move {
        loop {
            let Ok((socket, _)) = listener.accept().await else {
                break;
            };
            let w = w.clone();
            tokio::spawn(serve_hook(w, socket));
        }
    });
    Ok(())
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/approvals.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/approvals.js"),
                )
            }),
        )
        .route("/api/approvals", get(inbox))
        .route("/api/approvals/{id}", post(decide))
        .route("/api/approval-rules/{id}/revoke", post(revoke_read))
        .route("/api/project-command-rules", get(command_rules))
        .route("/api/project-command-rules/{id}/revoke", post(revoke_command))
}

#[derive(Default, Deserialize)]
struct InboxQuery {
    #[serde(default)]
    pending_only: bool,
}

async fn inbox(
    State(w): State<Workspace>,
    Query(query): Query<InboxQuery>,
) -> Result<impl IntoResponse, StoreError> {
    let pending = w
        .approvals
        .pending
        .lock()
        .map_err(|_| StoreError)?
        .values()
        .filter(|item| item.answer.is_some() && Instant::now() < item.until)
        .map(|item| item.info.clone())
        .collect::<Vec<_>>();
    if query.pending_only {
        // Native chat can act only on the exact launch it is following. A terminal
        // address may already belong to another session when a review expires.
        let sessions: BTreeMap<_, _> = w
            .approvals
            .summary(&w.history)?
            .into_iter()
            .filter_map(|item| Some((item.id, (item.terminal?, item.model))))
            .collect();
        let pending: Vec<_> = pending
            .into_iter()
            .filter_map(|review| {
                let ((core, address, created), model) = sessions.get(&review.id)?;
                let mut row = json!(review);
                row["core"] = json!(core);
                row["address"] = json!(address);
                row["created_ms"] = json!(created);
                row["launch_model"] = json!(model);
                Some(row)
            })
            .collect();
        return Ok(Json(json!({"pending": pending})));
    }
    let rules = w.approvals.rules.lock().map_err(|_| StoreError)?.list();
    let db = w.history.db()?;
    let mut stmt = db
        .prepare(
            "SELECT id,agent,tool,requested_ms,resolved_ms,state,provider,
            EXISTS(SELECT 1 FROM approval_rule_audit WHERE approval_id=approvals.id AND kind='rule'),
            EXISTS(SELECT 1 FROM approval_rule_audit WHERE approval_id=approvals.id AND kind='unconfirmed'),
            reviewer_bot_id,reviewer_name,reviewer_model,assessment
         FROM approvals WHERE state!='pending'
         ORDER BY id DESC LIMIT 40",
        )
        .map_err(StoreError::from)?;
    let history = stmt
        .query_map([], |row| {
            Ok(Record {
                id: row.get(0)?,
                agent: row.get(1)?,
                tool: row.get(2)?,
                requested_ms: row.get(3)?,
                resolved_ms: row.get(4)?,
                state: row.get(5)?,
                provider: row.get(6)?,
                automatic: row.get(7)?,
                unconfirmed: row.get(8)?,
                reviewer: if let Some(id) = row.get::<_,Option<String>>(9)? {
                    Some(crate::command_reviewer::Advice { bot_id: Some(id), bot_name: row.get(10)?,
                        model: row.get(11)?, assessment: row.get(12)?, problem: None })
                } else { None },
            })
        })
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(StoreError::from)?;
    Ok(Json(
        json!({"pending":pending,"history":history,"read_rules":rules,"command_rules":crate::project_command_rules::list(&db)?}),
    ))
}

async fn command_rules(State(w): State<Workspace>) -> Result<impl IntoResponse, StoreError> {
    Ok(Json(crate::project_command_rules::list(&*w.history.db()?)?))
}

async fn revoke_command(State(w): State<Workspace>, Path(id): Path<i64>) -> Result<impl IntoResponse, StoreError> {
    let count = w.history.db()?.execute("DELETE FROM project_command_rules WHERE id=?1", [id])?;
    Ok(Json(json!({"revoked": count == 1})))
}

async fn revoke_read(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, StoreError> {
    let revoked = w.approvals.rules.lock().map_err(|_| StoreError)?.revoke(id);
    Ok(Json(json!({"revoked": revoked})))
}

async fn decide(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(decision): Json<Decision>,
) -> impl IntoResponse {
    let answer = w.approvals.pending.lock().ok().and_then(|mut rows| {
        let pending = rows.get_mut(&id)?;
        if Instant::now() >= pending.until {
            return None;
        }
        if (matches!(decision, Decision::RememberRead) && !pending.info.can_remember_read)
            || (decision.remembers_command() && !pending.info.can_remember_command) {
            return None;
        }
        pending.answer.take()
    });
    if answer.is_some_and(|sender| sender.send(decision).is_ok()) {
        (StatusCode::ACCEPTED, Json(json!({"id":id})))
    } else {
        (
            StatusCode::CONFLICT,
            Json(json!({"error":"This request is no longer waiting for a decision."})),
        )
    }
}

async fn serve_hook(w: Workspace, mut stream: UnixStream) {
    let request = match timeout(Duration::from_secs(3), receive(&mut stream)).await {
        Ok(Ok(request)) if supported(&request) => request,
        _ => return,
    };
    let every_tool = matches!(request.provider, Provider::ClaudeTool);
    let confirmed = matches!(request.provider, Provider::OpenCode);
    let session = request
        .native_session
        .as_deref()
        .filter(|value| {
            value.len() <= 128
                && value.strip_prefix("ses_").is_some_and(|id| {
                    !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric())
                })
        })
        .map(str::to_owned);
    let read = if confirmed && request.tool == "read" && session.is_some() {
        ExactRead::from_request(&request.cwd, request.input.get()).await
    } else {
        None
    };
    let launch = request.key.clone();
    let command = if request.tool == "Bash" && matches!(request.provider, Provider::Claude | Provider::Codex) {
        crate::project_command_rules::Command::identify(&w.history, &launch, request.provider.name(), &request.cwd, request.input.get()).await
    } else { None };
    let command_match = || command.as_ref().and_then(|c| c.matching(&*w.history.db().ok()?).ok().flatten());
    let automatic = if command.is_some() {
        command_match()
    } else if let (Some(read), Some(session)) = (read.as_ref(), session.as_deref()) {
        let found = matching_rule(&w, &launch, session, read);
        if found.is_some() && launch_live(&w, &launch).await {
            found
        } else {
            None
        }
    } else {
        None
    };
    let reviewer = if matches!(request.provider, Provider::Codex) && request.tool == "Bash" {
        w.history.db().ok().and_then(|db| crate::bot_agent_settings::for_launch(&db, &launch).ok())
            .and_then(|s| crate::command_reviewer::Advice::pending(s.command_reviewer, s.reviewer_bot_id))
    } else { None };
    let review_input = reviewer.clone().map(|model| (model, json!({
        "tool": request.tool, "working_directory": request.cwd, "arguments": request.input
    }).to_string()));
    let registered = match register(&w, request, read.is_some(), command.is_some(), automatic.is_some(), reviewer) {
        Ok(Some(id)) => id,
        _ => return,
    };
    let Registered { id, agent, answer } = registered;
    let mut decision = if let Some(answer) = answer {
        // The user's decision, expiry or departure drops the future and its subprocess immediately.
        let review = async {
            if let Some((mut review, input)) = review_input {
                review.review(&w, &input).await;
                if let Ok(mut map) = w.approvals.pending.lock()
                    && let Some(item) = map.get_mut(&id)
                    && let Some(advice) = item.info.reviewer.as_mut() {
                    if review.bot_id.is_some() && review.assessment.is_some()
                        && let Ok(db) = w.history.db() {
                        let _ = db.execute("UPDATE approvals SET reviewer_bot_id=?2,reviewer_name=?3,reviewer_model=?4,assessment=?5 WHERE id=?1",
                            params![id,review.bot_id,review.bot_name,review.model,review.assessment]);
                    }
                    *advice = review;
                }
            }
            std::future::pending::<Decision>().await
        };
        let result = tokio::select! {
            // A canceled native hook must not count as a browser decision.
            biased;
            _ = stream.read_u8() => Decision::Terminal,
            reply = timeout(WAIT, answer) => match reply {
                Ok(Ok(choice)) => choice,
                _ if every_tool => Decision::Deny,
                _ => Decision::Terminal,
            },
            result = review => result,
        };
        if let Ok(mut map) = w.approvals.pending.lock() {
            map.remove(&id);
        }
        result
    } else {
        Decision::Approve
    };
    let command_expires = matches!(decision, Decision::RememberCommandHour).then(|| now() + 3_600_000);
    if let Some(command) = &command && (automatic.is_some() || decision.remembers_command()) {
        let valid = command.unchanged().await && launch_live(&w, &launch).await;
        if !valid || (automatic.is_some() && command_match() != automatic) { decision = Decision::Terminal; }
    } else if let Some(rule) = automatic {
        if let (Some(read), Some(session)) = (read.as_ref(), session.as_deref()) {
            if !read.unchanged().await || matching_rule(&w, &launch, session, read) != Some(rule) {
                decision = Decision::Terminal;
            }
        } else {
            decision = Decision::Terminal;
        }
    } else if matches!(decision, Decision::RememberRead) {
        let checked = match read.as_ref() {
            Some(read) => launch_live(&w, &launch).await && read.unchanged().await,
            None => false,
        };
        if !checked {
            decision = Decision::Terminal;
        }
    }
    let sent = matches!(
        timeout(
            Duration::from_secs(1),
            stream.write_all(&[decision.reply()])
        )
        .await,
        Ok(Ok(()))
    );
    let applied = sent
        && (!confirmed
            || matches!(decision, Decision::Terminal)
            || matches!(
                timeout(Duration::from_secs(6), stream.read_u8()).await,
                Ok(Ok(b'K'))
            ));
    let state = if applied {
        decision.audit()
    } else {
        "terminal"
    };
    let kind = if sent && !applied && confirmed {
        Some("unconfirmed")
    } else if state == "approved" && automatic.is_some() {
        Some("rule")
    } else {
        None
    };
    if w.history
        .db()
        .and_then(|mut db| {
            let tx = db.transaction()?;
            tx.execute(
                "UPDATE approvals SET state=?2,resolved_ms=?3 WHERE id=?1 AND state='pending'",
                params![id, state, now()],
            )?;
            if let Some(kind) = kind {
                tx.execute(
                    "INSERT INTO approval_rule_audit(approval_id,kind) VALUES (?1,?2)",
                    params![id, kind],
                )?;
            }
            if applied && decision.remembers_command() && let Some(command) = &command {
                command.save(&tx, command_expires)?;
            }
            tx.commit().map_err(StoreError::from)
        })
        .is_err()
    {
        eprintln!("SwarmHub could not record an approval result.");
    } else if applied
        && matches!(decision, Decision::RememberRead)
        && let Some(read) = read
        && let Some(session) = session
        && let Ok(mut rules) = w.approvals.rules.lock()
    {
        rules.remember(id, launch, session, agent, read);
    }
}

fn matching_rule(w: &Workspace, launch: &str, session: &str, read: &ExactRead) -> Option<i64> {
    w.approvals
        .rules
        .lock()
        .ok()?
        .applicable(launch, session, read)
}

async fn launch_live(w: &Workspace, launch: &str) -> bool {
    fn linked(
        history: &History,
        launch: &str,
    ) -> Result<Option<(String, String, u64)>, StoreError> {
        Ok(history.db()?.query_row(
            "SELECT core_id,address,created_ms FROM journal WHERE launch_key=?1 AND address IS NOT NULL AND created_ms IS NOT NULL",
            [launch], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        ).optional()?)
    }
    let Ok(Some((core, address, created))) = linked(&w.history, launch) else {
        return false;
    };
    timeout(Duration::from_secs(2), async {
        let Ok(hello) = w.core.identify().await else {
            return false;
        };
        hello.core.id == core
            && w.core.agent(&address, created).await.is_ok_and(|terminal| {
                terminal.launch_key() == Some(launch) && terminal.require_live().is_ok()
            })
    })
    .await
    .unwrap_or(false)
}

struct Registered {
    id: i64,
    agent: String,
    answer: Option<oneshot::Receiver<Decision>>,
}

fn register(
    w: &Workspace,
    request: HookRequest,
    can_remember_read: bool,
    can_remember_command: bool,
    automatic: bool,
    reviewer: Option<crate::command_reviewer::Advice>,
) -> Result<Option<Registered>, StoreError> {
    let arguments = request.input.get().to_owned();
    let mut pending = w.approvals.pending.lock().map_err(|_| StoreError)?;
    if !automatic && pending.len() >= MAX_PENDING {
        return Ok(None);
    }
    let db = w.history.db()?;
    let agent: Option<String> = db
        .query_row(
            "SELECT coalesce(profiles.name,journal.agent) FROM journal
             LEFT JOIN profiles ON profiles.id=journal.profile_id WHERE journal.launch_key=?1",
            [&request.key],
            |row| row.get(0),
        )
        .optional()?;
    let Some(agent) = agent else { return Ok(None) };
    let requested = now();
    let id: i64 = db.query_row(
        "INSERT INTO approvals (agent,tool,requested_ms,provider,state) VALUES (?1,?2,?3,?4,'pending') RETURNING id",
        params![agent,request.tool,requested,request.provider.name()], |row| row.get(0),
    )?;
    if automatic {
        return Ok(Some(Registered {
            id,
            agent,
            answer: None,
        }));
    }
    let (send, recv) = oneshot::channel();
    pending.insert(
        id,
        Pending {
            launch: request.key,
            info: Review {
                id,
                agent: agent.clone(),
                tool: request.tool,
                provider: request.provider.name(),
                cwd: request.cwd,
                arguments,
                expires_ms: requested + 45_000,
                can_remember_read,
                can_remember_command,
                can_remember_command_hour: can_remember_command,
                reviewer,
            },
            until: Instant::now() + WAIT,
            answer: Some(send),
        },
    );
    Ok(Some(Registered {
        id,
        agent,
        answer: Some(recv),
    }))
}

async fn receive(stream: &mut UnixStream) -> io::Result<HookRequest> {
    let size = stream.read_u32_le().await? as usize;
    if size == 0 || size > MAX_MESSAGE {
        return Err(io::Error::other("Invalid approval frame"));
    }
    let mut body = vec![0; size];
    stream.read_exact(&mut body).await?;
    serde_json::from_slice(&body).map_err(io::Error::other)
}

fn supported(request: &HookRequest) -> bool {
    let permitted = match request.provider {
        Provider::ClaudeTool => !request.tool.is_empty() && request.tool.len() <= 256
            && request.tool.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.:-".contains(&b)),
        Provider::Claude => matches!(
            request.tool.as_str(),
            "Bash"
                | "Read"
                | "Write"
                | "Edit"
                | "MultiEdit"
                | "Glob"
                | "Grep"
                | "WebFetch"
                | "WebSearch"
        ),
        Provider::Codex => {
            #[derive(Deserialize)]
            struct Command {
                command: String,
            }
            matches!(request.tool.as_str(), "Bash" | "apply_patch")
                && serde_json::from_str::<Command>(request.input.get())
                    .is_ok_and(|input| !input.command.trim().is_empty())
        }
        Provider::OpenCode => {
            #[derive(Deserialize)]
            #[serde(deny_unknown_fields)]
            struct Resources {
                resources: Vec<String>,
            }
            matches!(request.tool.as_str(), "read" | "glob" | "grep")
                && serde_json::from_str::<Resources>(request.input.get()).is_ok_and(|input| {
                    !input.resources.is_empty()
                        && input.resources.len() <= 32
                        && input
                            .resources
                            .iter()
                            .all(|resource| !resource.is_empty() && resource.len() <= 8192)
                })
        }
    };
    permitted
        && !request.cwd.contains(char::is_control)
        && request.cwd.len() <= 4096
        && request.input.get().trim_start().starts_with('{')
}

/// A hook failure or timeout returns no decision, leaving the provider's flow intact.
pub fn permission_hook(provider: Provider) {
    if let Ok(Some(byte)) = hook_answer(provider, "PermissionRequest") {
        let decision = match byte { b'A' => "allow", b'D' => "deny", _ => return };
        let output = json!({"hookSpecificOutput":{
            "hookEventName":"PermissionRequest","decision":{"behavior":decision}
        }});
        println!("{output}");
    }
}

/// A single PreToolUse call waits for its own decision even for tools Claude normally runs without asking.
pub fn claude_tool_hook() {
    let (decision, reason) = match hook_answer(Provider::ClaudeTool, "PreToolUse") {
        Ok(Some(b'A')) => ("allow", "Approved once in SwarmHub."),
        Ok(Some(b'T')) => ("ask", "Review this tool call in the terminal."),
        Ok(Some(b'D')) => ("deny", "SwarmHub did not approve this tool call."),
        _ => ("deny", "SwarmHub could not obtain approval for this tool call."),
    };
    println!("{}", json!({"hookSpecificOutput":{"hookEventName":"PreToolUse",
        "permissionDecision":decision,"permissionDecisionReason":reason}}));
}

fn hook_answer(provider: Provider, event: &str) -> Result<Option<u8>, Box<dyn std::error::Error>> {
    let hook: Permission = serde_json::from_str(&read_input(MAX_MESSAGE)?)?;
    if hook.hook_event_name != event {
        return Ok(None);
    }
    let (_, key) = crate::agent::session()?;
    let request = HookRequest {
        key,
        tool: hook.tool_name,
        provider,
        cwd: hook.cwd,
        input: hook.tool_input,
        native_session: None,
    };
    if !supported(&request) {
        return Ok(None);
    }
    let bytes = serde_json::to_vec(&request)?;
    if bytes.len() > MAX_MESSAGE {
        return Ok(None);
    }
    let path = std::env::var_os("SWARMHUB_APPROVAL_SOCKET")
        .map(PathBuf::from)
        .filter(|path| FilePath::is_absolute(path))
        .ok_or("No approval socket configured.")?;
    let mut stream = BlockingStream::connect(path)?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.set_read_timeout(Some(Duration::from_secs(49)))?;
    stream.write_all(&(bytes.len() as u32).to_le_bytes())?;
    stream.write_all(&bytes)?;
    let mut byte = [0];
    stream.read_exact(&mut byte)?;
    Ok(Some(byte[0]))
}

#[cfg(test)]
mod switch_tests {
    use super::*;

    #[test]
    fn inter_bot_delivery_uses_boppys_current_launch_and_keeps_its_review() {
        use crate::bots::{desk::agent_of, testing};
        let (_dir, history) = testing::journal(&["Boppy"]);
        let key = testing::session(&history, "Boppy", "fixture-terminal");
        {
            let db = history.db().unwrap();
            db.execute("UPDATE journal SET launch_runtime=? WHERE launch_key=?",
                params![r#"{"model":"Gemini Neon","model_id":"gemini"}"#, key]).unwrap();
            db.execute("UPDATE bots SET model='astra' WHERE id='boppy-id'", []).unwrap();
        }
        let bot = testing::bot(&history, "Boppy");
        let live = vec![serde_json::from_value(json!({
            "address":"fixture-terminal","created_ms":42,"name":bot.agent_name,"state":"live",
            "status":{"state":"blocked","kind":"permission"},"template":"fixture",
            "labels":{"swarmhub.workspace":"agent","swarmhub.launch":key}
        })).unwrap()];
        assert_eq!(bot.model, "astra");
        assert_eq!(agent_of(&history, "core", &live, &bot), Some(0));
        let desk = Desk::default();
        let (tx, mut decision) = oneshot::channel();
        desk.pending.lock().unwrap().insert(7, Pending {
            info: Review { id:7, agent:bot.agent_name, tool:"SSH directory listing (fixture)".into(),
                provider:"Gemini", cwd:"/fixture".into(), arguments:"archived-project".into(),
                expires_ms:30_000, can_remember_read:false, can_remember_command:false, can_remember_command_hour:false, reviewer:None },
            launch:key.clone(), until:Instant::now() + WAIT, answer:Some(tx),
        });
        let summary = desk.summary(&history).unwrap().pop().unwrap();
        assert_eq!(summary.model.as_deref(), Some("Gemini Neon"));
        assert_eq!(summary.terminal, Some(("core".into(), "fixture-terminal".into(), 42)));
        assert!(desk.waits_on(&key).unwrap());
        assert!(!desk.waits_on("another-launch").unwrap());
        assert!(matches!(decision.try_recv(), Err(oneshot::error::TryRecvError::Empty)));
    }
}
