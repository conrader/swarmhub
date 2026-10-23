# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Cases 10-16: credentials, usage errors and how CLI output is classified.

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
