//! One agent session as a stream of Server-Sent Events, so a client follows a turn without polling.
//!
//! `GET /api/agents/{address}/{created_ms}/events` answers with a `snapshot` and then sends what changes: saved
//! rows (`history`), the reply so far (`draft`, `draft_append`), tool calls (`tool`), the agent's state and status
//! (`agent`) and its running helpers (`helpers`). Everything is read from the same places as the polling routes
//! (`/api/history/…`, `…/draft`, `/api/workspace`, `…/helpers`), so both show the same ids and the same `seq`.
//!
//! A stream holds no queue of changes. It is woken when something may have changed, reads the current state and
//! sends the difference from what it sent before. A slow reader therefore gets fewer, larger updates, the hooks
//! that report text and tool calls never wait for a reader, and a stream's memory stays within what it last sent.

use crate::{
    AgentView, ApiError, Workspace,
    core::{self, Failure},
    helpers,
    history::{Page, StoreError},
    live_reply::{self, Draft},
    tool_activity::Call,
};
use axum::{
    Router,
    extract::{Path, Query, State},
    response::{
        IntoResponse, Response,
        sse::{Event, KeepAlive, Sse},
    },
    routing::get,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::BTreeMap,
    convert::Infallible,
    hash::{DefaultHasher, Hash, Hasher},
    sync::Arc,
    time::Duration,
};
use tokio::{
    sync::{Notify, Semaphore, SemaphorePermit, mpsc},
    task::JoinHandle,
    time::{MissedTickBehavior, interval, sleep, timeout},
};

/// Open streams, for all agents together. Each holds one task, two subscriptions to Core and what it last sent.
const STREAMS: usize = 48;
static OPEN: Semaphore = Semaphore::const_new(STREAMS);
/// Events waiting for a reader. A full queue makes the stream wait, not grow.
const QUEUE: usize = 16;
/// A reader that takes nothing for this long is gone.
const STALLED: Duration = Duration::from_secs(60);
const HEARTBEAT: Duration = Duration::from_secs(15);
/// Everything is read again this often, in case a wake-up was missed or the reply so far went stale.
const RECHECK: Duration = Duration::from_secs(5);
/// The same, for a Core without `events.subscribe`: the agent's status is then only learned by asking.
const RECHECK_WITHOUT_CORE_EVENTS: Duration = Duration::from_secs(1);
/// A change in Core often comes as several events; read once for all of them.
const SETTLE: Duration = Duration::from_millis(50);
/// After the agent's program ended, its hook may still save the last reply.
const LAST_REPLY: Duration = Duration::from_secs(2);
/// Pages of 30 rows read to reach `after`, and to catch up when many rows were written at once.
const PAGES: usize = 8;

pub fn routes() -> Router<Workspace> {
    Router::new().route("/api/agents/{id}/{created}/events", get(follow))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Resume {
    /// The newest saved row the reader already has. Only rows after it are sent.
    after: Option<i64>,
}

async fn follow(
    State(w): State<Workspace>,
    Path((address, created)): Path<(String, u64)>,
    Query(resume): Query<Resume>,
) -> Result<Response, ApiError> {
    let permit = OPEN.try_acquire().map_err(|_| {
        ApiError::TooMany("Too many live connections are open. Close one, or read the session with the history routes.")
    })?;
    let hello = w.core.identify().await?;
    let agent = w.core.agent(&address, created).await?;
    // The same bookkeeping `/api/workspace` does, for a reader that only follows this stream.
    w.history.recover_launch(&hello.core.id, &agent)?;
    w.history.link_profile(&hello.core.id, &agent)?;
    let (queue, events) = mpsc::channel(QUEUE);
    let stream = Stream {
        core_events: hello.supports("events.subscribe"),
        core_id: hello.core.id,
        address,
        created,
        key: None,
        journal: None,
        rows: BTreeMap::new(),
        draft: None,
        tools: Vec::new(),
        agent: Value::Null,
        helpers: Value::Null,
        helper_failures: 0,
        codex_child_revision: 0,
        queue,
        w,
    };
    tokio::spawn(stream.run(resume.after, agent, permit));
    let events = futures_util::stream::unfold(events, |mut events| async move {
        events
            .recv()
            .await
            .map(|event| (Ok::<_, Infallible>(event), events))
    });
    Ok(Sse::new(events)
        .keep_alive(KeepAlive::new().interval(HEARTBEAT).text("heartbeat"))
        .into_response())
}

/// The reader is gone, or the session is: either way the stream is over.
struct Over;

/// A saved row as it goes to the reader, with a hash to tell later whether it changed.
struct Row {
    id: i64,
    hash: u64,
    text: String,
}

#[derive(Serialize)]
struct Snapshot<'a> {
    core: &'a str,
    address: &'a str,
    created_ms: u64,
    agent: &'a Value,
    /// Saved rows after `after`, oldest first; `before` is set when older ones were left out.
    history: Page,
    draft: &'a Option<Draft>,
    tools: &'a [Call],
    /// `null` until the session's first task is recorded.
    helpers: &'a Value,
}

struct Stream {
    w: Workspace,
    core_events: bool,
    core_id: String,
    address: String,
    created: u64,
    /// The session's launch, which the reply so far, the tool calls and the helpers are kept under.
    key: Option<String>,
    /// The journal's signature when the rows were last read.
    journal: Option<(i64, u64)>,
    /// The newest saved rows and a hash of each as it was sent, to tell a new or changed row from a known one.
    rows: BTreeMap<i64, u64>,
    draft: Option<Draft>,
    /// `seq` and whether its end was sent.
    tools: Vec<(u64, bool)>,
    agent: Value,
    helpers: Value,
    helper_failures: u8,
    codex_child_revision: i64,
    queue: mpsc::Sender<Event>,
}

/// Core's events for this agent and for its helpers, ended with the stream.
struct CoreEvents(JoinHandle<()>, JoinHandle<()>);

impl Drop for CoreEvents {
    fn drop(&mut self) {
        self.0.abort();
        self.1.abort();
    }
}

fn follow_core(core: core::Core, filter: Value, changed: Arc<Notify>) -> JoinHandle<()> {
    tokio::spawn(async move {
        loop {
            core.follow(filter.clone(), &changed).await;
            // Core went away or is busy. It announces nothing meanwhile; the stream's own rereading covers that.
            sleep(RECHECK).await;
        }
    })
}

fn hashed(text: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

fn event(name: &str, data: &impl Serialize) -> Event {
    // serde_json escapes every line break, which is all an event's data must not contain.
    Event::default()
        .event(name)
        .data(serde_json::to_string(data).unwrap_or_else(|_| "null".into()))
}

/// What to send for the reply so far: nothing, the added text with where it starts, or the whole text again.
fn draft_change(sent: &Option<Draft>, now: &Option<Draft>) -> Option<(&'static str, Value)> {
    match (sent, now) {
        (None, None) => None,
        (Some(sent), Some(now)) if sent == now => None,
        (Some(sent), Some(now))
            if sent.id == now.id
                && now.text.len() > sent.text.len()
                && now.text.starts_with(&sent.text) =>
        {
            // Both are whole strings, so the cut never falls inside a character.
            Some((
                "draft_append",
                json!({"id":now.id,"offset":sent.text.len(),"text":now.text[sent.text.len()..]}),
            ))
        }
        (_, now) => Some(("draft", json!(now))),
    }
}

impl Stream {
    async fn run(
        mut self,
        after: Option<i64>,
        agent: core::Terminal,
        _permit: SemaphorePermit<'static>,
    ) {
        let _ = self.follow(after, agent).await;
    }

    async fn send(&self, event: Event) -> Result<(), Over> {
        match timeout(STALLED, self.queue.send(event)).await {
            Ok(Ok(())) => Ok(()),
            _ => Err(Over),
        }
    }

    async fn follow(&mut self, after: Option<i64>, agent: core::Terminal) -> Result<(), Over> {
        // Listen before the first reading, so nothing falls between the snapshot and the first event.
        let mut live = self.w.drafts.changes();
        let mut journal = self.w.history.changes();
        let (own, children) = (Arc::new(Notify::new()), Arc::new(Notify::new()));
        let _core_events = self.core_events.then(|| {
            CoreEvents(
                follow_core(
                    self.w.core.clone(),
                    json!({"terminal":self.address}),
                    own.clone(),
                ),
                follow_core(
                    self.w.core.clone(),
                    json!({"children_of":self.address}),
                    children.clone(),
                ),
            )
        });
        let mut recheck = interval(if self.core_events {
            RECHECK
        } else {
            RECHECK_WITHOUT_CORE_EVENTS
        });
        recheck.set_missed_tick_behavior(MissedTickBehavior::Delay);
        recheck.tick().await;

        let running = agent.state == "live";
        self.snapshot(after, &agent).await?;
        drop(agent);
        if !running {
            return self.end("ended").await;
        }
        loop {
            let (mut agent_changed, mut helpers_changed) = (false, false);
            tokio::select! {
                () = self.queue.closed() => return Err(Over),
                changed = live.changed() => if changed.is_err() { return Err(Over) },
                changed = journal.changed() => {
                    if changed.is_err() { return Err(Over); }
                    if let Some(key) = self.key.as_ref() {
                        let revision = self.w.history.db().ok().and_then(|db| db.query_row(
                            "SELECT coalesce(sum(c.revision),0) FROM native_children c JOIN journal p ON p.id=c.launch WHERE p.launch_key=?1",
                            [key], |r| r.get::<_,i64>(0)).ok());
                        if let Some(revision) = revision {
                            helpers_changed = self.codex_child_revision != revision;
                            self.codex_child_revision = revision;
                        }
                    }
                },
                () = own.notified() => { sleep(SETTLE).await; agent_changed = true }
                () = children.notified() => { sleep(SETTLE).await; helpers_changed = true }
                _ = recheck.tick() => { agent_changed = true; helpers_changed = self.helper_failures > 0 || !self.no_helpers() }
            }
            // Saved rows go first: the hook saves the reply before the reply so far is cleared, and a reader
            // must not see the text vanish before the row that replaces it.
            helpers_changed |= self.saved_rows().await?;
            self.live().await?;
            if agent_changed && !self.agent().await? {
                sleep(LAST_REPLY).await;
                self.saved_rows().await?;
                self.live().await?;
                return self.end("ended").await;
            }
            if helpers_changed {
                self.helpers().await?;
            }
        }
    }

    async fn end(&self, reason: &str) -> Result<(), Over> {
        self.send(event("end", &json!({"reason":reason}))).await?;
        Err(Over)
    }

    fn no_helpers(&self) -> bool {
        self.helpers["helpers"]
            .as_array()
            .is_some_and(|helpers| helpers.is_empty())
    }

    fn find_launch(&mut self) -> Result<(), StoreError> {
        if self.key.is_none() {
            self.key = live_reply::launch_key(
                &self.w.history,
                &self.core_id,
                &self.address,
                self.created,
            )?;
        }
        Ok(())
    }

    fn view(&self, agent: &core::Terminal) -> Result<Value, StoreError> {
        let parent = helpers::parents(&self.w.history, &self.core_id, std::slice::from_ref(agent))?
            .into_values()
            .next()
            .flatten();
        serde_json::to_value(AgentView::new(&self.w, agent, parent)).map_err(|_| StoreError)
    }

    async fn listing(&self) -> Option<Value> {
        let parent = helpers::ParentRef {
            address: self.address.clone(),
            created_ms: self.created,
        };
        let listing = helpers::listing(&self.w, self.core_id.clone(), self.key.as_deref()?, parent, true)
            .await
            .ok()?;
        serde_json::to_value(listing).ok()
    }

    /// The session's newest rows as they are sent: one page, or with `after` every page back to that row.
    /// The page that is returned holds only the rows after `after`.
    fn rows_after(&self, after: Option<i64>) -> Result<(Page, Vec<Row>), StoreError> {
        let (mut items, mut before) = (Vec::new(), None);
        for _ in 0..PAGES {
            let mut page = self
                .w
                .history
                .page(&self.core_id, &self.address, self.created, before)?
                .with_markup();
            before = page.before;
            page.items.append(&mut items);
            items = page.items;
            let reached =
                after.is_none_or(|after| items.first().is_none_or(|item| item.id() <= after));
            if reached || before.is_none() {
                break;
            }
        }
        let mut rows = Vec::with_capacity(items.len());
        for item in &items {
            let text = serde_json::to_string(item).map_err(|_| StoreError)?;
            rows.push(Row {
                id: item.id(),
                hash: hashed(&text),
                text,
            });
        }
        if let Some(after) = after {
            let known = items.iter().take_while(|item| item.id() <= after).count();
            // With `after` reached, the reader has every older row: nothing is left out.
            if known > 0 {
                before = None;
            }
            items.drain(..known);
        }
        Ok((Page { items, before }, rows))
    }

    async fn snapshot(&mut self, after: Option<i64>, agent: &core::Terminal) -> Result<(), Over> {
        self.find_launch().map_err(|_| Over)?;
        self.journal = self.w.history.signature().ok();
        let (history, sent) = self.rows_after(after).map_err(|_| Over)?;
        self.rows = sent.into_iter().map(|row| (row.id, row.hash)).collect();
        let preview = match &self.key {
            Some(key) => self.w.drafts.preview(key).map_err(|_| Over)?,
            None => live_reply::Preview::default(),
        };
        self.tools = preview
            .tools
            .iter()
            .map(|call| (call.seq(), call.finished()))
            .collect();
        self.draft = preview.draft;
        self.agent = self.view(agent).map_err(|_| Over)?;
        self.helpers = self.listing().await.unwrap_or(Value::Null);
        self.send(event(
            "snapshot",
            &Snapshot {
                core: &self.core_id,
                address: &self.address,
                created_ms: self.created,
                agent: &self.agent,
                history,
                draft: &self.draft,
                tools: &preview.tools,
                helpers: &self.helpers,
            },
        ))
        .await
    }

    /// Sends the rows that are new or changed since they were last sent. Says whether the journal had moved.
    async fn saved_rows(&mut self) -> Result<bool, Over> {
        let Ok(signature) = self.w.history.signature() else {
            return Ok(false);
        };
        if self.journal == Some(signature) {
            return Ok(false);
        }
        if self.find_launch().is_err() {
            return Ok(false);
        }
        // Rows up to the oldest one still remembered may have changed (a task's delivery state, a reaction).
        let oldest = self.rows.keys().next().map_or(0, |id| id - 1);
        let Ok((_, rows)) = self.rows_after(Some(oldest)) else {
            return Ok(false);
        };
        self.journal = Some(signature);
        for row in &rows {
            if self.rows.get(&row.id) != Some(&row.hash) {
                self.send(Event::default().event("history").data(&row.text))
                    .await?;
            }
        }
        // Remember the newest page only; an older row's later change is read with the history route.
        let keep = rows.len().saturating_sub(30);
        self.rows = rows
            .into_iter()
            .skip(keep)
            .map(|row| (row.id, row.hash))
            .collect();
        Ok(true)
    }

    /// Sends what changed in the reply so far and in the tool calls.
    async fn live(&mut self) -> Result<(), Over> {
        let Some(key) = &self.key else {
            return Ok(());
        };
        let Ok(preview) = self.w.drafts.preview(key) else {
            return Ok(());
        };
        for call in &preview.tools {
            let known = self.tools.iter().find(|(seq, _)| *seq == call.seq());
            if known.is_none_or(|(_, finished)| *finished != call.finished()) {
                self.send(event("tool", call)).await?;
            }
        }
        self.tools = preview
            .tools
            .iter()
            .map(|call| (call.seq(), call.finished()))
            .collect();
        if let Some((name, change)) = draft_change(&self.draft, &preview.draft) {
            self.send(event(name, &change)).await?;
            self.draft = preview.draft;
        }
        Ok(())
    }

    /// Sends the agent when its state or status changed. `false` once its program has ended.
    async fn agent(&mut self) -> Result<bool, Over> {
        let agent = match self.w.core.agent(&self.address, self.created).await {
            Ok(agent) => agent,
            Err(Failure::Missing) => return self.end("gone").await.map(|()| false),
            Err(Failure::Rejected(kind, _)) if kind == "not_found" => {
                return self.end("gone").await.map(|()| false);
            }
            // Core is restarting or busy: the agent may be fine, so ask again later.
            Err(_) => return Ok(true),
        };
        if let Ok(view) = self.view(&agent)
            && view != self.agent
        {
            self.send(event("agent", &view)).await?;
            self.agent = view;
        }
        Ok(agent.state == "live")
    }

    async fn helpers(&mut self) -> Result<(), Over> {
        let read = self.listing().await;
        if let Some(listing) = helper_update(read, &mut self.helper_failures)
            && listing != self.helpers
        {
            self.send(event("helpers", &listing)).await?;
            self.helpers = listing;
        }
        Ok(())
    }
}

// Older clients clear their rows on null. Tolerate transient failures just as the app poll does.
fn helper_update(listing: Option<Value>, failures: &mut u8) -> Option<Value> {
    if listing.is_some() {
        *failures = 0;
        return listing;
    }
    *failures = failures.saturating_add(1);
    (*failures >= 5).then_some(Value::Null)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn helper_updates_distinguish_transient_failure_from_empty_and_unavailable() {
        let mut failures = 0;
        let empty = json!({ "helpers": [] });
        for _ in 0..4 { assert_eq!(helper_update(None, &mut failures), None); }
        assert_eq!(helper_update(Some(empty.clone()), &mut failures), Some(empty));
        for _ in 0..4 { assert_eq!(helper_update(None, &mut failures), None); }
        assert_eq!(helper_update(None, &mut failures), Some(Value::Null));
    }

    fn draft(id: &str, text: &str) -> Option<Draft> {
        Some(Draft {
            id: id.into(),
            text: text.into(),
        })
    }

    #[test]
    fn a_growing_reply_is_sent_as_additions_and_a_replaced_one_whole() {
        assert_eq!(draft_change(&None, &None), None);
        assert_eq!(draft_change(&draft("a", "One"), &draft("a", "One")), None);
        assert_eq!(
            draft_change(&None, &draft("a", "Zürich")),
            Some(("draft", json!({"id":"a","text":"Zürich"})))
        );
        // The offset counts the UTF-8 bytes of the text the reader already has: "Zürich" is seven.
        assert_eq!(
            draft_change(&draft("a", "Zürich"), &draft("a", "Zürich is")),
            Some(("draft_append", json!({"id":"a","offset":7,"text":" is"})))
        );
        // Another message, or text that no longer starts the same way, replaces what the reader has.
        for (sent, now) in [
            (draft("a", "One"), draft("b", "One two")),
            (draft("a", "One"), draft("a", "Two")),
            (draft("a", "One two"), draft("a", "One")),
        ] {
            assert_eq!(draft_change(&sent, &now), Some(("draft", json!(now))));
        }
        assert_eq!(
            draft_change(&draft("a", "One"), &None),
            Some(("draft", Value::Null))
        );
    }
}
