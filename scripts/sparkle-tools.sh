#!/bin/zsh
# Shared by build, key setup and appcast generation. Keep the pin in sync with Package.swift.
SPARKLE_VERSION=2.10.0
SPARKLE_SHA256=17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959
SPARKLE_KEY_ACCOUNT=com.konrad.agentapp

ensure_sparkle() {
  local candidate
  for candidate in "$ROOT_DIR/.build/artifacts/sparkle/Sparkle" "$ROOT_DIR/.build/sparkle-$SPARKLE_VERSION"; do
    if [[ -d "$candidate/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" && -x "$candidate/bin/generate_appcast" ]]; then
      SPARKLE_DIR="$candidate"
      SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
      return
    fi
  done

  # The direct compiler fallback cannot use SwiftPM to fetch the binary dependency.
  local staging
  mkdir -p "$ROOT_DIR/.build"
  staging="$(mktemp -d "$ROOT_DIR/.build/sparkle-download.XXXXXX")"
  if ! curl --fail --location --silent --show-error --retry 2 \
    "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip" \
    -o "$staging/sparkle.zip"; then
    rm -rf "$staging"
    return 1
  fi
  if [[ "$(shasum -a 256 "$staging/sparkle.zip" | awk '{print $1}')" != "$SPARKLE_SHA256" ]]; then
    echo "ERROR: Sparkle download checksum mismatch." >&2
    rm -rf "$staging"
    return 1
  fi
  /usr/bin/ditto -x -k "$staging/sparkle.zip" "$staging/unpacked"
  SPARKLE_DIR="$ROOT_DIR/.build/sparkle-$SPARKLE_VERSION"
  mv "$staging/unpacked" "$SPARKLE_DIR"
  rm -rf "$staging"
  SPARKLE_FRAMEWORK="$SPARKLE_DIR/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
}
