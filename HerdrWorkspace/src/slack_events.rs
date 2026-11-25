use crate::{
    ApiError, Workspace,
    core::Failure,
    history::{History, now},
    routine_routes::spawn,
    routines::{HookAuth, HookRun},
    vault::Vault,
};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode, header},
    routing::post,
};
use ring::hmac;
use serde_json::{Value, json};
use std::sync::Arc;

#[derive(Clone)]
pub enum Signing {
    Environment(Arc<hmac::Key>),
    Vault {
        name: String,
        vault: Vault,
        history: History,
    },
}

impl Signing {
    pub fn configured(
        history: &History,
        vault: Option<&Vault>,
    ) -> Result<Option<Self>, &'static str> {
        match (
            std::env::var_os("SWARMHUB_SLACK_SIGNING_SECRET"),
            std::env::var_os("SWARMHUB_SLACK_VAULT_ENTRY"),
        ) {
            (None, None) => Ok(None),
            (Some(_), Some(_)) => {
                Err("Configure either a Slack signing secret or a Slack vault entry, not both.")
            }
            (Some(secret), None) => {
                let secret = secret.to_str().and_then(signing_key).ok_or(
                    "SWARMHUB_SLACK_SIGNING_SECRET must contain the Slack app's signing secret.",
                )?;
                Ok(Some(Self::Environment(secret)))
            }
            (None, Some(name)) => {
                let name = name
                    .to_str()
                    .filter(|value| crate::vault::valid_name(value))
                    .ok_or("Set SWARMHUB_SLACK_VAULT_ENTRY to a valid vault entry name.")?
                    .to_owned();
                let vault = vault
                    .cloned()
                    .ok_or("Set SWARMHUB_VAULT_KEY_FILE to use a Slack vault entry.")?;
                Ok(Some(Self::Vault {
                    name,
                    vault,
                    history: history.clone(),
                }))
            }
        }
    }

    pub fn vault_entry(&self) -> Option<&str> {
        match self {
            Self::Environment(_) => None,
            Self::Vault { name, .. } => Some(name),
        }
    }

    pub fn ready(&self) -> bool {
        self.key().is_some()
    }

    fn key(&self) -> Option<Arc<hmac::Key>> {
        match self {
            Self::Environment(key) => Some(key.clone()),
            Self::Vault {
                name,
                vault,
                history,
            } => vault
                .lookup(history, name)
                .ok()
                .flatten()
                .as_deref()
                .and_then(signing_key),
        }
    }

    fn verify(key: &hmac::Key, headers: &HeaderMap, bytes: &[u8]) -> bool {
        let get = |key| headers.get(key).and_then(|value| value.to_str().ok());
        let Some(timestamp) = get("x-slack-request-timestamp")
            .filter(|value| value.len() <= 12 && value.bytes().all(|c| c.is_ascii_digit()))
        else {
            return false;
        };
        if !timestamp
            .parse::<i64>()
            .is_ok_and(|at| at.abs_diff(now() / 1000) <= 300)
        {
            return false;
        }
        let Some(signature) =
            get("x-slack-signature").and_then(|value| decode_signature(value, "v0="))
        else {
            return false;
        };
        let mut signed = format!("v0:{timestamp}:").into_bytes();
        signed.extend_from_slice(bytes);
        hmac::verify(key, &signed, &signature).is_ok()
    }
}

fn signing_key(value: &str) -> Option<Arc<hmac::Key>> {
    ((16..=256).contains(&value.len()) && value.bytes().all(|c| c.is_ascii_graphic()))
        .then(|| Arc::new(hmac::Key::new(hmac::HMAC_SHA256, value.as_bytes())))
}

pub(crate) fn decode_signature(value: &str, prefix: &str) -> Option<[u8; 32]> {
    let hex = value.strip_prefix(prefix)?;
    if hex.len() != 64 || !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    let mut result = [0; 32];
    for (i, byte) in result.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(result)
}

pub fn routes() -> Router<Workspace> {
    Router::new().route(
        "/hooks/slack",
        post(receive).layer(DefaultBodyLimit::max(64 * 1024)),
    )
}

pub(crate) fn valid_slack_id(value: &str, prefixes: &[u8]) -> bool {
    (2..=32).contains(&value.len())
        && prefixes.contains(&value.as_bytes()[0])
        && value
            .bytes()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit())
}

async fn receive(
    State(w): State<Workspace>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    let Some(key) = w.slack.as_ref().and_then(Signing::key) else {
        return Ok((
            StatusCode::SERVICE_UNAVAILABLE,
            Json(json!({"error":"A Slack signing credential is not available."})),
        ));
    };
    if !Signing::verify(&key, &headers, &bytes) {
        return Ok((
            StatusCode::UNAUTHORIZED,
            Json(json!({"error":"A recent, valid Slack signature is required."})),
        ));
    }
    if !headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(';').next())
        .is_some_and(|value| value.trim().eq_ignore_ascii_case("application/json"))
    {
        return Ok((
            StatusCode::UNSUPPORTED_MEDIA_TYPE,
            Json(json!({"error":"Send Slack events as application/json."})),
        ));
    }
    let input: Value =
        serde_json::from_slice(&bytes).map_err(|_| Failure::Input("Invalid Slack event JSON."))?;
    match input.get("type").and_then(Value::as_str) {
        Some("url_verification") => {
            let challenge = input
                .get("challenge")
                .and_then(Value::as_str)
                .filter(|c| !c.is_empty() && c.len() <= 512)
                .ok_or(Failure::Input(
                    "A Slack verification challenge is required.",
                ))?;
            return Ok((StatusCode::OK, Json(json!({"challenge":challenge}))));
        }
        Some("event_callback") => (),
        _ => return Ok(ignored()),
    }
    let event = input
        .get("event")
        .ok_or(Failure::Input("A Slack event is required."))?;
    if event.get("type").and_then(Value::as_str) != Some("app_mention")
        || event.get("bot_id").is_some()
        || event.get("subtype").is_some()
    {
        return Ok(ignored());
    }
    let team = input
        .get("team_id")
        .and_then(Value::as_str)
        .filter(|v| valid_slack_id(v, b"T"))
        .ok_or(Failure::Input("A Slack workspace ID is required."))?;
    let channel = event
        .get("channel")
        .and_then(Value::as_str)
        .filter(|v| valid_slack_id(v, b"CG"))
        .ok_or(Failure::Input("A Slack channel ID is required."))?;
    let event_id = input
        .get("event_id")
        .and_then(Value::as_str)
        .filter(|v| {
            v.starts_with("Ev") && v.len() <= 64 && v.bytes().all(|c| c.is_ascii_alphanumeric())
        })
        .ok_or(Failure::Input("A Slack event ID is required."))?;
    let text: String = event
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .chars()
        .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
        .take(400)
        .collect();
    let normalized = json!({"event":"app_mention","team_id":team,"channel":channel,"text":text});
    let key = format!("slack:{event_id}");
    let mut accepted = 0;
    let mut duplicates = 0;
    let mut review = 0;
    let mut retry = false;
    for id in w.history.slack_routines(team, channel)? {
        match w.history.claim_webhook(
            id,
            &HookAuth::VerifiedSlack,
            &key,
            Some(normalized.clone()),
        )? {
            HookRun::Accepted(dispatch) => {
                spawn(w.clone(), *dispatch);
                accepted += 1;
            }
            HookRun::Duplicate(_) => duplicates += 1,
            HookRun::Queued {
                duplicate: true, ..
            } => duplicates += 1,
            HookRun::Queued {
                duplicate: false, ..
            } => review += 1,
            HookRun::Busy | HookRun::RateLimited | HookRun::ReviewFull => retry = true,
            HookRun::PreviouslyHandled | HookRun::Unauthorized | HookRun::Inactive | HookRun::Ignored | HookRun::Dismissed => (),
        }
    }
    // Retried deliveries can fill in routines that were busy without re-running successful matches.
    let status = if retry {
        StatusCode::SERVICE_UNAVAILABLE
    } else {
        StatusCode::OK
    };
    let mut result = json!({"accepted":accepted,"duplicates":duplicates,"retry":retry});
    if review != 0 {
        result["awaiting_review"] = json!(review);
    }
    Ok((status, Json(result)))
}

fn ignored() -> (StatusCode, Json<Value>) {
    (StatusCode::OK, Json(json!({"ignored":true})))
}
