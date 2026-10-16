# P55 — SwarmHub's voice requests vs. codex-cli 0.162 app-server protocol

Source: `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex` (`codex --version` → `codex-cli 0.162.0-alpha.17.2`).
`codex app-server --help` lists `generate-json-schema` and `generate-ts` ("[experimental] Generate JSON Schema / TypeScript
bindings for the app server protocol"). Generated offline with a throwaway `CODEX_HOME`:
`codex app-server generate-json-schema --experimental --out …` and `codex app-server generate-ts --experimental --out …`
(no app-server, no sign-in, no voice session, no microphone).

| SwarmHub sends / handles | Protocol 0.162 (schema) | Result |
|---|---|---|
| `initialize` `{clientInfo:{name,title,version}, capabilities:{experimentalApi:true}}` | `InitializeParams` requires `clientInfo`; `InitializeCapabilities.experimentalApi`; realtime methods are marked EXPERIMENTAL | match (experimental opt-in is needed and sent) |
| `initialized` notification | `ClientNotification` method `initialized` | match |
| `thread/start` `{ephemeral, sandbox:"read-only", approvalPolicy:"never", developerInstructions, config:{web_search:"disabled"}}` | `ThreadStartParams`: all optional; `SandboxMode` has `read-only`; `AskForApproval` has `never`; `config` is a free map (keys not validated by the schema) | match |
| reads `result.thread.id` | `ThreadStartResponse.thread` (required) | match |
| `thread/realtime/start` `{threadId, outputModality:"audio", transport:{type:"websocket"}, version:"v3", includeStartupContext:false, prompt, initialItems?:[{role:"user",text}]}` | `ThreadRealtimeStartParams` requires `threadId`, `outputModality` (`text`/`audio`); `transport` `{type:"websocket"}`; `version` `v1`/`v2`/`v3`; `prompt`, `includeStartupContext`, `initialItems` (`ThreadRealtimeInitialItem {role: user/developer/assistant, text}`, V3 only) | match |
| `thread/realtime/appendAudio` `{threadId, audio:{data, sampleRate, numChannels, samplesPerChannel}}` | `ThreadRealtimeAppendAudioParams {threadId, audio: ThreadRealtimeAudioChunk}`; chunk requires `data`, `sampleRate`, `numChannels`; `samplesPerChannel`, `itemId` optional | match |
| `thread/realtime/stop` `{threadId}`, `thread/unsubscribe` `{threadId}` | `ThreadRealtimeStopParams`, `ThreadUnsubscribeParams` `{threadId}` | match |
| `thread/realtime/listVoices` `{}` (connection check) | `ClientRequest` method exists | match |
| notifications `started`, `itemAdded`, `item/started`, `item/transcript/delta`, `item/completed`, `transcript/delta`, `transcript/done`, `outputAudio/delta`, `error`, `closed` (all `thread/realtime/…`) | `ServerNotification` has exactly these, plus `thread/realtime/sdp` (WebRTC only, not used) | match |
| `thread/realtime/error` → showed a fixed line | `ThreadRealtimeErrorNotification {threadId, message}` — no `code` field | **fixed**: the message is now shown and logged (redacted); a `code` is read if a build ever sends one |
| `thread/realtime/closed` early → fixed line | `ThreadRealtimeClosedNotification {threadId, reason?}` | **fixed**: the reason is shown (redacted) |
| JSON-RPC error responses → mapped to fixed `unavailable`/`invalidResponse`, code and message dropped | `JSONRPCErrorError {code (int64), message, data?}` | **fixed**: `CodexRPCError(code, message)` reaches the voice window as "ChatGPT refused live voice: <code> <message>" (redacted); `data` is never read |

Not compared: the `--disable` feature names passed to `codex app-server` (`shell_tool`, `unified_exec`, `apps`, `plugins`,
`multi_agent`) — the schema does not list features, and nothing beyond `--help`/schema/version was run.
