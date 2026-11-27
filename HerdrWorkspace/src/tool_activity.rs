//! Which tools a running agent has started and finished, for the reply that is still being written.
//!
//! Claude Code and Codex both run `swarmhub-herdr tool-activity` from their PreToolUse and PostToolUse hooks and
//! describe the call on standard input (`tool_name`, `tool_input`, `tool_use_id`); Gemini CLI's hook
//! (`gemini_agent`) reports its BeforeTool and AfterTool the same way. The hook sends one line to the
//! workspace's live socket; the workspace keeps the newest calls of each launch in memory only. A Claude
//! prompt sent by the helper stop control also uses PreToolUse to restrict its tools to the selected helper run.

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
    prompt_id: Option<String>,
    agent_id: Option<String>,
    session_id: Option<String>,
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
    /// Codex includes the command even in its completion event. That lets a follower which joined
    /// mid-command report the result. Output and working directory are never copied to the frame.
    pub(crate) fn codex_command(key: &str, item: &Value, finished: bool) -> Option<Self> {
        if item["type"] != "commandExecution"
            || matches!(
                item["source"].as_str(),
                Some("userShell" | "unifiedExecInteraction")
            )
        {
            return None;
        }
        let id = item["id"].as_str().filter(|id| !id.is_empty())?;
        let command = detail("exec_command", item)?;
        let phase = if finished {
            match item["status"].as_str()? {
                "completed" if item["exitCode"].as_i64().is_none_or(|code| code == 0) => {
                    Phase::Finished
                }
                "completed" | "failed" | "declined" => Phase::Failed,
                _ => return None,
            }
        } else {
            Phase::Started
        };
        let frame = Self {
            key: key.to_owned(),
            activity: Event {
                phase,
                tool: "exec_command".to_owned(),
                detail: Some(command),
                call: Some(id.to_owned()),
            },
        };
        frame.valid().then_some(frame)
    }

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
    started_ms: Option<u64>,
    completed_ms: Option<u64>,
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
        let calls = self.sessions.get_mut(&key);
        let existing = calls.and_then(|calls| {
            if let Some(id) = &event.call {
                return calls.iter_mut().find(|call| call.call.as_ref() == Some(id));
            }
            // Hooks without identifiers finish the oldest running call of that tool.
            if event.phase != Phase::Started {
                return calls
                    .iter_mut()
                    .find(|call| !call.finished && call.tool == event.tool);
            }
            None
        });
        if let Some(call) = existing {
            if call.detail.is_none() {
                call.detail = event.detail;
            }
            if event.phase != Phase::Started {
                call.completed_ms.get_or_insert(now_ms);
                call.finished = true;
                call.failed |= event.phase == Phase::Failed;
                call.at = now;
            }
            return;
        }
        // A hook completion alone carries no command. A complete, identified stream item
        // can create a finished row even when the start preceded subscription.
        if event.phase != Phase::Started && (event.call.is_none() || event.detail.is_none()) {
            return;
        }
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
            finished: event.phase != Phase::Started,
            failed: event.phase == Phase::Failed,
            started_ms: (event.phase == Phase::Started).then_some(now_ms),
            completed_ms: (event.phase != Phase::Started).then_some(now_ms),
            call: event.call,
            at: now,
        });
        if calls.len() > CALLS {
            calls.remove(0);
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
    let mut decision = None;
    report(&mut decision);
    if let Some(reason) = decision {
        println!("{}", serde_json::json!({"hookSpecificOutput":{"hookEventName":"PreToolUse",
            "permissionDecision":"deny","permissionDecisionReason":reason}}));
    } else {
        println!("{{}}");
    }
}

fn report(decision: &mut Option<&'static str>) {
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
    if phase == Phase::Started && std::env::var_os(crate::agent::claude_control::ENABLED).is_some()
        && let Some(session) = &hook.session_id
        && crate::agent::claude_control::deny_tool(&journal, &key, session, hook.prompt_id.as_deref().unwrap_or(""), &tool, hook.tool_input.as_ref())
    {
        *decision = Some("This SwarmHub stop request applies only to the selected helper run.");
        return;
    }
    if let (Some(child), Some(session)) = (&hook.agent_id, &hook.session_id)
        && std::env::var_os("SWARMHUB_CLAUDE_CHILD_HOOKS").is_some()
    {
        if let Some(call) = &hook.tool_use_id {
            let label = hook
                .tool_input
                .as_ref()
                .and_then(|args| detail(&tool, args))
                .map_or_else(|| tool.clone(), |d| format!("{tool} {d}"));
            let state = match phase {
                Phase::Started => "Running",
                Phase::Finished => "Finished",
                Phase::Failed => "Failed",
            };
            crate::agent::claude_children::step(&journal, &key, session, child, call, label, state);
        }
        return;
    }
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
    fn stream_and_hook_delivery_for_one_id_share_one_row() {
        let mut activity = Activity::default();
        let item = json!({"type":"commandExecution","id":"exec-a","command":"sleep 4",
                          "status":"completed","exitCode":0,"aggregatedOutput":"unrelated output"});
        let native = |finished| Frame::codex_command(KEY, &item, finished).unwrap();
        activity.apply(frame("started", "Bash", Some("exec-a")), 1);
        activity.apply(native(false), 2);
        activity.apply(frame("started", "Bash", Some("exec-b")), 3);
        activity.apply(native(true), 4);
        activity.apply(frame("finished", "Bash", Some("exec-a")), 5);
        activity.apply(frame("finished", "Bash", Some("unknown")), 6);
        let calls = activity.snapshot(KEY);
        assert_eq!(calls.len(), 2);
        assert!(calls[0].finished && !calls[0].failed && !calls[1].finished);
        assert_eq!(calls[0].seq, 1);
        assert_eq!((calls[0].started_ms, calls[0].completed_ms), (Some(1), Some(4)));
        assert_eq!(calls[0].detail.as_deref(), Some("sleep 4"));
    }

    #[test]
    fn a_complete_item_can_arrive_first_and_a_late_start_cannot_reopen_it() {
        let mut activity = Activity::default();
        let mut item = json!({"type":"commandExecution","id":"exec-a","command":"false","source":"agent",
                              "status":"completed","exitCode":1,"aggregatedOutput":"private output"});
        activity.apply(Frame::codex_command(KEY, &item, true).unwrap(), 5);
        activity.apply(Frame::codex_command(KEY, &item, false).unwrap(), 6);
        let calls = activity.snapshot(KEY);
        assert_eq!(calls.len(), 1);
        assert!(calls[0].finished && calls[0].failed);
        assert_eq!((calls[0].started_ms, calls[0].completed_ms), (None, Some(5)));
        assert_eq!(calls[0].detail.as_deref(), Some("false"));
        for source in ["userShell", "unifiedExecInteraction"] {
            item["source"] = json!(source);
            assert!(Frame::codex_command(KEY, &item, true).is_none());
        }
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
