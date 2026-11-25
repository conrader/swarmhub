// A closed receipt also fences a delayed request whose response the client lost.
use super::*;
use crate::{ApiError, Workspace};
use axum::{Json, extract::{Path, State}};
use serde_json::json;

#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "snake_case", deny_unknown_fields)]
pub(crate) enum Request {
    Hold { id: i64, target: Target },
    Install { owner: String, target: Target, name: String, task: String, schedule: Schedule, state: String, next_at: Option<i64> },
    Events { after: String },
    Remember { digests: Vec<String> },
    Activate,
    Suspend { attempt: String },
    Resume { attempt: String },
    Retire,
    Restore,
}

#[derive(Deserialize)]
pub(crate) struct Body {
    core: String,
    #[serde(flatten)]
    request: Request,
}

pub(crate) async fn handle(State(w): State<Workspace>, Path(token): Path<String>, Json(body): Json<Body>)
    -> Result<Json<Value>, ApiError>
{
    if token.len() != 36 || !token.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Err(crate::core::Failure::Input("Invalid move identifier.").into());
    }
    if w.core.identify().await?.core.id != body.core {
        return Err(ApiError::Conflict("The connected workspace changed."));
    }
    let agent = if let Request::Install { target, name, task, schedule, state, .. } = &body.request {
        crate::routine_routes::validate(name, task, schedule)?;
        if !matches!(state.as_str(), "active" | "paused") {
            return Err(ApiError::Conflict("The source routine is unavailable."));
        }
        let agent = w.core.agent(&target.address, target.created_ms).await?;
        agent.require_live()?;
        Some(agent.display_name().to_owned())
    } else { None };
    let mut db = w.history.db()?;
    transact(&mut db, &token, &body.core, body.request, agent.as_deref())
}

fn future(schedule: &Schedule, due: Option<i64>, zone: Tz) -> Option<i64> {
    let at = now();
    due.and_then(|due| if due > at { Some(due) } else { schedule.advance(due, at, zone) })
}

// Keep payloads, sender keys and original delivery identifiers on their own bridge.
fn freeze_events(tx: &Connection, id: i64) -> Result<(),ApiError> {
    if tx.query_row("SELECT EXISTS(SELECT 1 FROM webhook_reviews WHERE routine=? AND dismissed=0)",[id],
        |r|r.get::<_,bool>(0)).map_err(StoreError::from)? {
        return Err(ApiError::Conflict("Review or dismiss pending webhook events before moving this routine."));
    }
    let mut events = tx.prepare("SELECT event_key FROM routine_runs WHERE routine=?1 AND event_key IS NOT NULL
        UNION ALL SELECT event_key FROM webhook_reviews WHERE routine=?1").map_err(StoreError::from)?;
    let mut insert = tx.prepare("INSERT OR IGNORE INTO routine_event_receipts VALUES(?,?)").map_err(StoreError::from)?;
    for key in events.query_map([id],|r|r.get::<_,String>(0)).map_err(StoreError::from)? {
        insert.execute(params![id,webhook_hash(&key.map_err(StoreError::from)?)]).map_err(StoreError::from)?;
    }
    Ok(())
}

fn transact(db: &mut Connection, token: &str, core: &str, request: Request, agent: Option<&str>)
    -> Result<Json<Value>, ApiError>
{
    let tx = db.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate).map_err(StoreError::from)?;
    let receipt: Option<(String, Option<i64>, Option<String>, Option<i64>, Option<String>)> = tx.query_row(
        "SELECT phase,routine,original_state,original_next,binding FROM routine_transfers WHERE token=?",
        [token], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?))
    ).optional().map_err(StoreError::from)?;
    let row = |id| tx.query_row(&format!("{WITH_OWNER} WHERE id=?"), [id], with_owner).map_err(StoreError::from);
    let conflict = || ApiError::Conflict("The routine changed or has a delivery in progress. Check it and retry.");
    let zone = crate::person_profile::effective_timezone(&tx).map_err(StoreError::from)?;
    let result = match request {
        Request::Hold { id, target } => {
            let mut r = row(id)?;
            if r.core != core || r.target != target { return Err(conflict()); }
            if let Some((phase, rid, state, next, _)) = receipt {
                if phase != "held" || rid != Some(id) { return Err(conflict()); }
                r.state = state.ok_or_else(conflict)?;
                r.next_at = next;
            } else {
                if r.state == "archived" || pending(&tx, &r).map_err(StoreError::from)? { return Err(conflict()); }
                freeze_events(&tx,id)?;
                tx.execute("INSERT INTO routine_transfers(token,phase,routine,original_state,original_next) VALUES(?,'held',?,?,?)",
                    params![token,id,r.state,r.next_at]).map_err(StoreError::from)?;
                tx.execute("UPDATE routines SET state='archived',next_at=NULL WHERE id=?", [id]).map_err(StoreError::from)?;
            }
            if let Schedule::Daily { timezone, .. } = &mut r.schedule { timezone.get_or_insert(zone); }
            json!({"routine":r})
        }
        Request::Install { owner, target, name, task, schedule, state, next_at } => {
            let id = if let Some((phase, id, ..)) = receipt {
                if phase != "installed" && phase != "staged" { return Err(conflict()); }
                id.ok_or_else(conflict)?
            } else {

                let id: i64 = tx.query_row(
                    "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state,next_at) VALUES(?,?,?,?,?,?,?,'archived',NULL) RETURNING id",
                    params![core,target.address,target.created_ms,agent.ok_or_else(conflict)?,name,task,encode(&schedule)?],
                    |r| r.get(0)).map_err(StoreError::from)?;
                if row(id)?.owner_bot.as_deref().is_some_and(|saved| !saved.eq_ignore_ascii_case(&owner)) {
                    return Err(conflict());
                }
                tx.execute("UPDATE routines SET transferred_owner=? WHERE id=?", params![owner,id]).map_err(StoreError::from)?;
                tx.execute("INSERT INTO routine_transfers(token,phase,routine,binding,original_state,original_next) VALUES(?,'staged',?,?,?,?)",
                    params![token,id,review_binding(&row(id)?),state,next_at]).map_err(StoreError::from)?;
                id
            };
            json!({"routine":row(id)?})
        }
        Request::Events { after } => {
            let (phase, id, ..) = receipt.ok_or_else(conflict)?;
            if phase != "held" && phase != "suspended" && phase != "closed" { return Err(conflict()); }
            let mut stmt = tx.prepare("SELECT digest FROM routine_event_receipts WHERE routine=? AND digest>? ORDER BY digest LIMIT 128").map_err(StoreError::from)?;
            let page = stmt.query_map(params![id,after],|r|r.get::<_,String>(0)).map_err(StoreError::from)?
                .collect::<Result<Vec<_>,_>>().map_err(StoreError::from)?;
            json!({"digests":page})
        }
        Request::Remember { digests } => {
            let (phase,id,..) = receipt.ok_or_else(conflict)?;
            if phase != "held" && phase != "staged" && phase != "closed" || digests.len()>128 { return Err(conflict()); }
            for key in digests {
                if key.len()!=64 || !key.bytes().all(|b| b.is_ascii_hexdigit()) { return Err(conflict()); }
                tx.execute("INSERT OR IGNORE INTO routine_event_receipts VALUES(?,?)",params![id,key]).map_err(StoreError::from)?;
            }
            json!({})
        }
        Request::Activate => {
            let (phase, id, state, due, _) = receipt.ok_or_else(conflict)?;
            let id = id.ok_or_else(conflict)?;
            let r = row(id)?;
            if r.core != core { return Err(conflict()); }
            if phase == "staged" {
                tx.execute("UPDATE routines SET state=?,next_at=? WHERE id=?",
                    params![state,future(&r.schedule,due,zone),id]).map_err(StoreError::from)?;
                tx.execute("UPDATE routine_transfers SET phase='installed' WHERE token=?",[token]).map_err(StoreError::from)?;
            } else if phase != "installed" { return Err(conflict()); }
            json!({"routine":row(id)?})
        }
        Request::Suspend { ref attempt } | Request::Resume { ref attempt } => {
            let resume = matches!(&request, Request::Resume { .. });
            let (phase, id, state, due, binding) = receipt.ok_or_else(conflict)?;
            let id = id.ok_or_else(conflict)?;
            let r = row(id)?;
            if attempt.len() != 36 || r.core != core || binding != Some(review_binding(&r)) {
                return Err(conflict());
            }
            let known: Option<bool> = tx.query_row(
                "SELECT cancelled FROM routine_undo_attempts WHERE token=? AND attempt=?",
                params![token, attempt], |row| row.get(0)
            ).optional().map_err(StoreError::from)?;
            if resume {
                if phase == "suspended" && known == Some(false) {
                    tx.execute("UPDATE routines SET state=?,next_at=? WHERE id=?",
                        params![state,future(&r.schedule,due,zone),id]).map_err(StoreError::from)?;
                    tx.execute("UPDATE routine_transfers SET phase='installed' WHERE token=?",
                        [token]).map_err(StoreError::from)?;
                }
                tx.execute("INSERT INTO routine_undo_attempts VALUES(?,?,1)
                    ON CONFLICT(token,attempt) DO UPDATE SET cancelled=1",
                    params![token,attempt]).map_err(StoreError::from)?;
            } else if known != Some(true) && !(phase == "suspended" && known == Some(false)) {
                if phase != "installed" || state.as_deref() != Some(r.state.as_str())
                    || pending(&tx,&r).map_err(StoreError::from)? { return Err(conflict()); }
                freeze_events(&tx,id)?;
                tx.execute("INSERT INTO routine_undo_attempts VALUES(?,?,0)",
                    params![token,attempt]).map_err(StoreError::from)?;
                tx.execute("UPDATE routine_transfers SET phase='suspended',original_next=? WHERE token=?",
                    params![r.next_at,token]).map_err(StoreError::from)?;
                tx.execute("UPDATE routines SET state='archived',next_at=NULL WHERE id=?",
                    [id]).map_err(StoreError::from)?;
            } else if !resume && known == Some(true) { return Err(conflict()); }
            json!({})
        }
        Request::Retire | Request::Restore => {
            let restore = matches!(request, Request::Restore);
            if let Some((phase, id, state, next, binding)) = receipt {
                if phase != "closed" {
                    let id = id.ok_or_else(conflict)?;
                    let r = row(id)?;
                    if r.core != core || pending(&tx,&r).map_err(StoreError::from)? { return Err(conflict()); }
                    if restore && phase == "held" {
                        tx.execute("UPDATE routines SET state=?,next_at=? WHERE id=?",params![state,future(&r.schedule,next,zone),id]).map_err(StoreError::from)?;
                    } else if !restore && (phase == "suspended" || phase == "staged" || phase == "installed" && state.as_deref() == Some(r.state.as_str())) && binding == Some(review_binding(&r)) {
                        freeze_events(&tx,id)?;
                        tx.execute("UPDATE routines SET state='archived',next_at=NULL,webhook_hash=NULL WHERE id=?",[id]).map_err(StoreError::from)?;
                    } else { return Err(conflict()); }
                    tx.execute("UPDATE routine_transfers SET phase='closed' WHERE token=?",[token]).map_err(StoreError::from)?;
                }
            } else {
                tx.execute("INSERT INTO routine_transfers(token,phase) VALUES(?,'closed')",[token]).map_err(StoreError::from)?;
            }
            json!({})
        }
    };
    tx.commit().map_err(StoreError::from)?;
    Ok(Json(result))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scheduled_cutover_preserves_the_future_slot_and_skips_missed_intervals() {
        let (_root, history) = crate::bots::testing::journal(&[]);
        let mut db = history.db().unwrap();
        let schedule = Schedule::Interval { minutes: 60 };
        let due = now() + 3_600_000;
        let result = transact(&mut db, "fixture", "destination", Request::Install {
            owner: "owner".into(), target: Target { address: "fixture".into(), created_ms: 1 },
            name: "Hourly".into(), task: "fixture".into(), schedule: schedule.clone(),
            state: "active".into(), next_at: Some(due),
        }, Some("mapped")).unwrap();
        assert_eq!(result.0["routine"]["state"], "archived");
        assert!(result.0["routine"]["next_at"].is_null());
        for _ in 0..2 {
            let result = transact(&mut db, "fixture", "destination", Request::Activate, None).unwrap();
            assert_eq!(result.0["routine"]["state"], "active");
            assert_eq!(result.0["routine"]["next_at"], due);
        }
        let earlier = due - 15 * 60_000 - 2 * 3_600_000;
        assert_eq!(future(&schedule, Some(earlier), chrono_tz::UTC), Some(due - 15 * 60_000));
    }

    #[test]
    fn retry_cancel_and_undo_keep_webhook_auth_on_its_original_server() {
        let (_s, origin) = crate::bots::testing::journal(&[]);
        let (_d, destination) = crate::bots::testing::journal(&[]);
        let mut src = origin.db().unwrap();
        let mut dst = destination.db().unwrap();
        let filter = r#"{"kind":"webhook","review":true,"filters":[{"field":"action","equals":"opened"}]}"#;
        let id: i64 = src.query_row(
            "INSERT INTO routines(core,address,created_ms,agent,name,task,schedule,state,webhook_hash)
             VALUES('s','a',1,'bot','issues','triage',?,'paused',?) RETURNING id",
            params![filter,webhook_hash("fixture")], |r| r.get(0)).unwrap();
        let target = || Target { address: "a".into(), created_ms: 1 };
        let install = || Request::Install { owner: "owner".into(), target: target(), name: "issues".into(), task: "triage".into(),
            schedule: serde_json::from_str(filter).unwrap(), state: "paused".into(), next_at: None };
        let run = |db: &mut Connection, core, req| transact(db,"fixture",core,req,Some("mapped"));
        for _ in 0..2 {
            let held = run(&mut src,"s",Request::Hold {id,target:target()}).unwrap();
            assert_eq!(held.0["routine"]["state"], "paused");
            assert!(held.0["routine"]["schedule"]["review"].as_bool().unwrap());
            assert_eq!(run(&mut dst,"d",install()).unwrap().0["routine"]["id"],1);
        }
        assert_eq!(run(&mut dst,"d",Request::Activate).unwrap().0["routine"]["state"],"paused");
        assert!(!webhook_authorized(&dst,1,&HookAuth::Bearer("fixture")).unwrap());
        let attempt = "00000000-0000-0000-0000-000000000001";
        let suspend = || Request::Suspend { attempt: attempt.into() };
        run(&mut dst,"d",suspend()).unwrap();
        run(&mut dst,"d",suspend()).unwrap();
        run(&mut dst,"d",Request::Resume { attempt: attempt.into() }).unwrap();
        assert!(run(&mut dst,"d",suspend()).is_err());
        run(&mut dst,"d",Request::Retire).unwrap();
        run(&mut src,"s",Request::Restore).unwrap();
        assert!(webhook_authorized(&src,id,&HookAuth::Bearer("fixture")).unwrap());
        assert!(run(&mut dst,"d",install()).is_err());
        assert!(run(&mut src,"s",Request::Hold {id,target:target()}).is_err());
        transact(&mut dst,"cancel","d",Request::Retire,None).unwrap();
        assert!(transact(&mut dst,"cancel","d",install(),Some("mapped")).is_err());
    }
}
