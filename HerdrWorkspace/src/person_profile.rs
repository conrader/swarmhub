//! Workspace-local person settings. Only the zone and place names go to bots.

use crate::{
    ApiError, Workspace, bots,
    core::{Failure, validate_task},
    history::{History, StoreError, now},
};
use axum::{
    Json, Router, body::Bytes, extract::State, http::header, response::IntoResponse, routing::get,
};
use chrono::{DateTime, Offset, Utc};
use chrono_tz::Tz;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

const CONTEXT_START: &str = "[SwarmHub person profile]";
const CONTEXT_END: &str = "[/SwarmHub person profile]";
const HISTORY_LIMIT: i64 = 20;
const INVALID: &str = "Enter an IANA time zone and a valid location.";

#[derive(Clone, Copy, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
enum Source {
    Manual,
    Device,
}

#[derive(Clone, Deserialize, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Location {
    city: String,
    region: Option<String>,
    country: Option<String>,
    latitude: Option<f64>,
    longitude: Option<f64>,
    source: Source,
}

#[derive(Default, Serialize)]
struct Profile {
    timezone: Option<Tz>,
    location: Option<Location>,
    updated_at: Option<i64>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum LocationChange {
    Set { place: Location },
    Clear,
    ClearDevice,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Update {
    timezone: Option<Tz>,
    location: Option<LocationChange>,
}

fn place_name(raw: &str) -> Option<String> {
    // Keep each field to one line in the bot context. Reject invisible controls,
    // including direction overrides, and require some actual place-name text.
    let name = raw.trim();
    (name.chars().count() <= 80
        && name.chars().any(char::is_alphanumeric)
        && name.chars().all(|c| {
            c.is_alphanumeric()
                || matches!(c, '\u{0300}'..='\u{036f}' | '\u{0e31}'..='\u{0e4e}')
                || " .,'’‐‑-–()&".contains(c)
        }))
    .then(|| name.to_owned())
}

fn coarse(value: f64, limit: f64) -> Option<f64> {
    ((-limit..=limit).contains(&value)).then(|| (value * 10.0).round() / 10.0)
}

impl Location {
    fn validated(mut self) -> Option<Self> {
        self.city = place_name(&self.city)?;
        if let Some(region) = &mut self.region {
            *region = place_name(region)?;
        }
        if let Some(country) = &mut self.country {
            *country = place_name(country)?;
        }
        match (self.latitude, self.longitude) {
            (Some(lat), Some(lon)) => {
                self.latitude = Some(coarse(lat, 90.0)?);
                self.longitude = Some(coarse(lon, 180.0)?);
            }
            (None, None) => {}
            _ => return None,
        }
        Some(self)
    }

    fn label(&self) -> String {
        [
            Some(self.city.as_str()),
            self.region.as_deref(),
            self.country.as_deref(),
        ]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(", ")
    }
}

fn profiles(db: &Connection, limit: i64) -> rusqlite::Result<Vec<Profile>> {
    db.prepare_cached(
        "SELECT timezone,location,updated_at FROM person_profile_history ORDER BY id DESC LIMIT ?1",
    )?
    .query_map([limit], |row| {
        let zone: Option<String> = row.get(0)?;
        let place: Option<String> = row.get(1)?;
        Ok(Profile {
            timezone: zone.and_then(|zone| zone.parse().ok()),
            location: place.and_then(|place| serde_json::from_str(&place).ok()),
            updated_at: Some(row.get(2)?),
        })
    })?
    .collect()
}

pub(crate) fn zone(db: &Connection, fallback: Tz) -> rusqlite::Result<Tz> {
    let saved: Option<String> = db
        .query_row(
            "SELECT timezone FROM person_profile_history ORDER BY id DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?
        .flatten();
    Ok(saved.and_then(|zone| zone.parse().ok()).unwrap_or(fallback))
}

pub(crate) fn effective_timezone(db: &Connection) -> rusqlite::Result<Tz> {
    zone(db, bots::Settings::load(db)?.zone())
}

fn save(ctx: &bots::Ctx<'_>, update: Update) -> rusqlite::Result<Result<Profile, &'static str>> {
    let mut profile = profiles(ctx.db, 1)?.pop().unwrap_or_default();
    let old_zone = profile.timezone.unwrap_or(ctx.set.zone());
    let timezone = update.timezone.or(profile.timezone);
    let location = match update.location {
        Some(LocationChange::Set { place }) => match place.validated() {
            Some(place) => Some(place),
            None => return Ok(Err(INVALID)),
        },
        Some(LocationChange::Clear) => None,
        Some(LocationChange::ClearDevice) => profile
            .location
            .clone()
            .filter(|place| place.source != Source::Device),
        None => profile.location.clone(),
    };
    if (timezone, &location) == (profile.timezone, &profile.location) {
        return Ok(Ok(profile));
    }
    let city_changed =
        profile.location.as_ref().map(Location::label) != location.as_ref().map(Location::label);
    profile.timezone = timezone;
    profile.location = location;
    profile.updated_at = Some(ctx.now);
    ctx.db.execute(
        "INSERT INTO person_profile_history(timezone,location,updated_at) VALUES (?1,?2,?3)",
        params![
            timezone.map(|zone| zone.to_string()),
            profile
                .location
                .as_ref()
                .map(|value| serde_json::to_string(value).expect("validated location")),
            ctx.now
        ],
    )?;
    ctx.db.execute(
        "DELETE FROM person_profile_history WHERE id NOT IN
           (SELECT id FROM person_profile_history ORDER BY id DESC LIMIT ?1)",
        [HISTORY_LIMIT],
    )?;
    let new_zone = timezone.unwrap_or(ctx.set.zone());
    timezone_changed(ctx.db, ctx.now, old_zone, new_zone, city_changed)?;
    Ok(Ok(profile))
}

pub(crate) fn timezone_changed(
    db: &Connection,
    at: i64,
    before: Tz,
    after: Tz,
    city_changed: bool,
) -> rusqlite::Result<()> {
    if before != after {
        crate::routines::rezone(db, at, after)?;
        bots::rezone_plans(db, at, after)?;
    }
    bots::profile_moved(db, at, before, after, city_changed)
}

/// Apply the old workspace default while it is still available during migration.
/// Old absolute deadlines lack the wall-clock intent needed to move them.
pub(crate) fn migrate(db: &Connection) -> rusqlite::Result<()> {
    let default = bots::Settings::load(db)?.zone().to_string();
    for table in ["routines", "bot_checkins"] {
        db.execute(
            &format!(
                "UPDATE {table} SET schedule=json_remove(schedule,'$.timezone')
                       WHERE json_extract(schedule,'$.kind')='daily'
                         AND json_extract(schedule,'$.timezone')=?1"
            ),
            [&default],
        )?;
    }
    Ok(())
}

fn context_line(profile: &Profile, zone: Tz, at: DateTime<Utc>) -> String {
    let seconds = at.with_timezone(&zone).offset().fix().local_minus_utc();
    let sign = if seconds < 0 { '-' } else { '+' };
    let hours = seconds.abs() / 3600;
    let minutes = seconds.abs() / 60 % 60;
    let offset = if minutes == 0 {
        format!("{sign}{hours}")
    } else {
        format!("{sign}{hours}:{minutes:02}")
    };
    let place = profile
        .location
        .as_ref()
        .map_or_else(String::new, |place| format!(", location {}", place.label()));
    format!("The user's time zone is {zone} (currently UTC{offset}){place}.")
}

/// The injected line is for the live prompt only. Keep saved task text and API
/// errors independent of the person's location.
pub(crate) fn prompt(history: &History, agent: &str, text: String) -> Result<String, Failure> {
    let context = (|| -> Result<_, StoreError> {
        let db = history.db()?;
        if bots::of_agent(&db, agent)?.is_none() {
            return Ok(None);
        }
        let profile = profiles(&db, 1)?.pop().unwrap_or_default();
        let zone = profile
            .timezone
            .unwrap_or(bots::Settings::load(&db)?.zone());
        Ok(Some(context_line(
            &profile,
            zone,
            DateTime::from_timestamp_millis(now()).expect("workspace time"),
        )))
    })()
    .map_err(|_| Failure::Input("Could not read the workspace profile."))?;
    let Some(context) = context else {
        return Ok(text);
    };
    let prompt = format!(
        "{text}\n\n{CONTEXT_START} {context} Use this time zone for local times. Keep the location private. {CONTEXT_END}"
    );
    validate_task(&prompt)
        .map_err(|_| Failure::Input("Leave room in the task for the workspace profile."))?;
    Ok(prompt)
}

/// Core's terminal screen may echo what was typed, including a wrapped profile
/// line. The screen and its saved snapshots should omit the injected block.
pub(crate) fn strip_prompt_context(mut text: String) -> String {
    while let Some(end) = text.find(CONTEXT_END) {
        // A bounded screen read can begin in the middle of the injected block.
        let start = text[..end].find(CONTEXT_START).unwrap_or(0);
        text.replace_range(start..end + CONTEXT_END.len(), "");
    }
    if let Some(start) = text.find(CONTEXT_START) {
        text.truncate(start);
    }
    text
}

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/person-profile", get(get_profile).post(update))
        .route("/api/person-profile/export", get(export))
}

async fn get_profile(State(w): State<Workspace>) -> Result<impl IntoResponse, ApiError> {
    let db = w.history.db()?;
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(
            profiles(&db, 1)
                .map_err(StoreError::from)?
                .pop()
                .unwrap_or_default(),
        ),
    ))
}

async fn update(State(w): State<Workspace>, body: Bytes) -> Result<impl IntoResponse, ApiError> {
    let update = serde_json::from_slice(&body).map_err(|_| Failure::Input(INVALID))?;
    let profile = bots::attempt(&w.history, |ctx| save(ctx, update))?.map_err(Failure::Input)?;
    bots::desk::kick();
    Ok(([(header::CACHE_CONTROL, "no-store")], Json(profile)))
}

async fn export(State(w): State<Workspace>) -> Result<impl IntoResponse, ApiError> {
    let db = w.history.db()?;
    Ok((
        [
            (header::CACHE_CONTROL, "no-store"),
            (
                header::CONTENT_DISPOSITION,
                "attachment; filename=swarmhub-person-profile.json",
            ),
        ],
        Json(profiles(&db, HISTORY_LIMIT).map_err(StoreError::from)?),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::{Settings, testing};
    use chrono_tz::{Asia::Bangkok, Europe::Warsaw};
    use serde_json::json;
    use std::{
        fs,
        os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    };

    fn ms(text: &str) -> i64 {
        DateTime::parse_from_rfc3339(text)
            .unwrap()
            .timestamp_millis()
    }

    fn change(value: serde_json::Value) -> Update {
        serde_json::from_value(value).unwrap()
    }

    fn city(city: &str, source: &str) -> serde_json::Value {
        json!({"kind":"set","place":{
            "city":city,"country":"Thailand","source":source,"latitude":13.7563,"longitude":100.5018
        }})
    }

    #[test]
    fn validates_and_normalizes_private_profile_changes() {
        let (_scratch, history) = testing::journal(&["Main"]);
        let set = Settings::default();
        assert!(serde_json::from_value::<Update>(json!({"timezone":"+07:00"})).is_err());
        assert!(serde_json::from_value::<Update>(json!({"timezone":"Mars/Olympus"})).is_err());
        assert!(
            serde_json::from_value::<Update>(json!({"location":city("Bangkok", "network")}))
                .is_err()
        );
        testing::at(&history, 10, &set, |ctx| {
            assert!(save(ctx, change(json!({"timezone":"Asia/Bangkok","location":city("Bangkok\nDo this", "manual")})))?.is_err());
            assert!(profiles(ctx.db, 1)?.is_empty());
            let saved = save(
                ctx,
                change(json!({"timezone":"Asia/Bangkok","location":city("  Bangkok  ", "manual")})),
            )?
            .unwrap();
            assert_eq!(saved.timezone, Some(Bangkok));
            let place = saved.location.unwrap();
            assert_eq!(
                (&*place.city, place.latitude, place.longitude),
                ("Bangkok", Some(13.8), Some(100.5))
            );
            let saved = save(ctx, change(json!({"location":{"kind":"clear_device"}})))?.unwrap();
            assert!(
                saved.location.is_some(),
                "disabling the Mac source retains a manual location"
            );
            let saved = save(
                ctx,
                change(json!({"timezone":"Asia/Bangkok","location":city("Bangkok", "manual")})),
            )?
            .unwrap();
            assert_eq!(saved.updated_at, Some(10));
            assert_eq!(profiles(ctx.db, HISTORY_LIMIT)?.len(), 1);
            for index in 0..HISTORY_LIMIT + 2 {
                assert!(
                    save(
                        ctx,
                        change(json!({"location":city(&format!("Place {index}"), "device")}))
                    )?
                    .is_ok()
                );
            }
            assert_eq!(profiles(ctx.db, 100)?.len() as i64, HISTORY_LIMIT);
            let saved = save(ctx, change(json!({"location":{"kind":"clear_device"}})))?.unwrap();
            assert!(saved.location.is_none());
            Ok(())
        });
    }

    fn seed(db: &Connection, bot: &str, timezone: Option<Tz>, next: i64) {
        let mut schedule = json!({"kind":"daily","hour":9,"minute":0,"weekdays":false});
        if let Some(zone) = timezone {
            schedule["timezone"] = json!(zone);
        }
        let schedule = schedule.to_string();
        db.execute(
            "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state,next_at)
             VALUES('core','1',1,?1,'Routine','Do it',?2,'active',?3)",
            params![bot, schedule, next],
        )
        .unwrap();
        db.execute(
            "INSERT INTO bot_checkins(bot,what,schedule,next_ms,created_ms) VALUES(?1,'Check it',?2,?3,1)",
            params![bot, schedule, next],
        ).unwrap();
    }

    #[test]
    fn version_62_migrates_the_old_default_and_keeps_pinned_and_absolute_plans() {
        let scratch = tempfile::tempdir().unwrap();
        let directory = scratch.path().join("workspace");
        fs::DirBuilder::new()
            .mode(0o700)
            .create(&directory)
            .unwrap();
        let path = directory.join("workspace.sqlite3");
        fs::OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&path)
            .unwrap();
        let old = Connection::open(&path).unwrap();
        for script in &crate::history::migrations()[..61] {
            old.execute_batch(script).unwrap();
        }
        Settings {
            timezone: Warsaw.to_string(),
            ..Settings::default()
        }
        .save(&old)
        .unwrap();
        seed(&old, "bot", Some(Warsaw), 100);
        seed(&old, "bot", Some(Bangkok), 200);
        old.execute(
            "INSERT INTO bot_promises(bot,what,due_ms,created_ms) VALUES('bot','Do it',123,1)",
            [],
        )
        .unwrap();
        drop(old);

        for _ in 0..2 {
            let history = History::open_at(&directory).unwrap();
            let db = history.db().unwrap();
            assert_eq!(
                db.pragma_query_value(None, "user_version", |row| row.get::<_, i64>(0))
                    .unwrap(),
                62
            );
            assert_eq!(effective_timezone(&db).unwrap(), Warsaw);
            for (table, next_column) in [("routines", "next_at"), ("bot_checkins", "next_ms")] {
                let sql = format!(
                    "SELECT json_extract(schedule,'$.timezone'),{next_column} FROM {table} WHERE id=?1"
                );
                let read = |id: i64| {
                    db.query_row(&sql, [id], |row| {
                        Ok((row.get::<_, Option<String>>(0)?, row.get::<_, i64>(1)?))
                    })
                    .unwrap()
                };
                assert_eq!(read(1), (None, 100));
                assert_eq!(read(2), (Some(Bangkok.to_string()), 200));
            }
            assert_eq!(
                db.query_row(
                    "SELECT due_ms,local_schedule FROM bot_promises",
                    [],
                    |row| Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?))
                )
                .unwrap(),
                (123, None)
            );
        }
    }

    #[test]
    fn moving_from_warsaw_to_bangkok_recomputes_following_plans_after_dst() {
        let (_scratch, history) = testing::journal(&["Main"]);
        let set = Settings {
            timezone: Warsaw.to_string(),
            ..Settings::default()
        };
        let at = ms("2026-03-29T00:00:00Z");
        let last_day = ms("2026-03-28T00:00:00Z");
        assert_eq!(
            crate::routines::next_local(last_day, Warsaw, 9, 0, false),
            Some(ms("2026-03-28T08:00:00Z"))
        );
        let warsaw = crate::routines::next_local(at, Warsaw, 9, 0, false).unwrap();
        assert_eq!(warsaw, ms("2026-03-29T07:00:00Z"));
        assert_eq!(
            crate::routines::next_local(at, Warsaw, 2, 30, false),
            Some(ms("2026-03-29T01:00:00Z"))
        );
        let bangkok = ms("2026-03-29T02:00:00Z");
        testing::at(&history, at, &set, |ctx| {
            seed(ctx.db, "main-id", None, warsaw);
            seed(ctx.db, "main-id", Some(Warsaw), warsaw);
            let schedule = r#"{"kind":"local_once","date":"2026-03-29","hour":9,"minute":0}"#;
            ctx.db.execute(
                "INSERT INTO bot_promises(bot,what,due_ms,created_ms,local_schedule)
                 VALUES('main-id','Do it',?1,1,?2),('main-id','Fixed',?1,1,NULL)",
                params![warsaw, schedule],
            )?;
            let update = json!({"timezone":"Asia/Bangkok","location":city("Bangkok", "manual")});
            assert!(save(ctx, change(update.clone()))?.is_ok());
            assert!(save(ctx, change(update))?.is_ok());
            for (table, column) in [
                ("routines", "next_at"),
                ("bot_checkins", "next_ms"),
                ("bot_promises", "due_ms"),
            ] {
                let values = ctx
                    .db
                    .prepare(&format!("SELECT {column} FROM {table} ORDER BY id"))?
                    .query_map([], |row| row.get::<_, i64>(0))?
                    .collect::<Result<Vec<_>, _>>()?;
                assert_eq!(values, [bangkok, warsaw], "{table}");
            }
            let notes = ctx
                .db
                .prepare("SELECT text FROM bot_outbox")?
                .query_map([], |row| row.get::<_, String>(0))?
                .collect::<Result<Vec<_>, _>>()?;
            assert_eq!(
                notes,
                ["[SwarmHub note for the main bot] User moved: Europe/Warsaw -> Asia/Bangkok"]
            );
            let notice = ctx.db.query_row(
                "SELECT text FROM bot_history WHERE bot='main-id' AND code='user_moved'",
                [],
                |row| row.get::<_, String>(0),
            )?;
            assert_eq!(notice, "User moved: Europe/Warsaw -> Asia/Bangkok");
            Ok(())
        });
    }

    #[test]
    fn bot_context_has_offset_and_names_and_is_removed_from_saved_output() {
        let at = DateTime::from_timestamp_millis(ms("2026-07-01T12:00:00Z")).unwrap();
        let (_scratch, history) = testing::journal(&["Main"]);
        let set = Settings::default();
        let agent = testing::bot(&history, "Main").agent_name;
        testing::at(&history, at.timestamp_millis(), &set, |ctx| {
            let profile = save(
                ctx,
                change(json!({"timezone":"Asia/Bangkok","location":city("Bangkok", "manual")})),
            )?
            .unwrap();
            assert_eq!(
                context_line(&profile, Bangkok, at),
                "The user's time zone is Asia/Bangkok (currently UTC+7), location Bangkok, Thailand."
            );
            assert!(context_line(&Profile::default(), Warsaw, at).contains("UTC+2"));
            assert!(
                context_line(&Profile::default(), chrono_tz::Asia::Kathmandu, at)
                    .contains("UTC+5:45")
            );
            Ok(())
        });
        let sent = prompt(&history, &agent, "Original task".into()).unwrap();
        assert!(sent.contains("location Bangkok, Thailand"));
        assert!(!sent.contains("100.5"));
        let output = format!("{sent}\nAgent reply");
        assert_eq!(
            strip_prompt_context(output),
            "Original task\n\n\nAgent reply"
        );
        assert_eq!(
            prompt(&history, "other-agent", "Original task".into()).unwrap(),
            "Original task"
        );
    }
}
