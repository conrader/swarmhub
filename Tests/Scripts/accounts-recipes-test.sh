#!/bin/sh
# Hermetic tests for the P31 C recipes in Resources/BotManager/recipes/accounts.md ("Coding tools and logins"): each
# fence is cut out of the recipe file, filled the way SwarmHub fills it and run under $BOX_SH in a temp HOME with stub
# `claude`, `codex` and `hermes` and a synthetic ~/.hermes/auth.json. Needs `node` (as on the box); no network. Run by
# AccountsRecipeTests under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/accounts-recipes-test.sh <path/to/recipes/accounts.md> <dir with node>     BOX_SH (default /bin/sh)

TEXT=${1:?usage: accounts-recipes-test.sh <path/to/recipes/accounts.md> <node dir>}
NODE_DIR=${2:?usage: accounts-recipes-test.sh <path/to/recipes/accounts.md> <node dir>}
SH=${BOX_SH:-/bin/sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/accounts-recipes-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
PASSED=0 FAILED=0
# Only node from that folder (it may hold a real claude or codex).
mkdir "$ROOT/node" && ln -s "$NODE_DIR/node" "$ROOT/node/node" || exit 1
NODE_DIR=$ROOT/node

recipe() {
  awk -v marker="$1" 'found == 0 && index($0, marker) { found = 1; next }
    found == 1 && /^```/ { found = 2; next } found == 2 && /^```/ { exit } found == 2 { print }' "$TEXT"
}
STATUS=$(recipe 'Accounts status:')
START=$(recipe 'Log in, step 1')
LINK=$(recipe 'Log in, step 2')
CHECK=$(recipe 'Check a login')
CODE=$(recipe "Claude's one-time code")
LOGOUT=$(recipe 'Log out (claude or codex)')

# Stubs: versions, codex's device login (help lists the flag), hermes auth add (fails), claude-login code.
cat > "$ROOT/stub" <<'STUB'
#!/bin/sh
me=$(basename "$0")
# A sign-in "waits for Konrad" until the test releases it (after step 2 read the link), however slow the machine is.
held() { while [ ! -f "$HOME/release" ]; do sleep 0.05; done; }
case "$me $*" in
  "claude --version") echo "2.1.3 (Claude Code)" ;;
  "codex --version") echo "codex-cli 0.50.1" ;;
  "codex login --help") echo "Usage: codex login [OPTIONS]"; echo "      --device-auth   Sign in with a device code" ;;
  "codex login --device-auth") printf '\033[1mFollow these steps:\033[0m\n1. Open \033[4mhttps://auth.openai.com/codex/device\033[0m\n2. Enter this one-time code \033[1mABCD-1234\033[0m\n'
    held; mkdir -p "$HOME/.codex"; echo '{"tokens":"T"}' > "$HOME/.codex/auth.json" ;;
  "codex logout") rm -f "$HOME/.codex/auth.json" ;;
  "hermes auth add openai-codex") echo "HERMES_HOME=$HERMES_HOME"; echo "Open https://auth.openai.com/codex/device and enter WXYZ-9876"; held; echo "denied"; exit 1 ;;
  *) echo "stub $me: $*" >&2; exit 2 ;;
esac
STUB

new_case() {
  NAME=$1; shift; PROBLEMS=
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  mkdir -p "$C/home/.hermes/swarmhub/bin" "$C/bin"
  for n in "$@"; do cp "$ROOT/stub" "$C/bin/$n"; chmod 755 "$C/bin/$n"; done
}
# The recipes poll every 1-2 s on the box; here 10 times as often, with the same ceilings (40 s link, 120 s check).
fast() { sed -e 's/\[ \$i -lt 40 \]; do sleep 1;/[ $i -lt 400 ]; do sleep 0.1;/' -e 's/\[ \$i -lt 120 \]; do sleep 2;/[ $i -lt 1200 ]; do sleep 0.2;/' \
  -e 's/\[ \$i -lt 2 \]; do sleep 2;/[ $i -lt 2 ]; do sleep 0.2;/'; }
# Runs recipe $1 with <tool> = $2 and <code> = $3; output in $C/out.
run() {
  printf '%s\n' "$1" | sed -e "s|<tool>|$2|g" -e "s|<code>|$3|g" | fast > "$C/recipe.sh"
  env HOME="$C/home" PATH="$C/bin:/usr/bin:/bin:$NODE_DIR" "$SH" "$C/recipe.sh" > "$C/out" 2> "$C/err"
}
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
has() { grep -Fq -- "$1" "$C/out"; }
lacks() { ! grep -Fq -- "$1" "$C/out"; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1)); else echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1)); fi
}

new_case "the recipes are in the manager text"
for r in "$STATUS" "$START" "$LINK" "$CHECK" "$CODE" "$LOGOUT"; do expect "a recipe is missing" [ -n "$r" ]; done
done_case

new_case "status: versions, logins, pool without tokens or emails" claude codex
printf 'sk-ant-oat01-SECRET\n' > "$C/home/.hermes/swarmhub/claude.token"
mkdir -p "$C/home/.codex"; echo '{"tokens":"T"}' > "$C/home/.codex/auth.json"
FUTURE=$(( $(date +%s) + 7200 ))
cat > "$C/home/.hermes/auth.json" <<JSON
{"credential_pool":{"openai-codex":[
 {"label":"backup","priority":1,"access_token":"SECRET-B","refresh_token":"R-B","last_status":"ok"},
 {"label":"konrad@example.com","priority":0,"access_token":"SECRET-A","last_status":"exhausted","last_error_reset_at":$FUTURE}]}}
JSON
run "$STATUS"
expect "one JSON line (got: $(cat "$C/out") $(cat "$C/err"))" [ "$(wc -l < "$C/out" | tr -d ' ')" -eq 1 ]
expect "claude" has '"claude":{"installed":true,"version":"2.1.3","logged_in":true}'
expect "codex" has '"codex":{"installed":true,"version":"0.50.1","logged_in":true}'
expect "pool in priority order, email hidden" has '"chatgpt":{"count":2,"labels":["account 1","backup"],"benched_until":["'
expect "second entry not benched" has '",null]}}'
expect "no token, no email" lacks SECRET && lacks sk-ant && lacks '@' && lacks R-B
done_case

new_case "status: nothing installed, no pool"
run "$STATUS"
expect "nothing installed (got: $(cat "$C/out") $(cat "$C/err"))" has '"claude":{"installed":false,"version":null,"logged_in":false},"codex":{"installed":false,"version":null,"logged_in":false},"chatgpt":{"count":0,"labels":[],"benched_until":[]}'
done_case

new_case "codex: device flag from --help, link and code, then done" codex
printf '%s\n' "$START" | sed "s|<tool>|codex|g" > "$C/start.sh"
env HOME="$C/home" PATH="$C/bin:/usr/bin:/bin:$NODE_DIR" "$SH" "$C/start.sh" & BG=$!
run "$LINK" codex
expect "login_link (got: $(cat "$C/out"))" has '{"op":"login_link","tool":"codex","url":"https://auth.openai.com/codex/device","code":"ABCD-1234"}'
: > "$C/home/release"
run "$CHECK" codex
wait "$BG"
expect "login_done ok (got: $(cat "$C/out"))" has '{"op":"login_done","tool":"codex","ok":true}'
expect "out file 0600" [ "$(ls -l "$C/home/.hermes/swarmhub/codex-login.out" | cut -c1-10)" = "-rw-------" ]
run "$LOGOUT" codex; run "$STATUS"
expect "logged out" has '"codex":{"installed":true,"version":"0.50.1","logged_in":false}'
done_case

new_case "chatgpt: hermes auth add on the global home; a failed sign-in is ok:false" hermes
printf '%s\n' "$START" | sed "s|<tool>|chatgpt|g" > "$C/start.sh"
env HOME="$C/home" HERMES_HOME="$C/home/.hermes/profiles/boss" PATH="$C/bin:/usr/bin:/bin" "$SH" "$C/start.sh" & BG=$!
run "$LINK" chatgpt
expect "login_link (got: $(cat "$C/out"))" has '{"op":"login_link","tool":"chatgpt","url":"https://auth.openai.com/codex/device","code":"WXYZ-9876"}'
: > "$C/home/release"
wait "$BG"
run "$CHECK" chatgpt
expect "login_done false (got: $(cat "$C/out"))" has '{"op":"login_done","tool":"chatgpt","ok":false}'
expect "global HERMES_HOME" grep -Fqx "HERMES_HOME=$C/home/.hermes" "$C/home/.hermes/swarmhub/chatgpt-login.out"
done_case

new_case "a login still running reports pending; claude's code turn"
printf 'sleep 30\n' > "$C/never"; echo "started" > "$C/home/.hermes/swarmhub/codex-login.out"
printf '%s\n' "$CHECK" | sed -e 's|<tool>|codex|g' -e 's|-lt 120|-lt 2|' | fast > "$C/recipe.sh"
env HOME="$C/home" PATH="/usr/bin:/bin" "$SH" "$C/recipe.sh" > "$C/out"
expect "pending (got: $(cat "$C/out"))" has '{"op":"login_done","tool":"codex","ok":false,"pending":true}'
printf '#!/bin/sh\n[ "$1 $2" = "code good-code#st8" ] && echo ok || echo failed\n' > "$C/home/.hermes/swarmhub/bin/swarmhub-claude-login"
chmod 700 "$C/home/.hermes/swarmhub/bin/swarmhub-claude-login"
run "$CODE" claude 'good-code#st8'
expect "code ok (got: $(cat "$C/out"))" has '{"op":"login_done","tool":"claude","ok":true}'
expect "code not echoed" lacks good-code
run "$CODE" claude 'other-code'
expect "code failed" has '{"op":"login_done","tool":"claude","ok":false}'
done_case

echo "accounts recipe tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
