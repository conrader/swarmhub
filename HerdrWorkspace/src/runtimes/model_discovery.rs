use super::{Catalog, ModelAgent, ModelTarget, assignment, command_words};
use crate::{
    ApiError, Workspace,
    core::{Template, valid_name},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::post,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    sync::Mutex,
    time::{Duration, Instant},
};
use tokio::sync::broadcast;

const MAX_OUTPUT: usize = 256 * 1024;
const MAX_MODELS: usize = 512;
const CACHE_TTL: Duration = Duration::from_secs(30);
static DISCOVERY: Mutex<Discovery> = Mutex::new(Discovery { cached: None, active: None });

struct Discovery {
    cached: Option<Cached>,
    active: Option<(ProbeKey, broadcast::WeakSender<ProbeResult>)>,
}

type ProbeResult = Result<Models, &'static str>;

#[derive(Clone, PartialEq, Eq)]
struct ProbeKey {
    core: String,
    command: [u8; 32],
}

pub(super) struct Probe<'a> {
    agent: ModelAgent,
    helper: &'a str,
    env: BTreeMap<&'a str, &'a str>,
}

impl<'a> Probe<'a> {
    pub(super) fn for_template(catalog: &Catalog, template: &'a Template) -> Option<Self> {
        if !valid_name(&template.name) || !catalog.entries.get(&template.name)?.discover_models {
            return None;
        }
        let Some(ModelTarget::Builtin(agent @ (ModelAgent::OpenCode | ModelAgent::Codex | ModelAgent::Antigravity))) =
            catalog.model_target(template)
        else {
            return None;
        };
        let command = template.command.as_str();
        // The launch path uses a shell. Discovery only supports literal templates
        // so that it sees the same executable and environment without a shell.
        if command.contains(['~', '*', '?', '{', '}', '[', ']'])
            || command.chars().any(|c| c.is_control() && c != '\t')
        {
            return None;
        }
        Some(Self {
            agent,
            helper: command_words(command)?.next()?,
            env: command
                .split_ascii_whitespace()
                .map_while(assignment)
                .collect(),
        })
    }
}

#[derive(Clone, Serialize)]
struct Models {
    models: Vec<Model>,
    truncated: bool,
}

#[derive(Clone, Serialize)]
struct Model {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    provider: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    label: Option<String>,
}

struct Cached {
    key: ProbeKey,
    expires: Instant,
    models: Models,
}

fn failed(agent: ModelAgent) -> &'static str {
    match agent {
        ModelAgent::Antigravity => "Antigravity could not list models. Open agy on this Mac and check that you are signed in.",
        ModelAgent::Codex => {
            "Codex couldn't list models. Check its configuration on Herdr, or enter a model ID."
        }
        _ => {
            "OpenCode couldn't list models. SwarmHub requires OpenCode 2.3 or later. Check the CLI version and provider configuration on the workspace machine."
        }
    }
}

pub fn routes() -> Router<Workspace> {
    Router::new().route("/api/runtime-models/{template}", post(discover))
}

async fn discover(
    State(w): State<Workspace>,
    Path(template): Path<String>,
) -> Result<Json<Models>, ApiError> {
    const DISABLED: ApiError =
        ApiError::Conflict("Model discovery isn't enabled for this runtime.");
    if !valid_name(&template) {
        return Err(DISABLED);
    }
    let catalog = Catalog::load(w.history.file());
    if !catalog
        .entries
        .get(&template)
        .is_some_and(|entry| entry.discover_models)
    {
        return Err(DISABLED);
    }
    let template = w
        .core
        .templates()
        .await?
        .into_iter()
        .find(|item| item.name == template)
        .ok_or(DISABLED)?;
    let agent = Probe::for_template(&catalog, &template)
        .ok_or(DISABLED)?
        .agent;
    let core = w.core.identify().await?;
    if !core.supports("machine.exec") {
        return Err(ApiError::Conflict(
            "This version of Herdr cannot run model discovery.",
        ));
    }
    let key = ProbeKey { core: core.core.id, command: Sha256::digest(&template.command).into() };
    let mut receiver = {
        let mut state = DISCOVERY.lock().map_err(|_| ApiError::Conflict(failed(agent)))?;
        if let Some(cached) = &state.cached
            && cached.key == key && cached.expires > Instant::now() {
            return Ok(Json(cached.models.clone()));
        }
        if let Some((active_key, sender)) = &state.active
            && let Some(sender) = sender.upgrade() {
            if active_key != &key {
                return Err(ApiError::Conflict("A model list is loading already. Try again in a moment."));
            }
            sender.subscribe()
        } else {
            let (sender, receiver) = broadcast::channel(1);
            state.active = Some((key.clone(), sender.downgrade()));
            // A disconnected inspector must not cancel the CLI or release its slot early.
            tokio::spawn(async move {
                let result = run_probe(&w, &catalog, &template, agent).await;
                let mut state = DISCOVERY.lock().unwrap_or_else(|error| error.into_inner());
                if let Ok(models) = &result {
                    state.cached = Some(Cached { key, expires: Instant::now() + CACHE_TTL, models: models.clone() });
                }
                let _ = sender.send(result);
                state.active = None;
            });
            receiver
        }
    };
    receiver.recv().await
        .map_err(|_| ApiError::Conflict(failed(agent)))?
        .map(Json)
        .map_err(ApiError::Conflict)
}

async fn run_probe(w: &Workspace, catalog: &Catalog, template: &Template, agent: ModelAgent) -> ProbeResult {
    let probe = Probe::for_template(catalog, template).ok_or("Model discovery isn't enabled for this runtime.")?;
    let output = w.core.runtime_models(probe.agent, probe.helper, &probe.env).await.map_err(|_| failed(agent))?;
    if output.timed_out {
        return Err("The agent took too long to list models. Try again or enter a model ID.");
    }
    if output.code != Some(0) {
        return Err(failed(agent));
    }
    parse(agent, &output.stdout, output.truncated).ok_or_else(|| failed(agent))
}

pub(crate) fn launchable_model(agent: ModelAgent, id: &str) -> bool {
    agent.accepts(id)
}

fn parse(agent: ModelAgent, output: &str, truncated: bool) -> Option<Models> {
    if output.len() > MAX_OUTPUT.div_ceil(3) * 4 {
        return None;
    }
    let bytes = STANDARD.decode(output).ok()?;
    if bytes.len() > MAX_OUTPUT || truncated {
        return None;
    }
    if let ModelAgent::Codex = agent {
        let catalog: crate::codex_agent::ModelCatalog = serde_json::from_slice(&bytes).ok()?;
        if catalog.ids.len() > MAX_MODELS {
            return None;
        }
        let mut seen = BTreeSet::new();
        let mut models = Vec::new();
        for id in catalog.ids {
            if !launchable_model(agent, &id) || !seen.insert(id.clone()) {
                return None;
            }
            models.push(Model { id, provider: None, label: None });
        }
        return Some(Models {
            models,
            truncated: catalog.truncated,
        });
    }
    let stdout = std::str::from_utf8(&bytes).ok()?;
    if let ModelAgent::Antigravity = agent {
        let mut seen = BTreeSet::new();
        let mut models = Vec::new();
        for line in stdout.lines().filter(|line| !line.is_empty()) {
            let (id,label) = line.split_once('\t')?;
            if !agent.accepts(id) || label.is_empty() || label.len() > 160 || label.chars().any(char::is_control) { return None; }
            if seen.insert(id) && models.len() < MAX_MODELS {
                models.push(Model { id: id.to_owned(), label: Some(label.to_owned()), provider: None });
            }
        }
        return Some(Models { models, truncated: seen.len() > MAX_MODELS });
    }
    let mut ids = BTreeSet::new();
    for id in stdout.lines().filter(|line| !line.is_empty()) {
        if !launchable_model(ModelAgent::OpenCode, id) {
            return None;
        }
        ids.insert(id);
    }
    Some(Models {
        truncated: ids.len() > MAX_MODELS,
        models: ids
            .into_iter()
            .take(MAX_MODELS)
            .filter_map(|id| {
                let (provider, _) = id.split_once('/')?;
                Some(Model {
                    id: id.to_owned(),
                    provider: Some(provider.to_owned()),
                    label: None,
                })
            })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn reads_antigravity_model_picker_labels_in_provider_order() {
        let stdout = STANDARD.encode("gemini-high\tGemini (High)\ngemini-low\tGemini (Low)\n");
        let found = parse(ModelAgent::Antigravity,&stdout,false).unwrap();
        assert_eq!(found.models.len(),2);
        assert_eq!(found.models[0].id,"gemini-high");
        assert_eq!(found.models[0].label.as_deref(),Some("Gemini (High)"));
        assert!(parse(ModelAgent::Antigravity,&STANDARD.encode("Please sign in"),false).is_none());
    }

    #[test]
    fn requires_an_opted_in_compatible_literal_template() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("journal");
        fs::write(
            dir.path().join("runtime-catalog.json"),
            r#"{
            "open":{"harness":"OpenCode","discover_models":true},
            "codex":{"harness":"Codex","discover_models":true},
            "other":{"harness":"OpenCode"},
            "custom":{"harness":"OpenCode","discover_models":true,"model_transport":"environment"}
        }"#,
        )
        .unwrap();
        let catalog = Catalog::load(&path);
        let mut template = Template {
            name: "open".into(), description: String::new(), error: None,
            command: "SWARMHUB_OPENCODE_BIN=/opt/opencode AUTH_PATH=/opt/auth /usr/bin/swarmhub-herdr run-opencode --workspace-approvals mini".into(),
        };
        let probe = Probe::for_template(&catalog, &template).unwrap();
        assert_eq!(probe.helper, "/usr/bin/swarmhub-herdr");
        assert_eq!(probe.env["SWARMHUB_OPENCODE_BIN"], "/opt/opencode");
        assert_eq!(probe.env["AUTH_PATH"], "/opt/auth");
        for name in ["other", "custom", "unknown"] {
            template.name = name.into();
            assert!(Probe::for_template(&catalog, &template).is_none());
        }
        template.name = "open".into();
        for command in [
            "opencode mini",
            "/usr/bin/swarmhub-herdr run-claude",
            "/usr/bin/swarmhub-herdr run-opencode mini --model foo/bar",
            "OPENCODE_CONFIG=$HOME/test /usr/bin/swarmhub-herdr run-opencode mini",
            "~/bin/swarmhub-herdr run-opencode mini",
        ] {
            template.command = command.into();
            assert!(
                Probe::for_template(&catalog, &template).is_none(),
                "{command}"
            );
        }
        template.name = "codex".into();
        template.command =
            "CODEX_HOME=/opt/codex /usr/bin/swarmhub-herdr run-codex --workspace-approvals".into();
        let probe = Probe::for_template(&catalog, &template).unwrap();
        assert!(matches!(probe.agent, ModelAgent::Codex));
        assert_eq!(probe.env["CODEX_HOME"], "/opt/codex");
        template.command.push_str(" --model fixed");
        assert!(Probe::for_template(&catalog, &template).is_none());
    }

    #[test]
    fn exposes_only_sorted_unique_launchable_model_ids() {
        let output = STANDARD
            .encode("fixture/latest\nother/test:free\nfixture/latest\nfixture/other[fast]\n");
        let models = parse(ModelAgent::OpenCode, &output, false).unwrap();
        let rows: Vec<_> = models
            .models
            .iter()
            .map(|model| (model.id.as_str(), model.provider.as_deref().unwrap()))
            .collect();
        assert_eq!(
            rows,
            [
                ("fixture/latest", "fixture"),
                ("fixture/other[fast]", "fixture"),
                ("other/test:free", "other")
            ]
        );
        assert!(!models.truncated);
        for malformed in [
            "diagnostic with private values",
            "-fixture/no",
            "fixture/--no",
        ] {
            assert!(
                parse(
                    ModelAgent::OpenCode,
                    &STANDARD.encode(format!("fixture/latest\n{malformed}\n")),
                    false
                )
                .is_none()
            );
        }
        assert!(parse(ModelAgent::OpenCode, &output, true).is_none());
        assert!(
            parse(
                ModelAgent::OpenCode,
                &STANDARD.encode(vec![b'x'; MAX_OUTPUT + 1]),
                false
            )
            .is_none()
        );
        let many: String = (0..MAX_MODELS + 1)
            .map(|id| format!("fixture/model-{id:04}\n"))
            .collect();
        let models = parse(ModelAgent::OpenCode, &STANDARD.encode(many), false).unwrap();
        assert_eq!(models.models.len(), MAX_MODELS);
        assert!(models.truncated);
    }

    #[test]
    fn codex_keeps_catalog_order_without_inventing_a_provider() {
        let output = STANDARD.encode(r#"{"ids":["gpt-z","gpt-a"],"truncated":true}"#);
        let models = parse(ModelAgent::Codex, &output, false).unwrap();
        assert!(models.truncated);
        assert_eq!(
            models
                .models
                .into_iter()
                .map(|model| (model.id, model.provider))
                .collect::<Vec<_>>(),
            [("gpt-z".into(), None), ("gpt-a".into(), None)]
        );
        for invalid in [
            r#"{"ids":["-not-an-id"],"truncated":false}"#,
            r#"{"ids":["duplicate","duplicate"],"truncated":false}"#,
        ] {
            assert!(parse(ModelAgent::Codex, &STANDARD.encode(invalid), false).is_none());
        }
    }
}
