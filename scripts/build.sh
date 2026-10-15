#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DIR="/Applications/Xcode-16.2.0.app/Contents/Developer"
[[ -d "$XCODE_DIR" ]] || XCODE_DIR="/Applications/Xcode.app/Contents/Developer"
TOOLCHAIN="$XCODE_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK="$XCODE_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
cd "$ROOT_DIR"
source "$ROOT_DIR/scripts/sparkle-tools.sh"
BUILD_CONFIGURATION="${SWARMHUB_BUILD_CONFIGURATION:-debug}"
if [[ "$BUILD_CONFIGURATION" != debug && "$BUILD_CONFIGURATION" != release ]]; then
  echo "ERROR: SWARMHUB_BUILD_CONFIGURATION must be debug or release." >&2
  exit 1
fi

# SWARMHUB_FORCE_SWIFTC=1 (or the older TORVLI_FORCE_SWIFTC=1) takes the swiftc fallback even when xcrun works, so both paths can be checked.
if [[ "${SWARMHUB_FORCE_SWIFTC:-${TORVLI_FORCE_SWIFTC:-}}" != "1" ]] && /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  swift build --configuration "$BUILD_CONFIGURATION"
  BUILD_DIR="$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)"
  ensure_sparkle
else
  echo "Using the swiftc fallback ($XCODE_DIR)."
  ensure_sparkle
  BUILD_DIR="$ROOT_DIR/.build/$BUILD_CONFIGURATION"
  KIT_DIR=.build/swiftc-kit
  OPTIMIZATION=()
  [[ "$BUILD_CONFIGURATION" != release ]] || OPTIMIZATION=(-O)
  mkdir -p "$BUILD_DIR" "$KIT_DIR" /tmp/agentapp-module-cache
  # Compile shared code without xcrun/SwiftPM on the fallback path too.
  "$TOOLCHAIN/usr/bin/swiftc" \
    -swift-version 6 -target arm64-apple-macosx14.0 -sdk "$SDK" -parse-as-library \
    -I Packages/SwarmHubCore/Sources/CSQLite -module-name SwarmHubCore \
    -emit-module -emit-module-path "$KIT_DIR/SwarmHubCore.swiftmodule" \
    -emit-library -static -o "$KIT_DIR/libSwarmHubCore.a" \
    $(find Packages/SwarmHubCore/Sources/SwarmHubCore -name '*.swift' -print)
  # The vendored BotAvatarsKit is its own Swift 5 module; the app stays Swift 6.
  "$TOOLCHAIN/usr/bin/swiftc" \
    -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$SDK" -parse-as-library "${OPTIMIZATION[@]}" \
    -module-cache-path /tmp/agentapp-module-cache -module-name BotAvatarsKit \
    -emit-module -emit-module-path "$KIT_DIR/BotAvatarsKit.swiftmodule" \
    -emit-library -static -o "$KIT_DIR/libBotAvatarsKit.a" \
    $(find Vendor/BotAvatarsKit/Sources/BotAvatarsKit -name '*.swift' -print)
  "$TOOLCHAIN/usr/bin/swiftc" \
    -swift-version 6 -target arm64-apple-macosx14.0 -sdk "$SDK" "${OPTIMIZATION[@]}" \
    -module-cache-path /tmp/agentapp-module-cache -module-name AgentApp \
    -I "$KIT_DIR" -L "$KIT_DIR" -lBotAvatarsKit \
    -I Packages/SwarmHubCore/Sources/CSQLite -lSwarmHubCore -lsqlite3 \
    -F "${SPARKLE_FRAMEWORK:h}" -framework Sparkle \
    -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' \
    -Xlinker -rpath -Xlinker '@executable_path' \
    -o "$BUILD_DIR/AgentApp" $(find Sources/AgentApp -name '*.swift' -print)
  mkdir -p "$BUILD_DIR/AgentApp.resources"
  rm -rf "$BUILD_DIR/AgentApp.resources/Avatars"
  cp -R Resources/Avatars "$BUILD_DIR/AgentApp.resources/Avatars"
  rm -rf "$BUILD_DIR/AgentApp.resources/BotManager"
  cp -R Resources/BotManager "$BUILD_DIR/AgentApp.resources/BotManager"
  rm -rf "$BUILD_DIR/AgentApp.resources/Skills"
  cp -R Resources/Skills "$BUILD_DIR/AgentApp.resources/Skills"
  rm -rf "$BUILD_DIR/AgentApp.resources/ThemeIcons"
  cp -R Resources/AppIcon/ThemeIcons "$BUILD_DIR/AgentApp.resources/ThemeIcons"
  cp Resources/AppIcon/SwarmHub-dark.icns "$BUILD_DIR/AgentApp.resources/AppIcon-dark.icns"
fi
# Bare executable launches need the dynamic framework beside the binary too.
if [[ "$SPARKLE_FRAMEWORK" != "$BUILD_DIR/Sparkle.framework" ]]; then
  rm -rf "$BUILD_DIR/Sparkle.framework"
  /usr/bin/ditto "$SPARKLE_FRAMEWORK" "$BUILD_DIR/Sparkle.framework"
fi
printf '%s\n' "$BUILD_DIR" > "$ROOT_DIR/.build/agentapp-bin-path"
