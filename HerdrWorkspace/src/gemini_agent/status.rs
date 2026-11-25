//! Gemini CLI's status, written to its terminal the way Herdr reads it (an OSC 7501 report).
//!
//! The hooks write it (`report`). Gemini CLI runs no hook when a turn is cancelled or a permission refused, so
//! after the app's Stop the workspace writes `idle` itself (`after_stop`). For that, the hook that starts a
//! session leaves the terminal's path in `gemini-terminals/<launch>` beside the journal.

use std::{
    env, fs,
    io::Write,
    os::unix::fs::{DirBuilderExt, FileTypeExt, OpenOptionsExt},
    path::{Path, PathBuf},
    time::{Duration, SystemTime},
};

/// The terminal `run-gemini` started in, for hooks that have no terminal of their own.
pub(crate) const TTY_ENV: &str = "SWARMHUB_STATUS_TTY";
const FOLDER: &str = "gemini-terminals";
/// A terminal left behind by a session that was killed is forgotten after this long.
const KEEP: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const SWEEP: usize = 512;

pub(super) fn line(state: &str, kind: Option<&str>) -> String {
    match kind {
        Some(kind) => format!("\x1b]7501;state={state}:kind={kind}\x1b\\"),
        None => format!("\x1b]7501;state={state}\x1b\\"),
    }
}

fn write(terminal: &Path, state: &str, kind: Option<&str>) -> std::io::Result<()> {
    let mut file = fs::OpenOptions::new()
        .write(true)
        .custom_flags(libc::O_NOCTTY | libc::O_NONBLOCK)
        .open(terminal)?;
    if !file.metadata()?.file_type().is_char_device() {
        return Err(std::io::ErrorKind::InvalidInput.into());
    }
    file.write_all(line(state, kind).as_bytes())
}

fn terminal() -> PathBuf {
    env::var_os(TTY_ENV)
        .filter(|path| !path.is_empty())
        .map_or_else(|| "/dev/tty".into(), PathBuf::from)
}

/// From a hook: tells Herdr the state of the program in this terminal. Without a terminal it does nothing.
pub(super) fn report(state: &str, kind: Option<&str>) {
    let _ = write(&terminal(), state, kind);
}

fn entry(journal: &Path, key: &str) -> Option<PathBuf> {
    let plain = key.len() == 32 && key.bytes().all(|byte| byte.is_ascii_hexdigit());
    plain.then(|| journal.with_file_name(FOLDER).join(key))
}

/// From the hook that starts a session: where this launch's terminal is.
pub(super) fn remember(journal: &Path, key: &str) {
    let (Some(file), Some(terminal)) = (entry(journal, key), env::var_os(TTY_ENV)) else {
        return;
    };
    let Some(terminal) = terminal.to_str().filter(|path| path.starts_with("/dev/")) else {
        return;
    };
    let folder = journal.with_file_name(FOLDER);
    let _ = fs::DirBuilder::new().mode(0o700).create(&folder);
    sweep(&folder);
    let _ = fs::write(file, terminal);
}

/// From the hook that ends a session.
pub(super) fn forget(journal: &Path, key: &str) {
    if let Some(file) = entry(journal, key) {
        let _ = fs::remove_file(file);
    }
}

fn sweep(folder: &Path) {
    let Ok(entries) = fs::read_dir(folder) else {
        return;
    };
    let old = |file: &fs::DirEntry| {
        file.metadata()
            .and_then(|meta| meta.modified())
            .ok()
            .and_then(|at| SystemTime::now().duration_since(at).ok())
            .is_some_and(|age| age > KEEP)
    };
    for file in entries.take(SWEEP).flatten().filter(old) {
        let _ = fs::remove_file(file.path());
    }
}

/// Whether the launch is a Gemini CLI session that left its terminal's path.
pub(crate) fn known(journal: &Path, key: &str) -> bool {
    entry(journal, key).is_some_and(|file| file.is_file())
}

/// From the workspace, after the stop key was pressed in a live Gemini CLI terminal: the turn or the question
/// it stopped ends without a hook, so the terminal is told `idle` here. False when nothing was written.
pub(crate) fn after_stop(journal: &Path, key: &str) -> bool {
    let Some(terminal) = entry(journal, key).and_then(|file| fs::read_to_string(file).ok()) else {
        return false;
    };
    terminal.starts_with("/dev/")
        && !terminal.contains("..")
        && write(Path::new(&terminal), "idle", None).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_status_is_one_report_herdr_can_read() {
        assert_eq!(line("idle", None), "\x1b]7501;state=idle\x1b\\");
        assert_eq!(
            line("blocked", Some("auth")),
            "\x1b]7501;state=blocked:kind=auth\x1b\\"
        );
    }

    #[test]
    fn stop_writes_only_to_a_terminal_a_session_left() {
        let root = tempfile::tempdir().unwrap();
        let journal = root.path().join("journal.sqlite");
        let key = "0123456789abcdef0123456789abcdef";
        assert!(!known(&journal, key) && !after_stop(&journal, key));
        // A name that is not a launch never becomes a path.
        assert!(entry(&journal, "../../etc/passwd").is_none());

        fs::create_dir(root.path().join(FOLDER)).unwrap();
        let file = entry(&journal, key).unwrap();
        // Not a terminal: an ordinary file is left as it is.
        let plain = root.path().join("plain");
        fs::write(&plain, b"").unwrap();
        fs::write(&file, plain.to_str().unwrap()).unwrap();
        assert!(known(&journal, key) && !after_stop(&journal, key));
        fs::write(&file, "/dev/../etc/hostname").unwrap();
        assert!(!after_stop(&journal, key));
        // A device that takes anything stands in for the terminal.
        fs::write(&file, "/dev/null").unwrap();
        assert!(after_stop(&journal, key));

        forget(&journal, key);
        assert!(!known(&journal, key) && !after_stop(&journal, key));
    }
}
