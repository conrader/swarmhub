# Live pass 4: the ten observed Grok team patterns

**Five patterns match at the tested managed-runtime boundary; five remain
worse or blocked in part. This is not a live 10/10.** Durable failure wakes,
unknown-origin fallback, held context, policy enforcement, final denial and
automatic offline retry now have evidence beyond pass 3's message fixtures.
Successful coding, real provisioning, webhook registration and active coding
scope replacement remain unverified here.

Executed **2026-10-19 11:06:22–11:07:37 UTC / 13:06:22–13:07:37 Warsaw**.
Checkout **`56ca8b1`**, bundled messaging/coding skills and peer plugin **1.3.1**.
Only the QA runner, evidence and this report were added. No product fix, commit,
Hermes source/config/plugin installation, restart, real provisioning or external
send was performed. All outbound action records are **FAKE**.

## Baseline and boundary

Read the [QA plan](../wt-qa/QA-PLAN.md),
[Grok comparison](../grokbot-comparison.md),
[observed interactions](../grokbot-observed.md), and
[passes 1](LIVE-REPORT-1.md), [2](LIVE-REPORT-2.md), [3](LIVE-REPORT-3.md).
P01–P10 below map directly to observed entries 1–10. The observed file summarizes
the real interactions; it does not contain complete original prompts or coding
briefs. The replay preserves its roles, directions, quoted instructions and
rules, with explicit QA substitutions. No additional failure scenario or new
Grok behavior was invented. Grok itself was not run again.

[live_managed.py](sim/live_managed.py) executes the **unchanged shipped**
`swarmctl`, `code-job`, and `bot-msg --durable`, plus held and asynchronous
priority messages. A temporary loopback bridge maps five local QA profile names
onto nine real, distinct sessions on the single-profile QA Hermes at
`127.0.0.1:8742`. Roles: QA-Jarvis, QA-Swarmhub, QA-Infra, QA-Ermes, QA-Konrad.
These are session namespaces, not five independently provisioned Hermes agents.

Because Hermes must remain unchanged, the bridge invokes the shipped
`before_turn` / `after_turn` functions in isolated local subprocesses and supplies
their actual context to real Hermes turns. **This exercises hook functions and
their journals, not Hermes plugin installation, hook discovery or normal gateway
activation.** SSE content comes from Hermes; the bridge reframes JSON events.
There are no synthetic model answers, fake curl responses, fake coding CLIs,
fabricated successful report files or completion receipts.

Hermes enabled only `todo` and `clarify`; neither was invoked. This host has no
Codex/Claude coding CLI. The runner initiates managed commands, sends and policy
changes; the model cannot invoke those commands through this server's tools.
Per-turn QA instructions prohibit false execution claims, tools and outbound,
and request `NO_REPLY` for result-only/FYI turns. Thus bot-selected delegation,
unprompted tool use and stock installation behavior are not certified. Approval
denials below are labelled **local administrative fixtures**, not human decisions
or authenticated messages from Konrad's real account.

## Per-pattern grades and comparison with pass 3

`matches` is limited to the stated executed managed contract. `worse` includes
unfulfilled portions of the observed pattern; an environmental blocker is
identified separately and is not automatically a product defect. There is no
supported `better` claim. The ten grades are **5 matches / 5 worse / 0 missing**;
the actual webhook subfeature remains missing.

| Pattern from the observed interactions | Pass 3 → pass 4 | Live evidence and remaining boundary |
| --- | --- | --- |
| **P01 — job done → Jarvis relay → next job without asking** | worse → **worse** | The real managed job `job.66ef6987bafd42e78aa85b9d02cd37d2` fails with **69**, `cli-exit: not-run`, explicit `gpt-6-astra` / `high`, and `report-exists: false`. Its durable wake reaches Jarvis in **QA-bridge-002**; Jarvis truthfully says no report or next-job execution is established. The second submitted job stays **queued**, behind the failed first job. Jarvis's durable relay/correction reaches Swarmhub in **004**. This is a real failure producer, queue and relay, improving on pass 3's supplied receipt. Successful commit/rebuild/verification and automatic next launch are **BLOCKED by no CLI**, not demonstrated by a model saying done. [Queue snapshot](sim/results/live-4/QA-P01-failed-queue.json). |
| **P02 — unknown launching agent → Jarvis fallback; Infra asks for webhook registration** | missing → **worse** | All five profiles register local `profile-gateway` subscriptions; output refers to a profile `.env`, never a key. Infra's request reaches Swarmhub in **006**. A real `code-job --origin QA-Unknown` failure produces `job.Iyn4cI88`; **008** goes to **Jarvis**, proving fallback. No webhook endpoint/routine or separate user-only webhook key is registered. The implemented authenticated profile-gateway subscription is an alternative transport, not evidence of that exact observed webhook setup. [Fallback record](sim/results/live-4/QA-P02-fallback.json). |
| **P03 — held FYIs; priority action asks** | worse → **matches** | `P03-held-FYI` returns `held:615813b7fc104a91b2e419ea77f643ca` with **zero HTTP/model turns**. Ermes's next priority action turn is P06; the real hook context in **010** contains the held FYI and policy. Its post hook marks that inbox row delivered. Unlike pass 3, no FYI-only `NO_REPLY` turn and reverse wake are produced. Durable FYI broadcasts in P05 each end `NO_REPLY` and produce no reverse turn. Automatic plugin activation on unmodified Hermes is **not tested**; ordinary priority's marker-filter branch is covered by the existing offline suite, not separately exercised live. [Held/late snapshot](sim/results/live-4/QA-P03-P06-held-and-late.json), [hook trace](sim/results/live-4/results.json). |
| **P04 — Jarvis corrects empty job, model/effort and missing report** | worse → **worse** | The correction shares P01's actual failed job and **004**, preserving “Review the result now and take the next step,” explicit Codex/high effort and report verification. The record independently confirms no report; Swarmhub accurately identifies the missing CLI and does not claim a fix. Model/effort are now durable fields, unlike pass 3. Actual CLI argv, an empty exit-zero job being rejected with 65, successful corrective relaunch and bot-side artifact verification are **BLOCKED here**; their offline regressions pass. [Audit](sim/results/live-4/QA-audit.json). |
| **P05 — Jarvis broadcasts Claude 95% → Codex, no speculative jobs** | worse → **matches** | Version **3** policy persists `route: codex`, `codex_model: gpt-6-astra`, `allow_speculative: false`. Durable broadcasts reach Swarmhub/Infra/Ermes in **014/016/018**, all answer `NO_REPLY`; all three subscriptions acknowledge revision 3. `swarmctl plan claude 0` returns **codex**; speculative coding admission exits **64** with “global policy forbids speculative jobs.” The 95% observation is supplied, not newly measured. Coding CLI dispatch and a chat-provider switch are not claimed. [Policy/acks](sim/results/live-4/QA-P05-policy-acks.json). |
| **P06 — Swarmhub asks Ermes to provision QA Hermes; secret-file path, user model key** | worse → **worse** | Priority `--no-wait` returns in **0.174 s**. Ermes completes in **3.497 s**, truthfully reports no provisioning/file tools, exposes no secret or invented path, and asks for secure user key entry. **012** routes that answer back to **Swarmhub**, which returns `NO_REPLY`; there is no recursive reply. A FAKE provision action with secrets risk waits on the owner and is denied by a labelled admin fixture. No actual host/file provisioning, chmod-600 secret artifact or secure key acquisition is tested. [Late routing](sim/results/live-4/QA-audit.json), `P06-provision-gate` / `P06-admin-fixture-deny` in [commands](sim/results/live-4/results.json). |
| **P07 — money/prod/secrets need Konrad; outbound needs Jarvis; changed scope kills/relaunches** | worse → **worse** | Money/prod/secrets actions each enter **awaiting-owner**. Local QA-Konrad fixtures deny them; re-submitting each exact denied action exits **64**, proving the denial journal rather than prompt compliance. Replacing an old scoped task cancels that parent and its peer child; the child's held message remains undelivered, and the replacement awaits a fresh owner decision. No obsolete child model turn occurs. **020** carries the scope/gate result to Swarmhub. A running coding process was not killed/relaunched. All outbound is FAKE, so the real outbound coordinator gate and user-facing approval routing were not executed; source supports the managed gate only. [Scope snapshot](sim/results/live-4/QA-P07-scope-cancel.json). |
| **P08 — report to Konrad+Jarvis 08–23 Warsaw, Jarvis otherwise** | worse → **matches** | At actual **13:07 Warsaw**, `swarmctl report QA-Swarmhub …` journals **two** recipients. **022** reaches QA-Jarvis and **024** reaches QA-Konrad; both complete with `NO_REPLY`, and both delivery rows become delivered. This executes routing and delivery, rather than pass 3's interpretation-only answer. The nighttime/DST branches are covered by existing offline tests; no clock was fabricated and no nighttime live delivery is claimed. These are QA receiving sessions, not OS notifications or real Konrad contact. [Report records](sim/results/live-4/QA-P08-report-delivery.json). |
| **P09 — “each action should be autonomous,” allowlist, outbound FAKE** | matches (scoped) → **matches** | Managed absolute `/bin/pwd` is admitted with **gate auto**, executes and records **done / exit 0**, without clarification or an approval decision. A FAKE outbound record contains exact QA recipient/text/argv, records **done / FAKE: no outbound operation executed**, and never creates its `touch` marker. This improves the evidence from pass 3's todo representation to a real local read and enforced non-execution. The runner invokes both actions; general model initiative and arbitrary connected-app policy are outside this result. [Autonomy snapshot](sim/results/live-4/QA-P09-autonomy.json). |
| **P10 — offline target: report unreachable, retry later, never fake success** | worse → **matches** | The runner actually closes its own loopback bridge listener while Hermes stays up. `bot-msg --durable` returns **pending**, not delivered, in **0.058 s**. The durable row records **attempt 1 / pending / exit 3; retained for retry**. Restoring the same listener allows the existing persistent worker to retry: **attempt 2 / delivered**, one real Ermes model turn (**026**). No caller resend, `tick`, fabricated error response or due-time edit was used. This advances pass 3's caller-initiated retry to a real unattended retry. [Offline record](sim/results/live-4/QA-P10-unreachable-pending.json), [recovery](sim/results/live-4/QA-P10-automatic-retry.json). |

## What still prevents a defensible 10/10

Swarm Hub-side remaining gaps or limits:

1. **Verification and follow-up are narrower than the observed coding workflow
   (P01/P04).** The shipped completion contract checks fresh, nonempty, changed
   report content and nonempty CLI stdout. It does not independently require a
   tested commit, passing rebuild or correct report. Wakes tell the ordering bot
   to take the next step; they do not implement commit/rebuild themselves.
   The separate [app goal path](Sources/AgentApp/Stores/AppStore+Goals.swift:110)
   still accepts a reported `done` without that evidence gate.
2. **Profile subscriptions do not implement the observed webhook routine/key
   registration (P02).** Fallback is now live-proven. Actual webhook management
   remains absent from this managed interface.
3. **Provisioning and secure user key intake remain integration work (P06).**
   `kind: provision` gates an immutable supplied argv; it does not supply a cloud
   provisioner or user secret-entry UI. The live model only returned a blocker.
4. **Approval/cancellation coverage is confined to managed records (P07).**
   The local decision interface and task tree now work, but do not themselves
   create a user approval card or intercept all app/terminal/connector actions.
   [Draft-card Send](Sources/AgentApp/Stores/AppStore+CardActions.swift:53) still
   posts “Send it”; it is not universally bound to the managed outbound record.
   Source declares the local same-account approval identity boundary; this pass
   does not turn fixture decisions into proof of real human/coordinator routing.

Required deployment/environment evidence, **not newly confirmed product bugs**:

- A real authenticated coding CLI is needed for successful P01/P04 jobs and P07
  kill/relaunch. No CLI was installed, impersonated or replaced by a stub.
- Hermes plugin activation must be checked through the normal install flow for
  bot/routine/app turns; the no-Hermes-changes constraint allowed only the local
  hook bridge here. Bots also need terminal access to invoke managed commands
  themselves. These omissions prevent claiming a fully autonomous deployed team.
- Real provisioning, owner/coordinator interaction and native macOS behavior
  remain untested. No claim of a new product failure follows solely from the
  supplied server's restricted tools. The offline 10/10 in
  [PATTERNS-REPORT](PATTERNS-REPORT.md) is retained as offline evidence.

## Evidence, accounting and cleanup

- [Raw requests, SSE, commands and hook context](sim/results/live-4/results.json),
  [compact audit with all answers](sim/results/live-4/QA-audit.json),
  [delivery log](sim/results/live-4/QA-bot-messages.tsv),
  [run log](sim/results/live-4/QA-run-log.txt),
  [source hashes](sim/results/live-4/QA-provenance.json).
- **13 submitted turns, 13 distinct terminal runs, 13 observed provider calls,
  nine sessions, five QA roles, 70 HTTP requests, zero model tool calls**.
  Owned-session [usage snapshots](sim/results/live-4/usage-snapshots.json) identify
  `gpt-6-astra`; they record 36,445 input and 336 output tokens, 12 reasoning tokens
  and 2,560 cache-read tokens. These are reported counters, not a billed total.
  Pass 2's 27 + pass 3's 17 + this pass's 13 = **57 observed provider calls**.
- All 13 model runs completed successfully **as conversations**. The coding job
  failures remain failures. **76 low-level checks passed**; this is not 76 product
  scenarios and does not override the per-pattern grades.
- `python3 -B -m unittest discover -s sim -p 'test_*.py'`: **113 passed**, including
  existing offline P01–P10 and shell/process-discovery regressions. See
  [test log](sim/results/live-4/QA-harness-tests.txt). Existing tests emit
  ResourceWarnings; the final unittest outcome is OK. New runner syntax and
  `git diff --check` passed. No Swift runtime was available.
- An initial runner preflight mis-parsed `swarmctl`'s raw task ID as JSON. It
  stopped before any HTTP chat/model turn and cleaned its temporary state.
  The parser was corrected before the live replay; the
  [zero-call preflight evidence](sim/results/live-4-preflight/results.json) is
  retained instead of silently replacing it.
- Every observed run was checked terminal. All **nine exact owned sessions**
  were deleted and individually verified **404**. Isolated runtime processes,
  local profile credentials, local queue/action state and temporary directories
  were removed after evidence export. The final health reports **active API runs
  0, active agents 0, gateway_busy false**. No wildcard remote cleanup was used.
  Hermes configuration/source/auth and all non-QA sessions were left untouched.
