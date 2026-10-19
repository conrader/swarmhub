# Observed patterns: managed runtime implementation

Implemented the remaining gaps on top of `PEER-REPORT.md`. Both affected bundled
skills and the peer plugin are version **1.3.1**. No commit, deployment, live
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

## Review fixes (2026-10-19)

Fixes for `REVIEW-PATTERNS.md` findings 1–10, left uncommitted in the working tree.
Hermes itself is unchanged; only skill scripts, tests and these notes moved.

- **1 (HIGH) receipts bind by delivery id.** `deliver()` prefixes every durable
  text with `[SwarmHub delivery id=<id>]`; the `pre_llm_call` hook passes the turn's
  `user_message` and `receipt_bind` binds only receipts whose id appears in it, in
  the receipt's own session. An interleaved ordinary priority send no longer
  acknowledges a pending delivery (`sim/test_review_fixes.py`).
- **2 (HIGH) held batches fit under the Hermes spill limit.** A turn's held context,
  policy prefix and header included, is capped at 9,000 characters (Hermes
  `hooks.output_spill.max_chars` defaults to 10,000); one held message is capped at
  8,000 and `codex_model` at 200 characters so a batch always fits. Overflow stays
  unclaimed and is marked delivered only by the turn that carries it.
- **3 (MEDIUM) `fake: true` is a dry run for every kind.** `tick` records
  `FAKE: no <kind> operation executed` for read/outbound/provision/money/prod/
  secrets/coding/peer without spawning, enqueueing or launching anything;
  `run_action` repeats the check. Gates are unchanged.
- **4 (MEDIUM) supervised recovery.** `peer-runtime.py start` now spawns a
  supervisor that restarts the worker after any exit with backoff (2 s doubling to
  60 s; a lock-busy exit is not a crash). Inside the worker each sweep is guarded:
  any exception is written to `job-wake.error`, backed off and the loop continues.
  A removed state folder is no longer recreated by a late worker.
- **5 (MEDIUM) decision actor verified.** `decide` derives the caller from the
  invoking gateway's `HERMES_HOME` (`swarm_store.invoking_profile`) and refuses an
  unset value, a mismatch with the named actor, or an actor that is not the gate's
  configured role; actor, pid and time are recorded on the action and shown by
  `swarmctl status`. Profiles still share one Unix account, so this is gateway
  identity plus audit, not isolation against a hostile shell.
- **6 (LOW)** liveness compares `ps -o lstart=` recorded at spawn (`pid_start`).
  **7 (LOW)** a policy-only turn no longer claims held messages were delivered.
  **8 (LOW)** `tick` records the resolved order/model (`launched`); `check_job`
  compares against it and `code-job` skips policy re-resolution for a managed task.
  **9 (LOW)** `code-job` judges empty work on stdout alone (`$T/stdout`).
  **10 (LOW)** `swarm_control.py` is a 17-line facade over `swarm_store`,
  `swarm_policy`, `swarm_delivery` and `swarm_jobs` (all under 300 lines).
  **11 (INFO)** the leftover temp dir came from a late worker recreating its state
  folder (fixed with 4); test cleanup now also stops late children by HOME.

Validation on this box: `python3 -B -m unittest discover -s sim -p 'test_*.py'`:
**101 passed** (87 before plus 14 regressions in `sim/test_review_fixes.py`).
`Tests/Scripts/code-job-test.sh`: **16 passed under /bin/sh and 16 under /bin/dash**
(new case 16: stderr-only output on exit 0 is empty work). `bot-msg-test.sh`:
**14/14 under both shells**. `accounts-recipes-test.sh` 6/6, `box-adopt-test.sh`
11/11, `box-readings-test.sh` 12/12, `claude-login-test.sh` 5/5,
`swarmhub-report-test.sh` 21/22: its one failure (`stat` output format in the
"folder 700" case) reproduces unchanged with the committed `swarmhub-report`, so it
predates and is unrelated to these fixes. `git diff --check` clean. Swift is not
installed here: `BotMessageSkillTests.swift` was updated for the new module list
but not compiled. Skill versions were not bumped; bump both skills before a
reinstall so the app's version record triggers the update.

Approval decisions are a **trusted local administrative interface**: profiles
share one Unix account, and a deciding profile verified against the invoking
gateway's `HERMES_HOME` is still not independent authentication against malicious
unrestricted shell access. Managed gates,
declared risks, subscriptions and reporting apply to these entrypoints; they do
not intercept arbitrary terminal commands, every connected-app tool or all app
goal-completion paths. Remote stream cancellation relies on the gateway's
disconnect/stop behavior and cannot undo completed external effects. Live Hermes
plugin activation, genuine cloud provisioning, human notification delivery and
native macOS behavior still need integration validation before claiming all ten
patterns match universally in a deployed product.

## Codex cross-review (2026-10-19)

Cross-review of `07fd5d4`: [REVIEW-FIX-CODEX.md](REVIEW-FIX-CODEX.md). Closed the
remaining first-message/legacy-policy spill paths and the direct `code-job`
FAKE admission bypass, including direct peer sends bound to FAKE task IDs. Corrected Swift priority-call expectations and scoped
app-side run tracking by connection and session. Both affected skills and the
peer plugin are now **1.3.1**. The report test's permission check uses Python's
portable mode bits. See the cross-review for current test counts and sandbox
limits; Swift remains unavailable here. No Hermes changes or commit were made.
