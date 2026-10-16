# Swarm Hub real-app QA harness

Run locally on Linux, without dependencies, Swift, a backend or network access:

```sh
python3 -B sim/run.py
```

This runs the harness safety tests, reads source evidence probes, and writes `sim/results/latest/results.json` and `RESULTS.md`. Exit **2 means blocked/incomplete**, **1 means a harness failure or observed bug**, and **0 means all selected bounded variants passed**. It never represents whole-plan or Grok parity acceptance. Use a fresh `--output` directory on subsequent runs; existing results are preserved.

The final recorded run is in [results/final-20261016/RESULTS.md](results/final-20261016/RESULTS.md). `scenarios.json` retains the original QA scripts and source comparison ratings for A01–A18, F01–F25, B01–B10 and U01–U12. It contains 27 bounded recipes; 38 scenarios currently have no safe adapter. The 27 are **client recipes awaiting the proposed hook**, not working native UI tests on this checkout. Source probes are text checks, not Swift tests. The Grok comparison is the supplied reference, not a new Grok test.

No MacBook was contacted. No fake Hermes/OpenClaw backend, arbitrary model-driven action executor, OAuth flow, or app change is supplied. `RecordingSandbox` is only an outbound sink; its receipts always say `simulated: true, delivered: false`. It is tested here but **not wired into the real app or Hermes**. App-wide and server-side tool interception is required before any live recipe can run.

The hook is [design only](DEBUG-HOOK-DESIGN.md). This checkout has no matching endpoint or debug test-mode implementation. Consequently the live command below cannot run against the unmodified app and will fail closed. It is a client interface for a later, separately reviewed implementation; nobody should run it on the user's Mac as part of this task.

Once that implementation exists, the user can run locally on the Mac (no remote-host option exists):

```sh
python3 -B sim/run.py --mode live --scenario F03 \
  --token-file /private/tmp/swarmhub-qa-token \
  --output sim/results/mac-first-chat
```

The app must already be running in its explicit debug QA mode with a separate QA data store and real QA Hermes profiles. The token file must be user-owned, not a symlink, mode 0600, with at least 43 base64url characters. It is never passed in process arguments or logged. The default hook port is 49371 on numeric `127.0.0.1`; `--port` can select another local unprivileged port. There is no URL input, proxy, redirect, SSH, AppleScript launch, or automatic Mac job submission.

Every operation renews the sandbox attestation. A safety failure stops the suite. Uncertain mutation acknowledgement never causes a retry. Cleanup is attempted after every scope creation attempt, including failed begin; cleanup uncertainty stops further scenarios and relies on the separately required server watchdog. There are no per-action human prompts. The allowlist supplies authorization only for the fixed QA actions described in [SAFE-ACTIONS.md](SAFE-ACTIONS.md).

The runner grants at most 3 turns/120 seconds per scenario, 24 requested turn-producing actions/900 seconds per suite, and 120 actions. The hook must also enforce the aggregate actual remote-turn budget, including automation, helper and review turns; the client cannot constrain backend activity alone. These are workload limits, not a dollar billing cap. All work needs a server expiry so a runner crash cannot leave schedules enabled.

Read [REPORT-FORMAT.md](REPORT-FORMAT.md) before interpreting results. A successful bounded variant still leaves the catalog's `uncovered` branches untested. Fault windows, cold restart, native accessibility, mobile, actual overnight timing, real detached jobs and cross-provider behavior remain blocked. The recipes never invent provider faults or claim a recording-only coding tool validates real detached job supervision.

Standalone safety tests:

```sh
python3 -B -m unittest discover -s sim -p 'test_*.py' -v
```

The unit tests use synthetic records and an in-process hook-boundary spy solely to test refusals, cleanup and oracle logic. They never open an app/Hermes server or supply app success evidence. `scenarios.json`, the allowlist and protocol version should be reviewed together when adding coverage.
