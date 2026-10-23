# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Cases 24-26: process identity reads and kill_tree retries at a deadline.

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
if over_limit; then RC=125; else "$SH" "$C/check-reads" "$C" > "$C/out" 2> "$C/err"; RC=$?; fi
expect "read retries and identity refusal pass (got $RC)" [ "$RC" -eq 0 ]
done_case
}

# 25
case_25() {
new_case "a refused identity read at a deadline is retried (agent 124, verifier 124)" claude codex; mode claude tree; mode codex ok; with_control
# A ps stand-in first on PATH prints nothing for the first identity read (`-o sess=`, what kill_tree uses), so the
# first kill_tree refuses. Each deadline must try again on the next tick instead of letting the 60 s sleep run out.
cat > "$C/bin/ps" <<'PS'
#!/bin/sh
case "$*" in *sess=*) mkdir "$STUB_STATE/ps-failed-once" 2>/dev/null && exit 0 ;; esac
exec /bin/ps "$@"
PS
chmod 755 "$C/bin/ps"
t0=$(date +%s)
managed --bot jarvis --order claude,codex --timeout 1 --dir "$C/work" -- "$TASK"; RC=$?
took=$(( $(date +%s) - t0 ))
expect "agent: shim refused one read" [ -d "$C/state/ps-failed-once" ]
expect "agent: exit 124 (got $RC)" [ "$RC" -eq 124 ]
expect "agent: stopped soon after 1 s despite a refused read (took ${took}s)" [ "$took" -lt 30 ]
expect "agent: refusal on the job's stderr" has "$C/err" "code-job: not signalling pid"
expect "agent pid gone" sh -c "! kill -0 $(cat "$C/state/claude.pid") 2>/dev/null"
expect "agent's child gone" sh -c "! kill -0 $(cat "$C/state/claude.child") 2>/dev/null"
rmdir "$C/state/ps-failed-once" 2>/dev/null
CALLER_ENV=CODE_JOB_VERIFY_TIMEOUT=1 CASE_VERIFY='sleep 60'; t0=$(date +%s)
job --bot jarvis --order codex --dir "$C/work" -- "$TASK"; RC=$?
took=$(( $(date +%s) - t0 )); CALLER_ENV=; unset CASE_VERIFY
expect "verifier: shim refused one read" [ -d "$C/state/ps-failed-once" ]
expect "verifier: exit 66 (got $RC)" [ "$RC" -eq 66 ]
expect "verifier: verify exit 124 (got $(rec verify-exit))" [ "$(rec verify-exit)" = 124 ]
expect "verifier: stopped soon after 1 s despite a refused read (took ${took}s)" [ "$took" -lt 30 ]
done_case
}

# 26
case_26() {
new_case "the root exits on TERM, its child ignores TERM and the next read is refused: the child is still killed" claude codex
mode claude stubborn; mode codex ok; with_control
# The shim passes the first identity read and refuses the second (the one before KILL), after TERM ended the root.
cat > "$C/bin/ps" <<'PS'
#!/bin/sh
case "$*" in *sess=*) mkdir "$STUB_STATE/ps-read-1" 2>/dev/null || { mkdir "$STUB_STATE/ps-failed-2" 2>/dev/null && exit 0; } ;; esac
exec /bin/ps "$@"
PS
chmod 755 "$C/bin/ps"
t0=$(date +%s)
managed --bot jarvis --order claude,codex --timeout 1 --dir "$C/work" -- "$TASK"; RC=$?
took=$(( $(date +%s) - t0 ))
expect "shim refused the read after TERM" [ -d "$C/state/ps-failed-2" ]
expect "exit 124 (got $RC)" [ "$RC" -eq 124 ]
expect "stopped soon after 1 s (took ${took}s)" [ "$took" -lt 30 ]
expect "agent pid gone" sh -c "! kill -0 $(cat "$C/state/claude.pid") 2>/dev/null"
expect "TERM-ignoring child gone" sh -c "! kill -0 $(cat "$C/state/claude.child") 2>/dev/null"
done_case
}
