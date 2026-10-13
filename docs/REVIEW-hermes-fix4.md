# AgentApp Hermes FIX4 re-review (HERMES-FIX4.diff on 42ddfe3 + untracked files)

**Verdict: PASS-WITH-ISSUES.**

- **Six of the seven brief items are real in the code:** F6 gating, single Stop message, the run-id token guard, URLError.cancelled, the 8 s Stop timeout, and the divergence note.
- **One new regression, MEDIUM.** A failed or timed-out server Stop on the current run is now completely silent (finding R1).
- **Three of the new or changed Stop tests will most likely fail the first time they run.** The condition waits replaced the sleeps but wait for the wrong thing (finding T1). Under the existing gate ("treat any red test as a stop"), this blocks the MacBook install until fixed.
- **No FIX4 behaviour was exercised at runtime.** Fixtures and live checks failed at the `EPERM` bind, and the tests never ran.
- **Earlier fixes (F1–F3, N1/N2, H1–H4) still hold.**

## Scope and limits (read first)

- **Nothing was built or run.** This host is Linux with no Swift toolchain. Everything below comes from reading the code and tracing Swift concurrency scheduling by hand. Findings marked *predicted* are the result of that trace; none were executed.
- **The tree matches HERMES-FIX4.diff** on every hunk I checked: registry token, `timeout: 8`, `hasKnownCommand`, the `URLError` catch, `stoppedAssistantID`, the note, `waitUntil`, and the new tests.
- **`dist/` is not in this tree.** I could not check the zip or its SHA-256 (`7ba1cc35…`) against the source.

---

## Findings, highest severity first

### R1 (MEDIUM, regression introduced by FIX4): a failed or timed-out Stop on the current run is silent

- **Where:** `AppStore.swift:244-249`, together with `:201-203` and `:229-232`.
- **What changed:** FIX4 moved `errorMessage = "Hermes Stop failed: …"` inside `if activeStreamToken == streamToken`. In FIX3 it was unconditional (diff lines 207-211).
- **Why that makes it silent:** `stop()` cancels the stream task (`:229`) *before* awaiting `requestStop` (`:232`). The cancelled stream task's cleanup then runs on the next main-actor turn and sets `activeStreamToken = nil` (`:201-202`).
  - The POST needs a network round trip, or up to 8 s to time out, so cleanup always finishes first.
  - By the time the POST throws, `activeStreamToken` is `nil`, the guard is false, and **no banner and no system note appear**.
- **What still works:** a failure inside `stopTarget` still reports, because that path checks the token synchronously before cleanup runs.
- **Failure scenario:** a native run is executing tools. The user presses Stop, and the stop POST hits a 401, a 5xx or the new 8 s timeout. The UI shows the run as stopped with no message, while Hermes keeps running server-side. The new 8 s timeout therefore produces nothing the user can see.
- **What the test covers:** `failedOldStopDoesNotClearOrReportAgainstNewerRun` (`Tests:228-242`) correctly asserts *no banner for an older run*. Nothing asserts that a failure on the *latest* run is reported.
- **Fix (a few lines):** in the catch, insert `"Hermes Stop failed: …"` as a system note beside `stoppedAssistantID`, exactly as the success path does at `:239-242`. Keep only the global `errorMessage` banner token-guarded.

### T1 (MEDIUM for the install gate; test-only): three Stop tests are predicted to fail on first execution

`waitUntil` (`Tests:67-74`) spins with `Task.yield()` on the MainActor. So whenever any other main-actor job runs, the spinner's next iteration is already queued ahead of anything that job enqueues.

**1. `stopCapturesThenCancelsThenPostsOnlyOnce`** (`Tests:207-210`)
- The wait ends as soon as `"post"` is recorded and `isStreaming` is false.
- `TestBackend.requestStop` records `"post"` *before* its 80 ms sleep (`Tests:44-45`). The feedback line is inserted only after that sleep (`AppStore.swift:232-242`).
- So `…contains("Stop requested")…count == 1` runs about 80 ms early and sees 0. **Predicted red.** FIX3's 200 ms sleep covered this.

**2. `anOlderStopRequestDoesNotBlockStoppingTheNextRun`** (`Tests:219-221`) **and `failedOldStopDoesNotClearOrReportAgainstNewerRun`** (`Tests:233-235`)
- They wait for `!store.isStreaming` and then call `send("second")`.
- `isStreaming = false` is set by the *Stop* task (`AppStore.swift:231`). `streamTask = nil` is set later, by the stream task's cleanup (`:202`).
- `cancel()` enqueues the stream task's resumption *behind* the already-queued spinner. The spinner sees `!isStreaming`, the test calls `send`, and `send` hits `guard … streamTask == nil` (`:164`) and returns silently.
- The next `waitUntil { send count == 2 }` then throws `WaitTimeout` after 2 s. **Predicted red.**

**Fix:**
- In (1), wait for the feedback message itself.
- In (2), wait for cleanup before sending the second message: expose an internal `isIdle` (`streamTask == nil`), or retry `send` inside the wait until the second `"send"` is recorded.

**The same window exists in the app** (LOW): `ChatView.swift:31` clears the draft *before* `store.send`. Enter pressed in the same few milliseconds after Stop would drop the typed text. A human is unlikely to hit this, but the guard should not discard input silently.

### F6-R (LOW): approval gating is UI-only, and real payloads may never carry `command`

- **The gate:** Approve is disabled through `hasKnownCommand` (`ApprovalCard.swift:9,11`, `Models.swift:109`).
- **The store does not re-check it:** `AppStore.decide` (`:255`) does not verify `hasKnownCommand`. Today the card is the only caller (`ChatView.swift:20`). A one-line guard in `decide(approved: true)` would make the rule hold for any future entry point.
- **The `command` key is unconfirmed:** it is evidenced only by the fixture (`Tests/Fixtures/hermes_v0.21.7_server.py:45`), and `docs/hermes-v0.21.7-evidence.md:23` does not quote the payload. If real v0.21.7 events put the command elsewhere, **every** approval becomes decline-only. That fails safe, but would make approvals unusable. Verify with the first real approval on the MacBook.

### RID (LOW): residual run-id edges

- **Edge 1, B's Stop targets A's run.** The registry is keyed by session only (`HermesBackend.swift:3-11,115`). Run B can be stopped before B's first `run_id` event and before A's inner task has run its token-guarded clear. In that window, `stopTarget` returns **A's** stale run id.
  - The POST goes to the dead run A. That failure is now silent because of R1, and B keeps running.
  - The window is a few milliseconds.
  - Possible fixes: clear the entry synchronously at cancel, or have `stopTarget` ignore entries whose token is not the live stream's.
- **Edge 2, a late `set` from A.** A `run_id` line from A that is already buffered can still be processed after cancellation and `set` A's token over B's entry (`:225`). This is theoretical.

### UC (LOW): `URLError.cancelled` is treated as user cancellation unconditionally

- **Where:** `AppStore.swift:195-196` and `HermesBackend.swift:235`.
- **Problem:** `NSURLErrorCancelled` can also come from cancelled authentication or client-certificate challenges. That case would end a turn with an empty bubble and no error.
- **Fix:** add `where error.code == .cancelled && Task.isCancelled` in `AppStore.send`.

### NOTE (INFO): the divergence note is persisted, but does not affect merging

- **How it behaves:** the note is a `.system` `ChatMessage` that is appended and saved (`AppStore.swift:80-84`). It is de-duplicated only against the last row.
- **Why it can't damage history:**
  - The merge only considers user and assistant turns (`:92`), so the note can never cause a mis-merge.
  - Native send transmits only the last user message (`HermesBackend.swift:196`).
  - Legacy bots never load history (`AppStore.swift:76`), so they never get the note.
- **Wording:** it says "diverges" even in the common Stop-truncated case. That is acceptable.

### Carried, unchanged (from REVIEW-prev)

- **L4:** Keychain `OSStatus` is ignored, and the key is written on every keystroke (`SettingsView.swift:37`).
- **L5:** `::1` handling is untested (`HermesBackend.swift:40`).
- **L9:** `isStreaming` is global, and the test harness ships in the binary, gated by an environment variable (`AgentApp.swift:16-17`).
- **Mock/OpenClaw Stop wording:** stopping those bots still says "this Hermes version…" (`AppStore.swift:236`).
- **F8:** native send carries only the last user message (`HermesBackend.swift:196`). This is undocumented.

---

## 1. Are the claimed fixes real?

| Claim | Real? | Evidence |
|---|---|---|
| F6: Approve disabled, command shown as unknown | **Yes (UI-level)** | Parse: `command` is trimmed, `summary` falls back to `"Command unknown"`, and `command` is `nil` when empty (`HermesBackend.swift:256-258`). Model: `hasKnownCommand` (`Models.swift:109`). Card: an orange "Command unknown — approval is disabled." line, and `.disabled(!request.hasKnownCommand)` on Approve (`ApprovalCard.swift:9,11`). Decline stays enabled. The demo approval was given a command (`AppStore.swift:156`). See F6-R. |
| One Stop = one message | **Yes** | Stop during `createSession` or the first turn: `URLError.cancelled` is now silent in `send` (`AppStore.swift:195-196`). The only output is the `.noActiveRun` note (`:237`). Every other outcome also produces exactly one line. |
| A cancelled old stream cannot erase a newer run id | **Yes, for clear** | `set`/`clear` carry a per-stream `UUID` token, and `clear` is a no-op unless the token matches (`HermesBackend.swift:6-11`). There is one token per `sseStream` (`:213`), used on all three terminal paths (`:229,230,234`). Residual edges: see RID. |
| `URLError.cancelled` treated as cancellation | **Yes** | `AppStore.swift:195`, `HermesBackend.swift:235`. See UC. |
| Stop timeout of 8 s | **Yes** | `jsonRequest(..., timeout: 8)` sets `timeoutInterval` (`HermesBackend.swift:122,266-268`). This is the idle timeout, which is effectively the total for a small POST. **But the timeout outcome is invisible (R1).** |
| Late feedback goes beside the stopped turn | **Yes, on success only** | `stoppedAssistantID` is captured synchronously (`AppStore.swift:224`). The note is inserted at `index + 1`, or appended if the turn is gone (`:239-242`). There is no token guard, which is correct. On failure: R1. |
| Quiet note on divergent or truncated history | **Yes** | `AppStore.swift:80-84`. Placed after the race guard (`:79`), and it does not change user or assistant rows. |
| Double feedback | **None found** | Success → one note. `stopTarget` failure → one banner. `requestStop` failure → **zero** (R1). The local stream end is silent for both `CancellationError` and `URLError.cancelled`. |

## 2. Earlier fixes still hold

| # | Status | Evidence |
|---|---|---|
| F1 per-run Stop guard | **Holds** | `AppStore.swift:214-215,220,231,246,251`. Stream cleanup is token-guarded (`:201-203`). |
| F2 latest full-pair overlap | **Holds** | `mergeHermesHistory` is unchanged (`:89-125`). |
| F3 null or unsupported content | **Holds** | `normalizedContent` and `parseMessage` are unchanged (`HermesBackend.swift:129-156`). |
| N1 no shrink or overwrite | **Holds** | Every non-`nil` return is `local + …` (`:94,124`). The note path only appends. |
| N2 capture, then local cancel, then a single POST | **Holds** | `:228-232`, with `stopInProgressForStream` (`:214-215,251`). |
| H1 capabilities first; legacy never calls Sessions | **Holds** | `HermesBackend.swift:67,78,99`, `AppStore.swift:76,177`. |
| H2 no Mock or user-bot deletion | **Holds** | `delete` only (`:161`). Demo bots are hidden (`:42`). |
| H3 scoped approvals | **Holds** | Stamped at `:189`, filtered at `ChatView.swift:20`, the owning backend is used at `:256`, and approvals are cleared at run end (`:199`). |
| H4 no foreign-session adoption | **Holds** | Deterministic `agentapp_<uuid>` id, with 409 treated as already owned (`:178`, `HermesBackend.swift:104`). |

## 3. Tests: what they exercise, and what the logs prove

**New and changed tests:**

| Test | Exercises real code? | Comment |
|---|---|---|
| `failedOldStopDoesNotClearOrReportAgainstNewerRun` (`:228-242`) | **Yes, the AppStore token guard** | It does **not** touch `HermesRunRegistry`, which is private and bypassed by `TestBackend`. So the registry token fix itself is untested. Predicted red (T1). |
| `historyPagingStopsAtTheConfiguredCap` (`:165-177`) | **Yes, the real static `loadMessagePages`** | A good test. Offsets `0,2,4`, then the throw. It does not cover the short-page exit. |
| `divergentHistoryAddsAQuietNote` (`:191-198`) | **Yes, the real `AppStore.loadHermesHistory`** with a stub backend | It checks role and text, but not that existing rows are unchanged or that a second load doesn't duplicate the note. |
| `approvalKeepsHermesRunIdentity` (`:92-103`) | **Model property only** | `hasKnownCommand` true and false. Neither the card's disabled state nor `parseNative` with a missing `command` is tested. |
| The Stop tests, converted to `waitUntil` | Yes, `AppStore.stop()` | Two predicted red at the second `send`, and one red at the feedback assertion (T1). |
| `historyDoesNotAdoptForeignSession` (`:129-130`) | Yes | Now **weaker**. It returns as soon as `"capabilities"` is recorded, so a later forbidden `list` or `history` call would go unseen. |

**Are the waits deterministic?** Not fully.
- `waitUntil` is a bounded busy-yield poll with a 2 s deadline. That beats fixed sleeps for the conditions it waits on correctly. But on the MainActor its scheduling is what *causes* T1: it always wins the race against work it is waiting on indirectly.
- Fixed sleeps remain inside `TestBackend` (`:29,31,45`), which is acceptable.

**Still untested:**
- the registry token guard;
- `URLError.cancelled` in `send`;
- feedback placement beside the stopped turn;
- the Stop timeout path;
- a failed Stop on the latest run (R1);
- the F6 UI gate.

**What the saved logs prove:**

| Log | Proves |
|---|---|
| `hermes-fix4-swift-test.log`, `-xcodebuild-test.log` | The `_XPCTypeBool`/CoreDevice failure is genuine. **The tests have never executed.** |
| `hermes-fix4-build.log` | Only the line "xcrun is unavailable; using the Xcode 16.2 compiler directly." There is no diagnostic output and no recorded exit status. This is consistent with a clean compile under `set -e`, but it is weak evidence. |
| `hermes-fix4-test-typecheck.log` | Three lines ending "TYPECHECK PASSED". **No command line or compiler invocation is recorded**, so it cannot be reproduced or audited, and an `echo` would produce the same output. Even if real, a type-check would not catch T1 or R1. |
| `hermes-fix4-fixtures.log` | Both fixtures died at bind `EPERM`, and the app then failed with "Operation not permitted". **Zero fixture coverage in FIX4.** |
| `hermes-fix4-live-gateway.log`, `-live-client.log` | The gateway could not bind `127.0.0.1:18642` (`EPERM`), and the client failed. **Nothing live was exercised.** |
| `hermes-fix4-package.log` | Ad-hoc re-sign and the zip path. `codesign --verify --strict` was silent, which means success under `set -e`. It does **not** show which build the zip contains (see §4). |

**Net:** for FIX4, runtime verification is nil. Every claimed fix rests on reading the code, which I confirmed except for R1 and T1.

## 4. Packaging (`scripts/package-release.sh`)

**Is shipping a debug build a problem?** **Not for a personal install.**
- The fallback `swiftc` build has no `-O`, so the binary is unoptimized. Expect slower SwiftUI work and Markdown rendering on long transcripts, and a larger binary.
- There is no `#if DEBUG` code and there are no `assert`/`precondition` calls, so behaviour is the same as a release build.
- Building a release with `swift build -c release` would be better, but it is not required.

**Real packaging issues:**

1. **The packaged binary can't be traced to the reviewed source (LOW-MEDIUM).**
   - The script copies whatever is in `.build/debug/AgentApp` (`package-release.sh:9`). It does not build first, and it stamps no version or SHA (`CFBundleVersion` is a static `4`, `Info.plist:12`).
   - Nothing proves the zip was built from this exact tree after the last edit.
   - Recommendation: build on the MacBook from the reviewed tree, run `swift test`, then package. Or at least make `package-release.sh` run `build.sh` first and write the source SHA into the bundle.
2. **arm64 only and ad-hoc signed.**
   - The MacBook must be Apple Silicon.
   - A zip downloaded or AirDropped onto the MacBook gets quarantined, and Gatekeeper will block an ad-hoc app. Transfer it with `scp`/`rsync`, or use "Open Anyway". Don't disable Gatekeeper globally.
3. **Keychain prompts after every rebuild.** Ad-hoc signatures change with every build, and Keychain item access is bound to the signature. Expect "AgentApp wants to access…" prompts after each new build. This is the same issue as the known codesign/keychain re-prompt.
4. **`dist/` is not in `.gitignore`.** The `.app` and zip could be committed by accident.
5. **SwiftPM warnings.** `Package.swift:11` does not exclude the new `BRIEF-hermes*.md`, `Resources/Info.plist`, `dist/` or `REVIEW*` files, so SwiftPM will warn about unhandled files. These are warnings only.

**Safety: pass.**
- Keys live only in Keychain: service `com.konrad.agentapp.backends`, entered through `SecureField`, never in `@AppStorage` or `store.json`.
- The harness key comes from `HERMES_TEST_KEY`, and only in integration mode.
- The only hardcoded endpoints are loopback: `http://127.0.0.1:8642/v1` (`AppConstants.swift:5`) and `ws://127.0.0.1:18789` (`SettingsView.swift:9`).
- There are no references to the owner's servers, fleet IPs or domains. "Konrad" appears only as UI placeholder text and in the bundle id.
- A plain-HTTP key to a non-loopback host is refused (`HermesBackend.swift:37-41,276`).

## 5. README and docs honesty

- **Honest:**
  - README:16 and `docs/hermes-integration.md:31` now say plainly that "The Swift unit tests have never executed on this host" and that the type-check "is not test execution".
  - README:39 and docs:29 say the fixture and live reruns were blocked by `EPERM` and are unverified.
  - docs:13 describes the cap error and the divergence note.
- **Overstated:**
  1. docs:31 says the type-check's "complete command output is saved". The log has no command, so it doesn't back the claim in any auditable way. Record the exact `swiftc -typecheck …` invocation and its exit code.
  2. README:39 and docs:25 describe a "background run Stop" without mentioning that a failed or timed-out Stop is now silent (R1).
  3. Neither document says the packaged zip is an unoptimized debug build copied from `.build/debug`, or that it isn't tied to a source SHA.
  4. README:14 says the fallback "verifies the production build". It only shows the build compiles.

---

## Must fix before installing on the MacBook

1. **R1:** report a failed or timed-out Stop for the stopped turn by inserting a system note beside `stoppedAssistantID`. This is the kill switch, and its failure must not be silent. Add a test: latest-run Stop fails → a note is present.
2. **T1:** fix the three Stop tests' waits: wait for the feedback row, and wait for stream cleanup before the second `send`. Otherwise the first-ever `swift test` run will be red for test reasons and the install gate can't be judged.
3. **Then, on the MacBook, from the reviewed tree:**
   - run `swift test`, and treat any red test as a stop;
   - build, package, and transfer without quarantine;
   - smoke-test against the real gateway: send, Stop mid-reply, send, Stop again; confirm one note per Stop placed beside the right turn; click the bot and confirm no shrink or duplication.
   - On the first real approval, confirm the command text shows (F6-R).

Recommended soon, not blocking: a `hasKnownCommand` guard in `decide` (F6-R); a token-aware `stopTarget` (RID); `URLError.cancelled` only when `Task.isCancelled` (UC); have `package-release.sh` build first and stamp the source SHA; add `dist/` to `.gitignore`.
