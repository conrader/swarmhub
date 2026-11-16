use crate::{
    core::Terminal,
    group_forms::Form,
    history::{History, StoreError, now},
};
use axum::body::Bytes;
use rusqlite::{OptionalExtension, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Target {
    pub address: String,
    pub created_ms: u64,
}

#[derive(Serialize)]
pub struct Group {
    pub id: i64,
    pub core: String,
    pub name: String,
    pub revision: i64,
    pub members: Vec<Member>,
}

#[derive(Serialize)]
pub struct Member {
    #[serde(flatten)]
    pub target: Target,
    pub name: String,
}

#[derive(Serialize)]
pub struct Message {
    pub id: i64,
    pub author: Option<String>,
    pub text: String,
    pub at_ms: i64,
    pub deliveries: Vec<Receipt>,
    pub files: Vec<FileInfo>,
    pub is_question: bool,
    pub target: Option<Target>,
    pub reply_to: Option<Quote>,
    pub answer_state: Option<String>,
    pub form: Option<Form>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reaction: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub handoff: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    rendered: Option<String>,
}

#[derive(Serialize)]
pub struct Quote {
    id: i64,
    pub author: String,
    pub text: String,
    pub is_question: bool,
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub is_form: bool,
}

pub struct ReplySource {
    pub quote: Quote,
    pub target: Target,
    pub form: Option<Form>,
}

pub enum Queued {
    Ready(i64, Vec<Delivery>),
    RosterChanged,
    AnswerExists,
    HandoffUnavailable,
}

pub struct Upload {
    pub name: String,
    pub data: Bytes,
}

pub const MAX_FILES: usize = 4;
pub const DRAFT_BYTES: usize = 2048;
const DRAFT_LIFETIME_MS: i64 = 120_000;

fn read_form(row: &rusqlite::Row<'_>, index: usize) -> rusqlite::Result<Option<Form>> {
    row.get::<_, Option<String>>(index)?
        .map(|value| {
            serde_json::from_str(&value).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    index,
                    rusqlite::types::Type::Text,
                    Box::new(error),
                )
            })
        })
        .transpose()
}

#[derive(Serialize)]
pub struct FileInfo {
    id: i64,
    name: String,
    bytes: usize,
}

#[derive(Serialize)]
pub struct Receipt {
    pub name: String,
    #[serde(flatten)]
    pub target: Target,
    pub state: String,
    pub detail: Option<String>,
}

#[derive(Serialize)]
pub struct Page {
    pub items: Vec<Message>,
    pub before: Option<i64>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    drafts: Vec<Draft>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub live_drafts: Vec<crate::group_preview::Draft>,
}

#[derive(Serialize)]
struct Draft {
    author: String,
    task: String,
    text: String,
}

impl Page {
    pub fn with_markup(mut self) -> Self {
        for message in &mut self.items {
            if message.author.is_some() && !message.is_question {
                message.rendered = crate::markdown::reply(
                    crate::markdown::ReplyKey::Group(message.id),
                    &message.text,
                );
            }
        }
        self
    }
}

pub struct Delivery {
    pub id: i64,
    pub target: Target,
    pub name: String,
    pub token: String,
    pub launch_key: String,
    pub context: String,
}

fn add_member(
    db: &rusqlite::Connection,
    group: i64,
    agent: &Terminal,
    joined_after: i64,
) -> Result<(), StoreError> {
    db.execute(
        "INSERT INTO group_members (group_id,address,created_ms,name,launch_key,joined_after)
         VALUES (?1,?2,?3,?4,?5,?6)",
        params![
            group,
            agent.address,
            agent.created_ms,
            agent.display_name(),
            agent.launch_key().ok_or(StoreError)?,
            joined_after
        ],
    )?;
    Ok(())
}

fn add_files(db: &rusqlite::Connection, message: i64, files: &[Upload]) -> rusqlite::Result<()> {
    for file in files {
        db.execute(
            "INSERT INTO group_attachments (message_id,name,data) VALUES (?1,?2,?3)",
            params![message, file.name, file.data.as_ref()],
        )?;
    }
    Ok(())
}

impl History {
    pub fn create_group(
        &self,
        core: &str,
        name: &str,
        terminals: &[Terminal],
    ) -> Result<i64, StoreError> {
        let mut db = self.db()?;
        let txn = db.transaction()?;
        let id: i64 = txn.query_row(
            "INSERT INTO groups (core, name, created_at) VALUES (?1, ?2, ?3) RETURNING id",
            params![core, name, now()],
            |row| row.get(0),
        )?;
        for agent in terminals {
            add_member(&txn, id, agent, 0)?;
        }
        txn.commit()?;
        Ok(id)
    }

    pub fn group(&self, id: i64) -> Result<Option<Group>, StoreError> {
        let db = self.db()?;
        let row = db
            .query_row(
                "SELECT core, name, revision FROM groups WHERE id = ?1",
                [id],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
            )
            .optional()?;
        let Some((core, name, revision)) = row else {
            return Ok(None);
        };
        let mut stmt = db.prepare("SELECT address, created_ms, name FROM group_members WHERE group_id = ?1 ORDER BY name, address")?;
        let members = stmt
            .query_map([id], |row| {
                Ok(Member {
                    target: Target {
                        address: row.get(0)?,
                        created_ms: row.get(1)?,
                    },
                    name: row.get(2)?,
                })
            })?
            .collect::<Result<_, _>>()?;
        Ok(Some(Group {
            id,
            core,
            name,
            revision,
            members,
        }))
    }

    pub fn groups(&self) -> Result<Vec<Group>, StoreError> {
        let ids: Vec<i64> = {
            let db = self.db()?;
            let mut stmt = db.prepare("SELECT id FROM groups ORDER BY id DESC")?;
            stmt.query_map([], |row| row.get(0))?
                .collect::<Result<_, _>>()?
        };
        let mut groups = Vec::with_capacity(ids.len());
        for id in ids {
            if let Some(group) = self.group(id)? {
                groups.push(group);
            }
        }
        Ok(groups)
    }

    pub fn edit_group(
        &self,
        group: &Group,
        name: &str,
        members: &HashSet<Target>,
        additions: &[Terminal],
    ) -> Result<bool, StoreError> {
        let mut db = self.db()?;
        let txn = db.transaction()?;
        if txn.execute(
            "UPDATE groups SET name=?2, revision=revision+1 WHERE id=?1 AND revision=?3",
            params![group.id, name, group.revision],
        )? == 0
        {
            return Ok(false);
        }
        for member in group
            .members
            .iter()
            .filter(|m| !members.contains(&m.target))
        {
            txn.execute(
                "DELETE FROM group_members WHERE group_id=?1 AND address=?2 AND created_ms=?3",
                params![group.id, member.target.address, member.target.created_ms],
            )?;
        }
        if !additions.is_empty() {
            let last = txn.query_row(
                "SELECT coalesce(max(id),0) FROM group_messages WHERE group_id=?1",
                [group.id],
                |row| row.get(0),
            )?;
            for agent in additions {
                add_member(&txn, group.id, agent, last)?;
            }
        }
        txn.commit()?;
        Ok(true)
    }

    pub fn group_page(&self, group: i64, before: Option<i64>) -> Result<Page, StoreError> {
        let db = self.db()?;
        let latest = before.is_none();
        let mut query = db.prepare(
            "SELECT m.id,m.author,m.text,m.at_ms,m.is_question,d.address,d.created_ms,
                    source.id,source.author,substr(source.text,1,320),source.is_question,
                    m.form_json,source.form_json IS NOT NULL,m.reaction,
                    CASE WHEN approved.sent_message IS NOT NULL THEN 'approved'
                         WHEN h.message IS NOT NULL THEN CASE WHEN h.task IS NULL THEN 'dismissed' ELSE 'pending' END
                         ELSE NULL END
             FROM group_messages m
             LEFT JOIN group_deliveries d ON m.delivery_id=d.id
             LEFT JOIN group_messages source ON source.id=m.in_reply_to
             LEFT JOIN group_handoffs h ON h.message=m.id
             LEFT JOIN group_handoff_dispatches approved ON approved.proposal=m.id
             WHERE m.group_id=?1 AND m.id<?2 ORDER BY m.id DESC LIMIT 31",
        )?;
        let mut items: Vec<Message> = query
            .query_map(params![group, before.unwrap_or(i64::MAX)], |row| {
                Ok(Message {
                    id: row.get(0)?,
                    author: row.get(1)?,
                    text: row.get(2)?,
                    at_ms: row.get(3)?,
                    deliveries: vec![],
                    files: vec![],
                    is_question: row.get(4)?,
                    target: if let Some(address) = row.get(5)? {
                        Some(Target {
                            address,
                            created_ms: row.get(6)?,
                        })
                    } else {
                        None
                    },
                    reply_to: if let Some(id) = row.get(7)? {
                        Some(Quote {
                            id,
                            author: row.get(8)?,
                            text: row.get(9)?,
                            is_question: row.get(10)?,
                            is_form: row.get(12)?,
                        })
                    } else {
                        None
                    },
                    answer_state: None,
                    form: read_form(row, 11)?,
                    reaction: row.get(13)?,
                    handoff: row.get(14)?,
                    rendered: None,
                })
            })?
            .collect::<Result<_, _>>()?;
        let before = if items.len() > 30 {
            items.pop();
            items.last().map(|item| item.id)
        } else {
            None
        };
        let mut receipts = db.prepare(
            "SELECT address, created_ms, name, state, detail FROM group_deliveries WHERE message_id = ?1 ORDER BY id",
        )?;
        let mut files = db.prepare(
            "SELECT id, name, length(data) FROM group_attachments WHERE message_id=?1 ORDER BY id",
        )?;
        let mut answers = db.prepare(
            "SELECT d.state FROM group_messages AS answer JOIN group_deliveries d ON answer.id=d.message_id
             WHERE answer.in_reply_to=?1 ORDER BY answer.id DESC LIMIT 1",
        )?;
        for item in &mut items {
            if item.author.is_none() {
                item.deliveries = receipts
                    .query_map([item.id], |row| {
                        Ok(Receipt {
                            target: Target {
                                address: row.get(0)?,
                                created_ms: row.get(1)?,
                            },
                            name: row.get(2)?,
                            state: row.get(3)?,
                            detail: row.get(4)?,
                        })
                    })?
                    .collect::<Result<_, _>>()?;
            }
            if item.is_question {
                item.answer_state = answers.query_row([item.id], |row| row.get(0)).optional()?;
            }
            item.files = files
                .query_map([item.id], |row| {
                    Ok(FileInfo {
                        id: row.get(0)?,
                        name: row.get(1)?,
                        bytes: row.get(2)?,
                    })
                })?
                .collect::<Result<_, _>>()?;
        }
        items.reverse();
        let drafts = if latest {
            db.prepare(
                "SELECT d.name,substr(task.text,1,160),d.draft_text
                 FROM group_deliveries d
                 JOIN group_messages task ON task.id=d.message_id
                 JOIN group_members member ON member.group_id=task.group_id
                      AND member.address=d.address AND member.created_ms=d.created_ms
                      AND member.launch_key=d.launch_key
                 WHERE task.group_id=?1 AND d.draft_ms>=?2 AND d.state!='not_sent'
                 ORDER BY d.draft_ms DESC,d.id DESC LIMIT 12",
            )?
            .query_map(
                params![group, now().saturating_sub(DRAFT_LIFETIME_MS)],
                |row| {
                    Ok(Draft {
                        author: row.get(0)?,
                        task: row.get(1)?,
                        text: row.get(2)?,
                    })
                },
            )?
            .collect::<Result<_, _>>()?
        } else {
            vec![]
        };
        Ok(Page {
            live_drafts: vec![],
            items,
            before,
            drafts,
        })
    }

    pub fn queue_group(
        &self,
        group: &Group,
        text: &str,
        targets: Vec<Target>,
        files: &[Upload],
        reply_to: Option<i64>,
        handoff: Option<i64>,
    ) -> Result<Queued, StoreError> {
        let mut db = self.db()?;
        // Reserve the writer before reading the roster revision so an incoming
        // reply cannot force a failed read-to-write upgrade.
        let txn = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(message) = handoff {
            match crate::group_handoffs::queue_gate(&txn, group.id, message, &targets, text)? {
                crate::group_handoffs::QueueGate::Ready => {}
                crate::group_handoffs::QueueGate::Already(id) => {
                    return Ok(Queued::Ready(id, vec![]));
                }
                crate::group_handoffs::QueueGate::Unavailable => {
                    return Ok(Queued::HandoffUnavailable);
                }
            }
        }
        let revision: i64 = txn.query_row(
            "SELECT revision FROM groups WHERE id=?1",
            [group.id],
            |row| row.get(0),
        )?;
        if revision != group.revision {
            return Ok(Queued::RosterChanged);
        }
        if let Some(reply) = reply_to {
            let fulfilled: bool = txn.query_row(
                "SELECT EXISTS(
                    SELECT 1 FROM group_messages q JOIN group_messages a ON a.in_reply_to=q.id
                    JOIN group_deliveries d ON d.message_id=a.id
                    WHERE q.id=?1 AND q.is_question=1 AND d.state!='not_sent'
                 )",
                [reply],
                |row| row.get(0),
            )?;
            if fulfilled {
                return Ok(Queued::AnswerExists);
            }
        }
        let message_id: i64 = txn.query_row(
            "INSERT INTO group_messages (group_id, text, at_ms, in_reply_to) VALUES (?1, ?2, ?3, ?4) RETURNING id",
            params![group.id, text, now(), reply_to],
            |row| row.get(0),
        )?;
        if let Some(proposal) = handoff {
            txn.execute(
                "INSERT INTO group_handoff_dispatches(proposal,sent_message) VALUES(?1,?2)",
                params![proposal, message_id],
            )?;
        }
        add_files(&txn, message_id, files)?;
        let mut dispatch = Vec::with_capacity(targets.len());
        for target in targets {
            // Attach only the recent group transcript since this recipient joined.
            let mut context = txn
                .prepare(
                    "SELECT coalesce(author,'User'), substr(text,1,500)
                 FROM group_messages AS m JOIN group_members AS member USING(group_id)
                 LEFT JOIN group_deliveries AS original ON original.id=m.delivery_id
                 WHERE member.group_id=?1 AND member.address=?2 AND member.created_ms=?3
                   AND coalesce(original.message_id,m.id)>joined_after AND m.id<?4
                   AND (m.in_reply_to IS NULL OR EXISTS (
                       SELECT 1 FROM group_deliveries directed
                       WHERE directed.message_id=m.id AND directed.address=?2 AND directed.created_ms=?3
                   ))
                 ORDER BY m.id DESC LIMIT 5",
                )?
                .query_map(
                    params![group.id, target.address, target.created_ms, message_id],
                    |row| {
                        Ok(format!(
                            "{}: {}",
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?
                        ))
                    },
                )?
                .collect::<Result<Vec<_>, _>>()?;
            context.reverse();
            let delivery = txn.query_row(
                "INSERT INTO group_deliveries (message_id, address, created_ms, name, launch_key, token, state)
                 SELECT ?1, address, created_ms, name, launch_key, lower(hex(randomblob(16))), 'pending'
                 FROM group_members WHERE group_id = ?2 AND address = ?3 AND created_ms = ?4
                 RETURNING id, name, token, launch_key",
                params![message_id, group.id, target.address, target.created_ms],
                |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)),
            )?;
            dispatch.push(Delivery {
                id: delivery.0,
                target,
                name: delivery.1,
                token: delivery.2,
                launch_key: delivery.3,
                context: context.join("\n"),
            });
        }
        txn.commit()?;
        Ok(Queued::Ready(message_id, dispatch))
    }

    pub fn reply_source(
        &self,
        group: i64,
        message: i64,
    ) -> Result<Option<ReplySource>, StoreError> {
        Ok(self
            .db()?
            .query_row(
                "SELECT m.author,substr(m.text,1,1200),m.is_question,d.address,d.created_ms,m.form_json
             FROM group_messages m JOIN group_deliveries d ON m.delivery_id=d.id
             WHERE m.group_id=?1 AND m.id=?2 AND m.author IS NOT NULL",
                params![group, message],
                |row| {
                    let form = read_form(row, 5)?;
                    Ok(ReplySource {
                        quote: Quote {
                            id: message,
                            author: row.get(0)?,
                            text: row.get(1)?,
                            is_question: row.get(2)?,
                            is_form: form.is_some(),
                        },
                        target: Target {
                            address: row.get(3)?,
                            created_ms: row.get(4)?,
                        },
                        form,
                    })
                },
            )
            .optional()?)
    }

    pub fn group_file(
        &self,
        group: i64,
        file: i64,
    ) -> Result<Option<(String, Vec<u8>)>, StoreError> {
        Ok(self.db()?.query_row(
            "SELECT f.name,f.data FROM group_attachments f JOIN group_messages m ON m.id=f.message_id
             WHERE m.group_id=?1 AND f.id=?2",
            params![group,file], |row| Ok((row.get(0)?,row.get(1)?)),
        ).optional()?)
    }

    pub fn finish_group_delivery(
        &self,
        id: i64,
        state: &str,
        detail: Option<&str>,
    ) -> Result<(), StoreError> {
        self.db()?.execute(
            "UPDATE group_deliveries SET state = ?2, detail = ?3 WHERE id = ?1 AND state = 'pending'",
            params![id, state, detail],
        )?;
        Ok(())
    }
}

pub fn publish_group_draft(
    journal: &std::path::Path,
    launch_key: &str,
    token: &str,
    text: &str,
) -> Result<bool, StoreError> {
    let mut db = crate::history::connection(journal)?;
    let txn = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let at = now();
    let updated = txn.execute(
        "UPDATE group_deliveries AS d SET draft_text=?3, draft_ms=?4
         WHERE token=?1 AND launch_key=?2 AND state!='not_sent'
           AND NOT EXISTS(SELECT 1 FROM group_messages WHERE delivery_id=d.id)
           AND EXISTS(
               SELECT 1 FROM group_messages task JOIN group_members member ON member.group_id=task.group_id
               WHERE task.id=d.message_id AND member.address=d.address AND member.created_ms=d.created_ms
                 AND member.launch_key=d.launch_key
           )",
        params![token, launch_key, text, at],
    )?;
    if updated == 0 {
        return Ok(false);
    }
    txn.execute(
        "UPDATE group_deliveries SET draft_text=NULL, draft_ms=NULL WHERE draft_ms<?1",
        [at.saturating_sub(DRAFT_LIFETIME_MS)],
    )?;
    txn.commit()?;
    Ok(true)
}

pub fn publish_group_reply(
    journal: &std::path::Path,
    launch_key: &str,
    token: &str,
    text: &str,
    files: &[Upload],
    is_question: bool,
    form_json: Option<&str>,
) -> Result<bool, StoreError> {
    let mut db = crate::history::connection(journal)?;
    let txn = db.transaction()?;
    let message = txn
        .query_row(
            "INSERT INTO group_messages (group_id, author, text, at_ms, delivery_id, is_question, form_json)
         SELECT group_id, name, ?3, ?4, group_deliveries.id, ?5, ?6 FROM group_deliveries
         JOIN group_messages ON group_messages.id = message_id
         WHERE token = ?1 AND launch_key = ?2 AND state != 'not_sent'
         ON CONFLICT(delivery_id) DO NOTHING RETURNING id, delivery_id",
            params![token, launch_key, text, now(), is_question, form_json],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )
        .optional()?;
    let Some((message, delivery)) = message else {
        return Ok(false);
    };
    add_files(&txn, message, files)?;
    txn.execute(
        "UPDATE group_deliveries SET draft_text=NULL,draft_ms=NULL WHERE id=?1 AND draft_ms IS NOT NULL",
        [delivery],
    )?;
    txn.commit()?;
    Ok(true)
}
