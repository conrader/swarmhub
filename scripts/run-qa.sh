#!/bin/bash
set -euo pipefail

qa_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$qa_repo_root"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'QA mode requires a local Mac with Swift; no remote launch is supported.' >&2
  exit 2
fi
if [[ -z "${SWARMHUB_QA_HERMES_URL:-}" || -z "${SWARMHUB_QA_HERMES_TOKEN:-}" ]]; then
  echo 'Set SWARMHUB_QA_HERMES_URL and SWARMHUB_QA_HERMES_TOKEN for the isolated real Hermes QA gateway.' >&2
  exit 2
fi
export SWARMHUB_BUILD_CONFIGURATION=debug
./scripts/build.sh
export SWARMHUB_QA_MODE=1
export SWARMHUB_QA_SOURCE_COMMIT="$(git rev-parse HEAD)"
export SWARMHUB_QA_SOURCE_DIRTY="$(if [[ -n "$(git status --porcelain)" ]]; then echo true; else echo false; fi)"
exec "$(cat .build/agentapp-bin-path)/AgentApp"
