//! Reconcile saved native Codex workers after startup, including launches whose terminal has ended.
//! The bot folder narrows discovery. Only Codex's parent thread or an exact root turn recorded
//! by the workspace establishes which launch owns a child.
use super::stream::children::{Snapshot, origin};
use rusqlite::{Connection, OpenFlags, params};
use serde_json::Value;
use std::{collections::HashSet, error::Error, path::Path};

type Failure = Box<dyn Error + Send + Sync>;

pub(crate) fn recover_sessions(journal: &Path) {
    let journal = journal.to_owned();
    tokio::task::spawn_blocking(move || {
        let Some(home) = super::prefetch::home() else {
            return;
        };
        let Some(root) = crate::core::bot_workspace_root().ok().flatten() else {
            return;
        };
        let index = home.join("state_5.sqlite");
        if index.is_file()
            && let Err(error) = reconcile(&journal, &index, &root)
        {
            eprintln!("Could not recover saved Codex sessions: {error}");
        }
    });
}

fn reconcile(journal: &Path, index: &Path, root: &Path) -> Result<(), Failure> {
    let db = crate::history::connection(journal)?;
    let saved = Connection::open_with_flags(index, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
    let mut bots = db.prepare("SELECT lower(id) FROM bots WHERE removed_ms IS NULL")?;
    let bot_ids: HashSet<String> = bots
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let mut known = db.prepare("SELECT DISTINCT thread FROM codex_children")?;
    let indexed: HashSet<String> = known
        .query_map([], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    let candidates: Vec<(String, String)> = {
        let mut threads = saved.prepare(
            "SELECT id,cwd FROM threads WHERE originator='swarmhub-herdr'
            AND source LIKE '%\"thread_spawn\"%' ORDER BY updated_at DESC",
        )?;
        threads
            .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
            .collect::<Result<_, _>>()?
    };
    let mut server = None;
    for (id, cwd) in candidates {
        let folder = Path::new(&cwd);
        let Some(bot) = folder.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if folder.parent() != Some(root) || !bot_ids.contains(bot) || indexed.contains(&id) {
            continue;
        }
        if server.is_none() {
            server = Some(super::models::initialized(super::executable())?);
        }
        match server.as_mut().unwrap().saved_thread(&id) {
            Ok(thread) => {
                restore(&db, &id, bot, folder, &thread)?;
            }
            // A missing rollout or an oversized frame must not prevent the next child's read.
            Err(_) => {
                server = None;
            }
        }
    }
    Ok(())
}

fn restore(
    db: &Connection,
    id: &str,
    bot: &str,
    cwd: &Path,
    thread: &Value,
) -> rusqlite::Result<usize> {
    let Some(parent) = origin(thread) else {
        return Ok(0);
    };
    if thread["id"] != id
        || thread["originator"] != "swarmhub-herdr"
        || thread["cwd"].as_str().map(Path::new) != Some(cwd)
        || thread["ephemeral"] == true
    {
        return Ok(0);
    }
    let turns: Vec<_> = thread["turns"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|turn| turn["id"].as_str().is_some_and(|turn_id| turn_id >= id))
        .collect();
    if !matches!(
        turns.last().and_then(|turn| turn["status"].as_str()),
        Some("completed" | "interrupted" | "failed")
    ) {
        return Ok(0);
    }
    let events: Vec<_> = turns
        .iter()
        .filter_map(|turn| turn["rootTurnId"].as_str())
        .filter(|turn| super::valid_turn(turn))
        .map(|turn| format!("codex:{turn}"))
        .collect();
    let mut owners = db.prepare_cached(
        "SELECT p.id FROM journal p
        WHERE lower(p.parent_bot_id)=?1 AND p.launch_key IS NOT NULL AND (p.usage_thread=?2
        OR p.launch_key IN (SELECT reply_for FROM journal WHERE kind='reply'
           AND event_key IN (SELECT value FROM json_each(?3)))) LIMIT 2",
    )?;
    let matches: Vec<i64> = owners
        .query_map(
            params![bot, parent, serde_json::json!(events).to_string()],
            |r| r.get(0),
        )?
        .collect::<Result<_, _>>()?;
    match matches.as_slice() {
        [launch] => Snapshot::read(id, parent, "", thread).restore(db, *launch),
        _ => Ok(0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    const BOT: &str = "bot-id";
    const ROOT: &str = "01a217c2-0000-7000-8000-000000000000";
    const CHILD: &str = "01a217c2-1111-7000-8000-000000000000";
    const TURN: &str = "01a217c2-2222-7000-8000-000000000000";
    #[test]
    fn historical_child_requires_one_exact_owner_and_preserves_live_data() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE journal(id INTEGER PRIMARY KEY,kind TEXT,parent_bot_id TEXT,launch_key TEXT,reply_for TEXT,event_key TEXT,usage_thread TEXT);
            CREATE TABLE codex_children(launch INTEGER,thread TEXT,summary TEXT,transcript TEXT,PRIMARY KEY(launch,thread));
            INSERT INTO journal(id,kind,parent_bot_id,launch_key) VALUES(1,'task','bot-id','launch'),(2,'task','other','second');").unwrap();
        let cwd = Path::new("/work/bot-id");
        let mut thread = json!({"id":CHILD,"cwd":cwd,"originator":"swarmhub-herdr","source":{"subAgent":{"thread_spawn":{"parent_thread_id":ROOT}}},
            "agentNickname":"Tests","turns":[{"id":TURN,"rootTurnId":ROOT,"status":"completed","items":[{"type":"agentMessage","text":"Verified."}]}]});
        let recover = |v: &Value| restore(&db, CHILD, BOT, cwd, v).unwrap();
        assert_eq!(recover(&thread), 0);
        db.execute("INSERT INTO journal(kind,reply_for,event_key) VALUES('reply','second',?1),('reply','launch',?1)",[format!("codex:{ROOT}")]).unwrap();
        assert_eq!(recover(&thread), 1);
        let (launch, name, transcript): (i64, String, String) = db
            .query_row(
                "SELECT launch,json_extract(summary,'$.name'),transcript FROM codex_children",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(
            (launch, name.as_str(), transcript.as_str()),
            (1, "Tests", "Codex Verified.")
        );
        db.execute("UPDATE codex_children SET transcript='live result'", [])
            .unwrap();
        assert_eq!(recover(&thread), 0);
        assert_eq!(
            db.query_row("SELECT transcript FROM codex_children", [], |r| r
                .get::<_, String>(0))
                .unwrap(),
            "live result"
        );
        db.execute("DELETE FROM codex_children", []).unwrap();
        db.execute("UPDATE journal SET parent_bot_id=?1 WHERE id=2", [BOT])
            .unwrap();
        assert_eq!(recover(&thread), 0);
        db.execute("DELETE FROM journal WHERE id=2", []).unwrap();
        thread["source"] = json!({"subAgent":{"other":"guardian"}});
        assert_eq!(recover(&thread), 0);
    }
}
