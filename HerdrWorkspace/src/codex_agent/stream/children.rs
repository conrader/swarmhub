//! Codex child threads belong to a private app-server launch. They have their own transcript,
//! but no Core terminal. Keep their content out of the main conversation's reply stream.
use super::{Follower, Value, json};
use rusqlite::params;
use std::{
    collections::{HashMap, HashSet},
    path::Path,
    time::Duration,
};
use tokio::time::Instant;

#[derive(Default)]
pub(super) struct Children {
    tracked: HashMap<String, Child>,
    roots: HashSet<String>,
    reads: HashMap<u64, (String, Instant)>,
    pub(super) snapshot: Option<Snapshot>,
}

struct Child {
    parent: String,
    assignment: String,
    due: Option<Instant>,
    failures: u8,
}

pub(in crate::codex_agent) struct Snapshot {
    id: String,
    summary: Value,
    transcript: String,
}

/// Do SQLite work off the parent's reply stream. If storage is busy, keep the latest snapshot
/// of each changed child rather than accumulating copies of its output.
pub(super) struct Writer {
    pending: std::sync::Arc<std::sync::Mutex<HashMap<String, Snapshot>>>,
    wake: tokio::sync::mpsc::Sender<()>,
}

impl Writer {
    pub(super) fn new(journal: std::path::PathBuf, key: String) -> Self {
        let (wake, mut work) = tokio::sync::mpsc::channel(1);
        let pending =
            std::sync::Arc::new(std::sync::Mutex::new(HashMap::<String, Snapshot>::new()));
        let queue = pending.clone();
        tokio::task::spawn_blocking(move || {
            while work.blocking_recv().is_some() {
                let updates = std::mem::take(&mut *queue.lock().unwrap());
                for snapshot in updates.into_values() {
                    if snapshot.save(&journal, &key).is_err() {
                        super::note("Could not save a Codex child session.");
                    }
                }
            }
        });
        Self { pending, wake }
    }

    pub(super) fn put(&self, snapshot: Snapshot) {
        self.pending
            .lock()
            .unwrap()
            .insert(snapshot.id.clone(), snapshot);
        let _ = self.wake.try_send(());
    }
}

fn valid(id: &str) -> bool {
    id.len() == 36
        && id.bytes().enumerate().all(|(i, c)| {
            if matches!(i, 8 | 13 | 18 | 23) {
                c == b'-'
            } else {
                c.is_ascii_hexdigit()
            }
        })
}

pub(in crate::codex_agent) fn origin(thread: &Value) -> Option<&str> {
    thread["source"]["subAgent"]["thread_spawn"]["parent_thread_id"].as_str()
}

impl Children {
    fn track(&mut self, id: &str, parent: &str) {
        if !valid(id) || !valid(parent) || id == parent {
            return;
        }
        self.tracked.entry(id.into()).or_insert_with(|| Child {
            parent: parent.into(),
            assignment: String::new(),
            due: Some(Instant::now()),
            failures: 0,
        });
    }

    pub(super) fn observe(&mut self, method: &str, data: &Value) {
        if method == "thread/started" {
            self.see_thread(&data["thread"]);
        } else if let Some(sender) = data["threadId"].as_str() {
            let item = &data["item"];
            if matches!(method, "item/started" | "item/completed")
                && item["type"] == "subAgentActivity"
                && let Some(id) = item["agentThreadId"].as_str()
                && id != sender
            {
                self.track(id, sender);
                if let Some(child) = self.tracked.get_mut(id) {
                    child.due = Some(Instant::now());
                    child.failures = 0;
                }
            }
            if method == "item/completed"
                && item["type"] == "collabAgentToolCall"
                && item["tool"] == "spawnAgent"
                && item["senderThreadId"] == sender
            {
                for id in item["receiverThreadIds"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(Value::as_str)
                {
                    self.track(id, sender);
                    if let Some(child) = self.tracked.get_mut(id)
                        && child.parent == sender
                        && let Some(prompt) = item["prompt"].as_str()
                    {
                        child.assignment = clipped(prompt, 8000).into();
                    }
                }
            }
            if matches!(
                method,
                "thread/status/changed" | "turn/completed" | "turn/started" | "thread/closed"
            ) && let Some(child) = self.tracked.get_mut(sender)
            {
                child.failures = 0;
                child.due = Some(Instant::now());
            }
        }
    }

    pub(super) fn see_thread(&mut self, thread: &Value) {
        let Some(id) = thread["id"].as_str().filter(|id| valid(id)) else {
            return;
        };
        if let Some(parent) = origin(thread) {
            self.track(id, parent);
            // Activity can be relayed to an ancestor. The child's own metadata names its direct parent.
            if valid(parent) && id != parent
                && let Some(child) = self.tracked.get_mut(id)
                && child.parent != parent
            {
                child.parent = parent.to_owned();
                child.assignment.clear();
                child.due = Some(Instant::now());
            }
        } else if !super::other_conversation(thread) {
            self.roots.insert(id.into());
        }
    }

    // Thread notifications and resume replies can arrive child first. Read only branches connected
    // to a root that this private app server has actually opened.
    fn owns<'a>(&'a self, mut id: &'a str) -> bool {
        for _ in 0..=self.tracked.len() {
            if self.roots.contains(id) {
                return true;
            }
            let Some(child) = self.tracked.get(id) else {
                return false;
            };
            id = &child.parent;
        }
        false
    }

    pub(super) fn answer(&mut self, request: u64, result: Option<&Value>) -> bool {
        let Some((id, _)) = self.reads.remove(&request) else {
            return false;
        };
        let Some(child) = self.tracked.get_mut(&id) else {
            return true;
        };
        child.failures = child.failures.saturating_add(1);
        child.due = (child.failures < 6).then(|| Instant::now() + Duration::from_secs(2));
        if let Some(thread) = result.map(|value| &value["thread"])
            && thread["id"] == id
            && let Some(parent) = origin(thread).filter(|parent| valid(parent) && *parent != id)
        {
            self.see_thread(thread);
            if self.owns(&id) {
                let child = self.tracked.get_mut(&id).unwrap();
                child.failures = 0;
                let snapshot = Snapshot::read(&id, parent, &child.assignment, thread);
                child.due = (snapshot.summary["state"] == "working")
                    .then(|| Instant::now() + Duration::from_secs(2));
                self.snapshot = Some(snapshot);
            }
        }
        true
    }
}

impl Follower {
    pub(super) fn read_children(&mut self) -> Vec<Value> {
        let now = Instant::now();
        let expired: Vec<_> = self
            .children
            .reads
            .iter()
            .filter(|(_, (_, at))| now.duration_since(*at) >= Duration::from_secs(12))
            .map(|(k, _)| *k)
            .collect();
        for key in expired {
            self.children.answer(key, None);
        }
        let ids: Vec<_> = self
            .children
            .tracked
            .iter()
            .filter(|(id, child)| {
                child.due.is_some_and(|time| time <= now)
                    && self.children.owns(id)
                    && !self
                        .children
                        .reads
                        .values()
                        .any(|(pending, _)| pending == *id)
            })
            .map(|(id, _)| id.clone())
            .take(8usize.saturating_sub(self.children.reads.len()))
            .collect();
        ids.into_iter()
            .map(|id| {
                self.children.tracked.get_mut(&id).unwrap().due = None;
                let (key, request) =
                    self.request("thread/read", json!({"threadId":id,"includeTurns":true}));
                self.children.reads.insert(key, (id, now));
                request
            })
            .collect()
    }
}

fn clipped(text: &str, limit: usize) -> &str {
    let end = text.floor_char_boundary(limit.min(text.len()));
    &text[..end]
}

/// Tool activity comes from typed items in the child's latest turn. Assistant text and
/// command output can look like a transcript header and must never create extra steps.
fn step(item: &Value) -> Option<Value> {
    let kind = item["type"].as_str()?;
    let label = match kind {
        "commandExecution" => item["command"].as_str().unwrap_or("Run command"),
        "fileChange" => "Edit files",
        "mcpToolCall" | "dynamicToolCall" => item["tool"].as_str().unwrap_or("Tool call"),
        "collabAgentToolCall" => item["tool"].as_str().unwrap_or("Agent task"),
        "webSearch" => item["query"].as_str().unwrap_or("Web search"),
        "imageView" => item["path"].as_str().unwrap_or("View image"),
        "imageGeneration" => "Generate image",
        _ => return None,
    };
    Some(json!({"text":clipped(label,512),"state":item["status"].as_str()}))
}

impl Snapshot {
    pub(in crate::codex_agent) fn read(id: &str, parent: &str, assignment: &str, thread: &Value) -> Self {
        let turns = thread["turns"]
            .as_array()
            .map(Vec::as_slice)
            .unwrap_or_default();
        // A fork may include earlier turns copied from its parent. Codex creates UUIDv7 turn
        // and thread IDs in time order. Keep only turns created for this child or later.
        let own_turns: Vec<_> = turns
            .iter()
            .filter(|turn| {
                let Some(turn_id) = turn["id"].as_str() else {
                    return false;
                };
                valid(turn_id) && turn_id >= id
            })
            .collect();
        let last = own_turns.last().copied();
        let mut task = assignment;
        let mut answer = "";
        let mut lines = Vec::new();
        let mut bytes = 0;
        for (i, turn) in own_turns.iter().rev().enumerate() {
            let items = turn["items"]
                .as_array()
                .map(Vec::as_slice)
                .unwrap_or_default();
            if i == 0 {
                answer = super::final_from_items(items).unwrap_or_default();
                task = items
                    .iter()
                    .rev()
                    .filter(|i| i["type"] == "userMessage")
                    .find_map(|i| {
                        i["content"]
                            .as_array()?
                            .iter()
                            .find_map(|c| c["text"].as_str())
                    })
                    .unwrap_or(assignment);
            }
            for item in items.iter().rev() {
                let kind = item["type"].as_str().unwrap_or_default();
                let (who, text) = match kind {
                    "commandExecution" => ("$", item["command"].as_str()),
                    "agentMessage" => ("Codex", item["text"].as_str()),
                    "userMessage" => (
                        "Task",
                        item["content"]
                            .as_array()
                            .and_then(|cs| cs.iter().find_map(|c| c["text"].as_str())),
                    ),
                    _ => continue,
                };
                if let Some(text) = text.filter(|text| !text.is_empty()) {
                    let mut line = format!("{who} {}", clipped(text, 8000));
                    if kind == "commandExecution"
                        && let Some(output) =
                            item["aggregatedOutput"].as_str().filter(|s| !s.is_empty())
                    {
                        line.push('\n');
                        line.push_str(clipped(output, 8000));
                    }
                    bytes += line.len();
                    lines.push(line);
                }
                if bytes >= 48_000 {
                    break;
                }
            }
            if bytes >= 48_000 {
                break;
            }
        }
        lines.reverse();
        if lines.is_empty() && !task.is_empty() {
            lines.push(format!("Task {task}"));
        }
        let state = match last.and_then(|t| t["status"].as_str()) {
            _ if thread["status"]["type"] == "active" => "working",
            Some("failed") => "error",
            Some("interrupted") => "stopped",
            Some("completed") if !answer.is_empty() => "answered",
            Some("completed") => "finished",
            _ => "working",
        };
        let active_turn = last.filter(|turn| turn["status"] == "inProgress").and_then(|turn| turn["id"].as_str());
        let latest_reply = if state == "working" {
            last.and_then(|turn| turn["items"].as_array())
                .and_then(|items| items.iter().rev()
                    .filter(|item| item["type"] == "agentMessage")
                    .find_map(|item| item["text"].as_str().filter(|text| !text.trim().is_empty())))
                .unwrap_or(answer)
        } else {
            answer
        };
        let terminal = last.and_then(|turn| turn["items"].as_array()).and_then(|items| {
            items.iter().rev().filter(|item| item["type"] == "commandExecution").find_map(|item| {
                crate::agent::child_output::ChildCommandOutput::new(item["command"].as_str()?, item["aggregatedOutput"].as_str()?)
            })
        });
        let mut steps: Vec<_> = last.and_then(|turn| turn["items"].as_array()).into_iter().flatten()
            .rev().filter_map(step).take(64).collect();
        steps.reverse();
        let summary = json!({"id":id,"active_turn":active_turn,"parent":parent,"name":thread["agentNickname"].as_str().unwrap_or("Codex agent"),
            "model":thread["model"],"created_ms":thread["createdAt"].as_i64().unwrap_or_default().saturating_mul(1000),
            "completed_ms":last.and_then(|t| t["completedAt"].as_i64()).map(|s| s.saturating_mul(1000)),
            "details":{"task":clipped(task,8000),"reply":clipped(latest_reply,24000),"steps":steps,"terminal":terminal},
            "state":state,"task":clipped(task,300),"reply":clipped(answer,300)});
        Snapshot {
            id: id.into(),
            summary,
            transcript: lines.join("\n\n"),
        }
    }

    // A concurrent live snapshot always takes precedence over a historical read.
    pub(in crate::codex_agent) fn restore(self, db: &rusqlite::Connection, launch: i64) -> rusqlite::Result<usize> {
        db.execute("INSERT INTO codex_children(launch,thread,summary,transcript)
                    VALUES(?1,?2,?3,?4) ON CONFLICT(launch,thread) DO NOTHING",
            params![launch,self.id,self.summary.to_string(),self.transcript])
    }

    pub(super) fn save(self, journal: &Path, key: &str) -> rusqlite::Result<()> {
        let db = crate::history::connection(journal)?;
        db.execute("INSERT INTO codex_children(launch,thread,summary,transcript)
            SELECT id,?2,?3,?4 FROM journal WHERE launch_key=?1
            ON CONFLICT(launch,thread) DO UPDATE SET summary=excluded.summary,transcript=excluded.transcript,revision=revision+1
            WHERE summary!=excluded.summary OR transcript!=excluded.transcript",
            params![key,self.id,self.summary.to_string(),self.transcript])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    const ROOT: &str = "01a217c2-0e2d-7da2-8799-0bd89a08064d";
    const CHILD: &str = "01a217c2-0e83-78f1-962e-abaf6f88c063";
    const TURN: &str = "01a217c2-0ea1-78f1-962e-abaf6f88c063";

    #[test]
    fn private_child_can_arrive_before_owner_but_unrelated_threads_are_never_read() {
        let mut f = Follower::default();
        f.children.track(CHILD, ROOT);
        assert!(f.read_children().is_empty());
        f.children.see_thread(&json!({"id":ROOT,"ephemeral":true}));
        assert!(f.read_children().is_empty());
        f.children.see_thread(&json!({"id":ROOT,"source":"cli"}));
        let reads = f.read_children();
        assert_eq!(reads.len(), 1);
        let id = reads[0]["id"].as_u64().unwrap();
        assert!(f.read_children().is_empty());
        assert!(f.children.answer(id,Some(&json!({"thread":{"id":CHILD,"source":{"subAgent":{"thread_spawn":{"parent_thread_id":"other"}}}}}))));
        assert!(f.children.snapshot.is_none());
    }

    #[test]
    fn parent_activity_discovers_a_worker_without_a_spawn_tool_call() {
        let mut f = Follower::default();
        f.children.see_thread(&json!({"id":ROOT,"source":"cli"}));
        let activity = json!({"threadId":ROOT,"item":{"type":"subAgentActivity","kind":"started","agentThreadId":CHILD}});
        f.children.observe("item/started", &activity);
        let read = f.read_children().pop().unwrap();
        assert_eq!(read["params"]["threadId"], CHILD);
        let thread = json!({"id":CHILD,"source":{"subAgent":{"thread_spawn":{"parent_thread_id":ROOT}}},
            "turns":[{"id":TURN,"status":"completed","items":[]}]});
        assert!(f.children.answer(read["id"].as_u64().unwrap(), Some(&json!({"thread":thread}))));
        assert_eq!(f.children.snapshot.take().unwrap().id, CHILD);
        f.children.observe("item/completed", &activity);
        assert_eq!(f.read_children().len(), 1);
    }

    #[test]
    fn only_the_current_child_turn_can_be_interrupted() {
        let mut thread = json!({"turns":[{"id":ROOT,"status":"inProgress"}]});
        assert!(Snapshot::read(CHILD, ROOT, "", &thread).summary["active_turn"].is_null());
        thread["turns"].as_array_mut().unwrap().push(json!({"id":TURN,"status":"inProgress"}));
        assert_eq!(Snapshot::read(CHILD, ROOT, "", &thread).summary["active_turn"], TURN);
        thread["turns"][1]["status"] = "interrupted".into();
        let saved = Snapshot::read(CHILD, ROOT, "", &thread);
        assert!(saved.summary["active_turn"].is_null());
        assert_eq!(saved.summary["state"], "stopped");
    }

    #[test]
    fn working_child_shows_commentary_without_marking_the_task_answered() {
        let thread = json!({"status":{"type":"active"},"turns":[{"id":TURN,"status":"inProgress","items":[
            {"type":"agentMessage","phase":"commentary","text":"Checking the failing test."},
            {"type":"commandExecution","command":"cargo test","status":"inProgress"},
            {"type":"reasoning","text":"private reasoning"}]}]});
        let snapshot = Snapshot::read(CHILD, ROOT, "Check tests", &thread);
        assert_eq!(snapshot.summary["details"]["reply"], "Checking the failing test.");
        assert_eq!(snapshot.summary["state"], "working");
        assert_eq!(snapshot.summary["reply"], "");
    }

    #[test]
    fn fork_keeps_the_childs_commands_output_and_answer_out_of_the_parent_history() {
        let thread = json!({"agentNickname":"Scout","turns":[
            {"id":ROOT,"items":[{"type":"agentMessage","text":"parent only"}]},
            {"id":TURN,"status":"completed","items":[
                {"type":"userMessage","content":[{"type":"text","text":"Check tests"}]},
                {"type":"commandExecution","command":"cargo test","aggregatedOutput":"1 passed"},
                {"type":"agentMessage","text":"All green","phase":"final_answer"}]}]});
        let snapshot = Snapshot::read(CHILD, ROOT, "", &thread);
        assert_eq!(snapshot.summary["state"], "answered");
        assert_eq!(snapshot.summary["task"], "Check tests");
        assert_eq!(snapshot.summary["reply"], "All green");
        assert_eq!(snapshot.summary["details"], json!({"task":"Check tests","reply":"All green",
            "steps":[{"text":"cargo test","state":null}],"terminal":{"command":"cargo test","output":"1 passed"}}));
        assert_eq!(
            snapshot.transcript,
            "Task Check tests\n\n$ cargo test\n1 passed\n\nCodex All green"
        );
    }
}
