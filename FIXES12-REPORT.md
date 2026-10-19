# FIXES12 — Claude cross-review 2 (REVIEW-CLAUDE-XREV2) fixes

Base `ae95954` (peer-delivery), uncommitted working tree. Nothing was committed. Hermes was not touched: the diff
covers `Sources/AgentApp/Models/ChatAutomation.swift`, the swarmhub-coding and swarmhub-messages skill scripts and
`SKILL.md` files, Swift tests and `sim/`. No real network, provider or outbound send: CLIs are stubs, outbound is
FAKE or never run, and the HTTP handler is driven over in-memory streams.

## Required (release gate)

**1. Goal classifier regression: fixed (Swift and Python port).**
- **Where:** `ChatAutomation.swift:166-215`, `sim/goal_classifier.py:80-100`.
- **How scope is tracked now:** an explanation's scope is one of `unscoped`, `infinitive` or `clause`.
  - **Infinitive** ("how to V1 and V2 X") keeps coordinated verbs inside the explanation.
  - **Clause** ("why/what/where …") ends at `and` or `then`, so an imperative can follow.
- **Two refinements:**
  - In a clause, a change verb right after a subject, modal or `to` (`subordinateMarkers`) is the clause's own verb. A bare `and` then coordinates with it, so "Explain why we add tests and remove Python packages" stays general, as `test_fixes11` requires. `then` still opens an imperative.
  - Once "how to V" has an object, a comma or `then` ends the infinitive. "Explain how to build and test the parser, and fix the crash" is coding.
- **Tables:** the seven review phrases, plus three more, are in the coding table in `Tests/AgentAppTests/GoalTests.swift`. Three explanation phrases were added to the general table. The Python port runs that table (`test_fixes8_goal`; the expected count is now 38/23), and `sim/test_fixes12.py` also has them explicitly.
- **Still general:**
  - "Explain how to build and test the parser"
  - "Describe how to add and remove a Python package"
  - "Can you explain how to build and then test the parser?"
- **Known heuristic limits** (found by an adversarial pass, left as is):
  - "Explain why we add tests and fix the parser" and "Explain how to fix it and fix the parser" stay general. A bare `and` after the clause's own verb is ambiguous; `then` or a new sentence makes them coding.
  - "Explain why developers refactor code and fix bugs" is coding, because a noun subject is not recognised. That is a false positive, and `/goal --general` opts out.

**2. Git-authority capture no longer fails valid layouts: fixed.**
- **Capture is conditional:** `code-job:248` captures only when a verify command is configured.
- **Unsupported layouts are recorded, not fatal:** `verify-sandbox.py --capture-git` (`:429`) records a layout `verify_git` does not admit as `{"workspace", "unsupported": reason}`. That covers a submodule, `--separate-git-dir`, a forged pointer, and a NUL byte in a pointer.
  - It prints `code-job: verification will refuse: Git layout not supported: …`.
  - `validated_paths` (`verify_git.py:103`) then refuses with that reason. The job runs, the verify exit is 77 and the job reports `unverified` (66).
  - The library default `capture()` still raises, so the existing `test_fixes9_darwin` capture tests are unchanged.
- **Bare common directories (`*.git`) are admitted** (`verify_git.py:69`) under the same structure, reciprocity, outside-workspace and pin checks.
- **Relative backlinks** (git ≥ 2.48 `worktree.useRelativePaths`) resolve against `<target>`.
- **Backlinks are compared by `(st_dev, st_ino)`** (`:75`). That is finding 8: it covers the APFS case-folding case and keeps the existing /var vs /private/var alias test passing.
- **Regressions:**
  - bare-repo worktree job and submodule job without `--verify`: both run, commit, exit 0;
  - submodule with `--verify`: 66, reason on stderr, verify command not run;
  - bare worktree with `--verify`: verified, exit 0;
  - relative-backlink and identity unit tests.

**3. Outbound argv: fixed.**
- `swarm_policy.py:211-217` always composes `outbound_argv(to, text, fake)`, and a caller `argv` that differs is refused. This applies to FAKE records too. It mirrors `provision`.
- **Regression:** `PolicyTests.test_outbound_never_takes_a_caller_supplied_command` covers a shell argv, a FAKE argv and a different recipient, which are refused; an exact argv is coordinator-gated, and an omitted argv is composed.

## Also fixed

- **4. `swarm_remote.py`:**
  - `do_POST` catches `Exception` and returns 403 (`:202`).
  - A `wake()` failure after the commit is logged and the signed receipt is returned (`:173-177`).
  - The handler class is factored into `handler(service)` so tests drive `do_POST` without a socket. Tests cover sqlite lock and RecursionError → 403 with the task still awaiting, and wake failure → 200 with a signed receipt and the decision recorded.
- **5. Snapshot location:**
  - `$T` (git-trust.json, verify-mode) now lives in `~/.hermes/swarmhub/scratch/code-job.*` (`code-job:96-109`). That is outside `--dir`, `/tmp` and `$TMPDIR`, which are codex's writable roots.
  - Only when one of those contains it (a HOME workspace, or HOME under /tmp) does it fall back to `/tmp`. In that case codex gets `-c sandbox_workspace_write.exclude_slash_tmp=true -c sandbox_workspace_write.exclude_tmpdir_env_var=true` (`:307-310`).
  - Codex's argv is unchanged in the normal case, so the exact-flags shell test still holds.
  - **Not verified:** I rely on Codex's documented `sandbox_workspace_write` keys; no real Codex ran.
- **6. Integers:** `validate_spec` rejects any integer outside ±2^53 anywhere in a spec (`swarm_policy.py:151`). Booleans are allowed.
- **7. Stronger tests** in `sim/test_fixes12.py`:
  - a sendmsg spy whose `sendall`/`send` raise;
  - a forged `.git` pointing at another repository's structurally valid worktree, and a respelled `commondir`. `layout()` accepts both, so the pin alone refuses them. This is checked at unit level and through a real `code-job` run.
- **8.** Done as part of item 2.
- **9. Darwin teardown:**
  - `verify_darwin.run_grouped` (`:94`) runs sandbox-exec as a new session and process-group leader. After it exits, it SIGKILLs the group.
  - The test runs on Linux and macOS: a background `sleep` is dead after return.
  - **Remaining gap:** a descendant that calls `setsid`/`setpgid` leaves the group and is not reached, because macOS has no pidfd/subreaper equivalent. This is documented in the docstring and SKILL.md.

## Changed existing tests (adapted, not weakened)

Several existing tests had to change. In each case the assertions were kept or made stricter.

- **`test_patterns` P07, P09, and `test_review_fixes` fake-dry-run:** these submitted an outbound action with a caller `argv`, which is now refused.
  - They now publish an owner `outbound` sender and omit `argv`.
  - P09 and review-fixes use a sender that *would* create the marker, so "FAKE never executes" is still exercised.
  - P09 also asserts that the caller argv is refused.
- **`test_remote_approvals` timeout-after-commit:** it used to expect `TimeoutError` to propagate from `wake`. Per finding 4, it now expects the receipt. It still asserts that a restarted `get` returns the same receipt without waking.
- **`test_fixes5` Darwin launch:** it patches `verify_darwin.run_grouped` instead of `subprocess.call`, with the same assertions.
- **`test_fixes8_goal`:** only the table counts changed.

## Skill versions

swarmhub-coding and swarmhub-messages are bumped 1.3.7 → 1.3.8, so installed bots are told to update. The changes:
- the `SKILL.md` text documents conditional capture, the outbound argv rule and group teardown;
- the version pins are updated in `CodingSkillTests.swift`, `BotMessageSkillTests.swift` and `sim/test_fixes8_skills.py`.

## What I ran (Linux, Python 3.12, git 2.43; `/bin/sh` is dash here)

| Command | Result |
|---|---|
| Clean `ae95954` (`git archive` → `/tmp/fixes12/base`): `PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py' -v` | 285 tests, **OK** (7 skips, native-Mac) |
| Same discovery, final patched tree | **309 tests, OK** (same 7 skips); 24 new in `test_fixes12` |
| `python3 -B -m unittest discover -s scripts -p 'test_*.py'` | 56 tests, 1 error: `test_grokbot_server` loads `/usr/lib/system/libcommonCrypto.dylib` (macOS only); same error on the clean base, so environment-only |
| All 7 `Tests/Scripts/*-test.sh` under `/bin/sh` and under `/bin/dash` (`CODE_JOB_SH=/bin/dash`) | 92/92 each (code-job 22, bot-msg 14, swarmhub-report 22, box-readings 12, box-adopt 11, accounts 6, claude-login 5) |
| code-job and bot-msg suites again on the final tree, `/bin/sh` | 22/22, 14/14 |
| code-job suite under `/bin/bash` (`CODE_JOB_SH=/bin/bash`), a shell distinct from dash | 22/22 |
| `sh -n`/`dash -n code-job`, `git diff --check`, Python 3.9 grammar (`ast.parse(feature_version=(3,9))`, 13 files) | pass |
| An adversarial verifier pass (read-only) | Found the NUL-byte capture crash and the "how to …, and fix" case, both fixed and regression-tested; other findings are the heuristic limits listed under item 1 |

Because `/bin/sh` is dash on this host, the "sh" and "dash" runs used the same shell; the bash run is the second one.
Logs: `/tmp/fixes12/*.log`.

- **Not run:**
  - Swift build and tests (no toolchain here). The Swift classifier was checked by a line-by-line parity review against the port, not compiled.
  - Native Seatbelt.
  - A Python 3.9 runtime. All changed Python files parse with `feature_version=(3,9)`.
  - A real Codex CLI.

## Mac acceptance command

```sh
set -eu
git rev-parse HEAD; git status --short; sw_vers; /usr/bin/python3 --version
PYTHONPATH=sim /usr/bin/python3 -B -m unittest sim.test_fixes12 sim.test_fixes8_goal sim.test_fixes8_skills \
  sim.test_fixes11 sim.test_fixes9_darwin sim.test_fixes5 sim.test_fixes6 sim.test_remote_approvals \
  sim.test_patterns sim.test_review_fixes -v
PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py' -v
/bin/sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"
swift build --skip-update --disable-automatic-resolution
swift test --skip-update --disable-automatic-resolution --filter \
  'plainGoalsAreClassifiedByTheRequestedAction|codingLikeGoalsRequireEvidenceUnlessMarkedGeneral|aPlainCodingLikeGoalIsSentBackWithoutEvidenceAndGeneralOptsOut|codingSkillShipsWithItsScript|installTurnCarriesTheScriptAndTheVariant|installsAtThePreviousSkillVersionsAreOutdated|installRecordsTheVariantFromTheBlock|messagesSkillShipsWithItsScript|renderedMessagesSkillSendsAsThisBot'
swift test --skip-update --disable-automatic-resolution   # full suite, release gate
```

On the Mac, `test_snapshot_is_kept_in_launcher_state_outside_codex_writable_roots` creates and removes a temporary
`~/.swarmhub-fixes12-*` directory: the fixture HOME must lie outside `$TMPDIR` and `/tmp`, as a real one does.
