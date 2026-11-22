use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{collections::BTreeMap, io, path::PathBuf, time::Duration};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    time::timeout,
};

const LABEL: &str = "swarmhub.workspace";
const LABEL_VALUE: &str = "agent";
const LAUNCH_LABEL: &str = "swarmhub.launch";
const TEMPLATE_LABEL: &str = "swarmhub.direct-template";
#[cfg(any(test, feature = "fleet-test-fixture"))]
pub(crate) const COMPLETION_START: &str = "fixture.terminal.run";
#[cfg(any(test, feature = "fleet-test-fixture"))]
pub(crate) const COMPLETION_SEND: &str = "fixture.terminal.send_idle";
const MAX_REPLY: u64 = 16 * 1024 * 1024;
pub const MAX_FILE: usize = 8 * 1024 * 1024;

#[derive(Clone)]
pub struct Core(pub PathBuf);

#[derive(Debug)]
pub enum Failure {
    Unreachable,
    Protocol,
    Uncertain,
    Rejected(String, String),
    Missing,
    Input(&'static str),
}

#[derive(Deserialize)]
pub struct Identity {
    pub id: String,
}

#[derive(Deserialize)]
pub struct Hello {
    generation: u32,
    pub version: String,
    methods: Vec<String>,
    pub core: Identity,
}

impl Hello {
    pub fn supports(&self, method: &str) -> bool {
        self.methods.iter().any(|name| name == method)
    }

    pub(crate) fn supports_completion_start(&self) -> bool {
        #[cfg(any(test, feature = "fleet-test-fixture"))]
        return self.supports(COMPLETION_START);
        #[cfg(not(any(test, feature = "fleet-test-fixture")))]
        false
    }

    pub(crate) fn supports_completion_send(&self) -> bool {
        #[cfg(any(test, feature = "fleet-test-fixture"))]
        return self.supports(COMPLETION_SEND);
        #[cfg(not(any(test, feature = "fleet-test-fixture")))]
        false
    }
}

#[derive(Deserialize, Serialize)]
pub struct Status {
    pub state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
}

#[derive(Deserialize, Serialize)]
pub struct FirstMessage {
    pub sent: bool,
    pub reason: Option<String>,
}

#[derive(Deserialize, Serialize)]
pub struct Terminal {
    pub address: String,
    pub name: Option<String>,
    pub state: String,
    pub status: Option<Status>,
    pub template: Option<String>,
    pub created_ms: u64,
    pub exit_code: Option<i32>,
    pub reason: Option<String>,
    pub first_message: Option<FirstMessage>,
    /// Whether the program ever reported its status. Core types a launch's first task only after that.
    #[serde(default, skip_serializing)]
    reported: bool,
    /// How many times the program's status left `working`.
    #[serde(default, skip_serializing)]
    turn: u64,
    #[serde(default, skip_serializing)]
    labels: BTreeMap<String, String>,
    #[serde(default, skip_serializing)]
    keep: bool,
}

#[derive(Deserialize, Serialize)]
pub struct Template {
    pub name: String,
    pub description: String,
    pub error: Option<String>,
    #[serde(default, skip_serializing)]
    pub command: String,
}

pub struct LaunchEnv<'a> {
    pub key: &'a str,
    pub journal: &'a str,
    pub approval_socket: &'a str,
    pub vault_session: Option<&'a str>,
    pub model: Option<&'a crate::runtimes::LaunchModel>,
    pub results: Option<&'a str>,
    pub opencode_first_task: Option<&'a str>,
    /// A helper's parent terminal and starting folder (`helpers`); `None` for an agent a person starts.
    pub helper: Option<HelperOf<'a>>,
    pub workspace: Option<&'a str>,
}

pub struct HelperOf<'a> {
    pub parent: &'a str,
    pub cwd: Option<&'a str>,
}

pub enum LaunchSource {
    Template(String, String),
    /// The template's program alone: nothing is typed (`warm`).
    Warm(String),
    FixtureWarm { template: String, core: String },
    DirectOpenCode(String, String),
}

#[derive(Deserialize, Serialize)]
pub struct Output {
    pub text: String,
}

#[derive(Deserialize, Serialize)]
pub struct Delivery {
    pub status: Option<String>,
    pub started: Option<bool>,
}

#[derive(Deserialize)]
pub struct StagedFile {
    pub path: String,
    pub bytes: usize,
}

#[derive(Deserialize)]
pub(crate) struct ModelProbeOutput {
    pub code: Option<i32>,
    pub stdout: String,
    pub truncated: bool,
    pub timed_out: bool,
}

/// Another machine this Core added (`hc machine add`), with its connection as it is now.
#[derive(Clone, Deserialize)]
pub(crate) struct Machine {
    pub name: String,
    pub target: String,
    #[serde(default)]
    pub via: bool,
    #[serde(default)]
    pub temporary: bool,
    #[serde(default)]
    pub session: Option<String>,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub version: String,
    /// connecting, connected, needs_login or unreachable. Empty in the answer to adding one.
    #[serde(default)]
    pub state: String,
    #[serde(default)]
    pub since_ms: Option<u64>,
    #[serde(default)]
    pub why: Option<String>,
    #[serde(default)]
    pub keeps_running_after_logout: Option<bool>,
    #[serde(default)]
    pub logout_linger_user: Option<String>,
}

/// One program run on a machine without a terminal (`machine.exec`). The output is base64.
#[derive(Deserialize)]
pub(crate) struct Ran {
    pub code: Option<i32>,
    #[serde(default)]
    pub signal: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    pub truncated: bool,
    pub timed_out: bool,
    pub ms: u64,
}

/// What a machine runs: a program and its arguments as given, or one line for its shell.
pub(crate) enum Program<'a> {
    Argv(&'a [String]),
    Line(&'a str),
}

/// Lines of a text file on a machine (`file.read`).
#[derive(Deserialize)]
pub(crate) struct FileLines {
    pub text: String,
    pub first: usize,
    pub last: usize,
    pub lines: usize,
}

#[derive(Deserialize)]
pub(crate) struct Written {
    pub path: String,
    pub bytes: usize,
}

#[derive(Deserialize)]
struct RpcError {
    message: String,
    data: Option<RpcErrorData>,
}

#[derive(Deserialize)]
struct RpcErrorData {
    kind: String,
}

impl Core {
    async fn rpc<T: DeserializeOwned>(
        &self,
        method: &str,
        params: Value,
        seconds: u64,
        mutating: bool,
    ) -> Result<T, Failure> {
        let mut socket = timeout(Duration::from_secs(2), UnixStream::connect(&self.0))
            .await
            .map_err(|_| Failure::Unreachable)?
            .map_err(|_| Failure::Unreachable)?;
        let exchange = async {
            let mut request = serde_json::to_vec(
                &json!({"jsonrpc":"2.0","id":1,"method":method,"params":params}),
            )
            .map_err(io::Error::other)?;
            request.push(b'\n');
            socket.write_all(&request).await?;
            let mut line = Vec::new();
            BufReader::new(socket)
                .take(MAX_REPLY)
                .read_until(b'\n', &mut line)
                .await?;
            if line.last() != Some(&b'\n') {
                return Err(io::Error::other("incomplete JSON-RPC reply"));
            }
            Ok::<_, io::Error>(line)
        };
        let lost = || {
            if mutating {
                Failure::Uncertain
            } else {
                Failure::Protocol
            }
        };
        let line = timeout(Duration::from_secs(seconds), exchange)
            .await
            .map_err(|_| lost())?
            .map_err(|_| lost())?;
        let mut reply: Value = serde_json::from_slice(&line).map_err(|_| lost())?;
        if reply["jsonrpc"] != "2.0" || reply["id"] != 1 {
            return Err(lost());
        }
        match (reply.get("result").is_some(), reply.get("error").is_some()) {
            (true, false) => serde_json::from_value(reply["result"].take()).map_err(|_| lost()),
            (false, true) => {
                let error: RpcError =
                    serde_json::from_value(reply["error"].take()).map_err(|_| lost())?;
                Err(Failure::Rejected(
                    error.data.map(|data| data.kind).unwrap_or_default(),
                    crate::person_profile::strip_prompt_context(error.message),
                ))
            }
            _ => Err(lost()),
        }
    }

    pub async fn identify(&self) -> Result<Hello, Failure> {
        let hello: Hello = self.rpc("hello", json!({"generation":1}), 5, false).await?;
        if hello.generation == 1
            && [
                "templates.list",
                "terminal.get",
                "terminal.list",
                "terminal.run",
                "terminal.read",
                "terminal.send",
                "terminal.interrupt",
                "terminal.kill",
            ]
            .iter()
            .all(|required| hello.supports(required))
        {
            Ok(hello)
        } else {
            Err(Failure::Protocol)
        }
    }

    pub(crate) async fn runtime_models(
        &self,
        agent: crate::runtimes::ModelAgent,
        helper: &str,
        env: &BTreeMap<&str, &str>,
    ) -> Result<ModelProbeOutput, Failure> {
        let command = match agent {
            crate::runtimes::ModelAgent::Codex => "codex-models",
            crate::runtimes::ModelAgent::OpenCode => "opencode-models",
            crate::runtimes::ModelAgent::Claude | crate::runtimes::ModelAgent::Gemini => {
                return Err(Failure::Input(
                    "This runtime has no supported model listing.",
                ));
            }
        };
        let mut env: BTreeMap<&str, String> = env
            .iter()
            .map(|(name, value)| (*name, (*value).to_owned()))
            .collect();
        // The agent program is found through the person's PATH, as when an agent is started (`launch`).
        if let Some(path) = agent_path() {
            env.entry("PATH").or_insert(path);
        }
        self.rpc(
            "machine.exec",
            json!({"argv":[helper,command],"env":env,"timeout":35}),
            40,
            false,
        )
        .await
    }

    /// Follows Core's fact changes for the terminals `filter` selects (`events.subscribe`) and tells `changed`
    /// after each one. Returns when the connection ends or Core stops sending its 15-second heartbeat.
    pub(crate) async fn follow(&self, filter: Value, changed: &tokio::sync::Notify) {
        #[derive(Deserialize)]
        struct Line {
            method: Option<String>,
            result: Option<serde::de::IgnoredAny>,
        }
        let Ok(Ok(socket)) = timeout(Duration::from_secs(2), UnixStream::connect(&self.0)).await
        else {
            return;
        };
        // Core treats a closed write side as the end of the subscription, so keep it open.
        let (read, mut write) = socket.into_split();
        let Ok(mut request) = serde_json::to_vec(
            &json!({"jsonrpc":"2.0","id":1,"method":"events.subscribe","params":filter}),
        ) else {
            return;
        };
        request.push(b'\n');
        if write.write_all(&request).await.is_err() {
            return;
        }
        let mut input = BufReader::new(read);
        let mut line = Vec::new();
        let mut subscribed = false;
        loop {
            line.clear();
            let read = timeout(
                Duration::from_secs(45),
                (&mut input).take(MAX_REPLY).read_until(b'\n', &mut line),
            )
            .await;
            if !matches!(read, Ok(Ok(count)) if count > 0) || line.last() != Some(&b'\n') {
                return;
            }
            let Ok(message) = serde_json::from_slice::<Line>(&line) else {
                return;
            };
            match message.method.as_deref() {
                // The answer comes first: the matching terminals, or an error. Whatever changed before
                // this moment was not announced, so have the listener read once now.
                None if !subscribed && message.result.is_some() => {
                    subscribed = true;
                    changed.notify_one();
                }
                Some("heartbeat") if subscribed => {}
                Some(_) if subscribed => changed.notify_one(),
                _ => return,
            }
        }
    }

    pub(crate) async fn machines(&self) -> Result<Vec<Machine>, Failure> {
        #[derive(Deserialize)]
        struct List {
            machines: Vec<Machine>,
        }
        Ok(self
            .rpc::<List>("machine.list", json!({}), 5, false)
            .await?
            .machines)
    }

    /// Dials a machine now instead of at Core's next retry, and gives its connection afterwards.
    pub(crate) async fn dial_machine(&self, name: &str) -> Result<Machine, Failure> {
        self.rpc("machine.connect", json!({"machine":name}), 40, false)
            .await
    }

    /// Forgets a machine here. Its programs keep running there.
    pub(crate) async fn forget_machine(&self, name: &str) -> Result<(), Failure> {
        self.rpc::<serde::de::IgnoredAny>("machine.rm", json!({"machine":name}), 15, true)
            .await
            .map(|_| ())
    }

    /// Runs one program in `cwd` on the machine `on`, with no terminal, for at most `seconds`.
    pub(crate) async fn run_on(
        &self,
        on: &str,
        cwd: &str,
        program: Program<'_>,
        seconds: u64,
    ) -> Result<Ran, Failure> {
        let mut params = json!({"on":on,"cwd":cwd,"timeout":seconds});
        match program {
            Program::Argv(argv) => params["argv"] = json!(argv),
            Program::Line(line) => params["line"] = line.into(),
        }
        // Core ends the program at `seconds`; the rest is for the answer to travel back.
        self.rpc("machine.exec", params, seconds + 20, true).await
    }

    /// The fixture Core accepts encoded stdin as data on its private socket.
    #[cfg(any(test, feature = "fleet-test-fixture"))]
    pub(crate) async fn run_fixture_worker(
        &self, on: &str, argv: &[String], input: &[u8], seconds: u64,
    ) -> Result<Ran, Failure> {
        self.rpc("fixture.machine.exec_stdin", json!({
            "on": on, "cwd": "/", "argv": argv, "stdin": STANDARD.encode(input), "timeout": seconds,
        }), seconds + 20, true).await
    }

    pub(crate) async fn read_on(
        &self,
        on: &str,
        cwd: &str,
        path: &str,
        offset: Option<usize>,
        limit: Option<usize>,
    ) -> Result<FileLines, Failure> {
        self.rpc(
            "file.read",
            json!({"on":on,"cwd":cwd,"path":path,"offset":offset,"limit":limit}),
            40,
            false,
        )
        .await
    }

    pub(crate) async fn write_on(
        &self,
        on: &str,
        cwd: &str,
        path: &str,
        text: &str,
    ) -> Result<Written, Failure> {
        self.rpc(
            "file.write",
            json!({"on":on,"cwd":cwd,"path":path,"data":STANDARD.encode(text)}),
            40,
            true,
        )
        .await
    }

    /// Replaces each `old` text, found exactly once, with its `new`; all of them or none.
    pub(crate) async fn edit_on(
        &self,
        on: &str,
        cwd: &str,
        path: &str,
        edits: &[(String, String)],
    ) -> Result<Written, Failure> {
        let edits: Vec<Value> = edits
            .iter()
            .map(|(old, new)| json!({"old":old,"new":new}))
            .collect();
        self.rpc(
            "file.edit",
            json!({"on":on,"cwd":cwd,"path":path,"edits":edits}),
            40,
            true,
        )
        .await
    }

    pub async fn agents(&self) -> Result<Vec<Terminal>, Failure> {
        #[derive(Deserialize)]
        struct List {
            terminals: Vec<Terminal>,
        }
        let mut list: List = self
            .rpc(
                "terminal.list",
                json!({"all":true,"labels":{(LABEL):LABEL_VALUE}}),
                5,
                false,
            )
            .await?;
        for terminal in &mut list.terminals {
            terminal.hydrate_template();
        }
        list.terminals.retain(Terminal::managed);
        list.terminals
            .sort_by_key(|terminal| std::cmp::Reverse(terminal.created_ms));
        Ok(list.terminals)
    }

    pub async fn templates(&self) -> Result<Vec<Template>, Failure> {
        #[derive(Deserialize)]
        struct List {
            templates: Vec<Template>,
        }
        Ok(self
            .rpc::<List>("templates.list", json!({}), 5, false)
            .await?
            .templates)
    }

    pub async fn launch(
        &self,
        name: String,
        source: LaunchSource,
        env: LaunchEnv<'_>,
    ) -> Result<Terminal, Failure> {
        let (template, task, line, fixture_core) = match source {
            LaunchSource::Template(template, task) => (template, Some(task), None, None),
            LaunchSource::Warm(template) => (template, None, None, None),
            LaunchSource::FixtureWarm { template, core } => (template, None, None, Some(core)),
            LaunchSource::DirectOpenCode(template, command) => (template, None, Some(command), None),
        };
        if !valid_name(&name) || !valid_name(&template) {
            return Err(Failure::Input(
                "Use 1–32 lowercase letters, digits, dots, dashes or underscores for the agent and template names.",
            ));
        }
        if let Some(task) = task.as_deref() {
            crate::person_profile::validate_prompt(task)?;
        }
        let mut labels = BTreeMap::from([(LABEL, LABEL_VALUE), (LAUNCH_LABEL, env.key)]);
        let argv = match (task, &line) {
            (Some(task), _) => vec![template.clone(), task],
            // Core starts the template's command and, with no task and no Markdown body, types nothing.
            (None, None) => vec![template.clone()],
            (None, Some(_)) => {
                // Calling terminal.run with a template name would paste its Markdown body.
                labels.insert(TEMPLATE_LABEL, &template);
                Vec::new()
            }
        };
        let mut params = json!({
            "name":name,"argv":argv,"line":line,"wait":false,"no_parent":true,
            "labels":labels,"size":{"cols":100,"rows":30},
            "env":{"SWARMHUB_JOURNAL":env.journal,"SWARMHUB_LAUNCH_KEY":env.key,
                   "SWARMHUB_APPROVAL_SOCKET":env.approval_socket,
                   (crate::runtimes::MODEL_ENV):env.model.and_then(crate::runtimes::LaunchModel::builtin).unwrap_or_default(),
                   (crate::runtimes::CUSTOM_MODEL_ENV):env.model.and_then(crate::runtimes::LaunchModel::environment).unwrap_or_default(),
                   (crate::opencode_agent::first_task::ENV):env.opencode_first_task.unwrap_or_default(),
                   "SWARMHUB_RESULTS":env.results.unwrap_or_default(),
                   (crate::helpers::SPOOL_ENV):crate::helpers::spool_directory()
                       .and_then(|folder| folder.into_os_string().into_string().ok()).unwrap_or_default()}
        });
        if let Ok(exe) = std::env::current_exe()
            && let Some(path) = exe.to_str()
        {
            params["env"]["SWARMHUB_PUBLISHER"] = path.into();
        }
        // Mask a key path even if a manually started Core inherited it.
        params["env"][crate::vault::KEY_FILE] = "".into();
        if let Some(session) = env.vault_session {
            params["env"][crate::vault::SESSION_ENV] = session.into();
        }
        // Started by `service run`, the server knows the PATH the person's own shell has. Core may have been
        // started with a shorter one (by launchd, at login), and an agent program is found through it.
        if let Some(path) = agent_path() {
            params["env"]["PATH"] = path.into();
        }
        if let Some(helper) = &env.helper {
            // Core ends a child when its parent's program ends. Core's own notes stay off: they would be typed
            // into the parent as if a person had written them.
            params["no_parent"] = false.into();
            params["parent"] = helper.parent.into();
            params["no_notify"] = true.into();
        }
        // Without a folder, Core starts the agent in its own working directory.
        if let Some(cwd) = env
            .helper
            .as_ref()
            .and_then(|helper| helper.cwd)
            .or(env.workspace)
        {
            params["cwd"] = cwd.into();
        } else if let Some(cwd) = agent_cwd().map_err(|_| Failure::Input(AGENT_CWD_ERROR))? {
            params["cwd"] = cwd.into();
        }
        let method = match fixture_core {
            #[cfg(any(test, feature = "fleet-test-fixture"))]
            Some(core) => {
                params["core"] = core.into();
                COMPLETION_START
            }
            #[cfg(not(any(test, feature = "fleet-test-fixture")))]
            Some(_) => return Err(Failure::Input("Fixture launches are disabled.")),
            None => "terminal.run",
        };
        let mut terminal: Terminal = self.rpc(method, params, 85, true).await?;
        terminal.hydrate_template();
        if terminal.managed() {
            Ok(terminal)
        } else {
            Err(Failure::Uncertain)
        }
    }

    pub async fn agent(&self, id: &str, created: u64) -> Result<Terminal, Failure> {
        if !local_address(id) {
            return Err(Failure::Missing);
        }
        let mut terminal: Terminal = self
            .rpc("terminal.get", json!({"terminal":id}), 5, false)
            .await?;
        terminal.hydrate_template();
        if terminal.address == id && terminal.created_ms == created && terminal.managed() {
            Ok(terminal)
        } else {
            Err(Failure::Missing)
        }
    }

    pub async fn output(&self, agent: &Terminal) -> Result<Output, Failure> {
        // Zero lines avoids asking Core to drive a full-screen program to recover scrollback.
        let mut output: Output = self.rpc(
            "terminal.read",
            json!({"terminal":agent.address,"lines":0}),
            5,
            false,
        )
        .await?;
        output.text = crate::person_profile::strip_prompt_context(output.text);
        Ok(output)
    }

    pub async fn send(&self, agent: &Terminal, task: String) -> Result<Delivery, Failure> {
        crate::person_profile::validate_prompt(&task)?;
        agent.require_live()?;
        self.rpc(
            "terminal.send",
            json!({"terminal":agent.address,"text":task}),
            135,
            true,
        )
        .await
    }

    /// Fixture protocol: Core compares identity, launch and idle turn at the write boundary.
    #[cfg(any(test, feature = "fleet-test-fixture"))]
    pub(crate) async fn send_completion(
        &self, core: &str, agent: &Terminal, task: String,
    ) -> Result<Delivery, Failure> {
        crate::person_profile::validate_prompt(&task)?;
        self.rpc(
            COMPLETION_SEND,
            json!({"core":core,"terminal":agent.address,"created_ms":agent.created_ms,
                   "launch":agent.launch_key(),"turn":agent.turn(),"text":task}),
            135,
            true,
        ).await
    }

    #[cfg(not(any(test, feature = "fleet-test-fixture")))]
    pub(crate) async fn send_completion(
        &self, _core: &str, _agent: &Terminal, _task: String,
    ) -> Result<Delivery, Failure> {
        Err(Failure::Input("Fixture completion delivery is disabled."))
    }

    pub async fn stage_file(
        &self,
        agent: &Terminal,
        name: &str,
        bytes: &[u8],
    ) -> Result<StagedFile, Failure> {
        agent.require_live()?;
        self.rpc(
            "terminal.put",
            json!({"terminal":agent.address,"name":name,"data":STANDARD.encode(bytes)}),
            15,
            true,
        )
        .await
    }

    pub async fn interrupt(&self, agent: &Terminal) -> Result<String, Failure> {
        #[derive(Deserialize)]
        struct Outcome {
            outcome: String,
        }
        agent.require_live()?;
        Ok(self
            .rpc::<Outcome>(
                "terminal.interrupt",
                json!({"terminal":agent.address,"timeout":5}),
                30,
                true,
            )
            .await?
            .outcome)
    }

    pub async fn end(&self, agent: &Terminal) -> Result<Terminal, Failure> {
        agent.require_live()?;
        let mut terminal: Terminal = self
            .rpc("terminal.kill", json!({"terminal":agent.address}), 30, true)
            .await?;
        terminal.hydrate_template();
        Ok(terminal)
    }
}

impl Terminal {
    pub(crate) fn uses_opencode_api(&self) -> bool {
        self.launch_key().is_some()
            && self
                .labels
                .get(LABEL)
                .is_some_and(|label| label == LABEL_VALUE)
            && self
                .labels
                .get(TEMPLATE_LABEL)
                .is_some_and(|name| valid_name(name))
    }

    fn hydrate_template(&mut self) {
        if self.template.is_none() && self.uses_opencode_api() {
            self.template = self.labels.get(TEMPLATE_LABEL).cloned();
        }
    }

    pub fn display_name(&self) -> &str {
        self.name.as_deref().unwrap_or(&self.address)
    }

    pub fn launch_key(&self) -> Option<&str> {
        self.labels.get(LAUNCH_LABEL).map(String::as_str)
    }

    /// The program has reported its status at least once, so text typed now reaches its composer.
    pub(crate) fn reported(&self) -> bool {
        self.reported || self.status.is_some()
    }

    pub(crate) fn turn(&self) -> u64 {
        self.turn
    }

    fn managed(&self) -> bool {
        local_address(&self.address)
            && !self.keep
            && self.template.is_some()
            && self
                .labels
                .get(LABEL)
                .is_some_and(|label| label == LABEL_VALUE)
    }

    pub fn require_live(&self) -> Result<(), Failure> {
        if self.state == "live" && self.reason.is_none() {
            Ok(())
        } else {
            Err(Failure::Input("This agent process is not running."))
        }
    }
}

/// The `PATH` agents are started with, when `service run` found the person's own (`service`); otherwise Core's.
fn agent_path() -> Option<String> {
    std::env::var(crate::service::AGENT_PATH_ENV)
        .ok()
        .filter(|path| !path.is_empty())
}

pub const AGENT_CWD_ERROR: &str =
    "SWARMHUB_AGENT_CWD must be an absolute path to an existing directory.";

/// The folder new agents start in, from `SWARMHUB_AGENT_CWD`. Unset or empty leaves the choice to Core.
pub fn agent_cwd() -> Result<Option<String>, ()> {
    match std::env::var("SWARMHUB_AGENT_CWD") {
        Err(std::env::VarError::NotPresent) => Ok(None),
        Ok(value) if value.is_empty() => Ok(None),
        Ok(value)
            if std::path::Path::new(&value).is_absolute()
                && std::path::Path::new(&value).is_dir() =>
        {
            Ok(Some(value))
        }
        _ => Err(()),
    }
}

/// A host-local folder keyed by the app's full bot ID. Browser agents use their persistent runtime name.
pub(crate) fn bot_workspace(id: Option<&str>, runtime_name: &str) -> io::Result<Option<PathBuf>> {
    bot_workspace_root()?
        .map(|root| bot_workspace_at(&root, id, runtime_name))
        .transpose()
}

fn bot_workspace_at(
    root: &std::path::Path,
    id: Option<&str>,
    runtime_name: &str,
) -> io::Result<PathBuf> {
    use std::os::unix::fs::{DirBuilderExt, MetadataExt};
    let invalid = || io::Error::new(io::ErrorKind::InvalidInput, "invalid bot workspace");
    let name = match id {
        Some(id)
            if id.len() == 36
                && id.bytes().enumerate().all(|(i, c)| {
                    if [8, 13, 18, 23].contains(&i) {
                        c == b'-'
                    } else {
                        c.is_ascii_hexdigit()
                    }
                }) =>
        {
            id.to_ascii_lowercase()
        }
        Some(_) => return Err(invalid()),
        None if valid_name(runtime_name) => format!("agent-{runtime_name}"),
        None => return Err(invalid()),
    };
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(root)?;
    let folder = root.canonicalize()?.join(name);
    let mark = match std::fs::DirBuilder::new().mode(0o700).create(&folder) {
        Ok(()) => true,
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            let meta = std::fs::symlink_metadata(&folder)?;
            if !meta.is_dir() {
                return Err(error);
            }
            // Creation may have stopped before writing the marker. Only adopt an empty, private directory
            // owned by this account, as it would be immediately after mkdir.
            meta.mode() & 0o7777 == 0o700
                && meta.uid() == unsafe { libc::geteuid() }
                && std::fs::read_dir(&folder)?.next().is_none()
        }
        Err(error) => return Err(error),
    };
    if mark {
        match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(folder.join(".swarmhub-workspace"))
        {
            Ok(_) => (),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
            Err(error) => return Err(error),
        }
    }
    Ok(folder)
}

pub(crate) fn bot_workspace_root() -> io::Result<Option<PathBuf>> {
    let root = agent_cwd()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, AGENT_CWD_ERROR))?
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .filter(|path| path.is_absolute())
                .map(|home| home.join("swarmhub-agents"))
        });
    Ok(root.map(|root| root.canonicalize().unwrap_or(root)))
}

/// A terminal address on this Core: `t`, a digit 1-9, then Core's 30 id symbols
/// (digits and consonants without `l`), such as `t7`, `t1b` or `t9z`.
pub(crate) fn local_address(value: &str) -> bool {
    const SYMBOLS: &[u8] = b"0123456789bcdfghjkmnpqrstvwxyz";
    value.len() <= 16
        && value.strip_prefix('t').is_some_and(|id| {
            id.starts_with(|c: char| matches!(c, '1'..='9'))
                && id.bytes().all(|b| SYMBOLS.contains(&b))
        })
}

pub(crate) fn valid_name(value: &str) -> bool {
    (1..=32).contains(&value.len())
        && value != "."
        && value != ".."
        && value
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
}

pub fn validate_task(value: &str) -> Result<(), Failure> {
    if value.trim().is_empty()
        || value.len() > 16_384
        || value
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
    {
        Err(Failure::Input(
            "Enter a task with up to 16 KB of plain text.",
        ))
    } else {
        Ok(())
    }
}

pub fn valid_filename(value: &str) -> bool {
    !value.trim().is_empty()
        && value != "."
        && value != ".."
        && value.len() <= 180
        && !value
            .chars()
            .any(|c| c.is_control() || matches!(c, '/' | '\\'))
}

#[cfg(test)]
mod tests {
    use super::local_address;

    #[test]
    fn accepts_the_addresses_core_assigns_after_the_first_nineteen() {
        for address in [
            "t1", "t9", "t10", "t19", "t1b", "t1z", "t9z", "t100", "t3fk",
        ] {
            assert!(local_address(address), "{address}");
        }
        // Vowels and `l` are never id symbols; a leading zero or a remote prefix is not local.
        for address in [
            "", "t", "t0", "t01", "t1a", "t1l", "t1B", "x1", "box/t1", "t1 ",
        ] {
            assert!(!local_address(address), "{address}");
        }
    }
}

#[cfg(test)]
mod workspace_tests {
    use super::*;

    #[test]
    fn each_bot_has_a_stable_private_directory_and_existing_links_are_refused() {
        use std::os::unix::fs::{PermissionsExt, symlink};
        let root = tempfile::tempdir().unwrap();
        let ada = "12345678-aaaa-4aaa-aaaa-123456789abc";
        let bea = "12345678-bbbb-4bbb-bbbb-123456789def";
        let first = bot_workspace_at(root.path(), Some(ada), "ada-123456").unwrap();
        let second = bot_workspace_at(root.path(), Some(bea), "bea-123456").unwrap();
        assert_ne!(first, second);
        assert_eq!(
            first,
            bot_workspace_at(root.path(), Some(ada), "renamed-123456").unwrap()
        );
        assert_eq!(
            first.metadata().unwrap().permissions().mode() & 0o777,
            0o700
        );
        assert!(first.join(".swarmhub-workspace").is_file());
        assert!(bot_workspace_at(root.path(), Some("../unsafe"), "ignored").is_err());

        symlink(&first, root.path().join("agent-existing")).unwrap();
        assert!(bot_workspace_at(root.path(), None, "existing").is_err());
    }

    #[test]
    fn a_crash_before_the_marker_recovers_an_empty_private_folder() {
        use std::os::unix::fs::DirBuilderExt;
        let root = tempfile::tempdir().unwrap();
        let recovered = root.path().join("agent-recover");
        let existing = root.path().join("agent-existing");
        let shared = root.path().join("agent-shared");
        let mut builder = std::fs::DirBuilder::new();
        builder.mode(0o700).create(&recovered).unwrap();
        builder.create(&existing).unwrap();
        std::fs::write(existing.join("user-file"), "keep").unwrap();
        builder.mode(0o755).create(&shared).unwrap();

        let folder = bot_workspace_at(root.path(), None, "recover").unwrap();
        assert_eq!(
            std::fs::read(folder.join(".swarmhub-workspace")).unwrap(),
            b""
        );
        for name in ["existing", "shared"] {
            let folder = bot_workspace_at(root.path(), None, name).unwrap();
            assert!(!folder.join(".swarmhub-workspace").exists());
        }
    }
}
