use crate::{
    ApiError,
    core::{Terminal, validate_task},
    history::{History, StoreError, now},
    routines::Schedule,
};
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Serialize;
use serde_json::Value;
use std::collections::HashSet;

pub struct Imported {
    source: String,
    name: String,
    task: String,
    schedule: Option<Schedule>,
    source_hint: Option<String>,
}

#[derive(Serialize)]
pub struct Draft {
    id: i64,
    pub profile_id: i64,
    profile_name: String,
    name: String,
    task: String,
    schedule: Option<Schedule>,
    source_hint: Option<String>,
}

fn clean(raw: &str, max: usize) -> String {
    raw.chars()
        .filter(|c| !c.is_control())
        .take(max)
        .collect::<String>()
        .trim()
        .to_owned()
}

pub fn from_export(rows: Vec<Value>) -> Vec<Imported> {
    let mut seen = HashSet::new();
    rows.into_iter()
        .filter_map(|item| {
            let name = clean(item.get("name")?.as_str()?, 80);
            if name.is_empty() {
                return None;
            }
            let source = item
                .get("id")
                .and_then(Value::as_str)
                .map(|id| clean(id, 180))
                .filter(|id| !id.is_empty())
                .map(|id| format!("id:{id}"))
                .unwrap_or_else(|| format!("name:{}", name.to_lowercase()));
            if !seen.insert(source.clone()) {
                return None;
            }
            let task = item
                .get("prompt")
                .and_then(Value::as_str)
                .filter(|prompt| prompt.len() <= 12 * 1024 && validate_task(prompt).is_ok())
                .unwrap_or("")
                .to_owned();
            let zone = item
                .get("timezone")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty());
            let trigger = item
                .get("trigger")
                .and_then(Value::as_str)
                .filter(|value| !value.trim().is_empty());
            let exported = item.get("schedule").filter(|value| !value.is_null());
            let schedule = if trigger.is_none() {
                exported.and_then(|value| saved_schedule(value, zone))
            } else {
                None
            };
            let source_hint = if schedule.is_none() {
                let description =
                    exported.map(|value| value.as_str().unwrap_or("Unsupported schedule"));
                let hint = [description, zone, trigger]
                    .into_iter()
                    .flatten()
                    .collect::<Vec<_>>()
                    .join(" · ");
                let hint = clean(&hint, 300);
                (!hint.is_empty()).then_some(hint)
            } else {
                None
            };
            Some(Imported {
                source,
                name,
                task,
                schedule,
                source_hint,
            })
        })
        .collect()
}

fn saved_schedule(value: &Value, zone: Option<&str>) -> Option<Schedule> {
    let schedule = if let Some(expression) = value.as_str() {
        let fields = expression.split_ascii_whitespace().collect::<Vec<_>>();
        let [minute, hour, "*", "*", day] = fields.as_slice() else {
            return None;
        };
        if ![minute, hour]
            .into_iter()
            .all(|field| !field.is_empty() && field.bytes().all(|c| c.is_ascii_digit()))
        {
            return None;
        }
        Schedule::Daily {
            hour: hour.parse().ok()?,
            minute: minute.parse().ok()?,
            timezone: zone.map(|zone| zone.trim().parse()).transpose().ok()?,
            weekdays: match *day {
                "*" => false,
                "1-5" => true,
                _ => return None,
            },
        }
    } else {
        serde_json::from_value(value.clone()).ok()?
    };
    schedule.next(now())?;
    Some(schedule)
}

pub fn stage(db: &Connection, archive: i64, imports: Vec<Imported>) -> Result<usize, StoreError> {
    if imports.is_empty() {
        return Ok(0);
    }
    let mut statement = db.prepare_cached(
        "INSERT INTO grok_routine_drafts(archive,source_id,name,task,schedule,source_hint)
         VALUES (?1,?2,?3,?4,?5,?6) ON CONFLICT(archive,source_id) DO NOTHING",
    )?;
    let mut count = 0;
    for item in imports {
        let schedule = item
            .schedule
            .as_ref()
            .map(crate::routines::encode)
            .transpose()?;
        count += statement.execute(params![
            archive,
            item.source,
            item.name,
            item.task,
            schedule,
            item.source_hint
        ])?;
    }
    Ok(count)
}

fn row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Draft> {
    Ok(Draft {
        id: row.get(0)?,
        profile_id: row.get(1)?,
        profile_name: row.get(2)?,
        name: row.get(3)?,
        task: row.get(4)?,
        schedule: row
            .get::<_, Option<String>>(5)?
            .and_then(|value| serde_json::from_str(&value).ok()),
        source_hint: row.get(6)?,
    })
}

impl History {
    pub fn imported_routines(&self) -> Result<Vec<Draft>, StoreError> {
        let db = self.db()?;
        let mut query = db.prepare(
            "SELECT d.id,p.id,p.name,d.name,d.task,d.schedule,d.source_hint
             FROM grok_routine_drafts d JOIN grok_imports i ON i.id=d.archive
             JOIN profiles p ON p.id=i.profile
             WHERE d.routine_id IS NULL AND d.dismissed=0 ORDER BY p.name,d.id",
        )?;
        Ok(query
            .query_map([], row)?
            .collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn dismiss_imported_routine(&self, id: i64) -> Result<bool, StoreError> {
        Ok(self.db()?.execute(
            "UPDATE grok_routine_drafts SET dismissed=1 WHERE id=?1 AND routine_id IS NULL AND dismissed=0",
            [id],
        )? == 1)
    }

    pub fn configure_imported_routine(
        &self,
        draft: i64,
        core: &str,
        agent: &Terminal,
        name: &str,
        task: &str,
        schedule: &Schedule,
    ) -> Result<i64, ApiError> {
        let mut db = self.db()?;
        let txn = db
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(StoreError::from)?;
        let profile: i64 = txn
            .query_row(
                "SELECT i.profile FROM grok_routine_drafts d JOIN grok_imports i ON i.id=d.archive
             WHERE d.id=?1 AND d.dismissed=0 AND d.routine_id IS NULL AND i.profile IS NOT NULL",
                [draft],
                |row| row.get(0),
            )
            .optional()
            .map_err(StoreError::from)?
            .ok_or(ApiError::Conflict(
                "This draft was already set up or dismissed.",
            ))?;
        let owns_session: bool = txn.query_row(
            "SELECT EXISTS(SELECT 1 FROM journal WHERE profile_id=?1 AND core_id=?2 AND launch_key=?3
             AND address=?4 AND created_ms=?5 AND launch_template IS NOT NULL)",
            params![profile,core,agent.launch_key(),agent.address,agent.created_ms],|row|row.get(0),
        ).map_err(StoreError::from)?;
        if !owns_session {
            return Err(ApiError::Conflict(
                "Choose a running session belonging to the imported profile.",
            ));
        }
        let id: i64 = txn
            .query_row(
                "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state)
             VALUES (?1,?2,?3,?4,?5,?6,?7,'paused') RETURNING id",
                params![
                    core,
                    agent.address,
                    agent.created_ms,
                    agent.display_name(),
                    name,
                    task,
                    crate::routines::encode(schedule)?
                ],
                |row| row.get(0),
            )
            .map_err(StoreError::from)?;
        txn.execute(
            "UPDATE grok_routine_drafts SET routine_id=?2 WHERE id=?1",
            params![draft, id],
        )
        .map_err(StoreError::from)?;
        txn.commit().map_err(StoreError::from)?;
        Ok(id)
    }
}
