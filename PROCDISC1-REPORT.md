# PROCDISC1: process discovery on macOS (e63dcf1)

## Cause

This is not a regression in 78e73df..e63dcf1. The helper under test, `sim/test_peer_runtime.py`
(`children_by_home`), was last changed in 868a070. `git diff --stat 78e73df..e63dcf1` doesn't touch it or
`sim/test_process_discovery.py`. darwinkill2's `bounded_listing` is used only by `verify_darwin.live_members`
and isn't on this path. The test was added in 56ca8b1. As far as we can tell from the briefs and reports, every
earlier MacBook acceptance ran named module subsets (`test_darwinkill1 test_fixes18 …`, "60 tests OK") or Swift.
Swift reaches `children_by_home` only through an "is empty" check, so an empty result passes there. mac-mt2 was
the first Mac run of the full `discover -s sim` (the mactest2 command), so it was the first run that executed this test.

The macOS ps path can't see the child's `HOME` (inferred: it hasn't been observed with a direct probe on the Mac):

1. `ps -axEww` returns a listing (the "both fail" error was never raised), but the `/bin/sleep` row has no
   environment. With SIP on, macOS withholds the environment of restricted (CS_RESTRICT) platform
   binaries such as `/bin/sleep` and `/bin/sh` from other processes. The expected restricted row is
   `PID /bin/sleep 60`, without HOME. The reported MacBook symptoms (a readable listing but empty discovery)
   fit that explanation; the direct probe below must still verify the actual child rows on that host.
2. The dashless `axeww` fallback also requests the environment on macOS, subject to the same withholding.
   The original procdisc1 claim that this spelling meant all processes was wrong. Apple's
   [ps.c](https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/ps.c) calls
   `kludge_oldps_options`, which sets `u03 = 0` for dashless options (lines 1319–1322).
   In legacy mode, `case 'e'` falls through to `case 'E'` and sets `needenv`/`eflg` (lines 274–283).
   Only Unix2003-mode `-e` has the all-processes meaning.

So the subtests that force the fallback fail the same way. The two passing tests (both-fail error and the parser)
never run a real Mac listing.

## Change (`sim/test_peer_runtime.py`, ps path only; Linux `/proc` path unchanged)

- One extra environment-free listing, `/bin/ps axww -o pid=,ppid=,stat=,command=` (live rows only, zombies
  dropped). If it fails, comes back empty or can't be parsed, discovery raises `process discovery failed`
  (fails closed).
- A live descendant in both snapshots is included alongside `HOME=` matches, using PID and the plain
  listing's ppid chain. Procdisc1 originally required equal commands; procdisc2 removes that condition
  because exec between snapshots could cause a false empty. This deliberately includes other-HOME
  descendants too. Requiring presence in both snapshots excludes the short-lived ps probes themselves.
- Unchanged: a readable listing with no match still returns `[]`, and both env listings failing still raises.
- Known limit: a restricted-binary orphan (reparented to launchd) whose environment is withheld is still
  invisible on macOS. Nothing an unentitled process can read exposes its `HOME`. This is documented in the
  docstring.

`sim/test_process_discovery.py`: fallback call order is `["axww", "-axEww", "axeww"]`. Both-fail coverage
includes "plain listing works, both env listings fail". Linux-runnable mocked Darwin fixtures now cover
withheld children/grandchildren, other-HOME descendants, HOME-marked children/orphans, excluded withheld
orphans/zombies, command changes between snapshots, and an unavailable plain listing failing closed.
Both environment spellings preserve unrestricted processes' environment in the corrected fixture.

**Original procdisc1 validation (before review corrections).**
- With the new tests against the e63dcf1 helper: all 3 Darwin tests fail, plus the 5 fallback subtests
  (call-order assertion).
- Mutation (delete the `found += … _withheld_descendants …` line): 2 Darwin tests fail (the found-cases). The
  fail-closed test still passes, as it should, because it is independent of that line.
- Restored: 8/8 OK.

## Original procdisc1 runs (Linux, ovh)

- `PYTHONPATH=sim python3 -B -m unittest test_process_discovery`: `Ran 8 tests … OK`.
- `PYTHONPATH=sim python3 -B -m unittest test_process_discovery test_darwinkill1 test_darwinkill2`:
  `Ran 49 tests in 2.874s` / `OK (skipped=5)` (the macOS-native `DarwinNativeTests`).
- `PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py'`: `Ran 425 tests in 414.824s` /
  `FAILED (failures=14, skipped=12)`. All 14 failures are `test_macsmoke2.SmokeStubTests`, each
  `Items in the first set but not the second: 'macsmoke1.…' : disposable dirs left in /tmp`. Those dirs came
  from other sessions running the smoke suite at the same time (peer-review/mactest3, then
  wt-uistub1/wt-pyc314). No other test failed.
- `test_macsmoke2` alone: **not completed in isolation.** The first rerun overlapped peer-review's own
  `test_macsmoke2` run (`Ran 16 tests in 264.164s`, `FAILED (failures=15)`, the same /tmp-leak assertion). A
  quiet-box wait (`pgrep` for code-job-test/unittest smoke runs) then hit its 1 h limit, with other jobs'
  smoke suites still running. This change doesn't touch `test_macsmoke2` or anything it executes. It still
  needs a quiet-box rerun.
- `Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job`:
  `code-job tests under /bin/sh: 23 passed, 0 failed` under `sh`, `dash` and `bash` (rc=0 each).
- Not run: macOS (cause unconfirmed until the command below), Swift, the `scripts/` suite.

## procdisc2

- Concern 1: replaced command equality with PID/ppid ancestry for live descendants seen in both listings.
  `test_exec_between_ps_snapshots_cannot_report_clean` mocks a child exec between snapshots, with no HOME
  visible. It failed against the incoming procdisc1 helper (`[] != [900001]`) and passes after the fix.
- Concern 2: checked Apple's source above and corrected the docstrings, fixture and report. Keep the
  fallback: procps rejects `-E`, while dashless `axeww` requests environments on both platforms. Keep the
  five forced-fallback subtests (error, empty, no match, OSError, timeout). The Darwin fallback fixture now
  includes a HOME-marked orphan, which ancestry alone cannot find, alongside withheld descendants.
- Concern 3: `PYTHONPATH=sim python3 -B -m unittest sim.test_process_discovery sim.test_peer_runtime
  sim.test_darwinkill1 sim.test_darwinkill2`: 63 tests in 14.097s, OK (5 macOS-native skips).
  `PYTHONPATH=sim PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest discover -s sim`: 426 tests in
  375.608s, FAILED (17 failure records, 13 skips). Eight failures in `test_fixes6/7/8` concern unavailable
  user namespaces, fallback mode, or EPERM/permission-denied operations in this sandbox. Nine
  `test_macsmoke2` failures hit the host-global `/tmp` assertion (including another job's
  `code-job-test.kdnQJ1`, before our standalone shell run started). The discovery tests passed.
  `PYTHONDONTWRITEBYTECODE=1 /bin/sh Tests/Scripts/code-job-test.sh
  "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"`: 23 passed, 0 failed.
  One separate `PYTHONPATH=sim PYTHONDONTWRITEBYTECODE=1 python3 -B -m unittest sim.test_macsmoke2`
  retry (GNU timeout: INT after 595s, KILL after 5s): 16 tests in 271.260s, FAILED (3 failures), all
  host-global `/tmp` assertions. No other tests from this session ran alongside it; external activity
  persisted. **Not run cleanly in isolation**; no further retry or quiet-box wait.
- `git diff --check` passed. All touched files are under 500 lines; worktree smoke fixtures were removed.
- Only the two sim files and this report changed; no Hermes changes or real provider/message calls.
  The Mac cause remains an inference until the probe below is run on the affected host.

## Mac command to confirm

From `/tmp/qm6`, using `/usr/bin/python3`. The probe prints SIP status and only the two synthetic child rows,
under the same disposable HOME. It resolves the selected Xcode Python with `xcrun`, checks for missing HOME
on `/bin/sleep` and visible HOME on Python, and reaps both children before running discovery tests.
If that pattern is absent, the suspected cause is not confirmed on that host.

```sh
(
cd /tmp/qm6 || exit
csrutil status
/usr/bin/python3 -B - <<'PY'
import subprocess, tempfile, time
xcode_python = subprocess.check_output(["/usr/bin/xcrun", "--find", "python3"], text=True).strip()
print("Python control:", xcode_python, flush=True)
with tempfile.TemporaryDirectory(prefix="procdisc2-probe-") as home:
    children = []
    try:
        for argv in (["/bin/sleep", "30"], [xcode_python, "-B", "-c", "import time; time.sleep(30)"]):
            children.append(subprocess.Popen(argv, env={"HOME": home, "PATH": "/usr/bin:/bin"}))
        time.sleep(1)
        assert all(child.poll() is None for child in children), "probe child exited"
        rows = subprocess.check_output(["/bin/ps", "-Eww", "-o", "pid=,command=", "-p",
                                        ",".join(str(child.pid) for child in children)], text=True)
        print(rows, end="")
        by_pid = {int(row.split(None, 1)[0]): row for row in rows.splitlines()}
        sleep_row, python_row = (by_pid[child.pid] for child in children)
        confirmed = "HOME=" not in sleep_row and "HOME=" + home in python_row
        print("withheld-HOME pattern:", "CONFIRMED" if confirmed else "NOT CONFIRMED")
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=5)
PY
PYTHONPATH=sim /usr/bin/python3 -B -m unittest -v sim.test_process_discovery sim.test_peer_runtime sim.test_darwinkill1 sim.test_darwinkill2
)
```
