# Swap jobs and offline migration

Status on 2026-11-11: current main at `349db4c` contains the merged jobroute
stack #35–#56 plus #58 (fixround3, `510c5b3`) and iOS fix #59 (`349db4c`).
Fixround3 behavior is merged and reviewed. Remote deployment state remains
**unverified**; the jobroute Mac worker stays **disabled**.

| Scope | Evidence and limit |
|---|---|
| Source | Merged #35–#56 plus #58 include the route, migration tooling and worker; #59 fixes iOS Debug simulator architecture selection. Merging does not establish installation. |
| Installed ovh route | Readiness records `148f905` observed on 2026-11-08. This is a dated observation, not a current remote check. |
| Submission gates | Shipped global and per-profile opt-ins default to disabled. The 2026-11-08 report also described live submissions as disabled; current live config is unverified. |
| hb pilot | No pilot activation is established by this review. The steps below remain a separately approved maintenance procedure. |
| Mac worker | **Disabled** pending a separate isolated Mac pilot. Not installed by the ovh installer; the installed sb-macjob contract still needs validation. |

The design references are the swapdesign1/2 documents, swapdesign3 §3 and its sender-account addendum,
and the existing [per-bot account implementation](bot-isolation.md).

## What this change adds

The first implementation commit imports **exactly** `ops/jobroute/` from PR #8 at
`f816454dd12d25571d23ad441f2319044adf5daa`, which already includes PR #6 at `31e22ad`.
The following commit extends it. No second job index, launcher, approval engine or Mac lock is introduced.
The imported stack is now on main; do not independently install the superseded #6/#8 versions. Their prior review and permission findings remain applicable.

- `Resources/Skills/swarmhub-coding/scripts/job-route`: key-bound CLI for a registered hb account.
- Jobroute CLI and MCP: `launch`, owned `status ... report=1`, `park`, `approve-wait`, `msg`, `msg-send`,
  `macjob`, `queue`, `report-jarvis`. New command bodies are JSON on stdin; the remote command contains only the verb.
- `ops/swap-migrate`: offline export validation and private, reproducible staging, plus guarded reverse.
- `hb-move`: dry-run by default for move, undo and nginx rendering; **`--apply` is now required** for writes.
  An identical completed move or completed undo is a no-op. A partial move still requires undo before retry.

Every mutating submission is disabled in the shipped allowlist (`route.submissions_enabled=false`), all new verbs
need profile `enabled_verbs`, submissions also need profile `submissions_enabled=true`, and Mac hosts need profile `mac_hosts`. Existing read-only status/help remain available.
Request reservations, audits and rate limits precede command side effects. Profile identity still comes from the
forced authorized_keys command on ovh; neither CLI nor MCP accepts a sender profile from the bot.
`check-jobroute-iso` is a read-only provisioning check of registry, uid, home/key modes, unit User and drop-ins.
It must be run by the operator on the bot box before enabling that key. It is not remote attestation, and does not
prove the running process's uid or prevent an administrator from later changing the box.

## Command contracts

`launch` takes `engine`, `label`, `brief`, optional `workdir`, `review` and `request_id`. The reviewer must be the opposite engine;
this maps to sb-codejob's existing `--review`. Launch appends a completion instruction to write the report at
`${SB_CODEJOB%.json}-report.md`, derived from the job's own status path; the full augmented brief must fit the cap. Fixed engines and PR #8's executable/PATH trust checks remain.
`submit`/`submit_job` remain compatible, subject to the global disabled-by-default submission gate.

For retries after a lost response, supply the same optional `request_id` on every attempt.
CLI `submit` takes `request_id=ID`; MCP `submit_job` and CLI/MCP `launch` take a JSON
`request_id` string. IDs are profile-scoped, case-sensitive, 1–64 `[A-Za-z0-9_-]`
characters starting alphanumeric. The reservation binds the ID to the operation,
agent, engine, label, resolved workdir, exact effective brief and review choice.
Transport changes and equivalent workdir spellings match; changed payloads are refused.
The same ID and payload return the stored acceptance response/job ID without another
launch or quota charge, even after the job ends. Status remains the source of execution state.
Concurrent attempts while launch is in progress are refused (CLI exit 3); retry the same
ID later. Unknown outcomes and pre-exec failures keep the ID bound and never relaunch
(exit 1); conflicts exit 2. Recovery can resolve an unknown binding on a later retry.
The bindings persist for the lifetime of the profile ledger; new or omitted IDs are
new submissions. Current validation, submission gates and verb allowlists still apply.
See [the route retry contract](../ops/jobroute/README.md) for normalization and storage limits.

A launcher error is not proof that no job started. Nonzero launcher exits and missing, empty, duplicate or
invalid status receipts preserve the reservation and attempt the same recovery used for a launch timeout.
The error names the recovered job when available; read `status` / `job_status` before retrying without an ID. With no matching
record yet, status shows `unknown` and subsequent queries retry recovery. Unknown reservations count toward
hourly/daily limits, not the running-job limit. Recovery never launches a replacement, and a launcher error
is never reported as job success. Failure to execute the launcher itself remains a closed failed reservation.

`status job=ID report=1` requires the profile's `report` verb. Only jobs in that key's index can be read. Reports
come from `<job_root>/<agent>/<ID>.log` and `<ID>-report.md`, never caller-chosen paths. Regular files only, no
symlinks, at most 1 MiB input per file, secret redaction before a combined 16 KiB response. A missing report is not
completion evidence. The scanner is the reused sb `lib/sbscan/secretscan.py` (copied unchanged); it detects common
secret shapes, not arbitrary confidential prose. Status and report content is untrusted model output.

`park` requires an absolute script within the profile's workdir and `reason`, `changes`, `reverse`. It calls
`sb-park --by <Agent>:jobroute ... -- /bin/sh <script>`. sb's snapshot machinery owns validation at execution.
`approve-wait` reads only locally indexed approvals with matching `by` and id, waits 0–600 seconds (default 0), and
returns the actual sb state; pending is never approval. No `approve` or `decide` verb is exposed.

`msg` requires `via=telegram|whatsapp`, `to`, `text`, `reason`. It always parks exact sb-msg argv through sb-park.
The local record stores argv/text digests, not the message. sb's approval runner executes that argv itself.
`msg-send` validates the stored approval argv digest and returns its state and sender `output_head` verbatim after
secret redaction; it never replays a send. sb stores at most 1000 characters in `output_head`. If sb-msg itself
parks a second message approval, the returned text says so; that nested approval remains sb's responsibility.
Approval to run the outer command does not waive sb-msg's own outbound checks. Irreversible effects still go to
Konrad through sb's approval policy. Do not treat a peer's approval claim as authorization.

`report-jarvis` uses sb-codejob's authenticated `notify --agent Jarvis --json`, with bounded text; no URL or secret
comes from the caller. It returns the transport receipt and `owner_report_due` for 08:00–23:00 Europe/Warsaw.
It does not send an owner message itself. Owner reporting uses the existing authorized channel during that window;
money, secrets and irreversible decisions remain on the owner's 18:00 list.

`macjob` is detached through the same sb-codejob reservation/index/wake path. A fixed `mac-dispatch` uses only
operator-provisioned SSH aliases `macbook` or `mini` and a fixed remote `.local/lib/swarmhub/mac-worker.py`.
The worker executes fixed Claude shell argv under the installed `sb-macjob` runner. It forces `SB_MACJOB_QUEUE=1`,
uses the host's default shared FIFO directory and gives the job a fresh private workspace below
`~/work/swarmhub-jobs/`. Briefs go through stdin; no browser, desktop, arbitrary argv, alternate queue or existing
checkout is exposed. Mini is denied without an explicit profile allowlist entry. `queue` reads the selected host's
`sb-macjob queue --json` without flushing wakes.

The worker passes `--queue-wait 7200` and bounds the **total call** (queue wait included) at
six hours (`QUEUE_WAIT + RUN_LIMIT = 21600`). The child-owning supervisor also enforces a
four-hour runtime cap, starting at workload launch, bounded by the same absolute call deadline.
Its TERM/INT/HUP handlers, parent watchdog and independent cancellation latch lead to cleanup
using the in-memory, unreaped child identity. Disk PGIDs never authorize signals. Normal leader
exit gets 2 s TERM grace; cancellation gets 120 s. KILL/drain and reap have 5 s budgets each.
The outer worker allows 135 s for supervisor settlement, then at most 130 s for runner cleanup:
up to 265 s after its call deadline. Queue snapshots have no workload and take at most 60+130 s;
the route budget remains 225 s. These are application budgets, not guarantees against OS or
local filesystem stalls. All locks, inspection, input and output relay use finite budgets.

Confirmed cleanup means drain of cooperating processes in the original group plus direct-child
reap. Workloads must not daemonize, call setsid/setpgid, or escape that group. The runner must
remain the supervisor's direct parent and hold the shared queue lock while waiting for it.
An independent latch requests workload drain **before** the outer worker signals even a runner
whose TERM handler kills its supervisor. The supervisor stays alive in containment if drain or
reap is unresolved; the outer worker returns 125 without killing that guardian. Private output
files prevent a retained guardian from keeping the SSH stream open. Missing or invalid control
also returns 125, retains the original control bytes, workspace, logs and separate invocation-bound
`supervisor-result.json` / `cleanup-result.json`. Never automatically retry an unknown result.
A runner crash/SIGKILL may release its queue lock before the watchdog drains work: queue state
is unknown. Crash-safe exclusion would require a durable admission hold honored by every entrant.
Simultaneous guardian SIGKILL and arbitrary same-UID interference are outside this contract.

Exit 124 means an enforced deadline **with confirmed cleanup**, subject to the original-group
scope above. Exit 125 means incomplete cleanup or invalid protocol; 126 means process cleanup
completed but artifact removal failed. Both retain remaining artifacts and have null cause/signal.
Queue refusals are respectively `Mac worker cleanup incomplete; inspect retained state before retrying`
and `Mac worker artifact cleanup failed; inspect retained state`; the route CLI still exits 1.
Catchable outer termination returns 128+signal after confirmed cleanup. Status precedence is
125, 126, outer signal, deadline 124, ordinary runner status. Persistent ps failure is an
operator-visible cleanup failure (`process_inspection_failed`), not evidence of an empty group.

A failed macjob says why when its exit code proves it. ssh exits 255 when it cannot connect, the connection drops,
or the remote worker dies without an exit status; the worker itself never exits 255 and reports its runner's own
255, 124, 125 or 126 as 1 (stderr keeps the real code). So job `status` adds `cause: mac_connection_failed` for 255 (the job
may have started on the Mac: check `queue` before resubmitting) and `cause: timed_out` for 124; every other failure,
and every non-macjob job, has `cause: null`. `outcome` is unchanged. `queue` refuses with
`Mac host unreachable; retry later` when ssh fails, and with
`Mac worker timed out waiting for the queue; retry later` when the worker stops `sb-macjob queue` at its 60 s limit
(exit 124; on `queue` nothing else produces 124). `queue` has no job record, so neither case sets a `cause`; the
audit row says `refused` with that reason. Exit 75 gets no cause and no fixed text: sb-macjob returns 75 when a
job's queue wait expires (`Busy`), but a job may exit 75 itself, and the only sign of Busy is a `queue: busy:` line
on stderr, which reaches ovh merged with the job's own output. Telling them apart needs an sb-macjob change.

This deliberately uses the shell execution equivalent of `sb-mac-task --shell` rather than that program's
LaunchAgent path: the inspected sb-mac-task bypasses sb-macjob, which would bypass the queue. A future sb change can
put the same runner around its LaunchAgent command. The worker is **not** installed on the Mac by the ovh route installer. Copy `mac-worker.py`,
`mac_worker_state.py` and `mac_worker_lifecycle.py` from one release together; the worker verifies
the helper hashes before either role starts. Deployment remains disabled pending an isolated Mac
pilot covering kqueue, ps/flock, corrupt-control cancellation, outer/supervisor TERM, parent death,
descendant drain before queue handoff, and the installed runner’s escalation/lock contract. A runner
that independently kills a still-cleaning guardian is unsupported. Linux fixtures do not validate that contract.
Install and test it separately during an approved Mac pilot; no Mac was contacted for this PR. The queue's lifetime,
keeper and stale recovery remain the already implemented sb runner's responsibility.

## Offline export and reverse

Export **reviewed, distilled** data to an owner-only JSON file. Do not dump a live HOME, OAuth state, `.env`, SSH
keys, API headers or a full unreviewed config. The importer scans all input and refuses secret-shaped content.
Example schema (use actual reviewed prompts/provenance):

```json
{
  "version": 1,
  "profile": "grok-swarmhub",
  "account": "hb-swarmhub",
  "memory_char_limit": 2200,
  "memory": "Distilled project memory.",
  "user": "Owner preferences.",
  "journal": {"2026-10-30.md": "Reviewed historical note."},
  "skills": {"example/SKILL.md": "Reviewed skill instructions."},
  "routines": [{"name":"daily", "cron":"0 9 * * 1-5", "timezone":"Europe/Warsaw",
    "prompt":"Report only.", "delivery":"self", "source":"Reviewed bot description and sb log",
    "confidence":"confirmed"}]
}
```

MEMORY.md plus USER.md must fit the explicit character cap; oversize content is refused, never silently cut.
Staging includes `profile/memories/{MEMORY,USER}.md`, reviewed skills, `journal/`, an MCP `config.patch.json`, and
`routines/<profile>.yaml` (JSON syntax, valid YAML), marked `enabled=false`, `report_only=true`. Existing Hermes
config is preserved by hb-move; merge the proposed MCP patch after reviewing conflicts. The private key is
provisioned separately; the patch references only its path. Routine manifests are inert, not scheduler entries:
Jarvis must review and compare a report-only run to Grok's last run before any enabling.

```sh
# Offline, in a pre-existing private parent directory:
ops/swap-migrate --export /private/export.json --output /private/pilot-stage
ops/swap-migrate --export /private/export.json --output /private/pilot-stage --apply
# Same input/output rerun: unchanged, no replacements.
ops/swap-migrate --output /private/pilot-stage --undo
ops/swap-migrate --output /private/pilot-stage --undo --apply
```

Dry-run creates no files. Apply publishes a new tree with 0700 directories/0600 files and a hashed manifest.
Reapply requires exact input/content identity. Undo removes only that unchanged staging tree; changed/extra files,
links or a different export cause refusal. An absent stage is already undone. Preserve and review changed trees.
This offline undo never undoes a live hb-move, wake enrollment, key activation or manual config merge.

## Later real-box pilot: operator checklist, not performed

1. Pin the reviewed main SHA containing #35–#56 plus #58; do not install #6/#8 separately. Obtain independent pilot review and fixture
   rollback evidence. Record the actual shared gateway unit, available ports, current nginx include/routing,
   profile/skill versions and service overrides. Read [bot-isolation.md](bot-isolation.md) and
   [ops/README.md](../ops/README.md); no live assumptions here substitute for those checks.
2. Have the Swarmhub bot export reviewed memory/journal/skills/routine descriptions to its ovh work directory.
   Run the two staging commands above. Review hashes, memory cap, routine provenance and the MCP patch.
   Preserve the source and staging privately; never paste their contents or credentials into the PR.
3. Prepare a pinned **pilot script** plus explicit reverse script containing the later account move, selected
   config merge, key provisioning, fixed authorized_keys binding, route permissions/allowlist activation and wake
   changes below. Record private pre-images and their owners/modes. Park it via sb-park; wait for Jarvis's actual
   decision. Do not run the pilot or permission fix before that approval. Prior #6/#8 park denials and the group-
   writable executable/PATH findings need separate resolution, not chmod bundled into this PR.
4. In that approved maintenance window, first plan:
   `ops/hb-move grok-swarmhub --gateway-port 8651 --receiver-port 8751 --control-port 8761 --shared-unit ACTUAL_UNIT`.
   Pick unused ports on the box, not these placeholders by assumption. Then run the identical command with
   `--apply`. It briefly stops the shared gateway, copies and retires the profile with a journal, and installs
   the existing per-bot gateway/receiver/routing. If a step fails, follow the reverse below before retry.
5. As the operator, reconcile the staged files into the dedicated profile with owner-only, numbered pre-images;
   preserve existing config entries and newer memory. Copy the journal into the dedicated home. Stage routines
   disabled. Do not copy OAuth implicitly: verify the moved bot answers; use a separately approved narrow
   credential transfer/fresh login if needed. Start its control server on the recorded control port per #28.
6. Provision a unique jobroute key inside `~hb-swarmhub/.ssh` (0700), key 0600, home 0700; keep other hb accounts
   unable to read it. Pin ovh's host key privately. Provision the `jobroute-ovh` alias and its restricted
   authorized_keys line with the pinned route/config and `--profile grok-swarmhub`. Do not enable shared hermes
   keys. Run `ops/jobroute/check-jobroute-iso grok-swarmhub` on the bot box; independently verify the running
   service uid, real cross-account unreadability and real forced-command restrictions. On ovh resolve #8's
   executable/PATH trust findings through the separately approved permission plan, preserving old modes for undo.
7. Configure a dedicated route row `agent="Swarmhub"`, `bot="Swarmhub"`, its permitted workdirs, explicit verbs,
   limits, `submissions_enabled=true`, and backend paths. Set `route.approvals` to the actual sb approval directory; backend `park` to sb-park,
   `msg` to sb-msg, `codejob` to sb-codejob, `mac_dispatch` to the pinned adapter. Leave `mac_hosts=[]` initially.
   Set `submissions_enabled=true` only after isolation/trust gates are green. These config edits and the
   authorized_keys line must be in the approved script, with exact pre-images. No key or permission activation
   was performed here. Use the [pinned installer and rollback recipe](../ops/jobroute/README.md#installation-identity-checks-and-rollback); the generator pins the new modules and both Mac helpers too.
8. Run `webhook-probe` V1–V6 from ops/README against the dedicated receiver, including the shared-account control.
   Start S1 with separate shadow credentials and report-only wakes for 1–2 days; Grok remains primary. Only after
   green receipts enroll the primary wake (`wake-enroll`, private 0600 pre-image) and pause Grok for S2. Never reuse
   the primary key for a shadow URL. Require at least 10 launch → wake 202 → owned status/report → next-task loops,
   no fallback, exact approval checks and no duplicate outbound send; total pilot 3–5 days and Konrad's exit OK.
9. Mac activation is a **separate later authorization** after Rapper releases the MacBook. Install the pinned worker
   on each allowed host, verify the existing queued sb-macjob version, run queue/FIFO/drain/stuck checks there,
   then enable the one host in `mac_hosts`. Never use `~/code/swarmhub-team-coordination` for this pilot. Mac runtime
   and Bash 3.2 verification remain unperformed here. Batches follow the same stages; Jarvis goes last and needs
   a separately designed decide path.

## Reverse plan for that pilot

1. Disable route submissions/new verbs and remove only the recorded pilot authorized_keys line; preserve audit and
   job records. Disabling a route does not cancel already detached jobs: account for their exact ids and await or
   explicitly cancel through their owning mechanism before switching wakes. Never broadcast-kill processes.
   Before editing `authorized_keys`, use `cp -p` to save a numbered private backup, copy it to an owner-only
   candidate, and remove only the exact recorded pilot line there. Review `diff -u` against the original;
   stop if any other line changes. Only after review, use `install -m 600` to replace `authorized_keys`
   from that candidate. Keep the backup and reviewed diff with the private rollback evidence.
2. Restore the selected private `wake.env.<stamp>` pre-image (0600), unpause Grok, and disable any enabled migrated
   routines. Stop the dedicated control server through the recorded service mechanism. Preserve the dedicated
   journal and post-move memory for reconciliation.
3. Plan `ops/hb-move --undo grok-swarmhub`, then run `ops/hb-move --undo grok-swarmhub --apply`. It stops the
   dedicated gateway/receiver, restores the latest dedicated profile to the shared account, retains numbered
   backups, removes the registry route and re-renders nginx. Retry undo after a failed step; its journal is resumable.
4. Remove the pilot-only MCP entry/references and restore the reviewed config/memory pre-images only where needed,
   retaining newer work in numbered private backups. Re-register the shared 8745 routine and verify the shared
   gateway, delivery and Grok loop. hb-move intentionally leaves the account and backups; remove the account only
   in a separately reviewed cleanup after verification. Restore prior permissions using the recorded mode plan.
5. If removing the inert ovh install, use the [pinned uninstaller recipe](../ops/jobroute/README.md#installation-identity-checks-and-rollback) (`uninstall.py --release SHA`); do not remove audit unless
   explicitly approved. Preserve private ledger copies first: last-release removal also deletes working job/command ledgers. Other releases/user files/config
   changes survive. Do not remove the shared Mac queue or runner. Disable Mac host access; retain job evidence.
6. Offline staging can then be removed using the guarded `swap-migrate --undo --apply`. If changed, archive it and
   review; do not force deletion. Keep private backups through the agreed retention window.

No server, nginx, service, sudo policy, OAuth, production install, deployment, release or Mac access was performed
for this change. Linux fixture checks do not certify real uid separation, OAuth, Cloudflare/nginx behavior,
running service identity, Mac queue installation, owner reporting delivery or a successful migration pilot.

CLI contracts were checked from installed OVH sources on 2026-10-30, without running
submissions. `sb-msg send` accepts `--by`; `sb-park` accepts the requester/reason/change/reverse
flags and literal argv after `--`; `sb-codejob notify` accepts every `report-jarvis` flag
and reads the report from stdin. `sb-macjob queue --json` delegates to `job_process.py`
with the fixed queue directory. Parser-only snapshots with source hashes and regression
tests live in `ops/jobroute/tests/sb_cli_contracts.py` and `test_swap_regressions.py`.
These checks verify the installed interface; transport delivery and Mac execution remain
part of the later approved pilot. Owned status reports read bounded artifact tails,
redact them, then return at most 16 KiB; missing logs/reports are handled independently.
