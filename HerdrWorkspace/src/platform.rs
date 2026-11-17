//! What Linux and macOS do differently, in one place. The rest of the server calls these and has no `cfg` of its
//! own, apart from the tests that are about one system.
//!
//! The server runs on both. Three things exist on Linux only, and each has its macOS answer here: a child that is
//! ended by the kernel when its parent ends (`end_with_parent`), a read that leaves a file's access time alone
//! (`QUIET_READ`; macOS has none), and `daemon(3)` (`detach`). One thing has no macOS answer: an agent's graphical desktop, which
//! is an X11 display (`DESKTOP`). The server says so (`unsupported`), and so does the command that would start one.

use serde_json::{Value, json};
use std::io;

/// The flag for a read that must not change the file's access time. macOS has none: a read there always counts
/// as an access, so what depends on a quiet read is off there unless it is asked for (`codex_agent::prefetch`).
#[cfg(target_os = "linux")]
pub(crate) const QUIET_READ: Option<libc::c_int> = Some(libc::O_NOATIME);
#[cfg(not(target_os = "linux"))]
pub(crate) const QUIET_READ: Option<libc::c_int> = None;

/// Why an agent cannot have a graphical desktop on this system; `None` where it can.
#[cfg(target_os = "linux")]
pub(crate) const DESKTOP: Option<&str> = None;
#[cfg(not(target_os = "linux"))]
pub(crate) const DESKTOP: Option<&str> = Some(
    "An agent's graphical desktop needs an X11 display (Xvfb), which this workspace starts on Linux servers only. Start the agent without run-desktop.",
);

/// What this server cannot do on the system it runs on, for `bridge` in `/api/workspace`: a word an app can act
/// on and a sentence it can show. Empty on Linux.
pub(crate) fn unsupported() -> Value {
    let mut list = Vec::new();
    if let Some(why) = DESKTOP {
        list.push(json!({"feature": "agent_desktop", "why": why}));
    }
    Value::Array(list)
}

/// For `pre_exec`, or for the calling process itself: this process is sent `signal` when its parent ends, however
/// the parent ends. Linux only. On macOS it does nothing, and the caller ends its children itself (`end_on_signal`).
#[cfg(target_os = "linux")]
pub(crate) fn end_with_parent(signal: libc::c_int) -> io::Result<()> {
    // SAFETY: one system call, safe between fork and exec.
    if unsafe { libc::prctl(libc::PR_SET_PDEATHSIG, signal) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(not(target_os = "linux"))]
pub(crate) fn end_with_parent(_signal: libc::c_int) -> io::Result<()> {
    Ok(())
}

/// The child that must not outlive this process (`end_on_signal`); 0 for none.
#[cfg(not(target_os = "linux"))]
static WARD: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(0);

/// Makes sure `child` ends when this process is told to end. On Linux the kernel does that for a child started
/// with `end_with_parent`, so nothing is done here. On macOS this process catches the signals that end it, ends
/// the child and then itself. A process that is killed outright (`SIGKILL`) cannot do this on macOS; its child
/// is then left to whoever started the session.
#[cfg(target_os = "linux")]
pub(crate) fn end_on_signal(_child: libc::pid_t) {}
#[cfg(not(target_os = "linux"))]
pub(crate) fn end_on_signal(child: libc::pid_t) {
    extern "C" fn ended(signal: libc::c_int) {
        let child = WARD.load(std::sync::atomic::Ordering::SeqCst);
        // SAFETY: `kill` and `_exit` are async-signal-safe.
        unsafe {
            if child > 0 {
                libc::kill(child, libc::SIGTERM);
            }
            libc::_exit(128 + signal);
        }
    }
    WARD.store(child, std::sync::atomic::Ordering::SeqCst);
    for signal in [libc::SIGTERM, libc::SIGHUP, libc::SIGINT] {
        // SAFETY: the handler only makes async-signal-safe calls.
        unsafe {
            libc::signal(
                signal,
                ended as extern "C" fn(libc::c_int) as libc::sighandler_t,
            )
        };
    }
}

/// Leaves the caller's session and parent: the calling process ends at once, and what returns is a child of it in
/// a session of its own, with the same folder and the same open files. Call it before any thread is started.
#[cfg(target_os = "linux")]
pub(crate) fn detach() -> io::Result<()> {
    // SAFETY: nothing else runs in this process yet; the call forks, and the half that stays leaves at once.
    if unsafe { libc::daemon(1, 1) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
#[cfg(not(target_os = "linux"))]
pub(crate) fn detach() -> io::Result<()> {
    // macOS has deprecated daemon(3); this is what it does with (1, 1).
    // SAFETY: nothing else runs in this process yet, so the child may go on as an ordinary process.
    match unsafe { libc::fork() } {
        -1 => Err(io::Error::last_os_error()),
        0 => {
            // SAFETY: a fresh child is never a group leader, so it can start a session.
            if unsafe { libc::setsid() } == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        }
        // SAFETY: the parent has nothing of its own to flush or drop.
        _ => unsafe { libc::_exit(0) },
    }
}

/// This machine's name as the system gives it; empty when it gives none.
pub(crate) fn host_name() -> String {
    let mut name = [0_u8; 256];
    // SAFETY: the buffer is ours and one byte longer than the length passed, so the name ends in a zero.
    if unsafe { libc::gethostname(name.as_mut_ptr().cast(), name.len() - 1) } != 0 {
        return String::new();
    }
    let end = name.iter().position(|byte| *byte == 0).unwrap_or(0);
    String::from_utf8_lossy(&name[..end]).into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn says_what_this_system_cannot_do() {
        let list = unsupported();
        let desktop = list
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| entry["feature"] == "agent_desktop" && entry["why"].is_string());
        assert_eq!(desktop, cfg!(not(target_os = "linux")));
        assert_eq!(DESKTOP.is_some(), cfg!(not(target_os = "linux")));
    }

    #[test]
    fn the_machine_has_a_name() {
        assert!(!host_name().is_empty());
    }

    /// The half that returns is in a session of its own, and the caller's direct child has ended with success.
    #[test]
    fn detach_leaves_the_callers_session() {
        // SAFETY: the forked child only calls `detach`, writes one byte and leaves without unwinding.
        unsafe {
            let mut pipe = [0; 2];
            assert_eq!(libc::pipe(pipe.as_mut_ptr()), 0);
            let session = libc::getsid(0);
            let child = libc::fork();
            assert!(child >= 0);
            if child == 0 {
                libc::close(pipe[0]);
                let own = detach().is_ok() && libc::getsid(0) == libc::getpid();
                let moved = libc::getsid(0) != session;
                let byte = [u8::from(own && moved)];
                libc::write(pipe[1], byte.as_ptr().cast(), 1);
                libc::_exit(0);
            }
            libc::close(pipe[1]);
            let mut status = 0;
            assert_eq!(libc::waitpid(child, &mut status, 0), child);
            assert!(libc::WIFEXITED(status) && libc::WEXITSTATUS(status) == 0);
            let mut byte = [0_u8];
            assert_eq!(libc::read(pipe[0], byte.as_mut_ptr().cast(), 1), 1);
            libc::close(pipe[0]);
            assert_eq!(byte[0], 1);
        }
    }
}
