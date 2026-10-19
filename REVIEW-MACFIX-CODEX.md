# macOS portability and shell SKIP review

Reviewed 2026-10-19 at `a0943c1`. Scope: `b82bfed`, `464595f`, and `a0943c1`
(including `b82bfed` itself, although Git's `b82bfed..a0943c1` excludes it).

**Verdict: changes required at the reviewed HEAD; the findings below are fixed
in the uncommitted working tree.** Offline validation passes, with genuine
environment skips reported separately. Native macOS/Swift validation remains
outstanding; this is not a claim that the Mac suite passed.

## Findings and fixes

1. **P2 — Process discovery could silently make cleanup vacuous.**
   `sim/test_peer_runtime.py:children_by_home` ignored the `ps` exit status,
   returned `[]` on launch/timeout errors, and had no positive discovery test.
   `_pids_by_home_ps` also split HOME values on whitespace, so a temporary HOME
   containing spaces could never match. A failed scan therefore looked like
   successful cleanup and could leave late workers behind.

   The helper now checks command status and output, tries BSD `ps axeww` when
   `ps -axEww` fails, is empty, or finds no matching HOME, and raises when neither
   command supplies a listing. Parsing preserves HOME spaces and checks value
   boundaries. Process listings are never included in error diagnostics.

   `sim/test_process_discovery.py` starts a real `/bin/sleep` child with a unique
   synthetic HOME containing spaces and requires that exact PID to be found.
   It exercises native discovery and the no-`/proc` route, and forces primary
   failure, empty output, missing environment, launch error, and timeout while
   retaining a real fallback command. The fixture is killed and reaped through
   its `Popen` handle even when discovery fails. No discovery test skips.

2. **P2 — Preflights converted unexpected failures into skips.**
   Both shell preflights treated every interpreter failure as an environmental
   limitation. Missing/broken Python, JavaScript errors, or unrelated socket
   errors could bypass every case and become a green Swift wrapper result.

   `Tests/Scripts/bot-msg-test.sh` and `accounts-recipes-test.sh` now reserve
   permission skips for `EPERM`/`EACCES`; missing selected Node remains an
   explicit dependency skip. Other errors fail. Success requires a positive
   `ok` result; Node additionally verifies the child's actual output. The socket
   probe includes `listen`, matching the stub server's required capability.
   Synthetic interpreter and errno regressions cover these distinctions.

3. **P2 — The accounts suite could test the wrong Node.**
   The preflight checked the requested Node symlink but put `/usr/bin:/bin`
   ahead of it when executing Node. A system Node could hide a broken selected
   installation, and the recipe checks had the same ordering problem.

   The isolated Node-only directory now precedes system directories in both
   preflight and recipe execution. The caller's directory is still not added
   directly, so it cannot introduce real coding CLIs. Tests supply a selected
   Node that fails or emits no result and require failure despite system Node.

4. **P2 — Accounts privacy assertions could pass with leaks.**
   The existing `expect ... lacks SECRET && lacks sk-ant && lacks '@' && lacks R-B`
   only recorded the first check in `PROBLEMS`. Later failures were discarded by
   `done_case`. This predates the three commits, but is a real vacuous assertion
   in the suite they change.

   Each check now goes through `expect`. Regression tests inject three separate
   synthetic leaks into a temporary recipe copy and require a failed suite.
   The real recipe and any real credentials are untouched.

5. **P2 — Swift accepted mixed failure/skip output as a skip.**
   `TestSupport.swift:shellSuiteSkipped` accepted exit 77 plus `SKIP:` anywhere,
   including output containing failed or partially executed cases. All seven
   shell wrappers gained this bypass, though only two suites have preflights.

   Recognition now requires one nonempty `SKIP: ` line, a nonblank reason, and
   no `FAIL:` marker. The reason is printed. Only accounts-recipes and bot-msg
   retain the early-return path. `ShellSuiteSkipTests.swift` checks bad statuses,
   embedded markers, blank reasons, multiple lines, failures, and partial runs.
   These are source-reviewed Swift changes; the Swift regression was not run.

The code-job shard correction now covers case 16 and retains its coverage
assertion. The portable permission-mode check and accounts recipe's ignored
stdin are consistent with the tested behavior. No additional correctness issue
was established in `b82bfed`'s bounded inbox/policy and FAKE-action changes;
their offline regressions passed.

## Validation

All suite processes ran with an allowlisted environment (`env -i`), temporary
HOME/TMPDIR, synthetic fixtures, and no outbound calls. Hermes, including its
backend source, was not modified. No real credential files were read. Nothing
was committed.

- `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`:
  **113 passed, 0 failed, 0 skipped** (57.598 seconds).
- All seven `Tests/Scripts/*-test.sh` suites were invoked under both `/bin/sh`
  and `/bin/dash`, with their corresponding `*_SH` variables set.

| Suite | /bin/sh | /bin/dash |
| --- | --- | --- |
| accounts-recipes | 6 passed | 6 passed |
| bot-msg | exit 77; 14 cases skipped | exit 77; 14 cases skipped |
| box-adopt | 11 passed | 11 passed |
| box-readings | 12 passed | 12 passed |
| claude-login | 5 passed | 5 passed |
| code-job | 16 passed | 16 passed |
| swarmhub-report | 22 passed | 22 passed |

Shell total: **144 passed, 0 failed, 28 skipped**. The sandbox denies loopback
socket creation; bot-msg emitted exactly one permission SKIP line per shell.
Its 28 functional cases were not executed and are not counted as passes.

- A deliberate `children_by_home = lambda home: []` mutation failed the real
  known-child test with `PROCESS DISCOVERY BROKEN`. The original `a0943c1`
  helper also failed with `/proc` disabled and Darwin selected on Linux, where
  `-E` is unsupported. This proves fallback/error coverage, not a native Darwin
  failure. The original parser independently missed a HOME containing spaces.
- Running the new socket-error and privacy regressions against temporary copies
  of the original scripts produced four expected failures: unexpected `EINVAL`
  was skipped, and each of three injected leaks still reported 6/6 passing.
- Shell syntax checks under both shells and `git diff --check` passed.

Logs and the shell runner are in `/tmp/macfix-codex-review/`: `sim.log`,
`shell-results.json`, per-suite logs, `run-shells.py`,
`discovery-mutation.log`, and `preflight-mutation.log`.

This host is Linux and has no Swift executable on PATH. The real BSD `ps e`
fallback ran here; native Darwin `ps -E`, macOS environment rendering, and the
Swift suite still need a Mac run. On macOS the same known-child test invokes
the native discovery path and fails if neither command finds the child.
Swift's accepted skip still returns normally from its wrapper; the printed
reason and shell exit 77 must be distinguished from executed assertions when
interpreting aggregate Swift test totals.
