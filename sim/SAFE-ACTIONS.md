# Compiled safe-action allowlist

The runner's `OPS`, `PROMPT_OPS`, fixed values and canned prompts in `run.py` are the enforcement authority. Editing scenario prose or a model reply cannot add an operation. The future hook must independently apply this same versioned policy, enforce it atomically at execution, and bind every resource ID to its run. Display names alone never authorize an operation.

All chat, thread, group and routine names must be `QA-<run>-<scenario> [QA-TEST]`. Every sent content item contains `[QA-TEST]`. Existing production conversations, schedules and profiles are inaccessible in the isolated store. QA profiles must also be isolated on the real Hermes server: dedicated conversation namespace, empty QA workspace and memory, no production sessions, no real credentials, no inherited production tool grants. Real app and Hermes execute the bot loop; their tools are confined to fake recording-only implementations. Merely asking a bot to behave safely does not satisfy this policy.

| Allowed operation | Fixed scope and limits |
| --- | --- |
| `chat.send`, `chat.stop`, `chat.draft` | Current run's QA conversation; fixed prompt selector; synthetic main/thread draft; Stop cannot affect another run. |
| `thread.fork` | Only the QA origin and its QA history; preserve QA tag/metadata. |
| `goal.start/subgoal/pause/resume/clear` | Synthetic three-item list; fixed expected-results subgoal; at most three remote turns and 120 seconds, independently enforced by hook/watchdog. |
| `loop.start/pause/resume/stop` | Synthetic marker or 2-second QA wait; interval 60 seconds, **one run only**; no `--until`, infinite loop or arbitrary flags. |
| `routine.create/run/pause/delete` | Exact scoped routine, created paused with synthetic marker and one-shot expiry; duplicate Run now clicks target the same request. No user routine lookup or deletion by prefix. |
| `team.start/pause/cancel/stop` | Only preconfigured QA Coordinator/Worker/Reviewer; at most three synthetic tasks, one review round; exact scope; evidence gating when required by recipe. |
| `approval.request/decide` | Exact originating QA noop `qa_approval`, known immutable payload and intent fingerprint. Approve or deny only that pending request; no shell command, account grant, real send or wildcard approval. A repeated same-intent request is observed, never auto-approved after denial. |
| `draft.create/send` | Two fake drafts to `a@example.invalid` / `b@example.invalid`, `QA-sandbox` account and bodies `[QA-TEST] A/B`. Only card A is clicked after discussing B. Sink records attempt; never delivers. |
| `fact.write`, `review.request` | Fixed synthetic fact revisions 1/2 with synthetic source; arithmetic error `2 + 2 = 5`; QA readers and reviewer only. No real document/memory access. |
| `peer.ask` | Scoped QA reviewer only; markers propagate; peer transport remains the real Hermes path, with QA-only routing and deny-all other tools. |
| `transport.cut/restore`, `history.refresh` | Only instrumentation for this QA request's response stream/observation; never disable system networking, restart a production server, or substitute backend responses. Requires advertised real instrumentation. |

The following are refused: arbitrary text/commands/URLs/file paths; production contacts/accounts/messages; real email, Slack, WhatsApp or connected-app calls including reads; OAuth; money; secrets; production data; installing skills or creating real bots; shell jobs and commits; host/process kills; backend/model/account rebinding; device-global clocks, permissions, settings or updater/report sends; unmarked or foreign resources; unknown operation parameters. The reserved `swarmhub-heartbeat`/`Bot Chat` feature cannot meet the current QA name policy, so A05 is blocked rather than renamed into a different behavior.

Before *any* scope mutation, attestation must confirm debug mode, QA store, real Hermes, exhaustive connector inventory, zero real connectors, no connector credentials/network, app **and Hermes** sandbox enforcement, default-deny tools/egress, QA-only peers, propagated tags, and an active watchdog. Inventory includes browser, terminal, coding, messaging skills, webhooks, raw HTTP and any alternate app/tool broker, not just Composio. A real connector even present in the QA execution environment fails the gate; an approval card or an LLM promise is insufficient. Unknown/incomplete inventory also fails. The only allowed non-loopback egress is the explicit real model transport; connected channels are always stubs.

Unlisted actions are refused and logged without echoing possibly sensitive arguments. Driver logs have `outcome: refused`; the sink has a separate `*.refused.jsonl` log. No fallback to real provider APIs is permitted. Sandbox duplicate attempts are retained, including across sink restart; reusing an attempt ID for changed data is refused. The standalone sink is single-process and is not a deployed multi-process broker.

No per-action confirmation is required or requested inside this boundary. If safety or cleanup becomes uncertain, the runner stops; elapsed time never grants broader authorization. Only the independent watchdog may perform scoped emergency cleanup after attestation failure.
