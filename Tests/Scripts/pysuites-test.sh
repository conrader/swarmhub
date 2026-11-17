#!/bin/bash
# pysuites.sh must exit non-zero when the suite fails, with the suite's own code; 0 only when it passes. The suite is a
# stub: a PYSUITES_RUNNER that exits with the code set for it, and a python3 on PATH for the run without a runner. No
# real test runs, nothing leaves the temp directory.
#
#   bash Tests/Scripts/pysuites-test.sh [pysuites.sh under test]     (default: the one next to this file)
set -u
here=$(cd "$(dirname "$0")" && pwd)
script=$(cd "$(dirname "${1:-$here/pysuites.sh}")" && pwd)/$(basename "${1:-$here/pysuites.sh}")
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
fails=0
mkdir -p "$tmp/src/scripts" "$tmp/bin"
: > "$tmp/src/scripts/test_stub.py"  # scripts.log needs a test to list.
printf '#!/bin/bash\nexit "${SCRIPTS_EXIT:-0}"\n' > "$tmp/runner.sh"
printf '#!/bin/bash\nexit "${SCRIPTS_EXIT:-0}"\n' > "$tmp/bin/python3"
chmod +x "$tmp/runner.sh" "$tmp/bin/python3"

check() {  # check <name> <expected: 0|nonzero|N> <suite exit> [runner]
    local name=$1 want=$2 dir=$tmp/case-$1 code
    mkdir -p "$dir"
    cp "$script" "$dir/pysuites.sh"
    SCRIPTS_EXIT=$3 PYSUITES_RUNNER=${4:-} PATH="$tmp/bin:$PATH" bash "$dir/pysuites.sh" "$tmp/src" "$dir/logs" > "$dir/out" 2>&1
    code=$?
    case "$want" in
        nonzero) [ "$code" -ne 0 ] ;;
        *) [ "$code" -eq "$want" ] ;;
    esac && grep -q "^exit=$code\$" "$dir/logs/scripts.log" && { echo "ok   $name (exit $code)"; return; }
    echo "FAIL $name: exit $code, want $want"; sed 's/^/     /' "$dir/out"; fails=$((fails + 1))
}

check all-pass 0 0 "$tmp/runner.sh"
check suite-fails 9 9 "$tmp/runner.sh"
check killed-suite 137 137 "$tmp/runner.sh"
check no-runner-all-pass 0 0
check no-runner-suite-fails 9 9
# No test to list: scripts.log fails instead of running a bare `unittest` (whole-tree discovery).
rm "$tmp/src/scripts/test_stub.py"
check no-runner-empty-list nonzero 0
[ "$fails" -eq 0 ] && echo "PYSUITES TEST: PASS" || echo "PYSUITES TEST: FAIL ($fails)"
[ "$fails" -eq 0 ]
