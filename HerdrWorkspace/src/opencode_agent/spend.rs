//! Reserve a request's maximum cost before transport. Keep uncertain requests fully
//! reserved, including across plugin reloads. Units are billionths of a US dollar.
use crate::agent::{read_input, session};
use rusqlite::{Connection, OpenFlags, TransactionBehavior, params};
use serde::Deserialize;
use std::time::Duration;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
enum Entry {
    Refused { reason: Refusal },
    Reserve { request: String, nanos: i64 },
    Settle { request: String, nanos: i64 },
}

#[derive(Deserialize)]
#[serde(rename_all = "snake_case")]
enum Refusal {
    Pricing,
    Reservation,
}

fn change(db: &mut Connection, key: &str, entry: Entry) -> Result<(), Box<dyn std::error::Error>> {
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let (launch, cents): (i64, i64) = tx.query_row(
        "SELECT id,session_cap_cents FROM journal WHERE launch_key=?1 AND session_cap_cents IS NOT NULL",
        [key], |row| Ok((row.get(0)?, row.get(1)?)))?;
    match entry {
        Entry::Refused { reason } => {
            let label = match reason {
                Refusal::Pricing => "pricing",
                Refusal::Reservation => "reservation",
            };
            tx.execute("UPDATE journal SET spend_refusals=coalesce(spend_refusals,0)+1, spend_refusal_reason=?2 WHERE id=?1",
                params![launch, label])?;
        }
        Entry::Reserve { request, nanos } => {
            validate(&request, nanos)?;
            let used: i64 = tx.query_row(
                "SELECT coalesce(sum(nanos),0) FROM opencode_spend WHERE launch=?1",
                [launch],
                |row| row.get(0),
            )?;
            if nanos == 0 || i128::from(used) + i128::from(nanos) > i128::from(cents) * 10_000_000 {
                return Err(
                    "This request could exceed the OpenCode session spending limit.".into(),
                );
            }
            tx.execute(
                "INSERT INTO opencode_spend(launch,request,nanos) VALUES(?1,?2,?3)",
                params![launch, request, nanos],
            )?;
        }
        Entry::Settle { request, nanos } => {
            validate(&request, nanos)?;
            let changed = tx.execute("UPDATE opencode_spend SET nanos=?3,settled=1 WHERE launch=?1 AND request=?2 AND settled=0",
                params![launch, request, nanos])?;
            if changed != 1 {
                return Err("This request has no unsettled reservation.".into());
            }
        }
    }
    tx.commit()?;
    Ok(())
}

fn validate(request: &str, nanos: i64) -> Result<(), Box<dyn std::error::Error>> {
    if !super::valid_reply_id(request) || nanos < 0 {
        return Err("Invalid OpenCode spend reading.".into());
    }
    Ok(())
}

pub(crate) fn record() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let entry = serde_json::from_str(&read_input(1024)?)?;
    let mut db = Connection::open_with_flags(journal, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    db.busy_timeout(Duration::from_secs(2))?;
    change(&mut db, &key, entry)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Barrier};

    #[test]
    fn parallel_requests_share_one_reservation_and_settle_once() {
        let dir = tempfile::tempdir().unwrap();
        let history = crate::history::History::open_at(&dir.path().join("workspace")).unwrap();
        let mut db = Connection::open(history.file()).unwrap();
        for key in ["first", "other"] {
            db.execute("INSERT INTO journal (launch_key,core_id,agent,kind,state,text,at_ms,session_cap_cents)
                        VALUES (?1,'core','legal','task','sent','',0,2)", [key]).unwrap();
        }
        let gate = Arc::new(Barrier::new(2));
        let workers: Vec<_> = ["one", "two"]
            .into_iter()
            .map(|id| {
                let file = history.file().to_owned();
                let gate = Arc::clone(&gate);
                std::thread::spawn(move || {
                    let mut db = Connection::open(file).unwrap();
                    gate.wait();
                    change(
                        &mut db,
                        "first",
                        Entry::Reserve {
                            request: id.into(),
                            nanos: 14_000_000,
                        },
                    )
                    .is_ok()
                    .then_some(id)
                })
            })
            .collect();
        let won: Vec<_> = workers
            .into_iter()
            .filter_map(|w| w.join().unwrap())
            .collect();
        assert_eq!(won.len(), 1);
        let settle = || Entry::Settle {
            request: won[0].into(),
            nanos: 7_500_000,
        };
        assert!(change(&mut db, "other", settle()).is_err());
        change(&mut db, "first", settle()).unwrap();
        assert!(change(&mut db, "first", settle()).is_err());
        let reserve = |nanos| Entry::Reserve {
            request: "next".into(),
            nanos,
        };
        assert!(change(&mut db, "first", reserve(12_500_001)).is_err());
        change(&mut db, "first", reserve(12_500_000)).unwrap();
    }
}
