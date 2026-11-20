//! Bots for the app: the directory it registers its bots in, each bot's history, check-ins and promises, the
//! settings, and one stream of events for all bots. The README has the contract ("Bots on the server").

use super::{Bot, Registration, Settings, desk, plans, rules};
use crate::{Workspace, history::StoreError};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{Path, Query, State},
    http::StatusCode,
    response::{
        IntoResponse, Response,
        sse::{Event, KeepAlive, Sse},
    },
    routing::{get, post},
};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    convert::Infallible,
    hash::{DefaultHasher, Hash, Hasher},
    time::Duration,
};
use tokio::sync::{Semaphore, mpsc};

/// Open event streams. An app holds one.
static OPEN: Semaphore = Semaphore::const_new(16);
const LOOK: Duration = Duration::from_secs(1);
const HEARTBEAT: Duration = Duration::from_secs(15);
const STALLED: Duration = Duration::from_secs(60);
const PAGE: usize = 200;

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/bots", get(list).post(sync))
        .route("/api/bots/settings", get(settings).post(set_settings))
        .route("/api/bots/history", get(history))
        .route("/api/bots/fleet-policy", get(fleet_policy))
        .route("/api/bots/events", get(events))
        .route("/api/bots/{id}", post(update))
        .route("/api/bots/{id}/remove", post(remove))
        .route("/api/bots/{id}/stop", post(stop))
        .route("/api/bots/{id}/read", post(read))
        .route("/api/bots/{id}/exchanges", get(exchanges))
        .route("/api/bots/{id}/checkins", get(checkins).post(plan))
        .route("/api/bots/{id}/checkins/{checkin}/cancel", post(cancel))
        .route("/api/bots/{id}/promises", get(promises))
        .route(
            "/api/bots/{id}/promises/{promise}/close",
            post(close_promise),
        )
}

type Refusal = (StatusCode, Json<Value>);

fn refusal(status: StatusCode, kind: &str, error: &str) -> Refusal {
    (status, Json(json!({"error":error,"kind":kind})))
}

fn invalid(error: &str) -> Refusal {
    refusal(StatusCode::UNPROCESSABLE_ENTITY, "invalid", error)
}

fn storage<T>(_: T) -> Refusal {
    refusal(
        StatusCode::INTERNAL_SERVER_ERROR,
        "storage",
        "The workspace could not access its saved history. Check the workspace server.",
    )
}

fn unknown() -> Refusal {
    refusal(
        StatusCode::NOT_FOUND,
        "bot_unknown",
        "No bot with this id is registered on this server.",
    )
}

fn answered(result: Result<Response, Refusal>) -> Response {
    result.unwrap_or_else(IntoResponse::into_response)
}

fn body<T: for<'a> Deserialize<'a>>(bytes: &Bytes, shape: &str) -> Result<T, Refusal> {
    serde_json::from_slice(bytes).map_err(|_| invalid(shape))
}

/// The directory as the app reads it: every bot with its counts, the main bot, the settings.
fn directory(db: &rusqlite::Connection) -> rusqlite::Result<Value> {
    let bots = super::all(db)?;
    let mut listed = Vec::with_capacity(bots.len());
    for bot in &bots {
        let (unread, planned, promised, waiting): (i64, i64, i64, i64) = db.query_row(
            "SELECT (SELECT count(*) FROM bot_history WHERE bot=?1 AND unread=1 AND id>?2),
                    (SELECT count(*) FROM bot_checkins WHERE bot=?1 AND state='planned'),
                    (SELECT count(*) FROM bot_promises WHERE bot=?1 AND state IN ('open','raised','overdue')),
                    (SELECT count(*) FROM bot_messages WHERE (sender=?1 OR receiver=?1) AND state IN ('open','accepted'))",
            rusqlite::params![bot.id, bot.read_through],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
        )?;
        let mut view = serde_json::to_value(bot).unwrap_or(Value::Null);
        view["unread"] = unread.into();
        view["checkins"] = planned.into();
        view["promises"] = promised.into();
        view["open_exchanges"] = waiting.into();
        listed.push(view);
    }
    Ok(json!({
        "bots": listed,
        "main": bots.iter().find(|bot| bot.main).map(|bot| &bot.id),
        "settings": Settings::load(db)?,
        "command": super::command(),
    }))
}

async fn list(State(w): State<Workspace>) -> Response {
    answered((|| {
        let db = w.history.db().map_err(storage)?;
        Ok(Json(directory(&db).map_err(storage)?).into_response())
    })())
}

async fn fleet_policy(State(w): State<Workspace>) -> Response {
    answered(tokio::task::spawn_blocking(move || {
        w.fleet_authority()
    })
    .await
    .map(|view| Json(view).into_response())
    .map_err(storage))
}

/// Saves a bot and ends what the change ends.
fn save(ctx: &super::Ctx<'_>, wanted: &Registration) -> rusqlite::Result<Result<Bot, String>> {
    Ok(match super::register(ctx.db, wanted, ctx.now)? {
        Ok((bot, change)) => {
            if change.messaging_off {
                rules::stop(ctx, &bot, rules::Why::Switch)?;
            }
            Ok(bot)
        }
        Err(why) => Err(why),
    })
}

fn forget(ctx: &super::Ctx<'_>, bot: &Bot) -> rusqlite::Result<()> {
    rules::stop(ctx, bot, rules::Why::Removed)?;
    ctx.db.execute(
        "UPDATE bot_checkins SET state='cancelled',next_ms=NULL WHERE bot=?1 AND state='planned'",
        [&bot.id],
    )?;
    ctx.db.execute(
        "UPDATE bot_promises SET state='dropped',closed_ms=?2,note='The bot was removed.' WHERE bot=?1 AND state IN ('open','raised','overdue')",
        rusqlite::params![bot.id, ctx.now],
    )?;
    ctx.db.execute(
        "UPDATE bot_outbox SET state='dropped',detail='The bot was removed.' WHERE bot=?1 AND state='pending'
           AND NOT EXISTS (SELECT 1 FROM job_deliveries WHERE outbox=bot_outbox.id)",
        [&bot.id],
    )?;
    ctx.db.execute(
        "UPDATE bots SET removed_ms=?2,main=0 WHERE id=?1",
        rusqlite::params![bot.id, ctx.now],
    )?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Sync {
    bots: Vec<Registration>,
    /// The list is all of the app's bots on this server: a bot that is not in it is removed.
    #[serde(default)]
    replace: bool,
}

const SYNC_SHAPE: &str = "Send bots: a list of bots, each with an id and a name.";

async fn sync(State(w): State<Workspace>, bytes: Bytes) -> Response {
    answered((|| {
        let wanted: Sync = body(&bytes, SYNC_SHAPE)?;
        if wanted.bots.len() > 200 {
            return Err(invalid("A server takes at most 200 bots."));
        }
        let saved = super::attempt(&w.history, |ctx| {
            let mut kept = Vec::new();
            for bot in &wanted.bots {
                match save(ctx, bot)? {
                    Ok(bot) => kept.push(bot.id),
                    Err(why) => return Ok(Err(format!("{} ({why})", bot.id))),
                }
            }
            if wanted.replace {
                for bot in super::all(ctx.db)? {
                    if !kept.contains(&bot.id) {
                        forget(ctx, &bot)?;
                    }
                }
            }
            Ok(Ok(directory(ctx.db)?))
        })
        .map_err(storage)?
        .map_err(|why| invalid(&format!("This bot could not be saved: {why}")))?;
        desk::kick();
        Ok(Json(saved).into_response())
    })())
}

async fn update(State(w): State<Workspace>, Path(id): Path<String>, bytes: Bytes) -> Response {
    answered((|| {
        let mut wanted: Value = body(&bytes, "Send the fields of the bot that change.")?;
        if !wanted.is_object() {
            return Err(invalid("Send the fields of the bot that change."));
        }
        wanted["id"] = id.into();
        let wanted: Registration = serde_json::from_value(wanted)
            .map_err(|_| invalid("Send the fields of the bot that change."))?;
        let bot = super::attempt(&w.history, |ctx| save(ctx, &wanted))
            .map_err(storage)?
            .map_err(|why| invalid(&why))?;
        desk::kick();
        Ok(Json(json!({"bot":bot})).into_response())
    })())
}

/// Runs `work` for the bot with this id, or answers that there is none.
fn for_bot<T>(
    w: &Workspace,
    id: &str,
    work: impl FnOnce(&super::Ctx<'_>, &Bot) -> rusqlite::Result<T>,
) -> Result<T, Refusal> {
    let id = id.to_ascii_lowercase();
    super::write(&w.history, |ctx| match super::one(ctx.db, &id)? {
        Some(bot) => Ok(Some(work(ctx, &bot)?)),
        None => Ok(None),
    })
    .map_err(storage)?
    .ok_or_else(unknown)
}

async fn remove(State(w): State<Workspace>, Path(id): Path<String>) -> Response {
    answered((|| {
        for_bot(&w, &id, forget)?;
        desk::kick();
        Ok(Json(json!({"removed":id.to_ascii_lowercase()})).into_response())
    })())
}

async fn stop(State(w): State<Workspace>, Path(id): Path<String>) -> Response {
    answered((|| {
        let ended = for_bot(&w, &id, |ctx, bot| {
            rules::stop(ctx, bot, rules::Why::Person)
        })?;
        desk::kick();
        Ok(Json(json!({"ended":ended})).into_response())
    })())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Read {
    through: i64,
}

async fn read(State(w): State<Workspace>, Path(id): Path<String>, bytes: Bytes) -> Response {
    answered((|| {
        let read: Read = body(
            &bytes,
            "Send through: the id of the newest history line that was read.",
        )?;
        let through = for_bot(&w, &id, |ctx, bot| {
            ctx.db.execute(
                "UPDATE bots SET read_through=max(read_through,?2) WHERE id=?1",
                rusqlite::params![bot.id, read.through],
            )?;
            Ok(bot.read_through.max(read.through))
        })?;
        Ok(Json(json!({"read_through":through})).into_response())
    })())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HistoryQuery {
    bot: Option<String>,
    kind: Option<String>,
    after: Option<i64>,
    before: Option<i64>,
    limit: Option<usize>,
}

async fn history(State(w): State<Workspace>, Query(query): Query<HistoryQuery>) -> Response {
    answered((|| {
        let db = w.history.db().map_err(storage)?;
        let limit = query.limit.unwrap_or(PAGE).clamp(1, 500);
        let bot = query.bot.map(|bot| bot.to_ascii_lowercase());
        let mut items = rules::entries(
            &db,
            &rules::Lines {
                bot: bot.as_deref(),
                kind: query.kind.as_deref(),
                after: query.after,
                before: query.before,
                limit: limit + 1,
            },
        )
        .map_err(storage)?;
        let more = items.len() > limit;
        if more {
            // The extra line is the one furthest from where the reader is.
            if query.after.is_some() && query.before.is_none() {
                items.pop();
            } else {
                items.remove(0);
            }
        }
        Ok(Json(json!({"items":items,"more":more})).into_response())
    })())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Which {
    /// Also what has ended.
    #[serde(default)]
    all: Option<String>,
}

fn wants_all(which: &Which) -> bool {
    which
        .all
        .as_deref()
        .is_some_and(|all| all != "0" && all != "false")
}

async fn exchanges(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    Query(which): Query<Which>,
) -> Response {
    answered((|| {
        let all = wants_all(&which);
        let found = for_bot(&w, &id, |ctx, bot| rules::exchanges(ctx.db, &bot.id, !all))?;
        Ok(Json(json!({"exchanges":found})).into_response())
    })())
}

async fn checkins(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    Query(which): Query<Which>,
) -> Response {
    answered((|| {
        let all = wants_all(&which);
        let (found, set) = for_bot(&w, &id, |ctx, bot| {
            Ok((
                plans::checkins(ctx.db, Some(&bot.id), all)?,
                ctx.set.clone(),
            ))
        })?;
        Ok(Json(json!({"checkins":found,"limit":set.checkins_per_bot,"gap_seconds":set.checkin_gap_seconds}))
            .into_response())
    })())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Plan {
    what: String,
    when: plans::When,
}

async fn plan(State(w): State<Workspace>, Path(id): Path<String>, bytes: Bytes) -> Response {
    answered((|| {
        let wanted: Plan = body(
            &bytes,
            "Send what (words for the bot) and when, such as {\"when\":\"in\",\"seconds\":1800}.",
        )?;
        let planned = for_bot(&w, &id, |ctx, bot| {
            plans::plan(ctx, bot, &wanted.when, &wanted.what, "person")
        })?
        .map_err(|why| refusal(StatusCode::CONFLICT, "refused", &why))?;
        Ok((StatusCode::CREATED, Json(json!({"checkin":planned}))).into_response())
    })())
}

async fn cancel(State(w): State<Workspace>, Path((id, checkin)): Path<(String, i64)>) -> Response {
    answered((|| {
        if !for_bot(&w, &id, |ctx, bot| plans::cancel(ctx, &bot.id, checkin))? {
            return Err(refusal(
                StatusCode::NOT_FOUND,
                "checkin_unknown",
                "This bot has no planned check-in with this id.",
            ));
        }
        Ok(Json(json!({"cancelled":checkin})).into_response())
    })())
}

async fn promises(
    State(w): State<Workspace>,
    Path(id): Path<String>,
    Query(which): Query<Which>,
) -> Response {
    answered((|| {
        let all = wants_all(&which);
        let found = for_bot(&w, &id, |ctx, bot| {
            plans::promises(ctx.db, Some(&bot.id), all)
        })?;
        Ok(Json(json!({"promises":found})).into_response())
    })())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Close {
    /// `done` or `dropped`.
    state: String,
    note: Option<String>,
}

async fn close_promise(
    State(w): State<Workspace>,
    Path((id, promise)): Path<(String, i64)>,
    bytes: Bytes,
) -> Response {
    answered((|| {
        let close: Close = body(&bytes, "Send state: done or dropped.")?;
        if !matches!(close.state.as_str(), "done" | "dropped") {
            return Err(invalid("Send state: done or dropped."));
        }
        if !for_bot(&w, &id, |ctx, bot| {
            plans::settle(ctx, &bot.id, promise, &close.state, close.note.as_deref())
        })? {
            return Err(refusal(
                StatusCode::NOT_FOUND,
                "promise_unknown",
                "This bot has no open promise with this id.",
            ));
        }
        Ok(Json(json!({"closed":promise,"state":close.state})).into_response())
    })())
}

fn bounds() -> Value {
    Value::Object(
        super::BOUNDS
            .iter()
            .map(|(name, low, high)| ((*name).to_owned(), json!([low, high])))
            .collect(),
    )
}

async fn settings(State(w): State<Workspace>) -> Response {
    answered((|| {
        let db = w.history.db().map_err(storage)?;
        let set = Settings::load(&db).map_err(storage)?;
        Ok(Json(json!({"settings":set,"bounds":bounds()})).into_response())
    })())
}

async fn set_settings(State(w): State<Workspace>, bytes: Bytes) -> Response {
    answered((|| {
        const SHAPE: &str = "Send the settings that change, by their names.";
        let wanted: Value = body(&bytes, SHAPE)?;
        let Some(wanted) = wanted.as_object() else {
            return Err(invalid(SHAPE));
        };
        let set = super::attempt(&w.history, |ctx| {
            let mut merged = serde_json::to_value(ctx.set).unwrap_or(Value::Null);
            for (name, value) in wanted {
                merged[name] = value.clone();
            }
            let Ok(set) = serde_json::from_value::<Settings>(merged) else {
                return Ok(Err(SHAPE.to_owned()));
            };
            if let Some(problem) = set.problem() {
                return Ok(Err(problem));
            }
            set.save(ctx.db)?;
            let zone = crate::person_profile::zone(ctx.db, set.zone())?;
            crate::person_profile::timezone_changed(ctx.db, ctx.now, ctx.zone, zone, false)?;
            Ok(Ok(set))
        })
        .map_err(storage)?
        .map_err(|why| invalid(&why))?;
        desk::kick();
        Ok(Json(json!({"settings":set,"bounds":bounds()})).into_response())
    })())
}

// ---- The event stream.

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Resume {
    /// The newest history line the reader has. Without it, the stream starts at the newest line there is.
    after: Option<i64>,
}

fn hashed(value: &Value) -> u64 {
    let mut hasher = DefaultHasher::new();
    value.to_string().hash(&mut hasher);
    hasher.finish()
}

/// What a stream sends whole whenever it changes.
struct Now {
    bots: Value,
    checkins: Value,
    promises: Value,
    settings: Value,
}

fn read_now(w: &Workspace) -> Result<Now, StoreError> {
    let db = w.history.db()?;
    let mut directory = directory(&db)?;
    let settings = directory
        .as_object_mut()
        .and_then(|directory| directory.remove("settings"))
        .unwrap_or(Value::Null);
    Ok(Now {
        settings: json!({"settings":settings}),
        bots: directory,
        checkins: json!({"checkins":plans::checkins(&db, None, false)?}),
        promises: json!({"promises":plans::promises(&db, None, false)?}),
    })
}

fn event(name: &str, data: &Value) -> Event {
    Event::default().event(name).data(data.to_string())
}

async fn events(State(w): State<Workspace>, Query(resume): Query<Resume>) -> Response {
    let Ok(permit) = OPEN.try_acquire() else {
        return refusal(
            StatusCode::TOO_MANY_REQUESTS,
            "busy",
            "Too many live connections are open. Close one, or read with the history route.",
        )
        .into_response();
    };
    let (queue, reader) = mpsc::channel::<Event>(32);
    tokio::spawn(async move {
        let _permit = permit;
        let send = |event: Event| {
            let queue = queue.clone();
            async move {
                matches!(
                    tokio::time::timeout(STALLED, queue.send(event)).await,
                    Ok(Ok(()))
                )
            }
        };
        let newest = |w: &Workspace| -> i64 {
            w.history
                .db()
                .ok()
                .and_then(|db| {
                    db.query_row("SELECT coalesce(max(id),0) FROM bot_history", [], |row| {
                        row.get(0)
                    })
                    .ok()
                })
                .unwrap_or(0)
        };
        let lines = |w: &Workspace, after: i64| -> Vec<rules::Entry> {
            w.history
                .db()
                .ok()
                .and_then(|db| {
                    rules::entries(
                        &db,
                        &rules::Lines {
                            after: Some(after),
                            limit: PAGE,
                            ..rules::Lines::default()
                        },
                    )
                    .ok()
                })
                .unwrap_or_default()
        };
        let Ok(now) = read_now(&w) else {
            return;
        };
        let mut last = resume.after.unwrap_or_else(|| newest(&w));
        let missed = if resume.after.is_some() {
            lines(&w, last)
        } else {
            Vec::new()
        };
        let more = missed.len() == PAGE;
        if let Some(entry) = missed.last() {
            last = entry.id;
        }
        let mut snapshot = now.bots.clone();
        snapshot["settings"] = now.settings["settings"].clone();
        snapshot["checkins"] = now.checkins["checkins"].clone();
        snapshot["promises"] = now.promises["promises"].clone();
        snapshot["history"] = json!({"items":missed,"more":more});
        snapshot["last"] = last.into();
        if !send(event("snapshot", &snapshot)).await {
            return;
        }
        let mut sent = [
            hashed(&now.bots),
            hashed(&now.checkins),
            hashed(&now.promises),
            hashed(&now.settings),
        ];
        loop {
            tokio::select! {
                () = queue.closed() => return,
                () = tokio::time::sleep(LOOK) => {}
            }
            if newest(&w) > last {
                for entry in lines(&w, last) {
                    last = entry.id;
                    let data = serde_json::to_value(&entry).unwrap_or(Value::Null);
                    if !send(event("entry", &data)).await {
                        return;
                    }
                }
            }
            let Ok(now) = read_now(&w) else {
                continue;
            };
            for (index, (name, value)) in [
                ("bots", &now.bots),
                ("checkins", &now.checkins),
                ("promises", &now.promises),
                ("settings", &now.settings),
            ]
            .into_iter()
            .enumerate()
            {
                let hash = hashed(value);
                if hash != sent[index] {
                    sent[index] = hash;
                    if !send(event(name, value)).await {
                        return;
                    }
                }
            }
        }
    });
    let reader = futures_util::stream::unfold(reader, |mut reader| async move {
        reader
            .recv()
            .await
            .map(|event| (Ok::<_, Infallible>(event), reader))
    });
    Sse::new(reader)
        .keep_alive(KeepAlive::new().interval(HEARTBEAT).text("heartbeat"))
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::{plans::When, testing};

    #[test]
    fn turning_messages_off_ends_a_bots_exchanges_and_removing_it_ends_everything_it_had() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Infra", "Shop"]);
        let set = Settings::default();
        let (jarvis, infra, shop) = (
            testing::bot(&history, "Jarvis"),
            testing::bot(&history, "Infra"),
            testing::bot(&history, "Shop"),
        );
        let count = |sql: &str| -> i64 {
            history
                .db()
                .unwrap()
                .query_row(sql, [], |row| row.get(0))
                .unwrap()
        };
        testing::at(&history, 1_000, &set, |ctx| {
            rules::send(
                ctx,
                &jarvis,
                None,
                rules::Kind::Ask,
                "Infra",
                "Which port?",
                "command",
            )?
            .unwrap();
            rules::send(
                ctx,
                &shop,
                None,
                rules::Kind::Ask,
                "Infra",
                "Which price?",
                "command",
            )?
            .unwrap();
            plans::plan(
                ctx,
                &infra,
                &When::In { seconds: 3_600 },
                "Check the deploy.",
                "bot",
            )?
            .unwrap();
            plans::promise(
                ctx,
                &infra,
                Some(plans::Schedule::Once {
                    at_ms: ctx.now + 60_000,
                }),
                "Report.",
            )?
            .unwrap();
            Ok(())
        });
        // The switch: Jarvis may no longer message bots. Its ask ends, and nobody else's does.
        let off = Registration {
            id: "jarvis-id".into(),
            may_message: Some(false),
            ..Registration::default()
        };
        let saved = testing::at(&history, 2_000, &set, |ctx| save(ctx, &off)).unwrap();
        assert!(!saved.may_message);
        assert_eq!(
            count("SELECT count(*) FROM bot_messages WHERE state='stopped' AND sender='jarvis-id'"),
            1
        );
        assert_eq!(
            count("SELECT count(*) FROM bot_messages WHERE state='open' AND sender='shop-id'"),
            1
        );
        let line: String = history
            .db()
            .unwrap()
            .query_row(
                "SELECT text FROM bot_history WHERE bot='infra-id' AND code='stopped'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(line.starts_with("Jarvis may no longer message other bots (the person turned that off), so Jarvis's ask #1 to Infra ended"));
        // Saving the same again ends nothing more, and a registration that cannot be saved changes nothing.
        testing::at(&history, 3_000, &set, |ctx| save(ctx, &off)).unwrap();
        assert_eq!(
            count("SELECT count(*) FROM bot_messages WHERE state='stopped'"),
            1
        );
        let bad = Registration {
            id: "jarvis-id".into(),
            name: Some(String::new()),
            ..Registration::default()
        };
        assert!(testing::at(&history, 3_000, &set, |ctx| save(ctx, &bad)).is_err());

        // Removed: the bot that waited on it is told, its check-ins and promises end, and it is in no list.
        testing::at(&history, 4_000, &set, |ctx| forget(ctx, &infra));
        assert_eq!(
            count("SELECT count(*) FROM bot_messages WHERE state='open'"),
            0
        );
        let told: String = history
            .db()
            .unwrap()
            .query_row(
                "SELECT text FROM bot_outbox WHERE bot='shop-id' AND state='pending'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert!(
            told.contains(
                "Infra was removed by the person, so your ask #2 ended without an answer"
            )
        );
        assert_eq!(
            count("SELECT count(*) FROM bot_checkins WHERE state='planned'")
                + count("SELECT count(*) FROM bot_promises WHERE state='open'"),
            0
        );
        assert_eq!(
            count("SELECT count(*) FROM bot_outbox WHERE bot='infra-id' AND state='pending'"),
            0
        );
        let db = history.db().unwrap();
        assert!(super::super::one(&db, "infra-id").unwrap().is_none());
        let listed = directory(&db).unwrap();
        assert_eq!(listed["bots"].as_array().unwrap().len(), 2);
        assert_eq!(listed["main"], "jarvis-id");
        assert_eq!(listed["bots"][0]["open_exchanges"], 0);
        assert_eq!(listed["settings"]["ask_seconds"], 600);
        // Its history stays readable.
        assert!(
            !rules::entries(
                &db,
                &rules::Lines {
                    bot: Some("infra-id"),
                    after: Some(0),
                    limit: 50,
                    ..rules::Lines::default()
                }
            )
            .unwrap()
            .is_empty()
        );
        drop(db);
        // Registered again under the same id, it is back.
        let again = Registration {
            id: "infra-id".into(),
            name: Some("Infra".into()),
            ..Registration::default()
        };
        assert!(testing::at(&history, 5_000, &set, |ctx| save(ctx, &again)).is_ok());
        assert_eq!(crate::bots::all(&history.db().unwrap()).unwrap().len(), 3);
    }
}
