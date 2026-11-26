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
    active_turn: Option<String>,
    state: String,
    task: String,
    reply: String,
}

#[derive(Deserialize)]
struct Activity {
    #[serde(flatten)]
    child: Child,
    details: Option<Details>,
    transcript: String,
}

#[derive(Deserialize, Serialize)]
struct Details {
    task: String,
    reply: String,
    steps: Vec<Step>,
}

#[derive(Deserialize, Serialize)]
struct Step {
    text: String,
    state: Option<String>,
}

pub(crate) fn capture() -> Result<(), Box<dyn std::error::Error>> {
    let (journal, key) = session()?;
    let activity: Activity = serde_json::from_str(&read_input(768 * 1024)?)?;
    let child = activity.child;
    if !valid_session(&child.id)
        || !valid_session(&child.parent)
        || child.id == child.parent
        || child
            .active_turn
            .as_deref()
            .is_some_and(|t| child.state != "working" || !valid_turn(t))
        || !matches!(
            child.state.as_str(),
            "working" | "answered" | "finished" | "stopped" | "error"
        )
    {
        return Err("Invalid OpenCode child session.".into());
    }
    let mut summary = serde_json::to_value(&child)?;
    if let Some(details) = activity.details {
        summary["details"] = serde_json::to_value(details)?;
    }
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

fn valid_turn(turn: &str) -> bool {
    turn.len() == 32 && turn.bytes().all(|b| b.is_ascii_hexdigit())
}

pub(crate) async fn interrupt(
    key: &str,
    child: &str,
    parent: &str,
    turn: &str,
) -> Result<(), crate::ApiError> {
    use crate::{ApiError, core::Failure};
    use ring::digest::{SHA256, digest};
    use std::os::unix::fs::{MetadataExt, PermissionsExt};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::UnixStream,
        time::{Duration, timeout},
    };

    let stale = || ApiError::Conflict("This helper turn is no longer running.");
    if !valid_turn(turn) || !valid_session(child) || !valid_session(parent) || child == parent {
        return Err(stale());
    }
    let binding = [key, parent, child, turn].join("\n");
    let hash = digest(&SHA256, binding.as_bytes());
    let name: String = hash.as_ref()[..16]
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    let directory = std::path::PathBuf::from(format!("/tmp/swarmhub-oc-stop-{name}"));
    let meta = std::fs::symlink_metadata(&directory)
        .map_err(|_| stale())?;
    // SAFETY: geteuid has no memory preconditions.
    let uid = unsafe { libc::geteuid() };
    if !meta.is_dir() || meta.uid() != uid || meta.permissions().mode() & 0o077 != 0 {
        return Err(stale());
    }
    timeout(Duration::from_secs(8), async {
        let mut stream = UnixStream::connect(directory.join("stop"))
            .await
            .map_err(|_| stale())?;
        if stream.peer_cred().map_err(|_| stale())?.uid() != uid {
            return Err(stale());
        }
        stream
            .write_all(b"S")
            .await
            .map_err(|_| Failure::Uncertain)?;
        match stream.read_u8().await.map_err(|_| Failure::Uncertain)? {
            b'Y' => Ok(()),
            b'N' => Err(stale()),
            _ => Err(Failure::Uncertain.into()),
        }
    })
    .await
    .map_err(|_| Failure::Uncertain)?
}
