//! Per-bot launch preferences. Re-read for each new agent, including a running bot's next helper.
use crate::{
    ApiError, Workspace, bots,
    command_reviewer::Candidate,
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
    pub review_every_tool: bool,
    pub command_reviewer: crate::command_reviewer::Model,
    pub reviewer_bot_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reviewer_bots: Option<Vec<Candidate>>,
    pub auto_changed_ms: Option<i64>,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum Edit {
    Model(ModelEdit),
    Auto(AutoEdit),
    ToolReview(ToolReviewEdit),
    Reviewer(ReviewerEdit),
    BotReviewer(BotReviewerEdit),
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
struct BotReviewerEdit {
    reviewer_bot_id: String,
    #[serde(default)]
    existing_agents: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ReviewerEdit {
    command_reviewer: crate::command_reviewer::Model,
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ToolReviewEdit {
    review_every_tool: bool,
    #[serde(default)]
    existing_agents: Vec<String>,
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route("/api/bot-agent-settings/{bot}", get(read).post(save))
}

pub(crate) fn for_bot(db: &Connection, id: &str) -> rusqlite::Result<Settings> {
    Ok(db
        .query_row(
            "SELECT helper_template,helper_model,auto_mode,auto_changed_ms,command_reviewer,reviewer_bot_id,review_every_tool FROM bot_agent_settings WHERE bot=?1",
            [id],
            |r| {
                let template: Option<String> = r.get(0)?;
                let model: Option<String> = r.get(1)?;
                Ok(Settings {
                    review_every_tool: r.get(6)?,
                    reviewer_bot_id: r.get(5)?,
                    reviewer_bots: None,
                    choice: template
                        .zip(model)
                        .map(|(template, model)| Tier { template, model }),
                    auto_mode: r.get(2)?,
                    auto_changed_ms: r.get(3)?,
                    command_reviewer: crate::command_reviewer::Model::stored(&r.get::<_, String>(4)?),
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
    let settings = for_bot(&*w.history.db()?, &bot).map_err(StoreError::from)?;
    choices(&w, &bot, settings).await
}

async fn choices(
    w: &Workspace,
    owner: &str,
    mut settings: Settings,
) -> Result<Json<Settings>, ApiError> {
    let bots = bots::all(&*w.history.db()?).map_err(StoreError::from)?;
    let eligible: Vec<_> = bots.into_iter().filter(|b| b.id != owner).collect();
    let mut options = Vec::new();
    if !eligible.is_empty()
        && let Ok(templates) = w.core.templates().await
    {
        let catalog = Catalog::load(w.history.file());
        options.extend(
            eligible
                .iter()
                .filter_map(|b| Candidate::resolve(b, &templates, &catalog)),
        );
    }
    settings.reviewer_bots = Some(options);
    Ok(Json(settings))
}

async fn save(
    State(w): State<Workspace>,
    Path(bot): Path<String>,
    Json(body): Json<Edit>,
) -> Result<Json<Settings>, ApiError> {
    let existing = match &body {
        Edit::Model(e) => &e.existing_agents,
        Edit::Auto(e) => &e.existing_agents,
        Edit::ToolReview(e) => &e.existing_agents,
        Edit::Reviewer(e) => &e.existing_agents,
        Edit::BotReviewer(e) => &e.existing_agents,
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
    let templates = if let Edit::BotReviewer(edit) = &body {
        if edit.reviewer_bot_id == bot || !bots::valid_id(&edit.reviewer_bot_id) {
            return Err(Failure::Input("Choose another Claude bot on this workspace.").into());
        }
        w.core.templates().await?
    } else {
        Vec::new()
    };
    let result = {
        let mut db = w.history.db()?;
        let tx = db.transaction().map_err(StoreError::from)?;
        if let Edit::Auto(edit) = &body
            && edit.auto_mode && for_bot(&tx, &bot).map_err(StoreError::from)?.review_every_tool
        {
            return Err(ApiError::Conflict("Turn off review for every tool before enabling Auto mode."));
        }
        match &body {
            Edit::ToolReview(edit) => tx.execute(
                "INSERT INTO bot_agent_settings(bot,review_every_tool,auto_changed_ms) VALUES(?1,?2,?3)
                 ON CONFLICT(bot) DO UPDATE SET review_every_tool=excluded.review_every_tool,
                 auto_mode=CASE WHEN excluded.review_every_tool THEN 0 ELSE auto_mode END,
                 auto_changed_ms=CASE WHEN review_every_tool!=excluded.review_every_tool THEN excluded.auto_changed_ms ELSE auto_changed_ms END",
                 params![bot,edit.review_every_tool,crate::history::now()]),
            Edit::Model(_) => tx.execute(
                "INSERT INTO bot_agent_settings(bot,helper_template,helper_model) VALUES(?1,?2,?3)
                 ON CONFLICT(bot) DO UPDATE SET helper_template=excluded.helper_template,helper_model=excluded.helper_model",
                params![bot, choice.as_ref().map(|c| &c.template), choice.as_ref().map(|c| &c.model)]),
            Edit::Reviewer(edit) => tx.execute(
                "INSERT INTO bot_agent_settings(bot,command_reviewer) VALUES(?1,?2)
                 ON CONFLICT(bot) DO UPDATE SET command_reviewer=excluded.command_reviewer,reviewer_bot_id=NULL",
                params![bot, edit.command_reviewer.name()]),
            Edit::BotReviewer(edit) => {
                if bots::one(&tx, &edit.reviewer_bot_id).map_err(StoreError::from)?
                    .and_then(|b| Candidate::resolve(&b, &templates, &Catalog::load(w.history.file()))).is_none() {
                    return Err(Failure::Input("This bot is unavailable as a Claude reviewer on this workspace.").into());
                }
                tx.execute("INSERT INTO bot_agent_settings(bot,reviewer_bot_id) VALUES(?1,?2)
                    ON CONFLICT(bot) DO UPDATE SET reviewer_bot_id=excluded.reviewer_bot_id,command_reviewer='off'",
                    params![bot, edit.reviewer_bot_id])
            },
            Edit::Auto(edit) => tx.execute(
                "INSERT INTO bot_agent_settings(bot,auto_mode,auto_changed_ms) VALUES(?1,?2,?3)
                 ON CONFLICT(bot) DO UPDATE SET auto_mode=excluded.auto_mode,
                 auto_changed_ms=CASE WHEN auto_mode!=excluded.auto_mode THEN excluded.auto_changed_ms ELSE auto_changed_ms END",
                 params![bot,edit.auto_mode,crate::history::now()]),
        }.map_err(StoreError::from)?;
        for agent in existing {
            tx.execute(
                "UPDATE journal SET parent_bot_id=?1 WHERE parent_bot_id IS NULL
                        AND launch_key IS NOT NULL AND agent=?2",
                params![bot, agent],
            )
            .map_err(StoreError::from)?;
        }
        let saved = for_bot(&tx, &bot).map_err(StoreError::from)?;
        tx.commit().map_err(StoreError::from)?;
        saved
    };
    choices(&w, &bot, result).await
}

pub(crate) const AUTO_ENV: &str = "SWARMHUB_PROJECT_AUTO";
pub(crate) fn project_auto() -> bool {
    std::env::var(AUTO_ENV).as_deref() == Ok("1")
}

pub(crate) fn auto_writable_dirs() -> Vec<std::path::PathBuf> {
    auto_writable_dirs_from(
        std::env::var_os(crate::helpers::SPOOL_ENV),
        std::env::var_os("SWARMHUB_RESULTS"),
    )
}

pub(crate) fn auto_writable_dirs_from(
    spool: Option<std::ffi::OsString>,
    results: Option<std::ffi::OsString>,
) -> Vec<std::path::PathBuf> {
    let mut dirs = Vec::new();
    for value in [spool, results].into_iter().flatten() {
        let path = std::path::PathBuf::from(value);
        if path.is_absolute()
            && path
                .to_str()
                .is_some_and(|s| !s.chars().any(char::is_control))
            && std::fs::symlink_metadata(&path).is_ok_and(|meta| meta.is_dir())
            && !dirs.contains(&path)
        {
            dirs.push(path);
        }
    }
    dirs
}
