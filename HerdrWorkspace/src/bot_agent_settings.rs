//! Per-bot launch preferences. Re-read for each new agent, including a running bot's next helper.
use crate::{
    ApiError, Workspace, bots,
    core::{Failure, valid_name},
    helpers::{self, policy::Tier},
    history::StoreError,
    runtimes::Catalog,
};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::get,
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

#[derive(Default, Serialize)]
pub(crate) struct Settings {
    pub choice: Option<Tier>,
    pub auto_mode: bool,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Edit {
    Model(ModelEdit),
    Auto(AutoEdit),
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ModelEdit {
    choice: serde_json::Value,
    #[serde(default)]
    existing_agents: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AutoEdit {
    auto_mode: bool,
    #[serde(default)]
    existing_agents: Vec<String>,
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route("/api/bot-agent-settings/{bot}", get(read).post(save))
}

pub(crate) fn for_bot(db: &Connection, id: &str) -> rusqlite::Result<Settings> {
    Ok(db
        .query_row(
            "SELECT helper_template,helper_model,auto_mode FROM bot_agent_settings WHERE bot=?1",
            [id],
            |r| {
                let template: Option<String> = r.get(0)?;
                let model: Option<String> = r.get(1)?;
                Ok(Settings {
                    choice: template
                        .zip(model)
                        .map(|(template, model)| Tier { template, model }),
                    auto_mode: r.get(2)?,
                })
            },
        )
        .optional()?
        .unwrap_or_default())
}

pub(crate) fn for_launch(db: &Connection, key: &str) -> rusqlite::Result<Settings> {
    let owner: Option<String> = db.query_row(
        "SELECT parent_bot_id FROM journal WHERE launch_key=?1",
        [key],
        |r| r.get(0),
    )?;
    if let Some(owner) = owner {
        return for_bot(db, &owner);
    }
    // Older sessions, including direct chats whose bot has since been renamed.
    match bots::of_launch(db, key)? {
        bots::Who::Bot(bot) => for_bot(db, &bot.id),
        _ => Ok(Settings::default()),
    }
}

async fn read(
    State(w): State<Workspace>,
    Path(bot): Path<String>,
) -> Result<Json<Settings>, ApiError> {
    if !bots::valid_id(&bot) {
        return Err(Failure::Input(bots::ID_SHAPE).into());
    }
    Ok(Json(
        for_bot(&*w.history.db()?, &bot).map_err(StoreError::from)?,
    ))
}

async fn save(
    State(w): State<Workspace>,
    Path(bot): Path<String>,
    Json(body): Json<Edit>,
) -> Result<Json<Settings>, ApiError> {
    let existing = match &body {
        Edit::Model(e) => &e.existing_agents,
        Edit::Auto(e) => &e.existing_agents,
    };
    if !bots::valid_id(&bot) || existing.iter().any(|agent| !valid_name(agent)) {
        return Err(Failure::Input("Invalid bot or agent name.").into());
    }
    let mut choice: Option<Tier> = None;
    if let Edit::Model(edit) = &body {
        choice = serde_json::from_value(edit.choice.clone()).map_err(|_| {
            Failure::Input("Choose a helper AI and model, or use the server settings.")
        })?;
        if let Some(tier) = &choice {
            let templates = w.core.templates().await?;
            helpers::fit(&templates, &Catalog::load(w.history.file()), tier).map_err(|_| {
                Failure::Input("This helper AI and model cannot be started on this server.")
            })?;
        }
    }
    let mut db = w.history.db()?;
    let result = (|| -> rusqlite::Result<Settings> {
        let tx = db.transaction()?;
        match &body {
            Edit::Model(_) => tx.execute(
                "INSERT INTO bot_agent_settings(bot,helper_template,helper_model) VALUES(?1,?2,?3)
                 ON CONFLICT(bot) DO UPDATE SET helper_template=excluded.helper_template,helper_model=excluded.helper_model",
                params![bot, choice.as_ref().map(|c| &c.template), choice.as_ref().map(|c| &c.model)])?,
            Edit::Auto(edit) => tx.execute(
                "INSERT INTO bot_agent_settings(bot,auto_mode) VALUES(?1,?2)
                 ON CONFLICT(bot) DO UPDATE SET auto_mode=excluded.auto_mode", params![bot,edit.auto_mode])?,
        };
        for agent in existing {
            tx.execute("UPDATE journal SET parent_bot_id=?1 WHERE parent_bot_id IS NULL
                        AND launch_key IS NOT NULL AND agent=?2", params![bot, agent])?;
        }
        let saved = for_bot(&tx,&bot)?;
        tx.commit()?;
        Ok(saved)
    })().map_err(StoreError::from)?;
    Ok(Json(result))
}

pub(crate) const AUTO_ENV: &str = "SWARMHUB_PROJECT_AUTO";
pub(crate) fn project_auto() -> bool {
    std::env::var(AUTO_ENV).as_deref() == Ok("1")
}
