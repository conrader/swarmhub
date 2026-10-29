# MACFIX10 report

Base: `63d5352`, branch `swarmhub/peer-delivery`. Changes are uncommitted.
Only `sim/test_fixes5.py`, `sim/test_fixes7.py`, the new
`sim/test_macfix10.py`, and this report were changed. The existing untracked
`fixes8-brief.md` and `fixes8b-brief.md` were left alone.

Hermes was not altered or contacted. Tests used synthetic credentials, CLI stubs,
temporary repositories and fixture handlers. No real provider calls, outbound
deliveries, package installations or commits were performed. Native Mac acceptance
remains pending; the supplied Mac results are the baseline, not results for this patch.

## Python 3.9 compatibility

`test_fixes5` imports `tomllib` only on Python 3.11+. Its config-isolation test
now compares the complete generated config against a literal, known-valid, safe
TOML document on every version. This rejects additional tables/keys as well as
changes to the intended capabilities, without a partial TOML parser or a dependency.
On 3.11+, the real `tomllib.loads` call and all five original parsed-value
assertions still run. Authentication, source-config preservation and environment
scrubbing assertions remain unchanged. No existing test was skipped.

Three new regressions cover importing/running the isolation test with TOML imports
forbidden, rejection of six unsafe config mutations in both paths, and continued
parser invocation. The last test wraps real `tomllib` on 3.11+ and uses a parser
spy on 3.9. The six mutations enable network, apps, production writable roots,
a production MCP server, unrestricted sandboxing, or an unexpected table.

The audit covered all Python sources in `sim/`, `scripts/`, bundled skill scripts
(including extensionless `swarmctl`), and the shell/iOS/server fixture helpers:

- 68 source files compile with an already-installed **Python 3.9.25**, without
  writing bytecode. No interpreter or package was installed.
- Python 3.9 grammar checks also passed for 106 parseable multiline literals and
  three Python shell heredocs, including the appcast scripts and code-job stub.
- Imports, annotations, API calls and keyword arguments were inspected for newer
  requirements. No additional 3.10+/3.11+ dependency was found. Existing
  `zoneinfo`, `removeprefix`/`removesuffix`, `socket.send_fds`/`recv_fds`, and
  `os.waitstatus_to_exitcode` are available from 3.9. The timestamp importer
  already normalizes `Z` to `+00:00` before `fromisoformat`.
- Linux pidfd operations remain confined to Linux paths/tests. They are not
  invoked by the Darwin launcher. No app script, bundled helper or skill version
  needed changing.

## Cleanup test determinism

The original test searched **every host process's command line** for fixed strings
`sleep 37.91` and `sleep 37.92`. Another concurrent test invocation could match even
when this invocation cleaned up correctly. It also did not wait for the background
children to start, so a pass did not establish that the detached child reached `setsid`.

The replacement launches two indefinite, local Python children. Each acknowledges
its PID, process group and session; one uses `start_new_session=True` (setsid).
The verifier waits for an explicit stdin release. Before releasing it, the test
checks both children are alive, verifies ordinary/detached group membership and
opens pidfds to pin their identities. At launcher return, a **zero-timeout** pidfd
readiness check requires both children to have exited. There is no exit grace
period, natural sleep expiration, global process-name search or PID-reuse ambiguity.
Cleanup uses those same pinned identities if an assertion fails.

Evidence:

- 80/80 independent invocations passed with eight concurrent workers, while the
  full Python and shell suites were also running.
- A live unrelated `sleep 37.91` deterministically failed the original test and
  passed the replacement; the unrelated process remained alive in both cases.
- Two temporary launcher mutations selectively omitted ordinary-child or
  detached-child cleanup. Both caused the replacement's final liveness assertion
  to fail, with no test errors. The test then cleaned up its surviving child.
- The existing Linux-only gate is unchanged. This test still skips on macOS.

## Validation in this restricted Linux shell

This session cannot reproduce the user's **plain OVH shell** environment. Clean
`63d5352` was extracted with `git archive HEAD` into
`/tmp/macfix10-baseline-63d5352` and run under the same restrictions for comparison.

| Check | Untouched baseline | Changed tree |
| --- | --- | --- |
| Full `sim/`, system Python 3.12.3, default environment | 264 tests; 25 failures, 2 errors, 8 skips | 267 tests; **identical 25 failure and 2 error entries**, 8 skips |
| Code-job suite, `/bin/sh` | 10 passed, 12 failed | Same 10 passed, 12 failed |
| Code-job suite, `/bin/dash` | 10 passed, 12 failed | Same 10 passed, 12 failed |
| Code-job, existing Linux fallback selected, `/bin/sh` | 20 passed, 2 failed | Same 20 passed, 2 failed |
| Code-job, existing Linux fallback selected, `/bin/dash` | 20 passed, 2 failed | Same 20 passed, 2 failed |
| Full app `scripts/` Python suite | 56 tests; 5 errors | Same 56 tests; identical 5 errors |
| Config isolation class + new regressions, actual Python 3.9.25 | Confirmed `ModuleNotFoundError: tomllib` on import | **9 passed** |
| Same focused selection, actual Python 3.11.15 | Not rerun | **9 passed**, real TOML parsing |
| Final focused selection plus cleanup test, system Python | Not rerun | **10 passed** |
| Cleanup parallel stress | Collision reproduced separately | **80/80 passed** |

Failure/error counts above are unittest's counts, including subtest failures.
The full suites and both shells **were run**, but they are not claimed green here.
No failure was converted into a skip or accommodated by relaxing an assertion.

The primary restriction is namespace setup: even a bare verification of `true`
returns 77 with `Operation not permitted`. Selecting the existing fallback allows
`true`, but its deliberate prohibition on creating/removing top-level workspace
entries prevents the last two positive shell cases. Node's child-process operation
is also denied by the outer environment. The eighth sim skip is the existing
loopback-receiver preflight; the other seven require native macOS. App-script
errors are four denied loopback fixture listeners and unavailable macOS
`libcommonCrypto.dylib`, identically on the baseline.

An additional full sim run with `SWARMHUB_VERIFY_NAMESPACES=0` completed: 267 tests,
20 failures, 3 errors, 8 skips. Some tests explicitly select namespaces or build
their own child environment, so this does not bypass the outer restrictions.
The standalone Linux Python 3.9/3.11 builds lack `os.pidfd_open` and
`signal.pidfd_send_signal` at build time. A broader 3.11 run of fixes5 plus the new
tests therefore reported 22 tests, 6 failures and 1 error; an optional full 3.9
Linux sweep was interrupted after the same limitation caused child-test timeouts.
These interpreters were used successfully for the compatibility checks above;
system Python was used for the complete Linux suite and cleanup stress. This is
not a new Python-version requirement and does not affect the Mac path.

Logs are `/tmp/macfix10-python.log`, `macfix10-baseline-python.log`,
`macfix10-shell-{sh,dash}.log`, `macfix10-baseline-{sh,dash}.log`,
`macfix10-fallback-{python,sh,dash}.log`,
`macfix10-baseline-fallback-{sh,dash}.log`,
`macfix10-{app-python,baseline-app-python}.log`,
`macfix10-python{39,311}-compat.log`, `macfix10-parallel.log`,
`macfix10-cleanup-controls.log`, `macfix10-final-focused.log`,
`macfix10-python39-baseline-import.log`, and `macfix10-compat-audit.log` (all under `/tmp`).
Swift was not rerun; no Swift or shipped code changed. `git diff --check` passes.

## Exact Mac acceptance

Run from the checkout containing this patch, using the system Python; no pip or
other installation is needed. Record the revision and interpreter first:

```sh
git rev-parse HEAD
git status --short
sw_vers
/usr/bin/python3 --version

# Previous 60-test Mac selection + all 19 fixes5 tests + 3 new regressions.
# Expected: 82 tests, only the existing 12 Linux-only skips.
PYTHONPATH=sim /usr/bin/python3 -B -m unittest \
  sim.test_remote_approvals sim.test_fixes6 sim.test_fixes7 \
  sim.test_fixes9_darwin sim.test_fixes9_approvals sim.test_macfix9 \
  sim.test_fixes5 sim.test_macfix10 -v

# Full Python discovery, including all existing platform gates.
PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py' -v
/usr/bin/python3 -B -m unittest discover -s scripts -p 'test_*.py' -v

/bin/sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"
if [ -x /bin/dash ]; then
  CODE_JOB_SH=/bin/dash /bin/dash Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"
fi
```

Acceptance requires every fixes5 and macfix10 test to run, no `tomllib` import
error, all native Mac sandbox checks to retain their prior assertions, and 22/22
shell cases on each installed shell. The 82-test selection's twelve skips remain
the three Landlock, six limited-mode and three mount-namespace tests. Full
discovery has additional Linux-only gates; record any skip by name. Run the Linux
cleanup test on the plain box too; Mac's existing platform skip cannot validate it.
