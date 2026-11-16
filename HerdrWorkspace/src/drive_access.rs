use crate::{
    ApiError, Workspace, agent,
    core::MAX_FILE,
    history::{StoreError, now},
    token_matches,
};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::header,
    response::IntoResponse,
    routing::get,
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{
    collections::{HashMap, VecDeque},
    fs,
    io::{self, Read, Write},
    os::unix::{fs::FileTypeExt, net::UnixStream as BlockingStream},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
    time::timeout,
};

const LIFETIME: Duration = Duration::from_secs(60 * 60);
const DENIED: &str = "This agent session does not have Google Drive access.";
const CLOSED: ApiError = ApiError::Conflict("Google Drive access is unavailable.");
const FRAME: usize = 4096;

#[derive(Clone, PartialEq, Eq, Hash)]
struct Session {
    core: String,
    address: String,
    created: u64,
}

#[derive(Clone)]
struct Grant {
    launch: String,
    connection: [u8; 32],
    until: Instant,
    generation: u64,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Action {
    List,
    Read,
}

#[derive(Clone, Serialize)]
struct Call {
    action: Action,
    path: String,
    at_ms: i64,
    succeeded: bool,
}

#[derive(Default)]
struct Access {
    grants: HashMap<Session, Grant>,
    recent: VecDeque<(Session, Call)>,
    generation: u64,
    ready: bool,
}

#[derive(Clone, Default)]
pub(crate) struct Desk(Arc<Mutex<Access>>);

impl Desk {
    fn grant(
        &self,
        session: Session,
        launch: String,
        connection: [u8; 32],
    ) -> Result<(), ApiError> {
        let mut access = self.0.lock().map_err(|_| StoreError)?;
        let now = Instant::now();
        access
            .grants
            .retain(|_, grant| grant.until > now && grant.connection == connection);
        if !access.ready || (access.grants.len() >= 128 && !access.grants.contains_key(&session)) {
            return Err(CLOSED);
        }
        access.generation = access.generation.checked_add(1).ok_or(StoreError)?;
        let generation = access.generation;
        access.grants.insert(
            session,
            Grant {
                launch,
                connection,
                until: now + LIFETIME,
                generation,
            },
        );
        Ok(())
    }

    pub(crate) fn clear(&self) {
        if let Ok(mut access) = self.0.lock() {
            access.grants.clear();
        }
    }

    fn find(&self, launch: &str) -> Option<(Session, Grant)> {
        let access = self.0.lock().ok()?;
        access
            .grants
            .iter()
            .find(|(_, grant)| grant.until > Instant::now() && token_matches(launch, &grant.launch))
            .map(|(target, grant)| (target.clone(), grant.clone()))
    }

    fn record(&self, session: Session, call: Call) {
        if let Ok(mut access) = self.0.lock() {
            access.recent.push_front((session, call));
            access.recent.truncate(256);
        }
    }
}

#[derive(Deserialize)]
struct Selection {
    core: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Change {
    core: String,
    allowed: bool,
}

#[derive(Serialize)]
struct Status {
    available: bool,
    allowed: bool,
    minutes_remaining: u64,
    helper: Option<String>,
    recent: Vec<Call>,
}

fn socket_path(journal: &std::path::Path) -> PathBuf {
    journal.with_file_name("drive.sock")
}

pub(crate) fn listen(w: Workspace) -> io::Result<()> {
    if w.drive_files.is_none() {
        return Ok(());
    }
    let path = socket_path(w.history.file());
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_socket() => fs::remove_file(&path)?,
        Ok(_) => return Err(io::Error::other("Drive socket path is not a socket")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    // The journal directory is private and held by the workspace's exclusive lock.
    let listener = UnixListener::bind(path)?;
    w.drive_access
        .0
        .lock()
        .map_err(|_| io::Error::other("Drive access is unavailable"))?
        .ready = true;
    let slots = Arc::new(Semaphore::new(4));
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

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/agents/{address}/{created}/drive-access",
            get(status).post(change),
        )
        .route(
            "/drive-access.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/drive-access.js"),
                )
            }),
        )
}

async fn status(
    State(w): State<Workspace>,
    Path((address, created)): Path<(String, u64)>,
    Query(query): Query<Selection>,
) -> Result<impl IntoResponse, ApiError> {
    Ok(Json(view(
        &w,
        &Session {
            core: query.core,
            address,
            created,
        },
    )?))
}

async fn change(
    State(w): State<Workspace>,
    Path((address, created)): Path<(String, u64)>,
    Json(body): Json<Change>,
) -> Result<impl IntoResponse, ApiError> {
    let session = Session {
        core: body.core,
        address,
        created,
    };
    if body.allowed {
        let connection = identity(&w).ok_or(CLOSED)?;
        let launch = live_launch(&w, &session).await?;
        if identity(&w) != Some(connection) {
            return Err(CLOSED);
        }
        w.drive_access.grant(session.clone(), launch, connection)?;
    } else {
        w.drive_access
            .0
            .lock()
            .map_err(|_| StoreError)?
            .grants
            .remove(&session);
    }
    Ok(Json(view(&w, &session)?))
}

fn identity(w: &Workspace) -> Option<[u8; 32]> {
    w.drive_files.as_ref()?.access_identity()
}

fn view(w: &Workspace, session: &Session) -> Result<Status, ApiError> {
    let connection = identity(w);
    let access = w.drive_access.0.lock().map_err(|_| StoreError)?;
    let available = access.ready && connection.is_some();
    let grant = access
        .grants
        .get(session)
        .filter(|g| g.until > Instant::now() && available && Some(g.connection) == connection);
    Ok(Status {
        available,
        allowed: grant.is_some(),
        minutes_remaining: grant.map_or(0, |g| {
            g.until
                .saturating_duration_since(Instant::now())
                .as_secs()
                .div_ceil(60)
        }),
        helper: grant
            .and_then(|_| std::env::current_exe().ok())
            .and_then(|path| path.to_str().map(agent::shell_quote)),
        recent: access
            .recent
            .iter()
            .filter(|(target, _)| target == session)
            .take(12)
            .map(|(_, call)| call.clone())
            .collect(),
    })
}

async fn live_launch(w: &Workspace, session: &Session) -> Result<String, ApiError> {
    if w.core.identify().await?.core.id != session.core {
        return Err(ApiError::Conflict("The active Herdr Core changed."));
    }
    let agent = w.core.agent(&session.address, session.created).await?;
    agent.require_live()?;
    agent
        .launch_key()
        .map(str::to_owned)
        .ok_or(ApiError::Conflict(
            "Start this agent from SwarmHub to grant access.",
        ))
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    launch: String,
    action: Action,
    path: String,
}

#[derive(Default, Serialize, Deserialize)]
struct Reply {
    bytes: usize,
    name: Option<String>,
    error: Option<String>,
}

async fn serve(w: Workspace, mut stream: UnixStream) {
    let request = async {
        let size = stream.read_u32_le().await? as usize;
        if size > FRAME {
            return Err(io::Error::other("Invalid Drive request"));
        }
        let mut buf = vec![0; size];
        stream.read_exact(&mut buf).await?;
        decode::<Request>(&buf)
    };
    let Ok(Ok(request)) = timeout(Duration::from_secs(2), request).await else {
        return;
    };
    let (header, data) = match perform(&w, request).await {
        Ok((name, data)) => (
            Reply {
                bytes: data.len(),
                name,
                error: None,
            },
            data,
        ),
        Err(error) => (
            Reply {
                error: Some(error.into()),
                ..Default::default()
            },
            Vec::new(),
        ),
    };
    let Ok(bytes) = serde_json::to_vec(&header) else {
        return;
    };
    let write = async {
        stream.write_u32_le(bytes.len() as u32).await?;
        stream.write_all(&bytes).await?;
        stream.write_all(&data).await
    };
    let _ = timeout(Duration::from_secs(5), write).await;
}

async fn perform(
    w: &Workspace,
    request: Request,
) -> Result<(Option<String>, Vec<u8>), &'static str> {
    let (session, grant) = w.drive_access.find(&request.launch).ok_or(DENIED)?;
    let path = request.path;
    // Provider path validation is also checked by the connector. Bound audit text
    // before processing, and exclude special characters from the displayed record.
    let path_valid = path.len() <= 2048
        && path
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-/".contains(&b));
    let check = async {
        if identity(w) != Some(grant.connection)
            || !token_matches(
                &live_launch(w, &session).await.map_err(|_| DENIED)?,
                &grant.launch,
            )
        {
            return Err(DENIED);
        }
        if !w
            .drive_access
            .find(&grant.launch)
            .is_some_and(|(target, active)| {
                target == session && active.generation == grant.generation
            })
        {
            return Err(DENIED);
        }
        Ok(())
    };
    let use_drive = async {
        if !path_valid {
            return Err("Choose a valid path from the Google Drive listing.");
        }
        check.await?;
        let drive = w.drive_files.as_ref().ok_or(DENIED)?;
        let result = match request.action {
            Action::List => drive
                .agent_list(path.clone())
                .await
                .map(|data| (None, data)),
            Action::Read => drive
                .read(&path)
                .await
                .map(|(name, data)| (Some(name), data)),
        };
        let (name, data) = match result {
            Ok(value) => value,
            Err(ApiError::PayloadTooLarge(_)) => {
                return Err("The Google Drive file exceeds 8 MiB.");
            }
            Err(ApiError::NotFound | ApiError::Core(crate::Failure::Input(_))) => {
                return Err(
                    "The requested item cannot be read in the connected Google Drive folder.",
                );
            }
            Err(_) => return Err("Google Drive could not complete the request."),
        };
        if data.len() > MAX_FILE {
            return Err("The Google Drive result exceeds 8 MiB.");
        }
        // A revoke, connection change or stopped session while Drive was working
        // must prevent the data from leaving the broker.
        if !token_matches(
            &live_launch(w, &session).await.map_err(|_| DENIED)?,
            &grant.launch,
        ) || identity(w) != Some(grant.connection)
            || !w
                .drive_access
                .find(&grant.launch)
                .is_some_and(|(target, active)| {
                    target == session && active.generation == grant.generation
                })
        {
            return Err(DENIED);
        }
        Ok((name, data))
    };
    let result = timeout(Duration::from_secs(30), use_drive)
        .await
        .unwrap_or(Err("The Google Drive request took too long."));
    w.drive_access.record(
        session,
        Call {
            action: request.action,
            path: if path_valid { path } else { String::new() },
            at_ms: now(),
            succeeded: result.is_ok(),
        },
    );
    result
}

fn decode<T: DeserializeOwned>(bytes: &[u8]) -> io::Result<T> {
    serde_json::from_slice(bytes).map_err(|_| io::Error::other("Invalid Drive message"))
}

pub(crate) fn cli(read: bool) -> Result<(), Box<dyn std::error::Error>> {
    let mut args = std::env::args().skip(2);
    let path = args.next().unwrap_or_default();
    if args.next().is_some() || (read && path.is_empty()) || path.len() > 2048 {
        return Err("Use drive-list [FOLDER] or drive-read FILE.".into());
    }
    let (journal, launch) = agent::session()?;
    let request = serde_json::to_vec(&Request {
        launch,
        path,
        action: if read { Action::Read } else { Action::List },
    })?;
    if request.len() > FRAME {
        return Err("Invalid Google Drive path.".into());
    }
    let mut stream = BlockingStream::connect(socket_path(&journal))
        .map_err(|_| "The SwarmHub Drive connection is unavailable.")?;
    stream.set_read_timeout(Some(Duration::from_secs(35)))?;
    stream.set_write_timeout(Some(Duration::from_secs(3)))?;
    stream.write_all(&(request.len() as u32).to_le_bytes())?;
    stream.write_all(&request)?;
    let mut size = [0; 4];
    stream.read_exact(&mut size)?;
    let size = u32::from_le_bytes(size) as usize;
    if size > FRAME {
        return Err("Invalid Drive reply.".into());
    }
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes)?;
    let reply: Reply = decode(&bytes)?;
    if let Some(error) = reply.error {
        return Err(error.into());
    }
    if reply.bytes > MAX_FILE {
        return Err("Invalid Drive reply.".into());
    }
    let mut data = vec![0; reply.bytes];
    stream.read_exact(&mut data)?;
    io::stdout().lock().write_all(&data)?;
    if !read {
        println!();
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        core::Core, drive_files::tests::fixture_connector, history::History, local_browser,
    };
    use axum::{http::StatusCode, middleware};
    use serde_json::{Value, json};
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::io::{AsyncBufReadExt, BufReader};

    const LAUNCH: &str = "11111111111111111111111111111111";
    const OTHER: &str = "22222222222222222222222222222222";

    async fn json_response(request: reqwest::RequestBuilder) -> Value {
        let bytes = request
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap()
            .bytes()
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    async fn exchange(path: PathBuf, body: Value) -> io::Result<(Reply, Vec<u8>)> {
        let mut stream = UnixStream::connect(path).await?;
        let data = serde_json::to_vec(&body)?;
        stream.write_u32_le(data.len() as u32).await?;
        stream.write_all(&data).await?;
        let size = stream.read_u32_le().await? as usize;
        assert!(size <= FRAME);
        let mut response = vec![0; size];
        stream.read_exact(&mut response).await?;
        let reply: Reply = decode(&response)?;
        let mut data = vec![0; reply.bytes];
        stream.read_exact(&mut data).await?;
        Ok((reply, data))
    }

    #[tokio::test]
    async fn only_granted_live_launch_can_read_and_browser_shows_its_requests() {
        let temp = tempfile::tempdir().unwrap();
        let history = History::open_at(&temp.path().join("state")).unwrap();
        let core_path = temp.path().join("core.sock");
        let core_listener = UnixListener::bind(&core_path).unwrap();
        let running = Arc::new(AtomicBool::new(true));
        let live = running.clone();
        let core_server = tokio::spawn(async move {
            while let Ok((socket, _)) = core_listener.accept().await {
                let mut socket = BufReader::new(socket);
                let mut line = String::new();
                socket.read_line(&mut line).await.unwrap();
                let request: Value = serde_json::from_str(&line).unwrap();
                let result = match request["method"].as_str() {
                    Some("hello") => {
                        json!({"generation":1,"version":"fixture","core":{"id":"core-here"},
                        "methods":["templates.list","terminal.get","terminal.list","terminal.run","terminal.read","terminal.send","terminal.interrupt","terminal.kill"]})
                    }
                    Some("terminal.get") => {
                        let address = request["params"]["terminal"].as_str().unwrap();
                        json!({"address":address,"name":"Reporting agent","state":if live.load(Ordering::Relaxed) {"live"} else {"ended"},
                            "template":"fixture","created_ms":42,"labels":{"swarmhub.workspace":"agent",
                            "swarmhub.launch":if address == "t1" {LAUNCH} else {OTHER}}})
                    }
                    _ => panic!("unexpected Core method"),
                };
                let mut response =
                    serde_json::to_vec(&json!({"jsonrpc":"2.0","id":1,"result":result})).unwrap();
                response.push(b'\n');
                socket.get_mut().write_all(&response).await.unwrap();
            }
        });
        let (drive, tokens, provider) = fixture_connector().await;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let access_token = "a".repeat(64);
        let w = Workspace {
            core: Core(core_path),
            history,
            approvals: Default::default(),
            drafts: Default::default(),
            connected_files: None,
            drive_access: Desk::default(),
            drive_files: Some(drive),
            github_project: None,
            vault: None,
            slack: None,
            port,
            token: access_token.clone(),
        };
        listen(w.clone()).unwrap();
        let pipe = socket_path(w.history.file());
        let app = routes()
            .layer(middleware::from_fn_with_state(w.clone(), local_browser))
            .with_state(w.clone());
        let server = tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        let base = format!("http://127.0.0.1:{port}");
        let url = format!("{base}/api/agents/t1/42/drive-access");
        let client = reqwest::Client::builder().no_proxy().build().unwrap();
        let status = || {
            client
                .get(format!("{url}?core=core-here"))
                .bearer_auth(&access_token)
        };
        let change_from = |allowed, origin: &str| {
            client
                .post(&url)
                .header(header::ORIGIN, origin)
                .bearer_auth(&access_token)
                .header(header::CONTENT_TYPE, "application/json")
                .body(json!({"core":"core-here","allowed":allowed}).to_string())
        };
        let change = |allowed| change_from(allowed, &base);
        let query = |launch, action, path| {
            exchange(
                pipe.clone(),
                json!({"launch":launch,"action":action,"path":path}),
            )
        };
        assert_eq!(
            client
                .get(format!("{url}?core=core-here"))
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            change_from(true, "https://outside.test")
                .send()
                .await
                .unwrap()
                .status(),
            StatusCode::FORBIDDEN
        );
        assert_eq!(json_response(status()).await["allowed"], false);
        assert_eq!(
            query(LAUNCH, "read", "sub/blob")
                .await
                .unwrap()
                .0
                .error
                .as_deref(),
            Some(DENIED)
        );
        assert_eq!(tokens.load(Ordering::Relaxed), 0);
        let granted = json_response(change(true)).await;
        assert_eq!(granted["allowed"], true);

        assert_eq!(
            query(OTHER, "list", "").await.unwrap().0.error.as_deref(),
            Some(DENIED)
        );
        let (reply, data) = query(LAUNCH, "list", "sub").await.unwrap();
        assert!(reply.error.is_none());
        let listing: Value = serde_json::from_slice(&data).unwrap();
        assert!(
            listing["entries"]
                .as_array()
                .unwrap()
                .iter()
                .any(|entry| entry["id"] == "blob")
        );
        assert!(listing.get("uploads").is_none());
        assert!(!String::from_utf8_lossy(&data).contains("fixture-refresh"));
        let (reply, data) = query(LAUNCH, "read", "sub/blob").await.unwrap();
        assert!(reply.error.is_none());
        assert_eq!(data, b"content");
        for path in ["sub/outside", "../blob", "sub/big"] {
            let (reply, data) = query(LAUNCH, "read", path).await.unwrap();
            assert!(reply.error.is_some());
            assert!(data.is_empty());
        }
        assert!(query(LAUNCH, "write", "sub/blob").await.is_err());

        let response = json_response(status()).await;
        let recent = response["recent"].as_array().unwrap();
        assert_eq!(recent.len(), 5);
        assert_eq!(recent[3]["path"], "sub/blob");
        assert_eq!(recent[3]["succeeded"], true);
        let other = json_response(
            client
                .get(format!(
                    "{base}/api/agents/t2/42/drive-access?core=core-here"
                ))
                .bearer_auth(&access_token),
        )
        .await;
        assert_eq!(other["recent"], json!([]));

        assert_eq!(json_response(change(false)).await["allowed"], false);
        assert_eq!(
            query(LAUNCH, "read", "sub/blob")
                .await
                .unwrap()
                .0
                .error
                .as_deref(),
            Some(DENIED)
        );
        change(true)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap();
        w.drive_access
            .0
            .lock()
            .unwrap()
            .grants
            .values_mut()
            .next()
            .unwrap()
            .until = Instant::now();
        assert_eq!(
            query(LAUNCH, "read", "sub/blob")
                .await
                .unwrap()
                .0
                .error
                .as_deref(),
            Some(DENIED)
        );
        change(true)
            .send()
            .await
            .unwrap()
            .error_for_status()
            .unwrap();
        running.store(false, Ordering::Relaxed);
        assert_eq!(
            query(LAUNCH, "read", "sub/blob")
                .await
                .unwrap()
                .0
                .error
                .as_deref(),
            Some(DENIED)
        );
        for handle in [server, core_server, provider] {
            handle.abort();
        }
    }
}
