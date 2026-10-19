# FIXES18 — release fixes after REVIEW-CLAUDE-XREV3

Base: `78e73df`, workdir `/home/ubuntu/work/swarmhub/peer-review`. No commit made. Changes are confined to Swarm Hub sources, its bundled skills, tests and this report; Hermes was not changed or run. Existing untracked review/brief files were left intact. Network fixtures remained stubbed; no real outbound sender or coding provider was invoked.

I checked `REVIEW-CLAUDE-XREV3.md` and `/home/ubuntu/work/swarmhub/20261019T221231Z-claude-xrev3.review.txt` against the implementation. The evidence visibility gap, unchecked legacy outbound argv, late scratch trap and missing skill limitation were present. The detailed review numbers the Darwin kill-ordering race **2**, although the request calls it finding 7; its detailed finding 7 concerns Unicode parity. Items below use descriptions to avoid that ambiguity.

## Items completed and deferred, in requested order

1. **Done — evidence mode visibility (finding 5).** `Sources/AgentApp/Models/ChatAutomation.swift:45` supplies one shared display: coding/general, auto/explicit, and whether commit or test-pass plus report evidence is required. Both overrides are named, with the existing clear-then-restart procedure. `Sources/AgentApp/Stores/AppStore+Goals.swift:68` emits a local notice before advancing, including when offline; `:81` includes the same text in `/goal status`. Local command lines are excluded from model history (`Sources/AgentApp/Stores/AppStore+Turns.swift:206`). No stored schema or completion requirement changed.

   `sim/goal_run.py:17` is the text-only Python port of the same parsing, mode, start notice and status; it uses the existing classifier. `Tests/AgentAppTests/GoalTests.swift:31` adds native assertions for both automatic modes and both overrides, offline start, status and JSON restoration; `:60` checks an online start. `sim/test_fixes18.py:27` has **3 passing tests**, including those same four expectations and legacy/offline status. Swift was inspected, not executed.

2. **Done — legacy outbound execution (finding 1).** `Resources/Skills/swarmhub-messages/scripts/swarm_jobs.py:129` recomposes the outbound command from the current owner-configured sender plus exact stored recipient/text immediately before `Popen`. Execution requires full argv equality. Missing/invalid draft fields, missing sender or any mismatch mark the running record failed with a fixed, non-sensitive error. A changed sender requires resubmission and approval; the implementation does not silently replace an approved command. Existing FAKE and active/status guards still precede execution. Invalid process arguments also fail the record (`:151`). No migration or rewriting of fingerprints/approved specs was needed.

   **8 passing tests** at `sim/test_fixes18.py:64` insert pre-upgrade awaiting records directly into SQLite, approve them, and exercise execution. They cover arbitrary shell argv, recipient/text mismatch, malformed draft, changed/missing policy sender, exact binding and legacy FAKE. Even the successful binding uses a `Popen` spy, never an outbound executable. This closes the managed execution path; it does not create isolation from another program running as the same Unix account or freeze the bytes of the sender executable.

3. **Deferred — Darwin kill-ordering race (request finding 7 / detailed review finding 2).** `Resources/Skills/swarmhub-coding/scripts/verify_darwin.py:94` remains unchanged: leader wait/reap precedes `killpg`, and group death is not awaited. The suggested `os.waitid(... WNOWAIT)` replacement is not a portable drop-in: [Python 3.12 documents `os.waitid` as unavailable on macOS](https://docs.python.org/3.12/library/os.html#os.waitid). A Darwin-specific wait facility or supervisor needs validation on the supported Mac Python/OS versions, including exit status, interruption, descendant drain and PID reuse. Adding that without a Mac is beyond a low-risk pre-release change. The escape and race are now explicit skill limits; no claim of complete Darwin teardown is made.

4. **Done with conservative limits — scratch leak (finding 8).** `Resources/Skills/swarmhub-coding/scripts/code-job:101` sweeps on startup, creates a name containing the launcher PID atomically with `mktemp`, and installs EXIT/INT/TERM cleanup immediately after allocation. `Resources/Skills/swarmhub-coding/scripts/scratch.py:12` removes only owned, real directories in that new naming scheme older than 24 hours whose PID probe returns ESRCH. Live/reused PIDs, EPERM/other errors, symlinks, non-directories and old names without a PID stay intact. No age-only deletion of potentially active legacy entries was added. Recovery occurs on a later launch; `/tmp` fallback entries remain subject to system temporary-file cleanup. A dead launcher does not itself establish that every detached descendant has stopped.

   **4 passing tests** at `sim/test_fixes18.py:141` cover retention/removal boundaries and a shell integration probe that exits before the old late trap, then SIGKILLs a launcher and verifies the aged orphan is swept on the next startup. The probe uses a disposable HOME outside `/tmp` and never starts a coding CLI. The helper is included in shell and Python copied-script fixtures (`Tests/Scripts/code-job-test.sh:17`, `sim/test_fixes5.py:151`, `sim/live_cli_probe.py:46`); the live probe was not run.

5. **Done — docs and skill versions.** `Resources/Skills/swarmhub-coding/SKILL.md:100` now documents the Darwin `setsid()`/`setpgid()` cleanup escape, the reap-before-kill race and lack of group-drain acknowledgement. The descendant-reap claim at `:104` is explicitly Linux-only. Scratch limits are at `:111`. Runtime outbound revalidation is documented in `Resources/Skills/swarmhub-messages/SKILL.md:121`. Both changed skills are **1.3.9**, up from 1.3.8 (`SKILL.md:4` in each); Swift version, file-list, installation and update-banner expectations were updated in `Tests/AgentAppTests/CodingSkillTests.swift:30` and `BotMessageSkillTests.swift:11`. The **2 skill-version tests** in `sim/test_fixes8_skills.py:29` pass.

6. **Intentionally unchanged — classifier (FIXES17 decision).** `sim/goal_classifier.py` has no diff. The Swift `GoalProtocol` implementation and word lists are byte-identical to HEAD; only the enclosing `GoalRun` gained a display property. The existing 327-phrase shared table still passes. No heuristic patch, new classifier corpus or claim of Unicode parity was added. General-mode completion remains a bot claim, not independent verification.

## Validation

Commands run before and after implementation:

```sh
PYTHONPATH=sim python3 -B -m unittest discover -s sim
/bin/sh Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job
```

| Check | Before | After |
| --- | --- | --- |
| Full Python discovery | 345 tests; 8 failure records, 8 skipped | 360 tests; same 8 failure records, 8 skipped |
| Code-job shell suite, `/bin/sh` | 22 passed, 0 failed | 22 passed, 0 failed |
| New fixes18 tests | absent | 15 passed |
| Focused fixes18 + skill-version tests | not applicable | 17 passed |

The baseline was **not green**. Its eight failure records span five test methods (four failing subtests in the last method):

- `test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`: fallback mode denies a new top-level `build` directory.
- `test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work`: Node child-process completion reports `EPERM`.
- `test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`: expects `namespaced`, receives `fallback`.
- `test_fixes8.LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process`: local socket send returns `EPERM`.
- `test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode`: four variants require a namespace unavailable here.

The final run has the same failure names, four subtest variants and failure reasons as baseline; all 15 added tests pass. Discovery exits 1 before and after. This is a verified absence of new failures in this environment, not a full-suite green claim or proof that the existing verifier failures are harmless on other hosts.

Baseline results were captured in tool output. Final discovery log: `/tmp/fixes18-python-after.log`; shell logs: `/tmp/fixes18-shell-before.log`, `/tmp/fixes18-shell-after.log`. No tests were skipped or weakened to make these results green. Shell syntax and `git diff --check` pass. Swift compilation, native Seatbelt, APFS behavior and real Codex enforcement remain unverified on this Linux host.

## Commands for the Mac

From the matching checkout with Swift 6 and the macOS SDK:

```sh
swift build
swift test --filter goalEvidenceModeIsVisibleAtStartAndInStatus
swift test --filter plainGoalsAreClassifiedByTheRequestedAction
swift test
PYTHONPATH=sim python3 -B -m unittest discover -s sim
/bin/sh Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job
```

Also inspect plain coding/general goals and both explicit overrides in the app: the start notice and `/goal status` must agree, including after restart and offline start. Confirm 1.3.8 installations offer updates for both skills and that the coding skill installs `scripts/scratch.py`.

## Mac real-Codex `/tmp` exclusion smoke test (finding 3; not run here)

Use a disposable workspace/account with an already configured real Codex; record macOS, Python, `codex --version`, exact argv and tool transcripts. Use harmless files only, no outbound action or network tool requests. The provider call for this future acceptance check is separate from the fully stubbed tests above.

1. Create a workspace-writable positive-control file and host-owned synthetic `git-trust.json` sentinels with recorded hashes outside the workspace: under `/tmp/code-job.<random>/` and a distinct `$TMPDIR` (including a macOS-style symlink alias). Resolve the physical paths; `/tmp` may be `/private/tmp`. Ensure neither outside location is also granted by `--add-dir`, configuration or a workspace ancestor.
2. Run **the real installed Codex**, not the argv-recording stub, with the launcher's settings (`Resources/Skills/swarmhub-coding/scripts/code-job:315`):

   ```sh
   # Run in the disposable workspace; substitute the supported model and explicit probe paths in the prompt.
   codex exec --skip-git-repo-check \
     -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"' \
     -c sandbox_workspace_write.exclude_slash_tmp=true \
     -c sandbox_workspace_write.exclude_tmpdir_env_var=true \
     --model <supported-model> '<explicit local file-write probe instructions>'
   ```

3. Require actual shell-tool attempts: write the workspace control, attempt new markers beside each sentinel, and attempt overwrite/rename of each sentinel through both aliased and canonical paths. A refusal in model prose, a tool never called, missing login, startup failure, or failure to write the positive control is **inconclusive**, not a pass. From the host, assert the positive control exists, outside markers are absent and sentinel hashes are unchanged. Preserve the denied-operation tool results; the model's summary is not the oracle.
4. In disposable paths, repeat with exclusions off as a control that the attempted writes can otherwise succeed; then with each exclusion individually to establish which temporary root it protects. Do not perform this control against a real job's evidence or production files.
5. Exercise the actual code-job fallback in a disposable HOME-scoped workspace: confirm scratch moves out of that workspace to system `/tmp`, both exclusion keys reach Codex, and it cannot alter the launcher snapshot. Also check the ordinary non-HOME workspace path, where scratch stays outside the granted roots. Keep the verification command local and harmless.
6. Any unexpected writable sentinel blocks a claim of enforced evidence isolation; unknown/ignored settings are not success. Record and qualify the tested Codex version before pinning a minimum supported version. No minimum is invented from a stub-only test. This probe does not resolve the separate Darwin descendant cleanup limits or make Claude's host-shell route sandboxed.
