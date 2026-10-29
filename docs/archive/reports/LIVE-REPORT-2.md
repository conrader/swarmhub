# Live Hermes QA, pass 2

2026-10-19, Linux / Europe/Warsaw. Swarm Hub checkout
`0d6a4d7c665cce55be463c831537a22b8a845cc5`. Read the supplied brief,
`/home/box/work/swarmhub/wt-qa/QA-PLAN.md`, `SIM-REPORT.md`, and `LIVE-REPORT-1.md`.
No commit or app/server fix was made.

Real generated replies, tool execution, controls, disconnect recovery and concurrency
now work at the protocol/session level. **27 observed provider-call attempts** were
used, below the approximately 60-call allowance. All **17 owned QA sessions** were
deleted and individually verified absent. All **20 observed run IDs** reached a
remote terminal status. Both final health checks report **0 active API runs,
0 active agents, gateway_busy=false**.

The authoritative [adjudicated checks](../../../sim/results/live-2/adjudicated-results.json)
contain **84 PASS / 1 FAIL** across 85 low-level assertions, including creation and
cleanup. These are not 85 product scenarios. The failure is ignored session persona
configuration, an upstream Hermes issue. The scenario tables below explicitly mark
the wider app-dependent branches BLOCKED. No macOS/Swift execution or Grok runtime
comparison is claimed. **51 Python harness tests passed.**

## Environment, scope and evidence

The endpoint env was sourced without printing its key. Only authenticated numeric
loopback `127.0.0.1:8742` was used; there were no external connector calls, process
restarts, schedules, real outbound messages, profile filesystem edits, or config
changes. All created sessions, titles, persona names, idempotency keys and QA
operation labels begin `QA-`. The enabled toolsets were checked to be exactly
`todo` and `clarify`. Hermes also used its tool-discovery wrapper for two tasks;
those calls are included in the count.

The server README identifies Hermes `eea83bb` / 2026.9.24. Its model paragraph is
out of date: local config and owned-session counters show `openai-codex` /
`gpt-6-astra`, while the public model alias remains `hermes-qa-swarmhub`.
An explicitly locked turn independently returned runtime
`provider=openai-codex, model=gpt-6-astra, model_lock=confirmed`.
Default-route SSE runtime fields were empty; a virtual alias alone is not model
attestation. No alternative available model was supplied for cross-model review.

Evidence:

- [Core requests and raw responses](../../../sim/results/live-2/results.json), run
  `QA-LIVE2-20261019T085018-fc2eae`, 08:50:18–08:52:11 UTC.
- [Distinct edge variants](../../../sim/results/live-2-edges/results.json), run
  `QA-LIVE2-20261019T085320-01fd3e`, 08:53:20–08:53:29 UTC.
- [Capabilities, health, tool inventory and absent profile routes](../../../sim/results/live-2-discovery/results.json).
- [Correctly paged history reads](../../../sim/results/live-2/history-recovery.json) and
  [the valid clarify answer](../../../sim/results/live-2-clarify-correction/results.json).
- Usage snapshots before deletion: [core](../../../sim/results/live-2/usage-snapshots.json),
  [edges](../../../sim/results/live-2-edges/usage-snapshots.json).
- [Provenance/hashes](../../../sim/results/live-2/QA-provenance.json),
  [Python validation](../../../sim/results/live-2/QA-harness-tests.txt).

The Python harness talks to real Hermes directly. It does not bypass or claim to
exercise `sim/run.py`'s separately gated macOS QA adapter. No old, now-stale Python
Swift projection was used to score this pass. App conclusions below identify their
source-only boundary.

## Bot behavior scenarios

PASS applies only to the named protocol variant. Grok labels use QA-PLAN's supplied
G1–G9 baseline; Grok itself was not run here.

| Scenario | Verdict and actual evidence | Grok comparison and remaining boundary |
| --- | --- | --- |
| B01 answer/stream | **PASS** native 12-line reply, Polish characters and emoji; separately, legacy deltas reconstruct exactly `QA-LEGACY-✓` and end with stop / `[DONE]`. Native history contains one user turn. | **matches** G9 transport progress/completion; Thinking/Typing, switching chats and rendering BLOCKED. |
| B02 tools/final order | **PASS** one actual `todo_list` write, completed marker in its receipt, tool.started → tool.completed → final `QA-B02-DONE` → run.completed. | **matches** scoped G9/G8 tool evidence. No wait tool exists; 10-second tool, failure row and sidebar/UI BLOCKED. |
| B03 stop | **PASS** Stop posted on the first real text delta; stream carries interrupted/unsuccessful assistant result and run.cancelled; independent GET reports cancelled. | **matches** scoped G3/G9 stop acknowledgement. Before-ID, sleeping tool and UI partial preservation BLOCKED. |
| B04 steer | **PASS** steer during actual todo tool accepted with 200; final changed from QA-ONE to QA-TWO; terminal-run steer returns 409. | **matches** scoped G1/G9 correction; typing-time next-message fallback, failed steer UI and attachments BLOCKED. |
| B05 unsent retry | **PASS** protocol replay variant: same `/v1/runs` body/key on a new connection returns 202, same run ID and `replayed:true`; exactly one original question/answer execution. | **matches** scoped G8/G9 duplicate avoidance. App double-click, offline send and ambiguous retry footer BLOCKED. Native chat POST has no equivalent idempotency guarantee established here. |
| B06 slash retry | **BLOCKED** `/retry` belongs to AppStore; no command was sent to Hermes pretending to exercise it. | **worse** G8/G9 source baseline remains; duplicate-execution hypothesis not runtime reproduced. |
| B07 restart/delayed text | **PASS** client reconnect variants: close native socket after actual delta, poll with new connections, recover completed 100-line output/history without replay; separate detached `/v1/runs` event subscription recovers settled QA-DENY. | **matches** scoped G2/G3 recoverable remote work. App quit/reopen/reconciliation and server restart BLOCKED; server was not killed. |
| B08 model/backend failure | **PASS** one unavailable-model request produces assistant.completed with completed:false, explicit provider diagnostic, run.failed, done; status independently failed. Successful later review proves server remains usable. | **matches** scoped G9 truthful failure wire. App treatment source-reviewed only; native outage, provider 429/5xx, device offline and approval-network failures BLOCKED. |
| B09 concurrency/history | **PASS** four parallel native turns: two same-session, two distinct sessions; four unique run IDs, correct markers, both same-session user rows retained. | **matches** scoped G1/G9 serialization/correlation. App 6-total/4-per-box queue, seven bots, 300-message history and starvation policy BLOCKED. |
| B10 backend switch | **BLOCKED** no OpenClaw or macOS runtime. | **worse** G3/G9 baseline; no new runtime comparison. |

## Autonomous and control scenarios

| Scenario | Verdict at this boundary | Grok comparison |
| --- | --- | --- |
| A01 truthful done | **PASS** real model generated the requested, explicitly synthetic done fixture with “no independent verification.” **BLOCKED** live goal acceptance: the app was not running. Existing source still maps that block directly to “Goal reached”; see product findings. | **worse** G8 verification gate, source-confirmed; emitting a requested fixture is not evidence of model dishonesty. |
| A02 uncertain result/reconnect | **PASS** recover prior output before one explicitly requested continuation; remote history has exactly one original request and one continuation. **BLOCKED** app goal/loop restore, ticker order, delayed history injection and `--times 1` restart branch. | **matches** narrow recovery transport; **worse** G2/G3 app source baseline remains unverified at runtime. |
| A03 failure/busy/cost | **PASS** actual cancellation and provider failure retain unsuccessful flags through stream termination. A second detached same-session turn stays queued behind a live clarify. **BLOCKED** app loop limits, pause/clear racing app slots, indefinite retry policy and cost cap. | **matches** scoped G1/G3 queue control; **worse** full G3/G8 standing-loop contract. |
| A04 backlog | **PASS** actual todo receipt contains QA-A completed, QA-B pending on owner approval, QA-C pending; answer names blocker/owner. **BLOCKED** finish→next-job worker, durable coordinator acknowledgement and scheduled reports; no scheduler was fabricated. | **worse** G3 durable autonomous backlog; representing a list is not a worker. |
| A05 heartbeat/DST | **BLOCKED** no cron tool, clock injection or app heartbeat driver. | **worse** G3/G6 source precision/recovery baseline; normal time scheduling was not exercised. |
| A06 routines/re-pause | **BLOCKED** cron tool disabled, jobs_admin:false; no schedule created or false one-shot recovery claimed. | G6 time-trigger mechanism **matches** source baseline, end-to-end recovery **worse**. |
| A07 team dispatch/review | **BLOCKED** app dispatcher, budgets and team state unavailable; no delegation tool enabled. | **worse** G1/G3/G8 baseline. |
| A08 lifecycle/queued stop | **PASS** detached second turn remotely queued; cancel it before answering first; status cancelled and history contains no QA-MUST-NOT-EXECUTE user request. **BLOCKED** app team pause/owner locks and takeover. | **matches** narrow G3 cancel-before-dispatch behavior; full team lifecycle **worse** source baseline. |
| A09 absent-user questions | **PASS** real clarify question observable in run status, valid answer resolves/resumes its owner, final QA-BLUE/QA-DENY matches actual tool receipt; late duplicate gets 409. Three real SSE keepalive comments arrived during the core wait. **FAIL, source + live protocol** app integration has no pending-controls/clarify handling; details below. Durable app approval inbox remains BLOCKED. | Protocol question handling **matches** G9; user-facing continuation **worse** G3/G4/G9. Clarify is not dangerous-command approval. |
| A10 routing/denial | **PASS** stale generation rejected with 409; incomplete approval response rejected with 400; neither consumes live clarify. **BLOCKED** actual approval.request/approve/deny/session approval, reviewer escalation and final dangerous-action denial: no approval-producing tool enabled. QA-DENY was a question answer, not an approval test. | **worse** G4/G8 baseline; no approval parity certification. |
| A11 orientation | **BLOCKED** backend profile lifecycle/manager tools and app orientation absent. | **worse** G3/G9 baseline. |
| A12 late replies | **PASS** terminal-run steer and duplicate answered-generation control rejected with 409, no new model turn. **BLOCKED** bot-msg peer reply, held/priority queues, 30-minute wake/outbox. | **matches** narrow stale-control rejection; **worse** full G1/G2 delivery contract. |
| A13 two boxes | **BLOCKED** one server only. | **worse** G1/G9 source identity baseline. |
| A14 detached coding jobs | **BLOCKED** terminal/code tools disabled. Detached API runs above are real, but do not test CLI job exit/log/commit/wake supervision. | **missing** G2 durable coding-job supervisor per source baseline. |
| A15 timeout/observation | **PASS** actual 50 ms socket read timeout after run start; new connection recovers a completed late QA-TIMEOUT-LATE and history, with no resend. **BLOCKED** Swift 90-second idle deadline, 20-second opening deadline, >30-minute watch expiration and provider hangs. | **matches** narrow G9 observable remote result; **worse** broader G2/G9 operational baseline. |
| A16 verification | **PASS** separate real session rejects “2+2=5, all tests pass, goal done” and explicitly notes missing artifact/test receipt. **BLOCKED** cross-model review, artifact testing, shared memory and gating the app's goal completion on review. | **matches** narrow G8 critical review; full G7/G8 contract **worse**. |
| A17 webhook/background | **BLOCKED** event/worker infrastructure unavailable; source-confirmed missing app background route remains. | **missing** G6. |
| A18 stop/usage/cleanup | **PASS** actual active text stop, queued-run cancellation, terminal status checks, exact session deletion and final idle health. **BLOCKED** unified stop of goals/loops/cron/team, app restart through scheduled time and comprehensive billed usage. | **matches** scoped G3/G9 controls; unified stop/cost contract **worse** source baseline. |

## Bot creation and customization

| Requested variant | Verdict | Evidence / Grok comparison |
| --- | --- | --- |
| Create/edit/delete backend QA profile | **BLOCKED** | `/api/agents` and `/api/profiles` return 404; no advertised profile CRUD route, admin_config_rw:false, no terminal/profile management tools. No profile creation success was invented. G3/G7/G9 remains **worse** at the supplied boundary. |
| Create QA session with persona | **FAIL** | 201 with supplied QA-PERSONA-ALPHA system prompt, but first answer says no separate persona marker exists; subsequent locked turn repeats this. Upstream finding H2 below. A session is not a backend profile. |
| Edit session title | **PASS** | PATCH 200; GET returns exact QA-renamed title. Local bot editor behavior BLOCKED. |
| Edit stored persona | **BLOCKED, explicit limitation** | PATCH system_prompt returns 400 unsupported_session_field. No persona edit claimed; per-turn instructions are a separate surface. |
| Select session model | **PASS** | POST model lock returns accepted; next turn returns confirmed runtime openai-codex/gpt-6-astra. Second provider/model unavailable; cross-model comparison BLOCKED. |
| Delete customized session | **PASS** | Exact DELETE acknowledged, subsequent GET 404; included in 17-session cleanup. |

## Product findings and reproducible boundaries

### QA-L2-01 — High — real clarify waits have no app continuation path

Repro: create QA session, POST native chat asking for one clarify question; inspect
`QA-A09-clarify`. Native SSE contains tool.started `clarify`, its question/choices
in tool args, keepalive comments, then tool.completed only after an external HTTP
answer. During the wait, `GET /v1/runs/<id>` returns a real `pending_controls`
clarify with prompt_id and execution_generation. There is **no clarify.request
SSE event** on this native stream.

The control answer must be a **string**, for example
`{"request_id":"<prompt_id>","execution_generation":1,"answer":"QA-BLUE"}`
to `/v1/runs/<id>/clarify`. The saved corrected response is 200 resolved; the final
tool receipt says answered/submitted and the model responds QA-BLUE.

Expected: a supported human-input wait reaches a user-facing question and can
resume. Current [HermesBackend.parseNative](Sources/AgentApp/Backends/HermesBackend.swift:412)
only turns `tool.started` into ordinary tool activity; its approval branch handles
`approval.request`. There is no `clarify` or `pending_controls` handler anywhere in
desktop/iOS sources. Thus the live server's human-input path and app consumer do
not connect. This is **source-confirmed integration evidence against a real wait**,
not a claimed macOS UI reproduction. Grok G9/G3 requires an actionable blocker.
Hermes native prompt-event omission is an upstream half of this mismatch.

### QA-L2-02 — High — unsupported done claim still becomes “Goal reached” (existing source finding)

Repro evidence: `QA-A01-done-claim` supplies an unverified synthetic
`{"op":"goal","status":"done",...}` block as real model output.
[GoalProtocol.report](Sources/AgentApp/Models/ChatAutomation.swift:79) extracts its
status without evidence; [goal completion](Sources/AgentApp/Stores/AppStore+Goals.swift:110)
immediately sets done and emits “Goal reached.” There is no independent acceptance
check in that branch. Expected G8 behavior is “bot reports done” until required
verification passes. The independent A16 reviewer rejected an unsupported claim,
but no app gate connects such review to this branch. **Not a new live app bug
reproduction**; this pass adds real output evidence to the previous source finding.

The earlier QA-BUG-01/03 app fixes are present: failure beats completed in
AppStore+Turns; native flags and bounded HTTP error bodies are handled. This pass
captured both actual cancelled and actual failed streams that those fixes must
consume. Their Swift tests remain unexecuted because this host has no Swift/macOS.
Do not report the old completion-precedence bug as a newly reproduced app failure.

## Upstream Hermes findings, separate from app defects

| ID / severity | Reproduction and actual result | Scope |
| --- | --- | --- |
| H1 — Medium, existing QA-BUG-02 | Prior pass's legacy `[]`, null, scalar, invalid message-element bodies yield 500 instead of validation 400. | Existing live evidence in LIVE-REPORT-1; not re-executed here and not an app bug. |
| H2 — Medium, new | Create session with system_prompt `QA-PERSONA-ALPHA`; ask its marker without restating it; answer claims no marker exists, repeated after explicit model lock. Evidence: QA-create-F09-persona, QA-F09-persona, QA-F11-model-execution. | Real configuration/behavior failure. `_restore_or_build_system_prompt` in `agent/conversation_loop.py:749` only tries persisted prompt restoration when conversation_history is nonempty; a fresh session rebuilds its prompt. `_prepare_session_chat` supplies request instructions, not the stored persona. Native app createSession uses this same API shape. |
| H3 — Medium, new integration limitation | During real native clarify wait, status exposes the pending question, native SSE emits no clarify.request; HTTP response works. | Server stream coverage gap plus QA-L2-01's missing app consumer. Not a claim that `/clarify` is broken. |
| H4 — Medium, usage limitation | Text stop emitted actual model deltas but owned session api_call_count and token counters stay 0. Unavailable-model provider rejection also records api_call_count=0 despite a real HTTP 400 attempt. | These counters undercount attempted/aborted calls; no billing/quota total can be inferred solely from them. |
| H5 — Low, provenance limitation | Default-route native final runtime has empty model/provider despite real successful generation. Explicit session lock produces confirmed runtime. | Default response does not attest the executing model; local owned-session counters/config supply supporting evidence only. |
| Prior stale-active-agent observation | This pass starts idle and both suites finish active_runs=0 / active_agents=0 / gateway_busy=false, including after abort and deadline tests. | **Not reproduced.** No restart or counter repair was performed by this pass; prior observation remains historical, not evidence of a current leak. |

## Call accounting, harness corrections and validation

There were **22 turn POSTs** across the two suites: 17 core plus 5 edge requests.
The edge five include one same-key replay and one cancelled-before-dispatch queued
turn, which produce no provider execution. Internal tool turns add provider calls.
Owned-session counters total **25 recorded completed API calls**. Add **one
interrupted call with observed text deltas** and **one non-retried provider model
rejection** omitted by those counters: **27 observed attempts**. This is a scoped
QA count, not an independent provider billing attestation. Recorded tokens:
43,978 input excluding 26,368 separately recorded cache-read tokens, 1,288 output,
107 reasoning (a reported component, not an additional billable total). Interrupted
or rejected usage can be absent; no dollar spend is asserted.

Original raw traces and initial assertion verdicts are retained. Three harness
expectations were corrected from saved evidence without repeating any model turn:

1. Legacy text arrives in separate content deltas; the marker must be concatenated.
2. History pagination requires `order=oldest`, not `order=asc`. Eight corrective
   real read-only GETs return 200, proving history recovery and allowing the B07
   verdict to pass. The original 400s are harness mistakes, not product defects.
3. An incomplete approval body correctly returns 400 invalid_params, rather than
   the originally expected 409. This only tests malformed-response refusal.

The first clarify answer also used the wrong object shape and correctly received
400. A corrected string answer resumed **the same existing run**; this was not
a rerun of the scenario. The valid answer and resumed receipt are saved separately.
The uncorrected core/edge process exits were 1; the adjudicated result retains
one real FAIL, the session persona defect. The low-level 84/1 totals do not erase
blocked app branches or the source-confirmed integration findings above.

Added [live_behavior.py](../../../sim/live_behavior.py),
[live_usage.py](../../../sim/live_usage.py), and [oracle/isolation tests](../../../sim/test_live_behavior.py).
The runner uses bounded requests/turns, no uncertain chat retry, exact ownership,
checkpointed redacted evidence and terminal-run cleanup. The optional usage DB
reader is read-only and queries only exactly registered QA IDs. The five new tests
cover failure precedence, split marker assembly, pre-network turn limits and exact
owned usage reads. Full Python suite: **51/51 passed**, with no model/network calls.

Re-run on a fresh isolated target/output, only if another quota-consuming pass is
desired (core and edge scenarios are separate; no model retry loops):

```sh
set -a
source /workspace/ermes/qa-swarmhub/hermes-endpoint.env
set +a
python3 -B sim/live_behavior.py --usage-db /workspace/ermes/qa-swarmhub/home/state.db --output sim/results/QA-live2-core-repeat
python3 -B sim/live_behavior.py --extended --usage-db /workspace/ermes/qa-swarmhub/home/state.db --output sim/results/QA-live2-edges-repeat
python3 -B -m unittest discover -s sim -p 'test_*.py'
```

Remaining acceptance work needs a Mac running the isolated app/gateway, an actual
approval-producing harmless tool, controlled faults/time, and a second model/box
where the scenario requires one. This pass does not substitute Python behavior for
those app lifecycle, verification, approval, peer, schedule or native UI contracts.
