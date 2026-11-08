# backlog2 — retry-safe launch request IDs

Date: 2026-11-08. Repository: `conrader/swarmhub`.
Draft PR: [#37 — add retry-safe launch request IDs](https://github.com/conrader/swarmhub/pull/37).
Branch: `feat/backlog2-request-ids`.
Worktree: `/home/ubuntu/work/Swarmhub/backlog2-wt`.
Implementation commit: `ad9fa541549fede6b10050c9e0edb3a55ddcb7d1`.
Base: [PR #36](https://github.com/conrader/swarmhub/pull/36),
`feat/backlog1-launch-recovery` at `0dcdb15d383dd360a7a22531cb0d2dc9c2022f10`.
#36 remains stacked on [#35](https://github.com/conrader/swarmhub/pull/35),
`feat/swapjobs1` at `148f9058826dd6b8360f50fbddd2027f62395d2f`.
**No merge of #35, #36 or #37 is requested or performed.**

## What was built

- Optional `request_id` on CLI `submit`, MCP `submit_job`, and opt-in CLI/MCP
  `launch`. IDs are profile-scoped, case-sensitive, 1–64 ASCII characters
  `[A-Za-z0-9_-]`, starting alphanumeric. Omitted IDs preserve legacy behavior.
- The existing locked reservation atomically binds an ID before launch to a SHA-256
  of the validated effective payload: operation, configured agent, engine name,
  label, resolved workdir, exact brief digest and review choice. `launch` includes
  its appended report instruction. CLI/MCP and equivalent workdir spellings match.
  Submit and launch share a profile's ID namespace but are distinct operations.
- A matching retry after a lost client response returns the stored acceptance
  response and job ID. It launches nothing and consumes no further submission or
  command quota, including when the first job filled the running/hourly/daily limit.
  Current validation, submission switches and verb authorization still apply.
- Changed payloads are refused (CLI exit 2). Concurrent duplicates still launching
  are refused (exit 3), with instructions to retry the same request later. Unknown
  outcomes remain bound and return an error (exit 1), never a replacement launch.
- #36's existing recovery can resolve an interrupted/uncertain launch on a later
  retry and return its receipt. A definitive pre-exec failure remains bound and
  returns an error without retrying execution. Historical `failed` rows are not
  rewritten and remain excluded from owned status/recovery.
- Bindings and response templates live on reservation rows in the existing profile
  ledger; no new database, queue or production configuration is needed. Failed rows
  remain available to ID lookup. Request IDs appear in acceptance responses, owned
  status summaries and submission audits; successful replay is audited as `replayed`.
  Raw briefs are not stored in the binding or audit.
- Updated both route and migration command contracts, MCP tool schemas, and the
  throwaway SSH harness. Added 101 Linux tests and six SSH checks.

## Validation

Final full gate:

```sh
bash ops/jobroute/tests/run-sandbox.sh
```

**456 passed, 0 failed, 0 skipped**, in **103.10 seconds**, plus **23/23 SSH
checks**, runner exit **0**. Stage: `/tmp/jobroute-test.OQ2oM8`.
`git diff --check`, Python compilation checks and `bash -n` for the SSH harness passed.

Coverage includes fresh-process reconnects, response equality, CLI/MCP parity,
payload and review conflicts, profile isolation, concurrent duplicates, quota
exhaustion, killed route recovery, missing/nonzero launcher receipts, delayed
recovery, unknown and failed bindings, legacy submissions, ID validation/boundaries,
expired quota windows, missing job records, current authorization and tool schemas.
SSH verifies reconnect replay, CLI-to-MCP replay, changed brief/review refusals,
launch replay at capacity and exact launcher counts.

The first targeted run had **89 passed, 2 failed**, plus **17/17 SSH checks**.
Both failures were test assertions: same timestamp/label can yield identical job-ID
stems in different agents' directories. The profile-isolation fixture now uses a
separate label so it can test foreign-ID refusal without that collision. No runtime
change was needed for those failures; the final full run includes the corrected
fixtures, additional boundary cases and the six new SSH checks.

Evidence:

- `/home/ubuntu/work/Swarmhub/backlog2-evidence/targeted.log`
- `/home/ubuntu/work/Swarmhub/backlog2-evidence/full.log`

The sandbox stages the route and a copy of sb-codejob, uses recording/stub engines,
executes as sbtest in isolated user/PID namespaces, and runs a throwaway loopback
sshd with fixture keys. No real model, bot, live SSH service or Mac was contacted.

## Remaining ranked items (#3–#5)

Original ranking from backlog1, unchanged:

| Rank | Item | Value / effort | Intended outcome |
| --- | --- | --- | --- |
| 3 | Explicit completion and report evidence | 2 / 1 = 2.0 | Add compatible structured outcome/artifact fields. `_state` currently calls every ended job `done`; distinguish success, failure and missing report evidence before report-back. |
| 4 | Offline Mac queue handoff/failure contract tests | 4 / 3 = 1.33 | Exercise two queued submissions, runner failure and result propagation with subprocess fixtures using the existing shared sb-macjob queue. Native FIFO acceptance remains separate. |
| 5 | Combined steering, overflow and internal-session regression scenarios | 4 / 4 = 1.0 | Compose stub-backend concurrent jobs, queued steering and internal setup retries; assert no main-session contamination or error popup. Native verification needs a later sb-macjob. |

## Follow-ups and limits

- Review draft #37 against #36; coordinate any eventual landing across #35/#36/#37.
  This task performed a self-review and fixture verification, not an independent
  Claude review. #35/#36 and `backlog1-wt` were not edited or force-pushed.
- Clients must generate and persist one ID per intended launch and reuse both ID
  and payload after transport loss. Changing/omitting the ID starts a new submission;
  do not do that to bypass an unresolved outcome.
- Bindings have no TTL while the profile ledger is retained. Replays return acceptance,
  not execution success; query status/report for the current job outcome. This does
  not promise exactly-once execution across ledger deletion/storage loss or other
  launchers. Existing recovery still matches label/argv/workdir/time-window evidence.
- No Swift/UI code changed, so Mac/Xcode verification is not required for this change.
  For ranks #4/#5 and combined native acceptance, use a **separate future sb-macjob**
  on a pinned checkout with fixture backends: shared FIFO/runner propagation and
  hermetic Swift/AgentAppTests covering AutoContext, ChatParity, steering and
  concurrent/internal-session cases. No live gateway, install, release or deploy.
  **No sb-macjob was submitted or run here.**
- The GitHub connector could read PR metadata but returned HTTP 403 on PR creation.
  The authenticated repository GitHub CLI created the requested draft successfully.

No merge, release, deployment, live ovh unit/config edit, credential-file access,
pilot activation or approval decision was performed. Submission defaults remain off.
**hb-pilot still waits on BOT_HOST; c554005a8 remains HOLD; liveboard remains local.**
