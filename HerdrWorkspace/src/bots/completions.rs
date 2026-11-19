//! Durable bot-desk delivery, with the terminal job event as the logical inbox item.

use super::{Ctx, rules};
use crate::{core::Terminal, history::StoreError};
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::Serialize;

const RETRY_MS: i64 = 2_000;
const UNCERTAIN: &str = "Delivery is unconfirmed. The owner can recover by ID.";

#[derive(Serialize)]
pub(crate) struct Completion {
    pub id: String,
    pub job_id: String,
    attempt: i64,
    pub owner_bot_id: String,
    verdict: String,
    exit_reason: String,
    exit_code: Option<i32>,
    result_ref: Option<String>,
    expected_next_action: String,
}

/// Admission and replay use only terminal facts and an opaque result reference.
const EVENT: &str = "c.job_id,c.attempt,c.owner_bot_id,a.verdict,a.exit_reason,
    a.exit_code,a.result_ref,c.expected_next_action";

fn event(row: &Row<'_>) -> rusqlite::Result<Completion> {
    let job_id: String = row.get(0)?;
    let attempt: i64 = row.get(1)?;
    Ok(Completion {
        id: format!("{job_id}:{attempt}"),
        job_id,
        attempt,
        owner_bot_id: row.get(2)?,
        verdict: row.get(3)?,
        exit_reason: row.get(4)?,
        exit_code: row.get(5)?,
        result_ref: row.get(6)?,
        expected_next_action: row.get(7)?,
    })
}

fn event_key(id: &str) -> Option<(&str, i64)> {
    let (job, attempt) = id.split_once(':')?;
    let attempt: i64 = attempt.parse().ok()?;
    (attempt > 0
        && (1..=128).contains(&job.len())
        && job.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_')))
    .then_some((job, attempt))
}

pub(crate) fn valid_id(id: &str) -> bool {
    event_key(id).is_some()
}

fn stage(ctx: &Ctx<'_>, completion: &Completion) -> rusqlite::Result<i64> {
    let outbox = rules::post(
        ctx,
        rules::Post {
            bot: &completion.owner_bot_id,
            text: &super::notes::completion(ctx.cmd, completion),
            cause: "outcome",
            ..rules::Post::default()
        },
    )?;
    ctx.db.execute(
        "INSERT INTO job_deliveries(job_id,attempt,outbox) VALUES (?1,?2,?3)",
        params![completion.job_id, completion.attempt, outbox],
    )?;
    Ok(outbox)
}

pub(super) fn stage_waiting(ctx: &Ctx<'_>) -> rusqlite::Result<()> {
    let events = ctx.db.prepare_cached(&format!(
        "SELECT {EVENT} FROM job_completions c
         JOIN job_attempts a USING (job_id,attempt)
         LEFT JOIN job_deliveries d USING (job_id,attempt)
         WHERE d.outbox IS NULL ORDER BY c.created_ms,c.job_id,c.attempt LIMIT 200"
    ))?.query_map([], event)?.collect::<rusqlite::Result<Vec<_>>>()?;
    for completion in events {
        stage(ctx, &completion)?;
    }
    Ok(())
}

#[derive(Serialize)]
pub(crate) struct Status {
    #[serde(flatten)]
    pub event: Completion,
    state: String,
    blocker: Option<String>,
}

fn status(row: &Row<'_>) -> rusqlite::Result<Status> {
    Ok(Status {
        event: event(row)?,
        state: row.get(8)?,
        blocker: row.get(9)?,
    })
}

const STATUS: &str = "COALESCE(d.state,'pending'),
    CASE WHEN d.state='acknowledged' THEN NULL
         WHEN b.removed_ms IS NOT NULL THEN 'Owner was removed.'
         WHEN b.takes_messages=0 THEN 'Owner has paused incoming messages.'
         ELSE d.blocker END";

const FROM: &str = "FROM job_completions c JOIN job_attempts a USING (job_id,attempt)
    JOIN bots b ON b.id=c.owner_bot_id LEFT JOIN job_deliveries d USING (job_id,attempt)";

pub(crate) fn attention(db: &Connection) -> rusqlite::Result<Vec<Status>> {
    db.prepare_cached(&format!(
        "SELECT {EVENT},{STATUS} {FROM}
         WHERE d.acknowledged_ms IS NULL ORDER BY c.created_ms DESC,c.job_id,c.attempt LIMIT 101"
    ))?.query_map([], status)?.collect()
}

pub(crate) fn status_for(db: &Connection, job: &str, attempt: i64) -> rusqlite::Result<Option<Status>> {
    db.query_row(&format!(
        "SELECT {EVENT},{STATUS} {FROM} WHERE c.job_id=?1 AND c.attempt=?2"
    ), params![job, attempt], status).optional()
}

/// An owner can recover the same event by ID even when its last terminal write was ambiguous.
pub(super) fn inbox(
    ctx: &Ctx<'_>,
    owner: &str,
    id: Option<&str>,
) -> rusqlite::Result<Result<String, String>> {
    if let Some(id) = id {
        let Some((job, attempt)) = event_key(id) else {
            return Ok(Err("Use a completion ID in JOB:ATTEMPT form.".into()));
        };
        let found = status_for(ctx.db, job, attempt)?
            .filter(|item| item.event.owner_bot_id == owner);
        return Ok(found.map_or_else(
            || Err("You have no completion with that ID.".into()),
            |item| Ok(serde_json::to_string(&item).expect("completion status serializes")),
        ));
    }
    let items = ctx.db.prepare_cached(&format!(
        "SELECT {EVENT},{STATUS} {FROM} WHERE c.owner_bot_id=?1 AND d.acknowledged_ms IS NULL
         ORDER BY c.created_ms,c.job_id,c.attempt LIMIT 100"
    ))?.query_map([owner], status)?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(Ok(serde_json::to_string(&items).expect("completion inbox serializes")))
}

/// ACK is the sole consumption boundary. A retry, including from a replacement, returns the original key.
pub(super) fn ack(
    ctx: &Ctx<'_>,
    owner: &str,
    launch: i64,
    id: &str,
) -> rusqlite::Result<Result<String, String>> {
    let Some((job, attempt)) = event_key(id) else {
        return Ok(Err("Use a completion ID in JOB:ATTEMPT form.".into()));
    };
    let Some(item) = status_for(ctx.db, job, attempt)?
        .filter(|item| item.event.owner_bot_id == owner)
    else {
        return Ok(Err("You have no completion with that ID.".into()));
    };
    let outbox = ctx.db.query_row(
        "SELECT outbox FROM job_deliveries WHERE job_id=?1 AND attempt=?2",
        params![job, attempt],
        |r| r.get::<_, i64>(0),
    ).optional()?;
    let outbox = match outbox {
        Some(outbox) => outbox,
        None => stage(ctx, &item.event)?,
    };
    ctx.db.execute(
        "UPDATE job_deliveries SET state='acknowledged',blocker=NULL,retry_ms=0,
           next_step_token=lower(hex(randomblob(16))),acknowledged_ms=?2,acknowledged_launch=?3
         WHERE outbox=?1 AND state!='acknowledged'",
        params![outbox, ctx.now, launch],
    )?;
    let token: String = ctx.db.query_row(
        "SELECT next_step_token FROM job_deliveries WHERE outbox=?1",
        [outbox], |r| r.get(0),
    )?;
    Ok(Ok(token))
}

#[derive(Clone, Copy)]
pub(crate) enum Blocker {
    Removed,
    Paused,
    Unmapped,
    Core,
    Unsupported,
    Busy,
    Prompt,
    NotReady,
    Changed,
}

impl Blocker {
    fn text(self) -> &'static str {
        match self {
            Self::Removed => "Owner was removed.",
            Self::Paused => "Owner has paused incoming messages.",
            Self::Unmapped => "Owner has no eligible session mapping.",
            Self::Core => "Herdr Core is unavailable.",
            Self::Unsupported => "Herdr Core has no guarded completion delivery.",
            Self::Busy => "Owner has an active turn.",
            Self::Prompt => "Owner is waiting at a provider prompt.",
            Self::NotReady => "Owner's session is not ready.",
            Self::Changed => "Owner's session or turn changed.",
        }
    }

    fn notifies_main(self) -> bool {
        matches!(self, Self::Removed | Self::Paused | Self::Unmapped)
    }
}

pub(crate) fn availability(agent: &Terminal) -> Result<(), Blocker> {
    match agent.status.as_ref().map(|status| status.state.as_str()) {
        Some("idle" | "done") if agent.require_live().is_ok() => Ok(()),
        Some("working") => Err(Blocker::Busy),
        Some("blocked") => Err(Blocker::Prompt),
        _ => Err(Blocker::NotReady),
    }
}

pub(crate) fn defer(ctx: &Ctx<'_>, outbox: i64, blocker: Blocker) -> rusqlite::Result<()> {
    ctx.db.execute(
        "UPDATE job_deliveries SET blocker=?2,retry_ms=?3
         WHERE outbox=?1 AND state!='acknowledged'",
        params![outbox, blocker.text(), ctx.now + RETRY_MS],
    )?;
    if !ctx.set.completion_fallback_to_main || !blocker.notifies_main() {
        return Ok(());
    }
    let Some(main) = super::main_bot(ctx.db)?.filter(|main| main.takes_initiative) else {
        return Ok(());
    };
    let raised = ctx.db.query_row(
        "UPDATE job_deliveries AS d SET fallback_notified=1
         WHERE outbox=?1 AND state!='acknowledged' AND fallback_notified=0
           AND EXISTS (SELECT 1 FROM job_completions c WHERE c.job_id=d.job_id
                       AND c.attempt=d.attempt AND c.owner_bot_id!=?2)
         RETURNING job_id,attempt",
        params![outbox, main.id],
        |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?)),
    ).optional()?;
    if let Some((job, attempt)) = raised {
        rules::entry(ctx, &main.id, "notice",
            &format!("Job completion {job}:{attempt} is waiting for its owner. {}", blocker.text()),
            rules::About { code: Some("job_completion_blocked"), ..Default::default() },
            true, true)?;
    }
    Ok(())
}

pub(super) fn due(ctx: &Ctx<'_>, outbox: i64) -> rusqlite::Result<bool> {
    ctx.db.query_row(
        "SELECT EXISTS (SELECT 1 FROM job_deliveries
                        WHERE outbox=?1 AND state!='acknowledged' AND retry_ms<=?2)",
        params![outbox, ctx.now],
        |row| row.get(0),
    )
}

/// Reconcile the last offer against the recorded task. A pending task may still be sending.
/// Opening the journal converts abandoned pending tasks to unconfirmed.
pub(crate) fn reconcile(ctx: &Ctx<'_>, outbox: i64) -> rusqlite::Result<()> {
    let state: Option<String> = ctx.db.query_row(
        "SELECT j.state FROM bot_outbox o JOIN journal j ON j.id=o.task WHERE o.id=?1",
        [outbox], |r| r.get(0),
    ).optional()?;
    let (state, outbox_state, blocker) = match state.as_deref() {
        Some("sent") => ("offered", "typed", None),
        Some("not_sent") => ("pending", "pending", Some(Blocker::Changed.text())),
        Some("unconfirmed" | "start_not_observed") => ("uncertain", "typing", Some(UNCERTAIN)),
        _ => return Ok(()),
    };
    let changed = ctx.db.execute(
        "UPDATE job_deliveries SET state=?2,blocker=?3,retry_ms=?4
         WHERE outbox=?1 AND state='offered'
           AND EXISTS (SELECT 1 FROM bot_outbox WHERE id=?1 AND state='typing')",
        params![outbox, state, blocker, ctx.now + RETRY_MS],
    )?;
    // Later probes may add blockers without overwriting the recorded outcome or an ACK.
    if changed != 0 && outbox_state != "typing" {
        ctx.db.execute(
            "UPDATE bot_outbox SET state=?2,typed_ms=CASE WHEN ?2='typed' THEN ?3 END WHERE id=?1",
            params![outbox, outbox_state, ctx.now],
        )?;
    }
    Ok(())
}

/// Recheck owner and launch in the same transaction as the journal intent and offer.
pub(crate) fn reserve(
    ctx: &Ctx<'_>,
    outbox: i64,
    owner: &str,
    core: &str,
    agent: &Terminal,
    text: &str,
) -> rusqlite::Result<Option<i64>> {
    let Some(key) = agent.launch_key() else {
        return Ok(None);
    };
    match super::one(ctx.db, owner)? {
        None => {
            defer(ctx, outbox, Blocker::Removed)?;
            return Ok(None);
        }
        Some(bot) if !bot.takes_messages => {
            defer(ctx, outbox, Blocker::Paused)?;
            return Ok(None);
        }
        Some(_) => (),
    }
    let Some(launch) = owner_launch(ctx.db, core, key, owner)? else {
        defer(ctx, outbox, Blocker::Unmapped)?;
        return Ok(None);
    };
    let may_offer: bool = ctx.db.query_row(
        "SELECT EXISTS (
           SELECT 1 FROM job_deliveries d JOIN bot_outbox o ON o.id=d.outbox
           WHERE d.outbox=?1 AND o.bot=?2 AND d.state!='acknowledged' AND d.retry_ms<=?3
             AND NOT EXISTS (
               SELECT 1 FROM job_delivery_offers f JOIN journal j ON j.id=f.task
               WHERE f.outbox=d.outbox AND (j.state='pending' OR (f.launch=?4 AND j.state!='not_sent'))
             )
         )",
        params![outbox, owner, ctx.now, launch], |r| r.get(0),
    )?;
    if !may_offer {
        // The same launch already has an offer. Keep polling for a replacement,
        // and clear transient availability blockers that have since resolved.
        ctx.db.execute(
            "UPDATE job_deliveries SET retry_ms=?2,
                blocker=CASE WHEN state='uncertain' THEN ?3 END
             WHERE outbox=?1 AND retry_ms<=?4 AND state IN ('offered','uncertain')
               AND EXISTS (
                 SELECT 1 FROM job_delivery_offers f JOIN journal j ON j.id=f.task
                 WHERE f.outbox=?1 AND f.launch=?5 AND j.state NOT IN ('pending','not_sent')
               )",
            params![outbox, ctx.now + RETRY_MS, UNCERTAIN, ctx.now, launch],
        )?;
        return Ok(None);
    }
    let busy: bool = ctx.db.query_row(
        "SELECT EXISTS(SELECT 1 FROM journal WHERE core_id=?1 AND address=?2
                       AND created_ms=?3 AND kind='task' AND state='pending')",
        params![core, agent.address, agent.created_ms], |r| r.get(0),
    )?;
    if busy {
        defer(ctx, outbox, Blocker::Busy)?;
        return Ok(None);
    }
    let task = ctx.db.query_row(
        "INSERT INTO journal(core_id,address,created_ms,agent,kind,state,text,at_ms)
         VALUES (?1,?2,?3,?4,'task','pending',?5,?6) RETURNING id",
        params![core, agent.address, agent.created_ms, agent.display_name(), text, ctx.now],
        |r| r.get::<_, i64>(0),
    )?;
    ctx.db.execute(
        "INSERT INTO job_delivery_offers(task,outbox,launch) VALUES (?1,?2,?3)",
        params![task, outbox, launch],
    )?;
    ctx.db.execute(
        "UPDATE bot_outbox SET task=?2,state='typing',typed_ms=NULL WHERE id=?1", params![outbox, task],
    )?;
    ctx.db.execute(
        "UPDATE job_deliveries SET state='offered',blocker=NULL,retry_ms=0 WHERE outbox=?1", [outbox],
    )?;
    Ok(Some(task))
}

pub(super) fn owner_launch(
    db: &Connection,
    core: &str,
    key: &str,
    owner: &str,
) -> rusqlite::Result<Option<i64>> {
    let launch = db.query_row(
        "SELECT j.id,j.agent FROM journal j WHERE j.launch_key=?1 AND j.core_id=?2
           AND NOT EXISTS (SELECT 1 FROM helpers WHERE launch=j.id)",
        params![key, core], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?)),
    ).optional()?;
    let Some((launch, name)) = launch else {
        return Ok(None);
    };
    Ok((mapped_owner(db, &name)?.as_deref() == Some(owner)).then_some(launch))
}

pub(super) fn mapped_owner(db: &Connection, name: &str) -> rusqlite::Result<Option<String>> {
    let bots = super::all(db)?;
    let mut exact = bots.iter().filter(|bot| bot.agent_name == name);
    if let Some(bot) = exact.next() {
        return Ok(exact.next().is_none().then(|| bot.id.clone()));
    }
    let mut renamed = bots.iter().filter(|bot| name.contains('-')
        && super::suffix(name) == super::suffix(&bot.agent_name));
    Ok(renamed.next().filter(|_| renamed.next().is_none()).map(|bot| bot.id.clone()))
}

pub(crate) fn reconcile_one(history: &crate::History, outbox: i64) -> Result<(), StoreError> {
    super::write(history, |ctx| reconcile(ctx, outbox))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{bots::{Settings, testing, write}, jobs::{self, tests as fixture}};
    use serde_json::json;

    #[test]
    fn gapplan_03_unit_only_an_idle_live_terminal_can_receive_a_completion() {
        for (state, status, expected) in [
            ("live", Some("idle"), None),
            ("live", Some("done"), None),
            ("live", Some("working"), Some(Blocker::Busy)),
            ("live", Some("blocked"), Some(Blocker::Prompt)),
            ("live", None, Some(Blocker::NotReady)),
            ("live", Some("unknown"), Some(Blocker::NotReady)),
            ("dead", Some("idle"), Some(Blocker::NotReady)),
        ] {
            let terminal = serde_json::from_value(json!({
                "address":"t1", "created_ms":1, "state":state,
                "status":status.map(|state| json!({"state":state})),
            })).unwrap();
            assert_eq!(availability(&terminal).err().map(Blocker::text), expected.map(Blocker::text));
        }
    }

    fn new_event(history: &crate::History) -> (String, i64) {
        let mut db = history.db().unwrap();
        let job = fixture::submit_fixture(&mut db, "completion-unit");
        assert_eq!(fixture::dispatch(&mut db, &job), jobs::Dispatch::Recorded);
        jobs::finish(&mut db, &job.id, fixture::ATTEMPT, &fixture::success()).unwrap();
        drop(db);
        write(history, stage_waiting).unwrap();
        let outbox = history.db().unwrap()
            .query_row("SELECT outbox FROM job_deliveries", [], |r| r.get(0)).unwrap();
        (format!("{}:{}", job.id, fixture::ATTEMPT), outbox)
    }

    #[test]
    fn gapplan_03_unit_wrong_owner_cannot_read_or_acknowledge_event() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let db = history.db().unwrap();
        super::super::register(&db, &super::super::Registration {
            id: fixture::OWNER.into(), name: Some("Job Owner".into()), ..Default::default()
        }, 2).unwrap().unwrap();
        drop(db);
        let (id, outbox) = new_event(&history);
        let key = testing::session(&history, "Jarvis", "t1");
        write(&history, |ctx| {
            let other = testing::id_of("Jarvis");
            let launch = owner_launch(ctx.db, "core", &key, &other)?.unwrap();
            assert!(inbox(ctx, &other, Some(&id))?.is_err());
            assert_eq!(inbox(ctx, &other, None)?.unwrap(), "[]");
            assert!(ack(ctx, &other, launch, &id)?.is_err());
            let state: String = ctx.db.query_row(
                "SELECT state FROM job_deliveries WHERE outbox=?1", [outbox], |r| r.get(0))?;
            assert_eq!(state, "pending");
            Ok(())
        }).unwrap();
    }

    #[test]
    fn gapplan_03_unit_ack_retry_returns_one_durable_consumption_key() {
        let scratch = tempfile::tempdir().unwrap();
        let history = fixture::journal(&scratch.path().join("journal"));
        let (id, outbox) = new_event(&history);
        let (launch, _) = history.start_launch("core", "job-owner-jobown", "", None, "{}", "")
            .unwrap().unwrap();
        let token = testing::at(&history, 1_000, &Settings::default(), |ctx| {
            ack(ctx, fixture::OWNER, launch, &id)
        }).unwrap();
        testing::at(&history, 2_000, &Settings::default(), |ctx| {
            assert_eq!(ack(ctx, fixture::OWNER, launch, &id)?.unwrap(), token);
            let count: i64 = ctx.db.query_row(
                "SELECT COUNT(*) FROM job_deliveries
                 WHERE outbox=?1 AND state='acknowledged' AND next_step_token=?2 AND acknowledged_ms=1000",
                params![outbox, token], |r| r.get(0))?;
            assert_eq!(count, 1);
            Ok(())
        });
    }

    #[test]
    fn gapplan_03_unit_fallback_is_opt_in_and_notifies_main_only_once() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let db = history.db().unwrap();
        super::super::register(&db, &super::super::Registration {
            id: fixture::OWNER.into(), name: Some("Job Owner".into()), ..Default::default()
        }, 2).unwrap().unwrap();
        drop(db);
        let (_, outbox) = new_event(&history);
        let count = |ctx: &Ctx<'_>| -> rusqlite::Result<(i64, bool)> {
            ctx.db.query_row(
                "SELECT (SELECT COUNT(*) FROM bot_history WHERE bot='jarvis-id'
                  AND code='job_completion_blocked'),fallback_notified FROM job_deliveries WHERE outbox=?1",
                [outbox], |r| Ok((r.get(0)?, r.get(1)?)),
            )
        };
        let set = Settings::default();
        testing::at(&history, 1_000, &set, |ctx| {
            defer(ctx, outbox, Blocker::Paused)?;
            assert_eq!(count(ctx)?, (0, false));
            Ok(())
        });
        let set = Settings { completion_fallback_to_main: true, ..set };
        testing::at(&history, 3_000, &set, |ctx| {
            defer(ctx, outbox, Blocker::Busy)?;
            defer(ctx, outbox, Blocker::Prompt)?;
            defer(ctx, outbox, Blocker::Core)?;
            assert_eq!(count(ctx)?, (0, false));
            defer(ctx, outbox, Blocker::Unmapped)?;
            defer(ctx, outbox, Blocker::Removed)?;
            assert_eq!(count(ctx)?, (1, true));
            let owner: String = ctx.db.query_row(
                "SELECT bot FROM bot_outbox WHERE id=?1", [outbox], |r| r.get(0))?;
            assert_eq!(owner, fixture::OWNER);
            Ok(())
        });
    }
}
