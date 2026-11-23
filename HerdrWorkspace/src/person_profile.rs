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
const CONTEXT_FOOTER: &str =
    " Use this time zone for local times. Keep the location private. [/SwarmHub person profile]";
const CONTEXT_LIMIT: usize = 1536;
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
    follow: Option<Follow>,
    location: Option<LocationChange>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum Follow {
    Default { device: String, timezone: Tz },
    Enable { device: String, timezone: Tz },
    Sync { device: String, timezone: Tz },
    Disable { device: String },
}

#[derive(Serialize)]
struct ProfileState {
    #[serde(flatten)]
    profile: Profile,
    follow_source: Option<String>,
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

fn follow_state(db: &Connection) -> rusqlite::Result<Option<String>> {
    db.query_row(
        "SELECT value FROM bot_state WHERE key='person_follow_source'",
        [],
        |row| row.get(0),
    )
    .optional()
}

fn follow_source(state: &Option<String>) -> Option<&str> {
    state.as_deref().filter(|device| !device.is_empty())
}

fn write_follow_state(db: &Connection, device: &str) -> rusqlite::Result<()> {
    db.execute(
        "INSERT INTO bot_state(key,value) VALUES('person_follow_source',?1)
         ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [device],
    )?;
    Ok(())
}

fn save(
    ctx: &bots::Ctx<'_>,
    update: Update,
) -> rusqlite::Result<Result<ProfileState, &'static str>> {
    let mut profile = profiles(ctx.db, 1)?.pop().unwrap_or_default();
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
    let state = follow_state(ctx.db)?;
    let mut source = follow_source(&state);
    let mut wanted_zone = update.timezone;
    if let Some(follow) = &update.follow {
        let (device, timezone) = match follow {
            Follow::Default { device, timezone }
            | Follow::Enable { device, timezone }
            | Follow::Sync { device, timezone } => (device, Some(*timezone)),
            Follow::Disable { device } => (device, None),
        };
        if wanted_zone.is_some()
            || device.len() != 32
            || !device.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Ok(Err(INVALID));
        }
        match follow {
            // Keep an empty row after disabling so a later Mac cannot become primary by default.
            Follow::Default { .. } if state.is_none() || source == Some(device) => {
                source = Some(device);
                wanted_zone = timezone;
            }
            Follow::Enable { .. } => {
                source = Some(device);
                wanted_zone = timezone;
            }
            Follow::Sync { .. } if source == Some(device) => wanted_zone = timezone,
            Follow::Disable { .. } if source == Some(device) => source = None,
            _ => {}
        }
    } else if wanted_zone.is_some() {
        source = None;
    }
    if source != follow_source(&state) || update.timezone.is_some() && state.is_none() {
        write_follow_state(ctx.db, source.unwrap_or_default())?;
    }
    let source = source.map(str::to_owned);
    let old_zone = profile.timezone.unwrap_or(ctx.set.zone());
    let timezone = wanted_zone.or(profile.timezone);
    if (timezone, &location) == (profile.timezone, &profile.location) {
        return Ok(Ok(ProfileState {
            profile,
            follow_source: source,
        }));
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
    rezone(ctx.db, ctx.now, old_zone, new_zone)?;
    bots::profile_moved(ctx.db, ctx.now, old_zone, new_zone, city_changed)?;
    Ok(Ok(ProfileState {
        profile,
        follow_source: source,
    }))
}

pub(crate) fn rezone(
    db: &Connection,
    at: i64,
    before: Tz,
    after: Tz,
) -> rusqlite::Result<()> {
    if before != after {
        crate::routines::rezone(db, at, after)?;
        bots::rezone_plans(db, at, after)?;
    }
    Ok(())
}

/// A matching zone can be inferred as inherited only when the legacy workspace
/// inherited a configured server zone. Preserve saved settings and the implicit
/// UTC fallback, which has no evidence of a server zone (common on Mac hosts).
/// Old absolute deadlines lack the wall-clock intent needed to move them.
pub(crate) fn migrate(db: &Connection, server_zone: Option<&str>) -> rusqlite::Result<()> {
    let Some(default) = server_zone else {
        return Ok(());
    };
    if bots::Settings::saved(db)?
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok())
        .is_some_and(|settings| settings.get("timezone").is_some())
    {
        return Ok(());
    }
    for table in ["routines", "bot_checkins"] {
        db.execute(
            &format!(
                "UPDATE {table} SET schedule=json_remove(schedule,'$.timezone')
                       WHERE json_extract(schedule,'$.kind')='daily'
                         AND json_extract(schedule,'$.timezone')=?1"
            ),
            [default],
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
    validate_task(&text)?;
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
    Ok(format!(
        "{text}\n\n{CONTEXT_START} {context}{CONTEXT_FOOTER}"
    ))
}

// Internal delivery paths can receive a decorated prompt across a process boundary.
// Reserve room only for the bounded, single-line suffix. Raw input uses validate_task.
pub(crate) fn validate_prompt(prompt: &str) -> Result<(), Failure> {
    let original = validate_task(prompt);
    if original.is_ok() {
        return original;
    }
    if let Some((task, context)) = prompt.rsplit_once(concat!("\n\n", "[SwarmHub person profile] "))
        && context.len() <= CONTEXT_LIMIT
        && context.starts_with("The user's time zone is ")
        && context.ends_with(CONTEXT_FOOTER)
        && !context.chars().any(char::is_control)
    {
        return validate_task(task);
    }
    original
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
    let tx = db.unchecked_transaction().map_err(StoreError::from)?;
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(ProfileState {
            profile: profiles(&tx, 1)
                .map_err(StoreError::from)?
                .pop()
                .unwrap_or_default(),
            follow_source: follow_source(&follow_state(&tx).map_err(StoreError::from)?)
                .map(str::to_owned),
        }),
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
    fn only_the_active_mac_can_sync_and_move_notes_are_debounced() {
        let (_scratch, history) = testing::journal(&["Main"]);
        let set = Settings {
            timezone: Warsaw.to_string(),
            ..Settings::default()
        };
        let first = "a".repeat(32);
        let other = "b".repeat(32);
        let follow = |at, kind: &str, device: &str, timezone: Option<Tz>| {
            let mut fields = json!({"kind":kind,"device":device});
            if let Some(timezone) = timezone {
                fields["timezone"] = json!(timezone);
            }
            testing::at(&history, at, &set, |ctx| {
                save(ctx, change(json!({"follow":fields})))
            })
            .unwrap()
        };
        let notes = |table: &str, filter: &str| {
            history
                .db()
                .unwrap()
                .query_row(
                    &format!("SELECT count(*) FROM {table} WHERE {filter}"),
                    [],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap()
        };
        let state = follow(1_000, "default", &first, Some(Warsaw));
        assert_eq!(state.follow_source.as_deref(), Some(first.as_str()));
        assert_eq!(
            notes("bot_history", "code='user_moved'"),
            0,
            "the effective zone was unchanged"
        );
        for kind in ["default", "sync"] {
            let state = follow(2_000, kind, &other, Some(Bangkok));
            assert_eq!(state.follow_source.as_deref(), Some(first.as_str()));
            assert_eq!(state.profile.timezone, Some(Warsaw));
        }
        assert_eq!(
            profiles(&history.db().unwrap(), HISTORY_LIMIT)
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            follow(3_000, "sync", &first, Some(Bangkok))
                .profile
                .timezone,
            Some(Bangkok)
        );
        assert_eq!(
            follow(4_000, "sync", &first, Some(Bangkok))
                .profile
                .updated_at,
            Some(3_000)
        );
        assert_eq!(
            follow(5_000, "enable", &other, Some(Warsaw))
                .follow_source
                .as_deref(),
            Some(other.as_str())
        );
        assert_eq!(
            follow(6_000, "sync", &first, Some(Bangkok))
                .profile
                .timezone,
            Some(Warsaw)
        );
        assert_eq!(
            follow(7_000, "disable", &first, None)
                .follow_source
                .as_deref(),
            Some(other.as_str())
        );
        assert_eq!(notes("bot_history", "code='user_moved'"), 1);
        assert_eq!(notes("bot_outbox", "cause='note'"), 1);

        assert_eq!(
            follow(63_000, "sync", &other, Some(Bangkok))
                .profile
                .timezone,
            Some(Bangkok)
        );
        assert_eq!(notes("bot_history", "code='user_moved'"), 2);
        assert_eq!(follow(64_000, "disable", &other, None).follow_source, None);
        let disabled = follow(65_000, "default", &first, Some(Warsaw));
        assert_eq!(disabled.follow_source, None);
        assert_eq!(disabled.profile.timezone, Some(Bangkok));

        follow(66_000, "enable", &first, Some(Bangkok));
        let manual = testing::at(&history, 67_000, &set, |ctx| {
            save(ctx, change(json!({"timezone": Warsaw})))
        })
        .unwrap();
        assert_eq!(manual.follow_source, None);
        assert_eq!(
            follow(68_000, "sync", &first, Some(Bangkok))
                .profile
                .timezone,
            Some(Warsaw)
        );
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
            assert_eq!(saved.profile.timezone, Some(Bangkok));
            let place = saved.profile.location.unwrap();
            assert_eq!(
                (&*place.city, place.latitude, place.longitude),
                ("Bangkok", Some(13.8), Some(100.5))
            );
            let saved = save(ctx, change(json!({"location":{"kind":"clear_device"}})))?.unwrap();
            assert!(
                saved.profile.location.is_some(),
                "disabling the Mac source retains a manual location"
            );
            let saved = save(
                ctx,
                change(json!({"timezone":"Asia/Bangkok","location":city("Bangkok", "manual")})),
            )?
            .unwrap();
            assert_eq!(saved.profile.updated_at, Some(10));
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
            assert!(saved.profile.location.is_none());
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
    fn legacy_migration_follows_only_an_inherited_configured_server_zone() {
        for (server_zone, saved_zone, matching_zone, follows) in [
            (Some("Europe/Warsaw"), None, Warsaw, true),
            (Some("Europe/Warsaw"), Some(Warsaw), Warsaw, false),
            (Some("UTC"), None, chrono_tz::UTC, true),
            (None, None, chrono_tz::UTC, false),
            (None, Some(chrono_tz::UTC), chrono_tz::UTC, false),
        ] {
            let db = Connection::open_in_memory().unwrap();
            for script in &crate::history::migrations()[..61] {
                db.execute_batch(script).unwrap();
            }
            // Legacy settings rows can exist without a saved timezone.
            let mut settings = json!({"ask_seconds":900});
            if let Some(saved_zone) = saved_zone {
                settings["timezone"] = json!(saved_zone);
            }
            db.execute(
                "INSERT INTO bot_state(key,value) VALUES('settings',?1)",
                [settings.to_string()],
            )
            .unwrap();
            seed(&db, "bot", Some(matching_zone), 100);
            seed(&db, "bot", Some(Bangkok), 200);
            db.execute(
                "INSERT INTO bot_promises(bot,what,due_ms,created_ms) VALUES('bot','Do it',123,1)",
                [],
            )
            .unwrap();

            for _ in 0..2 {
                crate::history::migrate(&db, server_zone).unwrap();
                let version: usize = db
                    .pragma_query_value(None, "user_version", |row| row.get(0))
                    .unwrap();
                assert_eq!(version, crate::history::migrations().len());
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
                    assert_eq!(
                        read(1),
                        ((!follows).then(|| matching_zone.to_string()), 100)
                    );
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
                context_line(&profile.profile, Bangkok, at),
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

    #[test]
    fn profile_context_has_its_own_delivery_budget() {
        let (_scratch, history) = testing::journal(&["Main"]);
        let agent = testing::bot(&history, "Main").agent_name;
        let task = "x".repeat(16_384);
        let delivered = prompt(&history, &agent, task.clone()).unwrap();
        assert!(delivered.len() > task.len());
        assert!(validate_prompt(&delivered).is_ok());
        assert!(validate_task(&delivered).is_err());
        let literal = delivered.trim_start_matches('x');
        assert!(validate_task(literal).is_ok());
        assert!(validate_prompt(literal).is_ok());
        assert!(prompt(&history, &agent, format!("{task}x")).is_err());
        assert!(validate_prompt(&format!("x{delivered}")).is_err());
        assert!(validate_prompt(&format!("{delivered}x")).is_err());
        assert!(validate_prompt(&delivered.replace("currently", "currently\n")).is_err());
        assert!(
            validate_prompt(&delivered.replace("currently", &"x".repeat(CONTEXT_LIMIT))).is_err()
        );
    }
}
