# Mac staged skill installation (P4b)

The Mac verifies a **local service-layout snapshot** for the destination box using the core verifier, including
box compatibility, rollout and floors. It forwards the signed metadata and only the compatible box-targeted blobs
as base64 bytes. It never extracts an archive, imports its contents or executes them. The management turn writes
those bytes into a private temporary folder under the updater state directory and invokes exactly:

```
/usr/local/lib/swarmhub-update/bin/swarmhub-update --max-wait 0 apply --staged <folder>
```

It then requests a separate terminal call to `/usr/local/lib/swarmhub-update/bin/swarmhub-update status`.
The app matches the terminal command and its result by tool-call ID. Assistant prose and `skills_installed` replies
cannot confirm staged installs. Streams without terminal results leave installation unconfirmed. Refused, deferred,
held, pinned, failed and pending-code results cannot become an installed requested version. Pending status may
record the data skills that actually landed. `reload_pending` is reported; nothing enables plugins or restarts Hermes.
Read-back uses the same status call, and keeps versions newer than the compiled fallback.

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
dependencies still require the existing separate local confirmation; P4b never invokes that confirmation.

## Validation

`Tests/Updater/test_staged_transport.py` instantiates the exact box-side shell literal from `StagedInstall.swift`
with TEST-signed bytes and an isolated updater prefix, then runs the real launcher. It builds today's resources
with the release builder, verifies all four skills against the render goldens, checks altered archives leave live
and previous trees intact, and checks profile/variant refresh and Hermes confinement. No external host is used.
`Tests/AgentAppTests/StagedInstallTests.swift` covers verification, opaque transport, exact terminal-result binding,
the native Hermes event parser plus the app install path, model-only claims, pending code, source/box failure,
and legacy fallback. The existing Swift golden test remains the renderer authority.

On the MacBook run AgentApp `swift test` (including staged install, render and managed remote control tests),
SwarmHubCore `swift test`, and `scripts/test-ios-core.sh`. Goldens still carry the existing PROVISIONAL marker:
run the render test with `SWARMHUB_WRITE_RENDERS=1` on the Mac to replace that provisional set with Swift output.
The Linux P0d generator was used here; its only changes were the three messages renders' advertised/frontmatter
versions from 1.3.10 to 1.4.0.

Updater status is bot-account-writable, as documented in CORE-PLAN §3.5. This path verifies releases and reads the
updater's actual output; it cannot protect against an account rewriting skills or status outside that path.
