#!/bin/sh
# Builds the workspace server (HerdrWorkspace, `swarmhub-herdr`) and puts it in dist/workspace under the name a
# release gives it, with the fragment the release's manifest is made from:
#
#   dist/workspace/swarmhub-herdr-<version>-<arch>-<os>
#   dist/workspace/swarmhub-herdr-<version>-<arch>-<os>.asset.json
#
# On Linux it builds one program, for the machine it runs on (a Linux build machine for x86_64-linux); bring its
# dist/workspace to the Mac that signs the release. Nothing is signed there.
#
# On a Mac it builds two, for Apple silicon (aarch64-macos) and for Intel (x86_64-macos), and signs them:
#
#   SWARMHUB_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
#   SWARMHUB_NOTARY_PROFILE='swarmhub-notary' ./scripts/package-workspace.sh
#
# SWARMHUB_SIGN_IDENTITY signs both with that identity and the hardened runtime ("-" signs ad-hoc and asks the
# Keychain nothing: a rehearsal, or a build over SSH). Without it nothing is signed here: the Apple silicon program
# keeps the linker's ad-hoc signature, and the Intel one has none.
# With the notary settings scripts/package-release.sh reads (SWARMHUB_NOTARY_PROFILE, or SWARMHUB_NOTARY_KEY,
# SWARMHUB_NOTARY_KEY_ID and SWARMHUB_NOTARY_ISSUER) the two are sent to Apple's notary service as well.
# A fragment is written last and describes the signed file: do not sign a program again after it.
#
# Nothing is uploaded here; scripts/release.sh makes the release from dist/workspace.
# SWARMHUB_CARGO_FLAGS adds cargo flags, e.g. "--offline" on a build machine without network.
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
for check_only in SWARMHUB_BRIDGE_VERSION SWARMHUB_UPDATE_PUBLIC_KEY SWARMHUB_BRIDGE_TEST_FAULT; do
  if [ -n "$(printenv "$check_only" || true)" ]; then
    echo "ERROR: $check_only is set. It makes a check build that trusts another key or names another version; unset it for a release." >&2
    exit 1
  fi
done
if [ -n "$(git -C "$ROOT_DIR" status --porcelain -- HerdrWorkspace)" ] && [ "${SWARMHUB_ALLOW_DIRTY:-}" != 1 ]; then
  echo "ERROR: HerdrWorkspace has uncommitted changes. Commit them, or set SWARMHUB_ALLOW_DIRTY=1 for a build you will not publish." >&2
  exit 1
fi
cd "$ROOT_DIR/HerdrWorkspace"
if [ "$(uname -s)" != Darwin ]; then
  # shellcheck disable=SC2086
  cargo build --release --locked ${SWARMHUB_CARGO_FLAGS:-}
  BUILT="$ROOT_DIR/HerdrWorkspace/target/release/swarmhub-herdr"
  NAME="$("$BUILT" version --json | python3 -c 'import json,sys; said=json.load(sys.stdin); print("swarmhub-herdr-%s-%s" % (said["version"], said["target"]))')"
  mkdir -p "$ROOT_DIR/dist/workspace"
  cp "$BUILT" "$ROOT_DIR/dist/workspace/$NAME"
  chmod 755 "$ROOT_DIR/dist/workspace/$NAME"
  python3 "$ROOT_DIR/scripts/workspace-manifest.py" asset "$ROOT_DIR/dist/workspace/$NAME"
  echo "$ROOT_DIR/dist/workspace/$NAME"
  exit 0
fi

# A Mac: both kinds of Mac from one machine. The program built for the other kind may not run here (the Intel one
# needs Rosetta), so nothing below depends on running it; NATIVE is the one this Mac runs.
die() { echo "ERROR: $*" >&2; exit 1; }
case "$(uname -m)" in
  arm64) NATIVE=aarch64 OTHER=x86_64 ;;
  x86_64) NATIVE=x86_64 OTHER=aarch64 ;;
  *) die "this Mac reports the machine type $(uname -m); expected arm64 or x86_64." ;;
esac
IDENTITY="${SWARMHUB_SIGN_IDENTITY:-}"
if [ -n "$IDENTITY" ] && [ "$IDENTITY" != - ] && ! /usr/bin/security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  die "the login Keychain is locked, so $IDENTITY cannot sign. Run this in a terminal on the Mac itself, not over SSH."
fi
for ARCH in aarch64 x86_64; do
  # shellcheck disable=SC2086
  cargo build --release --locked --target "$ARCH-apple-darwin" ${SWARMHUB_CARGO_FLAGS:-}
done
built() { echo "$ROOT_DIR/HerdrWorkspace/target/$1-apple-darwin/release/swarmhub-herdr"; }
VERSION="$("$(built "$NATIVE")" version --json | python3 -c '
import json, sys
said = json.load(sys.stdin)
if said["target"] != sys.argv[1]:
    sys.exit("ERROR: the program built for this Mac reports %s, not %s." % (said["target"], sys.argv[1]))
print(said["version"])' "$NATIVE-macos")"
OUT="$ROOT_DIR/dist/workspace"
mkdir -p "$OUT"
placed() { echo "$OUT/swarmhub-herdr-$VERSION-$1-macos"; }

# Signed before anything describes it: the manifest's size and SHA-256 are those of the signed file.
# No entitlements: the server starts other programs (hc, launchctl, hooks, a login shell) but loads no code of
# anyone else's into itself, makes no code at run time and reads no DYLD_ variable, which is all the hardened
# runtime forbids a program without them. Its web page's WebAssembly runs in the browser, not here.
for ARCH in aarch64 x86_64; do
  FILE="$(placed "$ARCH")"
  # A new file, never a write into the old one: macOS remembers the signature of a file it has already run.
  rm -f "$FILE" "$FILE.asset.json"
  cp "$(built "$ARCH")" "$FILE"
  chmod 755 "$FILE"
  case "$ARCH" in aarch64) SLICE=arm64 ;; *) SLICE=x86_64 ;; esac
  [ "$(/usr/bin/lipo -archs "$FILE")" = "$SLICE" ] || die "$FILE is built for $(/usr/bin/lipo -archs "$FILE"), not for $SLICE alone."
  if [ -n "$IDENTITY" ]; then
    set -- --force --identifier com.konrad.agentapp.swarmhub-herdr --sign "$IDENTITY"
    [ "$IDENTITY" = - ] || set -- "$@" --options runtime --timestamp
    /usr/bin/codesign "$@" "$FILE"
    /usr/bin/codesign --verify --strict "$FILE"
    if [ "$IDENTITY" != - ]; then
      /usr/bin/codesign -dv "$FILE" 2>&1 | grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([a-z,-]*runtime' || die "$FILE was signed without the hardened runtime."
    fi
  fi
done
case "$IDENTITY" in
  "") echo "Not signed here: SWARMHUB_SIGN_IDENTITY is not set. The Apple silicon program keeps the ad-hoc signature the linker gave it; the linker signs no Intel program. scripts/release.sh does not publish these." ;;
  -) echo "Signed ad-hoc (SWARMHUB_SIGN_IDENTITY=-): a rehearsal. scripts/release.sh does not publish these." ;;
  *) echo "Signed with the hardened runtime by $IDENTITY." ;;
esac

# Notarization: Apple checks the two signed programs and records that it did. A bare program has nowhere to carry
# the ticket (stapler works on apps, disk images and installers), so a Mac asks Apple for it by the program's
# signature. Notarizing does not change the files, so what the fragments say stays true.
set --
if [ -n "${SWARMHUB_NOTARY_PROFILE:-}" ]; then
  set -- --keychain-profile "$SWARMHUB_NOTARY_PROFILE"
elif [ -n "${SWARMHUB_NOTARY_KEY:-}" ]; then
  set -- --key "$SWARMHUB_NOTARY_KEY" --key-id "${SWARMHUB_NOTARY_KEY_ID:?set SWARMHUB_NOTARY_KEY_ID}" --issuer "${SWARMHUB_NOTARY_ISSUER:?set SWARMHUB_NOTARY_ISSUER}"
fi
if [ $# -eq 0 ]; then
  echo "Not notarized: neither SWARMHUB_NOTARY_PROFILE nor SWARMHUB_NOTARY_KEY is set."
elif [ -z "$IDENTITY" ] || [ "$IDENTITY" = - ]; then
  echo "Not notarized: Apple notarizes only what a Developer ID signed."
else
  ZIP="$ROOT_DIR/dist/swarmhub-herdr-$VERSION-macos.zip"
  ANSWER="$ROOT_DIR/dist/swarmhub-herdr-$VERSION-macos.notary.json"
  rm -f "$ZIP" "$ANSWER"
  /usr/bin/zip -q -j "$ZIP" "$(placed aarch64)" "$(placed x86_64)"
  echo "Sending both programs to Apple's notary service and waiting for its answer (usually a few minutes)."
  # notarytool can end with success for a submission Apple turned down, so the answer itself is read.
  /usr/bin/xcrun notarytool submit "$ZIP" "$@" --wait --output-format json > "$ANSWER" || { cat "$ANSWER" >&2; die "the notary service could not be asked."; }
  python3 -c '
import json, sys
answer = json.load(open(sys.argv[1]))
if answer.get("status") != "Accepted":
    sys.exit("ERROR: Apple did not notarize the workspace programs: %s. See why with: xcrun notarytool log %s <the same sign-in options>" % (answer.get("status") or answer, answer.get("id", "<id>")))
print("Notarized by Apple (submission %s)." % answer.get("id"))' "$ANSWER"
  rm -f "$ZIP" "$ANSWER"
fi

# The fragments, last. The program for the other kind of Mac is described from this Mac's own build of the same
# source; the manifest tool checks its header and, where it does run (Rosetta), asks it too.
python3 "$ROOT_DIR/scripts/workspace-manifest.py" asset "$(placed "$NATIVE")"
python3 "$ROOT_DIR/scripts/workspace-manifest.py" asset "$(placed "$OTHER")" --target "$OTHER-macos" --like "$(placed "$NATIVE")"
placed aarch64
placed x86_64
