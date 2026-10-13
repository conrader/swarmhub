# AgentApp Hermes integration review (HERMES.diff on top of 1f06298 + untracked docs/scripts/fixture)

**Verdict: FAIL.** Do not install this build on the MacBook against real data or a real Hermes yet. The structure is sound: per-profile backends, `/p/<profile>/` routing, run-scoped Stop and approval calls, and keys kept in Keychain. But four HIGH defects remain. (1) The 0.20.x fallback cannot send from a new bot, which matters because the fleet runs 0.16–0.20.5. (2) Configuring Hermes permanently deletes user-created bots. (3) Approvals are still global and are resolved against whichever bot is selected. (4) Loading history adopts an arbitrary server session and then posts into it.

## Scope and limits (read first)

- **Not built, not run.** This host is Linux and has no Swift toolchain. One construct may not compile (see L1). Every claim below comes from reading the code.
- **I could not check the code against the upstream v0.21.7 sources.** In this session the permission layer denied `git clone`, WebFetch, and a delegated fetch of `github.com/NousResearch/hermes-agent` tag v0.21.7. As a result, check (1) of the brief is **not done against upstream**. It was done only for internal consistency against Codex's own `docs/hermes-integration.md`. Every wire-contract assumption the client makes is listed in the table in §1 and marked **UNVERIFIED**, with the file:line to check. Nothing in this review confirms that those endpoint names, event names or bodies exist in v0.21.7.
- The tree matches HERMES.diff. Every `+` hunk is present in the files that were read.

---

## 1. Hermes contract: what the client assumes (all UNVERIFIED against v0.21.7)

| Assumption | Where | What to check in `gateway/platforms/api_server*.py` @ v0.21.7 |
|---|---|---|
| Auth is `Authorization: Bearer <key>` on every request | `HermesBackend.swift:176` | Header name. Whether `/health/detailed` and `/v1/capabilities` need auth (the fixture accepts no auth at all) |
| `GET /health/detailed` → `{status, version}`, with fallback to `/health` on 404 | `:68-76` | Does the response include `version`? |
| `GET /v1/capabilities` → `features.session_chat_streaming` / `features.session_chat` (Bool) | `:94-100` | Exact feature key names. A wrong name silently sends every 0.21 user down the legacy path |
| `GET /api/sessions?limit=100&offset=0` → `data[]` or `sessions[]` with `id/title/preview` | `:30-37` | List key, sort order (see H4) |
| `POST /api/sessions {title, system_prompt, source}` → `{session:{id}}` | `:48-52` | Body keys and response nesting |
| `GET /api/sessions/{id}/messages?order=oldest&limit=500&inline_images=false` → `data[]` `{role, content:String}` | `:39-46` | Parameter semantics (M4), whether `content` can be a list |
| `POST /api/sessions/{id}/chat/stream {input, instructions}` | `:102-108` | Body key names (`input` vs `message`), and whether `instructions` overrides the session system prompt |
| SSE uses `event:` lines with single-line JSON `data:`. Names: `assistant.delta`/`message.delta` (`delta`/`text`), `tool.started/completed/failed` (`tool_name`/`tool`), `subagent.start/complete` (`task`, `profile`, `summary`, `status`), `assistant.completed` (`content`), `approval.request` (`run_id`, `request_id`, `description`, `command`), `run.completed/cancelled/failed`, `error` | `:149-162` | Every name and key. Is `run_id` at the top level of each payload (`:132`)? Does `assistant.completed` repeat the full text after the deltas (M1)? What status strings does `subagent.complete` use? |
| `POST /v1/runs/{run_id}/stop` stops a run that was started via the **session** stream | `:54-57` | Is a session-stream run registered in the runs table under the same id? |
| `POST /v1/runs/{run_id}/approval {choice:"once"\|"deny", request_id}` | `:61-66` | Path, `choice` values, and whether approvals on a session stream resolve through the runs endpoint |
| `/p/<profile>/…` prefix with a per-profile key | `:180-184`, `AppStore.swift:157` | Exact prefix, and confirm there really is no profile-list route |
| 0.20.x: `POST /v1/chat/completions`, OpenAI SSE, `X-Hermes-Session-Id`, `event: hermes.tool.progress` | `:110-118`, `:144-147` | Header name and semantics. If the server also loads stored session history, sending the full `messages` history (`:114-115`) duplicates context |

Internal consistency with Codex's own doc: the client matches what `docs/hermes-integration.md:9,15,19` describes. The exception is `docs:15`, which says `subagent.complete` carries `delegation_id`/`child_session_id`. The client ignores both fields (M2).

---

## 2. Findings, highest severity first

### HIGH

**H1. The 0.20.x fallback cannot send from any new bot, and every history load shows an error.**
`AppStore.send` always calls `createSession` (`POST /api/sessions`) for a Hermes bot that has no `hermesSessionID` (`AppStore.swift:114`). This happens *before* `HermesBackend.send` probes capabilities (`HermesBackend.swift:26`). Codex's doc says a server without `/v1/capabilities` is "typical 0.20.x" and that "durable REST session loading … require[s] the newer surface" (`docs/hermes-integration.md:19`). On such a server the call returns 404, the alert reads "HTTP 404", and the send never reaches the legacy chat-completions path. Separately, every sidebar click calls `loadHermesHistory` (`SidebarView.swift:36` → `AppStore.swift:66` → `GET /api/sessions`), which also returns 404 and shows an error alert. The brief says the servers run 0.16–0.20.5, so in practice the fallback is the main path, and it is broken. No test covers it: the fixture has no `/v1/chat/completions` route and no `POST /api/sessions` route.
*Fix:* probe capabilities once per backend. On legacy servers, use a client-generated session id (the `bot.id` path that existed before) and skip both `createSession` and the history load.

**H2. Configuring Hermes permanently deletes every Mock-backend bot, including bots the user created.**
`AppStore.swift:35` runs `bots.removeAll { $0.backend == .mock }` whenever `hasHermesConfiguration` is true. Merely having edited the URL field or set a key makes it true (`:46`). The next `refreshHermesAgents()` then calls `save()` (`:57`), which writes the deletion to `store.json`. No backup is made and no message is shown. The new-bot editor still defaults to `.mock` (`BotEditorView.swift:5`), so any bot created without changing the picker, and all of its history, disappears on the next launch. The brief asked to disable mock *behaviour* when a real connection exists. It did not ask to destroy stored conversations.
*Fix:* never delete stored bots. Skip *seeding* demo data when Hermes is configured, and hide or label Mock bots instead. Default the editor to `.hermes` when Hermes is configured.

**H3. Approvals are still global and are resolved against whichever bot is selected (previous M1, now with real consequences).**
`store.approvals` is a single list, and it is rendered in **every** bot's chat (`ChatView.swift:20`). `decide()` writes "Approved:/Declined:" into `selectedBot` and builds the backend from `selectedBot` (`AppStore.swift:148-150`). Suppose an approval arrives from profile A while the user is viewing profile B. The decision is then POSTed to `/p/B/v1/runs/<A's run>/approval` with B's key. Runs are profile-scoped (`docs:13`), so this fails with 401/404. Run A stays blocked waiting for approval, and the note is filed in B's chat. Approvals are also never removed when their run completes, fails or is cancelled (`AppStore.swift:123,131`), so stale cards stay clickable and produce errors. One improvement since the last review: errors are now shown (`:150`) instead of being swallowed. The mock path still adds a fake approval on every reply (`MockBackend.swift:18`).
*Fix:* store `botID` (or the profile) on `ApprovalRequest`, render the card only in that bot's chat, resolve it with that bot's backend, and drop the run's approvals when the stream ends.

**H4. Loading history adopts an arbitrary server session, then posts the user's messages into it.**
If a bot has no session yet, `loadHermesHistory` sets `bot.hermesSessionID = listSessions().first?.id` (`AppStore.swift:66`). That is whichever session the server lists first for the profile. It could be a Telegram, CLI or cron conversation, or one belonging to another client. Every later send goes into that session (`:115-116`), and the session id is saved in `store.json`. Nothing filters by `source: "agentapp"`, which the app sets itself in `HermesBackend.swift:49`. Nothing asks the user either.
The same function has a **race with sending**. `!isStreaming` is checked only on entry (`:62`). If the user sends while the load is still in flight, `bot.messages` is replaced wholesale (`:69`). The new user message and the streaming assistant message disappear. The stream then keeps writing into an orphaned `ChatMessage`, and the next `save()` persists the history without them. A full reload on every sidebar click (`SidebarView.swift:36`) also discards local delegation cards and "Approved:" notes.
*Fix:* only adopt sessions this app created (filter by source, or keep the created id), or show a picker. When the load returns, discard the result if a send started or `messages` changed since the load began.

### MEDIUM

**M1. The reply may be doubled.** `assistant.completed` sends the full `content` as one more `.token` (`HermesBackend.swift:155`). If v0.21.7 emits `assistant.delta` tokens *and then* `assistant.completed` with the full text, every reply appears twice. This is UNVERIFIED, and the fixture never emits `assistant.completed` (`Tests/Fixtures/hermes_v0.21.7_server.py:15-21`). If it is confirmed, this becomes HIGH. *Fix:* use `content` only when no deltas arrived, or replace the text instead of appending.

**M2. Sub-agent start and complete are not linked.** Each event gets a new `UUID()` (`HermesBackend.swift:153-154`). Overview therefore shows a "Running" row that never resolves plus a separate "Completed" row, and the chat gets two cards per delegation (`AppStore.swift:120-122`). `delegation_id`, which Codex's own doc says exists (`docs:15`), is ignored. Any status other than the exact string `"completed"` is shown as **failed** (`:154`). `subAgentTasks` is memory-only, while the inline cards are saved and are then removed by H4's history reload.

**M3. Stop can silently do nothing.** `cancel()` returns without a request when no `run_id` has been seen yet (`HermesBackend.swift:55`). That covers Stop pressed during `createSession`, during the capabilities probe, before the first event, and always on the legacy path. Errors from the stop request are discarded (`_ = try?`, `:56`), so a 401 or 404 looks like a successful stop. The app also does not show whether the server-side run actually ended; that depends on whether Hermes aborts a run when the client disconnects, which is UNVERIFIED. The registry is cleared only after a clean EOF (`:136`), not on error or cancellation.

**M4. History loads the *oldest* 500 messages.** The query is `order=oldest&limit=500` (`HermesBackend.swift:41`). If the parameters mean what their names say, a session with more than 500 messages shows its first 500 and drops the most recent ones. Rows whose `content` is not a `String` (multimodal or list content) are dropped silently (`:43`).

**M5. The API key can be sent in cleartext.** `validatedBaseURL` accepts `http` for any host (`HermesBackend.swift:21`). The Bearer key goes over plain HTTP to whatever remote host is configured. This was previous M6; now that real keys are in use it matters more. *Fix:* require `https` unless the host is loopback. `KeychainStore.set` still ignores `OSStatus` (`KeychainStore.swift:8-11`) and is called on every keystroke.

**M6. The "Named keys" field writes secrets to the wrong Keychain accounts.** `SettingsView.swift:36-37` parses `profile=key` on every keystroke. Editing a name writes the key under each intermediate name (`hermes.researc`, `hermes.research`, …), and those orphaned secrets are never cleaned up. Whitespace is not trimmed: `research = k` is stored under the account `hermes.research ` with the key ` k`. A key cannot be deleted, because an empty value fails the `count == 2` check. The field is blank every time Settings opens, so the user cannot see which profiles have keys. If a named profile fails discovery (wrong key, 401), it is skipped silently (`HermesBackend.swift:89`), and the result only reports "N profile(s)".

**M7. The integration test does not check anything.**
- `runHermesIntegration` returns `true` whenever nothing throws (`AgentApp.swift:33-35`). It asserts no token text, no `run_id` capture, no stop call and no approval call. If parsing produced zero events, it would still pass.
- The fixture is 33 hand-written lines, not something "copied from v0.21.7 api_server.py" (`Tests/Fixtures/hermes_v0.21.7_server.py:1`). It does not check `Authorization`. It has no `/p/<profile>/` routes, no `POST /api/sessions` (the session list is non-empty, so `createSession` never runs), no `/v1/chat/completions` (the fallback is never exercised), and no `tool.*`, `assistant.completed` or `run.completed` events.
- The script requires `/private/tmp/hermes-test/venv/bin/python` (`scripts/test-hermes-integration.sh:6`), which is not part of the repo.
- The test runs inside the GUI process after `AppStore(demoMode: false)` is constructed (`AgentApp.swift:11,14-15`). If the developer has Hermes configured, the run calls `refreshHermesAgents`, triggers H2 and **rewrites the real `store.json`**.
- The two new unit tests (`AgentAppTests.swift:13-25`) are only Codable round-trips. Nothing tests `parseNative`, `endpoint()`, `validatedBaseURL` or the profile prefix, even though these are pure and easy to test.

**M8. README and docs claim more than was verified.**
- README:37 says "real run Stop, approvals, tool status … work". `docs/hermes-integration.md:23` admits Stop and approval were never exercised live.
- Tool status is captured into `metadata["status"]` (`AppStore.swift:119`) but **never displayed**. `MessageView` reads `status` only in `DelegationCard` (`MessageView.swift:50-55`).
- The "real gateway ran on port 18642 … full session SSE lifecycle exercised live" claim (`docs:23`) has no log or transcript in the tree, and the only runnable test targets the fixture.
- README:45 says "Verified against v0.21.7 source", which this review could not confirm.
- README:14 ("The fallback was used to verify this prototype") is still stale.

### LOW

- **L1 (possible compile error).** `} catch where candidate == "default" { throw error }` (`HermesBackend.swift:88`) has no catch pattern. As far as I know the Swift grammar requires a pattern before `where` (`catch let error where …` / `catch _ where …`). The build will settle this.
- **L2.** `isStreaming` is still global (previous L1). Only one bot can stream at a time, and while any bot streams, `loadHermesHistory` is a no-op for all bots.
- **L3.** Every send makes an extra `/v1/capabilities` round trip (`HermesBackend.swift:26`). A non-404 failure from that probe (401, 500, timeout) fails the send instead of falling back.
- **L4.** `addingPercentEncoding(.urlPathAllowed)` leaves `/` unescaped in profile names and session ids (`HermesBackend.swift:40,103,182`). A profile named `a/b` changes the request path. The input is under the user's control, so the impact is low.
- **L5.** Profiles removed from Settings keep their bots. If the server is unreachable or a key is wrong at launch, an alert appears on every start (`AppStore.swift:43,58`). After "Test & Discover", Mock bots stay until the next relaunch, so demo and real bots are mixed.
- **L6.** History is loaded only on a sidebar click. The bot selected at launch and bots chosen through ⌘K (`ContentView.swift:36`) do not load it.
- **L7.** The test-only integration harness ships in the production binary behind an environment variable (`AgentApp.swift:14-37`).
- **L8.** `Package.swift:12` does not exclude `BRIEF-hermes.md`, `HERMES.diff`, `REVIEW-*.md`, `brief.md` or the other briefs, so SwiftPM will print warnings.
- **Still open from REVIEW-prev:** M4 (re-render on every token), M7 (60 s default timeout, line-per-line SSE; `bytes.lines` drops blank lines, so only single-line `data:` events work), L2 (snapshot ignores `AGENTAPP_APPEARANCE`), L3 (an invalid URL loses the draft), and the trivial-test and dense-code items.

## 3. Security summary

- Keys: the default key is stored in Keychain account `hermes` and named keys in `hermes.<profile>` (`SettingsView.swift:34,37`). **No secret is written to `store.json`**: the `Bot` encoder adds only `hermesProfile`/`hermesSessionID` (`Models.swift:87`), and approvals are not persisted. Nothing logs a key. `print` appears only in the env-gated integration harness, and the key travels only in the header. These points pass.
- Problems: plain HTTP to remote hosts (M5), orphaned Keychain items written on every keystroke (M6), unchecked `OSStatus`. Redirect behaviour with `Authorization` was not checked.

## 4. Mocks versus real connection

The demo is no longer seeded when Hermes is configured (`AppStore.swift:36-38`), which is correct. Removing the Mock bots, however, is destructive (H2), and Mock remains selectable and is the default in the editor. Any Mock bot that is still present still injects fake sub-agents and approvals (`MockBackend.swift:10,18`).

---

## Must fix before installing on the MacBook

1. **H2.** Never delete stored bots. Default new bots to Hermes when Hermes is configured.
2. **H1.** Gate `createSession` and history loading on capabilities, and test a send against a **0.20.5** server (the fleet's actual version).
3. **H3.** Scope approvals to their bot and run, resolve them with that bot's backend, and clear them when the run ends.
4. **H4.** Stop adopting `listSessions().first`, and guard the history replacement against a concurrent send.
5. Check the §1 table against the v0.21.7 `api_server*.py` source, at minimum the M1 duplication, event and key names, the approval body, and Stop on session-stream runs. Then make `runHermesIntegration` assert those results.
6. M5: require HTTPS for non-loopback hosts.
7. Run `./scripts/build.sh` and `swift test` on the Mac (L1 may not compile), then run a live check against a real gateway: send, Stop mid-run, one approval, two profiles.
