use crate::{
    ApiError, Workspace,
    core::Failure,
    history::{History, StoreError},
    vault::Vault,
};
use axum::{
    Json, Router,
    extract::{Query, State},
    http::{HeaderName, HeaderValue, StatusCode},
    response::{Html, IntoResponse, Redirect, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use reqwest::Url;
use ring::{
    digest::{SHA256, digest},
    rand::{SecureRandom, SystemRandom},
};
use serde::Deserialize;
use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

pub struct Setup {
    vault: Vault,
    history: History,
    name: String,
    redirect: String,
    pending: Mutex<Attempts>,
}

struct Pending {
    state: String,
    verifier: String,
    until: Instant,
}
#[derive(Default)]
struct Attempts {
    generation: u64,
    pending: Option<Pending>,
}

impl Setup {
    pub fn new(
        vault: Vault,
        history: History,
        port: u16,
        client: &str,
        folder: &str,
        uploads: bool,
    ) -> Self {
        let tag = digest(&SHA256, format!("{client}\n{folder}\n{uploads}").as_bytes());
        Self {
            vault,
            history,
            name: format!(
                "Google Drive OAuth {}",
                URL_SAFE_NO_PAD.encode(&tag.as_ref()[..12])
            ),
            redirect: format!("http://127.0.0.1:{port}/drive/oauth/callback"),
            pending: Mutex::new(Attempts::default()),
        }
    }

    pub fn name(&self) -> &str {
        &self.name
    }
    pub fn redirect(&self) -> &str {
        &self.redirect
    }
    pub fn secret(&self) -> Result<Option<String>, ApiError> {
        self.vault.lookup(&self.history, &self.name)
    }
    pub fn save(&self, generation: u64, refresh: String) -> Result<(), ApiError> {
        let current = self.pending.lock().map_err(|_| StoreError)?;
        if current.generation != generation {
            return Err(ApiError::Conflict(
                "Start the latest Google Drive connection again.",
            ));
        }
        self.vault.put_connector(&self.history, &self.name, refresh)
    }

    pub fn disconnect(&self) -> Result<(), ApiError> {
        let mut current = self.pending.lock().map_err(|_| StoreError)?;
        self.vault.remove_connector(&self.history, &self.name)?;
        current.generation = current.generation.checked_add(1).ok_or(StoreError)?;
        current.pending = None;
        Ok(())
    }

    pub fn begin(&self, client: &str, uploads: bool) -> Result<Url, ApiError> {
        // Check that the Vault is unlocked before sending a user through consent.
        self.secret()?;
        let mut state = [0u8; 32];
        let mut verifier = [0u8; 32];
        let random = SystemRandom::new();
        random.fill(&mut state).map_err(|_| StoreError)?;
        random.fill(&mut verifier).map_err(|_| StoreError)?;
        let state = URL_SAFE_NO_PAD.encode(state);
        let verifier = URL_SAFE_NO_PAD.encode(verifier);
        let challenge = URL_SAFE_NO_PAD.encode(digest(&SHA256, verifier.as_bytes()).as_ref());
        let mut attempts = self.pending.lock().map_err(|_| StoreError)?;
        attempts.generation = attempts.generation.checked_add(1).ok_or(StoreError)?;
        attempts.pending = Some(Pending {
            state: state.clone(),
            verifier,
            until: Instant::now() + Duration::from_secs(600),
        });
        let mut url =
            Url::parse("https://accounts.google.com/o/oauth2/v2/auth").expect("fixed OAuth origin");
        url.query_pairs_mut()
            .append_pair("client_id", client)
            .append_pair("redirect_uri", self.redirect())
            .append_pair("response_type", "code")
            .append_pair("access_type", "offline")
            .append_pair("prompt", "consent")
            .append_pair("state", &state)
            .append_pair("code_challenge", &challenge)
            .append_pair("code_challenge_method", "S256")
            .append_pair(
                "scope",
                if uploads {
                    "https://www.googleapis.com/auth/drive"
                } else {
                    "https://www.googleapis.com/auth/drive.readonly"
                },
            );
        Ok(url)
    }

    pub fn take(&self, candidate: &str) -> Result<Option<(String, u64)>, ApiError> {
        let mut slot = self.pending.lock().map_err(|_| StoreError)?;
        if slot
            .pending
            .as_ref()
            .is_some_and(|value| value.until <= Instant::now())
        {
            slot.pending = None;
        }
        if !slot
            .pending
            .as_ref()
            .is_some_and(|value| crate::token_matches(candidate, &value.state))
        {
            return Ok(None);
        }
        Ok(slot
            .pending
            .take()
            .map(|value| (value.verifier, slot.generation)))
    }
}

#[derive(Deserialize)]
struct Callback {
    state: Option<String>,
    code: Option<String>,
    error: Option<String>,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/drive-files/connect", post(begin))
        .route("/api/drive-files/disconnect", post(disconnect))
        .route("/drive/oauth/callback", get(callback))
        .route("/drive/oauth/connected", get(connected))
        .route("/drive/oauth/incomplete", get(incomplete))
}

async fn begin(State(w): State<Workspace>) -> Result<impl IntoResponse, ApiError> {
    let drive = w.drive_files.ok_or(Failure::Input(
        "Browser setup for Google Drive is not configured.",
    ))?;
    Ok(Json(
        serde_json::json!({"url":drive.begin_oauth()?.as_str()}),
    ))
}

async fn disconnect(State(w): State<Workspace>) -> Result<impl IntoResponse, ApiError> {
    let drive = w.drive_files.ok_or(Failure::Input(
        "Browser setup for Google Drive is not configured.",
    ))?;
    drive.disconnect_oauth().await?;
    w.drive_access.clear();
    Ok(Json(serde_json::json!({"configured":false})))
}

async fn callback(State(w): State<Workspace>, Query(query): Query<Callback>) -> Response {
    let success = if let (Some(drive), Some(state)) = (w.drive_files, query.state) {
        drive
            .complete_oauth(&state, query.code.filter(|_| query.error.is_none()))
            .await
            .is_ok()
    } else {
        false
    };
    if success {
        w.drive_access.clear();
    }
    let mut response = Redirect::to(if success {
        "/drive/oauth/connected"
    } else {
        "/drive/oauth/incomplete"
    })
    .into_response();
    response.headers_mut().insert(
        HeaderName::from_static("referrer-policy"),
        HeaderValue::from_static("no-referrer"),
    );
    response
}

async fn connected() -> Html<&'static str> {
    Html(
        "<!doctype html><meta charset=utf-8><title>Google Drive connected</title><h1>Google Drive connected</h1><p>Return to the SwarmHub tab and choose Check connection.</p>",
    )
}

async fn incomplete() -> (StatusCode, Html<&'static str>) {
    (
        StatusCode::OK,
        Html(
            "<!doctype html><meta charset=utf-8><title>Google Drive setup incomplete</title><h1>Google Drive setup incomplete</h1><p>Return to SwarmHub and try again. Use a Google account that has access to the configured folder.</p>",
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expired_and_superseded_consent_cannot_store_credentials() {
        let temp = tempfile::tempdir().unwrap();
        let history = History::open_at(&temp.path().join("workspace")).unwrap();
        let setup = Setup::new(Vault::fixture(), history, 8787, "client", "folder", true);
        let issue = || {
            let url = setup.begin("client", true).ok().unwrap();
            url.query_pairs()
                .find(|(key, _)| key == "state")
                .unwrap()
                .1
                .into_owned()
        };
        let expired = issue();
        setup
            .pending
            .lock()
            .unwrap()
            .pending
            .as_mut()
            .unwrap()
            .until = Instant::now();
        assert!(setup.take(&expired).ok().flatten().is_none());
        let submitted = issue();
        let (_, generation) = setup.take(&submitted).ok().flatten().unwrap();
        issue();
        assert!(setup.save(generation, "outdated-grant".into()).is_err());
        assert!(setup.secret().ok().flatten().is_none());
    }
}
