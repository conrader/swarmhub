//! Which tools a running agent has started and finished, for the reply that is still being written.
//!
//! Claude Code and Codex both run `swarmhub-herdr tool-activity` from their PreToolUse and PostToolUse hooks and
//! describe the call on standard input (`tool_name`, `tool_input`, `tool_use_id`); Gemini CLI's hook
//! (`gemini_agent`) reports its BeforeTool and AfterTool the same way. The hook sends one line to the
//! workspace's live socket; the workspace keeps the newest calls of each launch in memory only. Nothing here can
//! allow, deny or delay a tool: the hook always answers `{}` and gives up at once when the workspace is not running.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::HashMap,
    io::{self, Read, Write},
    os::unix::net::UnixStream,
    time::{Duration, Instant},
};

/// A tool result can be a whole file. It is skipped while parsing, never held.
const HOOK_LIMIT: u64 = 64 * 1024 * 1024;
const HOOK_WAIT: Duration = Duration::from_millis(200);
const DETAIL_CHARS: usize = 200;
const NAME_LIMIT: usize = 64;
const CALL_LIMIT: usize = 128;
const CALLS: usize = 32;
const SESSIONS: usize = 256;
const KEEP: Duration = Duration::from_secs(30 * 60);

#[derive(Deserialize)]
struct Hook {
    hook_event_name: String,
    tool_name: Option<String>,
    tool_input: Option<Value>,
    tool_use_id: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub(crate) enum Phase {
    Started,
    Finished,
    Failed,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Event {
    phase: Phase,
    tool: String,
    detail: Option<String>,
    call: Option<String>,
}

/// One line on the live socket. `activity` tells it apart from the reply previews that share the socket.
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Frame {
    pub key: String,
    activity: Event,
}

impl Frame {
    pub(crate) fn valid(&self) -> bool {
        let plain = |text: &str| !text.chars().any(char::is_control);
        self.key.len() == 32
            && self.key.bytes().all(|byte| byte.is_ascii_hexdigit())
            && !self.activity.tool.is_empty()
            && self.activity.tool.len() <= NAME_LIMIT
            && plain(&self.activity.tool)
            && self
                .activity
                .detail
                .as_deref()
                .is_none_or(|detail| detail.chars().count() <= DETAIL_CHARS && plain(detail))
            && self
                .activity
                .call
                .as_deref()
                .is_none_or(|call| call.len() <= CALL_LIMIT && plain(call))
    }
}

/// A tool call as the workspace reports it. `seq` only grows, so a reader can tell new calls from ones it has seen.
#[derive(Clone, Serialize)]
pub(crate) struct Call {
    seq: u64,
    tool: String,
    detail: Option<String>,
    finished: bool,
    failed: bool,
    #[serde(skip)]
    call: Option<String>,
    #[serde(skip)]
    at: Instant,
}

impl Call {
    pub(crate) fn seq(&self) -> u64 {
        self.seq
    }

    pub(crate) fn finished(&self) -> bool {
        self.finished
    }
}

#[derive(Default)]
pub(crate) struct Activity {
    sessions: HashMap<String, Vec<Call>>,
    last_seq: u64,
}

impl Activity {
    /// `now_ms` seeds `seq`, so numbers keep growing across a workspace restart.
    pub(crate) fn apply(&mut self, frame: Frame, now_ms: u64) {
        let Frame {
            key,
            activity: event,
        } = frame;
        let now = Instant::now();
        if event.phase == Phase::Started {
            if !self.sessions.contains_key(&key) && self.sessions.len() >= SESSIONS {
                let stale = self
                    .sessions
                    .iter()
                    .min_by_key(|(_, calls)| calls.last().map(|call| call.at))
                    .map(|(key, _)| key.clone());
                if let Some(stale) = stale {
                    self.sessions.remove(&stale);
                }
            }
            self.last_seq = now_ms.max(self.last_seq + 1);
            let calls = self.sessions.entry(key).or_default();
            calls.push(Call {
                seq: self.last_seq,
                tool: event.tool,
                detail: event.detail,
                finished: false,
                failed: false,
                call: event.call,
                at: now,
            });
            if calls.len() > CALLS {
                calls.remove(0);
            }
            return;
        }
        let Some(calls) = self.sessions.get_mut(&key) else {
            return;
        };
        // The same call id; without one, the oldest running call of that tool.
        let by_id = event.call.as_ref().and_then(|id| {
            calls
                .iter()
                .position(|call| !call.finished && call.call.as_ref() == Some(id))
        });
        let index = by_id.or_else(|| {
            calls
                .iter()
                .position(|call| !call.finished && call.tool == event.tool)
        });
        if let Some(index) = index {
            calls[index].finished = true;
            calls[index].failed = event.phase == Phase::Failed;
            calls[index].at = now;
        }
    }

    pub(crate) fn snapshot(&self, key: &str) -> Vec<Call> {
        self.sessions.get(key).map_or_else(Vec::new, |calls| {
            calls
                .iter()
                .filter(|call| call.at.elapsed() < KEEP)
                .cloned()
                .collect()
        })
    }

    pub(crate) fn is_empty(&self) -> bool {
        self.sessions.is_empty()
    }
}

/// `swarmhub-herdr tool-activity`: the hook itself.
pub fn hook() {
    report();
    // An empty decision: the agent's own permission flow continues unchanged.
    println!("{{}}");
}

fn report() {
    let Ok((journal, key)) = crate::agent::session() else {
        return;
    };
    let Ok(hook) = serde_json::from_reader::<_, Hook>(io::stdin().lock().take(HOOK_LIMIT)) else {
        return;
    };
    let phase = match hook.hook_event_name.as_str() {
        "PreToolUse" => Phase::Started,
        "PostToolUse" => Phase::Finished,
        "PostToolUseFailure" => Phase::Failed,
        _ => return,
    };
    let Some(tool) = hook.tool_name.filter(|tool| !tool.is_empty()) else {
        return;
    };
    send(
        &journal,
        key,
        phase,
        &tool,
        hook.tool_input.as_ref(),
        hook.tool_use_id,
    );
}

/// Tells the running workspace that a tool call of launch `key` started or ended. Gives up at once when the
/// workspace is not running. A program whose hooks have other names (Gemini CLI) reports through this too.
pub(crate) fn send(
    journal: &std::path::Path,
    key: String,
    phase: Phase,
    tool: &str,
    input: Option<&Value>,
    call: Option<String>,
) {
    let detail = if phase == Phase::Started {
        input.and_then(|input| detail(tool, input))
    } else {
        None
    };
    let frame = Frame {
        key,
        activity: Event {
            phase,
            tool: clean(tool, NAME_LIMIT),
            detail,
            call: call.filter(|id| id.len() <= CALL_LIMIT),
        },
    };
    if !frame.valid() {
        return;
    }
    let Ok(mut bytes) = serde_json::to_vec(&frame) else {
        return;
    };
    bytes.push(b'\n');
    let Ok(mut stream) = UnixStream::connect(journal.with_file_name("replies.sock")) else {
        return;
    };
    let _ = stream.set_write_timeout(Some(HOOK_WAIT));
    let _ = stream.write_all(&bytes);
}

/// What the call is about, in one line: the command, the file, the search or the address.
fn detail(tool: &str, input: &Value) -> Option<String> {
    let text = |key: &str| input.get(key).and_then(Value::as_str);
    let raw = match input.get("command") {
        Some(Value::String(command)) if tool == "apply_patch" => patched_files(command),
        Some(Value::String(command)) => command.clone(),
        Some(Value::Array(words)) => words
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" "),
        _ => [
            "file_path",
            "path",
            "dir_path",
            "notebook_path",
            "pattern",
            "query",
            "url",
            "description",
            "prompt",
        ]
        .iter()
        .find_map(|key| text(key))?
        .to_owned(),
    };
    let line = raw.lines().find(|line| !line.trim().is_empty())?;
    let line = clean(line, DETAIL_CHARS);
    (!line.is_empty()).then_some(line)
}

/// "src/a.rs" or "src/a.rs and 2 more", from a Codex patch's file headers.
fn patched_files(patch: &str) -> String {
    let files: Vec<&str> = patch
        .lines()
        .filter_map(|line| {
            ["*** Add File: ", "*** Update File: ", "*** Delete File: "]
                .iter()
                .find_map(|header| line.strip_prefix(header))
        })
        .collect();
    match files.as_slice() {
        [] => String::new(),
        [one] => (*one).to_owned(),
        [first, rest @ ..] => format!("{first} and {} more", rest.len()),
    }
}

fn clean(text: &str, limit: usize) -> String {
    let plain: String = text
        .chars()
        .map(|char| if char.is_control() { ' ' } else { char })
        .collect();
    let plain = plain.trim();
    if plain.chars().count() <= limit {
        return plain.to_owned();
    }
    let mut cut: String = plain.chars().take(limit - 1).collect();
    cut.push('…');
    cut
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const KEY: &str = "00112233445566778899aabbccddeeff";

    fn frame(phase: &str, tool: &str, call: Option<&str>) -> Frame {
        serde_json::from_value(
            json!({"key":KEY,"activity":{"phase":phase,"tool":tool,"detail":null,"call":call}}),
        )
        .unwrap()
    }

    #[test]
    fn describes_the_calls_claude_code_and_codex_report() {
        assert_eq!(
            detail(
                "Bash",
                &json!({"command":"\n  cargo test --locked\nsecond line"})
            )
            .as_deref(),
            Some("cargo test --locked")
        );
        assert_eq!(
            detail("shell", &json!({"command":["bash","-lc","ls"]})).as_deref(),
            Some("bash -lc ls")
        );
        assert_eq!(
            detail("Read", &json!({"file_path":"/tmp/a.txt","limit":5})).as_deref(),
            Some("/tmp/a.txt")
        );
        let patch =
            "*** Begin Patch\n*** Add File: a.txt\n+x\n*** Update File: b.txt\n*** End Patch";
        assert_eq!(
            detail("apply_patch", &json!({"command":patch})).as_deref(),
            Some("a.txt and 1 more")
        );
        assert_eq!(detail("Odd", &json!({"count":3})), None);
        let long = detail("Bash", &json!({"command":"x".repeat(500)})).unwrap();
        assert!(long.chars().count() == DETAIL_CHARS && long.ends_with('…'));
        assert_eq!(clean("a\u{1b}[0m\tb", 20), "a [0m b");
    }

    #[test]
    fn pairs_a_finish_with_its_start_and_keeps_the_order() {
        let mut activity = Activity::default();
        activity.apply(frame("started", "Bash", Some("one")), 1_000);
        activity.apply(frame("started", "Bash", Some("two")), 1_000);
        activity.apply(frame("started", "Read", None), 500);
        activity.apply(frame("finished", "Bash", Some("two")), 2_000);
        activity.apply(frame("failed", "Read", None), 2_000);
        // A finish for a launch or a call nobody started changes nothing.
        activity.apply(frame("finished", "Write", Some("none")), 2_000);
        let calls = activity.snapshot(KEY);
        let seen: Vec<_> = calls
            .iter()
            .map(|call| (call.seq, call.tool.as_str(), call.finished, call.failed))
            .collect();
        assert_eq!(
            seen,
            [
                (1_000, "Bash", false, false),
                (1_001, "Bash", true, false),
                (1_002, "Read", true, true)
            ]
        );
        assert!(
            activity
                .snapshot("ffffffffffffffffffffffffffffffff")
                .is_empty()
        );
    }

    #[test]
    fn keeps_only_the_newest_calls_and_refuses_odd_frames() {
        let mut activity = Activity::default();
        for index in 0..(CALLS as u64 + 5) {
            activity.apply(frame("started", "Bash", None), index);
        }
        let calls = activity.snapshot(KEY);
        assert_eq!(calls.len(), CALLS);
        assert_eq!(calls[0].seq, 6);
        assert!(frame("started", "Bash", None).valid());
        assert!(!frame("started", "", None).valid());
        assert!(!frame("started", "Ba\nsh", None).valid());
        let mut short = frame("started", "Bash", None);
        short.key = "abc".into();
        assert!(!short.valid());
        // A reply preview on the same socket is not an activity line.
        assert!(serde_json::from_value::<Frame>(json!({"key":KEY,"id":"x","text":"y"})).is_err());
    }
}
