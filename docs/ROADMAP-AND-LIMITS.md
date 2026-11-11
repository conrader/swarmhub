# Roadmap and limits

Living status page, reviewed offline on 2026-11-11 against current main
`349db4c`. Main contains merged #35–#56 plus reviewed fixround3 #58 (`510c5b3`)
and iOS fix #59 (`349db4c`). Update a gate only with revision, environment and
dated evidence. Merge status, local release history and live acceptance are
separate states. Publication and installed services remain **unverified** here.

## Source and release baseline

Local [release history](CHANGELOG.md) and bundle metadata cover **0.6.8**.
The merged #35–#56 plus #58 stack includes jobroute/worker and app fixes,
with coding skill **1.3.16** and messages **1.4.16**; #59 fixes iOS Debug
simulator architecture selection. Merge status does not establish publication or installation. [Stack readiness](releases/stack-merge-readiness.md)
preserves dated test results and their validation limits.

## Outstanding acceptance and operational gates

| Area | Gate still requiring evidence / action |
|---|---|
| Stack and route | The stack through #58 is merged; fixround3 is reviewed. Validate deployment suites in a suitable environment at the selected reviewed main SHA. Prepare a separately approved pinned route rollout with an observed rollback target. Coordinate the completion skill with the route's `outcome` contract. |
| Dedicated-account pilot | Resolve BOT_HOST and maintenance placeholders, independent trust/isolation evidence and resealing. Real UID/key isolation, OAuth handling, proxy routes, wakes, routine enabling and S1 registration remain pilot gates. Use the [migration runbook](swap-jobs-migration.md); an installed but disabled route is not a completed pilot. |
| Mac worker | **Keep disabled** pending the isolated Mac pilot; install separately, upgrade and verify the installed sb-macjob queue-lock/session contract, FIFO handoff, deadline cleanup and real SSH failure behavior. Code/fixtures do not establish Mac behavior. A distinct sb-macjob queue-busy status remains follow-up work. See the current Known limits below. |
| Signed native release | Obtain signed Mac build and acceptance evidence for app/skill changes. Historical unsigned tests do not close native approval-card, secure-key-sheet, Draft Send, sandbox or real coding-tool checks. Draft Send here still records a test action. |
| Live integration | Real OpenClaw Gateway setup, manager operations and approvals; provider-backed Hermes cancel/approval/delegation; legacy-gateway filtering; live voice; real TLS/Keychain managed approvals. Retain [recorded integration limits](hermes-integration.md) and [OpenClaw limits](openclaw-integration.md) until verified. |
| Import and recovery | Owner-attended Grok import/login acceptance, offline/reconnect/quit-mid-answer recovery, skill installation and first real bot-report/message flows from the old plan still need dated closure evidence. Do not infer completion from shipped UI. |
| Update signing and baseline | P1b key ceremony: confirm hardware Ed25519 capability, obtain and separately store recovery/publishing keys, sign the first real manifest and baseline; preserve the Sparkle signing-key backup gate. [Original key-ceremony phase](archive/plans/CORE-PHASES.md#p1b-key-ceremony-k), [baseline contract](update-service/BASELINE.md). Releases through 0.6.8 omit the signed embedded baseline. |
| Hosting, bootstrap and canary | Provision hosting/CDN/DNS and mirror, verify both origins, install the protected bootstrap on approved boxes, then enable a Linux/Mac canary. Verify mid-turn skill swaps and installed Hermes-version compatibility. Perform roll-forward and key-rotation drills with real keys. [Bootstrap](update-service/BOOTSTRAP.md), [updater](update-service/UPDATER.md), [channels](update-service/CHANNELS.md). |
| Device approval and iOS | Real device enrollment/cutover and native Mac/iOS acceptance remain separate from protocol code. Reconfirm App Store requirements and prepare submission/review evidence. [Device approvals](update-service/DEVICE-APPROVALS.md), [iOS notes](ios/APP-REVIEW-NOTES-SDUI.md). |
| Product backlog | OpenClaw skill installation/model recipe and heartbeat management; group-chat reviewer triggers; contextual bug-report suggestions. These old-plan follow-ups have no closure evidence in this review. Windows/Linux clients and Android remain planned; iOS has a native foundation. |
| External configuration | Historical sign-in/provider/connector setup and box-ops housekeeping need owner/operator reconciliation. Current credentials and service configuration were not inspected. Old plan observations are not instructions to change a live box. |

## Known limits

The pre-fixround3 Known limits supplied to PR #57 described `7963b72`.
The current contract below incorporates merged and reviewed #58 (`510c5b3`);
its cleanup behavior supersedes those older source observations.

The Mac path remains **disabled and unverified on the Mac**. No `mac_dispatch`
backend is configured by default. The ovh installer does not install the worker
on the Mac; ship the worker and both pinned helpers together during a separately
approved pilot. Earlier supplied evidence described an installed MacBook
sb-macjob without `queue`, `--queue-wait` or `--no-wait`; this job did not recheck
it. Upgrade and verify the actual FIFO runner's queue-lock and parent/escalation
contract before activation. Linux fixtures do not establish that contract.

The six-hour call limit includes queue wait; the child-owning supervisor also
enforces four hours from workload launch. Cleanup uses only the in-memory,
unreaped child identity. Disk PGIDs do not authorize signals or workspace removal.
An independent cancellation latch requests workload drain before runner termination.
Supervisor settlement (135 s) plus runner cleanup (130 s) can add 265 s. Queue
snapshots have no workload: at most 60 + 130 s within the 225 s route budget.
Locks, inspection and I/O have finite application budgets; OS/filesystem stalls
can exceed those budgets.

Exit 124 requires an enforced deadline with confirmed drain of cooperating
processes in the original group and direct-child reap. Exit 125 means incomplete
cleanup or invalid protocol; unresolved work keeps its guardian, and remaining
workspace/control/log/result evidence is retained. Exit 126 means process cleanup
completed but artifact removal failed. Both have null cause/signal. Persistent
`ps` failure is `process_inspection_failed`, not proof of drain. Never automatically
retry an unknown result. Workloads must not daemonize, call setsid/setpgid or escape
the original group. A runner crash/SIGKILL can release the queue lock before watchdog
cleanup; crash-safe exclusion would need a durable admission hold honored by all
entrants. Simultaneous guardian SIGKILL and arbitrary same-UID interference remain
outside the contract.

Exit 75 remains ambiguous (queue-wait expiry or the workload's own status) and
has no cause. SSH 255 means transport failure and does not prove nothing ran;
a runner's own 124/125/126/255 maps to 1. Real OpenSSH failure behavior and Mac
TERM/queue handoff still require the isolated pilot. See the
[migration contracts](swap-jobs-migration.md#command-contracts) for status precedence
and the full activation gate.

### Accepted ancestry exception

`swarm_devices.ancestors()` passes the ancestry check when `ppid` is 0 (caller
in a foreign PID namespace); the `HERMES_*` environment check runs first. This
was left as-is by decision on 2026-10-23 because failing closed would break
namespaced fixtures. **Accepted is not fixed.** The original single-entry
[KNOWN-GAPS record](archive/reports/KNOWN-GAPS.md) is preserved.

### Disabled or bounded behavior

- Off-app alerts remain disabled on both sides. Eligible count-based loops can
  run on the box; goals and `--until` loops stay in the app while it is closed.
  The service design and legacy reclaim code do not enable new goal handoffs.
  See [off-app alerts and handoff](offapp-alerts.md).
- P13 sub-agent guidance remains off after the recorded Hermes canary failed.
  Re-enabling needs a delivery fix and a new canary, not just source presence.
  See the dated [P13 canary](P13-canary.md).
- Request-ID retry safety lasts only while the profile ledger is retained;
  it is not exactly-once execution after storage loss. Unknown launch outcomes
  need status/recovery, not a new ID. [Route contract](../ops/jobroute/README.md).
- Automatic approvals use a textual executable/option filter, not a sandbox.
  Group-chat reviewer triggers and backend decision latching/policy revalidation
  retain the limits described in the [technical reference](reference.md#approval-safety-and-scope).

## Accepted architecture and historical plans

The accepted [CORE-PLAN decision](archive/plans/CORE-PLAN.md) keeps normal
app-to-box traffic direct; the update service is a signed release pipeline and
static host, outside the runtime path. Consumers verify bundles and keep the
last good version; code-bearing updates require confirmation. Approval and
secret-entry surfaces remain compiled, outside remotely delivered configuration
and SDUI. Current contracts live in [schemas](update-service/SCHEMAS.md),
[staged install](update-service/STAGED-INSTALL.md) and the runbooks above.

[CORE-PHASES](archive/plans/CORE-PHASES.md) preserves original sequencing and
external gates. Its old “Now” rows are not claims that implemented updater/SDUI
work is still unbuilt. [PLAN](archive/plans/PLAN.md) preserves release/decision
history, including the revised avatar-motion exception; historical briefs are
not a standing ban on that accepted motion. See [avatar behavior](avatar-animation-scenarios.md).

Job evidence is retained in [backlog1](archive/reports/backlog1-report.md),
[backlog2](archive/reports/backlog2-report.md) and [fix round 2b](archive/reports/fixround2b-report.md).
No P2 archive moves are included: root [briefs](../briefs/) and top-level review
and phase reports stay in place. The [archive index](archive/README.md) records
what moved and how to read historical references.
