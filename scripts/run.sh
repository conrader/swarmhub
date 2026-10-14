#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
./scripts/build.sh
exec "$(cat .build/agentapp-bin-path)/AgentApp"
