#!/bin/zsh
# Rehearses an app update for real, without any credential: an older and a newer scratch build with a bundle
# identifier and a home folder of their own, a throwaway signing key in a file, and a feed on this Mac's loopback
# address. The older build finds the newer one, checks its signature, and installs it when it quits. A second round
# offers an archive signed with another key, which must not be installed.
#
#   Tests/Scripts/update-rehearsal.sh
#
# It works in a new folder under /tmp and prints its name. Nothing here reads or writes the login Keychain, the
# installed app, or its data. The scratch app opens hidden.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d /tmp/swarmhub-update-rehearsal.XXXXXX)"
WORK="${WORK:A}"
BUNDLE_ID=com.konrad.agentapp.update-rehearsal
PORT="${SWARMHUB_REHEARSAL_PORT:-18733}"
FEED="http://127.0.0.1:$PORT"
OLD_BUILD=900001; NEW_BUILD=900002; OLD_VERSION=90.0.1; NEW_VERSION=90.0.2
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/sparkle-tools.sh"
SIGNATURE_TOOL=(/usr/bin/xcrun swift "$ROOT_DIR/scripts/release-signature.swift")
say() { print -r -- "== $*"; }

say "packaging (ad-hoc signed, no Keychain) in ${WORK:?}"
SWARMHUB_SIGN_IDENTITY=- SWARMHUB_BUILD_CONFIGURATION="${SWARMHUB_BUILD_CONFIGURATION:-debug}" ./scripts/package-release.sh > "$WORK/package.log" 2>&1 || { tail -20 "$WORK/package.log"; exit 1; }
ensure_sparkle
NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' Resources/Info.plist)"
INSTALLED="$WORK/installed/$NAME.app"
UPDATE="$WORK/update/$NAME.app"
mkdir "$WORK/installed" "$WORK/update" "$WORK/feed" "$WORK/home"

# Two throwaway keys: the one the scratch builds trust, and a stranger's.
for KEY in trusted stranger; do (umask 077; /usr/bin/openssl rand -base64 32 > "$WORK/$KEY.key"); done
PUBLIC_KEY="$("${SIGNATURE_TOOL[@]}" public "$WORK/trusted.key")"

# Makes the app at $1 a scratch copy of the packaged one, as build $2 version $3, signed inside out like the real one.
scratch() {
  local APP="$1" FRAMEWORK SERVICE
  /usr/bin/ditto "$ROOT_DIR/dist/$NAME.app" "$APP"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleVersion $2" -c "Set :CFBundleShortVersionString $3" \
    -c "Set :SUFeedURL $FEED/appcast.xml" -c "Set :SUPublicEDKey $PUBLIC_KEY" -c "Set :SUAutomaticallyUpdate true" "$APP/Contents/Info.plist"
  FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
  for SERVICE in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc; do /usr/bin/codesign --force --sign - --preserve-metadata=entitlements "$SERVICE"; done
  /usr/bin/codesign --force --sign - "$FRAMEWORK/Versions/B/Autoupdate"
  /usr/bin/codesign --force --sign - "$FRAMEWORK/Versions/B/Updater.app"
  /usr/bin/codesign --force --sign - "$FRAMEWORK"
  /usr/bin/codesign --force --sign - --entitlements "$ROOT_DIR/Resources/SwarmHub.entitlements" --identifier "$BUNDLE_ID" "$APP"
  /usr/bin/codesign --verify --deep --strict "$APP"
}
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist"; }
quit_installed() { local PID; for PID in $(pgrep -f "$INSTALLED/Contents/MacOS/" || true); do kill "$PID" 2>/dev/null || true; done; }

say "making build $OLD_BUILD (installed) and build $NEW_BUILD (the update)"
scratch "$UPDATE" "$NEW_BUILD" "$NEW_VERSION" 2>/dev/null
ZIP="$WORK/$NAME-$NEW_VERSION-$NEW_BUILD-rehearsal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$UPDATE" "$ZIP"
print -r -- "Rehearsal build $NEW_BUILD. **Nothing changed**; this only shows that an update arrives, is checked and installs." > "$WORK/notes.md"
SWARMHUB_REHEARSAL=1 SWARMHUB_UPDATE_KEY_FILE="$WORK/trusted.key" SWARMHUB_RELEASE_NOTES="$WORK/notes.md" SWARMHUB_UPDATE_DOWNLOAD_URL_PREFIX="$FEED/" \
  ./scripts/generate-appcast.sh "v$NEW_VERSION" "$ZIP" > "$WORK/appcast.log" 2>&1 || { cat "$WORK/appcast.log"; exit 1; }
cp "$ROOT_DIR/dist/appcast.xml" "$WORK/trusted-appcast.xml"
grep -q "Nothing changed" "$WORK/trusted-appcast.xml" || { echo "FAILED: the appcast carries no release notes."; exit 1; }
# The same appcast with a stranger's signature in place of the trusted one.
GOOD="$("$SPARKLE_DIR/bin/sign_update" --ed-key-file "$WORK/trusted.key" -p "$ZIP")"
STRANGE="$("$SPARKLE_DIR/bin/sign_update" --ed-key-file "$WORK/stranger.key" -p "$ZIP")"
python3 - "$WORK/trusted-appcast.xml" "$WORK/stranger-appcast.xml" "$GOOD" "$STRANGE" <<'PY'
import sys
text = open(sys.argv[1]).read()
assert sys.argv[3] in text, "the appcast does not carry the trusted key's signature"
open(sys.argv[2], "w").write(text.replace(sys.argv[3], sys.argv[4]))
PY
cp "$ZIP" "$WORK/feed/"

SERVER=0
cleanup() {
  [[ "$SERVER" == 0 ]] || kill "$SERVER" 2>/dev/null || true
  quit_installed
  # The scratch build's own preferences and download cache; the real app's are under another identifier.
  /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  /bin/rm -rf "${HOME:?}/Library/Caches/${BUNDLE_ID:?}"
}
trap cleanup EXIT

# Serves the feed with appcast $1, runs the installed scratch build until it has fetched the archive (or a minute and
# a half has passed), gives Sparkle $2 seconds to check and unpack it, quits the app and waits up to $3 seconds for
# the new build to be in its place.
run_installed() {
  cp "$1" "$WORK/feed/appcast.xml"
  (cd "$WORK/feed" && exec python3 -m http.server "$PORT" --bind 127.0.0.1) > /dev/null 2> "$WORK/feed.log" &
  SERVER=$!
  /usr/bin/open -n -g -j "$INSTALLED" --env "CFFIXED_USER_HOME=$WORK/home" --env SWARMHUB_UPDATE_CHECK_ON_LAUNCH=1
  local WAITED=0
  until grep -q "GET /.*\.zip" "$WORK/feed.log" 2>/dev/null || (( WAITED >= 90 )); do sleep 1; WAITED=$((WAITED + 1)); done
  grep -q "GET /appcast.xml" "$WORK/feed.log" || { echo "FAILED: the app never asked its feed."; return 1; }
  sleep "$2"
  quit_installed
  WAITED=0
  until [[ "$(build_of)" == "$NEW_BUILD" ]] || (( WAITED >= $3 )); do sleep 1; WAITED=$((WAITED + 1)); done
  kill "$SERVER" 2>/dev/null || true; SERVER=0
}

say "round 1: an update signed with a stranger's key is fetched and refused"
scratch "$INSTALLED" "$OLD_BUILD" "$OLD_VERSION" 2>/dev/null
run_installed "$WORK/stranger-appcast.xml" 25 20
grep -q "GET /.*\.zip" "$WORK/feed.log" || echo "note: the app did not fetch the archive in this round."
[[ "$(build_of)" == "$OLD_BUILD" ]] || { echo "FAILED: an archive signed with a stranger's key was installed."; exit 1; }
echo "ok: build $OLD_BUILD stayed"

say "round 2: the same update signed with the trusted key installs when the app quits"
run_installed "$WORK/trusted-appcast.xml" 20 90
[[ "$(build_of)" == "$NEW_BUILD" ]] || { echo "FAILED: the installed build is still $(build_of)."; cat "$WORK/feed.log"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$INSTALLED"
echo "ok: build $OLD_BUILD became build $NEW_BUILD"

say "the workspace manifest is signed and checked with the same tools"
print -r -- '{"product":"swarmhub-herdr","version":"0.0.0","api":1,"api_min":1,"assets":[]}' > "$WORK/workspace-manifest.json"
"$SPARKLE_DIR/bin/sign_update" --ed-key-file "$WORK/trusted.key" -p "$WORK/workspace-manifest.json" > "$WORK/workspace-manifest.json.sig"
"${SIGNATURE_TOOL[@]}" verify "$WORK/workspace-manifest.json" "$(cat "$WORK/workspace-manifest.json.sig")" "$PUBLIC_KEY"
if "${SIGNATURE_TOOL[@]}" verify "$WORK/workspace-manifest.json" "$(cat "$WORK/workspace-manifest.json.sig")" "$("${SIGNATURE_TOOL[@]}" public "$WORK/stranger.key")" 2>/dev/null; then
  echo "FAILED: a signature passed against the wrong key."; exit 1
fi
echo "ok"
echo "update rehearsal: ok ($WORK)"
