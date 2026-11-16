#[path = "desktop_runner.rs"]
mod runner;

pub use runner::run;

use crate::{ApiError, Workspace, core::Failure, history::StoreError, same_origin, token_matches};
use axum::{
    Json, Router,
    extract::{
        Path, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use futures_util::{SinkExt, StreamExt};
use ring::rand::{SecureRandom, SystemRandom};
use serde::Deserialize;
use serde_json::json;
use std::{
    collections::HashSet,
    fs, io,
    os::unix::fs::{FileTypeExt, MetadataExt},
    path::PathBuf,
    sync::{LazyLock, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UnixStream,
    sync::Semaphore,
    time::timeout,
};

const UNAVAILABLE: ApiError =
    ApiError::Conflict("This session has no available graphical desktop.");
const TICKET_AGE: Duration = Duration::from_secs(20);
const LIMIT: usize = 64 * 1024;
static TICKETS: Mutex<Vec<Grant>> = Mutex::new(Vec::new());
static VIEWERS: Semaphore = Semaphore::const_new(12);
static CONTROLLERS: LazyLock<Mutex<HashSet<PathBuf>>> =
    LazyLock::new(|| Mutex::new(HashSet::new()));

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    core: String,
    control: bool,
}

struct Grant {
    ticket: String,
    until: Instant,
    core: String,
    id: String,
    created: u64,
    control: bool,
}

struct Control(PathBuf);
impl Drop for Control {
    fn drop(&mut self) {
        if let Ok(mut held) = CONTROLLERS.lock() {
            held.remove(&self.0);
        }
    }
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/desktops/{id}/{created}", get(status).post(ticket))
        .route("/desktop/session/{ticket}", get(upgrade))
        .route(
            "/desktop.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/desktop.js"),
                )
            }),
        )
        .route(
            "/desktop.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
                    include_str!("../web/desktop.css"),
                )
            }),
        )
        .route(
            "/desktop-teaching.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/desktop-teaching.js"),
                )
            }),
        )
        .route(
            "/vendor/novnc.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/vendor/novnc.js"),
                )
            }),
        )
}

async fn status(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
) -> Result<impl IntoResponse, ApiError> {
    let agent = w.core.agent(&id, created).await?;
    let available = agent.require_live().is_ok()
        && agent
            .launch_key()
            .and_then(|key| endpoint(&w, key, false))
            .is_some();
    Ok(Json(json!({"available":available})))
}

fn endpoint(w: &Workspace, key: &str, control: bool) -> Option<PathBuf> {
    let folder = runner::folder(w.history.file(), key)?;
    let owner = fs::symlink_metadata(w.history.file()).ok()?.uid();
    let info = fs::symlink_metadata(&folder).ok()?;
    if !info.is_dir() || info.uid() != owner || info.mode() & 0o077 != 0 {
        return None;
    }
    let socket = runner::socket(&folder, control);
    let info = fs::symlink_metadata(&socket).ok()?;
    (info.file_type().is_socket() && info.uid() == owner).then_some(socket)
}

async fn resolve(
    w: &Workspace,
    core: &str,
    id: &str,
    created: u64,
    control: bool,
) -> Result<PathBuf, ApiError> {
    if w.core.identify().await?.core.id != core {
        return Err(ApiError::Conflict("The active Herdr Core changed."));
    }
    let agent = w.core.agent(id, created).await?;
    agent.require_live()?;
    agent
        .launch_key()
        .and_then(|key| endpoint(w, key, control))
        .ok_or(UNAVAILABLE)
}

async fn ticket(
    State(w): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    Json(request): Json<Request>,
) -> Result<impl IntoResponse, ApiError> {
    resolve(&w, &request.core, &id, created, request.control).await?;
    let mut random = [0u8; 32];
    SystemRandom::new()
        .fill(&mut random)
        .map_err(|_| StoreError)?;
    let ticket = URL_SAFE_NO_PAD.encode(random);
    let mut active = TICKETS.lock().map_err(|_| StoreError)?;
    let now = Instant::now();
    active.retain(|grant| grant.until > now);
    if active.len() >= 64 {
        return Err(Failure::Input("Too many desktops are opening. Try again shortly.").into());
    }
    active.push(Grant {
        ticket: ticket.clone(),
        until: now + TICKET_AGE,
        core: request.core,
        id,
        created,
        control: request.control,
    });
    Ok(Json(json!({"path":format!("/desktop/session/{ticket}")})))
}

fn consume_ticket(value: &str) -> Option<Grant> {
    let mut tickets = TICKETS.lock().ok()?;
    let now = Instant::now();
    tickets.retain(|grant| grant.until > now);
    let index = tickets
        .iter()
        .position(|grant| token_matches(value, &grant.ticket))?;
    Some(tickets.swap_remove(index))
}

async fn upgrade(
    State(w): State<Workspace>,
    Path(ticket): Path<String>,
    headers: HeaderMap,
    websocket: WebSocketUpgrade,
) -> Response {
    if !same_origin(&headers, w.port) {
        return StatusCode::FORBIDDEN.into_response();
    }
    let Some(grant) = consume_ticket(&ticket) else {
        return StatusCode::UNAUTHORIZED.into_response();
    };
    let Ok(viewer) = VIEWERS.try_acquire() else {
        return StatusCode::TOO_MANY_REQUESTS.into_response();
    };
    let Ok(Ok(path)) = timeout(
        Duration::from_secs(5),
        resolve(&w, &grant.core, &grant.id, grant.created, grant.control),
    )
    .await
    else {
        return StatusCode::CONFLICT.into_response();
    };
    let control = if grant.control {
        let Ok(mut held) = CONTROLLERS.lock() else {
            return StatusCode::SERVICE_UNAVAILABLE.into_response();
        };
        if !held.insert(path.clone()) {
            return StatusCode::CONFLICT.into_response();
        }
        Some(Control(path.clone()))
    } else {
        None
    };
    let Ok(Ok(stream)) = timeout(Duration::from_secs(3), UnixStream::connect(&path)).await else {
        return StatusCode::CONFLICT.into_response();
    };
    websocket
        .max_message_size(LIMIT)
        .max_frame_size(LIMIT)
        .on_upgrade(move |socket| async move {
            let (_viewer, _control) = (viewer, control);
            transport(socket, stream).await;
        })
}

async fn transport(socket: WebSocket, stream: UnixStream) {
    let (mut from_vnc, mut to_vnc) = stream.into_split();
    let (mut to_browser, mut from_browser) = socket.split();
    let export = async {
        let mut data = vec![0; LIMIT];
        loop {
            let count = from_vnc.read(&mut data).await?;
            if count == 0 {
                return Ok::<(), io::Error>(());
            }
            to_browser
                .send(Message::Binary(data[..count].to_vec().into()))
                .await
                .map_err(io::Error::other)?;
        }
    };
    let import = async {
        while let Some(Ok(message)) = from_browser.next().await {
            match message {
                Message::Binary(data) => to_vnc.write_all(&data).await?,
                Message::Ping(_) | Message::Pong(_) => {}
                _ => break,
            }
        }
        Ok::<(), io::Error>(())
    };
    tokio::select! { _ = export => {}, _ = import => {} }
}
