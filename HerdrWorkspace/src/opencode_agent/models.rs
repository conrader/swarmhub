//! Native model selection on an opted-in, interactive OpenCode session.
use super::{first_task::ApiSession, follow_up};
use crate::{
    ApiError, Workspace,
    core::{Failure, Terminal},
    runtimes::ModelAgent,
};
use axum::{
    Json, Router,
    extract::{Path, Query, State},
    routing::get,
};
use serde::{
    Deserialize, Serialize,
    de::{DeserializeOwned, IgnoredAny},
};
use std::{collections::BTreeMap, io};

#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct ModelState {
    /// Explicit selection in the session. Absent means OpenCode chooses.
    pub current: Option<String>,
    pub default_model: Option<String>,
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub enum ModelChange {
    Select { id: String },
    Reset,
}

impl ModelChange {
    pub(super) fn valid(&self) -> bool {
        match self {
            Self::Select { id } => ModelAgent::OpenCode.accepts(id),
            Self::Reset => true,
        }
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(tag = "operation", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum ModelOperation {
    Read,
    Change {
        change: ModelChange,
        expected_current: Option<String>,
        expected_default: Option<String>,
    },
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "result", rename_all = "snake_case", deny_unknown_fields)]
pub(super) enum ModelResult {
    State { state: ModelState },
    Blocked,
    Busy,
    NoDefault,
    Changed,
    Unavailable,
    Uncertain,
}

#[derive(Deserialize, Serialize)]
struct ModelRef {
    #[serde(rename = "providerID")]
    provider: String,
    id: String,
}

impl ModelRef {
    fn parse(id: &str) -> Option<Self> {
        let (provider, id) = id.split_once('/')?;
        Some(Self {
            provider: provider.to_owned(),
            id: id.to_owned(),
        })
    }

    fn full_name(self) -> Option<String> {
        let name = format!("{}/{}", self.provider, self.id);
        ModelAgent::OpenCode.accepts(&name).then_some(name)
    }
}

const MAX_RESPONSE: usize = 64 * 1024;

impl ApiSession {
    async fn read_model_data<T: DeserializeOwned>(
        &self,
        password: &str,
        path: &str,
    ) -> io::Result<T> {
        #[derive(Deserialize)]
        struct Data<T> {
            data: T,
        }
        let error = || io::Error::other("OpenCode's session model could not be checked.");
        let url = self.base.join(path).map_err(|_| error())?;
        let mut response = self
            .client
            .get(url)
            .basic_auth("opencode", Some(password))
            .send()
            .await
            .map_err(|_| error())?;
        if response.status() != reqwest::StatusCode::OK {
            return Err(error());
        }
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|_| error())? {
            if body.len() + chunk.len() > MAX_RESPONSE {
                return Err(error());
            }
            body.extend_from_slice(&chunk);
        }
        serde_json::from_slice::<Data<T>>(&body)
            .map(|envelope| envelope.data)
            .map_err(|_| error())
    }

    async fn current_model(&self, password: &str) -> io::Result<Option<String>> {
        #[derive(Deserialize)]
        struct Selected {
            id: String,
            model: Option<ModelRef>,
        }
        let selected: Selected = self
            .read_model_data(password, &format!("api/session/{}", self.id))
            .await?;
        if selected.id != self.id {
            return Err(io::Error::other("OpenCode returned a different session."));
        }
        selected
            .model
            .map(|model| {
                model
                    .full_name()
                    .ok_or_else(|| io::Error::other("Invalid OpenCode model identifier."))
            })
            .transpose()
    }

    async fn default_model(&self, password: &str) -> Option<String> {
        self.read_model_data::<Option<ModelRef>>(password, "api/model/default")
            .await
            .ok()
            .flatten()
            .and_then(ModelRef::full_name)
    }

    pub(super) async fn model_state(&self, password: &str) -> ModelResult {
        let (current, default_model) =
            tokio::join!(self.current_model(password), self.default_model(password));
        match current {
            Ok(current) => ModelResult::State {
                state: ModelState {
                    current,
                    default_model,
                },
            },
            Err(_) => ModelResult::Unavailable,
        }
    }

    pub(super) async fn change_model(
        &self,
        password: &str,
        change: ModelChange,
        expected_current: Option<String>,
        expected_default: Option<String>,
    ) -> ModelResult {
        if !change.valid() {
            return ModelResult::Unavailable;
        }
        let inbox = format!("api/session/{}/inbox", self.id);
        let (attention, active, queued, default_model, current) = tokio::join!(
            self.attention(password),
            self.read_model_data::<BTreeMap<String, IgnoredAny>>(password, "api/session/active"),
            self.read_model_data::<Vec<IgnoredAny>>(password, &inbox),
            self.default_model(password),
            self.current_model(password),
        );
        if matches!(attention, Ok(true)) {
            return ModelResult::Blocked;
        }
        let (Ok(false), Ok(active), Ok(queued), Ok(current)) = (attention, active, queued, current)
        else {
            return ModelResult::Unavailable;
        };
        if active.contains_key(&self.id) || !queued.is_empty() {
            return ModelResult::Busy;
        }
        if current != expected_current {
            return ModelResult::Changed;
        }
        let target = match change {
            ModelChange::Select { id } => id,
            ModelChange::Reset => {
                let Some(default) = default_model.clone() else {
                    return ModelResult::NoDefault;
                };
                if Some(&default) != expected_default.as_ref() {
                    return ModelResult::Changed;
                }
                default
            }
        };
        let Some(model) = ModelRef::parse(&target) else {
            return ModelResult::Unavailable;
        };
        let Ok(url) = self.base.join(&format!("api/session/{}/model", self.id)) else {
            return ModelResult::Unavailable;
        };
        #[derive(Serialize)]
        struct Selection {
            model: ModelRef,
        }
        let Ok(body) = serde_json::to_string(&Selection { model }) else {
            return ModelResult::Unavailable;
        };
        let response = self
            .client
            .post(url)
            .basic_auth("opencode", Some(password))
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .body(body)
            .send()
            .await;
        // A lost acknowledgement must never trigger another mutation.
        if !response.is_ok_and(|response| response.status() == reqwest::StatusCode::NO_CONTENT) {
            return ModelResult::Uncertain;
        }
        if self
            .current_model(password)
            .await
            .as_ref()
            .ok()
            .and_then(Option::as_ref)
            != Some(&target)
        {
            return ModelResult::Uncertain;
        }
        ModelResult::State {
            state: ModelState {
                current: Some(target),
                default_model,
            },
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct QueryCore {
    expected_core: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChangeBody {
    expected_core: String,
    expected_current: Option<String>,
    expected_default: Option<String>,
    change: ModelChange,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/opencode-models.js",
            get(|| async {
                (
                    [(
                        axum::http::header::CONTENT_TYPE,
                        "text/javascript; charset=utf-8",
                    )],
                    include_str!("../../web/opencode-models.js"),
                )
            }),
        )
        .route("/api/agents/{id}/{created}/model", get(read).post(change))
}

async fn checked(
    w: &Workspace,
    address: &str,
    created: u64,
    expected_core: &str,
) -> Result<Terminal, ApiError> {
    let hello = w.core.identify().await?;
    if hello.core.id != expected_core {
        return Err(ApiError::Conflict(
            "Herdr Core changed. Reopen this session before changing its model.",
        ));
    }
    let agent = w.core.agent(address, created).await?;
    agent.require_live()?;
    if !agent.uses_opencode_api() {
        return Err(Failure::Input(
            "Model changes require an OpenCode session started with API delivery.",
        )
        .into());
    }
    Ok(agent)
}

async fn read(
    State(w): State<Workspace>,
    Path((address, created)): Path<(String, u64)>,
    Query(query): Query<QueryCore>,
) -> Result<Json<ModelState>, ApiError> {
    let agent = checked(&w, &address, created, &query.expected_core).await?;
    Ok(Json(
        follow_up::model_state(w.history.file(), &agent).await?,
    ))
}

async fn change(
    State(w): State<Workspace>,
    Path((address, created)): Path<(String, u64)>,
    Json(body): Json<ChangeBody>,
) -> Result<Json<ModelState>, ApiError> {
    if !body.change.valid()
        || [&body.expected_current, &body.expected_default]
            .into_iter()
            .any(|id| {
                id.as_deref()
                    .is_some_and(|id| !ModelAgent::OpenCode.accepts(id))
            })
    {
        return Err(Failure::Input("Enter an exact OpenCode provider/model ID.").into());
    }
    let agent = checked(&w, &address, created, &body.expected_core).await?;
    if agent
        .status
        .as_ref()
        .is_some_and(|status| matches!(status.state.as_str(), "working" | "blocked"))
    {
        return Err(ApiError::Conflict(
            "Wait for OpenCode's current work or pending decision before changing its model.",
        ));
    }
    Ok(Json(
        follow_up::change_model(
            w.history.file(),
            &agent,
            body.change,
            body.expected_current,
            body.expected_default,
        )
        .await?,
    ))
}
