#!/bin/bash
set -euo pipefail
SWARMHUB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SWARMHUB_FIXTURE_DIR="$(mktemp -d /tmp/swarmhub-ios-fixture.XXXXXX)"
python3 "$SWARMHUB_ROOT/Apps/iOS/Fixtures/hermes_fixture.py" --port-file "$SWARMHUB_FIXTURE_DIR/port" > "$SWARMHUB_FIXTURE_DIR/server.log" 2>&1 &
SWARMHUB_FIXTURE_PID=$!
swarmhub_fixture_cleanup() {
  kill "$SWARMHUB_FIXTURE_PID" 2>/dev/null || true
  wait "$SWARMHUB_FIXTURE_PID" 2>/dev/null || true
  rm -rf "$SWARMHUB_FIXTURE_DIR"
}
trap swarmhub_fixture_cleanup EXIT
for _ in {1..100}; do
  [[ -f "$SWARMHUB_FIXTURE_DIR/port" ]] && break
  kill -0 "$SWARMHUB_FIXTURE_PID"
  sleep 0.05
done
export SWARMHUB_IOS_FIXTURE_URL="http://127.0.0.1:$(cat "$SWARMHUB_FIXTURE_DIR/port")"
swift test --package-path "$SWARMHUB_ROOT/Packages/SwarmHubCore"
