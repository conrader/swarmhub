# OpenClaw integration (P12)

SwarmHub talks to an [OpenClaw](https://openclaw.ai) Gateway over its WebSocket RPC, wire protocol **4**, as a paired
operator device. Persona, tools, skills, memory and model accounts stay in the Gateway; SwarmHub holds no model or
provider key. Brief: [`briefs/P12.md`](../briefs/P12.md).

**Status: built and tested against a scripted fake Gateway only. No real Gateway was contacted while building P12, so
the last hop (a real handshake, a real model reply) is unverified.** Konrad's last-hop steps are at the end.

## Tested version and sources

- Contract: `@openclaw/gateway-protocol@2026.10.3` `protocol.schema.json` (sha256 `b7ab8a5113021fc73344ab5fef3d84009b4d9b0dfb852287eadd031fed65cf72`,
  510 methods, 1,050 definitions). `scripts/openclaw-schema-keys.py` writes the allowed and required keys of `ConnectParams`
  and of every method SwarmHub calls to `Tests/Fixtures/openclaw/param-keys.json`; a test checks every request SwarmHub builds
  against it.
- Docs (read 2026-10-14): `docs.openclaw.ai/gateway/protocol` and its pages handshake, auth, transport, rpc-session-control,
  rpc-bootstrap-and-events, rpc-devices-nodes-and-approvals; `/gateway/clients`, `/gateway/remote`, `/gateway/pairing`,
  `/gateway/operator-scopes`; `llms-full.txt`.
- Reference client (MIT, read, not copied): npm `@openclaw/gateway-client@2026.10.3` (`buildDeviceAuthPayloadV3`,
  `selectGatewayConnectAuth`, `shouldRetryGatewayWithDeviceToken`, `mergeChatStreamMessage`).

## What SwarmHub sends

- **Frames:** JSON text `{type:"req",id,method,params}`; replies `{type:"res",id,ok,payload|error}`; events
  `{type:"event",event,payload,seq?}`. Unknown fields and events are ignored; malformed frames are skipped.
- **Identity:** `client {id: gateway-client, mode: ui, platform: macos, deviceFamily: Mac, version, displayName}` (constants in
  `OpenClawClient`), role `operator`, scopes exactly `operator.read operator.write operator.approvals`, caps
  `chat-only-assistant-text tool-events exec-approvals`, `userAgent SwarmHub/<version>`. Nothing else (no locale, commands,
  permissions, admin scope).
- **Device proof:** one Ed25519 key per Gateway in the Keychain (`openclaw.<id>.device-key`), `device.id` = hex SHA-256 of the
  raw public key, base64url without padding, signed string
  `v3|deviceId|clientId|clientMode|role|scopes|signedAtMs|token|nonce|platform|deviceFamily` with `signedAt` = the challenge `ts`;
  one retry with `v2` after `DEVICE_AUTH_SIGNATURE_INVALID`.
- **Credentials:** the shared token (Keychain `openclaw.<id>.token`) serves the first connect; `hello-ok.auth.deviceToken` is
  written, read back, and only then the shared token leaves the Keychain (unless "Keep the Gateway token" is ticked). Later
  connects send `auth.deviceToken`. `AUTH_TOKEN_MISMATCH` retries once with the stored device token only when
  `canRetryWithDeviceToken` is true and the endpoint is loopback or `wss://`.
- **Methods:** `agents.list`, `sessions.create` (chat sessions `agent:<agentId>:<name>`, threads with `parentSessionKey`, `fork`,
  `forkFrom:"last-completed"`), `sessions.list`, `chat.send` (steer with `queueMode:"steer"`), `chat.abort`, `chat.history`
  (`limit 200`, `maxChars 20000`), `exec.approval.list`, `exec.approval.resolve` (`allow-once` or `deny`, never `allow-always`),
  `models.list` (the P17 model catalog, read only over a live link).
- **Events:** `chat` (rendered), `agent` tool events (shown as status), `tick` (watchdog), `exec.approval.requested` /
  `.resolved`.

A feature is offered only when its method is in `hello-ok.features.methods` and its scope is in `auth.scopes`; an optional
call or parameter the Gateway rejects (`INVALID_REQUEST`) hides only that feature for the connection. Nothing connects at
launch: the hub is created on first use; opening a chat by click, sending, Test, Connect and Add bots connect.

## Where the references disagree

1. **Doc example vs schema:** the handshake page's example sends `client.mode: "operator"` and `client.id: "cli"` /
   `"ios-node"`; the schema's `client.mode` enum has no `operator` and `client.id` has no `ios-node`. SwarmHub follows the
   schema (`gateway-client`, `ui`).
2. **`connect` scope:** the schema lists `connect` with scope `operator.admin`; the docs treat `connect` as the handshake any
   role sends. SwarmHub never asks for `operator.admin`.
3. **Client caps:** the handshake page lists `chat-only-assistant-text` (and `tool-events`, `inline-widgets`, `ultrafast`);
   the client-caps registry page lists `exec-approvals` and `approvals` but not `chat-only-assistant-text`. SwarmHub sends
   `chat-only-assistant-text`, `tool-events` and `exec-approvals` as briefed.
4. **`exec.approval.list`** has no params definition in the schema (`ExecApprovalListParams` does not exist), and its result
   shape is not defined; SwarmHub sends `{}` and reads `[…]`, `approvals`, `items` or `pending` leniently.
5. **`chat.history` result:** `sessionInfo`, `inFlightRun` and the message rows are untyped (`{}`) in the schema; SwarmHub reads
   the fields the docs name (`hasActiveRun`, `activeRunIds`, `inFlightRun.runId/text`, rows `role`, `content`, `timestamp`).
6. **HTTP tier:** the README line "not an OpenAI-compatible HTTP endpoint" is out of date; the Gateway has an optional
   OpenAI-compatible HTTP tier (off by default). SwarmHub uses only the WebSocket RPC, as the docs advise for native clients.
7. **URLProtocol and WebSocket tasks (brief vs macOS):** the brief says URLProtocol cannot see WebSocket tasks. A five-line
   probe on this MacBook (macOS 26, SDK 27) showed the opposite: a session's URLProtocol is asked `canInit(with: task)` for a
   `URLSessionWebSocketTask` and `startLoading` runs (on the request rewritten to `http://`). There is still no URLProtocol API
   that carries WebSocket frames, so the `GatewayTransport` seam and the scripted fake stay.

## Upgrading the tested version

1. Download the new `protocol.schema.json` into a fresh directory outside the repo and check its sha256.
2. `python3 -I scripts/openclaw-schema-keys.py <schema> Tests/Fixtures/openclaw/param-keys.json`, then `swift test`.
3. Re-read the handshake, auth and session-control pages for changed error codes or caps; update `OpenClawClient` and
   `ConnectVerdict` if needed, and this page.
4. A protocol bump (v5) breaks SwarmHub until updated: `PROTOCOL_MISMATCH` shows "This Gateway speaks protocol …".

## Security and privacy

Only the Gateway the user entered receives anything: the client metadata above (device name editable, no hostname or
account), this Gateway's public key and signatures, the token on the first connect, chat text, images, approval decisions and
session titles "SwarmHub · <bot>". Secrets live only in the Keychain; no frame is logged; every error passes a redactor.
Public `ws://` is refused; plaintext on a private network needs a tick box. A paired device can read and write the Gateway's
sessions, and an agent that may run tools can run commands on the Gateway host (with approvals only if its policy asks).
Approvals for runs SwarmHub did not start, including the Gateway's own automations, are always ask-only.

## Konrad's last hop (not done here)

1. On a machine running OpenClaw 2026.8 or later: `openclaw gateway auth-token --show`; if remote,
   `ssh -N -L 18789:127.0.0.1:18789 user@host`.
2. SwarmHub → Settings → Advanced → Servers and keys → OpenClaw → Add Gateway (`ws://127.0.0.1:18789`, the token) → Test.
   Expect Connected (a tunnel pairs silently); if it says "Waiting for approval", run the `openclaw devices approve <id>` shown.
3. Add bots, send "Reply with exactly: SwarmHub OK", press Stop on a long answer, answer one approval, reply in a thread.
4. Also check once with a LAN `ws://` address whether macOS asks for Local Network access (loopback never does).
5. Report any difference from this page; that is P12b's first input.
