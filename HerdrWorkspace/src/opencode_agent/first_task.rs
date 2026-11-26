//! Opt-in OpenCode V2 first tasks. The launcher owns the only submission.
use crate::{
    core::{Template, valid_name},
    person_profile::validate_prompt,
};
use reqwest::{Client, Url, redirect::Policy};
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    cell::Cell,
    env, fs,
    io::{self, BufRead, BufReader, Read},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::mpsc,
    time::Duration,
};

pub const ENV: &str = "SWARMHUB_OPENCODE_FIRST_TASK_FILE";
pub(crate) const FLAG: &str = "--api-first-task";
const PREFIX: &str = "opencode-launch-";
const TASK: &str = "task.json";
const RESULT: &str = "result.json";
const MAX_TASK: u64 = 128 * 1024;
const STARTUP: Duration = Duration::from_secs(25);
const REQUEST: Duration = Duration::from_secs(8);
const HANDOFF: Duration = Duration::from_secs(50);

pub struct OptIn;

impl OptIn {
    // Detect an explicit request even in commands that our strict launch check
    // will refuse. Falling back would give the same template a PTY first task.
    pub fn requested(template: &Template) -> bool {
        fn word(value: &str) -> &str {
            value.trim_matches(['\'', '"', ';', '&', '|', '(', ')'])
        }
        let tokens = template
            .command
            .split_ascii_whitespace()
            .collect::<Vec<_>>();
        for (index, pair) in tokens.windows(2).enumerate() {
            if word(pair[0]).rsplit('/').next() == Some("swarmhub-herdr")
                && word(pair[1]) == "run-opencode"
                && tokens[index + 2..]
                    .iter()
                    .take_while(|token| !matches!(**token, ";" | "&&" | "||" | "|"))
                    .any(|token| word(token) == FLAG)
            {
                return true;
            }
        }
        false
    }

    pub fn new(template: &Template) -> Option<Self> {
        if template.error.is_some() || !valid_name(&template.name) {
            return None;
        }
        let mut words = crate::runtimes::command_words(&template.command)?;
        if template
            .command
            .contains(['~', '*', '?', '{', '}', '[', ']'])
            || template
                .command
                .chars()
                .any(|c| c.is_control() && c != '\t')
            || template
                .command
                .split_ascii_whitespace()
                .map_while(|word| word.split_once('='))
                .any(|(name, _)| {
                    matches!(
                        name,
                        ENV | "SWARMHUB_JOURNAL"
                            | "SWARMHUB_LAUNCH_KEY"
                            | crate::runtimes::MODEL_ENV
                    )
                })
            || words.next()?.rsplit('/').next()? != "swarmhub-herdr"
            || words.next()? != "run-opencode"
        {
            return None;
        }
        let mut word = words.next()?;
        if word == "--workspace-approvals" {
            word = words.next()?;
        }
        (word == FLAG && words.next() == Some("mini") && words.next().is_none()).then_some(Self)
    }
}

pub(super) fn take_flag(args: &mut Vec<std::ffi::OsString>) -> bool {
    let opted_in = args.first().is_some_and(|arg| arg == FLAG);
    if opted_in {
        args.remove(0);
    }
    opted_in
}

#[derive(Deserialize, Serialize)]
struct Task {
    launch: String,
    text: Option<String>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Ready,
    Submitted,
    NotSent,
    Uncertain,
}

pub struct Prepared {
    directory: tempfile::TempDir,
    task: PathBuf,
}

impl Prepared {
    pub fn new(journal: &Path, launch: &str, task: Option<&str>) -> io::Result<Self> {
        if let Some(task) = task { validate_prompt(task).map_err(|_| io::Error::other("invalid OpenCode first task"))?; }
        let parent = journal
            .parent()
            .ok_or_else(|| io::Error::other("no workspace directory"))?;
        let directory = tempfile::Builder::new().prefix(PREFIX).tempdir_in(parent)?;
        let input = Task {
            launch: launch.to_owned(),
            text: task.map(str::to_owned),
        };
        let path = directory.path().join(TASK);
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)?;
        serde_json::to_writer(&mut file, &input)?;
        Ok(Self {
            directory,
            task: path,
        })
    }

    pub fn path(&self) -> &Path {
        &self.task
    }

    pub async fn outcome(&self) -> Outcome {
        let path = self.directory.path().join(RESULT);
        let deadline = tokio::time::Instant::now() + HANDOFF;
        loop {
            if let Ok(mut file) = fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
                .open(&path)
            {
                let mut bytes = Vec::new();
                if (&mut file).take(64).read_to_end(&mut bytes).is_ok() {
                    return serde_json::from_slice(&bytes).unwrap_or(Outcome::Uncertain);
                }
            }
            if tokio::time::Instant::now() >= deadline {
                return Outcome::Uncertain;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }
}

pub(super) struct Handoff {
    directory: PathBuf,
    journal: PathBuf,
    launch: String,
    text: Option<String>,
    outcome: Cell<Outcome>,
}

impl Handoff {
    pub(super) fn claim(journal: &Path, launch: &str) -> io::Result<Self> {
        let path = env::var_os(ENV).map(PathBuf::from).ok_or_else(|| {
            io::Error::other("This OpenCode launch requires a workspace first task.")
        })?;
        Self::claim_path(journal, launch, &path)
    }

    fn claim_path(journal: &Path, launch: &str, path: &Path) -> io::Result<Self> {
        let directory = path
            .parent()
            .ok_or_else(|| io::Error::other("Invalid OpenCode task path."))?;
        if path.file_name().and_then(|name| name.to_str()) != Some(TASK)
            || directory.parent() != journal.parent()
            || !directory
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(PREFIX))
        {
            return Err(io::Error::other("Invalid OpenCode task path."));
        }
        // Rename within the private directory before reading. The same staged
        // task cannot be claimed by a second launcher.
        let claimed = directory.join("claimed.json");
        fs::rename(path, &claimed)?;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&claimed)?;
        fs::remove_file(claimed)?;
        if !file.metadata()?.is_file() {
            return Err(io::Error::other("Invalid OpenCode first task."));
        }
        let mut bytes = Vec::new();
        file.take(MAX_TASK + 1).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > MAX_TASK {
            return Err(io::Error::other("Invalid OpenCode first task."));
        }
        let task: Task = serde_json::from_slice(&bytes)?;
        if task.launch != launch || task.text.as_deref().is_some_and(|text| validate_prompt(text).is_err()) {
            return Err(io::Error::other("Invalid OpenCode first task."));
        }
        Ok(Self {
            directory: directory.to_owned(),
            journal: journal.to_owned(),
            launch: task.launch,
            text: task.text,
            outcome: Cell::new(Outcome::NotSent),
        })
    }

    fn record(&self, outcome: Outcome) {
        let Ok(mut file) = tempfile::NamedTempFile::new_in(&self.directory) else {
            return;
        };
        if serde_json::to_writer(&mut file, &outcome).is_ok() {
            let _ = file.persist_noclobber(self.directory.join(RESULT));
        }
    }
}

impl Drop for Handoff {
    fn drop(&mut self) {
        self.record(self.outcome.get());
    }
}

struct Process(Child);

impl Drop for Process {
    fn drop(&mut self) {
        if self.0.try_wait().ok().flatten().is_none() {
            let _ = self.0.kill();
        }
        let _ = self.0.wait();
    }
}

#[derive(Deserialize)]
struct Address {
    url: String,
}

fn loopback(value: &str) -> Option<Url> {
    let url = Url::parse(value).ok()?;
    (url.scheme() == "http"
        && url.host_str() == Some("127.0.0.1")
        && url.port().is_some_and(|port| port > 0)
        && url.username().is_empty()
        && url.password().is_none()
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none())
    .then_some(url)
}

fn start(mut server: Command, password: &str) -> io::Result<(Process, Url)> {
    let mut server = Process(
        server
            .args(["serve", "--hostname", "127.0.0.1", "--port", "0", "--stdio"])
            .env_remove("OPENCODE_SERVER_PASSWORD")
            .env("OPENCODE_PASSWORD", password)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?,
    );
    let stdout = server
        .0
        .stdout
        .take()
        .ok_or_else(|| io::Error::other("OpenCode did not return a private address."))?;
    let (send, read) = mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let mut output = BufReader::new(stdout);
        let mut line = Vec::new();
        let url = (&mut output)
            .take(1024)
            .read_until(b'\n', &mut line)
            .ok()
            .filter(|_| line.last() == Some(&b'\n'))
            .and_then(|_| serde_json::from_slice::<Address>(&line).ok())
            .and_then(|address| loopback(&address.url));
        let _ = send.send(url);
        let _ = io::copy(&mut output, &mut io::sink());
    });
    let url = read
        .recv_timeout(STARTUP)
        .ok()
        .flatten()
        .ok_or_else(|| io::Error::other("OpenCode did not return a private address."))?;
    Ok((server, url))
}

#[derive(Deserialize)]
struct Session {
    data: SessionData,
}

#[derive(Deserialize)]
struct SessionData {
    id: String,
}

pub(super) fn valid_session(value: &str) -> bool {
    value.starts_with("ses_")
        && (5..=128).contains(&value.len())
        && value.as_bytes()[4..].iter().all(u8::is_ascii_alphanumeric)
}

pub(super) struct ApiSession {
    pub(super) client: Client,
    pub(super) id: String,
    pub(super) base: Url,
    prompt: Url,
    permissions: Url,
    forms: Url,
}

pub(super) async fn create_session(
    base: &Url,
    password: &str,
    model: Option<&str>,
) -> io::Result<ApiSession> {
    let client = Client::builder()
        .http1_only()
        .no_proxy()
        .redirect(Policy::none())
        .retry(reqwest::retry::never())
        .timeout(REQUEST)
        .build()
        .map_err(|_| io::Error::other("Could not connect to OpenCode."))?;
    let not_created = || io::Error::other("OpenCode could not create a session.");
    let mut create = json!({});
    if let Some(model) = model {
        let (provider, model) = model.split_once('/').ok_or_else(not_created)?;
        create["model"] = json!({"providerID":provider,"id":model});
    }
    let create_url = base.join("api/session").map_err(|_| not_created())?;
    let mut response = client
        .post(create_url)
        .basic_auth("opencode", Some(password))
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(create.to_string())
        .send()
        .await
        .map_err(|_| not_created())?;
    if response.status() != reqwest::StatusCode::OK {
        return Err(not_created());
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| not_created())? {
        if body.len() + chunk.len() > 32 * 1024 {
            return Err(not_created());
        }
        body.extend_from_slice(&chunk);
    }
    let session = serde_json::from_slice::<Session>(&body)
        .map_err(|_| not_created())?
        .data
        .id;
    if !valid_session(&session) {
        return Err(not_created());
    }
    let prompt = base
        .join(&format!("api/session/{session}/prompt"))
        .map_err(|_| not_created())?;
    let permissions = base
        .join(&format!("api/session/{session}/permission"))
        .map_err(|_| not_created())?;
    let forms = base
        .join(&format!("api/session/{session}/form"))
        .map_err(|_| not_created())?;
    Ok(ApiSession {
        client,
        id: session,
        base: base.clone(),
        prompt,
        permissions,
        forms,
    })
}

impl ApiSession {
    async fn submit(&self, password: &str, handoff: &Handoff) {
        // This is the only submission. A failed exchange cannot tell us whether
        // the server durably accepted the message, so never send again.
        let Some(text) = handoff.text.as_deref() else {
            handoff.outcome.set(Outcome::Ready);
            return;
        };
        handoff.outcome.set(Outcome::Uncertain);
        handoff
            .outcome
            .set(self.send(password, text).await);
    }

    pub(super) async fn send(&self, password: &str, text: &str) -> Outcome {
        self.submit_prompt(password, json!({"text":text})).await
    }

    pub(super) async fn send_group(
        &self,
        password: &str,
        text: &str,
        group: &crate::group_preview::Binding,
    ) -> Outcome {
        self.submit_prompt(
            password,
            json!({
                "text": text,
                "delivery": "queue",
                "metadata": {"swarmhubGroupPreview":group}
            }),
        )
        .await
    }

    async fn submit_prompt(&self, password: &str, body: serde_json::Value) -> Outcome {
        let response = self
            .client
            .post(self.prompt.clone())
            .basic_auth("opencode", Some(password))
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body.to_string())
            .send()
            .await;
        if response.is_ok_and(|response| response.status() == reqwest::StatusCode::OK) {
            Outcome::Submitted
        } else {
            Outcome::Uncertain
        }
    }

    pub(super) async fn interrupt(&self, password: &str) -> io::Result<bool> {
        #[derive(Deserialize)]
        struct Status {
            interrupted: bool,
        }
        let error = || io::Error::other("OpenCode did not confirm the interrupt.");
        let url = self.base
            .join(&format!("api/session/{}/interrupt?resume=false", self.id))
            .map_err(|_| error())?;
        let mut response = self.client.post(url)
            .basic_auth("opencode", Some(password))
            .send().await.map_err(|_| error())?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(error());
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| error())? {
            if body.len() + chunk.len() > 4096 {
                return Err(error());
            }
            body.extend_from_slice(&chunk);
        }
        serde_json::from_slice::<Status>(&body)
            .map(|status| status.interrupted)
            .map_err(|_| error())
    }

    pub(super) async fn attention(&self, password: &str) -> io::Result<bool> {
        #[derive(Deserialize)]
        struct Pending {
            data: Vec<serde_json::Value>,
        }
        let inspect = |endpoint: Url| async {
            let unavailable = || io::Error::other("OpenCode attention could not be checked.");
            let mut response = self
                .client
                .get(endpoint)
                .basic_auth("opencode", Some(password))
                .send()
                .await
                .map_err(|_| unavailable())?;
            if response.status() != reqwest::StatusCode::OK {
                return Err(unavailable());
            }
            let mut body = Vec::new();
            while let Some(chunk) = response.chunk().await.map_err(|_| unavailable())? {
                if body.len() + chunk.len() > 64 * 1024 {
                    return Err(unavailable());
                }
                body.extend_from_slice(&chunk);
            }
            let pending: Pending = serde_json::from_slice(&body).map_err(|_| unavailable())?;
            Ok(!pending.data.is_empty())
        };
        let (permissions, forms) = tokio::join!(
            inspect(self.permissions.clone()),
            inspect(self.forms.clone())
        );
        Ok(permissions? || forms?)
    }
}

pub(super) fn run(
    mut server: Command,
    mut mini: Command,
    handoff: Handoff,
    model: Option<String>,
    capped: bool,
) -> io::Result<()> {
    let mut secret = [0; 32];
    if SystemRandom::new().fill(&mut secret).is_err() {
        return Err(io::Error::other(
            "Could not secure OpenCode's private server.",
        ));
    }
    let password = secret
        .into_iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>();
    // The server starts before the API chooses the chat's root. Give its plugin a private,
    // launch-scoped binding that stays alive as long as Mini, including across model changes.
    let usage_root = if capped { Some(tempfile::NamedTempFile::new()?) } else { tempfile::NamedTempFile::new().ok() };
    server.env(super::USAGE_ROOT, usage_root.as_ref().map_or(Path::new("/dev/null"), |file| file.path()));
    // Do not attach Mini or send the first prompt until the server has installed
    // the spending hooks. An ignored or incompatible plugin cannot run a paid turn.
    let ready = if capped { Some(tempfile::NamedTempFile::new()?) } else { None };
    server.env_remove("SWARMHUB_OPENCODE_CAP_READY");
    if let Some(file) = &ready { server.env("SWARMHUB_OPENCODE_CAP_READY", file.path()); }
    let (_server, url) = start(server, &password)?;
    let client = std::thread::spawn(move || -> io::Result<()> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let session = runtime.block_on(create_session(&url, &password, model.as_deref()))?;
        if let Some(file) = &usage_root {
            let result = fs::write(file.path(), &session.id);
            if capped { result?; }
        }
        if let Some(file) = &ready {
            runtime.block_on(session.attention(&password))?;
            let deadline = std::time::Instant::now() + REQUEST;
            while fs::read_to_string(file.path()).ok().as_deref() != Some(handoff.launch.as_str()) {
                if std::time::Instant::now() >= deadline { return Err(io::Error::other("OpenCode did not activate the session spending limit.")); }
                std::thread::sleep(Duration::from_millis(50));
            }
        }
        let mut attached = Process(
            mini.args(["mini", "--server", url.as_str(), "--session", &session.id])
                .env_remove("OPENCODE_SERVER_PASSWORD")
                .env("OPENCODE_PASSWORD", &password)
                .spawn()?,
        );
        if attached.0.try_wait()?.is_some() {
            return Err(io::Error::other(
                "OpenCode Mini exited before the first task.",
            ));
        }
        let terminal = env::var("HC_TERMINAL_ID").map_err(io::Error::other)?;
        let endpoint = runtime.block_on(async {
            super::follow_up::Endpoint::bind(&handoff.journal, &handoff.launch, terminal)
        })?;
        runtime.block_on(session.submit(&password, &handoff));
        drop(handoff);
        let result = runtime.block_on(async {
            tokio::select! {
                status = async {
                    loop {
                        if let Some(status) = attached.0.try_wait()? { break Ok(status); }
                        tokio::time::sleep(Duration::from_millis(100)).await;
                    }
                } => status,
                error = endpoint.serve(session, password) => {
                    error?;
                    Err(io::Error::other("OpenCode follow-up service exited."))
                }
            }
        })?;
        if result.success() {
            Ok(())
        } else {
            Err(io::Error::other("OpenCode Mini exited unsuccessfully."))
        }
    });
    client
        .join()
        .map_err(|_| io::Error::other("Could not start the OpenCode session."))?
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{Json, Router, http::StatusCode, routing::post};
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    #[tokio::test]
    async fn an_ambiguous_submission_is_only_attempted_once() {
        let workspace = tempfile::tempdir().unwrap();
        let journal = workspace.path().join("workspace.sqlite3");
        let prepared = Prepared::new(&journal, "fixture-launch", Some("Only one submission")).unwrap();
        let handoff = Handoff::claim_path(&journal, "fixture-launch", prepared.path()).unwrap();
        assert_eq!(handoff.text.as_deref(), Some("Only one submission"));
        assert!(!prepared.path().exists());
        assert!(Handoff::claim_path(&journal, "fixture-launch", prepared.path()).is_err());
        let received = Arc::new(AtomicUsize::new(0));
        let count = Arc::clone(&received);
        let local = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = loopback(&format!("http://{}", local.local_addr().unwrap())).unwrap();
        let app = Router::new()
            .route(
                "/api/session",
                post(|| async { Json(json!({"data":{"id":"ses_fixture"}})) }),
            )
            .route(
                "/api/session/ses_fixture/prompt",
                post(move |Json(body): Json<serde_json::Value>| async move {
                    assert_eq!(body["text"], "Only one submission");
                    count.fetch_add(1, Ordering::Relaxed);
                    StatusCode::BAD_GATEWAY
                }),
            );
        let server = tokio::spawn(async move { axum::serve(local, app).await.unwrap() });
        let session = create_session(&url, "fake-password", None).await.unwrap();
        assert_eq!(session.id, "ses_fixture");
        session.submit("fake-password", &handoff).await;
        drop(handoff);
        assert_eq!(prepared.outcome().await, Outcome::Uncertain);
        assert_eq!(received.load(Ordering::Relaxed), 1);
        let warm = Prepared::new(&journal, "warm-fixture", None).unwrap();
        let handoff = Handoff::claim_path(&journal, "warm-fixture", warm.path()).unwrap();
        session.submit("fake-password", &handoff).await;
        drop(handoff);
        assert_eq!(warm.outcome().await, Outcome::Ready);
        assert_eq!(received.load(Ordering::Relaxed), 1);
        server.abort();
    }

    #[test]
    fn only_a_literal_explicit_mini_template_opts_in() {
        let mut template = Template {
            name: "opencode".into(),
            description: String::new(),
            error: None,
            command: "OPENCODE_CONFIG=/opt/project.json /opt/swarmhub-herdr run-opencode --workspace-approvals --api-first-task mini".into(),
        };
        assert!(OptIn::new(&template).is_some());
        assert!(OptIn::requested(&template));
        for (command, requested) in [
            ("/opt/swarmhub-herdr run-opencode mini", false),
            ("/opt/other-agent --api-first-task mini", false),
            (
                "/opt/swarmhub-herdr run-opencode --api-first-task mini --prompt unsafe",
                true,
            ),
            (
                "/opt/swarmhub-herdr run-opencode --api-first-task mini && other",
                true,
            ),
            (
                "OPENCODE_CONFIG=$HOME/project.json /opt/swarmhub-herdr run-opencode --api-first-task mini",
                true,
            ),
            (
                "SWARMHUB_LAUNCH_KEY=wrong /opt/swarmhub-herdr run-opencode --api-first-task mini",
                true,
            ),
            (
                "/opt/swarmhub-herdr run-opencode --api-first-task 'mini'",
                true,
            ),
        ] {
            template.command = command.into();
            assert!(OptIn::new(&template).is_none(), "{command}");
            assert_eq!(OptIn::requested(&template), requested, "{command}");
        }
    }

    #[test]
    fn private_server_address_can_only_be_a_loopback_service() {
        assert!(loopback("http://127.0.0.1:42424").is_some());
        for forbidden in [
            "http://example.com:80",
            "http://127.0.0.1.evil.invalid:42424",
            "http://user@127.0.0.1:42424",
            "http://127.0.0.1:42424/elsewhere",
            "http://127.0.0.1:42424/?param=1",
            "http://127.0.0.1:0",
        ] {
            assert!(loopback(forbidden).is_none(), "{forbidden}");
        }
    }
}
