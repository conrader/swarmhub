#!/bin/zsh
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/sparkle-tools.sh"
ensure_sparkle

# Sparkle reuses the existing key for this account; the private key never leaves the login Keychain.
"$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT"
PUBLIC_KEY="$("$SPARKLE_DIR/bin/generate_keys" --account "$SPARKLE_KEY_ACCOUNT" -p)"
EXISTING_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$ROOT_DIR/Resources/Info.plist")"
if [[ -n "$EXISTING_KEY" && "$EXISTING_KEY" != "$PUBLIC_KEY" ]]; then
  echo "ERROR: the configured public key does not match this Mac's Keychain. Import the original private key; do not rotate it accidentally." >&2
  exit 1
fi
SWARMHUB_UPDATE_PUBLIC_KEY="$PUBLIC_KEY" python3 "$ROOT_DIR/scripts/configure-updates.py" "$ROOT_DIR/Resources/Info.plist"
echo "Sparkle is configured. Commit Resources/Info.plist and back up the private key securely using generate_keys -x."
