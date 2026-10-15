#!/bin/sh
# Hermetic tests for Resources/Skills/swarmhub-feedback/scripts/swarmhub-report: each case has its own temp HOME with
# the script installed in a synthetic jarvis profile next to fake SwarmHub skills, and a fake Hermes checkout. No real
# Hermes, no network; JSON is checked with python3 -I. Run by FeedbackSkillTests under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/swarmhub-report-test.sh <path/to/swarmhub-report>     REPORT_SH = the shell that runs it (default /bin/sh)

SRC=${1:?usage: swarmhub-report-test.sh <path/to/swarmhub-report>}
SH=${REPORT_SH:-/bin/sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/swarmhub-report-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
PASSED=0 FAILED=0

# A fresh case: its own HOME, the script in jarvis' swarmhub skills, three fake skills and Hermes 0.22.0.
new_case() {
  NAME=$1
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  H=$C/home/.hermes
  K=$H/profiles/jarvis/skills/swarmhub
  mkdir -p "$K/swarmhub-feedback/scripts" "$K/swarmhub-messages" "$K/swarmhub-coding" "$H/hermes-agent"
  cp "$SRC" "$K/swarmhub-feedback/scripts/swarmhub-report" && chmod 755 "$K/swarmhub-feedback/scripts/swarmhub-report"
  for s in swarmhub-feedback:1.0.0 swarmhub-messages:1.0.0 swarmhub-coding:1.2.0; do
    printf -- '---\nname: %s\ndescription: "fake"\nversion: %s\nauthor: SwarmHub\n---\n\n# Fake\n' "${s%%:*}" "${s#*:}" > "$K/${s%%:*}/SKILL.md"
  done
  printf '[project]\nname = "hermes-agent"\nversion = "0.22.0"\n' > "$H/hermes-agent/pyproject.toml"
  SCRIPT=$K/swarmhub-feedback/scripts/swarmhub-report
  R=$H/swarmhub/reports
  PROBLEMS=
}
# The script with the case's HOME and a minimal PATH; stdout in $C/out, stderr in $C/err, exit code in RC.
report() { report_with "$SCRIPT" "$@"; }
report_with() {
  script=$1; shift
  env -i HOME="$C/home" PATH=/usr/bin:/bin TMPDIR="$ROOT" "$SH" "$script" "$@" > "$C/out" 2> "$C/err" < /dev/null
  RC=$?
}
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
has() { grep -Fq -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -Fq -- "$2" "$1" 2>/dev/null; }
# The id from the op line, and that report's file.
rid() { python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read())["id"])' "$C/out" 2>/dev/null; }
rfile() { echo "$R/$(rid).json"; }
# Python expression $2 over the report file $1 (as d), printed; exits non-zero when it is not valid JSON. (The
# expressions are this file's own fixed checks, never input from elsewhere.)
pyget() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); print(eval(sys.argv[2]))' "$1" "$2" 2>/dev/null; }
pytrue() { [ "$(pyget "$1" "$2")" = True ]; }
nfiles() { ls "$R" 2>/dev/null | grep -c '\.json$'; }
mode_of() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1" 2>/dev/null; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "PASS: $NAME"; PASSED=$((PASSED + 1)); else echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1)); fi
}

# 1
new_case "op line: one line of valid JSON with op, id, kind and title"
report --kind bug --title 'Script failed' -- 'bot-msg exited 3'
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
expect "exactly one line (got $(wc -l < "$C/out"))" [ "$(wc -l < "$C/out" | tr -d ' ')" -eq 1 ]
expect "valid JSON with the right fields ($(cat "$C/out"))" python3 -I -c '
import json, re, sys
d = json.loads(open(sys.argv[1]).read())
assert sorted(d) == ["id", "kind", "op", "title"] and d["op"] == "report" and d["kind"] == "bug" and d["title"] == "Script failed"
assert re.fullmatch(r"r[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}", d["id"])' "$C/out"
expect "never the body" lacks "$C/out" 'bot-msg exited'
expect "nothing on stderr" [ ! -s "$C/err" ]
done_case

# 2
new_case "file: reports/<id>.json, folder 700, file 600, nothing else left"
mkdir -p "$R" && chmod 755 "$R"
report --kind feature --title 'More' -- 'Please add it'
F=$(rfile)
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "file exists ($F)" [ -f "$F" ]
expect "folder 700 (got $(mode_of "$R"))" [ "$(mode_of "$R")" = 700 ]
expect "file 600 (got $(mode_of "$F"))" [ "$(mode_of "$F")" = 600 ]
expect "one file only ($(ls -A "$R" | tr '\n' ' '))" [ "$(ls -A "$R" | wc -l | tr -d ' ')" -eq 1 ]
expect "one line" [ "$(wc -l < "$F" | tr -d ' ')" -eq 1 ]
expect "fixed fields" pytrue "$F" 'd["kind"] == "feature" and d["source"] == "agent" and d["bot_backend"] == "hermes" and d["body"] == "Please add it" and d["id"] in sys.argv[1]'
done_case

# 3
new_case "quotes, backslashes, newlines, tabs and unicode roundtrip exactly"
TITLE=$(printf 'A "quoted" \\ title\twith tab and ż 🎉')
BODY=$(printf 'Line "one" \\ back\\slash\n\tindented\nZażółć gęślą jaźń 🎉 $HOME `x` %%s\nlast')
printf '%s' "$TITLE" > "$C/title.expected"; printf '%s' "$BODY" > "$C/body.expected"
report --kind bug --title "$TITLE" -- "$BODY"
F=$(rfile)
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
expect "title roundtrips" pytrue "$F" 'd["title"] == open(sys.argv[1].rsplit("/home/", 1)[0] + "/title.expected", encoding="utf-8").read()'
expect "body roundtrips" pytrue "$F" 'd["body"] == open(sys.argv[1].rsplit("/home/", 1)[0] + "/body.expected", encoding="utf-8").read()'
expect "op title roundtrips" python3 -I -c 'import json,sys; assert json.loads(open(sys.argv[1]).read())["title"] == open(sys.argv[2], encoding="utf-8").read()' "$C/out" "$C/title.expected"
done_case

# 4
new_case "bot: from the install path, --bot overrides, default and unknown"
report --kind bug --title t -- b
expect "jarvis from the path" pytrue "$(rfile)" 'd["bot"] == "jarvis"'
report --bot grok-jarvis --kind bug --title t -- b
expect "--bot grok-jarvis" pytrue "$(rfile)" 'd["bot"] == "grok-jarvis"'
mkdir -p "$H/skills/swarmhub/swarmhub-feedback/scripts" "$C/elsewhere"
cp "$SRC" "$H/skills/swarmhub/swarmhub-feedback/scripts/swarmhub-report"; cp "$SRC" "$C/elsewhere/swarmhub-report"
report_with "$H/skills/swarmhub/swarmhub-feedback/scripts/swarmhub-report" --kind bug --title t -- b
expect "default from ~/.hermes/skills" pytrue "$(rfile)" 'd["bot"] == "default"'
report_with "$C/elsewhere/swarmhub-report" --kind bug --title t -- b
expect "unknown elsewhere" pytrue "$(rfile)" 'd["bot"] == "unknown"'
report --bot '../x' --kind bug --title t -- b
expect "bad --bot exits 2 (got $RC)" [ "$RC" -eq 2 ]
expect "four files" [ "$(nfiles)" -eq 4 ]
done_case

# 5
new_case "skill_versions: every SwarmHub skill beside this one, exactly"
mkdir -p "$K/Bad_Name" "$K/swarmhub-odd"
printf -- '---\nname: Bad_Name\nversion: 1.0.0\n---\n' > "$K/Bad_Name/SKILL.md"
printf -- '---\nname: swarmhub-odd\nversion: latest\n---\n' > "$K/swarmhub-odd/SKILL.md"
report --kind bug --title t -- b
expect "exact dict" pytrue "$(rfile)" 'd["skill_versions"] == {"swarmhub-coding": "1.2.0", "swarmhub-feedback": "1.0.0", "swarmhub-messages": "1.0.0"}'
done_case

# 6
new_case "hermes_version from pyproject.toml; VERSION wins; omitted when unknown"
report --kind bug --title t -- b
expect "0.22.0" pytrue "$(rfile)" 'd["hermes_version"] == "0.22.0"'
printf '0.23.1\n' > "$H/hermes-agent/VERSION"
report --kind bug --title t -- b
expect "VERSION 0.23.1" pytrue "$(rfile)" 'd["hermes_version"] == "0.23.1"'
rm -rf "$H/hermes-agent"
report --kind bug --title t -- b
expect "omitted" pytrue "$(rfile)" '"hermes_version" not in d'
done_case

# 7
new_case "created_at is UTC ISO 8601 and matches the id"
report --kind bug --title t -- b
expect "format and id" pytrue "$(rfile)" '__import__("re").fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", d["created_at"]) is not None and d["id"][1:17] == d["created_at"].replace("-", "").replace(":", "")'
done_case

# 8–17: one secret class each, in the title and the body; gone from the file and the op line, [redacted] in its place.
redaction_case() {
  new_case "redacts $1"
  secret=$2 text=$3
  report --kind bug --title "title $text" -- "before $text after"
  F=$(rfile)
  expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
  expect "secret gone from the file" lacks "$F" "$secret"
  expect "secret gone from the op line" lacks "$C/out" "$secret"
  expect "[redacted] in the body" pytrue "$F" '"[redacted]" in d["body"] and d["body"].startswith("before ") and d["body"].endswith(" after")'
  expect "[redacted] in the title" has "$C/out" '[redacted]'
  [ -z "${4:-}" ] || expect "keeps $4" pytrue "$F" "'$4' in d['body']"
  done_case
}
redaction_case "a Bearer token" 'abcDEF123456ghiJKL' 'Authorization: Bearer abcDEF123456ghiJKL' 'Bearer [redacted]'
redaction_case "an sk- key" 'sk-proj4f9a8b7c6d5e4f3a2b1c' 'key sk-proj4f9a8b7c6d5e4f3a2b1c here'
redaction_case "an sk-ant- key" 'api03-Zx9Yw8Vu7Ts6Rq5Po4Nm' 'sk-ant-api03-Zx9Yw8Vu7Ts6Rq5Po4Nm'
redaction_case "a ghp_ token" 'ghp_1a2B3c4D5e6F7g8H9i0JkLmNoPqRsTuVwXyZ' 'token ghp_1a2B3c4D5e6F7g8H9i0JkLmNoPqRsTuVwXyZ'
redaction_case "a xoxb- token" 'xoxb-123456789012-abcdefABCDEF' 'slack xoxb-123456789012-abcdefABCDEF'
redaction_case "an AKIA key" 'AKIAIOSFODNN7EXAMPLE' 'aws AKIAIOSFODNN7EXAMPLE id'
redaction_case "a JWT" 'eyJzdWIiOiIxMjM0NTY3ODkwIn0' 'jwt eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c'
redaction_case "password=" 'hunter2-Secret' 'login password=hunter2-Secret ok' 'password=[redacted]'
redaction_case '"api_key": "…"' 'q8Rt5LmN2pXz' '{"api_key": "q8Rt5LmN2pXz"}' '"api_key": "[redacted]"'
redaction_case "a PEM private key block over several lines" 'MIIEowIBAAKCAQEA7bq' "$(printf 'pem -----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA7bq\nZm9vYmFy\n-----END RSA PRIVATE KEY----- done')"

# 18
new_case "ordinary text is kept"
TEXT='the key idea; sk-short; password: x; token budget; Bearer of news; ask-me-anything-about-everything-here'
report --kind feature --title 'the key idea' -- "$TEXT"
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "body unchanged" pytrue "$(rfile)" "d['body'] == '$TEXT'"
expect "title unchanged" pytrue "$(rfile)" "d['title'] == 'the key idea'"
done_case

# 19
new_case "a long title is cut to 140 characters; the body to 8000 bytes"
LONG=$(printf 'ż%.0s' 1 2 3 4 5 6 7 8 9 10)$(printf '0123456789%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15)
BIG=$(awk 'BEGIN { for (i = 0; i < 900; i++) printf "0123456789" }')
report --kind bug --title "$LONG" -- "$BIG"
expect "exit 0 (got $RC)" [ "$RC" -eq 0 ]
expect "140 characters" pytrue "$(rfile)" 'len(d["title"]) == 140 and d["title"].startswith("ż" * 10)'
expect "8000 bytes" pytrue "$(rfile)" 'len(d["body"]) == 8000'
done_case

# 20
new_case "bad kind exits 2 and writes nothing"
report --kind question --title t -- b
expect "exit 2 (got $RC)" [ "$RC" -eq 2 ]
expect "says why" has "$C/err" 'bug or feature'
expect "no stdout" [ ! -s "$C/out" ]
expect "no file" [ "$(nfiles)" -eq 0 ]
done_case

# 21
new_case "missing or empty body or title fails and writes nothing"
report --kind bug --title t
expect "no body: non-zero (got $RC)" [ "$RC" -ne 0 ]
report --kind bug --title t -- '  '
expect "blank body: non-zero (got $RC)" [ "$RC" -ne 0 ]
report --kind bug --title '   ' -- b
expect "blank title: non-zero (got $RC)" [ "$RC" -ne 0 ]
report --kind bug -- b
expect "no title: non-zero (got $RC)" [ "$RC" -ne 0 ]
expect "no stdout" [ ! -s "$C/out" ]
expect "no file" [ "$(nfiles)" -eq 0 ]
expect "no work files left ($(ls -A "$R" 2>/dev/null | tr '\n' ' '))" [ -z "$(ls -A "$R" 2>/dev/null)" ]
done_case

# 22
new_case "body - reads stdin; several words after -- are joined"
printf 'from stdin\nsecond line\n' | env -i HOME="$C/home" PATH=/usr/bin:/bin TMPDIR="$ROOT" "$SH" "$SCRIPT" --kind bug --title t -- - > "$C/out" 2> "$C/err"
RC=$?
expect "exit 0 (got $RC: $(cat "$C/err"))" [ "$RC" -eq 0 ]
expect "stdin body" pytrue "$(rfile)" 'd["body"] == "from stdin\nsecond line"'
report --kind bug --title t -- several words here
expect "joined body" pytrue "$(rfile)" 'd["body"] == "several words here"'
done_case

echo "swarmhub-report tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
