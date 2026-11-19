//! Worker-local lifecycle for fixed, synthetic jobs. Each launch has its own
//! session and supervisor, independent of the command that recorded the intent.
mod store;

use crate::fleet_policy::principals::identifier;
use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::{OsStr, OsString},
    io::{self, BufRead, BufReader, Read, Write},
    net::Shutdown,
    os::{
        fd::{AsFd, OwnedFd},
        unix::{
            net::UnixStream,
            process::{CommandExt, ExitStatusExt},
        },
    },
    path::Path,
    process::{Child, Command, ExitStatus, Stdio},
    thread,
    time::{Duration, Instant},
};
use store::Store;

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const PROTOCOL: u32 = 1;
const INPUT_LIMIT: usize = 4096;
const LOG_LIMIT: usize = 1024;
const RESULT_LIMIT: usize = 4096;
const POLL: Duration = Duration::from_millis(20);
const LAUNCH_WAIT: Duration = Duration::from_secs(2);
const GROUP_WAIT: Duration = Duration::from_secs(5);
const RELEASE: u8 = b'G';
pub(crate) const USAGE: &str =
    "Fixture attempts: job-worker start|status|cancel|collect STATE_DIR (JSON on stdin)";

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
struct Worker {
    id: String,
    host_fingerprint: String,
}

impl Worker {
    fn valid(&self) -> bool {
        (1..=64).contains(&self.id.len())
            && self.id.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
            && self.host_fingerprint.strip_prefix("SHA256:").is_some_and(|digest| {
                STANDARD_NO_PAD.decode(digest).is_ok_and(|bytes| bytes.len() == 32)
            })
    }
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Attempt {
    job_id: String,
    number: i64,
}

#[derive(Clone, Copy, Deserialize, Serialize)]
#[serde(rename_all = "snake_case")]
enum Fixture {
    Success,
    Nonzero,
    Oversized,
    Group,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Request {
    protocol: u32,
    worker: Worker,
    attempt: Attempt,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fixture: Option<Fixture>,
}

pub(crate) fn cli(args: &[OsString]) -> Result<()> {
    match args.first().and_then(|arg| arg.to_str()) {
        Some("_supervise") if let [_, root, token] = args => {
            supervise(Path::new(root), token.to_str().ok_or(USAGE)?)
        }
        Some("_fixture") if let [_, fixture] = args => {
            run_fixture(serde_json::from_str(fixture.to_str().ok_or(USAGE)?)?)
        }
        Some("_fixture-member") if args.len() == 1 => {
            thread::sleep(GROUP_WAIT);
            Ok(())
        }
        Some(verb @ ("start" | "status" | "cancel" | "collect")) if let [_, root] = args => {
            let mut input = Vec::new();
            io::stdin().take((INPUT_LIMIT + 1) as u64).read_to_end(&mut input)?;
            if input.len() > INPUT_LIMIT {
                return Err("Worker request exceeds 4096 bytes.".into());
            }
            let request: Request = serde_json::from_slice(&input)?;
            if request.protocol != PROTOCOL {
                return Err("Unsupported job worker protocol.".into());
            }
            if !request.worker.valid()
                || !identifier(&request.attempt.job_id)
                || request.attempt.number <= 0
                || (verb == "start") != request.fixture.is_some()
            {
                return Err("Invalid job worker request.".into());
            }

            let mut store = Store::open(Path::new(root), Some(&request.worker))?;
            if let Some(fixture) = request.fixture {
                start(&mut store, &request, fixture)?;
            }
            let view = store.observe(&request.attempt, verb == "cancel", verb == "collect")?;
            let mut out = io::stdout().lock();
            serde_json::to_writer(&mut out, &view)?;
            writeln!(out)?;
            Ok(())
        }
        _ => Err(USAGE.into()),
    }
}

fn start(store: &mut Store, request: &Request, fixture: Fixture) -> Result<()> {
    let manifest_digest = digest(&serde_json::to_vec(request)?);
    let launcher = ProcessIdentity::current()?;
    let Some(token) = store.reserve(&request.attempt, &manifest_digest, fixture, &launcher)? else {
        return Ok(());
    };
    let mut command = subprocess([
        OsStr::new("_supervise"),
        store.root.as_os_str(),
        OsStr::new(&token),
    ])?;
    command.current_dir(&store.root);
    // SAFETY: setsid is async-signal-safe. Only the fresh child changes session.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut supervisor = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            store.start_unconfirmed(&token)?;
            return Err(error.into());
        }
    };

    // Pin the detached supervisor's identity before replying so status can
    // recognize it while it is still opening the store or registering a child.
    let deadline = Instant::now() + LAUNCH_WAIT;
    loop {
        if let Some(identity) = ProcessIdentity::read(supervisor.id() as i32) {
            store.register_supervisor(&token, &identity)?;
            break;
        }
        if supervisor.try_wait()?.is_some() {
            store.start_unconfirmed(&token)?;
            break;
        }
        if Instant::now() >= deadline {
            break;
        }
        thread::sleep(POLL);
    }
    Ok(())
}

fn supervise(root: &Path, token: &str) -> Result<()> {
    let mut store = Store::open(root, None)?;
    let supervisor = ProcessIdentity::current()?;
    // SAFETY: getsid(0) reads the current process's session ID.
    if supervisor.pid != supervisor.group || unsafe { libc::getsid(0) } != supervisor.pid {
        return Err("The fixture supervisor needs its own session.".into());
    }
    // An ignored SIGCHLD inherited from a launcher can cause automatic reaping.
    // Keep children waitable so the group leader pins its PID until we reap it.
    // SAFETY: SIG_DFL is the built-in disposition and this process owns its wait loop.
    if unsafe { libc::signal(libc::SIGCHLD, libc::SIG_DFL) } == libc::SIG_ERR {
        return Err(io::Error::last_os_error().into());
    }
    #[cfg(test)]
    checkpoint("before-supervisor-registration", &supervisor)?;
    let Some(fixture) = store.register_supervisor(token, &supervisor)? else {
        return Ok(());
    };

    let (mut channel, child_channel) = UnixStream::pair()?;
    let arg = serde_json::to_string(&fixture)?;
    let mut child = subprocess(["_fixture", &arg])?
        .process_group(0)
        .stdin(Stdio::from(OwnedFd::from(child_channel)))
        .spawn()?;

    // EOF before the release byte makes the child exit without running the
    // fixture, including when this supervisor dies before the DB write.
    let registered = (|| {
        let identity = ProcessIdentity::read(child.id() as i32)
            .filter(|process| process.pid == process.group)
            .ok_or("Could not establish the fixture process group identity.")?;
        #[cfg(test)]
        checkpoint("before-child-registration", &identity)?;
        let cancelled = store.register_child(token, &identity)?;
        Ok::<_, Box<dyn std::error::Error>>((identity, cancelled))
    })();
    let (identity, cancelled) = match registered {
        Ok((identity, Some(cancelled))) => (identity, cancelled),
        other => {
            drop(channel);
            child.wait()?;
            return other.map(|_| ());
        }
    };

    let mut sent_cancel = false;
    if cancelled {
        sent_cancel = cancel_group(&child, &identity)?;
    } else {
        // If the child died before release, still reap it and record its exit.
        let _ = channel.write_all(&[RELEASE]);
    }
    let _ = channel.shutdown(Shutdown::Write);
    // Drain while the child can still write. The fixture group member has no
    // copy of the socket, so this reader reaches EOF when the leader dies.
    let capture = thread::Builder::new()
        .spawn(move || read_output(channel).unwrap_or_default())
        .ok();
    let exit = loop {
        if let Some(exit) = child.try_wait()? {
            break exit;
        }
        if !sent_cancel && store.cancel_pending(token)? {
            sent_cancel = cancel_group(&child, &identity)?;
        }
        thread::sleep(POLL);
    };

    // A broken output channel cannot erase an exit that was already observed.
    let output = capture.and_then(|reader| reader.join().ok()).unwrap_or_default();
    store.finish(token, &Receipt::new(exit, sent_cancel, output))
}

fn cancel_group(child: &Child, expected: &ProcessIdentity) -> io::Result<bool> {
    // This supervisor is the sole reaper of this Child. Until try_wait/wait
    // reaps it, even a leader that exits during this check pins its PID/PGID.
    let pid = child.id() as i32;
    if expected.group != pid || ProcessIdentity::read(pid).as_ref() != Some(expected) {
        return Ok(false);
    }
    // SAFETY: the negative ID selects the verified fixture process group.
    if unsafe { libc::kill(-pid, libc::SIGKILL) } == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Ok(false);
    }
    Err(error)
}

fn subprocess(args: impl IntoIterator<Item = impl AsRef<OsStr>>) -> io::Result<Command> {
    let mut command = Command::new(std::env::current_exe()?);
    command.env_clear().stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(not(test))]
    command.arg("job-worker").args(args);
    #[cfg(test)]
    {
        command.args([
            "--exact",
            "fleet_tests::detached_attempts::gapplan_07_int_closed_launch_pipe_keeps_one_detached_attempt",
            "--nocapture",
        ]);
        command.env("SWARMHUB_TEST_JOB_WORKER", "1");
        for (index, arg) in args.into_iter().enumerate() {
            command.env(format!("SWARMHUB_TEST_JOB_WORKER_ARG_{index}"), arg);
        }
    }
    Ok(command)
}

fn run_fixture(fixture: Fixture) -> Result<()> {
    let mut channel = UnixStream::from(io::stdin().as_fd().try_clone_to_owned()?);
    let mut release = [0];
    if channel.read(&mut release)? == 0 {
        return Err("The fixture start was not released.".into());
    }
    if release != [RELEASE] {
        return Err("Invalid fixture release.".into());
    }
    #[cfg(test)]
    checkpoint("fixture-released", &ProcessIdentity::current()?)?;
    match fixture {
        Fixture::Success => channel.write_all(b"fixture completed\nfixture result\n")?,
        Fixture::Nonzero => {
            channel.write_all(b"fixture exited nonzero\n")?;
            std::process::exit(17);
        }
        Fixture::Oversized => {
            channel.write_all(b"fixture emitted an oversized result\n")?;
            let block = [b'x'; RESULT_LIMIT];
            for _ in 0..256 {
                channel.write_all(&block)?;
            }
        }
        Fixture::Group => {
            let mut member = subprocess(["_fixture-member"])?.spawn()?;
            let identity = ProcessIdentity::read(member.id() as i32)
                .ok_or("Could not observe the fixture group member.")?;
            // The group member inherits the fixture's group and has no channel.
            writeln!(channel, "{}", serde_json::to_string(&identity)?)?;
            #[cfg(test)]
            checkpoint("group-ready", &identity)?;
            if !member.wait()?.success() {
                return Err("The fixture group member failed.".into());
            }
            channel.write_all(b"fixture group result\n")?;
        }
    }
    Ok(())
}

#[derive(Default)]
struct Output {
    log: Option<String>,
    result: Option<String>,
    result_truncated: bool,
}

fn read_output(channel: UnixStream) -> Result<Output> {
    let mut reader = BufReader::new(channel);
    let mut log = Vec::new();
    (&mut reader).take((LOG_LIMIT + 1) as u64).read_until(b'\n', &mut log)?;
    let complete_log = log.last() == Some(&b'\n');
    let mut result = Vec::new();
    if complete_log {
        (&mut reader).take((RESULT_LIMIT + 1) as u64).read_to_end(&mut result)?;
    }
    // Keep the socket open through EOF so discarded output cannot break the
    // child's writes or change its exit status.
    io::copy(&mut reader, &mut io::sink())?;
    if !complete_log {
        // A partial log line cannot identify the boundary of a result.
        return Ok(Output::default());
    }
    log.pop();
    let result_truncated = result.len() > RESULT_LIMIT;
    Ok(Output {
        log: Some(String::from_utf8(log)?),
        result: (!result_truncated && !result.is_empty())
            .then(|| String::from_utf8(result))
            .transpose()?,
        result_truncated,
    })
}

#[derive(Debug, Deserialize, Serialize)]
struct Receipt {
    code: Option<i32>,
    signal: Option<i32>,
    cancelled: bool,
    log: Option<String>,
    result: Option<String>,
    result_truncated: bool,
}

impl Receipt {
    fn new(exit: ExitStatus, sent_cancel: bool, output: Output) -> Self {
        Self {
            code: exit.code(),
            signal: exit.signal(),
            cancelled: sent_cancel && exit.signal() == Some(libc::SIGKILL),
            log: output.log,
            result: exit.success().then_some(output.result).flatten(),
            result_truncated: output.result_truncated,
        }
    }
}

fn digest(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

#[derive(Debug, Deserialize, Eq, PartialEq, Serialize)]
struct ProcessIdentity {
    pid: i32,
    group: i32,
    birth: String,
}

impl ProcessIdentity {
    fn current() -> Result<Self> {
        Self::read(std::process::id() as i32).ok_or("Process birth identity is unavailable.".into())
    }

    fn live(&self) -> bool {
        Self::read(self.pid).as_ref() == Some(self)
    }

    #[cfg(target_os = "macos")]
    fn read(pid: i32) -> Option<Self> {
        if pid <= 0 {
            return None;
        }
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::uninit();
        let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
        // SAFETY: proc_pidinfo writes up to size bytes into the supplied buffer.
        let read = unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size) };
        if read != size {
            return None;
        }
        // SAFETY: the kernel returned a complete proc_bsdinfo.
        let info = unsafe { info.assume_init() };
        if info.pbi_pid != pid as u32 || info.pbi_status == libc::SZOMB || info.pbi_start_tvsec == 0 {
            return None;
        }
        Some(Self {
            pid,
            group: i32::try_from(info.pbi_pgid).ok()?,
            birth: format!("darwin:{}:{}", info.pbi_start_tvsec, info.pbi_start_tvusec),
        })
    }

    #[cfg(target_os = "linux")]
    fn read(pid: i32) -> Option<Self> {
        if pid <= 0 {
            return None;
        }
        let boot = std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok()?;
        let stat = std::fs::read(format!("/proc/{pid}/stat")).ok()?;
        // The command name can contain spaces, non-UTF8 bytes, and parentheses.
        let end = stat.iter().rposition(|byte| *byte == b')')?;
        let mut fields = std::str::from_utf8(&stat[end + 1..]).ok()?.split_ascii_whitespace();
        // Fields after comm are state (3), ppid (4), pgrp (5), ... starttime (22).
        if matches!(fields.next()?, "Z" | "X" | "x") {
            return None;
        }
        let group = fields.nth(1)?.parse().ok()?;
        let ticks: u64 = fields.nth(16)?.parse().ok()?;
        Some(Self { pid, group, birth: format!("linux:{}:{ticks}", boot.trim()) })
    }

    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    fn read(_pid: i32) -> Option<Self> {
        None
    }
}

#[cfg(test)]
fn checkpoint(name: &str, value: &ProcessIdentity) -> Result<()> {
    let pause = std::path::PathBuf::from(format!("pause-{name}"));
    if pause.exists() {
        let marker = tempfile::NamedTempFile::new_in(".")?;
        serde_json::to_writer(marker.as_file(), value)?;
        marker.persist(format!("{name}.json"))?;
        let deadline = Instant::now() + Duration::from_secs(10);
        while pause.exists() {
            if Instant::now() >= deadline {
                return Err("Fixture checkpoint timed out.".into());
            }
            thread::sleep(POLL);
        }
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests;
