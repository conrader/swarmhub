#!/bin/sh
# Hermetic tests for Resources/Skills/swarmhub-coding/scripts/code-job: a temp HOME, stub `claude`/`codex` scripts
# first on PATH (no real CLI, no network). Run by CodeJobScriptTests under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/code-job-test.sh <path/to/code-job>     CODE_JOB_SH = the shell that runs code-job (default /bin/sh)
#   CODE_JOB_CASES="1 2 3"   only these cases (the Swift test runs shards in parallel); code-job gets short poll/tick values.

JOB=${1:?usage: code-job-test.sh <path/to/code-job>}
SH=${CODE_JOB_SH:-/bin/sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/code-job-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
# Exercise the shipped coding scripts in an isolated layout. Managed wake/worker integration is covered by sim/;
# starting persistent recovery workers for these standalone CLI cases races the temporary HOME cleanup.
mkdir -p "$ROOT/skills/swarmhub-coding/scripts" || exit 1
cp "$JOB" "$ROOT/skills/swarmhub-coding/scripts/code-job" || exit 1
cp "$(dirname "$JOB")/completion-contract.py" "$ROOT/skills/swarmhub-coding/scripts/completion-contract.py" || exit 1
JOB=$ROOT/skills/swarmhub-coding/scripts/code-job
PASSED=0 FAILED=0
TASK='Fix the failing test in calc.py'

cat > "$ROOT/stub" <<'STUB'
#!/bin/sh
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
  slow) : > "$d/$me.slow"; while [ ! -f "$d/release" ]; do sleep 0.05; done; echo "$me slow done"; exit 0 ;;
  tree) sleep 60 & echo $! > "$d/$me.child"; sleep 60; exit 0 ;;
  commit) git add -A >/dev/null 2>&1 && git -c user.name=stub -c user.email=stub@example.invalid commit -qm "stub work" >/dev/null 2>&1; echo "$me committed"; exit 0 ;;
  *) echo "stub $me: no mode" >&2; exit 99 ;;
esac
STUB

# A fresh case: its own HOME, stub bin and work dir; $1 is the case name, then the stubs to put on PATH.
new_case() {
  NAME=$1; shift
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  mkdir -p "$C/home" "$C/bin" "$C/state" "$C/work"
  for n in "$@"; do cp "$ROOT/stub" "$C/bin/$n"; chmod 755 "$C/bin/$n"; done
  LOG=$C/home/.hermes/swarmhub/coding-jobs.log
  PROBLEMS=
}
mode() { echo "$2" > "$C/state/$1.mode"; }
# code-job with the case's HOME and PATH (stubs first, nothing from /usr/local or ~/.local); output in $C/out, $C/err.
# Cases 1-16 supply trivial evidence; cases 17-22 set CASE_VERIFY to test evidence and cleanup.
# (No `VAR=x job` prefixes: bash's POSIX mode keeps them after a function call.)
job() { job_to "$C/out" "$C/err" "$@"; }
job_to() {
  out=$1 err=$2; shift 2
  env HOME="$C/home" PATH="$C/bin:/usr/bin:/bin" STUB_STATE="$C/state" CODE_JOB_MODEL=synthetic-model CODE_JOB_REPORT="$C/work/REPORT.txt" CODE_JOB_POLL=0.2 CODE_JOB_TICK=0.25 CODE_JOB_VERIFY="${CASE_VERIFY-/bin/true}" ${CALLER_ENV:-} "$SH" "$JOB" "$@" > "$out" 2> "$err"
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
new_case "claude ok" claude codex; mode claude ok; mode codex ok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
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
new_case "claude limit -> codex ok" claude codex; mode claude limit; mode codex ok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
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
new_case "claude missing -> codex" codex; mode codex ok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
line_matches '^code-job: codex ok · .* · skipped claude: missing$' "summary line"
expect "log" [ "$(field 3)|$(field 8)" = "codex|claude: missing" ]
done_case
}

# 4
case_4() {
new_case "both limited -> exit 75 CODE_JOB_USE_DELEGATE" claude codex; mode claude limit; mode codex limit
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 75 (got $RC)" [ "$RC" -eq 75 ]
expect "delegate word is the last stdout line" [ "$(tail -n 1 "$C/out")" = "CODE_JOB_USE_DELEGATE" ]
line_matches '^code-job: hermes delegate · .* · skipped claude: limit, codex: limit$' "summary line"
expect "log" [ "$(field 3)|$(field 7)|$(field 8)" = "hermes|75|claude: limit, codex: limit" ]
done_case
}

# 5
case_5() {
new_case "not logged in -> skipped" claude codex; mode claude login; mode codex ok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
line_matches '· skipped claude: login$' "claude login skipped"
mode codex login; mode claude ok; rm -f "$LOG"
job --bot jarvis --order codex,claude --dir "$C/work" -- "$TASK"; RC=$?
expect "codex login → claude, exit 0 (got $RC)" [ "$RC" -eq 0 ]
line_matches '^code-job: claude ok · .* · skipped codex: login$' "codex login skipped"
done_case
}

# 6
case_6() {
new_case "plain failure returned without fallback" claude codex; mode claude fail; mode codex ok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
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
new_case "timeout kills the tree (exit 124)" claude codex; mode claude tree; mode codex ok
t0=$(date +%s)
job --bot jarvis --order claude,codex --timeout 1 --dir "$C/work" -- "$TASK"; RC=$?
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
new_case "SLOTS=1: second job waits, both finish" claude; mode claude slow
mkdir -p "$C/home/.hermes/swarmhub"; echo "SLOTS=1" > "$C/home/.hermes/swarmhub/coding.conf"
job_to "$C/out1" "$C/err1" --bot first --order claude --dir "$C/work" -- "$TASK" & P1=$!
# The first holds the slot until the second has waited over a second (released here, not on a timer, so a loaded
# machine cannot let the first finish before the second asks); the second's own run is instant. The loops only bound a hang.
n=0; while [ ! -f "$C/state/claude.slow" ] && [ $n -lt 600 ]; do sleep 0.05; n=$((n + 1)); done; mode claude ok
job_to "$C/out2" "$C/err2" --bot second --order claude --dir "$C/work" -- "$TASK" & P2=$!
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
new_case "stale lock is reclaimed" claude; mode claude ok
sh -c 'exit 0' & dead=$!; wait $dead
mkdir -p "$C/home/.hermes/swarmhub/slots/1.lock"; echo "$dead" > "$C/home/.hermes/swarmhub/slots/1.lock/pid"
# Bounded: a lock that is never reclaimed would make the job wait forever.
job --bot jarvis --order claude --dir "$C/work" -- "$TASK" & P=$!
n=0; while kill -0 $P 2>/dev/null && [ $n -lt 300 ]; do sleep 0.1; n=$((n + 1)); done
if kill -0 $P 2>/dev/null; then pkill -P $P 2>/dev/null; kill $P 2>/dev/null; RC=timeout; else wait $P; RC=$?; fi
expect "exit 0 (got $RC)" [ "$RC" = 0 ]
expect "did not wait" lacks "$C/err" "Waiting for a free coding slot"
expect "logged wait 0" [ "$(field 4)" = 0 ]
expect "lock gone afterwards" [ ! -d "$C/home/.hermes/swarmhub/slots/1.lock" ]
done_case
}

# 10
case_10() {
new_case "claude.token passed as CLAUDE_CODE_OAUTH_TOKEN, never logged" claude; mode claude ok
mkdir -p "$C/home/.hermes/swarmhub"; printf 'sk-ant-oat01-P31-STUB-TOKEN' > "$C/home/.hermes/swarmhub/claude.token"; chmod 600 "$C/home/.hermes/swarmhub/claude.token"
job --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "stub saw the token" has "$C/state/claude.env" "TOKEN=sk-ant-oat01-P31-STUB-TOKEN"
expect "not in the log" lacks "$LOG" "P31-STUB-TOKEN"
expect "not in stdout" lacks "$C/out" "P31-STUB-TOKEN"
expect "not in stderr" lacks "$C/err" "P31-STUB-TOKEN"
expect "token file still 0600" [ "$(ls -l "$C/home/.hermes/swarmhub/claude.token" | cut -c1-10)" = "-rw-------" ]
rm "$C/home/.hermes/swarmhub/claude.token"
job --bot jarvis --order claude --dir "$C/work" -- "$TASK"
expect "no file, no variable" has "$C/state/claude.env" "TOKEN=unset"
done_case
}

# 11
case_11() {
new_case "ANTHROPIC_API_KEY from the caller is not visible to claude" claude; mode claude ok
CALLER_ENV=ANTHROPIC_API_KEY=fake-caller-value-for-this-test
job --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
CALLER_ENV=
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "stub saw it unset" has "$C/state/claude.env" "ANTHROPIC_API_KEY=unset"
done_case
}

# 12
case_12() {
new_case "only agent skipped -> exit 69; hermes alone -> 75; bad usage -> 64" claude; mode claude limit
job --bot jarvis --order claude --dir "$C/work" -- "$TASK"; RC=$?
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
new_case "task output with authentication/429 is returned as is" claude codex; mode claude taskwords; mode codex taskwords
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 2 (got $RC)" [ "$RC" -eq 2 ]
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
line_matches '^code-job: claude failed · ' "claude failed"
expect "nothing skipped" [ "$(field 8)" = "-" ]
done_case
}

# 14
case_14() {
new_case "limit phrase before the last 20 lines, or on exit 0, is not a limit" claude codex; mode claude early; mode codex early
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "claude early: exit 4 (got $RC)" [ "$RC" -eq 4 ]
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
mode claude limitok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
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
new_case "stderr-only output on exit 0 is empty work (65), even with a fresh report" claude codex; mode claude quiet; mode codex ok
job --bot jarvis --order claude,codex,hermes --dir "$C/work" -- "$TASK"; RC=$?
expect "exit 65 (got $RC)" [ "$RC" -eq 65 ]
expect "report was written" [ -s "$C/work/REPORT.txt" ]
expect "empty job reported" has "$C/err" "empty job or missing/empty/unchanged report"
expect "codex not run" [ ! -f "$C/state/codex.calls" ]
done_case
}

# The newest job record's field $1.
rec() { f=$(ls -td "$C"/home/.hermes/swarmhub/job-completions/job.* 2>/dev/null | head -n 1); cat "$f/$1" 2>/dev/null; }
git_repo() { command -v git >/dev/null 2>&1 || return 1; git -C "$1" init -q && git -C "$1" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init; }

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
  echo "note: git missing, commit evidence not exercised" >&2
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
CASE_VERIFY='sleep 60 & echo $! > verify.child; wait'; job --bot jarvis --order codex --dir "$C/work" -- "$TASK" &
runner=$!
i=0; while [ ! -s "$C/work/verify.child" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
expect "verification started" [ -s "$C/work/verify.child" ]
pid=$(cat "$C/home/.hermes/swarmhub/job-completions/"job.*/pid 2>/dev/null)
[ -n "$pid" ] && kill -TERM "$pid"
wait "$runner"; RC=$?; unset CASE_VERIFY
expect "exit 143 (got $RC)" [ "$RC" -eq 143 ]
child=$(cat "$C/work/verify.child" 2>/dev/null)
state=$(ps -p "${child:-0}" -o stat= 2>/dev/null | tr -d ' ')
case $state in ''|Z*) ;; *) PROBLEMS="$PROBLEMS; verification child survived"; kill "$child" 2>/dev/null ;; esac
expect "job interrupted" [ "$(rec status)" = interrupted ]
done_case
}

for n in ${CODE_JOB_CASES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22}; do "case_$n"; done
echo "code-job tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
