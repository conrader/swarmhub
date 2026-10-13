# AgentApp approvals fix3: re-review (uncommitted, on top of 6b76da3 + fix2)

**Verdict: PASS-WITH-ISSUES.** By trace, all three must-fix items from last round (T1, N9, N2r) are fixed in the code. The strongly recommended items are also done: N4r StopTarget capture, `rg --pre`, Git `--output`, and the editor wording. No code change blocks a **fresh** MacBook install. Three issues remain:

- **Existing data.** Bots saved by an earlier approvals build keep the old `read*`/`*` allow rule, because nothing migrates it (F1).
- **The N4r Stop test doesn't prove the fix.** It would also pass on the fix2 code (F2).
- **`swift test` has still never run.**

## Scope and limits

- **Swift was not built, type-checked or run here.** This is a Linux host with no toolchain. Everything below comes from reading and hand-tracing the code, plus Codex's logs.
- **Diff scope confirmed.** `diff -rq prev-tree .` shows exactly the 5 files in `APPROVALS-FIX3-sources.diff` (`Models.swift`, `AppStore.swift`, `BotEditorView.swift`, `AgentAppTests.swift`, `README.md`). `HermesBackend.swift` and `AgentApp.swift` are unchanged since fix2.
- **What the logs say, and the order they were written in:**
  - Last source edit: `AppStore.swift` 05:51:45.
  - `build.sh` passed (log 05:51:50).
  - Last test edit: 05:52:41.
  - Test-target `swiftc -typecheck`: PASS, with the exact command recorded (log 05:53:02).
  - `swift test` aborted on `_XPCTypeBool`.
  - The fixture run hit `PermissionError [Errno 1]` on binding `127.0.0.1:18643`, so **this pass has no fixture result at all**. The last passing fixture run was fix2's run under Ermes.
  - Package and SHA (05:54:17): the SHA `968c1684…89fa4` matches between `GIT-STATUS.txt` and `approvals-fix3-sha256.log`. The zip isn't in this tree, so I didn't hash it.
- **Hermes source.** I could not read the v0.21.7 redactor from here. `docs/hermes-integration.md:23` and README:27 now claim it was checked. I can't confirm that.

---

## Item-by-item

### 1. T1: **Fixed.**
- **The change:** `approvalThenFinish` now raises `cat /tmp/x` (`Tests/AgentAppTests/AgentAppTests.swift:32`). In reviewer mode with the owner's default rules, `cat *` is the first match and its outcome is `allow`, so routing continues (`AppStore.swift:318`). The guard passes (`:322`). `reviewerMustEscalate` passes (`cat` is reviewable), so the reviewer is called.
- **The three tests, traced:**
  - `reviewerEscalationFallsBackToUser` (`:474-485`): the reviewer escalates and `askUser` records `decidedBy "reviewer:<id>"` ✓.
  - `reviewerApprovalRequestEscalatesAndSelfReviewIsGuarded` (`:487-507`): the nested `"cmd"` approval comes from the *reviewer* stream. It produces `approval:false`, then `post`, then "Reviewer … escalated." ✓. `post` is recorded before `askUser`, so the `waitUntil` ordering holds. The self-review half asks with "would review itself" ✓.
  - `ownerStopCancelsAndStopsInFlightReviewer` (`:449-462`): now reaches the reviewer (`send`). See F2 for what it actually proves.
- **Ask mode is unaffected.** `approvalIsScopedAndClearedAtRunEnd` (`:509-519`) asks regardless of the command, and the run-end clearing after 180 ms is unchanged ✓.
- **The other `.hanging` user is unaffected.** It now yields a token first. The `.hanging` case in `reviewerApproveDenyErrorAndTimeoutRoutesSafely` (`:398-407`) still times out at 10 ms and records `post` ✓.

### 2. N9: **Fixed.**
- **The check:** `commandRequiresUserReview` lowercases the command and returns true on `...`, `***`, `[redacted]`, `<redacted>` or `«redacted` (`Models.swift:47-49`). It runs before the charset check.
- **Where it applies:**
  - Rules `allow` (`AppStore.swift:305`).
  - The reviewer pre-check (`:322`). Redacted commands escalate to the user and never reach the reviewer.
  - `deny` rules still deny, which is safe.
- **Effective coverage:** only `...` is newly load-bearing. `*`, `[`, `<` and `«` were already rejected by the ASCII allowlist. Any Unicode `…` mask is also rejected by the allowlist. So the only case left open is a hypothetical mask that adds no marker at all.
- **Tests are honest, but thin:**
  - `automaticAllowRejectsRedactedLookingCommands` (`Tests:139-143`): the assertions are true. However, only `cat /tmp/abc...wxyz` fails on the fix2 code. The other four strings were already rejected by the charset check.
  - There is no store-level case. For example, the default `cat *` preset with a redacted command should end in `asked` and no `approval:true`. (LOW)
- **Collateral:** `git log a...b` now asks. That is conservative and acceptable.

### 3. N2r: **Fixed for new bots.**
- **The preset is gone.** The `read*`/`*` preset was removed from `sensibleDefaults` (`Models.swift:22-31`). The remaining allow presets are all `actionPattern: "command"`.
- **The regression test discriminates.** `defaultPresetsDoNotBroadlyAllowReadActionKinds` (`Tests:145-147`) fails on the fix2 preset list and passes on the new one.
  - It tests the preset list, not `routeApproval`. That is adequate, because routing is first-match over this same list.
- **Gap: existing bots (F1).** Old data isn't migrated. See below.

### 4. N4r: **The code is fixed; the test isn't discriminating (F2).**
- **The capture:** `ReviewerStopTargetBox` (`AppStore.swift:7-11`) records the first `.serverRun` target. The reviewer child takes it on each event until it has one (`:361-364`).
- **Why that works on real Hermes:** `HermesBackend` sets the registry *before* it parses and yields each SSE line (`HermesBackend.swift:225-226`). So the first yielded event of a native run sees the run ID.
- **Every stop path now prefers the captured target:** nested approval (`:378`), timeout (`:381`) and catch/owner-Stop (`:387`). The live lookup is only a fallback (`:392-398`).
- **The owner Stop path, traced:** `AppStore.stop()` cancels `streamTask`. `routeApproval` is awaited inline (`:200`), so cancellation reaches the task-group children. The iterator ends and the child throws. The catch then schedules an unstructured `Task` that POSTs to the captured `run-1` ✓.
- **Residuals (LOW):**
  - **No capture without an event.** If the reviewer's Hermes run yields no events before Stop (provider still thinking, and `run.started` not surfaced as an event), nothing is captured. The fallback hits the same registry-clear race as before. The `.hanging` mode was changed to yield a token first, so tests only cover the case where an event arrived.
  - **Timeout still stops twice.** `:381` awaits a stop, then throws inside the `do`, and `:387` fires a second stop. Both now go to the same captured run. Harmless, but untidy.
  - **`run.cancelled` still counts as completion.** It maps to `.completed` (`HermesBackend.swift:281`). A reviewer run cancelled right after streaming `approve` still counts as an approval. This is not in README Known issues.
  - **Legacy transport polls every event.** It returns `.disconnectedLegacy`, which is never captured, so `stopTarget` (a cached `transport()` check) runs on every token. Negligible.

### 5. N2r extras: **Done.**
- **Git `--output`:** `--output` and `--output=` are rejected for git (`Models.swift:66`).
- **`rg --pre`:** `--pre` and `--pre=` are rejected when the executable is `rg`, including path-qualified and upper-case forms (`:69-70`).
- **Test strings:** `git log --output=/tmp/x`, `git diff --output /tmp/x` and `rg --pre=/tmp/hook pattern .` were added (`Tests:134`). Each is caught only by the new code ✓.
- **Abbreviation:** I don't consider `--outp=` a practical bypass. It is ambiguous with `--output-indicator-*`, and diff option parsing keeps unknown options. Not verified against git source here.
- **Editor wording:** the hint now says "reject a short list of known-dangerous programs/options … and redaction markers" (`BotEditorView.swift:39`). It no longer claims completeness ✓.

### 6. README Known issues: **Mostly accurate, with three omissions.**
- **Accurate:**
  - Denylist (README:25): explicitly "short", "not a general sandbox".
  - N3r (README:26): git `--delete`/`-m`/`--force` and deny→ask. These flags also pass under a user `git *` allow rule in rules mode, not only in reviewer mode, but README:25's general statement covers that.
  - N9 (README:27).
  - N8 side effect (README:33).
- **Missing:**
  1. Bots saved by earlier approvals builds keep the legacy `read*` allow rule (F1).
  2. `run.cancelled` is treated as completion for reviewer decisions (N4r).
  3. Config-driven exec under `git` in an attacker-controlled repo (fsmonitor, textconv, ext-diff, hooks). Arguably this is covered by "side effects hidden behind less common programs or options".
- **Stale references:** README:35 and README:59 still point at `docs/approvals-fix-*.log`. The latest logs are `approvals-fix3-*.log`.

### 7. Regressions: **none found.**
- **Approvals:** only stricter. The fixture commands (`cat /tmp/fixture` and `send fixture message`) are unaffected by the marker check, but the fixture did not run this pass.
- **Hermes Stop:** `AppStore.stop()` and `HermesBackend` are unchanged.
- **TestBackend changes:**
  - The `runActive` flag defaults to inert (`clearTargetOnCancel: false`), so the existing Stop tests (`:256-318`) behave as before.
  - `streamDidFinish` runs for every mode, which is harmless.
- **Reviewer sessions:** still one per approval and never deleted (documented).
- **History and persistence:** Codable is unchanged.
- **Packaging:** the script is unchanged. It is still a `-dirty` build of 6b76da3, so build on the MacBook from a committed tree rather than copying the mini zip.

---

## Findings by severity

### F1 (MEDIUM, existing data only): the legacy `read*`/`*` allow rule survives in saved bots
- **The cause:** `Bot` decoding takes the stored `approvalRules` verbatim (`Models.swift:170`). Any bot saved by 6b76da3 or the fix2 build keeps either "Allow reads (extended action kinds)" `read*`/`*` → allow, or the original `read*` preset.
- **The effect:** in rules mode, any approval whose action kind starts with `read` auto-allows every command that passes the guard. That includes `/bin/rm -rf /Users/me/x`, `chmod -R 000 …` and `cp … ~/.zshrc`. `rm` and `-rf` are not on the denylist, and `/bin/rm` doesn't match the `rm *` ask preset. Note that the fixture server itself emits `action_kind: "read_file"`.
- **Who is affected:** a fresh MacBook install with no saved store is not affected.
- **Fix:** add a decode-time migration that drops rules with `actionPattern == "read*" && commandPattern == "*" && outcome == .allow`, plus one test. Alternatively, have the user delete that rule by hand.

### F2 (LOW-MEDIUM, test honesty): the N4r Stop test passes with or without the capture fix
- **The cause:** `TestBackend.requestStop` records `"post"` for *any* target, including `.noActiveRun` (`Tests:53-57`). `"capture"` is recorded both by the live capture and by the fallback lookup (`Tests:52`).
- **Why it can't tell:** on the fix2 code, the fallback `stopTarget` would return `.noActiveRun` (or `.serverRun`, depending on timing). Either way it calls `requestStop` and records `"post"`. So `ownerStopCancelsAndStopsInFlightReviewer` (`Tests:459-461`) cannot distinguish fixed from unfixed.
  - On real Hermes the distinction matters: `requestStop(.noActiveRun)` is a no-op (`HermesBackend.swift:125`).
- **The code fix itself is correct by trace.**
- **Fix:**
  1. Record the target, for example `"post:run-1"` versus `"post:none"`, or record nothing for `.noActiveRun`.
  2. Assert `"post:run-1"`.
  3. Optionally clear `runActive` synchronously in `onTermination`, so the fallback deterministically sees `.noActiveRun`.

### F3 (LOW): N4r residuals
- **No capture before the first yielded event:** the fallback is still racy.
- **Two stops per timeout:** `AppStore.swift:381` and `:387`.
- **`run.cancelled` → `.completed`:** a cancelled reviewer run can still yield an `approve` decision (`HermesBackend.swift:281`). Fix by having the reviewer reject decisions from a cancelled run.

### F4 (LOW): misleading audit reasons
- **Rules mode** gives the same reason for every guard-driven ask: "shell control, substitution, redirection, or newline syntax" (`AppStore.swift:305`). That is now also the reason for redaction markers and dangerous programs/options.
- **Reviewer mode** says "Unsafe, destructive, or unparseable" (`:323`) for redacted commands.
- **Effect:** cosmetic only, but it will mislead anyone reading the audit trail.

### F5 (LOW): test and doc nits
- **N9 test:** only 1 of its 5 strings is load-bearing, and there is no store-level redaction test.
- **README:** README:35 and README:59 still point at `approvals-fix-*.log`.
- **N3r dead code (carried over):** the quote/backslash normalization in `reviewerMustEscalate` is still dead code (`Models.swift:78`).

---

## Must-fix before MacBook install

1. **Run `swift test` on the MacBook and treat any red test as a stop.** The suite has never executed. Every test claim here and in Codex's logs comes from type-checking and hand-tracing.
2. **Only if the MacBook will load an AgentApp store saved by an earlier approvals build:** migrate away the legacy `read*`/`*` allow rule (F1), or delete it by hand before putting any bot in rules mode. For a fresh install, this item is **none**.

**Recommended (not blocking):**
- F2: make the Stop test assert the captured `run-1` target.
- Add the F1 migration anyway.
- Treat `run.cancelled` as a reviewer failure.
- Refresh the README log references.

*Swift was not built, type-checked or run for this review (Linux host, no toolchain). Every claim above comes from reading and hand-tracing the code, plus Codex's fix3 logs.*
