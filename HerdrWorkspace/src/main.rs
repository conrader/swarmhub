mod activity;
mod agent;
mod appearance;
mod approval_rules;
mod approvals;
mod attention;
mod codex_agent;
mod core;
mod desktop;
mod drive_access;
mod drive_files;
mod drive_oauth;
mod email_drafts;
mod events;
mod file_preview;
mod github_project;
mod grok_import;
mod group_forms;
mod group_handoffs;
mod group_preview;
mod group_routes;
mod groups;
mod helpers;
mod history;
mod live_reply;
mod machines;
mod markdown;
mod memory_proposals;
mod opencode_agent;
mod page_share;
mod pages;
mod pdf_assets;
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
mod skill_proposals;
mod skills;
mod skillshare;
mod slack_events;
mod task_files;
mod terminal;
mod tool_activity;
mod transcripts;
mod vault;
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
    history: History,
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
    async fn send_to_agent(
        &self,
        agent: &core::Terminal,
        prompt: String,
    ) -> Result<core::Delivery, Failure> {
        self.send_to_agent_with_group(agent, prompt, None).await
    }

    async fn send_to_agent_with_group(
        &self,
        agent: &core::Terminal,
        prompt: String,
        group: Option<group_preview::Binding>,
    ) -> Result<core::Delivery, Failure> {
        if !agent.uses_opencode_api() {
            return self.core.send(agent, prompt).await;
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
        if command == codex_agent::stream::COMMAND {
            return codex_agent::stream::run().await;
        }
        return agent::run(&command);
    }
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
    let vault = vault::Vault::configured()?;
    let workspace = Workspace {
        core: Core(socket),
        connected_files: webdav::Folder::configured(&history, vault.as_ref())?,
        drive_access: drive_access::Desk::default(),
        drive_files: drive_files::Drive::configured(&history, vault.as_ref(), port)?,
        github_project: github_project::Project::configured(&history, vault.as_ref())?,
        slack: slack_events::Signing::configured(&history, vault.as_ref())?,
        history,
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
    workspace.history.watch_changes();
    let app = Router::new()
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
        .merge(opencode_agent::models::routes())
        .merge(slack_events::routes())
        .merge(terminal::routes())
        .merge(desktop::routes())
        .merge(approvals::routes())
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
        .merge(task_files::routes())
        .merge(webdav::routes())
        .merge(drive_files::routes())
        .merge(drive_oauth::routes())
        .merge(github_project::routes())
        .merge(vault::routes())
        .route("/api/workspace", get(workspace_state))
        .route("/api/agents", post(launch))
        .route("/api/agents/{id}/{created}/output", get(output))
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
        .layer(DefaultBodyLimit::max(128 * 1024))
        .layer(middleware::from_fn_with_state(
            workspace.clone(),
            local_browser,
        ))
        .with_state(workspace);
    println!("SwarmHub · http://127.0.0.1:{port}");
    axum::serve(listener, app).await?;
    Ok(())
}

async fn local_browser(State(state): State<Workspace>, request: Request, next: Next) -> Response {
    let local_hook = (request.uri().path().starts_with("/hooks/routines/")
        || request.uri().path() == "/hooks/slack")
        && !request.headers().contains_key(header::ORIGIN);
    if !local_host(request.headers(), state.port)
        || (request.method() == axum::http::Method::POST
            && !local_hook
            && !same_origin(request.headers(), state.port))
    {
        return StatusCode::FORBIDDEN.into_response();
    }
    if request.uri().path().starts_with("/api/")
        && !request
            .headers()
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .is_some_and(|value| token_matches(value, &state.token))
    {
        return (
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"Enter the workspace access token to connect."})),
        )
            .into_response();
    }
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
                    "blocked" | "status_mismatch" | "name_taken" | "finished" => StatusCode::CONFLICT,
                    "invalid_params" | "invalid_template" => StatusCode::UNPROCESSABLE_ENTITY,
                    _ => StatusCode::BAD_GATEWAY,
                };
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
}

impl<'a> AgentView<'a> {
    fn new(
        history: &History,
        terminal: &'a core::Terminal,
        parent: Option<helpers::ParentRef>,
    ) -> Self {
        Self {
            terminal,
            opencode_api: terminal.uses_opencode_api(),
            parent,
            reply_arrives_whole: terminal
                .launch_key()
                .filter(|_| terminal.state == "live")
                .and_then(|key| codex_agent::stream::whole_reason(history.file(), key)),
        }
    }
}

async fn workspace_state(State(w): State<Workspace>) -> Result<Json<serde_json::Value>, ApiError> {
    let hello = w.core.identify().await?;
    let (agents, templates) = tokio::try_join!(w.core.agents(), w.core.templates())?;
    let catalog = runtimes::Catalog::load(w.history.file());
    let templates: Vec<_> = templates
        .into_iter()
        .map(|template| catalog.choice(template))
        .collect();
    for agent in &agents {
        w.history.recover_launch(&hello.core.id, agent)?;
        w.history.link_profile(&hello.core.id, agent)?;
    }
    let parents = helpers::parents(&w.history, &hello.core.id, &agents)?;
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
        .map(|(terminal, helper)| AgentView::new(&w.history, terminal, helper.cloned().flatten()))
        .collect();
    Ok(Json(
        json!({"version":hello.version,"core":hello.core.id,"agents":agents,"templates":templates,
               "demo":std::env::var("SWARMHUB_DEMO").as_deref() == Ok("1"),
               "runtime_catalog_warning":catalog.warning,
               "attachments":hello.supports("terminal.put"),"terminal_attach":hello.supports("terminal.attach"),
               "connected_files":w.connected_files.is_some() || w.drive_files.as_ref().is_some_and(drive_files::Drive::connected)}),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Launch {
    name: String,
    template: String,
    task: String,
    profile_id: Option<i64>,
    expected_runtime: Option<runtimes::Runtime>,
    model_choice: Option<runtimes::ModelChoice>,
    model_id: Option<String>,
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
}

async fn launch(
    State(w): State<Workspace>,
    Json(body): Json<Launch>,
) -> Result<impl IntoResponse, ApiError> {
    core::validate_task(&body.task)?;
    if (body.profile_id.is_some() && body.standing_instructions.is_some())
        || (body.profile_id.is_none() && body.instructions_revision.is_some())
    {
        return Err(Failure::Input("Use the saved instructions for an existing profile.").into());
    }
    let first_instructions =
        profiles::validate_instructions(body.standing_instructions.as_deref().unwrap_or(""))?;
    let hello = w.core.identify().await?;
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
    let instructions = if let Some((id, revision)) = body.profile_id.zip(body.instructions_revision)
    {
        w.history.saved_instructions(id, revision)?.ok_or(ApiError::Conflict(
            "Standing instructions changed. Reopen the launch dialog and review the new version.",
        ))?
    } else {
        first_instructions.to_owned()
    };
    const HINT: &str = "To share a finished file, move it into the folder named by the SWARMHUB_RESULTS environment variable after writing it. SwarmHub will add it to this conversation.";
    let hints: Vec<&str> = body
        .collect_results
        .then_some(HINT)
        .into_iter()
        .chain(project_hint.as_deref())
        .collect();
    let message = if hints.is_empty() {
        profiles::launch_message(&body.task, &instructions)?
    } else if instructions.is_empty() {
        let message = format!("{} | {}", body.task, hints.join(" "));
        core::validate_task(&message).map_err(|_| {
            Failure::Input(if body.collect_results {
                "Leave a little room in the first task for the results folder instructions."
            } else {
                "Leave a little room in the first task for the note about this agent's projects."
            })
        })?;
        message
    } else {
        profiles::launch_message(
            &body.task,
            &format!("{instructions}\n\n{}", hints.join("\n\n")),
        )?
    };
    let (record, key) = w
        .history
        .start_launch(
            &hello.core.id,
            &body.name,
            &body.task,
            body.profile_id,
            &runtime,
            &instructions,
        )?
        .ok_or(ApiError::Conflict(
            "A session for this profile is already starting.",
        ))?;
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
        match w
            .core
            .launch(
                body.name,
                if api_first_task {
                    core::LaunchSource::DirectOpenCode(body.template, template.command)
                } else {
                    core::LaunchSource::Template(body.template, message)
                },
                core::LaunchEnv {
                    key: &key,
                    journal,
                    approval_socket: approval_socket.to_str().unwrap_or_default(),
                    model: model.as_ref(),
                    results: results.as_deref().and_then(std::path::Path::to_str),
                    opencode_first_task: prepared.as_ref().and_then(|task| task.path().to_str()),
                    helper: None,
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
    Ok((StatusCode::CREATED, Json(result)))
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
) -> Result<impl IntoResponse, ApiError> {
    send_message(w, id, created, body, vec![]).await
}

async fn send_with_files(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    multipart: Multipart,
) -> Result<impl IntoResponse, ApiError> {
    let (body, files): (Message, _) = task_files::read(multipart).await?;
    if body.expected_core.is_none() {
        return Err(Failure::Input(
            "Choose the agent’s current Herdr Core before sending attachments.",
        )
        .into());
    }
    send_message(w, id, created, body, files).await
}

async fn send_message(
    w: Workspace,
    id: String,
    created: u64,
    body: Message,
    files: Vec<groups::Upload>,
) -> Result<Json<core::Delivery>, ApiError> {
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
    let mut paths = Vec::new();
    for file in &files {
        const STAGING: ApiError =
            ApiError::Conflict("A file could not be attached. The task was not sent.");
        if w.core.identify().await?.core.id != hello.core.id {
            return Err(CHANGED);
        }
        let staged = w
            .core
            .stage_file(&agent, &file.name, &file.data)
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
        body.text.clone()
    } else {
        if w.core.identify().await?.core.id != hello.core.id {
            return Err(CHANGED);
        }
        let current = w.core.agent(&id, created).await?;
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
            body.text,
            json!(attachment_list)
        )
    };
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
    Ok(Json(deliver_task(w, agent, record, prompt).await?))
}

async fn deliver_task(
    w: Workspace,
    agent: core::Terminal,
    record: i64,
    prompt: String,
) -> Result<core::Delivery, Failure> {
    let action = tokio::spawn(async move {
        match w.send_to_agent(&agent, prompt).await {
            Ok(delivery) => {
                let state = if delivery.started == Some(false) {
                    DeliveryState::StartNotObserved
                } else {
                    DeliveryState::Sent
                };
                w.history
                    .finish(record, state, None, None)
                    .map_err(|_| Failure::Uncertain)?;
                Ok(delivery)
            }
            Err(error) => {
                record_failure(&w.history, record, &error).map_err(|_| Failure::Uncertain)?;
                Err(error)
            }
        }
    });
    action.await.map_err(|_| Failure::Uncertain)?
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

async fn interrupt(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<impl IntoResponse, Failure> {
    let agent = w.core.agent(&id, created).await?;
    Ok(Json(json!({"outcome": w.core.interrupt(&agent).await?})))
}

async fn end(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<impl IntoResponse, Failure> {
    let agent = w.core.agent(&id, created).await?;
    Ok(Json(w.core.end(&agent).await?))
}
