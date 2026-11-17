#!/bin/bash
# The Python tests of a worktree: every scripts/test_*.py (the Grok Bot export tools and the Sparkle configuration), in
# one log that ends with the command's OWN exit code (no pipe between the command and $?). Exits with that code, 0 only
# when the tests passed: a failure is never masked by a log line or the final echo.
#
#   bash Tests/Scripts/pysuites.sh <worktree> <log dir>
#   PYSUITES_RUNNER (optional): a wrapper the suite runs under as `SRC=<worktree> $PYSUITES_RUNNER bash -c <command>`,
#   in its own copy of the worktree; without one, it runs in <worktree>.
set -u
src=${1:?usage: pysuites.sh <worktree> <log dir>}
logs=${2:?usage: pysuites.sh <worktree> <log dir>}
mkdir -p "$logs" || exit 2
status=0
run() {
    local log=$logs/$1 code
    shift
    if [ -n "${PYSUITES_RUNNER:-}" ]; then
        SRC=$src "$PYSUITES_RUNNER" bash -c "$*" > "$log" 2>&1
    else
        (cd "$src" && bash -c "$*") > "$log" 2>&1
    fi
    code=$?
    echo "exit=$code" >> "$log"
    echo "$log exit=$code"
    if [ "$code" -ne 0 ] && [ "$status" -eq 0 ]; then status=$code; fi
}
# An empty list fails rather than letting unittest discover everything.
run scripts.log "mods=\$(cd scripts && ls test_*.py | sed 's/\.py\$//') && [ -n \"\$mods\" ] && PYTHONPATH=scripts python3 -B -m unittest \$mods"
exit "$status"
