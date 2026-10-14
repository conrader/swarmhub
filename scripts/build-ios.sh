#!/bin/bash
set -euo pipefail
SWARMHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$SWARMHUB_ROOT/scripts/generate-ios-project.py"
xcodebuild \
  -project "$SWARMHUB_ROOT/Apps/iOS/SwarmHub.xcodeproj" \
  -scheme SwarmHub \
  -configuration "${SWARMHUB_IOS_CONFIGURATION:-Debug}" \
  -sdk "${SWARMHUB_IOS_SDK:-iphonesimulator}" \
  -destination "${SWARMHUB_IOS_DESTINATION:-generic/platform=iOS Simulator}" \
  -derivedDataPath "$SWARMHUB_ROOT/Apps/iOS/build" \
  CODE_SIGNING_ALLOWED=NO \
  "$@" build
