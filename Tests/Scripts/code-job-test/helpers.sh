# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Helpers every case uses: a fresh case layout, code-job runs, checks on output, log fields and job records.

# A fresh case: its own HOME, stub bin and work dir; $1 is the case name, then the stubs to put on PATH.
new_case() {
  NAME=$1; shift
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  mkdir -p "$C/home" "$C/bin" "$C/state" "$C/work"
  for n in "$@"; do cp "$ROOT/stub" "$C/bin/$n"; chmod 755 "$C/bin/$n"; done
  rm -f "$CTL_DIR/swarmctl"
  LOG=$C/home/.hermes/swarmhub/coding-jobs.log
  PROBLEMS=
}
mode() { echo "$2" > "$C/state/$1.mode"; }
# code-job with the case's HOME and PATH (stubs first, nothing from /usr/local or ~/.local); output in $C/out, $C/err.
# Use the POSIX true builtin: macOS has no /bin/true.
# Cases 1-16 supply trivial evidence; cases 17-22 set CASE_VERIFY to test evidence and cleanup.
# (No `VAR=x job` prefixes: bash's POSIX mode keeps them after a function call.)
job() { job_to "$C/out" "$C/err" "$@"; }
# A managed run: the fixture task id (accepted by the stub control interface) and an explicit trivial verifier,
# since a managed job never consults CODE_JOB_VERIFY.
managed() { job --task-id "$TASKID" --verify true "$@"; }
job_to() {
  out=$1 err=$2; shift 2
  if over_limit; then : > "$out"; echo "code-job-test: not started: over CODE_JOB_TEST_LIMIT" > "$err"; return 125; fi
  env HOME="$C/home" PATH="$C/bin:/usr/bin:/bin" STUB_STATE="$C/state" CODE_JOB_MODEL=synthetic-model CODE_JOB_REPORT="$C/work/REPORT.txt" CODE_JOB_POLL=0.2 CODE_JOB_TICK=0.25 CODE_JOB_VERIFY="${CASE_VERIFY-true}" ${CALLER_ENV:-} "$SH" "$JOB" "$@" > "$out" 2> "$err"
}
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
has() { grep -Fq -- "$2" "$1"; }
lacks() { ! grep -Fq -- "$2" "$1" 2>/dev/null; }
last_err() { tail -n 1 "${1:-$C/err}"; }
line_matches() { last_err "${3:-$C/err}" | grep -Eq -- "$1" || { PROBLEMS="$PROBLEMS; $2 (last line: $(last_err "${3:-$C/err}"))"; }; }
# Field $1 of log line $2 (1-based; TSV).
field() { sed -n "${2:-1}p" "$LOG" | awk -F '\t' -v f="$1" '{ print $f }'; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1)); else echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1)); fi
}


# The newest job record's field $1.
rec() { f=$(ls -td "$C"/home/.hermes/swarmhub/job-completions/job.* 2>/dev/null | head -n 1); cat "$f/$1" 2>/dev/null; }
git_repo() { command -v git >/dev/null 2>&1 || return 1; HOME="$C/home" git -C "$1" init -q && HOME="$C/home" git -C "$1" commit -q --allow-empty -m init; }
