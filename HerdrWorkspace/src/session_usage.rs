use rusqlite::{Connection, OpenFlags, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;

/// Counts from the provider. The latest model call measures context. The cumulative total can exceed its window.
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub(crate) struct SessionUsage {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub context_tokens: Option<i64>,
    pub window_tokens: Option<i64>,
    pub total_tokens: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub opencode_cost_usd: Option<f64>,
}

impl SessionUsage {
    pub(crate) fn codex(data: &Value) -> Option<Self> {
        let context_tokens = data["last"]["totalTokens"].as_i64().filter(|n| *n >= 0)?;
        let total_tokens = data["total"]["totalTokens"].as_i64().filter(|n| *n >= 0)?;
        let window_tokens = data["modelContextWindow"].as_i64().filter(|n| *n > 0);
        Some(Self {
            context_tokens: Some(context_tokens),
            opencode_cost_usd: None,
            window_tokens,
            total_tokens,
        })
    }
}

pub(crate) enum Change {
    Start(String, Option<String>),
    Configured(String, String),
    Turn { thread: String, turn: String, rerouted: Option<String> },
    Close(String),
    Report(String, SessionUsage),
}

impl Change {
    pub(crate) fn save(self, journal: &Path, key: &str) -> rusqlite::Result<()> {
        let db = Connection::open_with_flags(journal, OpenFlags::SQLITE_OPEN_READ_WRITE)?;
        // Telemetry shares the reply follower. A busy journal must not stall incoming chat text.
        db.busy_timeout(std::time::Duration::from_millis(60))?;
        match self {
            Self::Configured(thread, model) => {
                db.execute("UPDATE journal SET codex_session_model=?3 WHERE launch_key=?1 AND usage_thread=?2",
                    params![key, thread, model])?;
            }
            Self::Turn { thread, turn, rerouted } => {
                // Preserve the first setting observed in this turn. Codex can explicitly report a later reroute.
                db.execute("INSERT INTO codex_turn_models (launch,event,model,rerouted)
                    SELECT launch_key,?3,coalesce(?4,codex_session_model),?4 IS NOT NULL
                    FROM journal WHERE launch_key=?1 AND usage_thread=?2
                      AND coalesce(?4,codex_session_model) IS NOT NULL
                    ON CONFLICT(launch,event) DO UPDATE SET model=excluded.model, rerouted=1
                    WHERE excluded.rerouted=1",
                    params![key, thread, format!("codex:{turn}"), rerouted])?;
            }
            Self::Start(thread, model) => {
                db.execute(
                    "UPDATE journal SET usage_thread=?2, session_usage=NULL, codex_session_model=?3
                    WHERE launch_key=?1 AND usage_thread IS NOT ?2",
                    params![key, thread, model],
                )?;
            }
            Self::Close(thread) => {
                db.execute(
                    "UPDATE journal SET usage_thread=NULL, session_usage=NULL, codex_session_model=NULL
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
