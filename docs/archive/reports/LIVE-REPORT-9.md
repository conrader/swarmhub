# Live pass 9: strict grading after fixes5

**10/10 match** at the managed-runtime boundary: **10 matches / 0 worse / 0 missing**.
All ten retain their pass-8 grades. No regression is established within that
boundary after fixes5. This does not certify native app acceptance, remote
approval availability or a deployed autonomous Hermes team.

This is an evidence-only review of [the observed P01–P10](../grokbot-observed.md),
[pass 4](LIVE-REPORT-4.md), [pass 6](LIVE-REPORT-6.md),
[pass 7](LIVE-REPORT-7.md), [pass 8](LIVE-REPORT-8.md), review commit `a22bf25`
([REVIEW-CODEX-3](../reviews/REVIEW-CODEX-3.md)), fixes5 commit `bd5b98b`
([FIXES5-REPORT](FIXES5-REPORT.md)), and the supplied
[live-9 evidence](../../../sim/results/live-9/RESULTS.md), committed in `2328251`.
No models, Hermes, coding jobs, builds or test suites were run for this review.
Only this report was written; no code was changed and no commit was made.

## Evidence boundary

The graded run is **`QA-LIVE9-20261019T140108-a8c9ce`**, approximately
**14:01–14:07 UTC / 16:01–16:07 Warsaw on 2026-10-19**.
Its recorded scope is real QA Hermes, unchanged managed scripts, external hook
and bounded reply-action bridges, and real authenticated coding CLI jobs in a
throwaway repository, without an installed plugin
([results.json:1](../../../sim/results/live-9/results.json#L1)). The execution-path label is
**`plain box shell; workspace-write CLI; sandboxed verification; minimal QA config`**.
Git metadata again resides in environment-addressed `QA-git-store`, with no
`.git` entry ([results.json:5473](../../../sim/results/live-9/results.json#L5473)).
That label is provenance; command transcripts, CLI contexts, changed HEADs,
retained source/reports and build receipts establish the behavior. Ordinary
protected `.git` writes and every nested execution environment remain unproven.

The standard is unchanged: `matches` means the executed managed contract matches
the observed behavior within this declared boundary; `worse` includes an unmet
or unproven part of that contract; `missing` means absent behavior. A passing
result row alone does not establish a whole pattern.

P01/P04 use actual model replies requesting narrowly defined JSON actions. The
external harness validates their bindings and performs fixed operations. This
proves bounded model-directed review/commit/rebuild/relaunch, including a choice
between two authorized next jobs. It does not prove native Hermes terminal use,
general initiative or unrestricted work selection. Other operations remain
runner-initiated. Five QA roles use ten receiving sessions on one QA Hermes;
owner decisions are local administrative fixtures, provisioning is synthetic,
and outbound records are FAKE. These are the same limits used in pass 8.

## Per-pattern grades

Row names below identify exact rows in
[live-9/RESULTS.md](../../../sim/results/live-9/RESULTS.md). Bridge numbers identify actual
receiving turns in `results.json`; their pre/post-hook records retain the inputs,
context and replies.

| Observed pattern | Pass 8 → pass 9 | Concrete evidence and practical limit |
| --- | --- | --- |
| **P01 — completed job → Jarvis relay → ordering bot reviews, commits, rebuilds and launches next work unasked** | matches → **matches** | `QA-P01-Jarvis-relay`, `QA-P01-ordering-reviewed`, `QA-P01-ordering-commit-rebuilt`, `QA-P01-ordering-selected-next` and `QA-P01-next-launched-unasked` pass. Jarvis **002** relays the actual first completion; Swarmhub **004** reviews its report/source diff and requests commit/rebuild. The real commit **`0b0bd07`** contains the addition fix, NOTES and review ([committed diff:3621](../../../sim/results/live-9/results.json#L3621)). Post-commit sandboxed compilation and two tests pass. Only afterward, Swarmhub **006** selects **multiply**; that next CLI job completes with fresh report, commit **`02fdca3`**, compilation and two tests. The [chain:42](../../../sim/results/live-9/QA-action-chains.json#L42), through line 119, records the order and `preloaded_queue=false`. These are bounded model-requested operations through the external bridge. |
| **P02 — unknown origin falls back to Jarvis; Infra asks for keyed webhook registration** | matches → **matches** | `QA-P02-Infra-register-request` and `QA-P02-unknown-origin-code-job` pass. The intentionally CLI-free unknown-origin job fails **69**; Jarvis **020** receives that failure and claims no execution success. Register/idempotence/fire/rotate/rejection rows pass: key **0600**, directory **0700**, path only exported; old key CLI **77** / HTTP **403**, rotated key HTTP **202**. The [webhook journal:376](../../../sim/results/live-9/QA-P02-webhook.json#L376) records **`fired=2`**; **022/024** receive the wakes and return `NO_REPLY`. This retains the local managed webhook match, without establishing an installed Hermes routine, public TLS endpoint or native user key display. |
| **P03 — hold FYIs until the next turn; send action asks priority** | matches → **matches** | `QA-P03-held-FYI` and `QA-P03-no-held-wake` pass with **zero HTTP/model requests** at held admission. The priority provisioning command returns in **0.044 s** ([command:4148](../../../sim/results/live-9/results.json#L4148)). Ermes **026** receives the held FYI in its pre-hook and answers the action ask. The final inbox binds held ID **`ebf70eee…`** to **026** and records its delivery timestamp ([inbox:854](../../../sim/results/live-9/QA-final-local-state.json#L854)). The early snapshot precedes asynchronous completion; the final journal establishes delivery. Return turn **032** is `NO_REPLY`. Normal installed-plugin activation remains outside the replay. |
| **P04 — Jarvis corrects empty/failed work, requires explicit model/high effort and checks output before success** | matches → **matches** | `QA-P04-real-empty-rejected` records actual CLI **exit 0**, managed **exit 65**, no valid report and verification **not run** ([failure:122](../../../sim/results/live-9/QA-action-chains.json#L122)). Jarvis **010** issues an actionable `correct` request with `gpt-6-astra` / `high`; Swarmhub **012** requests relaunch. The real replacement payload uses those settings ([command:3774](../../../sim/results/live-9/results.json#L3774)). Jarvis **014** waits for independent checking. A separate sandboxed process compiles source and passes two tests, with fresh report/hash and commit **`39588fe`**; only then does Swarmhub **016** request success reporting bound to the proof hash ([check/report:165](../../../sim/results/live-9/QA-action-chains.json#L165)). As in pass 8, this repairs the output contract at a disclosed replacement path, not a second source bug or a default-model/effort-none case. |
| **P05 — Jarvis broadcasts Claude 95%; route to Codex and prohibit speculative jobs** | matches → **matches** | Policy/broadcast/route/no-speculation rows pass. [Policy/acks:170](../../../sim/results/live-9/QA-P05-policy-acks.json#L170) records revision **4**, `route=codex`, `codex_model=gpt-6-astra`, `allow_speculative=false`, with Ermes/Infra/Swarmhub acknowledging revision 4. **028/030/034** return `NO_REPLY`. `QA-P05-route-enforced` returns `codex`; `QA-P05-no-speculation` fails **64**, “global policy forbids speculative jobs.” The 95% quota remains supplied input, without a measured quota or Hermes chat-provider switch. |
| **P06 — priority provisioning request to Ermes; private secret path and user model-key request** | matches → **matches** | Secure-intake/owner-gate/wrong-actor/synthetic-completion rows pass. The generated-value **0600** intake is consumed only after the QA-Konrad fixture approval; wrong actor fails **64**. The [provision record:266](../../../sim/results/live-9/QA-P06-synthetic-provision.json#L266) binds the request/path, owner gate, decider and successful execution. Ermes **026** reports the exact path/mode, labels provisioning synthetic/FAKE and emits a `swarmhub` fence with `op=secret_request`, `name=QA-model-key` ([actual turn:1579](../../../sim/results/live-9/results.json#L1579)). No secret value appears in its reply. Real provisioning, a real user key and the native secure-sheet handoff remain untested. |
| **P07 — money/prod/secrets need Konrad, real outbound needs Jarvis; scope change kills and relaunches work** | matches → **matches** | Money/prod/secrets gate and final-denial rows pass; exact denied resubmissions fail **64**. **036** emits the actual pending money task in an approval fence. Scope replacement cancels parent/peer work and suppresses obsolete held work ([scope snapshot](../../../sim/results/live-9/QA-P07-scope-cancel.json)). A real CLI tree is alive before cancellation and records **cancelled / exit 125** afterward ([receipt:4](../../../sim/results/live-9/QA-P07-running-scope-killed.json#L4)). `QA-P07-corrected-scope-verified` passes: replacement **`job.6fbf5b…`** has fresh valid report, CLI exit 0, commit **`4029218`** and passing tests ([final receipt:122](../../../sim/results/live-9/QA-final-local-state.json#L122)); **040** receives its completion. Exact app-shaped FAKE draft admission remains idempotent. Real coordinator outbound approval and native approval/decision/Draft Send execution remain outside the live evidence. The new local-control and remote fail-closed boundary is detailed below. |
| **P08 — report to Konrad+Jarvis 08–23 Warsaw, Jarvis otherwise** | matches → **matches** | `QA-P08-report-real-current-time` selects **QA-Jarvis + QA-Konrad** at actual approximately **16:06 Warsaw**. Both durable rows become delivered ([delivery:642](../../../sim/results/live-9/QA-P08-report-delivery.json#L642), line 653); **044/046** return `NO_REPLY`. This proves the daytime branch. Nighttime/DST retains prior offline coverage, without a second live observation. QA-Konrad is a receiving session, not real user contact. |
| **P09 — autonomous allowlist instead of per-action approval; outbound stubs FAKE** | matches → **matches** | `QA-P09-autonomous-read`, `QA-P09-outbound-FAKE` and `QA-P09-no-send` pass. `/bin/pwd` records **auto / done / exit 0**, with no decider ([read:486](../../../sim/results/live-9/QA-P09-autonomy.json#L486)). The exact recipient/text/argv-bound outbound record finishes **“FAKE: no outbound operation executed”** ([draft:502](../../../sim/results/live-9/QA-P09-autonomy.json#L502)); its marker is never created. Runner submission retains the managed autonomy contract without establishing general model initiative or interception of arbitrary connectors. |
| **P10 — report unreachable and retry later, without false success** | matches → **matches** | `QA-P10-offline-durable` returns pending. Durable ID **`delivery.7e0646…`** records **attempt 1 / pending / “Unacknowledged (exit 3); retained for retry”** ([offline:664](../../../sim/results/live-9/QA-P10-unreachable-pending.json#L664)). The same ID becomes **attempt 2 / delivered / error null** after restoration ([retry:664](../../../sim/results/live-9/QA-P10-automatic-retry.json#L664)); **048** is its single receiving turn and returns `NO_REPLY`. The existing worker retries without caller resend or manual tick. The outage is the temporary local bridge, not a separately powered-off production machine. |

## P01/P04 evidence after sandboxing

P01's first worker deliberately leaves HEAD unchanged. Its initial
`commit-evidence=false` is consistent with the later ordering-bot commit; it is
not a failed commit claim. The review expressly limits its conclusions to the
supplied source diff and build evidence. NOTES and the actual committed change
are independently visible in the retained commit diff and
[artifact snapshot:65](../../../sim/results/live-9/QA-P01-full-chain.json#L65).
The rebuild is Python compilation plus two arithmetic tests, as in pass 8,
rather than a native Swift app build. The next completion's Jarvis **008** reply
does not initiate an additional cycle; the graded chain proves one complete
review/commit/rebuild/next-work cycle.

P04's negative control really finishes with empty output and no tool call
([CLI audit:101](../../../sim/results/live-9/QA-cli-audit-rollout-2026-10-19T16-03-22-01a15479-5cfd-7243-86a4-84b191140659.json#L101)).
The corrective audit independently records `gpt-6-astra`, high effort,
workspace-write, network disabled and approval-never
([context:34](../../../sim/results/live-9/QA-cli-audit-rollout-2026-10-19T16-03-48-01a15479-c32e-7b60-bab2-246c15bb1792.json#L34)).
Its source was already correct; the replacement adds the required note, creates
a new commit and produces the missing output contract
([report:140](../../../sim/results/live-9/QA-P04-full-correction-chain.json#L140)).
The failed job was already explicit/high, so separate live detection of a
default model or effort-none remains outside this particular observation.

Jarvis initially requests `QA-P04-empty.txt`. The receiving action contract uses
a new report path, the replacement binds `QA-P04-corrected.txt`, and the final
success request names that replacement path. The original empty file is not
repaired or claimed repaired. This retains pass 8's disclosed interpretation:
a verified replacement output file is required before success reporting. The
last reply requests reporting and does not claim a real external send.

Both the managed verifier and independent harness rebuilds now use the sandbox
helper ([code-job:125](../../../Resources/Skills/swarmhub-coding/scripts/code-job#L125),
[sandbox_check:143](../../../sim/live_chains.py#L143)). The live command receipts explicitly
invoke that helper and exit 0, including the post-commit rebuild
([results.json:3638](../../../sim/results/live-9/results.json#L3638)). The helper scrubs
the environment, limits filesystem access, blocks network access and refuses
unsupported isolation; there is no unsandboxed fallback
([verify-sandbox.py:16](../../../Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py#L16)).
Successful checks after this change preserve the P01/P04 evidence rather than
silently relying on the former host-shell verifier.

This review recomputed all three retained report hashes and proof hashes, plus
the post-commit build hash supplied to next-work selection; all matched. The
P01-next/P04 source hashes matched their snapshots. Both chain snapshots retain
the exact verifier text defined by the harness. The verifier now lives inside
the model-writable QA workspace; these comparisons support this run's artifact
consistency, without proving an immutable verifier against arbitrary hostile
edits or correctness beyond the shown source/tests. No retained code was executed
to perform these comparisons.

## Fixes5 and comparison with pass 8

**Sandboxed verification and minimal QA configuration:** fixes5 changes the
execution authority while retaining successful managed coding. The harness now
copies only authentication and generates the small QA configuration, with no
source configuration import; its environment uses an allowlist
([live_cli.py:42](../../../sim/live_cli.py#L42), lines 78–92). All five retained CLI contexts
show workspace-write and `network_access=false`, including P01's first run
([audit:34](../../../sim/results/live-9/QA-cli-audit-rollout-2026-10-19T16-01-14-01a15477-5da6-7700-949a-0b758fdca4aa.json#L34)).
The [isolation record](../../../sim/results/live-9/QA-cli-isolation.json) confirms unchanged
source auth/config contents and metadata. That assertion alone does not prove
removed capabilities; the generator and actual child contexts supply separate
evidence. The live artifacts do not contain a complete effective-config/tool
inventory for the nested CLI or live adversarial denial tests. Fixes5's recorded
offline negative tests cover those configuration/sandbox cases; this grading
does not independently recertify every security claim in B1/B2.

**Runtime-bound approvals and fail-closed remote notifications:** source now
fetches the runtime operation, builds the card from that record, and sends a
fingerprint/gate-bound decision. A card remains pending until a matching receipt
confirms it ([AppStore+ManagedActions.swift:9](../../../Sources/AgentApp/Stores/AppStore+ManagedActions.swift#L9),
lines 39–80; [swarm_policy.py:285](../../../Resources/Skills/swarmhub-messages/scripts/swarm_policy.py#L285)).
The local control transport accepts only loopback addresses and requires the
installed profile-local `swarmctl`; other hosts fail closed
([ManagedControl.swift:65](../../../Sources/AgentApp/Models/ManagedControl.swift#L65)).

Live 9 still uses the older direct `swarmctl decide` administrative fixture
commands, including [P06 approval:4097](../../../sim/results/live-9/results.json#L4097)
and [P07 denial:4404](../../../sim/results/live-9/results.json#L4404). It does **not** execute
the new native `control get/decide` path, a bound card decision or receipt recovery.
The approval fence in **036** is a notification, not approval authority or
evidence of a rendered, executable card. P07 retains its managed gate/cancellation
match because those operations still execute, and pass 8 already excluded native
decisions and real coordinator outbound approval.

Remote approval availability is explicitly narrower: the app no longer attempts
the former model-mediated decision route for a remote runtime. **Remote native
approvals require a trusted control transport before they can be enabled.** This
is a deliberate capability restriction, not a newly demonstrated remote approval
match. It does not reduce the unchanged managed-runtime score; anyone treating
pass 8's 10/10 as deployed remote-app acceptance would be exceeding both reports'
evidence.

**Other fixes:** verifier defaults are now frozen before fingerprinting
([swarm_policy.py:176](../../../Resources/Skills/swarmhub-messages/scripts/swarm_policy.py#L176));
the live jobs use explicit verifiers, so mutable-default/empty-verifier cases are
offline coverage. Shared Swift/Python intake, goal-type evidence, persisted
pending cards and exceptional cleanup paths likewise are not newly exercised by
these ten live scenarios. [FIXES5-REPORT](FIXES5-REPORT.md) records **156 Python
tests / 155 passed / 1 skipped**, six completion cases under each of sh/dash,
two skipped socket suites and seven unrun new Swift test functions. Those are
recorded validation results, not tests rerun here or native acceptance.

Live 9 independently records **146 PASS / 0 FAIL**, **24 receiving turns**, terminal
checks for **24 exact owned runs**, deletion/absence checks for **10 exact owned
sessions**, unchanged source auth/config and local-process/private-file cleanup
([results](../../../sim/results/live-9/RESULTS.md)). Cleanup's new independent-finally
structure is source-visible ([finish:588](../../../sim/live_managed.py#L588)); this successful
run does not itself exercise export or constructor failure.

**Exact remaining pattern gaps at the graded managed boundary: none.**
Deployment/native acceptance remains outstanding for normal plugin activation,
production bot orchestration without the QA bridges, native approval/receipt
and secure-sheet handoffs, remote approval transport, real human/coordinator
decisions, real provisioning/key handoff and real external sends. The unchanged
10/10 grade does not resolve those limits or constitute a release verdict on
all fixes5 findings.
