#!/bin/zsh
set -euo pipefail
unsetopt bgnice
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PORT="${HERMES_FIXTURE_PORT:-18643}"
if [[ -n "${HERMES_TEST_PYTHON:-}" ]]; then
  PYTHON_BIN="$HERMES_TEST_PYTHON"
elif [[ -x /private/tmp/hermes-test/venv/bin/python ]]; then
  PYTHON_BIN=/private/tmp/hermes-test/venv/bin/python
else
  PYTHON_BIN="$(command -v python3)"
fi
SERVER_PID=""
trap '[[ -n "$SERVER_PID" ]] && kill $SERVER_PID 2>/dev/null || true' EXIT

run_fixture() {
  local mode="$1" fixture_port="$2"
  "$PYTHON_BIN" "$ROOT_DIR/Tests/Fixtures/hermes_v0.21.7_server.py" "$fixture_port" "$mode" &
  SERVER_PID=$!
  sleep 0.3
  if [[ "$mode" == native ]]; then
    AGENTAPP_HERMES_INTEGRATION=1 HERMES_TEST_FIXTURE=native HERMES_TEST_CANCEL=1 HERMES_TEST_URL="http://127.0.0.1:$fixture_port/v1" HERMES_TEST_KEY=fixture "$ROOT_DIR/.build/debug/AgentApp"
  else
    AGENTAPP_HERMES_INTEGRATION=1 HERMES_TEST_FIXTURE=legacy HERMES_TEST_URL="http://127.0.0.1:$fixture_port/v1" HERMES_TEST_KEY=fixture "$ROOT_DIR/.build/debug/AgentApp"
  fi
  kill $SERVER_PID 2>/dev/null || true
  wait $SERVER_PID 2>/dev/null || true
  SERVER_PID=""
}

run_fixture native "$PORT"
run_fixture legacy "$((PORT + 1))"
