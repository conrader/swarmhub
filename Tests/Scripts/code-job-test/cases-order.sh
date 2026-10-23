# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Cases 1-6: agent order, fallback on limits and logins, and plain failures.

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
