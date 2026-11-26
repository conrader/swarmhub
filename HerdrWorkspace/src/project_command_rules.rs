//! A user's standing approval of an exact foreground shell request for one bot and directory.
use crate::{
    bots,
    history::{History, StoreError},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};
use std::{fs, os::unix::fs::MetadataExt, path::Path, time::Duration};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Bash {
    command: String,
    #[serde(rename = "description")]
    _description: Option<String>,
    timeout: Option<u32>,
    #[serde(alias = "cwd")]
    workdir: Option<String>,
    #[serde(default)]
    run_in_background: bool,
}

#[derive(PartialEq)]
struct Directory {
    path: String,
    identity: String,
}

async fn directory(path: &str) -> Option<Directory> {
    let path = path.to_owned();
    tokio::time::timeout(
        Duration::from_secs(1),
        tokio::task::spawn_blocking(move || {
            if !Path::new(&path).is_absolute() {
                return None;
            }
            let real = fs::canonicalize(path).ok()?;
            let stat = fs::metadata(&real).ok()?;
            if !stat.is_dir() || real.parent().is_none() {
                return None;
            }
            Some(Directory {
                path: real.to_str()?.to_owned(),
                identity: format!("{}:{}", stat.dev(), stat.ino()),
            })
        }),
    )
    .await
    .ok()?
    .ok()?
}

pub(crate) struct Command {
    core: String,
    bot: String,
    agent: String,
    provider: &'static str,
    cwd: String,
    dir: Directory,
    command: String,
    timeout: i64,
}

impl Command {
    pub(crate) async fn identify(
        history: &History,
        launch: &str,
        provider: &'static str,
        cwd: &str,
        input: &str,
    ) -> Option<Self> {
        let Bash {
            command,
            _description: _,
            timeout,
            workdir,
            run_in_background,
        } = serde_json::from_str(input).ok()?;
        if run_in_background
            || command.trim().is_empty()
            || command.len() > 8192
            || workdir.as_deref().is_some_and(|dir| dir != cwd)
        {
            return None;
        }
        // Older sessions can have a registered bot's exact launch receipt without a parent_bot_id.
        let (core, bot, agent): (String, String, String) = history.db().ok()?.query_row(
            "SELECT core_id,coalesce(parent_bot_id,
                (SELECT min(id) FROM bots WHERE noted_launch=j.launch_key AND agent_name=j.agent HAVING count(*)=1)),agent
             FROM journal j WHERE launch_key=?1 AND NOT EXISTS (SELECT 1 FROM helpers WHERE launch=j.id)",
            [launch], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))
        ).optional().ok()??;
        if !bots::valid_id(&bot) {
            return None;
        }
        Some(Self {
            core,
            bot,
            agent,
            provider,
            cwd: cwd.into(),
            dir: directory(cwd).await?,
            command,
            timeout: timeout.map(i64::from).unwrap_or(-1),
        })
    }

    pub(crate) async fn unchanged(&self) -> bool {
        directory(&self.cwd).await.as_ref() == Some(&self.dir)
    }

    pub(crate) fn matching(&self, db: &Connection) -> rusqlite::Result<Option<i64>> {
        db.query_row(
            "SELECT id FROM project_command_rules WHERE core=?1 AND bot=?2 AND provider=?3
            AND cwd=?4 AND directory_id=?5 AND command=?6 AND timeout_ms=?7",
            params![
                self.core,
                self.bot,
                self.provider,
                self.dir.path,
                self.dir.identity,
                self.command,
                self.timeout
            ],
            |r| r.get(0),
        )
        .optional()
    }

    pub(crate) fn save(&self, db: &Connection) -> rusqlite::Result<()> {
        db.execute("INSERT INTO project_command_rules(core,bot,agent,provider,cwd,directory_id,command,timeout_ms)
            VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT DO NOTHING",
            params![self.core,self.bot,self.agent,self.provider,self.dir.path,self.dir.identity,self.command,self.timeout])?;
        Ok(())
    }
}

#[derive(Serialize)]
pub(crate) struct Rule {
    id: i64,
    bot: String,
    agent: String,
    provider: String,
    cwd: String,
    command: String,
}

pub(crate) fn list(db: &Connection) -> Result<Vec<Rule>, StoreError> {
    let mut q = db.prepare(
        "SELECT id,bot,agent,provider,cwd,command FROM project_command_rules ORDER BY id DESC",
    )?;
    Ok(q.query_map([], |r| {
        Ok(Rule {
            id: r.get(0)?,
            bot: r.get(1)?,
            agent: r.get(2)?,
            provider: r.get(3)?,
            cwd: r.get(4)?,
            command: r.get(5)?,
        })
    })?
    .collect::<Result<_, _>>()?)
}
