use crate::runtimes::ModelAgent;
use serde::{Deserialize, Serialize, de::DeserializeOwned};
use serde_json::{Value, json};
use std::{
    collections::BTreeSet,
    io::{self, Read, Write},
    os::fd::AsRawFd,
    process::{Child, ChildStdin, ChildStdout, Command, Stdio},
    time::{Duration, Instant},
};

const TIMEOUT: Duration = Duration::from_secs(25);
const MAX_FRAME: usize = 256 * 1024;
const MAX_OUTPUT: usize = 2 * 1024 * 1024;
const MAX_FRAMES: usize = 256;
const PAGE_SIZE: usize = 64;
const MAX_PAGES: usize = 8;

#[derive(Deserialize, Serialize)]
pub(crate) struct Catalog {
    pub ids: Vec<String>,
    pub truncated: bool,
}

#[derive(Deserialize)]
struct Page {
    data: Vec<Row>,
    #[serde(rename = "nextCursor")]
    next: Option<String>,
}

#[derive(Deserialize)]
struct Row {
    // `model` is the CLI selection value; `id` and displayName may be aliases.
    model: String,
    hidden: bool,
}

pub(super) struct AppServer {
    process: Child,
    input: Option<ChildStdin>,
    output: ChildStdout,
    pending: Vec<u8>,
    total: usize,
    frames: usize,
    deadline: Instant,
}

fn protocol() -> io::Error {
    io::Error::other("Codex's app server did not return its model catalog.")
}

impl AppServer {
    pub(super) fn start(mut command: Command) -> io::Result<Self> {
        let deadline = Instant::now() + TIMEOUT;
        let mut process = command
            .args([
                "app-server",
                "--listen",
                "stdio://",
                "-c",
                "analytics.enabled=false",
                "-c",
                "check_for_update_on_startup=false",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|_| protocol())?;
        let mut server = Self {
            input: process.stdin.take(),
            output: process.stdout.take().ok_or_else(protocol)?,
            process,
            pending: Vec::new(),
            total: 0,
            frames: 0,
            deadline,
        };
        nonblocking(server.input.as_mut().ok_or_else(protocol)?.as_raw_fd())?;
        Ok(server)
    }

    pub(super) fn send(&mut self, message: Value) -> io::Result<()> {
        let mut wire = serde_json::to_vec(&message).map_err(|_| protocol())?;
        wire.push(b'\n');
        let input = self.input.as_mut().ok_or_else(protocol)?;
        let mut remaining = wire.as_slice();
        while !remaining.is_empty() {
            wait(input.as_raw_fd(), libc::POLLOUT, self.deadline)?;
            match input.write(remaining) {
                Ok(count) if count > 0 => remaining = &remaining[count..],
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                    ) => {}
                _ => return Err(protocol()),
            }
        }
        Ok(())
    }

    fn read(&mut self) -> io::Result<Value> {
        loop {
            if let Some(end) = self.pending.iter().position(|byte| *byte == b'\n') {
                self.frames += 1;
                if end >= MAX_FRAME || self.frames > MAX_FRAMES {
                    return Err(protocol());
                }
                let value = serde_json::from_slice(&self.pending[..end]).map_err(|_| protocol())?;
                self.pending.drain(..=end);
                return Ok(value);
            }
            if self.pending.len() >= MAX_FRAME {
                return Err(protocol());
            }
            wait(self.output.as_raw_fd(), libc::POLLIN, self.deadline)?;
            let mut buffer = [0; 8192];
            let count = self.output.read(&mut buffer).map_err(|_| protocol())?;
            self.total += count;
            if count == 0 || self.total > MAX_OUTPUT {
                return Err(protocol());
            }
            self.pending.extend_from_slice(&buffer[..count]);
        }
    }

    pub(super) fn result<T: DeserializeOwned>(&mut self, id: u64) -> io::Result<T> {
        loop {
            let mut frame = self.read()?;
            if frame.get("id").and_then(Value::as_u64) != Some(id) {
                continue;
            }
            if frame.get("error").is_some() || frame.get("result").is_none() {
                return Err(protocol());
            }
            return serde_json::from_value(frame["result"].take()).map_err(|_| protocol());
        }
    }
}

impl Drop for AppServer {
    fn drop(&mut self) {
        drop(self.input.take());
        // Stdio EOF is the normal shutdown; SIGTERM also lets the packaged
        // Node launcher forward shutdown to its native child.
        if self.process.try_wait().ok().flatten().is_none() {
            if let Ok(pid) = libc::pid_t::try_from(self.process.id()) {
                // The unreaped child cannot have had its PID reused.
                unsafe { libc::kill(pid, libc::SIGTERM) };
            }
            for _ in 0..10 {
                if self.process.try_wait().ok().flatten().is_some() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(25));
            }
            let _ = self.process.kill();
        }
        let _ = self.process.wait();
    }
}

fn wait(fd: libc::c_int, events: libc::c_short, deadline: Instant) -> io::Result<()> {
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(protocol());
        }
        let mut descriptor = libc::pollfd {
            fd,
            events,
            revents: 0,
        };
        // poll borrows the one live pipe descriptor. Its timeout is bounded.
        let outcome = unsafe {
            libc::poll(
                &mut descriptor,
                1,
                remaining.as_millis().max(1) as libc::c_int,
            )
        };
        if outcome > 0 {
            if descriptor.revents & events != 0 {
                return Ok(());
            }
            return Err(protocol());
        }
        if outcome < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
            continue;
        }
        return Err(protocol());
    }
}

fn nonblocking(fd: libc::c_int) -> io::Result<()> {
    // The child pipe is owned by the caller for the duration of both calls.
    let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
        return Err(protocol());
    }
    Ok(())
}

pub(super) fn discover(command: Command) -> io::Result<Catalog> {
    let mut server = AppServer::start(command)?;
    server.send(json!({"id":1,"method":"initialize","params":{"clientInfo":{
        "name":"swarmhub-herdr","version":env!("CARGO_PKG_VERSION")
    }}}))?;
    let _: serde::de::IgnoredAny = server.result(1)?;
    server.send(json!({"method":"initialized"}))?;
    let mut ids = Vec::new();
    let mut seen = BTreeSet::new();
    let mut cursors = BTreeSet::new();
    let mut cursor: Option<String> = None;
    for page in 0..MAX_PAGES {
        let id = page as u64 + 2;
        server.send(json!({"id":id,"method":"model/list","params":{
            "includeHidden":false,"limit":PAGE_SIZE,"cursor":cursor
        }}))?;
        let page: Page = server.result(id)?;
        if page.data.len() > PAGE_SIZE {
            return Err(protocol());
        }
        for row in page.data {
            if !row.hidden
                && ModelAgent::Codex.accepts(&row.model)
                && seen.insert(row.model.clone())
            {
                ids.push(row.model);
            }
        }
        match page.next {
            None => {
                return Ok(Catalog {
                    ids,
                    truncated: false,
                });
            }
            Some(next)
                if !next.is_empty() && next.len() <= 1024 && cursors.insert(next.clone()) =>
            {
                cursor = Some(next)
            }
            Some(_) => return Err(protocol()),
        }
    }
    Ok(Catalog {
        ids,
        truncated: true,
    })
}
