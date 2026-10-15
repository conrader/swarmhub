#!/bin/sh
# Hermetic tests for Resources/Skills/swarmhub-coding/scripts/swarmhub-claude-login: a temp HOME and a stub `claude`
# first on PATH that prints a login link, reads a code and prints a fake token (no real CLI, no network). Run by
# ClaudeLoginScriptTests under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/claude-login-test.sh <path/to/swarmhub-claude-login>     LOGIN_SH = the shell that runs it (default /bin/sh)

LOGIN=${1:?usage: claude-login-test.sh <path/to/swarmhub-claude-login>}
SH=${LOGIN_SH:-/bin/sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-login-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
PASSED=0 FAILED=0
FAKE=sk-ant-oat01-FAKEtokenFAKEtoken_abc-123
LINK='https://claude.ai/oauth/authorize?code=true&client_id=stub-client&state=st8'

# Like `claude setup-token` in a terminal: coloured link, a prompt, the code read from the terminal, then the token.
cat > "$ROOT/claude" <<'STUB'
#!/bin/sh
case $1 in --version) echo "2.9.9 (Claude Code)"; exit 0 ;; setup-token) ;; *) exit 2 ;; esac
[ -t 0 ] || { echo "stub claude: stdin is not a terminal"; exit 5; }
printf '\033[1mBrowse to:\033[0m \033[4mhttps://claude.ai/oauth/authorize?code=true&client_id=stub-client&state=st8\033[0m\r\n'
printf 'Paste code here if prompted > '
read code
echo "${ANTHROPIC_API_KEY:+API KEY LEAKED}"
[ "$code" = "good-code#st8" ] || { echo "OAuth error: invalid code"; exit 1; }
echo "Long-lived authentication token created successfully!"
echo "Your OAuth token (valid for 1 year): sk-ant-oat01-FAKEtokenFAKEtoken_abc-123"
echo "Store this token securely. You won't be able to see it again."
STUB
chmod 755 "$ROOT/claude"

new_case() {
  NAME=$1; PROBLEMS=
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  mkdir -p "$C/home" "$C/bin"
  [ "${2:-}" = nostub ] || cp "$ROOT/claude" "$C/bin/claude"
  S=$C/home/.hermes/swarmhub
}
# The script with the case's HOME and PATH; $1 = output name (out/err in $C/$1.out, $C/$1.err).
run() {
  o=$1; shift
  env HOME="$C/home" PATH="$C/bin:/usr/bin:/bin" ANTHROPIC_API_KEY=from-caller CLAUDE_LOGIN_WAIT=${WAIT:-20} \
    CLAUDE_LOGIN_CODE_WAIT=20 "$SH" "$LOGIN" "$@" > "$C/$o.out" 2> "$C/$o.err"
}
start_bg() { run start "$@" start & BG=$!; }
await_file() { i=0; while [ ! -s "$1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; [ -s "$1" ]; }
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
mode() { ls -l "$1" | cut -c1-10; }
# Nothing the case printed or left in its HOME (other than the token file) holds the token or the code.
clean() { ! cat "$C"/*.out "$C"/*.err 2>/dev/null | grep -Fq -e "$FAKE" -e "${1:-good-code}"
  ! find "$C/home" -type f ! -name claude.token -exec cat {} + 2>/dev/null | grep -Fq "$FAKE"; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1)); else echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1)); fi
}

# 1
new_case "start shows the link, code stores only the token (0600)"
run s0 status
expect "not logged in first" [ "$(cat "$C/s0.out")" = not-logged-in ]
start_bg
expect "link file written" await_file "$S/claude-login.url"
expect "link is the oauth URL" [ "$(cat "$S/claude-login.url" 2>/dev/null)" = "$LINK" ]
expect "link file 0600" [ "$(mode "$S/claude-login.url")" = "-rw-------" ]
expect "folder 0700" [ "$(ls -ld "$S" | cut -c1-10)" = "drwx------" ]
run code code 'good-code#st8'; RC=$?
wait "$BG"; SRC=$?
expect "code: ok, exit 0 (got $RC: $(cat "$C/code.out"))" [ "$RC" -eq 0 ] && [ "$(cat "$C/code.out")" = ok ]
expect "start: ok, exit 0 (got $SRC: $(cat "$C/start.out"))" [ "$SRC" -eq 0 ] && [ "$(cat "$C/start.out")" = ok ]
expect "token file holds only the token" [ "$(cat "$S/claude.token" 2>/dev/null)" = "$FAKE" ]
expect "token file 0600" [ "$(mode "$S/claude.token")" = "-rw-------" ]
expect "link, code and pid files gone" [ ! -e "$S/claude-login.url" ] && [ ! -e "$S/claude-login.code" ] && [ ! -e "$S/claude-login.pid" ]
expect "token and code never printed or left elsewhere" clean 'good-code#st8'
expect "no stderr" [ ! -s "$C/start.err" ] && [ ! -s "$C/code.err" ]
run s1 status
expect "logged in" [ "$(cat "$C/s1.out")" = logged-in ]
done_case

# 2
new_case "a wrong code fails without a token"
start_bg
expect "link file written" await_file "$S/claude-login.url"
run code code 'bad-code#st8'; RC=$?
wait "$BG"; SRC=$?
expect "code: failed (got $RC $(cat "$C/code.out"))" [ "$RC" -ne 0 ] && [ "$(cat "$C/code.out")" = failed ]
expect "start: failed" [ "$SRC" -ne 0 ] && [ "$(cat "$C/start.out")" = failed ]
expect "no token file" [ ! -e "$S/claude.token" ] && [ ! -e "$S/claude.token.new" ]
expect "code never printed" clean 'bad-code'
run s status
expect "not logged in" [ "$(cat "$C/s.out")" = not-logged-in ]
done_case

# 3
new_case "logout removes the token; status needs claude"
mkdir -p "$S" && printf '%s\n' "$FAKE" > "$S/claude.token"
run s0 status
expect "logged in with a token" [ "$(cat "$C/s0.out")" = logged-in ]
rm "$C/bin/claude"; run s1 status
expect "not logged in without claude" [ "$(cat "$C/s1.out")" = not-logged-in ]
run l logout
expect "logout prints not-logged-in" [ "$(cat "$C/l.out")" = not-logged-in ]
expect "token file removed" [ ! -e "$S/claude.token" ]
done_case

# 4
new_case "refusals: no claude, no waiting login, bad code, bad usage" nostub
run start start; RC=$?
expect "start without claude: 69 (got $RC)" [ "$RC" -eq 69 ] && [ "$(cat "$C/start.out")" = failed ]
run c1 code 'good-code#st8'; RC=$?
expect "code with no login waiting fails" [ "$RC" -eq 1 ] && [ "$(cat "$C/c1.out")" = failed ]
run c2 code 'x; rm -rf ~'; RC=$?
expect "code with shell characters: 64 (got $RC)" [ "$RC" -eq 64 ]
run u1 frobnicate; RC=$?
expect "unknown command: 64" [ "$RC" -eq 64 ]
expect "nothing echoed" clean 'rm -rf'
done_case

# 5
new_case "no code in time: start gives up"
WAIT=2 start_bg
wait "$BG"; SRC=$?
expect "start: failed after the wait (got $SRC)" [ "$SRC" -ne 0 ] && [ "$(cat "$C/start.out")" = failed ]
expect "no token, no pid left" [ ! -e "$S/claude.token" ] && [ ! -e "$S/claude-login.pid" ]
done_case

echo "claude-login tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
