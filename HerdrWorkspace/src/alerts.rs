//! Alerts to an address the person chooses, for when no app is open.
//!
//! The Mac app raises a notification only while it runs. A bot that finishes a goal overnight, needs an answer
//! or misses a check-in would otherwise wait unseen until the person opens the app. With an alert address set,
//! every line of a bot's history that would raise a notification is also posted there: the bot's name and the
//! first part of the line. The address is one the person picked (an ntfy topic, a Slack incoming webhook, any
//! receiver of a small POST), so this is the only place where chat content leaves the workspace by itself, and
//! it is off until an address is saved.

use crate::{
    Workspace,
    history::{self, History, StoreError},
};
use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::get,
};
use reqwest::Url;
use rusqlite::{Connection, OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{net::IpAddr, time::Duration};

const ADDRESS: &str = "alert_address";
const CURSOR: &str = "alert_cursor";
const BODY_CHARS: usize = 300;
/// A line older than this is no longer worth an alert: after a long outage the person gets the recent ones.
const FRESH_MS: i64 = 3_600_000;
const BATCH: usize = 10;

pub(crate) fn routes() -> Router<Workspace> {
    Router::new().route("/api/alerts", get(read).post(save))
}

/// An https address, or plain http to this machine or a private network (a receiver on the tailnet).
fn address(text: &str) -> Option<Url> {
    let url = Url::parse(text.trim()).ok()?;
    let host = url.host_str()?;
    let private = match host.trim_matches(['[', ']']).parse::<IpAddr>() {
        Ok(IpAddr::V4(ip)) => {
            ip.is_loopback() || ip.is_private() || (ip.octets()[0] == 100 && (64..128).contains(&ip.octets()[1]))
        }
        Ok(IpAddr::V6(ip)) => ip.is_loopback(),
        Err(_) => host == "localhost",
    };
    (text.len() <= 2_048
        && (url.scheme() == "https" || (url.scheme() == "http" && private))
        && url.fragment().is_none())
    .then_some(url)
}

fn state(db: &Connection, key: &str) -> rusqlite::Result<Option<String>> {
    db.query_row("SELECT value FROM bot_state WHERE key=?1", [key], |row| row.get(0))
        .optional()
}

fn set(db: &Connection, key: &str, value: &str) -> rusqlite::Result<()> {
    db.execute(
        "INSERT INTO bot_state (key,value) VALUES (?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        params![key, value],
    )?;
    Ok(())
}

async fn read(State(w): State<Workspace>) -> Result<Json<Value>, StoreError> {
    let db = w.history.db()?;
    Ok(Json(json!({"address": state(&db, ADDRESS)?})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Wanted {
    /// The address to post to; empty or null turns alerts off.
    #[serde(default)]
    address: Option<String>,
    /// Post one line there now, so the person sees that it arrives.
    #[serde(default)]
    test: bool,
}

async fn save(State(w): State<Workspace>, Json(wanted): Json<Wanted>) -> Result<Response, StoreError> {
    let text = wanted.address.unwrap_or_default();
    let text = text.trim();
    if text.is_empty() {
        w.history.db()?.execute("DELETE FROM bot_state WHERE key=?1", [ADDRESS])?;
        return Ok(Json(json!({"address": null})).into_response());
    }
    let Some(url) = address(text) else {
        return Ok((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"error":"Give an https address, or an http address on this machine or your private network."})),
        )
            .into_response());
    };
    {
        let db = w.history.db()?;
        // Alerts start with what happens from now on, not with the history so far.
        let newest: i64 = db.query_row("SELECT coalesce(max(id),0) FROM bot_history", [], |row| row.get(0))?;
        set(&db, ADDRESS, url.as_str())?;
        set(&db, CURSOR, &newest.to_string())?;
    }
    let mut answer = json!({"address": url.as_str()});
    if wanted.test {
        let sent = post(&client(), &url, "SwarmHub", "Alerts from this workspace arrive here.").await;
        answer["test"] = json!(match sent {
            Ok(()) => "sent".to_owned(),
            Err(why) => why,
        });
    }
    Ok(Json(answer).into_response())
}

fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(12))
        .build()
        .unwrap_or_default()
}

/// A header value has to be plain ASCII: a name that is not becomes "SwarmHub".
fn title(name: &str) -> String {
    let plain: String = name.chars().filter(|c| c.is_ascii_graphic() || *c == ' ').take(60).collect();
    let plain = plain.trim();
    if plain.is_empty() || plain.len() != name.trim().len() { "SwarmHub".into() } else { plain.into() }
}

fn body(name: &str, text: &str) -> String {
    let mut line: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > BODY_CHARS {
        line = line.chars().take(BODY_CHARS - 1).collect();
        line.push('…');
    }
    // A receiver that shows no title still says who it is about.
    if title(name) == name.trim() { line } else { format!("{}: {line}", name.trim()) }
}

/// One alert. Slack's incoming webhooks take JSON with `text`; everything else gets the line as plain text
/// with the bot's name in a `Title` header, which is what ntfy reads.
async fn post(client: &reqwest::Client, url: &Url, name: &str, text: &str) -> Result<(), String> {
    let line = body(name, text);
    let request = if url.host_str() == Some("hooks.slack.com") {
        client
            .post(url.clone())
            .header("Content-Type", "application/json")
            .body(json!({"text": format!("*{}* {line}", title(name))}).to_string())
    } else {
        client
            .post(url.clone())
            .header("Title", title(name))
            .header("Content-Type", "text/plain; charset=utf-8")
            .body(line)
    };
    match request.send().await {
        Ok(response) if response.status().is_success() => Ok(()),
        Ok(response) => Err(format!("The address answered {}.", response.status().as_u16())),
        Err(_) => Err("The address could not be reached.".into()),
    }
}

struct Due {
    id: i64,
    name: String,
    text: String,
}

/// The next lines that raise a notification, after the ones already posted. Lines too old to matter are skipped.
fn due(history: &History, now: i64) -> Result<Option<(Url, Vec<Due>)>, StoreError> {
    let db = history.db()?;
    let Some(url) = state(&db, ADDRESS)?.and_then(|text| address(&text)) else {
        return Ok(None);
    };
    let cursor: i64 = state(&db, CURSOR)?.and_then(|text| text.parse().ok()).unwrap_or(0);
    let stale: Option<i64> = db.query_row(
        "SELECT max(id) FROM bot_history WHERE id>?1 AND at_ms<?2",
        params![cursor, now - FRESH_MS],
        |row| row.get(0),
    )?;
    let cursor = match stale {
        Some(through) => {
            set(&db, CURSOR, &through.to_string())?;
            through
        }
        None => cursor,
    };
    let lines = db
        .prepare_cached(
            "SELECT h.id,coalesce(b.name,'SwarmHub'),h.text FROM bot_history h LEFT JOIN bots b ON b.id=h.bot
             WHERE h.id>?1 AND h.notify=1 ORDER BY h.id LIMIT ?2",
        )?
        .query_map(params![cursor, BATCH as i64], |row| {
            Ok(Due { id: row.get(0)?, name: row.get(1)?, text: row.get(2)? })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(Some((url, lines)))
}

fn done(history: &History, through: i64) -> Result<(), StoreError> {
    set(&*history.db()?, CURSOR, &through.to_string())?;
    Ok(())
}

/// Posts what is due, in order. An address that fails is tried again later; nothing is skipped for it until it
/// has grown too old.
async fn deliver_due(history: &History, client: &reqwest::Client, now: i64) -> usize {
    let Ok(Some((url, lines))) = due(history, now) else {
        return 0;
    };
    let mut sent = 0;
    for line in lines {
        if post(client, &url, &line.name, &line.text).await.is_err() {
            break;
        }
        if done(history, line.id).is_err() {
            break;
        }
        sent += 1;
    }
    sent
}

pub(crate) async fn deliver(history: History) {
    let client = client();
    let mut wait = 5;
    loop {
        let before = due(&history, history::now()).ok().flatten().map_or(0, |(_, lines)| lines.len());
        let sent = deliver_due(&history, &client, history::now()).await;
        // An address that does not answer is asked less and less often, up to every five minutes.
        wait = if before > 0 && sent == 0 { (wait * 2).min(300) } else { 5 };
        tokio::time::sleep(Duration::from_secs(wait)).await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::testing;
    use std::sync::{Arc, Mutex};

    #[test]
    fn only_an_address_that_is_safe_to_post_to_is_taken() {
        for good in [
            "https://ntfy.sh/konrad-swarmhub",
            " https://hooks.slack.com/services/T0/B0/x ",
            "http://127.0.0.1:8090/alerts",
            "http://100.101.102.103:2586/swarmhub",
            "http://localhost/x",
            "http://192.168.1.20/x",
        ] {
            assert!(address(good).is_some(), "{good}");
        }
        for bad in ["http://ntfy.sh/topic", "ftp://example.com/x", "ntfy.sh/topic", "", "https://x.example/#frag", "http://8.8.8.8/x"] {
            assert!(address(bad).is_none(), "{bad}");
        }
        assert_eq!(title("Infra"), "Infra");
        assert_eq!(title("Księgowy"), "SwarmHub");
        assert_eq!(body("Księgowy", "Gotowe.\n  Dwa pliki."), "Księgowy: Gotowe. Dwa pliki.");
        assert_eq!(body("Infra", &"x".repeat(400)).chars().count(), BODY_CHARS);
    }

    #[tokio::test]
    async fn lines_that_notify_are_posted_once_in_order_and_old_ones_are_left_out() {
        let (_scratch, history) = testing::journal(&["Infra", "Jarvis"]);
        let heard: Arc<Mutex<Vec<(String, String)>>> = Arc::default();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let sink = heard.clone();
        let fail = Arc::new(Mutex::new(false));
        let failing = fail.clone();
        tokio::spawn(async move {
            let app = axum::Router::new().route(
                "/topic",
                axum::routing::post(move |headers: axum::http::HeaderMap, text: String| {
                    let (sink, failing) = (sink.clone(), failing.clone());
                    async move {
                        if *failing.lock().unwrap() {
                            return StatusCode::SERVICE_UNAVAILABLE;
                        }
                        let title = headers.get("title").and_then(|v| v.to_str().ok()).unwrap_or_default().to_owned();
                        sink.lock().unwrap().push((title, text));
                        StatusCode::OK
                    }
                }),
            );
            axum::serve(listener, app).await.unwrap();
        });
        let now = 1_763_294_400_000i64;
        let line = |bot: &str, text: &str, notify: bool, at: i64| {
            history.db().unwrap().execute(
                "INSERT INTO bot_history (bot,kind,text,at_ms,unread,notify) VALUES (?1,'notice',?2,?3,1,?4)",
                params![testing::id_of(bot), text, at, notify],
            ).unwrap();
        };
        let client = client();
        // Nothing is posted until an address is saved, and then only what comes after.
        line("Infra", "Before alerts were on.", true, now);
        assert_eq!(deliver_due(&history, &client, now).await, 0);
        {
            let db = history.db().unwrap();
            set(&db, ADDRESS, &format!("http://127.0.0.1:{port}/topic")).unwrap();
            let newest: i64 = db.query_row("SELECT max(id) FROM bot_history", [], |row| row.get(0)).unwrap();
            set(&db, CURSOR, &newest.to_string()).unwrap();
        }
        line("Infra", "Goal completed: 20 GB free on OVH", true, now);
        line("Infra", "A quiet line.", false, now);
        line("Jarvis", "Infra needs your answer.", true, now);
        assert_eq!(deliver_due(&history, &client, now + 1_000).await, 2);
        assert_eq!(deliver_due(&history, &client, now + 2_000).await, 0, "each once");
        assert_eq!(
            *heard.lock().unwrap(),
            [("Infra".to_owned(), "Goal completed: 20 GB free on OVH".to_owned()), ("Jarvis".to_owned(), "Infra needs your answer.".to_owned())]
        );
        // An address that is down loses nothing: the line goes out when it is back.
        *fail.lock().unwrap() = true;
        line("Infra", "The check-in got no answer.", true, now + 3_000);
        assert_eq!(deliver_due(&history, &client, now + 4_000).await, 0);
        *fail.lock().unwrap() = false;
        assert_eq!(deliver_due(&history, &client, now + 5_000).await, 1);
        // After a long outage only what is recent is sent.
        line("Infra", "Hours ago.", true, now);
        line("Infra", "Just now.", true, now + 2 * FRESH_MS);
        assert_eq!(deliver_due(&history, &client, now + 2 * FRESH_MS + 1_000).await, 1);
        assert_eq!(heard.lock().unwrap().last().unwrap().1, "Just now.");
    }
}
