#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/build.sh"

SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
DIRTY_SUFFIX=""
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
  DIRTY_SUFFIX="-dirty"
fi
DIRTY_SUMMARY="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)"
DIRTY_SUMMARY_SHA="$(printf '%s' "$DIRTY_SUMMARY" | shasum -a 256 | awk '{print $1}')"
APP_DIR="$ROOT_DIR/dist/Torvli.app"
ZIP_PATH="$ROOT_DIR/dist/Torvli-${SOURCE_SHA}${DIRTY_SUFFIX}-arm64.zip"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/debug/AgentApp" "$APP_DIR/Contents/MacOS/AgentApp"
rm -rf "$APP_DIR/Contents/MacOS/AgentApp.resources" "$APP_DIR/Contents/Resources/Avatars"
cp -R "$ROOT_DIR/Resources/Avatars" "$APP_DIR/Contents/Resources/Avatars"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
{
  echo "source_sha=$(git -C "$ROOT_DIR" rev-parse HEAD)"
  echo "dirty=$([[ -n "$DIRTY_SUFFIX" ]] && echo true || echo false)"
  echo "dirty_summary_sha256=$DIRTY_SUMMARY_SHA"
  if [[ -n "$DIRTY_SUMMARY" ]]; then
    echo "dirty_files:"
    printf '%s\n' "$DIRTY_SUMMARY"
  fi
} > "$APP_DIR/Contents/Resources/SOURCE.txt"
chmod 755 "$APP_DIR/Contents/MacOS/AgentApp"

# Stable signing keeps the app the same to the Keychain across rebuilds; ad-hoc makes every build a stranger.
SIGN_ID="${TORVLI_SIGN_IDENTITY:-}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(/usr/bin/security find-identity -v -p codesigning | awk -F'"' '/"Apple Development: / {print $2; exit}')"
fi
if [[ -z "$SIGN_ID" ]]; then
  echo "WARNING: no Apple Development identity found; signing ad-hoc. Keychain keys will not survive rebuilds." >&2
  SIGN_ID="-"
elif ! /usr/bin/security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "ERROR: login keychain is locked; unlock it and rerun (not falling back to ad-hoc)." >&2
  exit 1
fi
SIGN_ARGS=(--force --sign "$SIGN_ID" --identifier com.konrad.agentapp)
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_DIR/Contents/MacOS/AgentApp"
TEAM_ID="$(/usr/bin/codesign -dv "$APP_DIR/Contents/MacOS/AgentApp" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
echo "signing_team=${TEAM_ID:-adhoc}" >> "$APP_DIR/Contents/Resources/SOURCE.txt"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$APP_DIR"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
/usr/bin/codesign --verify --strict "$APP_DIR"
echo "$ZIP_PATH"
