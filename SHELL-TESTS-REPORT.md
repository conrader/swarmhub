# Shell suites re-run without a sandbox — 2026-10-19

Base: `b82bfed` on `swarmhub/peer-delivery`. Host: this Linux box (Ubuntu, `/bin/sh` → dash 0.5.12,
`/bin/dash`, node 18.19.1 with the system libuv, python3 3.12.3), no sandbox. Each suite was invoked the way the
Swift tests invoke it (`PATH=/usr/bin:/bin`, a temp `HOME`/`TMPDIR`, the suite's shell variable set), under both
shells. Runner and logs: `/tmp/swarmhub-shell-tests/` (`run-all.sh`, `before/`, `after/`, `replica/`, `sim-*.log`).
Hermes was not touched; nothing was sent, deployed or committed.

## Counts

| Run | Suite invocations | Cases passed | Cases failed | Blocked / skipped |
| --- | --- | --- | --- | --- |
| Codex, sandboxed (REVIEW-FIX-CODEX.md) | 14 | 140 | 4 | 28 blocked (bot-msg never started) |
| **Before** fix, this host, no sandbox | 14 | **172** | **0** | 0 |
| **After** fix, this host, no sandbox | 14 | **172** | **0** | 0 |
| After fix, seccomp replica of the sandbox | 14 | 144 | 0 | 28 skipped cleanly (exit 77, one `SKIP:` line each) |

Per suite and shell, before and after (identical): code-job 16, swarmhub-report 22, box-adopt 11, box-readings 12,
claude-login 5, accounts-recipes 6, bot-msg 14 — all passed, 0 failed, under `/bin/sh` and `/bin/dash`.

`sim/` (`python3 -B -m unittest discover -s sim -p 'test_*.py'`): **103 passed, 0 failed** before and after.

So every one of the 4 failures and 28 blocked cases was environment-only; no Swarm Hub script or recipe has a
bug behind them, and the memory note that `swarmhub-report-test.sh` fails 1/22 at HEAD is stale (fixed in
`b82bfed`, 22/22 here under both shells).

## Exact causes

### accounts-recipes: 2 cases × 2 shells failed ("status: versions, logins, pool…" and "codex: … then done")

Both cases assert `"installed":true,"version":"2.1.3"` from the Accounts-status recipe, whose node one-liner reads
versions with `execSync(tool + " --version", {timeout: 20000})` inside a `try` that returns `null` on any error.
In the Codex sandbox node threw `EPERM` although the stub ran and printed its version, so every tool came back
`installed:false`.

Reproduced here with a seccomp filter (`systemd-run --user -p SystemCallFilter=~<syscall> -p SystemCallErrorNumber=EPERM`),
one syscall at a time, on `spawnSync("/bin/echo", ["hi"], {timeout: 20000})`:

| Denied syscall | Result |
| --- | --- |
| `shutdown` | **status 0, stdout "hi\n", error EPERM** — the Codex symptom exactly |
| `socketpair`, `clone` | spawn fails before the child runs (no stdout) — not the symptom |
| `io_uring_setup`, `kill`, `pidfd_open`, `rt_sigqueueinfo`, `getsockopt`, `setsockopt`, `getsockname` | no error |

libuv builds the child's stdio pipes from `socketpair(2)`; with no input, Node's spawnSync closes the child's stdin
with `shutdown(2)` and reports that call's errno as the result's `error` even after a clean exit. A sandbox policy
that treats `shutdown` as a network syscall and denies it with EPERM produces precisely "stdout and exit status fine,
EPERM anyway". With `stdio: ["ignore", "pipe", "pipe"]` the same call succeeds under the filter. On a real box
(no seccomp) the recipe is correct, so the recipe was left unchanged; see "Not changed" below.

### bot-msg: 14 cases × 2 shells blocked

`Tests/Scripts/bot-msg-stub-gateway.py` could not create its listener: `socket.socket()` →
`PermissionError: [Errno 1] Operation not permitted` (Codex log, reproduced here by denying `socket`). The test
then printed `FAIL: stub gateway did not start` and exited 1 before any case ran. `bot-msg` itself talks to the
gateway with curl over loopback, so nothing in the suite can run without `socket(2)`.

## Changes (uncommitted, tests only)

- `Tests/Scripts/accounts-recipes-test.sh`: a preflight before the cases. If the node folder has no executable
  `node`, or `node -e 'execSync("/bin/echo ok", {timeout: 20000})'` fails (the status recipe's own call shape),
  it prints one line `SKIP: accounts recipe tests under <shell>: node cannot run a child process in this environment
  (Error: spawnSync /bin/sh EPERM)` and exits **77**, running no cases. Header documents it.
- `Tests/Scripts/bot-msg-test.sh`: a preflight before the gateway starts. If `python3 -I` cannot
  `socket.socket().bind(("127.0.0.1", 0))`, it prints `SKIP: bot-msg tests under <shell>: no loopback socket in
  this environment (PermissionError: [Errno 1] Operation not permitted)` and exits **77**. Any other gateway start
  failure is still a `FAIL`.
- Exit 77 is the usual "skipped" code (automake/meson). The Swift wrappers (`AccountsTests.swift`,
  `BotMessageSkillTests.swift`) still require exit 0 and the exact `N passed, 0 failed` line, so a skip surfaces
  there as a failure whose message is the `SKIP:` reason. They were not edited: no Swift toolchain on this box to
  compile them, and the Mac they run on is not sandboxed.

## Verification

- After the change, all 14 suite invocations: 172 passed, 0 failed, exit 0 (`after/` logs).
- Replica run of the whole runner under `SystemCallFilter=~socket shutdown` with EPERM: the 5 unaffected suites
  pass as before (144 cases), accounts-recipes and bot-msg exit 77 with the `SKIP:` lines above under both shells,
  and no log contains the word `FAIL` (`replica/` logs).
- `sh -n` / `dash -n` on both scripts, `git diff --check`: clean.
- No worker/supervisor processes left behind after the runs.

## Not changed (for Konrad to decide)

- The Accounts-status recipe in `Resources/BotManager/recipes/accounts.md` could pass
  `stdio: ["ignore", "pipe", "pipe"]` to `execSync`, which avoids the `shutdown(2)` call and would make the status
  read correct even under such a sandbox. Not applied: it is product text that Swift tests may pin, those tests
  cannot be compiled here, and on the target boxes the current code is correct.
- Swift tests were not run (no Swift here); the 1,327-test MacBook total remains unrevalidated, as in the Codex report.
