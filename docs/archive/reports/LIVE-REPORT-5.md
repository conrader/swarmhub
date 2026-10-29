# Live pass 5: the ten observed Grok team patterns

**6 matches / 4 worse / 0 missing at the tested managed-runtime boundary.**
Pass 4 was 5/5/0. Managed webhook registration now matches; synthetic provisioning,
real CLI cancellation/relaunch and exact FAKE drafts have stronger evidence.
Successful coding and native approval/secret UI still prevent a live 10/10.

Executed **2026-10-19 12:09:17–12:15:53 UTC / 14:09:17–14:15:53 Warsaw**,
including two retained preflights. The complete replay ran **12:12:59–12:15:53 UTC**.
Checkout **`6968a26`**, bundled skills **1.3.2**, installed authenticated Codex
CLI **0.163.0**, explicit **`gpt-6-astra` / `high`**.
No commit, deploy, real outbound send, real provisioning, Hermes modification,
gateway restart or plugin installation into Hermes was performed.

## Boundary and method

Read [LIVE-REPORT-4](LIVE-REPORT-4.md), [GAPS-REPORT](GAPS-REPORT.md) and the
[ten observed patterns](../grokbot-observed.md) before execution. This compares
against that recorded Grok behavior; Grok was not rerun. The observations contain
summaries rather than complete original prompts, so QA tasks preserve the stated
roles and contracts with explicit synthetic substitutions.

[The runner](../../../sim/live_managed.py) invokes the unchanged shipped `swarmctl`,
`code-job` and `bot-msg --durable`, plus held and asynchronous priority messages.
Five local QA role profiles map onto ten distinct receiving sessions on the
existing single-profile QA Hermes at `127.0.0.1:8742`. These are namespaces,
not five provisioned agents. A temporary loopback bridge invokes the shipped
pre/post hooks in isolated subprocesses and supplies their context to real
Hermes turns. Normal plugin installation, discovery and activation remain untested.

Hermes still exposes only `todo` and `clarify`. Neither was used. Runner commands
produce the effects; model turns cannot execute managed commands themselves.
Instructions prohibit unsupported execution claims and request `NO_REPLY` for
FYIs/result-only replies. This tests managed runtime behavior and real model
responses, with limited evidence of bot initiative. Owner decisions are explicitly
**local administrative fixtures**, not real Konrad decisions or UI clicks.

The real CLI uses a throwaway git workspace. Its existing auth/config are referenced
read-only from a private temporary `CODEX_HOME`, allowing transient CLI state without
changing the source auth home. No CLI executable was installed, replaced or stubbed.
No successful report, commit or test result was fabricated.

## Per-pattern grades and comparison with pass 4

`matches` means the executed managed contract matches the observed behavior within
the boundary above. `worse` includes an unmet portion or environment blocker; it
does not automatically identify a product defect.

| Pattern | Pass 4 → pass 5 | Evidence and practical limit |
| --- | --- | --- |
| **P01 — completion wakes Jarvis, then next work without asking** | worse → **worse** | Real authenticated CLI job `job.db771d6695b641ca948824fc710c6a20` exits **0**, but produces no report because its tools cannot run. `code-job` rejects it with **65**, `report-valid=false`, `evidence=none`; the next job remains **queued**. Jarvis receives the durable failure in **QA-bridge-002** and accurately refuses completion. This improves pass 4's no-CLI exit 69 to a real CLI/model execution and effective rejection of exit-zero/no-artifact work. Successful fresh-report plus commit/tests, rebuild and unattended successful queue advance remain **BLOCKED**. [Queue/artifacts](../../../sim/results/live-5/QA-P01-CLI-queue.json). |
| **P02 — unknown origin falls back to Jarvis; managed keyed webhook** | worse → **matches** | A deliberate CLI-free unknown-origin job `job.w78Hg7np` wakes Jarvis in **008**. `QA-Infra/QA-wake` registration is idempotent; key file **0600**, directory **0700**, output contains only the path. CLI fire and rotated-key HTTP fire each produce one real durable self-wake (**010/012**); webhook `fired=2`. Old key fails CLI with **77** and HTTP with **403**; rotated key returns **202**. No keys enter chat/evidence. This is the newly shipped managed webhook receiver, not a Hermes-installed routine or publicly deployed endpoint. [Webhook journal](../../../sim/results/live-5/QA-P02-webhook.json), `P02-webhook-*` in [commands](../../../sim/results/live-5/results.json). |
| **P03 — hold FYIs, prioritize asks** | matches → **matches** | Held FYI admission creates **zero HTTP/model turns**. The next Ermes priority turn (**014**) receives it through the real pre-hook context; the post-hook acknowledges it. `--priority --no-wait` returns before the model answer, which routes back once to Swarmhub (**016**, `NO_REPLY`). Automatic hook activation remains outside this bridge. [Held/late snapshot](../../../sim/results/live-5/QA-P03-P06-held-and-late.json), [hook contexts and timing](../../../sim/results/live-5/results.json). |
| **P04 — coordinator corrects empty jobs and demands explicit model/effort/report** | worse → **worse** | The P01 job records actual Codex/high execution and a configured exact-line verification command. CLI exit 0 does **not** bypass the missing fresh-report gate. The durable correction reaches Swarmhub (**004**), which answers `NO_REPLY`; it does not inspect artifacts or relaunch a corrective job itself. Passing commit/test evidence remains offline-only here. A receipt wording defect also labels configured-but-unrun verification as “no verification command configured”; see remaining gaps. [CLI queue](../../../sim/results/live-5/QA-P01-CLI-queue.json), [model answers](../../../sim/results/live-5/QA-audit.json). |
| **P05 — quota 95% broadcast routes to Codex and stops speculation** | matches → **matches** | Policy **revision 4** persists Codex, `gpt-6-astra`, `allow_speculative=false`. Swarmhub/Infra/Ermes acknowledge revision 4 and return `NO_REPLY` (**018/020/022**). `plan claude 0` resolves Codex; speculative admission exits **64**. The supplied 95% observation is not a new quota measurement; no Hermes chat-provider switch is claimed. [Policy/acks](../../../sim/results/live-5/QA-P05-policy-acks.json). |
| **P06 — Ermes provisions QA; private secret path; secure model-key request** | worse → **worse** | Secure CLI intake creates a **0600** file holding only a generated synthetic value. A configured synthetic provisioner receives canonical request argv with that path. Its task stays **awaiting-owner** with no receipt before approval; a wrong actor exits **64**. QA-Konrad's labelled fixture approval lets the local hook complete **exit 0**; it creates only a QA receipt, no host or network operation. Ermes truthfully reports the synthetic boundary/path in **014** and requests secure intake. However, its `secret_request` JSON has **no required fence**, so the app parser would ignore it. Real provisioning, real user-key acquisition and the native secure sheet remain unverified. [Provision journal](../../../sim/results/live-5/QA-P06-synthetic-provision.json), [raw answer](../../../sim/results/live-5/QA-audit.json). |
| **P07 — owner/coordinator gates, approval cards, interrupt/relaunch** | worse → **worse** | Money/prod/secrets wait on owner; fixture denials are final, with identical resubmission refused **64**. Scope replacement cancels a parent and peer child and suppresses the obsolete held message. A **real CLI PID is alive**, then runtime replacement kills it: **cancelled / CLI exit 125**, PID gone. The corrected job actually launches the real CLI but fails **65** with no report. The model presents the actual pending money task's approval JSON (**024**) without a `swarmhub` fence: no native card evidence. An app-shaped exact subject/body/recipient FAKE draft is admitted once, repeated submission returns the same task, and status becomes **done / FAKE**. No real outbound gate, human click or Draft Send UI was executed. [Task-tree cancellation](../../../sim/results/live-5/QA-P07-scope-cancel.json), [running cancellation](../../../sim/results/live-5/QA-P07-running-scope-killed.json), [draft record](../../../sim/results/live-5/QA-P09-autonomy.json). |
| **P08 — Warsaw reporting hours** | matches → **matches** | At actual **14:15 Warsaw**, `swarmctl report` selects **QA-Jarvis + QA-Konrad**. Both delivery rows become delivered, both real receiving turns (**032/034**) return `NO_REPLY`. Nighttime/DST coverage remains offline; no clock was fabricated. These are QA receiving sessions, not real contact with Konrad. [Report delivery](../../../sim/results/live-5/QA-P08-report-delivery.json). |
| **P09 — autonomous allowlisted actions; outbound FAKE** | matches → **matches** | Allowlisted `/bin/pwd` completes **auto / done / exit 0** without an approval decision. FAKE outbound records bind exact QA recipient/text, finish **done / FAKE: no outbound operation executed**, and never execute their `touch` marker. This proves admission/execution behavior; the runner still initiates it. [Autonomy/drafts](../../../sim/results/live-5/QA-P09-autonomy.json). |
| **P10 — unreachable target, retain and retry, no false success** | matches → **matches** | Closing only the QA bridge listener causes **pending**, attempt **1**, exit **3**, retained for retry. Restoring that listener lets the existing worker deliver on attempt **2**, producing one Ermes turn (**036**). No caller resend, manual tick or due-time change. Hermes itself remains running. [Offline](../../../sim/results/live-5/QA-P10-unreachable-pending.json), [automatic recovery](../../../sim/results/live-5/QA-P10-automatic-retry.json). |

## Remaining gaps blocking 10/10

1. **Successful coding is still blocked by the nested CLI tool environment.**
   Codex authentication and provider access work, but its terminal tools fail with
   `error building bubblewrap command: app-server socket directory must be a user-owned directory with mode 0700`;
   file editing also fails. Both complete replay coding runs return exit 0 with
   blocked answers and no report; `code-job` correctly converts each to failure 65.
   Successful fresh-report plus accepted commit/tests and successful corrective work
   cannot be certified. This is an environment blocker, not evidence that the new
   success contract is absent. [Retained CLI diagnostic audit](../../../sim/results/live-5-cli-preflight/QA-cli-audit-rollout-2026-10-19T14-11-24-01a15412-d3bc-7e73-958f-b23a6f65365c.json).
2. **The live model-to-app fence contract did not hold for P06/P07.** Both outputs
   contain JSON but lack the required delimiters despite explicit requests.
   [ManagedApproval/SecretRequest parsers](../../../Sources/AgentApp/Models/ManagedActions.swift)
   consume fenced blocks. Source-derived consequence: these exact replies would
   not create a card/sheet. This is a live integration gap, not execution of Swift
   or proof of a parser defect. Native clicks, same-box decider routing, decision
   execution and Draft Send remain unexecuted on this Linux host without Swift.
3. **Receipt wording conflates unrun and unconfigured verification.** The P01
   journal contains `verify-command=grep -Fxq 'QA-P01-first done' NOTES.md` and
   `tests-passed=not-run`, yet its wake says no verification command was configured.
   The fallback in [peer-runtime.py](Resources/Skills/swarmhub-messages/scripts/peer-runtime.py:193)
   needs to distinguish those states. It did not grant success, but can misdirect
   a coordinator's correction. Listed only; product code was not changed.
4. **Deployed autonomous integration remains outside the test boundary.** The
   bridge runs hooks manually; Hermes lacks terminal tools to invoke managed
   commands, and the coordinator correction produced `NO_REPLY`. Native goal
   evidence still depends on bot claims about remote work, as documented in
   GAPS-REPORT. Real provisioning and secure key handoff need an actual provisioner
   and user intake on the relevant host. Public webhook/TLS deployment and real
   owner/coordinator interaction were intentionally not performed.

The gap closures are therefore stronger than pass 4's source-only claims, while
their native and successful-coding acceptance conditions remain open.

## Validation, call accounting and cleanup

- Full replay: **18 Hermes turns / 18 observed provider calls**, ten receiving
  sessions, **88 HTTP requests**, zero Hermes tool calls. **110 low-level checks
  pass, 3 fail**: first verified coding job, automatic next launch, corrected-scope
  verification. Those failures remain visible and drive the grades above.
- Including both preflights: **20 Hermes calls + 13 recorded real CLI provider
  responses = 33 observed**, below the approximately 60-call budget. CLI response
  IDs and usage are retained in the compact audits; cancellation before a CLI
  transcript is established does not prove no in-flight provider request existed.
  [Accounting and answers](../../../sim/results/live-5/QA-audit.json),
  [owned-session counters](../../../sim/results/live-5/usage-snapshots.json).
- `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`: **124 passed,
  zero skipped**, including the actual loopback webhook HTTP test previously
  skipped in GAPS-REPORT. [Test log](../../../sim/results/live-5-validation/QA-python-tests.txt).
  `bot-msg` socket suite: **14 passed under sh + 14 under dash**, no skips/failures.
  [sh](../../../sim/results/live-5-validation/QA-bot-msg-sh.txt),
  [dash](../../../sim/results/live-5-validation/QA-bot-msg-dash.txt).
  Final harness regressions **2 passed**; syntax parsing and `git diff --check`
  pass. Swift/native UI was unavailable and is not reported as tested.
- Two failed preflights are retained: original read-only CLI state prevented
  startup; writable QA state then exposed the nested tool failure. Interrupting
  their held-queue waits required resuming exact cleanup from recorded ownership.
  Neither attempt is erased or counted as success.
  [First](../../../sim/results/live-5-preflight/results.json),
  [second](../../../sim/results/live-5-cli-preflight/results.json).
- Small changes are confined to [live_cli.py](../../../sim/live_cli.py) and
  [live_managed.py](../../../sim/live_managed.py): temporary writable CLI state with existing
  read-only auth, fail-through handling of a blocked coding queue, compact CLI
  audits, and the requested QA replay steps. Shipped runtime/app code is unchanged.
  The report and evidence remain **uncommitted**.
- All **20 owned Hermes runs** were independently checked terminal. All **12 exact
  owned sessions**, including preflights, return **404**. The completed runner
  terminates its isolated processes and removes credentials, synthetic intake,
  webhook keys, CLI state, workspace and runtime state after export. The bridge
  and webhook receiver are closed. Final health is **active runs 0, active agents
  0, gateway_busy false**. Cleanup never selects remote sessions by wildcard.
  [Final independent verification](../../../sim/results/live-5/QA-cleanup-verification.json).

Additional evidence: [raw commands/SSE/hooks](../../../sim/results/live-5/results.json),
[delivery log](../../../sim/results/live-5/QA-bot-messages.tsv),
[run log](../../../sim/results/live-5/QA-run-log.txt),
[final journal](../../../sim/results/live-5/QA-final-local-state.json),
[source hashes](../../../sim/results/live-5/QA-provenance.json).
