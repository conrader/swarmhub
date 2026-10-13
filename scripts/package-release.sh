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
APP_DIR="$ROOT_DIR/dist/AgentApp.app"
ZIP_PATH="$ROOT_DIR/dist/AgentApp-${SOURCE_SHA}${DIRTY_SUFFIX}-arm64.zip"

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

/usr/bin/codesign --force --sign - "$APP_DIR/Contents/MacOS/AgentApp"
/usr/bin/codesign --force --sign - "$APP_DIR"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
/usr/bin/codesign --verify --strict "$APP_DIR"
echo "$ZIP_PATH"
