# Gaps4 result

2026-10-19. P01/P04 harness changes are ready for a plain-shell live pass 8; live closure is untested.
No Hermes/config/plugin changes, source auth/config writes, real outbound sends, provisioning, deployments,
gateway restarts or worktree commits. All outbound remains FAKE.

- **P01:** the disposable repo uses environment-addressed `QA-git-store` within the writable workspace,
  without a `.git` entry. The CLI keeps workspace-write/approval-never. The first real job deliberately
  leaves tested code uncommitted. Its actual completion reaches QA-Jarvis, whose model reply must relay it.
  QA-Swarmhub reviews the actual report and source diff; its requested action commits the actual code and
  review, changes HEAD, and compiles/runs two arithmetic tests. A separate receiving turn inspects that
  receipt and selects multiply or subtract; only then is the next CLI job submitted. That CLI must itself
  produce a new commit, fresh report and passing compilation/tests. There is no preloaded next-job queue.
- **P04:** a real CLI negative control is asked to exit zero without writing a report. The scenario requires
  actual CLI exit 0 plus rejected fresh-output evidence; an unexpectedly valid report fails the control.
  Jarvis must issue a correction, and Swarmhub must request its explicit-model/high-effort replacement,
  releasing the failed queue hold. The corrected completion is acknowledged without a success claim;
  independent checks hash the fresh report and compile/test the actual code before a separate success turn.
- **Evidence/boundary:** `QA-action-chains.json`, receiving SSE traces, actual command receipts and build
  JSON record each step. These are bounded model-requested local actions executed by the external harness,
  not native Hermes tool calls or installed plugin autonomy. Unknown actions, `NO_REPLY`, stale bindings,
  failed streams/builds and consumed actions fail closed. Failure of either chain is recorded independently;
  the runner returns nonzero for failed rows. The Hermes cap remains 24 turns; up to six real coding CLI calls
  are additional. Ten new offline tests cover the chains and refusals with synthetic model/job boundaries
  and actual disposable git commits, compilation and arithmetic tests.

Validation: `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`: **139 run, 138 passed,
0 failed, 1 skipped** (loopback HTTP test). Both requested socket suites were attempted under sh and dash;
both exit **77**, **0 cases run**, because this sandbox denies opening a loopback socket. Logs are in
`sim/results/gaps4/`. `git diff --check`: passed.

Run exactly once from the **plain box Bash shell**, with a fresh `sim/results/live-8` directory:

```bash
cd /home/box/work/swarmhub/wt-peer
set -a
source /workspace/ermes/qa-swarmhub/hermes-endpoint.env
set +a
PATH="/home/box/.npm-global/bin:$PATH" \
QA_CLI_EXECUTION_PATH='plain box shell; unchanged code-job workspace-write' \
python3 -B sim/live_managed.py \
  --usage-db /workspace/ermes/qa-swarmhub/home/state.db \
  --output sim/results/live-8
```

Untested: live pass 8, real model compliance with the action protocol/empty-job request, and actual nested-CLI
commits in the new layout. Pass 7 directly records `.git/index.lock` read-only failures; merely launching the
old layout from a plain shell does not establish a fix. Ordinary subprocess git/index writes in the new layout
pass offline tests. A credential-free installed-CLI `sandbox linux --help` probe with a disposable HOME/CODEX_HOME
still fails before execution with “app-server socket directory must be a user-owned directory with mode 0700”;
it made no provider/Hermes call. Nested sandbox acceptance therefore remains for the plain-shell replay.
Native Swift/UI, installed-plugin discovery and real external operations remain outside this validation.

Results: 138 passed / 0 failed / 1 skipped; socket suites: 0 cases / 2 skipped; diff check passed; live not run.
