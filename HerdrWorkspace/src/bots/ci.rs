//! Check public pull requests without starting an agent. Only a confirmed failure enters the outbox.
use super::{
    Ctx,
    plans::Schedule,
    rules::{About, entry},
};
use crate::history::History;
use rusqlite::{OptionalExtension, params};
use serde_json::Value;
use std::time::Duration;

pub(super) fn pull_request(raw: &str) -> Option<String> {
    let parts: Vec<_> = raw
        .trim_end_matches('/')
        .strip_prefix("https://github.com/")?
        .split('/')
        .collect();
    let [owner, repo, "pull", number] = parts.as_slice() else {
        return None;
    };
    if [owner, repo].iter().any(|s| {
        s.is_empty()
            || s.len() > 100
            || **s == "."
            || **s == ".."
            || !s
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b"._-".contains(&b))
    }) {
        return None;
    }
    let number = number.parse::<u64>().ok().filter(|n| *n > 0)?;
    Some(format!("https://github.com/{owner}/{repo}/pull/{number}"))
}

#[derive(Clone)]
enum Outcome {
    Waiting,
    Failed(String),
    Finished(&'static str),
}

async fn json(client: &reqwest::Client, url: String) -> Result<Value, Option<u16>> {
    let mut response = client.get(url).send().await.map_err(|_| None)?;
    if !response.status().is_success() {
        return Err(Some(response.status().as_u16()));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| None)? {
        if bytes.len() + chunk.len() > 4 * 1024 * 1024 {
            return Err(None);
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).map_err(|_| None)
}

async fn inspect(client: &reqwest::Client, url: &str) -> Outcome {
    let Some(valid) = pull_request(url) else {
        return Outcome::Finished("The pull request URL is invalid.");
    };
    let path = valid.trim_start_matches("https://github.com/");
    let (repo, number) = path.rsplit_once("/pull/").unwrap();
    let api = format!("https://api.github.com/repos/{repo}");
    let pr = match json(client, format!("{api}/pulls/{number}")).await {
        Ok(pr) => pr,
        Err(Some(404 | 410)) => {
            return Outcome::Finished("GitHub could not find a public pull request at this URL.");
        }
        Err(_) => return Outcome::Waiting,
    };
    if pr["state"] == "closed" {
        return Outcome::Finished("The pull request closed.");
    }
    let Some(sha) = pr
        .pointer("/head/sha")
        .and_then(Value::as_str)
        .filter(|s| s.len() == 40 && s.bytes().all(|b| b.is_ascii_hexdigit()))
    else {
        return Outcome::Waiting;
    };
    // All statuses participate in the latest per-name filter, including reruns in progress.
    for page in 1..=10 {
        let Ok(checks) = json(
            client,
            format!("{api}/commits/{sha}/check-runs?filter=latest&per_page=100&page={page}"),
        )
        .await
        else {
            break;
        };
        let Some(runs) = checks["check_runs"].as_array() else {
            break;
        };
        if let Some(id) = failed_check(runs, sha) {
            // Ignore a failure from a head that changed while its checks were being read.
            if let Ok(current) = json(client, format!("{api}/pulls/{number}")).await
                && current["state"] == "open"
                && current.pointer("/head/sha").and_then(Value::as_str) == Some(sha)
            {
                return Outcome::Failed(format!("https://github.com/{repo}/runs/{id}"));
            }
            return Outcome::Waiting;
        }
        if runs.len() < 100 {
            break;
        }
    }
    Outcome::Waiting
}

fn failed_check(runs: &[Value], sha: &str) -> Option<u64> {
    runs.iter()
        .find(|r| {
            r["head_sha"] == sha
                && r["status"] == "completed"
                && matches!(
                    r["conclusion"].as_str(),
                    Some("failure" | "timed_out" | "action_required" | "startup_failure")
                )
        })
        .and_then(|r| r["id"].as_u64())
}

fn settle(ctx: &Ctx<'_>, id: i64, bot: &str, url: &str, outcome: &Outcome) -> rusqlite::Result<()> {
    // Recheck inside the transaction: a person may have cancelled or paused it while GitHub was answering.
    let owned = "id=?1 AND bot=?2 AND state='planned' AND json_extract(schedule,'$.failure') IS NULL AND EXISTS(SELECT 1 FROM bots WHERE id=?2 AND removed_ms IS NULL AND takes_initiative)";
    match outcome {
        Outcome::Waiting => {}
        Outcome::Failed(link) => {
            let schedule = serde_json::to_string(&Schedule::Ci {
                url: url.into(),
                failure: Some(link.clone()),
            })
            .unwrap();
            ctx.db.execute(
                &format!("UPDATE bot_checkins SET schedule=?3,next_ms=?4 WHERE {owned}"),
                params![id, bot, schedule, ctx.now],
            )?;
        }
        Outcome::Finished(reason) => {
            if ctx.db.execute(
                &format!("UPDATE bot_checkins SET state='done',next_ms=NULL WHERE {owned}"),
                params![id, bot],
            )? == 1
            {
                entry(
                    ctx,
                    bot,
                    "notice",
                    &format!("CI watch ended for {url}. {reason}"),
                    About {
                        code: Some("ci_watch"),
                        checkin: Some(id),
                        ..Default::default()
                    },
                    true,
                    false,
                )?;
            }
        }
    }
    Ok(())
}

/// Reserve all active watches for the first due PR in one transaction.
fn reserve(ctx: &Ctx<'_>) -> rusqlite::Result<Vec<(i64, String, String)>> {
    let active = "FROM bot_checkins c JOIN bots b ON b.id=c.bot
        WHERE b.removed_ms IS NULL AND b.takes_initiative AND c.state='planned'
        AND json_extract(c.schedule,'$.kind')='ci' AND json_extract(c.schedule,'$.failure') IS NULL";
    let first: Option<String> = ctx.db.query_row(&format!(
        "SELECT json_extract(c.schedule,'$.url') {active} AND c.next_ms<=?1 ORDER BY c.next_ms,c.id LIMIT 1"),
        [ctx.now], |r|r.get(0)).optional()?;
    let Some(url) = first else {
        return Ok(Vec::new());
    };
    let mut statement = ctx.db.prepare_cached(&format!(
        "SELECT c.id,c.bot,c.created_ms {active} AND json_extract(c.schedule,'$.url')=?1"
    ))?;
    let records = statement
        .query_map([&url], |r| {
            Ok((
                r.get::<_, i64>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let mut batch = Vec::new();
    for (id, bot, created) in records {
        if ctx.now - created > 7 * 86_400_000 {
            settle(
                ctx,
                id,
                &bot,
                &url,
                &Outcome::Finished("The seven-day watch expired."),
            )?;
        } else {
            ctx.db.execute(
                "UPDATE bot_checkins SET next_ms=?2 WHERE id=?1",
                params![id, ctx.now + 300_000],
            )?;
            batch.push((id, bot, url.clone()));
        }
    }
    Ok(batch)
}

pub(super) async fn serve(history: History) {
    let Ok(client) = reqwest::Client::builder()
        .user_agent("SwarmHub-CI-watch")
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(12))
        .build()
    else {
        return;
    };
    loop {
        // Reserve a single PR, grouping all interested bots. The lease also bounds retries after a restart.
        let batch = super::write(&history, reserve);
        if let Ok(batch) = batch
            && let Some((_, _, url)) = batch.first()
        {
            let outcome = inspect(&client, url).await;
            let _ = super::write(&history, |ctx| {
                for (id, bot, url) in &batch {
                    settle(ctx, *id, bot, url, &outcome)?;
                }
                Ok(())
            });
            super::desk::kick();
        }
        tokio::time::sleep(Duration::from_secs(15)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::{Settings, plans, testing};

    #[test]
    fn accepts_only_github_pull_requests() {
        assert_eq!(
            pull_request("https://github.com/a/repo/pull/8/").as_deref(),
            Some("https://github.com/a/repo/pull/8")
        );
        for value in [
            "http://github.com/a/b/pull/1",
            "https://github.com/../b/pull/1",
            "https://github.com/a/b/pull/0",
            "https://github.com/a/b/pull/1?url=private",
            "https://example.org/a/b/pull/1",
        ] {
            assert!(pull_request(value).is_none());
        }
    }

    #[test]
    fn selects_only_completed_failures_on_the_requested_head() {
        let runs = serde_json::json!([
            {"id":1,"head_sha":"other","status":"completed","conclusion":"failure"},
            {"id":2,"head_sha":"head","status":"in_progress","conclusion":null},
            {"id":3,"head_sha":"head","status":"completed","conclusion":"success"},
            {"id":4,"head_sha":"head","status":"completed","conclusion":"timed_out"}
        ]);
        let list = runs.as_array().unwrap();
        assert_eq!(failed_check(&list[..3], "head"), None);
        assert_eq!(failed_check(list, "head"), Some(4));
    }

    #[test]
    fn coalesces_watches_and_expires_without_waking_an_agent() {
        let (_scratch, history) = testing::journal(&["Jarvis", "Reviewer"]);
        let settings = Settings::default();
        let main = testing::bot(&history, "Jarvis");
        let reviewer = testing::bot(&history, "Reviewer");
        let when = plans::When::Ci {
            url: "https://github.com/a/b/pull/1".into(),
        };
        testing::at(&history, 1_000, &settings, |ctx| {
            plans::plan(ctx, &main, &when, "watch", "person")?.unwrap();
            assert_eq!(reserve(ctx)?.len(), 1);
            Ok(())
        });
        testing::at(&history, 2_000, &settings, |ctx| {
            plans::plan(ctx, &reviewer, &when, "review", "person")?.unwrap();
            assert_eq!(reserve(ctx)?.len(), 2);
            assert!(reserve(ctx)?.is_empty());
            Ok(())
        });
        testing::at(&history, 8 * 86_400_000, &settings, |ctx| {
            assert!(reserve(ctx)?.is_empty());
            assert!(plans::checkins(ctx.db, None, false)?.is_empty());
            assert_eq!(plans::fire_due(ctx)?, 0);
            Ok(())
        });
    }

    #[test]
    fn wakes_once_only_after_a_failure_and_respects_cancellation() {
        let (_scratch, history) = testing::journal(&["Jarvis"]);
        let settings = Settings::default();
        let bot = testing::bot(&history, "Jarvis");
        let url = "https://github.com/example/project/pull/123";
        let when = plans::When::Ci { url: url.into() };
        testing::at(&history, 1_000_000, &settings, |ctx| {
            let watch = plans::plan(
                ctx,
                &bot,
                &when,
                "Ask Reviewer if release is blocked.",
                "person",
            )?
            .unwrap();
            settle(ctx, watch.id, &bot.id, url, &Outcome::Waiting)?;
            assert_eq!(plans::fire_due(ctx)?, 0);
            let failure = Outcome::Failed("https://github.com/example/project/runs/2".into());
            settle(ctx, watch.id, &bot.id, url, &failure)?;
            assert_eq!(plans::fire_due(ctx)?, 1);
            settle(ctx, watch.id, &bot.id, url, &failure)?;
            assert_eq!(plans::fire_due(ctx)?, 0);
            let task: String = ctx.db.query_row(
                "SELECT text FROM bot_outbox WHERE cause='checkin'",
                [],
                |r| r.get(0),
            )?;
            assert!(task.contains("runs/2") && task.contains("Ask Reviewer"));
            let cancelled = plans::plan(ctx, &bot, &when, "Cancelled test", "person")?.unwrap();
            assert!(plans::cancel(ctx, &bot.id, cancelled.id)?);
            settle(ctx, cancelled.id, &bot.id, url, &failure)?;
            assert_eq!(plans::fire_due(ctx)?, 0);
            Ok(())
        });
    }
}
