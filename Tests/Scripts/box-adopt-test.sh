#!/bin/sh
# Hermetic tests for the P35 recipes in Resources/BotManager/recipes/box.md ("List every bot", "Connect bots",
# "Restore a connected bot's old key"): each fence is cut out of the recipe file, filled the way SwarmHub fills it and
# run under $BOX_SH in a temp HOME with a synthetic ~/.hermes. No hermes CLI, no network. Run by BoxAdoptionTests under
# /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/box-adopt-test.sh <path/to/recipes/box.md>     BOX_SH = the shell that runs the recipes (default /bin/sh)

TEXT=${1:?usage: box-adopt-test.sh <path/to/recipes/box.md>}
SH=${BOX_SH:-/bin/sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/box-adopt-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
PASSED=0 FAILED=0
# HMAC-SHA256("boss-key", "swarmhub-bot-key:v1:<name>"), as BotManagerText.derivedKey computes it (the Swift test checks the same values).
KEY_CFO=fb7666de8508504313ba460dfe199999a811c28f0f9d35cfbb55346bf278b1e7
KEY_LOWCOST=ca205d2c546f49921db8c29361d03c421a5651de0becc10d8f4a92435591c9f5

# The fenced block after the first line containing $1.
recipe() {
  awk -v marker="$1" 'found == 0 && index($0, marker) { found = 1; next }
    found == 1 && /^```/ { found = 2; next } found == 2 && /^```/ { exit } found == 2 { print }' "$TEXT"
}
LIST=$(recipe 'List every bot:')
ADOPT=$(recipe 'Connect bots (')
RESTORE=$(recipe "Restore a connected bot's old key:")
CLOSE=$(recipe 'Close reports (')

# A fresh box: default (keyed), the manager boss, cfo (keyed, other lines, 0644), lowcost (no .env), knowledge-guide
# (empty key), and entries the list must skip.
new_case() {
  NAME=$1; PROBLEMS=
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  H=$C/home/.hermes P=$C/home/.hermes/profiles
  mkdir -p "$P/boss" "$P/cfo" "$P/lowcost" "$P/knowledge-guide" "$P/.retired/old-1" "$P/Upper" "$P/dot.ted"
  printf 'API_SERVER_KEY=main-key\nTELEGRAM=1\n' > "$H/.env"
  printf 'API_SERVER_KEY=boss-key\n' > "$P/boss/.env"
  printf 'OPENAI_API_KEY=sk-other\nAPI_SERVER_KEY=old-cfo-key\nLAST=keep me\n' > "$P/cfo/.env"; chmod 644 "$P/cfo/.env"
  printf 'API_SERVER_KEY=\nX=1' > "$P/knowledge-guide/.env"
  cp -p "$P/cfo/.env" "$C/cfo.orig"; cp -p "$H/.env" "$C/default.orig"; cp -p "$P/boss/.env" "$C/boss.orig"
}
# Runs recipe text $1 with SwarmHub's fills ($2 = names, $3 = name, $4 = backup); output in $C/out.
run() {
  printf '%s\n' "$1" | sed -e 's|{{MANAGER_ENV}}|~/.hermes/profiles/boss/.env|g' -e 's|{{MANAGER}}|boss|g' \
    -e "s|<names>|$2|g" -e "s|<name>|$3|g" -e "s|<backup>|$4|g" > "$C/recipe.sh"
  env HOME="$C/home" PATH=/usr/bin:/bin "$SH" "$C/recipe.sh" > "$C/out" 2> "$C/err"
}
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
mode() { ls -l "$1" | cut -c1-10; }
same() { cmp -s "$1" "$2"; }
lacks() { ! grep -q "$1" "$2"; }
backup_of() { ls -a "$P/$1" | grep '^\.env\.swarmhub-bak-' | head -n 1; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1)); else echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1)); fi
}

new_case "the three recipes are in the manager text"
expect "list recipe missing" [ -n "$LIST" ]
expect "adopt recipe missing" [ -n "$ADOPT" ]
expect "restore recipe missing" [ -n "$RESTORE" ]
done_case

new_case "list reports default and every profile with has_key, skipping dotted and invalid names"
run "$LIST"
expect "list line: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"bots","list":[{"name":"default","has_key":true},{"name":"boss","has_key":true},{"name":"cfo","has_key":true},{"name":"knowledge-guide","has_key":false},{"name":"lowcost","has_key":false}],"reports":[]}' ]
expect "the list printed a key" lacks 'key-\|main-key\|old-cfo' "$C/out"
expect "the list changed a file" same "$P/cfo/.env" "$C/cfo.orig"
done_case

new_case "adopt backs up 0600 byte-identical, replaces the key, keeps the other lines"
run "$ADOPT" "cfo"
B=$(backup_of cfo)
expect "no backup written" [ -n "$B" ]
expect "backup name $B" sh -c "echo '$B' | grep -Eq '^\.env\.swarmhub-bak-[0-9]{8}T[0-9]{6}Z$'"
expect "backup not byte-identical" same "$P/cfo/$B" "$C/cfo.orig"
expect "backup mode $(mode "$P/cfo/$B")" [ "$(mode "$P/cfo/$B")" = "-rw-------" ]
expect "new .env mode $(mode "$P/cfo/.env")" [ "$(mode "$P/cfo/.env")" = "-rw-------" ]
expect "key not replaced" [ "$(grep '^API_SERVER_KEY=' "$P/cfo/.env")" = "API_SERVER_KEY=$KEY_CFO" ]
expect "other lines lost" [ "$(grep -v '^API_SERVER_KEY=' "$P/cfo/.env")" = "$(printf 'OPENAI_API_KEY=sk-other\nLAST=keep me')" ]
expect "report line: $(cat "$C/out")" [ "$(cat "$C/out")" = "{\"op\":\"bots_adopted\",\"results\":[{\"name\":\"cfo\",\"ok\":true,\"backup\":\"$B\"}]}" ]
expect "the report printed a key" lacks "$KEY_CFO\|boss-key\|old-cfo" "$C/out"
expect "a temp file was left" [ ! -e "$P/cfo/.env.swarmhub-new" ]
done_case

new_case "adopt adds the key to a profile without .env (lowcost), no backup"
run "$ADOPT" "lowcost"
expect "lowcost .env: $(cat "$P/lowcost/.env" 2>&1)" [ "$(cat "$P/lowcost/.env")" = "API_SERVER_KEY=$KEY_LOWCOST" ]
expect "lowcost mode $(mode "$P/lowcost/.env")" [ "$(mode "$P/lowcost/.env")" = "-rw-------" ]
expect "a backup appeared" [ -z "$(backup_of lowcost)" ]
expect "report line: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"bots_adopted","results":[{"name":"lowcost","ok":true,"backup":""}]}' ]
done_case

new_case "adopt refuses default, the manager, unknown and invalid names; the others in the batch still go"
run "$ADOPT" "default boss ghost ../cfo cfo"
expect "default changed" same "$H/.env" "$C/default.orig"
expect "manager changed" same "$P/boss/.env" "$C/boss.orig"
expect "default got a backup" [ -z "$(ls -a "$H" | grep swarmhub-bak)" ]
expect "manager got a backup" [ -z "$(backup_of boss)" ]
expect "ghost created" [ ! -e "$P/ghost" ]
B=$(backup_of cfo)
expect "report line: $(cat "$C/out")" [ "$(cat "$C/out")" = "{\"op\":\"bots_adopted\",\"results\":[{\"name\":\"default\",\"ok\":false,\"backup\":\"\"},{\"name\":\"boss\",\"ok\":false,\"backup\":\"\"},{\"name\":\"ghost\",\"ok\":false,\"backup\":\"\"},{\"name\":\"../cfo\",\"ok\":false,\"backup\":\"\"},{\"name\":\"cfo\",\"ok\":true,\"backup\":\"$B\"}]}" ]
done_case

new_case "adopt without a readable manager key changes nothing"
rm "$P/boss/.env"
run "$ADOPT" "cfo"
expect "cfo changed" same "$P/cfo/.env" "$C/cfo.orig"
expect "report line: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"bots_adopted","results":[{"name":"cfo","ok":false,"backup":""}]}' ]
done_case

new_case "undo restores the backup byte for byte"
run "$ADOPT" "cfo"; B=$(backup_of cfo)
run "$RESTORE" "" "cfo" "$B"
expect "not restored" same "$P/cfo/.env" "$C/cfo.orig"
expect "report line: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"key_restored","name":"cfo","ok":true}' ]
expect "a temp file was left" [ ! -e "$P/cfo/.env.swarmhub-new" ]
done_case

new_case "undo without a backup removes the added key (and the file it created)"
run "$ADOPT" "lowcost"
run "$RESTORE" "" "lowcost" ""
expect "lowcost .env still there" [ ! -e "$P/lowcost/.env" ]
expect "report line: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"key_restored","name":"lowcost","ok":true}' ]
printf 'A=1\nAPI_SERVER_KEY=x\n' > "$P/lowcost/.env"
run "$RESTORE" "" "lowcost" ""
expect "other lines lost" [ "$(cat "$P/lowcost/.env")" = "A=1" ]
done_case

new_case "undo refuses default, the manager and a backup name that is not ours"
cp -p "$H/.env" "$H/.env.swarmhub-bak-20260101T000000Z"; printf 'API_SERVER_KEY=changed\n' > "$H/.env"
run "$RESTORE" "" "default" ".env.swarmhub-bak-20260101T000000Z"
expect "default restored" [ "$(cat "$H/.env")" = "API_SERVER_KEY=changed" ]
expect "default report: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"key_restored","name":"default","ok":false}' ]
run "$RESTORE" "" "boss" ""
expect "manager changed" same "$P/boss/.env" "$C/boss.orig"
run "$ADOPT" "cfo"; cp -p "$P/cfo/.env" "$C/cfo.adopted"
run "$RESTORE" "" "cfo" ".env.swarmhub-bak-x/../../boss/.env"
expect "foreign backup used" same "$P/cfo/.env" "$C/cfo.adopted"
expect "foreign report: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"key_restored","name":"cfo","ok":false}' ]
done_case

# P36: the listing carries unsent report files (one-line JSON starting {"id":"r), never .sent ones or other files.
new_case "list carries the unsent reports"
R=$H/swarmhub/reports; mkdir -p "$R"
printf '{"id":"r1-aa","kind":"bug","title":"t \\"q\\"","body":"b"}\n' > "$R/r1-aa.json"
printf '{"id":"r0-old","kind":"bug","title":"sent","body":"b"}\n' > "$R/r0-old.sent"
printf 'not json\n' > "$R/bad.json"
printf '{"id":"r2-ml","kind":"bug",\n"title":"two lines"}\n' > "$R/r2-ml.json"
run "$LIST"
expect "list line: $(cat "$C/out")" python3 -I -c 'import json,sys; o=json.load(open(sys.argv[1])); assert [r["id"] for r in o["reports"]]==["r1-aa"] and o["reports"][0]["title"]=="t \"q\"", o' "$C/out"
done_case

new_case "close reports renames sent files to .sent, deletes dismissed ones, skips odd ids"
R=$H/swarmhub/reports; mkdir -p "$R"
for I in r1-aa r2-bb r3-cc; do printf '{"id":"%s"}\n' "$I" > "$R/$I.json"; done
printf '%s\n' "$CLOSE" | sed -e 's|<sent>|r1-aa ../x r9-gone|' -e 's|<deleted>|r2-bb|' > "$C/recipe.sh"
env HOME="$C/home" PATH=/usr/bin:/bin "$SH" "$C/recipe.sh" > "$C/out" 2> "$C/err"
expect "close line: $(cat "$C/out")" [ "$(cat "$C/out")" = '{"op":"reports_closed","sent":["r1-aa"],"deleted":["r2-bb"]}' ]
expect "r1 not renamed" [ -f "$R/r1-aa.sent" ] && expect "r1 json left" [ ! -e "$R/r1-aa.json" ]
expect "r2 not deleted" [ ! -e "$R/r2-bb.json" ] && expect "r3 touched" [ -f "$R/r3-cc.json" ]
done_case

echo "box-adopt tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
