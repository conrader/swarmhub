# LIVE QA pass 3 — replay of observed Grok team interactions

Executed 2026-10-19, 09:02:36–09:03:35 UTC (11:02–11:03 Warsaw), against the
isolated QA Hermes at `127.0.0.1:8742`. Swarm Hub checkout:
`730a23c4058a15a12aa8d17d7a1643dadbe8260b`. No commit or product-code change.

**Actual asynchronous peer replies and late reply routing work at this boundary.
Held/priority delivery, durable coding-job wakes, automatic retry and universal
coordinator policy remain weaker than the observed Grok behavior.** A held FYI
immediately caused two model turns, including forwarding `NO_REPLY` back to its
sender. The reversible allowlisted action ran without asking and had a real tool
receipt. Coding, provisioning, approval and notification enforcement were not
available on this QA server and are not certified by the models' replies.

The replay used **four QA roles, eight real sessions, 15 successful model turns
and 17 recorded provider calls**. Pass 2 recorded 27 observed attempts; together
these total **44**, below the brief's approximately 60-call shared allowance.
All 15 runs were terminal; all eight sessions were deleted and individually
verified absent. Final health: zero active runs, zero active agents, gateway idle.

## Baseline and method

The final UPDATE controls scenario selection. Every P01–P10 below corresponds
one-to-one to entries 1–10 in
[grokbot-observed.md](/home/box/work/swarmhub/grokbot-observed.md).
Also read the [QA plan](/home/box/work/swarmhub/wt-qa/QA-PLAN.md),
[comparison](/home/box/work/swarmhub/grokbot-comparison.md), and
[pass 1](LIVE-REPORT-1.md) / [pass 2](LIVE-REPORT-2.md).
The observed file is a ten-entry summary, not a complete transcript. The replay
preserves its participants, message direction, quoted fragments and operating
rules, adds QA annotations, and explicitly labels substituted work. It does not
claim byte-for-byte reconstruction of unavailable messages or a fresh Grok run.

Added [live_observed.py](sim/live_observed.py). It executes the **unchanged**
bundled [bot-msg](Resources/Skills/swarmhub-messages/scripts/bot-msg), not a Python
replacement for its background and reply-handling logic. A temporary loopback
bridge maps `/p/QA-<role>` and the script's `swarmhub-from-<sender>` IDs onto exact
`QA-LIVE3-…-QA-<recipient>-from-QA-<sender>` sessions on the single-profile server.
All upstream session titles and IDs begin `QA-`. This prevents collisions between
recipients without modifying the bundled script. The bridge forwards real Hermes
answers and tool events; it supplies no model results, simulated tool receipts,
queue, error response, delay or completion-wake implementation. SSE JSON data is
relayed in newly framed events; this is not a byte-preservation test.

Roles are `QA-Jarvis`, `QA-Swarmhub`, `QA-Infra`, `QA-Ermes`. They are separate real
session namespaces, **not four provisioned backend agents**, processes or security
identities. The runner initiates sends and fan-out: the model cannot invoke a peer
tool on this server. Per-turn instructions identify the recipient, prohibit false
execution claims, permit at most one explicitly requested todo call, and request
`NO_REPLY` when no action remains. These are QA instructions, not proof that the
installed product would enforce those rules without them. Stored session personas
are not relied upon; pass 2 found their fresh-session limitation.

Only `todo` and `clarify` were enabled, checked before running. There was no
terminal, coding, file, outbound, provisioning, peer or cron tool. Linux has no
Swift executable or native app runtime. App conclusions below are source review;
the separately attested macOS QA adapter was not invoked or bypassed. No server
config, model setting, production resource, schedule or real outbound connector
was changed. The supplied QA key was sourced without printing it; temporary
owner-only profile credential files and the routing server were removed afterward.

## Ten observed patterns, grades and reproduction

Grades are **matches / worse / missing / better** against the supplied observed
behavior. A grade can be limited to an executed subpattern. **BLOCKED** describes
an execution boundary, not a model or product failure. An unavailable QA tool is
not by itself evidence that Swarm Hub cannot do the operation on a fully equipped
server. There is no supported **better** claim.

Trace labels below refer to [raw requests, replies and commands](sim/results/live-3/results.json).
`P…` labels identify entries in its `commands` array; `QA-bridge-…` labels identify
actual upstream requests. Saved histories contain authoritative tool receipts.

| Observed pattern | Replay and actual result | Grok grade and remaining boundary |
| --- | --- | --- |
| **P01 / observed 1 — job result → Jarvis relay → next action** | `QA-Jarvis → QA-Swarmhub`, `--no-wait`, preserves “Review the result now and take the next step.” It returned in **0.032 s**. `QA-bridge-002` performed one real todo call; `004` delivered the worker's result into `QA-Jarvis-from-QA-Swarmhub`. The supplied exit-zero receipt was explicitly a QA message fixture; no code job ran. | **worse** overall; asynchronous coordinator relay **matches**. Automatic CLI completion producer, commit, rebuild and next-job launch **BLOCKED**. A todo list is not an autonomous coding queue. Source still lacks a durable completion/wake service. |
| **P02 / observed 2 — unknown origin fallback and Infra's webhook request** | `QA-Infra → QA-Swarmhub`, `P02-fallback-webhook`, replays the unknown-launching-agent/Jarvis fallback context and asks to register the webhook with user-only key visibility. `QA-bridge-006` explicitly reports no registration/secret-storage tool, no routine and no generated key. | **missing** durable unknown-origin wake fallback/webhook registration path in the reviewed Swarm Hub implementation. Message transport **matches**; real fallback and registration **BLOCKED** here. No fake webhook, key or success was substituted. |
| **P03 / observed 3 — held FYI versus priority action ask** | `QA-Swarmhub → QA-Ermes`: held FYI via closest available `--no-wait`; `QA-bridge-008` immediately executes and answers `NO_REPLY`. `010` forwards that literal answer to Swarmhub, causing another `NO_REPLY` turn. The action ask is P06 below, not a second invented task. | **worse**, live gap plus source confirmation. No held/priority flag or scheduler exists in `bot-msg`. “Priority” in message text is not priority admission. Normal async delivery **matches**; held delivery and suppression of unnecessary reply wakes do not. Busy-target ordering was not tested. |
| **P04 / observed 4 — coordinator corrects empty job, model/effort and missing report** | `QA-Jarvis → QA-Swarmhub`, `P04-coordinator-correction`, supplies the recorded “no report, default model, effort none” correction, explicit Codex/high-effort requirement and absent QA report path. The runner checked absence. `QA-bridge-016` attributes that fact to the runner and refuses to claim independent file verification, rerun or model change. | **worse** full contract; truthful handling of the correction **matches** in this reply. Actual file check by the bot, explicit worker model/effort and corrective relaunch **BLOCKED**. Source `code-job` invokes `codex exec --full-auto` without explicit model/effort flags; goal completion still accepts self-reported done without a universal artifact gate. |
| **P05 / observed 5 — Jarvis quota broadcast, Claude 95% → Codex, no speculation** | `QA-Jarvis` sends the recorded instruction to each of the other three QA roles. `QA-bridge-018`, `020`, `022` all complete with `NO_REPLY`; no tools/jobs are started. | **worse** policy automation; delivery to all addressed peers **matches**. Fan-out came from the runner, not a global quota subscriber. Sessions already used Codex, so no route change was demonstrated. A prompt saying “Codex” is not model-switch evidence. |
| **P06 / observed 6 — Swarmhub asks Ermes to provision QA Hermes, secrets by file path** | `QA-Swarmhub → QA-Ermes`, `P06-priority-provision`, asks for provisioning, a chmod-600 secret-file path and a user-supplied model key. `--wait 1` returns **124 after 1.035 s**. `QA-bridge-012` finishes after **4.337 s**; `014` delivers that exact late result to Swarmhub. Ermes states it cannot provision/create the file and asks for the model provider/key through secure input, without a secret or invented path. | **worse at the supplied boundary**; timed-out ask, late reply and return routing **match**. Provisioning/file permissions, Ermes's direct user key-acquisition channel and actual priority scheduling **BLOCKED**. Tool unavailability is not a confirmed provisioning defect in the complete app/server product. |
| **P07 / observed 7 — Konrad/Jarvis gates and changed-scope kill/relaunch** | `QA-Jarvis → QA-Swarmhub`, `P07-gates-scope-update`, replays money/prod/secrets → Konrad, outbound text → Jarvis, and the user scope correction. The message explicitly states there is no live coding job. `QA-bridge-024` names the gates and does not claim a kill or relaunch. | **worse**, source-level policy integration; truthful reply **matches**. No real approval decision, outbound draft/send, CLI termination/relaunch or peer cancellation propagation was exercised. The app has configurable approval routes and workflow cancellation, but not a universal coordinator/risk/denied-intent contract binding the shell peer path. |
| **P08 / observed 8 — Konrad+Jarvis 08–23 Warsaw, Jarvis only otherwise** | `QA-Jarvis → QA-Swarmhub`, `P08-reporting-hours`, preserves the exact reporting rule. At actual **11:03 Warsaw**, `QA-bridge-026` identifies Konrad+Jarvis and states no send occurred. No clock was fabricated. | **worse** enforced routing; current-window policy interpretation **matches**. Overnight delivery **BLOCKED**. Source has timezone-aware team quiet hours and notification suppression, but that is not the observed universal two-recipient/one-recipient router. Orientation is prompt-based and defaults to 22–08, configurable separately. |
| **P09 / observed 9 — “each action should be autonomous,” allowlist, outbound FAKE** | `QA-Jarvis → QA-Swarmhub`, `P09-autonomous-allowlist`, supplies that user rule. The harmless substitute is one authorized todo write. `QA-bridge-028` calls todo once without clarify. History receipt contains **QA-autonomous completed** and **QA-outbound pending, FAKE**, revision 2; final reply accurately reflects it. | **matches for the executed reversible action and FAKE representation**. This does not certify an enforced outbound stub or global allowlist. Actual outbound tools were disabled; general connected-app reads still ask by default in source, so the full product autonomy policy remains **worse**, source-only. |
| **P10 / observed 10 — target offline, truthful failure, later retry** | `QA-Infra → QA-Ermes`, `P10-offline-target`, uses a genuinely bound but non-listening temporary loopback target. Unchanged `bot-msg` exits **3 in 0.020 s**, “gateway … did not answer,” before creating a remote session/model turn. After the runner restores its local bridge URL, `P10-later-retry` succeeds; `QA-bridge-030` cautiously confirms only message receipt. | **worse** autonomous retry; real unreachable diagnostic **matches**. Later retry was initiated by the runner. No persistent retry worker was installed, and no production host was contacted or taken offline. |

## Findings and concrete reproduction

### L3-01 — held delivery and quiet reply suppression are absent from the shell path

Within the QA runner, reproduce P03 using the unmodified command shape:

```sh
bot-msg --from QA-Swarmhub --to QA-Ermes --no-wait -- '[QA-TEST] FYI, held until your next turn: QA Hermes is for this team QA pass. No action requested.'
```

The saved `QA-bridge-008` request starts a real model run immediately and returns
`NO_REPLY`. `QA-bridge-010` has input
`[Reply from QA-Ermes via SwarmHub]\nNO_REPLY`, starting the sender's model turn.
The [script log](sim/results/live-3/QA-bot-messages.tsv) records queued and late-reply
delivery as successful. This is not a held queue or a quiet no-op. The two model
turns took 1.499 and 1.698 seconds respectively. The bridge adds no hold or wake
logic; these requests come from the script itself.

Source corroboration: `bot-msg` argument parsing, lines 24–41, only accepts
to/from/wait/no-wait. `deliver_late`, lines 181–205, forwards any nonempty
successful answer, with no silent-marker suppression, retry outbox, acknowledgement
or correlation ID for individual asks. This confirms an existing documented gap
with real generated replies; it is not presented as a newly introduced defect.

### L3-02 — delayed replies reach the asking peer; transport loop suppression works in this replay

P06 is the slow action ask already observed in the team. Use `--wait 1` on that
provisioning message. The caller's actual timeout is retained in `commands`; the
later answer and reverse request are `QA-bridge-012` / `014`. The latter includes
the complete provisioning blocker and secure-key question from the former. No
second copy of the ask or answer was submitted to Hermes.

P01 similarly sends the real worker result to the original asking coordinator,
not Infra or Ermes. Across the run, saved histories have **15 user rows for 15
distinct run IDs and 15 submitted turns**. All late-worker folders finished;
a further bounded two-second observation saw no new turn. Source deliberately
does not attach a follow-up to `deliver_late`'s reverse POST; the message skill
also instructs recipients not to answer delivered replies back through `bot-msg`.
This supports the bounded route/loop result. There is no durable operation-ID
deduplication guarantee for a repeated intent or independent late asks sharing
the same sender/recipient session.

### L3-03 — receipts distinguish reported work from verified work

P01's model omitted IDs from the two requested todo entries; the real tool
receipt retained only the pending QA-build item under ID `?`. Its final reply
explicitly said the receipt did **not** confirm QA-review complete. This was not
a successful two-item queue update, and the runner's P01 PASS only concerns reply
routing. No rerun was used to conceal or repair the result. P09 supplied distinct
IDs and the real receipt contains both requested entries. The complete receipts
are extracted in [audit.json](sim/results/live-3/audit.json).

P04 likewise distinguishes the runner's absent-file observation from the bot's
own verification. These are useful observed truthful replies under explicit QA
instructions. They do not repair the app's source-confirmed gap:
[goal completion](Sources/AgentApp/Stores/AppStore+Goals.swift:110) still maps a
done report directly to “Goal reached”; team evidence is optional by default in
[TeamCoordination](Sources/AgentApp/Models/TeamCoordination.swift:13).

### Enforcement boundaries from the requested patterns

- **Jobs, fallback and automatic next work (P01/P02/P04/P10):**
  [code-job](Resources/Skills/swarmhub-coding/scripts/code-job:75) logs exit and
  resource summaries and removes temporary output. It has slots, CLI fallback and
  process-tree termination, but no stable ordering-task job record, completion
  outbox, Jarvis fallback routing, retained commit/log evidence or scheduled wake
  retries. App teams do dispatch dependencies, but require the app dispatcher;
  the shell messaging path is separate.
- **Gates and final denial (P07/P09):**
  [regular approvals](Sources/AgentApp/Stores/AppStore+Approvals.swift:10) resolve
  and audit a particular request ID; configurable Ask/Approve/Reviewer/Deny routes
  exist. No task-level denied-intent journal was found on that path. The stronger
  fixed-intent refusal in DEBUG QA mode was not exercised and does not establish
  general app behavior. [Draft Send](Sources/AgentApp/Stores/AppStore+CardActions.swift:53)
  submits “Send it,” without an execution grant binding all outbound fields.
  Approval bypass or denial-resubmission was not attempted on an absent tool.
- **Cancellation (P07):**
  [pauseWorkflow(cancel:)](Sources/AgentApp/Stores/AppStore+Workflows.swift:176)
  cancels queued tasks and stops related app-owned active turns. Policy revocation
  and queued-work cancellation explicitly allow already-sent work to finish.
  `bot-msg` has no shared task cancellation tree. Do not describe all cancellation
  as missing; shell-peer propagation and observed kill/relaunch remain unverified.
- **Reporting (P08):**
  [TeamReporting](Packages/SwarmHubCoordination/Sources/SwarmHubCoordination/TeamPolicy.swift:45)
  supports an IANA timezone and wraparound quiet window.
  [Team notifications](Sources/AgentApp/Stores/AppStore+TeamRecovery.swift:100)
  skip user notifications during that window. This is narrower than delivery to
  Jarvis throughout the night and to both people during 08–23.

Per the UPDATE, there were no additional invented crash/restart, deliberate
provider-failure, duplicate-intent, denial-resubmission or simulated overnight
scenarios. Changed-scope kill/relaunch belongs to P07 but needs an actual coding
job. Such unexecuted branches are not claimed to match Grok.

## Evidence, accounting, validation and cleanup

- [Raw run](sim/results/live-3/results.json): run
  `QA-LIVE3-20261019T090236-30ca1f`; **73 HTTP requests**, 15 native turn POSTs,
  eight exactly registered sessions, 15 distinct terminal runs.
- [Read-only audit](sim/results/live-3/audit.json),
  [script delivery log](sim/results/live-3/QA-bot-messages.tsv),
  [process log](sim/results/QA-live3-run-log.txt),
  [discovery](sim/results/live-3-discovery/results.json),
  [source/input hashes](sim/results/live-3/QA-provenance.json).
  Discovery made four additional read-only requests and no model calls. The
  initially tried `/api/capabilities` returned 404; the replay uses the correct
  `/v1/capabilities`. This route correction is not a product defect.
- [Owned-session usage snapshots](sim/results/live-3/usage-snapshots.json):
  **17 recorded API calls, two todo invocations**, 25,759 input tokens excluding
  25,856 separately recorded cache-read tokens, 566 output tokens, 12 reasoning
  tokens (a reported component). Session records identify `gpt-6-astra`; native
  default-route runtime model/provider fields remain empty as in pass 2. No new
  model attestation or cross-model review is claimed. There were no interrupted
  or rejected provider turns in this pass; the failed offline connection never
  reached the provider. Counters are not an independent billing attestation.
- The new runner bounds turn POSTs at 18 and reserves headroom below a 23-recorded-
  call ceiling, checking usage before new turns. Tool bounds are instructions,
  not a server-enforced monetary cap. This run's 17 plus pass 2's 27 gives **44
  observed attempts**; pass 1 had no configured-provider executions.
- The process exited **2**, correctly indicating incomplete coverage. Raw results
  contain **30 PASS / 0 FAIL / 6 BLOCKED assertions**; 23 PASS checks concern
  terminal runs and session cleanup. `P03-FYI-wakes-immediately` PASS means the
  held-delivery gap was successfully reproduced, **not** product parity. The
  ten-pattern grades above, rather than raw assertion totals, are the comparison.
- [56 Python harness tests passed](sim/results/QA-live3-harness-tests.txt),
  including five new [namespace/refusal tests](sim/test_live_observed.py).
  They are offline harness tests, not app or Hermes acceptance evidence.
- Cleanup polled all 15 runs to completed, deleted each exact owned ID, checked
  eight independent 404s, and retained the final idle health response. All local
  late workers finished; the owner-only temporary credential tree was removed;
  the bridge was shut down. No schedules, jobs or outbound operations were created.

To reproduce only this observed-pattern pass on a fresh isolated output, with
another model-call allocation:

```sh
set -a
source /workspace/ermes/qa-swarmhub/hermes-endpoint.env
set +a
python3 -B sim/live_observed.py \
  --usage-db /workspace/ermes/qa-swarmhub/home/state.db \
  --output sim/results/QA-live3-new
python3 -B -m unittest discover -s sim -p 'test_*.py'
```

Existing captures were preserved. No commit was made.
