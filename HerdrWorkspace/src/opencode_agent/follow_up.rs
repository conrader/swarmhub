//! A private local capability bound to one running OpenCode session.
use super::first_task::{ApiSession, Outcome};
use super::models::{ModelChange, ModelOperation, ModelResult, ModelState};
use crate::core::{Delivery, Failure, Terminal};
use crate::group_preview::Binding;
use crate::person_profile::validate_prompt;
use ring::{
    hmac,
    rand::{SecureRandom, SystemRandom},
};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use std::{
    fs,
    io::{self, Read},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
    time::timeout,
};

const FRAME: u64 = 128 * 1024;
const CONNECT: Duration = Duration::from_secs(2);
const DELIVERY: Duration = Duration::from_secs(20);
const MODEL_TIMEOUT: Duration = Duration::from_secs(30);
const MODEL_CAPABILITY: &str = "models-v1";
const GROUP_CAPABILITY: &str = "group-preview-v1";
const UNAVAILABLE: &str =
    "OpenCode's follow-up channel is unavailable. Open the terminal or start a new session.";
const BLOCKED: &str = "OpenCode is waiting for a permission decision or an answer. Resolve it before sending another task.";

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Capability {
    socket: PathBuf,
    terminal: String,
    key: [u8; 32],
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Request<'a> {
    launch: std::borrow::Cow<'a, str>,
    terminal: std::borrow::Cow<'a, str>,
    text: std::borrow::Cow<'a, str>,
    auth: [u8; 32],
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct ModelRequest<'a> {
    launch: std::borrow::Cow<'a, str>,
    terminal: std::borrow::Cow<'a, str>,
    model: ModelOperation,
    auth: [u8; 32],
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct GroupRequest<'a> {
    launch: std::borrow::Cow<'a, str>,
    terminal: std::borrow::Cow<'a, str>,
    text: std::borrow::Cow<'a, str>,
    group: Binding,
    auth: [u8; 32],
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Incoming<'a> {
    Send(Request<'a>),
    Model(ModelRequest<'a>),
    Group(GroupRequest<'a>),
}

#[derive(Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Response {
    Accepted,
    Blocked,
    Busy,
    Unavailable,
    Uncertain,
}

fn metadata(journal: &Path, launch: &str) -> Option<PathBuf> {
    (launch.len() == 32 && launch.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| journal.with_file_name(format!("opencode-send-{launch}.json")))
}

fn binding(launch: &str, terminal: &str, text: &str) -> Vec<u8> {
    let mut message = b"swarmhub-opencode-follow-up-v1\0".to_vec();
    for field in [launch, terminal, text] {
        message.extend_from_slice(&(field.len() as u64).to_be_bytes());
        message.extend_from_slice(field.as_bytes());
    }
    message
}

fn authorized(key: &[u8; 32], request: &Request<'_>) -> bool {
    hmac::verify(
        &hmac::Key::new(hmac::HMAC_SHA256, key),
        &binding(&request.launch, &request.terminal, &request.text),
        &request.auth,
    )
    .is_ok()
}

fn model_binding(request: &ModelRequest<'_>) -> Option<Vec<u8>> {
    let model = serde_json::to_string(&request.model).ok()?;
    let mut result = b"swarmhub-opencode-model-v1\0".to_vec();
    result.extend(binding(&request.launch, &request.terminal, &model));
    Some(result)
}

fn group_binding(request: &GroupRequest<'_>) -> Option<Vec<u8>> {
    let group = serde_json::to_string(&request.group).ok()?;
    let mut result = b"swarmhub-opencode-group-send-v1\0".to_vec();
    result.extend(binding(&request.launch, &request.terminal, &request.text));
    result.extend(group.as_bytes());
    Some(result)
}

fn capability(journal: &Path, launch: &str) -> io::Result<Capability> {
    let path = metadata(journal, launch).ok_or_else(|| io::Error::other(UNAVAILABLE))?;
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let stat = file.metadata()?;
    if !stat.is_file() || stat.permissions().mode() & 0o077 != 0 {
        return Err(io::Error::other(UNAVAILABLE));
    }
    let mut bytes = Vec::new();
    file.take(8193).read_to_end(&mut bytes)?;
    if bytes.len() > 8192 {
        return Err(io::Error::other(UNAVAILABLE));
    }
    serde_json::from_slice(&bytes).map_err(io::Error::other)
}

pub async fn send(journal: &Path, agent: &Terminal, task: &str) -> Result<Delivery, Failure> {
    send_task(journal, agent, task, None).await
}

pub(crate) async fn send_group(
    journal: &Path,
    agent: &Terminal,
    task: &str,
    group: Binding,
) -> Result<Delivery, Failure> {
    send_task(journal, agent, task, Some(group)).await
}

async fn send_task(
    journal: &Path,
    agent: &Terminal,
    task: &str,
    group: Option<Binding>,
) -> Result<Delivery, Failure> {
    validate_prompt(task)?;
    agent.require_live()?;
    if agent
        .status
        .as_ref()
        .is_some_and(|status| status.state == "blocked")
    {
        return Err(Failure::Rejected("blocked".into(), BLOCKED.into()));
    }
    let launch = agent.launch_key().ok_or(Failure::Input(UNAVAILABLE))?;
    let cap = capability(journal, launch).map_err(|_| Failure::Input(UNAVAILABLE))?;
    if cap.terminal != agent.address || !cap.socket.is_absolute() {
        return Err(Failure::Input(UNAVAILABLE));
    }
    let key = hmac::Key::new(hmac::HMAC_SHA256, &cap.key);
    // An older broker still receives one ordinary API send. Never try a
    // second transport after writing a request to any broker.
    let tagged = fs::symlink_metadata(cap.socket.with_file_name(GROUP_CAPABILITY))
        .is_ok_and(|metadata| metadata.file_type().is_file());
    let mut body = if let Some(group) = group.filter(|_| tagged) {
        if !group.valid_shape() {
            return Err(Failure::Input(UNAVAILABLE));
        }
        let mut request = GroupRequest {
            launch: launch.into(),
            terminal: agent.address.as_str().into(),
            text: task.into(),
            group,
            auth: [0; 32],
        };
        let material = group_binding(&request).ok_or(Failure::Input(UNAVAILABLE))?;
        request
            .auth
            .copy_from_slice(hmac::sign(&key, &material).as_ref());
        serde_json::to_vec(&request)
    } else {
        let mut request = Request {
            launch: launch.into(),
            terminal: agent.address.as_str().into(),
            text: task.into(),
            auth: [0; 32],
        };
        request
            .auth
            .copy_from_slice(hmac::sign(&key, &binding(launch, &agent.address, task)).as_ref());
        serde_json::to_vec(&request)
    }
    .map_err(|_| Failure::Input(UNAVAILABLE))?;
    body.push(b'\n');
    if body.len() as u64 > FRAME {
        return Err(Failure::Input("The OpenCode task is too large."));
    }
    let mut stream = timeout(CONNECT, UnixStream::connect(cap.socket))
        .await
        .map_err(|_| Failure::Input(UNAVAILABLE))?
        .map_err(|_| Failure::Input(UNAVAILABLE))?;
    let result = timeout(DELIVERY, async {
        stream.write_all(&body).await?;
        frame::<Response>(&mut stream, 1024).await
    })
    .await
    .map_err(|_| Failure::Uncertain)?
    .map_err(|_| Failure::Uncertain)?;
    match result {
        Response::Accepted => Ok(Delivery {
            status: None,
            started: None,
        }),
        Response::Blocked => Err(Failure::Rejected("blocked".into(), BLOCKED.into())),
        Response::Busy => Err(Failure::Input(
            "OpenCode is already accepting another task. Try again after that send finishes.",
        )),
        Response::Unavailable => Err(Failure::Input(UNAVAILABLE)),
        Response::Uncertain => Err(Failure::Uncertain),
    }
}

pub(super) async fn model_state(journal: &Path, agent: &Terminal) -> Result<ModelState, Failure> {
    model_operation(journal, agent, ModelOperation::Read).await
}

pub(super) async fn change_model(
    journal: &Path,
    agent: &Terminal,
    change: ModelChange,
    expected_current: Option<String>,
    expected_default: Option<String>,
) -> Result<ModelState, Failure> {
    model_operation(
        journal,
        agent,
        ModelOperation::Change {
            change,
            expected_current,
            expected_default,
        },
    )
    .await
}

async fn model_operation(
    journal: &Path,
    agent: &Terminal,
    model: ModelOperation,
) -> Result<ModelState, Failure> {
    const MODEL_UNAVAILABLE: &str = "OpenCode's model controls are unavailable. Start a new API-backed session if this session predates model controls.";
    agent.require_live()?;
    let launch = agent
        .launch_key()
        .ok_or(Failure::Input(MODEL_UNAVAILABLE))?;
    let cap = capability(journal, launch).map_err(|_| Failure::Input(MODEL_UNAVAILABLE))?;
    if cap.terminal != agent.address
        || !cap.socket.is_absolute()
        || !fs::symlink_metadata(cap.socket.with_file_name(MODEL_CAPABILITY))
            .is_ok_and(|metadata| metadata.file_type().is_file())
    {
        return Err(Failure::Input(MODEL_UNAVAILABLE));
    }
    let reading = matches!(model, ModelOperation::Read);
    let mut request = ModelRequest {
        launch: launch.into(),
        terminal: agent.address.as_str().into(),
        model,
        auth: [0; 32],
    };
    let material = model_binding(&request).ok_or(Failure::Input(MODEL_UNAVAILABLE))?;
    let tag = hmac::sign(&hmac::Key::new(hmac::HMAC_SHA256, &cap.key), &material);
    request.auth.copy_from_slice(tag.as_ref());
    let mut bytes = serde_json::to_vec(&request).map_err(|_| Failure::Input(MODEL_UNAVAILABLE))?;
    bytes.push(b'\n');
    if bytes.len() as u64 > FRAME {
        return Err(Failure::Input(MODEL_UNAVAILABLE));
    }
    let mut stream = timeout(CONNECT, UnixStream::connect(cap.socket))
        .await
        .map_err(|_| Failure::Input(MODEL_UNAVAILABLE))?
        .map_err(|_| Failure::Input(MODEL_UNAVAILABLE))?;
    let lost = || {
        if reading {
            Failure::Input(MODEL_UNAVAILABLE)
        } else {
            Failure::Uncertain
        }
    };
    let result = timeout(MODEL_TIMEOUT, async {
        stream.write_all(&bytes).await?;
        frame::<ModelResult>(&mut stream, 1024).await
    })
    .await
    .map_err(|_| lost())?
    .map_err(|_| lost())?;
    match result {
        ModelResult::State {state} => Ok(state),
        ModelResult::Blocked => Err(Failure::Rejected("blocked".into(), BLOCKED.into())),
        ModelResult::Busy => Err(Failure::Rejected("blocked".into(), "Wait for OpenCode's current and queued work to finish before changing the model.".into())),
        ModelResult::NoDefault => Err(Failure::Input("OpenCode did not report a configured default model.")),
        ModelResult::Changed => Err(Failure::Rejected("status_mismatch".into(), "OpenCode's current or default model changed. Review its latest selection before proceeding.".into())),
        ModelResult::Unavailable => Err(Failure::Input(MODEL_UNAVAILABLE)),
        ModelResult::Uncertain => Err(Failure::Uncertain),
    }
}

async fn frame<T: DeserializeOwned>(socket: &mut UnixStream, limit: u64) -> io::Result<T> {
    let mut bytes = Vec::new();
    BufReader::new(socket)
        .take(limit)
        .read_until(b'\n', &mut bytes)
        .await?;
    if bytes.last() != Some(&b'\n') {
        return Err(io::Error::other("Incomplete OpenCode follow-up frame."));
    }
    serde_json::from_slice(&bytes).map_err(io::Error::other)
}

pub(super) struct Endpoint {
    path: PathBuf,
    _directory: tempfile::TempDir,
    listener: UnixListener,
    identity: Identity,
}

struct Identity {
    launch: String,
    terminal: String,
    key: [u8; 32],
}

impl Endpoint {
    pub(super) fn bind(journal: &Path, launch: &str, terminal: String) -> io::Result<Self> {
        let path = metadata(journal, launch).ok_or_else(|| io::Error::other(UNAVAILABLE))?;
        if !crate::core::local_address(&terminal) {
            return Err(io::Error::other(UNAVAILABLE));
        }
        let directory = tempfile::Builder::new().prefix("swarmhub-oc-").tempdir()?;
        let socket = directory.path().join("send.sock");
        let listener = UnixListener::bind(&socket)?;
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600))?;
        for feature in [MODEL_CAPABILITY, GROUP_CAPABILITY] {
            fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(directory.path().join(feature))?;
        }
        let mut secret = [0; 32];
        SystemRandom::new()
            .fill(&mut secret)
            .map_err(|_| io::Error::other(UNAVAILABLE))?;
        let mut file = tempfile::NamedTempFile::new_in(
            journal
                .parent()
                .ok_or_else(|| io::Error::other(UNAVAILABLE))?,
        )?;
        serde_json::to_writer(
            &mut file,
            &Capability {
                socket,
                terminal: terminal.clone(),
                key: secret,
            },
        )?;
        file.persist_noclobber(&path)?;
        Ok(Self {
            path,
            _directory: directory,
            listener,
            identity: Identity {
                launch: launch.into(),
                terminal,
                key: secret,
            },
        })
    }

    pub(super) async fn serve(&self, session: ApiSession, password: String) -> io::Result<()> {
        let session = Arc::new(session);
        let password = Arc::new(password);
        let slots = Arc::new(Semaphore::new(4));
        let admission = Arc::new(Semaphore::new(1));
        let identity = Arc::new(Identity {
            launch: self.identity.launch.clone(),
            terminal: self.identity.terminal.clone(),
            key: self.identity.key,
        });
        let mut requests = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                result = self.listener.accept() => {
                    let (stream, _) = result?;
                    let Ok(slot) = slots.clone().try_acquire_owned() else { continue };
                    let session = session.clone();
                    let password = password.clone();
                    let identity = identity.clone();
                    let admission = admission.clone();
                    requests.spawn(async move {
                        let _slot = slot;
                        handle(stream, &identity, &session, &password, admission).await;
                    });
                }
                _ = requests.join_next(), if !requests.is_empty() => {}
            }
        }
    }
}

impl Drop for Endpoint {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

async fn handle(
    mut stream: UnixStream,
    identity: &Identity,
    session: &ApiSession,
    password: &str,
    admission: Arc<Semaphore>,
) {
    let Ok(Ok(request)) = timeout(CONNECT, frame::<Incoming<'static>>(&mut stream, FRAME)).await
    else {
        return;
    };
    let (launch, terminal, text, group, authenticated) = match request {
        Incoming::Model(request) => {
            let result = if request.launch != identity.launch
                || request.terminal != identity.terminal
                || !model_binding(&request).is_some_and(|material| {
                    hmac::verify(
                        &hmac::Key::new(hmac::HMAC_SHA256, &identity.key),
                        &material,
                        &request.auth,
                    )
                    .is_ok()
                }) {
                ModelResult::Unavailable
            } else {
                match request.model {
                    ModelOperation::Read => session.model_state(password).await,
                    ModelOperation::Change {
                        change,
                        expected_current,
                        expected_default,
                    } => {
                        if let Ok(_permit) = admission.try_acquire() {
                            session
                                .change_model(password, change, expected_current, expected_default)
                                .await
                        } else {
                            ModelResult::Busy
                        }
                    }
                }
            };
            write_response(&mut stream, &result).await;
            return;
        }
        Incoming::Send(request) => {
            let ok = authorized(&identity.key, &request);
            (request.launch, request.terminal, request.text, None, ok)
        }
        Incoming::Group(request) => {
            let ok = request.group.valid_shape()
                && group_binding(&request).is_some_and(|material| {
                    hmac::verify(
                        &hmac::Key::new(hmac::HMAC_SHA256, &identity.key),
                        &material,
                        &request.auth,
                    )
                    .is_ok()
                });
            (
                request.launch,
                request.terminal,
                request.text,
                Some(request.group),
                ok,
            )
        }
    };
    let result = if launch != identity.launch
        || terminal != identity.terminal
        || !authenticated
        || validate_prompt(&text).is_err()
    {
        Response::Unavailable
    } else if let Ok(_permit) = admission.try_acquire() {
        match session.attention(password).await {
            Ok(true) => Response::Blocked,
            Err(_) => Response::Unavailable,
            Ok(false) => match if let Some(group) = group {
                session.send_group(password, &text, &group).await
            } else {
                session.send(password, &text).await
            } {
                Outcome::Submitted => Response::Accepted,
                Outcome::NotSent => Response::Unavailable,
                Outcome::Uncertain => Response::Uncertain,
            },
        }
    } else {
        Response::Busy
    };
    write_response(&mut stream, &result).await;
}

async fn write_response(stream: &mut UnixStream, result: &impl Serialize) {
    if let Ok(mut bytes) = serde_json::to_vec(result) {
        bytes.push(b'\n');
        let _ = timeout(CONNECT, stream.write_all(&bytes)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        Json, Router,
        http::StatusCode,
        routing::{get, post},
    };
    use serde_json::json;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[tokio::test]
    async fn forbids_bad_auth_or_native_attention_and_does_not_retry_uncertain_sends() {
        let home = tempfile::tempdir().unwrap();
        let journal = home.path().join("workspace.sqlite3");
        let launch = "00112233445566778899aabbccddeeff";
        let target: Terminal = serde_json::from_value(json!({
            "address":"t1", "created_ms":1, "state":"live", "template":"opencode",
            "labels":{"swarmhub.launch":launch}
        }))
        .unwrap();
        let endpoint = Endpoint::bind(&journal, launch, "t1".into()).unwrap();
        let cap = capability(&journal, launch).unwrap();
        let pending = Arc::new(AtomicUsize::new(1));
        let pending_request = pending.clone();
        let pending_form = pending.clone();
        let calls = Arc::new(AtomicUsize::new(0));
        let received = calls.clone();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url =
            reqwest::Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let fake = Router::new()
            .route(
                "/api/session",
                post(|| async { Json(json!({"data":{"id":"ses_fixture"}})) }),
            )
            .route(
                "/api/session/ses_fixture/permission",
                get(move || async move {
                    let list = if pending_request.load(Ordering::Relaxed) == 1 {
                        json!([{"id":"pending"}])
                    } else {
                        json!([])
                    };
                    Json(json!({"data":list}))
                }),
            )
            .route(
                "/api/session/ses_fixture/form",
                get(move || async move {
                    let list = if pending_form.load(Ordering::Relaxed) == 2 {
                        json!([{"id":"pending-form"}])
                    } else {
                        json!([])
                    };
                    Json(json!({"data":list}))
                }),
            )
            .route(
                "/api/session/ses_fixture/prompt",
                post(move |Json(body): Json<serde_json::Value>| async move {
                    assert_eq!(body["text"], "One web task");
                    if received.fetch_add(1, Ordering::Relaxed) == 0 {
                        StatusCode::OK
                    } else {
                        StatusCode::BAD_GATEWAY
                    }
                }),
            );
        let server = tokio::spawn(async move { axum::serve(listener, fake).await.unwrap() });
        let session = super::super::first_task::create_session(&url, "fixture", None)
            .await
            .unwrap();
        let worker =
            tokio::spawn(async move { endpoint.serve(session, "fixture".into()).await.unwrap() });
        let mut stream = UnixStream::connect(cap.socket).await.unwrap();
        let wrong = Request {
            launch: launch.into(),
            terminal: "t1".into(),
            text: "Wrong task".into(),
            auth: [0; 32],
        };
        let mut wire = serde_json::to_vec(&wrong).unwrap();
        wire.push(b'\n');
        stream.write_all(&wire).await.unwrap();
        assert_eq!(
            frame::<Response>(&mut stream, 1024).await.unwrap(),
            Response::Unavailable
        );
        assert!(
            matches!(send(&journal, &target, "One web task").await, Err(Failure::Rejected(kind, _)) if kind == "blocked")
        );
        pending.store(2, Ordering::Relaxed);
        assert!(
            matches!(send(&journal, &target, "One web task").await, Err(Failure::Rejected(kind, _)) if kind == "blocked")
        );
        assert_eq!(calls.load(Ordering::Relaxed), 0);
        pending.store(0, Ordering::Relaxed);
        assert!(send(&journal, &target, "One web task").await.is_ok());
        assert!(matches!(
            send(&journal, &target, "One web task").await,
            Err(Failure::Uncertain)
        ));
        assert_eq!(calls.load(Ordering::Relaxed), 2);
        worker.abort();
        server.abort();
    }
}
