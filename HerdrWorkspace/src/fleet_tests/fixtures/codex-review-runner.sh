#!/bin/sh
set -eu
[ "$(/bin/cat "$HOME/synthetic-login")" = fixture-login ]
[ -z "${COORDINATOR_FIXTURE_SENTINEL+x}" ]
[ "$1 $2 $3 $4 $5 $6 $7 $8" = 'exec --json --sandbox read-only --color never --skip-git-repo-check --output-last-message' ]
artifact="$9"
shift 9
[ "$*" = '--model gpt-6.1-sol -c model_reasoning_effort="medium" -' ]
printf '%s\n' 'fixture-private-diagnostic' >&2
printf '%s\n' started >> "$HOME/invocations"
printf '%s\n' '{"type":"thread.started","thread_id":"fixture-thread"}' '{"type":"turn.started"}'
umask 077
/bin/cat > "$artifact"
printf '%s' '{"model":"gpt-6.1-sol","effort":"high","cli_version":"fixture-1.0"}' > "${artifact%/*}/fixture-observed-runtime.json"
printf '%s\n' '{"type":"turn.completed"}'
