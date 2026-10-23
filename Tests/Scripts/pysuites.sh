#!/bin/bash
# The Python suites (updater, sim) of a worktree, each in its own log that ends with the command's OWN exit code (no
# pipe between the command and $?). Exits with the first failing suite's code, 0 only when every suite passed: a
# failure is never masked by a later suite, a log line or the final echo (recsfix3).
#
#   bash Tests/Scripts/pysuites.sh <worktree> <log dir>
#   PYSUITES_RUNNER (optional): a wrapper each suite runs under as `SRC=<worktree> $PYSUITES_RUNNER bash -c <command>`,
#   in its own copy of the worktree (e.g. as sbtest in a PID namespace); without one, each runs in <worktree>.
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
run updater.log "python3 -B -m unittest discover -s Tests/Updater -p 'test_*.py'"
run sim.log "cd sim && python3 -B -m unittest discover -v -p 'test_*.py'"
exit "$status"
