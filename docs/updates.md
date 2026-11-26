# Updates

SwarmHub has two halves, and both update themselves: the Mac app, and the workspace server that runs beside Herdr Core on each of your servers. **Settings → Software Update** shows all of it in one place and has one button when something is behind.

## What there is to update

| What | Where it runs | How it updates |
| --- | --- | --- |
| SwarmHub, the app | Your Mac | By itself, through Sparkle. It checks once a day. |
| The workspace (`swarmhub-herdr`) | Each Herdr server, and this Mac when your bots run on it | One click in Software Update. The server installs the release itself. |
| Herdr Core | Each Herdr server | Herdr's own updater, started from Software Update. |
| Herdr's helper | Each project server | Herdr's own updater, started from Software Update. |

Nothing is installed per bot. A bot's instructions live in the app and are sent when its agent starts. The notes that teach an agent its helper, messaging, bot-creation and project commands are written by the app each time. Skills come from the server's skillshare library. So after an update there is nothing to push to bots: a new agent simply starts with the new notes.

## Using Software Update

Open **Settings → Software Update**. **Check for Updates…** in Settings → About leads there too. (**Check for Updates…** in the SwarmHub menu checks the app alone and opens the update window.)

The top of the page answers the question in one line: *Everything is up to date*, *An update is available*, or what needs your attention. **Update Now** (or **Update All**) installs what is ready: the servers first, then the app.

**This Mac** shows the app's version and two switches:

- **Check for updates automatically.** Once a day, in the background. No window opens over your work. When an update is found, choose **Review updates** just below the sidebar search controls to open this page.
- **Install updates automatically.** Off unless you turn it on. A new version then downloads in the background and installs when you quit SwarmHub.

**Update Now…** opens the update window with the release notes. From there you install at once, or later.

**Your servers** shows one card per server, and one for this Mac when your bots run on it (it is a server like any other here): the workspace version, the Herdr Core version, and what is behind. **Update** installs the newest workspace on that server. The ••• menu has **Check Again**, **Update Herdr Core** and, after an update, **Go Back** to the version it replaced.

### What happens when a server updates

1. The server downloads the release and checks its signature and its size and digest.
2. It tries the new program: the program must report the right version, and it must open a copy of the journal (the server's database of conversations). Until this passes, nothing on the server has changed.
3. It backs up the journal, keeps the running program as `swarmhub-herdr.previous`, and puts the new one in its place.
4. The workspace restarts as the new version. On a Mac, where macOS itself keeps the workspace running, it stays the same background item. This takes a few seconds. **Your agents keep running**: they live in Herdr Core, not in the workspace. An agent that is working goes on working, and its reply is saved on the server as usual. A chat that is waiting for that reply can show a connection error for the seconds the workspace is away; the reply is there once it is back.

If the new version does not start, the server puts the previous one back by itself and Software Update says so, with the reason. If it hangs, a watcher does the same after 90 seconds. The app waits two and a half minutes for the server to come back before it reports that it has not.

The journal backups are in `backups/` inside the workspace's data folder (`~/.local/state/swarmhub-herdr` unless you chose another). The newest three are kept.

### When the app cannot update a server

- **The workspace is from before it could update itself.** Install the new one once by hand (see [First install on a server](#first-install-on-a-server)). After that, updates are one click.
- **The workspace is installed where it cannot write.** Update it the way it was installed.
- **The release has no program for that kind of machine.** Releases carry three programs: for 64-bit Intel and AMD Linux servers, for Macs with Apple silicon, and for Intel Macs. On any other kind of machine, build the workspace on the machine itself (`cargo build --release` in `HerdrWorkspace`).
- **The server cannot reach the internet.** Nothing for you to do: the app downloads the release, checks it, and hands it to the server, which checks it again.

### Going back

**Go Back** returns a server to the version its last update replaced. It is offered while the journal still has the layout that version knows. If the newer version changed the journal's layout, the app says so and names the backup file. Going back then means stopping the workspace and restoring that backup by hand, and what was saved after the update is not in it.

## How the app and a server know they fit

Each server reports its version and an API level, a whole number that goes up whenever the app would have to know that something changed. The app sends its own version and the level it was written for with every request. Nothing is guessed from what a server does or does not answer.

| The app says | Meaning |
| --- | --- |
| Up to date | The server serves the level the app was written for. |
| An update is available | A newer workspace is published. |
| The server is from before it could update itself | It reports no version. Install the new workspace once by hand. |
| This server is newer than this version of SwarmHub works with | Update the app. |

An older server still works; what is newer in the app stays off on that server until it is updated.

## What is trusted

An update is a way to run new code on your Mac and your servers, so it is worth saying exactly what the design relies on.

- **One release key.** Every app archive and every workspace release is signed with the same Ed25519 key. The public half is in the app (`SUPublicEDKey` in `Info.plist`) and compiled into the workspace server. No setting and no request can name another key. A test fails if the two copies differ.
- **The app.** Sparkle checks an archive's signature against that key before it unpacks it. A release is also signed with a Developer ID and notarized by Apple, which macOS checks when the app first opens.
- **The workspace.** The server checks the release's signature itself, then the program's size and SHA-256 against the signed description. This is the same whether the server downloaded the release or the app handed it over. The app's access key alone cannot make a server run anything that is not a signed release.
- **The workspace on a Mac.** The two macOS programs are also signed with the publisher's Developer ID, with the hardened runtime, and notarized by Apple when the publisher's Mac has the notarization credentials. They are signed before the release is described, so the size and SHA-256 in the signed description are those of the signed file. The app and the server still check a macOS program the way they check a Linux one: the description's signature against the release key, then the program's size and SHA-256. A program file by itself cannot carry Apple's notarization ticket the way the app does, so macOS asks Apple for it when it wants it.
- **No way down.** A server installs only a release that is newer than itself, so an old signed release cannot be replayed to bring a fixed bug back.
- **Where releases come from.** The GitHub releases of `conrader/swarmhub`. A signed description may only point at program files there. Whoever starts a workspace can name a mirror with `SWARMHUB_UPDATE_FEED`; the signature is checked all the same.
- **What this does not cover.** The very first install on a server is by hand, over HTTPS from GitHub, with a digest you compare yourself. And anyone who has the release key can sign a release. The private key stays on the signing Mac, in its Keychain or a protected local signing file.

Herdr Core and its helper are updated by Herdr's own commands (`hc update`, `hc machine update`), which have their own checks. SwarmHub only starts them and shows what they said.

## First install on a server

Choose **A server** during setup or open **Settings → Servers → Add a server**. Enter the SSH login, including the port if needed (for example, `deploy@example.org:2222`). Click **Connect**, then **Set up on server** when prompted. SwarmHub checks the release signature, checks the downloaded program against its digest, and runs it on the server before finishing installation. Use the same steps to retry after an incompatible program was installed.

## Releasing

Build the release on the Mac that holds the keys. A local Terminal or an SSH session with access to the signing Keychain can run the same scripts. The signer needs three credentials.

- the **Developer ID Application** certificate, for signing;
- a **notarization profile**, for Apple's check;
- the **release key** (Sparkle's EdDSA key, Keychain account `com.konrad.agentapp`).

### Once per Mac

1. Install the Developer ID Application certificate in the login Keychain. `security find-identity -v -p codesigning` then lists it.
2. Save the notarization credentials: `xcrun notarytool store-credentials swarmhub-notary` (an app-specific password or an API key; the name is yours to choose). Or skip the profile and give the scripts an App Store Connect API key directly: `SWARMHUB_NOTARY_KEY` (the `AuthKey_….p8` file), `SWARMHUB_NOTARY_KEY_ID` and `SWARMHUB_NOTARY_ISSUER`.
3. Make sure the release key is in the Keychain: `./scripts/setup-updates.sh`. It refuses a key that differs from the one in `Resources/Info.plist`. To move the key to another Mac, export it on the old one with Sparkle's `generate_keys --account com.konrad.agentapp -x FILE`, import it with `-f FILE`, and delete the file. **Never make a new key**: installed apps and servers would refuse every later update. Keep one offline backup of the exported key.
4. Install Rust with both kinds of Mac as build targets, for the workspace server: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`.

### Each release

1. In `Resources/Info.plist`, set `CFBundleShortVersionString` and raise `CFBundleVersion`. Sparkle compares the build number, so it must go up every time.
2. If the workspace server changed, raise `version` in `HerdrWorkspace/Cargo.toml` (and the same line in `Cargo.lock`). Raise `API` in `HerdrWorkspace/src/update.rs` and `HerdrCompatibility.level` in the app together when the app needs to know about the change.
3. Write `docs/releases/v<version>.md`: what changed, in plain words. This file also appears in Settings → What’s New. If an unpublished candidate is superseded, move its notes to `docs/release-candidates/` before preparing the next release. Keep the shipped changes in the published version’s notes.
4. Run the checks: `swift test`, `bash Tests/Scripts/pysuites.sh . /tmp/pysuites`, and in `HerdrWorkspace` `cargo test` and `python3 tests/update_smoke.py "$(command -v hc)"`.
5. Commit.
6. For a new workspace server, a release carries three programs. `./scripts/package-workspace.sh` builds them and puts each in `dist/workspace` beside a small file that describes it (its fragment):

   | Program | For | Where the script is run |
   | --- | --- | --- |
   | `swarmhub-herdr-<version>-x86_64-linux` | 64-bit Intel and AMD Linux servers | A Linux build machine |
   | `swarmhub-herdr-<version>-aarch64-macos` | Macs with Apple silicon | The Mac that signs the release |
   | `swarmhub-herdr-<version>-x86_64-macos` | Intel Macs | The Mac that signs the release |

   On the x86_64 Linux build machine, install the musl C toolchain and GNU binutils (Debian packages `musl-tools` and `binutils`) and run `rustup target add x86_64-unknown-linux-musl`. Run the packaging script. It rejects Linux executables that require a dynamic loader or shared libraries. Copy the new executable and its matching `.asset.json` fragment into the release checkout’s `dist/workspace` on the Mac. The two macOS programs are built in the next step.
7. On the signing Mac, unlock the signing Keychain with the host’s existing credential procedure. If it uses a dedicated Keychain, export `SWARMHUB_SIGN_KEYCHAIN` with its absolute path. Store the notarization profile in that same Keychain. If Sparkle uses an existing protected key file on this Mac, export `SWARMHUB_UPDATE_KEY_FILE` with its absolute path. The scripts verify its public key against the one trusted by installed apps before building. With both variables unset, the scripts use the login Keychain and the existing Sparkle account.

   ```sh
   export SWARMHUB_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
   export SWARMHUB_NOTARY_PROFILE='swarmhub-notary'
   ./scripts/package-workspace.sh        # only for a new workspace server
   tag="v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
   SWARMHUB_WORKSPACE_NOTES='One or two sentences on what the new workspace changes.' \
   ./scripts/release.sh "$tag"
   ```

   On a Mac, `package-workspace.sh` builds both macOS programs from the one Mac, signs each with the Developer ID and the hardened runtime, sends them to Apple to be notarized, and only then writes their fragments. A fragment holds the size and SHA-256 of the signed file, so do not sign a program again afterwards; run the script again instead. Without `SWARMHUB_SIGN_IDENTITY` it signs nothing, and without the notarization settings it skips Apple's check; it says so in either case.

   `release.sh` refuses to start if anything is missing, then builds, signs, notarizes and staples the app, writes the appcast with the release notes, writes and signs the workspace manifest, and checks every signature against the key in `Info.plist`. Without new programs in `dist/workspace` it carries the published workspace manifest over unchanged. A missing manifest (HTTP 404) permits a first app-only release. A network error, unreadable signature or failed signature check stops preparation so a temporary outage cannot remove the workspace update. Apple receives the notarization submission here. GitHub publication happens in step 8.

   Before it prints the command that publishes, it says which kinds of machine the workspace manifest has a program for, and warns when one of the three is missing: servers of that kind will not be offered the update, and This Mac cannot be set up on a kind of Mac that has no program. It does not publish a macOS program that is signed ad-hoc or not at all, signed by another team than the app, or signed without the hardened runtime.
8. Push the commit and the tag, then run the `gh release create …` command the script printed. The release must be the **latest** one: the app's feed and the servers' feed are its assets (`appcast.xml`, the app archive, `workspace-manifest.json`, `workspace-manifest.json.sig`, the workspace programs).

9. From the release checkout, verify the public feed using the previous installation’s feed URL and trusted key.

   ```sh
   python3 scripts/verify-published-update.py /Applications/SwarmHub.app/Contents/Info.plist \
     --workspace-manifest dist/workspace-manifest.json
   ```

   The verifier downloads the offered ZIP, checks its size and Sparkle signature, and compares the app identifier, version and build inside it with the release checkout. It checks that the public workspace manifest matches the staged file, verifies its signature and downloads each listed program from its tagged release to check size and SHA-256. For an app-only release that has no workspace manifest, omit the option.

Do not change a file after it is signed.

Release packaging builds one app executable for Apple silicon and Intel, verifies both slices, then signs the bundle. The signed workspace programs remain separate downloads for each server architecture.

### Rehearsing without credentials

```sh
Tests/Scripts/update-rehearsal.sh
```

This runs a real update with nothing of yours: two scratch builds with their own bundle identifier and home folder, a throwaway key in a file, and a feed on the Mac's loopback address. The older build must refuse an archive signed with a stranger's key and then install the properly signed one when it quits. The scratch app opens hidden. It takes a few minutes.

To test the upgrade from a specific published version on a logged-in Mac, supply its original app ZIP. The rehearsal keeps the original executable and version in a scratch copy, gives both copies a private app identity and uses a throwaway signing key.

```sh
SWARMHUB_REHEARSAL_BASELINE_ZIP="/path/to/published-SwarmHub.zip" \
SWARMHUB_REHEARSAL_CANDIDATE_ZIP="/path/to/candidate-SwarmHub.zip" \
Tests/Scripts/update-rehearsal.sh
```

Omit the candidate ZIP to build from the checkout. The test checks that the older app fetches the archive with the incorrect signature, keeps the old build, and installs the same candidate under the trusted signature. It compares the installed executable with the candidate and verifies its code signature and launch. Use the release checks above for the production identity, notarization and public feed.

`HerdrWorkspace/tests/update_smoke.py` does the same for a server: an isolated Herdr Core, a workspace on its own port and data folder, a local releases folder and a throwaway key. It covers an unsigned release, a damaged program, a program that reports the wrong version, an update, a replay, going back, an update handed over by an app, a version that cannot start and a version that hangs.

## For developers

- `scripts/package-release.sh` writes the release ZIP to `dist/` and removes its temporary app. `SWARMHUB_SIGN_IDENTITY=-` signs ad-hoc and asks the Keychain nothing.
- Run `scripts/install-app.sh path/to/SwarmHub-release.zip` to install or replace `/Applications/SwarmHub.app`. Quit SwarmHub before running it. The installer verifies the signature and checks that the app launches before discarding its temporary rollback copy.
- `scripts/generate-appcast.sh v<version> ZIP` writes `dist/appcast.xml`. `SWARMHUB_UPDATE_KEY_FILE` signs with a key file instead of the Keychain.
- `scripts/release-signature.swift` checks a signature the way the app and the server do.
- `scripts/package-workspace.sh` builds the workspace programs. On a Mac, `SWARMHUB_SIGN_IDENTITY=-` signs both ad-hoc and asks the Keychain nothing, which works over SSH; `scripts/release.sh` does not publish those.
- `scripts/workspace-manifest.py` writes the workspace manifest from the fragments `scripts/package-workspace.sh` makes.
- A bare executable, a test run, a snapshot, a UI smoke run and a benchmark never look for updates. `SWARMHUB_DISABLE_UPDATES=1` turns them off for any other launch.
- `SWARMHUB_WORKSPACE_FEED` (app) and `SWARMHUB_UPDATE_FEED` (server) name a mirror: `https`, or `http` on `127.0.0.1`.
- The server's side is described in `HerdrWorkspace/README.md`, *Versions and updates*.
