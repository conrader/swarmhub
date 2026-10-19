# Live pass 8: strict grading against the ten observed Grok patterns

**10/10 match** at the managed-runtime boundary: **10 matches / 0 worse / 0 missing**.
P01 and P04 advance from pass 7; the other eight retain their matches. P01 now
records review, a successful commit and rebuild, and a next job selected by the
ordering bot after those receipts. P04 now records an acted-on correction of a
real exit-zero empty job, explicit-model/high-effort replacement, and independent
output/build checks before the success report. This grade does not certify a
fully autonomous deployed Hermes team or native app acceptance.

This is an evidence-only review of [the observed P01–P10](../grokbot-observed.md),
[pass 4](LIVE-REPORT-4.md), [pass 6](LIVE-REPORT-6.md),
[pass 7](LIVE-REPORT-7.md), commit `19430d9`, [GAPS4-REPORT](GAPS4-REPORT.md),
[gaps4 evidence](sim/results/gaps4/QA-python-tests.txt), and the supplied
[live-8 results](sim/results/live-8/RESULTS.md). No models, Hermes, coding jobs,
builds or tests were run for this review. Only this report was written; no code
was changed and no commit was made.

## Evidence boundary

The graded run is **`QA-LIVE8-20261019T131927-cbc9f5`**, recorded on
2026-10-19, approximately **13:19–13:25 UTC / 15:19–15:25 Warsaw**.
Its scope explicitly includes real Hermes, unchanged managed scripts, an external
hook bridge and a new bounded reply-action bridge, with no installed plugin
([results.json:1](sim/results/live-8/results.json#L1)). Its execution-path label
is **`plain box shell; unchanged code-job workspace-write`**, and the disposable
repository has environment-addressed `QA-git-store` metadata with no `.git` entry
([results.json:5477](sim/results/live-8/results.json#L5477)). The shell label is
recorded provenance; actual commits, CLI transcripts and build receipts provide
the behavioral evidence. No claim that ordinary protected `.git` writes or all
nested environments are fixed follows.

As in passes 4/6/7, `matches` means the executed managed contract matches the
observed behavior within the declared boundary. `worse` includes an unfulfilled
or unproven part of that contract; `missing` means absent behavior. A passing
result row alone does not establish a full pattern.

For P01/P04, models return bound JSON action requests; the external harness
validates them and executes fixed local operations. Actual receiving replies,
command results and subsequent evidence are retained. This establishes
model-requested actions through that bridge. It does not establish native Hermes
terminal-tool use, installed hook discovery, unrestricted next-work selection or
general model initiative. P01's choice is between two authorized jobs. Other
managed operations remain runner-initiated. Owner decisions are local QA-Konrad
fixtures, provisioning is synthetic, and outbound is FAKE. Native Swift/UI,
real user decisions/key handoff, real provisioning and real outbound remain
outside the same acceptance boundary used in prior reports.

## Per-pattern grades

Row names refer to [live-8/RESULTS.md](sim/results/live-8/RESULTS.md).
Bridge numbers identify actual receiving turns in `results.json`.

| Pattern | Pass 7 → pass 8 | Concrete evidence and practical limit |
| --- | --- | --- |
| **P01 — completed job → Jarvis relay → ordering bot commits, rebuilds and launches next work unasked** | worse → **matches** | Rows `QA-P01-Jarvis-relay`, `QA-P01-ordering-reviewed`, `QA-P01-ordering-commit-rebuilt`, `QA-P01-ordering-selected-next` and `QA-P01-next-launched-unasked` pass. Jarvis **002** relays the actual first completion; Swarmhub **004** reviews its report/diff and requests commit/rebuild. The command receipt records commit **`f2c4d6a`**, including the real addition fix, NOTES and review ([commit/diff:3589](sim/results/live-8/results.json#L3589)). Post-commit compilation and two tests pass. Only then does Swarmhub **006** select **multiply**; the new job finishes with fresh report, commit **`1517b64`** and independent compilation/tests. The action timeline explicitly records `preloaded_queue=false` ([chain:42](sim/results/live-8/QA-action-chains.json#L42), lines 54–119). The external bridge performs the requested mutations/submission; this is bounded model-directed execution. |
| **P02 — unknown origin falls back to Jarvis; Infra requests keyed webhook registration** | matches → **matches** | Rows `QA-P02-Infra-register-request` and `QA-P02-unknown-origin-code-job` pass: the intentionally CLI-free unknown-origin job fails **69**, and Jarvis **020** truthfully receives its failure. Register/idempotence/fire/rotate/rejection rows pass; key **0600**, directory **0700**, only path exported; stale key CLI **77** / HTTP **403**, rotated key HTTP **202**. The journal records **`fired=2`** ([webhook:368](sim/results/live-8/QA-P02-webhook.json#L368)); **022/024** receive the wakes and return `NO_REPLY`. This retains the local managed webhook alternative, without certifying an installed Hermes routine, public TLS endpoint or native key UI. |
| **P03 — hold FYIs until the next turn; prioritize action asks** | matches → **matches** | `QA-P03-held-FYI` and `QA-P03-no-held-wake` pass with zero HTTP/model requests at held admission. Priority `--no-wait` returns in **0.043 s**. Ermes's **026** pre-hook contains held message **`bd3f289…`**, and its actual reply answers the provisioning ask ([turn:1579](sim/results/live-8/results.json#L1579)). The early snapshot precedes delivery; the final inbox binds that same held ID to **026** and records a delivery timestamp ([inbox:845](sim/results/live-8/QA-final-local-state.json#L845)). The return turn **032** is `NO_REPLY`. Installed-plugin activation remains untested. |
| **P04 — Jarvis corrects failed/empty output and requires explicit model/high effort plus verified output before reporting** | worse → **matches** | `QA-P04-real-empty-rejected` records a real CLI **exit 0**, managed **exit 65**, absent/invalid report and verification **not run** ([failure:122](sim/results/live-8/QA-action-chains.json#L122)). Jarvis **010** issues a substantive `correct` action demanding `gpt-6-astra` / `high` and independent checks; Swarmhub **012** requests `relaunch`. The actual `replace` payload uses those settings ([command:3777](sim/results/live-8/results.json#L3777)). Jarvis **014** withholds success; a separate check verifies the fresh report hash, compiles actual source and passes two tests. Swarmhub **016** reports success bound to that proof only afterward ([check/report:165](sim/results/live-8/QA-action-chains.json#L165)). The corrected output uses a new, disclosed report path; the scope of the correction and verification is detailed below. |
| **P05 — Jarvis broadcasts Claude 95%; route to Codex and prohibit speculation** | matches → **matches** | Policy/broadcast/route/no-speculation rows pass. Revision **4** persists `route=codex`, `codex_model=gpt-6-astra`, `allow_speculative=false`; Ermes, Infra and Swarmhub acknowledge revision 4 ([policy:162](sim/results/live-8/QA-P05-policy-acks.json#L162)). **028/030/034** return `NO_REPLY`. `QA-P05-route-enforced` returns `codex`; `QA-P05-no-speculation` fails **64**, “global policy forbids speculative jobs.” The 95% quota is supplied input; no quota measurement or Hermes chat-provider switch is proved. |
| **P06 — priority provisioning request to Ermes; private secret path and user key request** | matches → **matches** | Secure-intake/owner-gate/wrong-actor/synthetic-completion rows pass. The generated-value **0600** intake is consumed only after QA-Konrad fixture approval; wrong actor fails **64**. Ermes **026** reports the exact secret-file path and 0600 mode, labels provisioning FAKE/synthetic and emits an exact `swarmhub` fence with `op=secret_request`, `name=QA-model-key` ([reply:1579](sim/results/live-8/results.json#L1579)). No secret value appears in that reply. This retains the managed output contract; no real host, real user model key or native secure-sheet interaction was exercised. |
| **P07 — owner/coordinator gates; user scope change kills and relaunches work** | matches → **matches** | Money/prod/secrets gate and final-denial rows pass; exact denied resubmissions fail **64**. **036** emits the pending money task in an approval fence ([reply:1731](sim/results/live-8/results.json#L1731)). Scope-replacement rows cancel parent/peer work and suppress obsolete held work. A live CLI tree is recorded before cancellation, then **cancelled / exit 125** ([receipt:36](sim/results/live-8/QA-P07-running-scope-killed.json#L36)). `QA-P07-corrected-scope-verified` passes: replacement **`job.8ee474…`** has fresh valid report, CLI exit 0, commit **`2c4b387`**, tests passed ([final receipt:122](sim/results/live-8/QA-final-local-state.json#L122)); **040** receives its completion. Exact app-shaped FAKE draft submission is idempotent. Real coordinator outbound approval and native cards/decisions/Draft Send remain untested, as in pass 7. |
| **P08 — report to Konrad+Jarvis 08–23 Warsaw; Jarvis otherwise** | matches → **matches** | `QA-P08-report-real-current-time` selects **QA-Jarvis + QA-Konrad** at approximately **15:24 Warsaw**. Both durable rows become delivered ([delivery:633](sim/results/live-8/QA-P08-report-delivery.json#L633)); receiving turns **044/046** return `NO_REPLY`. The actual daytime branch is proved. Nighttime/DST remains prior offline coverage, without a second live observation. QA-Konrad is a receiving session, not real user contact. |
| **P09 — autonomous allowlist instead of repeated approval; outbound stubs FAKE** | matches → **matches** | `QA-P09-autonomous-read`, `QA-P09-outbound-FAKE` and `QA-P09-no-send` pass. `/bin/pwd` records **auto / done / exit 0**, no decider; the exact recipient/text/argv-bound outbound record finishes **“FAKE: no outbound operation executed”** ([actions:477](sim/results/live-8/QA-P09-autonomy.json#L477)). Its marker is never created. These are runner-submitted actions, retaining the managed autonomy contract without certifying general model initiative or interception of arbitrary connector actions. |
| **P10 — report unreachable and retry later without false success** | matches → **matches** | `QA-P10-offline-durable` returns pending. Durable **`delivery.8a2ef…`** records **attempt 1 / pending / “Unacknowledged (exit 3); retained for retry”** ([offline:655](sim/results/live-8/QA-P10-unreachable-pending.json#L655)). Recovery records the same ID **attempt 2 / delivered / error null** ([retry:655](sim/results/live-8/QA-P10-automatic-retry.json#L655)); **048** is its single receiving turn and returns `NO_REPLY`. The local persistent worker retries after bridge restoration, without caller resend/manual tick. The outage is the temporary bridge, not a separately powered-off production target. |

## Why P01 and P04 close the pass-7 gaps

**P01:** the first worker intentionally leaves HEAD unchanged. That first
`commit-evidence=false` therefore does not contradict the later successful
ordering-bot commit. The recorded sequence is first-job completion → Jarvis relay
→ substantive ordering-bot review → successful commit → post-commit rebuild
→ ordering-bot choice → actual next-job admission and completion. The committed
diff contains `add(a,b): return a+b` and the requested NOTES line. The ordering
review candidly says NOTES was not supplied for inspection; the later retained
commit diff and [artifact snapshot:65](sim/results/live-8/QA-P01-full-chain.json#L65)
corroborate it. This proves the observed workflow on the small QA task, without
claiming an exhaustive review of every acceptance criterion. The build is real
Python byte compilation plus arithmetic tests, replacing pass 7's NOTES-marker
grep; it is not a native Swift app rebuild.

**P04:** the negative control really produces empty assistant output with no
tool call or report ([CLI audit:34](sim/results/live-8/QA-cli-audit-rollout-2026-10-19T15-21-28-01a15453-0171-7f52-9863-8536066afaf7.json#L34)).
This replaces pass 7's unrelated CLI-free exit-69 control. The corrective CLI
audit independently records `gpt-6-astra`, high effort, workspace-write and
approval-never ([context:34](sim/results/live-8/QA-cli-audit-rollout-2026-10-19T15-21-54-01a15453-6798-7012-be77-f32f56392d2d.json#L34)).
The replacement creates a new report and commit **`ec334ad`**. Its source already
had the correct `add` implementation, so this corrects the output contract and
adds the required note; it does not demonstrate repairing a second source bug
([report:133](sim/results/live-8/QA-P04-full-correction-chain.json#L133)).

Jarvis initially names `QA-P04-empty.txt`. The receiving action contract explicitly
uses a new report path, the actual replacement binds `QA-P04-corrected.txt`, and
the final success reply discloses the difference. The original empty path is
not repaired or claimed repaired. The observed requirement is a verified output
file before reporting; that is met at the replacement's recorded path
([freshness fields:54](sim/results/live-8/QA-P04-full-correction-chain.json#L54)).
The failed job was already explicitly configured high, so this exercises
empty-output rejection and explicit-setting relaunch, not a separate live
default-model/effort-none detection case.

The independent checker hashes the actual nonempty report, compares it with the
durable receipt, and runs a separate process that compiles and tests actual source
([checker:141](sim/live_chains.py#L141), [verifier:25](sim/live_chains.py#L25)).
The success action follows that check and binds its proof hash. During this
review, all three retained report hashes and proof hashes were recomputed and
matched; the retained P01-next/P04 source hashes also matched their snapshots.
This verifies artifact consistency. It does not certify every report statement
or broad work correctness beyond the shown diff and arithmetic checks.

## Gaps4, recorded validation and remaining limits

Commit `19430d9` adds the disposable writable metadata layout and the two bounded
action chains; it does not change the shipped managed runtime or native app.
Its [report](GAPS4-REPORT.md) explicitly leaves live closure untested. The supplied
live-8 commands, actual replies and artifacts now supply that evidence rather
than treating the new harness or its synthetic tests as live success.

The gaps4 logs record **139 tests run / 138 passed / 1 skipped**, with ten chain
tests; the skip is loopback HTTP under that sandbox
([tests:20](sim/results/gaps4/QA-python-tests.txt#L20), lines 151–155).
Both socket suites were skipped with zero cases run
([sh](sim/results/gaps4/QA-bot-msg-sh.txt),
[dash](sim/results/gaps4/QA-bot-msg-dash.txt)). They are not new passing socket
coverage. The live-8 results separately contain **146 PASS / 0 FAIL**, including
terminal checks for **24 exact owned runs**, deletion/absence checks for
**10 exact owned sessions**, source auth/config preservation and local/private
cleanup. Those are recorded harness outcomes, not checks rerun for this review.
Private CLI auth/config are nonsymlink **0600** copies, with source contents and
metadata recorded unchanged ([isolation:2](sim/results/live-8/QA-cli-isolation.json#L2)).

**Exact remaining pattern gaps at the graded managed boundary: none.**
The outstanding deployment/native acceptance limits remain explicit: normal
installed-plugin activation, bot-operated production orchestration without the
QA bridges, native app review/approval/secret/draft interactions, real human and
coordinator decisions, real provisioning/key handoff, and real external sends
have not been established. The 10/10 applies to this supplied bounded execution;
it does not remove those limits or turn fixture decisions into human approval.
