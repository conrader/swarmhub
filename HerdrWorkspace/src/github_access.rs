//! User-granted, local-only read broker for the configured GitHub project.
use super::{CredentialStamp, Item, Kind, Project};
use crate::{
    ApiError, Workspace, agent,
    history::{StoreError, now},
    token_matches,
};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    http::header,
    routing::get,
};
use serde::{Deserialize, Serialize};
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
    sync::{Semaphore, watch},
    time::timeout,
};

const AGE: Duration = Duration::from_secs(3600);
const MAX_REQUEST: usize = 1024;
const MAX_REPLY: usize = 24 * 1024;
const UNAVAILABLE: ApiError = ApiError::Conflict("GitHub agent access is unavailable.");
const DENIED: &str = "This agent session does not have GitHub read access.";

#[derive(Clone, PartialEq, Eq, Hash)]
struct Session {
    core: String,
    address: String,
    created: u64,
}

struct Grant {
    launch: String,
    stamp: CredentialStamp,
    until: Instant,
    cancel: watch::Sender<()>,
}

struct Lease {
    session: Session,
    stamp: CredentialStamp,
    until: Instant,
    cancel: watch::Receiver<()>,
}

#[derive(Clone, Serialize)]
struct Call {
    kind: Kind,
    number: u32,
    at_ms: i64,
    succeeded: bool,
}

#[derive(Default)]
struct Access {
    ready: bool,
    grants: HashMap<Session, Grant>,
    recent: VecDeque<(Session, Call)>,
}

#[derive(Default)]
pub(super) struct Desk(Mutex<Access>);

impl Access {
    fn prune(&mut self, stamp: Option<&CredentialStamp>) {
        let now = Instant::now();
        self.grants
            .retain(|_, grant| grant.until > now && stamp == Some(&grant.stamp));
    }
}

impl Desk {
    fn grant(
        &self,
        session: Session,
        launch: String,
        stamp: CredentialStamp,
    ) -> Result<(), ApiError> {
        let mut access = self.0.lock().map_err(|_| StoreError)?;
        access.prune(Some(&stamp));
        if !access.ready || (access.grants.len() >= 64 && !access.grants.contains_key(&session)) {
            return Err(UNAVAILABLE);
        }
        let (cancel, _) = watch::channel(());
        access.grants.insert(
            session,
            Grant {
                launch,
                stamp,
                until: Instant::now() + AGE,
                cancel,
            },
        );
        Ok(())
    }

    fn lease(&self, key: &str, stamp: Option<&CredentialStamp>) -> Option<Lease> {
        let mut access = self.0.lock().ok()?;
        access.prune(stamp);
        let (session, grant) = access
            .grants
            .iter()
            .find(|(_, grant)| token_matches(key, &grant.launch))?;
        Some(Lease {
            session: session.clone(),
            stamp: grant.stamp.clone(),
            until: grant.until,
            cancel: grant.cancel.subscribe(),
        })
    }

    fn record(&self, session: Session, call: Call) {
        if let Ok(mut access) = self.0.lock() {
            access.recent.push_front((session, call));
            access.recent.truncate(192);
        }
    }
}

fn socket_path(history: &std::path::Path) -> PathBuf {
    history.with_file_name("github-agent.sock")
}

pub(crate) fn listen(w: Workspace) -> io::Result<()> {
    let Some(project) = &w.github_project else {
        return Ok(());
    };
    let path = socket_path(w.history.file());
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_socket() => fs::remove_file(&path)?,
        Ok(_) => return Err(io::Error::other("GitHub access path is not a socket")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    // The workspace holds its exclusive lock in the mode-0700 directory.
    let listener = UnixListener::bind(path)?;
    project
        .0
        .agent_access
        .0
        .lock()
        .map_err(|_| io::Error::other("GitHub access is unavailable"))?
        .ready = true;
    let project = project.clone();
    let slots = Arc::new(Semaphore::new(4));
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let Ok(permit) = slots.clone().try_acquire_owned() else {
                continue;
            };
            let w = w.clone();
            let project = project.clone();
            tokio::spawn(async move {
                let _permit = permit;
                serve(w, project, stream).await;
            });
        }
        if let Ok(mut access) = project.0.agent_access.0.lock() {
            access.ready = false;
            access.grants.clear();
        }
    });
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
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
    repository: String,
    available: bool,
    minutes_remaining: Option<u64>,
    helper: Option<String>,
    recent: Vec<Call>,
}

pub(super) fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/api/agents/{address}/{created}/github-access",
            get(status).post(change),
        )
        .route(
            "/github-access.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/github-access.js"),
                )
            }),
        )
}

fn view(project: &Project, session: &Session) -> Result<Json<Status>, ApiError> {
    let stamp = project.authorization().ok().map(|auth| auth.stamp);
    let mut access = project.0.agent_access.0.lock().map_err(|_| StoreError)?;
    access.prune(stamp.as_ref());
    let available = stamp.is_some() && access.ready;
    let active = access.grants.get(session).filter(|_| available);
    Ok(Json(Status {
        repository: project.0.repository.name(),
        available,
        minutes_remaining: active.map(|grant| {
            grant
                .until
                .saturating_duration_since(Instant::now())
                .as_secs()
                .div_ceil(60)
        }),
        helper: active
            .and_then(|_| std::env::current_exe().ok())
            .and_then(|path| path.to_str().map(agent::shell_quote)),
        recent: access
            .recent
            .iter()
            .filter(|(owner, _)| owner == session)
            .take(12)
            .map(|(_, call)| call.clone())
            .collect(),
    }))
}

async fn status(
    State(w): State<Workspace>,
    Path((address, created)): Path<(String, u64)>,
    Query(query): Query<Selection>,
) -> Result<Json<Status>, ApiError> {
    view(
        w.github_project.as_ref().ok_or(UNAVAILABLE)?,
        &Session {
            core: query.core,
            address,
            created,
        },
    )
}

async fn change(
    State(w): State<Workspace>,
    Path((address, created)): Path<(String, u64)>,
    Json(change): Json<Change>,
) -> Result<Json<Status>, ApiError> {
    let project = w.github_project.as_ref().ok_or(UNAVAILABLE)?;
    let session = Session {
        core: change.core,
        address,
        created,
    };
    if change.allowed {
        let stamp = project.authorization().map_err(|_| UNAVAILABLE)?.stamp;
        let launch = live_launch(&w, &session).await.ok_or(ApiError::Conflict(
            "Start a live SwarmHub session before granting GitHub access.",
        ))?;
        if project.authorization().map_err(|_| UNAVAILABLE)?.stamp != stamp {
            return Err(UNAVAILABLE);
        }
        project
            .0
            .agent_access
            .grant(session.clone(), launch, stamp)?;
    } else {
        project
            .0
            .agent_access
            .0
            .lock()
            .map_err(|_| StoreError)?
            .grants
            .remove(&session);
    }
    view(project, &session)
}

async fn live_launch(w: &Workspace, session: &Session) -> Option<String> {
    timeout(Duration::from_secs(2), async {
        if w.core.identify().await.ok()?.core.id != session.core { return None; }
        let terminal = w.core.agent(&session.address,session.created).await.ok()?;
        terminal.require_live().ok()?;
        let launch = terminal.launch_key()?;
        if !valid_key(launch) { return None; }
        let linked = w.history.db().ok()?.query_row(
            "SELECT EXISTS(SELECT 1 FROM journal WHERE launch_key=?1 AND core_id=?2 AND address=?3 AND created_ms=?4)",
            rusqlite::params![launch,session.core,session.address,session.created], |row| row.get::<_,bool>(0),
        ).ok()?;
        linked.then(|| launch.to_owned())
    }).await.ok().flatten()
}

fn valid_key(key: &str) -> bool {
    key.len() == 32 && key.bytes().all(|byte| byte.is_ascii_hexdigit())
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    launch: String,
    kind: Kind,
    number: u32,
}

#[derive(Serialize, Deserialize)]
struct Reply {
    text: String,
    error: Option<String>,
}

async fn send(stream: &mut UnixStream, result: Result<String, &'static str>) -> io::Result<()> {
    let (text, error) = match result {
        Ok(text) => (text, None),
        Err(error) => (String::new(), Some(error.into())),
    };
    let bytes = serde_json::to_vec(&Reply { text, error })?;
    if bytes.len() > MAX_REPLY {
        return Err(io::Error::other("GitHub reply is too large"));
    }
    timeout(Duration::from_secs(2), async {
        stream.write_u32_le(bytes.len() as u32).await?;
        stream.write_all(&bytes).await
    })
    .await?
}

async fn cancel(lease: &mut watch::Receiver<()>, until: Instant) {
    tokio::select! { _ = lease.changed() => {}, _ = tokio::time::sleep_until(until.into()) => {} }
}

async fn serve(w: Workspace, project: Project, mut stream: UnixStream) {
    let read = async {
        let size = stream.read_u32_le().await? as usize;
        if !(1..=MAX_REQUEST).contains(&size) {
            return Err(io::Error::other("Invalid GitHub request"));
        }
        let mut bytes = vec![0; size];
        stream.read_exact(&mut bytes).await?;
        serde_json::from_slice::<Request>(&bytes).map_err(io::Error::other)
    };
    let Ok(Ok(request)) = timeout(Duration::from_secs(2), read).await else {
        return;
    };
    if request.number == 0 || !valid_key(&request.launch) {
        let _ = send(&mut stream, Err(DENIED)).await;
        return;
    }
    let desk = &project.0.agent_access;
    let auth = project.authorization().ok();
    let Some(mut lease) = desk.lease(&request.launch, auth.as_ref().map(|auth| &auth.stamp)) else {
        let _ = send(&mut stream, Err(DENIED)).await;
        return;
    };
    let load = async {
        let still_live = || async {
            live_launch(&w, &lease.session)
                .await
                .is_some_and(|key| token_matches(&key, &request.launch))
        };
        if !still_live().await
            || !project
                .authorization()
                .is_ok_and(|current| current.stamp == lease.stamp)
        {
            return Err(DENIED);
        }
        let response = project
            .read_as(
                Item {
                    kind: request.kind,
                    number: request.number,
                },
                auth.as_ref().and_then(|auth| auth.token.as_deref()),
            )
            .await;
        if !still_live().await
            || !project
                .authorization()
                .is_ok_and(|current| current.stamp == lease.stamp)
        {
            return Err(DENIED);
        }
        match response {
            Ok(item) => Ok(match auth.as_ref().and_then(|auth| auth.token.as_deref()) {
                Some(token) => item.attachment.replace(token, "[credential removed]"),
                None => item.attachment,
            }),
            Err(ApiError::NotFound) => {
                Err("No open item of that type and number was found in the configured repository.")
            }
            _ => Err("GitHub could not return this item from the configured repository."),
        }
    };
    let result = tokio::select! {
        biased;
        _ = cancel(&mut lease.cancel,lease.until) => Err(DENIED),
        result = timeout(Duration::from_secs(21),load) => result.unwrap_or(Err("The GitHub read took too long.")),
    };
    let succeeded = if result.is_ok() {
        tokio::select! { biased; _ = cancel(&mut lease.cancel,lease.until) => false, sent = send(&mut stream,result) => sent.is_ok() }
    } else {
        let _ = send(&mut stream, result).await;
        false
    };
    desk.record(
        lease.session,
        Call {
            kind: request.kind,
            number: request.number,
            at_ms: now(),
            succeeded,
        },
    );
}

pub(crate) fn cli() -> Result<(), Box<dyn std::error::Error>> {
    const USAGE: &str = "Use github-read issue NUMBER or github-read pr NUMBER.";
    let mut args = std::env::args_os().skip(2);
    let kind = match args.next().as_deref().and_then(std::ffi::OsStr::to_str) {
        Some("issue") => Kind::Issue,
        Some("pr") => Kind::PullRequest,
        _ => return Err(USAGE.into()),
    };
    let number = args
        .next()
        .as_deref()
        .and_then(std::ffi::OsStr::to_str)
        .filter(|text| !text.is_empty() && text.bytes().all(|byte| byte.is_ascii_digit()))
        .and_then(|text| text.parse::<u32>().ok())
        .filter(|value| *value > 0)
        .ok_or(USAGE)?;
    if args.next().is_some() {
        return Err(USAGE.into());
    }
    let (history, launch) = agent::session()?;
    let bytes = serde_json::to_vec(&Request {
        launch,
        kind,
        number,
    })?;
    let mut stream = BlockingStream::connect(socket_path(&history))
        .map_err(|_| "GitHub agent access is unavailable.")?;
    stream.set_read_timeout(Some(Duration::from_secs(25)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;
    stream.write_all(&(bytes.len() as u32).to_le_bytes())?;
    stream.write_all(&bytes)?;
    let mut size = [0; 4];
    stream.read_exact(&mut size)?;
    let size = u32::from_le_bytes(size) as usize;
    if !(1..=MAX_REPLY).contains(&size) {
        return Err("Invalid GitHub reply.".into());
    }
    let mut bytes = vec![0; size];
    stream.read_exact(&mut bytes)?;
    let reply: Reply = serde_json::from_slice(&bytes)?;
    if let Some(error) = reply.error {
        return Err(error.into());
    }
    io::stdout().lock().write_all(reply.text.as_bytes())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        github_project::{Credential, Repository},
        history::History,
        vault::Vault,
    };
    use reqwest::Url;

    #[tokio::test]
    async fn vault_revision_and_expiry_cancel_checkout() {
        let root = tempfile::tempdir().unwrap();
        let history = History::open_at(&root.path().join("workspace")).unwrap();
        let vault = Vault::fixture();
        let name = "GitHub reader";
        let save = || vault.put_connector(&history, name, "fake_read_token".to_owned());
        assert!(save().is_ok());
        let project = Project::new(
            Repository::parse("fixture/board").unwrap(),
            Some(Credential {
                history: history.clone(),
                vault: vault.clone(),
                name: name.into(),
            }),
            Url::parse("http://127.0.0.1:9/").unwrap(),
        )
        .unwrap();
        let stamp = || project.authorization().ok().unwrap().stamp;
        let desk = &project.0.agent_access;
        desk.0.lock().unwrap().ready = true;
        let session = Session {
            core: "core".into(),
            address: "p1".into(),
            created: 1,
        };
        let key = "a0000000000000000000000000000000";
        let original = stamp();
        assert!(
            desk.grant(session.clone(), key.into(), original.clone())
                .is_ok()
        );
        let mut rotate = desk.lease(key, Some(&original)).unwrap();
        assert!(
            save().is_ok(),
            "replacing the same text still rotates the revision"
        );
        let replacement = stamp();
        assert!(replacement != original);
        assert!(desk.lease(key, Some(&replacement)).is_none());
        assert!(rotate.cancel.changed().await.is_err());

        assert!(
            desk.grant(session.clone(), key.into(), replacement.clone())
                .is_ok()
        );
        let mut expire = desk.lease(key, Some(&replacement)).unwrap();
        desk.0
            .lock()
            .unwrap()
            .grants
            .get_mut(&session)
            .unwrap()
            .until = Instant::now();
        assert!(desk.lease(key, Some(&replacement)).is_none());
        assert!(expire.cancel.changed().await.is_err());
    }
}
