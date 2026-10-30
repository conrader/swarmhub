# Live pass 7: strict grading against the ten observed Grok patterns

**8/10 match** at the managed-runtime boundary: **8 matches / 2 worse / 0 missing**.
P07 advances from pass 6 because the replacement coding job now passes verification.
P01 still lacks the observed commit/rebuild workflow. P04 has no successful
correction sequence, and its dedicated receiving turn returns `NO_REPLY`.
All 117 low-level result rows passing does not establish ten complete patterns.

This is an evidence-only review of [the observed P01–P10](../grokbot-observed.md),
[pass 4](LIVE-REPORT-4.md), [pass 6](LIVE-REPORT-6.md),
[GAPS3-REPORT](GAPS3-REPORT.md), and [the supplied pass-7 artifacts](../../../sim/results/live-7/RESULTS.md).
No models, Hermes, coding jobs or tests were run for this review. No code was
changed and no commit was made.

## Evidence boundary

The pass-7 directory retains the internal run identifier
`QA-LIVE6-20261019T125425-f25fad`; this report grades that directory, not pass 6's
earlier run. Its `results.json` records 2026-10-19 and describes real Hermes,
unchanged managed scripts, an external hook bridge, no installed plugin, and real
Codex jobs in a disposable repository. The recorded CLI execution path remains
`sandboxed exec_command; unchanged code-job workspace-write`
([results.json:2](../../../sim/results/live-7/results.json#L2),
[scope:6](../../../sim/results/live-7/results.json#L6),
[execution path:4706](../../../sim/results/live-7/results.json#L4706)). Successful file edits
and verification therefore supersede the earlier nested-shell failure for these
jobs; they do not prove a plain-box-shell replay or that every environment is fixed.

As in passes 4/6, `matches` means the executed managed contract matches within
this boundary. It does not certify native Swift/UI, installed Hermes hook
discovery, autonomous model invocation of managed commands, real provisioning,
human decisions or external sends. `worse` means a recorded behavior remains
unfulfilled or unproven; it does not automatically identify a product defect.
Synthetic provisioning and local QA-Konrad administrative decisions retain their
fixture status. Outbound is FAKE. No new native parser or UI acceptance is inferred
from the visible fences.

## Per-pattern grades

Result-row names below refer to [live-7/RESULTS.md](../../../sim/results/live-7/RESULTS.md).
Bridge numbers identify the actual receiving turns in `results.json`.

| Pattern | Pass 6 → pass 7 | Concrete evidence, remaining gap or boundary |
| --- | --- | --- |
| **P01 — completed job → Jarvis relay → ordering bot commits, rebuilds and starts next job unasked** | worse → **worse** | Rows `QA-P01-first-verified` and `QA-P01-next-launched-unasked` now pass. Both real jobs finish `done`, CLI exit 0, fresh report valid and verification passed. However, both record `commit-evidence=false` and unchanged HEAD; verification is only a `grep -Fxq` NOTES marker check ([queue:9](../../../sim/results/live-7/QA-P01-CLI-queue.json#L9), lines 15–16, 27–31, 39–61). The first report records a read-only `.git/index.lock` failure; the next report also states no commit ([reports:68](../../../sim/results/live-7/QA-P01-CLI-queue.json#L68)). Jarvis receives completions in **002/004**; the runner sends the subsequent relay, and Swarmhub answers `NO_REPLY` in **006** ([reply:913](../../../sim/results/live-7/results.json#L913)). **Exact remaining gap:** no successful commit, no rebuild, and no ordering-bot review/commit/rebuild/next-launch chain. The pre-submitted queue advances automatically, which is real progress but does not establish that full observed workflow. The commit blocker is environmental; no claim of a product bug follows. |
| **P02 — unknown origin falls back to Jarvis; Infra requests keyed webhook registration** | matches → **matches** | Rows `QA-P02-Infra-register-request` and `QA-P02-unknown-origin-code-job` pass; the deliberately CLI-free unknown-origin job fails 69, and **010** receives its wake as Jarvis, accurately reporting no CLI/report/verification ([wake/reply:1001](../../../sim/results/live-7/results.json#L1001)). Register, idempotence, fire, rotate and stale-key rejection rows all pass: key **0600**, directory **0700**, only path exported; old key CLI **77** / HTTP **403**, rotated key HTTP **202**. The webhook journal records `fired=2` ([webhook:294](../../../sim/results/live-7/QA-P02-webhook.json#L294)); receiving turns **014/016** return `NO_REPLY`. This proves the local managed webhook alternative; no installed Hermes routine, public TLS endpoint or native user-only key UI is certified. |
| **P03 — FYIs held until the next turn; action asks priority** | matches → **matches** | Rows `QA-P03-held-FYI` and `QA-P03-no-held-wake` pass: held admission creates zero HTTP/model requests. Priority `--no-wait` returns in **0.034 s**; Ermes's **018** pre-hook includes the actual held message ([context:4450](../../../sim/results/live-7/results.json#L4450)). The early snapshot still has `delivered=null`; the final inbox marks that same ID delivered ([final inbox:771](../../../sim/results/live-7/QA-final-local-state.json#L771), line 778). Ermes answers the ask in **018**, and the return turn **022** is `NO_REPLY`. Normal installed-plugin activation remains outside this hook-bridge evidence. |
| **P04 — Jarvis flags failed/empty jobs and demands explicit model/high effort plus verified output** | worse → **worse** | P01 jobs really use `gpt-6-astra` / `high` and pass the managed report/verification checks. The negative control is `job.YSOnxar7`, a deliberately CLI-free **69** failure, not an exit-zero empty/default-model job. Its **010** wake truthfully reports the missing report and verification not run. `P04-correct-failed-report` explicitly requests the model, effort, fresh report and passing verification, but also says the receiver cannot run tools and must not claim relaunch ([command:3206](../../../sim/results/live-7/results.json#L3206)). Its actual receiver **012** returns **`NO_REPLY`** ([reply:1045](../../../sim/results/live-7/results.json#L1045)), weaker than pass 6's substantive correction reply. **Exact remaining gap:** a receiving bot must actually issue/act on the correction, relaunch the failed/empty job with explicit model/high effort, and independently establish the fresh output and successful verification before reporting. P01's earlier successful jobs and P07's unrelated scope replacement do not prove that correction chain. The configured-but-not-run receipt wording is retained; it is not evidence that verification ran. |
| **P05 — Jarvis broadcasts Claude 95%; use Codex and forbid speculative jobs** | matches → **matches** | Rows `QA-P05-global-quota-policy`, all three broadcasts, `QA-P05-route-enforced` and `QA-P05-no-speculation` pass. Revision **4** records `route=codex`, `codex_model=gpt-6-astra`, `allow_speculative=false`; Ermes, Infra and Swarmhub acknowledge revision 4 ([policy/acks:98](../../../sim/results/live-7/QA-P05-policy-acks.json#L98)). Turns **020/024/026** return `NO_REPLY`. Claude planning resolves to Codex and speculative admission fails **64** with “global policy forbids speculative jobs.” The 95% quota is supplied scenario input; no new quota measurement or Hermes chat-provider switch is established. |
| **P06 — Swarmhub asks Ermes to provision QA Hermes; private secret path and user key request** | matches → **matches** | Rows `QA-P06-secure-intake`, `QA-P06-owner-gate-before-hook`, `QA-P06-wrong-actor-rejected` and `QA-P06-synthetic-hook-completed` pass. A generated-value **0600** intake file is consumed only after local QA-Konrad fixture approval; the wrong actor fails **64**. Ermes's real priority reply **018** reports the exact path and 0600 permissions, explicitly labels provisioning synthetic, and emits a `swarmhub` fence with `op=secret_request`, `name=QA-model-key` ([reply:1201](../../../sim/results/live-7/results.json#L1201)). This retains pass 6's managed contract match. No real host, real user model key, native secure sheet or actual key handoff was exercised. |
| **P07 — owner/coordinator approval gates; user scope change kills and relaunches** | worse → **matches** | Money/prod/secrets gate rows pass; fixture denials are final, and each exact denied resubmission fails **64**. **028** emits the pending money action in an exact approval fence ([reply:1397](../../../sim/results/live-7/results.json#L1397)). Scope replacement cancels parent/peer work and obsolete held work. Rows `QA-P07-real-job-running` and `QA-P07-running-process-killed` establish a live CLI tree before cancellation, then `cancelled / exit 125` ([cancel record:42](../../../sim/results/live-7/QA-P07-running-scope-killed.json#L42)). Crucially, `QA-P07-corrected-scope-verified` now passes: replacement `job.0eb870995b434e859c99859141332016` has valid report, tests passed and exit 0 ([final receipt:27](../../../sim/results/live-7/QA-final-local-state.json#L27)); **032** receives its completion. Exact app-shaped FAKE draft submission is idempotent. This closes pass 6's failed replacement-job blocker. Native card/decision/Draft Send interaction, real human/coordinator approval and real outbound gating remain untested under the same FAKE-only boundary used in pass 6; no successful commit/rebuild is attributed to P07. |
| **P08 — results to Konrad+Jarvis 08–23 Warsaw; Jarvis otherwise** | matches → **matches** | Row `QA-P08-report-real-current-time` selects QA-Jarvis and QA-Konrad at approximately **14:58 Warsaw** on the recorded run date. Both durable delivery records become delivered ([delivery:559](../../../sim/results/live-7/QA-P08-report-delivery.json#L559), line 570), and turns **036/038** return `NO_REPLY`. This establishes the actual daytime branch; nighttime/DST behavior remains prior offline coverage, not a second live observation. QA-Konrad is a receiving session, not contact with the real user. |
| **P09 — autonomous allowlist instead of repeated approval; outbound stubs FAKE** | matches → **matches** | Rows `QA-P09-autonomous-read`, `QA-P09-outbound-FAKE` and `QA-P09-no-send` pass. `/bin/pwd` records `gate=auto`, `done`, exit 0 and no decider ([action:383](../../../sim/results/live-7/QA-P09-autonomy.json#L383)). Outbound binds exact recipient/text/argv, finishes `FAKE: no outbound operation executed`, and never creates its marker ([draft:399](../../../sim/results/live-7/QA-P09-autonomy.json#L399)). The runner submits these actions; this does not establish general model initiative or interception of arbitrary connector actions. |
| **P10 — unreachable target reported pending and retried later, without false success** | matches → **matches** | `QA-P10-offline-durable` returns pending. The same durable ID records **attempt 1 / pending / “Unacknowledged (exit 3); retained for retry”** ([offline:581](../../../sim/results/live-7/QA-P10-unreachable-pending.json#L581)). After recovery it records **attempt 2 / delivered**, error null ([retry:581](../../../sim/results/live-7/QA-P10-automatic-retry.json#L581)); **040** is the single receiving turn and returns `NO_REPLY`. This retains the managed automatic-retry match. The target outage is the temporary local bridge, not a separately powered-off production machine. |

## What changed from pass 6 and what remains

The three previously failing low-level coding checks now pass: first-job
verification, unattended queue advancement, and corrected-scope verification.
Their evidence is fresh reports plus runner-configured NOTES marker checks.
The CLI-written reports say they found no configured verification command, while
the outer job receipts independently record a passing configured `grep` command.
Those are distinct observations: the outer check is valid evidence of that
specific marker, but neither it nor a report proves a commit, rebuild or broad
correctness. Both P01 HEADs remain unchanged.

GAPS3's nested socket failure is therefore no longer a blocker for these supplied
pass-7 edits/checks. Its model-to-app fence changes are reflected in P06 and P07's
actual replies, and the receipt wording distinguishes verification not run.
The later private-copy isolation is also retained:
[QA-cli-isolation.json:2](../../../sim/results/live-7/QA-cli-isolation.json#L2) asserts source
auth/config contents and metadata unchanged, with nonsymlink private 0600 copies.
These facts do not supply native Swift or deployed integration acceptance.

To close the two nonmatching patterns under this standard:

1. **P01:** capture the ordering bot reviewing the actual completion, successfully
   committing and rebuilding in an authorized writable repository, then choosing
   and launching the next job without user prompting. A preloaded queue and
   `tests` evidence alone leave those exact steps unproven.
2. **P04:** capture an actual failed/empty-job correction being received and acted
   on, with explicit model/high effort, a successful corrective relaunch, and
   output-file/verification evidence checked before a success report. The pass-7
   correction's `NO_REPLY` and intentionally tool-disabled receiver do not meet it.

The supplied results contain **117 PASS / 0 FAIL**, including terminal checks for
20 exact owned Hermes runs, deletion/absence checks for ten exact owned sessions,
unchanged source auth/config, and local-process/private-file cleanup rows. These
are recorded harness outcomes, not checks rerun by this grading review, and they
do not override the two pattern-level gaps above.
