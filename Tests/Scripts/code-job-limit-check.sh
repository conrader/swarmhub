#!/bin/sh
# Makes the CODE_JOB_TEST_LIMIT watchdog of code-job-test.sh fire, and checks that it stops the whole run:
#   7  case 7 then case 1, limit 1 s: one code-job invocation, which obeys TERM.
#   5  case 5 then case 6, limit 4 s: two invocations. The stand-in agent never returns and code-job runs under a
#      shell that ignores TERM, so only KILL frees the first invocation; the second must then not start.
# Each run must fail with the time-limit line naming the case it cut, start no later case, end within 60 s (an uncut
# run does not end), and leave no code-job, and nothing else, from its own temp dir.
#
#   sh Tests/Scripts/code-job-limit-check.sh <path/to/code-job>     CODE_JOB_SH as for code-job-test.sh (default /bin/sh)
#
# Sends signals through code-job-test.sh: run it only where that may run (see sim/ISOLATION.md).
JOB=${1:?usage: code-job-limit-check.sh <path/to/code-job>}
SH=${CODE_JOB_SH:-/bin/sh}
DIR=$(cd "$(dirname "$0")" && pwd -P) || exit 1
W=$(mktemp -d "${TMPDIR:-/tmp}/code-job-limit.XXXXXX") || exit 1
trap 'rm -rf "$W"' EXIT
. "$DIR/own-pid.sh" || exit 1
# Never returns while code-job lives; leaves once its parent is gone (or after 2 min), so nothing is left behind.
cat > "$W/stuck-stub" <<'STUB'
#!/bin/sh
i=0; while kill -0 "$PPID" 2>/dev/null && [ $i -lt 600 ]; do sleep 0.2; i=$((i + 1)); done
STUB
printf '#!/bin/sh\ntrap "" TERM\nexec %s "$@"\n' "$SH" > "$W/term-deaf-sh" && chmod 755 "$W/term-deaf-sh" || exit 1
FAILED=0
# Processes whose command line names this check's temp dir (the pattern travels in the environment, not in argv).
mine() { ps -A -o args= 2>/dev/null | P="$W/" Q="$1" awk 'index($0, ENVIRON["P"]) && index($0, ENVIRON["Q"])' | wc -l | tr -d ' '; }

# check NAME LIMIT CASES SHELL STUB, then the patterns the output must contain (or, after a leading !, must not).
check() {
  name=$1 limit=$2 cases=$3 run_sh=$4 stub=$5; shift 5
  t0=$(date +%s)
  env TMPDIR="$W" CODE_JOB_SH="$run_sh" CODE_JOB_STUB="$stub" CODE_JOB_CASES="$cases" CODE_JOB_TEST_LIMIT="$limit" \
    "$SH" "$DIR/code-job-test.sh" "$JOB" > "$W/$name.out" 2>&1 &
  p=$!
  n=0; while kill -0 "$p" 2>/dev/null && [ $n -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
  if own_pid "$p" && kill -0 "$p" 2>/dev/null; then
    kill -TERM "$p"; wait "$p"; rc=hung
  else
    wait "$p"; rc=$?
  fi
  took=$(( $(date +%s) - t0 ))
  jobs_left=$(mine /skills/swarmhub-coding/scripts/code-job)
  sleep 3; any_left=$(mine /)
  problems=
  [ "$rc" = 1 ] || problems="$problems; exit $rc, not 1"
  [ "$took" -lt 60 ] || problems="$problems; took ${took}s"
  [ "$jobs_left" -eq 0 ] || problems="$problems; $jobs_left code-job processes left at exit"
  [ "$any_left" -eq 0 ] || problems="$problems; $any_left processes from its temp dir left 3 s later"
  for want in "$@"; do
    case $want in
      !*) ! grep -Fq -- "${want#!}" "$W/$name.out" || problems="$problems; has \"${want#!}\"" ;;
      *) grep -Fq -- "$want" "$W/$name.out" || problems="$problems; no \"$want\"" ;;
    esac
  done
  if [ -z "$problems" ]; then
    echo "ok: limit, case $name: exit $rc in ${took}s, nothing left"
  else
    echo "FAIL: limit, case $name:${problems#;}"; FAILED=$((FAILED + 1))
  fi
  sed 's/^/    /' "$W/$name.out"
}

# Case 7's own 1 s --timeout may beat the limit's TERM under load, so its checks may pass; case 1 must still not run.
check 7 1 "7 1" "$SH" "$DIR/code-job-stub.sh" \
  'FAIL: time limit: still running after 1s, in "timeout kills the tree (exit 124)"' \
  '!claude: direct run'
# Case 5's first invocation ends only by KILL (137); its second is refused before it starts (125); case 6 never runs.
check 5 4 "5 6" "$W/term-deaf-sh" "$W/stuck-stub" \
  'FAIL: not logged in -> skipped: exit 0 (got 137)' \
  'codex login → claude, exit 0 (got 125)' \
  'code-job-test: not started: over CODE_JOB_TEST_LIMIT' \
  'FAIL: time limit: still running after 4s, in "not logged in -> skipped"' \
  'code-job tests under '"$W/term-deaf-sh"': 0 passed, 2 failed'
echo "code-job limit checks under $SH: $FAILED failed"
[ "$FAILED" -eq 0 ]
