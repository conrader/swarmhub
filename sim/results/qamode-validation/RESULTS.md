# Simulation results

Run `20261016T214503-48384b` · `45547b35f8f4afbd996a42872d5e7ad353e1bf5b` · offline · Linux

Harness tests: 40; failures: 0; errors: 0.
Source probes are textual checks, never native app test passes. Variant passes do not certify all QA branches.

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
