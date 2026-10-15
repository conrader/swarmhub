#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT_DIR/.build"
CONFIGURED_PLIST="$(mktemp "$ROOT_DIR/.build/release-info.XXXXXX")"
trap 'rm -f "$CONFIGURED_PLIST"' EXIT
cp "$ROOT_DIR/Resources/Info.plist" "$CONFIGURED_PLIST"
# Fail before building if a distributable bundle would have a missing key or an invalid feed.
CONFIG_ARGS=()
[[ "${SWARMHUB_ALLOW_MISSING_UPDATE_KEY:-}" != 1 ]] || CONFIG_ARGS=(--allow-missing-key)
python3 "$ROOT_DIR/scripts/configure-updates.py" "$CONFIGURED_PLIST" "${CONFIG_ARGS[@]}"
SWARMHUB_BUILD_CONFIGURATION="${SWARMHUB_BUILD_CONFIGURATION:-release}" "$ROOT_DIR/scripts/build.sh"
BUILD_DIR="$(cat "$ROOT_DIR/.build/agentapp-bin-path")"
source "$ROOT_DIR/scripts/sparkle-tools.sh"
ensure_sparkle

SOURCE_SHA="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
DIRTY_SUFFIX=""
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
  DIRTY_SUFFIX="-dirty"
fi
DIRTY_SUMMARY="$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)"
DIRTY_SUMMARY_SHA="$(printf '%s' "$DIRTY_SUMMARY" | shasum -a 256 | awk '{print $1}')"
# The bundle is named after CFBundleName (AppConstants.name; a test keeps them equal), so a rename touches no script.
APP_NAME="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$ROOT_DIR/Resources/Info.plist")"
APP_DIR="$ROOT_DIR/dist/$APP_NAME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONFIGURED_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CONFIGURED_PLIST")"
ARCHITECTURES="$(/usr/bin/lipo -archs "$BUILD_DIR/AgentApp" | tr ' ' '-')"
ZIP_PATH="$ROOT_DIR/dist/$APP_NAME-$VERSION-$BUILD_NUMBER-${SOURCE_SHA}${DIRTY_SUFFIX}-$ARCHITECTURES.zip"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BUILD_DIR/AgentApp" "$APP_DIR/Contents/MacOS/AgentApp"
/usr/bin/ditto "$BUILD_DIR/Sparkle.framework" "$APP_DIR/Contents/Frameworks/Sparkle.framework"
rm -rf "$APP_DIR/Contents/MacOS/AgentApp.resources" "$APP_DIR/Contents/Resources/Avatars" "$APP_DIR/Contents/Resources/BotManager" "$APP_DIR/Contents/Resources/Skills" "$APP_DIR/Contents/Resources/ThemeIcons"
cp -R "$ROOT_DIR/Resources/Avatars" "$APP_DIR/Contents/Resources/Avatars"
# P22: the bot-manager text SwarmHub sends the manager bot on demand.
cp -R "$ROOT_DIR/Resources/BotManager" "$APP_DIR/Contents/Resources/BotManager"
# P27: the skills SwarmHub installs into bots' own profiles.
cp -R "$ROOT_DIR/Resources/Skills" "$APP_DIR/Contents/Resources/Skills"
# P23: the Swarm app icon (CFBundleIconFile/CFBundleIconName = AppIcon in Info.plist).
/usr/bin/iconutil -c icns "$ROOT_DIR/Resources/AppIcon/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
# P38: the light and dark Dock icons AppIconAppearance picks at run time (the icns stays the light Finder fallback).
cp -R "$ROOT_DIR/Resources/AppIcon/ThemeIcons" "$APP_DIR/Contents/Resources/ThemeIcons"
cp "$ROOT_DIR/THIRD-PARTY-NOTICES.md" "$APP_DIR/Contents/Resources/THIRD-PARTY-NOTICES.md"
cp "$SPARKLE_DIR/LICENSE" "$APP_DIR/Contents/Resources/SPARKLE-LICENSE.txt"
cp "$CONFIGURED_PLIST" "$APP_DIR/Contents/Info.plist"
{
  echo "source_sha=$(git -C "$ROOT_DIR" rev-parse HEAD)"
  echo "version=$VERSION"
  echo "build=$BUILD_NUMBER"
  echo "dirty=$([[ -n "$DIRTY_SUFFIX" ]] && echo true || echo false)"
  echo "dirty_summary_sha256=$DIRTY_SUMMARY_SHA"
  if [[ -n "$DIRTY_SUMMARY" ]]; then
    echo "dirty_files:"
    printf '%s\n' "$DIRTY_SUMMARY"
  fi
} > "$APP_DIR/Contents/Resources/SOURCE.txt"
chmod 755 "$APP_DIR/Contents/MacOS/AgentApp"

# Stable signing keeps the app the same to the Keychain across rebuilds; ad-hoc makes every build a stranger.
# SWARMHUB_SIGN_IDENTITY picks the identity (TORVLI_SIGN_IDENTITY is still read); default: the first Apple Development one.
SIGN_ID="${SWARMHUB_SIGN_IDENTITY:-${TORVLI_SIGN_IDENTITY:-}}"
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
SIGN_ARGS=(--force --sign "$SIGN_ID")
if [[ "$SIGN_ID" != - ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
# P38 C: the app binary and bundle carry SwarmHub.entitlements (microphone input, needed under the hardened runtime).
# Sign inside out, preserving the helpers' own identifiers and entitlements.
# --deep is only used to verify, never to apply the app's identity to nested helpers.
FRAMEWORK="$APP_DIR/Contents/Frameworks/Sparkle.framework"
for SERVICE in "$FRAMEWORK"/Versions/B/XPCServices/*.xpc; do
  /usr/bin/codesign "${SIGN_ARGS[@]}" --preserve-metadata=entitlements "$SERVICE"
done
/usr/bin/codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
/usr/bin/codesign "${SIGN_ARGS[@]}" "$FRAMEWORK"
/usr/bin/codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT_DIR/Resources/SwarmHub.entitlements" --identifier com.konrad.agentapp "$APP_DIR/Contents/MacOS/AgentApp"
TEAM_ID="$(/usr/bin/codesign -dv "$APP_DIR/Contents/MacOS/AgentApp" 2>&1 | awk -F= '/^TeamIdentifier=/ {print $2}')"
echo "signing_team=${TEAM_ID:-adhoc}" >> "$APP_DIR/Contents/Resources/SOURCE.txt"
/usr/bin/codesign "${SIGN_ARGS[@]}" --entitlements "$ROOT_DIR/Resources/SwarmHub.entitlements" --identifier com.konrad.agentapp "$APP_DIR"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
if [[ ! -s "$APP_DIR/Contents/Resources/AppIcon.icns" ]]; then
  echo "ERROR: $APP_DIR lacks Contents/Resources/AppIcon.icns." >&2
  exit 1
fi
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
if [[ -n "${SWARMHUB_NOTARY_PROFILE:-}" ]]; then
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$SWARMHUB_NOTARY_PROFILE" --wait
  /usr/bin/xcrun stapler staple "$APP_DIR"
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
fi
echo "$ZIP_PATH"
