# Stack merge readiness: PRs #35 to #52

For Konrad and Jarvis, to decide whether and how to merge the draft stack.
Written 2026-11-08 (backlog14) for #35 to #48. Extended to #52 and test
results rerun on 2026-11-08 (mergeprep, after Jarvis stopped new stacking
at #52). Nothing in this document has been merged, deployed or parked.

Sources: `gh pr view` for each PR (bodies, heads, bases), the job reports
`~/work/Swarmhub/backlog1-report.md` to `backlog13-report.md`,
`jrinst148-report.md`, the job review files (`*.review.txt` / `*.json`), and a
read-only look at the live jobroute symlink on ovh. The jobroute sandbox
suite (`ops/jobroute/tests/run-sandbox.sh`, pytest plus the ssh harness) **was
rerun at every head #35 to #52 and at a local combined tip**. See "Test
reruns" below. All other figures (Mac/Swift, pysuites, updater, sim) are as
reported by each job at the time and were not rerun.

## Summary

- 18 PRs, one linear stack: #35 targets `main` and each later PR targets the
  one before it. Checked 2026-11-08: every PR head on GitHub matches the SHA
  below, and each head is an ancestor of the next (`origin/main` 4e9d4de is
  an ancestor of #35). #35 is open but not marked draft. #36 to #52 are
  drafts. No new SwarmHub follow-ups are stacked after #52 (Jarvis).
- **jobroute sandbox suite green at every head**, #35 to #52 and the combined
  tip (565 passed, SSH 23/23). No head failed.
- **The repo has no CI.** No branch has a status check, and there is no
  `.github/workflows`. The test gate is therefore a rerun of the listed suites
  at the PR head, by hand or by sb-codejob.
- **Live state on ovh:** `~/.local/lib/jobroute/current` points to
  `releases/148f9058…` (#35's head), switched 2026-11-08 10:40 UTC
  (re-read 2026-11-08 by mergeprep).
  `jrinst148-report.md` still says "live OVH remains on f816454". That
  report predates the install. The rollback target is f816454 (#8's head).
- **Codex cross-review is owed for #38 to #52.** Codex (gpt-6-astra) wrote
  #35 to #37, and a Claude reviewer gave PASS on their final jobs (macgreen1,
  backlog1, backlog2). The backlog3 Codex attempt (gpt-6.1-sol) was killed
  (exit 143, review FAIL). Because of the hold, Claude wrote #38 to #52 and no
  second model has reviewed them.
- #35 copies #8's jobroute directory (`f816454`) in a provenance commit; the
  git history is not shared. #6 and #8 are still open against
  `feat/hermes-jobroute` and `main`. Once #35 lands they are superseded.
  Merging them separately would create a second, conflicting route version.

## Merge order and gates

Merge strictly in order: #35, #36, #37 … #52. Before **each** merge:

1. **Tests green at the head.** Rerun the suites listed for that PR below, at
   its exact head SHA, after the previous PR has landed and the base has been
   moved to `main`. With no CI, the job report is the record; keep the log.
   The mergeprep reruns below are the pre-merge baseline. Once a base has
   moved to `main`, rerun at the head again. Because the stack is linear and
   `main` has not moved, the head trees should not change.
2. **Cross-review.** #35 to #37: done (Claude PASS on the Codex work). #38 to
   #52: a Codex cross-review, owed and on hold.
3. **Konrad's OK** for that PR, after reading its risks.
4. **A park for anything live.** If a PR changes something that runs on ovh
   or the Mac, the live install goes through sb-park and Jarvis's sb-approve.
   It never happens as part of the merge.

Mechanics (recommendation): use a merge commit, not a squash. A squash
would make every later PR in the stack show the earlier diffs again. After
each merge, run `gh pr edit <next> --base main` *before* the merged branch
is deleted, so GitHub does not close the dependent PR. Close #6 and #8 as
"superseded by #35" after #35 merges (Konrad's call).

Suggested grouping for live rollout: merge the whole stack, then do **one**
ovh jobroute park pinned to `main` at the #52 merge, with 148f905 as the
rollback target. Do not do one park per route PR. Then cut one app release
that carries the Swift and skill changes. Install the route before the app
release (see #39).

## Per-PR checklist

Format: PR · branch · head · base, then what it changes, tests, cross-review,
risks/follow-ups, deploy/pin impact, rollback.

### #35 · `feat/swapjobs1` · `148f905` · base `main`
- **Change:** opt-in bot job commands through jobroute (launch, review, status,
  reports, approvals, Mac submit/queue), an offline reversible hb migration
  path (`ops/swap-migrate`, `hb-move`), and coding skill 1.3.16 with
  `scripts/job-route`. +6222/-99.
- **Tests:** Mac Swift/AgentAppTests full **1,862 passed / 4 skipped / 0
  unexpected** (20 known issues are intentional guard probes). Mac updater
  (Python 3.9.6) **254 / 4 skipped**. OVH updater **255 / 3 skipped**.
  hb-pilot offline **40/40**. Historical at `6bc14f4`: route/installer/
  isolation/migration 397 passed / 4 skipped; SSH 17/17; rollback 74 checks;
  pysuites 7/7; simulation 733 passed / 31 skipped. Apart from the jobroute
  sandbox suite (next line), none of these was rerun at the head.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **305 passed**, SSH **17/17**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** Claude reviewer PASS on macgreen1 (Codex-authored). An
  earlier swapjobs1-fix2 review was CONCERNS; macgreen1 is the latest pass.
- **Risks / follow-ups:** coordinate with #6/#8 (see the summary). The hb-pilot
  park still has 24 maintenance placeholders, independent trust and
  installation evidence, and a reseal to do, and it waits on Konrad's BOT_HOST
  answer. Real uid separation, OAuth, Cloudflare/nginx, wakes, routine
  enabling, S1 MCP registration and Mac worker activation are later pilot work.
- **Deploy / pin:** jobroute **148f905 is already live on ovh**, so merging
  only lines `main` up with live. Submissions stay disabled, because the live
  config lacks both `submissions_enabled` opt-ins. Coding skill 1.3.16 (main
  has 1.3.15) ships with the next app bundle. Mac worker not installed.
- **Rollback:** `git revert -m 1 <merge>` on main. Live route:
  `bash ~/work/Swarmhub/jobroute-install-148f905.sh rollback` then
  `… verify-old` (back to f816454). That is a live change, so it needs a park.

### #36 · `feat/backlog1-launch-recovery` · `0dcdb15` · base `feat/swapjobs1`
- **Change:** when sb-codejob exits nonzero or a receipt is missing or bad,
  the job reservation is kept and recovered, not dropped. A detached job that
  is still running no longer disappears from status and capacity.
- **Tests:** `run-sandbox.sh` **355 passed, 0 failed/skipped**, SSH **17/17**;
  50 new cases; the old runtime reproduced 25 failures.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **355 passed**, SSH **17/17**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** Claude reviewer PASS (Codex-authored).
- **Risks:** recovery still matches on label/argv/workdir/time window, which
  is not exactly-once. Historical `failed` rows are not rewritten. Adds
  `backlog1-report.md` at the repo root (see "Stale root files").
- **Deploy:** route runtime (`jobroute_core.py`, `jobroute_jobs.py`); needs
  the ovh jobroute park. Nothing on the Mac.
- **Rollback:** revert the merge; live: reinstall the previous route release.

### #37 · `feat/backlog2-request-ids` · `3df7822` · base `feat/backlog1-launch-recovery`
- **Change:** optional profile-scoped `request_id` on submit/launch (CLI and
  MCP). A retry after a lost response returns the stored job instead of
  starting a second one.
- **Tests:** `run-sandbox.sh` **456 passed**, SSH **23/23**; 101 new tests.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **456 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** Claude reviewer PASS (Codex-authored).
- **Risks:** bindings have no TTL, and retry safety lasts only while the
  ledger is kept, so this is not exactly-once. Clients must persist the ID.
  Adds `backlog2-report.md` at the repo root.
- **Deploy:** route runtime plus `sandbox_ssh.sh`; ovh jobroute park.
- **Rollback:** revert; live: reinstall the previous route release. Not
  checked: how an older route treats a caller that still sends `request_id`.
  Test that before a live rollback.

### #38 · `feat/backlog3-completion-evidence` · `17a49c5` · base `feat/backlog2-request-ids`
- **Change:** status adds `outcome` (`success`/`failure`/`missing_report`/
  `unknown`), `signal`, `review_verdict` and `artifacts`. `state` is unchanged.
- **Tests:** new test file 41 tests; `run-sandbox.sh` **497 passed**, SSH
  **23/23**; Tests/Updater **255 passed / 3 skipped**.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **497 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** a present report is not a fresh or correct report. Only `launch`
  jobs can become `missing_report`. No Swift reads `outcome`.
- **Deploy:** route runtime; ovh jobroute park. **Must be live before the
  app release that carries #39.**
- **Rollback:** coordinate rollback of the #39 skill before rolling the route below #38. The newer skill requires `outcome: success`; it has no `state` fallback, and `state: done` does not establish success.

### #39 · `feat/backlog4-skill-outcome` · `58e7ce9` · base `feat/backlog3-completion-evidence`
- **Change:** coding skill text: a job counts as finished only on
  `outcome: success`. Includes the 15 re-rendered SKILL.md goldens. Version
  stays 1.3.16.
- **Tests:** Mac (Swift 6.4, unsigned) golden write and re-check; **47 Swift
  tests passed** (CodingSkill, RenderGolden, SkillLibrary, StagedInstall);
  `test_render.py` 17 OK. Linux: Updater exit 0 (3 skipped); sim skill/phrase
  44 and 166 (3 skipped); SwapJobs + hb_move 59. `test_release_build.py` had 1
  failure (the 1.3.15 pin), which already existed at the base and is fixed by
  #43.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **497 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** this is skill text and the code does not enforce it. A route
  without #38 returns no `outcome`, so bots never see "finished". That fails
  safe, but reporting stalls.
- **Deploy:** app bundle (skill). Install the route with #38 first.
- **Rollback:** revert (text and goldens together).

### #40 · `feat/backlog5-mac-queue-tests` · `5da2b91` · base `feat/backlog4-skill-outcome`
- **Change:** hermetic tests that run `mac-worker.py` against a fixture
  single-queue `sb-macjob`. **Also a runtime fix:** a signal-killed runner now
  exits 128+n, not 256−n.
- **Tests:** `run-sandbox.sh` **512 passed**, SSH **23/23**.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **512 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** the fixture is a model of sb-macjob, not the real one. Real ssh
  is not covered. Any caller that compared 256−n codes changes behaviour
  (none found in the repo).
- **Deploy:** `mac-worker.py` changes; ovh jobroute park (and later Mac
  worker activation).
- **Rollback:** revert.

### #41 · `feat/backlog6-steer-overflow` · `777a98f` · base `feat/backlog5-mac-queue-tests`
- **Change:** tests only: 4 composed Swift scenarios (install retry, steer,
  overflow, turn limit, setup sessions).
- **Tests:** MacBook unsigned filtered run **85 passed**; ComposedScenario
  passed 5 more runs in a row; mutation checks caught. Linux sim 764 with 1
  environment-only error (`test_fixes18` scratch, which passes when writable)
  and 30 skipped.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **512 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** stub fidelity only (no real Hermes timing). The real 2 s / 8 s
  backoff is not exercised.
- **Deploy:** none.
- **Rollback:** revert.

### #42 · `feat/backlog7-history-note` · `8211ddb` · base `feat/backlog6-steer-overflow`
- **Change:** app: reconcile and restart notes are tagged and kept out of
  model-bound `chatHistory` (they reached the legacy completions path).
- **Tests:** MacBook unsigned filtered **82/82**; mutation: all 3 new checks
  fail without the filter.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **512 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** untagged older rows are matched by text. **No check against a
  real legacy gateway**; the proof is an in-process server.
- **Deploy:** next signed app release.
- **Rollback:** revert. Old builds would send the notes to the model again.

### #43 · `feat/backlog8-bundle-pin` · `dde8321` · base `feat/backlog7-history-note`
- **Change:** swarmhub-manager now requires swarmhub-coding **1.3.16**
  (was 1.3.15). pysuites gains a `release.log` suite.
- **Tests:** `pysuites-test.sh` **9/9**; release suite **119 OK** (the pin
  test failed before the fix, and a mutation is caught); updater **258 OK**;
  sim 764 (1 `test_gaps` flake on the first run, OK on the second).
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **512 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** if coding 1.3.16 fails to apply, the manager is now held back
  too. Some `scripts/test_*.py` were unrun until #44.
- **Deploy / pin:** **manager install requires coding 1.3.16** (same bundle).
- **Rollback:** revert. The release test fails again until the pin and
  version agree.

### #44 · `feat/backlog9-unrun-tests` · `6de7377` · base `feat/backlog8-bundle-pin`
- **Change:** pysuites also runs Tests/Isolation, Tests/Ops and
  `scripts/test_*.py`. Fixes the `test_gaps` P01_P04 flake.
- **Tests:** `pysuites-test.sh` **16/16**; flake 7/24 before, **0/48** after.
  Outside pysuites: SwapJobs 38, jobroute 512 + 23 SSH, ios boundary OK in
  the worktree.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **512 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** `ops.log` needs nginx on the host (red without it).
  `scripts.log` runs 24 files in one process. jobroute, SwapJobs and
  `test_ios_approval_boundary` are still manual.
- **Deploy:** none (tests).
- **Rollback:** revert.

### #45 · `feat/backlog10-system-row-filter` · `8fedc4e` · base `feat/backlog9-unrun-tests`
- **Change:** app: manager notices, the "gave up" line, review cards and bot
  cards stay out of model-bound history (approved by Jarvis).
  Approved/Declined and stop lines stay in.
- **Tests:** MacBook full **1,882 passed in 43 suites** at `8fedc4e` (20
  pre-existing known issues); new tests ×3 12/12; 6 mutations caught. pysuites
  at `3c634b5` exit 0 (updater 258, sim 764, release 119, isolation 58, ops 26,
  scripts 548).
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **512 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** legacy templates are deliberately loose; the worst case is an
  extra app line left out of history. **No check against a real legacy
  gateway.**
- **Deploy:** next signed app release.
- **Rollback:** revert.

### #46 · `feat/backlog11-remaining-system-rows` · `5144aed` · base `feat/backlog10-system-row-filter`
- **Change:** app: the model-policy note and the compacted note (which
  reached the model) and orphaned "Waiting" lines are also dropped from
  history.
- **Tests:** MacBook full **1,892 passed** at `5144aed`; new tests ×3 pass;
  8 mutations caught. pysuites exit 0 (updater 258, sim 764, release 119,
  isolation 58, ops 26, scripts 548).
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **512 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** the `modelNotApplied` template is loose. Group "skipped" lines
  are not tagged, which matters only if group history ever goes through
  `chatHistory`. **No check against a real legacy gateway.**
- **Deploy:** next signed app release.
- **Rollback:** revert.

### #47 · `feat/backlog12-mac-job-limit` · `4ec236a` · base `feat/backlog11-remaining-system-rows`
- **Change:** `mac-worker.py` bounds the total Mac call, including queue wait, at 6 h (not a separate 4 h runtime). At the
  deadline it sends TERM, then KILL after 120 s, and exits 124. The queue
  snapshot is capped at 60 s.
- **Tests:** `run-sandbox.sh` **517 passed**, SSH **23/23**; 7 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **517 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** **not proven on a Mac.** TERM handling was read from ovh's copy
  of `sb-macjob`. The fix-round supervisor must be verified against the installed runner’s lock/session contract. 6 h is a policy
  choice.
- **Deploy:** jobroute mac-worker; **ovh jobroute park** (jobroute 148f905 is
  live) and later Mac worker activation.
- **Rollback:** revert; live: reinstall the previous route release.

### #48 · `feat/backlog13-mac-failure-cause` · `dcdfc78` · base `feat/backlog12-mac-job-limit`
- **Change:** failed macjobs get a `cause` (`mac_connection_failed` for ssh
  255, `timed_out` for 124). `queue` says "Mac host unreachable; retry later".
  `mac-dispatch` reports signal kills as 128+n.
- **Tests:** `run-sandbox.sh` **532 passed**, SSH **23/23**; new file 15/15 ×5;
  7 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **532 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** real OpenSSH 255 and the Mac's `sb-macjob` were not exercised.
  Exit 75 (queue wait expired) has no cause. The skill does not read `cause`
  yet (needs a bundle bump past 1.3.16 and a re-render). The `queue` route
  timeout equals the worker's 60 s, and an uncaught `TimeoutExpired` on the
  CLI path predates this PR. Both are fixed by #50. The 124 queue text is
  #51, and the orphan ssh child on a route timeout is #52. Exit 75 still has
  no cause (see #51).
- **Deploy:** jobroute, mac-worker and mac-dispatch; **ovh jobroute park**.
- **Rollback:** revert; live: reinstall the previous route release.

### #49 · `feat/backlog14-merge-readiness` · `1b8040a` · base `feat/backlog13-mac-failure-cause`
- **Change:** docs only. Adds this checklist
  (`docs/releases/stack-merge-readiness.md`) for #35 to #48.
- **Tests:** none of its own. No code changed, so the suite matches #48's.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **532 passed**, SSH **23/23**, exit 0.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** its "none rerun" statements were stale. This update (mergeprep)
  replaces them.
- **Deploy:** none.
- **Rollback:** revert.

### #50 · `feat/backlog15-queue-timeout` · `a9836c4` · base `feat/backlog14-merge-readiness`
- **Change:** `backend()` turns `subprocess.TimeoutExpired` into the fixed
  refusal "backend timed out; its outcome is unknown" (audited `refused`).
  The `queue` call gets `QUEUE_TIMEOUT` = 105 s (60 worker limit + 30 ssh +
  15 slack). `park`, `msg` and `report-jarvis` keep 60 s.
- **Tests:** new `test_queue_timeout.py` (6 tests, 5× stable);
  `run-sandbox.sh` **538 passed**, SSH **23 PASS**, run twice by the job;
  3 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **538 passed**, SSH **23/23**, exit 0.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** a slow Mac can now hold a bot for up to 105 s on `queue`. A
  runner that ignores TERM can still outlast the route timeout. The older
  `test_backend_timeout_is_audited` now covers the generic error path only.
- **Deploy:** route runtime; **ovh jobroute park**.
- **Rollback:** revert; live: reinstall the previous route release.

### #51 · `feat/backlog16-queue-busy-cause` · `c8ddbdc` · base `feat/backlog15-queue-timeout`
- **Change:** a `queue` exit of 124 (the worker's 60 s queue-snapshot limit)
  gives the fixed text "Mac worker timed out waiting for the queue; retry
  later". 255 stays "Mac host unreachable". Documents why exit 75 (sb-macjob
  Busy) can't be told apart without an sb-macjob change. README and
  `docs/swap-jobs-migration.md` are updated.
- **Tests:** new `test_queue_busy_cause.py` (19 cases, 5× stable);
  `run-sandbox.sh` **557 passed**, SSH **23 PASS**; 6 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **557 passed**, SSH **23/23**, exit 0.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** exit 75 still has no cause. The fix needs sb-macjob to use a
  distinct exit code or a status field, which stays in the backlog until
  after the merge. Real OpenSSH 255 is not exercised (the live 255 check
  stays in the backlog).
- **Deploy:** route runtime; **ovh jobroute park**.
- **Rollback:** revert; live: reinstall the previous route release.

### #52 · `feat/backlog17-route-timeout-ssh-child` · `6e55998` · base `feat/backlog16-queue-busy-cause`
- **Change:** `backend()` runs the backend in its own session (`run_group`).
  On timeout or error it sends TERM to the whole group, waits 2 s, sends
  KILL, then reaps. Before this, a route timeout killed `mac-dispatch` but
  left its `ssh` child running (reproduced on c8ddbdc).
- **Tests:** new `test_backend_route_timeout.py` (8 tests); the
  `test_queue_timeout.py` stand-ins now patch `run_group`. `run-sandbox.sh`
  **565 passed**, SSH 0 failures, run twice by the job; 5 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **565 passed**, SSH **23/23**, exit 0.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** the backend no longer shares the route's process group, so a
  group signal sent to the route does not reach it. If the route is
  SIGKILLed mid-call, the backend outlives it (systemd cgroup teardown still
  covers it). A timed-out call can take up to timeout + 2 s.
- **Deploy:** route runtime; **ovh jobroute park**.
- **Rollback:** revert; live: reinstall the previous route release.

## Test reruns (mergeprep, 2026-11-08)

The command at each head was `ops/jobroute/tests/run-sandbox.sh` (pytest plus
`sandbox_ssh.sh`, as `sbtest` under `unshare`). It ran from a `git archive`
export of that head's `ops/jobroute`, one head at a time in stack order,
between 19:23 and 19:59 UTC. Every GitHub `headRefOid` matched the table
first. `run-sandbox.sh` also stages sb-codejob from `~/sb`, which is not
part of any PR. It was `~/sb` @ `83ebf16dd` for every run. pysuites, the
Mac and Swift were not run.

| PR | Branch | Head | pytest | SSH harness | Exit |
|---|---|---|---|---|---|
| #35 | `feat/swapjobs1` | `148f9058826d` | 305 passed | 17/17 | 0 |
| #36 | `feat/backlog1-launch-recovery` | `0dcdb15d383d` | 355 passed | 17/17 | 0 |
| #37 | `feat/backlog2-request-ids` | `3df7822ecdc7` | 456 passed | 23/23 | 0 |
| #38 | `feat/backlog3-completion-evidence` | `17a49c506173` | 497 passed | 23/23 | 0 |
| #39 | `feat/backlog4-skill-outcome` | `58e7ce9727a8` | 497 passed | 23/23 | 0 |
| #40 | `feat/backlog5-mac-queue-tests` | `5da2b919cadd` | 512 passed | 23/23 | 0 |
| #41 | `feat/backlog6-steer-overflow` | `777a98f777a2` | 512 passed | 23/23 | 0 |
| #42 | `feat/backlog7-history-note` | `8211ddbf6666` | 512 passed | 23/23 | 0 |
| #43 | `feat/backlog8-bundle-pin` | `dde832199aa5` | 512 passed | 23/23 | 0 |
| #44 | `feat/backlog9-unrun-tests` | `6de7377b5bf5` | 512 passed | 23/23 | 0 |
| #45 | `feat/backlog10-system-row-filter` | `8fedc4e439b8` | 512 passed | 23/23 | 0 |
| #46 | `feat/backlog11-remaining-system-rows` | `5144aedfcb06` | 512 passed | 23/23 | 0 |
| #47 | `feat/backlog12-mac-job-limit` | `4ec236a4988c` | 517 passed | 23/23 | 0 |
| #48 | `feat/backlog13-mac-failure-cause` | `dcdfc78cf211` | 532 passed | 23/23 | 0 |
| #49 | `feat/backlog14-merge-readiness` | `1b8040af32ac` | 532 passed | 23/23 | 0 |
| #50 | `feat/backlog15-queue-timeout` | `a9836c456afb` | 538 passed | 23/23 | 0 |
| #51 | `feat/backlog16-queue-busy-cause` | `c8ddbdcd7fb4` | 557 passed | 23/23 | 0 |
| #52 | `feat/backlog17-route-timeout-ssh-child` | `6e55998a27eb` | 565 passed | 23/23 | 0 |

No test was skipped or failed at any head. Every count matches the figure
its job reported (#35's 305 is the sandbox suite alone; the 397 in its
history also counted installer, isolation and migration tests).

**Combined tip.** This is a local integration checkout, never pushed: a
detached worktree at `origin/main` 4e9d4de, then
`git merge --no-ff 6e55998a27eb` (the merge was clean), giving local commit
`eabfc9e`. Its tree `339fec35` is byte-identical to #52's tree, so merging the
whole stack into `main` as it stands today produces exactly #52's code.
`run-sandbox.sh` at `eabfc9e`: **565 passed, SSH 23/23, exit 0**
(19:59–20:01 UTC).

Not covered by these reruns: Mac/Swift suites (#35, #39, #41, #42, #45, #46),
pysuites (#43, #44, #45, #46), updater and sim suites. Those figures stay as
the job reported them.

## Deploy and pin impact at a glance

| Area | PRs | Where it lands | How |
|---|---|---|---|
| jobroute route (ovh) | #35 (live), #36, #37, #38, #40, #47, #48, #50, #51, #52 | `~/.local/lib/jobroute` on ovh | one new pinned installer, sb-park, Jarvis sb-approve; rollback to 148f905 |
| Mac worker / dispatch | #40, #47, #48 | ovh route plus the MacBook worker | ovh park; Mac activation is separate, later pilot work |
| Coding skill / bundle | #35 (1.3.16), #39, #43 | app release bundle | manager requires coding 1.3.16; route #38 must be live first |
| App (Swift) | #42, #45, #46 | next signed app release | signed Mac verify owed |
| Tests only | #41, #44 | none | none |
| Docs only | #49 | none | none |

## Rollback notes (stack-wide)

- Revert in **reverse** order (#52 first). Reverting a middle PR alone will
  probably conflict with later PRs that touch the same files
  (`jobroute_*.py`, `mac-worker.py`, `AppOnlyLine.swift`, `pysuites.sh`).
- Code reverts and live rollbacks are separate. A revert on `main` changes
  nothing on ovh. The live route moves only through the pinned installer's
  `rollback` / `verify-old`, which is a live change and needs a park.
- App changes roll back by shipping a new release. Users who already
  installed keep their build until the updater moves them.

## Blocked

- **Codex cross-reviews (hold):** #38 to #52 have had no second-model review.
- **Live Mac run for #47/#48:** one short sb-macjob that TERMs a `sleep` job
  (exit 143, the wake, queue released) and checks real ssh 255 to an
  unreachable alias. Not run. It stays in the backlog until after the stack
  merges, as does the sb-macjob distinct exit-75 change (#51).
- **Signed Mac verify (keychain):** every Mac run was unsigned
  (`--disable-keychain`). The app PRs (#42, #45, #46) and the skill bundle
  need a signed build check before release.
- **No check against a real legacy gateway** for #42, #45 and #46. The proof
  is the in-process `ChatParityServer`.
- Also waiting, outside the merge: hb-pilot park (Konrad's BOT_HOST answer);
  `c554005a8` stays HOLD.

## Stale root files (noted, not moved here)

- `backlog1-report.md`, `backlog2-report.md`: job reports committed to the
  repo root by #36/#37. Candidates for `docs/archive/reports/`.
- `KNOWN-GAPS.md`: one entry, closed by decision on 2026-10-23. The file is
  effectively empty.
- `PLAN.md` (2026-10-23), `CORE-PHASES.md` (2026-10-20), `CORE-PLAN.md`
  (2026-10-29): none mentions the jobroute or swap-jobs work. Check whether
  they are still current before the next release.
