# Swarm Hub — Claude cross-review 3 (ae95954..78e73df)

This is a read-only review of the detached worktree at `78e73df`. It covers seven commits:
- 0443a53 fixes12
- c6b1c48 fixes13
- ae2deda fixes14
- a255e70 macfix11
- a62f935 fixes15
- c635e05 fixes16
- 78e73df fixes17

I treated FIXES12–17 and MACFIX11 as claims and checked them against the code. Nothing was modified or committed, and no Hermes, provider or Codex job ran. My only probes were in `/tmp/xrev3-probe`.

## What I ran (Linux, Python 3.12, git 2.43, `/bin/sh` = dash)

- **Targeted Python suites: 155 tests OK, 2 skipped.** Command: `PYTHONPATH=sim python3 -B -m unittest` with these modules:
  - `test_fixes8_goal`, `test_fixes11` … `test_fixes17`
  - `test_remote_approvals`, `test_patterns`, `test_review_fixes`
  - `test_fixes5`, `test_fixes8_skills`, `test_fixes9_darwin`
- **Shell suite:** `/bin/sh Tests/Scripts/code-job-test.sh …/code-job` gave **22 passed, 0 failed**.
- **Classifier probes.** I extracted the Python port together with its Swift word lists at 042997c, ae95954, 0443a53, c6b1c48, ae2deda, a62f935, c635e05 and 78e73df, then compared them:
  - the 7 phrases from XREV2 finding 1;
  - a generated corpus of 1,350 phrases (6 explain starters × 15 subjects × 11 command tails or 4 explanation-only tails);
  - 56 phrases of the form "explanation series + command";
  - about 45 hand-written realistic goals.
- **Not run:** the Swift build and tests (no toolchain here; your MacBook run at 78e73df was green), native Seatbelt, a real Codex CLI, and the full `sim` discovery.
- **Hermes is unchanged.** `git diff --name-only ae95954..78e73df` touches only:
  - `Sources/AgentApp/Models/ChatAutomation.swift`;
  - the swarmhub-coding and swarmhub-messages skills (`SKILL.md` and scripts);
  - Swift tests, `sim/` and the reports.
- **No new real network or outbound path in tests:**
  - the remote handler is driven on in-memory streams against `https://box.example.invalid`;
  - outbound fixtures are FAKE, or owner-gated with a `/bin/true`-style sender;
  - CLIs are stubs.
- **No new secret exposure:**
  - the new `swarm_remote` stderr line (`swarm_remote.py:177`) prints a fixed string, not the exception text;
  - test keys are synthetic `synthetic-*-key` values.

## Status of the REVIEW-CLAUDE-XREV2 findings

**1. Classifier explain-then-fix regression: CLOSED.**
- All 7 XREV2 phrases are now coding, in both the port and the Swift table (`GoalTests.swift:289-295`).
- Clause scope ends at `and`/`then` unless the clause's own verb already coordinated:
  - Swift: `ChatAutomation.swift:296-308`
  - Python: `sim/goal_classifier.py:170-179`
- **Against the fixes12 baseline (0443a53) on my 1,350-phrase corpus,** 78e73df is identical: 36 false negatives and 24 false positives, the same phrases. Fixes13–17 introduced no net regression.
- **Against 042997c (before the overcorrection):** "how to build and test X" is now correctly general, and nothing that was coding there became general.
- **Bypass check:** I found no realistic "explain … and/then fix the <code noun>" phrasing that is general. The remaining misses are vocabulary gaps that predate the range (minor 4).
- **Churn:** two intermediate commits regressed on my corpus and later rounds removed the regressions:
  - ae2deda: 84 false negatives;
  - a62f935: 60 false negatives.

  This is evidence for item 3 below.

**2. Git capture killed bare/submodule jobs: CLOSED.**
- **Capture is conditional.** It runs only with `--verify` (`code-job:248-250`).
- **Unsupported layouts are recorded, not fatal.**
  - `verify-sandbox.py:429-431` records them as `{"unsupported": reason}`, catching `OSError`/`ValueError`, including NUL bytes and non-UTF-8 pointers (`verify_git.py:89-100`).
  - `validated_paths` refuses with that reason (`verify_git.py:103-104`), so the job reports unverified (66) without failing first.
- **Bare `*.git` common directories are admitted** (`verify_git.py:69`).
- **Relative backlinks resolve against `<target>`** and are compared by `(st_dev, st_ino)` (`:72-77`).
- **Bypass check: the relaxation from `== '.git'` to `endswith('.git')` keeps every other barrier.** These still apply:
  - the `objects`/`refs`/`HEAD`/`config` structure and the no-`commondir` check (`:40-47`);
  - target must be `<common>/worktrees/<n>`;
  - both roots outside the workspace (`:62`);
  - the reciprocal backlink must have the identity of this workspace's `.git`;
  - the pre-tool byte and inode pin.

  A relative backlink cannot point anywhere useful, because it must resolve to the workspace's own `.git` inode. The reach is still limited to directories the pre-tool layout already contained.
- **Coverage:** regressions for bare-worktree and submodule jobs with and without `--verify` pass here (`test_fixes12.py:214-241`).

**3. Outbound argv not bound: CLOSED for new records.**
- **The argv is always composed and compared** (`swarm_policy.py:212-217`), FAKE records included.
- **No path keeps a caller argv:**
  - `to`/`text` must be strings if present (`:174-176`);
  - if they are absent, `:221` refuses.
- **Remaining gap:** records already stored before 1.3.8 are not re-bound at execution (minor 1).

**4. Remote handler failure modes: CLOSED.**
- Any handler exception is a 403 (`swarm_remote.py:202`).
- A `wake()` failure after the commit still returns the signed receipt (`:173-177`).
- Both are tested through `do_POST` (`test_fixes12.py:406-421`).

**5. Snapshot in Codex-writable /tmp: CLOSED, but the Codex half is not proven against a real Codex.**
- **The snapshot moved.** `$T` lives in `~/.hermes/swarmhub/scratch` (`code-job:96-109`). Both `$T` and `--dir` are canonicalised with `pwd -P` (`:45,101`).
- **Fallback for HOME-scoped workspaces** (`--dir`, `/tmp` or `$TMPDIR` contains the scratch directory): `$T` goes to `/tmp`, and Codex gets `exclude_slash_tmp` and `exclude_tmpdir_env_var` (`:306-308`).
- **Not proven:** that real Codex honours those keys (minor 3).
- **Unchanged and documented:** Claude Code runs unsandboxed and owner-gated.

**6. Integers outside ±2^53: CLOSED.** `exact_integers` checks the whole spec recursively, and booleans are allowed (`swarm_policy.py:146-163`).

**7. Weak tests: CLOSED for the three cases named.**
- The sendmsg spy fails on `sendall`/`send` (`test_fixes12.py:424-451`).
- The forged pointers are structurally valid, so only the pin refuses them (`:156-173`, and through a real code-job at `:241`).
- The teardown unit tests are unchanged; `test_fixes7` still carries that assurance.

**8. APFS case mismatch on the backlink: CLOSED by the inode comparison** (`verify_git.py:75-77`). Native case-folding is still Mac-only evidence.

**9. No Darwin descendant teardown: PARTIALLY CLOSED (documented).**
- `run_grouped` makes the verifier a session leader and SIGKILLs its group (`verify_darwin.py:94-105`).
- A process that calls `setsid`/`setpgid` escapes. This is stated in the docstring and `SKILL.md:99`, and is acceptable for release.

## Findings

### Blockers

None.

### Major

None.

### Minor

**1. Outbound records stored before 1.3.8 can still execute a caller-supplied argv.**
- **Where:** `swarm_jobs.py:131` runs `spec["argv"]` from the database without re-binding it.
- **Scenario:** an `awaiting-coordinator` outbound record submitted under ≤1.3.7 with `argv:["/bin/sh","-c",…]` survives the upgrade and can be approved, including remotely.
- **Impact:** low. It needs a malicious record that predates the upgrade, and the shared-Unix-account trust limit already exists.
- **Fix:** in `run_action`, for a non-FAKE outbound, refuse unless `argv[-4:] == ["--to", to, "--text", text]` and `argv[:-4]` equals the policy `outbound` hook. Alternatively, a one-time migration can mark pending outbound records `failed` where `argv != outbound_argv(...)`. Add a regression that inserts a legacy row.

**2. Darwin group kill happens after the leader is reaped.**
- **Where:** `verify_darwin.py:100-103`.
- **Problem:** `process.wait()` reaps the leader before `killpg`. If the group is already empty, the pgid could in theory be reused. The kill is also not waited on, so a dying descendant may still write for a few milliseconds after the result.
- **Fix:**
  1. `os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)`;
  2. then `killpg`;
  3. then `process.wait()`;
  4. then poll `killpg(pgid, 0)` until `ESRCH`, with a short deadline.

**3. The Codex `/tmp` exclusion is unverified, and it fails silently if ignored.**
- **Where:** `code-job:306-308`; FIXES12 says no real Codex ran.
- **Scenario:** if a Codex release ignores the unknown `-c sandbox_workspace_write.*` keys, a HOME-workspace job can again rewrite `/tmp/code-job.*/git-trust.json`. The B1 structure checks still hold, so this is defense in depth only.
- **Fix:** add a Mac smoke test with a real Codex. Run `codex exec … -c …exclude_slash_tmp=true 'touch /tmp/probe'` and assert the probe is absent. Pin the minimum Codex version in `SKILL.md`.

**4. Classifier vocabulary gaps that predate the range: coding goals classified general.** These were already wrong at 042997c:
- "Explain why it crashes and fix it"
- "Tell me what broke, then fix it"
- "Investigate why the tests fail and fix them"
- "Find out why the build fails and fix it"
- "Explain why the parsers fail and fix them"

The causes are a missing code noun and a lead verb outside `explainVerbs`.
- **Impact:** such a goal is accepted on a chat deliverable. The done card says "claimed complete by the bot" (`ChatAutomation.swift:52`), so nothing is falsely reported as verified.
- **Fix:** don't add more grammar. Surface the automatic decision so the user can override it (finding 5).

**5. The automatic evidence mode is invisible.**
- **Where:** `startGoal` (`AppStore+Goals.swift:62-65`) and `goalStatus` (`:76-80`) never say whether a plain goal will require coding evidence.
- **Fix:** add one line, `Evidence: coding (auto — /goal --general to change)` or `general (auto — /goal --coding …)`, to the start line and to `/goal status`. A Swift test should assert it.

This turns the documented limits into something the user can see and correct, which is the condition under which I accept them (item 3).

**6. The classifier tests are fitted per round and have no held-out corpus.**
- **Where:** `test_fixes13`–`17` and the GoalTests table (175/152) contain phrases written to fit each round's rule.
- **Evidence:** ae2deda and a62f935 both passed their own tables while regressing on my generated corpus (84 and 60 false negatives against a baseline of 36).
- **Fix:** add a held-out template test to `sim/` and Swift asserting that every "<explain starter> <subject> (and|, then|. Then) fix|add|refactor <code noun>" variant is coding. Treat the 36-miss baseline as a ratchet.

**7. Swift/Python parity is by inspection plus the shared table only.**
- **What is shared:** the Python port reads its word lists from the Swift source (`goal_classifier.py:10-38`). I compared the control flow line by line and found no divergence:
  - `followsDeterminer` bounds;
  - `verbSeriesEnd`;
  - the `reopens` predicate;
  - the newline set, which includes U+0085, U+2028 and U+2029.
- **Known divergence:** Python iterates code points, while Swift uses graphemes (`word_char`, `len(word) > 3`). This only affects decomposed non-ASCII input.
- **Fix:** none required. Note it in the port's docstring.

**8. Scratch directories leak under `~/.hermes/swarmhub/scratch`.**
- **Where:** `code-job:100-109` creates `$T` before the EXIT trap at `:240`. A SIGKILL, or an exit between those lines, leaves `code-job.*` behind. Nothing ever cleans that location, unlike `/tmp`.
- **Fix:** install the cleanup trap right after `mktemp`. Alternatively, prune `scratch/code-job.*` entries older than one day at startup.

## Item 3: are the FIXES17 classifier limits acceptable for release?

**Yes.**
- **It is not a security boundary.** `requiresCodingEvidence` (`ChatAutomation.swift:42`) only decides whether a `done` claim must carry commit, test and report evidence. It grants no execution, sandbox or outbound authority.
- **A false negative cannot claim verification.** It yields an honest "claimed complete by the bot" card.
- **A false positive is caught.** It asks for evidence, and `/goal --general` overrides it (`AppStore+Goals.swift:62`).
- **The common case is correct.** The explain-then-fix regression XREV2 flagged is fixed, and fixes13–17 hold the fixes12 accuracy on an independent corpus.
- **Further patching does not converge.** Fixes13–17 spent five rounds on synthetic edge phrasings, and twice regressed common phrasings in between.
- **The overrides are the right escape hatch,** provided users can see the automatic decision (finding 5).
- **Agreed:** stop open-ended patching, and revisit only with a real usage corpus plus the held-out ratchet (finding 6).

## Required before release

Nothing blocks release. Recommended, in order:
1. **5:** show the evidence mode.
2. **1:** re-bind or migrate legacy outbound records.
3. **3:** a Codex `/tmp`-exclusion smoke test on the Mac.

Findings 2, 4, 6, 7 and 8 can follow.

Verdict: ship-with-fixes
