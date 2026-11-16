use crate::{ApiError, Workspace, grok_import};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::{get, post},
};
use rusqlite::params;
use serde::{Deserialize, Serialize};

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Reaction {
    Like,
    Thanks,
    Celebrate,
    Eyes,
    Remove,
}

impl Reaction {
    fn value(&self) -> Option<&'static str> {
        match self {
            Self::Like => Some("like"),
            Self::Thanks => Some("thanks"),
            Self::Celebrate => Some("celebrate"),
            Self::Eyes => Some("eyes"),
            Self::Remove => None,
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Change {
    reaction: Reaction,
}

#[derive(Serialize)]
struct Saved {
    reaction: Option<&'static str>,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/reactions.js",
            get(|| async {
                (
                    [("content-type", "text/javascript; charset=utf-8")],
                    include_str!("../web/reactions.js"),
                )
            }),
        )
        .route(
            "/api/history/{core}/{address}/{created}/{message}/reaction",
            post(direct),
        )
        .route("/api/groups/{id}/messages/{message}/reaction", post(group))
}

async fn direct(
    State(w): State<Workspace>,
    Path((core, address, created, message)): Path<(String, String, u64, i64)>,
    Json(body): Json<Change>,
) -> Result<Json<Saved>, ApiError> {
    if core == grok_import::ARCHIVE_CORE {
        return Err(ApiError::NotFound);
    }
    let reaction = body.reaction.value();
    apply(
        &w,
        "UPDATE journal SET reaction=?1 WHERE id=?2 AND core_id=?3 AND address=?4 AND created_ms=?5 AND kind IN ('task','reply')",
        params![reaction, message, core, address, created],
    )?;
    Ok(Json(Saved { reaction }))
}

async fn group(
    State(w): State<Workspace>,
    Path((group, message)): Path<(i64, i64)>,
    Json(body): Json<Change>,
) -> Result<Json<Saved>, ApiError> {
    let reaction = body.reaction.value();
    apply(
        &w,
        "UPDATE group_messages SET reaction=?1 WHERE id=?2 AND group_id=?3",
        params![reaction, message, group],
    )?;
    Ok(Json(Saved { reaction }))
}

fn apply(w: &Workspace, sql: &str, values: impl rusqlite::Params) -> Result<(), ApiError> {
    let changed = w
        .history
        .db()?
        .execute(sql, values)
        .map_err(crate::history::StoreError::from)?;
    if changed == 0 {
        return Err(ApiError::NotFound);
    }
    Ok(())
}
