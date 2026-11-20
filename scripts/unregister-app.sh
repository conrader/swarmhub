#!/bin/bash
# Clean up both an app and the Sparkle app nested inside the bundle before removing staging.
unregister_app() {
  local bundle="$1"
  local register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [[ -d "$bundle" && ! -L "$bundle" ]] || return 0
  "$register" -u "$bundle" >/dev/null 2>&1 || true
  local updater="$bundle/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
  if [[ -d "$updater" ]]; then "$register" -u "$updater" >/dev/null 2>&1 || true; fi
}
