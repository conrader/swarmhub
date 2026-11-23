//! Antigravity's terminal reports its status to Core. Its workspace Stop hook identifies the
//! transcript and completed conversation so the final model response can also reach the chat.
use crate::{agent, history};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    env, fs,
    io::{Read, Seek, SeekFrom, Write},
    os::unix::{
        fs::{DirBuilderExt, OpenOptionsExt},
        process::CommandExt,
    },
    path::{Path, PathBuf},
};

type Error = Box<dyn std::error::Error>;
const WORKSPACE: &str = "SWARMHUB_ANTIGRAVITY_WORKSPACE";
const HOOK: &str = "swarmhub-chat-reply";
const LOGS: &str = ".system_generated/logs";

pub fn models() -> Result<(), Error> {
    if env::args_os().nth(2).is_some() {
        return Err("Model discovery does not take arguments.".into());
    }
    Err(
        crate::service::agent_command("agy", "SWARMHUB_ANTIGRAVITY_BIN")
            .arg("models")
            .stdin(std::process::Stdio::null())
            .exec()
            .into(),
    )
}

pub fn launch() -> Result<(), Error> {
    agent::session()?;
    let folder = env::current_dir()?;
    if !crate::gemini_agent::bridge_made(&folder) {
        return Err("Antigravity needs a SwarmHub bot workspace.".into());
    }
    let exe = env::current_exe()?;
    let path = exe
        .to_str()
        .filter(|s| !s.chars().any(char::is_control))
        .ok_or("Invalid workspace program path.")?;
    install_hook(&folder, path)?;
    let mut args = env::args_os().skip(2).collect();
    crate::runtimes::ModelAgent::Antigravity.add_model_arg(&mut args)?;
    Err(
        crate::service::agent_command("agy", "SWARMHUB_ANTIGRAVITY_BIN")
            .args(args)
            .env(WORKSPACE, folder)
            .env_remove(crate::runtimes::MODEL_ENV)
            .exec()
            .into(),
    )
}

fn install_hook(folder: &Path, exe: &str) -> Result<(), Error> {
    let dir = folder.join(".agents");
    if !dir.exists() {
        fs::DirBuilder::new().mode(0o700).create(&dir)?;
    }
    if !dir.symlink_metadata()?.is_dir() {
        return Err("Expected a workspace .agents directory.".into());
    }
    let path = dir.join("hooks.json");
    let mut hooks: serde_json::Map<String, Value> = match fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&path)
    {
        Ok(file) => {
            let meta = file.metadata()?;
            if !meta.is_file() || meta.len() > 256 * 1024 {
                return Err("Unable to read workspace hooks.json.".into());
            }
            serde_json::from_reader(file)?
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Default::default(),
        Err(e) => return Err(e.into()),
    };
    let definition = json!({"Stop":[{"type":"command","command":format!("{} antigravity-reply", agent::shell_quote(exe)), "timeout":agent::REPLY_HOOK_SECONDS}]});
    if hooks.get(HOOK) == Some(&definition) {
        return Ok(());
    }
    hooks.insert(HOOK.to_owned(), definition);
    let mut tmp = tempfile::NamedTempFile::new_in(dir)?;
    serde_json::to_writer_pretty(&mut tmp, &hooks)?;
    tmp.flush()?;
    tmp.persist(path)?;
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Stop {
    conversation_id: String,
    transcript_path: PathBuf,
    workspace_paths: Vec<PathBuf>,
    termination_reason: String,
}

pub fn capture() -> Result<(), Error> {
    capture_from_env()?;
    println!("{{}}");
    Ok(())
}

fn capture_from_env() -> Result<(), Error> {
    let Ok((db, launch)) = agent::session() else {
        return Ok(());
    };
    let Some(folder) = env::var_os(WORKSPACE).map(PathBuf::from) else {
        return Ok(());
    };
    let home = PathBuf::from(env::var_os("HOME").ok_or("Missing home directory.")?);
    let raw = agent::read_input(1024 * 1024)?;
    capture_stop(&db, &launch, &folder, &home, &raw)
}

fn capture_stop(
    db: &Path,
    launch: &str,
    folder: &Path,
    home: &Path,
    raw: &str,
) -> Result<(), Error> {
    let stop: Stop = serde_json::from_str(raw)?;
    if !crate::gemini_agent::bridge_made(folder) {
        return Ok(());
    }
    let folder_real = folder.canonicalize().ok();
    let in_workspace = stop.workspace_paths.iter().any(|path| {
        path == folder
            || folder_real
                .as_ref()
                .is_some_and(|real| path.canonicalize().ok().as_ref() == Some(real))
    });
    if !matches!(
        stop.termination_reason.as_str(),
        "model_stop" | "NO_TOOL_CALL"
    ) || !in_workspace
    {
        return Ok(());
    }
    let id = stop.conversation_id;
    if id.len() != 36 || !id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Ok(());
    }
    let reported = stop
        .transcript_path
        .strip_prefix("~")
        .map(|p| home.join(p))
        .unwrap_or(stop.transcript_path);
    let Some(name) = reported.file_name().and_then(|s| s.to_str()) else {
        return Ok(());
    };
    if !matches!(name, "transcript.jsonl" | "transcript_full.jsonl") {
        return Ok(());
    }
    let brain = home.join(".gemini/antigravity-cli/brain");
    let Ok(brain_real) = brain.canonicalize() else {
        return Ok(());
    };
    let expected = brain.join(&id).join(LOGS).join(name);
    let expected_real = brain_real.join(&id).join(LOGS).join(name);
    let Ok(reported_real) = reported.canonicalize() else {
        return Ok(());
    };
    if (reported != expected && reported != expected_real)
        || reported_real != expected_real
        || expected_real.canonicalize().ok().as_ref() != Some(&expected_real)
    {
        return Ok(());
    }
    let Some(mut found) = read_final_step(&expected_real)? else {
        return Ok(());
    };
    if found.truncated && name == "transcript.jsonl" {
        let full_real = brain_real
            .join(&id)
            .join(LOGS)
            .join("transcript_full.jsonl");
        if full_real.canonicalize().ok().as_ref() == Some(&full_real)
            && let Ok(Some(full)) = read_final_step(&full_real)
            && full.index == found.index
            && !full.truncated
        {
            found = full;
        }
    }
    let key = format!("agy:{id}:{}", found.index);
    if !history::publish_reply(db, launch, "Antigravity CLI", &found.text, Some(&key))
        .map_err(|_| "Could not save the reply.")?
    {
        return Err("Unknown bot launch.".into());
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
struct FinalStep {
    index: u64,
    text: String,
    truncated: bool,
}

fn read_final_step(path: &Path) -> Result<Option<FinalStep>, Error> {
    let file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    if !file.metadata()?.is_file() {
        return Ok(None);
    }
    const LIMIT: u64 = 4 * 1024 * 1024;
    let offset = file.metadata()?.len().saturating_sub(LIMIT);
    let mut file = file;
    file.seek(SeekFrom::Start(offset))?;
    let mut tail = Vec::new();
    file.take(LIMIT).read_to_end(&mut tail)?;
    let mut lines = tail.split(|b| *b == b'\n');
    if offset != 0 {
        lines.next();
    }
    Ok(final_step(lines.rev()))
}

fn final_step<'a>(lines: impl Iterator<Item = &'a [u8]>) -> Option<FinalStep> {
    for line in lines.filter(|l| !l.is_empty()) {
        let step: Value = serde_json::from_slice(line).ok()?;
        match step["type"].as_str()? {
            "USER_INPUT" => return None,
            "PLANNER_RESPONSE" => {
                let text = step["content"].as_str()?;
                let truncated = step["truncated_fields"]
                    .as_array()
                    .is_some_and(|fields| fields.iter().any(|field| field == "content"));
                return (step["source"] == "MODEL"
                    && step["status"] == "DONE"
                    && step["tool_calls"].as_array().is_none_or(Vec::is_empty)
                    && !text.trim().is_empty()
                    && text.len() <= 128 * 1024)
                    .then_some(FinalStep {
                        index: step["step_index"].as_u64()?,
                        text: text.to_owned(),
                        truncated,
                    });
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn saves_only_the_current_final_model_text() {
        let msg = br#"{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","step_index":8,"content":"Hello","thinking":"private"}"#.as_slice();
        let user = br#"{"type":"USER_INPUT"}"#.as_slice();
        let tool = br#"{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","step_index":9,"content":"Working","tool_calls":[{}]}"#.as_slice();
        assert_eq!(
            final_step([msg, user].into_iter()),
            Some(FinalStep {
                index: 8,
                text: "Hello".into(),
                truncated: false,
            })
        );
        assert_eq!(final_step([user, msg].into_iter()), None);
        assert_eq!(final_step([tool, msg].into_iter()), None);
    }

    #[test]
    fn capture_recovers_full_transcript_across_symlinked_home_and_rejects_escaped_logs() {
        let scratch = tempfile::tempdir().unwrap();
        let real_root = scratch.path().join("private");
        fs::create_dir_all(&real_root).unwrap();
        let linked_root = scratch.path().join("var");
        std::os::unix::fs::symlink(&real_root, &linked_root).unwrap();

        let home = linked_root.join("home");
        let workspace = linked_root.join("bot");
        fs::create_dir_all(&workspace).unwrap();
        fs::write(workspace.join(".swarmhub-workspace"), b"").unwrap();

        let conv = "6174af3f-92c6-459e-88f5-5955c66cd326";
        let logs = home
            .join(".gemini/antigravity-cli/brain")
            .join(conv)
            .join(LOGS);
        fs::create_dir_all(&logs).unwrap();
        let compact = logs.join("transcript.jsonl");
        let full = logs.join("transcript_full.jsonl");
        fs::write(
            &compact,
            concat!(
                r#"{"type":"USER_INPUT","step_index":0}"#,
                "\n",
                r#"{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","step_index":1,"content":"Short <truncated>","truncated_fields":["content"]}"#,
                "\n"
            ),
        )
        .unwrap();
        fs::write(
            &full,
            concat!(
                r#"{"type":"USER_INPUT","step_index":0}"#,
                "\n",
                r#"{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","step_index":1,"content":"Full untruncated answer."}"#,
                "\n"
            ),
        )
        .unwrap();

        let history = history::History::open_at(&scratch.path().join("data")).unwrap();
        let (_, launch) = history
            .start_launch("core", "bot-123456", "Ask", None, "{}", "")
            .unwrap()
            .unwrap();

        let payload = json!({
            "conversationId": conv,
            "transcriptPath": compact,
            "workspacePaths": [workspace.canonicalize().unwrap()],
            "terminationReason": "NO_TOOL_CALL"
        })
        .to_string();
        capture_stop(history.file(), &launch, &workspace, &home, &payload).unwrap();

        let conn = history::connection(history.file()).unwrap();
        let saved: String = conn
            .query_row("SELECT text FROM journal WHERE kind='reply'", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(saved, "Full untruncated answer.");

        // A symlink inside brain/<conversationId> must be ignored rather than followed.
        let escaped_conv = "11111111-2222-3333-4444-555555555555";
        let outside = scratch.path().join("outside-logs");
        fs::create_dir_all(&outside).unwrap();
        fs::write(
            outside.join("transcript.jsonl"),
            r#"{"type":"PLANNER_RESPONSE","source":"MODEL","status":"DONE","step_index":2,"content":"Forged"}"#,
        )
        .unwrap();
        let escaped_parent = home
            .join(".gemini/antigravity-cli/brain")
            .join(escaped_conv)
            .join(".system_generated");
        fs::create_dir_all(&escaped_parent).unwrap();
        std::os::unix::fs::symlink(&outside, escaped_parent.join("logs")).unwrap();
        let forged = json!({
            "conversationId": escaped_conv,
            "transcriptPath": escaped_parent.join("logs/transcript.jsonl"),
            "workspacePaths": [&workspace],
            "terminationReason": "NO_TOOL_CALL"
        })
        .to_string();
        capture_stop(history.file(), &launch, &workspace, &home, &forged).unwrap();
        let count: i64 = conn
            .query_row("SELECT count(*) FROM journal WHERE kind='reply'", [], |r| {
                r.get(0)
            })
            .unwrap();
        assert_eq!(count, 1);
    }
}
