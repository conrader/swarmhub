# MACSMOKE1: Mac real-Codex `/tmp` exclusion smoke test

Originally written on `swarmhub/peer-delivery` @ 11f1f2d. Implements steps 1-6 of FIXES18-REPORT.md, section "Mac real-Codex `/tmp` exclusion smoke test" (REVIEW-CLAUDE-XREV3 finding 3). The original results below are Linux stub runs. The macsmoke3 section discusses the subsequently supplied Mac log for c044cbd; no real Codex was invoked during this revision.

New files:

- `sim/mac-codex-tmp-smoke.sh` is the probe (POSIX sh plus python3 ≥ 3.9 for hashing, timeouts and nonces).
- `sim/mac-codex-tmp-smoke-stub.py` is a stand-in for `codex`, used only with `--stub`.
- `sim/test_macsmoke2.py` holds the stub-mode regressions for the macsmoke1 review (added in macsmoke2, below).

## Claims checked before writing

- **Launcher argv (`code-job:315-317`).** Codex gets `exec --skip-git-repo-check -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"'`. The two `sandbox_workspace_write.exclude_*=true` keys are added only when `NOTMP=true`, followed by `--model "$MODEL" -c model_reasoning_effort="…"` and the task. This matches the FIXES18 command, and the script uses the same order.
- **Fallback (`code-job:105-117`).** The scratch directory `$T` starts in `$HOME/.hermes/swarmhub/scratch`. If `--dir`, `/tmp` or `$TMPDIR` contains it, it moves to `mktemp -d /tmp/code-job.XXXXXX` and `NOTMP=true`.
- **Launcher snapshot.** `$T/git-trust.json` exists only when a verification command is set, so the code-job runs pass `--verify true`.
- **No default model.** `code-job` has no default model: `--model` (or `CODE_JOB_MODEL`) is required, or the swarm policy's `codex_model` supplies one. So the script invents none:
  - Direct runs omit `--model`, and Codex uses its own configured default.
  - code-job runs pass the placeholder `macsmoke1-codex-default`. A host-side shim removes it before running the real Codex, and the shim record shows both argvs.
  - `--model <id>` pins a model for every run.
- **Local Codex flags.** The Codex on this Linux box (`codex-cli 0.159.2`) has `exec --skip-git-repo-check`, `-c`, `-m/--model` and `login status`. The Mac's version is recorded by the script.

## How to run it on the Mac

Prerequisites: this checkout at `/tmp/qm6`, the real `codex` installed and already logged in, and Xcode `python3`. One command:

```sh
cd /tmp/qm6 && sh sim/mac-codex-tmp-smoke.sh
```

- **Log.** Output goes to the terminal and to `./macsmoke1-<UTC>.log`. Set `SMOKE_LOG=-` for no log or `SMOKE_LOG=<file>` to choose the file. The exit code is preserved.
- **Cost.** Seven Codex calls, each capped by `--timeout` (default 300 s; code-job runs get an outer cap 120 s longer). Effort defaults to the launcher's `high`; `--effort medium` makes it cheaper.
- **The non-fallback run (`cj-outside`) is in the default command.** HOME and the workspace must be outside `/tmp` and `$TMPDIR`, so the script creates one `~/macsmoke1.XXXXXX` directory (fake HOME and workspace inside it) and removes it at exit. This is the only directory it creates outside `/tmp`/`$TMPDIR`. `--outside-dir <dir>` puts that directory in `<dir>` instead; a `<dir>` under `/tmp` or `$TMPDIR` is refused before any Codex call. If `$HOME` itself is missing or temporary and no `--outside-dir` is given, the run is reported as `inconclusive=cj-outside:no-outside-dir`.

### What it does

Every run creates new disposable locations:

- `A = /tmp/code-job.XXXXXX`
- `B = $TMPDIR/macsmoke1-tmpdir.XXXXXX`
- a links directory in `$TMPDIR` with `a -> A` and `b -> B`

A and B each hold a synthetic `git-trust.json` sentinel. Its SHA-256 is kept in shell memory, not on disk.

The prompt is two lines: run `sh ./smoke-probe.sh` once, then reply DONE, with no retries and no network. The probe runs inside Codex's sandbox. It:

- writes `./smoke-control.txt`, the positive control holding the run nonce;
- for each spelling of each location (as given, physical such as `/private/tmp/…` or `/private/var/folders/…`, and the symlink alias), tries to create `smoke-marker-<label>`, overwrite `git-trust.json`, and rename it to `git-trust.json.renamed-<label>`;
- logs each attempt as WROTE or refused, with the error text;
- writes `./smoke-done.txt` (`done <nonce>`) as its very last action, the completion marker.

| run | Codex settings | A (/tmp) | B ($TMPDIR) |
|---|---|---|---|
| `on` | launcher fallback argv, both keys | must be denied | must be denied |
| `off` | no exclusion keys (control) | expected writable | expected writable |
| `slash` | `exclude_slash_tmp` only | must be denied | expected writable |
| `tmpdir` | `exclude_tmpdir_env_var` only | expected writable | must be denied |
| `cj-home` | real `code-job`, fake HOME in `$TMPDIR`, `--dir $HOME` | must be denied | must be denied |
| `cj-sibling` | real `code-job`, fake HOME in `$TMPDIR`, `--dir` a `/tmp` workspace | must be denied | must be denied |
| `cj-outside` | real `code-job`, HOME and `--dir` under `~/macsmoke1.XXXXXX` (or `--outside-dir`) | — | — |

The expectations are computed, not hard-coded. A location is "must be denied" when every temporary root that contains it (`/tmp`, and `$TMPDIR` if set) is excluded in that run.

The code-job runs use a copy of `swarmhub-coding/scripts` without `swarmhub-messages`, so there are no policy lookups and no wake messages. `CODEX_HOME` points at the real `~/.codex` so login still works under the fake HOME. A host-side `codex` shim on `PATH` does five things:

1. records the argv code-job produced;
2. finds the launcher's `$T` (new, and its `git-trust.json` names this workspace);
3. adds `$T` to the probe targets (as given and physical);
4. hashes the snapshot;
5. runs the real Codex, then re-hashes and lists `$T` after Codex exits, writing its record only then.

The script then asserts:

- fallback runs got both keys, and `cj-outside` got none;
- `$T` is in system `/tmp` for fallback, or in `$HOME/.hermes/swarmhub/scratch` for `cj-outside`;
- `$T` is not inside the workspace;
- the snapshot is unchanged and has no new entries;
- the probe completed: control and completion marker both hold the nonce, and both code-job and the Codex it started exited 0.

**The oracle** is host-side only: sentinel hash and presence, the directory listing (anything besides `git-trust.json` counts as writable), the shim's snapshot hash and listing, and the control and completion files' nonce, plus the exit status. The probe log and Codex transcript are printed as evidence but never decide the result. The script also records:

- environment: date, `sw_vers` (macOS version, build, arch), `python3` path and version, `/bin/sh` target, repo HEAD;
- the `codex` path and realpath, `codex --version`, the `/tmp` and `$TMPDIR` physical paths;
- sandbox-related keys from `$CODEX_HOME/config.toml` (they also apply to the launcher);
- the exact argv of every run, the full Codex and code-job transcripts, the probe logs and the shim records.

### Expected output on a Mac where the claim holds (a prediction, not an observation)

```
smoke: result=PASS enforced=exclude_slash_tmp,exclude_tmpdir_env_var,cj-home,cj-sibling,cj-outside writable=off:tmp,off:tmpdir,slash:tmpdir,tmpdir:tmp unexpected=none codex=codex-cli_<version>
```

### Reading the final line

| field | meaning |
|---|---|
| `enforced=` | Exclusion keys whose protection was attributed: the location was writable in `off`, denied with the key alone and denied in `on`. Also lists each code-job run whose layout, keys, snapshot and control checks all passed. |
| `writable=` | Every `run:location` the host saw changed, whether expected or not. |
| `unexpected=` | Writable locations the settings should have protected. |
| `inconclusive=` | Why a run or attribution proved nothing. |
| `reason=` | Only on an early stop. |

### The three results

**FAIL (exit 1).** At least one protected sentinel, marker location or launcher snapshot changed. This blocks any claim of enforced evidence isolation for that Codex version, and the transcripts show which spelling got through. FAIL takes precedence over INCONCLUSIVE everywhere, including early stops (`result=FAIL reason=first-run:timeout`) and Ctrl-C.

**INCONCLUSIVE (exit 0).** Nothing protected was written, but something is unproven. Causes:

- before any run: `codex-missing`, `codex-not-logged-in`, `codex-version-failed`, a missing code-job, or a temporary `--outside-dir`;
- first run did not start: `first-run:codex-exit-N`, `first-run:timeout`, `first-run:codex-login` (the script stops here);
- a run that started but proved nothing: `tool-not-run`, `probe-incomplete` (no completion marker), `timeout`, `codex-exit-N` / `code-job-exit-N`, `codex-not-started`, `snapshot-none`, `launcher-layout` (wrong keys or wrong scratch location), `cj-outside:no-outside-dir`;
- a key that could not be attributed: `<key>:unattributed`. Typically the `off` control could not write, or `$TMPDIR` is `/tmp`.

A model refusing in prose, a tool never called, a probe that did not finish, or a run that timed out or exited non-zero is always INCONCLUSIVE, never PASS, even when the probe's files exist.

**PASS (exit 0).** Every run was conclusive, both keys were attributed, all three code-job runs held, and nothing unexpected was writable. The scope is limited to the recorded Codex version and these seven runs.

## Linux sanity checks run here (macsmoke1; see macsmoke2 below for the current results)

- `shellcheck -s sh` is clean apart from excluded style and eval-related codes: SC1007 empty assignments, SC2010/SC2012 `ls`, SC2015, and SC2154 (variables set via `eval`). The script also passes syntax checks under `dash`, `bash` and `bash --posix`. The stub passes `py_compile`.
- **`--stub` (enforce).** The stub records argv and emulates the writable roots by making out-of-root targets read-only during the probe. Run with a distinct symlinked `TMPDIR=/dev/shm/msk-alias -> /dev/shm/msk-real`: **PASS** both under `dash` with `--outside-dir` under the checkout, and under `bash --posix` with `--model` (no `--outside-dir`). Both keys were attributed. The code-job runs found the real launcher `$T`:
  - `cj-home` and `cj-sibling`: `/tmp/code-job.*`, both keys present;
  - `cj-outside`: `$HOME/.hermes/swarmhub/scratch/code-job.<pid>.*`, no keys.

  The placeholder was dropped, and `--model gpt-test-1` was passed through.
- **`--stub leaky`** (exclusions ignored): **FAIL, exit 1**, propagated through the log `tee`, with every protected location and both snapshots listed in `unexpected=`. This run exposed a bug that is now fixed: a code-job run with a writable snapshot was still being listed in `enforced=`.
- **`TMPDIR` unset:** INCONCLUSIVE `exclude_tmpdir_env_var:unattributed`. This is correct, because without `$TMPDIR` that key has nothing to remove.
- **Fake `codex` binaries:**
  - not installed → `reason=codex-missing`;
  - `Not logged in` → `reason=codex-not-logged-in`;
  - startup error → `reason=first-run:codex-exit-2`, with no further runs.

  All exit 0. `--outside-dir /tmp` was refused up front.
- **Cleanup:** after every run, no `code-job.*`, `macsmoke1*` or `msk*` entries were left in `/tmp`, `/dev/shm` or the outside directory.

Not run here:

- **The real Codex.** No provider call was made, and Linux Codex uses a different sandbox anyway.
- **macOS specifics:** the `/private/tmp` and `/private/var` aliases (on Linux `/tmp` is already physical, so no `.phys` target for A is generated), `sw_vers`, BSD `sed -E`/`mktemp`/`head -c`, bash 3.2 as `/bin/sh`, and Python 3.9 (3.12 here; only 3.9-compatible features are used).

## Limits

- **Stub mode proves nothing about Codex.** It only exercises the plumbing, the oracle and the classification. Only the Mac run with the installed Codex settles finding 3.
- **The probe is cooperative.** The model is asked to run one fixed script. That tests the sandbox against those shell operations, not against an adversarial model looking for other routes.
- **HOME placement is approximate.** The fake HOME of `cj-home` and `cj-sibling` is in `$TMPDIR`, which alone triggers the fallback, so the production HOME-scoped case (`--dir ~` with a real HOME) is approximated. `cj-outside` covers the genuine non-fallback path with a fake HOME under `~/macsmoke1.XXXXXX`, not the user's real `~/.hermes`.
- **Workspaces sit under an excluded root.** Workspaces are in `/tmp` or `$TMPDIR`. If Codex also denied a cwd under an excluded root, the positive control would fail and the run would be INCONCLUSIVE, not falsely PASS.
- **Records are in reachable places.** The shim, the evidence and the shim records sit in `/tmp`, which is writable in the `off` and `cj-outside` runs. Sentinel hashes are kept in memory, and the shim writes its record only after Codex exits. A run that tampered with these files would still need to leave A, B and `$T` untouched.
- **User config applies.** The user's `$CODEX_HOME/config.toml` (for example `writable_roots`) applies, exactly as it does for the launcher, and is printed. If a configured root grants `/tmp`, the result is a real FAIL for that setup.
- **The `off` control assumes Codex's default.** It relies on Codex's default workspace-write roots including `/tmp` and `$TMPDIR`. If they don't, the keys are `unattributed` (INCONCLUSIVE), not PASS.
- **Secrets.** The script never prints or reads auth files. The `codex login status` output is checked only for a fixed phrase and then deleted. From `config.toml`, only sandbox key lines are grepped. Transcripts pass through a redaction filter. `ANTHROPIC_API_KEY` is unset for every run.
- **Out of scope (as FIXES18 says):**
  - Darwin descendant cleanup limits;
  - the Claude host-shell route;
  - choosing a minimum supported Codex version: no minimum is pinned from this script; record the version a real PASS was obtained with.

## macsmoke2 fixes (review `20261019T224429Z-macsmoke1.review.txt`, verdict CONCERNS)

Each finding was confirmed by reading the macsmoke1 script before fixing it, and each regression was then shown to fail with its fix reverted (mutation runs below).

1. **Cleanup word-split registered paths.** `for d in $(printf '%s\n' "$CLEAN")` split on spaces and globbed, so `TMPDIR="/x/td x"` made it run `chmod -R u+rwx` and `rm -rf` on `/x/td` and on a relative `x/macsmoke1-tmpdir.*`. Now:
   - each `mktemp -d` result is registered as one line;
   - cleanup iterates in a subshell with `set -f` and `IFS=<newline>`, and a `$TMPDIR` or outside base containing a newline is refused up front;
   - a path is removed only if it is absolute, has no `.`/`..` component, is a real directory (not a symlink), is named `macsmoke1*` or `code-job.*`, and its physical parent is exactly `/tmp`, `/private/tmp`, physical `/tmp` or physical `$TMPDIR`. The one exception is the exact `macsmoke1.XXXXXX` directory this run created in the outside base (finding 4), whose parent must be that base;
   - anything else is left in place and reported as `cleanup: REFUSED [...]`.
2. **A timed-out run counted when the control file existed.** The probe now writes `./smoke-done.txt` (`done <nonce>`) as its last action. A run counts only if the control and completion files both hold the nonce and the exit status is 0: Codex's for direct runs; for code-job runs, code-job's and the shim-recorded Codex exit. Otherwise it is inconclusive with `timeout`, `codex-exit-N`/`code-job-exit-N`, `codex-login`, `tool-not-run` or `probe-incomplete`. The log line is `positive control: <state>; completion marker: <state>; exit: <rc>`.
3. **An early stop could report INCONCLUSIVE after an unexpected write.** `summary` now turns any result into FAIL (exit 1) when `unexpected=` is non-empty, so this holds for every early stop, and the INT/TERM traps report FAIL too. The `reason=` field is kept, for example `result=FAIL reason=first-run:timeout`.
4. **The default command skipped the non-fallback launcher case.** `cj-outside` now runs by default in a `~/macsmoke1.XXXXXX` directory the script creates and removes (see "How to run it on the Mac"). `--outside-dir` only changes where that directory goes. `skipped=` is gone; if no outside base is usable, the run is `inconclusive=cj-outside:no-outside-dir`. The Mac one-command invocation is unchanged: `cd /tmp/qm6 && sh sim/mac-codex-tmp-smoke.sh`.

New stub modes (`--stub <mode>`, Linux plumbing only): `timeout` (full probe, then hang), `leaky-timeout` (leaky and hang), `incomplete` (completion marker blocked). Like `codex exec`, the stub now exits 0 whatever the probe returns.

### Checks run here (Linux, stub only)

- `shellcheck -s sh -e SC1007,SC2010,SC2012,SC2015,SC2154`: clean. One SC2317 false positive (a function reached only from the traps) is suppressed inline. Syntax OK under `dash -n`, `bash -n` and `bash --posix -n`; the stub passes `py_compile`.
- `python3 -m unittest sim.test_macsmoke2`: **5/5 OK** (34 s, `sh` = dash). Each test also asserts that nothing is left in `$TMPDIR`, the outside base or `/tmp` (`code-job.*`, `macsmoke1*`), and that no cleanup was refused.
  - space in `$TMPDIR` (`<shm>/td x`, decoy `<shm>/td/canary`): PASS, decoy intact, `cj-outside` in `enforced=` with `expect fallback=no`, no `skipped=`;
  - `--stub timeout`: `INCONCLUSIVE reason=first-run:timeout`, exit 0, although the log shows control and completion marker both written;
  - `--stub incomplete`: INCONCLUSIVE with `probe-incomplete` for all seven runs, exit 0;
  - `--stub leaky-timeout`, through the log `tee`: `FAIL reason=first-run:timeout unexpected=on:tmp,on:tmpdir`, exit 1, and the same line is in the log;
  - `--stub leaky`: FAIL, exit 1.
- **Mutations:** each fix reverted in a copy of the script made its test fail. The `$(printf ...)` loop left the `$TMPDIR` dirs behind; without the exit-status check the timeout run went on to `inconclusive=...codex-not-started` instead of stopping at `first-run:timeout`; without FAIL precedence the leaky timeout returned exit 0.
- **Manual runs:**
  - `dash`, `--stub` enforce with symlinked `TMPDIR=/dev/shm/msk2-alias`: PASS with `cj-outside` under `/home/ubuntu/macsmoke1.*`;
  - `bash --posix` with `--model gpt-test-1 --outside-dir ~/msk2-od.*`: PASS;
  - `TMPDIR` unset: INCONCLUSIVE `exclude_tmpdir_env_var:unattributed` (as before);
  - `--outside-dir /tmp`: refused, `reason=outside-dir-is-temporary`.

  Afterwards no `code-job.*`/`macsmoke1*` entries were left in `/tmp`, `/dev/shm` or `~`.

Not run: the real Codex (no provider calls), anything on macOS (`/private/tmp` aliases, bash 3.2 `/bin/sh`, BSD tools, Python 3.9), and the `cleanup: REFUSED` path. No test feeds cleanup a path outside the allowed roots, because every registered path comes from this run's own `mktemp`; that branch was only reviewed by reading it.

## macsmoke3 (c044cbd)

**Diagnosis and its limit.** Read `/home/ubuntu/work/swarmhub/mac-smoke2-c044cbd.log` (Codex 0.162.1). Both fallback probes wrote their report and completion nonce, all isolation writes were denied, and code-job returned 65. The probe does **not** pre-write the baseline: `completion-contract.py baseline` runs before the shim/Codex/probe. It compares SHA-256 contents, not timestamps. `--dir` and the probe's absolute report path both use `pwd -P`. An unchanged probe report is therefore fresh for this new workspace; rewriting it is unnecessary. The unchanged launcher and original stub pass all seven cases locally without a model rewrite, under dash and bash POSIX. A new symlinked-TMPDIR regression also passes.

Exit 65 additionally covers **empty CLI stdout**, even with a fresh valid report. This is intentional launcher behavior (shell-suite case 16). The old stub printed its argv and all tool output on stdout, hiding that branch. A stderr-only stub reproduces exit 65 in all three launcher layouts with `report-before=missing-or-empty`, `report-valid=true`, both nonce files and CLI exit 0. **This verifies a mechanism, not the historical Mac cause:** the supplied log merges stdout/stderr and omits the completion journal. Its two `DONE` lines do not establish the captured stdout file's size. It cannot conclusively distinguish empty stdout from a report-check I/O failure. No production code-job bug has been demonstrated, and code-job is unchanged. A verified diagnosis of that Mac failure remains outstanding.

**Harness change.** The host shim now captures/replays raw Codex stdout, records its byte count, and prints a deterministic shim status line after Codex exits. Smoke completion no longer depends on final prose reaching stdout. It does not write or repair the report. The log includes the launcher's report baseline/hash/validity and exit records before cleanup, so another failure is diagnosable. Missing shim records after a killed CLI retain the timeout/nonzero reason. All sentinel hashes, directory/alias checks, launcher snapshot checks, nonce checks and both exit-status requirements remain; unexpected writes still win as FAIL. Missing/unchanged reports still return 65. Stub fixtures now use separate HOME/TMPDIR siblings outside system `/tmp`, avoiding the `/dev/shm` requirement that skipped all five tests on the Mac.

**Validation (Linux).** No commits, Hermes changes, outbound messages or real Codex/provider calls were made.

- Smoke script and both embedded scripts: shellcheck clean with the existing `SC1007,SC2010,SC2012,SC2015,SC2154` exclusions; dash/bash/bash-POSIX syntax and Python syntax pass. Unchanged code-job/shell-suite shellcheck additionally reports existing SC2086, SC2317 and SC2009 diagnostics. `git diff --check` passes.
- `test_macsmoke2`: **9/9 pass** in final full discovery, including the status-line mutation that reproduces 65, genuine missing/unchanged-report rejection, symlinked TMPDIR, leaks, incomplete probes, nonzero exits and timeouts. The first focused run exposed the misleading missing-shim timeout label, fixed before final discovery.
- Code-job shell suite: **22/22 each** under `/bin/sh`, `/bin/dash`, `/bin/bash`.
- `PYTHONPATH=sim python3 -B -m unittest discover -s sim -v`: **369 tests, 8 failure records, 8 skips** (201.7 s). Failure names match the documented FIXES18 baseline: fallback directory writes, Node subprocess EPERM, namespace-mode expectation, SIGIO socket EPERM, and four namespaced-signal variants. No smoke regression failed.
- `python3 -B -m unittest discover -s scripts -p 'test_*.py'`: **56 tests, 5 errors**: four sandbox-denied loopback fixtures and unavailable macOS CommonCrypto. Neither full suite is green here.
- Cleanup assertions pass after every smoke run; final checks found no disposable smoke/launcher directories in the checkout, `/tmp` or `/dev/shm`. Temporary diagnostic logs were removed after recording these results.

**Still needs the Mac.** Rerun the real sandbox cases and inspect the new stdout/contract diagnostics if any launcher is still inconclusive. Linux stubs cannot validate Seatbelt, `/private/tmp`, `/private/var`, or bash 3.2. The one-command invocation remains:

```sh
cd /tmp/qm6 && sh sim/mac-codex-tmp-smoke.sh
```

## macsmoke4 (533593b + uncommitted)

**Cause: what the Mac log proves and what it does not.** Source: `/home/ubuntu/work/swarmhub/mac-smoke3-533593b.log` (Codex 0.162.1, Python 3.14.2, macOS 26.6.2). In `cj-home` and `cj-sibling` the probe logged `report …: WROTE`, Codex exited 0 with 5 stdout bytes, every isolation write was denied, and the launcher recorded `report-exists=true report-sha256=missing-or-empty report-valid=false exit=65`.

- **Not a path bug.** The record's `report=` is byte-identical to the path the probe wrote and the path in the prompt. code-job derives it from `pwd -P` before anything else runs. On HEAD, the new shell case 23 (`--dir` is HOME through a symlinked parent, fallback scratch in `/tmp`, both exclusions, report written at the physical path) exits 0 with `report-valid=true`. The same layout passed with the stub on that Mac, in the same session, on the same Python (`test_macsmoke2` 9/9 in the log header).
- **Not a rule the probe trips.** The contract asks for a report that is non-empty and different from the pre-run baseline. It does not ask whether the model wrote it. A probe-written report passes.
- **What the two fields actually measure.** `report-exists` is the shell's `[ -f ]` at finish, which is true for an empty file. `report-sha256=missing-or-empty` came from the check right after Codex exited. It covers a missing, empty or non-regular file, and on Python 3.14 any stat error at all: 3.14's `Path.is_file()` returns False for EACCES where 3.12 raises (checked here: 3.14.4 vs 3.12.13). So the record fits two cases: the report was **empty** at the check, or **python3 could not stat it**. It cannot tell them apart. The 44-byte size in the macsmoke3 notes comes from `cj-outside`'s `ls -la`, before Codex rewrote that report. There is no size evidence for the two failing cases.

**Verdict:** this log shows neither a code-job path bug nor a harness rule. The Mac mechanism is still unproven. The code-job defect that *is* real is that its record cannot say why the report check failed, and what that record means depends on the Python version. That defect is what this pass fixes, along with making the next Mac run decisive.

**Fix.**
- `completion-contract.py` stats the file explicitly (no `Path.is_file()`) and records `report-state` (`ok`, `unchanged`, `missing`, `empty`, `not-regular`, `unreadable-<ERRNO>`) and `report-bytes`. `report-sha256` and `report-valid` keep their meaning. It still fails closed: a missing, empty, unchanged or unreadable report is 65. An unreadable report used to exit 65 with no record on Python ≤3.13. It now records why.
- `code-job` finish also records `report-final`, the shell's view (`missing`, `empty`, `nonempty`, `not-regular`), next to the contract's view at the check.
- Smoke: the host shim records `report-at-cli-exit` as soon as Codex exits. That covers python3 and `sh`, plus `ls -lndO@e` (flags, xattrs, ACL) on macOS. Each launcher run prints `report timeline: cli-exit …; verify …; finish …; host now …`. A launcher 65 whose report check failed is now reported as `code-job-exit-65-report-<state>`. It is still INCONCLUSIVE and never PASS. Unexpected writes still FAIL, and timeouts and non-zero exits still never count.
- Smoke flake found while testing: the login heuristic matched `401` anywhere in the last 20 transcript lines, so a random `job.x401…` or mktemp name turned a 65 into `codex-login`. It now matches `401` only as a word.
- Stub mode `emptied-report` reproduces the Mac record exactly: stdout `DONE`, probe `WROTE`, symlinked TMPDIR, then `report-exists=true`, `report-sha256=missing-or-empty`, exit 65 in all three launcher layouts.

**Reading the next Mac run** (`report timeline` line of `cj-home`/`cj-sibling`):

| cli-exit | verify | finish | Meaning |
|---|---|---|---|
| `python:empty sh:empty` | `empty` | `empty` | The report was already empty when Codex exited. The cause is on the Codex/Seatbelt/probe side, not code-job. |
| `python:unreadable-<ERRNO> sh:nonempty` | `unreadable-<ERRNO>` | `nonempty` | python3 cannot read a file the shell sees. This is code-job's problem: fix the contract's read path. |
| `python:bytes-<n> sh:nonempty` | `missing`, `empty` or `unreadable-…` | any | The report changed between the CLI exiting and the check. This is a code-job timing problem. |
| `… sh:missing` | `missing` | `nonempty` | The report appeared after the check (a late writer). |
| anything | `ok` | `nonempty` | The case no longer reproduces. The fallback runs reach PASS or FAIL on isolation. |

The `ls:` lines in the shim record show the macOS flags and xattrs (for example `com.apple.provenance`) on the report at that moment.

**Tests added.** Shell case 23 (`Tests/Scripts/code-job-test.sh`) covers the `cj-home` layout on Linux: a symlinked parent, fallback scratch in `/tmp`, both exclusions, and a report at the physical path. It checks that this exits 0 with `report-state=ok`. An emptied report must give exactly the Mac record plus `report-state=empty report-bytes=0 report-final=empty`. A report python3 cannot read must give `unreadable-EACCES` while the shell sees it as `nonempty` (skipped as root). On HEAD, case 23 already passes the layout and the Mac-record checks and fails only on the new fields. The Swift shard list and comment now include case 23 (`CodingSkillTests.swift`). The case stub moved to `Tests/Scripts/code-job-stub.sh` to keep the suite under 500 lines; its content is unchanged apart from two new modes. `test_macsmoke2` adds `test_mac_fallback_record_is_reproduced_and_located`: a symlinked TMPDIR with stdout `DONE` passes with a 44-byte report at every step, and `emptied-report` is INCONCLUSIVE `code-job-exit-65-report-empty` in all three layouts, with `unexpected=none`.

**Validation (Linux, no real Codex, no provider calls, no commits, Hermes untouched).**
- shellcheck: the smoke script and its three embedded scripts (probe, shim, report-state) are clean with the existing `SC1007,SC2010,SC2012,SC2015,SC2154` exclusions. The new `code-job-stub.sh` is clean. code-job and the suite report the same codes and counts as HEAD (SC1007×17, SC2009×2, SC2012×5, SC2015×2, SC2086×3, SC2317×9).
- `dash -n`, `bash -n` and `bash --posix -n` pass for the smoke script, the embedded scripts, code-job, the suite and the stub. `py_compile` passes. `completion-contract.py` gives identical states and exit codes on Python 3.9.25, 3.12.3 and 3.14.4 (missing, empty, ok, unchanged, unreadable file, directory, unsearchable parent). `git diff --check` passes.
- Code-job shell suite, run from the repo root: **23 passed, 0 failed** under `/bin/sh`, `/bin/dash` and `/bin/bash`. A first run with cwd `/tmp` failed case 12 (75 expected, 77 got) on HEAD as well. The cause is a stray empty `/tmp/.git` on this box (dated 2026-10-19 11:48, not created by this pass, left in place): `--capture-git` refuses it, and case 12 calls code-job without `--dir`.
- `test_macsmoke2`: **10/10 OK** (99 s).
- `PYTHONPATH=sim python3 -B -m unittest discover -s sim -v`: **370 tests OK, 7 skipped** (233 s).
- `python3 -B -m unittest discover -s scripts -p 'test_*.py'`: 56 tests, **1 error**: `test_grokbot_server…test_safe_storage_vector_from_openssl`. It is unrelated, and the macsmoke3 baseline already had the CommonCrypto error.
- Leftovers: no `code-job.*` or `macsmoke1*` entries in `/tmp`, `/dev/shm` or `~`. Diagnostic files from this pass were removed.

**Not run or not changed.** Swift is not built or run here, so the shard edit is unexecuted. Skill versions are **not bumped** (still 1.3.9). Installed boxes keep the old `completion-contract.py` and `code-job` until a bump ships them, though the smoke copies code-job from this checkout, so the Mac run uses the new one. Nothing here exercises Seatbelt, `/private/tmp`, `/private/var`, macOS `ls -O@e`, or bash 3.2.

**Still needs the Mac:** one run of the unchanged command, then read the `report timeline` lines of `cj-home` and `cj-sibling` against the table above:

```sh
cd /tmp/qm6 && sh sim/mac-codex-tmp-smoke.sh
```


## macsmoke5 (6d1c346 + uncommitted)

**Cause / limit of the evidence.** `mac-smoke4-6d1c346.log` proves the fallback reports are empty at CLI exit, before verification. Source inspection disproves launcher pre-creation: baseline only reads the report; the probe creates it, and Codex subsequently attempts replacement. Mode 600 follows `umask 077`; the provenance xattr does not identify the writer or denial. Old `WROTE` means `printf > file` returned zero, without readback. The failed replacement could have emptied a successfully written report, but there is no intermediate byte count or syscall trace to prove that mechanism. This is a harness ambiguity around an unnecessary second write in a Mac layout with observed failures, **not a demonstrated launcher pre-creation bug or proof that fallback reports are impossible**.

**Fix.** The probe compares exact persisted bytes, including the newline, before `WROTE`; its prompt tells Codex to retain that report. code-job warns before launch on Darwin when fallback exclusions overlap the physical workdir (`macos-excluded-tmp-workspace`), suggests HOME/workdir outside temporary roots, and records a specific failure status if the report fails. Both exclusions and completion requirements remain. A completed CLI with an invalid report yields **`REPORT_FAILURE`, exit 1**, with named details such as `cj-home:fallback-report-empty`; isolation violations still win as FAIL. Unreadable/nonregular baselines fail before launch, record an invalid baseline, and cannot pass later verification. Empty baselines must also be readable.

**Regressions.** `existing-report-denied` permits new files while denying writes to a pre-existing report; `rewrite-denied` writes a verified report, then simulates truncation plus denied replacement. Both fail the fallback jobs while `cj-outside` succeeds. These are hypotheses, not Seatbelt emulation. Further tests cover successful redirects with discarded data, stat/open EACCES (including empty files), unchanged contents after readability returns, invalid baselines, no baseline report creation, and warning-before-launch ordering.

**Validation from the repo root (Linux).** Focused `python3 -B -m unittest sim.test_macsmoke2 sim.test_macsmoke5 -v`: **16/16 pass** (11 smoke, 5 completion). Code-job shell suite: **23/23 each** under sh/dash/bash. All seven shell files (including embedded scripts) pass dash/bash/bash-POSIX syntax and shellcheck with existing exclusions; raw diagnostic codes/counts match HEAD. Python syntax and `git diff --check` pass. `PYTHONPATH=sim python3 -B -m unittest discover -s sim -v`: **376 tests, 8 failure records, 8 skips** (236 s); failures match the recorded macsmoke3 categories: fallback directory creation, Node EPERM, namespace expectations, SIGIO EPERM and four namespaced-signal variants. `python3 -B -m unittest discover -s scripts -p 'test_*.py' -v`: **56 tests, 5 errors** (four denied loopback fixtures, unavailable CommonCrypto). Neither full suite is green here. An initial concurrent smoke/shell run invalidated cleanup assertions by counting the other suite's active directories; the isolated rerun above passed. Diagnostic logs and disposable fixtures were removed.

**Still needs the Mac.** The exact denied syscall, whether retaining the probe report resolves both fallback runs, Seatbelt, physical Mac aliases and bash 3.2 remain unverified. No Hermes changes, commits, outbound messages or real Codex/provider calls here. Run:

```sh
cd /tmp/qm6 && sh sim/mac-codex-tmp-smoke.sh
```

## mactest1 (e60dc3d + uncommitted)

**Symptom.** In the MacBook's full Python run (`/usr/bin/python3` 3.9.6, macOS 26.6.2, `/tmp/qm6`), all 14 `SmokeStubTests` records failed on the same line: `['Library'] != [] : outside dir left in HOME`. Every other assertion before it passed, including the empty `$TMPDIR`, so the smoke had already removed its own dirs.

**Cause: a harness artifact, not a smoke defect.** Each test gives the smoke a fresh, empty fake HOME. The smoke writes into HOME in only one place: `$HOME/macsmoke1.XXXXXX` for `cj-outside`. Every code-job run gets its own `HOME=$H` inside a disposable dir. The only things that see the test's fake HOME are the smoke's top-level helper programs: the `python3 -c` calls in `hashf`, `cap`, `report-state`, the nonce and the version, plus `date`, `mktemp`, `ls` and `sed`. Xcode's `python3` keeps stdlib bytecode under `~/Library/Caches/com.apple.python` (its `sys.pycache_prefix`). In a fresh HOME it therefore creates `~/Library` on the first `import`. In a real run HOME is the user's home, which already has `~/Library`, so nothing new appears. This is inferred from Apple's Python layout and the smoke's source. It has **not** been confirmed on the Mac. The MacBook command below prints `sys.pycache_prefix` to check it. One thing is still unexplained: the earlier focused Mac run (`test_macsmoke5` + `test_macsmoke2`) passed 16/16. The most likely difference is the shell environment: a `python3` on PATH that was not Xcode's (the smoke uses the PATH `python3`, not `/usr/bin/python3`), or `PYTHONDONTWRITEBYTECODE` set. Both stop the bytecode writes. No test module changes the environment at import time or leaks it between tests; I checked `os.environ` writes in sim, scripts, Resources and Tests.

**Change (`sim/test_macsmoke2.py` only; smoke, stub, launcher and Hermes untouched).** `run_smoke` now accepts a leftover `HOME/Library` only when all of these hold:
- the platform is Darwin;
- the entry is named exactly `Library`, is a real directory and is not a symlink;
- everything in it is under `Library/Caches` or `Library/Preferences`;
- every entry is a plain directory or regular file (no symlinks);
- no name matches a smoke artifact (`smoke`, `code-job`, `sentinel`, `codex`, `hermes`, `swarmhub`, `git-trust`, `REPORT.txt`, `msk2`, `new-file`);
- no file's bytes contain a fixture path (the given and physical shm, HOME and TMPDIR) or `macsmoke`/`code-job`.

Any violation fails with `smoke files in HOME/Library` and lists the offending paths, so a future Mac failure names its cause. Every other HOME entry, including `macsmoke1.*` next to `Library`, still fails `outside dir left in HOME`. On Linux nothing is tolerated.

**Regressions (`OsLibraryTests`, Linux-runnable; the Darwin flag is patched).**
- `test_os_library_is_tolerated_only_on_darwin`: a wrapper creates an Xcode-shaped `Library/Caches/com.apple.python/.../hashlib.cpython-39.pyc` and a `Library/Preferences` plist, then runs the real stub smoke. It passes as Darwin and fails `outside dir left in HOME` as non-Darwin.
- `test_smoke_leaks_beside_or_inside_os_library_still_fail`: with the OS Library present, three leaks still fail: `$HOME/macsmoke1.leak` next to it, `Library/Caches/macsmoke1.leak`, and a cache file containing `$TMPDIR`.
- `test_library_classifier_names_each_smoke_trace`: a dir outside Caches/Preferences, smoke-named file and dir, fixture-path contents, a symlink, and `Library` itself as a symlink are each reported.

Mutation check: each of four weakenings fails at least one of these tests. The four are dropping the Darwin condition, skipping the Library classification, ignoring file contents, and ignoring names.

**What ran here (Linux, Python 3.12, repo root).**
- Focused `python3 -B -m unittest -v sim.test_macsmoke2 sim.test_macsmoke5 sim.test_fixes18 sim.test_darwinkill1`: **61 tests OK, 5 skipped** (the macOS-native `DarwinNativeTests`; 164 s) on a quiet box. `test_macsmoke2` is 11 smoke tests plus the 3 `OsLibraryTests`.
- `PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py' -v`: **406 tests OK, 12 skipped** (300 s).
- `python3 -B -m unittest discover -s scripts -p 'test_*.py' -v`: 56 tests, **1 error**: `test_grokbot_server…test_safe_storage_vector_from_openssl` (no CommonCrypto). This is the known baseline from macsmoke4/5.
- `Tests/Scripts/code-job-test.sh` under `/bin/sh`, `/bin/dash`, `/bin/bash`: **23/23 each**.
- Two focused runs failed only on the global `/tmp` assertion. Another session was running the same suites from the `peer-review` checkout at the time, and its `code-job.*`/`code-job-test.*` dirs showed up in `/tmp`. Those runs do not count. No failure in any run came from the HOME check.

No fixtures, logs or `/tmp` entries were left behind. Nothing was committed or sent, and no real Codex or provider was called. Swift and the Mac were not run.

**MacBook: one command (full Python suite, Xcode `/usr/bin/python3`).** First it prints which `python3` the smoke will use and that interpreter's `pycache_prefix`, which confirms or refutes the cause. It needs a quiet box: the smoke tests assert that `/tmp` gains no `code-job*`/`macsmoke1*` entries, so nothing else may run code-job at the same time.

```sh
cd /tmp/qm6 && command -v python3 && python3 -c 'import sys; print("pycache_prefix:", sys.pycache_prefix)'; PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py' -v; /usr/bin/python3 -B -m unittest discover -s scripts -p 'test_*.py' -v
```

Pass criteria: `test_macsmoke2` is green with no `outside dir left in HOME`. If `smoke files in HOME/Library` appears, its listed paths show what macOS (or the smoke) created outside the tolerated shape. On the Mac, `test_grokbot_server` should not hit the Linux CommonCrypto error.

## mactest2 (41869cc + uncommitted; supersedes the mactest1 tolerance and MacBook command)

**Cross-review findings, checked.** On the mactest1 classifier, `Library/Caches/unexpected.txt` containing `left behind` and an empty `Library/Caches/session` both passed, and so did an unreadable directory: `os.walk` without `onerror` skips scan errors. All three are confirmed by the new regressions, which fail on the mactest1 code (mutation run, 4 failures) and pass now. The mactest1 fixture also had the wrong shape. With a `pycache_prefix`, CPython writes `<prefix>/<source dir>/<stem>.cpython-NN.pyc` and has no `__pycache__` level (checked with `importlib.util.cache_from_source`).

**Cause (inferred for the Mac, reproduced here).** Xcode's `python3` sets `sys.pycache_prefix` to `~/Library/Caches/com.apple.python`. The smoke's top-level helper `python3 -c` calls run with the test's fresh fake HOME, so their first import creates `HOME/Library`. A python3 shim that forces that prefix (`-X pycache_prefix=$HOME/Library/Caches/com.apple.python`, which also overrides `PYTHONPYCACHEPREFIX`) reproduces the Mac failure on Linux exactly: `['Library'] != [] : outside dir left in HOME`.

**Change (`sim/test_macsmoke2.py` only; smoke, stub, launcher, skills and Hermes untouched).**
- Removes the cause: `run_smoke` now sets `PYTHONDONTWRITEBYTECODE=1`, so no python3 the smoke starts writes bytecode under any prefix. It also points `PYTHONPYCACHEPREFIX` into the fixture dir as a second guard. The strict "HOME must be empty" assertion stays, and on Linux nothing is tolerated. Without the env var, the shim test fails (mutation run).
- Darwin-only fallback, in case macOS still creates a Library (e.g. CFPreferences). This replaces the denylist with an allowlist. `os_library_problems` accepts only two shapes:
  - `Caches/com.apple.python/<dir>/<stem>.cpython-NN[.opt-N].pyc`, where `/<dir>/<stem>.py` is a real regular file outside every fixture dir and the repo, and the file has a CPython bytecode header;
  - `Preferences/com.apple.*.plist` directly in `Preferences`, with a plist header.
- Anything else fails, with the path named: an innocently named file, an empty directory (including an empty `Library`), a symlink, a special file, bytes containing a fixture path, and any walk, stat or read error (`os.walk(onerror=…)`, `lstat` and read in `try`).

**Regressions (`OsLibraryTests`, 5 tests, Linux-runnable; Darwin is patched where needed).**
- `test_xcode_like_python3_leaves_home_empty`: under the forcing shim, the strict non-Darwin path stays empty and the result is PASS. A shim that also drops `PYTHONDONTWRITEBYTECODE` reproduces the Mac failure.
- `test_os_library_is_tolerated_only_on_darwin`: a real python3-written Library (not a hand-made one) passes as Darwin and fails as non-Darwin.
- `test_smoke_leaks_beside_or_inside_os_library_still_fail`: five cases fail through the real stub smoke: `$HOME/macsmoke1.leak`, `Caches/macsmoke1.leak`, `$TMPDIR` appended to the real `.pyc` files, `Caches/unexpected.txt` "left behind", and an empty `Caches/session`.
- `test_library_classifier_names_each_smoke_trace`: 13 named problems, plus an empty Library and Library as a symlink.
- `test_unreadable_library_fails_closed`: a mode-0 dir, a mode-0 plist, and a simulated `scandir` `PermissionError` on Library itself.

**What ran here (Linux, Python 3.12, quiet box: no other code-job runs, no `/tmp/code-job*`/`macsmoke1*` before or after).**
- `PYTHONPATH=sim python3 -B -m unittest -v sim.test_macsmoke2 sim.test_macsmoke5 sim.test_fixes18 sim.test_darwinkill1 sim.test_darwinkill2`: **77 OK, 5 skipped** (the macOS-native `DarwinNativeTests`).
- `PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py' -v`: **422 OK, 12 skipped**.
- `Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job` run by `/bin/sh`, `/bin/dash` and `/bin/bash`: **23 passed, 0 failed** each. The script's label reads "under /bin/sh" each time because `$SH` is the shell it runs code-job with, not the outer shell.
- After wrapping two long lines: `sim.test_macsmoke2` alone, 16 OK.

Not run: the Mac, Swift, the `scripts/` suite. No temp files left; nothing committed or sent; no real Codex or provider.

**MacBook: one command.** It runs from `/tmp/qm6` on a quiet box, since the smoke tests assert that `/tmp` gains no `code-job*`/`macsmoke1*` entries. For both the PATH `python3` and `/usr/bin/python3`, it prints `sys.pycache_prefix` and what `import json` leaves in a fresh HOME with and without `PYTHONDONTWRITEBYTECODE=1`. That confirms or refutes the cause and the fix. Then it runs the full sim suite.

```sh
cd /tmp/qm6 && for p in "$(command -v python3)" /usr/bin/python3; do h=$(mktemp -d "$HOME/mactest2.XXXXXX") && echo "$p prefix=$("$p" -c 'import sys; print(sys.pycache_prefix)')" && HOME=$h PYTHONDONTWRITEBYTECODE=1 "$p" -c 'import json' && echo "  with env: [$(ls -A "$h")]" && HOME=$h "$p" -c 'import json' && echo "  without:  [$(ls -A "$h")]"; rm -rf "$h"; done; PYTHONPATH=sim /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py' -v
```

Pass criteria:
- Expected probe output: prefix `…/Library/Caches/com.apple.python`, `with env: []` and `without: [Library]`, which confirms the cause and that the env var stops it.
- The suite is green, and `test_macsmoke2` shows no `outside dir left in HOME`.
- If `smoke files in HOME/Library` appears, macOS made something outside the two allowed shapes, and the listed paths name it. Do not widen the allowlist without seeing them.
- If `without:` is also `[]`, the bytecode cause is refuted for that interpreter.


## mactest3 (e63dcf1 + uncommitted)

Both review bypasses were reproduced before editing: malformed XML, CRLF garbage bytecode, and an actual external `.py` symlink into this repository each returned `None` (allowed).

`sim/test_macsmoke2.py` now parses XML/binary plists with `plistlib` and checks raw bytes plus decoded keys/values for fixture/repository paths, including binary UTF-16 and XML-escaped values. Shared/cyclic containers cannot hang the scan. Bytecode requires this interpreter's magic, a complete 16-byte header with valid flags, and exactly one unmarshalled code object with no trailing bytes. Its `co_filename` must exactly match the source path implied by the prefix layout; the full source path resolves strictly and must be a regular file outside the fixture and repository, including through symlinks. Parse/resolve failures reject the file. The old header-only plist fixture is now valid XML. Linux still tolerates nothing in HOME.

Four Linux-runnable tests cover malformed files, repository/fixture source symlinks, valid plist/header forms, encoded paths, malformed marshal payloads, mismatched filenames, dangling links and symlink loops. Mutation check: restored only `os_library_file` from `git show e63dcf1:sim/test_macsmoke2.py` in memory and ran the two review regressions. All six expected failure records appeared (three malformed plists, garbage bytecode, two source symlinks); the same tests pass after the fix. No baseline files were overwritten.

Raw regression/mutation output:

```text
Ran 2 tests in 0.003s
FAILED (failures=6)
Mutation check: e63dcf1 classifier restored in memory; expected six failure records confirmed.
test_bytecode_header_payload_and_source_mapping (sim.test_macsmoke2.LibraryFileValidationTests.test_bytecode_header_payload_and_source_mapping) ... ok
test_external_source_symlinks_into_repo_or_fixture_are_rejected (sim.test_macsmoke2.LibraryFileValidationTests.test_external_source_symlinks_into_repo_or_fixture_are_rejected) ... ok
test_malformed_plist_and_crlf_garbage_are_rejected (sim.test_macsmoke2.LibraryFileValidationTests.test_malformed_plist_and_crlf_garbage_are_rejected) ... ok
test_plist_formats_and_encoded_fixture_paths (sim.test_macsmoke2.LibraryFileValidationTests.test_plist_formats_and_encoded_fixture_paths) ... ok
Ran 4 tests in 0.005s
OK
```

Validation from the repository root, Linux/Python 3.12, with `PYTHONDONTWRITEBYTECODE=1`; suites run sequentially:

```sh
PYTHONPATH=sim python3 -B -m unittest -v sim.test_macsmoke2 sim.test_macsmoke5 sim.test_fixes18 sim.test_darwinkill1 sim.test_darwinkill2
PYTHONPATH=sim python3 -B -m unittest discover -s sim -p 'test_*.py' -v
for shell in sh dash bash; do CODE_JOB_SH=/bin/$shell /bin/$shell Tests/Scripts/code-job-test.sh Resources/Skills/swarmhub-coding/scripts/code-job; done
```

Focused run:

```text
Ran 81 tests in 283.483s
OK (skipped=5)
```

Full discovery is **not green**. The eight failure records are in unchanged fixes6/7/8 tests: fallback mode denies creating `build`, Node reports `spawnSync /bin/sh EPERM`, namespace expectations see fallback mode, and the SIGIO probe's socket send gets EPERM. These match the sandbox-related categories already recorded under macsmoke5 above. Every `test_macsmoke2` record passed; no host-global `/tmp` interference required a rerun.

Raw full-suite failures:

```text
FAIL: test_workspace_remains_writable_and_outside_stays_closed (test_fixes6.GitMetadataEscapeTests.test_workspace_remains_writable_and_outside_stays_closed)
FAIL: test_node_child_processes_work (test_fixes6.OrdinaryVerifierTests.test_node_child_processes_work)
FAIL: test_mode_is_recorded_by_the_launcher_for_the_job_result (test_fixes7.LimitedModeSuitesTests.test_mode_is_recorded_by_the_launcher_for_the_job_result)
FAIL: test_a_sigio_owner_cannot_name_another_process (test_fixes8.LimitedModeProcessIsolationTests.test_a_sigio_owner_cannot_name_another_process)
FAIL: test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode (test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode) [rt_sigqueueinfo]
FAIL: test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode (test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode) [rt_tgsigqueueinfo]
FAIL: test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode (test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode) [kill]
FAIL: test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode (test_fixes8.NamespacedModeSignalTests.test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode) [tgkill]
Ran 426 tests in 406.714s
FAILED (failures=8, skipped=13)
```

Raw shell results (outer shell and `CODE_JOB_SH` both set to the named shell):

```text
pass: fallback through a symlinked parent: the physical report counts; an empty or unreadable one is 65, named
code-job tests under /bin/sh: 23 passed, 0 failed
pass: fallback through a symlinked parent: the physical report counts; an empty or unreadable one is 65, named
code-job tests under /bin/dash: 23 passed, 0 failed
pass: fallback through a symlinked parent: the physical report counts; an empty or unreadable one is 65, named
code-job tests under /bin/bash: 23 passed, 0 failed
```

Python syntax and `git diff --check` pass. No temporary fixtures or diagnostic logs remain. The two untracked fixes8 briefs are untouched. Nothing committed, no Hermes changes, no outbound messages or real Codex/provider calls. Native macOS behavior remains untested here.
