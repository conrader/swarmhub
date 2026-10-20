# Channels, local pin and drills (P8a)

Status: phase P8a of plan B (`CORE-PLAN.md` §2.1, §2.2, §3.2, §8 step 8; `CORE-PHASES.md`). Everything here has run
only against a loopback static host with TEST keys. Running the drills on the real canary group with the real
publishing key, and a rotation signed by a recovery key, is P8b (Konrad).

## Promotion and rollout (`scripts/release/channels.py`)

```
python3 scripts/release/channels.py promote canary beta --repo DIR --pins PINS --signer file:K \
    --issued TS --expires TS [--version N] [--rollout P] [--seq S] [--production]
python3 scripts/release/channels.py rollout canary --version N --percent P --repo DIR --pins PINS \
    --signer file:K --issued TS --expires TS [--seq S] [--production]
```

- `promote FROM TO` goes one step along canary → beta → stable. It copies FROM's index line(s) for bundle N (default:
  FROM's highest) into TO's index. The line keeps `manifest_sha256`, so TO's consumers fetch the bytes FROM's consumers
  verified. Only TO's index is signed and written; nothing under `bundles/` or `blobs/` is built, signed or written
  (`scripts/test_release_channels.py` proves it with the build, publish and key-signing functions disabled and the
  service files' bytes, inodes and mtimes compared).
- Before signing, the bundle is checked as a consumer checks it: FROM's index by a current `index` key and not
  expired, the manifest's raw SHA-256 against the line, its signature by a current `bundle` key, every blob (size,
  hash, archive rules, class). A tampered blob or manifest is never promoted.
- TO never goes back: a line already serving a higher bundle is refused (going back is `republish`), as is the same
  version with another manifest. `--rollout` sets the copied line's `rollout_percent` (default: as in FROM).
- `rollout CHANNEL` re-signs the index with a new `rollout_percent` on bundle N's line(s) and `seq + 1`. Raising the
  percent only adds installs (`bucket < rollout_percent`, `SCHEMAS.md` §6); each install answers the same way every run.
- Both sign with the release key only (never a root), replace the index atomically, and write nothing when a check
  fails. Remote backends (P1c) are not wired here; promoting on the real host is P8b.

## Local pin

- **Box:** `swarmhub-update pin previous|current|clear` (P2b, `UPDATER.md`). While pinned, `pull` still verifies and
  stores a newer bundle and raises the floors, but applies nothing; `clear` applies the stored bundle.
- **Apps (SwarmHubCore):** `UpdateClient.pin(.previous | .current)` and `clearPin()`. `UpdateState.pin` has the box's
  shape `{mode, at, bundle_version}` and survives a relaunch. `previous` swaps `current` and `previous`; while pinned,
  checks verify the chain and raise the key and index floors but store nothing (verdict `no_update`, stage `pin`,
  reason `pinned`), and the bundle floor stays, so the held bundle can still be applied later. `clearPin()` releases
  the hold and checks at once: a newer verified bundle becomes current; otherwise, after `pin(.previous)`, the bundle
  pinned away from is current again when it is still in `previous`, even if a failed apply raised the floor above
  it. The pin records the installed bundle before the swap. That second half is driven by the
  persisted `restore_bundle`, so a kill between the clear and its check is completed by the next check. Once pinned
  to `previous`, a further pin of either mode changes nothing. No pin lowers a floor. No Mac UI calls it yet (P6b).

## Drills (`scripts/release/drill.py`)

```
PYTHONDONTWRITEBYTECODE=1 python3 scripts/release/drill.py [rollforward|rotate|all] [--keep DIR]
```

Each drill builds its own temporary world (`drill_world.py`): a publisher using the real tooling (`build_bundle`,
`publish`, `republish`, `channels`, `keys`), a loopback static host, boxes running the real updater in process (plain
http to loopback is accepted only through the tests' fetcher; the command line never allows it) and a Python app
stand-in for the SwarmHubCore client. Content: the real `swarmhub-feedback` skill (code), a data skill `drill-notes`
and a `policy` config for the apps. Every step is checked; Hermes files outside `skills/swarmhub` stay byte-identical.

- **rollforward:** bundle 1 is promoted canary → beta → stable; a bad bundle 2 reaches canary only; one box and the app
  pin `previous`; bundle 1 is republished as 3 (same components and blobs, no blob written); every canary consumer
  recovers without a build (the pinned ones after `clear`); 3 is promoted to stable, whose box never saw 2; a mirror
  replaying the index that offered 2 is refused `index_rollback`.
- **rotate:** release key 1 signs bundle 1; key manifest 2 adds key 2, which signs bundle 2; key manifest 3 drops key 1
  and key 2 signs bundle 3. The tooling refuses key 1 (nothing written). Consumers refuse an index signed by key 1
  (`unknown_key`) and the same with key manifest 2 replayed (`keys_rollback`). A box with no state refuses key 1's
  index, and the admin pin file's checkpoint (`min_keys_version`) stops the replay there.

Known limit (plan §3.2): a box with no state and no checkpoint accepts the replayed key manifest 2, since the roots
signed it, and with it key 1. Operator maintenance passes advance the checkpoint; key `not_after` bounds the rest.

Swift: `UpdatePinTests.swift` runs the pin and both drills against the client (Mac `swift test`);
`scripts/test_swift_update_pin.py` re-derives its verifier expectations in Python.
