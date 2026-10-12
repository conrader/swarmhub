#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
XCODE_DIR="/Applications/Xcode-16.2.0.app/Contents/Developer"
TOOLCHAIN="$XCODE_DIR/Toolchains/XcodeDefault.xctoolchain"
SDK="$XCODE_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX15.2.sdk"
cd "$ROOT_DIR"

if /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
  swift build
else
  echo "xcrun is unavailable; using the Xcode 16.2 compiler directly."
  mkdir -p .build/debug /tmp/agentapp-module-cache
  "$TOOLCHAIN/usr/bin/swiftc" \
    -swift-version 6 -target arm64-apple-macosx14.0 -sdk "$SDK" \
    -module-cache-path /tmp/agentapp-module-cache -module-name AgentApp \
    -o .build/debug/AgentApp $(find Sources/AgentApp -name '*.swift' -print)
  mkdir -p .build/debug/AgentApp.resources
  rm -rf .build/debug/AgentApp.resources/Avatars
  cp -R Resources/Avatars .build/debug/AgentApp.resources/Avatars
fi
