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
rm -rf "$APP_DIR/Contents/MacOS/AgentApp.resources" "$APP_DIR/Contents/Resources/Avatars" "$APP_DIR/Contents/Resources/ThemeIcons"
cp -R "$ROOT_DIR/Resources/Avatars" "$APP_DIR/Contents/Resources/Avatars"
# The Icon Composer icon, as Assets.car (CFBundleIconName = AppIcon): macOS 26 and later draw the app's icon from it in
# the Default, Dark, Clear and Tinted icon styles. Without it macOS darkens the icns itself on a Mac with dark icons.
# actool also writes an AppIcon.icns of its own; the iconset's icns below replaces it.
/usr/bin/xcrun actool "$ROOT_DIR/Resources/AppIcon/AppIcon.icon" --compile "$APP_DIR/Contents/Resources" --platform macosx --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$ROOT_DIR/.build/appicon-partial.plist" >/dev/null
# P23: the app icon for macOS before 26 (CFBundleIconFile = AppIcon in Info.plist), with its own 16 and 32 px drawings.
/usr/bin/iconutil -c icns "$ROOT_DIR/Resources/AppIcon/AppIcon.iconset" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
# P38: the light and dark Dock icons AppIconAppearance picks at run time (the icns stays the light Finder fallback).
cp -R "$ROOT_DIR/Resources/AppIcon/ThemeIcons" "$APP_DIR/Contents/Resources/ThemeIcons"
# P38 E: the dark icon as an icns too (AppIconAppearance's fallback when the dark PNG cannot be read).
/usr/bin/iconutil -c icns "$ROOT_DIR/Resources/AppIcon/AppIcon-dark.iconset" -o "$APP_DIR/Contents/Resources/AppIcon-dark.icns"
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
# "-" signs ad-hoc on purpose and asks the Keychain nothing (a rehearsal, or a build over SSH).
SIGN_ID="${SWARMHUB_SIGN_IDENTITY:-${TORVLI_SIGN_IDENTITY:-}}"
if [[ -z "$SIGN_ID" ]]; then
  SIGN_ID="$(/usr/bin/security find-identity -v -p codesigning | awk -F'"' '/"Apple Development: / {print $2; exit}')"
fi
if [[ -z "$SIGN_ID" ]]; then
  echo "WARNING: no Apple Development identity found; signing ad-hoc. Keychain keys will not survive rebuilds." >&2
  SIGN_ID="-"
elif [[ "$SIGN_ID" != - ]] && ! /usr/bin/security show-keychain-info "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "ERROR: login keychain is locked; unlock it and rerun (not falling back to ad-hoc)." >&2
  exit 1
fi
SIGN_ARGS=(--force --sign "$SIGN_ID")
if [[ "$SIGN_ID" != - ]]; then
  SIGN_ARGS+=(--options runtime --timestamp)
fi
# The app binary and bundle are signed with SwarmHub.entitlements, which claims nothing: the app needs no entitlement under the hardened runtime.
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
if [[ ! -s "$APP_DIR/Contents/Resources/Assets.car" ]]; then
  echo "ERROR: $APP_DIR lacks Contents/Resources/Assets.car (the Icon Composer icon)." >&2
  exit 1
fi
# P38 E: the dark Dock icon (both forms) and the light runtime image.
for ICON in AppIcon-dark.icns ThemeIcons/SwarmHub-light.png ThemeIcons/SwarmHub-dark.png; do
  if [[ ! -s "$APP_DIR/Contents/Resources/$ICON" ]]; then
    echo "ERROR: $APP_DIR lacks Contents/Resources/$ICON." >&2
    exit 1
  fi
done
rm -f "$ZIP_PATH"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
# Notarization signs in with a Keychain profile, or with an App Store Connect API key file (no Keychain needed).
NOTARY_ARGS=()
if [[ -n "${SWARMHUB_NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$SWARMHUB_NOTARY_PROFILE")
elif [[ -n "${SWARMHUB_NOTARY_KEY:-}" ]]; then
  NOTARY_ARGS=(--key "$SWARMHUB_NOTARY_KEY" --key-id "${SWARMHUB_NOTARY_KEY_ID:?set SWARMHUB_NOTARY_KEY_ID}" --issuer "${SWARMHUB_NOTARY_ISSUER:?set SWARMHUB_NOTARY_ISSUER}")
fi
if (( ${#NOTARY_ARGS[@]} )); then
  /usr/bin/xcrun notarytool submit "$ZIP_PATH" "${NOTARY_ARGS[@]}" --wait
  /usr/bin/xcrun stapler staple "$APP_DIR"
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ZIP_PATH"
fi
echo "$ZIP_PATH"
