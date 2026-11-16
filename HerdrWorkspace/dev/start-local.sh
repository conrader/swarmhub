#!/bin/sh
# Start the SwarmHub bridge against the Herdr Core already running for this user.
# Settings come from the environment; anything unset gets the default below.
set -eu

config="${XDG_CONFIG_HOME:-$HOME/.config}/swarmhub-herdr"
token_file="$config/token"
if [ ! -s "$token_file" ]; then
  mkdir -p "$config"
  chmod 700 "$config"
  (umask 077 && openssl rand -hex 32 >"$token_file")
fi

: "${HC_SOCKET:=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/herdr-core/default.sock}"
: "${SWARMHUB_PORT:=8787}"
: "${SWARMHUB_AGENT_CWD:=$HOME/swarmhub-agents}"
SWARMHUB_ACCESS_TOKEN="$(cat "$token_file")"
export HC_SOCKET SWARMHUB_PORT SWARMHUB_AGENT_CWD SWARMHUB_ACCESS_TOKEN

[ -S "$HC_SOCKET" ] || { echo "Herdr Core socket not found at $HC_SOCKET. Start Core or set HC_SOCKET." >&2; exit 1; }
mkdir -p "$SWARMHUB_AGENT_CWD"

echo "SwarmHub: http://127.0.0.1:$SWARMHUB_PORT"
echo "Access token: $token_file"
echo "Agents start in: $SWARMHUB_AGENT_CWD"
exec "${SWARMHUB_BRIDGE:-$HOME/.local/bin/swarmhub-herdr}"
