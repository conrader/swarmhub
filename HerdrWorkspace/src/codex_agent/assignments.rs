//! Recent Codex versions summarize a spawn as subAgentActivity. The parent's persisted
//! spawn call and its successful receipt still identify the task that was actually assigned.
use chrono::DateTime;
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde_json::Value;
use std::{
    collections::HashMap,
    fs::{File, OpenOptions},
    io::{self, BufRead, BufReader, Read},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::SystemTime,
};

const LINE_LIMIT: u64 = 1024 * 1024;

#[derive(Default)]
pub(super) struct Assignments {
    log: Option<ParentLog>,
}

struct ParentLog {
    parent: String,
    path: PathBuf,
    length: u64,
    modified: SystemTime,
    receipts: Vec<Receipt>,
}

struct Receipt {
    id: Option<String>,
    path: Option<String>,
    started: i64,
    returned: i64,
    task: String,
}

impl Assignments {
    pub(super) fn find(
        &mut self,
        index: &Connection,
        home: &Path,
        child: &str,
        parent: &str,
    ) -> Option<String> {
        let (source, path): (String, String) = index
            .query_row(
                "SELECT c.source,p.rollout_path FROM threads c JOIN threads p ON p.id=?2
             WHERE c.id=?1 AND c.originator='swarmhub-herdr'",
                [child, parent],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .ok()?;
        let source: Value = serde_json::from_str(&source).ok()?;
        let spawn = &source["subagent"]["thread_spawn"];
        if spawn["parent_thread_id"].as_str() != Some(parent) {
            return None;
        }

        let path = Path::new(&path).canonicalize().ok()?;
        let home = home.canonicalize().ok()?;
        if !["sessions", "archived_sessions"]
            .iter()
            .any(|dir| path.starts_with(home.join(dir)))
        {
            return None;
        }
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&path)
            .ok()?;
        let meta = file.metadata().ok()?;
        if !meta.is_file() {
            return None;
        }
        let modified = meta.modified().ok()?;
        let stale = self.log.as_ref().is_none_or(|log| {
            log.parent != parent
                || log.path != path
                || log.length != meta.len()
                || log.modified != modified
        });
        if stale {
            self.log = Some(ParentLog {
                parent: parent.to_owned(),
                path,
                length: meta.len(),
                modified,
                receipts: receipts(file, parent, meta.len()).ok()?,
            });
        }
        let birth = uuid_millis(child);
        let agent_path = spawn["agent_path"].as_str();
        let mut matches = self.log.as_ref()?.receipts.iter().filter(|r| match &r.id {
            Some(id) => id == child,
            None => {
                agent_path.is_some()
                    && agent_path == r.path.as_deref()
                    && birth.is_some_and(|t| r.started <= t && t <= r.returned)
            }
        });
        let first = matches.next()?;
        matches.next().is_none().then(|| first.task.clone())
    }
}

// A path may be reused. Only accept a path-only receipt if this UUIDv7 was created inside
// that specific call. A receipt returning a thread ID already identifies the child exactly.
fn uuid_millis(id: &str) -> Option<i64> {
    if !super::stream::children::valid(id) || id.as_bytes()[14] != b'7' {
        return None;
    }
    i64::from_str_radix(&format!("{}{}", &id[..8], &id[9..13]), 16).ok()
}

fn receipts(file: File, parent: &str, length: u64) -> io::Result<Vec<Receipt>> {
    let mut reader = BufReader::new(file.take(length));
    let mut buf = Vec::new();
    let mut header = true;
    let mut pending = HashMap::new();
    let mut found = Vec::new();
    loop {
        buf.clear();
        if (&mut reader).take(LINE_LIMIT).read_until(b'\n', &mut buf)? == 0 {
            break;
        }
        if buf.last() != Some(&b'\n') {
            if header {
                break;
            }
            reader.skip_until(b'\n')?;
            continue;
        }
        let Ok(line) = std::str::from_utf8(&buf) else {
            if header {
                break;
            }
            continue;
        };
        if !header && !line.contains("\"function_call") {
            continue;
        }
        let Ok(row) = serde_json::from_str::<Value>(line) else {
            if header {
                break;
            }
            continue;
        };
        let p = &row["payload"];
        if header {
            if row["type"] != "session_meta" || p["id"] != parent {
                break;
            }
            header = false;
            continue;
        }
        if row["type"] != "response_item" {
            continue;
        }
        let Some(call) = p["call_id"].as_str() else {
            continue;
        };
        let Some(at) = row["timestamp"]
            .as_str()
            .and_then(|s| DateTime::parse_from_rfc3339(s).ok())
        else {
            continue;
        };
        let ms = at.timestamp_millis();
        match p["type"].as_str() {
            Some("function_call")
                if p["name"] == "spawn_agent"
                    && (p["namespace"].is_null() || p["namespace"] == "collaboration") =>
            {
                if let Some(args) = p["arguments"]
                    .as_str()
                    .and_then(|s| serde_json::from_str::<Value>(s).ok())
                    && let Some(task) = args["message"].as_str().filter(|s| !s.trim().is_empty())
                {
                    pending.insert(
                        call.to_owned(),
                        (ms, super::stream::children::clipped(task, 8000).to_owned()),
                    );
                }
            }
            Some("function_call_output") => {
                if let Some((started, task)) = pending.remove(call)
                    && let Some(result) = p["output"]
                        .as_str()
                        .and_then(|s| serde_json::from_str::<Value>(s).ok())
                    && result.get("error").is_none()
                    && (result["agent_id"].is_string() || result["task_name"].is_string())
                {
                    found.push(Receipt {
                        id: result["agent_id"].as_str().map(str::to_owned),
                        path: result["task_name"].as_str().map(str::to_owned),
                        started,
                        returned: ms,
                        task,
                    });
                }
            }
            _ => {}
        }
    }
    Ok(found)
}

pub(super) fn home() -> Option<PathBuf> {
    std::env::var_os("CODEX_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| Some(PathBuf::from(std::env::var_os("HOME")?).join(".codex")))
        .filter(|p| p.is_absolute())
}

pub(super) fn index() -> Option<Connection> {
    Connection::open_with_flags(
        super::prefetch::home()?.join("state_5.sqlite"),
        OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .ok()
}

pub(super) fn fill_saved(db: &Connection, index: &Connection, home: &Path) -> rusqlite::Result<()> {
    // Archived sessions can have a protected assignment, even on older Workspaces.
    let mut missing = db.prepare(
        "SELECT launch,thread,json_extract(summary,'$.parent') FROM codex_children
        WHERE json_type(summary,'$.task_name') IS NULL AND json_type(summary,'$.parent')='text'",
    )?;
    let rows = missing
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut source = index
        .prepare_cached("SELECT source FROM threads WHERE id=?1 AND originator='swarmhub-herdr'")?;
    for (launch, child, parent) in rows {
        let record = source
            .query_row([&child], |r| r.get::<_, String>(0))
            .optional()?;
        let Some(data) = record.and_then(|text| serde_json::from_str::<Value>(&text).ok()) else {
            continue;
        };
        let spawn = &data["subagent"]["thread_spawn"];
        if spawn["parent_thread_id"].as_str() == Some(&parent)
            && let Some(name) = spawn["agent_path"]
                .as_str()
                .and_then(super::stream::children::task_name)
        {
            db.execute("UPDATE codex_children SET summary=json_set(summary,'$.task_name',?3), revision=revision+1
                WHERE launch=?1 AND thread=?2 AND json_type(summary,'$.task_name') IS NULL AND json_extract(summary,'$.parent')=?4",
                params![launch,child,name,parent])?;
        }
    }
    let mut cache = Assignments::default();
    let mut select=db.prepare("SELECT launch,thread,json_extract(summary,'$.parent') FROM codex_children
        WHERE json_type(summary,'$.parent')='text' AND coalesce(json_extract(summary,'$.details.task'),'')='' ORDER BY json_extract(summary,'$.parent')")?;
    let rows = select
        .query_map([], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, String>(2)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    for (launch, child, parent) in rows {
        if let Some(task) = cache.find(index, home, &child, &parent) {
            db.execute("UPDATE codex_children SET summary=json_set(summary,'$.task',?3,'$.details.task',?4),revision=revision+1
                WHERE launch=?1 AND thread=?2 AND coalesce(json_extract(summary,'$.details.task'),'')=''",
                params![launch,child,super::stream::children::clipped(&task,300),task])?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::Write;

    #[test]
    fn fills_only_a_confirmed_child_and_keeps_saved_activity() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("sessions");
        std::fs::create_dir(&dir).unwrap();
        let log = dir.join("parent.jsonl");
        let mut file = File::create(&log).unwrap();
        let parent = "root-thread";
        let child = "00000000-03ed-7000-8000-000000000001"; // 1005 ms
        writeln!(
            file,
            "{}",
            json!({"type":"session_meta","payload":{"id":parent}})
        )
        .unwrap();
        let mut event = |ms: i64, p: Value| {
            let time = chrono::DateTime::from_timestamp_millis(ms)
                .unwrap()
                .to_rfc3339();
            writeln!(
                file,
                "{}",
                json!({"type":"response_item","timestamp":time,"payload":p})
            )
            .unwrap();
        };
        let spawn = |id: &str, msg: &str| json!({"namespace":"collaboration","name":"spawn_agent","type":"function_call","call_id":id,"arguments":json!({"message":msg}).to_string()});
        let result = |id: &str, body: Value| json!({"type":"function_call_output","call_id":id,"output":body.to_string()});
        event(950, spawn("earlier", "Earlier task"));
        event(990, result("earlier", json!({"task_name":"/root/qa"})));
        event(1000, spawn("ours", "Check the sidebar"));
        event(1001, spawn("other", "Different task"));
        event(1002, spawn("failed", "Failed task"));
        event(
            1010,
            result("failed", json!({"error":"failed","task_name":"/root/qa"})),
        );
        event(
            1011,
            result(
                "other",
                json!({"agent_id":"different-id","task_name":"/root/qa"}),
            ),
        );
        event(1012, result("ours", json!({"task_name":"/root/qa"})));
        let source=json!({"subagent":{"thread_spawn":{"parent_thread_id":parent,"agent_path":"/root/qa"}}}).to_string();
        let native = Connection::open_in_memory().unwrap();
        native
            .execute_batch(
                "CREATE TABLE threads(id TEXT,source TEXT,rollout_path TEXT,originator TEXT)",
            )
            .unwrap();
        native
            .execute(
                "INSERT INTO threads VALUES(?1,NULL,?2,NULL),(?3,?4,NULL,'swarmhub-herdr')",
                params![parent, log.to_str(), child, source],
            )
            .unwrap();
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE codex_children(launch INTEGER,thread TEXT,summary TEXT,revision INTEGER,transcript TEXT)").unwrap();
        let snapshot =
            json!({"parent":parent,"details":{"task":"","reply":"Done"},"state":"answered"});
        db.execute("INSERT INTO codex_children VALUES(1,?1,?2,4,'Saved transcript'),(2,'legacy','{}',0,'')",params![child,snapshot.to_string()]).unwrap();
        for _ in 0..2 {
            fill_saved(&db, &native, tmp.path()).unwrap();
        }
        let found: (String, i64, String) = db
            .query_row(
                "SELECT summary,revision,transcript FROM codex_children WHERE launch=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        let mut expected = snapshot;
        expected["task_name"] = json!("qa");
        expected["task"] = json!("Check the sidebar");
        expected["details"]["task"] = expected["task"].clone();
        assert_eq!(serde_json::from_str::<Value>(&found.0).unwrap(), expected);
        assert_eq!((found.1, found.2.as_str()), (6, "Saved transcript"));
        // A second successful call with the same path and overlapping lifetime is ambiguous.
        event(1000, spawn("ambiguous", "Unrelated"));
        event(1020, result("ambiguous", json!({"task_name":"/root/qa"})));
        assert!(
            Assignments::default()
                .find(&native, tmp.path(), child, parent)
                .is_none()
        );
    }
}
