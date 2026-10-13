#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/dist/AgentApp.app"
ZIP_PATH="$ROOT_DIR/dist/AgentApp-hermes-fix4-arm64.zip"

mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$ROOT_DIR/.build/debug/AgentApp" "$APP_DIR/Contents/MacOS/AgentApp"
rm -rf "$APP_DIR/Contents/MacOS/AgentApp.resources" "$APP_DIR/Contents/Resources/Avatars"
cp -R "$ROOT_DIR/Resources/Avatars" "$APP_DIR/Contents/Resources/Avatars"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod 755 "$APP_DIR/Contents/MacOS/AgentApp"

/usr/bin/codesign --force --sign - "$APP_DIR/Contents/MacOS/AgentApp"
/usr/bin/codesign --force --sign - "$APP_DIR"
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
/usr/bin/codesign --verify --strict "$APP_DIR"
echo "$ZIP_PATH"
