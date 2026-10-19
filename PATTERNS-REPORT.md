# Observed patterns: managed runtime implementation

Implemented the remaining gaps on top of `PEER-REPORT.md`. Both affected bundled
skills and the peer plugin are version **1.3.0**. No commit, deployment, live
provider call, real provisioning, outbound send or credential change was made.

All **P01–P10 grade `matches` in the offline managed-runtime replay**. These are
bounded acceptance results using shipped scripts with synthetic CLI/curl I/O,
not a regrading of the historical live capture or universal app certification.
Results: [patterns-20261019/results.json](sim/results/patterns-20261019/results.json).

| Pattern | Implemented behavior and replay evidence |
| --- | --- |
| P01 | Completion wakes include exit/status, explicit model/effort and the report path/existence, plus “take the next step.” A persistent standing queue automatically launches the next verified job for that bot. Failure holds later jobs until cancelled/replaced. A separate scheduler keeps the queue moving while gateway acknowledgements are slow. |
| P02 | `swarmctl register <profile> --coordinator` registers a wake/policy subscription and the unknown-origin fallback. Installation registers recipients automatically. Registration references the existing authenticated profile gateway; credentials are resolved from its current `.env`, never printed/copied into webhook settings. The replay registers a coordinator and routes an unknown-origin completion there. |
| P03 | Existing held/priority delivery and whole-answer quiet suppression remain covered by a replay: held sends make no HTTP request, next-turn context consumes them, and a priority `NO_REPLY` causes no reverse wake. |
| P04 | `code-job` passes explicit model/effort flags to the CLI and requests a report. Records include CLI exit separately from contract exit, report path/existence, validation and hashes. CLI zero with empty output, no/empty report or unchanged prior report fails with exit **65**. Tests also inspect actual stub argv. |
| P05 | Versioned SQLite policy has subscribers and is read at admission and dispatch, independently of prompt context. `route: codex` overrides agent order; optional `codex_model` pins the replacement model. `allow_speculative: false` rejects declared speculative work. Subscriber acknowledgements cannot erase a newer revision published mid-turn. Chat-provider configuration is not changed. |
| P06 | Managed provisioning/secrets actions require the owner. The synthetic provisioning replay creates an owner-only secret file after approval and exposes its path, not its contents, in the action record. Existing priority and late-reply transport regressions also pass. No cloud service was provisioned. |
| P07 | Managed money/prod/secrets actions require owner approval; real outbound drafts require the coordinator and store exact recipient/text/argv. Decisions bind to immutable records. Denial persists by intent and operation fingerprint, including relabelling under another ID. Scope replacement cancels the old task tree and waits for its process to stop before launching replacement work. Stop reaches held messages, queued deliveries, running peer streams and CLI process trees. |
| P08 | `swarmctl report` computes recipients: coordinator always, plus owner during **08:00 inclusive–23:00 exclusive Europe/Warsaw** by default. Reporting settings use IANA timezones. Tests cover both boundaries, summer/winter offsets, the DST change and a wrapping window. |
| P09 | Managed absolute system `pwd`, `ls`, `stat` reads run without another approval. An executable merely named `ls` is not allowlisted. `fake: true` outbound records FAKE and never executes its argv. Real outbound remains gated. |
| P10 | `bot-msg --durable` journals before network I/O and returns a truthful **pending** receipt. A persistent worker retries without a ceiling, retaining attempts/deadline/error. Ordinary priority sends also queue a retry when the gateway is unreachable before chat submission, while retaining exit **3**. Fresh-process recovery and rotated profile credentials are tested. |

Receiver deduplication is separate from the sender outbox: `(recipient, delivery
ID)` is journalled with a claim/lease and post-turn acknowledgement. A completed
receiver acknowledgement survives a missing sender ACK; retries then return
without another gateway turn. Concurrent claims for the reused peer session are
serialized. Unanswered claims can recover after the lease. Arbitrary model-tool
side effects are not transactionally exactly once across a crash before ACK.

The app persists/parses durable mode and task IDs, labels admission “Delivery to
… pending,” and keeps queue receipts out of replies and active-recipient state.
That chip describes admission mode; `swarmctl status` is the durable delivery
status. Existing saved calls retain their previous interpretation.

## Installation and operation

Update both skills through the existing SwarmHub Install flow. Reload the peer
plugin/gateway when required by Hermes. Python **3.9+**, SQLite, IANA timezone
data and the pre/post hook support described in `PEER-REPORT.md` are required.
Configure real local coordinator and owner receiving profiles. There is no
hardcoded Jarvis/Konrad profile and no new public HTTP endpoint or webhook key.

The messaging skill's `scripts/swarmctl` provides `register`, `policy [set]`,
`submit`, `decide`, `replace`, `stop`, `report`, `status` and `tick`. JSON bodies
arrive on stdin; no shell evaluation is used. The two updated SKILL.md files
document payloads, configuration and command examples. In particular:

- Publish `coordinator`, `owner`, `route`, optional `codex_model`,
  `allow_speculative`, `timezone`, `start` and `end` with `policy set`.
- Submit standing work with stable intents and parent IDs. Coding specs require
  an absolute directory, task, model, effort and report. External actions store
  argv; outbound also requires recipient and exact draft text. Declare risks.
- The deciding role uses `decide <id> <profile> approve|deny`. Replacement takes
  a new intent and new JSON, cancels the old tree and requires fresh approvals.
- Direct authorized `code-job` calls now need `--model` and `--report` (or
  `CODE_JOB_MODEL`/`CODE_JOB_REPORT`). Effort defaults to explicit `high`.
  Model IDs must be supported by the selected CLI. When forcing Codex for jobs
  pinned to another provider, configure a supported `codex_model`.

Private state is retained under `~/.hermes/swarmhub`: inbox and control SQLite
databases, cancelled-task tombstones, and completion directories. Control records
retain the task/argv needed for recovery; completion records retain metadata and
hashes, not CLI output or report contents. Supply secret-file paths, never keys,
in task payloads/argv. The process lock prevents competing recovery workers.
Plugin startup, admission, policy/registration changes and code-job completion
start recovery; `bot-msg --retry` or `swarmctl tick` also recover pending work.
A killed worker needs a startup path to run again. Failed jobs are not blindly
replayed after an uncertain process loss.

## Validation and limits

- `python3 -B -m unittest discover -s sim -p 'test_*.py'`: **87 passed**.
  Includes ten P01–P10 replays and eight additional regressions for denial
  resubmission, failed-queue release, policy revisions, approved job parameters,
  active peer cancellation, basename spoofing, default unreachable retries and
  a slow wake acknowledgement that must not stall queued jobs.
- `python3 -B sim/live_observed.py --offline --output sim/results/patterns-20261019`:
  **10 matches**, zero model calls. `--pattern P01` selects one replay. Historical
  live captures are untouched; the live runner still reports its actual limits.
- `Tests/Scripts/code-job-test.sh`: **15 passed under /bin/sh; 15 under /bin/dash**.
  Both shipped shell scripts pass syntax checks under both shells. Python syntax
  and `git diff --check` pass.
- Added two native Swift parsing/persistence/UI-state tests and ten parameterized
  Swift replay cases; updated skill/version/install assertions. **Swift is not
  installed on this box, so these have not been compiled or run.** The previous
  socket-based gateway test remains subject to the sandbox boundary documented
  in `PEER-REPORT.md`; all new tests use file-based synthetic transport.

Approval decisions are a **trusted local administrative interface**: profiles
share one Unix account, and a caller-supplied deciding profile is not independent
authentication against malicious unrestricted shell access. Managed gates,
declared risks, subscriptions and reporting apply to these entrypoints; they do
not intercept arbitrary terminal commands, every connected-app tool or all app
goal-completion paths. Remote stream cancellation relies on the gateway's
disconnect/stop behavior and cannot undo completed external effects. Live Hermes
plugin activation, genuine cloud provisioning, human notification delivery and
native macOS behavior still need integration validation before claiming all ten
patterns match universally in a deployed product.
