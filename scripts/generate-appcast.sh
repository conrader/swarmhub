#!/bin/zsh
# Writes dist/appcast.xml for one packaged archive: signed, with the release notes inside, and checked.
#
#   ./scripts/generate-appcast.sh v<version> /path/to/packaged-update.zip
#
# The signing key is the one in the login Keychain (account com.konrad.agentapp). SWARMHUB_UPDATE_KEY_FILE names a
# private key file instead (a rehearsal's throwaway key; the Keychain is then not asked at all).
# The release notes are docs/releases/v<version>.md, or the file SWARMHUB_RELEASE_NOTES names (.md, .html or .txt).
# SWARMHUB_REHEARSAL=1 accepts a scratch bundle: another bundle identifier and a feed on this Mac's loopback address.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# != 2 || "$1" != v* ]]; then
  echo "Usage: $0 v<version> /path/to/packaged-update.zip" >&2
  exit 1
fi
RELEASE_TAG="$1"
ARCHIVE="${2:A}"
if [[ ! -f "$ARCHIVE" ]]; then
  echo "ERROR: archive not found: $ARCHIVE" >&2
  exit 1
fi
source "$ROOT_DIR/scripts/sparkle-tools.sh"
source "$ROOT_DIR/scripts/unregister-app.sh"
ensure_sparkle

# An isolated folder prevents accidental publication of old, dirty or development archives from dist/.
STAGING="$(mktemp -d "$ROOT_DIR/.build/appcast.XXXXXX")"
# Sparkle caches this archive's unpacked app under the ZIP's SHA-256. Clean it as well as our own staging.
CACHE_DIR=""
cleanup() {
  for app in "$STAGING"/unpacked/*.app(N); do unregister_app "$app"; done
  if [[ -n "$CACHE_DIR" ]]; then
    for app in "$CACHE_DIR"/*.app(N) "$CACHE_DIR.tmp"/*.app(N); do unregister_app "$app"; done
    rm -rf "$CACHE_DIR" "$CACHE_DIR.tmp"
  fi
  rm -rf "$STAGING"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
/usr/bin/ditto -x -k "$ARCHIVE" "$STAGING/unpacked"
APPS=("$STAGING"/unpacked/*.app(N))
if [[ ${#APPS[@]} != 1 ]]; then
  echo "ERROR: the update archive must contain exactly one application." >&2
  exit 1
fi
APP="${APPS[1]}"
python3 - "$APP/Contents/Info.plist" "$RELEASE_TAG" "$ROOT_DIR/scripts" "${SWARMHUB_REHEARSAL:-}" <<'PY'
import plistlib, sys
sys.path.insert(0, sys.argv[3])
from importlib import import_module
with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
rehearsal = sys.argv[4] == '1'
import_module('configure-updates').validate(info, rehearsal=rehearsal)
if (info.get('CFBundleIdentifier') == 'com.konrad.agentapp') == rehearsal:
    raise SystemExit('ERROR: this archive is not a SwarmHub release' if not rehearsal else 'ERROR: a rehearsal needs a bundle identifier of its own')
if sys.argv[2] != 'v' + info['CFBundleShortVersionString']:
    raise SystemExit('ERROR: the release tag must match CFBundleShortVersionString in the archive')
PY
/usr/bin/codesign --verify --deep --strict "$APP"
if [[ -n "${SWARMHUB_UPDATE_KEY_FILE:-}" ]]; then
  KEY_ARGS=(--ed-key-file "$SWARMHUB_UPDATE_KEY_FILE")
  PUBLIC_KEY="$(/usr/bin/xcrun swift "$ROOT_DIR/scripts/release-signature.swift" public "$SWARMHUB_UPDATE_KEY_FILE")"
else
  KEY_ARGS=(--account "$SPARKLE_KEY_ACCOUNT")
  PUBLIC_KEY="$("$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)"
fi
BUNDLED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
if [[ "$PUBLIC_KEY" != "$BUNDLED_KEY" ]]; then
  echo "ERROR: the signing key does not match the public key in the update archive." >&2
  exit 1
fi
mkdir "$STAGING/feed"
cp "$ARCHIVE" "$STAGING/feed/"
# What the update window shows: the release's notes, carried inside the appcast.
NOTES="${SWARMHUB_RELEASE_NOTES:-$ROOT_DIR/docs/releases/$RELEASE_TAG.md}"
if [[ ! -s "$NOTES" ]]; then
  echo "ERROR: no release notes at $NOTES. Write what changed, in plain words; people read it before they install." >&2
  exit 1
fi
cp "$NOTES" "$STAGING/feed/${ARCHIVE:t:r}.${NOTES:e}"
ARCHIVE_SHA="$(shasum -a 256 "$STAGING/feed/${ARCHIVE:t}" | awk '{print $1}')"
[[ "$ARCHIVE_SHA" =~ '^[a-f0-9]{64}$' ]] || exit 1
CACHE_DIR="${CFFIXED_USER_HOME:-$HOME}/Library/Caches/Sparkle_generate_appcast/$ARCHIVE_SHA"
"$SPARKLE_DIR/bin/generate_appcast" "${KEY_ARGS[@]}" --maximum-deltas 0 --embed-release-notes \
  --download-url-prefix "${SWARMHUB_UPDATE_DOWNLOAD_URL_PREFIX:-https://github.com/conrader/swarmhub/releases/download/$RELEASE_TAG/}" \
  -o "$STAGING/feed/appcast.xml" "$STAGING/feed"
SIGNATURE="$(python3 - "$STAGING/feed/appcast.xml" "$ARCHIVE" "${SWARMHUB_REHEARSAL:-}" <<'PY'
import base64, pathlib, sys, urllib.parse, xml.etree.ElementTree as ET
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
archive = pathlib.Path(sys.argv[2])
items = ET.parse(sys.argv[1]).findall('./channel/item')
enclosures = [enclosure for item in items for enclosure in item.findall('enclosure')]
if len(items) != 1 or len(enclosures) != 1:
    raise SystemExit('ERROR: expected exactly one signed update in the appcast')
enclosure = enclosures[0]
signature = base64.b64decode(enclosure.get(namespace + 'edSignature', ''), validate=True)
download = urllib.parse.urlsplit(enclosure.get('url', ''))
if len(signature) != 64 or int(enclosure.get('length', '0')) != archive.stat().st_size:
    raise SystemExit('ERROR: the appcast is missing a valid signature or archive size')
secure = download.scheme == 'https' or (sys.argv[3] == '1' and download.scheme == 'http' and download.hostname == '127.0.0.1')
if not secure or urllib.parse.unquote(download.path).split('/')[-1] != archive.name:
    raise SystemExit('ERROR: the appcast download URL does not match the archive')
if not (items[0].findtext('description') or '').strip():
    raise SystemExit('ERROR: the appcast carries no release notes')
print(enclosure.get(namespace + 'edSignature'))
PY
)"
# The check an installed app makes: the signature in the appcast, over this archive, by the key inside the archive.
/usr/bin/xcrun swift "$ROOT_DIR/scripts/release-signature.swift" verify "$ARCHIVE" "$SIGNATURE" "$BUNDLED_KEY"
OUTPUT_DIR="$ROOT_DIR/dist"
if [[ "${SWARMHUB_REHEARSAL:-}" == 1 ]]; then
  OUTPUT_DIR="${SWARMHUB_REHEARSAL_DIR:-$OUTPUT_DIR}"
fi
mkdir -p "$OUTPUT_DIR"
cp "$STAGING/feed/appcast.xml" "$OUTPUT_DIR/appcast.xml"
echo "$OUTPUT_DIR/appcast.xml"
echo "Upload appcast.xml and ${ARCHIVE:t} as assets of the GitHub release $RELEASE_TAG."
