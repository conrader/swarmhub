# Fixes11 — Codex review 4

Base: `042997c`, branch `swarmhub/peer-delivery`. Read `/home/ubuntu/work/swarmhub/REVIEW-CODEX-4.md` in full. No commit was made. Hermes core, server, installation and services are unchanged. Tests use disposable repositories, synthetic secrets and CLI/provider stubs; no real provider jobs or external outbound requests were made. The pre-existing untracked `fixes8-brief.md` and `fixes8b-brief.md` are unchanged.

## Changes

1. **Git metadata authority.** `code-job:233` captures metadata before launching any coding tool. `verify_git.py:23` validates ordinary repositories and linked worktrees without invoking Git or executing configuration. Linked roots must have the expected `<main>/.git/worktrees/<name>` relationship, reciprocal `gitdir` pointer, and repository structure. External metadata cannot live inside the writable workspace. Root device/inode identities and pointer file identities/bytes are recorded in launcher-owned scratch space outside workspace-controlled `TMPDIR`. Validation runs again before launch and when constructing Linux/Darwin grants. Changed pointers or roots refuse verification with exit 77. Snapshot creation failures publish a failed job through the existing completion path.

   There is no implicit external grant for standalone invocation: linked worktrees need an explicit pre-tool snapshot. Ordinary in-workspace `.git` directories and non-repositories remain supported. Arbitrary separate-git-dir layouts, symlinked metadata roots, nested linked metadata inside the workspace, and new/replaced repository layouts after capture are refused. Legitimate commits can change HEAD, config and objects without invalidating the directory identity. Mac `/var` versus `/private/var` backlink spellings are canonicalized and tested with a local alias fixture.

   The trust boundary is the existing trusted launcher and its private scratch directory, not a signature that protects against arbitrary host code running as the same Unix account. Snapshot paths are supplied by the launcher, never discovered from workspace content or environment variables. `verify_darwin.py` consumes only the paths returned by this validation through the launcher.

2. **Mandatory seccomp rules.** `verify-sandbox.py:175` requires every syscall name to resolve. Missing names raise an error naming the syscall; rule installation errors also identify the syscall. The supervisor number map is resolved before forking (`:381`), so its failure cannot race workspace execution. Filter construction/installation finishes before exec in either mode. No architecture exceptions are silently inferred: a library/architecture that cannot express the mandatory policy refuses startup with exit 77. No new architecture exemption was added.

3. **Explanatory goals.** Swift and the Python mirror retain embedded question/explanation scope across coordinated verbs. “Explain how to build and test the parser” and “Describe how to add and remove a Python package” are general goals. “Explain the failure and then fix it” is coding; `failure` is included in the code-context nouns for the pronoun reference. The Swift table grew from 44 to 48 phrases, retaining every prior case; direct Python regressions also cover sentence boundaries and polite embedded requests.

4. **Ordered teardown.** `verify_signals.py:292` retains descendant pidfds after SIGKILL, polls for exit within a five-second deadline, and reaps adopted children before returning. Discovery repeats to catch descendants forked during scanning or adopted during parent exit. The launcher retains the root wait status. A timeout refuses successful completion. The existing zero-grace post-return pidfd assertion in `test_fixes7` is unchanged; new unit tests check kill → exit acknowledgement → reap → close ordering and bounded refusal.

5. **Private IPC.** Namespaced mode reporting now uses `sendmsg` on the same already-created anonymous Unix socketpair, checks the byte count, and adds no socket or network permission. An IPC regression exercises that exact branch. Direct host probes reproduce EPERM for `send`/`sendall` and success for `sendmsg` under the outer sandbox.

The coding skill version is **1.3.6 → 1.3.7**. Packaging/copy fixtures and Swift version assertions include `verify_git.py`. The messages skill version is unchanged. No existing test assertion or platform gate was relaxed.

## Regressions

`sim/test_fixes9_darwin.py` puts the new authority tests beside the legitimate linked-worktree profile test. They cover forged `.git` and `commondir` pointers to synthetic secrets in Linux limited mode and generated Darwin profiles, structurally valid replacement roots, missing pre-tool authority, invalid initial layouts, nested writable metadata, and canonical Mac-style aliases. Both standalone and stub `code-job` paths are exercised. Existing linked-worktree Git reads and metadata write denials remain.

`sim/test_fixes11.py` fault-injects unresolved names for every required Linux filter/supervisor syscall while retaining the real libseccomp elsewhere. Each subprocess must return 77, identify the syscall, and leave the workspace execution marker absent. Additional cases inject simple/conditional rule installation failure in both modes and namespaced filter load failure. Listener installation failure, private mode IPC, classifier behavior, and teardown ordering/deadlines have separate regressions. Namespaced filter/IPC injection exercises those branches without claiming that this host successfully created a PID namespace.

## Validation

All commands ran offline from this checkout unless stated otherwise. Clean-base comparison used `git archive HEAD` extracted to `/tmp/fixes11-baseline`, then ran discovery **with that directory as cwd** to keep imports isolated.

| Check | Result |
| --- | --- |
| Clean `042997c`: `PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py' -v` | 267 tests; 25 failing assertions, 2 errors, 8 skips; 21 failing/error methods |
| Patched full `sim` discovery | 285 tests; 8 failing assertions, 1 intermittent worker-test error, 8 skips; all 18 new methods passed |
| `python3 -B -m unittest discover -s scripts -p 'test_*.py' -v` | 56 tests; 51 passed, 5 environment/platform errors |
| `/bin/sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | **22 passed, 0 failed** |
| `CODE_JOB_SH=/bin/dash /bin/dash Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | **22 passed, 0 failed** |
| Focused security/process/classifier/packaging selection | 48 tests; 46 passed, 2 native-Mac skips (before the final nested-root case) |
| Final Git authority + fixes11 selection | 23 tests; 21 passed, 2 native-Mac skips |
| Original strict `test_fixes7` cleanup case repeated | **20/20 passed** |
| Python 3.9 grammar audit | All 11 changed/new Python sources pass `ast.parse(..., feature_version=(3, 9))` |
| Shell syntax and whitespace | `sh -n`, `dash -n`, `git diff --check` pass |

No Swift toolchain or Python 3.9 runtime is installed here. Python runs used 3.12. Native Seatbelt/Swift acceptance remains required; generated-profile and grammar checks do not substitute for those runs.

### Remaining environment failures

The patched full discovery has eight failing assertions across these five existing methods. All five also fail on the clean base; the earlier 284-test run had only these failures and no errors, resolving 16 of the base’s 21 failing/error methods:

- `test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed`: unavailable namespaces select limited mode, where creating a new top-level `build` directory is intentionally denied.
- `test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work`: `spawnSync /bin/sh EPERM`. The same Node operation fails directly outside Swarm Hub's verifier under the outer Codex sandbox.
- `test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result`: expects `namespaced`, receives `fallback` on this restricted host.
- `test_fixes8.LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process`: the test's anonymous socket `send` fails under the outer sandbox. A direct host socketpair probe reproduces EPERM, without any address or external endpoint.
- `test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode`: all four subtests reject the host's fallback mode.

The final 285-test run additionally hit an intermittent error in the unchanged `test_killed_worker_process_is_restarted_by_the_supervisor`: it read the PID file while empty and called `int('')`. Its immediately repeated isolated run passes. This is a PID-file publication/test race, **not a demonstrated Codex-sandbox artifact**, and it is recorded separately from the environment failures. Neither that test nor its worker implementation was changed.

The separate `scripts` suite has four local HTTP-fixture setup errors because the outer sandbox denies AF_INET socket creation (`FetchTests`), and one Linux platform error because Apple's `/usr/lib/system/libcommonCrypto.dylib` is absent (`test_safe_storage_vector_from_openssl`). These tests are unchanged. No failures were turned into skips or counted as successful security denials.

Logs: `/tmp/fixes11-clean-base-python.log`, `/tmp/fixes11-release-python.log`, `/tmp/fixes11-scripts.log`, `/tmp/fixes11-acceptance-sh.log`, `/tmp/fixes11-acceptance-dash.log`, `/tmp/fixes11-focused-final.log`, `/tmp/fixes11-git-final.log`, `/tmp/fixes11-cleanup-repeat.log`, `/tmp/fixes11-host-node.log`, `/tmp/fixes11-host-ipc.log`, `/tmp/fixes11-worker-rerun.log`.

## Exact Mac acceptance commands

Run from the patched checkout on the Mac with the project's Swift dependencies already cached. These commands do not install dependencies or run real coding providers. Retain failures and all existing assertions.

```sh
set -eu
git rev-parse HEAD
git status --short
sw_vers
/usr/bin/python3 --version

PYTHONPATH=sim /usr/bin/python3 -B -m unittest \
  sim.test_fixes11 sim.test_fixes9_darwin sim.test_fixes6 \
  sim.test_fixes7 sim.test_fixes8_goal sim.test_fixes8_skills \
  sim.test_macfix9 sim.test_macfix10 -v
PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py' -v
/usr/bin/python3 -B -m unittest discover -s scripts -p 'test_*.py' -v

/bin/sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"
if [ -x /bin/dash ]; then
  CODE_JOB_SH=/bin/dash /bin/dash Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"
fi

swift build --skip-update --disable-automatic-resolution
swift test --skip-update --disable-automatic-resolution
```

Require the native Seatbelt probes to reach their execution markers; valid linked-worktree Git reads must work, metadata writes and host-secret reads must remain denied, and forged/changed pointers must refuse before workspace execution. Both installed shell variants must pass 22/22. The Swift classification table and skill packaging/version tests must pass. Linux-only syscall and teardown tests retain their normal Mac skips and must also pass on an unrestricted Linux box.

For an explicitly trusted standalone linked-worktree invocation, capture before any coding tool runs, then pass the same snapshot to verification:

```sh
trust_dir=$(mktemp -d /tmp/swarmhub-git-trust.XXXXXX)
python3 Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py \
  --capture-git "$workspace" "$trust_dir/git.json"
# Authorized coding tool work happens here; never recapture after its edits.
python3 Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py \
  "$workspace" 'git status --short && git rev-parse HEAD' "$trust_dir/mode" "$trust_dir/git.json"
rm -rf "$trust_dir"
```
