use crate::{Workspace, token_matches};
use axum::{
    Router,
    extract::{
        Path, State, WebSocketUpgrade,
        ws::{Message, WebSocket},
    },
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::get,
};
use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    io,
    sync::atomic::{AtomicU32, Ordering},
    time::Duration,
};
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::UnixStream,
    time::timeout,
};

const DATA: u8 = 0;
const CREDIT: u8 = 1;
const CLOSE: u8 = 2;
const RESIZE: u8 = 3;
const FOCUS: u8 = 4;
const MAX_FRAME: usize = 16 * 1024 * 1024;
const WINDOW: u32 = 256 * 1024;
const WS_INPUT_LIMIT: usize = 64 * 1024;

pub fn routes() -> Router<Workspace> {
    Router::new()
        .route("/attach/{id}/{created}", get(upgrade))
        .route("/terminal-preview", get(|| async { axum::response::Html(include_str!("../web/terminal-preview.html")) }))
        .route("/terminal-preview.js", get(|| async { js(include_str!("../web/terminal-preview.js")) }))
        .route(
            "/chat-model.js",
            get(|| async { js(include_str!("../web/chat-model.js")) }),
        )
        .route(
            "/chat-terminal",
            get(|| async { axum::response::Html(include_str!("../web/chat-terminal.html")) }),
        )
        .route(
            "/terminal.js",
            get(|| async { js(include_str!("../web/terminal.js")) }),
        )
        .route(
            "/vendor/xterm.js",
            get(|| async { js(include_str!("../web/vendor/xterm.js")) }),
        )
        .route(
            "/vendor/addon-fit.js",
            get(|| async { js(include_str!("../web/vendor/addon-fit.js")) }),
        )
        .route(
            "/vendor/xterm.css",
            get(|| async {
                (
                    [(header::CONTENT_TYPE, "text/css; charset=utf-8")],
                    include_str!("../web/vendor/xterm.css"),
                )
            }),
        )
}

fn js(content: &'static str) -> ([(header::HeaderName, &'static str); 1], &'static str) {
    (
        [(header::CONTENT_TYPE, "text/javascript; charset=utf-8")],
        content,
    )
}

// The native web view loads these public assets on its loopback SSH listener.
pub(super) fn forwarded_resource(path: &str, headers: &HeaderMap) -> bool {
    let host = headers.get(header::HOST).and_then(|v| v.to_str().ok());
    let Some(host) = host else { return false };
    let Some((name, port)) = host.rsplit_once(':') else { return false };
    if !matches!(name, "127.0.0.1" | "localhost") || !port.parse::<u16>().is_ok_and(|p| p > 0 && p.to_string() == port) {
        return false;
    }
    // WebKit GETs through a forwarded port carry that port as Host. Only the
    // observer's geometry read is eligible. The API still requires its bearer token.
    if let Some(agent) = path.strip_prefix("/api/agents/").and_then(|s| s.strip_suffix("/geometry"))
        && let Some((address, created)) = agent.rsplit_once('/')
        && !address.is_empty() && !address.contains('/') && created.parse::<u64>().is_ok()
    {
        return headers.get("x-swarmhub-terminal-preview").is_some_and(|v| v == "1")
            && headers.get(header::ORIGIN).is_none_or(|v| v == format!("http://{host}").as_str());
    }
    if path.starts_with("/attach/") {
        return headers.get(header::ORIGIN).is_some_and(|v| v == format!("http://{host}").as_str());
    }
    matches!(path, "/terminal-preview" | "/terminal-preview.js" | "/chat-terminal" | "/terminal.js" | "/chat-model.js"
        | "/vendor/xterm.js" | "/vendor/xterm.css" | "/vendor/addon-fit.js")
}

#[cfg(test)]
#[test]
fn forwarded_terminal_accepts_its_assets_and_same_origin_attach() {
    let mut headers = HeaderMap::new();
    headers.insert(header::HOST, "127.0.0.1:49152".parse().unwrap());
    assert!(forwarded_resource("/chat-terminal", &headers));
    assert!(forwarded_resource("/vendor/xterm.js", &headers));
    assert!(!forwarded_resource("/api/agents/t1/5/geometry", &headers));
    headers.insert("x-swarmhub-terminal-preview", "1".parse().unwrap());
    assert!(forwarded_resource("/api/agents/t1/5/geometry", &headers));
    assert!(!forwarded_resource("/api/approvals", &headers));
    assert!(!forwarded_resource("/attach/t1/5", &headers));
    headers.insert(header::ORIGIN, "http://127.0.0.1:8787".parse().unwrap());
    assert!(!forwarded_resource("/attach/t1/5", &headers));
    headers.insert(header::ORIGIN, "http://127.0.0.1:49152".parse().unwrap());
    assert!(forwarded_resource("/attach/t1/5", &headers));
    headers.insert(header::HOST, "external.test:49152".parse().unwrap());
    assert!(!forwarded_resource("/chat-terminal", &headers));
}

async fn upgrade(
    State(workspace): State<Workspace>,
    Path((id, created)): Path<(String, u64)>,
    headers: HeaderMap,
    websocket: WebSocketUpgrade,
) -> Response {
    if !forwarded_resource("/attach/", &headers) {
        return StatusCode::FORBIDDEN.into_response();
    }
    websocket
        .max_message_size(WS_INPUT_LIMIT)
        .max_frame_size(WS_INPUT_LIMIT)
        .on_upgrade(move |socket| session(workspace, id, created, socket))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Connect {
    #[serde(default)]
    observe: bool,
    expected_core: Option<String>,
    token: String,
    cols: u16,
    rows: u16,
}

async fn session(w: Workspace, id: String, created: u64, mut ws: WebSocket) {
    let connect = match timeout(Duration::from_secs(5), ws.recv()).await {
        Ok(Some(Ok(Message::Text(text)))) => serde_json::from_str::<Connect>(&text).ok(),
        _ => None,
    };
    let Some(connect) = connect.filter(|request| token_matches(&request.token, &w.token)) else {
        let _ = ws
            .send(notice(
                "error",
                "The terminal access token was not accepted.",
            ))
            .await;
        return;
    };
    if !valid_size(connect.cols, connect.rows) {
        let _ = ws
            .send(notice(
                "error",
                "The requested terminal size is not supported.",
            ))
            .await;
        return;
    }
    let result = timeout(Duration::from_secs(8), async {
        if let Some(expected) = &connect.expected_core {
            if w.core.identify().await.ok()?.core.id != *expected { return None; }
        }
        let agent = w.core.agent(&id, created).await.ok()?;
        agent.require_live().ok()?;
        attach(
            &w.core.0,
            &agent.address,
            created,
            connect.cols,
            connect.rows,
            connect.observe,
        )
        .await
        .ok().map(|pair| (pair, agent.cols, agent.rows))
    })
    .await;
    let Ok(Some(((core, channel), cols, rows))) = result else {
        let _ = ws
            .send(notice(
                "error",
                "Could not attach to this Herdr session. It may have ended.",
            ))
            .await;
        return;
    };
    if ws.send(Message::Text(json!({"type":"ready","message":"Attached","cols":cols,"rows":rows,"observe":connect.observe}).to_string().into())).await.is_err() {
        return;
    }

    let (mut out, mut input) = ws.split();
    let (mut reader, mut writer) = tokio::io::split(core);
    let uncredited = AtomicU32::new(0);
    let inbound = async {
        while let Some(Ok(message)) = input.next().await {
            match message {
                Message::Binary(bytes) if !bytes.is_empty() => {
                    if connect.observe { break; }
                    if write_frame(&mut writer, channel, DATA, &bytes)
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Message::Text(text) => {
                    let Ok(control) = serde_json::from_str(&text) else {
                        break;
                    };
                    if connect.observe && !matches!(control, Control::Credit { .. }) { break; }
                    if send_control(&mut writer, channel, &uncredited, control)
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Message::Close(_) => break,
                _ => {}
            }
        }
        let _ = timeout(
            Duration::from_secs(1),
            write_frame(&mut writer, channel, CLOSE, &[]),
        )
        .await;
    };
    let outbound = async {
        loop {
            let Ok((stream, kind, payload)) = read_frame(&mut reader).await else {
                let _ = out
                    .send(notice(
                        "end",
                        "Connection to Herdr closed. The workspace did not end the session.",
                    ))
                    .await;
                break;
            };
            if stream != channel {
                continue;
            }
            match kind {
                DATA if !payload.is_empty() => {
                    let size = payload.len() as u32;
                    if size > WINDOW || uncredited.fetch_add(size, Ordering::AcqRel) > WINDOW - size
                    {
                        let _ = out
                            .send(notice(
                                "error",
                                "Herdr exceeded the terminal's output window.",
                            ))
                            .await;
                        break;
                    }
                    if out.send(Message::Binary(payload.into())).await.is_err() {
                        break;
                    }
                }
                CLOSE => {
                    let text = match serde_json::from_slice::<Value>(&payload)
                        .ok()
                        .and_then(|value| value.get("exit_code")?.as_i64())
                    {
                        Some(code) => format!("The terminal ended with exit code {code}."),
                        None => "Herdr closed the terminal stream.".into(),
                    };
                    let _ = out.send(notice("end", &text)).await;
                    break;
                }
                _ => {}
            }
        }
    };
    // Cancel the other half only on disconnect; never cancel and resume a partial frame read.
    tokio::select! { () = inbound => {}, () = outbound => {} }
}

fn notice(kind: &str, message: &str) -> Message {
    Message::Text(json!({"type":kind,"message":message}).to_string().into())
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
enum Control {
    Credit { bytes: u32 },
    Resize { cols: u16, rows: u16 },
    Focus { focused: bool },
}

async fn send_control(
    writer: &mut (impl AsyncWrite + Unpin),
    channel: u32,
    uncredited: &AtomicU32,
    control: Control,
) -> io::Result<()> {
    match control {
        Control::Credit { bytes } if bytes != 0 => {
            let mut count = uncredited.load(Ordering::Acquire);
            loop {
                let remaining = count
                    .checked_sub(bytes)
                    .ok_or_else(|| io::Error::other("invalid output credit"))?;
                match uncredited.compare_exchange_weak(
                    count,
                    remaining,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => break,
                    Err(actual) => count = actual,
                }
            }
            write_frame(writer, channel, CREDIT, &bytes.to_le_bytes()).await
        }
        Control::Resize { cols, rows } if valid_size(cols, rows) => {
            let [x, y] = cols.to_le_bytes();
            let [z, w] = rows.to_le_bytes();
            write_frame(writer, channel, RESIZE, &[x, y, z, w]).await
        }
        Control::Focus { focused } => {
            write_frame(writer, channel, FOCUS, &[u8::from(focused)]).await
        }
        _ => Err(io::Error::other("invalid terminal control")),
    }
}

fn valid_size(cols: u16, rows: u16) -> bool {
    (2..=300).contains(&cols) && (1..=120).contains(&rows)
}

async fn attach(
    path: &std::path::Path,
    id: &str,
    created: u64,
    cols: u16,
    rows: u16,
    observe: bool,
) -> io::Result<(BufReader<UnixStream>, u32)> {
    let mut socket = BufReader::new(UnixStream::connect(path).await?);
    let hello = b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"hello\",\"params\":{\"generation\":1,\"framed\":true}}\n";
    socket.write_all(hello).await?;
    let mut line = Vec::new();
    (&mut socket)
        .take(MAX_FRAME as u64)
        .read_until(b'\n', &mut line)
        .await?;
    let result = rpc_result(&line, 1)?;
    if result["generation"] != 1 || result["framed"] != true {
        return Err(io::Error::other("framed attach unsupported"));
    }
    let request = json!({"jsonrpc":"2.0","id":2,"method":"terminal.attach","params":{
        "terminal":id,"cols":cols,"rows":rows,"history":if observe { 0 } else { 250 },"observe":observe
    }});
    write_frame(&mut socket, 0, DATA, request.to_string().as_bytes()).await?;
    let (stream, kind, reply) = read_frame(&mut socket).await?;
    if stream != 0 || kind != DATA {
        return Err(io::Error::other("invalid attach reply"));
    }
    let result = rpc_result(&reply, 2)?;
    if result["terminal"]["address"] != id || result["terminal"]["created_ms"] != created {
        return Err(io::Error::other("attach target changed"));
    }
    let channel = result["channel"]
        .as_u64()
        .and_then(|x| u32::try_from(x).ok())
        .filter(|channel| *channel != 0)
        .ok_or_else(|| io::Error::other("invalid attach channel"))?;
    Ok((socket, channel))
}

fn rpc_result(bytes: &[u8], id: u32) -> io::Result<Value> {
    let mut json: Value = serde_json::from_slice(bytes).map_err(io::Error::other)?;
    if json["jsonrpc"] != "2.0" || json["id"] != id || json.get("error").is_some() {
        return Err(io::Error::other("Herdr refused terminal attach"));
    }
    let result = json["result"].take();
    if !result.is_object() {
        return Err(io::Error::other("invalid attach result"));
    }
    Ok(result)
}

async fn write_frame(
    writer: &mut (impl AsyncWrite + Unpin),
    channel: u32,
    kind: u8,
    payload: &[u8],
) -> io::Result<()> {
    let mut header = [0; 9];
    header[..4].copy_from_slice(&channel.to_le_bytes());
    header[4] = kind;
    header[5..].copy_from_slice(&(payload.len() as u32).to_le_bytes());
    writer.write_all(&header).await?;
    writer.write_all(payload).await
}

async fn read_frame(reader: &mut (impl AsyncRead + Unpin)) -> io::Result<(u32, u8, Vec<u8>)> {
    let mut header: [u8; 9] = [0; 9];
    reader.read_exact(&mut header).await?;
    let channel = u32::from_le_bytes(header[..4].try_into().unwrap());
    let length = u32::from_le_bytes(header[5..].try_into().unwrap()) as usize;
    if length > MAX_FRAME {
        return Err(io::Error::other("oversized Herdr frame"));
    }
    let mut payload = vec![0; length];
    reader.read_exact(&mut payload).await?;
    Ok((channel, header[4], payload))
}
