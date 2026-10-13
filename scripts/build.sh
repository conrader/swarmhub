#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DIR="/Applications/Xcode-16.2.0.app/Contents/Developer"
[[ -d "$XCODE_DIR" ]] || XCODE_DIR="/Applications/Xcode.app/Contents/Developer"
TOOLCHAIN="$XCODE_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK="$XCODE_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
cd "$ROOT_DIR"

# SWARMHUB_FORCE_SWIFTC=1 (or the older TORVLI_FORCE_SWIFTC=1) takes the swiftc fallback even when xcrun works, so both paths can be checked.
if [[ "${SWARMHUB_FORCE_SWIFTC:-${TORVLI_FORCE_SWIFTC:-}}" != "1" ]] && /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  swift build
else
  echo "Using the swiftc fallback ($XCODE_DIR)."
  KIT_DIR=.build/swiftc-kit
  mkdir -p .build/debug "$KIT_DIR" /tmp/agentapp-module-cache
  # The vendored BotAvatarsKit is its own Swift 5 module; the app stays Swift 6.
  "$TOOLCHAIN/usr/bin/swiftc" \
    -swift-version 5 -target arm64-apple-macosx14.0 -sdk "$SDK" -parse-as-library \
    -module-cache-path /tmp/agentapp-module-cache -module-name BotAvatarsKit \
    -emit-module -emit-module-path "$KIT_DIR/BotAvatarsKit.swiftmodule" \
    -emit-library -static -o "$KIT_DIR/libBotAvatarsKit.a" \
    $(find Vendor/BotAvatarsKit/Sources/BotAvatarsKit -name '*.swift' -print)
  "$TOOLCHAIN/usr/bin/swiftc" \
    -swift-version 6 -target arm64-apple-macosx14.0 -sdk "$SDK" \
    -module-cache-path /tmp/agentapp-module-cache -module-name AgentApp \
    -I "$KIT_DIR" -L "$KIT_DIR" -lBotAvatarsKit \
    -o .build/debug/AgentApp $(find Sources/AgentApp -name '*.swift' -print)
  mkdir -p .build/debug/AgentApp.resources
  rm -rf .build/debug/AgentApp.resources/Avatars
  cp -R Resources/Avatars .build/debug/AgentApp.resources/Avatars
fi
