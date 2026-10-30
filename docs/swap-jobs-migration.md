# Swap jobs and offline migration

Status: implementation for review, no activation. Base main includes PR #28 (`4e9d4de`) and #34 (`c92b773`).
PR1/PR3 are live and PR2 is merged according to the task brief; this work makes no new deployment claim.
The design references are the swapdesign1/2 documents, swapdesign3 §3 and its sender-account addendum,
and the existing [per-bot account implementation](bot-isolation.md).

## What this change adds

The first implementation commit imports **exactly** `ops/jobroute/` from open PR #8 at
`f816454dd12d25571d23ad441f2319044adf5daa`, which already includes PR #6 at `31e22ad`.
The following commit extends it. No second job index, launcher, approval engine or Mac lock is introduced.
This PR targets main so reviewers can inspect and test the complete dependency; coordinate landing with #6/#8
rather than independently installing both versions. Their prior review and permission findings remain applicable.

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

`launch` takes `engine`, `label`, `brief`, optional `workdir` and `review`. The reviewer must be the opposite engine;
this maps to sb-codejob's existing `--review`. Launch appends a completion instruction to write the report at
`${SB_CODEJOB%.json}-report.md`, derived from the job's own status path; the full augmented brief must fit the cap. Fixed engines and PR #8's executable/PATH trust checks remain.
`submit`/`submit_job` remain compatible, subject to the global disabled-by-default submission gate.

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

This deliberately uses the shell execution equivalent of `sb-mac-task --shell` rather than that program's
LaunchAgent path: the inspected sb-mac-task bypasses sb-macjob, which would bypass the queue. A future sb change can
put the same runner around its LaunchAgent command. The worker is **not** installed by the ovh route installer.
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

1. Land reviewed code in coordination with #6/#8; pin the reviewed SHA. Obtain an independent review and fixture
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
   was performed here. Use the #8 pinned installer/uninstaller recipe; this PR's generator pins the new modules too.
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
5. If removing the inert ovh install, use the pinned `uninstall.py --release SHA` from #8; do not remove audit unless
   explicitly approved. It also recognizes the new per-profile command ledgers. Other releases/user files/config
   changes survive. Do not remove the shared Mac queue or runner. Disable Mac host access; retain job evidence.
6. Offline staging can then be removed using the guarded `swap-migrate --undo --apply`. If changed, archive it and
   review; do not force deletion. Keep private backups through the agreed retention window.

No server, nginx, service, sudo policy, OAuth, production install, deployment, release or Mac access was performed
for this change. Linux fixture checks do not certify real uid separation, OAuth, Cloudflare/nginx behavior,
running service identity, Mac queue installation, owner reporting delivery or a successful migration pilot.
