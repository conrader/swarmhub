//! The bridge checks consent and opens values. Only the local CLI starts the
//! command, so it retains the calling agent's sandbox.
use super::{Session, Status};
use crate::{Workspace, history::now};
use serde::{Deserialize, Serialize};
use std::{
    env,
    ffi::OsString,
    fs,
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{FileTypeExt, PermissionsExt},
        net::UnixStream as BlockingStream,
    },
    path::{Path, PathBuf},
    process,
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt},
    net::{UnixListener, UnixStream},
    sync::Semaphore,
    time::timeout,
};

pub(crate) const SESSION_ENV: &str = "SWARMHUB_VAULT_SESSION";
const DENIED: &str = "An approved Vault request for this agent and name is required.";
const UNAVAILABLE: &str = "Vault is unavailable in this agent session.";
pub(crate) const USAGE: &str = "Vault: swarmhub-herdr vault request --name NAME --label LABEL --description DESCRIPTION\n       swarmhub-herdr vault status --name NAME\n       swarmhub-herdr vault exec --name NAME [--name NAME ...] -- COMMAND [ARG ...]";
const IO_TIME: Duration = Duration::from_secs(5);
const REQUEST_LIMIT: u64 = 8192;
const RESPONSE_LIMIT: u64 = 128 * 1024;

#[derive(Deserialize, Serialize)]
struct Call {
    session: String,
    action: Action,
}

#[derive(Deserialize, Serialize)]
enum Action {
    Request {
        name: String,
        label: String,
        description: String,
    },
    Status {
        name: String,
    },
    Exec {
        names: Vec<String>,
    },
}

#[derive(Deserialize, Serialize)]
enum Reply {
    Status(String),
    Values(Vec<(String, String)>),
    Denied,
    Unavailable,
}

fn socket_path(journal: &Path) -> PathBuf {
    journal.with_file_name("vault.sock")
}

pub(crate) fn listen(w: Workspace) -> io::Result<()> {
    if w.vault.is_none() {
        return Ok(());
    }
    let path = socket_path(w.history.file());
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_socket() => fs::remove_file(&path)?,
        Ok(_) => return Err(io::Error::other("Vault socket path is not a socket")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let listener = UnixListener::bind(&path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    let slots = Arc::new(Semaphore::new(16));
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let Ok(slot) = slots.clone().try_acquire_owned() else {
                continue;
            };
            let w = w.clone();
            tokio::spawn(async move {
                let _slot = slot;
                let _ = serve(w, stream).await;
            });
        }
    });
    Ok(())
}

async fn serve(w: Workspace, mut stream: UnixStream) -> io::Result<()> {
    let mut line = Vec::new();
    timeout(
        IO_TIME,
        tokio::io::BufReader::new(&mut stream)
            .take(REQUEST_LIMIT)
            .read_until(b'\n', &mut line),
    ).await??;
    let call: Call = decode(&line)?;
    let session = w.vault.as_ref().and_then(|vault| vault.requests.authenticate(&call.session));
    let reply = match session {
        Some(session) if call.action.valid() && active(&w, &session).await => {
            tokio::task::spawn_blocking(move || handle(w, session, call.action))
                .await
                .unwrap_or(Reply::Unavailable)
        }
        _ => Reply::Unavailable,
    };
    let bytes = encode(&reply)?;
    timeout(IO_TIME, stream.write_all(&bytes)).await??;
    Ok(())
}

async fn active(w: &Workspace, session: &Session) -> bool {
    w.core.agents().await.is_ok_and(|agents| {
        agents.iter().any(|agent| {
            agent.launch_key() == Some(session.launch.as_str()) && agent.require_live().is_ok()
        })
    })
}

fn handle(w: Workspace, session: Session, action: Action) -> Reply {
    let Some(vault) = w.vault else {
        return Reply::Unavailable;
    };
    let Ok(mut db) = w.history.db() else {
        return Reply::Unavailable;
    };
    let at = now();
    match action {
        Action::Request { name, label, description } => vault
            .check(&db)
            .ok()
            .and_then(|_| vault.requests.request(&db, &session, &name, &label, &description, at).ok())
            .map_or(Reply::Unavailable, |state| Reply::Status(state.into())),
        Action::Status { name } => vault.requests
            .status(&db, &session, &name, at)
            .map_or(Reply::Unavailable, |state| Reply::Status(state.into())),
        Action::Exec { names } => vault.requests
            .take(&mut db, &vault, &session, &names, at)
            .map_or(Reply::Denied, Reply::Values),
    }
}

fn env_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphabetic() || *byte == b'_')
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
        && !["SWARMHUB_", "LD_", "DYLD_"].iter().any(|prefix| name.starts_with(prefix))
        && !matches!(name, "PATH" | "BASH_ENV" | "ENV")
}

fn metadata(text: &str, max: usize) -> bool {
    !text.trim().is_empty() && text.len() <= max && !text.chars().any(char::is_control)
}

impl Action {
    fn valid(&self) -> bool {
        match self {
            Self::Request { name, label, description } => env_name(name) && metadata(label, 120) && metadata(description, 500),
            Self::Status { name } => env_name(name),
            Self::Exec { names } => {
                (1..=8).contains(&names.len()) && names.iter().enumerate().all(|(index, name)| {
                    env_name(name) && !names[..index].iter().any(|other| other.eq_ignore_ascii_case(name))
                })
            }
        }
    }
}

fn encode(value: &impl Serialize) -> io::Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(value).map_err(|_| io::Error::other(UNAVAILABLE))?;
    bytes.push(b'\n');
    Ok(bytes)
}

fn decode<T: serde::de::DeserializeOwned>(line: &[u8]) -> io::Result<T> {
    if !line.ends_with(b"\n") {
        return Err(io::Error::other(UNAVAILABLE));
    }
    serde_json::from_slice(line).map_err(|_| io::Error::other(UNAVAILABLE))
}

fn exchange(action: Action) -> Result<Reply, &'static str> {
    let journal = env::var_os("SWARMHUB_JOURNAL")
        .map(PathBuf::from)
        .filter(|path| path.is_absolute())
        .ok_or(UNAVAILABLE)?;
    let session = env::var(SESSION_ENV).map_err(|_| UNAVAILABLE)?;
    let message = encode(&Call { session, action }).map_err(|_| UNAVAILABLE)?;
    let mut stream = BlockingStream::connect(socket_path(&journal)).map_err(|_| UNAVAILABLE)?;
    stream.set_read_timeout(Some(Duration::from_secs(30))).map_err(|_| UNAVAILABLE)?;
    stream.set_write_timeout(Some(IO_TIME)).map_err(|_| UNAVAILABLE)?;
    stream.write_all(&message).map_err(|_| UNAVAILABLE)?;
    let mut line = Vec::new();
    BufReader::new(stream).take(RESPONSE_LIMIT).read_until(b'\n', &mut line).map_err(|_| UNAVAILABLE)?;
    decode(&line).map_err(|_| UNAVAILABLE)
}

fn option(args: &mut impl Iterator<Item = OsString>, expected: &str) -> Result<String, &'static str> {
    if args.next().as_deref().is_some_and(|flag| flag == expected) {
        return args.next().and_then(|value| value.into_string().ok()).ok_or(USAGE);
    }
    Err(USAGE)
}

pub(crate) fn cli() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(2).peekable();
    let command = args.next().ok_or(USAGE)?;
    let name = option(&mut args, "--name")?;
    if !env_name(&name) {
        return Err("Use a Vault name suitable for an environment variable.".into());
    }
    let mut exec = None;
    let action = match command.to_str() {
        Some("request") => {
            let label = option(&mut args, "--label")?;
            let description = option(&mut args, "--description")?;
            if args.next().is_some() {
                return Err(USAGE.into());
            }
            Action::Request { name: name.clone(), label, description }
        }
        Some("status") if args.next().is_none() => Action::Status { name: name.clone() },
        Some("exec") => {
            let mut names = vec![name.clone()];
            while args.peek().is_some_and(|flag| flag == "--name") {
                if names.len() >= 8 {
                    return Err(USAGE.into());
                }
                names.push(option(&mut args, "--name")?);
            }
            if args.next().as_deref().is_none_or(|separator| separator != "--") {
                return Err(USAGE.into());
            }
            exec = args.next().filter(|program| !program.is_empty());
            if exec.is_none() {
                return Err(USAGE.into());
            }
            Action::Exec { names }
        }
        _ => return Err(USAGE.into()),
    };
    if !action.valid() {
        return Err(USAGE.into());
    }
    match (exchange(action)?, exec) {
        (Reply::Status(status), None) => {
            let result = Status { status: &status, name };
            println!("{}", serde_json::to_string(&result)?);
        }
        (Reply::Values(values), Some(program)) => {
            let exit = super::output::run(program, args, &values)
                .map_err(|_| "Vault could not run the command or capture its output.")?;
            process::exit(exit);
        }
        (Reply::Denied, _) => return Err(DENIED.into()),
        _ => return Err(UNAVAILABLE.into()),
    }
    Ok(())
}
