# Embedded baseline and bootstrap package (P2c)

Status: phase P2c of plan B (`CORE-PLAN.md` §3.1 "fail closed", §3.5; `CORE-PHASES.md`). Code:
`scripts/release/baseline.py` (embed), `scripts/release/check_baseline.py` (build check),
`Packages/SwarmHubCore/Sources/SwarmHubCore/Baseline/EmbeddedBaseline.swift` (reader, Mac + iOS),
`Sources/AgentApp/Updates/BootstrapExport.swift` + `BootstrapExportView.swift` (Mac export). Tests:
`scripts/test_release_baseline.py`, `Tests/Updater/test_baseline_offline.py`, `Tests/AgentAppTests/BootstrapExportTests.swift`,
`Packages/SwarmHubCore/Tests/SwarmHubCoreTests/EmbeddedBaselineTests.swift`. Debug builds use TEST keys only.

## What a build embeds

| Build | Folder | Holds |
| --- | --- | --- |
| Mac (`scripts/build.sh`, copied into `Contents/Resources` by `scripts/package-release.sh`) | `Baseline/` | `pins.json`, `keys.json`, `channels/stable.json`, `bundles/<N>.json`, `blobs/sha256/<sha256>`: the update service's layout (`SCHEMAS.md` §1) for the content this checkout ships (`bundle_layout.json`) |
| Mac | `Bootstrap/` | `swarmhub-updater-<VERSION>.tar` and `swarmhub-updater-<VERSION>.tar.sha256` |
| iOS (Xcode phase "Embed baseline", run by `scripts/build-ios.sh` or Xcode itself) | `Baseline/` | the same signed files, but only the blobs of components that target `ios` (no box archives); no `Bootstrap/` (iOS has no updater or transport role) |

The package is a deterministic ustar (mtime 0, uid/gid 0) of `swarmhub-updater/bin/swarmhub-update` (0755),
`swarmhub-updater/swarmhub_update/*.py` (0644) and `swarmhub-updater/pins.json`, the baseline's own pin file. The
`.sha256` file is one line `<hex>  <file name>`, as `shasum -a 256` and `sha256sum` print it.

## Configurations

- **Debug**: `baseline.py` signs the baseline in the build with the TEST keys (`TEST-root-1`/`-2`, 1 of 2;
  `TEST-release-1`), dated far in the future. Two builds of one checkout give identical bytes.
- **Release** (Mac `SWARMHUB_BUILD_CONFIGURATION=release`, the default of `package-release.sh`; iOS any configuration
  other than `Debug`): nothing is signed in the build. `SWARMHUB_BASELINE_DIR` must name a baseline made with real keys
  (P1b: `build_bundle.py --baseline`, `keys.py sign-keys --production`, `publish.py --production`, plus `pins.json`).
  Without it the build stops. The check refuses any `TEST-` key id and any TEST fixture public key among the pinned
  roots, the signatures (key manifest, index, bundle) and the listed release keys.
- **Mac release without keys**: `SWARMHUB_RELEASE_WITHOUT_BASELINE=1` embeds neither folder, so the app works as
  before P2c, and the Sparkle release can still ship. iOS has no such switch.

Both configurations run `check_baseline.py`: the baseline verifies with the P0b library (signatures as of the
index's `issued` time), its components equal what this checkout builds (a stale baseline fails), the digest file
matches the package bytes, and the package is this checkout's updater with `Baseline/pins.json`.
`package-release.sh` runs the check again on the signed `.app`, and `build-ios.sh` on the built iOS app.

## Using it

- **App, first launch, no network**: `EmbeddedBaseline.load` (iOS: `target: "ios"`) reads the folder from disk and checks the hash chain
  index → manifest → blobs. It makes no network call. Signatures are checked by the build and P0c's verifier; the app's
  code signature seals the files. The update client (P4a) takes its floors and pins from here.
- **Operator (box bootstrap)**: Settings → Advanced → About → "Box updater package" shows the expected SHA-256 and
  exports the package and its `.sha256`. Export first checks the bytes against the recorded digest and writes nothing on
  a mismatch. On the box, check with `sha256sum -c swarmhub-updater-<VERSION>.tar.sha256` (or `shasum -a 256`)
  against the value the app shows, then extract. The admin-owned install is P2d.
- **Box**: the extracted launcher takes `Baseline/` plus a `profiles.json` as `apply --staged DIR`. This is tested
  offline inside an empty network namespace.

```
python3 scripts/release/baseline.py embed --configuration debug --out DIR   # Baseline/ + Bootstrap/ into DIR
python3 scripts/release/check_baseline.py --configuration release DIR       # exit 1 on any TEST key
python3 scripts/test_release_baseline.py
python3 -m unittest discover -s Tests/Updater -p 'test_baseline_offline.py'
```
