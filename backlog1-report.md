# backlog1 — next SwarmHub item

Date: 2026-11-08. Repository: `conrader/swarmhub`.
Branch: `feat/backlog1-launch-recovery`, based on PR #35 head
`148f9058826dd6b8360f50fbddd2027f62395d2f`.
Draft PR: [#36 — retain and recover jobs after uncertain launcher receipts](https://github.com/conrader/swarmhub/pull/36).
Implementation commit: `ce475e6`. PR base: `feat/swapjobs1` (PR #35 is still unmerged).

## Read-only triage

- GitHub returned **zero open issues** and three open PRs:
  [#6](https://github.com/conrader/swarmhub/pull/6) (restricted jobroute),
  [#8](https://github.com/conrader/swarmhub/pull/8) (jobroute recovery/trust follow-ups), and
  [#35](https://github.com/conrader/swarmhub/pull/35) (job commands and reversible migration).
  #35 has no inline review threads. Its head is still `148f905`; main is `4e9d4de`.
  #35 already imports #8, including #6. This change is stacked on #35 so its draft diff
  can be reviewed separately without merging any dependency.
- Reviewed [README](README.md), [PLAN](PLAN.md), [KNOWN-GAPS](KNOWN-GAPS.md),
  [command/migration contracts](docs/swap-jobs-migration.md),
  [jobroute design](ops/jobroute/README.md), [team coordination](docs/team-coordination.md),
  and relevant reference/feature sections. PLAN contains dated historical entries;
  it was checked against current sources instead of treating every old gap as open.
- A case-sensitive `TODO|FIXME` scan of `Sources`, `Packages`, and `ops` (excluding SVGs
  and the copied secret scanner) returned no hits. Concrete candidates came from code
  and contract gaps, rather than invented TODOs. `KNOWN-GAPS.md` records a deliberate
  PID-namespace ancestry exception; it remains outside this task.
- Inspected the route's reservation, receipt, recovery, status/report and Mac-worker
  code and their tests. Current Swift sources already have steering, automatic context
  recovery and isolated setup sessions (`AppStore+ContextRecovery.swift`); improving
  combined regression coverage is more useful than reimplementing those features.

## Ranked next items

Scores are relative prioritization judgments, not measured delivery estimates.
Value is contribution to reliable Grok Bot replacement; effort includes implementation
and verification. All five can be developed against local fixtures without production,
paid model calls, account credentials or deployment.

| Rank | Item | Value / effort | Evidence and intended outcome |
| --- | --- | --- | --- |
| 1 | Recover detached jobs after ambiguous launcher exits/receipts | 5 / 1 = 5.0 | `_launch` wrote `failed` on nonzero exit or missing receipt; `own_jobs` then removed the reservation even if a job record existed. Reuse timeout recovery so running/completed jobs stay visible and live jobs still count toward capacity. **Built here.** |
| 2 | Retry-safe launch request IDs | 5 / 2 = 2.5 | `submit` creates a new random reservation for every request; `launch` has no caller request ID. Bind an optional profile-scoped ID to the payload and reuse its result after a lost client response, rejecting changed payloads and concurrent duplicates. This is separate from recovery of a launcher error. |
| 3 | Explicit completion and report evidence | 2 / 1 = 2.0 | `_state` calls every ended job `done`; consumers must interpret `exit_code`, while `report()` combines log/report text and a missing report can be empty. Add compatible structured outcome/artifact fields so a bot can distinguish success, failure and missing evidence before reporting back. |
| 4 | Offline Mac queue handoff/failure contract tests | 4 / 3 = 1.33 | `mac-worker.py` uses the shared `sb-macjob` runner, but current tests largely record argv/environment. Add subprocess fixture scenarios for two queued submissions, runner failure and result propagation without creating a second queue. Native FIFO acceptance remains a later sb-macjob follow-up. |
| 5 | Combined steering, overflow and internal-session regression scenarios | 4 / 4 = 1.0 | `AutoContextTests`, `ChatParityTests`, `SteerUnreadTests` and coordination recovery tests cover the individual paths. Add composed stub-backend scenarios with concurrent jobs, queued steer and internal setup retry, asserting no main-session contamination or error popup. Native verification requires a later sb-macjob. |

Excluded: hb-pilot activation or resolving its BOT_HOST dependency, permission/service
changes for #6/#8, real OAuth/OpenClaw acceptance, signing/releases and deployment.
`c554005a8` remains HOLD; liveboard remains local.

## What was built

- Nonzero launcher exits and missing/empty/multiple/malformed status receipts now use
  `_abandon` and the existing reservation recovery path instead of recording a false
  definitive launch failure. Receipt validation also requires a `.json` path and rejects NULs.
- A recovered job is named in the error, appears in owned status and consumes a running
  slot if live. Recovery is audited once and never starts another job. Completed-job
  exit codes come from the job record, not the launcher's exit code.
- With no matching record yet, status retains `unknown` and later queries can recover
  it. The error directs the caller to inspect status before retrying. Such reservations
  retain hourly/daily accounting; the existing rule that unknown jobs do not consume
  running slots is unchanged. A failure to execute the launcher itself still closes
  the reservation as failed.
- Added 50 Linux regression cases: legacy CLI submit, MCP submit and opt-in launch;
  running/completed records; eight receipt/exit combinations; profile isolation;
  once-only recovery; running-limit enforcement; delayed lookup; and pre-exec failure.
  Updated two existing assertions to require the new unknown-outcome semantics,
  including hourly-limit enforcement. Updated both route and command docs.

## Validation

Final gate: **355 passed, 0 failed, 0 skipped** (71.90 seconds), plus **17/17
throwaway SSH checks**, runner exit **0**. This includes the full route, trust,
installer and swap-command test set and all 50 new regression cases.

```sh
bash ops/jobroute/tests/run-sandbox.sh
git diff --check
```

`git diff --check` passed. The final run used stage `/tmp/jobroute-test.FWfjZW`.
No Swift, Xcode, real-model or live acceptance test was run.

The initial regression run against unchanged PR #35 runtime code produced **25 failed,
7 passed, 305 deselected**: the failures reproduced the bug, while six existing
foreign-path recovery cases and the pre-exec failure case already passed. Later receipt
edge cases expanded the new tests from 32 to 50.

The first full run after the fix produced **354 passed, 1 failed**, plus **17/17 SSH
checks**. The failure was the second old assertion that a nonzero launcher exit must
disappear from status; it was corrected to require an unknown reservation.

Evidence is local in `/home/ubuntu/work/Swarmhub/backlog1-evidence/`:
`baseline.log`, `full.log`, and `full-final.log`. The documented sandbox runner stages
code and a copy of sb-codejob, runs as `sbtest` in isolated PID/user namespaces, uses
recording engines and a throwaway loopback sshd. The copied-launcher integration cases
use a stub engine and a nonexistent wake configuration. No real bots or Mac were contacted.

## Follow-ups and limits

- Review the draft against `feat/swapjobs1`; coordinate eventual landing with #35/#8/#6.
  No merge is requested by this report.
- Recovery still uses the existing label/argv/workdir/time-window matching. This is
  not exactly-once execution or full launch idempotency (rank #2). Historical `failed`
  rows are not rewritten. Unknown outcomes need reconciliation before a caller retries.
- No Swift/UI code changed, so Mac/Xcode verification is not required for this Linux
  route fix. Before combined desktop acceptance, use a **separate follow-up sb-macjob**
  against the pinned branch: fresh checkout, hermetic `swift test`/AgentAppTests with
  fixture backends, especially AutoContext, ChatParity and concurrent-turn cases;
  no live gateway, install, release or deploy. **Not submitted or run here.**
- Shared-Mac FIFO/worker native verification remains the separate follow-up described
  in the existing migration runbook; this task did not activate that worker.

No merge, release, deploy, production unit/config edit, credential access, approval
decision or pilot activation was performed. Submission defaults remain disabled.
