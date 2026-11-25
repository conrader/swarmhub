#!/bin/bash
# From a logged-in macOS desktop, pass an output directory for the fixture PNGs.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo 'The visual fixture requires AppKit and WKWebView on macOS.' >&2
    exit 1
fi
shots=${1:-"$(mktemp -d)"}
mkdir -p "$shots"
export SWARMHUB_FIXTURE_SHOTS="$(cd "$shots" && pwd)"
swift test --filter TerminalViewportTests
swift test --filter ScheduleListFixtureTests
for image in terminal-24 terminal-resized routines-compact routines-expanded; do
    test -s "$SWARMHUB_FIXTURE_SHOTS/$image.png"
done
echo "Fixture screenshots in $SWARMHUB_FIXTURE_SHOTS"
