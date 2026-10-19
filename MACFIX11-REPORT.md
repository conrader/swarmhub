# MACFIX11 report

Base: `0443a53`. Validation host: Linux, Python 3.12.3, bash 5.2.21.

## Cause

This was a test-fixture environment bug. `CodeJobLayoutTests.job()` built a minimal child environment that omitted `TMPDIR`. The parent Python process created its temporary HOME under the macOS temporary root (`/private/var/folders/.../T/`), but code-job received neither that root nor a HOME under `/tmp`. Its scratch directory was also outside the linked worktree. Consequently, it correctly retained scratch under HOME and did not enable the tmp exclusions for that child environment.

Linux hid the mismatch because the fixture normally lives under `/tmp`, which code-job always checks.

The production script already canonicalizes its initial scratch directory and both `/tmp` and `${TMPDIR:-/tmp}` using `cd` and `pwd -P` before checking containment. This resolves `/tmp` to `/private/tmp` on macOS and resolves symlinks in `TMPDIR`; no production detection change was needed.

## Fix

- Pass the parent's `TMPDIR` into the isolated job environment, using `tempfile.gettempdir()` when it is unset. The child now knows the fixture's temporary root without inheriting unrelated host environment variables.
- Strengthen the original failing test to require both `exclude_slash_tmp=true` and `exclude_tmpdir_env_var=true`.
- Add a regression with a physical `private/var/folders/synthetic/T` directory outside `/tmp`, a symlinked `var` alias, and a trailing slash in `TMPDIR`. Exercise both physical and aliased HOME paths. Assert successful verification, both Codex exclusions, removal of HOME scratch before the stub CLI starts, and scratch cleanup.
- Place the existing outside-tmp fixture in the writable checkout instead of the real user's HOME. Its containment check remains in place. This avoids the sandbox's read-only `/home/ubuntu` restriction. These tests explicitly skip if their checkout cannot provide the required outside-tmp location; neither skipped here.

The new regression failed for both HOME spellings with the original child environment, reproducing the missing `exclude_slash_tmp=true` assertion on Linux. It passed after the environment fix. Production sandbox settings and fallback behavior are unchanged: fallback continues to deny Codex both `/tmp` and `$TMPDIR`.

## Validation

| Command | Result |
| --- | --- |
| `PYTHONPATH=sim python3 -B -m unittest sim.test_fixes12 sim.test_fixes11 -v` | 35 passed; no skips; exit 0 |
| `/bin/sh Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | 22 passed, 0 failed; exit 0 |
| `CODE_JOB_SH=bash bash Tests/Scripts/code-job-test.sh "$PWD/Resources/Skills/swarmhub-coding/scripts/code-job"` | 22 passed, 0 failed; exit 0 |
| `sh Tests/Scripts/bot-msg-test.sh "$PWD/Resources/Skills/swarmhub-messages/scripts/bot-msg"` | Skipped, exit 77: permission denied opening a loopback socket |
| `git diff --check` | Passed |

`CODE_JOB_SH=bash` ensures the bash run exercises code-job itself under bash as well as the harness. Native macOS/Xcode Python 3.9 and Swift acceptance were not rerun on this Linux host; the new test uses Python 3.9-compatible APIs.

Only `sim/test_fixes12.py` and this report were changed. Goal classifier code and tests within their existing class, Hermes, and production scripts were left untouched. No commit was made.
