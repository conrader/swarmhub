//! Resume a bot's requested next step once its helper finishes an assignment.
use super::{Ctx, Who, rules};
use crate::{core, history::History};
use rusqlite::{OptionalExtension, params};
use std::collections::HashSet;

pub(crate) fn register(
    history: &History,
    parent: &str,
    name: &str,
    step: &str,
) -> Result<String, String> {
    if step.len() > 2_048 || core::validate_task(step).is_err() {
        return Err("Give the bot a next step of up to 2 KB of plain text.".into());
    }
    super::attempt(history, |ctx| {
        let Who::Bot(bot) = super::of_launch(ctx.db, parent)? else {
            return Ok(Err("A registered bot can schedule this follow-up in its direct chat.".to_owned()));
        };
        let group: bool = ctx.db.query_row(
            "SELECT EXISTS(SELECT 1 FROM group_members WHERE launch_key=?1)",
            [parent], |row| row.get(0),
        )?;
        if group {
            return Ok(Err("Helper follow-ups are available in a direct bot chat.".to_owned()));
        }

        let owned: Option<(i64, i64)> = ctx.db.query_row(
            "SELECT h.launch, coalesce((SELECT max(t.id) FROM journal t WHERE t.kind='task'
                AND t.core_id=j.core_id AND t.address=j.address AND t.created_ms=j.created_ms
                AND t.state!='not_sent'), j.id)
             FROM helpers h JOIN journal j ON j.id=h.launch
             WHERE h.parent_key=?1 AND h.name=?2 ORDER BY h.launch DESC LIMIT 1",
            params![parent, name], |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?;
        let Some((launch, task)) = owned else {
            return Ok(Err(format!("You have no helper named {name}.")));
        };
        let stopped: bool = ctx.db.query_row(
            "SELECT coalesce((SELECT CAST(value AS INTEGER) FROM bot_state WHERE key='floor:'||?1),0)>=?2",
            params![parent, task], |row| row.get(0),
        )?;
        if stopped {
            return Ok(Err("This assignment was stopped.".to_owned()));
        }
        ctx.db.execute(
            "INSERT INTO helper_followups(task, launch, bot, instruction) VALUES (?1,?2,?3,?4)
             ON CONFLICT(task) DO NOTHING",
            params![task, launch, bot.id, step],
        )?;
        let (existing, cancelled): (String, bool) = ctx.db.query_row(
            "SELECT instruction, cancelled FROM helper_followups WHERE task=?1",
            [task], |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        if cancelled || existing != step {
            return Ok(Err("That assignment already has a different or cancelled follow-up.".to_owned()));
        }
        Ok(Ok(format!("Follow-up recorded for {name}. Finish this turn. The workspace will send the outcome and your next step to this bot.")))
    }).map_err(|_| "The workspace could not save the helper follow-up.".to_owned())?
}

/// Snapshot pending assignments before asking Core which terminals are live. A launch which
/// acquires an address during that call must not be mistaken for a terminal that has closed.
pub(crate) fn pending(
    history: &History,
) -> Result<Vec<(i64, Option<String>)>, crate::history::StoreError> {
    let db = history.db()?;
    let mut rows = db.prepare_cached(
        "SELECT f.task, CASE WHEN j.address IS NOT NULL OR j.state='unconfirmed' THEN j.launch_key END
         FROM helper_followups f JOIN journal j ON j.id=f.launch WHERE f.outbox IS NULL AND f.cancelled=0",
    )?;
    Ok(rows
        .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?)
}

pub(crate) fn check(
    history: &History,
    core: &str,
    agents: &[core::Terminal],
    pending: Vec<(i64, Option<String>)>,
) -> Result<(), crate::history::StoreError> {
    if pending.is_empty() {
        return Ok(());
    }
    let live: HashSet<_> = agents
        .iter()
        .filter(|agent| agent.state == "live")
        .filter_map(core::Terminal::launch_key)
        .collect();
    let ended: Vec<_> = pending
        .into_iter()
        .filter_map(|(task, key)| key.filter(|k| !live.contains(k.as_str())).map(|_| task))
        .collect();
    let ended = serde_json::to_string(&ended).map_err(|_| crate::history::StoreError)?;
    super::write(history, |ctx| stage(ctx, core, &ended))
}

fn stage(ctx: &Ctx<'_>, core: &str, ended_tasks: &str) -> rusqlite::Result<()> {
    // Bound each reply to the assignment which requested it, even if the helper is reused before the sweep.
    let mut rows = ctx
        .db
        .prepare_cached(include_str!("helper-followups-ready.sql"))?;
    let ready = rows
        .query_map(params![core, ended_tasks], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
                row.get::<_, Option<String>>(4)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for (task, instruction, bot, name, answer) in ready {
        let text = match answer {
            Some(reply) => {
                let reply: String = reply
                    .chars()
                    .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'))
                    .collect();
                format!(
                    "[From SwarmHub] Your helper {name} finished its assignment. Your saved next step: {instruction}\n\nHelper reply (up to 2,000 characters):\n{reply}"
                )
            }
            None => format!(
                "[From SwarmHub] Your helper {name} closed or moved on without a saved answer to this assignment. Check its result before continuing your saved next step: {instruction}"
            ),
        };
        let outbox = rules::post(
            ctx,
            rules::Post {
                bot: &bot,
                text: &text,
                cause: "outcome",
                ..Default::default()
            },
        )?;
        ctx.db.execute(
            "UPDATE helper_followups SET outbox=?2 WHERE task=?1",
            params![task, outbox],
        )?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn followups_stay_with_their_assignment_and_resume_only_once() {
        let scratch = tempfile::tempdir().unwrap();
        let directory = scratch.path().join("workspace");
        let history = History::open_at(&directory).unwrap();
        history.db().unwrap().execute_batch(
            "INSERT INTO bots(id,name,agent_name,created_ms,updated_ms) VALUES('owner','Parent','parent',1,1);
             INSERT INTO journal(id,launch_key,core_id,address,created_ms,agent,kind,state,text,at_ms) VALUES
                  (1,'parent-key','core','t1',1,'parent','task','sent','parent work',1),
                  (2,'child-key','core','t2',2,'helper','task','sent','first assignment',2);
             INSERT INTO helpers(launch,parent_key,name,difficulty,template,model)
                  VALUES(2,'parent-key','sampler','easy','code','default');",
        ).unwrap();

        assert!(register(&history, "child-key", "sampler", "verify first").is_err());
        assert!(register(&history, "parent-key", "other", "verify first").is_err());
        register(&history, "parent-key", "sampler", "verify first").unwrap();
        register(&history, "parent-key", "sampler", "verify first").unwrap();
        assert!(register(&history, "parent-key", "sampler", "different action").is_err());
        history
            .db()
            .unwrap()
            .execute_batch(
                "INSERT INTO journal(core_id,address,created_ms,agent,kind,state,text,at_ms)
                  VALUES('core','t2',2,'helper','task','sent','second assignment',3);
             INSERT INTO journal(core_id,reply_for,agent,kind,state,text,at_ms)
                  VALUES('core','child-key','helper','reply','received','SECOND RESULT',4);",
            )
            .unwrap();
        register(&history, "parent-key", "sampler", "verify second").unwrap();
        drop(history);
        let history = History::open_at(&directory).unwrap();
        for _ in 0..2 {
            super::super::write(&history, |ctx| stage(ctx, "core", "[]")).unwrap();
        }
        let rows = history
            .db()
            .unwrap()
            .prepare("SELECT text FROM bot_outbox WHERE bot='owner' ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        assert_eq!(rows.len(), 2);
        assert!(rows[0].contains("without a saved answer") && !rows[0].contains("SECOND RESULT"));
        assert!(rows[1].contains("verify second") && rows[1].contains("SECOND RESULT"));
        assert!(pending(&history).unwrap().is_empty());
        // This is the bot's own next step, including when messages from peers are off.
        history.db().unwrap().execute_batch(
            "UPDATE bots SET takes_messages=0 WHERE id='owner';
             UPDATE bot_outbox SET state='typing',task=3 WHERE id=(SELECT min(id) FROM bot_outbox);"
        ).unwrap();
        let first = history
            .db()
            .unwrap()
            .query_row("SELECT min(id) FROM bot_outbox", [], |r| r.get(0))
            .unwrap();
        let delivery = crate::warm::Wait::Outbox { id: first, task: 3 };
        assert!(delivery.check_outbox(&history).is_ok());
        super::super::write(&history, |ctx| {
            let owner = super::super::one(ctx.db, "owner")?.unwrap();
            rules::stop(ctx, &owner, rules::Why::Person)?;
            Ok(())
        })
        .unwrap();
        let dropped: i64 = history
            .db()
            .unwrap()
            .query_row(
                "SELECT count(*) FROM bot_outbox WHERE state='dropped'",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(dropped, 1);
        assert!(delivery.check_outbox(&history).is_err());
    }
}
