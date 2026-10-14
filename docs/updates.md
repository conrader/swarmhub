# Automatic updates

Installed macOS builds use Sparkle 2.10.0. The application menu and Settings → Updates share one updater. It checks daily by default; automatic downloading and installation is an opt-in setting. Sparkle saves both preferences across launches and handles download progress, installation and relaunch.

The default feed is `https://github.com/conrader/swarmhub/releases/latest/download/appcast.xml`. Each stable GitHub release must include `appcast.xml` and the exact ZIP archive it describes. Archive signatures are verified before extraction. The application keeps its existing bundle identifier, preferences, history and Keychain service.

## Set up the signing key once

On the Mac used to sign releases (with Xcode and Python 3 installed):

```sh
./scripts/setup-updates.sh
```

This downloads the pinned, checksum-verified Sparkle tools if SwiftPM has not fetched them. Sparkle creates or reuses an Ed25519 key in the login Keychain under account `com.konrad.agentapp`. The script writes only the public key to `Resources/Info.plist`. Commit that file so every build trusts the same key. The script refuses to replace a previously configured public key with a different one.

Back up the private key securely with Sparkle's `generate_keys --account com.konrad.agentapp -x /secure/path/private-key`. Keep it outside the repository. Use `-f /secure/path/private-key` with the same account when moving the release process to another Mac. Losing or changing this key can prevent existing installations from accepting updates.

## Publish a release

1. Update `CFBundleShortVersionString` and increase `CFBundleVersion` in `Resources/Info.plist`. Sparkle compares the numeric **build number**, so it must increase for every update, even when the displayed version stays the same.
2. Run the tests on macOS:

   ```sh
   swift test
   python3 -m unittest discover -s scripts -p 'test_configure_updates.py'
   ```

3. Package the release. For public distribution, select a Developer ID Application certificate and a Keychain profile previously configured with `xcrun notarytool store-credentials`:

   ```sh
   SWARMHUB_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
   SWARMHUB_NOTARY_PROFILE='swarmhub-notary' ./scripts/package-release.sh
   ```

   The script builds in release mode, embeds Sparkle, signs its helpers and framework before the app, verifies all signatures, and notarizes/staples when `SWARMHUB_NOTARY_PROFILE` is supplied. Without an explicit identity, it retains the existing Apple Development/ad-hoc behavior for local builds. The final line prints the ZIP path under `dist/`.

4. Generate the appcast from that final ZIP. For example, after setting the displayed version to `0.4.1`:

   ```sh
   ./scripts/generate-appcast.sh v0.4.1 /absolute/path/to/dist/SwarmHub-0.4.1-6-<sha>-arm64.zip
   ```

   Use the actual ZIP path printed by packaging. The script checks the bundled key against Keychain, verifies the release tag and app signatures, and generates `dist/appcast.xml` with a signed full update. It stages only the specified ZIP, so other archives in `dist/` cannot be published accidentally. No delta files are generated.

5. Upload `dist/appcast.xml` and the ZIP together to the GitHub release with that tag. Mark the stable release as latest. Uploading or publishing is a separate step; the scripts only produce local artifacts. Do not modify the ZIP after generating its signature.

For other hosting, set `SWARMHUB_UPDATE_FEED_URL` during packaging and `SWARMHUB_UPDATE_DOWNLOAD_URL_PREFIX` during appcast generation. `SWARMHUB_UPDATE_PUBLIC_KEY` can supply an existing public key during packaging without changing the source plist. The matching private key must still be in the release Mac's Keychain for appcast generation.

## Development and verification

`scripts/build.sh` supports SwiftPM and the existing direct `swiftc` fallback. Both link Sparkle and place it beside the executable for `scripts/run.sh`. Packaged apps load their own `Contents/Frameworks/Sparkle.framework`; `ditto` preserves its symlinks and executable permissions.

Bare SwiftPM executables and builds without a public key keep the existing on-demand GitHub release lookup in Settings. The automatic updater is also disabled for snapshots, UI smoke runs, benchmarks and integration runs. Set `SWARMHUB_DISABLE_UPDATES=1` to disable it for any other automated launch. For a local development bundle before key setup, use `SWARMHUB_ALLOW_MISSING_UPDATE_KEY=1 ./scripts/package-release.sh`; appcast generation still requires a valid key.

To test an installation, package two builds with the same key and increasing build numbers, host the newer ZIP and appcast, and install the older app in a writable Applications folder. Choose **Check for Updates…**, install, and verify the new build and retained data. Check that disabling automatic checks persists after relaunch. Public distribution should also be tested with notarized builds.

The initial installation of a Sparkle-enabled build is manual for users of older SwarmHub versions that only supported release lookup.

See Sparkle's [setup guide](https://sparkle-project.org/documentation/), [SwiftUI integration](https://sparkle-project.org/documentation/programmatic-setup/) and [updater preferences](https://sparkle-project.org/documentation/customization/).
