//! Codex's state databases, read into memory before Codex asks for them.
//!
//! Before its app server listens, Codex 0.169 reads its whole state database (`state_5.sqlite`, 7 MB here) and
//! about a thousand pages of its log database (`logs_2.sqlite`, 65 MB). On a server that is short of memory those
//! pages have been dropped again by the next start, and SQLite then asks the disk for them one page at a time.
//! With the disk busy, a traced start spent 66 of its 89 seconds on these reads: 2,800 of them, 24 ms each.
//! The same megabytes read once in file order take a second or two, and nothing when they are still in memory.
//!
//! So `run-codex` reads those files through while Codex starts. It only reads: the files are opened read-only
//! and without changing their access time, no lock is taken, and SQLite is not involved. A file that changes
//! meanwhile is simply read as it is; Codex reads it again itself, from memory.
//!
//! That is Linux. macOS cannot read a file without changing its access time, and a Mac's disk does not seek, so
//! there the files are left alone unless the template asks (`SWARMHUB_CODEX_PREFETCH=on`); the read then counts
//! as an access like any other.

use std::{
    env,
    fs::{self, File, OpenOptions},
    io::Read,
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

/// `SWARMHUB_CODEX_PREFETCH=off` leaves the files alone; `on` reads them where that is not the default (macOS).
const SWITCH: &str = "SWARMHUB_CODEX_PREFETCH";
/// A database larger than this is not read through: Codex's saved conversations (`thread_history_1.sqlite`,
/// 220 MB here) are, and a start reads only a few pages of them.
const FILE_LIMIT: u64 = 128 * 1024 * 1024;
const TOTAL_LIMIT: u64 = 256 * 1024 * 1024;
/// On a disk too busy to finish in this time, stop: Codex has long passed these reads or is doing them itself.
const TIME_LIMIT: Duration = Duration::from_secs(30);
const CHUNK: usize = 1024 * 1024;

/// Where Codex keeps its databases: `CODEX_SQLITE_HOME`, else `CODEX_HOME`, else `~/.codex`.
pub(super) fn home() -> Option<PathBuf> {
    ["CODEX_SQLITE_HOME", "CODEX_HOME"]
        .into_iter()
        .find_map(|name| env::var_os(name).filter(|value| !value.is_empty()))
        .map(PathBuf::from)
        .or_else(|| Some(PathBuf::from(env::var_os("HOME")?).join(".codex")))
        .filter(|path| path.is_absolute())
}

/// The databases and their write-ahead logs in `folder`, smallest first, within the limits.
fn files(folder: &Path) -> Vec<PathBuf> {
    let mut found: Vec<(u64, PathBuf)> = fs::read_dir(folder)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|entry| {
            entry
                .file_name()
                .to_str()
                .is_some_and(|name| name.ends_with(".sqlite") || name.ends_with(".sqlite-wal"))
        })
        // Not through a link: only files that are Codex's own, in this folder.
        .filter_map(|entry| {
            let file = fs::symlink_metadata(entry.path()).ok()?;
            (file.is_file() && file.len() > 0 && file.len() <= FILE_LIMIT)
                .then(|| (file.len(), entry.path()))
        })
        .collect();
    found.sort();
    let mut total = 0;
    found
        .into_iter()
        .take_while(|(bytes, _)| {
            total += bytes;
            total <= TOTAL_LIMIT
        })
        .map(|(_, path)| path)
        .collect()
}

fn open(path: &Path) -> Option<File> {
    let read_only = |flags| {
        OpenOptions::new()
            .read(true)
            .custom_flags(flags | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
    };
    // Another user's file cannot be opened without its access time changing. Then it is not opened.
    read_only(crate::platform::QUIET_READ.unwrap_or(0)).ok()
}

/// Reads the files through in order. Returns the bytes read.
fn read_through(folder: &Path, until: Instant) -> u64 {
    let mut buffer = vec![0_u8; CHUNK];
    let mut read = 0;
    for path in files(folder) {
        let Some(mut file) = open(&path) else {
            continue;
        };
        loop {
            if Instant::now() >= until {
                return read;
            }
            match file.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(bytes) => read += bytes as u64,
            }
        }
    }
    read
}

/// Whether to read at all: unless turned off where the read is quiet, and only when asked where it is not.
fn wanted(switch: Option<&str>, quiet: bool) -> bool {
    match switch {
        Some("off") => false,
        Some("on") => true,
        _ => quiet,
    }
}

/// Starts reading on a thread of its own. `run-codex` goes on at once, and the thread ends with it when it
/// becomes Codex, which by then is past these reads.
pub(super) fn start() {
    if !wanted(
        env::var(SWITCH).ok().as_deref(),
        crate::platform::QUIET_READ.is_some(),
    ) {
        return;
    }
    let Some(folder) = home() else {
        return;
    };
    let _ = std::thread::Builder::new()
        .name("codex-prefetch".into())
        .spawn(move || read_through(&folder, Instant::now() + TIME_LIMIT));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_codexs_own_databases_smallest_first_and_leaves_them_as_they_were() {
        let scratch = tempfile::tempdir().unwrap();
        let folder = scratch.path();
        fs::write(folder.join("logs_2.sqlite"), vec![7_u8; 3 * CHUNK + 5]).unwrap();
        fs::write(folder.join("state_5.sqlite"), vec![1_u8; 4096]).unwrap();
        fs::write(folder.join("state_5.sqlite-wal"), vec![2_u8; 100]).unwrap();
        fs::write(folder.join("goals_1.sqlite-wal"), b"").unwrap();
        fs::write(folder.join("auth.json"), b"{}").unwrap();
        fs::write(folder.join("state_5.sqlite-shm"), vec![3_u8; 32]).unwrap();
        std::os::unix::fs::symlink(folder.join("auth.json"), folder.join("linked.sqlite")).unwrap();
        let names: Vec<_> = files(folder)
            .iter()
            .map(|path| path.file_name().unwrap().to_str().unwrap().to_owned())
            .collect();
        assert_eq!(
            names,
            ["state_5.sqlite-wal", "state_5.sqlite", "logs_2.sqlite"]
        );

        let before = fs::metadata(folder.join("state_5.sqlite")).unwrap();
        let far = Instant::now() + Duration::from_secs(60);
        assert_eq!(read_through(folder, far), 3 * CHUNK as u64 + 5 + 4096 + 100);
        let after = fs::metadata(folder.join("state_5.sqlite")).unwrap();
        use std::os::unix::fs::MetadataExt;
        assert_eq!(
            (before.mtime_nsec(), before.len()),
            (after.mtime_nsec(), after.len())
        );
        // Where a read can be quiet, the access time is as it was.
        if crate::platform::QUIET_READ.is_some() {
            assert_eq!(
                (before.atime(), before.atime_nsec()),
                (after.atime(), after.atime_nsec())
            );
        }
        // Out of time, or nothing there: nothing is read and nothing fails.
        assert_eq!(read_through(folder, Instant::now()), 0);
        assert_eq!(read_through(&folder.join("missing"), far), 0);
    }

    #[test]
    fn reads_by_default_only_where_a_read_leaves_no_trace() {
        assert!(wanted(None, true) && wanted(Some("on"), true) && !wanted(Some("off"), true));
        assert!(!wanted(None, false) && wanted(Some("on"), false) && !wanted(Some("off"), false));
        assert!(wanted(Some("anything"), true) && !wanted(Some("anything"), false));
    }
}
