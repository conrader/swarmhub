#!/bin/sh
# Stand-in `claude`/`codex` for Tests/Scripts/code-job-test.sh: records its argv, cwd and env in $STUB_STATE and
# behaves as $STUB_STATE/<name>.mode says. Copied into each case's bin directory under both names.
me=$(basename "$0") d=$STUB_STATE
echo $$ > "$d/$me.pid"
printf '%s\n' "$@" > "$d/$me.args"
pwd -P > "$d/$me.pwd"
{ echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY-unset}"; echo "TOKEN=${CLAUDE_CODE_OAUTH_TOKEN-unset}"; } > "$d/$me.env"
echo x >> "$d/$me.calls"
# The stub writes a fresh report for each invocation, like a real contracted CLI.
if [ -n "${SWARMHUB_REPORT_FILE:-}" ]; then printf '%s\n' "$$" > "$SWARMHUB_REPORT_FILE"; fi
case $(cat "$d/$me.mode" 2>/dev/null) in
  ok) echo "$me did the work"; echo "$me note on stderr" >&2; exit 0 ;;
  limit) if [ "$me" = claude ]; then echo "Claude AI usage limit reached|1760000000" >&2; else echo "ERROR: usage_limit_reached" >&2; fi; exit 1 ;;
  login) if [ "$me" = claude ]; then echo "Invalid API key · Please run /login"; else echo "Not logged in. Please run codex login"; fi; exit 1 ;;
  fail) echo "$me: SyntaxError in calc.py line 3" >&2; exit 3 ;;
  taskwords) echo "test_auth.py: authentication failed for user bob"; echo "GET /api -> 429 Too Many Requests" >&2; exit 2 ;;
  early) if [ "$me" = claude ]; then echo "Claude AI usage limit reached"; else echo "You've hit your usage limit"; fi
    i=0; while [ $i -lt 25 ]; do echo "build line $i"; i=$((i + 1)); done; exit 4 ;;
  limitok) echo "note: rate_limit_error and usage_limit_reached are handled in retry.py"; exit 0 ;;
  quiet) echo "$me: warning on stderr only" >&2; exit 0 ;;
  emptyreport) : > "$SWARMHUB_REPORT_FILE"; echo "$me did the work"; exit 0 ;;
  lockedreport) chmod 000 "$SWARMHUB_REPORT_FILE"; echo "$me did the work"; exit 0 ;;
  slow) : > "$d/$me.slow"; while [ ! -f "$d/release" ]; do sleep 0.05; done; echo "$me slow done"; exit 0 ;;
  tree) sleep 60 & echo $! > "$d/$me.child"; sleep 60; exit 0 ;;
  stubborn) ( trap '' TERM; exec sleep 60 ) & echo $! > "$d/$me.child"; sleep 60; exit 0 ;;
  commit) git add -A && git commit -qm "stub work" || exit 3; echo "$me committed"; exit 0 ;;
  *) echo "stub $me: no mode" >&2; exit 99 ;;
esac
