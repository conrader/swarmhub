//! Content-free Web Push wakes the installed workspace for a new failed CI watch.
use crate::{
    Workspace,
    history::{self, History, StoreError},
};
use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post},
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
use reqwest::Url;
use ring::{
    rand::SystemRandom,
    signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair},
};
use rusqlite::{Connection, OptionalExtension, params};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{collections::HashMap, time::Duration};

const DAY: i64 = 86_400_000;

pub(crate) fn routes() -> Router<Workspace> {
    Router::new()
        .route("/api/ci-push/key", get(public_key))
        .route("/api/ci-push/device", post(device))
}

fn signing_key(db: &Connection) -> Result<EcdsaKeyPair, StoreError> {
    let rng = SystemRandom::new();
    let key: Option<Vec<u8>> = db
        .query_row("SELECT pkcs8 FROM ci_push_key WHERE id=1", [], |r| r.get(0))
        .optional()?;
    if let Some(bytes) = key {
        return EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &bytes, &rng)
            .map_err(|_| StoreError);
    }
    let bytes = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
        .map_err(|_| StoreError)?;
    db.execute(
        "INSERT OR IGNORE INTO ci_push_key VALUES(1,?1)",
        [bytes.as_ref()],
    )?;
    signing_key(db)
}

async fn public_key(State(w): State<Workspace>) -> Result<Json<Value>, StoreError> {
    let db = w.history.db()?;
    Ok(Json(
        json!({"key": B64.encode(signing_key(&db)?.public_key().as_ref())}),
    ))
}

fn push_service(endpoint: &str) -> Option<Url> {
    let url = Url::parse(endpoint).ok()?;
    let host = url.host_str()?;
    let known = host.ends_with(".push.apple.com")
        || host == "fcm.googleapis.com"
        || host == "updates.push.services.mozilla.com";
    (known
        && endpoint.len() <= 4096
        && url.scheme() == "https"
        && url.port().is_none()
        && url.username().is_empty()
        && url.password().is_none()
        && url.fragment().is_none()
        && url.path().len() > 1)
        .then_some(url)
}

#[derive(Deserialize)]
struct Device {
    endpoint: String,
    enabled: Option<bool>,
}

async fn device(
    State(w): State<Workspace>,
    Json(input): Json<Device>,
) -> Result<Response, StoreError> {
    if push_service(&input.endpoint).is_none() {
        return Ok((
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(json!({"error":"This browser’s push service is unsupported."})),
        )
            .into_response());
    }
    let db = w.history.db()?;
    if input.enabled == Some(true) {
        db.execute("INSERT OR IGNORE INTO ci_push_devices(endpoint) SELECT ?1 WHERE (SELECT count(*) FROM ci_push_devices)<128", [&input.endpoint])?;
    } else if input.enabled == Some(false) {
        db.execute(
            "DELETE FROM ci_push_devices WHERE endpoint=?1",
            [&input.endpoint],
        )?;
    }
    let enabled: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM ci_push_devices WHERE endpoint=?1)",
        [&input.endpoint],
        |r| r.get(0),
    )?;
    if input.enabled == Some(true) && !enabled {
        return Ok((
            StatusCode::CONFLICT,
            Json(json!({"error":"This workspace has reached its push device limit."})),
        )
            .into_response());
    }
    Ok(Json(json!({"enabled":enabled})).into_response())
}

// Called inside the same transaction that records the first CI failure.
pub(crate) fn enqueue(db: &Connection, watch: i64, bot: &str, now: i64) -> rusqlite::Result<()> {
    db.execute(
        "INSERT OR IGNORE INTO ci_push_queue(device,watch,expires,next_try)
        SELECT id,?1,?3,?4 FROM ci_push_devices WHERE EXISTS
        (SELECT 1 FROM bots WHERE id=?2 AND notifications AND removed_ms IS NULL)",
        params![watch, bot, now + DAY, now],
    )?;
    Ok(())
}

struct Delivery {
    device: i64,
    watch: i64,
    endpoint: String,
    expires: i64,
    attempt: u32,
}

fn reserve(history: &History, now: i64) -> Result<Option<Delivery>, StoreError> {
    let mut db = history.db()?;
    // Idle workspaces should not acquire SQLite write locks on every tick.
    let due: bool = db.query_row(
        "SELECT EXISTS(SELECT 1 FROM ci_push_queue WHERE next_try<=?1)",
        [now],
        |r| r.get(0),
    )?;
    if !due {
        return Ok(None);
    }
    let Some(tx) = history::background_write(&mut db)? else {
        return Ok(None);
    };
    tx.execute("DELETE FROM ci_push_queue WHERE expires<=?1 OR NOT EXISTS
        (SELECT 1 FROM bot_checkins c JOIN bots b ON b.id=c.bot WHERE c.id=watch AND b.notifications AND b.removed_ms IS NULL AND c.ci_reviewed=0)", [now])?;
    let item = tx.query_row("SELECT d.id,q.watch,d.endpoint,q.expires,q.attempts+1 FROM ci_push_queue q
        JOIN ci_push_devices d ON d.id=q.device WHERE q.next_try<=?1 ORDER BY next_try,device,watch LIMIT 1",
        [now], |r| Ok(Delivery{device:r.get(0)?,watch:r.get(1)?,endpoint:r.get(2)?,expires:r.get(3)?,attempt:r.get(4)?})).optional()?;
    if let Some(d) = &item {
        tx.execute(
            "UPDATE ci_push_queue SET attempts=?3,next_try=?4 WHERE device=?1 AND watch=?2",
            params![d.device, d.watch, d.attempt, now + 60_000],
        )?;
    }
    tx.commit()?;
    Ok(item)
}

struct Vapid {
    tokens: HashMap<String, (i64, String)>,
}

impl Vapid {
    fn header(&mut self, history: &History, url: &Url, now: i64) -> Result<String, StoreError> {
        let origin = url.origin().ascii_serialization();
        if let Some((expires, token)) = self.tokens.get(&origin)
            && *expires > now + 600
        {
            return Ok(token.clone());
        }
        let db = history.db()?;
        let key = signing_key(&db)?;
        let expires = now + 43_200;
        let claims = json!({"aud":origin,"sub":"https://swarmhub.org/","exp":expires});
        let jwt = format!(
            "{}.{}",
            B64.encode(br#"{"typ":"JWT","alg":"ES256"}"#),
            B64.encode(claims.to_string())
        );
        let sig = key
            .sign(&SystemRandom::new(), jwt.as_bytes())
            .map_err(|_| StoreError)?;
        let token = format!(
            "vapid t={jwt}.{}, k={}",
            B64.encode(sig.as_ref()),
            B64.encode(key.public_key().as_ref())
        );
        self.tokens.retain(|_, (expiry, _)| *expiry > now);
        self.tokens.insert(origin, (expires, token.clone()));
        Ok(token)
    }
}

fn finish(
    history: &History,
    d: &Delivery,
    status: Option<StatusCode>,
    retry_seconds: Option<i64>,
) -> Result<(), StoreError> {
    let db = history.db()?;
    if matches!(status, Some(StatusCode::NOT_FOUND | StatusCode::GONE)) {
        db.execute("DELETE FROM ci_push_devices WHERE id=?1", [d.device])?;
    } else if status.is_some_and(|s| {
        s.is_success() || (s.is_client_error() && !matches!(s.as_u16(), 408 | 429))
    }) {
        db.execute(
            "DELETE FROM ci_push_queue WHERE device=?1 AND watch=?2 AND attempts=?3",
            params![d.device, d.watch, d.attempt],
        )?;
    } else {
        let delay = retry_seconds
            .unwrap_or(15 << d.attempt.min(8))
            .clamp(15, 86_400);
        db.execute("UPDATE ci_push_queue SET next_try=min(expires,?4) WHERE device=?1 AND watch=?2 AND attempts=?3", params![d.device,d.watch,d.attempt,history::now()+delay*1000])?;
    }
    Ok(())
}

pub(crate) async fn deliver(history: History) {
    let Ok(client) = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(12))
        .build()
    else {
        return;
    };
    let mut vapid = Vapid {
        tokens: HashMap::new(),
    };
    loop {
        let now = history::now();
        if let Ok(Some(d)) = reserve(&history, now) {
            if let Some(url) = push_service(&d.endpoint)
                && let Ok(token) = vapid.header(&history, &url, now / 1000)
            {
                let response = client
                    .post(url)
                    .header("Authorization", token)
                    .header("Topic", "swarmhub-ci")
                    .header("TTL", ((d.expires - now) / 1000).max(1))
                    .header("Urgency", "normal")
                    .header("Content-Length", 0)
                    .send()
                    .await;
                let retry = response
                    .as_ref()
                    .ok()
                    .and_then(|r| r.headers().get("retry-after")?.to_str().ok()?.parse().ok());
                let _ = finish(&history, &d, response.ok().map(|r| r.status()), retry);
            }
        } else {
            tokio::time::sleep(Duration::from_secs(5)).await;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bots::testing;
    use ring::signature::{ECDSA_P256_SHA256_FIXED, UnparsedPublicKey};

    #[test]
    fn accepts_only_push_service_urls() {
        for url in [
            "https://web.push.apple.com/Q",
            "https://fcm.googleapis.com/fcm/send/X",
            "https://updates.push.services.mozilla.com/wpush/v2/X",
        ] {
            assert!(push_service(url).is_some());
        }
        for url in [
            "https://127.0.0.1/X",
            "https://web.push.apple.com.example.org/X",
            "https://user@web.push.apple.com/X",
            "https://web.push.apple.com:444/X",
            "http://web.push.apple.com/X",
            "https://web.push.apple.com/X#extra",
        ] {
            assert!(push_service(url).is_none());
        }
    }

    #[test]
    fn signed_token_is_reused_for_its_origin_and_survives_workspace_reopen() {
        let (scratch, history) = testing::journal(&[]);
        let url = Url::parse("https://web.push.apple.com/test").unwrap();
        let mut vapid = Vapid {
            tokens: HashMap::new(),
        };
        let header = vapid.header(&history, &url, 1_000).unwrap();
        assert_eq!(
            vapid
                .header(&history, &url.join("/other").unwrap(), 4_600)
                .unwrap(),
            header
        );
        let (jwt, encoded) = header
            .strip_prefix("vapid t=")
            .unwrap()
            .split_once(", k=")
            .unwrap();
        let (signed, sig) = jwt.rsplit_once('.').unwrap();
        let public = B64.decode(encoded).unwrap();
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, &public)
            .verify(signed.as_bytes(), &B64.decode(sig).unwrap())
            .unwrap();
        let claims: Value =
            serde_json::from_slice(&B64.decode(signed.split_once('.').unwrap().1).unwrap())
                .unwrap();
        assert_eq!(claims["aud"], "https://web.push.apple.com");
        assert_eq!(claims["exp"], 44_200);
        drop(history);
        let reopened = History::open_at(&scratch.path().join("workspace")).unwrap();
        assert_eq!(
            signing_key(&reopened.db().unwrap())
                .unwrap()
                .public_key()
                .as_ref(),
            public
        );
    }
}
