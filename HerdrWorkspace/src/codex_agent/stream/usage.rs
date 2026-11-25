use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;

/// Counts from the provider. The latest model call measures context. The cumulative total can exceed its window.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub(crate) struct SessionUsage {
    pub context_tokens: i64,
    pub window_tokens: Option<i64>,
    pub total_tokens: i64,
}

impl SessionUsage {
    pub(super) fn reported(data: &Value) -> Option<Self> {
        let context_tokens = data["last"]["totalTokens"].as_i64().filter(|n| *n >= 0)?;
        let total_tokens = data["total"]["totalTokens"].as_i64().filter(|n| *n >= 0)?;
        let window_tokens = data["modelContextWindow"].as_i64().filter(|n| *n > 0);
        Some(Self {
            context_tokens,
            window_tokens,
            total_tokens,
        })
    }
}

pub(super) enum Change {
    Start(String),
    Close(String),
    Report(String, SessionUsage),
}

impl Change {
    pub(super) fn save(self, journal: &Path, key: &str) -> rusqlite::Result<()> {
        let db = Connection::open_with_flags(journal, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        // Telemetry shares the reply follower. A busy journal must not stall incoming chat text.
        db.busy_timeout(std::time::Duration::from_millis(60))?;
        match self {
            Self::Start(thread) => {
                db.execute(
                    "UPDATE journal SET usage_thread=?2, session_usage=NULL
                    WHERE launch_key=?1 AND usage_thread IS NOT ?2",
                    params![key, thread],
                )?;
            }
            Self::Close(thread) => {
                db.execute(
                    "UPDATE journal SET usage_thread=NULL, session_usage=NULL
                    WHERE launch_key=?1 AND usage_thread=?2",
                    params![key, thread],
                )?;
            }
            Self::Report(thread, report) => {
                db.execute(
                    "UPDATE journal SET usage_thread=?2, session_usage=?3
                    WHERE launch_key=?1 AND (usage_thread IS NULL OR usage_thread=?2)",
                    params![key, thread, serde_json::json!(report).to_string()],
                )?;
            }
        }
        Ok(())
    }
}
