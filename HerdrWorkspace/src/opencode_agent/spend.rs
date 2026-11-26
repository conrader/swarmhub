//! Reserve a request's maximum cost before transport. Keep uncertain requests fully
//! reserved, including across plugin reloads. Units are billionths of a US dollar.
use crate::agent::{read_input, session};
use rusqlite::{Connection, OpenFlags, TransactionBehavior, params};
use serde::Deserialize;
use std::time::Duration;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Entry {
    Reserve { request: String, nanos: i64 },
    Settle { request: String, nanos: i64 },
}

fn change(db: &mut Connection, key: &str, entry: Entry) -> Result<(), Box<dyn std::error::Error>> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (launch, cents): (i64, i64) = tx.query_row(
        "SELECT id,session_cap_cents FROM journal WHERE launch_key=?1 AND session_cap_cents IS NOT NULL",
        [key], |row| Ok((row.get(0)?, row.get(1)?)))?;
    let (request, nanos) = match &entry {
        Entry::Reserve { request, nanos } | Entry::Settle { request, nanos } => (request, *nanos),
    };
    if !super::valid_reply_id(request) || nanos < 0 {
        return Err("Invalid OpenCode spend reading.".into());
    }
    match entry {
        Entry::Reserve { .. } => {
            let used: i64 = tx.query_row("SELECT coalesce(sum(nanos),0) FROM opencode_spend WHERE launch=?1",
                [launch], |row| row.get(0))?;
            if nanos == 0 || i128::from(used) + i128::from(nanos) > i128::from(cents) * 10_000_000 {
                return Err("This request could exceed the OpenCode session spending limit.".into());
            }
            tx.execute("INSERT INTO opencode_spend(launch,request,nanos) VALUES(?1,?2,?3)",
                params![launch, request, nanos])?;
        }
        Entry::Settle { .. } => {
            let changed = tx.execute("UPDATE opencode_spend SET nanos=?3,settled=1 WHERE launch=?1 AND request=?2 AND settled=0",
                params![launch, request, nanos])?;
            if changed != 1 { return Err("This request has no unsettled reservation.".into()); }
        }
    }
    tx.commit()?;
    Ok(())
}

pub(crate) fn record() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let entry = serde_json::from_str(&read_input(1024)?)?;
    let mut db = Connection::open_with_flags(journal, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    db.busy_timeout(Duration::from_secs(2))?;
    change(&mut db, &key, entry)
}
