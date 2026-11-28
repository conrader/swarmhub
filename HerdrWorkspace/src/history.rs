use crate::core::Terminal;
use rusqlite::{
    Connection, ErrorCode, OpenFlags, OptionalExtension, Row, Transaction, TransactionBehavior,
    params,
};
use serde::{Deserialize, Serialize};
use std::{
    fs::{self, DirBuilder, File, OpenOptions},
    os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone)]
pub struct History(Arc<Store>);

struct Store {
    db: Mutex<Connection>,
    file: PathBuf,
    _lock: File,
    /// Counts the times `watch_changes` saw the journal move, for the event streams (`events`).
    changed: tokio::sync::watch::Sender<u64>,
}

/// How often `watch_changes` looks at the journal while an event stream is open.
const WATCH_EVERY: Duration = Duration::from_millis(200);

#[derive(Debug)]
pub struct StoreError;

impl From<rusqlite::Error> for StoreError {
    fn from(error: rusqlite::Error) -> Self {
        // Avoid logging SQL-related data or private conversation content.
        eprintln!("SwarmHub storage error: {:?}", error.sqlite_error());
        Self
    }
}

#[derive(Serialize)]
pub struct Item {
    id: i64,
    kind: String,
    state: String,
    text: String,
    detail: Option<String>,
    at_ms: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    launch_instructions: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    page_id: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    page_revision: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    page_title: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    live_reply_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    codex_model: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    codex_rerouted: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reaction: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    reply_to: Option<ReplyQuote>,
    #[serde(skip_serializing_if = "Option::is_none")]
    followups: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    answer_to: Option<ReplyQuote>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rendered: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    files: Vec<TaskFile>,
    #[serde(skip_serializing_if = "Option::is_none")]
    skill_proposal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    routine_proposal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    memory_proposal: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    email_draft: Option<String>,
}

#[derive(Serialize)]
struct TaskFile {
    id: i64,
    name: String,
    bytes: usize,
}

#[derive(Serialize)]
pub struct DirectThread {
    original: Item,
    #[serde(flatten)]
    history: Page,
}

#[derive(Serialize)]
pub struct ReplyQuote {
    pub id: i64,
    pub text: String,
}

#[derive(Serialize)]
pub struct LibraryItem {
    id: i64,
    title: String,
    agent: String,
    at_ms: i64,
    pinned: bool,
}

pub enum LibraryScope {
    Profile(i64),
    Session(String, String, u64),
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ResultKind {
    Page,
    File,
    Snapshot,
}

impl ResultKind {
    fn name(&self) -> &'static str {
        match self {
            Self::Page => "page",
            Self::File => "file",
            Self::Snapshot => "snapshot",
        }
    }
}

#[derive(Serialize)]
pub struct AgentResult {
    id: i64,
    title: String,
    kind: String,
    at_ms: i64,
    pinned: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    revision: Option<i64>,
}

#[derive(Serialize)]
pub struct Archive {
    core: String,
    address: String,
    created_ms: u64,
    agent: String,
    at_ms: i64,
}

#[derive(Serialize)]
pub struct Page {
    pub items: Vec<Item>,
    pub before: Option<i64>,
}

impl Item {
    pub(crate) fn id(&self) -> i64 {
        self.id
    }

    fn render_reply(&mut self) {
        if self.kind == "reply" {
            self.rendered =
                crate::markdown::reply(crate::markdown::ReplyKey::Direct(self.id), &self.text);
        }
    }
}

impl Page {
    pub fn with_markup(mut self) -> Self {
        self.items.iter_mut().for_each(Item::render_reply);
        self
    }
}

impl DirectThread {
    pub fn with_markup(mut self) -> Self {
        self.original.render_reply();
        self.history = self.history.with_markup();
        self
    }
}

pub enum State {
    Sent,
    NotSent,
    StartNotObserved,
    Unconfirmed,
}

impl State {
    pub(crate) fn as_str(&self) -> &str {
        match self {
            State::Sent => "sent",
            State::NotSent => "not_sent",
            State::StartNotObserved => "start_not_observed",
            State::Unconfirmed => "unconfirmed",
        }
    }
}

/// Called at bridge startup after acquiring workspace.lock. Preserve the claimed
/// attempt and any partial evidence for reconciliation, without touching the effect.
fn recover_interrupted_parks(db: &Connection) -> Result<(), rusqlite::Error> {
    let tx = Transaction::new_unchecked(db, TransactionBehavior::Immediate)?;
    tx.execute(
        "INSERT INTO park_decisions(park_id,action,actor,source,basis,at_ms)
         SELECT id,'hold','workspace','backstop','reconciliation: executor interrupted at startup',?1
         FROM parks WHERE state='executing'",
        [now()],
    )?;
    tx.execute("UPDATE parks SET state='reconciliation' WHERE state='executing'", [])?;
    tx.commit()
}

impl History {
    pub fn open() -> Result<Self, Box<dyn std::error::Error>> {
        Self::open_at(&private_directory()?)
    }

    pub(crate) fn open_at(directory: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(directory)?;
        if fs::symlink_metadata(directory)?.permissions().mode() & 0o077 != 0 {
            return Err("The workspace data directory must be private (mode 0700).".into());
        }
        let lock = private_file(&directory.join("workspace.lock"))?;
        lock.try_lock()
            .map_err(|_| "Another workspace server may already be using this data directory.")?;
        let file = directory.join("workspace.sqlite3");
        private_file(&file)?;
        let db = connection(&file)?;
        // Agent helpers open independent connections to this same local journal.
        // Require a release with the WAL fixes before activating WAL.
        if rusqlite::version_number() < 3_051_003 {
            return Err(
                "SwarmHub requires SQLite 3.51.3 or newer for its workspace journal.".into(),
            );
        }
        let mode: String = db.query_row("PRAGMA journal_mode=WAL", [], |row| row.get(0))?;
        if mode != "wal" {
            return Err(
                "SwarmHub could not enable WAL. Keep its data directory on local storage.".into(),
            );
        }
        migrate(&db, crate::bots::configured_server_timezone().as_deref())?;
        recover_interrupted_parks(&db)?;
        db.execute(
            "UPDATE journal SET state = 'unconfirmed' WHERE state = 'pending'",
            [],
        )?;
        db.execute(
            "UPDATE group_deliveries SET state = 'unconfirmed' WHERE state = 'pending'",
            [],
        )?;
        db.execute(
            "UPDATE routine_runs SET state = 'unconfirmed' WHERE state = 'pending'",
            [],
        )?;
        db.execute(
            "UPDATE approvals SET state='terminal',resolved_ms=?1 WHERE state='pending'",
            [now()],
        )?;
        Ok(Self(Arc::new(Store {
            db: Mutex::new(db),
            file,
            _lock: lock,
            changed: tokio::sync::watch::Sender::new(0),
        })))
    }

    /// Two numbers that stay the same only while nothing was written to the journal: SQLite's count of
    /// other connections' commits (an agent's reply hook is one) and this connection's own changed rows.
    pub(crate) fn signature(&self) -> Result<(i64, u64), StoreError> {
        let db = self.db()?;
        let others = db.query_row("PRAGMA data_version", [], |row| row.get(0))?;
        Ok((others, db.total_changes()))
    }

    /// Changes shortly after anything was written to the journal, once `watch_changes` runs.
    pub(crate) fn changes(&self) -> tokio::sync::watch::Receiver<u64> {
        self.0.changed.subscribe()
    }

    /// Tells `changes` when the journal moved. It reads two counters and no rows, and only while someone listens.
    pub(crate) fn watch_changes(&self) {
        let history = self.clone();
        tokio::spawn(async move {
            let mut seen = None;
            let mut tick = tokio::time::interval(WATCH_EVERY);
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tick.tick().await;
                if history.0.changed.receiver_count() == 0 {
                    seen = None;
                    continue;
                }
                let Ok(now) = history.signature() else {
                    continue;
                };
                if seen.replace(now).is_some_and(|before| before != now) {
                    history
                        .0
                        .changed
                        .send_modify(|count| *count = count.wrapping_add(1));
                }
            }
        });
    }

    pub fn file(&self) -> &Path {
        &self.0.file
    }

    pub(crate) fn db(&self) -> Result<std::sync::MutexGuard<'_, Connection>, StoreError> {
        self.0.db.lock().map_err(|_| StoreError)
    }

    pub fn start_launch(
        &self,
        core_id: &str,
        name: &str,
        task: &str,
        profile: Option<i64>,
        runtime: &str,
        instructions: &str,
    ) -> Result<Option<(i64, String)>, StoreError> {
        Ok(self.db()?.query_row(
            "INSERT INTO journal (launch_key, core_id, agent, kind, state, text, at_ms, profile_id, launch_runtime, launch_instructions)
             SELECT lower(hex(randomblob(16))), ?1, ?2, 'task', 'pending', ?3, ?4, ?5, ?6, NULLIF(?7,'')
             WHERE ?5 IS NULL OR NOT EXISTS (
                SELECT 1 FROM journal WHERE profile_id=?5 AND core_id=?1 AND state='pending'
                   AND launch_key IS NOT NULL
             )
             RETURNING id, launch_key",
            params![core_id, name, task, now(), profile, runtime, instructions],
            |row| Ok((row.get(0)?, row.get(1)?)),
        ).optional()?)
    }

    pub fn save_launch_files(&self, task: i64, files: &[crate::groups::Upload]) -> Result<(), StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction()?;
        for file in files {
            tx.execute(
                "INSERT INTO direct_task_files (task_id,name,data) VALUES (?1,?2,?3)",
                params![task, file.name, file.data.as_ref()],
            )?;
        }
        tx.commit()?;
        Ok(())
    }

    pub fn start_task(
        &self,
        core_id: &str,
        agent: &Terminal,
        task: &str,
        quote: Option<&ReplyQuote>,
        allow_thread_answer: bool,
        files: &[crate::groups::Upload],
    ) -> Result<(i64, Option<String>), StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        // The first message to an agent that was started ahead of it is that agent's launch row (`warm`).
        if quote.is_none()
            && let Some(id) = crate::warm::take_first_task(&tx, core_id, agent, task, now())?
        {
            for file in files {
                tx.execute(
                    "INSERT INTO direct_task_files (task_id,name,data) VALUES (?1,?2,?3)",
                    params![id, file.name, file.data.as_ref()],
                )?;
            }
            tx.commit()?;
            return Ok((id, None));
        }
        let (id,token) = tx.query_row(
            "INSERT INTO journal (core_id, address, created_ms, agent, kind, state, text, at_ms, in_reply_to, reply_excerpt, thread_reply_token)
             VALUES (?1, ?2, ?3, ?4, 'task', 'pending', ?5, ?6, ?7, ?8,
                    CASE WHEN ?9 THEN lower(hex(randomblob(16))) END) RETURNING id,thread_reply_token",
            params![
                core_id,
                agent.address,
                agent.created_ms,
                agent.display_name(),
                task,
                now(),
                quote.map(|quote| quote.id),
                quote.map(|quote| quote.text.as_str()),
                quote.is_some() && allow_thread_answer,
            ],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )?;
        for file in files {
            tx.execute(
                "INSERT INTO direct_task_files (task_id,name,data) VALUES (?1,?2,?3)",
                params![id, file.name, file.data.as_ref()],
            )?;
        }
        tx.commit()?;
        Ok((id, token))
    }

    pub fn direct_reply_quote(
        &self,
        core: &str,
        address: &str,
        created: u64,
        id: i64,
    ) -> Result<Option<ReplyQuote>, StoreError> {
        let text: Option<String> = self.db()?.query_row(
            "SELECT text FROM journal WHERE id=?1 AND core_id=?2 AND address=?3 AND created_ms=?4 AND kind='reply' AND in_reply_to IS NULL",
            params![id, core, address, created],
            |row| row.get(0),
        ).optional()?;
        Ok(text.map(|text| {
            let mut chars = text
                .chars()
                .filter(|c| !c.is_control() || matches!(c, '\n' | '\t'));
            let mut text: String = chars.by_ref().take(320).collect();
            if chars.next().is_some() {
                text.push('…');
            }
            ReplyQuote { id, text }
        }))
    }

    pub fn finish(
        &self,
        id: i64,
        state: State,
        detail: Option<&str>,
        terminal: Option<&Terminal>,
    ) -> Result<(), StoreError> {
        let changed = self.db()?.execute(
            "UPDATE journal SET state = ?2, detail = ?3,
               address = coalesce(?4, address), created_ms = coalesce(?5, created_ms)
             WHERE id = ?1 AND state = 'pending'",
            params![
                id,
                state.as_str(),
                detail,
                terminal.map(|t| &t.address),
                terminal.map(|t| t.created_ms)
            ],
        )?;
        if changed != 1 {
            return Err(StoreError);
        }
        Ok(())
    }

    pub fn recover_launch(&self, core_id: &str, agent: &Terminal) -> Result<(), StoreError> {
        if let Some(key) = agent.launch_key() {
            self.db()?.execute(
                "UPDATE journal SET address = ?3, created_ms = ?4,
                   state = CASE WHEN ?5 THEN 'not_sent' ELSE state END, detail = coalesce(?6, detail)
                 WHERE core_id = ?1 AND launch_key = ?2 AND address IS NULL AND state = 'unconfirmed'",
                params![core_id, key, agent.address, agent.created_ms,
                    agent.first_message.as_ref().is_some_and(|first| !first.sent),
                    agent.first_message.as_ref().and_then(|first| first.reason.as_deref())],
            )?;
        }
        Ok(())
    }

    pub fn page(
        &self,
        core_id: &str,
        address: &str,
        created: u64,
        before: Option<i64>,
    ) -> Result<Page, StoreError> {
        let db = self.db()?;
        let mut statement = db.prepare(&format!(
            "SELECT journal.id, CASE WHEN kind='artifact' AND page_id IS NOT NULL THEN 'page' ELSE kind END, state,
                    CASE kind WHEN 'snapshot' THEN '' ELSE text END,
                    CASE WHEN kind='artifact' AND page_id IS NOT NULL THEN workspace_pages.title ELSE detail END,
                    at_ms, launch_instructions, page_id,
                    CASE WHEN kind='artifact' AND page_id IS NOT NULL THEN workspace_pages.revision ELSE page_revision END,
                    workspace_pages.title,
                    CASE WHEN journal.event_key LIKE 'opencode:%' THEN substr(journal.event_key, 10) END,
                    reaction, in_reply_to, reply_excerpt,
                    CASE WHEN kind='reply' AND in_reply_to IS NULL THEN (
                      SELECT count(*) FROM journal followup WHERE followup.in_reply_to=journal.id AND followup.kind='task'
                    ) END,
                    answers_task, (SELECT substr(text,1,180) FROM journal task WHERE task.id=journal.answers_task),
                    telemetry.model, telemetry.rerouted
             FROM journal LEFT JOIN workspace_pages ON workspace_pages.id=journal.page_id
             LEFT JOIN codex_turn_models telemetry ON telemetry.launch=journal.reply_for AND telemetry.event=journal.event_key
             WHERE core_id=?1 AND address=?2 AND created_ms=?3 AND journal.id<?4 AND {}
             ORDER BY journal.id DESC LIMIT 31",
            crate::warm::SHOWN
        ))?;
        let mut items = statement
            .query_map(
                params![core_id, address, created, before.unwrap_or(i64::MAX)],
                item,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        populate_task_files(&db, &mut items)?;
        populate_proposals(&db, &mut items)?;
        Ok(chronological_page(items))
    }

    pub fn direct_thread(
        &self,
        core: &str,
        address: &str,
        created: u64,
        root: i64,
        before: Option<i64>,
    ) -> Result<Option<DirectThread>, StoreError> {
        let db = self.db()?;
        let Some(original) = db.query_row(
            "SELECT id,kind,state,text,detail,at_ms,NULL,NULL,NULL,NULL,NULL,reaction,NULL,NULL,NULL,NULL,NULL, telemetry.model,telemetry.rerouted
             FROM journal LEFT JOIN codex_turn_models telemetry ON telemetry.launch=journal.reply_for AND telemetry.event=journal.event_key
             WHERE id=?1 AND core_id=?2 AND address=?3 AND created_ms=?4 AND kind='reply' AND in_reply_to IS NULL",
            params![root, core, address, created], item,
        ).optional()? else {
            return Ok(None);
        };
        let mut statement = db.prepare(
            "SELECT id,kind,state,text,detail,at_ms,NULL,NULL,NULL,NULL,NULL,reaction,in_reply_to,reply_excerpt,NULL,
                    answers_task,(SELECT substr(text,1,180) FROM journal task WHERE task.id=journal.answers_task),
                    telemetry.model,telemetry.rerouted
             FROM journal LEFT JOIN codex_turn_models telemetry ON telemetry.launch=journal.reply_for AND telemetry.event=journal.event_key
             WHERE in_reply_to=?1 AND id<?2 AND core_id=?3 AND address=?4 AND created_ms=?5
             ORDER BY id DESC LIMIT 31",
        )?;
        let mut items = statement
            .query_map(
                params![root, before.unwrap_or(i64::MAX), core, address, created],
                item,
            )?
            .collect::<Result<Vec<_>, _>>()?;
        populate_task_files(&db, &mut items)?;
        Ok(Some(DirectThread {
            original,
            history: chronological_page(items),
        }))
    }

    pub fn save_snapshot(
        &self,
        core_id: &str,
        agent: &Terminal,
        title: &str,
        text: &str,
    ) -> Result<i64, StoreError> {
        Ok(self.db()?.query_row(
            "INSERT INTO journal (core_id, address, created_ms, agent, kind, state, text, detail, at_ms)
             VALUES (?1, ?2, ?3, ?4, 'snapshot', 'saved', ?5, ?6, ?7) RETURNING id",
            params![core_id, agent.address, agent.created_ms, agent.display_name(), text, title, now()],
            |row| row.get(0),
        )?)
    }

    pub fn library(&self, kind: &str) -> Result<Vec<LibraryItem>, StoreError> {
        let db = self.db()?;
        let mut statement = db.prepare(
            "SELECT j.id,j.detail,j.agent,j.at_ms,p.item_id IS NOT NULL AS pinned
             FROM journal j LEFT JOIN library_pins p ON p.item_id=j.id AND p.kind=?2
             WHERE j.kind=?1 AND j.page_id IS NULL ORDER BY pinned DESC,j.id DESC LIMIT 100",
        )?;
        let name = if kind == "artifact" { "file" } else { kind };
        Ok(statement
            .query_map([kind, name], |row| {
                Ok(LibraryItem {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    agent: row.get(2)?,
                    at_ms: row.get(3)?,
                    pinned: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?)
    }

    pub fn agent_library(
        &self,
        scope: LibraryScope,
        kind: Option<ResultKind>,
    ) -> Result<Vec<AgentResult>, StoreError> {
        let (profile, core, address, created) = match &scope {
            LibraryScope::Profile(id) => (Some(*id), None, None, None),
            LibraryScope::Session(core, address, created) => (
                None,
                Some(core.as_str()),
                Some(address.as_str()),
                Some(*created),
            ),
        };
        let kind = kind.as_ref().map(ResultKind::name);
        let db = self.db()?;
        let mut query = db.prepare(
            "WITH sessions(core_id,address,created_ms) AS (
                SELECT DISTINCT core_id,address,created_ms FROM journal
                WHERE profile_id=?1 AND launch_key IS NOT NULL AND address IS NOT NULL
                UNION ALL SELECT ?2,?3,?4 WHERE ?1 IS NULL
             ), results AS (
                SELECT coalesce(p.id,j.id) AS id,coalesce(p.title,j.detail) AS title,
                    CASE WHEN p.id IS NOT NULL THEN 'page' WHEN j.kind='artifact' THEN 'file'
                         ELSE j.kind END AS kind,coalesce(p.updated_ms,j.at_ms) AS at_ms,p.revision
                FROM sessions s JOIN journal j USING(core_id,address,created_ms)
                LEFT JOIN workspace_pages p ON p.id=j.page_id
                WHERE j.kind IN ('snapshot','artifact') AND j.detail IS NOT NULL
             ) SELECT r.id,r.title,r.kind,r.at_ms,r.revision,p.item_id IS NOT NULL AS pinned
               FROM results r LEFT JOIN library_pins p ON p.item_id=r.id AND p.kind=r.kind
               WHERE ?5 IS NULL OR r.kind=?5 ORDER BY pinned DESC,r.at_ms DESC,r.id DESC,r.kind LIMIT 100",
        )?;
        Ok(query
            .query_map(params![profile, core, address, created, kind], |row| {
                Ok(AgentResult {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    kind: row.get(2)?,
                    at_ms: row.get(3)?,
                    revision: row.get(4)?,
                    pinned: row.get(5)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?)
    }

    pub fn set_library_pin(
        &self,
        kind: ResultKind,
        id: i64,
        pinned: bool,
    ) -> Result<bool, StoreError> {
        let mut db = self.db()?;
        let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let exists = match kind {
            ResultKind::Page => "SELECT EXISTS(SELECT 1 FROM workspace_pages WHERE id=?1)",
            ResultKind::File => {
                "SELECT EXISTS(SELECT 1 FROM journal j JOIN artifacts USING(id)
                                 WHERE j.id=?1 AND j.kind='artifact' AND j.page_id IS NULL)"
            }
            ResultKind::Snapshot => {
                "SELECT EXISTS(SELECT 1 FROM journal WHERE id=?1 AND kind='snapshot')"
            }
        };
        if !tx.query_row(exists, [id], |row| row.get::<_, bool>(0))? {
            return Ok(false);
        }
        tx.execute(
            if pinned {
                "INSERT OR IGNORE INTO library_pins(kind,item_id) VALUES (?1,?2)"
            } else {
                "DELETE FROM library_pins WHERE kind=?1 AND item_id=?2"
            },
            params![kind.name(), id],
        )?;
        tx.commit()?;
        Ok(true)
    }

    pub fn snapshot(&self, id: i64) -> Result<Option<Item>, StoreError> {
        Ok(self.db()?.query_row(
            "SELECT id, kind, state, text, detail, at_ms, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM journal WHERE kind = 'snapshot' AND id = ?1",
            [id], item,
        ).optional()?)
    }

    pub fn direct_file(
        &self,
        core: &str,
        address: &str,
        created: u64,
        task: i64,
        file: i64,
    ) -> Result<Option<(String, Vec<u8>)>, StoreError> {
        Ok(self.db()?.query_row(
            "SELECT f.name,f.data FROM direct_task_files f JOIN journal j ON j.id=f.task_id
             WHERE f.id=?5 AND j.id=?4 AND j.kind='task' AND j.core_id=?1 AND j.address=?2 AND j.created_ms=?3",
            params![core,address,created,task,file], |row| Ok((row.get(0)?,row.get(1)?)),
        ).optional()?)
    }

    pub fn artifact(&self, id: i64) -> Result<Option<(String, Vec<u8>)>, StoreError> {
        Ok(self
            .db()?
            .query_row(
                "SELECT journal.detail, artifacts.data FROM journal JOIN artifacts USING(id)
             WHERE journal.kind = 'artifact' AND id = ?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?)),
            )
            .optional()?)
    }

    pub fn record_attachment(
        &self,
        core_id: &str,
        agent: &Terminal,
        name: &str,
        path: &str,
    ) -> Result<(), StoreError> {
        self.db()?.execute(
            "INSERT INTO journal (core_id, address, created_ms, agent, kind, state, text, detail, at_ms)
             VALUES (?1, ?2, ?3, ?4, 'attachment', 'saved', ?5, ?6, ?7)",
            params![core_id, agent.address, agent.created_ms, agent.display_name(), path, name, now()],
        )?;
        Ok(())
    }

    pub fn conversations(&self) -> Result<Vec<Archive>, StoreError> {
        let db = self.db()?;
        let mut statement = db.prepare(&format!(
            "SELECT core_id, address, created_ms, agent, max(at_ms) FROM journal
             WHERE address IS NOT NULL AND {}
             GROUP BY core_id, address, created_ms
             ORDER BY max(id) DESC LIMIT 100",
            crate::warm::SHOWN
        ))?;
        Ok(statement
            .query_map([], |row| {
                Ok(Archive {
                    core: row.get(0)?,
                    address: row.get(1)?,
                    created_ms: row.get(2)?,
                    agent: row.get(3)?,
                    at_ms: row.get(4)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?)
    }
}

pub(crate) fn connection(path: &Path) -> rusqlite::Result<Connection> {
    connect(path, Duration::from_secs(3))
}

fn connect(path: &Path, wait: Duration) -> rusqlite::Result<Connection> {
    let db = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
    db.busy_timeout(wait)?;
    db.execute_batch("PRAGMA synchronous=FULL; PRAGMA foreign_keys=ON;")?;
    Ok(db)
}

/// Used on blocking workers so maintenance cannot hold the browser's database mutex
/// while SQLite waits on another process. The next poll can pick up deferred work.
pub(crate) struct BackgroundJournal {
    db: Option<Connection>,
    history: History,
}

impl BackgroundJournal {
    pub fn new(history: History) -> Self {
        Self { db: None, history }
    }

    pub fn db(&mut self) -> Result<Option<&mut Connection>, StoreError> {
        if self.db.is_none() {
            self.db = defer_if_busy(connect(self.history.file(), Duration::from_millis(200)))?;
        }
        Ok(self.db.as_mut())
    }
}

pub(crate) fn defer_if_busy<T>(result: rusqlite::Result<T>) -> Result<Option<T>, StoreError> {
    match result {
        Ok(value) => Ok(Some(value)),
        Err(error) if error.sqlite_error_code() == Some(ErrorCode::DatabaseBusy) => Ok(None),
        Err(error) => Err(error.into()),
    }
}

pub(crate) fn background_write(db: &mut Connection) -> Result<Option<Transaction<'_>>, StoreError> {
    defer_if_busy(db.transaction_with_behavior(TransactionBehavior::Immediate))
}

pub(crate) fn migrations() -> &'static [&'static str] {
    &[
        include_str!("migrate-replies.sql"),
        include_str!("migrate-files.sql"),
        include_str!("migrate-groups.sql"),
        include_str!("migrate-routines.sql"),
        include_str!("migrate-approvals.sql"),
        include_str!("migrate-codex.sql"),
        include_str!("migrate-skills.sql"),
        include_str!("migrate-group-members.sql"),
        include_str!("migrate-profiles.sql"),
        include_str!("migrate-runtimes.sql"),
        include_str!("migrate-profile-instructions.sql"),
        include_str!("migrate-group-files.sql"),
        include_str!("migrate-group-questions.sql"),
        include_str!("migrate-group-forms.sql"),
        include_str!("migrate-pages.sql"),
        include_str!("migrate-page-tasks.sql"),
        include_str!("migrate-attention.sql"),
        include_str!("migrate-result-folders.sql"),
        include_str!("migrate-profile-copies.sql"),
        include_str!("migrate-roster-sections.sql"),
        include_str!("migrate-profile-avatars.sql"),
        include_str!("migrate-grok-import.sql"),
        include_str!("migrate-grok-routine-drafts.sql"),
        include_str!("migrate-reactions.sql"),
        include_str!("migrate-direct-replies.sql"),
        include_str!("migrate-direct-threads.sql"),
        include_str!("migrate-thread-answers.sql"),
        include_str!("migrate-activity.sql"),
        include_str!("migrate-activity-notices.sql"),
        include_str!("migrate-routine-outcomes.sql"),
        include_str!("migrate-routine-webhooks.sql"),
        include_str!("migrate-grok-files.sql"),
        include_str!("migrate-group-drafts.sql"),
        include_str!("migrate-webhook-review.sql"),
        include_str!("migrate-vault.sql"),
        include_str!("migrate-page-revisions.sql"),
        include_str!("migrate-library-pins.sql"),
        include_str!("migrate-direct-task-files.sql"),
        include_str!("migrate-skill-proposals.sql"),
        include_str!("migrate-routine-proposals.sql"),
        include_str!("migrate-memory-proposals.sql"),
        include_str!("migrate-email-drafts.sql"),
        include_str!("migrate-group-handoffs.sql"),
        include_str!("migrate-approval-rules.sql"),
        include_str!("migrate-grok-skill-drafts.sql"),
        include_str!("migrate-page-sharing.sql"),
        include_str!("migrate-helpers.sql"),
        include_str!("migrate-projects.sql"),
        include_str!("migrate-warm-launches.sql"),
        include_str!("migrate-bots.sql"),
        include_str!("migrate-vault-requests.sql"),
        include_str!("migrate-parks.sql"),
        include_str!("migrate-jobs.sql"),
        include_str!("migrate-job-delivery.sql"),
        include_str!("migrate-fleet-policy.sql"),
        include_str!("migrate-worker-hosts.sql"),
        include_str!("migrate-job-reviews.sql"),
        include_str!("migrate-workload-grants.sql"),
        include_str!("migrate-outbound-drafts.sql"),
        include_str!("migrate-outbound-receipts.sql"),
        include_str!("migrate-completion-backoff.sql"),
        include_str!("migrate-person-profile.sql"),
        include_str!("migrate-routine-rezone.sql"),
        include_str!("migrate-bot-agent-settings.sql"),
        include_str!("migrate-routine-transfers.sql"),
        include_str!("migrate-launch-review.sql"),
        include_str!("migrate-message-delivery.sql"),
        include_str!("migrate-codex-effective.sql"),
        include_str!("migrate-checkin-control.sql"),
        include_str!("migrate-helper-followups.sql"),
        include_str!("migrate-command-reviewer.sql"),
        include_str!("migrate-session-usage.sql"),
        include_str!("migrate-codex-session-model.sql"),
        include_str!("migrate-ci-review.sql"),
        include_str!("migrate-project-command-rules.sql"),
        include_str!("migrate-command-rule-expiry.sql"),
        include_str!("migrate-named-reviewer.sql"),
        include_str!("migrate-tool-review.sql"),
        include_str!("migrate-codex-children.sql"),
        include_str!("migrate-claude-children.sql"),
        include_str!("migrate-opencode-children.sql"),
        include_str!("migrate-gemini-children.sql"),
        include_str!("migrate-opencode-spend.sql"),
        include_str!("migrate-document-review.sql"),
        include_str!("migrate-ci-push.sql"),
        include_str!("migrate-routine-pages.sql"),
        include_str!("migrate-bot-final-status.sql"),
        include_str!("migrate-auto-default.sql"),
    ]
}

pub(crate) fn migrate(
    db: &Connection,
    server_zone: Option<&str>,
) -> Result<(), Box<dyn std::error::Error>> {
    let version: usize = db.query_row("PRAGMA user_version", [], |row| row.get(0))?;
    for (index, script) in migrations()
        .get(version..)
        .ok_or("This workspace database was created by a newer version.")?
        .iter()
        .enumerate()
    {
        if version + index == 61 {
            let tx = db.unchecked_transaction()?;
            tx.execute_batch(script)?;
            crate::person_profile::migrate(&tx, server_zone)?;
            tx.commit()?;
        } else {
            db.execute_batch(script)?;
        }
    }
    Ok(())
}

/// Publish at most one answer for the issued follow-up, using the session's launch identity.
pub fn publish_thread_answer(
    path: &Path,
    launch: &str,
    token: &str,
    text: &str,
) -> Result<bool, StoreError> {
    let db = connection(path)?;
    let changed = db.execute(
        "INSERT INTO journal
            (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms,in_reply_to,reply_excerpt,answers_task)
         SELECT launch.launch_key,task.core_id,task.address,task.created_ms,task.agent,
                'reply','received',?3,'Agent',?4,task.in_reply_to,task.reply_excerpt,task.id
         FROM journal task JOIN journal launch ON launch.launch_key=?1
            AND launch.core_id=task.core_id AND launch.address=task.address AND launch.created_ms=task.created_ms
         WHERE task.thread_reply_token=?2 AND task.kind='task' AND task.in_reply_to IS NOT NULL
            AND task.state IN ('pending','sent','start_not_observed','unconfirmed')
         ON CONFLICT(answers_task) WHERE answers_task IS NOT NULL DO NOTHING",
        params![launch, token, text, now()],
    )?;
    Ok(changed == 1)
}

/// Called by a local agent hook, which can publish while the browser service is down.
pub fn publish_reply(
    path: &Path,
    launch_key: &str,
    source: &str,
    text: &str,
    event_key: Option<&str>,
) -> Result<bool, StoreError> {
    let db = connection(path)?;
    let changed = db.execute(
        "INSERT INTO journal (reply_for, core_id, address, created_ms, agent, kind, state, text, detail, at_ms, event_key)
         SELECT launch_key, core_id, address, created_ms, agent, 'reply', 'received', ?2, ?3, ?4, ?5
         FROM journal WHERE launch_key = ?1
         ON CONFLICT(reply_for, event_key) WHERE event_key IS NOT NULL DO NOTHING",
        params![launch_key, text, source, now(), event_key],
    )?;
    if changed == 1 {
        return Ok(true);
    }
    Ok(event_key.is_some()
        && db.query_row(
            "SELECT EXISTS(SELECT 1 FROM journal WHERE reply_for=?1 AND event_key=?2)",
            params![launch_key, event_key],
            |row| row.get::<_, bool>(0),
        )?)
}

pub fn publish_artifact(
    path: &Path,
    launch_key: &str,
    name: &str,
    data: &[u8],
) -> Result<Option<i64>, StoreError> {
    let mut db = connection(path)?;
    let transaction = db.transaction()?;
    let id = transaction.query_row(
        "INSERT INTO journal (reply_for, core_id, address, created_ms, agent, kind, state, text, detail, at_ms)
         SELECT launch_key, core_id, address, created_ms, agent, 'artifact', 'saved', '', ?2, ?3
         FROM journal WHERE launch_key = ?1 RETURNING id",
        params![launch_key, name, now()], |row| row.get(0),
    ).optional()?;
    if let Some(id) = id {
        transaction.execute(
            "INSERT INTO artifacts (id, data) VALUES (?1, ?2)",
            params![id, data],
        )?;
    }
    transaction.commit()?;
    Ok(id)
}

fn item(row: &Row<'_>) -> rusqlite::Result<Item> {
    Ok(Item {
        id: row.get(0)?,
        kind: row.get(1)?,
        state: row.get(2)?,
        text: row.get(3)?,
        detail: row.get(4)?,
        at_ms: row.get(5)?,
        launch_instructions: row.get(6)?,
        page_id: row.get(7)?,
        page_revision: row.get(8)?,
        page_title: row.get(9)?,
        live_reply_id: row.get(10)?,
        codex_model: row.get(17)?,
        codex_rerouted: row.get(18)?,
        reaction: row.get(11)?,
        reply_to: match row.get(12)? {
            Some(id) => Some(ReplyQuote {
                id,
                text: row.get(13)?,
            }),
            None => None,
        },
        followups: row.get(14)?,
        answer_to: match row.get(15)? {
            Some(id) => Some(ReplyQuote {
                id,
                text: row.get(16)?,
            }),
            None => None,
        },
        rendered: None,
        files: Vec::new(),
        skill_proposal: None,
        routine_proposal: None,
        memory_proposal: None,
        email_draft: None,
    })
}

fn populate_task_files(db: &Connection, items: &mut [Item]) -> Result<(), StoreError> {
    let mut lookup = db.prepare(
        "SELECT id,name,length(data) FROM direct_task_files WHERE task_id=?1 ORDER BY id",
    )?;
    for item in items.iter_mut().filter(|item| item.kind == "task") {
        item.files = lookup
            .query_map([item.id], |row| {
                Ok(TaskFile {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    bytes: row.get(2)?,
                })
            })?
            .collect::<Result<_, _>>()?;
    }
    Ok(())
}

fn populate_proposals(db: &Connection, items: &mut [Item]) -> Result<(), StoreError> {
    for item in items {
        let (field, query) = match item.detail.as_deref() {
            Some("Skill proposal") => (
                &mut item.skill_proposal,
                "SELECT state FROM skill_proposals WHERE message=?1",
            ),
            Some("Routine proposal") => (
                &mut item.routine_proposal,
                "SELECT state FROM routine_proposals WHERE message=?1",
            ),
            Some("Memory suggestion") => (
                &mut item.memory_proposal,
                "SELECT state FROM memory_proposals WHERE message=?1",
            ),
            Some("Email draft") => (
                &mut item.email_draft,
                "SELECT state FROM email_drafts WHERE message=?1",
            ),
            _ => continue,
        };
        *field = db
            .prepare_cached(query)?
            .query_row([item.id], |row| row.get(0))
            .optional()?;
    }
    Ok(())
}

fn chronological_page(mut items: Vec<Item>) -> Page {
    let before = if items.len() > 30 {
        items.pop();
        items.last().map(|item| item.id)
    } else {
        None
    };
    items.reverse();
    Page { items, before }
}

pub(crate) fn private_directory() -> Result<PathBuf, Box<dyn std::error::Error>> {
    let directory = if let Some(value) = std::env::var_os("SWARMHUB_DATA_DIR") {
        PathBuf::from(value)
    } else if let Some(value) = std::env::var_os("XDG_STATE_HOME") {
        PathBuf::from(value).join("swarmhub-herdr")
    } else {
        PathBuf::from(std::env::var_os("HOME").ok_or("Set SWARMHUB_DATA_DIR or HOME.")?)
            .join(".local/state/swarmhub-herdr")
    };
    if !directory.is_absolute() {
        return Err("The workspace data directory must be an absolute path.".into());
    }
    Ok(directory)
}

fn private_file(path: &Path) -> std::io::Result<File> {
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .mode(0o600)
        .read(true)
        .write(true)
        .open(path)?;
    if file.metadata()?.permissions().mode() & 0o077 != 0 {
        return Err(std::io::Error::other(
            "Workspace data files must be private (mode 0600).",
        ));
    }
    Ok(file)
}

pub(crate) fn now() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(i64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_signature_moves_with_every_write_and_only_then() {
        let scratch = tempfile::tempdir().unwrap();
        let history = History::open_at(&scratch.path().join("workspace")).unwrap();
        let empty = history.signature().unwrap();
        assert_eq!(history.signature().unwrap(), empty);
        // The server's own write.
        let (_, key) = history
            .start_launch("core", "agent", "Read this", None, "{}", "")
            .unwrap()
            .unwrap();
        let launched = history.signature().unwrap();
        assert_ne!(launched, empty);
        // A reply hook writes through its own connection.
        assert!(publish_reply(history.file(), &key, "Codex", "Done", None).unwrap());
        let replied = history.signature().unwrap();
        assert_ne!(replied, launched);
        history.page("core", "t1", 1, None).unwrap();
        assert_eq!(history.signature().unwrap(), replied);
    }

    #[test]
    fn agent_replies_and_idle_schedules_allow_concurrent_access() {
        let scratch = tempfile::tempdir().unwrap();
        let data = scratch.path().join("workspace");
        let history = History::open_at(&data).unwrap();
        let (_, key) = history
            .start_launch("core", "agent", "Read this", None, "{}", "")
            .unwrap()
            .unwrap();
        let reader = connection(history.file()).unwrap();
        let reply_count = |db: &Connection| {
            db.query_row(
                "SELECT count(*) FROM journal WHERE kind='reply'",
                [],
                |row| row.get::<_, i64>(0),
            )
            .unwrap()
        };
        reader.execute_batch("BEGIN").unwrap();
        assert_eq!(reply_count(&reader), 0);
        assert!(
            publish_reply(
                history.file(),
                &key,
                "OpenCode",
                "Finished",
                Some("test:event")
            )
            .unwrap()
        );
        assert_eq!(
            reply_count(&reader),
            0,
            "reader must retain its consistent snapshot"
        );
        reader.execute_batch("COMMIT").unwrap();
        assert_eq!(reply_count(&reader), 1);

        // An idle scheduler must stay read-only even while an agent holds the writer lock.
        let writer = connection(history.file()).unwrap();
        writer.execute_batch("BEGIN IMMEDIATE").unwrap();
        let mut background = BackgroundJournal::new(history.clone());
        let db = background.db().unwrap().unwrap();
        db.busy_timeout(Duration::ZERO).unwrap();
        assert!(
            crate::routines::claim_schedule(db, now())
                .unwrap()
                .is_empty()
        );
        writer.execute_batch("ROLLBACK").unwrap();
        for name in ["workspace.sqlite3-wal", "workspace.sqlite3-shm"] {
            let permissions = fs::metadata(data.join(name)).unwrap().permissions();
            assert_eq!(permissions.mode() & 0o077, 0, "{name} must remain private");
        }
    }
}
