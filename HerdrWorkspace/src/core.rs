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
    pub model: Option<&'a crate::runtimes::LaunchModel>,
    pub results: Option<&'a str>,
    pub opencode_first_task: Option<&'a str>,
}

pub enum LaunchSource {
    Template(String, String),
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
                    error.message,
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
            crate::runtimes::ModelAgent::Claude => {
                return Err(Failure::Input(
                    "This runtime has no supported model listing.",
                ));
            }
        };
        self.rpc(
            "machine.exec",
            json!({"argv":[helper,command],"env":env,"timeout":35}),
            40,
            false,
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
        let (template, task, line) = match source {
            LaunchSource::Template(template, task) => (template, Some(task), None),
            LaunchSource::DirectOpenCode(template, command) => (template, None, Some(command)),
        };
        if !valid_name(&name) || !valid_name(&template) {
            return Err(Failure::Input(
                "Use 1–32 lowercase letters, digits, dots, dashes or underscores for the agent and template names.",
            ));
        }
        if let Some(task) = task.as_deref() {
            validate_task(task)?;
        }
        let mut labels = BTreeMap::from([(LABEL, LABEL_VALUE), (LAUNCH_LABEL, env.key)]);
        let argv = if let Some(task) = task {
            vec![template.clone(), task]
        } else {
            // Calling terminal.run with a template name would paste its Markdown body.
            labels.insert(TEMPLATE_LABEL, &template);
            Vec::new()
        };
        let mut terminal: Terminal = self
            .rpc(
                "terminal.run",
                json!({
                    "name":name,"argv":argv,"line":line,"wait":false,"no_parent":true,
                    "labels":labels,"size":{"cols":100,"rows":30},
                    "env":{"SWARMHUB_JOURNAL":env.journal,"SWARMHUB_LAUNCH_KEY":env.key,
                           "SWARMHUB_APPROVAL_SOCKET":env.approval_socket,
                           (crate::runtimes::MODEL_ENV):env.model.and_then(crate::runtimes::LaunchModel::builtin).unwrap_or_default(),
                           (crate::runtimes::CUSTOM_MODEL_ENV):env.model.and_then(crate::runtimes::LaunchModel::environment).unwrap_or_default(),
                           (crate::opencode_agent::first_task::ENV):env.opencode_first_task.unwrap_or_default(),
                           "SWARMHUB_RESULTS":env.results.unwrap_or_default()}
                }),
                85,
                true,
            )
            .await?;
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
        self.rpc(
            "terminal.read",
            json!({"terminal":agent.address,"lines":0}),
            5,
            false,
        )
        .await
    }

    pub async fn send(&self, agent: &Terminal, task: String) -> Result<Delivery, Failure> {
        validate_task(&task)?;
        agent.require_live()?;
        self.rpc(
            "terminal.send",
            json!({"terminal":agent.address,"text":task}),
            135,
            true,
        )
        .await
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

fn local_address(value: &str) -> bool {
    value
        .strip_prefix('t')
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
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
