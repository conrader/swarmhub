//! Query the CLI in the selected template's launch environment. Only the sign-in state and billing label
//! leave the helper process. No chat, model call or credential refresh is needed.
use crate::{
    ApiError, Workspace,
    core::{Template, valid_name},
    runtimes::{Catalog, ModelAgent, ModelTarget, model_discovery::Probe},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::get,
};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    process::Stdio,
    sync::{Arc, LazyLock, Mutex},
    time::{Duration, Instant},
};
use tokio::{io::AsyncReadExt, sync::OnceCell};

#[derive(Clone, Default, Deserialize, Serialize, PartialEq, Debug)]
#[serde(rename_all = "snake_case")]
enum SignIn {
    SignedIn,
    SignedOut,
    #[default]
    Unreported,
}

#[derive(Clone, Deserialize, Serialize, PartialEq, Debug)]
enum Billing {
    #[serde(rename = "Free plan")]
    Free,
    #[serde(rename = "API key")]
    ApiKey,
    #[serde(rename = "Subscription · Go")]
    Go,
    #[serde(rename = "Subscription · Plus")]
    Plus,
    #[serde(rename = "Subscription · Pro")]
    Pro,
    #[serde(rename = "Subscription · Team")]
    Team,
    #[serde(rename = "Subscription · Business")]
    Business,
    #[serde(rename = "Subscription · Enterprise")]
    Enterprise,
    #[serde(rename = "Subscription · Education")]
    Education,
    #[serde(rename = "Subscription · Max")]
    Max,
}

#[derive(Clone, Default, Deserialize, Serialize, PartialEq, Debug)]
pub(crate) struct Account {
    state: SignIn,
    #[serde(skip_serializing_if = "Option::is_none")]
    billing: Option<Billing>,
}

impl Account {
    pub(crate) fn codex(result: &Value) -> Self {
        match result.get("account") {
            Some(Value::Null) if result["requiresOpenaiAuth"] == true => Self::signed_out(),
            Some(account) => match account["type"].as_str() {
                Some("apiKey") => Self::signed_in(Some(Billing::ApiKey)),
                Some("chatgpt" | "chatgptAuthTokens") => {
                    Self::signed_in(match account["planType"].as_str() {
                        Some("free") => Some(Billing::Free),
                        Some("go") => Some(Billing::Go),
                        Some("plus") => Some(Billing::Plus),
                        Some("pro") => Some(Billing::Pro),
                        Some("team") => Some(Billing::Team),
                        Some("business") => Some(Billing::Business),
                        Some("enterprise") => Some(Billing::Enterprise),
                        Some("edu") => Some(Billing::Education),
                        _ => None,
                    })
                }
                _ => Self::default(),
            },
            None => Self::default(),
        }
    }

    fn claude(result: &Value, success: bool) -> Self {
        match result["loggedIn"].as_bool() {
            Some(false) => Self::signed_out(),
            Some(true) if success => Self::signed_in(match result["authMethod"].as_str() {
                Some("api_key" | "apiKey" | "api-key") => Some(Billing::ApiKey),
                Some("claude.ai" | "oauth_token") => match result["subscriptionType"].as_str() {
                    Some("max") => Some(Billing::Max),
                    Some("pro") => Some(Billing::Pro),
                    Some("team") => Some(Billing::Team),
                    Some("enterprise") => Some(Billing::Enterprise),
                    Some("free") => Some(Billing::Free),
                    _ => None,
                },
                _ => None,
            }),
            _ => Self::default(),
        }
    }

    fn signed_out() -> Self {
        Self {
            state: SignIn::SignedOut,
            billing: None,
        }
    }

    fn signed_in(billing: Option<Billing>) -> Self {
        Self {
            state: SignIn::SignedIn,
            billing,
        }
    }
}

pub(crate) async fn cli(codex: bool) -> Result<(), Box<dyn std::error::Error>> {
    if std::env::args_os().nth(2).is_some() {
        return Err("Account status takes no arguments.".into());
    }
    let account = if codex {
        crate::codex_agent::account().unwrap_or_default()
    } else {
        tokio::time::timeout(Duration::from_secs(6), claude_status())
            .await
            .ok()
            .flatten()
            .unwrap_or_default()
    };
    println!("{}", serde_json::to_string(&account)?);
    Ok(())
}

async fn claude_status() -> Option<Account> {
    let mut child = tokio::process::Command::from(crate::service::agent_command(
        "claude",
        "SWARMHUB_CLAUDE_BIN",
    ))
    .args(["auth", "status", "--json"])
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(Stdio::null())
    .kill_on_drop(true)
    .spawn()
    .ok()?;
    let mut bytes = Vec::new();
    child
        .stdout
        .take()?
        .take(16385)
        .read_to_end(&mut bytes)
        .await
        .ok()?;
    if bytes.len() > 16384 {
        return None;
    }
    Some(Account::claude(
        &serde_json::from_slice(&bytes).ok()?,
        child.wait().await.ok()?.success(),
    ))
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/runtime-account", get(default_runtime))
        .route("/api/runtime-account/{template}", get(selected_runtime))
}

async fn default_runtime(State(w): State<Workspace>) -> Result<Json<Account>, ApiError> {
    lookup(w, None).await
}
async fn selected_runtime(
    State(w): State<Workspace>,
    Path(name): Path<String>,
) -> Result<Json<Account>, ApiError> {
    if !valid_name(&name) {
        return Ok(Json(Account::default()));
    }
    lookup(w, Some(name)).await
}

type Cache = HashMap<(String, [u8; 32]), (Instant, Arc<OnceCell<Account>>)>;
static CACHE: LazyLock<Mutex<Cache>> = LazyLock::new(Mutex::default);

async fn lookup(w: Workspace, name: Option<String>) -> Result<Json<Account>, ApiError> {
    let catalog = Catalog::load(w.history.file());
    let templates = w.core.templates().await?;
    let template = crate::bots::desk::configured_template(
        name.as_deref().unwrap_or_default(),
        &templates,
        &catalog,
    );
    let Some(template) = template else {
        return Ok(Json(Account::default()));
    };
    let Some(ModelTarget::Builtin(agent @ (ModelAgent::Claude | ModelAgent::Codex))) =
        catalog.model_target(template)
    else {
        return Ok(Json(Account::default()));
    };
    let Some(probe) = Probe::literal(template, agent) else {
        return Ok(Json(Account::default()));
    };
    let hello = w.core.identify().await?;
    if !hello.supports("machine.exec") {
        return Ok(Json(Account::default()));
    }
    let cell = cell(&hello.core.id, template);
    let command = match agent {
        ModelAgent::Claude => "claude-account",
        _ => "codex-account",
    };
    let account = cell
        .get_or_init(|| async {
            let Some(out) = w
                .core
                .runtime_probe(probe.helper, command, &probe.env)
                .await
                .ok()
            else {
                return Account::default();
            };
            if out.code != Some(0) || out.timed_out || out.truncated || out.stdout.len() > 1024 {
                return Account::default();
            }
            STANDARD
                .decode(out.stdout)
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
                .unwrap_or_default()
        })
        .await;
    Ok(Json(account.clone()))
}

fn cell(core: &str, template: &Template) -> Arc<OnceCell<Account>> {
    let now = Instant::now();
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    cache.retain(|_, (expires, _)| *expires > now);
    cache
        .entry((core.into(), Sha256::digest(&template.command).into()))
        .or_insert_with(|| (now + Duration::from_secs(30), Arc::default()))
        .1
        .clone()
}
