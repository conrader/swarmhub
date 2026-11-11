# Roadmap and limits

Living status page, reviewed offline on 2026-11-11 against `7963b72` (user-supplied
draft PR #56 tip). Update a gate only with revision, environment and dated
evidence. Source presence, local release history and live acceptance are
separate states. GitHub heads/reviews, publication and installed services are
**unverified** in this review.

## Source and release baseline

Local [release history](CHANGELOG.md) and bundle metadata cover **0.6.8**.
The #35–#56 source stack includes subsequent jobroute/worker and app fixes,
with coding skill **1.3.16** and messages **1.4.16**. These are not claims that
the stack is merged, published or installed. [Stack readiness](releases/stack-merge-readiness.md)
preserves dated test results and their validation limits.

## Outstanding acceptance and operational gates

| Area | Gate still requiring evidence / action |
|---|---|
| Stack and route | Confirm actual #35–#56 heads, dependencies and cross-reviews; validate suites in a suitable environment at the reviewed head. Prepare a separately approved pinned route rollout with an observed rollback target. Coordinate the completion skill with the route's `outcome` contract. |
| Dedicated-account pilot | Resolve BOT_HOST and maintenance placeholders, independent trust/isolation evidence and resealing. Real UID/key isolation, OAuth handling, proxy routes, wakes, routine enabling and S1 registration remain pilot gates. Use the [migration runbook](swap-jobs-migration.md); an installed but disabled route is not a completed pilot. |
| Mac worker | Install separately; upgrade and verify the installed sb-macjob queue-lock/session contract, FIFO handoff, deadline cleanup and real SSH failure behavior. Code/fixtures do not establish Mac behavior. A distinct sb-macjob queue-busy status remains follow-up work. See the supplied Known limits below. |
| Signed native release | Obtain signed Mac build and acceptance evidence for app/skill changes. Historical unsigned tests do not close native approval-card, secure-key-sheet, Draft Send, sandbox or real coding-tool checks. Draft Send here still records a test action. |
| Live integration | Real OpenClaw Gateway setup, manager operations and approvals; provider-backed Hermes cancel/approval/delegation; legacy-gateway filtering; live voice; real TLS/Keychain managed approvals. Retain [recorded integration limits](hermes-integration.md) and [OpenClaw limits](openclaw-integration.md) until verified. |
| Import and recovery | Owner-attended Grok import/login acceptance, offline/reconnect/quit-mid-answer recovery, skill installation and first real bot-report/message flows from the old plan still need dated closure evidence. Do not infer completion from shipped UI. |
| Update signing and baseline | P1b key ceremony: confirm hardware Ed25519 capability, obtain and separately store recovery/publishing keys, sign the first real manifest and baseline; preserve the Sparkle signing-key backup gate. [Original key-ceremony phase](archive/plans/CORE-PHASES.md#p1b-key-ceremony-k), [baseline contract](update-service/BASELINE.md). Releases through 0.6.8 omit the signed embedded baseline. |
| Hosting, bootstrap and canary | Provision hosting/CDN/DNS and mirror, verify both origins, install the protected bootstrap on approved boxes, then enable a Linux/Mac canary. Verify mid-turn skill swaps and installed Hermes-version compatibility. Perform roll-forward and key-rotation drills with real keys. [Bootstrap](update-service/BOOTSTRAP.md), [updater](update-service/UPDATER.md), [channels](update-service/CHANNELS.md). |
| Device approval and iOS | Real device enrollment/cutover and native Mac/iOS acceptance remain separate from protocol code. Reconfirm App Store requirements and prepare submission/review evidence. [Device approvals](update-service/DEVICE-APPROVALS.md), [iOS notes](ios/APP-REVIEW-NOTES-SDUI.md). |
| Product backlog | OpenClaw skill installation/model recipe and heartbeat management; group-chat reviewer triggers; contextual bug-report suggestions. These old-plan follow-ups have no closure evidence in this review. Windows/Linux clients and Android remain planned; iOS has a native foundation. |
| External configuration | Historical sign-in/provider/connector setup and box-ops housekeeping need owner/operator reconciliation. Current credentials and service configuration were not inspected. Old plan observations are not instructions to change a live box. |

## Known limits

The following text is retained verbatim from the supplied `../known-limits.md`
(read 2026-11-11). Its installed-Mac observations are supplied evidence, not a
remote check performed by this documentation job.

**Known limits.** The Mac path is inactive and unverified. No `mac_dispatch` backend is configured by default, and `mac-worker.py`
is installed separately during the approved pilot. The worker needs the queued sb-macjob contract (`queue --json`, `--queue-wait`,
a FIFO runner that holds the lock until its session drains), and that contract was read only from ovh's copy. The MacBook's
installed sb-macjob is an older build without `queue`, `--queue-wait` or `--no-wait`, so it must be upgraded and its lock/session
contract checked before the pilot. Workloads must not daemonize into additional sessions. The six-hour limit includes queue wait.
At the deadline, cleanup stops the workload, then the runner. Each phase has a 120 s TERM grace and bounded 5 s KILL retries, plus
a 5 s reap: about 255 s nominal. A blocking control-file lock or a hung `ps` can stretch that. Cleanup is best effort and does not
fail closed. If the runner exits early (it crashes, or sb-macjob gets TERM/INT/HUP, which the supervisor does not pass on to its
workload session), the workload can keep running with no limit after the queue lock is released. The same can happen after launch
if the control file is missing or corrupt, or if a KILL drain is never confirmed. In those cases the workspace and control evidence
may also be removed. A forged or foreign PGID, or a `ps` failure, can stop cleanup before the runner is stopped. The workspace is
kept then, but the worker reports exit 2 or 1 rather than 124. Exit 124 means the deadline path ran, not that every descendant
stopped. A supervisor exit of 0 doesn't prove its descendants drained either. Exit 75 is still ambiguous (queue-wait expiry or the
workload's own 75) and gets no cause. SSH 255 means a transport failure, and after launch it doesn't prove nothing ran. Real
OpenSSH 255 and a live Mac TERM/queue run haven't been exercised.

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
