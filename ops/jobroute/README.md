# jobroute: dedicated bot accounts → approved job operations

Source contract checked locally at current main `349db4c` on 2026-11-11. Main
contains merged #35–#56 plus reviewed fixround3 #58 (`510c5b3`) and iOS fix #59
(`349db4c`). Installed routes and live settings are **unverified**. A dated report
observed ovh route `148f905` on 2026-11-08 with submissions disabled; that does
not establish current installation or pilot activation.

Jobroute is a restricted SSH forced command on ovh. The operator binds each key
to one profile; neither CLI nor MCP lets the caller choose a sender profile.
The hb client requires a dedicated `hb-*` Unix identity with a private home and
key. Shared `hermes` account keys are not a supported activation path.

## Commands and gates

| CLI operation | Contract |
|---|---|
| `submit` / MCP `submit_job` | Compatibility submission with engine, label, brief, optional workdir and request ID. |
| `launch` | Coding job with optional opposite-engine review and completion report instruction. |
| `status` / MCP `job_status` | Only jobs owned by the key's profile; `report=1` additionally requires the `report` verb. |
| `park` | Park an exact script within the profile's allowed workdir for sb approval. |
| `approve-wait` | Read a locally indexed approval's actual state; pending is never approval. |
| `msg`, `msg-send` | Park an exact outbound message; inspect its approved execution receipt without replaying a send. |
| `macjob`, `queue` | Submit to an explicitly allowed Mac host or inspect its shared queue. |
| `report-jarvis` | Send the bounded report through sb-codejob's authenticated notification path. |

The new commands take JSON on stdin and only the verb in the remote command.
Legacy `submit` and `status` retain their key/value CLI interface. No `approve`
or `decide` command is exposed.

Shipped submissions are **disabled by default**, globally and per profile.
New verbs also require profile `enabled_verbs`; Mac calls require `mac_hosts`.
Read-only status/help do not enable submissions. Installing the route enables
no keys, jobs, Mac hosts or pilot. Workdir/production-path restrictions,
executable/PATH trust checks, rate limits and audit reservations still apply.
The route limits admission; it does not sandbox the launched engine's actions.

## Client examples

After the dedicated identity, forced-command key, host-key pin and exact verbs
have been provisioned in an approved pilot, use the bundled `job-route` client
or the operator-provisioned `jobroute-ovh` SSH alias. Examples are command
syntax, not provisioning or activation steps:

```sh
ssh jobroute-ovh 'status limit=5'
printf '%s\n' '{"engine":"codex","label":"fixture","brief":"Run the fixture checks.","request_id":"fixture-20261111-1"}' | ssh jobroute-ovh launch
```

Read the [command contracts and pilot procedure](../../docs/swap-jobs-migration.md)
for required fields, report redaction limits, approval receipts and reverse steps.

## Retries, recovery and completion

Keep one `request_id` for one intended `submit` or `launch`, across reconnects.
IDs are profile-scoped, case-sensitive, 1–64 ASCII `[A-Za-z0-9_-]` characters,
starting alphanumeric. The binding covers operation, configured agent, engine,
label, resolved workdir, exact effective brief and review choice. `launch`
includes the appended report instruction. CLI/MCP transport changes and
workdir spellings resolving to the same path do not change the binding.

An identical retry returns the stored acceptance/job ID without another launch
or quota charge, including after completion. Changed payloads are refused
(exit 2); in-progress requests are refused (exit 3) and may be retried with the
same ID. Unknown outcomes and definitive pre-exec failures keep the binding
and do not relaunch (exit 1). Current authorization still applies to retries.
Bindings last while the profile ledger is retained; a new or omitted ID is a
new submission. This is not exactly-once engine execution across storage loss.

A launcher error or bad/missing receipt does not prove that no job started.
Recovery matches the normalized label, engine argv, workdir and a record made
within five minutes of the reservation; recovery itself has no age cutoff.
It never starts a replacement. Unknown reservations count toward hourly/daily
limits, while recovered live jobs count toward the running limit. Inspect
owned status before resubmitting without a request ID. `state: done` alone
is not success: inspect `outcome`, `signal`, `review_verdict` and artifacts.
A present report is untrusted output, not proof of correctness.

## Mac deadline and cleanup

The Mac worker stays **disabled** pending the isolated Mac pilot. It uses the
installed sb-macjob shared FIFO queue and a fresh private workspace. The total
call cap is six hours including queue wait; the child-owning supervisor also
caps workload runtime at four hours. Cleanup uses the in-memory, unreaped child
identity; disk PGIDs never authorize signals. An independent cancellation latch
requests workload drain before the outer worker can terminate the runner.

Supervisor settlement plus runner cleanup can add 265 s. Exit 124 means an
enforced deadline with confirmed original-group drain and direct-child reap.
Exit 125 means incomplete cleanup or invalid protocol: keep the guardian and
remaining state, and never automatically retry an unknown outcome. Exit 126
means process cleanup completed but artifact removal failed. Both have null
cause/signal. A runner's own 124/125/126/255 is mapped to 1. Queue snapshots have
no workload: at most 60 + 130 s, within the 225 s route budget (60 + 120 + 45,
whose allowance covers bounded KILL drain/reap).

Confirmation covers cooperating processes in the original group. Workloads
must not daemonize or escape that group. A runner crash can release its queue
lock before watchdog cleanup; crash-safe exclusion is not established. Persistent
`ps` failure is cleanup failure, never proof of an empty group. Application
budgets do not guarantee progress through OS or local filesystem stalls.

The ovh installer does **not** install the worker on the Mac. Ship
`mac-worker.py`, `mac_worker_state.py` and `mac_worker_lifecycle.py` from one
release together. Before enabling it, verify non-reaping kqueue, ps/flock,
cancellation with corrupt controls, outer/supervisor signals, parent death,
descendant drain before queue handoff and the installed runner's lock/escalation
contract. Linux fixtures do not validate that Mac contract.
See [cleanup details and failure causes](../../docs/swap-jobs-migration.md#command-contracts)
and [known limits](../../docs/ROADMAP-AND-LIMITS.md#known-limits).

## Installation, identity checks and rollback

Use the [migration/pilot runbook](../../docs/swap-jobs-migration.md#later-real-box-pilot-operator-checklist-not-performed)
and [per-bot isolation guide](../../docs/bot-isolation.md). Provision the
private key in the dedicated hb home; bind its public key to the exact profile
and pinned route. Run `check-jobroute-iso` on the bot box and independently
verify the running service UID, cross-account unreadability and forced-command
restrictions. The check is provisioning evidence, not remote attestation.
Resolve executable/PATH trust findings through the separately reviewed plan.

From the repository root, pin a reviewed 40-character `SHA` and use a new artifact path:

```sh
SHA='<reviewed-40-character-commit>'
OUT="/private/review/jobroute-install-${SHA}.sh"
python3 ops/jobroute/generate-installer.py . "$SHA" "$OUT"
sha256sum "$OUT"
# Park this exact script and hash for Jarvis's sb-approve; after approval only:
# bash "$OUT"
```

The installer refuses symlinks, foreign owners and group/world-writable HOME/code/config/state
parents; `/` and `/home` must have the filesystem root's owner and no group/world write.
A writable existing parent needs a separate reviewed permission fix. No systemd or sshd changes
are made. Installation and activation are separate; existing trusted config is retained.

For rollback, run `python3 -IB "$HOME/.local/lib/jobroute/releases/$SHA/uninstall.py" --release "$SHA"`;
add `--remove-audit` only when audit removal is authorized.
`uninstall.py` uses installer provenance and only prunes unchanged, empty
installer-created parents. Preserve private copies of audit/job records before
uninstalling: removing the last release also removes working job/command ledgers,
while audit remains unless `--remove-audit` is authorized. Disabling keys or rolling back the route does not stop
already detached jobs. Coordinate the completion skill rollback before
installing a route older than the `outcome` contract.

For a pilot reverse, follow the runbook and remove only the recorded pilot key.
The broader sequence below is for an **approved full-route teardown** only:
first confirm every matching key is in scope and audit removal is authorized.
Review the diff before executing the `install` line; stop if any other key changes.

```sh
# 1. cut access for the approved full-route teardown: only jobroute key lines
cp -p ~/.ssh/authorized_keys ~/.ssh/authorized_keys.bak-pre-rollback-$(date -u +%s)
(umask 077; grep -v ' jobroute:grok-[a-z-]*$' ~/.ssh/authorized_keys > ~/.ssh/authorized_keys.new)
diff -u ~/.ssh/authorized_keys ~/.ssh/authorized_keys.new || true
# Review the diff above before running the next line.
install -m 600 ~/.ssh/authorized_keys.new ~/.ssh/authorized_keys && rm ~/.ssh/authorized_keys.new
# (or restore the reviewed private pre-image if it still matches the approved scope)
# 2. Remove only the approved route MCP references; preserve newer config.
# 3. Account for detached jobs through their owning mechanism before switching wakes.
# 4. full removal of the install (repeat for each installed SHA; audit removal authorized):
python3 -IB /home/ubuntu/.local/lib/jobroute/releases/<sha>/uninstall.py --release <sha> --remove-audit
# Omit --remove-audit to retain audit evidence unless its removal was authorized.
```

## Local implementation and validation entry points

- `jobroute`, `jobroute_core.py`, `jobroute_jobs.py`: CLI/MCP, admission, job index and recovery.
- `jobroute_commands.py`, `jobroute_trust.py`: opt-in commands and executable trust checks.
- `mac-dispatch`, `mac-worker.py`, `mac_worker_state.py`, `mac_worker_lifecycle.py`: fixed SSH adapter and separately installed worker with pinned helpers.
- `check-jobroute-iso`: dedicated-account provisioning checks.
- `check-hermes-tools`: legacy no-tools check; it does not establish hb isolation.
- `generate-installer.py`, `install.sh.in`, `uninstall.py`: pinned install and rollback.
- `tests/run-sandbox.sh`: route suite and SSH harness in the required sandbox environment.
- `tests/run-rollback-sandbox.sh`: generated-installer rollback checks in a scratch HOME.

Run the full sandbox tests on ovh as `ubuntu`: `ops/jobroute/tests/run-sandbox.sh`.
Test the exact generated installer with
`ops/jobroute/tests/run-rollback-sandbox.sh /path/to/installer.sh`.
These environment-dependent suites and SSH/deployment checks were not run for this docs update;
the local documentation-test selection is recorded in the docsfix2 report.
Dated results and their environment limits are in [stack readiness](../../docs/releases/stack-merge-readiness.md).
