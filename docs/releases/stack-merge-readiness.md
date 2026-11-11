# Merged stack and rollout readiness: #35–#56, #58 and #59

Updated offline on 2026-11-11 against current main `349db4c`. Main now contains
the merged jobroute stack #35–#56 plus #58 (fixround3, `510c5b3`) and iOS fix #59
(`349db4c`). Fixround3 behavior is merged and reviewed. The jobroute Mac worker
stays **disabled** pending its isolated pilot. Deployment observations and older
test/review results below remain dated evidence; no remote checks were run here.

## Current scope and verification limits

| Field | Status / evidence |
|---|---|
| Merged source | Current main contains #35–#56 plus reviewed #58 (`510c5b3`) and iOS #59 (`349db4c`). Local history retains the earlier stack and fix rounds. |
| GitHub heads and bases | Not re-queried. The #35–#52 table records the 2026-11-08 heads/bases; those are historical, not a pending merge queue. |
| Reviews and checks | Fixround3 #58 is merged and reviewed. Earlier PASS/owed/hold entries are dated job reports, not current merge blockers; remote review records were not re-queried. |
| Installed ovh route | **Unverified now**. The 2026-11-08 report observed `current → releases/148f9058…` (#35); the older `jrinst148` report's `f816454` observation preceded it. |
| Submission gates | Source defaults disable submissions globally and per profile. The dated #35 install observation also reported submissions disabled; current live config is **unverified**. |
| hb pilot / Mac activation | No completed pilot is established here. **Keep the Mac worker disabled** pending isolated Mac validation; the ovh installer does not install it on the Mac. |
| Validation at this tip | No full runtime suite rerun in this docs job. Fix round 2b reports **527 passed / 48 failed / 4 skipped**, with environment explanations; neither that result nor the older 565/23 validates current main. Local doc-test selection is recorded in the docsfix2 report. |

### Follow-ups after #52 and fix-round matrix

The local history has no GitHub PR metadata for #53–#55. The following is a
**provisional grouping by local commit sequence**, not verified PR heads/bases.
The #53–#56 grouping below preserves the earlier source record; the whole stack
is now merged. It does not assert individual remote head/base mappings.

| PR scope | Local evidence / candidate boundary | Changes and outstanding verification |
|---|---|---|
| #53 (mapping unverified) | `986c616` (mergeprep, 2026-11-08) | Extends readiness through #52 and records dated reruns. Documentation only; no current GitHub review/head check. |
| #54 (mapping unverified) | `a415ba3` through `e9328ab` (2026-11-10) | #40 bounded fixture collection; #50 queue budget; #49 coordinated skill rollback; #52 monotonic child grace; #45 known-identity legacy matching; #47 workload supervisor. Route, worker and app verification remain separate. |
| #55 (mapping unverified) | `b07e1c5`, `958318d` (2026-11-10) | Fix-round regression fixtures: valid dispatch input and retained workload output. Test changes in the source stack, no tests changed or run by this docs job. |
| #56 (tip user-supplied) | `2983f09` through `7963b72` (fix round 2b, 2026-11-10) | Isolated control state, fresh runner grace, lingering-descendant cleanup, bounded KILL drains/reap, #52 process-inspection fallback, stronger stubborn-runner fixture and docs. Local report identifies base `958318d`; this is historical source evidence, superseded for current cleanup behavior by #58. |
| #58 (merged, reviewed) | `510c5b3` (fixround3) | Child-owned cleanup, independent cancellation, four-hour runtime cap, retained guardian/evidence on incomplete cleanup, exits 125/126, finite inspection/I/O budgets and pinned Mac helpers. Mac deployment stays disabled. |
| #59 (merged) | `349db4c` | iOS Debug builds select the active simulator architecture so SwarmHubCore resolves; signed/native acceptance remains separate. |

The [fix-round report](../archive/reports/fixround2b-report.md) records the full-suite result
as 527 passed, 48 failed and 4 skipped: 11 failures lacked `yaml` in the
invoked system Python; 37 required unavailable `unshare --mount`; four external
sb-copy cases skipped. It also records focused passes (supervisor 7, backend
timeout 12, queue fixtures/timeout 29 and the final stubborn fixture 1).
These are reported results in that environment, not fresh runs or a fully green
suite at this checkout. The 2026-11-08 suite used a different baseline and
sandbox; neither result supersedes the other's conditions.

Current Mac cleanup follows merged fixround3: a six-hour total call cap including
queue wait plus an independent four-hour workload cap. Supervisor-owned cleanup
uses the in-memory, unreaped child identity; invalid disk controls authorize
neither signals nor workspace removal. The cancellation latch requests workload
drain before runner termination. Supervisor settlement plus runner cleanup can
add 265 s. Exit 124 requires confirmed original-group drain and direct-child reap;
125 retains the guardian/evidence for incomplete cleanup or invalid protocol;
126 retains remaining artifacts after removal failure. Persistent `ps` failure
is not proof of drain. These budgets do not guarantee progress through OS or
filesystem stalls. Daemonization/group escape is unsupported; runner crash can
release the queue before cleanup, so crash-safe exclusion is not established.
Queue snapshots have no workload: at most 60 + 130 s inside the unchanged
225 s route budget. See [migration contracts](../swap-jobs-migration.md#command-contracts).

## Historical summary: mergeprep, 2026-11-08

The original report covered 18 PRs, #35–#52, with heads/bases checked then and
all sandbox reruns green (combined tip: 565 passed, SSH 23/23). It recorded no
CI/status checks, Claude PASS reviews on #35–#37, Codex cross-reviews owed on
#38–#52, and #6/#8 as superseded candidates once #35 lands. Those observations
are retained as history; no current GitHub or live conclusion follows.

Sources used by that report: `gh pr view`, backlog1–backlog13 job reports,
`jrinst148-report.md`, job review files and a read-only ovh symlink check.
Those network/live reads were **not repeated** for this documentation job.

## Merge order and gates

The merge gate is complete for #35–#56 plus #58 and #59. Do not replay the old
#35–#56 merge/rebase sequence or independently install #6/#8. Their imported
route is already in the merged stack. The 2026-11-08 checklist below preserves
historical heads and review/test observations for comparison.

Rollout remains separate. Pin a reviewed main SHA, validate its suites in a
suitable environment and keep the logs. Prepare one ovh route park through
sb-park and Jarvis's sb-approve, checking the actual installed release and
rollback target during separately authorized preparation. Coordinate coding
skill `outcome` support with the route before shipping the app bundle (#39).
Use the [current installer/rollback recipe](../../ops/jobroute/README.md#installation-identity-checks-and-rollback).

Keep the Mac worker disabled until the isolated pilot verifies non-reaping
kqueue, ps/flock, corrupt-control cancellation, outer/supervisor signals, parent
death, descendant drain before queue handoff and the installed runner's
lock/escalation behavior. Ship the worker and both pinned helpers together.
No Mac deployment is performed by this docs update.

## Historical #35–#52 per-PR checklist

Heads, branches, bases, reviews and installation observations in this section
are the 2026-11-08 record. Later fix-round amendments are identified in the
matrix above. All these PRs are now merged; old owed/hold entries describe
2026-11-08. Deployment fields remain historical and were not rechecked.

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
- **Deploy / pin:** jobroute **148f905 was observed installed on ovh on 2026-11-08**.
  At that observation submissions were disabled because the config lacked
  both `submissions_enabled` opt-ins. Current installation/gates are unverified. Coding skill
  1.3.16 is now in main; its installed/released version remains unverified. Mac worker not installed.
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
  [`backlog1-report.md`](../archive/reports/backlog1-report.md), now archived.
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
  Added [`backlog2-report.md`](../archive/reports/backlog2-report.md), now archived.
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
- **Change (updated by fixround3):** total Mac call remains 6 h including queue wait;
  the supervisor now independently caps workload runtime at 4 h. Supervisor-owned cleanup
  pins the unreaped child through the last signal. Invalid controls cannot authorize signals
  or workspace removal. The independent cancellation latch drains before runner termination.
  Settlement plus runner cleanup can add 265 s. Unresolved work retains its guardian and
  artifacts, returning 125; artifact-removal failure returns 126. Confirmed cleanup covers
  only cooperating processes in the original group; daemonization/group escape is unsupported.
- **Tests:** `run-sandbox.sh` **517 passed**, SSH **23/23**; 7 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **517 passed**, SSH **23/23**, exit 0. Other figures above are as the
  job reported them and were not rerun.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** **not proven on a Mac.** TERM handling was read from ovh's copy
  of `sb-macjob`. The fix-round supervisor must be verified against the installed runner’s lock/session contract. 6 h is a policy
  choice.
- **Deploy (fixround3):** route runtime needs an **ovh jobroute park**; 148f905
  was observed installed on 2026-11-08, current installation unverified.
  Ship `mac-worker.py`, `mac_worker_state.py` and `mac_worker_lifecycle.py` together.
  **Keep the worker disabled until the isolated Mac pilot above passes.** Runner
  crash can release the queue before cleanup; no crash-safe exclusion claim is made.
  This docs update performs no Mac deployment.
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
  The `queue` call gets `QUEUE_TIMEOUT` = 225 s (60 worker limit + 120 runner grace +
  45 transport/startup allowance, including bounded post-KILL cleanup). `park`, `msg` and `report-jarvis` keep 60 s.
- **Tests:** new `test_queue_timeout.py` (6 tests, 5× stable);
  `run-sandbox.sh` **538 passed**, SSH **23 PASS**, run twice by the job;
  3 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **538 passed**, SSH **23/23**, exit 0.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** a slow Mac can now hold a bot for up to 225 s on `queue`. The
  budget covers the worker limit, runner grace and bounded KILL cleanup. The older
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
- **Fixround3 amendment:** finite input/wait/inspection budgets and non-reaping
  child ownership now gate drain/reap. Unresolved cleanup retains the owned child
  and reports failure, including on `ps` failure; timeout + 2 s alone is not a
  current cleanup bound.
- **Tests:** new `test_backend_route_timeout.py` (8 tests); the
  `test_queue_timeout.py` stand-ins now patch `run_group`. `run-sandbox.sh`
  **565 passed**, SSH 0 failures, run twice by the job; 5 mutations caught.
- **Rerun 2026-11-08 (mergeprep):** `run-sandbox.sh` at the head:
  **565 passed**, SSH **23/23**, exit 0.
- **Cross-review:** **Codex owed (hold).**
- **Risks:** the backend no longer shares the route's process group, so a
  group signal sent to the route does not reach it. If the route is
  SIGKILLed mid-call, the backend outlives it (systemd cgroup teardown still
  covers it). The historical timeout + 2 s estimate is superseded by the fixround3 amendment above.
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

**Historical combined tip (2026-11-08).** The report describes a local integration checkout, never pushed: a
detached worktree at `origin/main` 4e9d4de, then
`git merge --no-ff 6e55998a27eb` (the merge was clean), giving local commit
`eabfc9e`. Its tree `339fec35` is byte-identical to #52's tree, so merging the
then-current #35–#52 stack into that `main` produced #52's code. This does not
represent the later #53–#56 source at `7963b72`.
`run-sandbox.sh` at `eabfc9e`: **565 passed, SSH 23/23, exit 0**
(19:59–20:01 UTC).

Not covered by these reruns: Mac/Swift suites (#35, #39, #41, #42, #45, #46),
pysuites (#43, #44, #45, #46), updater and sim suites. Those figures stay as
the job reported them.

## Deploy and pin impact at a glance

| Area | PRs | Where it lands | How |
|---|---|---|---|
| jobroute route (ovh) | #35–#56 plus #58 | `~/.local/lib/jobroute` on ovh | one new pinned installer, sb-park, Jarvis sb-approve; verify installed SHA and rollback target separately |
| Mac worker / dispatch | #40, #47, #48 plus #58 supervisor/cleanup fixes | ovh route plus separately installed Mac worker and both pinned helpers | ovh park; **keep Mac worker disabled** pending isolated pilot |
| Coding skill / bundle | #35 (1.3.16), #39, #43 | app release bundle | manager requires coding 1.3.16; route #38 must be live first |
| App (Swift) | #42, #45, #46 plus known-identity matching fix | next signed app release | signed Mac verify owed |
| iOS Debug simulator build | #59 (`349db4c`) | generated iOS project/build settings | active simulator architecture fix is merged; native acceptance remains separate |
| Tests only | #41, #44 | none | none |
| Docs only | #49, mergeprep (#53 mapping unverified), fix-round docs | none | none |

## Rollback notes (stack-wide)

- Revert in **reverse** order (latest dependent change first; main includes #58 and #59). Reverting a middle PR alone will
  probably conflict with later PRs that touch the same files
  (`jobroute_*.py`, `mac-worker.py`, `AppOnlyLine.swift`, `pysuites.sh`).
- Code reverts and live rollbacks are separate. A revert on `main` changes
  nothing on ovh. A live rollback needs a park and a reviewed pinned reinstall
  or provenance-aware uninstaller from the [current recipe](../../ops/jobroute/README.md#installation-identity-checks-and-rollback).
  The `rollback` / `verify-old` commands in the historical #35 entry belong to
  that specific parked artifact, not the current generated installer interface.
- App changes roll back by shipping a new release. Users who already
  installed keep their build until the updater moves them.

## Outstanding rollout and acceptance gates

The stack is merged, and fixround3 #58 is reviewed. The old #38–#52 owed/hold
entries are historical, not outstanding merge gates.

- **Isolated Mac pilot:** the fixround3 checklist above is still required before
  enabling the worker. Validate the actual installed runner; Linux fixtures do not
  close Mac acceptance.
- **Live Mac run for #47/#48:** one short sb-macjob that TERMs a `sleep` job
  (exit 143, the wake, queue released) and checks real ssh 255 to an
  unreachable alias. Not run. It remains a rollout gate; the sb-macjob distinct exit-75 change (#51)
  also remains follow-up work after the completed merge.
- **Signed Mac verify (keychain):** every Mac run was unsigned
  (`--disable-keychain`). The app PRs (#42, #45, #46) and the skill bundle
  need a signed build check before release.
- **No check against a real legacy gateway** for #42, #45 and #46. The proof
  is the in-process `ChatParityServer`.
- Also waiting, outside the merge: hb-pilot park (Konrad's BOT_HOST answer);
  `c554005a8` stays HOLD.

## Documentation and accepted limits

The root reports and plans are historical records, not current acceptance.
Their archive locations and open gates are indexed in the
[living roadmap and limits](../ROADMAP-AND-LIMITS.md).
The `KNOWN-GAPS.md` ancestry exception is an accepted **residual limitation**;
acceptance by decision did not fix or remove it.
