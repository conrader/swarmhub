# AgentApp Hermes fix pass: re-review (HERMES-FIX.diff on 1f06298 + untracked files)

**Verdict: FAIL (narrow).** All four prior HIGH findings (H1–H4) are fixed in the code as written. Do not install this build yet, for two reasons:

- **N1 (new, HIGH).** Loading history permanently overwrites a bot's local conversation with whatever the server returns.
- **N2 (MEDIUM).** Stop no longer stops locally until the server's stop request returns, which is a regression.

Both fixes are small. Separately, nothing in this review confirms the wire contract against upstream v0.21.7 (see Scope).

## Scope and limits (read first)

- **Not built, not run.** This host is Linux with no Swift toolchain, so every statement here comes from reading the code. `scripts/build.sh:10-22` falls back to a bare `swiftc` call when `xcrun` is broken. Codex's own notes say `xcrun` is broken on the mini, so **`swift test` probably never ran there**, and the unit tests are unexecuted too.
- **Not checked against upstream v0.21.7.** The session's permission layer blocked `git clone`, `git ls-remote` and WebFetch of `github.com/NousResearch/hermes-agent`, and it blocked them for a delegated agent as well. Section A therefore checks Codex's claims for internal consistency only. Every endpoint, event and body name below remains **UNVERIFIED by this review**.
- The tree matches HERMES-FIX.diff. The diff is against 1f06298, so it contains both Hermes passes.

---

## 1. Prior FAIL list

| # | Requirement | Status | Evidence |
|---|---|---|---|
| H1 | Probe capabilities before any session/history call; 0.16–0.20.x never calls Sessions; legacy Chat Completions | **Fixed** | `transport()` probes `/v1/capabilities` once and caches the result per `baseURL\|profile` (`HermesBackend.swift:40-55`). Only a 404 maps to legacy; other errors throw and are not cached. `listSessions`, `loadMessages` and `createSession` are each gated on `.nativeSessions` (`:63,74,83`). `send` creates a session only when the probe says native (`AppStore.swift:124`), otherwise it uses `bot.id.uuidString` with `/v1/chat/completions` and `X-Hermes-Session-Id` (`:128`, `HermesBackend.swift:143-151`). History load returns early on legacy (`AppStore.swift:70`). Discovery uses only `/v1/models`. Residual risk: a 0.20.x server that answers an unknown route with 401/405 instead of 404 would make every send fail (L3). |
| H2 | Never delete Mock/user bots; hide demo bots only; Hermes is the default for new bots | **Fixed** (one gap: L1) | No `removeAll` on bots remains, apart from the user-initiated `delete` (`AppStore.swift:109`). Demo bots are only hidden (`:36`). The Hermes seed is created only for a brand-new store (`:37-39`). The editor defaults new bots to `.hermes` when Hermes is configured (`BotEditorView.swift:18`). Gap: stores written before `isDemo` existed decode as `isDemo=false` (`Models.swift:80`), so the old Atlas/Mira/… demo bots stay visible as Mock bots, with fake sub-agents and fake "Send email?" approvals (`MockBackend.swift:10,18`). |
| H3 | Approvals scoped to bot/profile/session/run/request, rendered on that bot only, resolved with that bot's backend, cleared at run end | **Fixed** | `ApprovalRequest` carries `runID, requestID, botID, profile, sessionID` (`Models.swift:99-103`), and they are filled when the event arrives (`AppStore.swift:136`). Cards are filtered by `botID` (`ChatView.swift:20`). `decide` builds the backend, and therefore the key and `/p/<profile>` prefix, from `approval.botID` and not from `selectedBot`. It removes the card only on success and surfaces errors (`AppStore.swift:174-183`). Approvals for the bot+session are cleared when the stream ends, whether it completed, failed or was cancelled (`:144`). Minor: `ApprovalRequest.profile` is stored but never used, because the profile is re-derived from the bot. |
| H4 | Never adopt `listSessions().first`; deterministic app-owned session id per bot; discard a history replacement if a send/mutation happened meanwhile | **Fixed** (but see N1) | `listSessions` is now called only by the integration harness (`AgentApp.swift:33`). History loads only for a session the bot already owns (`AppStore.swift:71`). `createSession` posts `id: "agentapp_<bot uuid>"` and treats 409 as "already ours" (`AppStore.swift:125`, `HermesBackend.swift:82-91`). If the server ignores `id`, the server-assigned id that comes back is stored, which is still app-owned. The race guard compares a per-bot token (cleared by `send`, `:116`), `isStreaming`, the session id and the message-id list before replacing anything (`:73`). |

### Claimed medium fixes

| Item | Status | Evidence / note |
|---|---|---|
| Doubled reply | **Fixed** | `assistant.completed.content` is used only if no `assistant.delta`/`message.delta` arrived (`HermesBackend.swift:185,190`). The harness asserts `reply == "fixture reply"` (`AgentApp.swift:54`). Note that `assistant.commentary` text is concatenated into the reply with no separator (`:187`). |
| Stop feedback | **Fixed, but regressed: N2** | `StopOutcome` drives a system message for each case (`AppStore.swift:162-169`), and a failed stop request now shows an error. Mock/OpenClaw bots get the Hermes-specific text "this Hermes version has no run-control endpoint" (`MockBackend.swift:25`, `OpenClawBackend.swift:10`). |
| `order=latest` history | **Fixed (as claimed)** | `HermesBackend.swift:75`. Whether the newest page comes back in chronological order is Codex's claim (`docs/hermes-integration.md:11`) and is UNVERIFIED. |
| HTTPS except loopback | **Fixed** | `permitsAPIKey` is enforced in `makeRequest`, so it covers every request, named-profile keys included (`HermesBackend.swift:34-38,208`). It has unit tests (`AgentAppTests.swift:31-37`). `[::1]` is untested and depends on how `URL.host` returns brackets (L5). |
| Keychain orphan cleanup | **Fixed** | Named keys are now written only on "Save named keys", and accounts that are no longer listed are deleted (`KeychainStore.swift:25-37`, `SettingsView.swift:39-40`). Names and keys are trimmed, and an empty key deletes the entry. `SecItemAdd`/`SecItemDelete` still ignore `OSStatus`, so "saved" is shown even when a write fails (L4). |
| Temp-store integration test that asserts behaviour | **Partly fixed** | The temp store is used and `autoConfigureHermes` is off (`AgentApp.swift:12-13`), so the real `store.json` is no longer touched. Real assertions now exist: on the client side (reply, approval resolved, Stop accepted, legacy transport) and on the fixture side (bearer key, `source`, `id` prefix, `order=latest`, approval body, legacy header/body). A failing fixture `assert` returns 500, which fails the run. **Gaps:** the harness drives `HermesBackend` only. **None of the H1–H4 logic in `AppStore` is exercised**, so nothing tests send gating, non-adoption, the history guard, approval scoping/clearing or demo hiding. The legacy fixture still serves `/api/sessions` successfully, so it cannot prove that Sessions APIs are never called on legacy. It should 500 on any Sessions route in legacy mode. `guard storeURL.path.hasPrefix(temporaryDirectory)` (`AgentApp.swift:29`) is a tautology. |
| `catch … where` compile fix | **Fixed** | `catch let error where candidate == "default"` (`HermesBackend.swift:129`) is valid Swift. The other `catch <pattern> where` clauses (`:50,88,113`) are valid too. Not compiled here. |

---

## 2. New and remaining findings, highest severity first

### HIGH

**N1. Opening a Hermes bot permanently replaces its local conversation with the server's session transcript, losing every earlier message.**
Every sidebar click on a native-transport bot that owns a session runs `bot.messages = rows…; save()` (`AppStore.swift:74-75`, triggered from `SidebarView.swift:36`). The H4 guard protects against a concurrent send. It does **not** protect against the server transcript being shorter than, or different from, the local one. Paths that lose data:
1. **An existing bot switched to Hermes.** H2 now keeps Mock/user bots, and the editor lets the user change a bot's backend (`BotEditorView.swift:20`). The first send creates `agentapp_<id>`. The next click replaces the bot's whole prior history with the 2 server messages, and `store.json` is overwritten.
2. **A fleet server upgraded from 0.20.x to 0.21.** The fleet is on 0.16–0.20.5 today, so this upgrade is expected. Legacy bots hold all their history locally with no `hermesSessionID`. After the upgrade the first send creates a native session, and the next click wipes the legacy history.
3. **An empty or mis-parsed response.** If `/messages` returns a key other than `data`, or rows whose `content` is not a `String` (multimodal or list content is dropped at `HermesBackend.swift:77`), `rows` is empty. The guard still passes, and the local transcript is replaced with nothing.
4. **Routine loss on every click.** Local-only messages (Stop feedback, "Approved:/Declined:" notes, delegation cards) are discarded. Every message is also rebuilt with a new UUID and `createdAt = .now`, so reactions, `replyToID` links and timestamps are lost. Sessions with more than 500 messages are truncated to 500 (`:75`).

The prior review's H2 bar was "the brief did not ask to destroy stored conversations". This is the same class of defect.
*Fix (small):* never let a load shrink local history. Replace only when the local bot has no messages that predate `hermesSessionID`. Otherwise either (a) append only the server rows that come after the last locally-known turn, or (b) keep messages that existed before session creation and replace only the tail. Refuse an empty result when local history is non-empty. Preserve local system/delegation rows.

### MEDIUM

**N2. Stop regression: the stream keeps running until the server's stop request returns.**
`stop()` now awaits `activeBackend.cancel(…)`, a `POST /v1/runs/{id}/stop` with URLSession's default 60 s timeout, **before** cancelling the local task (`AppStore.swift:159-171`). The earlier fix cancelled immediately. If the server is slow or hung, which is a common reason to press Stop, tokens keep arriving for up to 60 s, `isStreaming` stays true and the composer stays locked. Pressing Stop again sends a second request and adds a second feedback line. Codex ordered the steps this way because cancelling first runs the registry `clear` in `sseStream`'s cancel path (`HermesBackend.swift:171`) and loses the run id.
*Fix:* read the run id first (or have `cancel` return a closure), cancel the local task immediately, then send the server stop in the background and report its outcome.

**N3. Wire contract still unverified by an independent reader, and the fixture is Codex's own transcription.**
The fixture (`Tests/Fixtures/hermes_v0.21.7_server.py:1`) is hand-written to match what Codex says v0.21.7 does. It is not derived mechanically from upstream. The following are all UNVERIFIED:
- event names `assistant.delta`, `assistant.commentary`, `approval.request`, `assistant.completed`, `run.cancelled`
- `run_id` sitting at the top level of each payload
- the approval body `{"choice":"once"|"deny","request_id"}`
- `POST /api/sessions` accepting a client `id` and returning `{session:{id}}`, with 409 on a duplicate
- `/v1/runs/{id}/stop` controlling a run started on the **session** stream
- `features.session_chat_streaming`

Codex says it read the tagged raw files and ran a real gateway, which is more evidence than the first pass had. No log, transcript or source excerpt is in the tree, though, and the cited source copy lives in `/private/tmp`, which macOS clears on reboot. Before trusting approvals and Stop on the MacBook, check `gateway/platforms/api_server.py` and `api_server_runs.py` @ v0.21.7 for these items, or capture and commit a short real-gateway transcript.

**N4. The `source: "desktop"` label may mean more than metadata.** (UNVERIFIED)
Hermes normalizes `agentapp` to `api_server`, so Codex switched to the allow-listed `desktop` (`HermesBackend.swift:64,84`; `docs:11`). That makes AgentApp sessions look like Hermes Desktop sessions, and they will appear mixed into Desktop's session lists. If v0.21.7 derives the platform from `source` to choose toolsets, approval mode or prompt hints (from memory, not checked here: Hermes picks toolsets per platform), AgentApp runs could get the Desktop toolset or policy instead of `api_server`'s. Ownership no longer depends on `source`, because the deterministic id handles it. *Recommendation:* omit `source` and accept `api_server`, unless upstream shows `desktop` has no behavioural effect.

**N5. The integration test does not cover the code that the H1–H4 fixes changed.** See the table in §1. The harness and the 5 unit tests never instantiate `AppStore` against the fixture. The pure functions `parseNative`, `endpoint()`/profile prefix and `transport()` caching are also untested. N1 and N2 would both pass the current suite.

### LOW

- **L1.** Stores written before `isDemo` keep demo bots visible as Mock bots, with fake approvals and sub-agents (§1, H2). Consider a one-time migration that marks the five seed bots with their seed content, or a "Mock" badge.
- **L2.** Sub-agent start and complete are still unlinked, because each event gets a fresh `UUID()` (`HermesBackend.swift:188-189`). The `delegation_id` that the fixture sends is ignored. This is moot for v0.21.7, which emits neither event. The Overview copy "Delegated work will appear here while Hermes runs sub-agents" (`InfoPanel.swift:42`) promises something v0.21.7's HTTP stream never delivers.
- **L3.** Only a 404 selects the legacy path (`HermesBackend.swift:50`). A 401/405/501 from an old server or a proxy fails every send. The capability cache is process-wide and never invalidated, so a server upgrade needs an app restart.
- **L4.** `KeychainStore.set` ignores `OSStatus` (`KeychainStore.swift:8,11`), and the default key is still written on every keystroke (`SettingsView.swift:37`). No orphans result, because it is a single account.
- **L5.** The loopback allowlist is exactly `localhost`/`127.0.0.1`/`::1` (`HermesBackend.swift:37`). The `[::1]` bracket handling is untested. Whether URLSession forwards `Authorization` on a redirect to plain http was not checked.
- **L6.** `sseStream` treats only `CancellationError` as a cancel (`HermesBackend.swift:171`). URLSession usually throws `URLError.cancelled`, which falls into the generic catch and leaves a stale run id in the registry. A later Stop pressed before the first event can then POST stop to the previous run.
- **L7.** Tool status goes into `metadata["status"]` (`AppStore.swift:132`) but is never displayed. `MessageView` reads `status` only for delegation cards (`MessageView.swift:50-55`). README:37 says "tool status capture", which is literally true and has no visible effect.
- **L8.** If a stop lands just as the run finishes, the run can end with `run.cancelled` before the local cancel. `cancelled` is then false, and a notification fires for a stopped reply (`AppStore.swift:143-146`). System notes and delegation cards are sent back as `system`/`assistant` turns on the legacy path (`:119`).
- **L9.** Carried over and still open: `isStreaming` is global (one bot streams at a time); history loads only on a sidebar click, not for the bot selected at launch or via ⌘K (`ContentView.swift:36`); the test harness ships in the production binary behind an env var (`AgentApp.swift:16-18`); `Package.swift:12` doesn't exclude the BRIEF/REVIEW/diff files (warnings only); profile names are percent-encoded with `.urlPathAllowed`, so `/` is not escaped (`HermesBackend.swift:218`).
- **L10.** Docs inconsistency: `docs:9` says every native event carries `session_id` and `run_id`, but the fixture's events carry only `run_id`, apart from `run.started`. This is harmless, but it is another sign the fixture isn't a transcript.

---

## 3. (A) Hermes client vs v0.21.7: what the client assumes

UNVERIFIED by this review (upstream access was blocked). Consistent with Codex's `docs/hermes-integration.md` except where noted.

| Area | Client behaviour | Where |
|---|---|---|
| Auth | `Authorization: Bearer <key>` on every request, including `/health/detailed` and `/v1/capabilities`. Omitted if the key is empty | `HermesBackend.swift:212` |
| Version | `GET /health/detailed` → `version`,`status`; falls back to `/health` on 404 | `:109-117` |
| Capabilities | `GET /v1/capabilities` → `features.session_chat_streaming == true` ⇒ native | `:47-49` |
| Sessions | `GET /api/sessions?source=desktop&limit=100&offset=0` (harness only); `POST /api/sessions {title, system_prompt, source:"desktop", id}`; `GET …/messages?order=latest&limit=500&inline_images=false` → `data[]{role, content:String}` | `:62-91` |
| Stream | `POST /api/sessions/{id}/chat/stream {input, instructions}`. SSE events: `assistant.delta`/`message.delta` (`delta`/`text`), `assistant.commentary` (`already_streamed`), `tool.started/completed/failed/progress`, `approval.request` (`run_id, request_id, description, command`), `assistant.completed` (`content`), `run.completed/cancelled/failed`, `error`. Single-line `data:` only | `:135-141,183-197` |
| Stop | `POST /v1/runs/{run_id}/stop` using the last `run_id` seen on the session stream; legacy = disconnect only | `:93-98` |
| Approval | `POST /v1/runs/{run_id}/approval {choice:"once"\|"deny", request_id}` | `:102-107` |
| Profiles | `/p/<profile>/…` with a per-profile key; no list route; discovery via `/v1/models` | `:119-133,216-220` |
| Legacy | `POST /v1/chat/completions` stream, OpenAI chunks, `[DONE]`, `X-Hermes-Session-Id`, `event: hermes.tool.progress` (`message`/`name`); sends full history plus a system message | `:143-151,178-181` |
| Source normalization | `agentapp`→`api_server` is acknowledged; the client uses `desktop` (see N4) | `docs:11` |
| Sub-agent events | Codex says v0.21.7's HTTP session stream emits none; parsing is kept for forward compatibility | `docs:17`, README:39 |

Open questions are carried over from the prior review: does the legacy server also persist history per `X-Hermes-Session-Id`, in which case sending the full `messages` array duplicates context? And does Hermes abort a run when the client disconnects (legacy Stop)?

## 4. (B) Security

- **Pass.** Keys live only in Keychain: account `hermes` and `hermes.<profile>`, service `com.konrad.agentapp.backends` (`KeychainStore.swift:5`). `store.json` encodes only `hermesProfile`/`hermesSessionID` (`Models.swift:88`). Approvals, which can contain command text, are not persisted. No `print`/logger outside the env-gated harness, and the harness prints profile ids, the session id and event kinds, never the key. The fixture's bearer `fixture` is a test constant.
- Plain http with a key is refused for non-loopback hosts (fixed M5).
- Remaining: unchecked `OSStatus` (L4) and unverified redirect behaviour (L5). Settings reads every named key back into a `SecureField` on open (`SettingsView.swift:17`), which is acceptable.

## 5. (C) Regressions of earlier fixes

- **Store:** corrupt-store backup and disabled persistence are intact (`AppStore.swift:25-35`). Injecting the store URL keeps the default path. No regression. N1 is new data loss, not a regression of this fix.
- **URL:** `validatedBaseURL`, trailing-`/v1` stripping and invalid-URL errors are intact (`HermesBackend.swift:29-32,216-220`).
- **Stop:** **regressed**, see N2. It was an immediate local cancel; it is now delayed until the network call returns.

## 6. (D) Honesty of tests, README and docs

- `docs/hermes-integration.md` is now largely honest. It says outright that sub-agent SSE is absent on v0.21.7 (`:17`). It says the clone was blocked and raw tag files plus a `/private/tmp` copy were used instead (`:25`). It says the live turn ended in a provider-authentication failure, and that the long-run cancel, a real approval pause and delegation were not exercised live (`:27`).
- One remaining overstatement: the live run is described as having "exercised native session SSE". With no provider key the turn produced only a failure event. The harness's live mode throws on `.failed` (`AgentApp.swift:51`) and would have exited 1, so the live run proves routing and auth, not streaming of a reply.
- README:37 and README:39 are honest about the fixture versus live split and about sub-agents being a stub. README:45 ("Checked against … v0.21.7 tagged source") is Codex's claim and not independently confirmed. README:14 ("The fallback was used to verify this prototype") is stale, and the fallback skips `swift test`. README:37 "tool status capture" is invisible in the UI (L7).
- The fixture header "matching the verified v0.21.7 API-server wire contract" overstates its provenance (N3).

---

## Must fix before installing on the MacBook

1. **N1:** make history loading non-destructive. Never shrink or replace local history that predates the bot's Hermes session. Refuse empty or unparseable results. Keep local system/delegation rows.
2. **N2:** cancel the local stream immediately on Stop, then request the server stop in the background with the run id captured beforehand.
3. **N3/N4:** confirm against `api_server.py`/`api_server_runs.py` @ v0.21.7 (or with a committed real-gateway transcript) the approval body, Stop on session-stream runs, `POST /api/sessions` with a client `id`, and whether `source:"desktop"` changes toolsets or policy. Drop `source` if unsure.
4. Build on a Mac with a working `xcrun` and run **`swift test`** there, not only the `swiftc` fallback. Run `scripts/test-hermes-integration.sh`, then do one manual check against a **0.20.5** fleet server: send, Stop, and confirm no `/api/sessions` request in the server log.
