#!/bin/bash
set -euo pipefail
SWARMHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWARMHUB_SIMCTL="${SWARMHUB_SIMCTL:-$(xcode-select -p)/usr/bin/simctl}"
SWARMHUB_CAPTURE_APP="${SWARMHUB_CAPTURE_APP:-$SWARMHUB_ROOT/Apps/iOS/build/Build/Products/Debug-iphonesimulator/SwarmHub.app}"
SWARMHUB_CAPTURE_OUTPUT="${SWARMHUB_CAPTURE_OUTPUT:-$SWARMHUB_ROOT/docs/ios/screenshots}"
: "${SWARMHUB_CAPTURE_DEVICE:?Set SWARMHUB_CAPTURE_DEVICE to a dedicated, booted simulator UUID.}"
if [[ ! -d "$SWARMHUB_CAPTURE_APP" ]]; then
    echo "Build the Debug simulator app with ./scripts/build-ios.sh first." >&2
    exit 1
fi
mkdir -p "$SWARMHUB_CAPTURE_OUTPUT"
cleanup() { "$SWARMHUB_SIMCTL" terminate "$SWARMHUB_CAPTURE_DEVICE" com.konrad.swarmhub.ios >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$SWARMHUB_SIMCTL" install "$SWARMHUB_CAPTURE_DEVICE" "$SWARMHUB_CAPTURE_APP"
"$SWARMHUB_SIMCTL" status_bar "$SWARMHUB_CAPTURE_DEVICE" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
for theme in dark light; do
    if [[ "$theme" == dark ]]; then appearance=Dark; else appearance=Light; fi
    "$SWARMHUB_SIMCTL" ui "$SWARMHUB_CAPTURE_DEVICE" appearance "$theme"
    for screen in chats conversation approvals settings; do
        cleanup
        "$SWARMHUB_SIMCTL" launch "$SWARMHUB_CAPTURE_DEVICE" com.konrad.swarmhub.ios --capture-screen "$screen" --capture-appearance "$appearance"
        sleep 3
        "$SWARMHUB_SIMCTL" io "$SWARMHUB_CAPTURE_DEVICE" screenshot "$SWARMHUB_CAPTURE_OUTPUT/$screen-$theme.png"
    done
done
