# DARWINKILL1: Darwin verify-sandbox teardown ordering

Base: `swarmhub/peer-delivery` @ b4ebf2b, uncommitted. Closes REVIEW-CLAUDE-XREV3 detailed finding 2 / FIXES18 item 3
(deferred): on macOS the verifier's leader was reaped before `killpg`, and group death was never awaited.

## Design

`verify_darwin.run_grouped` (`Resources/Skills/swarmhub-coding/scripts/verify_darwin.py`) now runs:

1. **Start.** `Popen(start_new_session=True)`. The verifier (`sandbox-exec` → guard → `/bin/sh -c`) leads a new session
   and group. Its PID is the group ID.
2. **Wait without reaping.** `kqueue` `EVFILT_PROC`/`NOTE_EXIT` on the leader (`kqueue_wait`). An `ESRCH` at
   registration means the child has already exited: only our unreaped child can hold that PID. Linux has `os.waitid(WNOWAIT)` for
   the same job. That path exists for the Linux tests only; the Linux verifier never calls `run_grouped`. If neither
   facility exists, the launcher refuses with `OSError` and returns 77, still after teardown.
3. **Kill and drain.** `drain` sends SIGKILL to the group and repeats it until `killpg` reports `ESRCH`. The repeat
   covers a member that was forking during the first kill. `EPERM` counts as "members remain". A group that still answers is checked every 0.25 s
   with `/bin/ps -A -o pid= -o pgid= -o stat=`, and zombies do not count as live. This handles kernels where zombies
   answer `killpg` (Linux keeps the unreaped leader in its group). XNU's `killpg1` skips `SZOMB`, so the listing normally
   never runs on macOS. The deadline is 5 s.
4. **Reap.** `process.wait()` is the only reap, and no group signal follows it.
5. **Result.**
   - Live members after the deadline, or a failed listing: refuse with exit 77 and the message
     `descendants outlived the verifier (process group N still had live pids …)`.
   - Launcher interrupted: `128+signal`.
   - Otherwise the verifier's own status. Signal deaths become `128+sig`, matching the Linux path. Before this change,
     Darwin returned a negative value, which `sys.exit` turned into 247 for SIGKILL.

**PID-reuse argument.** Every `killpg(pgid, …)` happens while PID == pgid is still held, by the live leader or its
unreaped zombie. A new group with that ID can only be created by a process with that PID, so no unrelated group can be
signalled. Processes outside the session cannot join the group.

**Signal interruption.** While `run_grouped` runs, the launcher handles SIGTERM, SIGINT and SIGHUP. code-job's
`kill_tree` sends TERM to the launcher on timeout or cancel, and KILL one second later.
- The handler raises once, only while the launcher is waiting. Later signals are only recorded, so they cannot cut the
  drain or the reap short.
- A signal before `Popen` returns is recorded, and the wait is skipped. The leader is then alive and unreaped, so the
  group kill is still safe.
- Handlers are restored afterwards. A previous handler of `None` (installed outside Python) is left alone.
- PEP 475 retries `EINTR` in `kqueue.control` when no handler raises.

**SIGCHLD.** An inherited `SIGCHLD=SIG_IGN` makes Darwin auto-reap the leader. That frees its PID and makes `wait()`
report 0. `run_grouped` sets `SIG_DFL` for its duration.

**Options considered.**
- **Polling `killpg(pgid, 0)` while the leader is a zombie.** This is part of the design, but it needs the non-reaping
  exit wait that kqueue supplies.
- **A supervisor child that holds the group open.** Rejected: it adds a process. It also needs its own exit protocol,
  and it gains nothing over the zombie, which already pins the ID.
- **`os.waitid`.** Not available on macOS Python.

**setsid()/setpgid() escape (task 2): kept documented, not closed.** Two cheap options were evaluated:
- **Deny syscalls 147/82 with Seatbelt `syscall-unix`.** Rejected: XNU `posix_spawn` with
  `POSIX_SPAWN_SETSID`/`SETPGROUP` creates new sessions and groups in the kernel without those syscalls, so the escape
  remains. The deny would also break verifiers that legitimately use `start_new_session` (Python `subprocess`, Node
  `detached`), and it is unvalidated on a Mac.
- **An inherited sentinel pipe that detects survivors.** Rejected: daemonizers close their descriptors, so it is
  bypassable. Build-tool daemons (Gradle, Bazel) would also make those projects fail closed on every run.

The SKILL.md limits text states the escape.

## What changed

- `Resources/Skills/swarmhub-coding/scripts/verify_darwin.py` (105 → 256 lines): `wait_exited`, `kqueue_wait`,
  `signal_group`, `live_members`, `drain`, `exit_code`, and a new `run_grouped`. The call signature is compatible, with
  two injectable keyword arguments for tests. The Linux path (`verify-sandbox.py linux()`) is unchanged.
- `Resources/Skills/swarmhub-coding/SKILL.md`: the Darwin teardown text now describes the new ordering, drain, fail-closed
  77 and launcher-signal teardown. The remaining limit is the setsid/setpgid/spawn-attribute escape. Version
  **1.3.9 → 1.3.10**, because runtime behaviour changed.
- `Tests/AgentAppTests/CodingSkillTests.swift`: coding-skill version expectations are 1.3.10. The previous-version test
  now uses coding 1.3.9 and messages 1.3.8; messages stays 1.3.9.
- `sim/test_fixes8_skills.py`: coding bump `1.3.9 → 1.3.10`.
- New file `sim/test_darwinkill1.py` (27 tests, 5 Darwin-only):
  - **Mocked ordering (Linux).** Covers wait → drain → reap order, status mapping, survivors and unlistable members → 77,
    EPERM, zombie-only groups, launcher SIGTERM (guarded so a regression cannot kill the runner), a failed wait still
    tearing down first, a failed drain killing the leader before the reap, and the SIGCHLD reset.
  - **Fake kqueue.** Covers the registration flags, ESRCH at registration, error events and facility selection.
  - **ps parsing.** A malformed listing counts as unknown (fail closed).
  - **Real processes (`RealGroupTests`, Linux via waitid and macOS via kqueue).**
    - Nested and stopped descendants are dead at return, and the status is kept.
    - A background writer has stopped by the time the result is returned.
    - SIGKILL death → 137.
    - The leader is still listed (unreaped) while its group is signalled.
    - SIGTERM to a real launcher tears the group down → 143.
  - **`DarwinNativeTests` (skipped off macOS).**
    - The kqueue path is the one used.
    - A zombie-only drain takes under 1 s. It prints whether `killpg` skipped the zombie.
    - Through the real `verify-sandbox.py`/`sandbox-exec`: descendants and the writer are gone, statuses 0/9/137 are
      kept, and SIGTERM to the launcher → 143 with the background process dead.

## Independent review (Sonnet verifier, read-only)

- **Confirmed:**
  - Every group signal comes before the reap on all paths.
  - The status mapping is as described.
  - The code is 3.9-safe stdlib with valid macOS kqueue/ps usage.
  - The mutations are caught.
- **Refuted, now fixed:** if `drain` raised while the leader was still alive (an unexpected `killpg` errno, or a
  malformed `ps` line raising `ValueError`), the final `wait()` blocked forever.
  - Fix: a failed drain now sends SIGKILL to the group and the leader, which is safe because the leader is still
    unreaped, then reaps and re-raises. verify-sandbox turns that into 77.
  - A `ps` line that cannot be parsed now makes the listing count as unknown (fail closed).
  - Both have regressions.
- **Accepted behaviour:**
  - A TERM that arrives during the drain, after a normal verifier exit, reports `128+signal` instead of the verifier's
    code. code-job records 124/125 for those cases anyway.
  - code-job's KILL comes one second after TERM and could land during a slow drain. Its TERM pass has already hit the
    whole ps-tree, so this is defence in depth.

## What ran (Linux, Python 3.12)

- `py_compile` on all coding-skill scripts and the new test, plus an `ast` parse with `feature_version=(3, 9)` on the
  changed Python: OK.
- `sh -n`, `dash -n` and `bash -n` on `code-job`: OK.
- `shellcheck -s sh`: only the existing SC1007/SC2086/SC2317/SC2012/SC2015/SC2009 warnings and info notes, in files
  this change does not touch (`code-job`, `code-job-test.sh`).
- `test_darwinkill1`: 27 run, 22 pass, 5 skipped (Darwin-native). The same result came from `PYTHONPATH=sim /usr/bin/python3 -B -m unittest …`.
- **Mutation checks.** Each regression was planted, run, and then restored:
  - Reap before drain: 5 failures.
  - Single kill with no drain: 4 failures.
  - No launcher signal handlers: 2 failures.
- `test_fixes18`, `test_macsmoke5`, `test_macsmoke2`, `test_fixes12` (including the existing Darwin teardown test) and
  `test_fixes8_skills`: pass.
- Code-job shell suite `Tests/Scripts/code-job-test.sh` under `/bin/sh`, `/bin/dash` and `/bin/bash`: 23/23 each.
- Full suite from the repo root, `python3 -B -m unittest discover -s sim -p 'test_*.py'`: **403 tests OK, 12 skipped**. This is the rerun after the review fix above; the first run gave 402 OK.
- **Not run here:** the native Darwin tests, real kqueue and Seatbelt, Xcode Python 3.9, and `swift build`/`swift test`.
  There is no Mac on this box. The macOS facts this relies on are unverified until the Mac run:
  - The `select.kqueue` constants exist.
  - `NOTE_EXIT` fires without reaping.
  - `killpg` skips zombies. If it does not, the ps check still decides, with about 0.25 s added per verification.
  - `ps` field output.

Leftovers: none from this work. A stray `sleep 59.*` check was empty, and the `__pycache__` that `py_compile` created
under the scripts directory was removed. Pre-existing empty `/tmp/swarmhub-verify-*` directories appear in triples 30 s
apart throughout 2026-10-19/20. Re-running the relevant suites did not create any, so they were left alone.

## MacBook: one command

From the checkout at `/tmp/qm6` (Xcode `/usr/bin/python3`, Swift toolchain):

```sh
cd /tmp/qm6 && PYTHONPATH=sim /usr/bin/python3 -B -m unittest -v test_darwinkill1 test_fixes18 test_macsmoke5 && swift build && swift test
```

Pass criteria:
- `test_darwinkill1` runs with **0 skipped** in `DarwinNativeTests`/`RealGroupTests`.
- `test_a_zombie_leader_alone_drains_quickly` prints `killpg skips zombies: True`. `False` is not a failure; it means the
  ps fallback is in use.
- The Swift `CodingSkillTests` pass at 1.3.10.
