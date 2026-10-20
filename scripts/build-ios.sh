#!/bin/bash
set -euo pipefail
SWARMHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${SWARMHUB_IOS_CONFIGURATION:-Debug}"
SDK="${SWARMHUB_IOS_SDK:-iphonesimulator}"
# P2c: the project's "Embed baseline" phase adds the signed baseline bundle only (iOS has no updater); Debug signs a TEST
# baseline, any other configuration needs SWARMHUB_BASELINE_DIR (real keys) and fails on TEST keys.
BASELINE_CONFIGURATION=release
[[ "$CONFIGURATION" != Debug ]] || BASELINE_CONFIGURATION=debug
python3 "$SWARMHUB_ROOT/scripts/generate-ios-project.py"
xcodebuild \
  -project "$SWARMHUB_ROOT/Apps/iOS/SwarmHub.xcodeproj" \
  -scheme SwarmHub \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  -destination "${SWARMHUB_IOS_DESTINATION:-generic/platform=iOS Simulator}" \
  -derivedDataPath "$SWARMHUB_ROOT/Apps/iOS/build" \
  CODE_SIGNING_ALLOWED=NO \
  "$@" build
# The built app carries the baseline and no bootstrap package.
python3 -B "$SWARMHUB_ROOT/scripts/release/check_baseline.py" --configuration "$BASELINE_CONFIGURATION" --ios \
  "$SWARMHUB_ROOT/Apps/iOS/build/Build/Products/$CONFIGURATION-$SDK/SwarmHub.app"
