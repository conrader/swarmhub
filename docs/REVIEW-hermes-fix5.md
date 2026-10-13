# AgentApp Hermes FIX5 re-review (HERMES-FIX5.diff on local 2bb7409 + untracked files)

**Verdict: PASS-WITH-ISSUES.** Nothing in the code blocks the MacBook install. The install still depends on the procedure: the suite must go green there.

- **All three FIX4 must-fix items are fixed in the code.**
  - The silent failed or timed-out Stop (R1) is gone.
  - The three Stop tests now wait for the right condition. By hand trace they should pass.
  - Packaging builds first, stamps the SHA and a dirty flag, and `dist/` is ignored.
- **The low items are done:** store-level F6 gate, `URLError.cancelled` gating, and wider command extraction.
- **No new Stop regression found.** Late feedback, a token race, or a newer run cannot misplace the note or touch the newer run's state.
- **Runtime verification is still nil:**
  - The tests have never executed.
  - The FIX5 test changes have not even been compiled, because the FIX4 type-check claim was dropped and not re-run.
  - Fixtures and the live run died at the `EPERM` bind.
  - Everything below comes from reading the code and tracing the scheduling by hand.
- **The remaining issues are LOW:**
  - The docs overstate the fixture attempt and the source evidence for approvals.
  - The `-dirty` name cannot identify *which* dirty tree went into the zip.
  - One new test force-unwraps where it should `#require`.
  - The carried draft-loss window is still open.

## Scope and limits

- **Nothing was built or run.** This host is Linux with no Swift toolchain, and `.build` and the `.app` are absent. All findings come from reading the code, plus hand traces of main-actor and actor scheduling.
- **The tree matches HERMES-FIX5.diff** on every hunk checked: `.gitignore`, README, HermesBackend `:235,256-265`, AppStore `:195,208,245-256,262-265`, tests, docs, and `package-release.sh`.
- **There is no `.git` here.** I could not confirm that 2bb7409 is the parent, or what porcelain status the mini actually saw. I relied on GIT-STATUS.txt for both.
- **Zip:** `sha256sum dist/AgentApp-2bb74097ca18-dirty-arm64.zip` = `d53513b6…d8d62`, which **matches** the claim.
  - Listing the zip or reading `SOURCE.txt` from inside it needed approval that this session did not have, so I could not check the `SOURCE.txt` *contents* in the shipped zip. They are only inferred from the script.
  - A stale `dist/AgentApp-hermes-fix4-arm64.zip` sits beside it. Don't confuse the two.

---

## Findings, highest severity first

### L1 (LOW, docs honesty): the fixture claim says "both native/legacy … attempted", but only native ran

- **Where:** `docs/hermes-integration.md:29`.
- **What happens:** `scripts/test-hermes-integration.sh` runs under `set -euo pipefail` (`:2`). When the native AgentApp run exits 1 (`:22`), the script aborts before `run_fixture legacy` (`:32`).
- **Evidence:** `docs/hermes-fix5-fixtures.log` has exactly one traceback, on port 18643 (native), and one app failure. There is no 18644 attempt. FIX4's log is identical, so the prior review's "both fixtures died" was also wrong.
- **Fix:** say "the native fixture failed at bind; the legacy fixture was never reached".

### L2 (LOW, docs and evidence): "v0.21.7 emits the redacted command in top-level `command`" has no saved source excerpt

- **The claim:** `docs/hermes-integration.md:23` asserts it, and the comment at `HermesBackend.swift:257-258` repeats it.
- **The evidence:** `docs/hermes-v0.21.7-evidence.md` cites only `api_server.py:3743-3752` ("binds … approvals to the run ID and emits `approval.request`"). It quotes no payload and does not mention `command` or `display_command`.
- **Why it matters:** the claim may well be true, but it can't be audited. The F6-R risk carries over unchanged: if real events lack all four keys, every approval becomes decline-only. That fails safe but is unusable.
- **Fix:** paste the emitting lines into the evidence doc, or confirm on the first real approval on the MacBook.

### L3 (LOW, parser edges in the new extraction): `HermesBackend.swift:259-265`

- **An empty top-level command blocks the fallbacks.** If the top-level `command` is present but empty (`""`), it short-circuits the `??` chain (`:260`). A non-empty wrapped or `display_command` value is then ignored, so the card says "Command unknown". This fails safe.
- **`json["data"]` is only consulted when `json["approval"]` is absent** (`:259`).
- **Wrapped payloads still lose their IDs.** `run_id` and `request_id` are read only at the top level (`:265`). For a gateway that really wraps the approval (the case this change exists for), Approve becomes *enabled*, but `resolveApproval` throws "no longer identifies its Hermes run" (`:161`).
  - This doesn't matter for v0.21.7, which stamps `run_id` at the top level on every session event (evidence `api_server.py:1121-1137`).
  - The same fallback should also apply to the IDs, or the comment should not promise compatibility with wrapped payloads.
- **Approving on `display_command` is a trust choice.** It is display text. It is acceptable as a last resort, since `command` is preferred.

### L4 (LOW, packaging honesty): `-dirty` names the base commit, not the bytes in the zip

- **The tag:** `package-release.sh:7-11,21-24` writes `source_sha=<HEAD>` and `dirty=true`. That is honest: 2bb7409 plus uncommitted FIX5 changes plus untracked BRIEF and log files.
- **The gap:** nothing records *what* was dirty, so every dirty state on top of 2bb7409 yields the same name. The zip can't be reproduced from git, and 2bb7409 is a local, unpushed commit.
- **Untracked files count as dirty too** (`--untracked-files=normal`). So the untracked BRIEFs and logs alone would keep the name `-dirty` even if FIX5 were committed. The tree only packages clean once those are committed or ignored.
- **Fix:** add `diff_sha=$(git diff HEAD | shasum -a 256)` plus the list of untracked files, or commit FIX5 before packaging.
- **Practical rule:** don't install the mini zip. Build and package on the MacBook, as the checklist says.
- **Good:**
  - `SOURCE.txt` is written before `codesign --force --sign -` on the bundle (`:21-28`), so it is sealed by the signature.
  - The package log shows the build ran first: the "xcrun is unavailable" line, then the sign lines, then `exit_status=0`.

### L5 (LOW, test quality): `failedCurrentStopIsReportedBesideStoppedTurn` force-unwraps after a soft expect, and cannot distinguish insert from append

- **The force unwrap:** `Tests:256-257` reads `#expect(stoppedIndex != nil)` and then `bot.messages[stoppedIndex! + 1]`. If the expectation fails, the force unwrap (or an out-of-range index) **crashes the test process** instead of reporting one red test. Use `let i = try #require(stoppedIndex)` and guard `i + 1 < count`.
- **Insert vs append:** the stopped assistant is the last row, so `insert(at: index+1)` and `append` give the same result. This test only proves that R1 is fixed, meaning a note now appears.
- **Placement is still covered elsewhere:** `failedOldStopDoesNotClearOrReportAgainstNewerRun` (`Tests:240`, `dropLast(2)`) would fail under append, so between them placement is covered.

### L6 (LOW, carried, app): draft loss in the Stop→cleanup window is unchanged

- **Where:** `ChatView.swift:31`.
- **The window:** the view checks only `!store.isStreaming`, clears `draft`, and then calls `store.send`. `send` can return silently on `streamTask == nil` (`AppStore.swift:164`).
- **Why FIX5 didn't close it:** FIX5 added `isIdle` (`AppStore.swift:208`), but only the tests use it, and it isn't `@Published`.
- **Fix:** guard the view on `store.isIdle`, or have `send` return a Bool so the draft is cleared only on success.

### L7 (LOW, checklist): the MacBook steps omit `.git`, and the order is slightly redundant

- **`.git` is required.** `package-release.sh:7` needs a git repo. An rsync that excludes `.git`, or a tree copied like this review bundle, aborts after building. That fails closed, but the checklist should say to copy *with* `.git`. 2bb7409 is unpushed, so cloning is not an option.
- **Step 3 builds twice.** It runs `build.sh` and then `package-release.sh`, which builds again. This is harmless.
- **Missing items:**
  - Apple Silicon only (arm64).
  - Confirm that the first real approval shows command text (L2/F6-R).
  - Commit FIX5 first if a non-`-dirty` name is wanted.

### INFO

- **A `stopTarget` failure on the current run now produces two surfaces:** the transcript note (`AppStore.swift:247-251`) and the banner (`:252-255`). This is what the prior review recommended. Only the banner is token-gated. A `requestStop` failure or timeout on the current run yields the note only, because cleanup has already cleared the token. That is still visible, so R1 is resolved.
- **A note inserted while a history load is in flight** trips the race guard (`AppStore.swift:79`), and that load silently doesn't merge. This is safe: nothing is shrunk or duplicated.
- **No Stop retry after a failure.** After a failed server Stop, the UI is locally stopped while Hermes may keep running, and there is no "Retry Stop" control. The note tells the user. Consider a retry later.
- **The RID edge carries over** (`HermesBackend.swift:3-11,115`). B's Stop can target A's stale run id in a window of milliseconds. It is now *visible* when Hermes rejects the dead run (via the R1 fix). It is still wrong if Hermes answers 200 for a finished run.
- **Carried, unchanged:**
  - L4 Keychain `OSStatus` and per-keystroke writes (`SettingsView.swift:37`).
  - L5 `::1` untested.
  - L9 global `isStreaming`, and the env-gated harness in the binary.
  - Mock/OpenClaw Stop wording "this Hermes version" (`AppStore.swift:237`).
  - F8 sends only the last user message (`HermesBackend.swift:196`).
  - `Package.swift:11` excludes are stale. New BRIEFs, `REVIEW*`, `dist/` and `Resources/Info.plist` will produce SwiftPM unhandled-file warnings.

---

## 1. Are the claimed FIX5 fixes real?

| Claim | Real? | Evidence / trace |
|---|---|---|
| A failed or timed-out Stop inserts "Hermes Stop failed" beside the captured stopped turn | **Yes** | `stoppedAssistantID` is captured synchronously before the Task (`AppStore.swift:225`). The catch always builds the note and inserts it at `index+1`, or appends it if the turn is gone (`:247-251`), with **no token gate**. `requestStop`'s 8 s `timeoutInterval` throws `URLError.timedOut` into the same catch (`HermesBackend.swift:122,275`). |
| Doesn't touch newer-run state | **Yes** | Banner and `isStreaming=false` only if `activeStreamToken == streamToken` (`:252-255`). `taskToCancel` is the old, finished task, so cancelling it again is a no-op (`:246`). `stopInProgressForStream` is cleared only if it still equals the old token (`:257`). The note is inserted by the old turn's id, between the old assistant row and the new user row. The newer stream holds `assistant`/`bot` references, not indices, so the insert can't disturb it. |
| Three Stop waits corrected | **Yes** | See §3. |
| Coverage for current-run failure placement | **Partial** | The new test proves a note appears. It can't distinguish insert from append (L5). |
| Store-level rejection of a commandless approval | **Yes** | `decide` guards `!approved \|\| approval.hasKnownCommand` *before* any backend or Task (`AppStore.swift:262-265`). Decline is still allowed. The card is unchanged (`ApprovalCard.swift:9,11`). |
| Broader command extraction | **Yes, but unaudited** | `HermesBackend.swift:259-265`. See L2 and L3. |
| `URLError.cancelled` is silent only when the task was actually cancelled | **Yes** | In the store: `where error.code == .cancelled && Task.isCancelled` (`AppStore.swift:195`). `Task.isCancelled` is the stream task's own flag, which is set before URLSession propagates the error. Otherwise it falls to the generic catch, which sets the banner and `failed=true` (`:197`). In the backend: `…, Task.isCancelled` on the inner producer task (`HermesBackend.swift:235`), which is cancelled only by `onTermination` when the consumer is cancelled (`:239`). A non-cancel `URLError.cancelled` (an auth or certificate challenge) now reaches the user as an error. The registry clear still runs on every terminal path (`:229,230,234`). |
| Packaging: build first, `SOURCE.txt`, SHA/dirty name, `dist/` ignored | **Yes** | `package-release.sh:5` (`build.sh`), `:7-11` (short SHA and the porcelain-based dirty flag), `:13` (name), `:15` (`rm -rf` of the stale `.app`), `:21-24` (`SOURCE.txt` with the full SHA and dirty flag), `:31` (`--verify --strict`). `.gitignore:2` holds `dist/`. Caveat: L4. |
| `./scripts/build.sh` passed | **Weakly evidenced** | `hermes-fix5-build.log` is the single "xcrun is unavailable" line, with no exit status. The package log runs the same build under `set -e` and ends `exit_status=0`, which is better evidence that the production target compiles. |

## 2. Earlier fixes still hold

**The FIX4 silent-Stop regression (R1) is gone.** The note path at `AppStore.swift:247-251` is unconditional. Only the banner is token-gated.

| # | Status | Evidence |
|---|---|---|
| F1 per-run Stop guard | Holds | `AppStore.swift:215-216,221,232,252,257`. Stream cleanup is token-guarded (`:201-203`). |
| F2 latest full-pair overlap | Holds | `mergeHermesHistory` is unchanged (`:89-125`). |
| F3 null or unsupported content | Holds | `HermesBackend.swift:129-156` is unchanged. |
| N1 no shrink or overwrite | Holds | Both returns are `local + …` (`:94,124`). Notes only insert or append. |
| N2 capture, then local cancel, then a single POST | Holds | `:229-233`. A double `stop()` is blocked by `stopInProgressForStream` (`:215`). |
| H1 capabilities first; legacy never calls Sessions | Holds | `HermesBackend.swift:67,78,99,114`, `AppStore.swift:76,177`. |
| H2 no Mock or user-bot deletion | Holds | Only `delete` (`:161`). Demo bots are hidden (`:42`). |
| H3 scoped approvals | Holds | `:189`, `ChatView.swift:20`, the owning backend (`:266`), cleared at run end (`:199`). |
| H4 no foreign-session adoption | Holds | `agentapp_<uuid>` (`:178`), with 409 treated as owned (`HermesBackend.swift:104`). |
| FIX4 F6 (UI), single Stop message, run-id token, 8 s timeout, divergence note | Hold | Unchanged apart from the FIX5 hunks above. |

## 3. Tests: do the waits test the right thing, and what do the logs prove?

| Test | Trace result |
|---|---|
| `stopCapturesThenCancelsThenPostsOnlyOnce` (`Tests:207`) | **Fixed.** It now waits for the "Stop requested" row itself, so the 80 ms POST delay no longer causes a false red. The second `stop()` returns at the guard (`stopInProgressForStream`), giving exactly one capture/post and the trace `["cancel","post"]`. Deterministic. |
| `anOlderStopRequestDoesNotBlockStoppingTheNextRun` (`Tests:220`) | **Fixed.** `isIdle` (`streamTask == nil`) becomes true only in the stream task's cleanup (`AppStore.swift:202`). By then the Stop task has already set `isStreaming=false` synchronously (`:232`), so `send("second")` passes both guards (`:164`). The second `stop()` passes because its token is different. The trace order holds: post #1 is enqueued on the actor before any later actor job. |
| `failedOldStopDoesNotClearOrReportAgainstNewerRun` (`Tests:234-240`) | **Fixed, plus a new placement check.** After `post-failed` is observed, the Stop task's catch has already run: both resumptions go through the serial main queue in order (the Stop task leaves the actor before the test's later `recordedCalls` job runs). So `errorMessage == nil` and the note in `dropLast(2)` are reliable. This test would fail under append, so it covers placement. |
| `failedCurrentStopIsReportedBesideStoppedTurn` (new) | Proves R1 is fixed (a note appears on the current run). L5 applies: weak on placement, and a force-unwrap crash risk. |
| `storeRejectsApprovalWithoutCommandText` (new) | Valid via `errorMessage`, because the guard is synchronous. The `!contains("approval")` half is weak: one `Task.yield()` may not be enough time for an unguarded call to record anyway. |

- **Determinism:** the waits are condition-based with a 2 s bound. There are no fixed sleeps in the tests themselves. They rely on FIFO main-queue ordering, which holds for `@MainActor` tests.
- **Still untested:** the registry token guard (private and bypassed by `TestBackend`), `URLError.cancelled` with and without task cancellation, `parseNative` approval extraction, the timeout path specifically, and the RID edge.
- **New code is uncompiled:** the FIX5 test code (and `isIdle` usage) has **never been compiled**, because there is no type-check this pass. By reading it, I see no compile errors: memberwise `ApprovalRequest(... draft:, botID:)` is valid given the defaults at `Models.swift:105-107`, and `await` inside `#expect` matches the existing use at `Tests:130`.

**What the saved logs prove:**

| Log | Proves |
|---|---|
| `hermes-fix5-swift-test.log` | The command is recorded and exited 72 on `_XPCTypeBool`, before compilation. **The tests never ran or compiled.** |
| `hermes-fix5-build.log` | One line with no status. On its own it proves nothing. |
| `hermes-fix5-package.log` | `package-release.sh` built first, re-signed, and produced `AgentApp-2bb74097ca18-dirty-arm64.zip`, with `exit_status=0` under `set -e`. That means the production target compiled and `codesign --verify --strict` passed. It does **not** show which source content was used (L4). |
| `hermes-fix5-fixtures.log` | The native fixture failed at bind `EPERM` on 18643, then the app reported "Operation not permitted" (exit 1). **The legacy fixture never ran** (L1). Zero fixture coverage. |
| `hermes-fix5-live-gateway.log` / `-live-client.log` | The gateway could not bind 18642 (`EPERM`), and the client exited 1. **Nothing live was exercised.** The key is masked as `<throwaway>`. |

## 4. Packaging and safety

- **Naming and `SOURCE.txt`:** honest as far as they go. The name and file say "2bb7409 + something uncommitted". They don't say what (L4).
- **Debug build for a personal install:** fine.
  - Neither `swift build` nor the fallback `swiftc` uses `-O`.
  - The source has no `#if DEBUG`, `assert` or `precondition`.
  - The cost is speed and binary size, not behaviour.
  - It is arm64-only and ad-hoc signed.
  - Expect Keychain prompts after each rebuild.
- **Safety: pass.**
  - Keys are only in Keychain (`com.konrad.agentapp.backends`) through `SecureField`, never in `@AppStorage` or `store.json`.
  - `HERMES_TEST_KEY` is read only in integration mode.
  - The hardcoded endpoints are loopback only: `AppConstants.swift:5`, `SettingsView.swift:9`.
  - A plaintext key to a non-loopback host is refused (`HermesBackend.swift:37-41,283`).
  - There are no owner servers, fleet IPs or domains. `SOURCE.txt` contains only a SHA and a boolean.
  - The logs reveal only the local home path.
- **`.gitignore`:** includes `dist/`. The `rm -rf` targets only `$ROOT_DIR/dist/AgentApp.app`.

## 5. README and docs honesty

- **Fixed since FIX4:**
  - The type-check claim was dropped.
  - "Verifies the production build" now reads "verifies that the production target compiles" (README:14).
  - The Stop-failure behaviour is documented (README:39, docs:23).
  - There is a MacBook checklist (docs:33-39).
- **Still overstated or missing:**
  - **L1:** "both native/legacy" (docs:29).
  - **L2:** the source claim about the command field has no excerpt (docs:23).
  - README:16 still says "Both `swift test` and `xcodebuild test` fail". The `xcodebuild` evidence is the FIX4 log; FIX5 reran only `swift test`. Minor.
  - Neither document says the package is an unoptimized debug build. README does not point to the checklist.
  - **L7:** checklist gaps.

---

## Must fix before installing on the MacBook

**No code changes block the install.** The install remains conditional on these steps, which the checklist mostly covers:

1. **Don't install the mini zip** (`AgentApp-2bb74097ca18-dirty-arm64.zip`). Copy the reviewed tree **including `.git`** to the MacBook with `rsync`/`scp`.
2. **Run `swift test` on the MacBook, and stop on any red.** This pass is the first compile of the FIX5 test code. A crash in `failedCurrentStopIsReportedBesideStoppedTurn` means the placement is wrong (L5).
3. **Build and package there.** Then smoke-test against the real gateway:
   - Stop mid-reply.
   - Send, then Stop again.
   - If practical, a failed Stop (wrong key or gateway down): confirm exactly one "Hermes Stop failed" note beside the stopped turn.
   - Reopen the bot and confirm history neither shrinks nor duplicates.
   - On the first real approval, confirm the command text appears and Approve is enabled (L2).

Recommended soon, not blocking: correct the docs for L1 and L2; add a diff hash to `SOURCE.txt`, or commit FIX5 before packaging (L4); use `#require` in the new test (L5); have `ChatView` use `isIdle` (L6); fall back to the wrapped `run_id`/`request_id` (L3).
