# Fixes9 — verification isolation and approval recovery

Branch `swarmhub/peer-delivery`, base/unchanged HEAD `32f408e`, 2026-10-19. No commit was made.
Read `FIXES8-REPORT.md`, `REMOTE-APPROVALS-REPORT.md`, both supplied reviewer notes, and the Mac findings in the
request. Changes are confined to the Swarm Hub app, its bundled skills/scripts, and its tests. Hermes is unchanged.
Tests use temporary repositories, synthetic identities/keys, stub executables and fake outbound operations; no live
Hermes, provider or external service was contacted. The two pre-existing untracked brief files are unchanged.

## 1. Limited-mode non-signal process isolation

`Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py:219` registers the additional notifications;
`:276` resolves their syscall numbers for the supervisor. The new `verify_processes.py:37` implements self-only
PID checks. It compares the kernel's signed low 32 bits, including attempts with junk in the upper register bits.
Only scalar self targets are continued; another process's numeric PID is never checked and then continued.

| Call | Limited-mode rule |
|---|---|
| `prlimit64` | PID 0, caller TID or its TGID only; foreign queries and limit changes refused |
| `setpriority`, `getpriority` | `PRIO_PROCESS` self only; all `PRIO_PGRP`/`PRIO_USER` requests refused, including `who=0` |
| `sched_setaffinity`, `sched_setscheduler`, `sched_setparam`, `sched_setattr` | Self only |
| `ioprio_set` | `IOPRIO_WHO_PROCESS` self only; group/user scopes refused |
| `kcmp` | Both PIDs must identify the caller's process/threads |
| `move_pages`, `migrate_pages` | Self only |
| `get_robust_list` | Also restricted to self, closing another process-inspection path |
| `process_madvise` | Self pidfd, subject to the kernel's normal capability checks |

Each child inherits the policy and can operate on itself. Existing own-tree signal delivery is retained.

`verify_processes.py:58`, called at `verify-sandbox.py:435`, discards inherited descriptors before launcher IPC is
created, and replaces anonymous handles/sockets masquerading as stdio with `/dev/null`. This prevents a host pidfd
from entering the sandbox. Ordinary files, pipes and devices remain usable as stdio.

`verify_signals.py:190` now brokers `pidfd_open` for the own tree. It opens the descriptor, checks ancestry, and
transfers that exact descriptor with `SECCOMP_IOCTL_NOTIF_ADDFD | SECCOMP_ADDFD_FLAG_SEND`, atomically answering the
request. It does not continue a numeric PID lookup. This is needed because Python asyncio selects its pidfd child
watcher once a self pidfd is available. Host pidfds are refused; `pidfd_send_signal` and `pidfd_getfd` remain denied.
The pidfd acquisition restriction, closed inherited handles, and existing socket/proc restrictions mean a concurrent
fd replacement during a `process_madvise` check cannot introduce a host-process pidfd.

The additional notifications exposed an existing cancellation race. `verify_signals.py:255` now retries after
`SECCOMP_IOCTL_NOTIF_RECV` returns ENOENT for an exited requesting child. Previously that result incorrectly ended
supervision and killed the remaining verifier tree. The root pidfd continues to determine teardown.

Tests in `sim/test_fixes9_processes.py:108`:

- Thirteen individual syscall tests: each reaches the real syscall against an external helper, an in-tree parent/PID 1
  where applicable, and self. Priority tests include process/group/user variants; scalar tests include upper bits.
- Each self result is compared with the same unsandboxed control, and the policy's self CONTINUE path is checked
  independently. All self probes succeed here except valid `process_madvise`, which returns EPERM both outside and
  inside the verifier because the host lacks the required capability. It is not silently skipped or claimed to
  have performed memory advice. `migrate_pages` uses valid same-node masks and succeeds.
- The pidfd test verifies readiness for an actual own child and rejects an inherited foreign pidfd supplied as
  stdin. The cancellation-race test checks ENOENT/EINTR without ending supervision. Three policy tests cover the
  cancellation race, scalar widths/scopes and both kcmp targets.
- The child-pidfd regression passed 30 consecutive runs after the race fix.
- Negative control: running the new thirteen syscall tests against the archived original scripts fails all thirteen
  (missing foreign-target restrictions or the old blanket self-pidfd/kcmp denial). This is not a claim that every
  original syscall could mutate a host process; some original calls were already denied.
- `sim/test_fixes7.py:73` and `sim/test_fixes8.py` retain foreign pidfd denials and update the old self-denial
  expectation to the new safe self-pidfd behavior.

## 2. Joined coding imperatives in /goal

`Sources/AgentApp/Models/ChatAutomation.swift:176` tracks a descriptive request and recognizes a subsequent
`and`, `then`, or `and then` as an imperative boundary. This also applies to polite `can/could you explain...`
requests. Existing how/why-question behavior is preserved. `sim/goal_classifier.py:80` mirrors the control flow;
its word lists still come from the Swift source.

`Tests/AgentAppTests/GoalTests.swift:281` adds the two reported phrases and four similar requests, including
“Describe the parser and then refactor it” and “Could you describe the failure and add a test?”. The Python port
runs the complete Swift table: **27 coding + 17 general phrases**, with all previous cases preserved. Its six tests
pass. Swift macros remain unnested.

## 3. Darwin toolchain startup and linked worktrees

The Seatbelt profile was extracted into `Resources/Skills/swarmhub-coding/scripts/verify_darwin.py:14` to keep the
launcher below 500 lines. `verify-sandbox.py:427` supplies the repository metadata paths.

- `verify_darwin.py:27` adds exact read-only grants for `/Library/Preferences/com.apple.dt.Xcode.plist`,
  `/Library/Preferences/com.apple.dt.CommandLineTools.plist` and `/private/var/db/xcode_select_link`, plus read/execute
  access to the resolved selected Developer directory and metadata-only access to exact ancestors. The environment
  remains scrubbed. No preferences daemon, broad Preferences directory, user home or secret directory is granted.
- `verify_darwin.py:37` grants reads to linked-worktree gitdir/commondir paths outside the workspace. The original
  profile denied writes to these paths but omitted their read grants, explaining the supplied git exit 128.
  The final explicit write denials remain in place. `verify-sandbox.py:90` canonicalizes absolute as well as relative
  gitdir paths, accounting for macOS `/var` and `/tmp` aliases.
- Deny-default, no network, the existing Mach-service allowlist and `.git` write protection remain intact.

`sim/test_fixes9_darwin.py:17` has three passing profile tests: exact license grants, selected developer-directory
scope, and linked gitdir reads/ancestor metadata/write denials. Its two native tests (`:61`) require the real Mac:
`/usr/bin/python3` must print its probe marker, git must actually complete in a linked worktree, and attempted
metadata writes/host-secret reads must reach Python and get EACCES/EPERM. Exit 69 or a failed interpreter import
cannot count as a successful security denial.

`sim/test_fixes6.py:59` now rejects license/startup failures in negative assertions, and its native Mach denial test
checks output from the actual service probe. `sim/test_fixes5.py:141` now copies all verifier helpers and requires
an in-workspace marker written by each actual shell/Python attack probe. It previously passed on a missing helper
import. This test explicitly selects limited mode on Linux and passes; macOS still uses Seatbelt.

**Native Mac resolution is not yet verified.** The license-file diagnosis follows the supplied evidence; this Linux
host cannot prove the Xcode shim needs no additional exact path. No broad grant or unsandboxed fallback was added.

## 4. Remote approval cards and durable receipts

### (a) Unsent choices and stale cards

`Sources/AgentApp/Stores/AppStore+ManagedActions.swift:52` no longer persists a choice when the button is clicked.
It first validates the connection and queries the runtime, and records the choice immediately before dispatch
(`:90`). An offline lookup therefore leaves the choice unset, including after serialization/restart, and the user
can choose Decline instead. Persisted pending requests still get a query-only recovery pass.

`Sources/AgentApp/Models/ManagedRemoteControl.swift:25` distinguishes failures before transport dispatch with
`ManagedControlError.unsent` (`ManagedControl.swift:121`). On that explicit result, the store restores the prior
choice (`AppStore+ManagedActions.swift:113`): a newly unsent choice unlocks, but an earlier uncertain decision stays
locked. Errors after dispatch, including lost replies, preserve the choice and require receipt reconciliation.
Previously persisted choices without proof of non-dispatch are treated conservatively as uncertain.

`swarm_remote.py:83` signs explicit `gone`/`superseded` lookup responses for missing operations, obsolete pending
roles, and non-pending operations without a remote receipt. These responses bind the request digest, expiry, task,
origin and runtime. They do not authorize anything. `ManagedRemoteControl.swift:104` verifies them only after the
normal signature/request/expiry checks. `AppStore+ManagedActions.swift:100` removes a card only when the task,
origin and runtime match the reviewed binding, and records an audit note stating retirement and that no decision
was confirmed. A changed runtime or unauthenticated response retains the card.

Four new Swift tests in `Tests/AgentAppTests/ManagedRemoteControlTests.swift`:

- `offlineLookupDoesNotLockChoiceAcrossRestart` (`:158`)
- `provenUnsentDecisionUnlocksOnlyANewChoice` (`:186`)
- `decisionPreflightFailureIsExplicitlyUnsent` (`:217`)
- `signedRetirementRemovesOnlyTheBoundRuntimeCardAndAudits` (`:230`, both reasons and mismatched runtimes)

These use injected closures/URLProtocol stubs, synthetic keys and fake outbound specs. Existing lost-ACK/restart,
conflicting-choice, signature, expiry and mismatched-operation tests remain.

### (b) Receipts survive deciding-profile changes

`Resources/Skills/swarmhub-messages/scripts/swarm_remote.py:125` separates the current policy's decider from the
receipt's recorded binding. Existing receipt lookups authenticate/validate against the saved profile, origin and
runtime, retaining fingerprint/spec/gate checks. New decisions (`:151`) still require the current profile.

`sim/test_fixes9_approvals.py:39` saves both approve and deny receipts, rotates the owner, restarts the service and
retrieves the identical receipts as their original profile. It rejects old-profile decisions and verifies that a
new pending operation requires the new profile. `:62` tests authenticated retirement responses without decisions.

### (c) Cancellation markers follow commit

`swarm_policy.py:352` now writes cancellation intent into a transactional `cancellation_markers` outbox alongside
the cancelled action/delivery states. `swarm_store.py:77` creates the table; `:93` commits first, then `:98` emits the
marker files and clears successful outbox rows. Local stop and remote denial share this path. A write failure or
crash leaves durable rows for retry on the next successful database access; the committed action status already
blocks managed work. A rolled-back transaction has no filesystem cancellation effects.

`sim/test_fixes9_approvals.py:83` checks marker creation through a separate SQLite connection, proving it sees the
committed parent/child statuses and receipt. `:104` causes an actual commit failure with a deferred foreign-key
constraint and verifies rollback of statuses, receipts, nonces, denials and outbox rows, with no markers. `:128`
checks marker-write failure and outbox recovery from the saved receipt; `:141` checks local stop. All six tests pass.

## Packaging and versions

- `Resources/Skills/swarmhub-coding/SKILL.md:4`: **1.3.4 → 1.3.5**.
- `Resources/Skills/swarmhub-messages/SKILL.md:4`: **1.3.6 → 1.3.7**.
- `Tests/AgentAppTests/CodingSkillTests.swift:32`, `BotMessageSkillTests.swift:13` and
  `sim/test_fixes8_skills.py:15` pin the new versions; the update-banner test uses the immediately previous versions.
- Coding packaging assertions, `Tests/Scripts/code-job-test.sh:18`, `sim/live_cli_probe.py:47`, and the isolated
  code-job regression copy both new verifier helpers. No live CLI probe was run.
- Every touched source, test and skill file is under 500 lines (launcher: 463; shell suite: 473). Python AST parsing
  and `git diff --check` pass. No bytecode/cache files exist under `Resources/Skills`.

## Validation and clean-HEAD comparison

Clean baseline: `git archive HEAD` extracted into `/tmp/swarmhub-fixes9-baseline`, with no working-tree edits.
The baseline and changed suites used the same host restrictions and default verifier mode. No failures were
converted to skips or treated as successful security denials.

| Check | Clean `32f408e` | Changed tree |
|---|---|---|
| `python3 -B -m unittest discover -s sim -v` | 227 tests; 25 failure assertions, 3 errors, 4 skips | 255 tests; 25 failure assertions, 2 errors, 6 skips |
| `/bin/sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | 10 passed, 12 failed | 10 passed, 12 failed |
| `CODE_JOB_SH=/bin/dash dash Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | 10 passed, 12 failed | 10 passed, 12 failed |
| Focused regression run, command below | — | 50 tests: 48 passed, 2 native-Mac skips |
| Child-pidfd cancellation regression repeated | — | 30/30 passed |
| New thirteen syscall probes against original scripts | 13 fail as expected | All 13 pass |
| Swift build/tests | Not available | Not available |

The full changed run completed in 102.257 seconds: **228 successful methods, 21 failing/error methods, 6 skips**.
Clean HEAD had **201 successful methods, 22 failing/error methods, 4 skips**. Assertion totals exceed method totals
because several existing tests have failing subtests. All 21 remaining failing/error methods also fail on clean
HEAD; there are **no new failing methods**. The former timeout in
`test_fixes7.LimitedModeSuitesTests.test_forced_fallback_runs_the_pytest_style_module_with_pool_timeout_and_self_signal`
passes now. The two additional skips are the new native-Mac tests. All 26 new Linux-runnable tests pass.

Both final shell logs are byte-for-byte identical to their clean-HEAD logs. The remaining failures involve the
existing default/namespaced verifier failing with EPERM/exit 77, restricted filesystem/socket operations, and coding
jobs consequently returning unverified/66. This is not a green full-suite claim or a claim to have fixed the host's
namespace configuration. The unchanged failing/error methods are:

- `test_fixes5.VerificationTests.test_B1_environment_scrubbed_and_symlink_escape_denied`
- `test_fixes5.VerificationTests.test_B1_outside_write_from_verify_command_is_denied`
- `test_gaps.GapTests.test_P01_P04_done_requires_evidence_and_wake_states_verified_versus_unverified`
- `test_patterns.ObservedPatternTests.test_P01_result_next_step_standing_queue_and_receiver_dedupe`
- `test_patterns.ObservedPatternTests.test_P04_explicit_execution_contract_rejects_empty_missing_and_stale_reports`
- `test_patterns.ObservedPatternTests.test_P05_global_quota_subscriptions_and_job_admission`
- `test_patterns.ObservedPatternTests.test_P07_final_denial_bound_outbound_scope_relaunch_and_peer_stop`
- `test_fixes8.LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process`
- `test_fixes6_policy.CodingGateTests.test_codex_job_waits_for_the_owner_then_runs_after_the_bound_decision`
- `test_fixes6_policy.CodingGateTests.test_direct_code_job_skips_claude_for_approval_and_falls_through`
- `test_patterns.RuntimeEdgeTests.test_failed_queue_holds_later_work_until_cancelled`
- `test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`
- `test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work`
- `test_fixes6_policy.CodingGateTests.test_owner_approved_claude_job_runs_claude_bound_to_its_record`
- `test_live_chains.LiveChainTests.test_p01_actual_relay_review_commit_build_then_bot_selected_submission`
- `test_live_chains.LiveChainTests.test_p04_real_job_boundary_correction_relaunch_check_before_success`
- `test_review_fixes.ReviewFixTests.test_policy_change_after_launch_does_not_fail_the_running_job`
- `test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode`
- `test_patterns.RuntimeEdgeTests.test_slow_completion_acknowledgement_does_not_hold_the_standing_queue`
- `test_fixes5.VerificationTests.test_verifier_runs_builtins_and_workspace_executables_and_preserves_exit`
- `test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`

Focused command (from `sim/`):

```sh
python3 -B -m unittest test_fixes9_processes test_fixes9_approvals test_fixes9_darwin \
  test_fixes8_goal test_fixes8_skills test_remote_approvals test_fixes6.DarwinProfileTextTests \
  test_fixes5.VerificationTests.test_B1_admitted_code_job_cannot_execute_host_verification -v
```

Logs: `/tmp/fixes9-clean-head-python.log`, `/tmp/fixes9-baseline-sh.log`, `/tmp/fixes9-baseline-dash.log`,
`/tmp/fixes9-final-python.log`, `/tmp/fixes9-final-sh.log`, `/tmp/fixes9-final-dash.log`, `/tmp/fixes9-focused.log`,
and `/tmp/fixes9-negative-control.log`. These are local artifacts, not committed files.

## Required real-Mac runs

Run `swift build`, then the full `swift test`. Focused tests to run first:

- `swift test --filter ManagedRemoteControlTests`: the four new tests above and the six existing remote tests,
  especially `lostReceiptPersistsCardAndChoiceThenQueriesWithoutResending` and
  `changedHostRuntimeOrDigestKeepsPendingCard`.
- `plainGoalsAreClassifiedByTheRequestedAction` (44 phrases) and
  `codingLikeGoalsRequireEvidenceUnlessMarkedGeneral`.
- `codingSkillShipsWithItsScript`, `renderedCodingSkillCarriesThisBotsOrder`,
  `installTurnCarriesTheScriptAndTheVariant`, `installRecordsTheVariantFromTheBlock`,
  `installsAtThePreviousSkillVersionsAreOutdated`, `messagesSkillShipsWithItsScript`,
  `renderedMessagesSkillSendsAsThisBot`.
- Existing managed approval/local control regressions, particularly
  `failedOrUnexecutedManagedDecisionsKeepRetryableCards`,
  `staleManagedRecordCannotBeApprovedAndPendingSurvivesPersistence`,
  `realControlGetCardDecideAndReceiptBindTheRuntimeRecord`, and
  `theAppApprovesARealRuntimeRecordThroughSwarmctlAndRemovesTheCardOnItsReceipt`.

On the real MacBook, run `python3 -B -m unittest sim.test_fixes6 sim.test_fixes7 sim.test_fixes9_darwin -v`, then
`python3 -B -m unittest discover -s sim -v` and both shell suites. Confirm the system Python shim actually reaches
its probe, linked-worktree `git status`/`rev-parse` work, and each `.git`, secret, Mach and network denial reaches
its actual probe. The two new native tests are intentionally skipped on Linux. Deployment through the real TLS
proxy/Keychain and a real Mac app restart remains untested; offline protocol/stub tests do not claim that coverage.
