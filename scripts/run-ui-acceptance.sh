#!/bin/bash
set -euo pipefail

acceptance_repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$acceptance_repo_root"
if [[ "${SWARMHUB_UI_ACCEPTANCE:-}" != 1 ]]; then
  echo 'UI acceptance launch refused: explicitly set SWARMHUB_UI_ACCEPTANCE=1.' >&2
  exit 78
fi
# Reject conflicting configuration before building. Never silently scrub an unsafe request.
while IFS= read -r acceptance_name; do
  [[ "$acceptance_name" == SWARMHUB_UI_ACCEPTANCE ]] && continue
  [[ -z "${!acceptance_name}" ]] && continue
  case "$acceptance_name" in
    *[Hh][Ee][Rr][Mm][Ee][Ss]*|*[Cc][Oo][Mm][Pp][Oo][Ss][Ii][Oo]*|*[Oo][Pp][Ee][Nn][Cc][Ll][Aa][Ww]*|*[Kk][Ee][Yy][Cc][Hh][Aa][Ii][Nn]*|SWARMHUB_UI_ACCEPTANCE_*|SWARMHUB_QA_MODE)
      echo 'UI acceptance launch refused: remove Hermes, connector, Keychain and other QA configuration.' >&2
      exit 78 ;;
  esac
done < <(compgen -e)
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'UI acceptance requires a local Mac with Swift; no remote launch is supported.' >&2
  exit 2
fi
export SWARMHUB_BUILD_CONFIGURATION=debug
./scripts/build.sh
exec "$(cat .build/agentapp-bin-path)/AgentApp"
