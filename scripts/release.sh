#!/bin/zsh
# One release, on the Mac that holds the keys: a signed and notarized app with its appcast, and the workspace
# server's signed manifest. It builds and checks everything and uploads nothing; the last lines print the one
# command that publishes it.
#
#   SWARMHUB_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
#   SWARMHUB_NOTARY_PROFILE='swarmhub-notary' ./scripts/release.sh v<version>
#
# Notarization can sign in with an App Store Connect API key instead of a Keychain profile:
#   SWARMHUB_NOTARY_KEY=<AuthKey file> SWARMHUB_NOTARY_KEY_ID=<id> SWARMHUB_NOTARY_ISSUER=<issuer id>
#
# Before: set CFBundleShortVersionString and raise CFBundleVersion in Resources/Info.plist, write
# docs/releases/v<version>.md, commit, and (for a release with a new workspace server) fill dist/workspace: bring
# the output of scripts/package-workspace.sh from the Linux build machine, and run it here, with the same signing
# and notary settings, for the two macOS programs. docs/updates.md has every step.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
die() { echo "ERROR: $*" >&2; exit 1; }
[[ $# == 1 && "$1" == v* ]] || die "usage: $0 v<version>"
TAG="$1"
REPO="conrader/swarmhub"
FEED="https://github.com/$REPO/releases/latest/download"
PLIST="$ROOT_DIR/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST")"
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")"
NOTES="$ROOT_DIR/docs/releases/$TAG.md"
SIGNATURE_TOOL=(/usr/bin/xcrun swift "$ROOT_DIR/scripts/release-signature.swift")

# 1. Nothing is built until the release can be finished.
[[ "$TAG" == "v$VERSION" ]] || die "the tag is $TAG but Resources/Info.plist says version $VERSION."
[[ -s "$NOTES" ]] || die "write the release notes first: $NOTES (plain words; they show in the update window)."
[[ "${SWARMHUB_SIGN_IDENTITY:-}" == "Developer ID Application: "* ]] || die "set SWARMHUB_SIGN_IDENTITY to your Developer ID Application certificate's name (security find-identity -v -p codesigning)."
[[ -n "${SWARMHUB_NOTARY_PROFILE:-}" || ( -s "${SWARMHUB_NOTARY_KEY:-}" && -n "${SWARMHUB_NOTARY_KEY_ID:-}" && -n "${SWARMHUB_NOTARY_ISSUER:-}" ) ]] \
  || die "set SWARMHUB_NOTARY_PROFILE to the Keychain profile made with xcrun notarytool store-credentials, or SWARMHUB_NOTARY_KEY, SWARMHUB_NOTARY_KEY_ID and SWARMHUB_NOTARY_ISSUER to an App Store Connect API key file, its id and its issuer."
/usr/bin/security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || die "the login Keychain is locked. Run this in a terminal on the Mac itself, not over SSH."
if [[ -n "$(git status --porcelain --untracked-files=normal)" && "${SWARMHUB_ALLOW_DIRTY:-}" != 1 ]]; then
  die "the working tree has uncommitted changes; a release is built from a commit."
fi
source "$ROOT_DIR/scripts/sparkle-tools.sh"
ensure_sparkle
[[ "$("$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)" == "$PUBLIC_KEY" ]] \
  || die "this Mac's Keychain does not hold the release key that Resources/Info.plist trusts. Import it (docs/updates.md); never make a new one."
# Sparkle offers an update only when its build number is higher than the installed one.
PUBLISHED="$(curl --fail --silent --location --max-time 30 "$FEED/appcast.xml" | sed -n 's|.*<sparkle:version>\([0-9.]*\)</sparkle:version>.*|\1|p' | head -1 || true)"
if [[ -z "$PUBLISHED" ]]; then
  echo "NOTE: the published appcast could not be read, so the build number was not compared with it."
elif [[ "$PUBLISHED" == "$BUILD" || "$(printf '%s\n%s\n' "$PUBLISHED" "$BUILD" | sort -V | tail -1)" != "$BUILD" ]]; then
  die "CFBundleVersion is $BUILD, and build $PUBLISHED is already published. Raise CFBundleVersion."
fi

# 2. The app: built for release, signed with the Developer ID, notarized and stapled.
ZIP="$(./scripts/package-release.sh | tail -1)"
APP="$ROOT_DIR/dist/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$PLIST").app"
/usr/bin/xcrun stapler validate "$APP"
/usr/sbin/spctl --assess --type execute --verbose=2 "$APP"

# 3. The appcast: the archive's EdDSA signature and the release notes.
./scripts/generate-appcast.sh "$TAG" "$ZIP"

# 4. The workspace server: this release's programs, or the published manifest carried over unchanged.
MANIFEST="$ROOT_DIR/dist/workspace-manifest.json"
: > "$MANIFEST"; : > "$MANIFEST.sig"
FRAGMENTS=("$ROOT_DIR"/dist/workspace/*.asset.json(N))
PROGRAMS=()
if [[ ${#FRAGMENTS[@]} -gt 0 ]]; then
  WORKSPACE_NOTES="${SWARMHUB_WORKSPACE_NOTES:-}"
  [[ -n "$WORKSPACE_NOTES" ]] || die "set SWARMHUB_WORKSPACE_NOTES to one or two plain sentences on what the new workspace server changes; the app shows them beside Update."
  python3 "$ROOT_DIR/scripts/workspace-manifest.py" manifest --tag "$TAG" --notes "$WORKSPACE_NOTES" --released "$(date +%Y-%m-%d)" --out "$MANIFEST" "${FRAGMENTS[@]}"
  APP_TEAM="$(/usr/bin/codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
  for FRAGMENT in "${FRAGMENTS[@]}"; do
    PROGRAM="${FRAGMENT%.asset.json}"
    [[ -s "$PROGRAM" ]] || die "$PROGRAM is missing beside its fragment."
    [[ "$(shasum -a 256 "$PROGRAM" | awk '{print $1}')" == "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["asset"]["sha256"])' "$FRAGMENT")" ]] || die "$PROGRAM is not the file its fragment describes. A program signed again after its fragment was written is another file: run scripts/package-workspace.sh again."
    TARGET="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["asset"]["target"])' "$FRAGMENT")"
    if [[ "$TARGET" == *-macos ]]; then
      # A macOS program is published as the app is: signed by the same Developer ID, with the hardened runtime.
      # An ad-hoc signature (a rehearsal, or a build without SWARMHUB_SIGN_IDENTITY) is never published; this
      # script has no rehearsal of its own, it starts only with a Developer ID.
      AGAIN="Build and sign it on this Mac: SWARMHUB_SIGN_IDENTITY='$SWARMHUB_SIGN_IDENTITY' ./scripts/package-workspace.sh"
      [[ "$(/usr/bin/lipo -archs "$PROGRAM" 2>/dev/null)" == "${${TARGET%-macos}/aarch64/arm64}" ]] || die "$PROGRAM is not a program for $TARGET alone."
      /usr/bin/codesign --verify --strict "$PROGRAM" 2>/dev/null || die "$PROGRAM has no valid code signature. $AGAIN"
      SIGNED="$(/usr/bin/codesign -dvv "$PROGRAM" 2>&1)"
      PROGRAM_TEAM="$(awk -F= '/^TeamIdentifier=/ {print $2}' <<< "$SIGNED")"
      [[ "$SIGNED" != *$'\nSignature=adhoc'* && -n "$PROGRAM_TEAM" && "$PROGRAM_TEAM" != "not set" ]] || die "$PROGRAM is only ad-hoc signed. $AGAIN"
      [[ "$SIGNED" == *$'\nAuthority=Developer ID Application: '* ]] || die "$PROGRAM is not signed with a Developer ID Application certificate. $AGAIN"
      [[ "$PROGRAM_TEAM" == "$APP_TEAM" ]] || die "$PROGRAM is signed by team $PROGRAM_TEAM and the app by team $APP_TEAM. $AGAIN"
      [[ "$SIGNED" =~ 'flags=0x[0-9a-f]+\([a-z,-]*runtime' ]] || die "$PROGRAM is signed without the hardened runtime. $AGAIN"
    fi
    PROGRAMS+=("$PROGRAM")
  done
  "$SPARKLE_DIR/bin/sign_update" --account "$SPARKLE_KEY_ACCOUNT" -p "$MANIFEST" > "$MANIFEST.sig"
elif curl --fail --silent --location --max-time 30 "$FEED/workspace-manifest.json" -o "$MANIFEST" \
  && curl --fail --silent --location --max-time 30 "$FEED/workspace-manifest.json.sig" -o "$MANIFEST.sig"; then
  echo "NOTE: no new workspace server in dist/workspace; the published manifest is carried over unchanged."
else
  : > "$MANIFEST"; : > "$MANIFEST.sig"
  echo "NOTE: this release has no workspace server, and none is published yet. Servers will find nothing to update to."
fi
# Which kinds of machine the manifest serves, new or carried over. A missing kind does not stop the release.
CARRIED=()
MISSING=()
if [[ -s "$MANIFEST" ]]; then
  "${SIGNATURE_TOOL[@]}" verify "$MANIFEST" "$(cat "$MANIFEST.sig")" "$PUBLIC_KEY"
  CARRIED=($(python3 -c 'import json,sys; print(" ".join(asset["target"] for asset in json.load(open(sys.argv[1]))["assets"]))' "$MANIFEST")) \
    || die "$MANIFEST does not list its programs."
  for WANTED in x86_64-linux aarch64-macos x86_64-macos; do
    (( ${CARRIED[(Ie)$WANTED]} )) || MISSING+=("$WANTED")
  done
fi

# 5. What to upload. `latest` must be this release: the app's feed and the servers' feed are its assets.
ASSETS=("$ZIP" "$ROOT_DIR/dist/appcast.xml")
[[ ! -s "$MANIFEST" ]] || ASSETS+=("$MANIFEST" "$MANIFEST.sig" "${PROGRAMS[@]}")
echo
echo "Ready: $VERSION (build $BUILD), signed by team $(/usr/bin/codesign -dv "$APP" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}'), notarized, appcast and signatures checked."
if [[ -s "$MANIFEST" ]]; then
  echo "The workspace manifest carries a program for: ${(j:, :)CARRIED:-no kind of machine}."
  for WANTED in "${MISSING[@]}"; do
    case "$WANTED" in
      x86_64-linux) echo "WARNING: it has no program for 64-bit Intel and AMD Linux ($WANTED). Servers of that kind will not be offered this update." ;;
      aarch64-macos) echo "WARNING: it has no program for Macs with Apple silicon ($WANTED). Servers of that kind will not be offered this update, and This Mac cannot be set up on that kind of Mac." ;;
      x86_64-macos) echo "WARNING: it has no program for Intel Macs ($WANTED). Servers of that kind will not be offered this update, and This Mac cannot be set up on that kind of Mac." ;;
    esac
  done
fi
echo "Nothing was uploaded. To publish, push the commit and its tag, then run:"
echo
printf '  gh release create %s --repo %s --latest --title %q --notes-file %q' "$TAG" "$REPO" "SwarmHub $VERSION" "$NOTES"
printf ' \\\n    %q' "${ASSETS[@]}"
echo
