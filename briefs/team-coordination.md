# Team coordination — Team coordination entirely in SwarmHub

Planning date: 2026-10-16, Europe/Warsaw. Status: implementation on `codex/swarmhub-team-coordination`; no deployment. The upstream P41 number is already used by a separate shipped change.

Goal: reproduce the useful communication patterns in Konrad's Grok conversations and improve their reliability:
specialists exchange findings, challenge mistakes, continue authorized work, and report useful results to Konrad
and their coordinator. Build on P34 messaging, P37 reviews, P38 workflows and P39 concurrent chats.

## Architecture boundary — decided by Konrad

"It needs to be SwarmHub only without interference with Hermes."
"Hermes is working on remote server and work is happening there usually."
"If we can't delegate anything new then we don't delegate."

- Hermes remains the remote execution backend. SwarmHub uses the existing chat/session/run APIs as a normal client.
- All new routing, task records, permissions, communication rules and project context live in SwarmHub.
- No additional service, daemon, remote SwarmHub runtime, webhook infrastructure or always-on supervisor.
- No Hermes core patches, plugins, installed scripts, profile/SOUL/skill/memory/configuration changes, direct database
  access, credential-file reads, new cron jobs, or changes to Hermes approval rules. No changes to SB job launchers.
- SwarmHub sends new work only while the app is running, connected and able to dispatch. Otherwise it waits.
- Work already running independently on the remote server remains there. Reopening SwarmHub reads remote state,
  reconciles results and dispatches eligible next work. It never treats app closure as proof of remote cancellation.
- Whether a particular server run survives a disconnected client depends on the existing API. Verify this behaviour;
  display incomplete/unknown when appropriate. Do not promise background execution beyond what Hermes provides.
- New schedules, if added later, would belong to SwarmHub and could not promise to fire while it is closed. Existing
  Hermes routines can still be displayed; this plan neither creates nor edits them.

The proposed separate runtime from the initial discussion is withdrawn and is not a dependency or deliverable.

## Evidence and baseline

The review analysed 6,843 exported entries across 16 bots and one group, dated 8–13 October in Europe/Warsaw.
There are 3,317 bot-channel entries, including mirrored records; these are not counts of unique deliveries.
The archive has missing entries. Bot statements about execution are evidence of conversation behaviour, not proof
that the underlying work succeeded. Keep real transcripts, private identifiers and credentials out of fixtures.

| Observed pattern | Requirement |
| --- | --- |
| DMT and Achilles exchanged 12 bot messages after one user instruction, correcting facts and avoiding duplicate work | Multiple directed turns inside a group, with a shared task and explicit completion |
| Konrad repeatedly asked for the next task to start after a job finished | Continue authorized work when SwarmHub is available; otherwise retain the pending step |
| Heartbeat notifications flooded Konrad, then a 10-minute reporting rule hid wanted results | Persistent routing rules for results, decisions, urgency and quiet hours |
| Doc asked Konrad again after Jarvis approved | Preserve the scope and evidence of delegated approval across steps |
| Jarvis inferred the executing model from configuration and repeated an incorrect browser/account claim | Distinguish requested settings, observed execution and unverified claims |
| Agents repeated rules through broadcasts; the export has no structured routines, skills or memory facts | SwarmHub-owned project context and an explicit migration coverage report |
| Voice requests assigned work to specialists | Route reviewed voice intent into the same real agent conversations |

Confirmed implementation issue: the current `bot-msg --no-wait` returns exit 0 and logs `ok` for both an HTTP 500
and a `run.failed` response. Reproduced against the repository's loopback stub. The new path must not depend on this
script. Existing installations are left alone; legacy threads remain readable.

## Implementation approach

Extend the current app-side operation envelope used by `ConnectedAppsChat` and `WorkflowTools`. During a coordinated
turn, SwarmHub supplies a short, request-scoped description of available operations through ordinary API input.
The agent can request a peer message, help, review or completion. SwarmHub validates the request, records it and
delivers the next ordinary API turn using the selected recipient's existing connection.

This requires no tool installation or server change. Do not parse incidental prose or quoted history as commands.
An operation is actionable only when it is the complete structured response to the current operation contract.
Sender identity comes from the active SwarmHub turn; target IDs must belong to the authorized roster. A recipient
gets peer content marked as data, alongside the actual user task and applicable SwarmHub instructions.

Keep the existing local runtime ledger, recovery, receipts, activity UI and document access controls. Use a small
shared `Packages/SwarmHubCoordination` module for protocol/model code that both native clients need; bridge existing
desktop/mobile implementations incrementally. No whole-store rewrite. Existing ordinary chats remain usable.

## Delivery sequence

| Phase | Deliverable | Depends on |
| --- | --- | --- |
| A | Reliable app-mediated bot messages and task threads | Existing P34/P38/P39 |
| B | Reconnect and restart recovery | A |
| C | Persistent authority and reporting rules | A, B |
| D | Continuing workflows with evidence-based completion | B, C |
| E | Directed, multi-turn group collaboration | C, D |
| F | Shared project facts and migration coverage | A, C; consumed by D/E |
| G | Voice connected to the actual team | C, D, E |
| H | Product acceptance and platform rollout | A–G |

Each phase is split into implementation, focused verification and integration commits. Phase F can be implemented
independently once its prerequisites exist. This plan does not require parallel agents or changes in another repo.

### A — Reliable messages, without bot-msg

1. Add a coordination envelope containing operation ID, task ID, conversation ID, recipient ID, reply-to ID,
   message kind and payload. Bind identity to connection ID + backend agent/profile ID, never display name alone.
2. Commit the outgoing intent before dispatch. Store backend session/run IDs and append receipt events atomically.
   Separate local queue acceptance from server acceptance and task completion.
3. Delivery states: queued, dispatching, accepted, running, completed, failed, uncertain, cancelled-before-send.
   A broken stream or a timeout after transmission becomes uncertain until reconciled.
4. Deduplicate operation IDs and payload fingerprints locally. Retry a dispatch automatically only when it is
   known not to have reached the server, or the existing endpoint proves idempotent. Never claim exactly-once remote
   execution where the backend cannot establish it.
5. Use task-specific peer conversations. Keep pair-based history navigation, with separate topics for concurrent
   work. Every exchange links to its originating user request and downstream result.
6. Extend the existing recipient chip, thread sheet and arrival line with accurate status and a retry/check action.
   Add a composer for a user intervention scoped to the task and named recipients.

Acceptance: rejected calls cannot show sent/completed; replayed operations create one local intent; two unrelated
tasks between the same bots keep separate context; duplicate display names route correctly; forged sender fields,
quoted operation text and nonmember recipients cannot dispatch work. Run all cases with synthetic API fixtures.

### B — Recover remote work before issuing more work

1. Persist task ownership, dependency state, continuation, budget, pending operation and last known backend run.
2. On reconnect/reopen, read existing runs/messages first. Settle confirmed results once, rebuild the visible
   timeline, then release authorized queued work. Keep unresolved submissions uncertain instead of resending them.
3. Separate pause-new-work, cancel-queued-work and request-stop-of-running-work. Disconnect, app quit and transport
   failure must not be translated into an explicit remote Stop request. Report actual backend behaviour honestly.
4. Hold new delegations while offline, the app is unavailable, or a backend cannot provide the needed capability.
   Show "Waiting for connection" or "Waiting to continue" rather than a fabricated active state.
5. One local dispatcher owns an operation. Multiple windows and app instances must not drain the same queue twice.
   If two devices have independent local stores, retain one explicit coordinating device per workflow. Do not claim
   cross-device failover without a shared authority; other devices may inspect remote conversations independently.

Acceptance: an externally completing run is recovered without another execution; a crash between send and receipt
does not cause a blind resend; an unfinished task remains visible; queued work waits during a disconnect and resumes
only after reconciliation. Verify disconnect behaviour separately against a stock Hermes test instance.

### C — Remember who may decide and who should hear

1. Store versioned SwarmHub policy records for project, agents, permitted operation types, reviewer, applicable
   targets/accounts, expiry/revocation and originating user decision. Check policies at dispatch, including retries.
2. Allow in-scope peer questions, read-only investigation, reviews and previously authorized continuation without
   approving every graph change. A handoff does not itself expand the underlying permission to take actions.
3. Extend existing reviewer routing to supported connected-app actions using typed action arguments. Bind a review
   receipt to exact content, target and policy version. Reuse a decision only for the same pending action; permission
   reuse must never imply executing an already completed action again.
4. Preserve nondelegable backend/platform requirements. If an existing API does not expose an approval or its
   outcome, show that limitation. Never edit Hermes rules or treat a peer's "approved" text as user authorization.
5. Store reporting rules by event: requested result, blocker, decision, urgent failure, routine progress. Initial
   suggested policy: requested results reach the originating chat and coordinator; ordinary background updates are
   consolidated; quiet hours silence notifications while retaining visible results. Default timezone follows the
   user's device, with an explicit override. Treat historic Grok preferences as migration candidates, not current grants.
6. Track delivery to the coordinator, projection into the user's chat and notification separately. Deduplicate by
   result/event ID across these surfaces; repeat unchanged status silently. No LLM needed for notification routing.

Acceptance: an authorized peer handoff proceeds; revoked policy blocks a queued action; altered target/text requires
a fresh decision; Jarvis approval does not generate an identical second SwarmHub prompt; quiet hours and DST work;
both user and coordinator receive the intended result once; policy persists through restart.

### D — Continue tasks and verify outcomes

1. Promote workflows to a task graph with owner, objective, expected output, dependencies, next step, review state,
   blockers and evidence. Keep existing task/result artifacts and operation receipts.
2. A confirmed remote result makes the next eligible task ready. While SwarmHub is available, dispatch it under
   policy and capacity limits; otherwise persist it as ready and wait. New in-scope help/review/revision requests
   need no additional plan approval. Changed scope and exhausted limits remain explicit stops.
3. Support review → revision → review loops and independent tasks under the existing concurrency caps. Avoid a
   coordinator occupying a turn while waiting for a specialist; persist the dependency and release the turn.
4. Replace fixed limits as the only execution model with visible, configurable per-workflow task, review, elapsed
   execution and usage limits. Initially keep current conservative defaults; allow an authorized longer workflow.
   Waiting for the app or connection is not active execution time. Preserve spent budgets through restarts.
5. Check existing API status without an LLM; invoke an agent only for a new result, question, revision or decision.
   Use subscriptions when already supported, otherwise bounded polling while the app runs.
6. Store evidence references, observed model/host when available, verification result and reviewer verdict. Distinguish
   "agent reported finished", "remote run finished" and "task verified". For conversational tasks the answer may be
   sufficient; code/deployment/data tasks use their declared acceptance checks. Unknown usage/model stays unknown.
7. Observe independently launched external jobs only through status already exposed by an existing supported API
   or connection. If their completion cannot be observed, show "External job status unavailable"; do not invent a
   webhook, patch a launcher, or interpret an initial "job started" reply as completion.

Acceptance: an authorized task completes, is reviewed, revised and summarized without another user prompt while
SwarmHub is available; closing the app leaves unsent work pending; reopening reconciles then continues once;
finished prose alone does not verify a required deployment; no-change polling causes zero model calls; repeated
no-progress exchanges hit a visible limit; Stop affects only the selected workflow.

### E — Let the team have a conversation

1. Add a clearly selected "Work together" mode to groups; retain the existing one-round interaction.
2. Route structured peer questions/corrections to addressed members. Permit an earlier speaker to respond to a
   later correction. Do not awaken every member for every message or rely on incidental name mentions.
3. Attach discussion turns to the task graph. Give members relevant decisions, evidence and changes since their
   last turn; preserve source attribution and document access restrictions. Summarize older context visibly.
4. Apply the same policy, review and delivery handling as direct chats. Support user steering, recipient changes,
   task cancellation and one consolidated result with unresolved disagreements retained.
5. Prevent circular handoffs, repeated acknowledgements and duplicate assignments. Stop when the goal is verified,
   a genuine blocker appears, nobody has a useful next action, or the configured allowance is reached.

Acceptance: a synthetic DMT/Achilles scenario produces a directed question, data-backed correction, revised plan,
independent review and final answer; the user can interrupt; unrelated bots stay idle; no duplicate analysis runs;
group replies receive the configured reviews. Progress continues only while SwarmHub can dispatch.

### F — Shared facts, durable decisions and honest import coverage

1. Extend SwarmHub's document/ledger storage with project facts and decisions: source, owner, timestamp, revision,
   status, supersedes link and reader list. Separate observed facts from assumptions and user decisions.
2. Resolve applicable context in SwarmHub and include it in ordinary API requests. Never write it into Hermes
   memory, SOUL, skills or profile files. Recheck access before delivery to every recipient.
3. Retain disagreements and stale facts explicitly. A new unverified agent claim cannot silently replace a verified
   fact or user decision. Policy records and project facts have distinct authority.
4. Add a migration coverage view: identity, accessible history, extracted preference candidates, tools observed,
   external routines observed, pending work and missing/unknown items. History import is not capability migration.
   Imported preferences require review before becoming current authority; external routines remain untouched.

Acceptance: a corrected forecasting assumption reaches both bots with its source; old assumptions remain traceable;
revoked documents are excluded; reopening keeps the latest accepted decision; incomplete imports are labelled;
no Hermes filesystem/configuration/scheduler mutation occurs.

### G — Voice reaches the same agents

1. Use the selected real chat/task as the target. The voice layer provides speech input/output; the existing remote
   agent and SwarmHub coordination path own work and permissions.
2. Keep voice and text in one timeline, including peer dispatches, results and interruptions. A voice session
   cannot claim that its separate conversation has executed an agent action.
3. Start with dictation into the actual chat and spoken real-agent replies. Add live delegation/steering only if the
   existing voice transport supports the necessary events. Treat that capability check as an early gate, with the
   first increment as a useful deliverable if full duplex control is unavailable.
4. Deduplicate speech transcripts and bind confirmations to the precise pending action. Apply existing task/policy
   checks; ambiguous speech produces a draft or clarification. Closing voice alone does not cancel remote work.

Acceptance: a spoken assignment reaches the selected agent once; its specialist result appears in the same chat and
can be spoken; a spoken correction targets the right task; a duplicate transcript cannot duplicate an action.

### H — Acceptance and rollout

Use synthetic replay fixtures based on the behaviours above, not copied private transcripts. Complete checks at
each phase, then run one integrated scenario covering assignment, correction, review, authorized continuation,
disconnect, remote completion, reopen/reconciliation and a consolidated user result.

Required measures:
- Zero false success states in HTTP-error, failed-run and truncated-stream fixtures.
- Zero blind re-executions in lost-response, repeated-event and restart fixtures.
- Every handoff links to a requester, task, recipient and observable delivery state.
- No second SwarmHub permission request for an unchanged, still-authorized pending action.
- No model calls solely for unchanged polling or notification routing.
- Successful replay of the multi-turn forecasting case and a completion/revision/next-task case.
- Request logs contain only allowed ordinary backend calls; no manager recipes, profile writes, installs, scheduler
  writes or direct state-file access. Stock-server acceptance checks confirm configuration remains unchanged.

Roll out to new coordinated conversations first. Keep existing histories readable and ordinary chat as the fallback.
Enable recovery before automatic continuation, and policy before delegated approval. Disabling the feature stops
new coordination; it must not silently cancel remote work or erase pending/evidence records. Migrations are additive.

macOS is the first acceptance target. Reuse shared contracts on iOS; iOS suspension means it cannot dispatch until
active again. Complete multi-device ownership handling before advertising continuation from another device.
Run focused tests during implementation and the relevant full suite at integration. Release timing follows the
existing user-controlled cadence; this plan makes no deployment or publication changes.

## Implementation status on this branch

The macOS implementation and synthetic acceptance coverage are described in `docs/team-coordination.md`. A–F have app-side implementations; G delivers the agreed dictation/real-reply speech increment. H has synthetic tests and native UI rendering. Live stock-server acceptance and the incremental iOS UI rollout remain explicit release follow-ups; neither is represented as completed.

## First implementation slice

Phase A: implement a SwarmHub-mediated Jarvis → Infra question with a persisted receipt, a dedicated task thread,
an attributable reply and a visible failure path, using only existing API sessions. Prove it against the fake backend
before widening to groups or automatic continuation. No bot-msg installation and no server modification.
