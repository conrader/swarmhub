use super::{first_task::valid_session, read_input, session};
use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};

#[derive(Deserialize, Serialize)]
struct Child {
    id: String,
    parent: String,
    name: String,
    model: Option<String>,
    created_ms: i64,
    completed_ms: Option<i64>,
    state: String,
    task: String,
    reply: String,
}

#[derive(Deserialize)]
struct Activity {
    #[serde(flatten)]
    child: Child,
    transcript: String,
}

pub(crate) fn capture() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let activity: Activity = serde_json::from_str(&read_input(256 * 1024)?)?;
    let child = activity.child;
    if !valid_session(&child.id)
        || !valid_session(&child.parent)
        || child.id == child.parent
        || !matches!(
            child.state.as_str(),
            "working" | "answered" | "finished" | "stopped" | "error"
        )
    {
        return Err("Invalid OpenCode child session.".into());
    }
    let mut summary = serde_json::to_value(&child)?;
    summary["runtime"] = "opencode".into();
    let db = Connection::open_with_flags(journal, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    db.busy_timeout(std::time::Duration::from_secs(2))?;
    db.execute(
        "INSERT INTO opencode_children(launch,thread,summary,transcript)
         SELECT id,?2,?3,?4 FROM journal WHERE launch_key=?1
         ON CONFLICT(launch,thread) DO UPDATE SET summary=excluded.summary, transcript=excluded.transcript,
         revision=opencode_children.revision+1 WHERE summary<>excluded.summary OR transcript<>excluded.transcript",
        params![key, child.id, summary.to_string(), activity.transcript],
    )?;
    Ok(())
}
