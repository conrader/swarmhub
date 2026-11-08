#!/bin/bash
# The Python suites (updater, sim, release, isolation, ops, scripts) of a worktree, each in its own log that ends with the command's OWN exit code (no
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
# The release scripts' suites, among them the bundle layout's pins against the bundled skill versions (backlog8).
run release.log "python3 -B -m unittest discover -s scripts -p 'test_release_*.py'"
# The suites that no log ran before backlog9. Isolation and ops need the sbtest PID namespace like sim; ops starts a
# temporary nginx (/usr/sbin). scripts.log is every other scripts/test_*.py, except test_ios_approval_boundary.py,
# which needs the git history a runner copy does not have. An empty list fails rather than letting unittest discover
# everything. Tests/SwapJobs (pytest) and ops/jobroute/tests (run-sandbox.sh, needs ~/sb) run outside pysuites.
run isolation.log "python3 -B -m unittest discover -s Tests/Isolation -p 'test_*.py'"
run ops.log "PATH=\$PATH:/usr/sbin python3 -B -m unittest discover -s Tests/Ops -p 'test_*.py'"
run scripts.log "mods=\$(cd scripts && ls test_*.py | grep -v -e '^test_release_' -e '^test_ios_approval_boundary\.py\$' | sed 's/\.py\$//') && [ -n \"\$mods\" ] && PYTHONPATH=scripts python3 -B -m unittest \$mods"
exit "$status"
