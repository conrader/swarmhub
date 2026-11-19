//! Worker-local lifecycle for fixed, synthetic jobs. Each launch has its own
//! session and supervisor, independent of the command that recorded the intent.
mod admission;
pub(crate) mod bridge;
mod providers;
mod store;

use crate::{fleet_policy::principals::identifier, history};
use admission::{Admission, Blocker, Manifest, RuntimeReceipt, same_directory};
use base64::{Engine as _, engine::general_purpose::STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::{OsStr, OsString},
    fs::File,
    io::{self, BufRead, BufReader, Read, Write},
    net::Shutdown,
    os::{
        fd::{AsRawFd, FromRawFd, OwnedFd, RawFd},
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
#[cfg(any(test, feature = "fleet-test-fixture"))]
use std::os::fd::AsFd;
use store::{LEASE_MS, Run, Store};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

const PROTOCOL: u32 = 2;
const LEGACY_PROTOCOL: u32 = 1;
const INPUT_LIMIT: usize = 4096;
const LOG_LIMIT: usize = 1024;
const RESULT_LIMIT: usize = 4096;
const POLL: Duration = Duration::from_millis(20);
const LAUNCH_WAIT: Duration = Duration::from_secs(5);
const PROBE_INTERVAL: Duration = Duration::from_millis(100);
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

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
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

// The v2 launch column continues to accept the original fixture strings.
#[derive(Deserialize, Serialize)]
#[serde(untagged)]
enum Launch {
    Fixture(Fixture),
    Provider { profile_pin: String },
}

impl From<Fixture> for Launch {
    fn from(value: Fixture) -> Self {
        Self::Fixture(value)
    }
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Request {
    protocol: u32,
    worker: Worker,
    attempt: Attempt,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    fixture: Option<Fixture>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    manifest: Option<Manifest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    payload_digest: Option<String>,
}

impl Request {
    fn valid(&self, verb: &str) -> bool {
        (cfg!(any(test, feature = "fleet-test-fixture")) || self.fixture.is_none())
            && self.worker.valid()
            && identifier(&self.attempt.job_id)
            && self.attempt.number > 0
            && (verb == "start") == self.manifest.is_some()
            && match &self.manifest {
                Some(manifest) => self.fixture.is_some() != manifest.provider_run.is_some() && manifest.valid(),
                None => self.fixture.is_none(),
            }
    }
}

pub(crate) fn cli(args: &[OsString]) -> Result<()> {
    match args.first().and_then(|arg| arg.to_str()) {
        Some("rpc") if let [_, root, verb] = args => {
            bridge::run(Path::new(root), verb.to_str().ok_or(USAGE)?)
        }
        #[cfg(test)]
        Some("_outbound-executor") if args.len() == 1 => {
            crate::vault::workload::outbound::serve(
                UnixStream::from(io::stdin().as_fd().try_clone_to_owned()?),
            )?;
            Ok(())
        }
        #[cfg(test)]
        Some("_workload") if let [_, root, executor] = args => {
            relay_workload(Path::new(root), UnixStream::from(io::stdin().as_fd().try_clone_to_owned()?),
                workload_socket(executor)?)?;
            Ok(())
        }
        #[cfg(test)]
        Some("_workload-executor") if let [_, root, controller] = args => {
            crate::vault::workload::serve(Path::new(root), UnixStream::from(io::stdin().as_fd().try_clone_to_owned()?),
                workload_socket(controller)?)?;
            Ok(())
        }
        Some("_supervise") if let [_, root, token] = args => {
            supervise(Path::new(root), token.to_str().ok_or(USAGE)?)
        }
        Some("_provider") if let [_, dir, stdout, stderr] = args => {
            let stdout = descriptor(stdout)?;
            let stderr = descriptor(stderr)?;
            if stdout == stderr {
                return Err(USAGE.into());
            }
            // SAFETY: these distinct descriptors were inherited from the supervisor.
            let (stdout, stderr) = unsafe { (OwnedFd::from_raw_fd(stdout), OwnedFd::from_raw_fd(stderr)) };
            providers::exec(Path::new(dir), stdout, stderr)
        }
        #[cfg(any(test, feature = "fleet-test-fixture"))]
        Some("_fixture") if let [_, root, fixture] = args => {
            run_fixture(Path::new(root), serde_json::from_str(fixture.to_str().ok_or(USAGE)?)?)
        }
        #[cfg(any(test, feature = "fleet-test-fixture"))]
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
            if request.protocol != PROTOCOL
                && !(request.protocol == LEGACY_PROTOCOL && verb != "start")
            {
                return Err("Unsupported job worker protocol.".into());
            }
            if !request.valid(verb) || request.payload_digest.is_some() {
                return Err("Invalid job worker request.".into());
            }

            let mut store = Store::open(Path::new(root), Some(&request.worker))?;
            if let Some(manifest) = &request.manifest {
                start(&mut store, &request, manifest)?;
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

#[cfg(test)]
fn workload_socket(arg: &OsStr) -> Result<UnixStream> {
    let fd = descriptor(arg)?;
    // SAFETY: the fixture controller passes a distinct, owned socket at each
    // fixed descriptor. Neither descriptor survives the privileged child exec.
    Ok(UnixStream::from(unsafe { OwnedFd::from_raw_fd(fd) }))
}

#[cfg(test)]
fn relay_workload(root: &Path, mut bridge: UnixStream, mut executor: UnixStream) -> io::Result<()> {
    use crate::vault::workload::{Invocation, Outcome, read_frame, write_frame};
    let call: Invocation = read_frame(&mut bridge)?;
    let attempt = Attempt { job_id: call.terms.job_id.clone(), number: call.terms.attempt };
    let token = Store::open(root, None).and_then(|mut store| {
        if store.worker.id != call.terms.host_id || store.worker.host_fingerprint != call.terms.host_fingerprint {
            return Ok(None);
        }
        store.workload_admitted(&attempt, &call.terms.manifest_digest)
    }).ok().flatten();
    let outcome = if let Some(token) = token {
        match write_frame(&mut executor, &call).and_then(|()| read_frame::<Outcome>(&mut executor)) {
            Ok(outcome) => {
                let mut staged = tempfile::NamedTempFile::new_in(root)?;
                serde_json::to_writer(staged.as_file_mut(), &outcome)?;
                staged.persist(workload_outcome_path(root, &token))?;
                outcome
            }
            Err(_) => Outcome::Uncertain,
        }
    } else {
        Outcome::Denied
    };
    write_frame(&mut bridge, &outcome)
}

#[cfg(test)]
fn workload_outcome_path(root: &Path, token: &str) -> std::path::PathBuf {
    root.join(format!("workload-outcome-{token}"))
}

fn start(store: &mut Store, request: &Request, manifest: &Manifest) -> Result<()> {
    let manifest_digest = digest(&serde_json::to_vec(request)?);
    let launcher = ProcessIdentity::current()?;
    let Some(token) = store.reserve(&request.attempt, &manifest_digest, manifest, &launcher, |root, worker| {
        let (grant, _) = Admission::open(root).map_err(|_| Blocker::hold("policy_unavailable"))?
            .check(worker, &request.attempt.job_id, manifest, None)?;
        let launch = match (&manifest.provider_run, request.fixture) {
            (Some(provider_run), None) => {
                let profile = providers::Profile::load(root, provider_run, manifest.provider,
                    &grant.account_ref, grant.runtime_version.as_deref())?;
                Launch::Provider {
                    profile_pin: profile.pin().map_err(|_| Blocker::hold("runtime_profile_unavailable"))?,
                }
            }
            (None, Some(fixture)) => Launch::Fixture(fixture),
            _ => return Err(Blocker::hold("invalid_launch")),
        };
        Ok((grant, launch))
    })? else {
        return Ok(());
    };
    let (mut gate, supervisor_gate) = UnixStream::pair()?;
    let mut command = subprocess([
        OsStr::new("_supervise"),
        store.root.as_os_str(),
        OsStr::new(&token),
    ])?;
    command.current_dir(&store.root).stdin(Stdio::from(OwnedFd::from(supervisor_gate)));
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
            store.start_unconfirmed(&token, "supervisor_spawn_failed")?;
            return Err(error.into());
        }
    };

    #[cfg(test)]
    checkpoint(&store.root, "before-launcher-pin", &launcher)?;

    // The detached supervisor waits for this durable pin before opening SQLite.
    // A competing start can observe the launcher until the pin commits.
    let deadline = Instant::now() + LAUNCH_WAIT;
    loop {
        if let Some(identity) = ProcessIdentity::read(supervisor.id() as i32)
            .filter(|process| process.pid == process.group)
        {
            if store.register_supervisor(&token, &identity)?.is_some() {
                let _ = gate.write_all(&[RELEASE]);
            }
            break;
        }
        if supervisor.try_wait()?.is_some() {
            store.start_unconfirmed(&token, "supervisor_exited_before_pin")?;
            break;
        }
        if Instant::now() >= deadline {
            store.start_unconfirmed(&token, "supervisor_identity_unavailable")?;
            break;
        }
        thread::sleep(POLL);
    }
    Ok(())
}

fn supervise(root: &Path, token: &str) -> Result<()> {
    let mut release = [0];
    if io::stdin().read_exact(&mut release).is_err() || release != [RELEASE] {
        return Ok(());
    }
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
    checkpoint(root, "after-supervisor-pin", &supervisor)?;
    // The launcher already recorded the same identity before releasing the gate.
    let Some(run) = store.run(token, &supervisor)? else {
        return Ok(());
    };

    let admission = match Admission::open(root) {
        Ok(admission) => admission,
        Err(_) => return stopped_before_launch(&mut store, token, &run, Blocker::stop("policy_heartbeat_lost")),
    };
    let mut lease_deadline = run.lease_deadline;
    let (directory, grant) = match launch_health(&mut store, token, &run, &admission, None, &mut lease_deadline) {
        Ok(ready) => ready,
        Err(stop) => return stopped_before_launch(&mut store, token, &run, stop),
    };
    let (mut channel, child_channel) = UnixStream::pair()?;
    let prepared;
    let mut provider_io;
    let mut command = match &run.launch {
        #[cfg(any(test, feature = "fleet-test-fixture"))]
        Launch::Fixture(fixture) => {
            prepared = None;
            provider_io = None;
            let arg = serde_json::to_string(fixture)?;
            subprocess([OsStr::new("_fixture"), root.as_os_str(), OsStr::new(&arg)])?
        }
        #[cfg(not(any(test, feature = "fleet-test-fixture")))]
        Launch::Fixture(_) => return Err("The fixture launch is disabled.".into()),
        Launch::Provider { profile_pin } => {
            let request = run.manifest.provider_run.as_ref().ok_or("Missing provider request.")?;
            let stage = (|| {
                let profile = providers::Profile::load(root, request, run.manifest.provider,
                    &run.account_ref, grant.runtime_version.as_deref()).map_err(|_| "Profile is unavailable.")?;
                if &profile.pin()? != profile_pin {
                    return Err("Profile pin changed.".into());
                }
                profile.stage(root, request, run.manifest.requested_model.as_deref(),
                    run.manifest.requested_effort.as_deref(),
                    #[cfg(test)]
                    workload_outcome_path(root, token),
                )
            })();
            let invocation = match stage {
                Ok(invocation) => invocation,
                Err(_) => return stopped_before_launch(&mut store, token, &run, Blocker::stop("runtime_profile_changed")),
            };
            let (capture, stdout, stderr) = ProviderIo::new()?;
            let stdout_fd = stdout.as_raw_fd();
            let stderr_fd = stderr.as_raw_fd();
            let mut command = subprocess([
                OsString::from("_provider"), invocation.path().into(),
                stdout_fd.to_string().into(), stderr_fd.to_string().into(),
            ])?;
            // The launcher keeps its own stdout/stderr. Only the exec'd provider
            // writes to the capture sockets in both the production and test path.
            // SAFETY: fcntl is async-signal-safe and only changes descriptors in the fresh child.
            unsafe {
                command.pre_exec(move || {
                    set_descriptor_flags(stdout.as_raw_fd(), 0)?;
                    set_descriptor_flags(stderr.as_raw_fd(), 0)
                });
            }
            provider_io = Some(capture);
            prepared = Some(invocation);
            command
        }
    };
    command.process_group(0).stdin(Stdio::from(OwnedFd::from(child_channel)));
    let workdir_fd = directory.as_raw_fd();
    // SAFETY: fchdir is async-signal-safe. The parent keeps the verified
    // directory descriptor open through spawn so the child uses that directory.
    unsafe {
        command.pre_exec(move || {
            if libc::fchdir(workdir_fd) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(_) => return stopped_before_launch(&mut store, token, &run, Blocker::stop("child_spawn_failed")),
    };
    drop(command);

    // EOF before the release byte leaves the child unable to execute a provider.
    let registered = (|| {
        let identity = ProcessIdentity::read(child.id() as i32)
            .filter(|process| process.pid == process.group)
            .ok_or("Could not establish the child process group identity.")?;
        #[cfg(test)]
        checkpoint(root, "before-child-registration", &identity)?;
        let cancelled = store.register_child(token, &identity)?;
        Ok::<_, Box<dyn std::error::Error>>((identity, cancelled))
    })();
    let (identity, cancelled) = match registered {
        Ok((identity, Some(cancelled))) => (identity, cancelled),
        other => {
            // Explicit shutdown also reaches the child if another process inherited a descriptor.
            let _ = channel.shutdown(Shutdown::Both);
            child.wait()?;
            return other.map(|_| ());
        }
    };

    let mut stop = match launch_health(&mut store, token, &run, &admission, Some(&directory), &mut lease_deadline) {
        Ok((_, grant)) if prepared.as_ref().is_some_and(|attempt| {
            grant.runtime_version.as_deref() != Some(attempt.version.as_str())
        }) => Some(Blocker::stop("runtime_version_changed")),
        Ok(_) => None,
        Err(stop) => Some(stop),
    };
    let mut sent_cancel = false;
    if let Some(reason) = &stop {
        store.record_stop(token, reason);
    }
    if cancelled {
        sent_cancel = cancel_group(&child, &identity).unwrap_or(false);
    } else if stop.is_none() {
        let _ = channel.write_all(&[RELEASE]);
    }
    let _ = channel.shutdown(Shutdown::Write);
    let capture = if prepared.is_none() {
        thread::Builder::new().spawn(move || read_output(channel).unwrap_or_default()).ok()
    } else {
        None
    };
    let deadline = prepared.as_ref().map(|attempt| Instant::now() + attempt.timeout);
    let mut next_probe = Instant::now() + PROBE_INTERVAL;
    let mut cancel_verified = history::now();
    let exit = loop {
        if let Some(capture) = &mut provider_io {
            capture.drain();
        }
        if let Some(exit) = reap(&mut child, prepared.is_some())? {
            break exit;
        }
        if !sent_cancel {
            if stop.is_none() && deadline.is_some_and(|deadline| Instant::now() >= deadline) {
                stop = Some(Blocker::stop("runtime_timeout"));
            }
            if stop.is_none() && (Instant::now() >= next_probe || history::now() >= lease_deadline) {
                next_probe = Instant::now() + PROBE_INTERVAL;
                match health(&mut store, token, &run, &admission, Some(&directory)) {
                    Ok((_, _, until)) => lease_deadline = until,
                    Err(reason) if retry_health(&reason, lease_deadline) => next_probe = Instant::now() + POLL,
                    Err(reason) => stop = Some(reason),
                }
            }
            let cancelled = stop.is_none() && match store.cancel_pending(token) {
                Ok(cancelled) => {
                    cancel_verified = history::now();
                    cancelled
                }
                Err(error) if sqlite_busy(&error) && history::now() < (cancel_verified + LEASE_MS).min(lease_deadline) => false,
                Err(_) => {
                    stop = Some(Blocker::stop("lease_unavailable"));
                    false
                }
            };
            if stop.is_some() || cancelled {
                let signalled = cancel_group(&child, &identity).unwrap_or(false);
                sent_cancel = cancelled && signalled;
                if signalled && let Some(reason) = &stop {
                    store.record_stop(token, reason);
                }
            }
        }
        thread::sleep(POLL);
    };

    let deadline = Instant::now() + GROUP_WAIT;
    while !identity.group_ended() && Instant::now() < deadline {
        thread::sleep(POLL);
    }
    let output = capture.and_then(|reader| reader.join().ok()).unwrap_or_default();
    let mut receipt = Receipt::new(exit, sent_cancel, output);
    if let (Some(prepared), Some(mut capture)) = (prepared, provider_io) {
        // The leader has exited. Collect buffered data without waiting for EOF
        // from a descendant that inherited a socket.
        capture.drain();
        let output = prepared.collect(&capture.events.bytes, &capture.diagnostics.bytes,
            exit.success() && stop.is_none());
        receipt.set_provider(&run, output, stop.as_ref());
    } else {
        receipt.set_runtime(&run);
    }
    store.finish(token, &receipt, stop.as_ref(), identity.group_ended())
}

fn sqlite_busy(error: &rusqlite::Error) -> bool {
    matches!(error.sqlite_error_code(), Some(rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked))
}

fn retry_health(reason: &Blocker, lease_deadline: i64) -> bool {
    matches!(reason.reason.as_str(), "policy_busy" | "lease_busy") && history::now() < lease_deadline
}

fn launch_health(
    store: &mut Store, token: &str, run: &Run, admission: &Admission, launched_in: Option<&File>,
    lease_deadline: &mut i64,
) -> std::result::Result<(File, admission::Grant), Blocker> {
    loop {
        match health(store, token, run, admission, launched_in) {
            Ok((directory, grant, until)) => {
                *lease_deadline = until;
                if run.manifest.provider_run.is_some() && !grant.login_ready {
                    return Err(Blocker::stop("login_stale"));
                }
                return Ok((directory, grant));
            }
            Err(reason) if retry_health(&reason, *lease_deadline) => thread::sleep(POLL),
            Err(reason) => return Err(reason),
        }
    }
}

fn health(
    store: &mut Store, token: &str, run: &Run, admission: &Admission, launched_in: Option<&File>,
) -> std::result::Result<(File, admission::Grant, i64), Blocker> {
    let (grant, directory) = admission.check(&store.worker, &run.job_id, &run.manifest, Some(&run.policy))?;
    if launched_in.is_some_and(|original| !same_directory(original, &directory)) {
        return Err(Blocker::stop("workdir_changed"));
    }
    if run.exception.as_ref().is_some_and(|exception| history::now() >= exception.expires_ms) {
        return Err(Blocker::stop("exception_expired"));
    }
    match store.renew(token, run, &grant) {
        Ok(Some(until)) => Ok((directory, grant, until)),
        Ok(None) => Err(Blocker::stop("lease_expired")),
        Err(error) if sqlite_busy(&error) => Err(Blocker::stop("lease_busy")),
        Err(_) => Err(Blocker::stop("lease_unavailable")),
    }
}

// The provider leader stays waitable until its group is signalled. Holding
// its PID prevents reuse between observing its exit and cleaning up the group.
#[cfg(any(target_os = "macos", target_os = "linux"))]
fn reap(child: &mut Child, provider: bool) -> io::Result<Option<ExitStatus>> {
    if !provider {
        return child.try_wait();
    }
    let pid = child.id() as i32;
    // SAFETY: waitid writes a siginfo record. With WNOHANG, an empty record has si_pid=0.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    let result = unsafe {
        libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOHANG | libc::WNOWAIT)
    };
    if result == -1 {
        let error = io::Error::last_os_error();
        return if error.kind() == io::ErrorKind::Interrupted { Ok(None) } else { Err(error) };
    }
    if unsafe { info.si_pid() } == 0 {
        return Ok(None);
    }
    // SAFETY: this is our unreaped child, spawned as the leader of this group.
    unsafe { libc::kill(-pid, libc::SIGKILL) };
    child.wait().map(Some)
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn reap(child: &mut Child, _provider: bool) -> io::Result<Option<ExitStatus>> {
    child.try_wait()
}

fn set_descriptor_flags(fd: RawFd, flags: i32) -> io::Result<()> {
    // SAFETY: fcntl checks the descriptor and F_SETFD takes an integer argument.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, flags) } == -1 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn descriptor(value: &OsStr) -> Result<RawFd> {
    let fd = value.to_str().and_then(|value| value.parse().ok()).filter(|fd| *fd > 2)
        .ok_or(USAGE)?;
    set_descriptor_flags(fd, libc::FD_CLOEXEC)?;
    Ok(fd)
}

struct Capture {
    socket: UnixStream,
    bytes: Vec<u8>,
    limit: usize,
}

impl Capture {
    fn new(limit: usize) -> io::Result<(Self, OwnedFd)> {
        let (socket, writer) = UnixStream::pair()?;
        socket.set_nonblocking(true)?;
        Ok((Self { socket, bytes: Vec::new(), limit }, OwnedFd::from(writer)))
    }

    fn drain(&mut self) {
        let mut buffer = [0; 8192];
        // A flooding child cannot starve the timeout or policy checks.
        for _ in 0..16 {
            match self.socket.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    let keep = count.min(self.limit.saturating_sub(self.bytes.len()));
                    self.bytes.extend_from_slice(&buffer[..keep]);
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    }
}

struct ProviderIo {
    events: Capture,
    diagnostics: Capture,
}

impl ProviderIo {
    fn new() -> io::Result<(Self, OwnedFd, OwnedFd)> {
        let (events, stdout) = Capture::new(providers::EVENTS_LIMIT + 1)?;
        let (diagnostics, stderr) = Capture::new(LOG_LIMIT)?;
        Ok((Self { events, diagnostics }, stdout, stderr))
    }

    fn drain(&mut self) {
        self.events.drain();
        self.diagnostics.drain();
    }
}

fn stopped_before_launch(store: &mut Store, token: &str, run: &Run, stop: Blocker) -> Result<()> {
    let mut receipt = Receipt::new(ExitStatus::from_raw(0), false, Output::default());
    receipt.code = None;
    if run.manifest.provider_run.is_some() {
        receipt.set_provider(run, providers::Collected::default(), Some(&stop));
    } else {
        receipt.set_runtime(run);
    }
    store.finish(token, &receipt, Some(&stop), true)
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

#[cfg(any(test, feature = "fleet-test-fixture"))]
fn run_fixture(root: &Path, fixture: Fixture) -> Result<()> {
    #[cfg(not(test))]
    let _ = root;
    let mut channel = UnixStream::from(io::stdin().as_fd().try_clone_to_owned()?);
    let mut release = [0];
    if channel.read(&mut release)? == 0 {
        return Err("The fixture start was not released.".into());
    }
    if release != [RELEASE] {
        return Err("Invalid fixture release.".into());
    }
    #[cfg(test)]
    checkpoint(root, "fixture-released", &ProcessIdentity::current()?)?;
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
            checkpoint(root, "group-ready", &identity)?;
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    runtime: Option<RuntimeReceipt>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    runtime_failure: Option<String>,
}

impl Receipt {
    fn without_child(cancelled: bool) -> Self {
        Self {
            code: None, signal: None, cancelled, log: None, result: None,
            result_truncated: false, runtime: None,
            runtime_failure: (!cancelled).then(|| "supervisor_lost_before_child_pin".into()),
        }
    }

    fn new(exit: ExitStatus, sent_cancel: bool, output: Output) -> Self {
        Self {
            code: exit.code(),
            signal: exit.signal(),
            cancelled: sent_cancel && exit.signal() == Some(libc::SIGKILL),
            log: output.log,
            result: exit.success().then_some(output.result).flatten(),
            result_truncated: output.result_truncated,
            runtime: None,
            runtime_failure: None,
        }
    }

    fn set_runtime(&mut self, run: &Run) {
        self.runtime = Some(RuntimeReceipt {
            provider: Some(run.manifest.provider),
            account_ref: Some(run.account_ref.clone()),
            result_digest: self.result.as_ref().map(|result| digest(result.as_bytes())),
            ..RuntimeReceipt::default()
        });
    }

    fn provider_run(&self) -> bool {
        self.runtime.as_ref().is_some_and(|runtime| runtime.profile.is_some())
    }

    fn set_provider(&mut self, run: &Run, output: providers::Collected, stop: Option<&Blocker>) {
        self.log = output.log;
        self.result = output.result;
        self.result_truncated = output.truncated;
        let (verdict, failure) = if stop.is_some() {
            ("interrupted", None)
        } else if self.cancelled {
            ("cancelled", None)
        } else if self.signal.is_some() {
            ("interrupted", None)
        } else if self.code != Some(0) {
            ("failed", Some("nonzero_exit"))
        } else if let Some(failure) = output.failure {
            ("failed", Some(failure))
        } else {
            ("succeeded", None)
        };
        self.runtime_failure = failure.map(str::to_owned);
        let review_eligible = verdict == "succeeded"
            && output.observed.family.is_some() && output.observed.version.is_some();
        self.runtime = Some(RuntimeReceipt {
            provider: Some(run.manifest.provider),
            account_ref: Some(run.account_ref.clone()),
            observed_model: output.observed.model,
            observed_family: output.observed.family.map(str::to_owned),
            observed_effort: output.observed.effort,
            cli_version: output.observed.version,
            verdict: Some(verdict.into()),
            result_digest: self.result.as_ref().map(|result| digest(result.as_bytes())),
            requested_model: run.manifest.requested_model.clone(),
            requested_effort: run.manifest.requested_effort.clone(),
            profile: run.manifest.provider_run.as_ref().map(|request| request.profile.clone()),
            review_eligible: Some(review_eligible),
        });
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

    fn group_ended(&self) -> bool {
        if self.group <= 0 || self.pid != self.group {
            return false;
        }
        // SAFETY: signal 0 queries existence without signalling the process group.
        (unsafe { libc::kill(-self.group, 0) == -1 })
            && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
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
fn checkpoint(root: &Path, name: &str, value: &ProcessIdentity) -> Result<()> {
    let pause = root.join(format!("pause-{name}"));
    if pause.exists() {
        let marker = tempfile::NamedTempFile::new_in(root)?;
        serde_json::to_writer(marker.as_file(), value)?;
        marker.persist(root.join(format!("{name}.json")))?;
        let deadline = Instant::now() + Duration::from_secs(30);
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
