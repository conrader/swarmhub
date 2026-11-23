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
    let Ok((db, launch)) = agent::session() else {
        return Ok(());
    };
    let Some(folder) = env::var_os(WORKSPACE).map(PathBuf::from) else {
        return Ok(());
    };
    let stop: Stop = serde_json::from_str(&agent::read_input(1024 * 1024)?)?;
    if !matches!(
        stop.termination_reason.as_str(),
        "model_stop" | "NO_TOOL_CALL"
    ) || !stop.workspace_paths.contains(&folder)
        || !crate::gemini_agent::bridge_made(&folder)
    {
        return Ok(());
    }
    let id = stop.conversation_id;
    if id.len() != 36 || !id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-') {
        return Ok(());
    }
    let home = PathBuf::from(env::var_os("HOME").ok_or("Missing home directory.")?);
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
    let expected = home
        .join(".gemini/antigravity-cli/brain")
        .join(&id)
        .join(LOGS)
        .join(name);
    if reported != expected || expected.canonicalize()? != expected {
        return Ok(());
    }
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(expected)?;
    if !file.metadata()?.is_file() {
        return Ok(());
    }
    const LIMIT: u64 = 4 * 1024 * 1024;
    let offset = file.metadata()?.len().saturating_sub(LIMIT);
    file.seek(SeekFrom::Start(offset))?;
    let mut tail = Vec::new();
    file.take(LIMIT).read_to_end(&mut tail)?;
    let mut lines = tail.split(|b| *b == b'\n');
    if offset != 0 {
        lines.next();
    }
    if let Some((index, text)) = final_step(lines.rev()) {
        let key = format!("agy:{id}:{index}");
        if !history::publish_reply(&db, &launch, "Antigravity CLI", &text, Some(&key))
            .map_err(|_| "Could not save the reply.")?
        {
            return Err("Unknown bot launch.".into());
        }
    }
    println!("{{}}");
    Ok(())
}

fn final_step<'a>(lines: impl Iterator<Item = &'a [u8]>) -> Option<(u64, String)> {
    for line in lines.filter(|l| !l.is_empty()) {
        let step: Value = serde_json::from_slice(line).ok()?;
        match step["type"].as_str()? {
            "USER_INPUT" => return None,
            "PLANNER_RESPONSE" => {
                let text = step["content"].as_str()?;
                return (step["source"] == "MODEL"
                    && step["status"] == "DONE"
                    && step["tool_calls"].as_array().is_none_or(Vec::is_empty)
                    && !text.trim().is_empty()
                    && text.len() <= 128 * 1024)
                    .then_some((step["step_index"].as_u64()?, text.to_owned()));
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
            Some((8, "Hello".into()))
        );
        assert_eq!(final_step([user, msg].into_iter()), None);
        assert_eq!(final_step([tool, msg].into_iter()), None);
    }
}
