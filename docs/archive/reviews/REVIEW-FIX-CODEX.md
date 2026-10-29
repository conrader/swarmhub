# Codex cross-review of 07fd5d4

**Verdict: ship-with-fixes; code corrections applied, native validation pending.**

Reviewed `07fd5d4` against `../20261019T094756Z-patterns-review.review.txt`,
`REVIEW-PATTERNS.md`, and the “Review fixes” section of `PATTERNS-REPORT.md`.
The five high/medium findings are addressed within the documented trusted-local
execution boundary after the additional fixes below. Swift compilation and the
MacBook test rerun remain unverified because this host has no Swift toolchain.
All changes remain uncommitted. Hermes itself was neither edited nor deployed;
`Sources/AgentApp/Backends/HermesBackend.swift` is Swarm Hub's client adapter.
No outbound service calls, real credentials, or deployments were used.

## High/medium findings, checked individually

1. **HIGH — receipt binding: fixed in 07fd5d4.**
   `Resources/Skills/swarmhub-messages/scripts/swarm_delivery.py:75` binds a running
   receipt by delivery ID, recipient and session; `deliver` attaches that ID to the
   message. `peer-runtime.py:100` passes the current user message through. Ordinary
   interleaved sends cannot acknowledge an unseen delivery by session alone.
   Passing regressions exercise ordinary sends, a foreign session, multimodal text,
   ID-bearing delivery, and reuse after acknowledgement without another send.

2. **HIGH — held-context spill: incomplete in 07fd5d4; corrected here.**
   `Resources/Skills/swarmhub-messages/scripts/peer-runtime.py:104` and `:127` now
   enforce the 9,000-character cap even for the first message and legacy policy
   records. The prior `and batch` condition admitted an oversized first row; old
   inboxes can still contain 32,000-character messages. Old policies also predate
   the model-name length check. Neither oversized content nor an omitted policy is
   acknowledged. Smaller queued messages can proceed. Two new regressions fail
   against HEAD and pass with these changes; existing batch-overflow tests pass.
   Oversized legacy rows remain intact and pending, with a diagnostic in
   `job-wake.error`; resend them with priority/durable mode. Publish a shorter
   oversized policy. The cap assumes Hermes' default 10,000-character spill limit;
   a locally configured lower limit is outside this verification.

3. **MEDIUM — FAKE execution: scheduler fix verified; direct task-bound execution bypasses closed.**
   `swarm_jobs.py:33` and `:104` make scheduled FAKE operations and direct
   `run-action` no-ops. However, `check_job` still admitted a queued FAKE coding
   record, allowing direct `code-job --task-id` to execute it before the scheduler
   processed it. `swarm_jobs.py:26` now rejects that admission. The shared
   `swarm_policy.py:290` active-task check also rejects FAKE records, including
   completed ones, so direct held/priority/durable peer sends cannot use them.
   Direct `run-action` still records FAKE without executing. The coding assertion
   fails against HEAD and passes here; tests also reject each direct peer entry
   point and verify every FAKE kind creates no external marker or delivery.

4. **MEDIUM — recovery-worker failure: fixed in 07fd5d4.**
   `peer-runtime.py:245`, `:264`, and `:303` guard both scheduling and delivery
   sweeps and supervise worker exits with backoff. Passing tests inject SQLite
   exceptions, a malformed completion record, supervisor exit sequences, and a
   real SIGKILL of an isolated worker. Recovery continues/restarts as expected.
   This is worker supervision; killing the supervisor still needs a startup path.

5. **MEDIUM — caller-supplied approval actor: fixed to the requested local boundary.**
   `swarm_store.py:97` resolves the invoking profile from `HERMES_HOME`;
   `swarm_policy.py:222` checks that identity against both argv and the configured
   role, then records actor/PID/time. Passing function and CLI tests reject missing
   identity, impersonation by argv, and a non-owner, and accept the owner gateway.
   This remains a same-Unix-account identity check and audit trail, not protection
   against a shell deliberately changing its environment or editing local state.

The low fixes also retain passing coverage: PID/start-time matching, policy-only
context wording, launch-time parameter binding, stdout-only completion checks,
and the split control modules. No additional changes were needed for those paths.

## MacBook Swift failures and version/report fixes

- **Seven BotMessage comparison failures:** `BotMessageTests.swift:22` and `:56`
  expected `durable == nil`; parsed contemporary commands explicitly set `false`.
  Expectations now include `durable: false`; `taskID` correctly remains nil.
  Parser behavior and compatibility with old persisted calls are preserved.
- **Legacy provider-failure run ID:** the captured legacy response contains no
  `run_id`. The process-wide registry keyed only by session could expose a native
  run from a different concurrent backend using `QA-live-regression`.
  `HermesBackend.swift:4` now keys by connection scope (base URL, profile and key
  fingerprint) plus session. Reads for current-run/steer/stop, writes, and cleanup
  use that scope; stream-token cleanup still protects replacement runs.
  A deterministic regression at `HermesLiveRegressionTests.swift:106` holds a
  native stream open while a different gateway's legacy request fails, and checks
  both gateway/profile isolation and preservation of the native run.
- Messaging skill, coding skill, and generated peer plugin are **1.3.1**. Updated
  native version/install expectations and the Python plugin-install assertion.
- **Report suite 21/22:** GNU `stat -f %Lp` can emit filesystem details before
  failing, polluting the BSD/GNU fallback's captured mode. The test helper at
  `Tests/Scripts/swarmhub-report-test.sh:48` now reads portable `stat.S_IMODE`
  through Python. Both folder 0700 and file 0600 checks remain enforced.

## Executed validation

All suite runs used synthetic fixtures and temporary homes. `/bin/sh` and
`/bin/dash` were both invoked; on this Linux host sh resolves to dash.

- `python3 -B -m unittest discover -v -s sim -p 'test_*.py'`: **103/103 passed**.
- Baseline replay: the two legacy-size regressions and FAKE coding admission
  assertion produced **3 expected failures against unmodified 07fd5d4 functions**.
- Python syntax: **21 files passed**; relevant shell syntax passed under both
  shells; `git diff --check` passed.

| Tests/Scripts suite | /bin/sh | /bin/dash |
| --- | --- | --- |
| code-job | 16 passed, 0 failed | 16 passed, 0 failed |
| swarmhub-report | 22 passed, 0 failed | 22 passed, 0 failed |
| box-adopt | 11 passed, 0 failed | 11 passed, 0 failed |
| box-readings | 12 passed, 0 failed | 12 passed, 0 failed |
| claude-login | 5 passed, 0 failed | 5 passed, 0 failed |
| accounts-recipes | 4 passed, 2 failed (environment) | 4 passed, 2 failed (environment) |
| bot-msg | 0/14 run; fixture blocked | 0/14 run; fixture blocked |

Totals: **140 shell cases passed, 4 failed, 28 blocked before execution** across
14 distinct suite/shell combinations. Four combinations exited nonzero. The
coding suites were rerun after the final FAKE-boundary change. Accounts failures are the
installed-version/status and post-logout status checks: Node's synchronous child
process API reports `EPERM` even for `/bin/echo`, despite its successful stdout
and exit status; `execSync` consequently throws. The bot-msg HTTP fixture cannot
create its loopback socket (`PermissionError: Operation not permitted`). The
file-based peer transport regressions in sim passed. Neither sandbox restriction
was bypassed, and these failures are not reported as passes.

Logs: `/tmp/swarmhub-codex-review/sim.log`, `scripts-summary.log`, individual
`<suite>-sh.log` / `<suite>-dash.log`, and `reproduce-head.log` in that directory.
No Swift tests were compiled or run; the reported MacBook total of 1,327 tests
has not been revalidated here. No live Hermes-version/hook compatibility claim
is added. Rerun `swift test` on the MacBook and the blocked suites in a permitted
local test environment before treating validation as complete.
