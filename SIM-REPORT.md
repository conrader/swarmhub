# Swarm Hub simulation report

Reviewed 2026-10-16, source commit `ed9c70a5c680bbbb4d59c23df41f50a0a285b243` (QA baseline: release 0.5.6/build 21). Host: Linux; timezone Europe/Warsaw. Read the simulation brief including UPDATE 1–4, the complete QA plan, its supplied Grok comparison, and the relevant app/service/model/skill sources. No GitHub network access, MacBook execution, real backend connection, outbound delivery, app-source changes or commits occurred.

## Outcome

Delivered a dependency-free Python runner, 65-scenario catalog, 27 bounded action recipes, compiled safe-action allowlist, recording-only outbound sink, evidence/oracle logic, source probes, and a design-only debug hook. **33 harness tests pass. All 65 app/runtime scenarios are blocked; zero live passes, zero live failures and zero runtime-reproduced bugs.** Fourteen source patterns from the QA findings were confirmed in this checkout. They are source evidence, not newly reproduced live defects.

The current app has no `test_mode`/`[QA-TEST]` enforcement or matching debug endpoint; the supplied recording sink is not wired into app/Hermes execution. A safe live adapter cannot honestly be claimed without that isolation. The runner's live client targets the proposed hook, but the hook itself remains design-only as requested. This delivery therefore prepares automation and validates the harness on Linux; it does **not** complete real-app scenario execution or Grok-parity acceptance.

The brief's updates override the older mock-backend, disposable-server injection and tester-owned real-send instructions: real Swarm Hub + real Hermes for the bot loop, **fake recording-only tools for every outbound/connected channel**, no per-action human approval inside the allowlist, fail closed on any real/unknown connector, and visible/machine-readable QA tagging. No fake Hermes/OpenClaw backend was built or run.

## Files and one-command runner

- [Runner and usage](sim/README.md): `python3 -B sim/run.py` from this worktree. Default is offline and makes no app/backend requests.
- [Scenario catalog](sim/scenarios.json): all A01–A18, F01–F25, B01–B10 and U01–U12, original scripts, safe recipes, assertions, required capabilities, blockers and uncovered branches.
- [Safe-action allowlist](sim/SAFE-ACTIONS.md): compiled operation/prompt/value checks plus independent future app/server enforcement requirements.
- [Hook proposal](sim/DEBUG-HOOK-DESIGN.md): loopback-only, debug-only, token-protected, off by default; app/Hermes sandboxing, visible QA mode/tag propagation, protocol/checkpoints, independent watchdog and risks. No hook implementation or activation is included.
- [Report format](sim/REPORT-FORMAT.md), [final readable results](sim/results/final-20261016/RESULTS.md), [machine-readable results](sim/results/final-20261016/results.json), [safety tests](sim/test_runner.py), [source probes](sim/source-probes.json).

Use a fresh `--output` directory on repeat runs. Exit 2 means incomplete/blocked, exit 1 means failed harness checks or an evidenced variant bug, and exit 0 requires all selected bounded variants to pass. Partial recipe coverage never certifies the whole manual scenario.

## What actually ran

Executed `python3 -B sim/run.py --output sim/results/final-20261016` locally. It completed 33 harness tests with zero failures/errors, evaluated 14 textual source probes, and wrote 65 blocked scenario results. Exit code **2 is intentional**, reflecting unavailable real-app execution. Final run timestamp: **2026-10-16T21:08:50.506800+00:00** UTC.

The tests cover QA names/tags; unknown operations/parameters and mismatched prompts; missing safety fields and wrong types; real/credentialed/network-capable connector detection; incomplete inventories; app/Hermes sandbox drift; expired/replayed leases; owner-only tokens and symlink refusal; evidence scope/provenance/order; missing observations; instrumented zero counts; false completion claims; recording-only email/Slack/WhatsApp/connected-app attempts; duplicate receipts across sink restart; changed payload under the same ID; lost acknowledgement without resend; per-operation attestation; run-budget refusal; cleanup uncertainty halting the suite; and the Linux live gate issuing no hook request. Unit tests use synthetic receipt records and an in-process transport-boundary spy, not a fake backend or app-success simulation.

The first validation found a catalog parser defect: a title regex consumed subsequent sections. It was fixed, a title-boundary assertion was added, and the final 33 tests pass. [The initial attempt log](sim/results/validation-attempt-1.txt) preserves that harness issue. The earlier 32-test successful run is retained separately under `sim/results/offline-20261016/`.

Not run: Swift/XCTest (no Swift executable), native macOS app/UI/Accessibility/AppleScript, `sb-macjob`, real Hermes/OpenClaw/model turns, real tool calls, approvals, schedules, detached jobs, mobile or overnight tests. No historical PLAN test count is presented as a new result. No real-data or account discovery was attempted.

## Source-confirmed findings and safe repro instructions

These reconfirm QA findings rather than claim new live discoveries. “S” means source behavior/limitation confirmed; “L” means the practical failure remains a runtime hypothesis. Repros below are for a future isolated QA debug environment only. The runner does not execute off-list parts. Runtime status for every row remains **not reproduced**.

| Evidence / scenarios | Source and concrete trigger | Expected vs source-supported outcome; Grok gap |
| --- | --- | --- |
| S01, S / A01,A16 | [Goal completion](Sources/AgentApp/Stores/AppStore+Goals.swift#L110): have the real QA bot emit a structured done claim without acceptance evidence. | Done directly produces `Goal reached`; no independent evidence gate. G8 verification → **worse**. Team evidence also defaults false in `Models/TeamCoordination.swift:13`. |
| S02–S03, S/L / A02 | [Restore](Sources/AgentApp/Stores/AppStore+Automation.swift#L81), [reconnect](Sources/AgentApp/Stores/ConnectivityMonitor.swift#L68), [loop dispatch](Sources/AgentApp/Stores/AppStore+Loops.swift#L47): interrupt an accepted one-run QA loop, delay history, then restore. | Await flags reset; reconnect ticks automation before reconciliation; loop entry has no positive remaining-count guard. Need reconciliation before continuation and exactly one execution. G2/G3 → **worse**; extra run still needs runtime confirmation. |
| S04, S/L / A06 | [Re-pause](Sources/AgentApp/Stores/AppStore+Routines.swift#L155): run a paused QA routine; let the actual post-run pause fail once. | Intent is cleared before `try? pause`; failure can leave future scheduling enabled. Need acknowledged pause before clearing intent. G3/G6 → **worse**. Fault adapter unavailable. |
| S05, S/L / A06 | [Delivery cursor](Sources/AgentApp/Stores/AppStore+Routines.swift#L143): fail catch-up/read or interrupt after mark save before ledger delivery. | Cursor persists before asynchronous delivery, risking a skipped result on later refresh. Need durable pending delivery/retry. G2/G6 → **worse**. Crash/fault branch not executed. |
| S06, S/L / F08 | [Card action](Sources/AgentApp/Stores/AppStore+CardActions.swift#L53): generate fake drafts A/B, discuss B, click A and compare sink payload. | Click sends `Send it`; `draftSent` follows local acceptance, not exact outbound receipt. Wrong-payload impact needs a live repro; transport binding is absent in this method. G5 → **worse**. |
| S07, S/L / B06 | [Slash retry](Sources/AgentApp/Stores/AppStore+SlashCommands.swift#L84): after accepted-but-incomplete QA work, invoke `/retry` while idle. | When `canRetry` is false it sends the last user content again rather than first reconciling that incomplete work. Need no duplicated accepted execution. G8/G9 → **worse**. Unsafe fault recipe remains blocked. |
| S08, S/L / F06 | [Thread model command](Sources/AgentApp/Stores/AppStore+SlashCommands.swift#L58): invoke `/model` from a QA thread. | It uses bot-level picker/session and `switchModel(for: bot)` despite conversation context. Need thread-targeted behavior or explicit refusal. G8/G9 → **worse**. Model mutation is not allowlisted. |
| S09, S/L / F06 | [Draft scope](Sources/AgentApp/Views/ChatView.swift#L88): put distinct unsent QA text in main/thread, switch between them. | Persistence uses bot ID for both. Need independent drafts or explicit shared-state UX. G9 → **worse**. |
| S10, S/L / F05 | [Scroll](Sources/AgentApp/Views/ChatView.swift#L56): read older QA text while a new answer streams. | Every last-content change scrolls main to bottom without checking reading position. Native impact untested. G9 reading continuity → **worse**. |
| S11, S/L / A05 | [Heartbeat window](Sources/AgentApp/Models/BotHeartbeat.swift#L30): compare displayed 08:30–09:15 against minute 08:07/09:50; separately test Warsaw 2026-10-25 DST. | Window floors to hours; cron conversion uses an apply-time offset. Need exact displayed bounds and timezone behavior. G3/G6 → **worse** for precision; server time scheduling exists. Reserved real heartbeat name is outside this runner's QA scope. |
| S12, S/L / A11,F19 | [Orientation](Sources/AgentApp/Stores/AppStore+Orientation.swift#L67): let an accepted first turn fail asynchronously, reconnect. | `orientedAt` is set after local send acceptance; useful completion is not required. Need recoverable failed orientation. G3/G9 → **worse**. Provisioning/orientation mutation not automated. |
| S13, S/L / A13 | [Peer identity](Sources/AgentApp/Stores/AppStore+BotMessages.swift#L35): two actual QA boxes with same profile; open peer arrival/thread. | First matching profile lookup ignores connection identity. Need connection+profile correlation. G1/G9 → **worse**; second box unavailable. |
| S14, S/M / A17 | [Background routes](Sources/AgentApp/ConnectedApps/BackgroundExecutionClient.swift#L3): demand a real event-trigger registration receipt. | Routes explicitly undeployed; no generic webhook workflow found in reviewed path. G6 → **missing**, not a live regression. |

Additional manually inspected limitations: pending approvals are in-memory (`Stores/AppStore.swift:14`), while `decide` sends an asynchronous decision without an in-flight guard (`Stores/AppStore+Approvals.swift:11`); A09/F15 must test recovery/double-click/acknowledgement before any live bug claim. Review-after launches asynchronously and does not gate goal continuation (`Stores/AppStore+Reviews.swift:22`, `Stores/AppStore+Turns.swift:175–186`); G8 **worse**. `code-job` removes temporary output during finish/EXIT and has no durable completion-wake contract (`Resources/Skills/swarmhub-coding/scripts/code-job:75–99`); G2 durable supervisor **missing**, while its real slot/timeout/fallback features do exist. No real detached job was started, and a stub job would not validate that gap.

## Per-scenario runtime results

Every row below is an environment/safety/adapter block, not an app failure. “Partial” describes planned bounded recipe scope, not completed execution. Comparison labels retain the supplied source baseline; “matches” is provisional mechanism parity, not a new runtime comparison. Full original expectations and qualifications are in the catalog. No “better” claim is supported. F20 separately matches per-bot skills while background memory is worse; A05 normal server time scheduling exists despite its worse precision/recovery rating.

| Scenario | Bounded variant | Grok comparison (source baseline) | Result/reason |
| --- | --- | --- | --- |
| A01 — Standing goal lifecycle, subgoals and truthful done | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A02 — Restart/reconnect with unknown goal or loop result | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A03 — Loops, failures, busy chats and cost | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A04 — Standing backlog and the next-job contract | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A05 — Server heartbeat, silence, local time and DST | blocked (design-only) | worse | Heartbeat uses reserved swarmhub-heartbeat/Bot Chat names; QA-only scope cannot safely mutate it. Minute/DST behavior is source-reviewed only. |
| A06 — Routines while away; re-pause and result recovery | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A07 — Team dispatch, help, reviews and budget exhaustion | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A08 — Team lifecycle, pause/cancel/stop and dispatcher ownership | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A09 — Approval queue when user is absent | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A10 — Approval routing, final denials and review limits | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A11 — Orientation promises, unavailable bot and recovery | blocked (design-only) | worse | Real bot provisioning/orientation and global quiet-hour clock manipulation are outside the QA chat/routine allowlist. |
| A12 — Peer asks, late replies, held and priority delivery | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A13 — Two boxes with identical profile names | blocked (design-only) | worse | Requires two real QA Hermes boxes and stable connection+profile identity; no second connection supplied. |
| A14 — Detached jobs: completion, failure, fallback and orphan | blocked (design-only) | missing | Real detached CLI jobs/host kills exceed QA chat/routine allowlist; recording-only tools cannot validate durable real job supervision. |
| A15 — Stuck/silent work and observability timeout | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A16 — Shared memory and review across independent work | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| A17 — Event/webhook triggers and background app execution | blocked (design-only) | missing | Generic event trigger/background worker is a source-confirmed missing capability; no fake implementation supplied. |
| A18 — Stop all unwanted unattended work and account for cost | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F01 — First run, samples, cancellation | blocked (design-only) | matches | First-run/reset/sample state modifies the app globally; requires an isolated native QA launch and UI adapter. |
| F02 — Hermes setup/discovery and degraded capabilities | blocked (design-only) | matches | Connection setup/key changes are not permitted by the QA chat/routine allowlist. |
| F03 — Chat, Markdown, quote/reaction, sidebar state | blocked (partial) | matches | Linux/offline source and harness checks only; no app/backend contacted |
| F04 — Draft retention and keyboard navigation | blocked (design-only) | matches | No safe scoped adapter implemented for this full scenario; see original QA script. |
| F05 — Long chats and reading while streaming | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| F06 — Thread navigation, composer scope and coding role | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F07 — Attachments, extraction, media and refusal states | blocked (design-only) | matches | No safe scoped adapter implemented for this full scenario; see original QA script. |
| F08 — Choice and outbound draft cards | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F09 — Local bot versus backend bot management | blocked (design-only) | worse | Backend bot creation/retirement is outside the allowlist. |
| F10 — OpenClaw connect, capability changes, and forget | blocked (design-only) | worse | This brief authorizes the real Hermes loop; no real disposable OpenClaw target is supplied. |
| F11 — Model defaults, switching and coding accounts | blocked (design-only) | worse | Global model defaults, coding-account login and provider fault injection are outside the allowlist. |
| F12 — Routine CRUD and normal result | blocked (partial) | matches | Linux/offline source and harness checks only; no app/backend contacted |
| F13 — Connect first app and choose among accounts | blocked (design-only) | worse | Real OAuth/accounts/connectors forbidden. Only record-only connector testing is permitted; no fake authorization success. |
| F14 — Abandoned and second-account authorization | blocked (design-only) | worse | Real OAuth/account mutation forbidden; no browser authorization is automated. |
| F15 — Manual decisions, rules and audit | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F16 — Reviewer and review-after | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F17 — Ordinary groups and mentions | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F18 — Planned versus Work together flow | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F19 — New-bot orientation | blocked (design-only) | worse | Real bot provisioning and app-global orientation changes are outside the allowlist. |
| F20 — Shared context and skills | blocked (partial) | worse | Linux/offline source and harness checks only; no app/backend contacted |
| F21 — Grok history and template import | blocked (design-only) | worse | User Grok history/real-data import forbidden; synthetic import needs an isolated native import adapter. |
| F22 — Settings, usage, notifications and appearance | blocked (design-only) | worse | Global settings/notification permissions/appearance need a native isolated UI adapter; no app-global changes allowed. |
| F23 — Computer, dictation, spoken and separate voice conversations | blocked (design-only) | matches | Microphone, computer control and voice credentials are outside the allowlist. |
| F24 — Feedback reports and update flow | blocked (design-only) | matches | Feedback sending and updater network actions are outside the allowlist; no real reports sent. |
| F25 — Actual iOS foundation and away-from-Mac limits | blocked (design-only) | worse | Requires iOS hardware/simulator and separate mobile adapter; Mac driver cannot certify mobile. |
| B01 — Answer and stream | blocked (partial) | matches | Linux/offline source and harness checks only; no app/backend contacted |
| B02 — Tools and final answer order | blocked (partial) | matches | Linux/offline source and harness checks only; no app/backend contacted |
| B03 — Stop | blocked (partial) | matches | Linux/offline source and harness checks only; no app/backend contacted |
| B04 — Steer/correction | blocked (design-only) | matches | No safe scoped adapter implemented for this full scenario; see original QA script. |
| B05 — Explicit unsent retry | blocked (partial) | matches | Linux/offline source and harness checks only; no app/backend contacted |
| B06 — `/retry` after interrupted delivery | blocked (design-only) | worse | Slash retry fault recipe not implemented; source probe documents replay risk without sending it. |
| B07 — Restart and delayed final text | blocked (partial) | matches | Linux/offline source and harness checks only; no app/backend contacted |
| B08 — Offline, backend outage and model overload | blocked (design-only) | worse | App/server-wide outage and provider 429/500 injection unavailable without forbidden backend substitution. |
| B09 — Long history and concurrency | blocked (design-only) | matches | No safe scoped adapter implemented for this full scenario; see original QA script. |
| B10 — Backend switch and feature loss | blocked (design-only) | worse | Backend rebinding/global keys are outside the allowlist. |
| U01 — Creation/onboarding mental model | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U02 — Find work and blockers | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U03 — Empty states and disabled controls | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U04 — Loading, cancellation and errors | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U05 — Labels and inconsistent words | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U06 — Quiet-hour settings | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U07 — Click count and navigation | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U08 — Reading and drafts | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U09 — Keyboard and command surprises | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U10 — Accessibility labels and focus | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U11 — Dark/light/contrast and reduced motion | blocked (design-only) | matches | No safe scoped adapter implemented for this full scenario; see original QA script. |
| U12 — Fixed layouts and long labels | blocked (design-only) | worse | No safe scoped adapter implemented for this full scenario; see original QA script. |

## Remaining live boundary

Live execution requires a separately implemented, reviewed debug hook and real Hermes QA-profile sandbox with exhaustive connector inventory, all connected tools replaced with recording-only stubs, independent server expiry/cleanup, and persistent visible QA tags. None was enabled here. A token or prompt-only instruction cannot replace these requirements. The runner has no per-action human confirmation flow and refuses real/unknown connectors before mutation and on every subsequent attestation.

After those prerequisites exist, the user can launch the existing real app in its isolated debug QA mode and invoke the documented local Mac command. Native UI capture, fault/checkpoint capabilities, full restart/overnight coverage and the 38 missing adapters remain implementation work. Grok parity additionally requires features the reviewed source lacks; a normal chat pass would not establish it.

Only `sim/` additions and this requested root report were written. App code was left unchanged; no fix, commit or deployment was attempted.
