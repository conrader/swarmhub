# jobroute: dedicated bot accounts → approved job operations

Source contract checked locally at `7963b72` on 2026-11-11. GitHub heads,
reviews, installed routes and live settings are **unverified**. A dated report
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

The Mac worker uses the installed sb-macjob shared FIFO queue and a fresh
private workspace. Its six-hour total includes queue wait; cleanup then has
separate workload and runner TERM graces (up to 120 s each), bounded KILL drains
and reap. Cleanup is **best effort** and can leave work running. Exit 124 means
the deadline path, not confirmed descendant drain. The supervisor launches the
workload before recording its PGID. `queue` uses one runner cleanup phase;
the outer route budget is 225 s (60 + 120 + 45).

The ovh installer does **not** install `mac-worker.py` on the Mac. Install and
validate it separately against the real runner's lock/session contract during
the approved pilot. Workloads must not daemonize into additional sessions.
See [cleanup details and failure causes](../../docs/swap-jobs-migration.md#command-contracts)
and [known limits](../../docs/ROADMAP-AND-LIMITS.md).

## Installation, identity checks and rollback

Use the [migration/pilot runbook](../../docs/swap-jobs-migration.md#later-real-box-pilot-operator-checklist-not-performed)
and [per-bot isolation guide](../../docs/bot-isolation.md). Provision the
private key in the dedicated hb home; bind its public key to the exact profile
and pinned route. Run `check-jobroute-iso` on the bot box and independently
verify the running service UID, cross-account unreadability and forced-command
restrictions. The check is provisioning evidence, not remote attestation.
Resolve executable/PATH trust findings through the separately reviewed plan.

`generate-installer.py` produces an exact-commit installer for review. Install
and activation are separate operations; existing trusted config is retained.
`uninstall.py` uses installer provenance and only prunes unchanged, empty
installer-created parents. Preserve audit/job records unless their removal is
explicitly authorized. Disabling keys or rolling back the route does not stop
already detached jobs. Coordinate the completion skill rollback before
installing a route older than the `outcome` contract.

## Local implementation and validation entry points

- `jobroute`, `jobroute_core.py`, `jobroute_jobs.py`: CLI/MCP, admission, job index and recovery.
- `jobroute_commands.py`, `jobroute_trust.py`: opt-in commands and executable trust checks.
- `mac-dispatch`, `mac-worker.py`: fixed SSH adapter and separately installed worker.
- `check-jobroute-iso`: dedicated-account provisioning checks.
- `check-hermes-tools`: legacy no-tools check; it does not establish hb isolation.
- `generate-installer.py`, `install.sh.in`, `uninstall.py`: pinned install and rollback.
- `tests/run-sandbox.sh`: route suite and SSH harness in the required sandbox environment.
- `tests/run-rollback-sandbox.sh`: generated-installer rollback checks in a scratch HOME.

Test entry points are listed for maintainers; no tests, SSH or deployment checks
were run for this documentation update. Dated results and their environment
limits are in [stack readiness](../../docs/releases/stack-merge-readiness.md).
