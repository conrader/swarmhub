# Swarm Hub real-app QA harness

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
