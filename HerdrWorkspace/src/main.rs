mod activity;
mod agent;
mod appearance;
mod approval_rules;
mod command_reviewer;
mod project_command_rules;
mod approvals;
mod attention;
mod bot_agent_settings;
mod bots;
mod codejob_activity;
mod codex_agent;
mod core;
mod desktop;
mod drive_access;
mod drive_files;
mod drive_oauth;
mod email_drafts;
mod events;
mod fleet_policy;
#[cfg(test)]
mod fleet_tests;
mod file_preview;
mod first_time;
mod gemini_agent;
mod antigravity_agent;
mod github_project;
mod grok_import;
mod group_forms;
mod group_handoffs;
mod group_preview;
mod group_routes;
mod groups;
mod helpers;
mod history;
mod job_reviews;
mod job_worker;
mod jobs;
mod live_reply;
mod machines;
mod markdown;
mod memory_proposals;
mod opencode_agent;
mod page_share;
mod pages;
mod outbound;
mod parks;
mod pdf_assets;
mod person_profile;
mod platform;
mod portable_profiles;
mod profile_avatars;
mod profiles;
mod projects;
mod pwa;
mod reactions;
mod results;
mod roster_sections;
mod routine_drafts;
mod routine_proposals;
mod routine_routes;
mod routines;
mod runtimes;
mod search;
mod service;
mod session_usage;
mod runtime_account;
mod skill_proposals;
mod skills;
mod skillshare;
mod slack_events;
mod task_files;
mod terminal;
mod tool_activity;
mod transcripts;
mod update;
mod vault;
mod warm;
mod webdav;

use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, Multipart, Path, Query, Request, State},
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
    response::{Html, IntoResponse, Response},
    routing::{get, post},
};
use core::{Core, Failure};
use history::{History, State as DeliveryState, StoreError};
use serde::Deserialize;
use serde_json::json;
use std::{net::Ipv4Addr, path::PathBuf};

#[derive(Clone)]
struct Workspace {
    core: Core,
    worker_core: Option<Core>,
    history: History,
    fleet_policy: Result<Option<fleet_policy::Authority>, fleet_policy::Error>,
    parks: parks::Service,
    approvals: approvals::Desk,
    drafts: live_reply::Drafts,
    connected_files: Option<webdav::Folder>,
    drive_access: drive_access::Desk,
    drive_files: Option<drive_files::Drive>,
    github_project: Option<github_project::Project>,
    vault: Option<vault::Vault>,
    slack: Option<slack_events::Signing>,
    port: u16,
    token: String,
}

impl Workspace {
    fn fleet_authority(&self) -> fleet_policy::Inspection {
        fleet_policy::inspect_configuration(&self.fleet_policy)
    }

    async fn send_to_agent_with_group(
        &self,
        agent: &core::Terminal,
        prompt: String,
        group: Option<group_preview::Binding>,
    ) -> Result<core::Delivery, Failure> {
        let _turn = task_turn(self, &agent.address, agent.created_ms).await;
        self.send_to_agent_waiting(agent, prompt, group, warm::Wait::Held).await
    }

    /// `wait`: who waits if the agent was started ahead of its first task and is not ready yet (`warm`).
    async fn send_to_agent_waiting(
        &self,
        agent: &core::Terminal,
        prompt: String,
        group: Option<group_preview::Binding>,
        wait: warm::Wait,
    ) -> Result<core::Delivery, Failure> {
        if !agent.uses_opencode_api() {
            return warm::send(self, agent, prompt, wait).await;
        }
        core::validate_task(&prompt)?;
        let current = self
            .core
            .agent(&agent.address, agent.created_ms)
            .await
            .map_err(|_| {
                Failure::Input("The OpenCode session could not be checked. The task was not sent.")
            })?;
        if !current.uses_opencode_api() || current.launch_key() != agent.launch_key() {
            return Err(Failure::Missing);
        }
        current.require_live()?;
        if current
            .status
            .as_ref()
            .is_some_and(|status| status.state == "blocked")
        {
            return Err(Failure::Rejected(
                "blocked".into(),
                "This agent needs attention before it can receive another task.".into(),
            ));
        }
        let prompt = person_profile::prompt(&self.history, current.display_name(), prompt)?;
        wait.check_outbox(&self.history)?;
        match group {
            Some(binding) => {
                opencode_agent::follow_up::send_group(
                    self.history.file(),
                    &current,
                    &prompt,
                    binding,
                )
                .await
            }
            None => opencode_agent::follow_up::send(self.history.file(), &current, &prompt).await,
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    if let Some(command) = std::env::args_os().nth(1) {
        if command == "codex-account" || command == "claude-account" {
            return runtime_account::cli(command == "codex-account").await;
        }
        if command == codex_agent::stream::COMMAND {
            return codex_agent::stream::run().await;
        }
        if command != "service" {
            return agent::run(&command);
        }
        // `service run` readies this process and then serves like a server started by hand.
        if std::env::args_os().nth(2).is_none_or(|verb| verb != "run") {
            return service::cli().await;
        }
        service::prepare_run()?;
    }
    let served = serve().await;
    // A new version that cannot start gives its place back to the one before it (`update`).
    if let Err(error) = &served {
        update::failed_start(&error.to_string());
    }
    served
}

async fn serve() -> Result<(), Box<dyn std::error::Error>> {
    update::init()?;
    let socket = PathBuf::from(
        std::env::var_os("HC_SOCKET")
            .ok_or("Set HC_SOCKET to the running Herdr Core's Unix socket.")?,
    );
    if !socket.is_absolute() {
        return Err("HC_SOCKET must be an absolute path.".into());
    }
    let token = std::env::var("SWARMHUB_ACCESS_TOKEN")
        .map_err(|_| "Set SWARMHUB_ACCESS_TOKEN to a random 64-character hex string.")?;
    if token.len() != 64 || !token.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return Err("SWARMHUB_ACCESS_TOKEN must be a random 64-character hex string.".into());
    }
    core::agent_cwd().map_err(|_| core::AGENT_CWD_ERROR)?;
    let port = std::env::var("SWARMHUB_PORT")
        .unwrap_or_else(|_| "8787".into())
        .parse()?;
    let listener = tokio::net::TcpListener::bind((Ipv4Addr::LOCALHOST, port)).await?;
    let port = listener.local_addr()?.port();
    let history = History::open()?;
    let fleet_policy = fleet_policy::Authority::configured(fleet_policy::Role::Bridge);
    if let Err(error) = &fleet_policy {
        eprintln!("SwarmHub fleet authority held: {error}");
    }
    if let Ok(Some(store)) = &fleet_policy {
        match history.db() {
            Ok(mut db) => {
                if let Err(error) = store.audit(&mut db) {
                    eprintln!("SwarmHub fleet policy audit unavailable: {error}");
                }
            }
            Err(_) => eprintln!("SwarmHub fleet policy audit could not open the journal."),
        }
    }
    let vault = vault::Vault::configured(history.file())?;
    let workspace = Workspace {
        worker_core: jobs::configured_core(&socket),
        core: Core(socket),
        connected_files: webdav::Folder::configured(&history, vault.as_ref())?,
        drive_access: drive_access::Desk::default(),
        drive_files: drive_files::Drive::configured(&history, vault.as_ref(), port)?,
        github_project: github_project::Project::configured(&history, vault.as_ref())?,
        slack: slack_events::Signing::configured(&history, vault.as_ref())?,
        history,
        fleet_policy,
        parks: parks::Service::default(),
        approvals: approvals::Desk::default(),
        drafts: live_reply::Drafts::default(),
        vault,
        port,
        token,
    };
    if let Err(error) = approvals::listen(workspace.clone()) {
        eprintln!(
            "SwarmHub browser approvals unavailable; the provider can still prompt in its terminal: {error}"
        );
    }
    if vault::listen(workspace.clone()).is_err() {
        eprintln!("SwarmHub agent access to the Vault is unavailable.");
    }
    routine_routes::start(workspace.clone());
    results::start(workspace.history.clone());
    page_share::start_cleanup(workspace.history.clone());
    if let Err(error) = live_reply::listen(workspace.clone()) {
        eprintln!(
            "SwarmHub live reply previews unavailable; final replies can still be saved: {error}"
        );
    }
    if let Err(error) = drive_access::listen(workspace.clone()) {
        eprintln!("SwarmHub agent access to Drive is unavailable: {error}");
    }
    if let Err(error) = github_project::access::listen(workspace.clone()) {
        eprintln!("SwarmHub agent access to GitHub is unavailable: {error}");
    }
    helpers::start_serving(workspace.clone());
    bots::start_serving(workspace.clone());
    warm::start_sweeping(workspace.clone());
    service::keep_core_running();
    workspace.history.watch_changes();
    let app = workspace_router(workspace);
    println!("SwarmHub · http://127.0.0.1:{port}");
    update::started();
    axum::serve(listener, app).await?;
    Ok(())
}

fn workspace_router(workspace: Workspace) -> Router {
    Router::new()
        .route(
            "/",
            get(|| async { Html(include_str!("../web/index.html")) }),
        )
        .route(
            "/workspace.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
                    include_str!("../web/workspace.css"),
                )
            }),
        )
        .route(
            "/workspace.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/workspace.js"),
                )
            }),
        )
        .route(
            "/groups.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/groups.js"),
                )
            }),
        )
        .route(
            "/runtime-setup.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/runtime-setup.js"),
                )
            }),
        )
        .route(
            "/voice-memos.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/voice-memos.js"),
                )
            }),
        )
        .route(
            "/dictation.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/dictation.js"),
                )
            }),
        )
        .merge(group_routes::routes())
        .merge(group_handoffs::routes())
        .merge(helpers::routes())
        .merge(bots::routes())
        .merge(person_profile::routes())
        .merge(jobs::routes())
        .merge(machines::routes())
        .merge(projects::routes())
        .merge(events::routes())
        .merge(reactions::routes())
        .merge(grok_import::routes())
        .merge(routine_routes::routes())
        .merge(routine_proposals::routes())
        .merge(memory_proposals::routes())
        .merge(email_drafts::routes())
        .merge(runtimes::model_discovery::routes())
        .merge(runtime_account::routes())
        .merge(opencode_agent::models::routes())
        .merge(slack_events::routes())
        .merge(terminal::routes())
        .merge(desktop::routes())
        .merge(approvals::routes())
        .merge(parks::routes())
        .merge(job_reviews::routes())
        .merge(outbound::routes())
        .merge(attention::routes())
        .merge(activity::routes())
        .merge(skills::routes())
        .merge(skillshare::routes())
        .merge(skill_proposals::routes())
        .merge(profiles::routes())
        .merge(pwa::routes())
        .merge(appearance::routes())
        .merge(portable_profiles::routes())
        .merge(drive_access::routes())
        .merge(roster_sections::routes())
        .merge(pages::routes())
        .merge(page_share::routes())
        .merge(pdf_assets::routes())
        .merge(search::routes())
        .merge(live_reply::routes())
        .merge(transcripts::routes())
        .merge(update::routes())
        .merge(task_files::routes())
        .merge(webdav::routes())
        .merge(drive_files::routes())
        .merge(drive_oauth::routes())
        .merge(github_project::routes())
        .merge(vault::routes())
        .route("/api/workspace", get(workspace_state))
        .route("/api/codejobs/{host}/{owner}/{job}/output", get(codejob_activity::log_tail))
        .route("/api/agents/{id}/{created}/geometry", get(terminal_geometry))
        .route("/api/agents", post(launch))
        .route(
            "/api/agents/with-files",
            post(launch_with_files).layer(DefaultBodyLimit::max(task_files::UPLOAD_LIMIT)),
        )
        .route("/api/agents/{id}/{created}/output", get(output))
        .route("/api/agents/{id}/{created}/steer", post(steer))
        .route("/api/agents/{id}/{created}/steer/with-files", post(steer_files).layer(DefaultBodyLimit::max(task_files::UPLOAD_LIMIT)))
        .route("/api/agents/{id}/{created}/messages", post(send))
        .route(
            "/api/agents/{id}/{created}/messages/with-files",
            post(send_with_files).layer(DefaultBodyLimit::max(task_files::UPLOAD_LIMIT)),
        )
        .route(
            "/api/agents/{id}/{created}/attachments",
            post(attach_file).layer(DefaultBodyLimit::max(core::MAX_FILE)),
        )
        .route("/api/agents/{id}/{created}/snapshots", post(save_snapshot))
        .route("/api/history/{core}/{id}/{created}", get(conversation))
        .route(
            "/api/history/{core}/{id}/{created}/threads/{root}",
            get(direct_thread),
        )
        .route(
            "/direct-threads.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/direct-threads.js"),
                )
            }),
        )
        .route(
            "/reply-markup.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/reply-markup.js"),
                )
            }),
        )
        .route("/api/library", get(library))
        .route("/api/library/agent", get(agent_library))
        .route("/api/library/pins/{kind}/{id}", post(set_library_pin))
        .route("/api/library/conversations", get(saved_conversations))
        .route("/api/library/files", get(files))
        .route("/api/library/files/{id}", get(file_info))
        .route("/api/library/files/{id}/image", get(file_image))
        .route("/api/library/files/{id}/download", get(download_file))
        .route("/api/library/{id}", get(snapshot))
        .route("/api/agents/{id}/{created}/interrupt", post(interrupt))
        .route("/api/agents/{id}/{created}/end", post(end))
        .route("/api/agents/{id}/{created}/end-if-idle", post(end_if_idle))
        .layer(DefaultBodyLimit::max(128 * 1024))
        .layer(middleware::from_fn_with_state(
            workspace.clone(),
            local_browser,
        ))
        .with_state(workspace)
}

async fn local_browser(State(state): State<Workspace>, request: Request, next: Next) -> Response {
    let local_hook = (request.uri().path().starts_with("/hooks/routines/")
        || request.uri().path() == "/hooks/slack")
        && !request.headers().contains_key(header::ORIGIN);
    let api = request.uri().path().starts_with("/api/");
    let authorized = api && request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .is_some_and(|value| token_matches(value, &state.token));
    let forwarded = (authorized && ssh_forward(request.headers(), state.port))
        || (request.method() == axum::http::Method::GET
            && terminal::forwarded_resource(request.uri().path(), request.headers()));
    if !forwarded
        && (!local_host(request.headers(), state.port)
            || (request.method() == axum::http::Method::POST
                && !local_hook
                && !same_origin(request.headers(), state.port)))
    {
        return StatusCode::FORBIDDEN.into_response();
    }
    if api && !authorized {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"Enter the workspace access token to connect."})),
        )
            .into_response();
    }
    update::seen(request.headers());
    let pdf_worker = request.uri().path() == "/vendor/pdfjs/pdf.worker.min.mjs";
    let page_viewer = request.uri().path() == "/view/page";
    let mut response = next.run(request).await;
    let headers = response.headers_mut();
    headers.insert(header::CACHE_CONTROL, "no-store".parse().unwrap());
    headers.insert(header::X_CONTENT_TYPE_OPTIONS, "nosniff".parse().unwrap());
    let policy = if page_viewer {
        "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'".into()
    } else if pdf_worker {
        // Image decoding in the PDF parser worker may compile WebAssembly.
        "default-src 'none'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'".into()
    } else {
        format!(
            "default-src 'none'; script-src 'self'; worker-src 'self'; manifest-src 'self'; style-src 'self' 'unsafe-inline'; img-src blob: 'self'; media-src blob:; font-src data:; connect-src 'self' ws://127.0.0.1:{} ws://localhost:{}; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
            state.port, state.port
        )
    };
    headers.insert(header::CONTENT_SECURITY_POLICY, policy.parse().unwrap());
    response
}

fn token_matches(actual: &str, expected: &str) -> bool {
    actual.len() == expected.len()
        && actual
            .bytes()
            .zip(expected.bytes())
            .fold(0, |difference, (actual, expected)| {
                difference | (actual ^ expected)
            })
            == 0
}

fn local_host(headers: &HeaderMap, port: u16) -> bool {
    headers
        .get(header::HOST)
        .and_then(|v| v.to_str().ok())
        .is_some_and(|host| {
            host == format!("127.0.0.1:{port}") || host == format!("localhost:{port}")
        })
}

fn same_origin(headers: &HeaderMap, port: u16) -> bool {
    let host = headers.get(header::HOST).and_then(|v| v.to_str().ok());
    let origin = headers.get(header::ORIGIN).and_then(|v| v.to_str().ok());
    local_host(headers, port)
        && host.is_some_and(|host| origin == Some(format!("http://{host}").as_str()))
}

/// A token-authenticated desktop client can reach this API through a loopback SSH listener on
/// another port. URLSession may substitute that listener’s authority in Host.
fn ssh_forward(headers: &HeaderMap, port: u16) -> bool {
    let loopback_listener = headers
        .get(header::HOST)
        .and_then(|value| value.to_str().ok())
        .and_then(|host| host.rsplit_once(':'))
        .is_some_and(|(host, port)| {
            matches!(host, "127.0.0.1" | "localhost") && port.parse::<u16>().is_ok_and(|p| p > 0)
        });
    loopback_listener
        && headers.get("x-swarmhub-ssh-forward").is_some_and(|value| value == "1")
        && headers.get(header::ORIGIN).is_some_and(|origin| {
            origin == format!("http://127.0.0.1:{port}").as_str()
        })
}

#[cfg(test)]
#[test]
fn ssh_forward_requires_a_loopback_listener_and_the_bridge_origin() {
    let mut headers = HeaderMap::new();
    headers.insert(header::HOST, "127.0.0.1:49152".parse().unwrap());
    headers.insert(header::ORIGIN, "http://127.0.0.1:8787".parse().unwrap());
    assert!(!ssh_forward(&headers, 8787));
    headers.insert("x-swarmhub-ssh-forward", "1".parse().unwrap());
    assert!(ssh_forward(&headers, 8787));
    assert!(!ssh_forward(&headers, 8788));
    headers.insert(header::HOST, "external.test:49152".parse().unwrap());
    assert!(!ssh_forward(&headers, 8787));
}

impl IntoResponse for Failure {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            Self::Unreachable => (StatusCode::SERVICE_UNAVAILABLE, "Cannot reach Herdr Core. Check that it is running and that the workspace points to its socket.".into()),
            Self::Protocol => (StatusCode::BAD_GATEWAY, "Herdr Core did not return a compatible response.".into()),
            Self::Uncertain => (StatusCode::BAD_GATEWAY, "Herdr Core did not confirm the action. Check the agent's output before trying again.".into()),
            Self::Missing => (StatusCode::NOT_FOUND, "This agent session is no longer available.".into()),
            Self::Input(message) => (StatusCode::UNPROCESSABLE_ENTITY, message.into()),
            Self::Rejected(kind, message) => {
                let status = match kind.as_str() {
                    "not_found" => StatusCode::NOT_FOUND,
                    "blocked" | "status_mismatch" | "name_taken" | "finished" | warm::NOT_READY => StatusCode::CONFLICT,
                    "invalid_params" | "invalid_template" => StatusCode::UNPROCESSABLE_ENTITY,
                    _ => StatusCode::BAD_GATEWAY,
                };
                // A warm agent that is still starting: a client tells this refusal from the others by its kind.
                if kind == warm::NOT_READY {
                    return (status, Json(json!({ "error":message, "kind":kind }))).into_response();
                }
                (status, message)
            }
        };
        (status, Json(json!({ "error":message }))).into_response()
    }
}

impl IntoResponse for StoreError {
    fn into_response(self) -> Response {
        (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({
            "error":"The workspace could not access its saved history. Check the workspace server."
        }))).into_response()
    }
}

#[derive(Debug)]
enum ApiError {
    Core(Failure),
    Storage(StoreError),
    NotFound,
    Conflict(&'static str),
    PayloadTooLarge(&'static str),
    ConnectedFiles(&'static str),
    TooMany(&'static str),
}

impl From<Failure> for ApiError {
    fn from(value: Failure) -> Self {
        Self::Core(value)
    }
}

impl From<StoreError> for ApiError {
    fn from(value: StoreError) -> Self {
        Self::Storage(value)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        match self {
            Self::Core(error) => error.into_response(),
            Self::Storage(error) => error.into_response(),
            Self::Conflict(error) => {
                (StatusCode::CONFLICT, Json(json!({ "error": error }))).into_response()
            }
            Self::PayloadTooLarge(error) => {
                (StatusCode::PAYLOAD_TOO_LARGE, Json(json!({"error":error}))).into_response()
            }
            Self::ConnectedFiles(error) => {
                (StatusCode::BAD_GATEWAY, Json(json!({"error":error}))).into_response()
            }
            Self::TooMany(error) => {
                (StatusCode::TOO_MANY_REQUESTS, Json(json!({"error":error}))).into_response()
            }
            Self::NotFound => (
                StatusCode::NOT_FOUND,
                Json(json!({
                "error":"This saved item is no longer available."
                })),
            )
                .into_response(),
        }
    }
}

fn delivery_failure(error: &Failure) -> (DeliveryState, Option<&str>) {
    // After the call reaches Core, a rejected send can still have partially typed
    // the payload. Only report a definite failure where none could have been sent.
    match error {
        Failure::Input(detail) => (DeliveryState::NotSent, Some(*detail)),
        Failure::Missing | Failure::Unreachable => (DeliveryState::NotSent, None),
        Failure::Rejected(kind, detail)
            if matches!(
                kind.as_str(),
                "blocked"
                    | "status_mismatch"
                    | "name_taken"
                    | "config"
                    | "invalid_params"
                    | "invalid_template"
                    | "spawn_failed"
                    | warm::NOT_READY
            ) =>
        {
            (DeliveryState::NotSent, Some(detail.as_str()))
        }
        _ => (DeliveryState::Unconfirmed, None),
    }
}

fn record_failure(history: &History, record: i64, error: &Failure) -> Result<(), StoreError> {
    let (state, detail) = delivery_failure(error);
    history.finish(record, state, detail, None)
}

/// An agent as `/api/workspace` lists it and as its event stream reports it (`events`).
#[derive(serde::Serialize)]
struct AgentView<'a> {
    #[serde(flatten)]
    terminal: &'a core::Terminal,
    opencode_api: bool,
    /// Set for a helper: the agent that started it (`helpers`).
    #[serde(skip_serializing_if = "Option::is_none")]
    parent: Option<helpers::ParentRef>,
    /// Set for a running Codex session that could not show its replies as they are written: why
    /// (`codex_agent::stream`). Its replies still arrive, each in one piece.
    #[serde(skip_serializing_if = "Option::is_none")]
    reply_arrives_whole: Option<String>,
    #[serde(flatten)]
    launch_status: codex_agent::stream::LaunchStatus,
    vault_session_stale: bool,
    /// `ready`, `warm` and `warm_ends_ms`: whether a task sent now is typed at once (`warm`).
    #[serde(flatten)]
    start: warm::Start,
}

impl<'a> AgentView<'a> {
    fn new(
        w: &Workspace,
        terminal: &'a core::Terminal,
        parent: Option<helpers::ParentRef>,
    ) -> Self {
        let history = &w.history;
        Self {
            terminal,
            vault_session_stale: terminal.state == "live" && terminal.launch_key().is_some()
                && w.vault.as_ref().is_some_and(|v| v.predates_session_credentials(terminal.created_ms)),
            launch_status: codex_agent::stream::launch_status(history, terminal.launch_key()),
            opencode_api: terminal.uses_opencode_api(),
            parent,
            reply_arrives_whole: terminal
                .launch_key()
                .filter(|_| terminal.state == "live")
                .and_then(|key| codex_agent::stream::whole_reason(history.file(), key)),
            start: warm::Start::of(history, terminal),
        }
    }
}

#[derive(Default, Deserialize)]
struct WorkspaceQuery {
    #[serde(default)]
    codejobs: bool,
}

async fn workspace_state(State(w): State<Workspace>, Query(query): Query<WorkspaceQuery>) -> Result<Json<serde_json::Value>, ApiError> {
    let hello = w.core.identify().await?;
    let (agents, templates) = tokio::try_join!(w.core.agents(), w.core.templates())?;
    let catalog = runtimes::Catalog::load(w.history.file());
    let templates = runtimes::beta_last(
        templates
            .into_iter()
            .map(|template| catalog.choice(template))
            .collect(),
    );
    for agent in &agents {
        w.history.recover_launch(&hello.core.id, agent)?;
        w.history.link_profile(&hello.core.id, agent)?;
    }
    let parents = helpers::parents(&w.history, &hello.core.id, &agents)?;
    let session_parents = if query.codejobs {
        Some((helpers::session_parents(&w.history, &hello.core.id, &agents)?,
              helpers::archived_parents(&w.history, &hello.core.id, &agents)?))
    } else { None };
    let agents: Vec<_> = agents
        .iter()
        .map(|terminal| {
            (
                terminal,
                terminal.launch_key().and_then(|key| parents.get(key)),
            )
        })
        // A helper that has ended leaves the roster; its conversation stays in the history.
        .filter(|(terminal, helper)| helper.is_none() || terminal.state == "live")
        .map(|(terminal, helper)| AgentView::new(&w, terminal, helper.cloned().flatten()))
        .collect();
    let timezone = {
        let db = w.history.db()?;
        person_profile::effective_timezone(&db).map_err(StoreError::from)?
    };
    let mut roster = json!({"timezone":timezone,"version":hello.version,"core":hello.core.id,"bridge":update::info(),"agents":agents,"templates":templates,
               "demo":std::env::var("SWARMHUB_DEMO").as_deref() == Ok("1"),
               "runtime_catalog_warning":catalog.warning,
               "attachments":hello.supports("terminal.put"),"terminal_preview":true,"bot_workspaces":true,"routine_transfers":true,"launch_attachments":true,"codex_turn_steer":true,"helper_results":true,"end_if_idle":true,
               "workspace_root":core::bot_workspace_root().ok().flatten(),"terminal_attach":hello.supports("terminal.attach"),
               "connected_files":w.connected_files.is_some() || w.drive_files.as_ref().is_some_and(drive_files::Drive::connected)});
    if let Some((session_parents, archived_helper_parents)) = session_parents {
        roster["helper_session_parents"] = json!(session_parents);
        roster["archived_helper_parents"] = json!(archived_helper_parents);
        roster["codejob_activity"] = json!(codejob_activity::snapshot(&w.core, hello.supports("machine.exec")).await);
    }
    Ok(Json(roster))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Launch {
    name: String,
    template: String,
    turn_reference: Option<String>,
    /// The first task. Left out with `warm`.
    #[serde(default)]
    task: String,
    /// Start the agent's program and type nothing: the first task comes later, as a message (`warm`).
    #[serde(default)]
    warm: bool,
    profile_id: Option<i64>,
    expected_runtime: Option<runtimes::Runtime>,
    model_choice: Option<runtimes::ModelChoice>,
    model_id: Option<String>,
    workspace_id: Option<String>,
    expected_core: Option<String>,
    standing_instructions: Option<String>,
    instructions_revision: Option<i64>,
    #[serde(default)]
    collect_results: bool,
    /// Ids of the projects on other machines this agent may use (`projects`).
    #[serde(default)]
    projects: Vec<i64>,
}

#[derive(serde::Serialize)]
struct CreatedLaunch {
    #[serde(flatten)]
    terminal: core::Terminal,
    core: String,
    profile_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    open_code_first_task: Option<opencode_agent::first_task::Outcome>,
    #[serde(flatten)]
    start: warm::Start,
}

async fn launch(
    State(w): State<Workspace>,
    Json(body): Json<Launch>,
) -> Result<impl IntoResponse, ApiError> {
    Ok((
        StatusCode::CREATED,
        Json(launch_agent(w, body, None, None, vec![]).await?),
    ))
}

async fn launch_with_files(
    State(w): State<Workspace>,
    multipart: Multipart,
) -> Result<impl IntoResponse, ApiError> {
    let (body, files): (Launch, _) = task_files::read(multipart).await?;
    if body.expected_core.is_none() || body.warm {
        return Err(Failure::Input("Choose the current Herdr Core and include a first task with attachments.").into());
    }
    Ok((
        StatusCode::CREATED,
        Json(launch_agent(w, body, None, None, files).await?),
    ))
}

/// Starts an agent as `POST /api/agents` asks. `own_instructions` is for a start the workspace decides on
/// itself (`bots`, for a bot whose agent is not running): those instructions go with the first task, whatever
/// the profile has saved.
struct CompletionStart {
    core: String,
    owner: String,
    agent_name: String,
}

async fn launch_agent(
    w: Workspace,
    body: Launch,
    own_instructions: Option<String>,
    fixture: Option<CompletionStart>,
    files: Vec<groups::Upload>,
) -> Result<CreatedLaunch, ApiError> {
    if !body.warm {
        core::validate_task(&body.task)?;
    } else if !body.task.is_empty() || body.turn_reference.is_some() {
        return Err(Failure::Input(
            "Leave out the task to start an agent ahead of it, or leave out warm to start it with the task.",
        )
        .into());
    }
    if (body.profile_id.is_some() && body.standing_instructions.is_some())
        || (body.profile_id.is_none() && body.instructions_revision.is_some())
    {
        return Err(Failure::Input("Use the saved instructions for an existing profile.").into());
    }
    let first_instructions =
        profiles::validate_instructions(body.standing_instructions.as_deref().unwrap_or(""))?;
    let hello = w.core.identify().await?;
    if body.expected_core.as_ref().is_some_and(|core| *core != hello.core.id) {
        return Err(ApiError::Conflict("Herdr Core changed. The task was not sent."));
    }
    if fixture.as_ref().is_some_and(|fixture| {
        fixture.core != hello.core.id || !hello.supports_completion_start()
    }) {
        return Err(ApiError::Conflict("Herdr Core changed before the fixture launch."));
    }
    if let Some(id) = body.profile_id {
        let name = w
            .history
            .profile_runtime_name(id)?
            .ok_or(ApiError::NotFound)?;
        if name != body.name {
            return Err(Failure::Input("Start this profile with its saved runtime name.").into());
        }
        for agent in w.core.agents().await? {
            if agent.state == "live"
                && w.history.session_profile(&hello.core.id, &agent)? == Some(id)
            {
                return Err(ApiError::Conflict(
                    "End the running session before starting another session for this profile.",
                ));
            }
        }
    }
    let template = w
        .core
        .templates()
        .await?
        .into_iter()
        .find(|template| {
            template.name == body.template
                && template.error.is_none()
                && core::valid_name(&template.name)
        })
        .ok_or(Failure::Input("Choose an available Herdr template."))?;
    let api_first_task = opencode_agent::first_task::OptIn::new(&template).is_some();
    if !api_first_task && opencode_agent::first_task::OptIn::requested(&template) {
        return Err(Failure::Input(runtimes::INVALID_API_TEMPLATE).into());
    }
    if body.warm && api_first_task {
        return Err(Failure::Input(
            "This template gives OpenCode its first task as it starts, so it cannot be started ahead of one.",
        )
        .into());
    }
    let catalog = runtimes::Catalog::load(w.history.file());
    let runtime = catalog.runtime(&template);
    if body
        .expected_runtime
        .as_ref()
        .is_some_and(|expected| expected != &runtime)
    {
        return Err(ApiError::Conflict(
            "The runtime labels changed. Reopen the launch dialog and review your selection.",
        ));
    }
    if body.model_choice.is_some() && body.model_id.is_some() {
        return Err(Failure::Input("Choose a preset or enter a model ID.").into());
    }
    let (runtime, model) = if let Some(choice) = body.model_choice {
        let (target, _) = catalog.models(&template)
            .filter(|(_, models)| models.contains(&&choice))
            .ok_or(ApiError::Conflict(
                "This model choice is no longer available. Reopen the launch dialog and choose a model.",
            ))?;
        (
            runtime.with_model(target, &choice),
            Some(target.selection(&choice.id)),
        )
    } else if let Some(id) = body.model_id.as_deref() {
        let (target, models) = catalog.models(&template).ok_or(Failure::Input(
            "This template does not support selecting a model.",
        ))?;
        if !target.accepts(id) {
            return Err(Failure::Input("Enter a valid model ID for this template.").into());
        }
        let runtime = match models.into_iter().find(|model| model.id == id) {
            Some(preset) => runtime.with_model(target, preset),
            None => runtime.with_model_id(target, id),
        };
        (runtime, Some(target.selection(id)))
    } else {
        (runtime, None)
    };
    let runtime = serde_json::to_string(&runtime).map_err(|_| StoreError)?;
    let project_hint = projects::launch_hint(
        &projects::wanted(&w.history, &body.projects)?
            .ok_or(Failure::Input(projects::LAUNCH_SHAPE))?,
    );
    // No awaits between checking the saved revision and recording the launch.
    let instructions = if let Some(own) = own_instructions {
        own
    } else if let Some((id, revision)) = body.profile_id.zip(body.instructions_revision) {
        w.history.saved_instructions(id, revision)?.ok_or(ApiError::Conflict(
            "Standing instructions changed. Reopen the launch dialog and review the new version.",
        ))?
    } else {
        first_instructions.to_owned()
    };
    // The agent of a registered bot reads the workspace's notes for bots with its first task (`bots`).
    let bot_note = bots::launch_note(&w, &body.name)?;
    let hints: Vec<&str> = body
        .collect_results
        .then_some(warm::RESULTS_HINT)
        .into_iter()
        .chain(project_hint.as_deref())
        .chain(bot_note.as_ref().map(|(_, note)| note.as_str()))
        .chain(w.vault.as_ref().map(|_| vault::NOTE))
        .collect();
    let folder = core::bot_workspace(body.workspace_id.as_deref(), &body.name)
        .map_err(|_| Failure::Input("Could not prepare this bot’s private workspace folder."))?;
    if let Some(folder) = &folder
        && serde_json::from_str::<serde_json::Value>(&runtime)
            .ok()
            .and_then(|labels| labels["harness"].as_str().map(str::to_owned))
            .is_some_and(|harness| harness.to_ascii_lowercase().contains("claude"))
    {
        first_time::trust_workspace(w.history.file(), folder)
            .map_err(|_| Failure::Input("Claude Code’s folder trust could not be saved. Check Claude Code’s settings on the host."))?;
    }
    let staged = if files.is_empty() {
        None
    } else {
        let directory = folder.as_deref().ok_or(Failure::Input("This bot needs a workspace folder for attachments."))?;
        Some(task_files::stage_launch_files(directory, &files)?)
    };
    let task = runtime_task(&body.task, body.turn_reference.as_deref())?;
    let first_task = staged.as_ref().map(|(_, suffix)| format!("{task}{suffix}"));
    // A warm agent reads the same words around its first message. Check now that a message still fits.
    let message = warm::first_message(
        if body.warm {
            "A first message."
        } else {
            first_task.as_deref().unwrap_or(&task)
        },
        &instructions,
        &hints,
    )?;
    let message = if body.warm {
        message
    } else {
        person_profile::prompt(&w.history, &body.name, message)?
    };
    if let Some(fixture) = &fixture {
        let db = w.history.db()?;
        if !bots::one(&db, &fixture.owner).map_err(StoreError::from)?.is_some_and(|bot| {
            bot.takes_messages && bot.agent_name == fixture.agent_name
        }) {
            return Err(ApiError::Conflict("The owner changed before the fixture launch."));
        }
    }
    let (owner, settings) = {
        let db = w.history.db()?;
        let owner = resolve_launch_owner(
            &db,
            body.workspace_id.as_deref(),
            bot_note.as_ref().map(|(id, _)| id.as_str()),
            &body.name,
        )
        .map_err(StoreError::from)?;
        let settings = match owner.as_deref() {
            Some(id) => bot_agent_settings::for_bot(&db, id).map_err(StoreError::from)?,
            None => bot_agent_settings::Settings::default(),
        };
        (owner, settings)
    };
    let auto_mode = settings.auto_mode;
    let review_every_tool = settings.review_every_tool;
    if review_every_tool && !runtimes::supports_tool_review(&template.command) {
        return Err(Failure::Input("This bot requires approval before each tool call. Choose a standard Claude template.").into());
    }
    let started = if body.warm {
        warm::start(
            &w.history,
            &hello.core.id,
            &body.name,
            body.profile_id,
            &runtime,
            &instructions,
            &hints,
        )?
    } else {
        w.history.start_launch(
            &hello.core.id,
            &body.name,
            &body.task,
            body.profile_id,
            &runtime,
            &instructions,
        )?
    };
    let (record, key) = started.ok_or(ApiError::Conflict(
        "A session for this profile is already starting.",
    ))?;
    if let Some(id) = owner {
        if let Err(error) = w.history.db().and_then(|db| {
            db.execute("UPDATE journal SET parent_bot_id=?1,launch_auto=?3,launch_tool_review=?4 WHERE id=?2", rusqlite::params![id, record, auto_mode, review_every_tool])
                .map(|_| ()).map_err(StoreError::from)
        }) {
            w.history.finish(record, DeliveryState::NotSent, Some("The bot for this launch could not be saved."), None)?;
            return Err(error.into());
        }
    }
    if !files.is_empty() {
        if let Err(error) = w.history.save_launch_files(record, &files) {
            w.history.finish(record, DeliveryState::NotSent, Some("The attachments could not be saved."), None)?;
            return Err(error.into());
        }
    }
    // The note is left out of a first task that has no room for it; a warm agent gets it with its first task.
    let noted = bot_note
        .filter(|(_, note)| body.warm || message.contains(note.as_str()))
        .map(|(bot, _)| (w.history.clone(), bot, key.clone()));
    if !body.projects.is_empty() && !projects::grant_launch(&w.history, &key, &body.projects)? {
        w.history.finish(
            record,
            DeliveryState::NotSent,
            Some("A project for this session was removed while it was starting."),
            None,
        )?;
        return Err(Failure::Input(projects::LAUNCH_SHAPE).into());
    }
    let results = if body.collect_results {
        match results::enable(&w.history, record) {
            Ok(path) => Some(path),
            Err(_) => {
                w.history.finish(
                    record,
                    DeliveryState::NotSent,
                    Some("The results folder could not be created."),
                    None,
                )?;
                return Err(Failure::Input(
                    "Could not create a private folder for this session’s results.",
                )
                .into());
            }
        }
    } else {
        None
    };
    if let Some((directory, _)) = staged {
        // The agent will read these paths after launch, including when a reply is disconnected.
        let _ = directory.keep();
    }
    let action = tokio::spawn(async move {
        use opencode_agent::first_task::{Outcome, Prepared};
        let journal = w.history.file().to_str().ok_or(Failure::Input(
            "The workspace data directory must have a UTF-8 path.",
        ))?;
        let approval_socket = approvals::socket_path(&w.history);
        let prepared = if api_first_task {
            match Prepared::new(w.history.file(), &key, &message) {
                Ok(task) if task.path().to_str().is_some() => Some(task),
                _ => {
                    let description = "Could not prepare the first task for OpenCode.";
                    w.history
                        .finish(record, DeliveryState::NotSent, Some(description), None)
                        .map_err(|_| Failure::Uncertain)?;
                    return Err(Failure::Input(description));
                }
            }
        } else {
            None
        };
        let vault_session = w.vault.as_ref().and_then(|vault| vault.session(&key, &body.name));
        gemini_agent::startup::watch(&w.core, w.history.file(), &key, &template);
        match w
            .core
            .launch(
                body.name,
                if api_first_task {
                    core::LaunchSource::DirectOpenCode(body.template, template.command)
                } else if let Some(fixture) = fixture {
                    core::LaunchSource::FixtureWarm {
                        template: body.template,
                        core: fixture.core,
                    }
                } else if body.warm {
                    core::LaunchSource::Warm(body.template)
                } else {
                    core::LaunchSource::Template(body.template, message)
                },
                core::LaunchEnv {
                    key: &key,
                    auto_mode,
                    review_every_tool,
                    journal,
                    approval_socket: approval_socket.to_str().unwrap_or_default(),
                    vault_session: vault_session.as_deref(),
                    model: model.as_ref(),
                    results: results.as_deref().and_then(std::path::Path::to_str),
                    opencode_first_task: prepared.as_ref().and_then(|task| task.path().to_str()),
                    helper: None,
                    workspace: folder.as_deref().and_then(std::path::Path::to_str),
                },
            )
            .await
        {
            Ok(mut terminal) => {
                let open_code_first_task = if let Some(prepared) = prepared {
                    Some(prepared.outcome().await)
                } else {
                    None
                };
                let (state, detail) = match (open_code_first_task, &terminal.first_message) {
                    (Some(Outcome::Submitted), _)
                    | (None, Some(core::FirstMessage { sent: true, .. })) => {
                        (DeliveryState::Sent, None)
                    }
                    (Some(Outcome::NotSent), _) => (
                        DeliveryState::NotSent,
                        Some("OpenCode did not accept the first task."),
                    ),
                    (Some(Outcome::Uncertain), _) => (
                        DeliveryState::Unconfirmed,
                        Some(
                            "OpenCode did not confirm the first task. Check the conversation before resending.",
                        ),
                    ),
                    (None, Some(first)) => (DeliveryState::NotSent, first.reason.as_deref()),
                    // Nothing was to be typed: the program runs, which is all a warm launch asks for.
                    (None, None) if body.warm => (DeliveryState::Sent, None),
                    (None, None) => (DeliveryState::Unconfirmed, None),
                };
                w.history
                    .finish(record, state, detail, Some(&terminal))
                    .map_err(|_| Failure::Uncertain)?;
                w.history
                    .link_profile(&hello.core.id, &terminal)
                    .map_err(|_| Failure::Uncertain)?;
                let profile_id = w
                    .history
                    .session_profile(&hello.core.id, &terminal)
                    .map_err(|_| Failure::Uncertain)?;
                if let Some(outcome) = open_code_first_task {
                    terminal.first_message = Some(core::FirstMessage {
                        sent: outcome == Outcome::Submitted,
                        reason: detail.map(str::to_owned),
                    });
                }
                Ok(CreatedLaunch {
                    start: warm::Start::of(&w.history, &terminal),
                    terminal,
                    core: hello.core.id,
                    profile_id,
                    open_code_first_task,
                })
            }
            Err(error) => {
                let error = match &error {
                    Failure::Rejected(kind, _) if kind == "invalid_template" => {
                        Failure::Input("Herdr could not load this template.")
                    }
                    _ => error,
                };
                record_failure(&w.history, record, &error).map_err(|_| Failure::Uncertain)?;
                Err(error)
            }
        }
    });
    let result = action.await.map_err(|_| Failure::Uncertain)??;
    if let Some((history, bot, key)) = noted {
        let _ = bots::noted(&history, &bot, &key);
    }
    Ok(result)
}

async fn terminal_geometry(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<impl IntoResponse, Failure> {
    let agent = w.core.agent(&id, created).await?;
    agent.require_live()?;
    Ok(Json(json!({"cols":agent.cols,"rows":agent.rows})))
}

async fn output(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<impl IntoResponse, Failure> {
    let agent = w.core.agent(&id, created).await?;
    Ok(Json(w.core.output(&agent).await?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Message {
    text: String,
    turn_reference: Option<String>,
    reply_to: Option<ReplyTarget>,
    expected_core: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReplyTarget {
    core: String,
    id: i64,
}

async fn send(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    Json(body): Json<Message>,
) -> Result<Response, ApiError> {
    send_message(w, id, created, body, vec![]).await
}

async fn send_with_files(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    multipart: Multipart,
) -> Result<Response, ApiError> {
    let (body, files): (Message, _) = task_files::read(multipart).await?;
    if body.expected_core.is_none() {
        return Err(Failure::Input(
            "Choose the agent’s current Herdr Core before sending attachments.",
        )
        .into());
    }
    send_message(w, id, created, body, files).await
}

/// Serialize the availability check and reservation with sends to this terminal.
async fn task_turn(w: &Workspace, address: &str, created: u64) -> tokio::sync::OwnedMutexGuard<()> {
    use std::{
        collections::BTreeMap,
        sync::{Arc, Mutex, Weak},
    };
    type Key = (PathBuf, String, u64);
    type Gate = tokio::sync::Mutex<()>;
    static TURNS: Mutex<BTreeMap<Key, Weak<Gate>>> = Mutex::new(BTreeMap::new());
    let gate = {
        let mut turns = TURNS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        turns.retain(|_, gate| gate.strong_count() != 0);
        let slot = turns
            .entry((w.history.file().to_owned(), address.to_owned(), created))
            .or_default();
        slot.upgrade().unwrap_or_else(|| {
            let gate = Arc::new(Gate::new(()));
            *slot = Arc::downgrade(&gate);
            gate
        })
    };
    gate.lock_owned().await
}

async fn stage_message(w: &Workspace, agent: &core::Terminal, core_id: &str, text: &str, files: &[groups::Upload]) -> Result<String, ApiError> {
    const CHANGED: ApiError = ApiError::Conflict("The terminal changed during file staging.");
    let mut paths = Vec::new();
    for file in files {
        const STAGING: ApiError =
            ApiError::Conflict("A file could not be attached. The task was not sent.");
        if w.core.identify().await?.core.id != core_id {
            return Err(CHANGED);
        }
        let staged = w
            .core
            .stage_file(agent, &file.name, &file.data)
            .await
            .map_err(|_| STAGING)?;
        if staged.bytes != file.data.len()
            || staged.path.is_empty()
            || staged.path.chars().any(char::is_control)
        {
            return Err(STAGING);
        }
        paths.push((file.name.as_str(), staged.path));
    }
    let text = if paths.is_empty() {
        text.to_owned()
    } else {
        if w.core.identify().await?.core.id != core_id {
            return Err(CHANGED);
        }
        let current = w.core.agent(&agent.address, agent.created_ms).await?;
        current.require_live()?;
        if current.launch_key() != agent.launch_key() {
            return Err(CHANGED);
        }
        let attachment_list: Vec<_> = paths
            .iter()
            .map(|(name, path)| json!({"name":name,"path":path}))
            .collect();
        format!(
            "{}\n\nAttached files (name and terminal path):\n{}",
            text,
            json!(attachment_list)
        )
    };
    Ok(text)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Steer {
    expected_core: String,
    reference: String,
    text: String,
}

async fn steer(State(w): State<Workspace>, Path(target): Path<(String, u64)>, Json(body): Json<Steer>) -> Result<Response, ApiError> {
    steer_turn(w, target, body, vec![]).await
}

async fn steer_files(State(w): State<Workspace>, Path(target): Path<(String, u64)>, multipart: Multipart) -> Result<Response, ApiError> {
    let (body, files) = task_files::read(multipart).await?;
    steer_turn(w, target, body, files).await
}

fn validate_turn_reference(reference: &str) -> Result<(), Failure> {
    if reference.len() == 36 && reference.bytes().enumerate().all(|(i, c)| {
        if matches!(i, 8 | 13 | 18 | 23) { c == b'-' } else { c.is_ascii_hexdigit() }
    }) {
        Ok(())
    } else {
        Err(Failure::Input("Invalid turn reference."))
    }
}

/// The provider must see the reference to match an in-progress turn. Keep the journal's task text verbatim.
fn runtime_task(text: &str, reference: Option<&str>) -> Result<String, Failure> {
    match reference {
        Some(reference) => {
            validate_turn_reference(reference)?;
            let marked = format!("[SwarmHub turn {reference}]\n{text}");
            core::validate_task(&marked)?;
            Ok(marked)
        }
        None => Ok(text.to_owned()),
    }
}

#[cfg(test)]
#[test]
fn scoped_turn_keeps_the_journal_text_separate_from_the_runtime_input() {
    let reference = "ec7b6242-eed2-4d59-84a3-e8daa44c9f64";
    let task = "Review the changes";
    let message: Message = serde_json::from_value(json!({"text": task, "turn_reference": reference})).unwrap();
    let launch: Launch = serde_json::from_value(json!({"name": "bot", "template": "codex", "task": task,
        "turn_reference": reference})).unwrap();
    for (saved, scope) in [(&message.text, &message.turn_reference), (&launch.task, &launch.turn_reference)] {
        assert_eq!(saved, task);
        assert_eq!(runtime_task(saved, scope.as_deref()).unwrap(), format!("[SwarmHub turn {reference}]\n{task}"));
    }
    assert_eq!(runtime_task(task, None).unwrap(), task);
    assert!(runtime_task(task, Some("invalid")).is_err());
    assert!(runtime_task(&"a".repeat(16_384), Some(reference)).is_err());
}

async fn steer_turn(w: Workspace, (address, created): (String, u64), body: Steer, files: Vec<groups::Upload>) -> Result<Response, ApiError> {
    core::validate_task(&body.text)?;
    validate_turn_reference(&body.reference)?;
    let hello = w.core.identify().await?;
    if body.expected_core != hello.core.id || (!files.is_empty() && !hello.supports("terminal.put")) {
        return Err(ApiError::Conflict("The selected workspace cannot receive this follow-up."));
    }
    let agent = w.core.agent(&address, created).await?;
    agent.require_live()?;
    let key = agent.launch_key().ok_or(ApiError::Conflict("No steerable session."))?;
    let text = stage_message(&w, &agent, &hello.core.id, &body.text, &files).await?;
    core::validate_task(&text)?;
    codex_agent::stream::steer(w.history.file(), key, &body.reference, &text).await?;
    Ok(Json(json!({"delivered":true})).into_response())
}

async fn send_message(
    w: Workspace,
    id: String,
    created: u64,
    body: Message,
    files: Vec<groups::Upload>,
) -> Result<Response, ApiError> {
    core::validate_task(&body.text)?;
    let hello = w.core.identify().await?;
    const CHANGED: ApiError = ApiError::Conflict("Herdr Core changed. The task was not sent.");
    if body
        .expected_core
        .as_ref()
        .is_some_and(|core| core != &hello.core.id)
    {
        return Err(CHANGED);
    }
    if !files.is_empty() && (!hello.supports("terminal.put") || body.text.len() > 12 * 1024) {
        return Err(Failure::Input(
            "Attachments require file staging support and a task of 12 KiB or less.",
        )
        .into());
    }
    let agent = w.core.agent(&id, created).await?;
    agent.require_live()?;
    let quote = if let Some(target) = body.reply_to {
        if target.core != hello.core.id {
            return Err(ApiError::NotFound);
        }
        if body.text.len() > 14 * 1024 {
            return Err(Failure::Input(
                "Keep a reply under 14 KiB so there is room for the quoted message.",
            )
            .into());
        }
        Some(
            w.history
                .direct_reply_quote(&hello.core.id, &id, created, target.id)?
                .ok_or(ApiError::NotFound)?,
        )
    } else {
        None
    };
    let task = runtime_task(&body.text, body.turn_reference.as_deref())?;
    let text = stage_message(&w, &agent, &hello.core.id, &task, &files).await?;
    const INTRO: &str = "The user is replying to this excerpt from your earlier message (a JSON string for context):";
    let base = quote
        .as_ref()
        .map(|quote| format!("{INTRO}\n{}\n\nCurrent task:\n{}", json!(quote.text), text));
    let instruction = (base.is_some() && agent.launch_key().is_some())
        .then(|| std::env::current_exe().ok())
        .flatten()
        .and_then(|exe| exe.into_os_string().into_string().ok())
        .filter(|exe| !exe.chars().any(char::is_control))
        .map(|exe| format!(
            " To post one answer in this thread, pipe only the answer text into this command (leave the token out of your answer): {} thread-reply ",
            agent::shell_quote(&exe)
        ))
        .filter(|instruction| base.as_ref().is_some_and(|base| base.len() + instruction.len() + 32 <= 16_384));
    core::validate_task(base.as_deref().unwrap_or(&text))?;
    let (record, token) = w.history.start_task(
        &hello.core.id,
        &agent,
        &body.text,
        quote.as_ref(),
        instruction.is_some(),
        &files,
    )?;
    let mut prompt = base.unwrap_or(text);
    if let (Some(instruction), Some(token)) = (instruction, token) {
        prompt.insert_str(INTRO.len(), &format!("{instruction}{token}"));
    }
    let queued = warm::starting(&w.history, &agent);
    let action = tokio::spawn(async move {
        let _turn = task_turn(&w, &agent.address, agent.created_ms).await;
        let wait = if queued {
            warm::Wait::Queued
        } else {
            warm::Wait::Held
        };
        type_recorded_task(&w, &agent, record, prompt, wait).await
    });
    if queued {
        return Ok((
            StatusCode::ACCEPTED,
            Json(json!({"status":null,"started":null,"queued":true})),
        ).into_response());
    }
    Ok(Json(action.await.map_err(|_| Failure::Uncertain)??).into_response())
}

async fn deliver_task(
    w: Workspace,
    agent: core::Terminal,
    record: i64,
    prompt: String,
) -> Result<core::Delivery, Failure> {
    deliver_task_waiting(w, agent, record, prompt, warm::Wait::Held).await
}

/// Types a recorded task into its agent and records how that went.
async fn deliver_task_waiting(
    w: Workspace,
    agent: core::Terminal,
    record: i64,
    prompt: String,
    wait: warm::Wait,
) -> Result<core::Delivery, Failure> {
    let action = tokio::spawn(async move {
        let _turn = task_turn(&w, &agent.address, agent.created_ms).await;
        type_recorded_task(&w, &agent, record, prompt, wait).await
    });
    action.await.map_err(|_| Failure::Uncertain)?
}

async fn type_recorded_task(
    w: &Workspace,
    agent: &core::Terminal,
    record: i64,
    prompt: String,
    wait: warm::Wait,
) -> Result<core::Delivery, Failure> {
    let outcome = w.send_to_agent_waiting(agent, prompt, None, wait).await;
    finish_task(&w.history, record, outcome)
}

fn finish_task(
    history: &History,
    record: i64,
    outcome: Result<core::Delivery, Failure>,
) -> Result<core::Delivery, Failure> {
    match outcome {
        Ok(delivery) => {
            let state = if delivery.started == Some(false) {
                DeliveryState::StartNotObserved
            } else {
                DeliveryState::Sent
            };
            history.finish(record, state, None, None).map_err(|_| Failure::Uncertain)?;
            Ok(delivery)
        }
        Err(error) => {
            record_failure(history, record, &error).map_err(|_| Failure::Uncertain)?;
            Err(error)
        }
    }
}

/// Offers a completion only against a current, idle launch. The fixture Core also compares the
/// same launch and turn when accepting the write, since a provider can change state independently.
async fn deliver_completion(
    w: &Workspace,
    core: &str,
    agent: &core::Terminal,
    outbox: i64,
    owner: &str,
    text: &str,
) {
    use bots::{
        completions::{self, Blocker},
        desk::{self, CompletionLaunch},
    };
    let defer = |blocker| {
        let _ = bots::write(&w.history, |ctx| completions::defer(ctx, outbox, blocker));
    };
    let _turn = task_turn(w, &agent.address, agent.created_ms).await;
    let Ok(hello) = w.core.identify().await else {
        return defer(Blocker::Core);
    };
    if hello.core.id != core {
        return defer(Blocker::Changed);
    }
    if !hello.supports_completion_send() {
        return defer(Blocker::Unsupported);
    }
    let Ok(agents) = w.core.agents().await else {
        return defer(Blocker::Core);
    };
    let Some(key) = agent.launch_key() else {
        return defer(Blocker::Unmapped);
    };
    let current = match desk::completion_launch(w, core, &agents, owner) {
        Ok(CompletionLaunch::Current(index)) => &agents[index],
        Ok(CompletionLaunch::Unmapped) => return defer(Blocker::Unmapped),
        Ok(CompletionLaunch::Absent) => return defer(Blocker::Changed),
        Err(_) => return,
    };
    if current.address != agent.address
        || current.created_ms != agent.created_ms
        || current.launch_key() != Some(key)
    {
        return defer(Blocker::Changed);
    }
    if current.uses_opencode_api() {
        return defer(Blocker::Unsupported);
    }
    if let Err(blocker) = completions::availability(current) {
        return defer(blocker);
    }
    let Ok(Some(record)) = bots::write(&w.history, |ctx| {
        completions::reserve(ctx, outbox, owner, core, current, text)
    }) else {
        return;
    };
    let outcome = warm::send_completion(w, core, current, key, text.to_owned()).await;
    let state = match outcome {
        Ok(delivery) if delivery.started == Some(false) => DeliveryState::StartNotObserved,
        Ok(_) => DeliveryState::Sent,
        Err(error) => delivery_failure(&error).0,
    };
    let _ = w.history.finish(record, state, None, None);
    let _ = completions::reconcile_one(&w.history, outbox);
}

#[derive(Deserialize)]
struct HistoryQuery {
    before: Option<i64>,
}

async fn conversation(
    State(w): State<Workspace>,
    Path((core, id, created)): Path<(String, String, u64)>,
    Query(query): Query<HistoryQuery>,
) -> Result<Response, StoreError> {
    if core == grok_import::ARCHIVE_CORE {
        return Ok(
            Json(grok_import::page(&w.history, &id, created, query.before)?).into_response(),
        );
    }
    Ok(Json(
        w.history
            .page(&core, &id, created, query.before)?
            .with_markup(),
    )
    .into_response())
}

async fn direct_thread(
    State(w): State<Workspace>,
    Path((core, id, created, root)): Path<(String, String, u64, i64)>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<history::DirectThread>, ApiError> {
    if core == grok_import::ARCHIVE_CORE {
        return Err(ApiError::NotFound);
    }
    Ok(Json(
        w.history
            .direct_thread(&core, &id, created, root, query.before)?
            .ok_or(ApiError::NotFound)?
            .with_markup(),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SnapshotRequest {
    title: String,
}

async fn save_snapshot(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    Json(body): Json<SnapshotRequest>,
) -> Result<impl IntoResponse, ApiError> {
    let title = body.title.trim();
    if title.is_empty() || title.chars().count() > 100 || title.chars().any(char::is_control) {
        return Err(Failure::Input("Enter a title of up to 100 characters.").into());
    }
    let hello = w.core.identify().await?;
    let agent = w.core.agent(&id, created).await?;
    let output = w.core.output(&agent).await?;
    if output.text.trim().is_empty() || output.text.len() > 128 * 1024 {
        return Err(Failure::Input("The terminal screen is empty or too large to save.").into());
    }
    let id = w
        .history
        .save_snapshot(&hello.core.id, &agent, title, &output.text)?;
    Ok((StatusCode::CREATED, Json(json!({"id":id}))))
}

async fn library(State(w): State<Workspace>) -> Result<impl IntoResponse, StoreError> {
    Ok(Json(w.history.library("snapshot")?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentLibraryQuery {
    profile: Option<i64>,
    core: Option<String>,
    address: Option<String>,
    created_ms: Option<u64>,
    kind: Option<history::ResultKind>,
}

async fn agent_library(
    State(w): State<Workspace>,
    Query(query): Query<AgentLibraryQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let scope = match (query.profile, query.core, query.address, query.created_ms) {
        (Some(id), None, None, None) if id > 0 => history::LibraryScope::Profile(id),
        (None, Some(core), Some(address), Some(created))
            if !core.is_empty()
                && core.len() <= 256
                && !address.is_empty()
                && address.len() <= 256
                && created <= i64::MAX as u64 =>
        {
            history::LibraryScope::Session(core, address, created)
        }
        _ => return Err(Failure::Input("Choose one agent profile or session.").into()),
    };
    Ok(Json(w.history.agent_library(scope, query.kind)?))
}

async fn files(State(w): State<Workspace>) -> Result<impl IntoResponse, StoreError> {
    Ok(Json(w.history.library("artifact")?))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LibraryPin {
    pinned: bool,
}

async fn set_library_pin(
    State(w): State<Workspace>,
    Path((kind, id)): Path<(history::ResultKind, i64)>,
    Json(body): Json<LibraryPin>,
) -> Result<impl IntoResponse, ApiError> {
    if !w.history.set_library_pin(kind, id, body.pinned)? {
        return Err(ApiError::NotFound);
    }
    Ok(Json(json!({"pinned":body.pinned})))
}

async fn file_info(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, ApiError> {
    let (name, data) = w.history.artifact(id)?.ok_or(ApiError::NotFound)?;
    Ok(Json(file_preview::info(&name, &data)).into_response())
}

async fn file_image(State(w): State<Workspace>, Path(id): Path<i64>) -> Result<Response, ApiError> {
    let (_, data) = w.history.artifact(id)?.ok_or(ApiError::NotFound)?;
    file_preview::raster_response(data)
}

async fn download_file(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, ApiError> {
    let (name, data) = w.history.artifact(id)?.ok_or(ApiError::NotFound)?;
    Ok(file_download_response(&name, data))
}

fn file_download_response(name: &str, data: Vec<u8>) -> Response {
    let mut encoded = String::with_capacity(name.len());
    for byte in name.bytes() {
        if byte.is_ascii_alphanumeric() || b"._-".contains(&byte) {
            encoded.push(char::from(byte));
        } else {
            use std::fmt::Write;
            let _ = write!(&mut encoded, "%{byte:02X}");
        }
    }
    let disposition = format!("attachment; filename*=UTF-8''{encoded}");
    (
        [
            (header::CONTENT_TYPE, "application/octet-stream"),
            (header::CONTENT_DISPOSITION, disposition.as_str()),
        ],
        data,
    )
        .into_response()
}

#[derive(Deserialize)]
struct AttachmentQuery {
    name: String,
}

async fn attach_file(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    Query(query): Query<AttachmentQuery>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    if !core::valid_filename(&query.name) {
        return Err(
            Failure::Input("Use a filename up to 180 bytes without path separators.").into(),
        );
    }
    let hello = w.core.identify().await?;
    if !hello.supports("terminal.put") {
        return Err(Failure::Input("This Herdr Core does not support file staging.").into());
    }
    let terminal = w.core.agent(&id, created).await?;
    stage_attachment(w, terminal, hello.core.id, query.name, body).await
}

async fn stage_attachment(
    w: Workspace,
    terminal: core::Terminal,
    core_id: String,
    name: String,
    body: Bytes,
) -> Result<(StatusCode, Json<serde_json::Value>), ApiError> {
    let transfer = tokio::spawn(async move {
        let file = w.core.stage_file(&terminal, &name, &body).await?;
        let recorded = w
            .history
            .record_attachment(&core_id, &terminal, &name, &file.path)
            .is_ok();
        Ok::<_, Failure>(Json(
            json!({"path":file.path,"bytes":file.bytes,"recorded":recorded}),
        ))
    });
    let result = transfer.await.map_err(|_| Failure::Uncertain)??;
    Ok((StatusCode::CREATED, result))
}

async fn saved_conversations(State(w): State<Workspace>) -> Result<impl IntoResponse, StoreError> {
    Ok(Json(w.history.conversations()?))
}

async fn snapshot(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<impl IntoResponse, ApiError> {
    let item = w.history.snapshot(id)?.ok_or(ApiError::NotFound)?;
    Ok(Json(item))
}

/// Gemini CLI runs no hook when a turn is cancelled or a permission refused, so nothing would report that it
/// stopped and it would read as working, or as waiting for an answer, until its next turn. For a Gemini CLI
/// session that is working or asking, this tells its terminal `idle` shortly after the stop key
/// (`gemini_agent::status`). Never while it waits for a sign-in: the stop key does not answer that question, and
/// a program that still asks it must not look ready.
fn gemini_stop(w: &Workspace, agent: &core::Terminal) -> Option<tokio::task::JoinHandle<bool>> {
    let status = agent.status.as_ref()?;
    let stops = match status.state.as_str() {
        "working" => true,
        "blocked" => status.kind.as_deref() != Some("auth"),
        _ => false,
    };
    let key = agent.launch_key()?.to_owned();
    let journal = w.history.file().to_owned();
    if !stops || !gemini_agent::status::known(&journal, &key) {
        return None;
    }
    Some(tokio::spawn(async move {
        tokio::time::sleep(std::time::Duration::from_millis(600)).await;
        tokio::task::spawn_blocking(move || gemini_agent::status::after_stop(&journal, &key))
            .await
            .unwrap_or(false)
    }))
}

async fn interrupt(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<impl IntoResponse, Failure> {
    let agent = w.core.agent(&id, created).await?;
    let gemini = gemini_stop(&w, &agent);
    let outcome = w.core.interrupt(&agent).await?;
    if let Some(told) = gemini {
        let _ = told.await;
        if outcome == "still_working" {
            // A hook reported after the first `idle`, or the key came later than it. The key is pressed now.
            let journal = w.history.file().to_owned();
            let key = agent.launch_key().unwrap_or_default().to_owned();
            let _ = tokio::task::spawn_blocking(move || {
                gemini_agent::status::after_stop(&journal, &key)
            })
            .await;
        }
    }
    // The person's Stop also ends the exchanges this bot is part of with other bots (`bots`).
    bots::stopped_agent(&w, &agent);
    Ok(Json(json!({"outcome": outcome})))
}

#[derive(Deserialize)]
struct IdleRollover {
    expected_core: String,
    unused_only: bool,
}

/// Serialize a model/Auto rollover with bot messages, check-ins and direct tasks.
/// A rollover keeps the chat and outbox; only an explicit Stop ends exchanges.
async fn end_if_idle(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    Json(request): Json<IdleRollover>,
) -> Result<impl IntoResponse, ApiError> {
    let _turn = task_turn(&w, &id, created).await;
    let hello = w.core.identify().await?;
    if hello.core.id != request.expected_core { return Err(ApiError::Conflict("The workspace changed.")); }
    let agents = w.core.agents().await?;
    let agent = agents.iter().find(|a| a.address == id && a.created_ms == created).ok_or(ApiError::NotFound)?;
    agent.require_live()?;
    let key = agent.launch_key().ok_or(ApiError::Conflict("Unknown launch."))?;
    let unused = warm::Start::of(&w.history, agent).warm;
    let idle = match agent.status.as_ref().map(|s| s.state.as_str()) {
        Some("idle" | "done") => true,
        None => unused,
        _ => false,
    };
    let parents = helpers::parents(&w.history, &hello.core.id, &agents)?;
    let helper_busy = agents.iter().filter(|a| a.state == "live").any(|a| {
        a.launch_key().and_then(|key| parents.get(key)).and_then(Option::as_ref)
            .is_some_and(|p| p.address == id && p.created_ms == created)
            && !a.status.as_ref().is_some_and(|s| matches!(s.state.as_str(), "idle" | "done"))
    });
    if !idle || helper_busy || (request.unused_only && !unused) || w.approvals.waits_on(key)? {
        return Err(ApiError::Conflict("The existing session is busy or waiting for a decision."));
    }
    let pending: bool = w.history.db()?.query_row(
        "SELECT EXISTS(SELECT 1 FROM journal WHERE core_id=? AND address=? AND created_ms=? AND kind='task' AND state='pending')",
        rusqlite::params![request.expected_core, id, created], |row| row.get(0)
    ).map_err(StoreError::from)?;
    if pending { return Err(ApiError::Conflict("The existing session has a pending delivery.")); }
    Ok(Json(w.core.end(agent).await?))
}

async fn end(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<impl IntoResponse, Failure> {
    let agent = w.core.agent(&id, created).await?;
    let ended = w.core.end(&agent).await?;
    bots::stopped_agent(&w, &agent);
    Ok(Json(ended))
}

fn resolve_launch_owner(
    db: &rusqlite::Connection,
    workspace_id: Option<&str>,
    bot_note_id: Option<&str>,
    agent_name: &str,
) -> rusqlite::Result<Option<String>> {
    use rusqlite::OptionalExtension;
    if let Some(id) = workspace_id.or(bot_note_id) {
        return Ok(Some(id.to_ascii_lowercase()));
    }
    if let Some(bot) = bots::of_agent(db, agent_name)? {
        return Ok(Some(bot.id));
    }
    db.query_row(
        "SELECT parent_bot_id FROM journal WHERE agent=?1 AND parent_bot_id IS NOT NULL ORDER BY id DESC LIMIT 1",
        [agent_name],
        |row| row.get::<_, String>(0),
    )
    .optional()
}

#[cfg(test)]
mod launch_owner_tests {
    use super::resolve_launch_owner;
    use crate::{bots, history::History};

    #[test]
    fn resolve_launch_owner_covers_registered_and_group_agents_without_workspace_id() {
        let scratch = tempfile::tempdir().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(scratch.path(), std::fs::Permissions::from_mode(0o700))
                .unwrap();
        }
        let history = History::open_at(&scratch.path().join("data")).unwrap();
        {
            let db = history.db().unwrap();
            bots::register(
                &db,
                &bots::Registration {
                    id: "11111111-2222-3333-4444-555555555555".into(),
                    name: Some("Builder".into()),
                    may_message: Some(false),
                    ..Default::default()
                },
                1_000,
            )
            .unwrap()
            .unwrap();

            // Direct/renamed bot launch with no workspace_id or bot_note still resolves to the bot.
            assert_eq!(
                resolve_launch_owner(&db, None, None, "builder-111111").unwrap(),
                Some("11111111-2222-3333-4444-555555555555".into())
            );
        }

        // Group runtime previously associated via existing_agents keeps its owner on relaunch.
        let (record, _) = history
            .start_launch("core", "group-abcdef123456", "hi", None, "{}", "")
            .unwrap()
            .unwrap();
        let db = history.db().unwrap();
        db.execute(
            "UPDATE journal SET parent_bot_id=?1 WHERE id=?2",
            rusqlite::params!["11111111-2222-3333-4444-555555555555", record],
        )
        .unwrap();
        assert_eq!(
            resolve_launch_owner(&db, None, None, "group-abcdef123456").unwrap(),
            Some("11111111-2222-3333-4444-555555555555".into())
        );
    }
}
