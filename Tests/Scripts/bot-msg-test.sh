#!/bin/sh
# Hermetic tests for Resources/Skills/swarmhub-messages/scripts/bot-msg: a temp HOME with synthetic profiles and a stub
# gateway (bot-msg-stub-gateway.py on 127.0.0.1, python3 -I). No real Hermes, no network. Run by BotMessageScriptTests
# under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/bot-msg-test.sh <path/to/bot-msg>     BOT_MSG_SH = the shell that runs bot-msg (default /bin/sh)
#
# Exit 77 = skipped (one "SKIP:" line, no cases run): python3 cannot open a loopback socket, so neither the stub
# gateway nor bot-msg's curl could run (a sandbox that denies socket(2) with EPERM; seen in a review sandbox,
# 2026-10-19). That is the environment, not bot-msg; any other gateway start failure is still a FAIL.

# Sends signals: run only inside an isolated PID namespace (Linux) or the macOS signal guard; see sim/ISOLATION.md.
/usr/bin/python3 -I -B "$(dirname "$0")/../../sim/sim_isolation.py" --check > /dev/null || exit 78  # absolute: PATH cannot fake it
MSG=${1:?usage: bot-msg-test.sh <path/to/bot-msg>}
SH=${BOT_MSG_SH:-/bin/sh}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/bot-msg-test.XXXXXX") || exit 1
GW=
trap '[ -n "$GW" ] && kill "$GW" 2>/dev/null && wait "$GW" 2>/dev/null; rm -rf "$ROOT"' EXIT
PASSED=0 FAILED=0
KEY_INFRA=sk-infra-7f3a9c1e5b2d4086
KEY_DEFAULT=sk-default-0c9e8d7f6a5b4c3d
KEY_JARVIS=sk-jarvis-1a2b3c4d5e6f7a8b

# Preflight (not a case): skip, don't fail, when no loopback socket can be opened here (see the header).
PREFLIGHT=$(python3 -I -c 'import errno, socket, sys
try:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        s.listen(1)
except OSError as e:
    sys.exit(77 if e.errno in (errno.EPERM, errno.EACCES) else 1)
print("ok")' 2>&1)
PREFLIGHT_STATUS=$?
case "$PREFLIGHT_STATUS" in
  77) echo "SKIP: bot-msg tests under $SH: permission denied opening a loopback socket"; exit 77 ;;
  0) [ "$PREFLIGHT" = ok ] || { echo "FAIL: bot-msg preflight returned no valid socket result"; exit 1; } ;;
  *) echo "FAIL: bot-msg preflight failed (exit $PREFLIGHT_STATUS)"; exit 1 ;;
esac

# One stub gateway for every case; each case resets its state.
mkdir -p "$ROOT/gw"
printf 'infra %s\ndefault %s\njarvis %s\n' "$KEY_INFRA" "$KEY_DEFAULT" "$KEY_JARVIS" > "$ROOT/gw/keys"
python3 -I "$HERE/bot-msg-stub-gateway.py" "$ROOT/gw" 2> "$ROOT/gw/stderr" &
GW=$!
i=0
while [ ! -s "$ROOT/gw/port" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
PORT=$(cat "$ROOT/gw/port" 2>/dev/null)
[ -n "$PORT" ] || { echo "FAIL: stub gateway did not start: $(cat "$ROOT/gw/stderr")"; exit 1; }
GATEWAY=http://127.0.0.1:$PORT

# A fresh case: its own HOME with profiles infra (key), jarvis (key), nokey (no key) and a default profile.
new_case() {
  NAME=$1
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  H=$C/home/.hermes
  mkdir -p "$H/profiles/infra" "$H/profiles/jarvis" "$H/profiles/nokey"
  printf 'OPENROUTER_API_KEY=other\nAPI_SERVER_KEY=%s\n' "$KEY_INFRA" > "$H/profiles/infra/.env"
  printf 'API_SERVER_KEY="%s"\n' "$KEY_JARVIS" > "$H/profiles/jarvis/.env"
  printf 'API_SERVER_ENABLED=true\n' > "$H/profiles/nokey/.env"
  printf 'export API_SERVER_KEY=%s\r\n' "$KEY_DEFAULT" > "$H/.env"
  LOG=$H/swarmhub/bot-messages.log
  rm -f "$ROOT/gw/requests" "$ROOT"/gw/input.* "$ROOT/gw/release" "$ROOT/gw/answered"
  echo ok > "$ROOT/gw/mode"; : > "$ROOT/gw/reset"
  GWURL=$GATEWAY
  PROBLEMS=
}
mode() { echo "$1" > "$ROOT/gw/mode"; }
# Ends a slow reply's hold and waits until the gateway has let it go (the loop only bounds a hang).
release() { : > "$ROOT/gw/release"; i=0; while [ ! -e "$ROOT/gw/answered" ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done; }
# bot-msg with the case's HOME and a minimal PATH; output in $C/out, $C/err, exit code in RC.
msg() { msg_with "$MSG" "$@"; }
msg_with() {
  script=$1; shift
  if [ -n "$GWURL" ]; then
    env -i HOME="$C/home" PATH=/usr/bin:/bin TMPDIR="$ROOT" SWARMHUB_GATEWAY="$GWURL" "$SH" "$script" --priority "$@" > "$C/out" 2> "$C/err"
  else
    env -i HOME="$C/home" PATH=/usr/bin:/bin TMPDIR="$ROOT" "$SH" "$script" --priority "$@" > "$C/out" 2> "$C/err"
  fi
  RC=$?
}
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
# Waits (bounded) until the follow-up logged its late-reply line and removed its folder.
wait_late() {
  i=0; while ! grep -q 'late-reply' "$LOG" 2>/dev/null && [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  i=0; while [ -n "$(ls -d "$ROOT"/bot-msg-late.* 2>/dev/null)" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
}
# Waits (bounded) until a held reply was let go and its folder is gone.
wait_released() {
  i=0; while [ ! -e "$ROOT/gw/answered" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  i=0; while [ -n "$(ls -d "$ROOT"/bot-msg-late.* 2>/dev/null)" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
}
has() { grep -Fq -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -Fq -- "$2" "$1" 2>/dev/null; }
requests() { cat "$ROOT/gw/requests" 2>/dev/null; }
count() { grep -c -- "$1" "$ROOT/gw/requests" 2>/dev/null || true; }
# Field $1 of log line $2 (1-based; TSV).
field() { sed -n "${2:-1}p" "$LOG" | awk -F '\t' -v f="$1" '{ print $f }'; }
no_key_anywhere() {
  for f in "$C/out" "$C/err" "$LOG"; do
    for k in "$KEY_INFRA" "$KEY_DEFAULT" "$KEY_JARVIS"; do lacks "$f" "$k" || PROBLEMS="$PROBLEMS; a key in $(basename "$f")"; done
  done
}
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1)); else echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1)); fi
}

# 1
new_case "wait: reply printed, thread From jarvis created, header line first"
msg --from jarvis --to infra -- 'Is the disk on /data above 80%?'
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
expect "reply decoded" has "$C/out" 'Hi from infra: Zażółć ✓ "done"'
expect "reply second line" has "$C/out" 'line two'
expect "deltas not doubled" lacks "$C/out" 'partial'
expect "session created under /p/infra" has "$ROOT/gw/requests" 'POST /p/infra/api/sessions ok 201 title=From jarvis id=swarmhub-from-jarvis source=api_server'
expect "chat to that session" has "$ROOT/gw/requests" 'POST /p/infra/api/sessions/swarmhub-from-jarvis/chat/stream ok 200 known=True'
expect "input starts with the header line" [ "$(head -n 1 "$ROOT/gw/input.1")" = '[Message from jarvis via SwarmHub]' ]
expect "input carries the text" [ "$(sed -n 2p "$ROOT/gw/input.1")" = 'Is the disk on /data above 80%?' ]
no_key_anywhere
done_case

# 2
new_case "thread reuse: the second message goes to the same From jarvis session"
msg --from jarvis --to infra -- 'first'
msg --from jarvis --to infra -- 'second'
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "created once" [ "$(count ' 201 title=From jarvis')" -eq 1 ]
expect "409 the second time" [ "$(count ' 409 title=From jarvis id=swarmhub-from-jarvis')" -eq 1 ]
expect "both chats in swarmhub-from-jarvis" [ "$(count 'api/sessions/swarmhub-from-jarvis/chat/stream ok 200')" -eq 2 ]
expect "second input" [ "$(sed -n 2p "$ROOT/gw/input.2")" = 'second' ]
msg --from default --to infra -- 'third'
expect "another sender, another thread" has "$ROOT/gw/requests" 'title=From default id=swarmhub-from-default'
done_case

# 3
new_case "no-wait: session id at once, the message still arrives"
mode slow
msg --from jarvis --to infra --no-wait -- 'Restart the backup job when you can'
expect "returned while the reply was still held" [ ! -e "$ROOT/gw/answered" ]
release
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
expect "prints the session id" [ "$(cat "$C/out")" = swarmhub-from-jarvis ]
expect "chat request reached the gateway" [ "$(sed -n 2p "$ROOT/gw/input.1" 2>/dev/null)" = 'Restart the backup job when you can' ]
expect "log says queued" [ "$(field 5)" = queued ]
expect "log ok" [ "$(field 7)" = ok ]
wait_late
done_case

# 4
new_case "timeout: no reply within --wait exits 124"
mode slow
msg --from jarvis --to infra --wait 1 -- 'slow question'
expect "exit 124 (got $RC)" [ "$RC" -eq 124 ]
expect "says it may still answer" has "$C/err" 'no reply from infra within 1s'
release
wait_late
expect "log error" [ "$(field 7)" = error ]
expect "log waited" [ "$(field 5)" = waited ]
done_case

# 5
new_case "unknown bot and missing key exit 2 without a request"
msg --from jarvis --to ghost -- 'hello'
expect "unknown exit 2 (got $RC)" [ "$RC" -eq 2 ]
expect "names the bot" has "$C/err" 'no bot named ghost'
msg --from jarvis --to nokey -- 'hello'
expect "no key exit 2 (got $RC)" [ "$RC" -eq 2 ]
expect "says no key" has "$C/err" 'nokey has no API_SERVER_KEY'
expect "no request made" [ ! -s "$ROOT/gw/requests" ]
msg --from jarvis --to '../infra' -- 'hello'
expect "path in --to is usage (got $RC)" [ "$RC" -eq 64 ]
msg --from jarvis --to infra
expect "no text is usage (got $RC)" [ "$RC" -eq 64 ]
done_case

# 6
new_case "the key is never in argv, output or log"
mode slow
msg --from jarvis --to infra --wait 120 -- 'watch my argv' &
BG=$!
SEEN=
# The reply is held while ps is read: at least 5 times and until curl is among the processes seen (300 bounds a hang).
i=0
while [ $i -lt 300 ] && kill -0 $BG 2>/dev/null && { [ $i -lt 5 ] || [ -z "${CURL_SEEN:-}" ]; }; do
  if ps -A -o args= 2>/dev/null | grep -F -- "$KEY_INFRA" | grep -v grep > /dev/null; then SEEN=1; fi
  ps -A -o args= 2>/dev/null | grep -F -- 'swarmhub-from-jarvis/chat/stream' | grep -v grep > /dev/null && CURL_SEEN=1
  sleep 0.05; i=$((i + 1))
done
release
wait $BG
expect "curl was running while we looked" [ -n "${CURL_SEEN:-}" ]
expect "key never in ps" [ -z "$SEEN" ]
expect "exit 0 after the slow reply (got $(cat "$C/err"))" has "$C/out" 'Hi from infra'
no_key_anywhere
expect "no temp files left" [ -z "$(ls -d "$ROOT"/bot-msg.* 2>/dev/null)" ]
done_case

# 7
new_case "log line: time, from, to, session, waited|queued, ms, ok|error; never the text"
msg --from jarvis --to infra -- 'secret plan text'
msg --from jarvis --to ghost -- 'x'
expect "one line per sent message (got $(wc -l < "$LOG"))" [ "$(wc -l < "$LOG" | tr -d ' ')" -eq 1 ]
expect "7 tab-separated fields" [ "$(awk -F '\t' '{ print NF }' "$LOG")" = 7 ]
expect "UTC time" sh -c "[ -n \"\$(echo '$(field 1)' | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')\" ]"
expect "from/to/session" [ "$(field 2)|$(field 3)|$(field 4)|$(field 5)" = "jarvis|infra|swarmhub-from-jarvis|waited" ]
expect "ms is a number" sh -c "case '$(field 6)' in ''|*[!0-9]*) exit 1 ;; esac"
expect "ok" [ "$(field 7)" = ok ]
expect "no text in the log" lacks "$LOG" 'secret plan'
expect "log folder 700" [ "$(ls -ld "$H/swarmhub" | cut -c1-10)" = drwx------ ]
done_case

# 8
new_case "gateway errors exit 3: failed run, HTTP 500, nothing listening, wrong key"
mode fail
msg --from jarvis --to infra -- 'x'
expect "failed run exit 3 (got $RC)" [ "$RC" -eq 3 ]
expect "says why" has "$C/err" 'Provider authentication failed'
mode down500
msg --from jarvis --to infra -- 'x'
expect "500 exit 3 (got $RC)" [ "$RC" -eq 3 ] && has "$C/err" 'HTTP 500'
mode ok
GWURL=http://127.0.0.1:9
msg --from jarvis --to infra -- 'x'
expect "nothing listening exit 3 (got $RC)" [ "$RC" -eq 3 ] && has "$C/err" 'did not answer'
GWURL=$GATEWAY
printf 'API_SERVER_KEY=sk-wrong-key-value\n' > "$H/profiles/infra/.env"
msg --from jarvis --to infra -- 'x'
expect "wrong key exit 3 (got $RC)" [ "$RC" -eq 3 ] && has "$C/err" 'refused its key'
expect "all four logged as error" [ "$(grep -c "	error$" "$LOG")" -eq 4 ]
done_case

# 9
new_case "default profile: ~/.hermes/.env (export, CRLF) and no /p/ prefix"
msg --from jarvis --to default -- 'hi main'
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
expect "unprefixed path" has "$ROOT/gw/requests" 'POST /api/sessions/swarmhub-from-jarvis/chat/stream ok 200'
done_case

# 10
new_case "sender from the install path; API_SERVER_PORT reaches the profile directly"
D=$H/profiles/jarvis/skills/swarmhub/swarmhub-messages/scripts
mkdir -p "$D" && cp "$MSG" "$D/bot-msg" && chmod 755 "$D/bot-msg"
GWURL=
# (the stub reads an unprefixed path as the default profile, so infra carries that key here)
printf 'API_SERVER_KEY=%s\nAPI_SERVER_PORT=%s\n' "$KEY_DEFAULT" "$PORT" > "$H/profiles/infra/.env"
msg_with "$D/bot-msg" --to infra -- 'who am I'
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
expect "sender is jarvis" [ "$(head -n 1 "$ROOT/gw/input.1")" = '[Message from jarvis via SwarmHub]' ]
expect "direct port, no /p/ prefix" has "$ROOT/gw/requests" 'POST /api/sessions ok 201 title=From jarvis'
mkdir -p "$C/elsewhere" && cp "$MSG" "$C/elsewhere/bot-msg"
msg_with "$C/elsewhere/bot-msg" --to infra -- 'x'
expect "unknown sender is usage (got $RC)" [ "$RC" -eq 64 ]
done_case

# 11
new_case "quotes, backslashes, tabs and newlines arrive intact"
TEXT=$(printf 'Line "one" \\ back\tslash\nline two $HOME `x`')
msg --from jarvis --to infra -- "$TEXT"
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "text intact" [ "$(sed 1d "$ROOT/gw/input.1")" = "$TEXT" ]
done_case

# 12
new_case "late reply: no reply within --wait, the follow-up delivers it once to the sender"
mode slow
msg --from jarvis --to infra --wait 1 -- 'slow question'
expect "exit 124 (got $RC)" [ "$RC" -eq 124 ]
expect "says the reply will come" has "$C/err" 'its reply will reach you as a new message'
release
wait_late
expect "the sender's From infra session" has "$ROOT/gw/requests" 'POST /p/jarvis/api/sessions ok 201 title=From infra id=swarmhub-from-infra source=api_server'
expect "delivered once (got $(count 'jarvis/api/sessions/swarmhub-from-infra/chat/stream'))" [ "$(count 'POST /p/jarvis/api/sessions/swarmhub-from-infra/chat/stream ok 200')" -eq 1 ]
expect "header line" [ "$(head -n 1 "$ROOT/gw/input.2" 2>/dev/null)" = '[Reply from infra via SwarmHub]' ]
expect "the reply" [ "$(sed -n 2p "$ROOT/gw/input.2" 2>/dev/null)" = 'Hi from infra: Zażółć ✓ "done"' ]
expect "log line late-reply ($(sed -n 2p "$LOG"))" [ "$(field 2 2)|$(field 3 2)|$(field 4 2)|$(field 5 2)|$(field 7 2)" = "infra|jarvis|swarmhub-from-infra|late-reply|ok" ]
expect "no third input" [ ! -e "$ROOT/gw/input.3" ]
no_key_anywhere
done_case

# 13
new_case "late reply: --no-wait delivers the reply once"
mode slow
msg --from jarvis --to infra --no-wait -- 'Restart the backup job and tell me'
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ] && [ "$(cat "$C/out")" = swarmhub-from-jarvis ]
release
wait_late
expect "delivered once" [ "$(count 'POST /p/jarvis/api/sessions/swarmhub-from-infra/chat/stream ok 200')" -eq 1 ]
expect "header line" [ "$(head -n 1 "$ROOT/gw/input.2" 2>/dev/null)" = '[Reply from infra via SwarmHub]' ]
expect "queued, then late-reply ok" [ "$(field 5)|$(field 5 2)|$(field 7 2)" = "queued|late-reply|ok" ]
done_case

# 14
new_case "a delivered reply never gets a follow-up"
mode slow
msg --from jarvis --to infra --no-wait -- '[Reply from infra via SwarmHub] thanks, noted'
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "no follow-up folder" [ -z "$(ls -d "$ROOT"/bot-msg-late.* 2>/dev/null)" ]
msg --from jarvis --to infra --wait 1 -- '[Reply from infra via SwarmHub] and this'
expect "exit 124 (got $RC)" [ "$RC" -eq 124 ]
expect "no promise of a reply" lacks "$C/err" 'will reach you'
release
wait_released
sleep 0.3
expect "nothing sent to the sender" [ "$(count 'POST /p/jarvis/')" -eq 0 ]
expect "no late-reply line" lacks "$LOG" 'late-reply'
done_case

echo "bot-msg tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
