use crate::{
    ApiError, Workspace,
    core::Failure,
    profiles::{Profile, display_name, validate_instructions, validate_subtitle},
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State, rejection::JsonRejection},
    http::{StatusCode, header},
    routing::{get, post},
};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};

const MAX_TEMPLATE: usize = 48 * 1024;

#[derive(Serialize, Deserialize)]
enum Format {
    #[serde(rename = "swarmhub-agent-template/v1")]
    V1,
}

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum Avatar {
    Initial,
    Spark,
    Layers,
    Target,
    Terminal,
}

impl Avatar {
    fn from_profile(value: &str) -> Self {
        match value {
            "spark" => Self::Spark,
            "layers" => Self::Layers,
            "target" => Self::Target,
            "terminal" => Self::Terminal,
            _ => Self::Initial,
        }
    }

    fn into_str(self) -> &'static str {
        match self {
            Self::Initial => "initial",
            Self::Spark => "spark",
            Self::Layers => "layers",
            Self::Target => "target",
            Self::Terminal => "terminal",
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AgentTemplate {
    format: Format,
    name: String,
    subtitle: String,
    avatar: Avatar,
    instructions: String,
}

impl AgentTemplate {
    fn normalize(mut self) -> Result<Self, ApiError> {
        self.name = display_name(&self.name)?.to_owned();
        self.subtitle = validate_subtitle(&self.subtitle)?.to_owned();
        // Browser editors use LF. Support copies written by CRLF-based editors too.
        self.instructions = self.instructions.replace("\r\n", "\n");
        validate_instructions(&self.instructions)?;
        Ok(self)
    }
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/profiles/{id}/agent-template", get(export))
        .route(
            "/api/profile-templates/preview",
            post(preview).layer(DefaultBodyLimit::max(MAX_TEMPLATE)),
        )
        .route(
            "/api/profile-templates/import",
            post(import).layer(DefaultBodyLimit::max(MAX_TEMPLATE)),
        )
        .route(
            "/portable-profiles.js",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
                    include_str!("../web/portable-profiles.js"),
                )
            }),
        )
}

async fn export(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
) -> Result<Json<AgentTemplate>, ApiError> {
    let template = w
        .history
        .db()?
        .query_row(
            "SELECT name,subtitle,avatar,instructions FROM profiles WHERE id=?1",
            [id],
            |row| {
                Ok(AgentTemplate {
                    format: Format::V1,
                    name: row.get(0)?,
                    subtitle: row.get(1)?,
                    avatar: Avatar::from_profile(row.get_ref(2)?.as_str()?),
                    instructions: row.get(3)?,
                })
            },
        )
        .optional()
        .map_err(crate::history::StoreError::from)?
        .ok_or(ApiError::NotFound)?;
    Ok(Json(template.normalize()?))
}

fn decode(input: Result<Json<AgentTemplate>, JsonRejection>) -> Result<AgentTemplate, ApiError> {
    match input {
        Ok(Json(template)) => template.normalize(),
        Err(error) if error.status() == StatusCode::PAYLOAD_TOO_LARGE => Err(
            ApiError::PayloadTooLarge("Use an agent template up to 48 KiB."),
        ),
        Err(_) => Err(Failure::Input(
            "Choose a SwarmHub agent template in the supported v1 JSON format.",
        )
        .into()),
    }
}

async fn preview(
    input: Result<Json<AgentTemplate>, JsonRejection>,
) -> Result<Json<AgentTemplate>, ApiError> {
    Ok(Json(decode(input)?))
}

async fn import(
    State(w): State<Workspace>,
    input: Result<Json<AgentTemplate>, JsonRejection>,
) -> Result<(StatusCode, Json<Profile>), ApiError> {
    let template = decode(input)?;
    let agent = w.history.create_configured_profile(
        &template.name,
        &template.subtitle,
        template.avatar.into_str(),
        &template.instructions,
    )?;
    Ok((StatusCode::CREATED, Json(agent)))
}
