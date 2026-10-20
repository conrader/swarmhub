#!/bin/bash
# P7c snapshot parity on iOS: run the shared SDUI suites of SwarmHubCore (render goldens, action goldens, router,
# interaction, decoder, view source) on an iOS simulator. `swift test` runs the same suites on macOS; both must pass.
set -euo pipefail
SWARMHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SWARMHUB_ROOT/Packages/SwarmHubCore"
xcodebuild test \
  -scheme SwarmHubCore \
  -destination "${SWARMHUB_IOS_TEST_DESTINATION:-platform=iOS Simulator,name=iPhone 16 Pro}" \
  -derivedDataPath "$SWARMHUB_ROOT/.build/ios-core-tests" \
  -only-testing:SwarmHubCoreTests/SDUIRenderTreeTests \
  -only-testing:SwarmHubCoreTests/SDUIActionGoldenTests \
  -only-testing:SwarmHubCoreTests/SDUIInteractionTests \
  -only-testing:SwarmHubCoreTests/SDUIActionRouterTests \
  -only-testing:SwarmHubCoreTests/SDUIDecoderTests \
  -only-testing:SwarmHubCoreTests/SDUIViewSourceTests \
  CODE_SIGNING_ALLOWED=NO \
  "$@"
