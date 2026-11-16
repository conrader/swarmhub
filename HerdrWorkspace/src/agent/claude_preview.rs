//! Best-effort preview of text Claude Code renders in an explicitly bound session.
use super::{read_input, session, shell_quote};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    env,
    ffi::OsString,
    io::{Read, Write},
    os::unix::net::UnixStream,
    process::Command,
    time::{Duration, Instant},
};

pub(crate) const FLAG: &str = "--workspace-preview";
const ENABLED: &str = "SWARMHUB_CLAUDE_DISPLAY_PREVIEW";
const LIMIT: usize = 32 * 1024;
const HOOK_LIMIT: usize = 256 * 1024;
const MAX_SESSIONS: usize = 128;
const MAX_BATCHES: u32 = 4096;
const RECENT: usize = 8;
const TTL: Duration = Duration::from_secs(90);
const HOOK_WAIT: Duration = Duration::from_millis(100);

fn is_key(key: &str) -> bool {
    key.len() == 32 && key.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn session_id(key: &str) -> String {
    // Do not turn the private launch key into a visible Claude session ID.
    // A domain-separated digest binds the two without disclosing the key.
    let digest = Sha256::new()
        .chain_update(b"swarmhub-claude-display-session-v1\0")
        .chain_update(key.as_bytes())
        .finalize();
    let mut data: [u8; 16] = digest[..16].try_into().expect("16-byte digest prefix");
    data[6] = (data[6] & 0x0f) | 0x40;
    data[8] = (data[8] & 0x3f) | 0x80;
    let mut uuid = String::with_capacity(36);
    for (index, byte) in data.into_iter().enumerate() {
        if [4, 6, 8, 10].contains(&index) {
            uuid.push('-');
        }
        use std::fmt::Write;
        write!(uuid, "{byte:02x}").expect("writing to String");
    }
    uuid
}

fn uuid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, value)| {
            if [8, 13, 18, 23].contains(&i) {
                value == b'-'
            } else {
                value.is_ascii_hexdigit()
            }
        })
}

pub(super) fn configure(
    requested: bool,
    executable: &str,
    key: &str,
    settings: &mut Value,
    args: &mut Vec<OsString>,
    command: &mut Command,
) {
    command.env_remove(ENABLED);
    // Never replace explicit user --session-id, resume/continue, print mode,
    // or any other specialized launch. Pass those arguments through intact.
    let model_only = args.len() == 2
        && args[0] == "--model"
        && args[1]
            .to_str()
            .is_some_and(|model| crate::runtimes::ModelAgent::Claude.accepts(model));
    if !requested || !(args.is_empty() || model_only) {
        return;
    }
    let hook = format!("{} claude-preview-hook", shell_quote(executable));
    for event in [
        "SessionStart",
        "UserPromptSubmit",
        "MessageDisplay",
        "StopFailure",
        "SessionEnd",
    ] {
        settings["hooks"][event] = json!([{
            "hooks":[{"type":"command", "command":hook, "timeout":1}]
        }]);
    }
    args.extend(["--session-id".into(), session_id(key).into()]);
    command.env(ENABLED, "1");
}

#[derive(Deserialize)]
struct Hook {
    session_id: String,
    hook_event_name: String,
    turn_id: Option<String>,
    message_id: Option<String>,
    index: Option<u32>,
    delta: Option<String>,
    #[serde(rename = "final")]
    complete: Option<bool>,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "claude_preview", rename_all = "snake_case")]
pub(crate) enum Operation {
    Clear,
    Prompt,
    Display {
        turn: String,
        message: String,
        index: u32,
        delta: String,
        complete: bool,
    },
}

#[derive(Serialize, Deserialize)]
pub(crate) struct Update {
    pub key: String,
    session: String,
    #[serde(flatten)]
    operation: Operation,
}

impl Update {
    pub(crate) fn valid(&self) -> bool {
        is_key(&self.key)
            && self.session == session_id(&self.key)
            && match &self.operation {
                Operation::Display {
                    turn,
                    message,
                    index,
                    delta,
                    ..
                } => {
                    uuid(turn)
                        && uuid(message)
                        && *index < MAX_BATCHES
                        && delta.len() <= LIMIT
                        && !delta
                            .chars()
                            .any(|char| char.is_control() && char != '\n' && char != '\t')
                }
                _ => true,
            }
    }
}

pub(super) fn hook() {
    if env::var(ENABLED).as_deref() != Ok("1") {
        return;
    }
    let Ok(input) = read_input(HOOK_LIMIT) else {
        return;
    };
    let Ok(event) = serde_json::from_str::<Hook>(&input) else {
        return;
    };
    let operation = match event.hook_event_name.as_str() {
        "SessionStart" | "SessionEnd" | "StopFailure" => Operation::Clear,
        "UserPromptSubmit" => Operation::Prompt,
        "MessageDisplay" => {
            let (Some(turn), Some(message), Some(index), Some(delta), Some(complete)) = (
                event.turn_id,
                event.message_id,
                event.index,
                event.delta,
                event.complete,
            ) else {
                return;
            };
            Operation::Display {
                turn,
                message,
                index,
                delta,
                complete,
            }
        }
        _ => return,
    };
    send(event.session_id, operation);
}

pub(super) fn clear(session_id: String) {
    send(session_id, Operation::Clear);
}

fn send(session_id: String, operation: Operation) {
    if env::var(ENABLED).as_deref() != Ok("1") {
        return;
    }
    let Ok((journal, key)) = session() else {
        return;
    };
    let update = Update {
        key,
        session: session_id,
        operation,
    };
    if !update.valid() {
        return;
    }
    let Ok(mut bytes) = serde_json::to_vec(&update) else {
        return;
    };
    bytes.push(b'\n');
    let Ok(mut stream) = UnixStream::connect(journal.with_file_name("replies.sock")) else {
        return;
    };
    if stream.set_write_timeout(Some(HOOK_WAIT)).is_err()
        || stream.set_read_timeout(Some(HOOK_WAIT)).is_err()
    {
        return;
    }
    if stream.write_all(&bytes).is_ok() {
        // Short, best-effort acknowledgement keeps sequential hooks ordered.
        // Never emit hook output or alter the terminal's own display.
        let _ = stream.read_exact(&mut [0]);
    }
}

#[derive(Default)]
pub(crate) struct Previews(HashMap<String, Turn>);

struct Turn {
    updated: Instant,
    accepting: bool,
    id: Option<String>,
    retired: VecDeque<String>,
    message: Option<Message>,
}

struct Message {
    id: String,
    next_index: u32,
    complete: bool,
    invalid: bool,
    text: String,
}

impl Turn {
    fn reset(&mut self, accepting: bool) {
        if let Some(id) = self.id.take() {
            if self.retired.len() == RECENT {
                self.retired.pop_front();
            }
            self.retired.push_back(id);
        }
        self.accepting = accepting;
        self.message = None;
        self.updated = Instant::now();
    }

    fn display(
        &mut self,
        turn: String,
        message: String,
        index: u32,
        delta: String,
        complete: bool,
    ) {
        if !self.accepting
            || self.retired.contains(&turn)
            || self.id.as_ref().is_some_and(|id| *id != turn)
        {
            return;
        }
        if self.message.as_ref().is_none_or(|msg| msg.id != message) {
            if index != 0 || complete || self.message.as_ref().is_some_and(|msg| !msg.complete) {
                // A one-batch final-only message is never presented as live.
                return;
            }
            self.message = Some(Message {
                id: message,
                next_index: 0,
                complete: false,
                invalid: false,
                text: String::new(),
            });
            self.id = Some(turn);
        }
        let Some(msg) = self.message.as_mut() else {
            return;
        };
        if msg.complete || index < msg.next_index {
            return;
        }
        if index > msg.next_index || msg.text.len() + delta.len() > LIMIT {
            msg.invalid = true;
            msg.text.clear();
        }
        msg.next_index = index + 1;
        msg.complete = complete;
        self.updated = Instant::now();
        if !msg.invalid && !complete {
            msg.text.push_str(&delta);
        }
    }
}

impl Previews {
    pub(crate) fn apply(&mut self, update: Update) {
        self.prune();
        if !self.0.contains_key(&update.key) {
            if !matches!(update.operation, Operation::Prompt) || self.0.len() >= MAX_SESSIONS {
                return;
            }
            self.0.insert(
                update.key.clone(),
                Turn {
                    updated: Instant::now(),
                    accepting: false,
                    id: None,
                    retired: VecDeque::new(),
                    message: None,
                },
            );
        }
        let Some(turn) = self.0.get_mut(&update.key) else {
            return;
        };
        match update.operation {
            Operation::Prompt => turn.reset(true),
            Operation::Clear => turn.reset(false),
            Operation::Display {
                turn: id,
                message,
                index,
                delta,
                complete,
            } => turn.display(id, message, index, delta, complete),
        }
    }

    pub(crate) fn get(&self, key: &str) -> Option<(&str, &str)> {
        let turn = self.0.get(key)?;
        let message = turn.message.as_ref()?;
        (turn.updated.elapsed() < TTL && !message.text.trim().is_empty())
            .then_some((message.id.as_str(), message.text.as_str()))
    }

    pub(crate) fn visible(&self) -> bool {
        self.0.values().any(|turn| {
            turn.updated.elapsed() < TTL
                && turn
                    .message
                    .as_ref()
                    .is_some_and(|msg| !msg.text.trim().is_empty())
        })
    }

    fn prune(&mut self) {
        self.0.retain(|_, turn| turn.updated.elapsed() < TTL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LAUNCH: &str = "00112233445566778899aabbccddeeff";
    const TURN: &str = "11111111-2222-4333-8444-555555555555";
    const MESSAGE: &str = "66666666-7777-4888-8999-aaaaaaaaaaaa";

    fn update(operation: Operation) -> Update {
        Update {
            key: LAUNCH.into(),
            session: session_id(LAUNCH),
            operation,
        }
    }

    fn batch(index: u32, delta: &str, complete: bool) -> Update {
        update(Operation::Display {
            turn: TURN.into(),
            message: MESSAGE.into(),
            index,
            delta: delta.into(),
            complete,
        })
    }

    #[test]
    fn binds_exact_session_and_never_revives_finished_or_final_only_messages() {
        let mut drafts = Previews::default();
        let mut wrong = batch(0, "Wrong session\n", false);
        wrong.session = MESSAGE.into();
        assert!(!wrong.valid());
        assert_ne!(session_id(LAUNCH).replace('-', ""), LAUNCH);
        for bad in [
            batch(0, "\u{1b}[31m", false),
            batch(MAX_BATCHES, "Too many", false),
        ] {
            assert!(!bad.valid());
        }
        assert!(batch(0, "First line\n", false).valid());
        drafts.apply(batch(0, "No prompt gate\n", false));
        assert!(!drafts.visible());
        drafts.apply(update(Operation::Prompt));
        drafts.apply(batch(0, "Only final text", true));
        assert!(!drafts.visible());
        drafts.apply(batch(0, "First line\n", false));
        drafts.apply(batch(1, "Second line\n", false));
        drafts.apply(batch(1, "Duplicate\n", false));
        assert_eq!(
            drafts.get(LAUNCH),
            Some((MESSAGE, "First line\nSecond line\n"))
        );
        drafts.apply(update(Operation::Clear));
        drafts.apply(batch(2, "Late final", true));
        drafts.apply(update(Operation::Prompt));
        drafts.apply(batch(0, "Late old turn\n", false));
        assert!(!drafts.visible());
    }

    #[test]
    fn a_missing_batch_cannot_display_an_incomplete_or_unbounded_preview() {
        let mut drafts = Previews::default();
        drafts.apply(update(Operation::Prompt));
        drafts.apply(batch(0, "First\n", false));
        drafts.apply(batch(2, "Missing previous line\n", false));
        drafts.apply(batch(3, "Still incomplete\n", false));
        assert!(!drafts.visible());
        let mut drafts = Previews::default();
        drafts.apply(update(Operation::Prompt));
        drafts.apply(batch(0, &"a".repeat(LIMIT), false));
        assert!(drafts.visible());
        drafts.apply(batch(1, "b", false));
        assert!(!drafts.visible());
    }

    #[test]
    fn explicit_session_and_resume_flags_pass_through_without_preview() {
        for args in [
            vec!["--resume".into(), MESSAGE.into()],
            vec!["--session-id".into(), MESSAGE.into()],
            vec!["-p".into()],
        ] {
            let mut current = args.clone();
            let mut settings = json!({"hooks":{}});
            configure(
                true,
                "/bin/false",
                LAUNCH,
                &mut settings,
                &mut current,
                &mut Command::new("/bin/true"),
            );
            assert_eq!(current, args);
            assert!(settings["hooks"]["MessageDisplay"].is_null());
        }
    }
}
