use crate::{
    Workspace,
    agent::claude_preview,
    group_preview,
    history::{History, StoreError},
};
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::get,
};
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    fs, io,
    os::unix::fs::FileTypeExt,
    sync::{Arc, Mutex},
};
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    net::{UnixListener, UnixStream},
    sync::{Semaphore, watch},
};

const TEXT_LIMIT: usize = 32 * 1024;
const FRAME_LIMIT: usize = TEXT_LIMIT * 6 + 1024;

#[derive(Clone, PartialEq, Eq, Serialize)]
pub(crate) struct Draft {
    pub id: String,
    pub text: String,
}

/// What a launch is doing right now: the reply so far and its newest tool calls.
#[derive(Default, Serialize)]
pub(crate) struct Preview {
    pub draft: Option<Draft>,
    /// The launch's newest tool calls, oldest first (`tool_activity`).
    pub tools: Vec<crate::tool_activity::Call>,
}

#[derive(Deserialize)]
struct Update {
    key: String,
    id: String,
    text: String,
}

#[derive(Default)]
struct DraftState {
    /// The reply so far of an agent that sends the whole text on one connection: OpenCode's plugin and the
    /// Codex follower (`codex_agent::stream`). The number is the connection, so a newer one wins.
    streamed: HashMap<String, (u64, Draft)>,
    claude: claude_preview::Previews,
    group: group_preview::Previews,
    tools: crate::tool_activity::Activity,
}

impl DraftState {
    fn preview(&self, key: &str) -> Preview {
        Preview {
            tools: self.tools.snapshot(key),
            draft: self
                .streamed
                .get(key)
                .map(|(_, draft)| draft.clone())
                .or_else(|| {
                    self.claude.get(key).map(|(id, text)| Draft {
                        id: id.to_owned(),
                        text: text.to_owned(),
                    })
                }),
        }
    }
}

struct Shared {
    state: Mutex<DraftState>,
    /// Counts the changes to a reply so far or a tool call, for the event streams (`events`).
    changed: watch::Sender<u64>,
}

#[derive(Clone)]
pub struct Drafts(Arc<Shared>);

impl Default for Drafts {
    fn default() -> Self {
        Self(Arc::new(Shared {
            state: Mutex::default(),
            changed: watch::Sender::new(0),
        }))
    }
}

impl Drafts {
    pub(crate) fn group_drafts(
        &self,
        history: &History,
        group: i64,
    ) -> Result<Vec<group_preview::Draft>, StoreError> {
        let entries = self.lock().map_err(|_| StoreError)?.group.snapshot(group);
        group_preview::feed(history, group, entries)
    }

    fn lock(&self) -> std::sync::LockResult<std::sync::MutexGuard<'_, DraftState>> {
        self.0.state.lock()
    }

    /// Wakes the event streams. Never waits: a hook's line is handled the same with or without a listener.
    fn announce(&self) {
        self.0
            .changed
            .send_modify(|count| *count = count.wrapping_add(1));
    }

    /// Changes whenever any launch's reply so far or tool calls may have changed.
    pub(crate) fn changes(&self) -> watch::Receiver<u64> {
        self.0.changed.subscribe()
    }

    pub(crate) fn helper_activity(&self, key: &str, since_ms: i64) -> Result<Option<crate::tool_activity::HelperActivity>, StoreError> {
        Ok(self.lock().map_err(|_| StoreError)?.tools.helper_activity(key, since_ms))
    }

    /// The same reading `/draft` returns for this launch.
    pub(crate) fn preview(&self, key: &str) -> Result<Preview, StoreError> {
        Ok(self.lock().map_err(|_| StoreError)?.preview(key))
    }
}

fn launch_exists(w: &Workspace, key: &str) -> bool {
    key.len() == 32
        && w.history.db().is_ok_and(|db| {
            db.query_row("SELECT 1 FROM journal WHERE launch_key=?1", [key], |_| {
                Ok(())
            })
            .is_ok()
        })
}

pub fn listen(w: Workspace) -> io::Result<()> {
    let path = w.history.file().with_file_name("replies.sock");
    match fs::symlink_metadata(&path) {
        Ok(meta) if meta.file_type().is_socket() => fs::remove_file(&path)?,
        Ok(_) => return Err(io::Error::other("Live reply socket path is not a socket")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let listener = UnixListener::bind(path)?;
    let slots = Arc::new(Semaphore::new(32));
    tokio::spawn(async move {
        let mut source = 0_u64;
        while let Ok((socket, _)) = listener.accept().await {
            let Ok(permit) = slots.clone().try_acquire_owned() else {
                continue;
            };
            source = source.wrapping_add(1);
            let w = w.clone();
            tokio::spawn(async move {
                let _permit = permit;
                read_updates(w, socket, source).await;
            });
        }
    });
    Ok(())
}

async fn read_updates(w: Workspace, socket: UnixStream, source: u64) {
    let mut input = BufReader::new(socket);
    let mut frame = Vec::new();
    let mut launch = None;
    let mut grouped: Option<(i64, String, group_preview::Binding, String)> = None;
    loop {
        frame.clear();
        let got_frame = (&mut input)
            .take(FRAME_LIMIT as u64)
            .read_until(b'\n', &mut frame)
            .await;
        if !matches!(got_frame, Ok(count) if count > 0) || frame.last() != Some(&b'\n') {
            break;
        }
        if let Ok(update) = serde_json::from_slice::<crate::tool_activity::Frame>(&frame) {
            if launch.is_none()
                && grouped.is_none()
                && update.valid()
                && launch_exists(&w, &update.key)
                && let Ok(mut drafts) = w.drafts.lock()
            {
                drafts
                    .tools
                    .apply(update, crate::history::now().max(0) as u64);
                drop(drafts);
                w.drafts.announce();
            }
            break;
        }
        if let Ok(update) = serde_json::from_slice::<claude_preview::Update>(&frame) {
            if launch.is_none()
                && grouped.is_none()
                && update.valid()
                && launch_exists(&w, &update.key)
            {
                let accepted = if let Ok(mut drafts) = w.drafts.lock() {
                    drafts.claude.apply(update);
                    true
                } else {
                    false
                };
                if accepted {
                    w.drafts.announce();
                    let _ = input.get_mut().write_all(&[0]).await;
                }
            }
            break;
        }
        if let Ok(update) = serde_json::from_slice::<group_preview::Update>(&frame) {
            if launch.is_some() || !update.valid() {
                break;
            }
            let group = if let Some((group, key, binding, id)) = &grouped {
                if key != &update.key || binding != &update.group_preview || id != &update.draft_id
                {
                    break;
                }
                *group
            } else {
                let Some(group) =
                    group_preview::group(&w.history, &update.key, &update.group_preview)
                else {
                    break;
                };
                grouped = Some((
                    group,
                    update.key.clone(),
                    update.group_preview.clone(),
                    update.draft_id.clone(),
                ));
                group
            };
            if let Ok(mut drafts) = w.drafts.lock() {
                drafts.group.update(group, source, update);
            }
            continue;
        }
        if grouped.is_some() {
            break;
        }
        let Ok(update) = serde_json::from_slice::<Update>(&frame) else {
            break;
        };
        if update.text.len() > TEXT_LIMIT || !crate::opencode_agent::valid_reply_id(&update.id) {
            break;
        }
        if let Some(launch) = &launch {
            if launch != &update.key {
                break;
            }
        } else {
            if !launch_exists(&w, &update.key) {
                break;
            }
            launch = Some(update.key.clone());
        }
        if let Ok(mut drafts) = w.drafts.lock()
            && drafts
                .streamed
                .get(&update.key)
                .is_none_or(|(previous, _)| *previous <= source)
        {
            drafts.streamed.insert(
                update.key,
                (
                    source,
                    Draft {
                        id: update.id,
                        text: update.text,
                    },
                ),
            );
            drop(drafts);
            w.drafts.announce();
        }
    }
    if let Some(launch) = launch
        && let Ok(mut drafts) = w.drafts.lock()
        && drafts
            .streamed
            .get(&launch)
            .is_some_and(|(previous, _)| *previous == source)
    {
        drafts.streamed.remove(&launch);
        drop(drafts);
        w.drafts.announce();
    }
    if let Some((_, _, binding, _)) = grouped
        && let Ok(mut drafts) = w.drafts.lock()
    {
        drafts.group.close(binding.delivery, source);
    }
}

pub fn routes() -> Router<Workspace> {
    Router::new().route("/api/history/{core}/{id}/{created}/draft", get(current))
}

async fn current(
    State(w): State<Workspace>,
    Path((core, id, created)): Path<(String, String, u64)>,
) -> Result<Json<Preview>, StoreError> {
    let empty = {
        let drafts = w.drafts.lock().map_err(|_| StoreError)?;
        drafts.streamed.is_empty() && !drafts.claude.visible() && drafts.tools.is_empty()
    };
    if empty {
        return Ok(Json(Preview::default()));
    }
    Ok(Json(match launch_key(&w.history, &core, &id, created)? {
        Some(key) => w.drafts.preview(&key)?,
        None => Preview::default(),
    }))
}

/// The launch a session belongs to, once its first task has been recorded.
pub(crate) fn launch_key(
    history: &History,
    core: &str,
    address: &str,
    created: u64,
) -> Result<Option<String>, StoreError> {
    Ok(history.db()?.query_row(
        "SELECT launch_key FROM journal WHERE core_id=?1 AND address=?2 AND created_ms=?3 AND launch_key IS NOT NULL LIMIT 1",
        params![core, address, created],
        |row| row.get(0),
    ).optional()?)
}
