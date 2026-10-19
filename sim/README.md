# Swarm Hub real-app QA harness

`python3 -B -m unittest discover -s sim -p 'test_*.py'` runs the offline suite. The gap regressions cover completion
evidence, managed webhooks, private key intake, provisioner approval and CLI detection. HTTP handler validation also
runs without sockets; the separate loopback test explicitly skips when the sandbox denies sockets.

`live_managed.py --usage-db <QA state.db> --output <fresh QA evidence directory>` detects an authenticated `codex` on
PATH using `codex login status` against disposable auth/config copies. Jobs use another private `CODEX_HOME`
with regular 0600 copies, 0700 runtime/temp directories, an isolated QA HOME and throwaway repository.
Source auth/config contents and metadata must stay unchanged. Reports stay inside the CLI workspace.
Pass 8 uses `QA-git-store` inside that workspace, addressed by `GIT_DIR`/`GIT_WORK_TREE`, with no `.git` entry.
This avoids depending on writes to Codex's protected `.git` path; workspace-write and approval-never stay enabled.
P01's first job deliberately leaves its tested changes for the ordering bot to review and commit. After the
actual commit/build receipt, a separate receiving turn chooses multiply or subtract and launches that real CLI job,
which must itself commit. P04 requests a real exit-zero empty job, requires a Jarvis correction and a receiving
bot's explicit-model/high-effort replacement, then independently hashes the fresh report and compiles/tests the code
before the success-report turn. A negative control that writes a valid report fails the scenario honestly.
Both chains use a bounded reply-to-action bridge in the harness, not installed Hermes tools: only armed receiving
turns may request the fixed local operations. `NO_REPLY`, mismatched evidence or failed checks cannot advance a chain.
`QA-action-chains.json`, command traces and build receipts retain each step. One failed chain is recorded and
stopped without preventing the other from being exercised. P01/P04 use four real CLI calls;
P07 adds a cancellation and replacement (six CLI invocations beyond the unchanged 24-turn Hermes cap).
Without an authenticated CLI the chains fail as untested. The runner never installs or
replaces a CLI. All outbound remains FAKE. See [GAPS-REPORT.md](../GAPS-REPORT.md) for verification boundaries.

`live_cli_probe.py --output <fresh evidence directory> --execution-path <description>` repeats the gaps3
real-CLI acceptance probe with source auth/config assertions. Use an available plain box shell for coding
acceptance when the nested sandbox has the known bubblewrap socket-directory error. The probe preserves
the unchanged runner's workspace-write sandbox and records failure honestly when no plain shell is available.

Peer delivery regressions run without sockets or providers:
`python3 -B -m unittest discover -s sim -p 'test_peer_runtime.py' -v`.
These execute the bundled shell scripts with a local curl stub and exercise the
held-inbox plugin callbacks and durable coding-completion outbox. The LIVE3 runner
now explicitly uses `--priority` for action asks and checks that a held FYI starts
no upstream turn. It marks next-turn held delivery blocked because its temporary
HOME and namespace bridge do not install the peer plugin on the remote gateway.
See [PEER-REPORT.md](../PEER-REPORT.md) for installation and validation limits.

For the ten real team interaction patterns recorded in `grokbot-observed.md`, use
`live_observed.py --usage-db /workspace/ermes/qa-swarmhub/home/state.db --output
sim/results/QA-live3-new` after sourcing the QA endpoint env as below. It runs the
unchanged bundled `bot-msg` through a temporary namespace-only loopback bridge to
real Hermes sessions; the runner initiates sends. It does not provision backend
agents or certify native app, coding-job, approval or overnight behavior. Exit 2
means coverage remains blocked. This consumes shared model quota; reserve calls
before another run. See [LIVE-REPORT-3.md](../LIVE-REPORT-3.md) for the observed
patterns, precise grades, bridge boundaries, accounting and verified cleanup.

For generated-output testing on the working isolated Hermes, use the focused
LIVE2 runner. Its core and edge sets cover different protocol/session variants;
they do not run the native app. This consumes shared model quota.

```sh
set -a
source /workspace/ermes/qa-swarmhub/hermes-endpoint.env
set +a
python3 -B sim/live_behavior.py --usage-db /workspace/ermes/qa-swarmhub/home/state.db --output sim/results/QA-live2-core-new
python3 -B sim/live_behavior.py --extended --usage-db /workspace/ermes/qa-swarmhub/home/state.db --output sim/results/QA-live2-edges-new
```

Each invocation requires a fresh output directory. Enabled toolsets must be exactly
todo/clarify. The optional SQLite argument records usage read-only for exact owned
QA IDs before deletion; it never queries unrelated sessions. Counters can omit
interrupted/rejected attempts, so they are not a billing total. The runner limits
requests and turn POSTs, refuses uncertain chat retries, and cleans registered
sessions after checking their run status. A requested tool-call bound is also
included in prompts; it is not a server-enforced quota cap. Exit 1 means an assertion
failed. App-only branches remain blocked regardless of that exit status.

See [LIVE-REPORT-2.md](../LIVE-REPORT-2.md) for per-scenario scope, 27 observed
provider attempts, upstream findings and the corrected assertion audit. Preserve
the original captures: [adjudicated results](results/live-2/adjudicated-results.json)
explain three harness assertion corrections made without re-running model turns.

For the explicitly provisioned throwaway Linux Hermes, a separate direct transport
suite exercises the real HTTP APIs without claiming macOS app QA coverage:

```sh
set -a
source /workspace/ermes/qa-swarmhub/hermes-endpoint.env
set +a
python3 -B sim/live_transport.py --output sim/results/QA-live-new-run
```

Use a fresh output directory. This suite accepts only numeric IPv4 HTTP loopback,
never prints the key, and uses fixed `[QA-TEST]` prompts and `QA-` session names.
It checks native and legacy streams, authentication, malformed requests,
concurrency, client disconnects/read deadlines, reconnect and owned-session cleanup.
Requests and turn creation are bounded; no server configuration or tools are changed.
It retains raw responses and source-derived Swift projections separately: Swift
and the app are **not executed** on Linux. Exit 1 means an observed server bug or
source-confirmed compatibility failure; exit 2 means remaining blocked checks.
See [LIVE-REPORT-1.md](../LIVE-REPORT-1.md) and
[live evidence](results/live-1/RESULTS.md). Existing app QA attestation gates below
remain required for real app scenarios.
That older suite expects the pass-1 missing-provider failure and retains historical
source projections; use LIVE2 for the current working-model behavior.

Run locally on Linux, without dependencies, Swift, a backend or network access:

```sh
python3 -B sim/run.py
```

This runs the harness safety tests, reads source evidence probes, and writes `sim/results/latest/results.json` and `RESULTS.md`. Exit **2 means blocked/incomplete**, **1 means a harness failure or observed bug**, and **0 means all selected bounded variants passed**. It never represents whole-plan or Grok parity acceptance. Use a fresh `--output` directory on subsequent runs; existing results are preserved.

The catalog retains 65 scenarios and 27 bounded recipes. The historical simulation-only results are in [results/final-20261016/RESULTS.md](results/final-20261016/RESULTS.md); they are not results for QA-mode changes.

The DEBUG app now supplies an isolated local controller, QA workspace, recording sink, and real-Hermes transport boundary. See [QA-MODE.md](QA-MODE.md) for launch instructions, the implemented action subset, checkpoint hooks and the exact required server contract. **The real Hermes gateway/tool sandbox/watchdog is not part of this repository and remains a live blocker.** The app refuses an ordinary or unattested Hermes server before creating a chat. No fake Hermes backend or real outbound connector is supplied.

On a local Mac, after provisioning that real isolated gateway:

```sh
# Set the QA-only gateway URL/token in the launch environment.
./scripts/run-qa.sh
python3 -B sim/run.py --mode live --scenario F03 \
  --endpoint-file /absolute/path/printed/by/app/endpoint.json \
  --output sim/results/mac-first-chat
```

Each launch chooses a numeric IPv4 loopback port and writes an owner-only descriptor/token in its fresh private data directory. `--endpoint-file` loads both safely; manual `--port`/`--token-file` remain supported. There is no remote host, proxy, redirect, SSH, AppleScript launch or automatic Mac job submission. The original [hook design](DEBUG-HOOK-DESIGN.md) remains a reference for wider capabilities that are not implemented.

Every operation renews the sandbox attestation. A safety failure stops the suite. Uncertain mutation acknowledgement never causes a retry. Cleanup is attempted after every scope creation attempt, including failed begin; cleanup uncertainty stops further scenarios and relies on the separately required server watchdog. There are no per-action human prompts. The allowlist supplies authorization only for the fixed QA actions described in [SAFE-ACTIONS.md](SAFE-ACTIONS.md).

The runner grants at most 3 turns/120 seconds per scenario, 24 requested turn-producing actions/900 seconds per suite, and 120 actions. The hook must also enforce the aggregate actual remote-turn budget, including automation, helper and review turns; the client cannot constrain backend activity alone. These are workload limits, not a dollar billing cap. All work needs a server expiry so a runner crash cannot leave schedules enabled.

Read [REPORT-FORMAT.md](REPORT-FORMAT.md) before interpreting results. A successful bounded variant still leaves the catalog's `uncovered` branches untested. Fault windows, cold restart, native accessibility, mobile, actual overnight timing, real detached jobs and cross-provider behavior remain blocked. The recipes never invent provider faults or claim a recording-only coding tool validates real detached job supervision.

Standalone safety tests:

```sh
python3 -B -m unittest discover -s sim -p 'test_*.py' -v
```

The unit tests use synthetic records and an in-process hook-boundary spy solely to test refusals, cleanup and oracle logic. They never open an app/Hermes server or supply app success evidence. `scenarios.json`, the allowlist and protocol version should be reviewed together when adding coverage.
