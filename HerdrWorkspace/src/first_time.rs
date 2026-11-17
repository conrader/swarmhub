//! The questions an agent program asks a person the first time it works for this server, answered ahead.
//!
//! Claude Code asks once per folder whether the folder is trusted, in its terminal, where no chat shows the
//! question; a bot's first message would wait there forever. A person who sets a computer up through the app
//! agrees, in one step that says so in plain words, that SwarmHub tells Claude Code to trust the one folder the
//! bots work in. This module makes exactly that entry, the way Claude Code's own documentation names for doing
//! it by hand (`projects["<folder>"].hasTrustDialogAccepted` in `~/.claude.json`), and takes it out again.
//!
//! The rules it keeps:
//! - It changes one member of one object. Everything else in the file keeps its text and its order (`json_edit`).
//! - The file is replaced in one step, with its permissions, and only if nobody changed it meanwhile. The file as
//!   it was before the first change is kept beside it (`….before-swarmhub`).
//! - A file that is missing (the program was never started here), unreadable, or not of the expected shape is
//!   left alone, and the answer says so: the app then shows the question to the person instead.
//! - What was changed is written down in the server's data folder (`first-time.json`), so that `undo` removes
//!   exactly that and nothing a person did themselves.
//! - Nothing here allows a tool, skips a permission prompt, or changes a sandbox or approval setting.
//!
//! Codex asks about the hooks `run-codex` gives it. Nothing is written for that: with the person's agreement,
//! which is written down here, `run-codex` tells Codex at each start that exactly those hooks are trusted
//! (`codex_agent::trust`). `undo` withdraws the agreement, and Codex asks again.

mod json_edit;

use json_edit::Node;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    env, fs,
    io::Write,
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
};

const RECORD: &str = "first-time.json";
const TRUST: &str = "hasTrustDialogAccepted";
const MAX_FILE: u64 = 64 * 1024 * 1024;

/// What was changed in an agent program's own settings, for `undo`.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
struct Record {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    claude: Option<Trusted>,
    /// The person agreed that `run-codex` tells Codex to trust the hooks it passes.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    codex_hooks: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
struct Trusted {
    file: PathBuf,
    folder: String,
    /// The folder had no entry in the file before: `undo` removes the entry when it is empty again.
    made_entry: bool,
    /// The member was there and said something else (its text): `undo` puts that back.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    was: Option<String>,
}

impl Record {
    fn load(data: &Path) -> Self {
        fs::read(data.join(RECORD))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save(&self, data: &Path) -> std::io::Result<()> {
        if *self == Self::default() {
            return match fs::remove_file(data.join(RECORD)) {
                Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
                _ => Ok(()),
            };
        }
        replace(
            &data.join(RECORD),
            serde_json::to_string_pretty(self)
                .map_err(std::io::Error::other)?
                .as_bytes(),
            0o600,
        )
    }
}

/// Writes `bytes` beside `path` and puts them in its place in one step.
fn replace(path: &Path, bytes: &[u8], mode: u32) -> std::io::Result<()> {
    let folder = path.parent().unwrap_or(Path::new("/"));
    let mut draft = tempfile::Builder::new()
        .prefix(".swarmhub-")
        .tempfile_in(folder)?;
    draft.write_all(bytes)?;
    draft.as_file().sync_all()?;
    fs::set_permissions(draft.path(), fs::Permissions::from_mode(mode))?;
    draft.persist(path).map_err(|error| error.error)?;
    Ok(())
}

/// Where Claude Code keeps what it remembers per folder: `.claude.json` in `CLAUDE_CONFIG_DIR`, else in the home folder.
fn claude_file(home: &Path) -> PathBuf {
    env::var_os("CLAUDE_CONFIG_DIR")
        .filter(|folder| !folder.is_empty())
        .map(PathBuf::from)
        .filter(|folder| folder.is_absolute())
        .unwrap_or_else(|| home.to_path_buf())
        .join(".claude.json")
}

/// Why a file was left alone.
#[derive(Debug, PartialEq)]
enum Left {
    /// The program has never been started for this account: there is nothing to add to.
    Missing,
    /// The file is not what this code knows how to change.
    Unrecognised(&'static str),
    /// It could not be read or replaced.
    NotWritten(String),
}

impl Left {
    fn sentence(&self, file: &Path) -> String {
        match self {
            Self::Missing => format!(
                "Claude Code has not been started on this computer yet ({} is not there), so there was nothing to tell it. Open Terminal, type claude, and sign in.",
                file.display()
            ),
            Self::Unrecognised(what) => format!(
                "Claude Code's settings file ({}) is not in a form SwarmHub knows ({what}), so it was left as it is.",
                file.display()
            ),
            Self::NotWritten(why) => format!(
                "Claude Code's settings file ({}) could not be changed ({why}), so it was left as it is.",
                file.display()
            ),
        }
    }
}

fn read(file: &Path) -> Result<(String, fs::Metadata), Left> {
    let meta = match fs::symlink_metadata(file) {
        Ok(meta) => meta,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Err(Left::Missing),
        Err(error) => return Err(Left::NotWritten(error.to_string())),
    };
    if !meta.is_file() {
        return Err(Left::Unrecognised("it is not an ordinary file"));
    }
    if meta.len() > MAX_FILE {
        return Err(Left::Unrecognised("it is larger than expected"));
    }
    let text = fs::read_to_string(file).map_err(|error| Left::NotWritten(error.to_string()))?;
    Ok((text, meta))
}

/// Applies `change` to the file's JSON and replaces the file, unless the change says there is nothing to do
/// (`Ok(None)`). The file must not have changed between the read and the replace; it is tried a few times, since
/// a running Claude Code rewrites this file often.
fn edit<T>(
    file: &Path,
    backup: bool,
    change: impl Fn(&mut Node) -> Result<Option<T>, Left>,
) -> Result<Option<T>, Left> {
    for _ in 0..5 {
        let (text, meta) = read(file)?;
        let mut tree = Node::read(&text).ok_or(Left::Unrecognised("it is not a JSON object"))?;
        let Some(done) = change(&mut tree)? else {
            return Ok(None);
        };
        let written = tree
            .write(&text)
            .ok_or(Left::Unrecognised("it could not be written again"))?;
        // What comes out must still be the file, with only this change: read it back before anything is replaced.
        if Node::read(&written).is_none() {
            return Err(Left::Unrecognised("it could not be written again"));
        }
        if backup {
            let mut name = file.file_name().unwrap_or_default().to_os_string();
            name.push(".before-swarmhub");
            let copy = file.with_file_name(name);
            if !copy.exists() {
                fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .mode(0o600)
                    .open(&copy)
                    .and_then(|mut copy| copy.write_all(text.as_bytes()))
                    .map_err(|error| Left::NotWritten(error.to_string()))?;
            }
        }
        // Someone wrote the file meanwhile: start again from what is there now.
        if fs::read_to_string(file).ok().as_deref() != Some(text.as_str()) {
            std::thread::sleep(std::time::Duration::from_millis(150));
            continue;
        }
        replace(file, written.as_bytes(), meta.permissions().mode() & 0o777)
            .map_err(|error| Left::NotWritten(error.to_string()))?;
        return Ok(Some(done));
    }
    Err(Left::NotWritten(
        "it kept changing while SwarmHub tried".into(),
    ))
}

/// Has Claude Code trust `folder`. `Ok(None)`: it does already, and nothing was written.
fn trust(file: &Path, folder: &str) -> Result<Option<Trusted>, Left> {
    edit(file, true, |tree| {
        let odd = Left::Unrecognised("its list of folders is not where it is expected");
        let (projects, _) = tree.object("projects").ok_or(odd)?;
        let odd = Left::Unrecognised("the folder's entry is not what is expected");
        let (entry, made_entry) = projects.object(folder).ok_or(odd)?;
        let was = entry.text_of(TRUST);
        if was.as_deref() == Some("true") {
            return Ok(None);
        }
        entry.set(TRUST, "true").ok_or(Left::Unrecognised(
            "the folder's entry is not what is expected",
        ))?;
        Ok(Some(Trusted {
            file: file.into(),
            folder: folder.into(),
            made_entry,
            was,
        }))
    })
}

/// Takes back what `trust` wrote: the member (or its earlier value), and the folder's entry when `trust` made it
/// and nothing else is in it. True when the file was changed.
fn untrust(trusted: &Trusted) -> Result<bool, Left> {
    let done = edit(&trusted.file, false, |tree| {
        let Some((projects, _)) = tree.object("projects") else {
            return Ok(None);
        };
        let Some((entry, made)) = projects.object(&trusted.folder) else {
            return Ok(None);
        };
        if made || entry.text_of(TRUST).as_deref() != Some("true") {
            // The entry is gone, or someone changed the answer since: it is theirs now.
            return Ok(None);
        }
        match &trusted.was {
            Some(was) => {
                entry.set(TRUST, was);
            }
            None => {
                entry.remove(TRUST);
            }
        }
        if trusted.made_entry && entry.is_empty_object() {
            projects.remove(&trusted.folder);
        }
        Ok(Some(()))
    })?;
    Ok(done.is_some())
}

/// Whether the person agreed that Codex is told to trust the hooks `run-codex` passes.
pub(crate) fn codex_hooks_agreed(data: &Path) -> bool {
    Record::load(data).codex_hooks
}

pub(crate) fn agree_codex_hooks(data: &Path, agreed: bool) -> std::io::Result<()> {
    let mut record = Record::load(data);
    record.codex_hooks = agreed;
    record.save(data)
}

/// Codex's part of `prepare`. `codex`: Codex as an agent would start it, in the bots' folder, or `None` when it
/// is not on this computer. It is asked, read-only, whether it reports the hooks in the form this code knows.
fn prepare_codex(data: &Path, exe: &Path, codex: Option<std::process::Command>) -> Option<Value> {
    let codex = codex?;
    let exe = exe.to_str()?;
    let (hooks, commands) = crate::codex_agent::hook_values(exe, false);
    Some(
        if crate::codex_agent::trust::ask(codex, &hooks, &commands).is_some() {
            let saved = agree_codex_hooks(data, true).is_ok();
            json!({"id": "codex", "done": saved, "changed": false,
                   "what": format!("Codex is told at each start to trust the three commands SwarmHub gives it ({exe} capture-codex-reply and tool-activity). Nothing was written into Codex's settings.")})
        } else {
            json!({"id": "codex", "done": false, "changed": false,
                   "why": "Codex did not list its hooks in a form SwarmHub knows, so it will ask about them itself the first time."})
        },
    )
}

/// Answers ahead what the agent programs would ask the first time they work in `folder`, the folder the bots
/// work in. Returns one entry per program for the app: `done` (nothing will be asked), and when not, `why` in a
/// sentence. `exe`: this server's program, as the starter templates name it. `claude`: Claude Code is here.
pub(crate) fn prepare(
    home: &Path,
    data: &Path,
    folder: &Path,
    exe: &Path,
    claude: bool,
    codex: Option<std::process::Command>,
) -> Value {
    // Only for the programs that are on this computer: nothing is told to a program nobody uses here.
    let mut answers = Vec::new();
    if claude {
        answers.push(prepare_claude(home, data, folder));
    }
    answers.extend(prepare_codex(data, exe, codex));
    Value::Array(answers)
}

fn prepare_claude(home: &Path, data: &Path, folder: &Path) -> Value {
    let mut record = Record::load(data);
    let file = claude_file(home);
    // The folder as Claude Code names it: the path it is started in, with links resolved.
    let named = folder
        .canonicalize()
        .unwrap_or_else(|_| folder.to_path_buf());
    let claude = match named.to_str() {
        None => json!({"id": "claude", "done": false, "changed": false,
                       "why": "The bots' folder has a name SwarmHub cannot write down for Claude Code."}),
        Some(named) => match trust(&file, named) {
            Ok(Some(trusted)) => {
                // The bots' folder is another than last time: what was written for the old one is taken back.
                if let Some(old) = record.claude.take().filter(|old| old.folder != named) {
                    let _ = untrust(&old);
                }
                record.claude = Some(trusted);
                let saved = record.save(data).is_ok();
                json!({"id": "claude", "done": true, "changed": true, "file": file, "folder": named, "recorded": saved,
                       "what": format!("Told Claude Code to trust the bots' folder ({named}).")})
            }
            Ok(None) => {
                json!({"id": "claude", "done": true, "changed": false, "file": file, "folder": named,
                               "what": format!("Claude Code already trusts the bots' folder ({named}).")})
            }
            Err(left) => json!({"id": "claude", "done": false, "changed": false, "file": file,
                                "why": left.sentence(&file)}),
        },
    };
    claude
}

/// Removes what `prepare` wrote. Returns what it did, one sentence each.
pub(crate) fn undo(data: &Path) -> Vec<String> {
    let mut record = Record::load(data);
    let mut did = Vec::new();
    if let Some(trusted) = record.claude.take() {
        match untrust(&trusted) {
            Ok(true) => did.push(format!(
                "Claude Code no longer trusts the bots' folder ({}) on SwarmHub's word.",
                trusted.folder
            )),
            Ok(false) => {}
            Err(left) => did.push(left.sentence(&trusted.file)),
        }
    }
    if record.codex_hooks {
        record.codex_hooks = false;
        did.push("Codex is no longer told to trust the commands SwarmHub gives it.".into());
    }
    let _ = record.save(data);
    crate::codex_agent::trust::forget(data);
    did
}

#[cfg(test)]
mod tests {
    use super::*;

    const BEFORE: &str = "{\n  \"numStartups\": 7,\n  \"projects\": {\n    \"/Users/ada/app\": {\n      \"allowedTools\": [],\n      \"hasTrustDialogAccepted\": true\n    }\n  },\n  \"oauthAccount\": {\"emailAddress\":\"ada@example.com\"}\n}";

    fn scratch() -> (tempfile::TempDir, PathBuf, PathBuf) {
        let scratch = tempfile::tempdir().unwrap();
        let file = scratch.path().join(".claude.json");
        let data = scratch.path().join("data");
        fs::create_dir(&data).unwrap();
        (scratch, file, data)
    }

    #[test]
    fn trusts_one_folder_keeps_the_rest_and_takes_it_back_exactly() {
        let (_scratch, file, _) = scratch();
        fs::write(&file, BEFORE).unwrap();
        fs::set_permissions(&file, fs::Permissions::from_mode(0o600)).unwrap();
        let trusted = trust(&file, "/Users/ada/swarmhub-agents").unwrap().unwrap();
        assert!(trusted.made_entry && trusted.was.is_none());
        let after = fs::read_to_string(&file).unwrap();
        assert_eq!(
            after,
            "{\n  \"numStartups\": 7,\n  \"projects\": {\n    \"/Users/ada/app\": {\n      \"allowedTools\": [],\n      \"hasTrustDialogAccepted\": true\n    },\n    \"/Users/ada/swarmhub-agents\": {\n      \"hasTrustDialogAccepted\": true\n    }\n  },\n  \"oauthAccount\": {\"emailAddress\":\"ada@example.com\"}\n}"
        );
        assert_eq!(
            fs::metadata(&file).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // The file as it was is kept beside it, once, for the account alone.
        let copy = file.with_file_name(".claude.json.before-swarmhub");
        assert_eq!(fs::read_to_string(&copy).unwrap(), BEFORE);
        assert_eq!(
            fs::metadata(&copy).unwrap().permissions().mode() & 0o777,
            0o600
        );
        // Asked again, nothing is written.
        assert_eq!(trust(&file, "/Users/ada/swarmhub-agents").unwrap(), None);
        assert_eq!(fs::read_to_string(&file).unwrap(), after);
        // Taken back, the file is what it was, byte for byte.
        assert!(untrust(&trusted).unwrap());
        assert_eq!(fs::read_to_string(&file).unwrap(), BEFORE);
        assert!(
            !untrust(&trusted).unwrap(),
            "a second undo finds nothing of its own"
        );
    }

    #[test]
    fn undo_leaves_what_a_person_or_claude_added_since() {
        let (_scratch, file, _) = scratch();
        // The folder was known and not trusted: only that answer changes, and undo puts it back.
        fs::write(
            &file,
            r#"{"projects":{"/bots":{"history":[1],"hasTrustDialogAccepted":false}}}"#,
        )
        .unwrap();
        let trusted = trust(&file, "/bots").unwrap().unwrap();
        assert!(!trusted.made_entry && trusted.was.as_deref() == Some("false"));
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            r#"{"projects":{"/bots":{"history":[1],"hasTrustDialogAccepted":true}}}"#
        );
        assert!(untrust(&trusted).unwrap());
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            r#"{"projects":{"/bots":{"history":[1],"hasTrustDialogAccepted":false}}}"#
        );
        // An entry SwarmHub made, which Claude Code has since added to, keeps what was added.
        fs::write(&file, r#"{"projects":{}}"#).unwrap();
        let trusted = trust(&file, "/bots").unwrap().unwrap();
        fs::write(
            &file,
            r#"{"projects":{"/bots":{"hasTrustDialogAccepted":true,"lastCost":0.25}}}"#,
        )
        .unwrap();
        assert!(untrust(&trusted).unwrap());
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            r#"{"projects":{"/bots":{"lastCost":0.25}}}"#
        );
        // An answer a person changed since is theirs.
        fs::write(
            &file,
            r#"{"projects":{"/bots":{"hasTrustDialogAccepted":false}}}"#,
        )
        .unwrap();
        assert!(!untrust(&trusted).unwrap());
    }

    #[test]
    fn a_file_that_is_missing_or_not_as_expected_is_left_alone() {
        let (_scratch, file, _) = scratch();
        assert_eq!(trust(&file, "/bots"), Err(Left::Missing));
        assert!(
            !file.exists(),
            "nothing is made for a program that was never started"
        );
        for odd in [
            "",
            "[]",
            "{\"projects\": 3}",
            "{\"projects\": {\"/bots\": true}}",
            "{not json",
        ] {
            fs::write(&file, odd).unwrap();
            assert!(
                matches!(trust(&file, "/bots"), Err(Left::Unrecognised(_))),
                "{odd}"
            );
            assert_eq!(fs::read_to_string(&file).unwrap(), odd);
        }
        assert!(!file.with_file_name(".claude.json.before-swarmhub").exists());
        std::os::unix::fs::symlink("/dev/null", file.with_file_name("link")).unwrap();
        assert!(matches!(
            trust(&file.with_file_name("link"), "/bots"),
            Err(Left::Unrecognised(_))
        ));
    }

    #[test]
    fn prepare_writes_down_what_it_changed_and_undo_removes_exactly_that() {
        let (scratch, file, data) = scratch();
        let bots = scratch.path().join("bots");
        fs::create_dir(&bots).unwrap();
        let named = bots.canonicalize().unwrap();
        let named = named.to_str().unwrap();
        fs::write(&file, "{\n  \"projects\": {}\n}\n").unwrap();
        let record = |data: &Path| Record::load(data);
        // `prepare` reads the file's place from the home folder it is given.
        let said = prepare(
            scratch.path(),
            &data,
            &bots,
            Path::new("/x/swarmhub-herdr"),
            true,
            None,
        );
        assert_eq!(said[0]["id"], "claude");
        assert!(
            said[0]["done"] == true && said[0]["changed"] == true,
            "{said}"
        );
        assert!(fs::read_to_string(&file).unwrap().contains(named));
        assert_eq!(record(&data).claude.unwrap().folder, named);
        // Again: nothing changes, and the record of the first change stays.
        let again = prepare(
            scratch.path(),
            &data,
            &bots,
            Path::new("/x/swarmhub-herdr"),
            true,
            None,
        );
        assert!(again[0]["done"] == true && again[0]["changed"] == false);
        assert!(record(&data).claude.is_some());
        let did = undo(&data);
        assert_eq!(did.len(), 1);
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            "{\n  \"projects\": {}\n}\n"
        );
        assert!(!data.join(RECORD).exists() && undo(&data).is_empty());
        // Codex: the agreement is written down, and withdrawn by undo.
        assert!(!codex_hooks_agreed(&data));
        agree_codex_hooks(&data, true).unwrap();
        assert!(codex_hooks_agreed(&data));
        assert_eq!(undo(&data).len(), 1);
        assert!(!codex_hooks_agreed(&data) && !data.join(RECORD).exists());
        // A folder Claude Code trusted by itself is not SwarmHub's to take back.
        fs::write(
            &file,
            format!("{{\"projects\": {{\"{named}\": {{\"hasTrustDialogAccepted\": true}}}}}}"),
        )
        .unwrap();
        assert!(
            prepare(
                scratch.path(),
                &data,
                &bots,
                Path::new("/x/swarmhub-herdr"),
                true,
                None
            )[0]["changed"]
                == false
        );
        assert!(undo(&data).is_empty() && fs::read_to_string(&file).unwrap().contains(TRUST));
        // No file: nothing is done, and the app is told why.
        fs::remove_file(&file).unwrap();
        let none = prepare(
            scratch.path(),
            &data,
            &bots,
            Path::new("/x/swarmhub-herdr"),
            true,
            None,
        );
        assert!(
            none[0]["done"] == false
                && none[0]["why"]
                    .as_str()
                    .unwrap()
                    .contains("not been started")
        );
        // A program that is not on this computer is told nothing.
        let absent = prepare(
            scratch.path(),
            &data,
            &bots,
            Path::new("/x/swarmhub-herdr"),
            false,
            None,
        );
        assert_eq!(absent, json!([]));
    }
}
