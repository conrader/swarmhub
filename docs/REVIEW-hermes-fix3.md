# AgentApp Hermes FIX3 re-review (HERMES-FIX3.diff on 1f06298 + untracked files)

**Verdict: PASS-WITH-ISSUES.**

- **F1 is fixed.** Stop state is now scoped to the stream token. An older Stop POST can no longer block a later Stop or clear `isStreaming` for a newer run.
- **F3 is fixed.** `null`, scalar and unsupported content is dropped, and `{text:…}` is kept.
- **F2 is fixed in substance.** Established histories now need a user→assistant overlap, the longest suffix wins, then the latest window. The paging loop is bounded, and hitting the bound raises an error rather than truncating silently.
- **N1/N2 and H1–H4 remain fixed.**
- **No new MEDIUM-or-higher defects.** The remaining findings are LOW or LOW-MEDIUM, mostly carried over from earlier reviews.
- **The biggest open gap is verification, not code:** across three passes, no unit test has ever executed.

## Scope and limits (read first)

- **I did not build or run anything.** This host is Linux with no Swift toolchain, so this review is from reading the code. I could not run `swift build`, `swift test`, the fixtures or the live gateway.
- **Codex's results are its own word.** Codex reports that `build.sh` and the native/legacy fixtures passed on the mini, and that the live throwaway Hermes got as far as provider auth. No logs for these are in the tree.
- **The unit tests have never run.** `swift test` is still blocked by CoreDevice/`_XPCTypeBool` (`docs/hermes-integration.md:31`). So the 14 tests in `Tests/AgentAppTests/AgentAppTests.swift` are written and, by Codex's claim, type-checked, but never executed.
- **I could not check upstream.** This session's permission layer again blocked fetching `raw.githubusercontent.com/NousResearch/hermes-agent/v2026.9.24/...`. The new `order=oldest` quote (`docs/hermes-v0.21.7-evidence.md:12-20`) is consistent and specific, but I have not checked it against upstream.
- **The tree matches HERMES-FIX3.diff** on spot checks: `stopInProgressForStream`, `didCancelLocalStream`, `maximumPages`, the `URLError` clear and the new tests all appear in the diff.

---

## 1. Prior must-fix list

| # | Requirement | Status | Evidence |
|---|---|---|---|
| **F1** (MEDIUM) | Stop guard is per run | **Fixed** | Each `send` mints a `streamToken` and stores it in `activeStreamToken` (`AppStore.swift:167`). `stop()` only skips when `stopInProgressForStream == activeStreamToken` (`:208-209`). That flag is released only if it still holds this token (`:214,238`). An older run's pending POST therefore no longer blocks Stop on the next run. |
| | A failed old POST must not clear `isStreaming` for a newer run | **Fixed** | Both the success path and the catch path guard with `if activeStreamToken == streamToken` (`:224,235`). The stream task's own cleanup is token-guarded too (`:195-197`). |
| | Local cancel before the server Stop | **Fixed** | Order: `stopTarget` (registry read) → `taskToCancel?.cancel()` → `didCancelLocalStream?()` → `isStreaming = false` → `await requestStop` (`:221-225`). The run id is still captured *before* the cancel, which matters now that cancellation clears the registry (`HermesBackend.swift:221-227`). |
| | Short timeout on the stop request (optional) | **Not done** | `requestStop` uses `jsonRequest` with the default 60 s (`HermesBackend.swift:114,255-258`). Now that state is per run, this is harmless except for late feedback (F1-R2). |
| **F3** (LOW-MEDIUM) | `null` content treated as empty | **Fixed** | `normalizedContent` returns `nil` for `nil`/`NSNull`, `text` for a `{text}` dictionary, `nil` for other dictionaries, and `nil` for any non-array scalar (`HermesBackend.swift:133-148`). Array parts that are `NSNull` or unknown are dropped (`:138-146`). `parseMessage` drops `nil` and empty content (`:123`), so tool-call-only assistant rows no longer appear or break overlap matching. |
| **F2** (LOW-MEDIUM) | At least a full user→assistant pair for histories with two or more turns | **Fixed** | `minimum = 2` when there are two or more local turns (`AppStore.swift:98`), and the suffix must contain an adjacent user→assistant pair (`:102-105`). |
| | Prefer the latest window | **Fixed (latest within the longest matching suffix)** | Suffix lengths go from longest to shortest (`:100`). Within a length, windows go from latest to earliest (`:106`). Preferring the longest suffix first is good: an earlier copy of the tail only wins if the *entire* longer local suffix repeats. |
| | Confirm `order=oldest` or sort | **Evidence added (unchecked by me)** | The evidence quotes `order not in (None, "oldest", "latest")` → 400, with the response echoing `order` (`evidence.md:12-20`). Independently of that, the pair requirement makes a reversed page fail to match (a u→a pair reads a→u when reversed), so a wrong order now gives `nil` instead of a reversed append. |
| | Bounded paging loop | **Fixed; the cap errors, it does not truncate** | `for page in 0..<100`. A short page returns (`HermesBackend.swift:83`). A full 100th page **throws** "exceeded the 50,000-row paging safety limit" (`:85`). `loadHermesHistory` turns that into `errorMessage` with no merge (`AppStore.swift:82`). This is not a silent truncation. Edge: a session with exactly 50,000 rows raises the error falsely, and every sidebar click on a huge session costs 100 requests. LOW. |
| L6 (nice) | Stale run id on `URLError.cancelled` | **Fixed** | Every terminal path clears the registry: normal end (`:220`), `CancellationError` (`:221`), and any other error including `URLError.cancelled`, which now finishes cleanly instead of throwing (`:222-227`). |
| Tests | Ordering, null content, latest window | **Done, see §4** | `stopCaptures…` (`Tests:162-173`), `anOlderStopRequest…` (`:175-188`), `hermesContentNormalization…` (`:142-148`), `historyMergeUsesLatestFullTurnPair…` (`:150-160`). |
| Nice-to-have | Quiet note on divergence; warn on approval without command text | **Not done** | `mergeHermesHistory` returning `nil` is still silent (`AppStore.swift:80`). `ApprovalCard` is unchanged: Approve is always enabled, with fallback text (`HermesBackend.swift:247`, `ApprovalCard.swift:8-10`). |

## 2. Regression hunt

### Stop: races between the old and new stream token

I traced each interleaving and found none that breaks per-run state:

- **Stop A, then A's cleanup, then send B, then Stop B while A's POST is pending.** At the guard, `stopInProgressForStream` is A and `activeStreamToken` is B, so B's Stop proceeds. A's completion only clears the flag if it still equals A, which it doesn't once B has set it (`:238`). Neither path touches `isStreaming` for B (`:224,235`). Correct.
- **Second Stop on the same run.** It's blocked by the flag while the POST is pending (`:208`). After the local cancel, `isStreaming` is false (`:224`), so further presses are no-ops even after the flag clears. Correct.
- **`send` while A's cancellation is in flight.** It's blocked until A's token-guarded cleanup sets `streamTask = nil` (`:160,196`). Correct.
- **No-backend path.** `stop()` cancels and resets synchronously (`:212-215`). Correct.

### Findings

**F1-R1 (LOW). The run-id registry is keyed by session, and clears are unconditional.** (`HermesBackend.swift:3-9,216,220-227`)
Every turn of a bot uses the same `agentapp_<uuid>` session id. A's inner SSE task clears `runs[sessionID]` asynchronously after its cancel. If B's first event had already stored B's run id, A's late clear would erase it, and an early Stop on B would report `.noActiveRun` and leave B's server run going.

This needs the user to send a new message within the few milliseconds the URLSession cancel takes, so it is theoretical. The hardening is `clear(sessionID, ifRunID:)`, which would make the run-id lifetime exact rather than "almost always right".

**F1-R2 (LOW). Feedback can arrive late, and a Stop during `createSession` produces double feedback.**
- The old run's "Stop requested from Hermes." line, or its "Hermes Stop failed: …" banner, can arrive up to 60 s later. It is then appended *after* the next turn's placeholder (`AppStore.swift:232,236`). The prior review noted this. It's cosmetic now that state is correct.
- Pressing Stop during a bot's first turn, while `createSession` is in flight (`:173-174`), produces two feedback messages:
  - URLSession usually reports that cancellation as `URLError.cancelled`, not `CancellationError`. So the stream task's generic catch shows `errorMessage = "cancelled"` and marks the run failed (`:189-191`).
  - The Stop also appends "Stopped locally before Hermes supplied a run ID." (`:230`).

  That's two messages for one Stop. A one-line fix would treat `URLError.cancelled` like `CancellationError` in `send` as well.

**F1-R3 (INFO). Local-only stop when Stop is pressed before the first SSE event.** Hermes may keep running server-side after a `.noActiveRun` stop, until the first event carries a `run_id`. The feedback says exactly that, which is honest. Whether Hermes aborts a session run when the client disconnects is unverified.

### History merge

- **No shrink or overwrite.** Every non-`nil` return is `local + …` (`AppStore.swift:90,120`), and `[]` is returned only when local is empty (`:86`). Local `ChatMessage` objects are reused. The race guard is unchanged (`:79`). **Holds.**
- **Repeated identical turns.**
  - The new test shows the latest window avoids the earliest-window duplicate (`Tests:150-158`).
  - Duplication would now need a *longer* local suffix that matches an earlier server window than the true alignment. That means the whole local tail, including a turn from before the session, would have to repeat verbatim. This is pathological. **Acceptable.**
  - The opposite failure is possible: if the entire local turn sequence is later repeated verbatim on the server, the rows in between are skipped. That is safe under-merging, not corruption. **INFO.**
- **Paging cap.** It raises an error and does not truncate (above). One residual: a server that caps pages below 500 would end paging after the first page as a "short page" (`HermesBackend.swift:83`). For oldest-first data that usually means no tail match, so the result is `nil` and nothing is lost. **INFO.**

**F4 (LOW-MEDIUM, carried). The merge still often does nothing, and silently.** (`AppStore.swift:80,88,108-109`)
Every candidate suffix includes the last local turn, which must be byte-identical on the server. Two common cases break that, and the load then returns `nil` with no message:
- a Stop-truncated partial reply;
- an assistant turn built from deltas plus non-streamed commentary.

This is safe, but "history merge" will frequently not merge anything. The brief listed a quiet divergence note as a nice-to-have, and it was not done.

### Other carried findings (unchanged)

- **F6 (LOW-MEDIUM, safety UX).** The approval card falls back to "Hermes needs approval / A tool action is waiting for your decision.", and Approve stays enabled (`HermesBackend.swift:247`, `ApprovalCard.swift:8-10`). The live evidence never captured an `approval.request` payload; only the fixture shows the `description`/`command` keys (`Tests/Fixtures/hermes_v0.21.7_server.py:45`). I recommend fixing this before relying on approvals for anything destructive.
- **L4.** `OSStatus` is ignored on Keychain writes (`KeychainStore.swift:8,11`), and the default key is written on every keystroke (`SettingsView.swift:37`).
- **L5.** `[::1]` handling is untested (`HermesBackend.swift:37`).
- **L9.** `isStreaming` is global, history loads only on a sidebar click, and the test harness ships in the production binary (`AgentApp.swift:16-17`).
- **Mock/OpenClaw Stop wording.** Stopping a Mock or OpenClaw bot still says "this Hermes version has no run-control endpoint" (`AppStore.swift:229`, `AgentBackend.swift:29`).
- **F8.** Native send transmits only the last user message (`HermesBackend.swift:188`). Pre-session local history is not given to the model. This is a design limit and is not documented.

## 3. N1/N2 and H1–H4 still fixed

| # | Status | Evidence |
|---|---|---|
| N1 no shrink/overwrite | **Holds** | `AppStore.swift:85-121` (above). |
| N2 capture, cancel locally, POST once | **Holds, now per run** | `AppStore.swift:207-241`. |
| H1 capabilities first; legacy never touches Sessions | **Holds** | `transport()` is cached per baseURL/profile (`HermesBackend.swift:40-55`). `listSessions`, `loadMessages` and `createSession` are each gated (`:64,75,91`). AppStore send (`AppStore.swift:173`) and history (`:76`) are gated. The legacy fixture returns 500 on any `/api/sessions*` route (`fixture:12-13`). |
| H2 no Mock/user bot deletion | **Holds** | The only bot removal is the user's `delete` (`AppStore.swift:157`). Demo bots are hidden, not deleted (`:42`). |
| H3 scoped approvals | **Holds** | Stamped with `botID`, `profile` and `sessionID` (`AppStore.swift:185`). Filtered per bot (`ChatView.swift:20`). `decide` uses the owning bot's backend (`AppStore.swift:243`). Cleared at run end (`:193`). |
| H4 no `listSessions().first` adoption | **Holds** | The only caller is the harness, which lists then creates its own `agentapp_integration_<uuid>` (`AgentApp.swift:33-35`). App sends use `agentapp_<bot uuid>`, and a 409 is treated as already owned (`AppStore.swift:174`, `HermesBackend.swift:96`). |

## 4. Do the new tests exercise the real paths?

| Test | Real code path? | Gaps |
|---|---|---|
| `stopCapturesThenCancelsThenPostsOnlyOnce` (`:162-173`) | **Yes, it drives `AppStore.stop()`.** Ordering is now asserted: "cancel" (the hook right after `taskToCancel?.cancel()`, `AppStore.swift:222-223`) and "post" (inside `requestStop`) go into one `LockedTrace`, and the result must be `["cancel","post"]`. The pre-FIX2 order (POST, then cancel) would fail. A double press gives exactly one capture, one POST and one feedback line. | It asserts the hook was called, not that the stream task actually ended. It does not assert `isStreaming == false` while the 80 ms POST is pending. |
| `anOlderStopRequestDoesNotBlockStoppingTheNextRun` (`:175-188`) | **Yes, a genuine regression test for F1(a).** With the old global flag the second Stop is swallowed and the trace is `["cancel","post"]`, so the test fails. | F1(b) is untested: `requestStop` never throws, and nothing asserts that run B still has `isStreaming == true` after A's POST resolves. The test relies on an 80 ms sleep for A's cleanup to finish before `send("second")`, which could be flaky on a loaded CI. |
| `hermesContentNormalizationDropsNullAndUnsupportedJSON` (`:142-148`) | **Yes, it calls the real `HermesBackend.normalizedContent`.** | It doesn't cover arrays containing `NSNull`, or `parseMessage` dropping the row. |
| `historyMergeUsesLatestFullTurnPairOverlap` (`:150-160`) | **Yes, it calls the real `mergeHermesHistory`.** Earliest-window logic would produce 6 rows and fail. It also checks that a lone assistant row does not count as overlap. | It doesn't cover a reversed page, or a pre-session tail plus a session tail. |
| Untested FIX3 code | — | The paging cap and short-page exit (`HermesBackend.swift:78-86`; the fixture always returns `[]`). The registry clear on `URLError.cancelled` (`:222-227`), which needs a `URLProtocol` stub. `loadHermesHistory` end to end, including the race guard. `historyMergeAcceptsMultimodal…` (`:134-140`) is still vacuous for parsing. |

The tests are now real AppStore and parser tests, not only fixtures. But **none of them has ever run**, and all the Stop tests depend on fixed sleeps.

## 5. README and docs honesty

- **Honest:**
  - README:14 says the compiler fallback doesn't run tests.
  - README:37 now says "internal tool status handling" (L7 wording fixed) and "per-run immediate local Stop plus background run Stop". It also says plainly that the credential-free gateway can't produce a paused approval or a long run.
  - `docs/hermes-integration.md:13` describes the latest-pair overlap and the 100-page cap. `:23` describes capture → local cancel → background POST.
  - `:29-31` say the live turn failed at provider auth and that the runner can't execute.
  - `evidence.md:72` admits that live Stop and approval were not exercised.
- **Soft spots:**
  - `docs/hermes-integration.md:29` says the AppStore tests "are written to cover … Stop ordering/idempotence" and that "the runner limitation … determines whether they execute on this host". It should say plainly that they have **never executed**.
  - "The full test source type-checks" (`:31`) has no log in the tree.
  - `:13` doesn't say that the 50k cap raises an error, or that a divergent transcript silently merges nothing (F4).
  - Apart from the new quoted `order` snippet, `evidence.md` "excerpts" are still paraphrases with line ranges, sourced from `/private/tmp` on the mini.
- **Keys:** **pass.**
  - Keys are only read and written through `KeychainStore` (service `com.konrad.agentapp.backends`), both fields are `SecureField`s (`SettingsView.swift:16-17,37,39-40`), and `@AppStorage` holds only URLs, profile names and UI preferences.
  - `store.json` holds no secrets, the harness never prints the key, and plain-http keys are refused for non-loopback hosts (`HermesBackend.swift:34-38,264`).
  - The evidence and fixture bearers (`agentapp-throwaway-evidence-key`, `fixture`) are throwaway constants.

---

## Must fix before installing on the MacBook

No code defect blocks install. One gate remains:

1. **On the MacBook, run `swift test` (or `xcodebuild test`) before relying on the build, and treat any red test as a stop.** This would be the first time the 14 tests execute. Then do a manual smoke against the real gateway:
   - send, Stop mid-reply, send again, Stop again, and confirm the second Stop cancels;
   - click the bot in the sidebar and confirm the transcript is not shrunk or duplicated.

Recommended soon after, not blocking:
- F6: disable Approve when an approval arrives without command text.
- F4: show a quiet "history not merged" note.
- F1-R2: treat `URLError.cancelled` as cancellation in `AppStore.send`.
- F1-R1: make the registry clear conditional on the run id.
- A 5–10 s timeout on the stop POST.
