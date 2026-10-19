# Gap closures: P01, P02, P04, P06 and P07

Final review: **2026-10-19**, base **`5b3c4f7`**, branch `swarmhub/peer-delivery`.
All changes remain **uncommitted**. No Hermes source, installation, configuration or running gateway was changed.
No real outbound, real provisioning, deployment or credential disclosure was performed. Tests use isolated temporary
homes, synthetic credentials and local commands; app Draft Send and live-harness outbound remain **FAKE**.

## Final status by brief item

| Item | Final implementation status | Verification and limits |
| --- | --- | --- |
| **1 — P01/P04 completion evidence and app goals** | Implemented. Successful coding jobs need nonempty CLI stdout, a fresh changed report, and a new commit or passing verification command. App goals refuse bare `done` and require a commit/test-pass marker plus a report path. Wakes distinguish verified facts from unchecked claims. | Shell and simulation regressions pass. App evidence is explicitly labelled as claimed by the bot; the app cannot independently inspect a remote filesystem. Swift tests added/reviewed, not executed here. |
| **2 — P02 managed webhook/key registration** | Implemented: `webhook register`, `show`, `rotate`, `list`, `fire`, `serve`. Keys stay in owner-only files; commands return URL and file path, never the key. | Registration, idempotency, rotation, authentication, durable delivery and malformed HTTP requests pass offline. Real loopback HTTP test is skipped because this sandbox forbids sockets. |
| **3 — P06 provisioner interface and secure intake** | Implemented: configured provisioner argv, immutable request binding and owner approval. CLI intake and app secure-entry sheet write a 0600 file and disclose only its path. | Synthetic provisioner execution waits for owner approval; file modes, replacement and path validation pass. Native sheet tests need macOS. The sheet's path is local to the Mac; remote provisioning requires intake on that host. Secret transfer and a cloud provisioner are outside this hook interface. |
| **4 — P07 approval cards and Draft Send** | Implemented: approval fences create real app cards, routed to the deciding profile on the same box. A click sends the exact managed decision command through that profile. Draft Send binds the exact draft and stable intent to a FAKE managed outbound submission. | Swift regressions cover routing, deduplication, missing deciders, decision turns and exact drafts. Python tests cover managed admission/gates. Acceptance requires the deciding bot to execute the command; the app displays “Decision sent”, not confirmed runtime completion. |
| **5 — authenticated CLI in the live harness** | Implemented: detect installed authenticated Codex, preserve its auth home, run P01/P04 jobs with verification, cancel an actual P07 CLI process and launch a real corrected replacement. No CLI is installed or replaced. | Detection, bridge instructions/environment and coding specs pass offline. Full live replay was not run: sockets are prohibited here. No new real provider call was made in this continuation. |

## Completion and goal details

`code-job` records HEAD before and after execution. An unchanged HEAD, reset to an ancestor or switch to unrelated
history cannot count as a new commit. `--verify` takes precedence over `CODE_JOB_VERIFY`, then `VERIFY=` in the box's
`coding.conf`. Verification runs in `--dir`, has a bounded timeout, and records its command and exit status; output
is discarded. A failing configured verification cannot be outweighed by a commit.

- Missing/empty/unchanged report or empty CLI stdout: **exit 65**.
- Fresh report without accepted evidence: **exit 66**, status `unverified`; later managed jobs remain held.
- Successful evidence: `commit`, `tests` or `commit+tests`, with separate CLI and verification exits.
- The report is checked again after verification; deleting it cannot certify completion.
- Cancellation/interruption terminate verification children as well as CLI children. `cli-pid` distinguishes an
  actual coding CLI from a waiting launcher in the live harness.
- The appended task contract respects explicit no-commit instructions; passing verification is an alternative.

Wakes contain “Verified by code-job” and “Unverified” lines. Report contents and verification output are never
copied into wakes. File freshness and command success do not establish work correctness. A managed verification
command must match its admitted task.

App `GoalEvidence` accepts a commit-shaped ID or test-pass marker plus a non-placeholder report path. Missing
markers produce a “Done claimed without evidence” card and at most two evidence follow-ups, then block the goal.
Follow-ups respect pause, offline state, time and round budgets. Resume resets the evidence retry counter. Accepted
cards explicitly say “Claimed by the bot, not verified by SwarmHub”.

## Webhook, provisioning and secret details

Webhook URLs use `/swarmhub/webhook/<profile>/<routine>/<slug>`. Key files use unique slugs under
`~/.hermes/swarmhub/webhooks/`, preventing collisions between dotted profile/routine names. The directory is 0700,
files are 0600, and rotation replaces files atomically. Re-registration is idempotent. Keys are absent from SQLite
and command output. Authenticated calls enqueue a durable self-delivery to the registered profile.

The loopback HTTP receiver accepts `X-SwarmHub-Key` and JSON containing `text`. It rejects invalid, negative or
oversized lengths and non-object JSON without echoing input or logging keys. TLS/reverse-proxy exposure is deployment
work and was not performed. This is a managed keyed wake routine, not a Hermes routine/configuration change.

The provisioner policy is an argv array beginning with an absolute executable. A flat `request` becomes
`<provisioner...> --request <canonical JSON>` in the approved record. Secret-like fields must reference existing
owner-owned 0600 regular intake files; symlinks, missing files and inline values are refused. Explicit argv cannot
conflict with the composed hook/request. Provisioning always requires the owner.

Both secret writers create a new private file and atomically replace the destination; replacing a symlink never
writes into its target. CLI intake reads stdin and checks empty/oversized values. The app uses a `SecureField`,
reports failures in the sheet and clears the field after submission/dismissal. Chat receives only the path and an
explicit notice that a Mac-local file is not readable by a remote provisioner.

## Approval and outbound details

Approval fences carry task, kind, gate, deciding profile, summary, risks and draft. The card routes to that profile
on the submitting bot's connection; an identically named profile on another box is ineligible. Missing deciders
leave the card visible and never send a decision using the submitter's identity. Ordinary turn cleanup no longer
discards managed cards. Pending/decided cards are deduplicated; group replies also surface managed approval cards.

A click sends `scripts/swarmctl decide <task> <actor> approve|deny` through the correct gateway. The runtime enforces
actor identity and the immutable record. The app audits the user's choice and says it awaits the runtime result.
This remains a bot-executed command, not direct RPC confirmation.

Draft Send builds JSON from the exact recipient, subject and body, with stable intent
`draft-<message UUID>-<card index>`. The card remembers the intent and refuses repeat Send. Every app submission has
`fake: true`; the unfinished implementation's hidden `managedOutboundLive` preference was removed. Automatic FAKE
records report their actual status instead of fabricating a coordinator approval. Unsupported backends are refused
instead of reverting to “Send it”. The existing managed real-outbound gate remains, but no real outbound operation
was executed.

## Live-harness fixes found during review

- Restored the missing `RULES` import, which otherwise broke bridge turns at runtime.
- Added the bridge URL to the fallback job environment, so unknown-origin wakes reach the isolated bridge.
- Put reports inside the throwaway CLI workspace; verification matches the exact expected line.
- Wait for scheduler terminal status before grading a delivered completion.
- Stop the unrelated owner-gated replacement fixture before P07, so it cannot hold the coding queue.
- Check the actual CLI PID and wait for cancellation cleanup before grading the kill.
- Run P07's corrected replacement through the real CLI instead of the unfinished FAKE replacement.
- Preserve the supplied PATH/auth environment during CLI detection, including interpreters needed by wrappers.

The runner can make up to four coding CLI invocations in addition to its Hermes turn budget. Without authentication
it retains the explicit exit-69 / `cli-exit: not-run` boundary. CLI flags were checked against local `codex exec
--help`; full execution is not certified here. The interrupted report mentioned an earlier direct Codex smoke run;
this final verification does not rely on that unretained transcript.

## Tests and packaging

Final Linux results ([retained test output](sim/results/gaps-final/QA-tests.txt)):

- `python3 -B -m unittest discover -s sim -p 'test_*.py' -v`: **124 tests, 123 passed, 1 skipped**, no failures.
  Only the real webhook loopback receiver skips; HTTP handler validation runs separately without sockets.
- `Tests/Scripts`, under **both `/bin/sh` and `/bin/dash`**:

  | Suite | Per shell |
  | --- | --- |
  | accounts-recipes | 6 passed |
  | box-adopt | 11 passed |
  | box-readings | 12 passed |
  | claude-login | 5 passed |
  | code-job | 22 passed |
  | swarmhub-report | 22 passed |
  | bot-msg | Explicit exit-77 skip: loopback sockets denied |

  **156 shell cases passed**, no failures. Socket-free peer-delivery regressions run in `sim/`.
- Python syntax validation and `git diff --check` passed. Shell evidence includes missing/failing verification,
  commit evidence, passing tests, post-verification report deletion and interruption cleanup.
- Final standalone shell reruns exposed and fixed a temporary-directory cleanup race: coding scripts are now copied
  unchanged into an isolated test layout, while managed wake/worker integration remains covered by `sim/`.
- Swift tests cover evidence/budgets, approval lifecycle/routing, FAKE drafts, private-file replacement and path-only
  delivery. The bundled script-list assertion now includes both new Python modules.
- Coding/messaging skill versions, generated peer-plugin metadata and matching tests are **1.3.2**. Nothing was
  installed. Generated Python bytecode was removed from resource folders; subprocess test environments suppress it
  so it cannot make a bundled skill un-installable.

**Still requires the native environment:** `swift build` and `swift test` on macOS (Swift is absent here), visual
verification of cards/the secret sheet, actual loopback HTTP, and a full QA live replay. These are unexecuted
validation steps, not claims of passing behavior. No deploy or Hermes modification was performed.

## macOS fixes 2

The exit-66 failures came from the fixtures configuring `/bin/true` as their verifier. macOS places that
executable in `/usr/bin`; verification already runs through a POSIX shell, so the fixtures now use its `true`
builtin. This also explains P01: the first job became unverified, and the scheduler correctly held the second
job behind it. The replay now checks the first job's status and includes its evidence/verification fields before
waiting for the second job. The eight-second `eventually` timeout is unchanged.

Shell and Python commit fixtures explicitly export synthetic `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL`,
`GIT_COMMITTER_NAME` and `GIT_COMMITTER_EMAIL`, with global/system Git configuration disabled and temporary HOMEs.
A failed fixture commit now fails the stub; failed shell repository initialization fails the case rather than
silently reporting a pass. `ManagedActions.swift` comments use `host-local` in place of the reserved fixture name.

The production evidence gate is unchanged: report content fingerprints use Python SHA-256, commit evidence uses
Git ancestry, and configured verification must actually exit zero. No GNU `stat`/`date` evidence workaround or
relaxed completion rule was needed. The shell regression now also checks an unavailable verifier: exit 127 must
produce job exit 66, `tests-passed=false` and `evidence=none`.

Validation on Linux, using synthetic CLI/curl fixtures only:

- `env -i PATH=/usr/bin:/bin PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -B -m unittest discover -s sim -p 'test_*.py' -v`:
  **124 tests, 123 passed, one loopback-socket skip**, no failures.
- All seven `Tests/Scripts/*-test.sh` suites under `/bin/sh`, `/bin/dash` and a wrapper executing
  `/bin/bash --posix`, with an empty temporary HOME: **234 cases passed** (78 per shell). Each `bot-msg` suite
  explicitly skipped with exit 77 because this sandbox denies loopback sockets.
- P01–P10 through `sim/live_observed.py --offline`, in a temporary copy routing shell launches and shebangs
  through `bash --posix`: **all ten matched, zero model calls**. Injecting a nonexistent verifier into that copy
  reproduced P01's blocked queue with `status=unverified`, `evidence=none`, `verify-exit=127`.
- The Swift fixture-name assertion was mirrored across **434 source files**, with no forbidden names found.
  Python 3.9 grammar parsing passed for **30 Python files**; `git diff --check` passed.

Native macOS/Swift tests remain unexecuted here: Swift, Python 3.9 and Bash 3.2 are unavailable. The available
interpreters are Python 3.12.3 and Bash 5.2.21; POSIX mode and 3.9 grammar checks do not certify those older runtimes.
No Hermes installation was read or modified, no real credentials/providers/outbound actions were used, and no
repository commit was made (Git commits occurred only inside disposable evidence fixtures).
