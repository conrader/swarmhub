#!/bin/sh
# Hermetic tests for Resources/Skills/swarmhub-coding/scripts/code-job: a temp HOME, stub `claude`/`codex` scripts
# first on PATH (no real CLI, no network). Run by CodeJobScriptTests under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/code-job-test.sh <path/to/code-job>     CODE_JOB_SH = the shell that runs code-job (default /bin/sh)
#   CODE_JOB_CASES="1 2 3"   only these cases (the Swift test runs shards in parallel); code-job gets short poll/tick values.
#   CODE_JOB_TEST_LIMIT=300  fail the run if it is still going after this many seconds (below).
#   CODE_JOB_STUB=<file>     another stand-in claude/codex (code-job-limit-check.sh uses one that never returns).

# Sends signals: run only inside an isolated PID namespace (Linux) or the macOS signal guard; see sim/ISOLATION.md.
/usr/bin/python3 -I -B "$(dirname "$0")/../../sim/sim_isolation.py" --check > /dev/null || exit 78  # absolute: PATH cannot fake it
JOB=${1:?usage: code-job-test.sh <path/to/code-job>}
SH=${CODE_JOB_SH:-/bin/sh}
# The setup, helpers and cases live in code-job-test/ by theme; the case numbers are the same as before the split.
PARTS=$(dirname "$0")/code-job-test
. "$PARTS/setup.sh" || exit 1
. "$PARTS/helpers.sh" || exit 1
for part in order slots output evidence cleanup; do . "$PARTS/cases-$part.sh" || exit 1; done


for n in ${CODE_JOB_CASES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26}; do
  over_limit && break
  "case_$n"
done
if over_limit; then
  rm -f "$ROOT/swept"; n=0; while [ ! -f "$ROOT/swept" ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
  echo "FAIL: time limit: still running after ${CODE_JOB_TEST_LIMIT}s, in \"$NAME\"; no later case ran"; FAILED=$((FAILED + 1))
fi
echo "code-job tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
