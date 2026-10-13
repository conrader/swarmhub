# AgentApp Hermes FIX2 re-review (HERMES-FIX2.diff on 1f06298 + untracked files)

**Verdict: PASS-WITH-ISSUES.**

- **N1 is fixed.** History loading can no longer shrink or overwrite local chat.
- **N2 is fixed for a single run.** Stop now captures the run id, cancels locally, then POSTs in the background, and a second press is ignored.
- **H1–H4 remain fixed. N4 is resolved:** the source is now `api_server`. **L1 is fixed.**
- **Three new defects found:**
  - One MEDIUM: stop state leaks into the next run.
  - Two LOW-MEDIUM in the history parser and merge: `null` content becomes the text `"<null>"`, and a one-turn overlap match can duplicate rows.
- The AppStore tests are a real improvement. They do **not** prove the N2 ordering property, and **none of them has ever run**.

## Scope and limits (read first)

- **Not built, not run.** This host is Linux with no Swift toolchain, so everything here comes from reading the code. Codex reports that `swift test` is still blocked on the mini (`docs/hermes-integration.md:31`). So the 12 tests in `Tests/AgentAppTests/AgentAppTests.swift` are written and, by Codex's claim, type-checked, but **never executed**. No type-check log is in the tree.
- **Upstream not independently checked.** This session's permission layer again blocked `curl` and WebFetch of `raw.githubusercontent.com/NousResearch/hermes-agent@v2026.9.24`. Section A therefore checks Codex's evidence doc for internal consistency and specificity only.
- The tree matches HERMES-FIX2.diff on spot checks (`mergeHermesHistory`, `stopInProgress`, `normalizedContent`, `order=oldest` all appear in the diff).

---

## 1. Prior FAIL list

| # | Requirement | Status | Evidence |
|---|---|---|---|
| **N1** (HIGH) | Loads never shrink or overwrite local history | **Fixed (no data loss)** | `mergeHermesHistory` always returns `local + additions` or `nil` (`AppStore.swift:84-114`), so local rows are never rebuilt or dropped. Existing `ChatMessage` objects are reused, so their IDs, timestamps, reactions, `replyToID`, presentations and system/Stop/approval/delegation rows survive by construction. |
| | Empty, malformed or non-overlapping result can't wipe local chat | **Fixed** | An empty result with non-empty local history returns `nil` (`:85`). With no overlap, it returns `nil` (`:111`). A page whose `data` isn't an array throws (`HermesBackend.swift:80`), which only sets `errorMessage`. |
| | Append-only after verified overlap | **Fixed, but the overlap check is weak** | The longest local turn-suffix is matched against a server window (`:94-110`). A 1-turn match is accepted, and the *earliest* matching window wins (`:99`). See F2. |
| | Pre-Hermes messages kept (switched bots, upgrade from 0.20) | **Fixed** | Pre-session turns stay at the front. Only server rows after the overlap are appended. |
| | Page oldest-first through all 500-row pages | **Implemented; `order=oldest` is unsubstantiated** | `order=oldest&limit=500&offset=…` is requested until a page comes back short (`HermesBackend.swift:78-84`). The evidence says only that `order` is "supported" (`evidence.md:12`), not that `oldest` is an accepted value. The loop has no upper bound (F5). |
| | Multimodal content | **Mostly fixed. Bug: `null` content** | Arrays of strings, `{text}` and `{image_url}` parts are rendered (`HermesBackend.swift:131-144`). For any other value, including JSON `null` (`NSNull`), it falls back to `String(describing:)` (`:133`). See F3. |
| | Race guard | **Kept** | Before applying, the per-bot token, `isStreaming`, the session id and the message-id list are all re-checked (`AppStore.swift:78`). |
| **N2** (MEDIUM) | Capture run_id, cancel locally at once, then POST stop | **Fixed for a single run** | `stopTarget` makes no network call when the capability is cached; it reads the registry (`HermesBackend.swift:103-107`). It is awaited first, then the code calls `taskToCancel?.cancel()` and `isStreaming = false`, and only then `await requestStop` (`AppStore.swift:205-209`). Only an actor hop separates the press from the cancel. |
| | Reports the server outcome | **Fixed** | One system line for each `StopOutcome` (`:211-216`). A failed POST surfaces `errorMessage` (`:219`). "Stop requested" reflects an accepted request, not confirmed termination, which is fair wording. |
| | Second Stop is idempotent | **Fixed, but the flag is global and outlives the run** | The `stopInProgress` guard (`:196-197`) is held until the background POST returns (`:221`). See F1. |
| **H1** | Capabilities first; legacy never calls Sessions | **Still fixed** | `transport()` is unchanged (`HermesBackend.swift:40-55`). `listSessions`, `loadMessages` and `createSession` are each gated (`:64,75,89`). AppStore sends are gated (`AppStore.swift:165`), and so is history (`:75`). The legacy fixture now returns 500 on any `/api/sessions*` route (`hermes_v0.21.7_server.py:12-13`). |
| **H2** | No Mock or user bot deletion | **Still fixed. L1 fixed** | The only `removeAll` on bots is the user's `delete` (`AppStore.swift:150`). Stores written before `isDemo` existed mark mock bots named Atlas/Mira/Patch/Scout/Nova as demo bots (`Models.swift:81-86`), and those are hidden, not deleted, when Hermes is configured (`AppStore.swift:41`). The match is by name only, so a user's own pre-`isDemo` Mock bot called "Atlas" would be hidden. It can be recovered from the hidden list (LOW). |
| **H3** | Scoped approvals | **Still fixed** | `botID`, `profile` and `sessionID` are stamped when the event arrives (`AppStore.swift:177`). Cards are filtered by `botID` (`ChatView.swift:20`). `decide` builds its backend from `approval.botID` (`:225`). Approvals are cleared when the run ends (`:185`). |
| **H4** | No `listSessions().first` adoption | **Still fixed** | The harness is the only caller (`AgentApp.swift:33`). The session id is `agentapp_<uuid>`, and a 409 is treated as already owned (`AppStore.swift:166`, `HermesBackend.swift:94`). |
| N4 | `source:"desktop"` semantics | **Resolved** | Both create and list now use `api_server` (`HermesBackend.swift:65,90`), and the fixture asserts it. This holds whatever `desktop` would have changed. |

---

## 2. Findings, highest severity first

### MEDIUM

**F1. The background Stop POST leaks global state into the next run.** (`AppStore.swift:196,217-221`)
`stopInProgress` stays true for as long as the POST is pending, which can be URLSession's default 60 s. A slow or hung server is the usual reason to press Stop. Meanwhile the stream task finishes cleaning up and `streamTask` becomes nil, so the user can send a new message. Two problems follow:
- (a) Pressing Stop on the **new** run hits `guard … !stopInProgress` and does nothing. There's no local cancel at all, which is the original N2 symptom on the next turn.
- (b) If the old POST then fails (timeout, or 404 because the run had already ended), the catch block runs `isStreaming = false` (`:218`) while the **new** run is streaming. The Stop button disappears, the history guard (`:68`) is lifted mid-stream, and `send` stays blocked only because of `streamTask == nil`.

The late feedback line also lands after the new turn's placeholder.

*Fix (small):* make the guard per run. Capture `let run = streamTask` and only skip a press if `stopInProgress == run`. In the catch block, touch `isStreaming` only if `streamTask` is still the captured task, or just drop it, because the do block already cancelled. Optionally give the stop request a short timeout (5–10 s).

### LOW-MEDIUM

**F2. A one-turn overlap with an earliest-window match can append duplicates, and correctness depends on the unverified `order=oldest`.** (`AppStore.swift:95-113`, `HermesBackend.swift:79`)
The merge accepts an overlap of length 1 and picks the *first* server window that matches. If the server returns pages newest-first, for example because `oldest` is not an accepted value and the default is newest-first, then:
- every longer local suffix fails;
- the last local assistant turn matches server row 0;
- the whole older history is appended **in reverse** and saved;
- each later click appends more.

That is persistent corruption. Nothing is lost, but the bot's stored history grows. Repeated short turns ("ok", "continue") can trigger a smaller version of this even with the right order.

*Fix:* require an overlap of at least one full user→assistant pair when local history has two or more turns. Prefer the **last** matching window. Also confirm `order=oldest` against `api_server.py:3270-3303`, or sort the rows by timestamp or id before merging.

**F3. JSON `null` content is rendered as the literal text `"<null>"`.** (`HermesBackend.swift:133`)
`row["content"]` is `NSNull` for a `null` value, so `value.map { String(describing:) }` returns `"<null>"`. That passes the `!content.isEmpty` filter, and the row is kept as an assistant message. Assistant rows that only carry `tool_calls` usually have null content in OpenAI-style stores; whether Hermes does this is unverified. Where it does:
- these rows show up as `"<null>"` bubbles when appended, or when local history is empty (`AppStore.swift:89`);
- they break overlap matching for any tool-using turn.

*Fix (one line):* return `nil` for `NSNull` and for non-string scalars and dictionaries, except a single `{text}` object.

**F4. The merge rarely applies in practice, and it fails silently.**
Matching needs byte-identical content. Locally, a turn's assistant text is every delta plus any non-streamed commentary joined into one message (`AppStore.swift:172`, `HermesBackend.swift:233`). The server probably stores interim assistant text and tool-call rows separately. A Stop leaves a partial local reply. In all of these cases the local tail matches nothing on the server, the function returns `nil`, and nothing is merged until a later plain-text turn re-aligns the tail. This direction is safe, so it is not data loss. But "merge newer server turns" will often do nothing, and the user is never told. Consider surfacing "History not merged: local and server transcripts diverge."

### LOW

- **F5.** The paging loop `while true` has no page cap and no progress check (`HermesBackend.swift:78-84`). A server that ignores `offset` and returns 500 or more rows would loop forever and grow memory without limit. Every sidebar click also re-downloads the whole transcript, which means 10 requests for 5,000 messages.
- **F6.** The approval card can ask the user to approve an unseen command. If `approval.request` doesn't carry `description` and `command` under exactly those names, the card shows only the fallback text "Hermes needs approval / A tool action is waiting for your decision." Approve stays enabled (`HermesBackend.swift:237`, `ApprovalCard.swift:8-10`). The evidence doc cites `api_server.py:3743-3752`, but it doesn't list the payload keys (§A). Disable Approve, or show a warning, when no command text arrived.
- **F7. Carried over and still open:**
  - L6: `URLError.cancelled` leaves a stale run id in the registry (`HermesBackend.swift:217-218`). An early Stop on the next turn can then POST to the previous run, which now surfaces only as a misleading 404 error.
  - L4: `OSStatus` is ignored on Keychain writes (`KeychainStore.swift:8,11`), and the default key is still written on every keystroke (`SettingsView.swift:37`).
  - L5: `[::1]` handling is untested.
  - L7: tool status is captured but never shown, yet README:37 still lists "tool status capture".
  - L9: global `isStreaming`; history loads only on a sidebar click; the test harness ships in the production binary.
  - Mock and OpenClaw bots still say "this Hermes version has no run-control endpoint" when stopped (`AppStore.swift:213`).
- **F8.** Native send transmits only the last user message (`HermesBackend.swift:184`). After a bot switches to Hermes or the server is upgraded from legacy, the local history before the session is preserved locally but **not** given to the model. This is a design limitation and should be documented.

---

## 3. (A) Client vs `docs/hermes-v0.21.7-evidence.md`

| Claim | Client | Evidence quality |
|---|---|---|
| `source`: unknown values become `api_server`; tools are fixed by the API-server platform | `api_server` everywhere (`HermesBackend.swift:65,90`) | Paraphrase with line refs (`evidence.md:18`). Moot now that the client uses `api_server`. **Consistent.** |
| `POST /api/sessions` with client `id` → 201 `{session:{id}}`; duplicate → 409 `session_exists` | Handled (`:93-96`) | **Live transcript** (`evidence.md:33-43`). Strongest item. **Consistent.** |
| Every session-stream payload carries top-level `session_id` and `run_id` | Reads `run_id` from any event (`:212`) | Live transcript plus source paraphrase (`:10`). Resolves L10. **Consistent.** |
| Event names | `assistant.delta`, `assistant.commentary`, `tool.*`, `approval.request`, `assistant.completed`, `run.*` | Live: `run.started`, `message.started`, `assistant.completed`, `run.completed`, `done`; the client safely ignores the unknown ones. Delta, commentary, tool and approval events are source paraphrase only. Tool payload keys (`tool_name`/`tool`) and the commentary `already_streamed`/`text` keys are **not evidenced**. |
| Provider failure | — | Live: delivered as `assistant.completed` content followed by `run.completed`, **not** `run.failed`. The client therefore shows it as a normal reply, with no error and possibly a notification. That matches the server's semantics, but note it. |
| Approval body `{choice:"once"\|"deny", request_id}` | `:150-152` | Paraphrase of `api_server_runs.py:1165-1216` (`evidence.md:16`). **Consistent but not live.** The **event** payload keys (`request_id`, `description`, `command`) are not stated anywhere (F6). |
| `/v1/runs/{id}/stop` reaches session-stream runs | `:109-113` | Inferred from two paraphrases: registration in `_active_run_agents` (`:14`) and the stop handler (`:17`). **Plausible, not live-verified**, as `evidence.md:64` itself says. |
| Messages paging: `order`, `limit` ≤500, `offset` | `order=oldest` | **Unsubstantiated for the value `oldest`** (`evidence.md:12`). See F2. |
| v0.21.7 ↔ tag `v2026.9.24` | — | Asserted (`evidence.md:3`). Not checked. |

Overall, the evidence is far better than in the last pass: there is a real transcript of capabilities, create, 409 and SSE routing. However, the "source excerpts" are **paraphrases with line ranges, not verbatim code** (the brief asked for excerpts). The source copy still lives only in `/private/tmp` on the mini, which macOS clears on reboot. The highest-risk claims (Stop on session runs, approval payload, `order` values) are therefore still Codex's word. N3 is mostly closed, not fully.

## 4. (B) Security: **Pass**

- Keys are only ever read from or written to Keychain (`KeychainStore.swift`, service `com.konrad.agentapp.backends`; `SettingsView.swift:16-17,37,40`). No key goes through `UserDefaults`; `@AppStorage` holds only URLs and profile names. `store.json` holds no secrets.
- Plain-http keys are refused for any non-loopback host (`HermesBackend.swift:34-38,254`).
- There is no logging outside the env-gated harness, and the harness never prints the key.
- The bearer values in the evidence doc and fixture are throwaway test constants.
- L4 and L5 are unchanged, and F6 is a UX safety issue.

## 5. (C) Do the AppStore tests cover the gating?

The tests now drive `AppStore` through an injected `backendFactory`, which is real progress. Coverage:

| Target | Test | Real coverage? |
|---|---|---|
| H1 legacy send gating | `legacySendNeverCallsSessions` (`:92-101`) | **Yes.** It asserts no create/list/history call and no session id. |
| H4 non-adoption | `historyDoesNotAdoptForeignSession` (`:103-111`) | **Yes** for history. Nothing checks that `send` creates `agentapp_<uuid>`: the fixture checks the prefix only through the harness, not through AppStore. |
| N1 no-shrink | `historyMergeNeverShrinks…` (`:113-126`) | **Yes, for the pure merge.** It checks IDs, reactions, `replyToID`, and `nil` for empty and unrelated input. It does not test `loadHermesHistory` end to end (race guard, legacy early return), paging (the fixture always returns `[]` at `hermes_v0.21.7_server.py:30-32`), reversed order, or one-turn ambiguity. |
| N1 multimodal | `historyMergeAcceptsMultimodal…` (`:128-134`) | **Vacuous for parsing.** It passes pre-normalized strings, so `normalizedContent` is never exercised. A parser test would have caught F3. |
| N2 Stop | `stopCapturesThenCancelsThenPostsOnlyOnce` (`:136-147`) | **Partial.** Single POST, single feedback line and a single cancel are covered. **The ordering is not asserted:** "cancel" goes to `LockedTrace` and "post" to the actor's call log, and they are never compared. The `requestStop` stub also returns instantly. The pre-FIX2 implementation (await POST, then cancel) would pass this test. A stub that blocks in `requestStop` while the test asserts that `isStreaming == false` and that cancel happened would prove it. F1 is untested. |
| H3 scoping and clearing | `approvalIsScopedAndClearedAtRunEnd` (`:149-159`) | **Yes** for stamping and clearing. Not for `decide` routing to the owning bot's backend, because the factory ignores the bot. |
| H2 demo hiding / L1 | `legacyDemoBotsAreMigrated…` (`:161-171`) | **Yes.** It temporarily writes `hermesBaseURL` to the test process's standard defaults and restores it afterwards. |

All of these depend on fixed sleeps of 50–200 ms, so they will be flaky on a loaded machine. And again, **none of them has run.**

## 6. (D) Honesty of README and docs

- **Honest:**
  - README:14 now says the fallback doesn't run SwiftPM tests.
  - README:37 separates fixture coverage from what the credential-free live gateway can show.
  - `docs/hermes-integration.md:29` now says live SSE "routing", not streaming, and that the harness treats the provider-auth failure as a failure.
  - `:31` states exactly why `swift test` is blocked (`xcrun` → CoreDevice → missing `_XPCTypeBool` in Mercury.framework) and that a provider-backed cancel, approval pause and delegation are unverified live.
  - `evidence.md:64` makes the same admission.
- **Overstatements:**
  - `docs/hermes-integration.md:29` says the AppStore tests "cover … Stop ordering/idempotence". Ordering isn't asserted, and the sentence should say the tests are unexecuted rather than leave that to the next paragraph.
  - The claim that "the test target separately type-checks" (`:31`) has no log in the tree.
  - The claim of "non-destructive paged history merging" (README:37, docs:13) is true for data safety. It does not mention the F2 ordering assumption or that the merge often does nothing (F4).
  - `evidence.md:5` "Source excerpts" are paraphrases.
  - README:37 "tool status capture" is invisible in the UI (L7).

---

## Must fix before installing on the MacBook

1. **F1:** scope the Stop guard to the run being stopped. Don't reset `isStreaming` in the catch block unless the same stream task is still current. Ideally also put a short timeout on the stop POST.
2. **F3:** treat `NSNull` and non-text content as no content (`HermesBackend.swift:133`).
3. **F2:** require at least a user→assistant pair of overlap and prefer the latest matching window. Alternatively, confirm `order=oldest` in `api_server.py:3270-3303` and sort rows by timestamp before merging.
4. **Run `swift test` once on a Mac with a working `xcrun`**, for example the MacBook itself, and fix the Stop test so it asserts cancel-before-POST with a blocking `requestStop` stub. Then repeat the prior manual check against a 0.20.5 server: send, Stop, and confirm there is no `/api/sessions` request in the server log.
