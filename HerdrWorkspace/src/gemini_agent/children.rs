//! Gemini writes the scheduled invoke_agent call before BeforeTool. A later entry with the same
//! call ID contains the result. Hooks for two simultaneous children carry the same parent session
//! ID, so neither the name of a tool nor the order of hook arrivals identifies a child.
use super::Event;
use crate::history;
use rusqlite::{Connection, OptionalExtension, TransactionBehavior, params};
use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    env,
    fs::{self, File, OpenOptions},
    io::{BufRead, BufReader, Read, Seek, SeekFrom},
    os::unix::fs::OpenOptionsExt,
    path::{Component, Path, PathBuf},
};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;
const MAX_LINE: u64 = 8 * 1024 * 1024;

fn identifier(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 128
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
}

// Keep the path inside the managed user's Gemini chat directory, including on a Mac whose
// home is reached through a symlink. The session and project must also match the file header.
fn local_path(reported: &Path) -> Option<PathBuf> {
    let home = PathBuf::from(env::var_os("GEMINI_CLI_HOME").or_else(|| env::var_os("HOME"))?);
    let real_home = home.canonicalize().ok()?;
    let base = Path::new(".gemini/tmp");
    let tail = reported
        .strip_prefix(home.join(base))
        .or_else(|_| reported.strip_prefix(real_home.join(base)))
        .ok()?;
    let mut parts = tail.components();
    let (
        Some(Component::Normal(_)),
        Some(Component::Normal(chats)),
        Some(Component::Normal(name)),
        None,
    ) = (parts.next(), parts.next(), parts.next(), parts.next())
    else {
        return None;
    };
    let name = name.to_str()?;
    if chats != "chats" || !name.starts_with("session-") || !name.ends_with(".jsonl") {
        return None;
    }
    let expected = real_home.join(base).join(tail);
    (expected.canonicalize().ok()? == expected).then_some(expected)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Header {
    kind: String,
    session_id: String,
    project_hash: String,
}

fn open_parent(path: &Path, session: &str, hash: &str) -> Option<BufReader<File>> {
    let checked = local_path(path)?;
    open_log(&checked, "main", session, hash)
}

fn open_log(checked: &Path, kind: &str, session: &str, hash: &str) -> Option<BufReader<File>> {
    let f = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
        .open(checked)
        .ok()?;
    if !f.metadata().ok()?.is_file() {
        return None;
    }
    let mut reader = BufReader::new(f);
    let mut header = Vec::new();
    if (&mut reader)
        .take(64 * 1024)
        .read_until(b'\n', &mut header)
        .ok()?
        == 0
        || header.last() != Some(&b'\n')
    {
        return None;
    }
    let header: Header = serde_json::from_slice(&header).ok()?;
    (header.kind == kind && header.session_id == session && header.project_hash == hash)
        .then_some(reader)
}

pub(super) fn observe(journal: &Path, key: &str, event: &Event) {
    let relevant = match event.hook_event_name.as_str() {
        "BeforeTool" | "AfterTool" => event.tool_name.as_deref() == Some("invoke_agent"),
        "SessionStart" | "BeforeAgent" | "AfterAgent" | "SessionEnd" => true,
        _ => false,
    };
    if !relevant {
        return;
    }
    let (Some(session), Some(path), Some(cwd)) =
        (&event.session_id, &event.transcript_path, &event.cwd)
    else {
        return;
    };
    if !identifier(session)
        || fs::canonicalize(cwd)
            .ok()
            .zip(env::current_dir().ok().and_then(|p| p.canonicalize().ok()))
            .is_none_or(|(a, b)| a != b || !super::bridge_made(&a))
    {
        return;
    }
    let _ = observe_session(journal, key, event, session, Path::new(path), cwd);
}

fn observe_session(
    journal: &Path,
    key: &str,
    event: &Event,
    session: &str,
    path: &Path,
    cwd: &str,
) -> Result<()> {
    let hash = format!("{:x}", Sha256::digest(cwd.as_bytes()));
    let Some(mut reader) = open_parent(path, session, &hash) else {
        return Ok(());
    };
    let mut db = history::connection(journal)?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let launch: i64 = tx.query_row("SELECT id FROM journal WHERE launch_key=?", [key], |r| {
        r.get(0)
    })?;
    let size = reader.get_ref().metadata()?.len();
    // Start at the end of a resumed conversation. Never copy old exchanges into a new bot's launch.
    if matches!(
        event.hook_event_name.as_str(),
        "SessionStart" | "BeforeAgent"
    ) {
        tx.execute("INSERT INTO gemini_transcripts(launch,session,path,project_hash,offset) VALUES(?,?,?,?,?)
                    ON CONFLICT(launch) DO UPDATE SET session=excluded.session,path=excluded.path,
                    project_hash=excluded.project_hash,offset=excluded.offset WHERE session<>excluded.session",
            params![launch,session,path.to_str(),hash,size])?;
    }
    if let Some(offset) = tx.query_row("SELECT offset FROM gemini_transcripts WHERE launch=? AND session=? AND path=? AND project_hash=?",
        params![launch,session,path.to_str(),hash], |r|r.get::<_,u64>(0)).optional()? {
        consume(&tx, launch, session, &mut reader, offset, size)?;
        if event.hook_event_name == "SessionEnd" {
            tx.execute("DELETE FROM gemini_transcripts WHERE launch=? AND session=?",params![launch,session])?;
            tx.execute("UPDATE gemini_children SET summary=json_set(summary,'$.state','stopped','$.completed_ms',?),
                        revision=revision+1 WHERE launch=? AND json_extract(summary,'$.parent')=? AND json_extract(summary,'$.state')='working'",
                        params![history::now(),launch,session])?;
        }
    }
    tx.commit()?;
    Ok(())
}

// The final tool receipt is written after AfterTool returns. A user can open the panel
// before the next parent hook, so reads of an active Gemini session also consume pending bytes.
pub(crate) async fn refresh_live(journal: &Path, key: &str) {
    let (journal, key) = (journal.to_owned(), key.to_owned());
    let _ = tokio::task::spawn_blocking(move || {
        let _ = refresh(&journal, &key);
    })
    .await;
}

fn refresh(journal: &Path, key: &str) -> Result<()> {
    let mut db = history::connection(journal)?;
    let source = db
        .query_row(
            "SELECT g.launch,g.session,g.path,g.project_hash,g.offset FROM gemini_transcripts g
        JOIN journal j ON j.id=g.launch WHERE j.launch_key=?",
            [key],
            |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    r.get::<_, String>(3)?,
                    r.get::<_, u64>(4)?,
                ))
            },
        )
        .optional()?;
    let Some((launch, session, path, hash, offset)) = source else {
        return Ok(());
    };
    let Some(mut reader) = open_parent(Path::new(&path), &session, &hash) else {
        return Ok(());
    };
    let size = reader.get_ref().metadata()?.len();
    if size <= offset {
        return Ok(());
    }
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    if tx
        .query_row(
            "SELECT 1 FROM gemini_transcripts WHERE launch=? AND session=? AND offset=?",
            params![launch, session, offset],
            |_| Ok(()),
        )
        .optional()?
        .is_some()
    {
        consume(&tx, launch, &session, &mut reader, offset, size)?;
    }
    tx.commit()?;
    Ok(())
}

#[derive(Deserialize)]
struct Row {
    #[serde(rename = "toolCalls", default)]
    calls: Vec<Call>,
}

#[derive(Deserialize)]
struct Call {
    id: String,
    name: String,
    #[serde(default)]
    args: Value,
    status: String,
    timestamp: Option<String>,
    #[serde(rename = "agentId")]
    agent_id: Option<String>,
    #[serde(rename = "resultDisplay", default)]
    display: Value,
    #[serde(default)]
    result: Value,
}

fn consume(
    db: &Connection,
    launch: i64,
    session: &str,
    reader: &mut BufReader<File>,
    mut offset: u64,
    size: u64,
) -> Result<()> {
    if offset >= size {
        return Ok(());
    }
    let source: (String, String) = db.query_row(
        "SELECT path,project_hash FROM gemini_transcripts WHERE launch=? AND session=?",
        params![launch, session],
        |r| Ok((r.get(0)?, r.get(1)?)),
    )?;
    reader.seek(SeekFrom::Start(offset))?;
    let mut line = Vec::new();
    let mut input = reader.take(size - offset);
    loop {
        line.clear();
        let count = (&mut input).take(MAX_LINE).read_until(b'\n', &mut line)? as u64;
        if count == 0 {
            break;
        }
        if line.last() != Some(&b'\n') {
            if count < MAX_LINE {
                break;
            }
            let mut skipped = 0;
            let mut ended = false;
            while !ended {
                let buf = input.fill_buf()?;
                if buf.is_empty() {
                    break;
                }
                let len = buf
                    .iter()
                    .position(|&v| v == b'\n')
                    .map_or(buf.len(), |at| {
                        ended = true;
                        at + 1
                    });
                input.consume(len);
                skipped += len as u64;
            }
            // A partial oversized record will be skipped from its beginning on the next hook.
            if !ended {
                break;
            }
            offset += count + skipped;
            continue;
        }
        offset += count;
        if let Ok(row) = serde_json::from_slice::<Row>(&line) {
            for call in row.calls {
                if call.name == "invoke_agent" && identifier(&call.id) {
                    save(db, launch, session, &call, &source)?;
                }
            }
        }
    }
    db.execute(
        "UPDATE gemini_transcripts SET offset=? WHERE launch=? AND session=?",
        params![offset, launch, session],
    )?;
    Ok(())
}

fn clipped(value: Option<&str>, bytes: usize) -> &str {
    let s = value.unwrap_or_default();
    &s[..s.floor_char_boundary(s.len().min(bytes))]
}

fn save(
    db: &Connection,
    launch: i64,
    session: &str,
    call: &Call,
    source: &(String, String),
) -> Result<()> {
    let name = clipped(call.args["agent_name"].as_str(), 256);
    if name.is_empty() {
        return Ok(());
    }
    let task = clipped(call.args["prompt"].as_str(), 24000);
    let fallback = call
        .result
        .pointer("/0/functionResponse/response/output")
        .and_then(Value::as_str);
    let reply = clipped(
        call.display["result"]
            .as_str()
            .filter(|v| !v.is_empty())
            .or(fallback),
        24000,
    );
    let state = match call.status.as_str() {
        "success" if call.display["state"] == "error" => "error",
        "success" if call.display["state"] == "cancelled" => "stopped",
        "success"
            if call.display["terminateReason"]
                .as_str()
                .is_some_and(|r| r.starts_with("ERROR")) =>
        {
            "error"
        }
        "success" if call.display["terminateReason"] == "ABORTED" => "stopped",
        "success"
            if call.display["terminateReason"]
                .as_str()
                .is_some_and(|r| r != "GOAL") =>
        {
            "finished"
        }
        "success" if !reply.is_empty() => "answered",
        "success" => "finished",
        "error" => "error",
        "cancelled" => "stopped",
        "scheduled" | "executing" | "validating" | "awaiting_approval" => "working",
        _ => return Ok(()),
    };
    let id = format!("{session}-{}", call.id);
    let at = call
        .timestamp
        .as_deref()
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map_or_else(history::now, |v| v.timestamp_millis());
    let mut transcript = vec![format!("Task {task}")];
    let mut steps = Vec::new();
    let mut sidebar = None;
    if let Some(items) = call.display["recentActivity"].as_array() {
        for item in items[items.len().saturating_sub(64)..]
            .iter()
            .filter(|v| v["type"] == "tool_call")
        {
            let text = clipped(
                item["description"]
                    .as_str()
                    .or(item["displayName"].as_str())
                    .or(item["content"].as_str()),
                320,
            );
            let status = clipped(item["status"].as_str(), 40);
            if !text.is_empty() {
                sidebar = Some(crate::tool_activity::sidebar_label(item["displayName"].as_str().unwrap_or(""), None));
                steps.push(json!({"text":text,"state":status}));
                transcript.push(format!("{status} · {text}"));
            }
        }
    }
    if !reply.is_empty() {
        transcript.push(format!("Gemini {reply}"));
    }
    let (model, terminal) = call
        .agent_id
        .as_deref()
        .and_then(|child| child_output(source, session, child))
        .unwrap_or_default();
    if let Some(command) = &terminal {
        transcript.push(format!("$ {}\n{}", command.command, command.output));
    }
    let details = json!({"task":task,"reply":reply,"steps":steps,"terminal":terminal});
    let prev:Option<i64>=db.query_row("SELECT json_extract(summary,'$.created_ms') FROM gemini_children WHERE launch=? AND thread=?",
        params![launch,id],|r|r.get(0)).optional()?;
    let summary = json!({"sidebar_summary":sidebar.filter(|_| state=="working"),"id":id,"runtime":"gemini","model":model,"parent":session,"name":name,"task":clipped(Some(task),500),
        "reply":clipped(Some(reply),500),"state":state,"created_ms":prev.unwrap_or(at),
        "completed_ms":(state!="working").then_some(at),"details":details});
    db.execute("INSERT INTO gemini_children(launch,thread,summary,transcript) VALUES(?,?,?,?)
        ON CONFLICT(launch,thread) DO UPDATE SET summary=excluded.summary,transcript=excluded.transcript,revision=revision+1
        WHERE (json_extract(summary,'$.state')='working' OR json_extract(excluded.summary,'$.state')<>'working')
        AND (summary<>excluded.summary OR transcript<>excluded.transcript)",
        params![launch,id,summary.to_string(),transcript.join("\n\n")])?;
    Ok(())
}

// Once the CLI supplies the child ID, use only this child's model and its actual shell result.
fn child_output(
    source: &(String, String),
    session: &str,
    child: &str,
) -> Option<(
    Option<String>,
    Option<crate::agent::child_output::ChildCommandOutput>,
)> {
    if !identifier(child) {
        return None;
    }
    let parent = local_path(Path::new(&source.0))?;
    let path = parent
        .parent()?
        .join(session)
        .join(format!("{child}.jsonl"));
    if path.canonicalize().ok()? != path {
        return None;
    }
    let mut reader = open_log(&path, "subagent", child, &source.1)?;
    // Only the most recent records are relevant to a terminal preview. Skip a cut first row.
    let size = reader.get_ref().metadata().ok()?.len();
    if size > MAX_LINE {
        reader.seek(SeekFrom::Start(size - MAX_LINE)).ok()?;
        reader.skip_until(b'\n').ok()?;
    }
    let mut model = None;
    let mut terminal = None;
    let mut line = Vec::new();
    let mut input = reader.take(MAX_LINE);
    loop {
        line.clear();
        if input.read_until(b'\n', &mut line).ok()? == 0 {
            break;
        }
        let Ok(row) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        if row["type"] != "gemini" {
            continue;
        }
        if let Some(id) = row["model"].as_str() {
            model = Some(clipped(Some(id), 128).to_owned());
        }
        for call in row["toolCalls"].as_array().into_iter().flatten() {
            if call["name"] != "run_shell_command" {
                continue;
            }
            let command = call.pointer("/args/command").and_then(Value::as_str);
            let output = call
                .pointer("/result/0/functionResponse/response/output")
                .and_then(Value::as_str);
            if let Some(value) = command
                .zip(output)
                .and_then(|(c, o)| crate::agent::child_output::ChildCommandOutput::new(c, o))
            {
                terminal = Some(value);
            }
        }
    }
    Some((model, terminal))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn validates_the_provider_header_before_reading_messages() {
        let mut file = tempfile::NamedTempFile::new().unwrap();
        writeln!(
            file,
            "{}",
            json!({"sessionId":"child","kind":"subagent","projectHash":"hash"})
        )
        .unwrap();
        assert!(open_log(file.path(), "subagent", "child", "hash").is_some());
        for (kind, id, hash) in [
            ("main", "child", "hash"),
            ("subagent", "sibling", "hash"),
            ("subagent", "child", "elsewhere"),
        ] {
            assert!(open_log(file.path(), kind, id, hash).is_none());
        }
        let link = file.path().with_extension("link");
        std::os::unix::fs::symlink(file.path(), &link).unwrap();
        assert!(open_log(&link, "subagent", "child", "hash").is_none());
        fs::remove_file(link).unwrap();
    }

    #[test]
    fn reads_only_complete_new_calls_and_keeps_siblings_and_replays_separate() {
        let db = Connection::open_in_memory().unwrap();
        db.execute_batch("CREATE TABLE gemini_transcripts(launch,session,path,project_hash,offset);
          CREATE TABLE gemini_children(launch,thread,summary,transcript,revision INTEGER DEFAULT 1, PRIMARY KEY(launch,thread));
          INSERT INTO gemini_transcripts VALUES(1,'parent','','project',0);").unwrap();
        let mut file = tempfile::NamedTempFile::new().unwrap();
        let record = |id: &str, status: &str| {
            json!({"toolCalls":[{"id":id,"name":"invoke_agent","status":status,
            "timestamp":"2026-08-01T00:00:00Z","args":{"agent_name":"reader","prompt":id},"resultDisplay":{"result":if status=="success" {"answer"} else {""}}}]}).to_string()
        };
        writeln!(file, "{}", record("old", "success")).unwrap();
        let baseline = file.as_file().metadata().unwrap().len();
        writeln!(file, "{}", record("A", "scheduled")).unwrap();
        write!(file, "{}", record("B", "scheduled")).unwrap();
        let read = |offset| {
            let mut input = BufReader::new(File::open(file.path()).unwrap());
            let size = input.get_ref().metadata().unwrap().len();
            consume(&db, 1, "parent", &mut input, offset, size).unwrap();
            db.query_row("SELECT offset FROM gemini_transcripts", [], |r| {
                r.get::<_, u64>(0)
            })
            .unwrap()
        };
        let next = read(baseline);
        let path = file.path().to_owned();
        let mut append = OpenOptions::new().append(true).open(path).unwrap();
        writeln!(append).unwrap();
        writeln!(append, "{}", record("A", "success")).unwrap();
        writeln!(append, "{}", record("A", "scheduled")).unwrap();
        read(next);
        read(baseline);
        let mut stmt = db.prepare("SELECT thread,json_extract(summary,'$.state'),revision FROM gemini_children ORDER BY thread").unwrap();
        let rows = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, i64>(2)?,
                ))
            })
            .unwrap()
            .collect::<rusqlite::Result<Vec<_>>>()
            .unwrap();
        assert_eq!(
            rows,
            vec![
                ("parent-A".into(), "answered".into(), 2),
                ("parent-B".into(), "working".into(), 1)
            ]
        );
    }
}
