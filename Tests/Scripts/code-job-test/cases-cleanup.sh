# Part of Tests/Scripts/code-job-test.sh, which sources it; not a runnable script by itself.
# Cases 24-31: process identity reads, kill_tree retries at a deadline or an interrupt, late forks and the retry cap.

# 24
case_24() {
new_case "interrupted reads retry; exhausted process identities signal nothing"
# Exercise the shipped functions with deterministic empty reads, without sending real signals.
sed -n '/^now() {/,/^}/p; /^read_output() {/,/^}/p; /^tree_pids() {/,/^}/p; /^signalable() {/,/^}/p; /^kill_tree() {/,/^}/p; /^kill_cap() {/,/^}/p' "$JOB" > "$C/functions"
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

# 27
case_27() {
new_case "every identity read after TERM is refused: retries stop at the cap, nothing unverified is signalled, the pids are named" claude codex
mode claude tree; mode codex ok; with_control
# The shim passes the first identity read (TERM goes out, and the agent and its child exit on it) and refuses every
# later one, so code-job can never confirm the tree is gone. It must give up at the cap and say which pids it read.
cat > "$C/bin/ps" <<'PS'
#!/bin/sh
case "$*" in *sess=*) mkdir "$STUB_STATE/ps-read-1" 2>/dev/null || exit 0 ;; esac
exec /bin/ps "$@"
PS
chmod 755 "$C/bin/ps"
t0=$(date +%s)
managed --bot jarvis --order claude,codex --timeout 1 --dir "$C/work" -- "$TASK"; RC=$?
took=$(( $(date +%s) - t0 ))
agent=$(cat "$C/state/claude.pid") child=$(cat "$C/state/claude.child")
expect "exit 124 (got $RC)" [ "$RC" -eq 124 ]
expect "retries ended at the cap (took ${took}s)" [ "$took" -lt 60 ]
expect "gave up on stderr" has "$C/err" "code-job: gave up on the tree of pid $agent"
left=" $(rec cleanup-incomplete) "
expect "record names the agent (got '$left')" sh -c 'case $1 in " $2:"*" $2 "*) exit 0 ;; esac; exit 1' - "$left" "$agent"
expect "record names the agent's child (got '$left')" sh -c 'case $1 in *" $2 "*) exit 0 ;; esac; exit 1' - "$left" "$child"
line_matches "cleanup incomplete" "summary line names the incomplete cleanup"
expect "agent pid gone (it exited on TERM)" sh -c "! kill -0 $agent 2>/dev/null"
expect "agent's child gone (it exited on TERM)" sh -c "! kill -0 $child 2>/dev/null"
done_case
}

# 28
case_28() {
new_case "children forked after a read are caught: an orphan's new child, and a fork between the read and KILL"
# The shipped functions against a scripted process table; signals are recorded, never sent.
sed -n '/^tree() {/,/^}/p; /^tree_pids() {/,/^}/p; /^signalable() {/,/^}/p; /^kill_tree() {/,/^}/p; /^kill_cap() {/,/^}/p' "$JOB" > "$C/functions"
cat > "$C/check-forks" <<'FORKS'
. "$1/functions"
C=$1
kill() { printf '%s\n' "$*" >> "$C/kills"; }
row() { printf '%s %s 700 800 Wed Oct 21 12:00:0%s 2026\n' "$1" "$2" "${3:-0}"; }
# 1. TERM ends the root, the read before KILL is refused, then the orphaned child forks: the next call must walk it.
phase=initial
sleep() { case $phase in initial) phase=unreadable ;; esac; }
ps() {
  [ "$phase" != unreadable ] || return 0
  row 1 0; row $$ 1
  if [ "$phase" = initial ]; then row 1500000001 $$; row 1500000002 1500000001
  else row 1500000002 1; row 1500000003 1500000002 1; fi
}
kill_tree 1500000001
[ -n "$KILL_LEFT" ] || exit 1
phase=orphan
kill_tree 1500000001
grep -qx -- '-KILL 1500000002 1500000003' "$C/kills" || exit 2
[ -z "$KILL_LEFT" ] || exit 3
# 2. The child forks after the read that would have preceded KILL: a later read lists the new child, which is KILLed.
: > "$C/kills"; KILL_ROOT=; echo 0 > "$C/reads"
sleep() { :; }
ps() {
  n=$(cat "$C/reads"); n=$((n + 1)); echo "$n" > "$C/reads"
  row 1 0; row $$ 1; row 1500000011 $$; row 1500000012 1500000011
  [ "$n" -le 2 ] || row 1500000013 1500000012 1
}
kill_tree 1500000011
grep -qx -- '-TERM 1500000011 1500000012' "$C/kills" || exit 4
grep -qx -- '-KILL 1500000011 1500000012 1500000013' "$C/kills" || exit 5
# Nothing is KILLed before every listed process is stopped and a read finds nothing new.
awk '$1 == "-KILL" { k = NR } $1 == "-STOP" && / 1500000013/ { s = NR } END { exit !(s && k > s) }' "$C/kills" || exit 6
[ -z "$KILL_LEFT" ] || exit 7
FORKS
if over_limit; then RC=125; else "$SH" "$C/check-forks" "$C" > "$C/out" 2> "$C/err"; RC=$?; fi
expect "late children are caught (got $RC; signals: $(tr '\n' ',' < "$C/kills" 2>/dev/null))" [ "$RC" -eq 0 ]
done_case
}

# 29
case_29() {
new_case "an interrupted job retries refused identity reads: the agent and its child are still gone" claude codex
mode claude tree; mode codex ok; with_control
# interrupted() reads the watchdog's tree first, then the agent's: the shim refuses both first reads.
cat > "$C/bin/ps" <<'PS'
#!/bin/sh
case "$*" in *sess=*) mkdir "$STUB_STATE/ps-failed-1" 2>/dev/null && exit 0; mkdir "$STUB_STATE/ps-failed-2" 2>/dev/null && exit 0 ;; esac
exec /bin/ps "$@"
PS
chmod 755 "$C/bin/ps"
managed --bot jarvis --order claude,codex --timeout 60 --dir "$C/work" -- "$TASK" &
runner=$!
i=0; while [ ! -s "$C/state/claude.child" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
expect "agent started" [ -s "$C/state/claude.child" ]
pid=$(cat "$C/home/.hermes/swarmhub/job-completions/"job.*/pid 2>/dev/null)
own_pid "$pid" "$JOB" && kill -TERM "$pid"
wait "$runner"; RC=$?
agent=$(cat "$C/state/claude.pid") child=$(cat "$C/state/claude.child")
expect "exit 143 (got $RC)" [ "$RC" -eq 143 ]
expect "shim refused two reads" [ -d "$C/state/ps-failed-2" ]
i=0; while { kill -0 "$agent" 2>/dev/null || kill -0 "$child" 2>/dev/null; } && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
expect "agent pid gone" sh -c "! kill -0 $agent 2>/dev/null"
expect "agent's child gone" sh -c "! kill -0 $child 2>/dev/null"
expect "job interrupted" [ "$(rec status)" = interrupted ]
done_case
}

# 30
case_30() {
new_case "identity reads that alternate between good and refused still end the retries at the cap"
sed -n '/^tree() {/,/^}/p; /^tree_pids() {/,/^}/p; /^signalable() {/,/^}/p; /^kill_tree() {/,/^}/p; /^kill_cap() {/,/^}/p' "$JOB" > "$C/functions"
cat > "$C/check-alternating" <<'ALT'
. "$1/functions"
C=$1 T=$1/t
mkdir -p "$T"
kill() { printf '%s\n' "$*" >> "$C/kills"; }
sleep() { :; }
# Every odd read lists the root and its child; every even read (the one before KILL) is refused.
echo 0 > "$C/reads"
ps() {
  n=$(cat "$C/reads"); n=$((n + 1)); echo "$n" > "$C/reads"
  [ $((n % 2)) -eq 1 ] || return 0
  printf '%s 700 800 Wed Oct 21 12:00:00 2026\n' "1 0" "$$ 1" "1500000021 $$" "1500000022 1500000021"
}
calls=1; kill_tree 1500000021
while [ -n "$KILL_LEFT" ] && [ "$calls" -lt 200 ]; do kill_tree 1500000021; calls=$((calls + 1)); done
[ "$calls" -le 30 ] || exit 1
! grep -q -- '^-KILL' "$C/kills" || exit 2
grep -qx -- '1500000021: 1500000021 1500000022' "$T/cleanup-incomplete" || exit 3
ALT
if over_limit; then RC=125; else "$SH" "$C/check-alternating" "$C" > "$C/out" 2> "$C/err"; RC=$?; fi
expect "alternating reads end at the cap, named (got $RC)" [ "$RC" -eq 0 ]
expect "gave up on stderr" has "$C/err" "code-job: gave up on the tree of pid 1500000021"
done_case
}

# 31
case_31() {
new_case "interrupted after the agent exited: the watchdog's identity read still leads to its TERM-ignoring child" claude codex
mode claude stubborn; mode codex ok; with_control
# The shim passes the first identity read (the watchdog TERMs the agent, which exits; its child ignores TERM), then
# refuses reads, slowly, so the watchdog keeps retrying, until the test interrupts code-job; from then on reads pass.
# Only the watchdog's cached identities lead from the exited agent to its orphan.
cat > "$C/bin/ps" <<'PS'
#!/bin/sh
case "$*" in *sess=*) [ -e "$STUB_STATE/reads-ok" ] || mkdir "$STUB_STATE/ps-read-1" 2>/dev/null || { : > "$STUB_STATE/refused"; sleep 0.5; exit 0; } ;; esac
exec /bin/ps "$@"
PS
chmod 755 "$C/bin/ps"
managed --bot jarvis --order claude,codex --timeout 1 --dir "$C/work" -- "$TASK" &
runner=$!
i=0; while [ ! -e "$C/state/refused" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
agent=$(cat "$C/state/claude.pid") child=$(cat "$C/state/claude.child")
i=0; while kill -0 "$agent" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
expect "a read was refused after TERM" [ -e "$C/state/refused" ]
expect "agent exited on TERM" sh -c "! kill -0 $agent 2>/dev/null"
expect "its child was still there" sh -c "kill -0 $child 2>/dev/null"
: > "$C/state/reads-ok"
pid=$(cat "$C/home/.hermes/swarmhub/job-completions/"job.*/pid 2>/dev/null)
own_pid "$pid" "$JOB" && kill -TERM "$pid"
wait "$runner"; RC=$?
expect "exit 143 (got $RC)" [ "$RC" -eq 143 ]
i=0; while kill -0 "$child" 2>/dev/null && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
expect "TERM-ignoring child gone" sh -c "! kill -0 $child 2>/dev/null"
done_case
}
