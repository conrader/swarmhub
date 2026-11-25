#[tokio::test]
async fn team_registration_http_body_boundary() {
    use super::job_delivery::{AUTH, ORIGIN, workspace};
    use crate::history::History;
    use axum::{
        ServiceExt,
        body::{Body, to_bytes},
        extract::Request,
        http::StatusCode,
        response::Response,
    };
    use serde_json::{Value, json};
    use std::convert::Infallible;

    let root = tempfile::tempdir().unwrap();
    let history = History::open_at(&root.path().join("journal")).unwrap();
    let app = crate::workspace_router(workspace(root.path(), history));
    async fn dispatch(
        mut app: impl ServiceExt<Request, Response = Response, Error = Infallible>,
        req: Request,
    ) -> Response {
        app.call(req).await.unwrap()
    }
    let request = |method, path: &str, token: &str, origin: &str, body: Vec<u8>| {
        let req = Request::builder()
            .method(method)
            .uri(path)
            .header("Host", "localhost:41053")
            .header("Origin", origin)
            .header("Authorization", format!("Bearer {token}"))
            .header("Content-Type", "application/json")
            .header("Content-Length", body.len())
            .body(Body::from(body))
            .unwrap();
        dispatch(app.clone(), req)
    };
    let post = |body, token: &str, origin: &str| {
        let response = request("POST", "/api/bots", token, origin, body);
        async move { response.await.status() }
    };
    let directory = || async {
        let response = request("GET", "/api/bots", AUTH, ORIGIN, vec![]).await;
        assert_eq!(response.status(), StatusCode::OK);
        let bytes = to_bytes(response.into_body(), 1 << 20).await.unwrap();
        serde_json::from_slice::<Value>(&bytes).unwrap()
    };
    let settings = serde_json::to_vec(&json!({"ask_seconds": 910})).unwrap();
    assert_eq!(
        request("POST", "/api/bots/settings", AUTH, ORIGIN, settings)
            .await
            .status(),
        StatusCode::OK
    );
    let instructions = "雪".repeat(4096); // 12 KiB decoded, independently of the request limit.
    let peer = |text: &str| {
        serde_json::to_vec(&json!({"bots": [{
            "id": "other-install", "name": "Other installation", "instructions": text
        }]}))
        .unwrap()
    };
    assert_eq!(
        post(peer(&instructions), AUTH, ORIGIN).await,
        StatusCode::OK
    );
    assert_eq!(
        post(peer(&format!("{instructions}x")), AUTH, ORIGIN).await,
        StatusCode::UNPROCESSABLE_ENTITY
    );
    let original = directory().await;
    assert_eq!(original["bots"][0]["instructions"], instructions);
    assert_eq!(original["settings"]["ask_seconds"], 910);

    let mut bots: Vec<Value> = (0..25)
        .map(|i| {
            json!({
                "id": format!("bot-{i}"), "name": format!("Bot {i}"), "main": i == 0,
                "instructions": "雪\n\"\\".repeat(520),
            })
        })
        .collect();
    let encode = |bots: &[Value]| serde_json::to_vec(&json!({"bots": bots})).unwrap();
    let padding = 128_896 - encode(&bots).len();
    for (i, bot) in bots.iter_mut().enumerate() {
        let extra = "x".repeat(padding / 25 + usize::from(i < padding % 25));
        bot["instructions"] = format!("{}{extra}", bot["instructions"].as_str().unwrap()).into();
    }
    let saved = encode(&bots);
    assert_eq!(saved.len(), 128_896);
    assert_eq!(post(saved.clone(), AUTH, ORIGIN).await, StatusCode::OK);
    let mut boundary = saved;
    boundary.resize(131_072, b' '); // JSON trailing whitespace also counts on the wire.
    assert_eq!(post(boundary.clone(), AUTH, ORIGIN).await, StatusCode::OK);
    boundary.push(b' ');
    assert_eq!(
        post(boundary.clone(), AUTH, ORIGIN).await,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    assert_eq!(
        post(boundary.clone(), "wrong", ORIGIN).await,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(
        post(boundary, AUTH, "http://other.test").await,
        StatusCode::FORBIDDEN
    );

    bots[0]["main"] = false.into();
    bots.push(
        json!({"id":"bot-25", "name":"Bot 25", "instructions":"x".repeat(5100), "main":true}),
    );
    assert_eq!(
        post(encode(&bots), AUTH, ORIGIN).await,
        StatusCode::PAYLOAD_TOO_LARGE
    );
    let before = directory().await;
    assert_eq!(before["bots"].as_array().unwrap().len(), 26);
    assert_eq!(before["main"], "bot-0");

    // The promotion commits first. Every omitted peer survives each upsert and its retry.
    for batch in [&bots[25..], &bots[..25], &bots[..25]] {
        assert_eq!(post(encode(batch), AUTH, ORIGIN).await, StatusCode::OK);
        let directory = directory().await;
        assert_eq!(directory["main"], "bot-25");
        let listed = directory["bots"].as_array().unwrap();
        assert_eq!(listed.len(), 27);
        assert!(listed.contains(&original["bots"][0]));
        assert_eq!(directory["settings"], original["settings"]);
    }
    let after = directory().await;
    for bot in bots {
        let saved = after["bots"]
            .as_array()
            .unwrap()
            .iter()
            .find(|saved| saved["id"] == bot["id"])
            .unwrap();
        assert_eq!(saved["instructions"], bot["instructions"]);
    }
}
