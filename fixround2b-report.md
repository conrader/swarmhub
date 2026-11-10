# Fix round 2b

Base: `958318d`. Seven scoped commits, one per requested item, on
`feat/fixround2b` in `/tmp/swarmhub-fixround2b-commits` (alternate git directory).
The checkout's original `.git` was left unchanged. `XREVIEW.md` was read and
removed; it was untracked at the base and is absent from all commits.

1. **#47 control state:** moved `.workload.json` into a sibling temporary 0700
   control directory under `swarmhub-jobs`. Reject bool/non-integer, <=1 and
   own-group pgids. Missing/corrupt/invalid state still enters runner TERM/KILL
   cleanup and returns 124. Regression coverage exercises deleted, corrupt,
   string, bool, low and own-group values and directory isolation.
2. **#47 runner grace:** start a fresh 120 s runner grace after workload cleanup.
   A simulated clock test consumes the workload grace and verifies the runner
   still receives its full grace. Queue snapshots have no workload group, so
   the route budget remains 60 + 120 + 45 = 225 s; allowance covers bounded
   post-KILL cleanup as well as transport/startup.
3. **#47 lingering descendants:** after leader exit, TERM the workload group,
   allow 2 s, then KILL with bounded drain. Supervisor regression verifies
   TERM/KILL and return for a lingering group.
4. **#47 post-KILL drain:** retry KILL during a maximum 5 s drain, with one
   diagnostic when that cap expires; bound runner reap too. Clear `pgid` under
   the control-file flock after confirmed drain, preserving cancellation.
   Regression verifies retries, bound and one diagnostic.
5. **#52:** assert `BACKEND_TIMED_OUT` in the parent-exits-first test. If process
   inspection fails during exception cleanup, still KILL and wait while
   preserving the original exception. Added a mocked inspection-failure test.
6. **Stubborn fixture:** restrict stubborn behavior to the held `stubborn`
   label. Simulate a 0.2 s runner post-job step and require its `end` event after
   workload grace and before the next job starts.
7. **Docs:** correct readiness queue budget/breakdown, workload and runner
   deadline phases, bounded cleanup and the requirement to install
   `mac-worker.py` on the Mac.

## Validation

Command: `cd ops/jobroute && /workspace/fr1-venv/bin/python -m pytest -q -p no:cacheprovider`.

- First full run: **524 passed, 48 failed, 4 skipped** (90.34 s), before the
  final three regression tests were collected.
- Final full run: **527 passed, 48 failed, 4 skipped** (90.12 s), including
  all added regression tests. The final fixture strengthening was also checked
  separately as noted below.
- Focused supervisor tests: **7 passed** (items 1–4).
- Backend timeout file: **12 passed**, including real signals and the new
  inspection-failure test (item 5).
- Mac queue fixtures plus queue timeout file: **29 passed** (items 2, 3, 6).
- After strengthening the runner post-job fixture: **1 passed** for the
  stubborn runner test (6.64 s).
- `git diff --check`: clean.

The 48 full-suite failures are outside the changed behavior: 11 Hermes checker
checks invoke `/usr/bin/python3`, which lacks `yaml` (confirmed directly), and
37 installer checks require `unshare --mount`, denied with `Operation not
permitted`. Four external sb-copy cases skip because `JOBROUTE_SB_COPY` is unset.
No relevant real-signal tests were blocked. No dependency installation or
sandbox bypass was attempted. No actual network, SSH, Mac or production check
was performed; a real Mac installation/runner check remains outstanding.
