use crate::core::{Template, valid_name};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap, env, ffi::OsString, fs::OpenOptions, io::Read,
    os::unix::fs::OpenOptionsExt, path::Path,
};

pub mod model_discovery;

const MAX_CATALOG: u64 = 64 * 1024;
pub const MODEL_ENV: &str = "SWARMHUB_LAUNCH_MODEL";
pub(crate) const INVALID_API_TEMPLATE: &str =
    "Use a literal swarmhub-herdr run-opencode --api-first-task mini command for this template.";
pub const CUSTOM_MODEL_ENV: &str = "SWARMHUB_MODEL_ID";

#[derive(Clone, Copy)]
pub enum ModelAgent {
    Claude,
    Codex,
    OpenCode,
}

impl ModelAgent {
    pub fn name(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::OpenCode => "OpenCode",
        }
    }

    fn tag(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::OpenCode => "opencode",
        }
    }

    pub fn selection(self, id: &str) -> String {
        format!("{}:{id}", self.tag())
    }

    pub(crate) fn accepts(self, id: &str) -> bool {
        if !valid_model_id(id) {
            return false;
        }
        match self {
            Self::OpenCode => id.split_once('/').is_some_and(|(provider, model)| {
                provider
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
                    && starts_alphanumeric(model)
            }),
            Self::Claude | Self::Codex => true,
        }
    }

    pub fn add_model_arg(self, args: &mut Vec<OsString>) -> Result<(), &'static str> {
        let Some(value) = env::var_os(MODEL_ENV).filter(|value| !value.is_empty()) else {
            return Ok(());
        };
        let id = value
            .to_str()
            .and_then(|value| value.split_once(':'))
            .filter(|(agent, id)| *agent == self.tag() && self.accepts(id))
            .map(|(_, id)| id)
            .ok_or("This model selection does not match the agent template.")?;
        let supported = match self {
            Self::OpenCode => args.len() == 1 && args[0] == "mini",
            Self::Claude | Self::Codex => args.is_empty(),
        };
        if !supported {
            return Err("The selected model requires a template without fixed agent arguments.");
        }
        args.extend(["--model".into(), id.into()]);
        Ok(())
    }
}

#[derive(Clone, Copy, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ModelTransport {
    Environment,
}

#[derive(Clone, Copy)]
pub enum ModelTarget {
    Builtin(ModelAgent),
    Environment,
}

pub enum LaunchModel {
    Builtin(String),
    Environment(String),
}

impl LaunchModel {
    pub fn builtin(&self) -> Option<&str> {
        match self {
            Self::Builtin(id) => Some(id),
            Self::Environment(_) => None,
        }
    }

    pub fn environment(&self) -> Option<&str> {
        match self {
            Self::Environment(id) => Some(id),
            Self::Builtin(_) => None,
        }
    }
}

impl ModelTarget {
    fn name(self, harness: &str) -> String {
        match self {
            Self::Builtin(agent) => agent.name().to_owned(),
            Self::Environment => harness.to_owned(),
        }
    }

    pub fn selection(self, id: &str) -> LaunchModel {
        match self {
            Self::Builtin(agent) => LaunchModel::Builtin(agent.selection(id)),
            Self::Environment => LaunchModel::Environment(id.to_owned()),
        }
    }

    pub fn accepts(self, id: &str) -> bool {
        match self {
            Self::Builtin(agent) => agent.accepts(id),
            Self::Environment => valid_model_id(id),
        }
    }
}

/// Launch labels, not a provider connection or evidence of inference.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Runtime {
    harness: String,
    provider: Option<String>,
    model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_id: Option<String>,
    /// The agent program's short name for people ("Claude" for Claude Code): the catalog's, or the one the
    /// workspace knows for the program.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    display_name: Option<String>,
}

/// The short name of an agent program the workspace knows.
fn short_name(harness: &str) -> Option<String> {
    match harness {
        "Claude Code" => Some("Claude".to_owned()),
        "Codex" | "OpenCode" => Some(harness.to_owned()),
        _ => None,
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ModelChoice {
    pub id: String,
    provider: String,
    label: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    harness: String,
    provider: Option<String>,
    model: Option<String>,
    /// The agent program's short name for people, when the workspace's own is not wanted.
    display_name: Option<String>,
    #[serde(default)]
    models: Vec<ModelChoice>,
    model_transport: Option<ModelTransport>,
    #[serde(default)]
    discover_models: bool,
}

#[derive(Default)]
pub struct Catalog {
    entries: BTreeMap<String, Entry>,
    pub warning: Option<&'static str>,
}

#[derive(Serialize)]
pub struct Choice {
    name: String,
    description: String,
    error: Option<&'static str>,
    runtime: Runtime,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    models: Vec<ModelChoice>,
    #[serde(skip_serializing_if = "Option::is_none")]
    model_agent: Option<String>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    discover_models: bool,
}

impl Catalog {
    pub fn load(journal: &Path) -> Self {
        let input = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(journal.with_file_name("runtime-catalog.json"));
        if input
            .as_ref()
            .is_err_and(|error| error.kind() == std::io::ErrorKind::NotFound)
        {
            return Self::default();
        }
        let entries = input.ok().and_then(|file| {
            if !file.metadata().ok()?.is_file() {
                return None;
            }
            let mut bytes = Vec::new();
            file.take(MAX_CATALOG + 1).read_to_end(&mut bytes).ok()?;
            if bytes.len() as u64 > MAX_CATALOG {
                return None;
            }
            let entries: BTreeMap<String, Entry> = serde_json::from_slice(&bytes).ok()?;
            entries
                .iter()
                .all(|(name, entry)| valid_name(name) && entry.valid())
                .then_some(entries)
        });
        match entries {
            Some(entries) => Self {
                entries,
                warning: None,
            },
            None => Self {
                warning: Some(
                    "SwarmHub couldn't read runtime-catalog.json. Herdr templates are still available.",
                ),
                ..Self::default()
            },
        }
    }

    pub fn runtime(&self, template: &Template) -> Runtime {
        self.entries
            .get(&template.name)
            .map(Entry::runtime)
            .unwrap_or_else(|| {
                let harness = recognize(&template.command);
                Runtime {
                    harness: harness.to_owned(),
                    provider: None,
                    model: None,
                    model_id: None,
                    display_name: short_name(harness),
                }
            })
    }

    pub fn choice(&self, template: Template) -> Choice {
        let runtime = self.runtime(&template);
        let discover_models = model_discovery::Probe::for_template(self, &template).is_some();
        let (models, model_agent) =
            self.models(&template)
                .map_or((Vec::new(), None), |(target, models)| {
                    (
                        models.into_iter().cloned().collect(),
                        Some(target.name(&runtime.harness)),
                    )
                });
        let error = if template.error.is_some() {
            Some("Herdr could not load this template.")
        } else if !valid_name(&template.name) {
            Some(
                "This template name must use 1–32 lowercase letters, digits, dots, dashes or underscores.",
            )
        } else if crate::opencode_agent::first_task::OptIn::requested(&template)
            && crate::opencode_agent::first_task::OptIn::new(&template).is_none()
        {
            Some(INVALID_API_TEMPLATE)
        } else {
            None
        };
        Choice {
            name: template.name,
            description: template.description,
            error,
            runtime,
            models,
            model_agent,
            discover_models,
        }
    }

    pub fn model_target(&self, template: &Template) -> Option<ModelTarget> {
        if template.error.is_some() {
            return None;
        }
        match self
            .entries
            .get(&template.name)
            .and_then(|entry| entry.model_transport)
        {
            // A custom template explicitly declares that its entrypoint consumes the chosen ID.
            Some(ModelTransport::Environment) => Some(ModelTarget::Environment),
            None => model_agent(&template.command).map(ModelTarget::Builtin),
        }
    }

    pub fn models(&self, template: &Template) -> Option<(ModelTarget, Vec<&ModelChoice>)> {
        let target = self.model_target(template)?;
        let models = self
            .entries
            .get(&template.name)
            .into_iter()
            .flat_map(|entry| &entry.models)
            .filter(|model| target.accepts(&model.id))
            .collect();
        Some((target, models))
    }
}

impl Catalog {
    /// The label the catalog gives a model of a template ("Sonnet 5.5"), when it lists that model.
    pub(crate) fn model_label(&self, template: &str, model: &str) -> Option<String> {
        self.entries
            .get(template)?
            .models
            .iter()
            .find(|choice| choice.id == model)
            .map(|choice| choice.label.clone())
    }
}

impl Runtime {
    pub fn with_model(mut self, target: ModelTarget, choice: &ModelChoice) -> Self {
        self.harness = target.name(&self.harness);
        self.model_id = Some(choice.id.clone());
        self.provider = Some(choice.provider.clone());
        self.model = Some(choice.label.clone());
        self
    }

    pub fn with_model_id(mut self, target: ModelTarget, id: &str) -> Self {
        self.harness = target.name(&self.harness);
        self.model_id = Some(id.to_owned());
        self.model = Some(id.to_owned());
        self.provider = if matches!(target, ModelTarget::Builtin(ModelAgent::OpenCode)) {
            id.split_once('/').map(|(provider, _)| provider.to_owned())
        } else {
            None
        };
        self
    }
}

fn label(value: &str) -> bool {
    !value.is_empty()
        && value.trim() == value
        && value.chars().count() <= 100
        && !value.chars().any(char::is_control)
}

impl Entry {
    fn runtime(&self) -> Runtime {
        Runtime {
            harness: self.harness.clone(),
            provider: self.provider.clone(),
            model: self.model.clone(),
            model_id: None,
            display_name: self
                .display_name
                .clone()
                .or_else(|| short_name(&self.harness)),
        }
    }

    fn valid(&self) -> bool {
        label(&self.harness)
            && self.display_name.as_deref().is_none_or(label)
            && self.provider.as_deref().is_none_or(label)
            && self.model.as_deref().is_none_or(label)
            && self.models.len() <= 32
            && self.models.iter().enumerate().all(|(index, model)| {
                valid_model_id(&model.id)
                    && label(&model.provider)
                    && label(&model.label)
                    && self.models[..index]
                        .iter()
                        .all(|previous| previous.id != model.id)
            })
    }
}

fn valid_model_id(id: &str) -> bool {
    id.len() <= 160
        && starts_alphanumeric(id)
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"_.-:/@+#[]".contains(&byte))
}

fn starts_alphanumeric(value: &str) -> bool {
    value
        .as_bytes()
        .first()
        .is_some_and(u8::is_ascii_alphanumeric)
}

pub(crate) fn command_words(command: &str) -> Option<impl Iterator<Item = &str>> {
    // Interpret neither the shell nor its arguments. Recognize a literal
    // executable only; complicated wrappers can be labeled in the catalog.
    if command.contains([
        '\n', '\r', '\'', '"', '$', '\\', '`', '&', '|', ';', '<', '>', '(', ')', '#',
    ]) {
        return None;
    }
    let mut words = command.split_ascii_whitespace().peekable();
    while words.peek().is_some_and(|word| assignment(word).is_some()) {
        words.next();
    }
    Some(words)
}

fn assignment(word: &str) -> Option<(&str, &str)> {
    word.split_once('=').filter(|(name, _)| {
        !name.is_empty()
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
            && !name.as_bytes()[0].is_ascii_digit()
    })
}

fn model_agent(command: &str) -> Option<ModelAgent> {
    let mut words = command_words(command)?;
    if words.next()?.rsplit('/').next() != Some("swarmhub-herdr") {
        return None;
    }
    let wrapper = words.next()?;
    let mut first = words.next();
    if first == Some("--workspace-approvals") {
        first = words.next();
    }
    if wrapper == "run-opencode" && first == Some(crate::opencode_agent::first_task::FLAG) {
        first = words.next();
    }
    if wrapper == "run-claude" && first == Some(crate::agent::claude_preview::FLAG) {
        first = words.next();
    }
    let agent = match (wrapper, first) {
        ("run-opencode", Some("mini")) => ModelAgent::OpenCode,
        ("run-claude", None) => ModelAgent::Claude,
        ("run-codex", None) => ModelAgent::Codex,
        _ => return None,
    };
    words.next().is_none().then_some(agent)
}

fn recognize(command: &str) -> &'static str {
    const GENERIC: &str = "Custom agent";
    let Some(mut words) = command_words(command) else {
        return GENERIC;
    };
    match words.next().and_then(|exe| exe.rsplit('/').next()) {
        Some("claude") => "Claude Code",
        Some("codex") => "Codex",
        Some("opencode") => "OpenCode",
        Some("pi") => "Pi",
        Some("swarmhub-herdr") => match words.next() {
            Some("run-claude") => "Claude Code",
            Some("run-codex") => "Codex",
            Some("run-opencode") => "OpenCode",
            _ => GENERIC,
        },
        _ => GENERIC,
    }
}

#[cfg(test)]
mod tests {
    use super::recognize;

    #[test]
    fn recognizes_fixed_harnesses_without_inventing_values_for_wrappers() {
        assert_eq!(recognize("/usr/bin/codex --model sample"), "Codex");
        assert_eq!(
            recognize("MODE=test /usr/bin/swarmhub-herdr run-claude"),
            "Claude Code"
        );
        assert_eq!(recognize("opencode --model test/local"), "OpenCode");
        assert_eq!(recognize("echo claude"), "Custom agent");
        assert_eq!(recognize("codex && other-agent"), "Custom agent");
        assert_eq!(recognize("codex --model \"$MODEL\""), "Custom agent");
    }

    #[test]
    fn a_runtime_carries_the_programs_short_name_and_the_catalog_labels_its_models() {
        use super::{Catalog, Entry};
        let entries: std::collections::BTreeMap<String, Entry> = serde_json::from_str(
            r#"{"claude-work":{"harness":"Claude Code","models":[{"id":"sonnet","label":"Sonnet 5.5","provider":"Anthropic"}]},
                "codex-work":{"harness":"Codex","display_name":"Codex CLI"},
                "local":{"harness":"Local runner"}}"#,
        )
        .unwrap();
        assert!(entries.values().all(Entry::valid));
        let catalog = Catalog {
            entries,
            warning: None,
        };
        let template = |name: &str, command: &str| -> crate::core::Template {
            serde_json::from_value(
                serde_json::json!({"name":name,"description":"","error":null,"command":command}),
            )
            .unwrap()
        };
        let shown = |name: &str, command: &str| {
            serde_json::to_value(catalog.runtime(&template(name, command))).unwrap()
        };
        // The workspace's own short name, the catalog's when it gives one, and none for a program it does not know.
        assert_eq!(shown("claude-work", "x")["display_name"], "Claude");
        assert_eq!(shown("codex-work", "x")["display_name"], "Codex CLI");
        assert!(shown("local", "x").get("display_name").is_none());
        // A template the catalog does not list is named by its command.
        assert_eq!(
            shown("plain", "/usr/bin/swarmhub-herdr run-codex")["display_name"],
            "Codex"
        );
        assert!(shown("other", "echo hi").get("display_name").is_none());
        // What a client sends back as `expected_runtime` is the same runtime.
        let sent: super::Runtime = serde_json::from_value(shown("claude-work", "x")).unwrap();
        assert_eq!(sent, catalog.runtime(&template("claude-work", "x")));
        let old: super::Runtime =
            serde_json::from_str(r#"{"harness":"Codex","provider":null,"model":null}"#).unwrap();
        assert!(
            serde_json::to_value(old)
                .unwrap()
                .get("display_name")
                .is_none()
        );

        assert_eq!(
            catalog.model_label("claude-work", "sonnet").as_deref(),
            Some("Sonnet 5.5")
        );
        assert_eq!(catalog.model_label("claude-work", "opus"), None);
        assert_eq!(catalog.model_label("nowhere", "sonnet"), None);
    }
}
