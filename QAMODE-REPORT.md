# Isolated QA mode implementation report

Worktree: `/home/box/work/swarmhub/wt-qamode`; branch `swarmhub/qa-mode`; baseline `45547b35f8f4afbd996a42872d5e7ad353e1bf5b`. Implementation/validation: 2026-10-16 UTC / 2026-10-17 Europe/Warsaw. Read the supplied QA-mode brief, SIM-REPORT.md, sim harness/design/policy and `/home/box/work/swarmhub/wt-qa/QA-PLAN.md`. No commits or Git writes, remote Mac execution, backend connection, real account/secret discovery, or outbound deliveries were performed.

## Outcome and remaining blocker

Implemented the **app-side** DEBUG-only QA launch path, closed local controller, recording sink, isolation guards, real native Hermes transport boundary, Swift unit tests, and runner integration. The feature is off by default and its activation/types/listener/routes are enclosed in `#if DEBUG`. Invalid QA launch configuration exits before normal app startup.

**This is not an operational end-to-end real-Hermes sandbox.** Hermes's server/agent runtime is not in this repository. Its exhaustive tool replacement, OS egress/filesystem isolation, scope adapter and independent watchdog still need implementation/deployment against the real runtime. This change specifies and requires that gateway; it does not invent one, accept ordinary Hermes capability flags as proof, or replace real Hermes with a fake backend. The app refuses all live scope creation without the full safety attestation. Consequently the brief's server-side outbound/expiry requirement and live acceptance remain incomplete.

| Brief requirement | Delivered source behavior / limit |
| --- | --- |
| DEBUG test mode and visible tags | `SWARMHUB_QA_MODE=1` enters a dedicated QA scene before headless/setup/sample/integration handling. Persistent banner, QA resource names and per-message badges; message metadata records `test_mode=true`, marker and originating IDs. Native requests carry structured QA scope/run/scenario/action/lease headers; control JSON carries boolean `test_mode:true`. Gateway must persist/propagate these through real Hermes, cron and bots. Release exclusion is source-guarded, not binary-verified here. |
| All outbound tools record-only; fail closed | Swift recorder implements the sim sink's closed synthetic schema, matching payload SHA-256, duplicate persistence and `simulated:true, delivered:false` receipts. Unknown/real payloads refuse without logging their contents. Production Composio execution is refused, other app HTTP is denied except authenticated scoped QA-gateway traffic; external opens, live keys and voice process entrypoints refuse. No production connector is constructed by the QA chat path. Real Hermes must independently replace/deny every server tool/escape path and route attempts to this recorder. That server implementation is absent, so the safety gate remains closed. |
| Loopback local control and hard allowlist | Random-port IPv4 `127.0.0.1` listener, rotating 256-bit token, exact Host/auth/method/JSON/route checks, browser Origin refusal, request caps, connection deadline and rate limit. Exact run/scenario/resource ownership, one-use expiring leases, independent compiled prompt/operation validation, action acceptance journals, reentrancy guards and no uncertain replay. Real AppStore send/stop/approval/routine paths are used. Supported subset and protocol are in sim/QA-MODE.md. |
| Isolated app data | Fresh OS-temporary mode-0700 directory on every QA launch; own store/defaults/ledger/caches/evidence and an empty key store. No migration from real app state. All QA scene AppStorage uses its injected defaults; updater/discovery/normal commands/settings are excluded. Private control/evidence files are mode 0600 with exclusive/no-follow creation. |
| Tests, runner and handoff | Eight new Swift Testing tests authored; not run or compiled. Eight Python tests added (seven descriptor tests and one checkpoint-policy test); 41 total Python tests pass. Runner accepts the app's private `--endpoint-file`; offline/live gating and blocked semantics remain intact. This report and launch/protocol documentation added. |

## Files changed

New app sources, all DEBUG-only:

- `Sources/AgentApp/QA/QAMode.swift`: activation, fresh private directory/token files, empty key store, scoped HTTP boundary and redirect refusal.
- `Sources/AgentApp/QA/QAPolicy.swift`: closed operations/prompts, QA names/fields and strict typed safety proof validation, including mandatory connector classes.
- `Sources/AgentApp/QA/QAHTTP.swift`: bounded HTTP parser and token-protected loopback listener.
- `Sources/AgentApp/QA/QARecorder.swift`: durable recording-only sink and payload-free refusals.
- `Sources/AgentApp/QA/QAController.swift`: lease/scope ownership, action journals/budgets, real AppStore actions, evidence/checkpoint/restart-preparation hooks.
- `Sources/AgentApp/QA/QAWorkspace.swift`: visible isolated workspace using actual AppStore messages and the existing MessageView renderer.

Integration changes:

- `Sources/AgentApp/AgentApp.swift`: early QA startup and QA-only scene/defaults; normal scenes retained.
- `Sources/AgentApp/AppIconAppearance.swift`: skips normal preference observation in QA.
- `Sources/AgentApp/TestRunGuard.swift`: QA network/default/key/external-access refusals in existing transport guard entrypoints.
- `Sources/AgentApp/Backends/HermesBackend.swift`: scoped authenticated QA headers, endpoint validation and SSE redirect refusal.
- `Sources/AgentApp/Backends/HermesTimeouts.swift`: QA session redirect guard.
- `Sources/AgentApp/ConnectedApps/ComposioClient.swift`: refuses the production client in QA.
- `Sources/AgentApp/ConnectedApps/CodexVoiceRPC.swift`: refuses voice subprocess launch in QA.
- `Sources/AgentApp/Models/Models.swift`: machine-readable QA message metadata at creation.
- `Sources/AgentApp/Stores/AppStore.swift`: QA-only backend selection, assistant metadata propagation, notification refusal and delta capture callback.
- `Sources/AgentApp/Stores/AppStore+ConnectedApps.swift`: QA store without production provisioning and real Hermes stream path without production app broker.
- `Sources/AgentApp/Stores/AppStore+Turns.swift`: actual delta capture; skips post-turn management/report/review/automation side effects in QA.
- `Sources/AgentApp/Stores/AppUpdater.swift`: updater cannot start in QA.
- `Sources/AgentApp/Views/MessageView.swift`: visible per-message QA badge.

Tests, launch, runner and documentation:

- `Tests/AgentAppTests/QAModeTests.swift`: eight Swift tests for closed policy, strict attestation/inventory drift, HTTP auth/browser/smuggling rejection, transport scope/expiry, sink persistence/refusal/hash compatibility, private-file replacement/symlink refusal, lease replay, and preventing foreign/off-list content from reaching gateway authorization. Boundary proofs are unit-only data, not fake model/backend execution.
- `scripts/build.sh`: DEBUG definition on the debug swiftc fallback; release gets no definition.
- `scripts/run-qa.sh`: local Mac debug-only launcher with read-only source provenance; requires a dedicated QA gateway URL/token.
- `sim/run.py`: secure private endpoint descriptor loading and live CLI integration; legacy port/token options retained.
- `sim/test_qamode.py`: seven descriptor safety tests and one checkpoint-policy safety test.
- `sim/README.md`, `sim/DEBUG-HOOK-DESIGN.md`, `sim/SAFE-ACTIONS.md`: current implementation status and scoped checkpoint policy distinguished from historical design-only results.
- `sim/QA-MODE.md`: exact launch, app API, supported subset, recorder and required real Hermes gateway contract.
- `sim/results/qamode-validation/{results.json,RESULTS.md}` and `sim/results/qamode-final-validation/{results.json,RESULTS.md}`: initial and final offline validation artifacts, preserved separately.
- `QAMODE-REPORT.md`: this handoff.

## How to launch

On the local Mac, first provision the real isolated Hermes QA gateway described in `sim/QA-MODE.md`. It must attest actual isolation and independent expiry, not merely relay native API calls. Configure its QA-only token in the launch environment without exposing it in logs or process arguments:

```sh
export SWARMHUB_QA_HERMES_URL=http://127.0.0.1:49372
# Set SWARMHUB_QA_HERMES_TOKEN using your local secret mechanism.
./scripts/run-qa.sh
```

The app prints a private `endpoint.json` path. In a second terminal:

```sh
python3 -B sim/run.py --mode live --scenario F03 \
  --endpoint-file /absolute/path/printed/by/app/endpoint.json \
  --output sim/results/mac-qa-first-chat
```

No gateway is shipped or running here. Those commands cannot currently complete a live scenario against an unmodified Hermes server. Unsupported catalog operations/capabilities block before resource creation. Scope names alone never grant access to existing work. No per-action human approval is required inside the compiled synthetic allowlist.

The checkpoint hook writes only the owned QA bot snapshot and a receipt. `restart.prepare` requires remotely verified zero active work, revokes the scope, then checkpoints it. It does not kill/relaunch a process or restore/replay a saved run. Each next app launch starts fresh; cold restart/recovery and unattended acceptance remain blocked.

## Validation performed

- Initial standalone safety suite: **40 tests passed**, zero failures/errors. After adding the checkpoint-policy test, the final runner executed the full **41-test** Python suite with zero failures/errors (existing 33 plus eight new tests).
- `python3 -B sim/run.py --output /tmp/swarmhub-qamode-final-validation`: **exit 2**, 41 passing harness tests, all 65 live scenarios blocked, `live_app_executed:false`. Retained the final generated JSON/readable results under `sim/results/qamode-final-validation/`; earlier 40-test output remains under `sim/results/qamode-validation/`. Fourteen existing source probes remain source-confirmed; none is a runtime reproduction or a claimed QA-mode fix.
- `bash -n scripts/run-qa.sh`: passed.
- `git diff --check`: passed. Python AST parsing also passed; a source scan confirmed QA references are DEBUG-guarded. This is not a release-binary check.
- Swift executable lookup: unavailable. No Swift compile, typecheck, Swift Testing/XCTest, Mac UI, actual socket inspection, release packaging/binary inspection, Hermes/model/tool run or watchdog kill/recovery test was performed. Auth/transport/recorder source tests are authored checks, not runtime evidence of safety.

## Risks and remaining acceptance

1. **Server isolation is the critical remaining implementation dependency.** This repo cannot enforce Hermes tool process egress, hidden credentials, delegation or schedule expiry. A gateway that lies or merely forwards traffic defeats its own attestation; do not enable live mutations until the real runtime implements and independently verifies the contract. App guards do not replace an OS sandbox for Hermes or the GUI process.
2. **Swift compilation and native behavior are unverified.** Run the eight new tests (`swift test --filter qa`) and existing suite on a Mac, then negative auth/scope/network tests and real debug launch. Verify the actual IPv4 bind and no listener/QA symbols/activation strings in both release build paths.
3. **The QA workspace is constrained.** It uses real store/actions/message rendering, with editing surfaces restricted. Content-view PNG capture is not a native Accessibility, toolbar/composer, focus, screen-compositor or complete normal-workspace pass. The broader QA plan and most adapters remain unsupported.
4. **Native gateway operations require atomic checks.** Every real native request must recheck ownership, inventory revision, expiring lease and immutable accepted action. Creation must enforce paused/expiring one-run routines before they can fire. Local per-request proof checks cannot close server-side races. Cleanup acknowledgement must come from actual remote checks.
5. **Accepted and completed differ.** App action acknowledgement means accepted by the existing AppStore path; async approval/run outcomes still require observation. Unknown acceptance is never resent. A failed/expired safety proof halts the driver; only the independent server watchdog can clean up after app/runner loss.
6. **Local private artifacts are retained.** Tokens, synthetic model output and QA screenshots stay under a fresh owner-only temporary directory. Tokens rotate and sockets disappear on exit, but evidence files are not automatically deleted and OS temporary cleanup may remove them. Same-user compromise is outside the token boundary. Use only a QA gateway key in the environment; never production credentials.

## Compile-error follow-up (2026-10-17)

Moved DEBUG launch selection to `AgentAppLauncher.main()` in `QA/QAApp.swift`, which calls the selected SwiftUI app's `main()`. The dedicated `QAApp` owns its controller and unconditional QA window; `AgentAppMain.body` always returns the existing normal scenes. Invalid QA initialization still exits with code 78. This removes runtime control flow from SceneBuilder and avoids constructing normal app state on a QA launch. Release retains `AgentAppMain` as its entry point and excludes the entire new file.

Reviewed all QA sources/tests and integration hooks for Swift 6 actor/Sendable boundaries, imports, deployment-target availability and existing API signatures; no additional clear compile blockers were found. Validation: all 41 Python harness tests passed; source checks confirmed identical normal scenes, whitespace-equivalent release `AgentApp.swift`, no release QA entry point, and exactly one active entry point in each configuration; `git diff --check` passed. Swift is unavailable here, so the Swift 6.4 macOS build, Swift tests and both debug launch modes still require verification on a Mac. No commits were made.
