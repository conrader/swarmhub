use crate::{
    ApiError, Workspace,
    core::{Failure, Terminal},
    history::{History, StoreError},
    profile_avatars,
};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    http::StatusCode,
    routing::{get, post},
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};

#[derive(Serialize)]
pub struct Profile {
    id: i64,
    pub runtime_name: String,
    name: String,
    subtitle: String,
    avatar: String,
    pinned: bool,
    hidden: bool,
    revision: i64,
    instructions: String,
    section_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    avatar_key: Option<String>,
    sessions: Vec<Session>,
    #[serde(skip_serializing_if = "Option::is_none")]
    copied_setup: Option<CopySetup>,
    #[serde(skip_serializing_if = "Option::is_none")]
    imported_archive: Option<crate::grok_import::Archive>,
}

#[derive(Serialize)]
struct CopySetup {
    template: String,
    runtime: Option<crate::runtimes::Runtime>,
    collect_results: bool,
    routines: usize,
}

const PROFILE_FIELDS: &str = "id,runtime_name,name,subtitle,avatar,pinned,hidden,revision,instructions,section_id,avatar_key";

#[derive(Serialize)]
struct Session {
    core: String,
    address: String,
    created_ms: u64,
    template: String,
    runtime: Option<crate::runtimes::Runtime>,
    #[serde(skip_serializing_if = "Option::is_none")]
    results_folder: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Edit {
    name: String,
    subtitle: String,
    avatar: String,
    pinned: bool,
    hidden: bool,
    revision: i64,
    instructions: Option<String>,
    avatar_png: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Duplicate {
    name: String,
    revision: i64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Create {
    name: String,
    instructions: Option<String>,
}

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route(
            "/profiles.js",
            get(|| async {
                (
                    [(
                        axum::http::header::CONTENT_TYPE,
                        "text/javascript; charset=utf-8",
                    )],
                    include_str!("../web/profiles.js"),
                )
            }),
        )
        .route(
            "/avatar-upload.js",
            get(|| async {
                (
                    [(
                        axum::http::header::CONTENT_TYPE,
                        "text/javascript; charset=utf-8",
                    )],
                    include_str!("../web/avatar-upload.js"),
                )
            }),
        )
        .route(
            "/api/profiles",
            get(list)
                .post(create)
                .layer(DefaultBodyLimit::max(32 * 1024)),
        )
        .route(
            "/api/profiles/{id}",
            post(edit).layer(DefaultBodyLimit::max(profile_avatars::EDIT_BODY_LIMIT)),
        )
        .route("/api/profiles/{id}/avatar/{key}", get(profile_avatars::get))
        .route("/api/profiles/{id}/duplicate", post(duplicate))
}

async fn list(State(w): State<Workspace>) -> Result<Json<Vec<Profile>>, ApiError> {
    let db = w.history.db()?;
    let mut statement = db
        .prepare(&format!(
            "SELECT {PROFILE_FIELDS} FROM profiles ORDER BY pinned DESC,id DESC"
        ))
        .map_err(StoreError::from)?;
    let mut profiles = statement
        .query_map([], profile_row)
        .and_then(|rows| rows.collect::<Result<Vec<_>, _>>())
        .map_err(StoreError::from)?;
    let mut sessions = db
        .prepare(
            "SELECT core_id,address,created_ms,launch_template,launch_runtime,
                    (SELECT launch FROM result_folders WHERE launch=journal.id) FROM journal
                  WHERE profile_id=?1 AND launch_key IS NOT NULL AND launch_template IS NOT NULL
                  ORDER BY id DESC LIMIT 40",
        )
        .map_err(StoreError::from)?;
    let mut imported = crate::grok_import::for_profiles(&db)?;
    for profile in &mut profiles {
        profile.imported_archive = imported.remove(&profile.id);
        profile.copied_setup = copy_setup(&db, profile.id)?;
        profile.sessions = sessions
            .query_map([profile.id], |row| {
                Ok(Session {
                    core: row.get(0)?,
                    address: row.get(1)?,
                    created_ms: row.get(2)?,
                    template: row.get(3)?,
                    runtime: row
                        .get::<_, Option<String>>(4)?
                        .and_then(|runtime| serde_json::from_str(&runtime).ok()),
                    results_folder: row.get::<_, Option<i64>>(5)?.and_then(|record| {
                        crate::results::path(&w.history, record)
                            .to_str()
                            .map(str::to_owned)
                    }),
                })
            })
            .and_then(|rows| rows.collect::<Result<_, _>>())
            .map_err(StoreError::from)?;
    }
    Ok(Json(profiles))
}

fn copy_setup(db: &Connection, profile: i64) -> Result<Option<CopySetup>, StoreError> {
    Ok(db
        .query_row(
            "SELECT template,runtime,collect_results,
           (SELECT count(*) FROM profile_copy_routines WHERE profile=?1)
         FROM profile_copy_setup WHERE profile=?1",
            [profile],
            |row| {
                Ok(CopySetup {
                    template: row.get(0)?,
                    runtime: row
                        .get::<_, Option<String>>(1)?
                        .and_then(|text| serde_json::from_str(&text).ok()),
                    collect_results: row.get(2)?,
                    routines: row.get(3)?,
                })
            },
        )
        .optional()?)
}

async fn duplicate(
    State(w): State<Workspace>,
    Path(source): Path<i64>,
    Json(body): Json<Duplicate>,
) -> Result<(StatusCode, Json<Profile>), ApiError> {
    let name = display_name(&body.name)?;
    Ok((
        StatusCode::CREATED,
        Json(w.history.copy_profile(source, body.revision, name)?),
    ))
}

async fn create(
    State(w): State<Workspace>,
    Json(body): Json<Create>,
) -> Result<(StatusCode, Json<Profile>), ApiError> {
    let name = display_name(&body.name)?;
    let instructions = validate_instructions(body.instructions.as_deref().unwrap_or_default())?;
    Ok((
        StatusCode::CREATED,
        Json(w.history.create_profile(name, instructions)?),
    ))
}

pub(crate) fn display_name(input: &str) -> Result<&str, Failure> {
    let name = input.trim();
    if name.is_empty() || name.chars().count() > 60 || input.chars().any(char::is_control) {
        return Err(Failure::Input("Enter a display name up to 60 characters."));
    }
    Ok(name)
}

pub(crate) fn validate_subtitle(input: &str) -> Result<&str, Failure> {
    let subtitle = input.trim();
    if subtitle.chars().count() > 80 || input.chars().any(char::is_control) {
        return Err(Failure::Input("Enter a label up to 80 characters."));
    }
    Ok(subtitle)
}

async fn edit(
    State(w): State<Workspace>,
    Path(id): Path<i64>,
    Json(body): Json<Edit>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let name = display_name(&body.name)?;
    let subtitle = validate_subtitle(&body.subtitle)?;
    if !matches!(
        body.avatar.as_str(),
        "initial" | "spark" | "layers" | "target" | "terminal" | "image"
    ) {
        return Err(Failure::Input("Choose one of the available avatars.").into());
    }
    let instructions = body
        .instructions
        .as_deref()
        .map(validate_instructions)
        .transpose()?;
    if body.avatar_png.is_some() && body.avatar != "image" {
        return Err(Failure::Input("Choose Uploaded image before adding a crop.").into());
    }
    let png = body
        .avatar_png
        .as_deref()
        .map(profile_avatars::normalize)
        .transpose()?;
    let mut db = w.history.db()?;
    let txn = db
        .transaction_with_behavior(TransactionBehavior::Immediate)
        .map_err(StoreError::from)?;
    if body.avatar == "image"
        && png.is_none()
        && txn
            .query_row(
                "SELECT avatar_key IS NULL FROM profiles WHERE id=?1 AND revision=?2",
                params![id, body.revision],
                |row| row.get::<_, bool>(0),
            )
            .optional()
            .map_err(StoreError::from)?
            == Some(true)
    {
        return Err(Failure::Input("Choose an image before saving.").into());
    }
    let count = txn.execute(
        "UPDATE profiles SET name=?2,subtitle=?3,avatar=?4,pinned=?5,hidden=?6,revision=revision+1,
         instructions=coalesce(?8,instructions),
         avatar_key=CASE WHEN ?4!='image' THEN NULL WHEN ?9 THEN lower(hex(randomblob(16))) ELSE avatar_key END
         WHERE id=?1 AND revision=?7",
        params![id, name, subtitle, body.avatar, body.pinned, body.hidden, body.revision, instructions,png.is_some()],
    ).map_err(StoreError::from)?;
    if count == 0 {
        return Err(ApiError::Conflict(
            "This profile changed. Reopen the editor to see its latest settings.",
        ));
    }
    if let Some(png) = png {
        txn.execute(
            "INSERT INTO profile_avatars(profile,png) VALUES (?1,?2) ON CONFLICT(profile) DO UPDATE SET png=excluded.png",
            params![id,png],
        ).map_err(StoreError::from)?;
    } else if body.avatar != "image" {
        txn.execute("DELETE FROM profile_avatars WHERE profile=?1", [id])
            .map_err(StoreError::from)?;
    }
    txn.commit().map_err(StoreError::from)?;
    Ok(Json(serde_json::json!({"saved":true})))
}

fn profile_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Profile> {
    Ok(Profile {
        id: row.get(0)?,
        runtime_name: row.get(1)?,
        name: row.get(2)?,
        subtitle: row.get(3)?,
        avatar: row.get(4)?,
        pinned: row.get(5)?,
        hidden: row.get(6)?,
        revision: row.get(7)?,
        instructions: row.get(8)?,
        section_id: row.get(9)?,
        avatar_key: row.get(10)?,
        sessions: Vec::new(),
        copied_setup: None,
        imported_archive: None,
    })
}

impl History {
    fn create_profile(&self, name: &str, instructions: &str) -> Result<Profile, StoreError> {
        self.create_configured_profile(name, "", "initial", instructions)
    }

    pub(crate) fn create_configured_profile(
        &self,
        name: &str,
        subtitle: &str,
        avatar: &str,
        instructions: &str,
    ) -> Result<Profile, StoreError> {
        Ok(self.db()?.query_row(
            &format!("INSERT INTO profiles (runtime_name,name,subtitle,avatar,instructions)
                      VALUES ('agent-' || lower(hex(randomblob(12))),?1,?2,?3,?4) RETURNING {PROFILE_FIELDS}"),
            params![name, subtitle, avatar, instructions],
            profile_row,
        )?)
    }

    fn copy_profile(&self, source: i64, revision: i64, name: &str) -> Result<Profile, ApiError> {
        let mut db = self.db()?;
        let txn = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(StoreError::from)?;
        let mut profile = txn.query_row(
            &format!("INSERT INTO profiles (runtime_name,name,subtitle,avatar,instructions,avatar_key)
                SELECT substr(runtime_name,1,12) || '-copy-' || lower(hex(randomblob(6))),?2,subtitle,avatar,instructions,avatar_key
                FROM profiles WHERE id=?1 AND revision=?3 RETURNING {PROFILE_FIELDS}"),
            params![source,name,revision], profile_row,
        ).optional().map_err(StoreError::from)?.ok_or(ApiError::Conflict(
            "This profile changed. Reopen the copy dialog to see its latest settings."
        ))?;
        let id = profile.id;
        if profile.avatar_key.is_some() {
            txn.execute(
                "INSERT INTO profile_avatars(profile,png) SELECT ?1,png FROM profile_avatars WHERE profile=?2",
                params![id,source],
            ).map_err(StoreError::from)?;
        }
        // Profiles with a session use the most recent launch defaults. Copies that
        // have not started can themselves be copied from their saved setup.
        let latest: Option<(i64, String, String, u64)> = txn
            .query_row(
                "SELECT id,core_id,address,created_ms FROM journal
             WHERE profile_id=?1 AND launch_key IS NOT NULL AND launch_template IS NOT NULL
             ORDER BY id DESC LIMIT 1",
                [source],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )
            .optional()
            .map_err(StoreError::from)?;
        if let Some((launch, core, address, created)) = latest {
            txn.execute(
                "INSERT INTO profile_copy_setup
                 SELECT ?1,launch_template,launch_runtime,EXISTS(SELECT 1 FROM result_folders WHERE launch=?2)
                 FROM journal WHERE id=?2",
                params![id,launch],
            ).map_err(StoreError::from)?;
            txn.execute(
                "INSERT INTO profile_copy_routines(profile,name,task,schedule)
                 SELECT ?1,name,task,schedule FROM routines
                  WHERE core=?2 AND address=?3 AND created_ms=?4 AND state!='archived' ORDER BY id",
                params![id, core, address, created],
            )
            .map_err(StoreError::from)?;
            txn.execute(
                "INSERT INTO profile_copy_disabled_skills
                 SELECT ?1,skill FROM disabled_skills WHERE core=?2 AND address=?3 AND created_ms=?4",
                params![id,core,address,created],
            ).map_err(StoreError::from)?;
        } else {
            txn.execute(
                "INSERT INTO profile_copy_setup
                 SELECT ?1,template,runtime,collect_results FROM profile_copy_setup WHERE profile=?2",
                params![id,source],
            ).map_err(StoreError::from)?;
            txn.execute(
                "INSERT INTO profile_copy_routines(profile,name,task,schedule)
                 SELECT ?1,name,task,schedule FROM profile_copy_routines WHERE profile=?2 ORDER BY id",
                params![id,source],
            ).map_err(StoreError::from)?;
            txn.execute(
                "INSERT INTO profile_copy_disabled_skills
                 SELECT ?1,skill FROM profile_copy_disabled_skills WHERE profile=?2",
                params![id, source],
            )
            .map_err(StoreError::from)?;
        }
        profile.copied_setup = copy_setup(&txn, id)?;
        txn.commit().map_err(StoreError::from)?;
        Ok(profile)
    }

    pub fn saved_instructions(&self, id: i64, revision: i64) -> Result<Option<String>, StoreError> {
        Ok(self
            .db()?
            .query_row(
                "SELECT instructions FROM profiles WHERE id=?1 AND revision=?2",
                params![id, revision],
                |row| row.get(0),
            )
            .optional()?)
    }

    pub fn profile_runtime_name(&self, id: i64) -> Result<Option<String>, StoreError> {
        Ok(self
            .db()?
            .query_row(
                "SELECT runtime_name FROM profiles WHERE id=?1",
                [id],
                |row| row.get(0),
            )
            .optional()?)
    }

    pub fn session_profile(
        &self,
        core: &str,
        terminal: &Terminal,
    ) -> Result<Option<i64>, StoreError> {
        Ok(self
            .db()?
            .query_row(
                "SELECT profile_id FROM journal WHERE core_id=?1 AND launch_key=?2",
                params![core, terminal.launch_key()],
                |row| row.get::<_, Option<i64>>(0),
            )
            .optional()?
            .flatten())
    }

    pub fn link_profile(&self, core: &str, terminal: &Terminal) -> Result<(), StoreError> {
        let (Some(key), Some(template)) = (terminal.launch_key(), terminal.template.as_deref())
        else {
            return Ok(());
        };
        let mut db = self.db()?;
        let pending_link = db.query_row(
            "SELECT id,profile_id,agent,coalesce(launch_instructions,'') FROM journal
             WHERE core_id=?1 AND launch_key=?2 AND address=?3 AND created_ms=?4 AND launch_template IS NULL",
            params![core, key, terminal.address, terminal.created_ms],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<i64>>(1)?, row.get::<_, String>(2)?, row.get::<_, String>(3)?)),
        ).optional()?;
        if let Some((row_id, profile, name, instructions)) = pending_link {
            let txn = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
            let id = match profile {
                Some(id) => id,
                None => txn.query_row(
                    "INSERT INTO profiles (runtime_name,name,instructions) VALUES (?1,?1,?2) RETURNING id",
                    params![name, instructions],
                    |row| row.get(0),
                )?,
            };
            txn.execute(
                "UPDATE journal SET profile_id=?2,launch_template=?3 WHERE id=?1",
                params![row_id, id, template],
            )?;
            if profile.is_some() {
                apply_copy(&txn, id, core, terminal)?;
            }
            txn.commit()?;
        }
        Ok(())
    }
}

fn apply_copy(
    db: &Connection,
    profile: i64,
    core: &str,
    terminal: &Terminal,
) -> rusqlite::Result<()> {
    db.execute(
        "INSERT INTO routines (core,address,created_ms,agent,name,task,schedule,state)
         SELECT ?2,?3,?4,?5,name,task,schedule,'paused' FROM profile_copy_routines WHERE profile=?1 ORDER BY id",
        params![profile,core,terminal.address,terminal.created_ms,terminal.display_name()],
    )?;
    db.execute(
        "INSERT OR IGNORE INTO disabled_skills (skill,core,address,created_ms)
         SELECT skill,?2,?3,?4 FROM profile_copy_disabled_skills WHERE profile=?1",
        params![profile, core, terminal.address, terminal.created_ms],
    )?;
    db.execute("DELETE FROM profile_copy_setup WHERE profile=?1", [profile])?;
    Ok(())
}

pub fn validate_instructions(text: &str) -> Result<&str, Failure> {
    if text.len() > 6 * 1024
        || text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\n' | '\t'))
    {
        return Err(Failure::Input(
            "Use up to 6 KiB of plain text for standing instructions.",
        ));
    }
    Ok(text.trim())
}

pub fn launch_message(task: &str, instructions: &str) -> Result<String, Failure> {
    if instructions.is_empty() {
        return Ok(task.to_owned());
    }
    // Some interactive templates accept one line at a time. Preserve line
    // breaks inside the JSON text without turning them into new terminal input.
    let context = serde_json::json!({"standing_instructions":instructions,"current_task":task});
    let message =
        format!("Apply the standing_instructions in this JSON to the current_task: {context}");
    crate::core::validate_task(&message).map_err(|_| {
        Failure::Input("The first task and standing instructions together must fit within 16 KiB.")
    })?;
    Ok(message)
}
