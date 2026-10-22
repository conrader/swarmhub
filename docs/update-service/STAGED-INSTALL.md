# Mac staged skill installation and code confirmation (P4b, P4c)

The Mac verifies a **local service-layout snapshot** for the destination box using the core verifier, including
box compatibility, rollout and floors. It forwards the signed metadata and only the compatible box-targeted blobs
as opaque bytes. It never extracts an archive, imports its contents or executes them.

The app sends the bytes directly through stock Hermes' authenticated, profile-prefixed `POST /api/sessions`.
Each temporary, empty carrier session stores at most 49,152 payload bytes as a base64 `system_prompt` (65,536
characters). **No model turn is started in a carrier session.** The management turn receives only a bounded script,
random carrier IDs, expected chunk hashes and the whole payload hash. It never receives the archive payload.
The script copies the raw profile DB and WAL into updater-owned temporary storage, opens that snapshot with SQLite
`mode=ro`, checks every part and the complete envelope, deletes the snapshot, then writes the
opaque files into a private temporary folder under the updater state directory and invokes exactly:

```
/usr/local/lib/swarmhub-update/bin/swarmhub-update --max-wait 0 apply --staged <folder>
```

The app requires the matching staging terminal call to finish successfully with this transfer's receipt, then
requests a separate terminal call to `/usr/local/lib/swarmhub-update/bin/swarmhub-update status`.
Both calls are matched by exact command and tool-call ID. A missing/altered part stops before invoking the updater;
an altered archive is refused by the updater. Either keeps the last good tree. An older successful status for the
same bundle cannot confirm a failed transfer. Assistant prose and `skills_installed` replies cannot confirm installs.
Streams without terminal results leave installation unconfirmed. Refused, deferred, held, pinned, failed and
pending-code results cannot become an installed requested version. Pending status may record the data skills that
actually landed. `reload_pending` is reported; nothing enables plugins or restarts Hermes.

The staging call emits `SWARMHUB_UPDATER_RESULT:<carrier-prefix>` followed by JSON containing the updater's
exit code and its exact stdout, including nonzero exits (65 rejected, 75 deferred). Only exit 0 prints the separate,
exact `SWARMHUB_TRANSFER_OK:<carrier-prefix>` line. The app binds diagnostic receipts to the staging command,
tool-call ID and transfer prefix. It shows the updater's rejection reason or deferral detail and caches a failed/deferred
reading, preserving the last known live versions without recording an installation. This also handles lock deferral,
whose stdout has a reason but does not rewrite `status.json`. A later stale successful status cannot replace this
turn's failure. Transfer exceptions have their own `SWARMHUB_TRANSFER_FAILED:<carrier-prefix>` diagnostic and never
invoke the updater. Assistant prose cannot supply either diagnostic. An app diagnostic overlay does not change the
box's status file.

Skills-view opens reuse the last updater reading (including persisted installed versions), with no model turn.
“Refresh from updater” explicitly requests a fresh reading, single-flight per connection. Its temporary session is
deleted afterward. Carrier sessions are also deleted after completion, upload failure or cancellation. Cleanup IDs
are saved before upload; interrupted/unreachable cleanup is retried before the next updater action. New transfers
and refresh turns wait for that cleanup, so repeated failures cannot accumulate sessions.
Carrier and refresh IDs both include `sessionNamespace` (including QA/E2E). Cleanup uses the saved full IDs and
recognizes namespaced IDs even if the app's current namespace has changed.

### Stock Hermes transport investigation

Read-only inspection of the local **stock 0.21.7** source verified `gateway/platforms/api_server.py`:
`_handle_create_session` inserts `body.system_prompt` verbatim into `sessions.system_prompt`, commits before replying,
and does not start an agent; `_handle_delete_session` deletes the session through the normal authenticated API.
The prefix middleware scopes both endpoints to the selected profile. `hermes_state.py` resolves `state.db` under
that profile's Hermes home. The script queries only these newly created rows, never imports Hermes or opens its live DB through SQLite.
Copying DB/WAL bytes first keeps SQLite shared-memory bookkeeping inside updater state too. A concurrent checkpoint
that makes the copied snapshot inconsistent fails closed; retrying creates fresh carrier IDs.
Stock `GET /api/sessions/<id>` deliberately omits `system_prompt`, so it cannot fetch just the carrier bytes.
Opening the live DB read-only can still write SQLite shared-memory bookkeeping; immutable mode ignores the WAL.
Neither is safe for this transport. The raw snapshot is therefore retained, with a **64 MiB combined DB + WAL cap**.
Each source must be a regular file opened without following symlinks; both its initial size and the actual bytes
copied (including growth) must fit the remaining budget. An oversized history fails closed with a transfer diagnostic;
it never starts the updater. There is no truncation, live-DB query or automatic Hermes maintenance.
The DB/WAL/SHM copy is deleted as soon as carrier reads finish, before updater execution. The outer `finally` removes
the private staging folder on success, rejection, deferral and transfer exceptions, including partial snapshot failures.
The server itself performs its normal session bookkeeping through its existing API. Hermes source, configuration,
services and plugins are untouched. No terminal call writes outside the updater state and `skills/swarmhub/`.

The script uses `HERMES_HOME` when set, otherwise `~/.hermes`, and selects the manager profile's `state.db`.
The terminal must share the gateway's local profile storage (stock host execution); a sandbox without that storage,
a relocated database, incompatible schema or absent native-session API fails closed. No legacy raw-payload fallback
is attempted for a bootstrapped connection. Commands above 32 KiB are refused before upload.

The stock `/v1/artifacts/upload` alternative was rejected: it is gated on browser extension control, returns no
filesystem path, and stores artifacts outside the permitted updater write area. This transport needs no Hermes
configuration changes, browser-control enablement, new listener, update host or credentials in model instructions.

## Operator configuration for test boxes

This checkout does **not** contain the P2c embedded signed baseline or P2d bootstrap installer. P4b therefore takes
an existing signed service-layout directory as input; it does not provision a host, bootstrap a box, or invent an
update origin. P4a's app-data store deliberately excludes box code and cannot serve as a box-archive source.
Refreshing this local source can be added to that fetching infrastructure later. An unavailable source fails closed
for a bootstrapped box. Direct chat and approval routing do not depend on the source or an update host.

Only debug builds have the fixed public TEST roots from `Tests/Fixtures/release-bundles/keys/pins.json`.
Release builds refuse this transport until production pins/baseline are supplied by the later key/bootstrap work.
No test keys or private keys are read from a remote source. Nothing in this phase has run against real boxes.

After an **operator-controlled deterministic bootstrap check**, place `Updates/box-transport.json` beside the Mac's
`store.json`. The top-level dictionary is keyed by the app's exact `connection(of:)` string. Each entry is:

```json
{
  "source": "file:///absolute/path/to/a/local/TEST-service-layout/",
  "channel": "stable",
  "installID": "TEST-install-0001",
  "versions": {"updater": "1.0.0", "hermes": "0.21.7"},
  "checkpoint": {"keys": 1, "index": 4, "bundle": 10}
}
```

`installID`, channel, known version axes and checkpoint must describe that destination's updater configuration.
Omit `hermes` when unknown; compatibility is checked again by the box. The source contains `keys.json`,
`channels/<channel>.json`, `bundles/<version>.json`, and `blobs/sha256/<digest>`; it supplies neither pins nor scripts
to run on the Mac. Root pins are compiled. A model reply/status does not create this operator record or establish
bootstrap trust. The fixed updater/pin paths must be admin-owned and not bot-writable. Status must report protected
pins at `/usr/local/lib/swarmhub-update/pins.json`; this is a check of the existing operator record, not bootstrap discovery.

The Mac persists verification floors per connection in its own defaults. Resending the same version is allowed
only for the exact manifest already verified by this Mac. It remembers that a connection used bootstrap; losing
its configuration cannot silently switch it back to raw installation. An explicit operator reset must clear both
the record and `updates.transport.bootstrapped.<connection>` in defaults to select the legacy path again.

Boxes with no bootstrap record retain the existing raw-file installer and its existing limitations. It makes no
verification claim. The all-bots action follows the same selection per connection. The box-side staging script
preserves other profiles and installed skill selections when adding the requested profiles. Re-sending previously
applied archives can render a new profile or coding order without authorizing any new code. Code and its waiting
dependencies require the separate per-box confirmation below; staged installation never invokes it.

## Per-box code confirmation (P4c)

The existing skills panel and bot editor show the updater state, code components, and waiting data components
with their `waits_for` dependencies. For `pending_confirm`, the button reads **Apply code update N on <box>**.
Opening either view, refreshing status, and installing skills (including all-bots install) never confirm code.
The button captures the exact connection, bundle version and manifest hash shown. A stale button or another box's
button cannot start a turn. The operator's bootstrap record must still exist; the update source need not be reachable.

One click starts one native management turn on that connection and invokes exactly:

```
/usr/local/lib/swarmhub-update/bin/swarmhub-update --max-wait 0 apply --version N && <receiver step>
```

The receiver step (`StagedInstall.receiverCommand`, also run at the end of a successful staged install) runs only
after the updater exits 0. It reinstalls the webhook receiver from the first live swarmhub-messages copy
(`swarmctl webhook receiver install`, which is idempotent and restarts the receiver when its code changed). Its output
is discarded and a failure fails nothing, so the call's stdout and exit code stay the updater's. swarmhub-messages is
code, so the receiver's code reaches the box only through this confirm.

With `--max-wait 0` a busy box defers the confirm (exit 75): the updater keeps the confirmation (`state` `deferred`,
`confirmed_version` N, `applied_bundle_version` below N, no `pending_confirm`) but the code is not live, so the
receiver step does not run. The pane then offers **Retry code update N on <box>**, the same command for the same
version; the retry that lands the code runs the receiver step.

The Mac is not needed for that last step. The confirmation stays recorded, so a later `check` or the timer's `pull`
can land the deferred code in the background, and the state turns `current` with no Retry left. The updater
therefore installs the receiver itself, the same `swarmctl webhook receiver install` from the first live copy,
whenever a run lands new swarmhub-messages content, whichever command it was (`runner.ensure_receiver`; output
discarded, failure fails nothing). A run that only re-renders bytes the box already had, or lands nothing new, leaves
the receiver alone, so an owner's `webhook receiver uninstall` survives the timer. The Mac's receiver step stays for
boxes whose updater predates this; on a current updater it is a second, idempotent install.

Run by the timer, the updater is a oneshot systemd user service, and systemd kills whatever is left in its control
group when it exits. Without lingering the install starts the receiver's fallback supervisor, so there the updater runs
the install in a transient scope of its own (`systemd-run --user --scope`, `runner.own_scope`) and the supervisor
outlives the run. If the scope cannot be made, the install runs directly, as before. A scope still belongs to the user
manager, which stops at logout without lingering; the gateway brings the recorded fallback back at its next start.

The updater checks `--version` under its CLI lock, so N+1 arriving before execution refuses the old click. There is
no automatic retry with a new version. Apply must finish in the matched terminal call and report `current`, the
expected manifest/version, `confirmed_version` and `applied_bundle_version`. A separate matched fixed-path `status`
call must then report the same result. Assistant text, `skills_installed`, an unrelated call, nonzero apply exit or
an older successful status cannot establish success. Deferred/rejected/unconfirmed outcomes remain visible, and
`reload_pending` is shown without restarting Hermes. Temporary sessions use the existing persisted cleanup path;
confirmation, refresh and staged install are mutually exclusive per connection.

`BoxUpdateState` persists the highest bundle version and most recently reported version per exact connection in
the Mac's defaults (`updates.box-state.<connection>`). A lower report displays a regression warning, including after
relaunch while the box is offline. A report reaching the recorded maximum clears the warning without lowering the
maximum. This is detection only: it changes no updater floors, apply policy, installed files or direct routing.
Only matched updater readings update the record; model prose and local diagnostic overlays do not.

P4c adds `BoxUpdateStateTests.swift` for click/box/version binding, actual native event parsing, separate status
read-back, stale success refusal, single flight/cleanup, persisted regression, offline source and box failures, and
unchanged direct chat routing. `Tests/Updater/test_mac_code_confirm.py` executes the Mac command against two isolated
TEST-key updater states, including N+1 racing a click and unchanged Hermes fixture bytes. No box-side code changed.
Swift tests are authored and require the Mac run; P4c is not fully verified until that run passes.

## Validation

`Tests/Updater/test_staged_transport.py` instantiates the exact box-side shell literal from `StagedInstall.swift`
with TEST-signed bytes and an isolated updater prefix, populates temporary SQLite carrier rows matching the stock
session-create contract, then runs the real launcher. It also transfers a signed archive over 300 KB and checks
altered/missing chunks stop before the updater, leaving status and live/previous trees intact. It builds today's resources
with the release builder, verifies all four skills against the render goldens, checks altered archives leave live
and previous trees intact, and checks profile/variant refresh and Hermes confinement. Rejection, busy-box and lock
deferral tests assert the exact updater JSON/exit and absence of a success receipt. Snapshot tests cover uncheckpointed
WAL, combined size refusal, invalid SQLite, deletion before updater execution and failure cleanup. No external host is used.
`Tests/AgentAppTests/StagedInstallTests.swift` covers verification, opaque transport, exact terminal-result binding,
the native Hermes event parser plus the app install path, model-only claims, pending code, source/box failure,
legacy fallback, direct carrier upload and cleanup, stale-status refusal after a failed transfer, and explicit
single-flight status refresh with cleanup on success/failure, QA/E2E namespaces, and rejected/deferred/transfer-failure
diagnostics reaching the user and cached reading without accepting stale success. Swift tests are authored but require
the Mac run. The existing Swift golden test remains the renderer authority.

On the MacBook run AgentApp `swift test` (including staged install, render and managed remote control tests),
SwarmHubCore `swift test`, and `scripts/test-ios-core.sh`. Goldens still carry the existing PROVISIONAL marker:
run the render test with `SWARMHUB_WRITE_RENDERS=1` on the Mac to replace that provisional set with Swift output.
The Linux P0d generator was used here; its only changes were the three messages renders' advertised/frontmatter
versions from 1.3.10 to 1.4.0.

Updater status is bot-account-writable, as documented in CORE-PLAN §3.5. This path verifies releases and reads the
updater's actual output; it cannot protect against an account rewriting skills or status outside that path.
