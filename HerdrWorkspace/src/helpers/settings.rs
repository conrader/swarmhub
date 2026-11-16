//! `/api/helper-policy`: the helper policy for a settings screen. It reads and replaces `helper-policy.json`, the
//! same file a person can edit by hand, and holds nothing in memory.

use super::{
    Unfit, fit,
    policy::{FILE, MAX_RUNNING, Policy, STOP_AFTER_RANGE, STOP_AFTER_SECONDS},
};
use crate::{Workspace, core::Failure};
use axum::{
    Json, Router,
    body::Bytes,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use serde::Serialize;
use serde_json::{Value, json};

const SHAPE: &str = "Send max_running (0 to 16), stop_after_seconds (5 to 86400) and difficulties: easy, medium or hard, each with a template and a model.";

#[derive(Serialize)]
struct Shown {
    /// The saved policy; `null` when there is none that can be applied.
    policy: Option<Policy>,
    /// Why helpers cannot start as things are, in words for the workspace's owner.
    problem: Option<String>,
    bounds: Value,
}

pub(super) fn routes() -> Router<Workspace> {
    Router::new().route("/api/helper-policy", get(show).post(save))
}

/// The first choice in `policy` that could not be started now, in words for the workspace's owner.
async fn unfit(w: &Workspace, policy: &Policy) -> Result<Option<String>, Failure> {
    let templates = w.core.templates().await?;
    let catalog = crate::runtimes::Catalog::load(w.history.file());
    Ok(policy
        .tiers()
        .find_map(|(level, tier)| match fit(&templates, &catalog, tier) {
            Ok(_) => None,
            Err(Unfit::Template) => Some(format!(
                "Herdr has no usable template named {} (chosen for {} helpers).",
                tier.template,
                level.name()
            )),
            Err(Unfit::Model) => Some(format!(
                "The template {} cannot take the model {} (chosen for {} helpers).",
                tier.template,
                tier.model,
                level.name()
            )),
        }))
}

async fn shown(w: &Workspace) -> Shown {
    let (policy, problem) = match Policy::load(w.history.file()) {
        Ok(policy) => {
            let problem = unfit(w, &policy).await.unwrap_or_else(|_| {
                Some("Herdr Core is not reachable, so the templates could not be checked.".into())
            });
            (Some(policy), problem)
        }
        Err(unusable) => (None, Some(unusable.for_owner().to_owned())),
    };
    Shown {
        policy,
        problem,
        bounds: json!({
            "max_running": {"min": 0, "max": MAX_RUNNING},
            "stop_after_seconds": {
                "min": STOP_AFTER_RANGE.start(), "max": STOP_AFTER_RANGE.end(), "default": STOP_AFTER_SECONDS
            },
        }),
    }
}

async fn show(State(w): State<Workspace>) -> Json<Shown> {
    Json(shown(&w).await)
}

fn refused(status: StatusCode, error: &str) -> Response {
    (status, Json(json!({ "error": error }))).into_response()
}

/// Saves the policy in the body when every choice in it can be started now, and answers like `GET`.
async fn save(State(w): State<Workspace>, body: Bytes) -> Response {
    let Some(policy) = Policy::parse(&body) else {
        return refused(StatusCode::UNPROCESSABLE_ENTITY, SHAPE);
    };
    match unfit(&w, &policy).await {
        Ok(None) => {}
        Ok(Some(problem)) => return refused(StatusCode::UNPROCESSABLE_ENTITY, &problem),
        Err(failure) => return failure.into_response(),
    }
    if policy.save(w.history.file()).is_err() {
        return refused(
            StatusCode::INTERNAL_SERVER_ERROR,
            &format!("The workspace could not write {FILE}. Nothing was changed."),
        );
    }
    Json(shown(&w).await).into_response()
}
