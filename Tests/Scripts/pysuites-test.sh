#!/bin/bash
# pysuites.sh must exit non-zero when any suite fails, whichever it is, with the failing suite's own code; 0 only when
# all pass. The suites are stubs: a PYSUITES_RUNNER that exits with the code set for the suite it was handed, and a
# python3 on PATH for the run without a runner. No real suite runs, nothing leaves the temp directory.
#
#   bash Tests/Scripts/pysuites-test.sh [pysuites.sh under test]     (default: the one next to this file)
set -u
here=$(cd "$(dirname "$0")" && pwd)
script=$(cd "$(dirname "${1:-$here/pysuites.sh}")" && pwd)/$(basename "${1:-$here/pysuites.sh}")
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
fails=0
mkdir -p "$tmp/src/sim" "$tmp/src/Tests/Updater" "$tmp/bin"
# The runner stub: the sim suite's command has `cd sim`; anything else is the updater suite.
cat > "$tmp/runner.sh" <<'STUB'
#!/bin/bash
case "$*" in *"cd sim"*) exit "${SIM_EXIT:-0}" ;; *) exit "${UPDATER_EXIT:-0}" ;; esac
STUB
# The python3 stub for the run without a runner: in sim/ it is the sim suite.
cat > "$tmp/bin/python3" <<'STUB'
#!/bin/bash
case "$PWD" in */sim) exit "${SIM_EXIT:-0}" ;; *) exit "${UPDATER_EXIT:-0}" ;; esac
STUB
chmod +x "$tmp/runner.sh" "$tmp/bin/python3"

check() {  # check <name> <expected: 0|nonzero|N> <updater exit> <sim exit> [runner]
    local name=$1 want=$2 dir=$tmp/case-$1 code
    mkdir -p "$dir"
    cp "$script" "$dir/pysuites.sh"
    cp "$tmp/runner.sh" "$dir/sbrun.sh"  # Where the round-2 evidence script looks for its runner.
    UPDATER_EXIT=$3 SIM_EXIT=$4 PYSUITES_RUNNER=${5:-} PATH="$tmp/bin:$PATH" bash "$dir/pysuites.sh" "$tmp/src" "$dir/logs" > "$dir/out" 2>&1
    code=$?
    case "$want" in
        nonzero) [ "$code" -ne 0 ] ;;
        *) [ "$code" -eq "$want" ] ;;
    esac && { echo "ok   $name (exit $code)"; return; }
    echo "FAIL $name: exit $code, want $want"; sed 's/^/     /' "$dir/out"; fails=$((fails + 1))
}

check all-pass 0 0 0 "$tmp/runner.sh"
check sim-fails 3 0 3 "$tmp/runner.sh"
check updater-fails-sim-passes 1 1 0 "$tmp/runner.sh"
check both-fail-first-code 4 4 1 "$tmp/runner.sh"
check killed-suite 137 0 137 "$tmp/runner.sh"
check no-runner-sim-fails nonzero 0 1
check no-runner-all-pass 0 0 0
[ "$fails" -eq 0 ] && echo "PYSUITES TEST: PASS" || echo "PYSUITES TEST: FAIL ($fails)"
[ "$fails" -eq 0 ]
