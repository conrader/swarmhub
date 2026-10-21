#!/bin/sh
# Hermetic tests for Resources/Skills/swarmhub-coding/scripts/code-job: a temp HOME, stub `claude`/`codex` scripts
# first on PATH (no real CLI, no network). Run by CodeJobScriptTests under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/code-job-test.sh <path/to/code-job>     CODE_JOB_SH = the shell that runs code-job (default /bin/sh)
#   CODE_JOB_CASES="1 2 3"   only these cases (the Swift test runs shards in parallel); code-job gets short poll/tick values.

# Sends signals: run only inside an isolated PID namespace (Linux) or the macOS signal guard; see sim/ISOLATION.md.
/usr/bin/python3 -I -B "$(dirname "$0")/../../sim/sim_isolation.py" --check > /dev/null || exit 78  # absolute: PATH cannot fake it
JOB=${1:?usage: code-job-test.sh <path/to/code-job>}
SH=${CODE_JOB_SH:-/bin/sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/code-job-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
# Exercise the shipped coding scripts in an isolated layout. Managed wake/worker integration is covered by sim/;
# starting persistent recovery workers for these standalone CLI cases races the temporary HOME cleanup.
mkdir -p "$ROOT/skills/swarmhub-coding/scripts" || exit 1
cp "$JOB" "$ROOT/skills/swarmhub-coding/scripts/code-job" || exit 1
cp "$(dirname "$JOB")/completion-contract.py" "$ROOT/skills/swarmhub-coding/scripts/completion-contract.py" || exit 1
cp "$(dirname "$JOB")/scratch.py" "$ROOT/skills/swarmhub-coding/scripts/scratch.py" || exit 1
cp "$(dirname "$JOB")/verify-sandbox.py" "$ROOT/skills/swarmhub-coding/scripts/verify-sandbox.py" || exit 1
cp "$(dirname "$JOB")/verify_darwin.py" "$ROOT/skills/swarmhub-coding/scripts/verify_darwin.py" || exit 1
cp "$(dirname "$JOB")/verify_git.py" "$ROOT/skills/swarmhub-coding/scripts/verify_git.py" || exit 1
cp "$(dirname "$JOB")/verify_processes.py" "$ROOT/skills/swarmhub-coding/scripts/verify_processes.py" || exit 1
cp "$(dirname "$JOB")/verify_signals.py" "$ROOT/skills/swarmhub-coding/scripts/verify_signals.py" || exit 1
JOB=$ROOT/skills/swarmhub-coding/scripts/code-job
# Claude Code only runs for a managed task (--task-id) that the control interface's check-job accepted. The real
# check-job (owner gate for claude orders) is covered by sim/test_fixes6_policy.py; this stand-in accepts the fixture
# task so the CLI-level behaviour of a managed claude run stays testable here. Cases opt in with `with_control`.
CTL_DIR=$ROOT/skills/swarmhub-messages/scripts
cat > "$ROOT/swarmctl-stub" <<'CTL'
#!/usr/bin/env python3
import sys
command, *args = sys.argv[1:]
if command in ("plan", "model"):
    print(args[0])
elif command != "check-job":
    sys.exit(64)
CTL
TASKID=task.0123456789abcdef0123456789abcdef
with_control() { mkdir -p "$CTL_DIR" && cp "$ROOT/swarmctl-stub" "$CTL_DIR/swarmctl"; }
PASSED=0 FAILED=0
# Signals name only a live descendant of this shell (an empty, garbage or recycled pid must not be signalled).
. "$(dirname "$0")/own-pid.sh" || exit 1
TASK='Fix the failing test in calc.py'
# Synthetic identities must reach both setup git and the CLI subprocess, even on
# a fresh Mac with no gitconfig. Ignore host signing/hooks/identity configuration.
export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

cp "$(dirname "$0")/code-job-stub.sh" "$ROOT/stub" || exit 1

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

# 1
case_1() {
new_case "claude: direct run skipped for approval, managed owner-approved run ok" claude codex; mode claude ok; mode codex ok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "direct: exit 0 via codex (got $RC)" [ "$RC" -eq 0 ]
expect "direct: claude never started" [ ! -f "$C/state/claude.calls" ]
expect "direct: codex ran" has "$C/out" "codex did the work"
line_matches '^code-job: codex ok · waited 0s · ran [0-9]+s · peak [0-9]+ MB · skipped claude: approval$' "direct summary line"
expect "direct: log skipped claude: approval" [ "$(field 3)|$(field 7)|$(field 8)" = "codex|0|claude: approval" ]
job --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
expect "direct, claude only: exit 69 (got $RC)" [ "$RC" -eq 69 ]
expect "direct, claude only: never started" [ ! -f "$C/state/claude.calls" ]
# A task id without the control interface that checks it is not an approval either.
managed --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
expect "managed without control: exit 69 (got $RC)" [ "$RC" -eq 69 ]
expect "managed without control: never started" [ ! -f "$C/state/claude.calls" ]
with_control; rm -f "$LOG" "$C/state/codex.calls"
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "managed: exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "stdout streamed" has "$C/out" "claude did the work"
expect "stderr streamed" has "$C/err" "claude note on stderr"
line_matches '^code-job: claude ok · waited 0s · ran [0-9]+s · peak [0-9]+ MB$' "summary line"
expect "claude task" has "$C/state/claude.args" "$TASK"
expect "claude flags" has "$C/state/claude.args" "$(printf -- '--permission-mode\nacceptEdits\n--allowedTools\nRead,Edit,Write,Bash,Glob,Grep\n--model\nsynthetic-model\n--effort\nhigh\n--max-turns\n40\n--output-format\ntext')"
expect "cwd is --dir" [ "$(cat "$C/state/claude.pwd")" = "$(cd "$C/work" && pwd -P)" ]
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
expect "one log line" [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ]
expect "log time" [ -n "$(field 1 | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" ]
expect "log bot/agent/exit/skipped" [ "$(field 2)|$(field 3)|$(field 7)|$(field 8)" = "jarvis|claude|0|-" ]
expect "log has 8 fields" [ "$(awk -F '\t' '{ print NF }' "$LOG")" -eq 8 ]
expect "task never logged" lacks "$LOG" "calc.py"
expect "state dir 0700" [ "$(ls -ld "$C/home/.hermes/swarmhub" | cut -c1-10)" = "drwx------" ]
expect "slot released" [ -z "$(ls "$C/home/.hermes/swarmhub/slots")" ]
done_case
}

# 2
case_2() {
new_case "claude limit -> codex ok" claude codex; mode claude limit; mode codex ok; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "codex ran" has "$C/out" "codex did the work"
expect "codex flags" has "$C/state/codex.args" "$(printf 'exec\n--skip-git-repo-check\n-c\nsandbox_mode="workspace-write"\n-c\napproval_policy="never"\n--model\nsynthetic-model\n-c\nmodel_reasoning_effort="high"\n%s' "$TASK")"
expect "codex cwd" [ "$(cat "$C/state/codex.pwd")" = "$(cd "$C/work" && pwd -P)" ]
line_matches '^code-job: codex ok · waited 0s · ran [0-9]+s · peak [0-9]+ MB · skipped claude: limit$' "summary line"
expect "log agent codex, skipped claude: limit" [ "$(field 3)|$(field 7)|$(field 8)" = "codex|0|claude: limit" ]
done_case
}

# 3
case_3() {
new_case "claude missing -> codex" codex; mode codex ok; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
line_matches '^code-job: codex ok · .* · skipped claude: missing$' "summary line"
expect "log" [ "$(field 3)|$(field 8)" = "codex|claude: missing" ]
done_case
}

# 4
case_4() {
new_case "both limited -> exit 75 CODE_JOB_USE_DELEGATE" claude codex; mode claude limit; mode codex limit; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 75 (got $RC)" [ "$RC" -eq 75 ]
expect "delegate word is the last stdout line" [ "$(tail -n 1 "$C/out")" = "CODE_JOB_USE_DELEGATE" ]
line_matches '^code-job: hermes delegate · .* · skipped claude: limit, codex: limit$' "summary line"
expect "log" [ "$(field 3)|$(field 7)|$(field 8)" = "hermes|75|claude: limit, codex: limit" ]
done_case
}

# 5
case_5() {
new_case "not logged in -> skipped" claude codex; mode claude login; mode codex ok; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
line_matches '· skipped claude: login$' "claude login skipped"
mode codex login; mode claude ok; rm -f "$LOG"
managed --bot jarvis --order codex,claude --dir "$C/work" -- "$TASK"; RC=$?
expect "codex login → claude, exit 0 (got $RC)" [ "$RC" -eq 0 ]
line_matches '^code-job: claude ok · .* · skipped codex: login$' "codex login skipped"
done_case
}

# 6
case_6() {
new_case "plain failure returned without fallback" claude codex; mode claude fail; mode codex ok; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 3 as the agent's (got $RC)" [ "$RC" -eq 3 ]
expect "agent's error streamed" has "$C/err" "SyntaxError in calc.py"
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
expect "no delegate" lacks "$C/out" CODE_JOB_USE_DELEGATE
line_matches '^code-job: claude failed · waited 0s · ran [0-9]+s · peak [0-9]+ MB$' "summary line"
expect "log" [ "$(field 3)|$(field 7)|$(field 8)" = "claude|3|-" ]
done_case
}

# 7
case_7() {
new_case "timeout kills the tree (exit 124)" claude codex; mode claude tree; mode codex ok; with_control
t0=$(date +%s)
managed --bot jarvis --order claude,codex --timeout 1 --dir "$C/work" -- "$TASK"; RC=$?
took=$(( $(date +%s) - t0 ))
expect "exit 124 (got $RC)" [ "$RC" -eq 124 ]
expect "stopped soon after 1 s (took ${took}s)" [ "$took" -lt 10 ]
expect "agent pid gone" sh -c "! kill -0 $(cat "$C/state/claude.pid") 2>/dev/null"
expect "agent's child gone" sh -c "! kill -0 $(cat "$C/state/claude.child") 2>/dev/null"
expect "no fallback after a timeout" [ ! -f "$C/state/codex.calls" ]
line_matches '^code-job: claude timeout · ' "summary line"
expect "log" [ "$(field 3)|$(field 7)" = "claude|124" ]
done_case
}

# 8
case_8() {
new_case "SLOTS=1: second job waits, both finish" claude; mode claude slow; with_control
mkdir -p "$C/home/.hermes/swarmhub"; echo "SLOTS=1" > "$C/home/.hermes/swarmhub/coding.conf"
job_to "$C/out1" "$C/err1" --task-id "$TASKID" --verify true --bot first --order claude --dir "$C/work" -- "$TASK" & P1=$!
# The first holds the slot until the second has waited over a second (released here, not on a timer, so a loaded
# machine cannot let the first finish before the second asks); the second's own run is instant. The loops only bound a hang.
n=0; while [ ! -f "$C/state/claude.slow" ] && [ $n -lt 600 ]; do sleep 0.05; n=$((n + 1)); done; mode claude ok
job_to "$C/out2" "$C/err2" --task-id "$TASKID" --verify true --bot second --order claude --dir "$C/work" -- "$TASK" & P2=$!
n=0; while ! grep -q 'Waiting for a free coding slot' "$C/err2" 2>/dev/null && [ $n -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
sleep 1.2; : > "$C/state/release"
wait $P1; RC1=$?; wait $P2; RC2=$?
expect "both exit 0 ($RC1, $RC2)" [ "$RC1" -eq 0 ] && [ "$RC2" -eq 0 ]
expect "second said it waits" has "$C/err2" "Waiting for a free coding slot (1 in use)…"
expect "said once" [ "$(grep -c 'Waiting for a free coding slot' "$C/err2")" -eq 1 ]
expect "first did not wait" lacks "$C/err1" "Waiting for a free coding slot"
expect "two log lines" [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 2 ]
w2=$(awk -F '\t' '$2 == "second" { print $4 }' "$LOG")
expect "second's logged wait > 0 (got $w2)" [ "${w2:-0}" -gt 0 ]
line_matches "^code-job: claude ok · waited ${w2}s · " "second's summary carries its wait" "$C/err2"
expect "slots released" [ -z "$(ls "$C/home/.hermes/swarmhub/slots")" ]
done_case
}

# 9
case_9() {
new_case "stale lock is reclaimed" claude; mode claude ok; with_control
sh -c 'exit 0' & dead=$!; wait $dead
mkdir -p "$C/home/.hermes/swarmhub/slots/1.lock"; echo "$dead" > "$C/home/.hermes/swarmhub/slots/1.lock/pid"
# Bounded: a lock that is never reclaimed would make the job wait forever.
managed --bot jarvis --order claude --dir "$C/work" -- "$TASK" & P=$!
n=0; while kill -0 $P 2>/dev/null && [ $n -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
if own_pid "$P" && kill -0 "$P" 2>/dev/null; then pkill -P "$P" 2>/dev/null; kill "$P" 2>/dev/null; RC=timeout; else wait $P; RC=$?; fi
expect "exit 0 (got $RC)" [ "$RC" = 0 ]
expect "did not wait" lacks "$C/err" "Waiting for a free coding slot"
expect "logged wait 0" [ "$(field 4)" = 0 ]
expect "lock gone afterwards" [ ! -d "$C/home/.hermes/swarmhub/slots/1.lock" ]
done_case
}

# 10
case_10() {
new_case "claude.token passed as CLAUDE_CODE_OAUTH_TOKEN, never logged" claude; mode claude ok; with_control
mkdir -p "$C/home/.hermes/swarmhub"; printf 'sk-ant-oat01-P31-STUB-TOKEN' > "$C/home/.hermes/swarmhub/claude.token"; chmod 600 "$C/home/.hermes/swarmhub/claude.token"
managed --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "stub saw the token" has "$C/state/claude.env" "TOKEN=sk-ant-oat01-P31-STUB-TOKEN"
expect "not in the log" lacks "$LOG" "P31-STUB-TOKEN"
expect "not in stdout" lacks "$C/out" "P31-STUB-TOKEN"
expect "not in stderr" lacks "$C/err" "P31-STUB-TOKEN"
expect "token file still 0600" [ "$(ls -l "$C/home/.hermes/swarmhub/claude.token" | cut -c1-10)" = "-rw-------" ]
rm "$C/home/.hermes/swarmhub/claude.token"
managed --bot jarvis --order claude --dir "$C/work" -- "$TASK"
expect "no file, no variable" has "$C/state/claude.env" "TOKEN=unset"
done_case
}

# 11
case_11() {
new_case "ANTHROPIC_API_KEY from the caller is not visible to claude" claude; mode claude ok; with_control
CALLER_ENV=ANTHROPIC_API_KEY=fake-caller-value-for-this-test
managed --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
CALLER_ENV=
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "stub saw it unset" has "$C/state/claude.env" "ANTHROPIC_API_KEY=unset"
done_case
}

# 12
case_12() {
new_case "only agent skipped -> exit 69; hermes alone -> 75; bad usage -> 64" claude; mode claude limit; with_control
managed --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 69 (got $RC)" [ "$RC" -eq 69 ]
line_matches '^code-job: none failed · .* · skipped claude: limit$' "summary line"
job --bot jarvis --order hermes -- "$TASK"; RC=$?
expect "hermes alone exit 75 (got $RC)" [ "$RC" -eq 75 ] && has "$C/out" CODE_JOB_USE_DELEGATE
job --bot jarvis --order claude,gemini -- "$TASK"; RC=$?
expect "unknown agent exit 64 (got $RC)" [ "$RC" -eq 64 ]
job --bot jarvis --order claude; RC=$?
expect "no task exit 64 (got $RC)" [ "$RC" -eq 64 ]
done_case
}

# 13
case_13() {
new_case "task output with authentication/429 is returned as is" claude codex; mode claude taskwords; mode codex taskwords; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 2 (got $RC)" [ "$RC" -eq 2 ]
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
line_matches '^code-job: claude failed · ' "claude failed"
expect "nothing skipped" [ "$(field 8)" = "-" ]
done_case
}

# 14
case_14() {
new_case "limit phrase before the last 20 lines, or on exit 0, is not a limit" claude codex; mode claude early; mode codex early; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "claude early: exit 4 (got $RC)" [ "$RC" -eq 4 ]
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
mode claude limitok
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "limit words on exit 0: ok (got $RC)" [ "$RC" -eq 0 ]
line_matches '^code-job: claude ok · ' "claude ok"
rm -f "$C/bin/claude"; mode codex early
job --bot jarvis --order codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "codex early: exit 4 (got $RC)" [ "$RC" -eq 4 ]
done_case
}

# 15
case_15() {
new_case "codex's own phrases: limit and login fall back" codex; mode codex limit
job --bot jarvis --order codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "limit -> 75 (got $RC)" [ "$RC" -eq 75 ]
expect "skipped codex: limit" [ "$(field 8)" = "codex: limit" ]
mode codex login
job --bot jarvis --order codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "login -> 75 (got $RC)" [ "$RC" -eq 75 ]
expect "skipped codex: login" [ "$(field 8 2)" = "codex: login" ]
done_case
}

# 16
case_16() {
new_case "stderr-only output on exit 0 is empty work (65), even with a fresh report" claude codex; mode claude quiet; mode codex ok; with_control
managed --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 65 (got $RC)" [ "$RC" -eq 65 ]
expect "report was written" [ -s "$C/work/REPORT.txt" ]
expect "empty job reported" has "$C/err" "empty job or missing/empty/unchanged report"
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
done_case
}

# The newest job record's field $1.
rec() { f=$(ls -td "$C"/home/.hermes/swarmhub/job-completions/job.* 2>/dev/null | head -n 1); cat "$f/$1" 2>/dev/null; }
git_repo() { command -v git >/dev/null 2>&1 || return 1; HOME="$C/home" git -C "$1" init -q && HOME="$C/home" git -C "$1" commit -q --allow-empty -m init; }

# 17
case_17() {
new_case "fresh report and output but no commit and no verification: unverified (66)" codex; mode codex ok
CASE_VERIFY=; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 66 (got $RC)" [ "$RC" -eq 66 ]
expect "report was written" [ -s "$C/work/REPORT.txt" ]
expect "unverified reason on stderr" has "$C/err" "code-job: unverified: fresh report but no new commit and no passing verification"
expect "status unverified" [ "$(rec status)" = unverified ]
expect "evidence none" [ "$(rec evidence)" = none ]
expect "tests not-run" [ "$(rec tests-passed)" = not-run ]
expect "verify mode - when nothing ran" [ "$(rec verify-mode)" = - ]
expect "not a repo" [ "$(rec commit-evidence)" = not-a-repo ]
expect "report-valid true" [ "$(rec report-valid)" = true ]
expect "cli-exit 0" [ "$(rec cli-exit)" = 0 ]
expect "log exit 66" [ "$(field 7)" = 66 ]
line_matches '^code-job: codex unverified · ' "summary line"
done_case
}

# 18
case_18() {
new_case "a failing verification command is recorded and fails the job (66)" codex; mode codex ok
CASE_VERIFY='exit 3'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 66 (got $RC)" [ "$RC" -eq 66 ]
expect "verify exit 3" [ "$(rec verify-exit)" = 3 ]
expect "tests false" [ "$(rec tests-passed)" = false ]
expect "verify command recorded" [ "$(rec verify-command)" = 'exit 3' ]
expect "evidence none" [ "$(rec evidence)" = none ]
expect "verify exit on stderr" has "$C/err" "(verify exit 3)"
# An unavailable verifier must still fail closed (the macOS /bin/true failure).
# Keep the missing executable in the allowed workspace: this tests ENOENT (127),
# not a sandbox refusal to inspect an executable outside it (126 on macOS sh).
CASE_VERIFY='./missing-verifier'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "missing verification: 66 (got $RC)" [ "$RC" -eq 66 ]
expect "missing verify exit 127" [ "$(rec verify-exit)" = 127 ]
expect "missing verify tests false" [ "$(rec tests-passed)" = false ]
expect "missing verify evidence none" [ "$(rec evidence)" = none ]
done_case
}

# 19
case_19() {
new_case "a new commit in --dir is evidence (ok) and a failing verification outweighs it" codex; mode codex commit
if git_repo "$C/work"; then
  before=$(git -C "$C/work" rev-parse HEAD)
  CASE_VERIFY=; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
  expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
  expect "evidence commit" [ "$(rec evidence)" = commit ]
  expect "commit-evidence true" [ "$(rec commit-evidence)" = true ]
  expect "head-before recorded" [ "$(rec head-before)" = "$before" ]
  expect "head moved" [ "$(rec head-after)" = "$(git -C "$C/work" rev-parse HEAD)" ] && [ "$(rec head-after)" != "$before" ]
  expect "tests not-run" [ "$(rec tests-passed)" = not-run ]
  line_matches '^code-job: codex ok · ' "summary line"
  CASE_VERIFY='exit 5'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
  expect "commit plus failing verification: 66 (got $RC)" [ "$RC" -eq 66 ]
  expect "commit still recorded" [ "$(rec commit-evidence)" = true ]
  expect "evidence none" [ "$(rec evidence)" = none ]
else
  PROBLEMS="$PROBLEMS; git fixture initialization failed (commit evidence not exercised)"
fi
done_case
}

# 20
case_20() {
new_case "a passing verification command run by code-job in --dir is evidence (ok)" codex; mode codex ok
CASE_VERIFY='test -s REPORT.txt && pwd -P > verify.pwd'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "evidence tests" [ "$(rec evidence)" = tests ]
expect "tests true" [ "$(rec tests-passed)" = true ]
expect "verify exit 0" [ "$(rec verify-exit)" = 0 ]
expect "verify ran in --dir" [ "$(cat "$C/work/verify.pwd")" = "$(cd "$C/work" && pwd -P)" ]
expect "no verify output kept" [ ! -f "$C/home/.hermes/swarmhub/job-completions/verify" ]
# The launcher's isolation mode is part of the record (fixes7): a known word, written out of the verifier's reach.
vm=$(rec verify-mode)
case $vm in namespaced|fallback|seatbelt) ;; *) PROBLEMS="$PROBLEMS; verify mode recorded (got '$vm')" ;; esac
[ "$vm" = fallback ] && expect "limited mode said on stderr" has "$C/err" "verification ran in the limited sandbox"
[ "$vm" = fallback ] || expect "no limited-mode line when namespaced" lacks "$C/err" "limited sandbox"
mode codex quiet
CASE_VERIFY='true'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "empty work still 65 before any evidence (got $RC)" [ "$RC" -eq 65 ]
expect "evidence not collected" [ "$(rec evidence)" = none ] && [ "$(rec tests-passed)" = not-run ]
done_case
}

# 21
case_21() {
new_case "verification cannot remove the required report and still certify done" codex; mode codex ok
CASE_VERIFY='rm REPORT.txt'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?; unset CASE_VERIFY
expect "exit 65 (got $RC)" [ "$RC" -eq 65 ]
expect "report invalid after verification" [ "$(rec report-valid)" = false ]
expect "verification did run" [ "$(rec tests-passed)" = true ]
done_case
}

# 22
case_22() {
new_case "interrupting verification kills its child process" codex; mode codex ok
# The verifier runs in its own PID namespace on Linux, so its `$!` means nothing to the host: find the child by
# a unique argument. Zombies print as <defunct> and do not match.
sleepers() { ps -A -o args= 2>/dev/null | grep -c '^sleep 59\.37$'; }
CASE_VERIFY='sleep 59.37 & wait'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK" &
runner=$!
i=0; while [ "$(sleepers)" -eq 0 ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
expect "verification started" [ "$(sleepers)" -gt 0 ]
pid=$(cat "$C/home/.hermes/swarmhub/job-completions/"job.*/pid 2>/dev/null)
own_pid "$pid" "$JOB" && kill -TERM "$pid"
wait "$runner"; RC=$?; unset CASE_VERIFY
expect "exit 143 (got $RC)" [ "$RC" -eq 143 ]
i=0; while [ "$(sleepers)" -gt 0 ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
expect "verification child gone" [ "$(sleepers)" -eq 0 ]
expect "job interrupted" [ "$(rec status)" = interrupted ]
done_case
}

# 23
case_23() {
new_case "fallback through a symlinked parent: the physical report counts; an empty or unreadable one is 65, named" codex
# The Mac cj-home layout: --dir is HOME reached through a symlink, so launcher scratch falls back to /tmp and codex
# gets both tmp exclusions; the CLI writes the report at the physical path code-job hands it.
ln -s "$C/home" "$C/homelink"; P=$(cd "$C/home" && pwd -P)
mode codex ok
job --bot jarvis --order codex --dir "$C/homelink" --report REPORT.txt -- "$TASK"; RC=$?
expect "ok: exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "ok: report at the physical path" [ "$(rec report)" = "$P/REPORT.txt" ]
expect "ok: codex ran in the physical dir" [ "$(cat "$C/state/codex.pwd")" = "$P" ]
expect "ok: fallback /tmp exclusion" has "$C/state/codex.args" "sandbox_workspace_write.exclude_slash_tmp=true"
expect "ok: fallback TMPDIR exclusion" has "$C/state/codex.args" "sandbox_workspace_write.exclude_tmpdir_env_var=true"
expect "ok: report checked and kept" [ "$(rec report-valid)|$(rec report-state)|$(rec report-final)" = "true|ok|nonempty" ]
# mac-smoke3-533593b recorded exactly this: report-exists=true, report-sha256=missing-or-empty, exit 65.
mode codex emptyreport
job --bot jarvis --order codex --dir "$C/homelink" --report REPORT.txt -- "$TASK"; RC=$?
expect "empty: exit 65 (got $RC)" [ "$RC" -eq 65 ]
expect "empty: the Mac record" [ "$(rec report-exists)|$(rec report-sha256)|$(rec report-valid)" = "true|missing-or-empty|false" ]
expect "empty: named at check and finish" [ "$(rec report-state)|$(rec report-bytes)|$(rec report-final)" = "empty|0|empty" ]
# A report python3 cannot read is not "missing" (Python 3.14 folded such stat errors into is_file() == False).
if [ "$(id -u)" -ne 0 ]; then
  mode codex lockedreport
  job --bot jarvis --order codex --dir "$C/homelink" --report REPORT.txt -- "$TASK"; RC=$?
  chmod 600 "$C/home/REPORT.txt"
  expect "unreadable: exit 65 (got $RC)" [ "$RC" -eq 65 ]
  expect "unreadable: named, the shell still sees it" [ "$(rec report-state)|$(rec report-valid)|$(rec report-final)" = "unreadable-EACCES|false|nonempty" ]
fi
done_case
}

# 24
case_24() {
new_case "interrupted reads retry; exhausted process identities signal nothing"
# Exercise the shipped functions with deterministic empty reads, without sending real signals.
sed -n '/^now() {/,/^}/p; /^read_output() {/,/^}/p; /^tree_pids() {/,/^}/p; /^signalable() {/,/^}/p; /^kill_tree() {/,/^}/p' "$JOB" > "$C/functions"
cat > "$C/check-reads" <<'READS'
. "$1/functions"
C=$1
empty_then_value() {
  IFS= read -r n < "$C/count"
  n=$((n + 1)); echo "$n" > "$C/count"
  [ "$n" -lt 3 ] || printf '%s\n' "$*"
  return 0
}
echo 0 > "$C/count"
read_output empty_then_value 'a value with spaces' || exit 1
[ "$READ_OUTPUT" = 'a value with spaces' ] || exit 2
IFS= read -r n < "$C/count"; [ "$n" -eq 3 ] || exit 3
# Exhaustion clears an old value, and command errors retain their status without retrying.
empty() { echo x >> "$C/empty-calls"; return 0; }
read_output empty && exit 4
[ -z "$READ_OUTPUT" ] && [ "$(wc -l < "$C/empty-calls" | tr -d ' ')" -eq 5 ] || exit 5
failed() { echo x >> "$C/failed-calls"; return 17; }
read_output failed; rc=$?
[ "$rc" -eq 17 ] && [ "$(wc -l < "$C/failed-calls" | tr -d ' ')" -eq 1 ] || exit 6
date() { empty_then_value 123; }
echo 0 > "$C/count"; NOW=100
now; [ "$NOW" -eq 123 ] || exit 7
date() { return 0; }
now; [ "$NOW" -eq 123 ] || exit 8
kill() { printf '%s\n' "$*" >> "$C/kills"; }
sleep() { :; }
snapshot() { printf '%s\n' '1500000123 50 1500000123 1500000123 Wed Oct 21 12:00:00 2026' '1500000456 1500000123 1500000123 1500000123 Wed Oct 21 12:00:00 2026' end; }
tree() {
  IFS= read -r n < "$C/count"; n=$((n + 1)); echo "$n" > "$C/count"
  if [ "$n" -lt 3 ]; then printf '%s\n' '1500000123 50 1500000123 1500000123 Wed Oct 21 12:00:00 2026'; else snapshot; fi
  return 0
}
echo 0 > "$C/count"
kill_tree 1500000123
grep -qx -- '-TERM 1500000123 1500000456' "$C/kills" || exit 9
grep -qx -- '-KILL 1500000123 1500000456' "$C/kills" || exit 10
: > "$C/kills"
tree() { return 0; }
kill_tree 1500000123
[ ! -s "$C/kills" ] || exit 11
# A complete initial identity snapshot permits TERM; an empty post-TERM read must never use stale pids.
tree() { [ -s "$C/kills" ] || snapshot; return 0; }
kill_tree 1500000123
grep -qx -- '-TERM 1500000123 1500000456' "$C/kills" || exit 12
[ "$(wc -l < "$C/kills" | tr -d ' ')" -eq 1 ] || exit 13
: > "$C/kills"
tree() { printf '%s\n' '1500000123 50 1500000123 1500000123 Wed Oct 21 12:00:00 2026'; }
kill_tree 1500000123
[ ! -s "$C/kills" ] || exit 14
READS
"$SH" "$C/check-reads" "$C" > "$C/out" 2> "$C/err"; RC=$?
expect "read retries and identity refusal pass (got $RC)" [ "$RC" -eq 0 ]
done_case
}

for n in ${CODE_JOB_CASES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24}; do "case_$n"; done
echo "code-job tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
