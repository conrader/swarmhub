use crate::{
    core::{MAX_FILE, valid_filename},
    history::{BackgroundJournal, History, StoreError, background_write, defer_if_busy, now},
};
use rusqlite::{Connection, OptionalExtension, params};
use rustix::fs::{Dir, FileType, Mode, OFlags, mkdirat, open, openat};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    fs::{DirBuilder, File, Metadata},
    io::{self, Read},
    os::unix::fs::{DirBuilderExt, MetadataExt},
    path::{Path, PathBuf},
    time::Duration,
};

const DIRECTORY: OFlags = OFlags::RDONLY
    .union(OFlags::DIRECTORY)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);
const FILE: OFlags = OFlags::RDONLY
    .union(OFlags::NONBLOCK)
    .union(OFlags::NOFOLLOW)
    .union(OFlags::CLOEXEC);
const FOLDERS: usize = 16;
const ENTRIES: usize = 128;
const FILES_PER_LAUNCH: i64 = 64;
const BYTES_PER_LAUNCH: i64 = 64 * 1024 * 1024;

pub fn path(history: &History, record: i64) -> PathBuf {
    history
        .file()
        .with_file_name("results")
        .join(record.to_string())
}

pub fn enable(history: &History, record: i64) -> Result<PathBuf, Box<dyn std::error::Error>> {
    let root = history.file().with_file_name("results");
    match DirBuilder::new().mode(0o700).create(&root) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error.into()),
    }
    let dir = open(root, DIRECTORY, Mode::empty())?;
    mkdirat(&dir, record.to_string(), Mode::RWXU)?;
    history
        .db()
        .map_err(|_| "Workspace journal unavailable.")?
        .execute("INSERT INTO result_folders (launch) VALUES (?1)", [record])?;
    Ok(path(history, record))
}

#[derive(Clone, Copy, Eq, PartialEq)]
struct Stamp(u64, u64, u64, i64, i64, i64, i64);

impl Stamp {
    fn new(meta: &Metadata) -> Option<Self> {
        (meta.is_file() && meta.nlink() == 1 && meta.len() <= MAX_FILE as u64).then(|| {
            Self(
                meta.dev(),
                meta.ino(),
                meta.len(),
                meta.mtime(),
                meta.mtime_nsec(),
                meta.ctime(),
                meta.ctime_nsec(),
            )
        })
    }

    fn settled(self) -> bool {
        now().saturating_sub(self.3.max(self.5).saturating_mul(1000)) >= 3000
    }
}

#[derive(Default)]
struct Scanner {
    seen: HashMap<i64, HashMap<String, (Stamp, bool)>>,
    after: i64,
}

impl Scanner {
    fn scan(
        &mut self,
        results_root: &Path,
        journal: &mut BackgroundJournal,
    ) -> Result<(), StoreError> {
        let Ok(root) = open(results_root, DIRECTORY, Mode::empty()) else {
            return Ok(());
        };
        let Some(db) = journal.db()? else {
            return Ok(());
        };
        let Some(folders) = defer_if_busy((|| {
            let mut stmt = db.prepare(
                "SELECT launch FROM result_folders WHERE launch>?1 ORDER BY launch LIMIT ?2",
            )?;
            stmt.query_map(params![self.after, FOLDERS], |row| row.get::<_, i64>(0))?
                .collect::<Result<Vec<_>, _>>()
        })())?
        else {
            return Ok(());
        };
        let mut read_bytes = 0;
        for &record in &folders {
            if read_bytes >= 2 * MAX_FILE {
                return Ok(());
            }
            self.after = record;
            let Ok(fd) = openat(&root, record.to_string(), DIRECTORY, Mode::empty()) else {
                continue;
            };
            let Ok(entries) = Dir::read_from(&fd) else {
                continue;
            };
            // Keep observations of a bounded number of folders in memory. Content
            // hashes in the database still suppress duplicates on restart.
            if self.seen.len() >= 512 && !self.seen.contains_key(&record) {
                self.seen.clear();
            }
            let seen = self.seen.entry(record).or_default();
            let mut next = HashMap::new();
            for entry in entries.take(ENTRIES).filter_map(Result::ok) {
                if entry.file_type() != FileType::RegularFile {
                    continue;
                }
                let Ok(name) = entry.file_name().to_str() else {
                    continue;
                };
                if name.starts_with('.') || !valid_filename(name) {
                    continue;
                }
                let Ok(opened) = openat(&fd, entry.file_name(), FILE, Mode::empty()) else {
                    continue;
                };
                let mut file = File::from(opened);
                let Some(stamp) = file.metadata().ok().as_ref().and_then(Stamp::new) else {
                    continue;
                };
                let mut done = false;
                let unchanged = seen.get(name).filter(|(before, _)| *before == stamp);
                if unchanged.is_some() || stamp.settled() {
                    done = unchanged.is_some_and(|(_, imported)| *imported);
                    if !done && read_bytes < 2 * MAX_FILE {
                        let mut data = Vec::new();
                        read_bytes += stamp.2 as usize;
                        if (&mut file)
                            .take(MAX_FILE as u64 + 1)
                            .read_to_end(&mut data)
                            .is_ok()
                            && data.len() as u64 == stamp.2
                            && file.metadata().ok().as_ref().and_then(Stamp::new) == Some(stamp)
                        {
                            if !save(db, record, name, &data)? {
                                // A writer is active. Try again on a later pass.
                                return Ok(());
                            }
                            done = true;
                        }
                    }
                }
                next.insert(name.to_owned(), (stamp, done));
            }
            *seen = next;
        }
        if folders.len() < FOLDERS {
            self.after = 0;
        }
        Ok(())
    }
}

fn save(db: &mut Connection, record: i64, name: &str, data: &[u8]) -> Result<bool, StoreError> {
    let mut hash = Sha256::new();
    hash.update(name.as_bytes());
    hash.update([0]);
    hash.update(data);
    let key = format!("collected:{:x}", hash.finalize());
    let Some(txn) = background_write(db)? else {
        return Ok(false);
    };
    let id: Option<i64> = txn.query_row(
        "INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms,event_key)
         SELECT launch_key, core_id,address,created_ms,agent,'artifact','saved','',?2,?3,?4
           FROM journal JOIN result_folders ON result_folders.launch=journal.id
          WHERE journal.id=?1 AND launch_key IS NOT NULL AND
            (SELECT count(*) < ?5 AND coalesce(sum(length(artifacts.data)),0) + ?6 <= ?7
              FROM journal saved JOIN artifacts ON artifacts.id=saved.id
             WHERE saved.reply_for=journal.launch_key AND saved.event_key LIKE 'collected:%')
         ON CONFLICT(reply_for,event_key) WHERE event_key IS NOT NULL DO NOTHING RETURNING id",
        params![record, name, now(), key, FILES_PER_LAUNCH, data.len(), BYTES_PER_LAUNCH],
        |row| row.get(0),
    ).optional()?;
    if let Some(id) = id {
        txn.execute(
            "INSERT INTO artifacts (id,data) VALUES (?1,?2)",
            params![id, data],
        )?;
    }
    txn.commit()?;
    Ok(true)
}

pub fn start(history: History) {
    let root = history.file().with_file_name("results");
    let mut journal = BackgroundJournal::new(history);
    tokio::spawn(async move {
        let mut scanner = Scanner::default();
        let mut tick = tokio::time::interval(Duration::from_secs(2));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tick.tick().await;
            let root = root.clone();
            let Ok((next, next_journal)) = tokio::task::spawn_blocking(move || {
                if scanner.scan(&root, &mut journal).is_err() {
                    eprintln!("SwarmHub could not collect finished files; it will try again.");
                }
                (scanner, journal)
            })
            .await
            else {
                break;
            };
            scanner = next;
            journal = next_journal;
        }
    });
}
