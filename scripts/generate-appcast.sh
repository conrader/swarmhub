#!/bin/zsh
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
ensure_sparkle

# An isolated folder prevents accidental publication of old, dirty or development archives from dist/.
STAGING="$(mktemp -d "$ROOT_DIR/.build/appcast.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
/usr/bin/ditto -x -k "$ARCHIVE" "$STAGING/unpacked"
APPS=("$STAGING"/unpacked/*.app(N))
if [[ ${#APPS[@]} != 1 ]]; then
  echo "ERROR: the update archive must contain exactly one application." >&2
  exit 1
fi
APP="${APPS[1]}"
python3 - "$APP/Contents/Info.plist" "$RELEASE_TAG" "$ROOT_DIR/scripts" <<'PY'
import plistlib, sys
sys.path.insert(0, sys.argv[3])
from importlib import import_module
with open(sys.argv[1], 'rb') as file:
    info = plistlib.load(file)
import_module('configure-updates').validate(info)
if info.get('CFBundleIdentifier') != 'com.konrad.agentapp':
    raise SystemExit('ERROR: this archive is not a SwarmHub release')
if sys.argv[2] != 'v' + info['CFBundleShortVersionString']:
    raise SystemExit('ERROR: the release tag must match CFBundleShortVersionString in the archive')
PY
/usr/bin/codesign --verify --deep --strict "$APP"
PUBLIC_KEY="$("$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)"
BUNDLED_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")"
if [[ "$PUBLIC_KEY" != "$BUNDLED_KEY" ]]; then
  echo "ERROR: the signing key does not match the public key in the update archive." >&2
  exit 1
fi
mkdir "$STAGING/feed"
cp "$ARCHIVE" "$STAGING/feed/"
"$SPARKLE_DIR/bin/generate_appcast" --account "$SPARKLE_KEY_ACCOUNT" --maximum-deltas 0 \
  --download-url-prefix "${SWARMHUB_UPDATE_DOWNLOAD_URL_PREFIX:-https://github.com/conrader/swarmhub/releases/download/$RELEASE_TAG/}" \
  -o "$STAGING/feed/appcast.xml" "$STAGING/feed"
python3 - "$STAGING/feed/appcast.xml" "$ARCHIVE" <<'PY'
import base64, pathlib, sys, urllib.parse, xml.etree.ElementTree as ET
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
archive = pathlib.Path(sys.argv[2])
enclosures = ET.parse(sys.argv[1]).findall('./channel/item/enclosure')
if len(enclosures) != 1:
    raise SystemExit('ERROR: expected exactly one signed update in the appcast')
enclosure = enclosures[0]
signature = base64.b64decode(enclosure.get(namespace + 'edSignature', ''), validate=True)
download = urllib.parse.urlsplit(enclosure.get('url', ''))
if len(signature) != 64 or int(enclosure.get('length', '0')) != archive.stat().st_size:
    raise SystemExit('ERROR: the appcast is missing a valid signature or archive size')
if download.scheme != 'https' or urllib.parse.unquote(download.path).split('/')[-1] != archive.name:
    raise SystemExit('ERROR: the appcast download URL does not match the archive')
PY
mkdir -p "$ROOT_DIR/dist"
cp "$STAGING/feed/appcast.xml" "$ROOT_DIR/dist/appcast.xml"
echo "$ROOT_DIR/dist/appcast.xml"
echo "Upload appcast.xml and ${ARCHIVE:t} as assets of the GitHub release $RELEASE_TAG."
