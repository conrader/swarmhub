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
BUNDLE_ID="com.konrad.agentapp.update-menu-test.$(uuidgen)"
OLD_BUILD=900001; NEW_BUILD=900002; OLD_VERSION=90.0.1; NEW_VERSION=90.0.2
BASELINE="${SWARMHUB_REHEARSAL_BASELINE_ZIP:-}"
CANDIDATE="${SWARMHUB_REHEARSAL_CANDIDATE_ZIP:-}"
[[ -z "$BASELINE" ]] || BASELINE="${BASELINE:A}"
[[ -z "$CANDIDATE" ]] || CANDIDATE="${CANDIDATE:A}"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/sparkle-tools.sh"
source "$ROOT_DIR/scripts/unregister-app.sh"
SIGNATURE_TOOL=(/usr/bin/xcrun swift "$ROOT_DIR/scripts/release-signature.swift")
say() { print -r -- "== $*"; }

NAME="SwarmHub Dev"
INSTALLED="$WORK/installed/$NAME.app"
UPDATE="$WORK/update/$NAME.app"
quit_installed() {
  local PID
  for PID in $(pgrep -f "$INSTALLED/Contents/MacOS/" || true); do kill "$PID" 2>/dev/null || true; done
}
cleanup() {
  set +e
  local SERVER PORT APP
  if [[ -s "$WORK/server-ready" ]]; then
    read -r SERVER PORT < "$WORK/server-ready"
    kill "$SERVER" 2>/dev/null || true
  fi
  quit_installed
  unregister_app "$INSTALLED"
  unregister_app "$UPDATE"
  for APP in "$WORK"/{base,baseline}/*.app(N); do unregister_app "$APP"; done
  /usr/bin/defaults delete "$BUNDLE_ID" >/dev/null 2>&1 || true
  /bin/rm -rf "${HOME:?}/Library/Caches/${BUNDLE_ID:?}" "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep the EXIT trap in the parent. zsh's errexit inside a failing function can
# terminate the child before a script-level EXIT trap runs.
(
unpack_app() {
  local ARCHIVE="$1" DESTINATION="$2"
  /usr/bin/ditto -x -k "$ARCHIVE" "$DESTINATION" || return 1
  local APPS=("$DESTINATION"/*.app(N))
  [[ ${#APPS[@]} == 1 ]] || { echo "Expected one app in $ARCHIVE." >&2; return 1; }
  /usr/bin/codesign --verify --deep --strict "$APPS[1]" || return 1
  print -r -- "$APPS[1]"
}

say "private update workspace: $WORK"
if [[ -z "$CANDIDATE" ]]; then
  say "packaging (ad-hoc signed, no Keychain) in ${WORK:?}"
  SWARMHUB_SIGN_IDENTITY=- SWARMHUB_REHEARSAL_PACKAGE=1 SWARMHUB_REHEARSAL_DIR="$WORK" \
    SWARMHUB_BUILD_CONFIGURATION="${SWARMHUB_BUILD_CONFIGURATION:-debug}" \
    ./scripts/package-release.sh > "$WORK/package.log" 2>&1 || { tail -20 "$WORK/package.log"; exit 1; }
  CANDIDATE="$(tail -1 "$WORK/package.log")"
fi
ensure_sparkle
BASE_APP="$(unpack_app "$CANDIDATE" "$WORK/base")"
OLD_APP="$BASE_APP"
if [[ -n "$BASELINE" ]]; then
  OLD_APP="$(unpack_app "$BASELINE" "$WORK/baseline")"
  OLD_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OLD_APP/Contents/Info.plist")"
  OLD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OLD_APP/Contents/Info.plist")"
  say "starting from packaged SwarmHub $OLD_VERSION ($OLD_BUILD)"
fi
mkdir "$WORK/installed" "$WORK/update" "$WORK/feed" "$WORK/home"

# Let the OS reserve a loopback port. Record the Python server's own PID because on macOS
# /usr/bin/python3 can be an Xcode launcher with a separate process serving requests.
python3 -u - "$WORK" "${SWARMHUB_REHEARSAL_PORT:-0}" > "$WORK/server.log" 2>&1 <<'PYTHON' &
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os, sys
work = Path(sys.argv[1])
class Feed(SimpleHTTPRequestHandler):
    def log_message(self, template, *args):
        with (work / "feed.log").open("a") as log:
            print(template % args, file=log)
with ThreadingHTTPServer(("127.0.0.1", int(sys.argv[2])), partial(Feed, directory=str(work / "feed"))) as server:
    ready = work / "server-starting"
    ready.write_text(f"{os.getpid()} {server.server_port}\n")
    ready.rename(work / "server-ready")
    server.serve_forever()
PYTHON
LAUNCHER=$!
for attempt in {1..100}; do
  [[ ! -s "$WORK/server-ready" ]] || break
  kill -0 "$LAUNCHER" 2>/dev/null || break
  sleep 0.1
done
[[ -s "$WORK/server-ready" ]] || { cat "$WORK/server.log"; exit 1; }
read -r SERVER PORT < "$WORK/server-ready"
FEED="http://127.0.0.1:$PORT"

# Two throwaway keys: the one the scratch builds trust, and a stranger's.
for KEY in trusted stranger; do (umask 077; /usr/bin/openssl rand -base64 32 > "$WORK/$KEY.key"); done
PUBLIC_KEY="$("${SIGNATURE_TOOL[@]}" public "$WORK/trusted.key")"

# Makes the app at $1 a scratch copy of the packaged one, as build $2 version $3, signed inside out like the real one.
scratch() {
  local APP="$1" FRAMEWORK SERVICE
  /usr/bin/ditto "$4" "$APP"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" -c "Set :CFBundleVersion $2" -c "Set :CFBundleShortVersionString $3" \
    -c 'Add :LSUIElement bool true' -c "Set :SUFeedURL $FEED/appcast.xml" -c "Set :SUPublicEDKey $PUBLIC_KEY" -c "Set :SUAutomaticallyUpdate true" "$APP/Contents/Info.plist"
  FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
  for SERVICE in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc; do /usr/bin/codesign --force --sign - --preserve-metadata=entitlements "$SERVICE"; done
  /usr/bin/codesign --force --sign - "$FRAMEWORK/Versions/B/Autoupdate"
  /usr/bin/codesign --force --sign - "$FRAMEWORK/Versions/B/Updater.app"
  /usr/bin/codesign --force --sign - "$FRAMEWORK"
  /usr/bin/codesign --force --sign - --entitlements "$ROOT_DIR/Resources/SwarmHub.entitlements" --identifier "$BUNDLE_ID" "$APP"
  /usr/bin/codesign --verify --deep --strict "$APP"
}
build_of() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist"; }

say "making build $OLD_BUILD (installed) and build $NEW_BUILD (the update)"
scratch "$UPDATE" "$NEW_BUILD" "$NEW_VERSION" "$BASE_APP" 2>/dev/null
ZIP="$WORK/SwarmHub-Dev-$NEW_VERSION-$NEW_BUILD-rehearsal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$UPDATE" "$ZIP"
print -r -- "Rehearsal build $NEW_BUILD. **Nothing changed**; this only shows that an update arrives, is checked and installs." > "$WORK/notes.md"
SWARMHUB_REHEARSAL=1 SWARMHUB_REHEARSAL_DIR="$WORK" SWARMHUB_UPDATE_KEY_FILE="$WORK/trusted.key" SWARMHUB_RELEASE_NOTES="$WORK/notes.md" SWARMHUB_UPDATE_DOWNLOAD_URL_PREFIX="$FEED/" \
  ./scripts/generate-appcast.sh "v$NEW_VERSION" "$ZIP" > "$WORK/appcast.log" 2>&1 || { cat "$WORK/appcast.log"; exit 1; }
cp "$WORK/appcast.xml" "$WORK/trusted-appcast.xml"
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

# Serves the feed with appcast $1, runs the installed scratch build until it has fetched the archive (or a minute and
# a half has passed), gives Sparkle $2 seconds to check and unpack it, quits the app and waits up to $3 seconds for
# the new build to be in its place.
run_installed() {
  cp "$1" "$WORK/feed/appcast.xml"
  : > "$WORK/feed.log"
  env HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" TMPDIR="$WORK/" SWARMHUB_SERVICE_HOME="$WORK/home" SWARMHUB_UPDATE_CHECK_ON_LAUNCH=1 \
    "$INSTALLED/Contents/MacOS/AgentApp" > "$WORK/launch.log" 2>&1 &
  local WAITED=0 ZIP_REQUEST='"GET /[^ ]*\.zip HTTP/[0-9.]+" 2[0-9][0-9]'
  until grep -Eq "$ZIP_REQUEST" "$WORK/feed.log" 2>/dev/null || (( WAITED >= 90 )); do sleep 1; WAITED=$((WAITED + 1)); done
  grep -Eq "$ZIP_REQUEST" "$WORK/feed.log" || { echo "FAILED: the app did not download the offered archive."; cat "$WORK/feed.log"; return 1; }
  sleep "$2"
  quit_installed
  WAITED=0
  until [[ "$(build_of)" == "$NEW_BUILD" ]] || (( WAITED >= $3 )); do sleep 1; WAITED=$((WAITED + 1)); done
}

say "round 1: an update signed with a stranger's key is fetched and refused"
scratch "$INSTALLED" "$OLD_BUILD" "$OLD_VERSION" "$OLD_APP" 2>/dev/null
run_installed "$WORK/stranger-appcast.xml" 25 20
[[ "$(build_of)" == "$OLD_BUILD" ]] || { echo "FAILED: an archive signed with a stranger's key was installed."; exit 1; }
echo "ok: build $OLD_BUILD stayed"

say "round 2: the same update signed with the trusted key installs when the app quits"
run_installed "$WORK/trusted-appcast.xml" 20 90
[[ "$(build_of)" == "$NEW_BUILD" ]] || { echo "FAILED: the installed build is still $(build_of)."; cat "$WORK/feed.log"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$INSTALLED"
cmp "$UPDATE/Contents/MacOS/AgentApp" "$INSTALLED/Contents/MacOS/AgentApp"
env HOME="$WORK/home" CFFIXED_USER_HOME="$WORK/home" TMPDIR="$WORK/" SWARMHUB_SERVICE_HOME="$WORK/home" "$INSTALLED/Contents/MacOS/AgentApp" --verify-install-launch
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
)
