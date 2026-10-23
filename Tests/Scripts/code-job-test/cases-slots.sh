# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Cases 7-9: the timeout, the SLOTS queue and stale lock reclaim.

# 7
case_7() {
new_case "timeout kills the tree (exit 124)" claude codex; mode claude tree; mode codex ok; with_control
t0=$(date +%s)
managed --bot jarvis --order claude,codex --timeout 1 --dir "$C/work" -- "$TASK"; RC=$?
took=$(( $(date +%s) - t0 ))
expect "exit 124 (got $RC)" [ "$RC" -eq 124 ]
# The agent sleeps 60 s: a run cut at its 1 s deadline ends within seconds, and 30 s still tells cut from uncut under load.
expect "stopped soon after 1 s (took ${took}s)" [ "$took" -lt 30 ]
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
n=0; while [ ! -f "$C/state/claude.slow" ] && ! over_limit && [ $n -lt 600 ]; do sleep 0.05; n=$((n + 1)); done; mode claude ok
job_to "$C/out2" "$C/err2" --task-id "$TASKID" --verify true --bot second --order claude --dir "$C/work" -- "$TASK" & P2=$!
n=0; while ! grep -q 'Waiting for a free coding slot' "$C/err2" 2>/dev/null && ! over_limit && [ $n -lt 600 ]; do sleep 0.05; n=$((n + 1)); done
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
