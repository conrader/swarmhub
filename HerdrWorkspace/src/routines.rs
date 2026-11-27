pub(crate) mod transfer;
use crate::{
    core::Terminal,
    groups::Target,
    history::{History, State as TaskState, StoreError, background_write, defer_if_busy, now},
};
use chrono::{
    DateTime, Datelike, LocalResult, NaiveDate, NaiveTime, TimeDelta, TimeZone, Utc, Weekday,
};
use chrono_tz::Tz;
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

fn webhook_hash(secret: &str) -> String {
    format!("{:x}", Sha256::digest(secret.as_bytes()))
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum WebhookSource {
    Github,
    Slack,
}

pub enum HookAuth<'a> {
    Bearer(&'a str),
    VerifiedSlack,
    Github {
        master: &'a str,
        signature: &'a [u8],
        body: &'a [u8],
    },
}

fn github_key(master: &str, id: i64, salt: &str) -> String {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, master.as_bytes());
    let tag = ring::hmac::sign(
        &key,
        format!("swarmhub-github-routine/v1:{id}:{salt}").as_bytes(),
    );
    use std::fmt::Write;
    let mut output = String::with_capacity(64);
    for byte in tag.as_ref() {
        let _ = write!(output, "{byte:02x}");
    }
    output
}

fn webhook_authorized(db: &Connection, id: i64, auth: &HookAuth<'_>) -> rusqlite::Result<bool> {
    let settings: Option<(Option<String>, Option<String>)> = db
        .query_row(
            "SELECT webhook_hash,json_extract(schedule,'$.source') FROM routines WHERE id=?1
               AND json_extract(schedule,'$.kind')='webhook'",
            [id],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .optional()?;
    Ok(settings.is_some_and(|(saved, source)| match auth {
        HookAuth::Bearer(secret) => {
            source.is_none()
                && saved.is_some_and(|hash| crate::token_matches(&webhook_hash(secret), &hash))
        }
        HookAuth::VerifiedSlack => source.as_deref() == Some("slack"),
        HookAuth::Github {
            master,
            signature,
            body,
        } => {
            source.as_deref() == Some("github")
                && saved
                    .as_deref()
                    .and_then(|hash| hash.strip_prefix("github:"))
                    .is_some_and(|salt| {
                        let key = ring::hmac::Key::new(
                            ring::hmac::HMAC_SHA256,
                            github_key(master, id, salt).as_bytes(),
                        );
                        ring::hmac::verify(&key, body, signature).is_ok()
                    })
        }
    }))
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum Schedule {
    Webhook {
        #[serde(skip_serializing_if = "Option::is_none")]
        source: Option<WebhookSource>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        filters: Vec<WebhookFilter>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        review: bool,
    },
    Interval {
        minutes: u32,
    },
    Daily {
        hour: u8,
        minute: u8,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timezone: Option<Tz>,
        weekdays: bool,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WebhookFilter {
    field: String,
    equals: String,
}

impl WebhookFilter {
    fn valid(&self) -> bool {
        self.field.len() <= 128
            && self.field.split('.').count() <= 8
            && self.field.split('.').all(|part| {
                !part.is_empty()
                    && part
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"_-".contains(&byte))
            })
            && !self.equals.trim().is_empty()
            && self.equals.chars().count() <= 160
            && !self.equals.chars().any(char::is_control)
    }

    fn matches(&self, event: Option<&Value>) -> bool {
        event
            .and_then(|root| {
                self.field
                    .split('.')
                    .try_fold(root, |value, key| value.as_object()?.get(key))
            })
            .and_then(Value::as_str)
            .is_some_and(|value| value == self.equals)
    }
}

impl Schedule {
    pub fn source(&self) -> Option<&'static str> {
        match self {
            Self::Webhook {
                source: Some(WebhookSource::Github),
                ..
            } => Some("github"),
            Self::Webhook {
                source: Some(WebhookSource::Slack),
                ..
            } => Some("slack"),
            _ => None,
        }
    }

    pub fn valid_slack_scope(&self) -> bool {
        let Self::Webhook {
            source: Some(WebhookSource::Slack),
            filters,
            ..
        } = self
        else {
            return true;
        };
        filters.iter().any(|rule| {
            rule.field == "team_id" && crate::slack_events::valid_slack_id(&rule.equals, b"T")
        }) && filters.iter().any(|rule| {
            rule.field == "channel" && crate::slack_events::valid_slack_id(&rule.equals, b"CG")
        })
    }

    pub fn valid(&self, at: i64) -> bool {
        match self {
            Self::Webhook { filters, .. } => {
                filters.len() <= 4
                    && self.valid_slack_scope()
                    && filters.iter().enumerate().all(|(i, rule)| {
                        rule.valid()
                            && !filters[..i]
                                .iter()
                                .any(|previous| previous.field == rule.field)
                    })
            }
            _ => self.next(at).is_some(),
        }
    }

    pub fn next(&self, after: i64) -> Option<i64> {
        self.next_in(after, chrono_tz::UTC)
    }

    fn next_in(&self, after: i64, user_zone: Tz) -> Option<i64> {
        match *self {
            Self::Webhook { .. } => None,
            Self::Interval { minutes } if (1..=43_200).contains(&minutes) => {
                after.checked_add(i64::from(minutes) * 60_000)
            }
            Self::Interval { .. } => None,
            Self::Daily {
                hour,
                minute,
                timezone,
                weekdays,
            } => next_local(after, timezone.unwrap_or(user_zone), hour, minute, weekdays),
        }
    }

    fn advance(&self, due: i64, at: i64, zone: Tz) -> Option<i64> {
        if let Self::Interval { .. } = self {
            let period = self.next(due)?.checked_sub(due)?;
            let future_slot = at.checked_sub(due)?.checked_div(period)?.checked_add(1)?;
            due.checked_add(period.checked_mul(future_slot)?)
        } else {
            self.next_in(at, zone)
        }
    }
}

/// A wall-clock time fires once on a repeated hour. In a gap, use the first
/// valid minute on that date, including when the day's offset changed at midnight.
pub(crate) fn local_on_date(date: NaiveDate, zone: Tz, hour: u8, minute: u8) -> Option<i64> {
    let time = NaiveTime::from_hms_opt(hour.into(), minute.into(), 0)?;
    let nominal = date.and_time(time);
    for offset in 0..=180 {
        let candidate = nominal.checked_add_signed(TimeDelta::minutes(offset))?;
        if candidate.date() != date {
            break;
        }
        match zone.from_local_datetime(&candidate) {
            LocalResult::Single(value) => return Some(value.timestamp_millis()),
            LocalResult::Ambiguous(first, second) => {
                return Some(first.timestamp_millis().min(second.timestamp_millis()));
            }
            LocalResult::None => {}
        }
    }
    None
}

pub(crate) fn next_local(
    after: i64,
    zone: Tz,
    hour: u8,
    minute: u8,
    weekdays: bool,
) -> Option<i64> {
    NaiveTime::from_hms_opt(hour.into(), minute.into(), 0)?;
    let mut date = DateTime::<Utc>::from_timestamp_millis(after)?
        .with_timezone(&zone)
        .date_naive();
    for _ in 0..8 {
        if (!weekdays || !matches!(date.weekday(), Weekday::Sat | Weekday::Sun))
            && let Some(at) = local_on_date(date, zone, hour, minute).filter(|at| *at > after)
        {
            return Some(at);
        }
        date = date.succ_opt()?;
    }
    None
}

pub(crate) fn schedule_lateness_cutoff(at: i64) -> i64 {
    at.saturating_sub(30_000)
}

pub(crate) fn rezone(db: &Connection, at: i64, zone: Tz) -> rusqlite::Result<()> {
    // Give recently due occurrences time to claim an idle target. Leave all
    // due timestamps for claim_schedule to record and advance in the new zone.
    db.execute(
        "UPDATE routines SET run_due_after_rezone=(next_at >= ?2) WHERE state='active' AND next_at <= ?1
           AND json_extract(schedule,'$.kind')='daily' AND json_extract(schedule,'$.timezone') IS NULL",
        [at, schedule_lateness_cutoff(at)],
    )?;
    let routines = db.prepare(
        "SELECT * FROM routines WHERE state='active' AND (next_at IS NULL OR next_at > ?1)
           AND json_extract(schedule,'$.kind')='daily' AND json_extract(schedule,'$.timezone') IS NULL",
    )?.query_map([at], from_row)?.collect::<Result<Vec<_>, _>>()?;
    for routine in routines {
        db.execute(
            "UPDATE routines SET next_at=?2 WHERE id=?1",
            params![routine.id, routine.schedule.next_in(at, zone)],
        )?;
    }
    Ok(())
}

#[derive(Serialize)]
pub struct Routine {
    pub id: i64,
    pub core: String,
    pub target: Target,
    pub agent: String,
    pub name: String,
    pub task: String,
    pub schedule: Schedule,
    pub state: String,
    pub next_at: Option<i64>,
    pub webhook_ready: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<i64>,
    pub owner_bot: Option<String>,
}

const WITH_OWNER: &str = "SELECT r.*,
   (SELECT j.profile_id FROM journal j WHERE j.core_id=r.core AND j.address=r.address
    AND j.created_ms=r.created_ms AND j.launch_key IS NOT NULL ORDER BY j.id DESC LIMIT 1)
   AS owner_profile,
   coalesce(r.transferred_owner, (SELECT j.parent_bot_id FROM journal j WHERE j.core_id=r.core AND j.address=r.address
    AND j.created_ms=r.created_ms AND j.launch_key IS NOT NULL ORDER BY j.id DESC LIMIT 1)
   ) AS owner_bot FROM routines r";

#[derive(Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Binding {
    pub core: String,
    pub target: Target,
}

pub enum Move {
    Changed,
    Missing,
    Stale,
    WrongProfile,
    Busy,
}

#[derive(Serialize)]
pub struct Run {
    pub id: i64,
    pub kind: String,
    pub at_ms: i64,
    pub state: String,
    pub detail: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub task_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub conversation: Option<RunConversation>,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub awaiting_result: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<RunResult>,
}

#[derive(Serialize)]
pub struct RunConversation {
    core: String,
    #[serde(flatten)]
    target: Target,
    agent: String,
}

#[derive(Serialize)]
pub struct RunResult {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) page: Option<ResultPage>,
    pub id: i64,
    pub state: String,
    pub summary: String,
    pub at_ms: i64,
}

pub enum Outcome {
    Succeeded,
    Failed,
}

impl Outcome {
    pub fn state(&self) -> &'static str {
        match self {
            Self::Succeeded => "succeeded",
            Self::Failed => "failed",
        }
    }
}

pub struct Dispatch {
    pub routine: Routine,
    pub run: i64,
    pub event: Option<String>,
}

pub enum HookRun {
    PreviouslyHandled,
    Accepted(Box<Dispatch>),
    Duplicate(i64),
    Queued { id: i64, duplicate: bool },
    Dismissed,
    ReviewFull,
    Ignored,
    Unauthorized,
    Inactive,
    Busy,
    RateLimited,
}

#[derive(Serialize)]
pub struct WebhookReview {
    id: i64,
    at_ms: i64,
    payload: Option<Value>,
    stale: bool,
}

pub enum ReviewDecision {
    Run(Box<Dispatch>),
    Dismissed,
    Missing,
    Stale,
    Inactive,
    Busy,
}

fn review_binding(routine: &Routine) -> String {
    let snapshot = serde_json::json!([
        routine.name,
        routine.task,
        routine.core,
        routine.target,
        routine.schedule
    ]);
    format!("{:x}", Sha256::digest(snapshot.to_string().as_bytes()))
}

pub enum Control {
    Pause,
    Resume,
    Archive,
}

impl History {
    pub fn create_routine(
        &self,
        core: &str,
        agent: &Terminal,
        name: &str,
        task: &str,
        schedule: &Schedule,
    ) -> Result<i64, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let next = schedule.next_in(now(), crate::person_profile::effective_timezone(&tx)?);
        let id = tx.query_row(
            "INSERT INTO routines (core,address,created_ms,agent,name,task,schedule,state,next_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,'active',?8) RETURNING id",
            params![
                core,
                agent.address,
                agent.created_ms,
                agent.display_name(),
                name,
                task,
                encode(schedule)?,
                next
            ],
            |row| row.get(0),
        )?;
        tx.commit()?;
        Ok(id)
    }

    pub fn routines(&self) -> Result<Vec<Routine>, StoreError> {
        let db = self.db()?;
        let mut stmt = db.prepare(&format!("{WITH_OWNER} ORDER BY state='archived',id DESC"))?;
        Ok(stmt.query_map([], with_owner)?.collect::<Result<_, _>>()?)
    }

    pub fn routine(&self, id: i64) -> Result<Option<Routine>, StoreError> {
        Ok(self
            .db()?
            .query_row(&format!("{WITH_OWNER} WHERE id=?1"), [id], with_owner)
            .optional()?)
    }

    pub fn move_routine(
        &self,
        id: i64,
        from: &Binding,
        to: &Binding,
        agent: &Terminal,
    ) -> Result<Move, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let Some(routine) = tx
            .query_row(
                &format!("{WITH_OWNER} WHERE id=?1 AND state!='archived'"),
                [id],
                with_owner,
            )
            .optional()?
        else {
            return Ok(Move::Missing);
        };
        if routine.core != from.core || routine.target != from.target || from == to {
            return Ok(Move::Stale);
        }
        let owner: Option<i64> = tx.query_row(
            "SELECT profile_id FROM journal WHERE launch_key=?1 AND core_id=?2 AND address=?3 AND created_ms=?4",
            params![agent.launch_key(),to.core,to.target.address,to.target.created_ms], |row| row.get(0),
        ).optional()?.flatten();
        if owner.is_none() || owner != routine.profile_id {
            return Ok(Move::WrongProfile);
        }
        let busy: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM routine_runs WHERE routine=?1 AND state='pending')",
            [id],
            |row| row.get(0),
        )?;
        if busy {
            return Ok(Move::Busy);
        }
        tx.execute(
            "UPDATE routines SET core=?2,address=?3,created_ms=?4,agent=?5,state='paused',
             next_at=NULL,run_due_after_rezone=0 WHERE id=?1",
            params![id,to.core,to.target.address,to.target.created_ms,agent.display_name()],
        )?;
        tx.commit()?;
        Ok(Move::Changed)
    }

    pub fn edit_routine(
        &self,
        id: i64,
        name: &str,
        task: &str,
        schedule: &Schedule,
    ) -> Result<bool, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let next = schedule.next_in(now(), crate::person_profile::effective_timezone(&tx)?);
        let webhook = matches!(schedule, Schedule::Webhook { .. });
        let source = schedule.source();
        let schedule = encode(schedule)?;
        let changed = tx.execute(
            "UPDATE routines SET name=?2, task=?3,
             next_at=CASE WHEN state!='active' THEN NULL WHEN schedule=?4 THEN next_at ELSE ?5 END,
             run_due_after_rezone=CASE WHEN schedule=?4 THEN run_due_after_rezone ELSE 0 END,
             schedule=?4,webhook_hash=CASE WHEN ?6 AND json_extract(schedule,'$.source') IS ?7 THEN webhook_hash END
             WHERE id=?1 AND state!='archived'",
            params![id, name, task, schedule, next, webhook, source],
        )? == 1;
        tx.commit()?;
        Ok(changed)
    }

    pub fn control_routine(&self, routine: &Routine, action: Control) -> Result<bool, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let (state, next_at) = match action {
            Control::Pause => ("paused", None),
            Control::Archive => ("archived", None),
            Control::Resume => (
                "active",
                routine
                    .schedule
                    .next_in(now(), crate::person_profile::effective_timezone(&tx)?),
            ),
        };
        let changed = tx.execute(
            "UPDATE routines SET state=?2,next_at=?3,run_due_after_rezone=0,
             webhook_hash=CASE WHEN ?2!='archived' THEN webhook_hash END WHERE id=?1 AND state!='archived'",
            params![routine.id, state, next_at],
        )? == 1;
        if changed && state == "archived" {
            tx.execute("UPDATE webhook_reviews SET dismissed=1,payload=NULL WHERE routine=?1 AND dismissed=0",[routine.id])?;
        }
        tx.commit()?;
        Ok(changed)
    }

    pub fn routine_runs(&self, id: i64) -> Result<Vec<Run>, StoreError> {
        let db = self.db()?;
        let mut query = db.prepare(
            "SELECT r.id,r.kind,r.at_ms,r.state,r.detail,r.task_id,
                    r.result_token IS NOT NULL AND r.state IN ('pending','sent','start_not_observed','unconfirmed'),
                    r.result_id,r.result_state,substr(j.text,1,280),j.at_ms,
                    task.core_id,task.address,task.created_ms,task.agent
             FROM routine_runs r LEFT JOIN journal j ON j.id=r.result_id
             LEFT JOIN journal task ON task.id=r.task_id
             WHERE r.routine=?1 ORDER BY r.id DESC LIMIT 30",
        )?;
        Ok(query
            .query_map([id], |row| {
                Ok(Run {
                    id: row.get(0)?,
                    kind: row.get(1)?,
                    at_ms: row.get(2)?,
                    state: row.get(3)?,
                    detail: row.get(4)?,
                    task_id: row.get(5)?,
                    conversation: match row.get(11)? {
                        Some(core) => Some(RunConversation {
                            core,
                            target: Target {
                                address: row.get(12)?,
                                created_ms: row.get(13)?,
                            },
                            agent: row.get(14)?,
                        }),
                        None => None,
                    },
                    awaiting_result: row.get(6)?,
                    result: match row.get(7)? {
                        Some(id) => Some(RunResult {
                            page: result_page(&db, id)?,
                            id,
                            state: row.get(8)?,
                            summary: row.get(9)?,
                            at_ms: row.get(10)?,
                        }),
                        None => None,
                    },
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    pub fn claim_test(&self, routine: Routine) -> Result<Option<Dispatch>, StoreError> {
        let mut db = self.db()?;
        let txn = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let available: bool = txn.query_row("SELECT state!='archived' FROM routines WHERE id=?", [routine.id], |r| r.get(0))?;
        if !available || pending(&txn, &routine)? {
            return Ok(None);
        }
        let run = make_run(&txn, routine.id, "test", now(), "pending", None)?;
        txn.commit()?;
        Ok(Some(Dispatch {
            routine,
            run,
            event: None,
        }))
    }

    pub fn rotate_webhook(
        &self,
        id: i64,
        master: &str,
    ) -> Result<Option<(String, bool)>, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let Some(github) = tx
            .query_row(
                "SELECT json_extract(schedule,'$.source') IS 'github' FROM routines
             WHERE id=?1 AND state!='archived' AND json_extract(schedule,'$.kind')='webhook'
               AND json_extract(schedule,'$.source') IS NOT 'slack'",
                [id],
                |row| row.get::<_, bool>(0),
            )
            .optional()?
        else {
            return Ok(None);
        };
        let random: String =
            tx.query_row("SELECT lower(hex(randomblob(32)))", [], |row| row.get(0))?;
        let (secret, saved) = if github {
            (github_key(master, id, &random), format!("github:{random}"))
        } else {
            let hash = webhook_hash(&random);
            (random, hash)
        };
        tx.execute(
            "UPDATE routines SET webhook_hash=?2 WHERE id=?1",
            params![id, saved],
        )?;
        tx.commit()?;
        Ok(Some((secret, github)))
    }

    pub fn authorize_github(&self, id: i64, auth: &HookAuth<'_>) -> Result<bool, StoreError> {
        Ok(webhook_authorized(&*self.db()?, id, auth)?)
    }

    pub fn slack_routines(&self, team: &str, channel: &str) -> Result<Vec<i64>, StoreError> {
        let db = self.db()?;
        let mut query = db.prepare(
            "SELECT id FROM routines r WHERE state='active' AND json_extract(r.schedule,'$.source')='slack'
             AND EXISTS (SELECT 1 FROM json_each(r.schedule,'$.filters') f
                 WHERE json_extract(f.value,'$.field')='team_id' AND json_extract(f.value,'$.equals')=?1)
             AND EXISTS (SELECT 1 FROM json_each(r.schedule,'$.filters') f
                 WHERE json_extract(f.value,'$.field')='channel' AND json_extract(f.value,'$.equals')=?2)
             ORDER BY id",
        )?;
        Ok(query
            .query_map(params![team, channel], |row| row.get(0))?
            .collect::<Result<_, _>>()?)
    }

    pub fn claim_webhook(
        &self,
        id: i64,
        auth: &HookAuth<'_>,
        key: &str,
        event: Option<Value>,
    ) -> Result<HookRun, StoreError> {
        let mut db = self.db()?;
        // Invalid secrets never take the database writer lock.
        if !webhook_authorized(&db, id, auth)? {
            return Ok(HookRun::Unauthorized);
        }
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if !webhook_authorized(&tx, id, auth)? {
            return Ok(HookRun::Unauthorized);
        }
        let routine = tx.query_row("SELECT * FROM routines WHERE id=?1", [id], from_row)?;
        if let Some(id) = tx
            .query_row(
                "SELECT id FROM routine_runs WHERE routine=?1 AND event_key=?2",
                params![id, key],
                |row| row.get(0),
            )
            .optional()?
        {
            return Ok(HookRun::Duplicate(id));
        }
        if let Some((id, dismissed)) = tx
            .query_row(
                "SELECT id,dismissed FROM webhook_reviews WHERE routine=?1 AND event_key=?2",
                params![id, key],
                |row| Ok((row.get(0)?, row.get::<_, bool>(1)?)),
            )
            .optional()?
        {
            return Ok(if dismissed {
                HookRun::Dismissed
            } else {
                HookRun::Queued {
                    id,
                    duplicate: true,
                }
            });
        }
        if tx.query_row("SELECT EXISTS(SELECT 1 FROM routine_event_receipts WHERE routine=? AND digest=?)",
            params![id,webhook_hash(key)], |r| r.get::<_,bool>(0))? {
            return Ok(HookRun::PreviouslyHandled);
        }
        let Schedule::Webhook {
            filters, review, ..
        } = &routine.schedule
        else {
            return Ok(HookRun::Inactive);
        };
        if routine.state != "active" {
            return Ok(HookRun::Inactive);
        }
        if !filters.iter().all(|filter| filter.matches(event.as_ref())) {
            return Ok(HookRun::Ignored);
        }
        if !review && pending(&tx, &routine)? {
            return Ok(HookRun::Busy);
        }
        let at = now();
        let recent: i64 = tx.query_row(
            "SELECT (SELECT count(*) FROM routine_runs WHERE routine=?1 AND kind='webhook' AND at_ms>=?2)
                 + (SELECT count(*) FROM webhook_reviews WHERE routine=?1 AND at_ms>=?2)",
            params![id, at.saturating_sub(60_000)],
            |row| row.get(0),
        )?;
        if recent >= 10 {
            return Ok(HookRun::RateLimited);
        }
        let event = event.map(|event| event.to_string());
        if *review {
            let waiting: i64 = tx.query_row(
                "SELECT count(*) FROM webhook_reviews WHERE routine=?1 AND dismissed=0",
                [id],
                |row| row.get(0),
            )?;
            if waiting >= 20 {
                return Ok(HookRun::ReviewFull);
            }
            let entry = tx.query_row(
                "INSERT INTO webhook_reviews (routine,event_key,at_ms,binding,payload)
                 VALUES (?1,?2,?3,?4,?5) RETURNING id",
                params![id, key, at, review_binding(&routine), event],
                |row| row.get(0),
            )?;
            tx.commit()?;
            return Ok(HookRun::Queued {
                id: entry,
                duplicate: false,
            });
        }
        let run = tx.query_row(
            "INSERT INTO routine_runs (routine,kind,at_ms,state,event_key) VALUES (?1,'webhook',?2,'pending',?3) RETURNING id",
            params![id,at,key], |row| row.get(0),
        )?;
        tx.commit()?;
        Ok(HookRun::Accepted(Box::new(Dispatch {
            routine,
            run,
            event,
        })))
    }

    pub fn webhook_reviews(&self, routine: &Routine) -> Result<Vec<WebhookReview>, StoreError> {
        let db = self.db()?;
        let current = review_binding(routine);
        let mut query = db.prepare(
            "SELECT id,at_ms,payload,binding FROM webhook_reviews WHERE routine=?1 AND dismissed=0 ORDER BY id",
        )?;
        Ok(query
            .query_map([routine.id], |row| {
                let payload: Option<String> = row.get(2)?;
                let value = payload
                    .map(|payload| {
                        serde_json::from_str(&payload).map_err(|error| {
                            rusqlite::Error::FromSqlConversionFailure(
                                2,
                                rusqlite::types::Type::Text,
                                Box::new(error),
                            )
                        })
                    })
                    .transpose()?;
                Ok(WebhookReview {
                    id: row.get(0)?,
                    at_ms: row.get(1)?,
                    payload: value,
                    stale: row.get::<_, String>(3)? != current,
                })
            })?
            .collect::<Result<_, _>>()?)
    }

    pub fn resolve_webhook_review(
        &self,
        id: i64,
        entry: i64,
        approve: bool,
    ) -> Result<ReviewDecision, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let Some((key,binding,event)) = tx.query_row(
            "SELECT event_key,binding,payload FROM webhook_reviews WHERE routine=?1 AND id=?2 AND dismissed=0",
            params![id,entry], |row| Ok((row.get::<_,String>(0)?,row.get::<_,String>(1)?,row.get::<_,Option<String>>(2)?)),
        ).optional()? else { return Ok(ReviewDecision::Missing); };
        if !approve {
            tx.execute(
                "UPDATE webhook_reviews SET dismissed=1,payload=NULL WHERE id=?1",
                [entry],
            )?;
            tx.commit()?;
            return Ok(ReviewDecision::Dismissed);
        }
        let Some(routine) = tx
            .query_row("SELECT * FROM routines WHERE id=?1", [id], from_row)
            .optional()?
        else {
            return Ok(ReviewDecision::Missing);
        };
        if routine.state != "active" {
            return Ok(ReviewDecision::Inactive);
        }
        if binding != review_binding(&routine) {
            return Ok(ReviewDecision::Stale);
        }
        if pending(&tx, &routine)? {
            return Ok(ReviewDecision::Busy);
        }
        let run = tx.query_row(
            "INSERT INTO routine_runs (routine,kind,at_ms,state,event_key)
             VALUES (?1,'webhook',?2,'pending',?3) RETURNING id",
            params![id, now(), key],
            |row| row.get(0),
        )?;
        tx.execute("DELETE FROM webhook_reviews WHERE id=?1", [entry])?;
        tx.commit()?;
        Ok(ReviewDecision::Run(Box::new(Dispatch {
            routine,
            run,
            event,
        })))
    }

    pub fn finish_routine_run(
        &self,
        run: i64,
        state: &str,
        detail: Option<&str>,
        task: Option<&(TaskState, Option<String>)>,
    ) -> Result<(), StoreError> {
        // Wait for competing reply or result writers off the browser's connection.
        for _ in 0..4 {
            if defer_if_busy(self.settle_routine_run(run, state, detail, task))?.is_some() {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        Err(StoreError)
    }

    fn settle_routine_run(
        &self,
        run: i64,
        state: &str,
        detail: Option<&str>,
        task: Option<&(TaskState, Option<String>)>,
    ) -> rusqlite::Result<()> {
        let mut db = crate::history::connection(self.file())?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        if let Some((state, detail)) = task
            && tx.execute(
                "UPDATE journal SET state=?2,detail=?3 WHERE id=(SELECT task_id FROM routine_runs WHERE id=?1)
                 AND state='pending'",
                params![run,state.as_str(),detail.as_deref()],
            )? != 1
        {
            return Err(rusqlite::Error::QueryReturnedNoRows);
        }
        if tx.execute(
            "UPDATE routine_runs SET state=?2,detail=?3,
             result_token=CASE WHEN ?2='not_sent' THEN NULL ELSE result_token END
             WHERE id=?1 AND state='pending'",
            params![run, state, detail],
        )? != 1
        {
            return Err(rusqlite::Error::QueryReturnedNoRows);
        }
        tx.commit()?;
        Ok(())
    }

    pub fn prepare_routine_task(
        &self,
        run: i64,
        routine: &Routine,
        agent: &crate::core::Terminal,
        track: bool,
    ) -> Result<Option<String>, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
        let entry: i64 = tx.query_row(
            "INSERT INTO journal (core_id,address,created_ms,agent,kind,state,text,at_ms)
             VALUES (?1,?2,?3,?4,'task','pending',?5,?6) RETURNING id",
            params![
                routine.core,
                agent.address,
                agent.created_ms,
                agent.display_name(),
                routine.task,
                now()
            ],
            |row| row.get(0),
        )?;
        let token = tx.query_row(
            "UPDATE routine_runs SET task_id=?2,result_token=CASE WHEN ?3 THEN lower(hex(randomblob(16))) END
             WHERE id=?1 AND routine=?4 AND state='pending' AND task_id IS NULL RETURNING result_token",
            params![run,entry,track,routine.id], |row| row.get(0),
        )?;
        tx.commit()?;
        Ok(token)
    }
}

/// The revision explicitly supplied by the bot when it reports this run's outcome.
#[derive(Serialize)]
pub(crate) struct ResultPage {
    pub id: i64,
    pub revision: i64,
    pub title: String,
    pub excerpt: String,
}

pub(crate) fn result_page(db: &Connection, result: i64) -> rusqlite::Result<Option<ResultPage>> {
    db.query_row(
        "SELECT v.page,v.revision,v.title,substr(v.markdown,1,480)
         FROM routine_result_pages r JOIN workspace_page_versions v ON v.page=r.page AND v.revision=r.revision
         WHERE r.result=?1",
        [result],
        |row| Ok(ResultPage { id: row.get(0)?, revision: row.get(1)?, title: row.get(2)?, excerpt: row.get(3)? }),
    ).optional()
}

pub fn publish_result(
    path: &std::path::Path,
    launch: &str,
    token: &str,
    outcome: Outcome,
    text: &str,
    page: Option<(i64, i64)>,
) -> Result<bool, StoreError> {
    let mut db = crate::history::connection(path)?;
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let run: Option<i64> = tx
        .query_row(
            "SELECT r.id FROM routine_runs r
         JOIN journal task ON task.id=r.task_id
         JOIN journal launch ON launch.launch_key=?1 AND launch.core_id=task.core_id
              AND launch.address=task.address AND launch.created_ms=task.created_ms
         WHERE r.result_token=?2 AND r.result_id IS NULL
           AND r.state IN ('pending','sent','start_not_observed','unconfirmed')",
            params![launch, token],
            |row| row.get(0),
        )
        .optional()?;
    let Some(run) = run else {
        return Ok(false);
    };
    if let Some((id, revision)) = page {
        let owned: bool = tx.query_row(
            "SELECT EXISTS(SELECT 1 FROM workspace_pages p JOIN workspace_page_versions v ON v.page=p.id
             WHERE p.owner_launch=?1 AND p.id=?2 AND v.revision=?3)",
            params![launch, id, revision], |row| row.get(0),
        )?;
        if !owned {
            return Ok(false);
        }
    }
    let result: i64 = tx.query_row(
        "INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms)
         SELECT launch_key,core_id,address,created_ms,agent,'reply','received',?2,?3,?4
         FROM journal WHERE launch_key=?1 RETURNING id",
        params![launch,text,if matches!(outcome,Outcome::Succeeded) { "Routine succeeded" } else { "Routine failed" },now()],
        |row| row.get(0),
    )?;
    tx.execute(
        "UPDATE routine_runs SET result_id=?2,result_state=?3,result_token=NULL WHERE id=?1",
        params![run, result, outcome.state()],
    )?;
    if let Some((id, revision)) = page {
        tx.execute(
            "INSERT INTO routine_result_pages(result,page,revision) VALUES (?1,?2,?3)",
            params![result, id, revision],
        )?;
    }
    if let crate::bots::Who::Bot(bot) = crate::bots::of_launch(&tx, launch)? {
        tx.execute(
            "INSERT INTO bot_history(bot,kind,text,at_ms,unread,notify,code,journal)
             SELECT ?1,'said',text,at_ms,1,0,'routine_result',id FROM journal WHERE id=?2
               AND NOT EXISTS(SELECT 1 FROM group_members WHERE launch_key=?3)",
            params![bot.id, result, launch],
        )?;
    }
    tx.commit()?;
    Ok(true)
}

pub(crate) fn claim_schedule(db: &mut Connection, at: i64) -> Result<Vec<Dispatch>, StoreError> {
    // Idle ticks don't need a writer lock. Recheck under the write transaction
    // before claiming work, rather than upgrading a read snapshot.
    let Some(true) = defer_if_busy(db.query_row(
        "SELECT EXISTS (SELECT 1 FROM routines WHERE state='active' AND next_at <= ?1)",
        [at],
        |row| row.get(0),
    ))?
    else {
        return Ok(Vec::new());
    };
    let Some(txn) = background_write(db)? else {
        return Ok(Vec::new());
    };
    let cutoff = schedule_lateness_cutoff(at);
    let due: Vec<(Routine, bool)> = {
        let mut stmt = txn.prepare(
            "SELECT r.* FROM routines r WHERE r.state='active' AND r.next_at <= ?1
             AND (r.run_due_after_rezone=0 OR r.next_at < ?2 OR NOT EXISTS (
                 SELECT 1 FROM routine_runs run JOIN routines target ON target.id=run.routine
                 WHERE run.state='pending' AND target.core=r.core AND target.address=r.address
                   AND target.created_ms=r.created_ms
             )) ORDER BY r.next_at, r.id LIMIT 16",
        )?;
        stmt.query_map([at, cutoff], |row| {
            Ok((from_row(row)?, row.get("run_due_after_rezone")?))
        })?
        .collect::<Result<_, _>>()?
    };
    let mut dispatch = Vec::with_capacity(due.len());
    let zone = crate::person_profile::effective_timezone(&txn)?;
    for (routine, preserve_due) in due {
        let due_at = routine.next_at.ok_or(StoreError)?;
        let missed = due_at < cutoff;
        let busy = !missed && pending(&txn, &routine)?;
        if preserve_due && busy {
            continue;
        }
        let next = routine
            .schedule
            .advance(due_at, at, zone)
            .ok_or(StoreError)?;
        txn.execute(
            "UPDATE routines SET next_at=?2,run_due_after_rezone=0 WHERE id=?1",
            params![routine.id, next],
        )?;
        let (state, detail) = if missed {
            ("skipped", Some("The workspace missed the scheduled time."))
        } else if busy {
            (
                "skipped",
                Some("Another routine is still delivering a task to this agent."),
            )
        } else {
            ("pending", None)
        };
        let run = make_run(&txn, routine.id, "schedule", at, state, detail)?;
        if state == "pending" {
            dispatch.push(Dispatch {
                routine,
                run,
                event: None,
            });
        }
    }
    txn.commit()?;
    Ok(dispatch)
}

fn pending(db: &rusqlite::Connection, item: &Routine) -> rusqlite::Result<bool> {
    db.query_row(
        "SELECT EXISTS (SELECT 1 FROM routine_runs JOIN routines ON routines.id=routine_runs.routine
          WHERE routine_runs.state='pending' AND core=?1 AND address=?2 AND created_ms=?3)",
        params![item.core, item.target.address, item.target.created_ms], |row| row.get(0),
    )
}

fn make_run(
    db: &rusqlite::Connection,
    routine: i64,
    kind: &str,
    at: i64,
    state: &str,
    detail: Option<&str>,
) -> rusqlite::Result<i64> {
    db.query_row(
        "INSERT INTO routine_runs (routine,kind,at_ms,state,detail) VALUES (?1,?2,?3,?4,?5) RETURNING id",
        params![routine, kind, at, state, detail], |row| row.get(0),
    )
}

fn from_row(row: &Row<'_>) -> rusqlite::Result<Routine> {
    let input: String = row.get("schedule")?;
    let schedule = serde_json::from_str(&input).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(7, rusqlite::types::Type::Text, Box::new(error))
    })?;
    Ok(Routine {
        id: row.get("id")?,
        core: row.get("core")?,
        target: Target {
            address: row.get("address")?,
            created_ms: row.get("created_ms")?,
        },
        agent: row.get("agent")?,
        name: row.get("name")?,
        task: row.get("task")?,
        state: row.get("state")?,
        next_at: row.get("next_at")?,
        webhook_ready: row.get::<_, Option<String>>("webhook_hash")?.is_some(),
        profile_id: None,
        owner_bot: None,
        schedule,
    })
}

fn with_owner(row: &Row<'_>) -> rusqlite::Result<Routine> {
    let mut routine = from_row(row)?;
    routine.profile_id = row.get("owner_profile")?;
    routine.owner_bot = row.get("owner_bot")?;
    Ok(routine)
}

pub(crate) fn encode(schedule: &Schedule) -> Result<String, StoreError> {
    serde_json::to_string(schedule).map_err(|_| StoreError)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn ms(input: &str) -> i64 {
        DateTime::parse_from_rfc3339(input)
            .unwrap()
            .timestamp_millis()
    }

    fn insert_daily(db: &Connection, hour: u8, minute: u8, due_at: i64) -> i64 {
        let schedule = Schedule::Daily {
            hour,
            minute,
            timezone: None,
            weekdays: false,
        };
        db.query_row(
            "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state,next_at)
             VALUES ('core','1',1,'main','Daily','Do it',?1,'active',?2) RETURNING id",
            params![encode(&schedule).unwrap(), due_at],
            |row| row.get(0),
        )
        .unwrap()
    }

    #[test]
    fn reported_page_is_owned_pinned_and_delivered_once() {
        use crate::bots::testing::{journal, session};
        let (_scratch, history) = journal(&["Scout", "Patch"]);
        let launch = session(&history, "Scout", "1");
        let other = session(&history, "Patch", "2");
        let db = history.db().unwrap();
        let routine = insert_daily(&db, 8, 55, 1);
        let run = make_run(&db, routine, "test", 1, "sent", None).unwrap();
        db.execute(
            "UPDATE routine_runs SET task_id=(SELECT id FROM journal WHERE launch_key=?1),result_token='once' WHERE id=?2",
            params![launch, run],
        ).unwrap();
        let create = |key: &str| db.query_row(
            "INSERT INTO workspace_pages(owner_launch,title,markdown,updated_ms) VALUES(?1,'Morning brief','Original',1) RETURNING id",
            [key], |r| r.get::<_, i64>(0),
        ).unwrap();
        let id = create(&launch);
        let foreign = create(&other);
        let report = |key, page| publish_result(history.file(), key, "once", Outcome::Succeeded, "Published", Some(page)).unwrap();
        assert!(!report(&launch, (id, 2)));
        assert!(!report(&launch, (foreign, 1)));
        assert!(!report(&other, (foreign, 1)));
        assert!(report(&launch, (id, 1)));
        assert!(!report(&launch, (id, 1)));
        let result: i64 = db.query_row("SELECT journal FROM bot_history WHERE code='routine_result' AND bot='scout-id'", [], |r| r.get(0)).unwrap();
        drop(db);
        assert_eq!(history.routine_runs(routine).unwrap()[0].result.as_ref().unwrap().id, result);
        let db = history.db().unwrap();
        db.execute("DELETE FROM routine_runs WHERE id=?1", [run]).unwrap();
        for revision in 2..=53 {
            db.execute("UPDATE workspace_pages SET revision=?1,markdown='Updated' WHERE id=?2", params![revision, id]).unwrap();
        }
        let saved = result_page(&db, result).unwrap().unwrap();
        assert_eq!((saved.id, saved.revision, saved.excerpt.as_str()), (id, 1, "Original"));
        let count: i64 = db.query_row("SELECT count(*) FROM workspace_page_versions WHERE page=?1", [id], |r| r.get(0)).unwrap();
        assert_eq!(count, 51);
    }

    #[test]
    fn rezone_keeps_an_unclaimed_daily_occurrence_and_claim_advances_in_the_new_zone() {
        use chrono_tz::{Asia::Bangkok, Europe::Warsaw};
        let (_scratch, history) = crate::bots::testing::journal(&[]);
        let mut db = history.db().unwrap();
        let due_at = ms("2026-03-29T07:00:00Z");
        let moved_at = due_at + 29_000;
        let id = insert_daily(&db, 9, 0, due_at);
        let pending_run = make_run(&db, id, "test", due_at - 1, "pending", None).unwrap();
        let tx = db.transaction().unwrap();
        crate::bots::Settings {
            timezone: Warsaw.to_string(),
            ..Default::default()
        }
        .save(&tx)
        .unwrap();
        tx.execute(
            "INSERT INTO person_profile_history(timezone,updated_at) VALUES ('Asia/Bangkok',?1)",
            [moved_at],
        )
        .unwrap();
        crate::person_profile::rezone(&tx, moved_at, Warsaw, Bangkok).unwrap();
        tx.commit().unwrap();
        let next = |db: &Connection| {
            db.query_row("SELECT next_at FROM routines WHERE id=?1", [id], |row| {
                row.get::<_, Option<i64>>(0)
            })
            .unwrap()
        };
        assert_eq!(next(&db), Some(due_at));
        assert!(claim_schedule(&mut db, moved_at).unwrap().is_empty());
        assert_eq!(next(&db), Some(due_at));

        db.execute("DELETE FROM routine_runs WHERE id=?1", [pending_run])
            .unwrap();
        let claimed = claim_schedule(&mut db, moved_at + 1_000).unwrap();
        assert_eq!(claimed.len(), 1);
        assert_eq!(claimed[0].routine.id, id);
        assert_eq!(claimed[0].routine.next_at, Some(due_at));
        assert!(
            claim_schedule(&mut db, moved_at + 1_000)
                .unwrap()
                .is_empty()
        );
        assert_eq!(next(&db), Some(ms("2026-03-30T02:00:00Z")));
        assert_eq!(db.query_row(
            "SELECT count(*) FROM routine_runs WHERE routine=?1 AND kind='schedule' AND state='pending'",
            [id], |row| row.get::<_, i64>(0),
        ).unwrap(), 1);
    }

    #[test]
    fn rezone_skips_old_routines_and_expires_a_preserved_routine_at_the_normal_cutoff() {
        use chrono_tz::{Asia::Bangkok, Europe::Warsaw};
        let (_scratch, history) = crate::bots::testing::journal(&[]);
        let mut db = history.db().unwrap();
        let due_at = ms("2026-03-28T19:30:00Z");
        let moved_at = due_at + 30_000;
        let old_due = due_at - 86_400_000;
        let old = insert_daily(&db, 2, 30, old_due);
        let recent = insert_daily(&db, 2, 30, due_at);
        make_run(&db, recent, "test", due_at - 1, "pending", None).unwrap();

        let tx = db.transaction().unwrap();
        crate::bots::Settings {
            timezone: Warsaw.to_string(),
            ..Default::default()
        }
        .save(&tx)
        .unwrap();
        crate::person_profile::rezone(&tx, moved_at, Bangkok, Warsaw).unwrap();
        tx.commit().unwrap();

        let slot = |db: &Connection, id| {
            db.query_row(
                "SELECT next_at,run_due_after_rezone FROM routines WHERE id=?1",
                [id],
                |row| Ok((row.get::<_, i64>(0)?, row.get::<_, bool>(1)?)),
            )
            .unwrap()
        };
        assert_eq!(slot(&db, old), (old_due, false));
        assert_eq!(slot(&db, recent), (due_at, true));
        let next = ms("2026-03-29T01:00:00Z"); // First valid minute after Warsaw's DST gap.
        assert!(claim_schedule(&mut db, moved_at).unwrap().is_empty());
        assert_eq!(slot(&db, old), (next, false));
        assert_eq!(slot(&db, recent), (due_at, true));
        assert!(claim_schedule(&mut db, moved_at + 1).unwrap().is_empty());
        assert_eq!(slot(&db, recent), (next, false));

        for id in [old, recent] {
            let run: (String, String) = db
                .query_row(
                    "SELECT state,detail FROM routine_runs WHERE routine=?1 AND kind='schedule'",
                    [id],
                    |row| Ok((row.get(0)?, row.get(1)?)),
                )
                .unwrap();
            assert_eq!(run.0, "skipped");
            assert_eq!(run.1, "The workspace missed the scheduled time.");
        }
    }

    #[test]
    fn daylight_transition_never_sends_twice_and_finds_the_first_valid_minute() {
        let daily = |hour| Schedule::Daily {
            hour,
            minute: 30,
            timezone: Some(chrono_tz::America::New_York),
            weekdays: false,
        };
        assert_eq!(
            daily(2).next(ms("2026-03-08T06:00:00Z")),
            Some(ms("2026-03-08T07:00:00Z"))
        );
        assert_eq!(
            daily(1).next(ms("2026-11-01T05:30:00Z")),
            Some(ms("2026-11-02T06:30:00Z"))
        );
    }

    #[test]
    fn weekdays_skip_weekends_without_changing_local_hour() {
        let schedule = Schedule::Daily {
            hour: 8,
            minute: 0,
            timezone: Some(chrono_tz::Europe::Warsaw),
            weekdays: true,
        };
        assert_eq!(
            schedule.next(ms("2026-03-27T09:00:00Z")),
            Some(ms("2026-03-30T06:00:00Z"))
        );
    }
}
