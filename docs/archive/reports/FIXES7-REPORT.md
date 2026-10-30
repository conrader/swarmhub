# Fixes7 report: Codex review of fixes6 (issues A and B, mount-EPERM fallback)

Branch `swarmhub/peer-delivery`, base `0d64c7e`, Linux (Ubuntu, kernel 6.8, libseccomp 2.5.5, Python 3.12), 2026-10-19.
Input: `REVIEW-CODEX-FIXES6.md` (verdict: concerns) and `FIXES6-REPORT.md`. Findings 5 and 9 untouched. Hermes untouched.
No live Hermes or provider calls; every test runs synthetic CLIs and the shipped scripts against temporary repositories.

Commits: `f551ef5` (item 3), `0f4c2e3` (items 1 and 2), plus this report and the brief.

## Item 1: issue A, the no-user-namespace fallback cannot run common suites

Root causes: the fallback denied every signal syscall outright (BPF cannot express "your own descendants"), and
nothing writable existed for POSIX semaphores/shared memory, so `subprocess` timeouts could not end their child and
`multiprocessing.Pool` failed in `sem_open`.

What changed (the mode is now called the limited mode; its record word stays `fallback`):

- **Supervised signals**, `Resources/Skills/swarmhub-coding/scripts/verify_signals.py` (new, 223 lines). In limited mode
  `kill`, `tkill` and `tgkill` are seccomp user-notification calls answered by the unconfined launcher (`seccomp()` at
  `verify-sandbox.py:188-235`, `install_with_listener` at `:242-266`). The launcher pins the target with a pidfd
  (`Supervisor.pinned`, `:76-81`) so its pid cannot be reused, walks `/proc/<pid>/status` PPid to the sandbox root
  (`descendant`, `:62-74`; the launcher is a child subreaper, `verify-sandbox.py:385`, so orphans stay in the tree),
  and performs the signal itself with `pidfd_send_signal` or a pinned `tgkill` (`signal_process` `:83-91`,
  `signal_thread` `:117-129`). Process groups (`kill(0)`, `kill(-pgid)`) are enumerated and allowed only when every
  member is a descendant (`signal_group`, `:93-115`); the verifier gets its own group (`limited_run`,
  `verify-sandbox.py:348`). `kill(-1)`, the launcher, PID 1 and all host processes get EPERM. `pidfd_open` and
  `pidfd_send_signal` stay denied in the verifier (a `/proc/<pid>` directory fd is accepted by the latter).
  The filter is installed through `seccomp(2)` with `WAIT_KILLABLE_RECV` (libseccomp 2.5 cannot set it): without it a
  self-signal cancelled the pending request and `os.kill(os.getpid(), SIGUSR1)` raised `InterruptedError`.
  When the root exits, or the launcher receives INT/TERM/HUP, remaining descendants are killed (`kill_tree`,
  `verify_signals.py:182-197`), like the PID namespace's teardown.
- **Shared memory by name**, `verify-sandbox.py:38-39, 349`. The limited mode grants the host `/dev/shm` with
  `READ_FILE | WRITE_FILE | TRUNCATE | MAKE_REG | REMOVE_FILE` only: `sem_open`/`shm_open` create, open, size and unlink
  objects; listing and directories are denied. This is **not private**: without a mount namespace glibc's fixed
  `/dev/shm` path cannot be redirected, so same-uid host objects remain reachable by name (DAC still applies; the macOS
  profile already allows all POSIX shm/sem). This is the part that cannot be done privately, so it is stated in the
  mode and in the result (next point).
- **The limited mode is explicit in the job result.** The launcher writes the mode to a third argument path the
  verifier cannot reach (`record_mode`, `verify-sandbox.py:418-421`; `linux` `:392-394`); code-job passes
  `$T/verify-mode`, records `verify-mode` (`namespaced`, `fallback`, `seatbelt`, `-`) in the job record (`code-job:99,
  130, 142-145, 198`) and prints a stderr line in fallback. The completion wake says `verification command exit N in
  the limited sandbox (...)` and adds `Verification sandbox: limited (no user namespace): ...` naming the four limits
  (`peer-runtime.py:173-176, 194-211`); an exit 77 reads `the sandbox refused to start on this host`.
- `.git` protections from fixes6 are unchanged: `workspace_rules(namespaced=False)` is the same entry-by-entry rule set
  (`verify-sandbox.py:280-291`).
- `SKILL.md:85-94` documents the limited mode. The coding skill now ships `verify_signals.py`; `CodingSkillTests.swift:39,
  78` expect the fifth file; the file-by-file harnesses copy it (`Tests/Scripts/code-job-test.sh:18`,
  `sim/live_cli_probe.py:47`). `sys.dont_write_bytecode` keeps `__pycache__` out of the skill folder
  (`verify-sandbox.py:29`).

Regression tests, `sim/test_fixes7.py`, class `LimitedModeSuitesTests` (forced `SWARMHUB_VERIFY_NAMESPACES=0`):
the 5-test pytest-style module from fixes6 (Pool, `TimeoutExpired`, asyncio, self-signal, git) passes; a 5-test signal
module checks child SIGTERM, timeout kills the child, `killpg` of an own session and `kill(0)`, self-signal and
`raise_signal` without EINTR, and EPERM for PID 1, the launcher (`$PPID`), the test runner, `kill -1`, the runner's
process group and `pidfd_open`; shared memory is created and unlinked with listing and `mkdir` denied and no leftovers in
the host `/dev/shm`; `.git/config` stays byte-identical while a child is signalled; processes left behind (plain and
`setsid`) do not outlive the run; the mode file reads `fallback`, cannot be rewritten by the verifier, and reads
`namespaced` for a namespaced run. `JobResultModeTests` checks the wake wording for fallback, namespaced, seatbelt,
pre-field records and exit 77. `Tests/Scripts/code-job-test.sh` cases 17 and 20 check `verify-mode`.

## Item 2: unshare succeeds, mount returns EPERM

`namespaced_run` (`verify-sandbox.py:310-341`) runs the namespace attempt in its own forked process and reports to the
launcher's child over a pipe: `namespaced` once the mounts and the nested unshare succeeded, `fallback` when unshare was
refused or when the id maps, any mount or the nested unshare failed with EPERM/EACCES (`powerless_namespace`,
`:305-307`, the AppArmor signature). The launcher's child, never having entered a namespace, then takes the limited mode
(`linux_child`, `:358-377`). Any other errno keeps the old behaviour (refuse, exit 77), and a limited mode that cannot
confine (Landlock or seccomp failure) also refuses before running anything.

Tests, `MountDeniedAfterUnshareTests`: a wrapper (`sim/test_fixes7.py:150-170`) loads the shipped script with `runpy`
and patches `mount` through the functions' real globals; with EPERM an ordinary command runs in the limited mode (mode
file `fallback`, stderr says `no user namespace`), a child SIGTERM works, and `.git` writes, `mkdir` at top level,
outside writes and `kill -0 <runner>` are refused without exit 77; with EINVAL the run exits 77 and nothing ran; with EPERM
plus a broken Landlock the run exits 77, nothing ran and no mode is recorded. The class skips where user namespaces are
unavailable (there the real unshare path is already the fallback).

## Item 3: issue B, the plain `/goal` coding classifier

`Sources/AgentApp/Models/ChatAutomation.swift:114-160`. The first recognised verb decides: `explainVerbs` (explain,
describe, summarize, document, review, compare, question starters what/why/how/is/are/does, ...) make the goal general;
`codingOnlyVerbs` (implement, refactor, rewrite, debug, patch, compile, lint, typecheck, commit, rebase, ...) make it
coding; `changeVerbs` (add, fix, write, upgrade, update, bump, build, create, port, make, run, merge, test, ...) make it
coding only when a `codeNouns` word or `codePhrases` phrase follows them; words after "about"/"regarding" are the topic
of prose. Without a recognised verb a code noun decides. `requiresCodingEvidence` and `doneDetail` are unchanged callers.

Tests, `Tests/AgentAppTests/GoalTests.swift:269-294`, `plainGoalsAreClassifiedByTheRequestedAction`: 12 coding phrases
(the review's three plus "Can you fix the typo in the README", "Bump the Node version in CI", "Make the tests pass",
"Port the CLI to TypeScript", "the login bug", "Add retry logic to the scraper and explain the approach", and the three
earlier positives) and 12 general phrases ("Explain this function", "Describe how the users API works", "Summarize the
test results", "What does this script do?", "Write a blog post about Python", "Build a presentation for the board",
"Draft the release notes", "Review the pull request and list concerns", "How do I fix the build?", and the three earlier
negatives), each a single `#expect` in a loop, plus evidence checks: an explanation goal accepts a prose reply and an
upgrade goal rejects a bare done. The existing finding-8 tests are kept. No Swift toolchain here: the same rules were
run against the 24 phrases through a Python port of the function (0 misclassified), and the Swift was kept to plain
constructs (`if let` shorthand, array slices, no nested macros).

## Tests run here

| Command | Result |
|---|---|
| `python3 -B -m unittest sim.test_fixes6 -v` before any change | 18 tests OK, 3 Darwin skips (environment baseline: user namespaces available) |
| `cd sim && python3 -B -m unittest discover` | **194 tests in 110.9 s, OK, 3 skips** (Darwin-native), exit 0; log `/tmp/fixes7-python.log` |
| `sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | **22 passed, 0 failed**, exit 0 |
| `CODE_JOB_SH=/bin/dash dash Tests/Scripts/code-job-test.sh ...` | **22 passed, 0 failed**, exit 0 |
| Adversarial probe of the limited mode (independent Sonnet verifier, scratch repo, decoy `sleep 1000`) | CONFIRMED: kill/killpg/tgkill/tkill against the decoy, PID 1, the launcher and its ancestors all EPERM; `setpgid` into a host group allowed but `kill(0)` then EPERM; pidfd routes EPERM/EACCES; `/dev/shm` listing and mkdir denied, shm block create/unlink works; `.git/config` sha unchanged; daemonised descendant signalable; 3000 pid-reuse cycles, 0 hits. Log `/tmp/f7attack/report.md` |

The first shell-suite run after the change failed 13 cases: the harness copies the scripts one by one and did not copy
`verify_signals.py`, so every verification exited 77. Fixed in the harness and in `live_cli_probe.py`; the Swift skill
loader installs every regular file under `scripts/`, so the app side needs only the expectation change.

## Known limits of the limited mode (disclosed in the result)

- Shared memory is the host `/dev/shm` by name, not private (see item 1). Same-uid objects are reachable by name.
- The signal's `siginfo` sender is the launcher, not the calling process.
- A signal that arrives at a verifier process between its `kill()` entry and the launcher's receive still returns EINTR
  (kernel semantics; the window is microseconds and Python's default SIGCHLD disposition does not interrupt).
- Descendants killed by the launcher stay zombies until the launcher exits (it only reaps the root).
- A `__pycache__` appeared in `scripts/` during the local runs (something imported the sandbox as a module; the
  launcher itself sets `dont_write_bytecode`). It is gitignored, but the Swift skill loader bundles every regular
  file under a skill folder, so build the app from a clean checkout; `codingSkillShipsWithItsScript` would catch
  a stray one by its file-list assertion.
- Orphans are in the tree only because the launcher is a subreaper; an orphan that outlives a `SIGKILL`ed launcher is
  on its own (as before).

## Not done, or for Konrad

- Findings 5 (remote-box approvals) and 9: unchanged, per the brief.
- Skill versions not bumped (consistent with fixes5/6); the coding skill gains a file, so bots with the installed 1.3.3
  skill will not receive `verify_signals.py` until the version changes. Decide whether to bump `swarmhub-coding`.
- Whether "host `/dev/shm` by name" is acceptable for the limited mode, or whether Pool should rather fail there with the
  disclosure alone. Switching is one line (`verify-sandbox.py:349`).

## What still needs a real Mac

- `swift build`, then `swift test --filter 'GoalTests|CodingSkillTests'`: `plainGoalsAreClassifiedByTheRequestedAction`,
  `codingLikeGoalsRequireEvidenceUnlessMarkedGeneral`, `aPlainCodingLikeGoalIsSentBackWithoutEvidenceAndGeneralOptsOut`,
  `goalEvidenceFollowsExplicitTypeAndRejectsPlaceholders`, `codingSkillShipsWithItsScript`,
  `installTurnCarriesTheScriptAndTheVariant`; then the full suite (the fixes6 `ManagedLocalControlTests` are still
  pending a Mac run too).
- `python3 -B -m unittest sim.test_fixes6 sim.test_fixes7 -v` natively: the Darwin-native Seatbelt class from fixes6, and
  from fixes7 only `JobResultModeTests` runs (the limited mode is Linux-only); confirm `verify-mode` reads `seatbelt` in a
  code-job record there (`Tests/Scripts/code-job-test.sh` case 20 accepts it).
- An AppArmor host with `apparmor_restrict_unprivileged_userns=1` (the ovh box has 0) to see the real mount-EPERM path
  take the limited mode; here it is simulated by patching `mount`.
