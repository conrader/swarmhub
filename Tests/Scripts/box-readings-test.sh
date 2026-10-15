#!/bin/sh
# Hermetic tests for the P31 D+E recipes: "Bot models" (recipes/models.md), "Box capacity" and "Set the coding job
# limit" (recipes/capacity.md), and the core model recipe's skip check (manager-hermes.md) with an empty value. Each
# fence is cut out of its file, filled the way SwarmHub fills it and run under $BOX_SH in a temp HOME with fixture
# config.yaml files, a fixture coding-job log, a fixture /proc (the recipe's /proc/ paths are pointed at it) and stub
# `nproc`, `df` and `hermes`. No network. Run by BoxReadingsTests under /bin/sh and /bin/dash.
#
#   sh Tests/Scripts/box-readings-test.sh <recipes/models.md> <recipes/capacity.md> <manager-hermes.md>     BOX_SH (default /bin/sh)

MODELS_TEXT=${1:?usage: box-readings-test.sh <models.md> <capacity.md> <manager-hermes.md>}
CAPACITY_TEXT=${2:?usage: box-readings-test.sh <models.md> <capacity.md> <manager-hermes.md>}
CORE_TEXT=${3:?usage: box-readings-test.sh <models.md> <capacity.md> <manager-hermes.md>}
SH=${BOX_SH:-/bin/sh}
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/box-readings-test.XXXXXX") || exit 1
trap 'rm -rf "$ROOT"' EXIT
PASSED=0 FAILED=0

# The fenced block after the first line of file $2 containing $1.
recipe() {
  awk -v marker="$1" 'found == 0 && index($0, marker) { found = 1; next }
    found == 1 && /^```/ { found = 2; next } found == 2 && /^```/ { exit } found == 2 { print }' "$2"
}
MODELS=$(recipe 'Bot models (' "$MODELS_TEXT")
CAPACITY=$(recipe 'Box capacity (' "$CAPACITY_TEXT")
LIMIT=$(recipe 'Set the coding job limit' "$CAPACITY_TEXT")
CHANGE=$(recipe 'Change the model (one bot' "$CORE_TEXT")

# Stubs: `hermes` records every call (none may happen in the read recipes); nproc and df answer like a 2-CPU box.
cat > "$ROOT/stub" <<'STUB'
#!/bin/sh
me=$(basename "$0")
case $me in
  hermes) printf '%s\n' "$*" >> "$HOME/hermes-calls" ;;
  nproc) echo 2 ;;
  df) echo "Filesystem 1048576-blocks Used Available Capacity Mounted on"; echo "/dev/vda1 25000 7600 17400 31% /" ;;
esac
STUB

new_case() {
  NAME=$1; PROBLEMS=
  C=$ROOT/$(echo "$NAME" | tr -c 'A-Za-z0-9\n' '_')
  H=$C/home/.hermes
  mkdir -p "$H/profiles" "$H/swarmhub" "$C/bin" "$C/proc"
  for n in hermes nproc df; do cp "$ROOT/stub" "$C/bin/$n"; chmod 755 "$C/bin/$n"; done
}
# Runs recipe text $1 (with <slots> = $2); /proc/ points at the case's fixture. Output in $C/out.
run() {
  printf '%s\n' "$1" | sed -e "s|/proc/|$C/proc/|g" -e "s|<slots>|$2|g" > "$C/recipe.sh"
  env HOME="$C/home" PATH="$C/bin:/usr/bin:/bin" "$SH" "$C/recipe.sh" > "$C/out" 2> "$C/err"
}
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
is_out() { [ "$(cat "$C/out")" = "$1" ]; }
no_hermes() { [ ! -e "$C/home/hermes-calls" ]; }
mode() { ls -l "$1" | cut -c1-10; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1)); else echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1)); echo "  out: $(cat "$C/out" 2>/dev/null)"; fi
}
# A box with default (pinned), jarvis ('' pin), mira (no delegation section), grok-rapper ("" pin, a comment, quotes),
# lowcost (no config.yaml) and names the list must skip.
models_box() {
  P=$H/profiles
  mkdir -p "$P/jarvis" "$P/mira" "$P/grok-rapper" "$P/lowcost" "$P/Upper" "$P/.retired"
  printf 'model:\n  default: gpt-5.6-terra\n  provider: openai-codex\nterminal:\n  backend: local\ndelegation:\n  model: gpt-6.1-sol\n  provider: openai-codex\n  max_iterations: 50\n' > "$H/config.yaml"
  printf "model:\n  default: gpt-5.6-terra\n  provider: openai-codex\ndelegation:\n  model: ''\n  provider: ''\n" > "$P/jarvis/config.yaml"
  printf 'model:\n  provider: openai-codex\n  default: "grok-4.1"\nagent:\n  max_turns: 90\n' > "$P/mira/config.yaml"
  printf 'model:\n  default: grok-4.1-fast   # quick\n  provider: "xai"\ndelegation:\n  model: ""\n  provider:\n' > "$P/grok-rapper/config.yaml"
  printf 'model:\n  default: evil","x":"y\n' > "$P/Upper/config.yaml"
}

new_case "the recipes are in their files"
expect "models recipe missing" [ -n "$MODELS" ]
expect "capacity recipe missing" [ -n "$CAPACITY" ]
expect "limit recipe missing" [ -n "$LIMIT" ]
expect "core model recipe missing" [ -n "$CHANGE" ]
done_case

new_case "Bot models reads every bot's config.yaml and treats '', \"\" and a missing key as empty"
models_box; run "$MODELS"
expect "line" is_out '{"op":"models","list":[{"name":"default","model":"gpt-5.6-terra","provider":"openai-codex","sub_model":"gpt-6.1-sol","sub_provider":"openai-codex"},{"name":"grok-rapper","model":"grok-4.1-fast","provider":"xai","sub_model":"","sub_provider":""},{"name":"jarvis","model":"gpt-5.6-terra","provider":"openai-codex","sub_model":"","sub_provider":""},{"name":"mira","model":"grok-4.1","provider":"openai-codex","sub_model":"","sub_provider":""}]}'
expect "no hermes start" no_hermes
expect "stderr" [ ! -s "$C/err" ]
done_case

new_case "Bot models keeps JSON intact on a hostile value"
models_box; printf 'model:\n  default: a"b\\c$(id)`x`\n  provider: p q\n' > "$H/profiles/mira/config.yaml"; run "$MODELS"
expect "mira row" grep -Fq '{"name":"mira","model":"abcidx","provider":"pq","sub_model":"","sub_provider":""}' "$C/out"
expect "one line" [ "$(wc -l < "$C/out")" -eq 1 ]
done_case

new_case "Bot models on an empty box"
rmdir "$H/profiles"; mkdir "$H/profiles"; run "$MODELS"
expect "line" is_out '{"op":"models","list":[]}'
done_case

LOG_LINE() { printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
new_case "Box capacity reads nproc, meminfo, df, loadavg, coding.conf and the log, dropping bot and agent"
printf 'MemTotal:        3984528 kB\nMemFree:          301000 kB\nMemAvailable:    1413280 kB\n' > "$C/proc/meminfo"
printf '0.42 0.30 0.21 1/180 4242\n' > "$C/proc/loadavg"
printf 'TIMEOUT=900\nSLOTS=2\n' > "$H/swarmhub/coding.conf"
{ LOG_LINE 2026-10-14T08:00:00Z coder claude 0 41 210 0 -
  LOG_LINE 2026-10-14T09:00:00Z coder codex 120 300 480 1 claude
  LOG_LINE bad coder claude 0 1 1 0 -
  printf 'short\tline\n'
  LOG_LINE 2026-10-15T01:02:03Z jarvis hermes x 5 5 0 -
  LOG_LINE 2026-10-15T01:02:03Z jarvis hermes 3 5 600 124 -; } > "$H/swarmhub/coding-jobs.log"
run "$CAPACITY"
expect "line" is_out '{"op":"box_capacity","cpus":2,"mem_total_mb":3891,"mem_avail_mb":1380,"disk_free_mb":17400,"load1":"0.42","slots":2,"jobs":[["2026-10-14T08:00:00Z",0,41,210,0],["2026-10-14T09:00:00Z",120,300,480,1],["2026-10-15T01:02:03Z",3,5,600,124]]}'
expect "no bot or agent names" eval '! grep -Eq "coder|jarvis|claude|codex|hermes\"" "$C/out"'
expect "no hermes start" no_hermes
done_case

new_case "Box capacity with no coding.conf and no log"
printf 'MemTotal: 2048000 kB\nMemAvailable: 1024000 kB\n' > "$C/proc/meminfo"; printf '1.05 0.9 0.8 1/90 7\n' > "$C/proc/loadavg"
run "$CAPACITY"
expect "line" is_out '{"op":"box_capacity","cpus":2,"mem_total_mb":2000,"mem_avail_mb":1000,"disk_free_mb":17400,"load1":"1.05","slots":null,"jobs":[]}'
done_case

new_case "Box capacity reads only the last 200 log lines"
printf 'MemTotal: 2048000 kB\nMemAvailable: 1024000 kB\n' > "$C/proc/meminfo"; printf '0.00 0 0 1/1 1\n' > "$C/proc/loadavg"
i=0; while [ $i -lt 250 ]; do LOG_LINE 2026-10-15T00:00:00Z b a $i 1 1 0 -; i=$((i + 1)); done > "$H/swarmhub/coding-jobs.log"
run "$CAPACITY"
expect "200 rows" [ "$(grep -o '\["2026' "$C/out" | wc -l | tr -d ' ')" = 200 ]
expect "first kept is line 51" grep -Fq '"jobs":[["2026-10-15T00:00:00Z",50,1,1,0]' "$C/out"
done_case

new_case "Set the coding job limit keeps other lines, writes 0600"
printf 'TIMEOUT=900\nSLOTS=1\nSLOTS=4\n' > "$H/swarmhub/coding.conf"; chmod 644 "$H/swarmhub/coding.conf"
run "$LIMIT" 3
expect "exit" [ ! -s "$C/err" ]
expect "content" [ "$(cat "$H/swarmhub/coding.conf")" = "$(printf 'TIMEOUT=900\nSLOTS=3')" ]
expect "mode" [ "$(mode "$H/swarmhub/coding.conf")" = "-rw-------" ]
expect "no temp file" [ ! -e "$H/swarmhub/coding.conf.swarmhub-new" ]
done_case

new_case "Set the coding job limit creates the file"
rm -rf "$H/swarmhub"; run "$LIMIT" 2
expect "content" [ "$(cat "$H/swarmhub/coding.conf")" = "SLOTS=2" ]
expect "mode" [ "$(mode "$H/swarmhub/coding.conf")" = "-rw-------" ]
done_case

new_case "Set the coding job limit refuses 0 and non-numbers"
printf 'SLOTS=2\n' > "$H/swarmhub/coding.conf"
for bad in 0 07 "2;id" "" x; do
  run "$LIMIT" "$bad"
  expect "kept for '$bad'" [ "$(cat "$H/swarmhub/coding.conf")" = "SLOTS=2" ]
done
done_case

# The core model recipe with SwarmHub's fills; $1 = MODEL, $2 = PROV, $3 = KM, $4 = KP, $5 = names.
change() {
  printf '%s\n' "$CHANGE" | sed -e "s|^export MODEL=.*|export MODEL='$1' PROV='$2' KM=$3 KP=$4|" -e "s|<names>|$5|" > "$C/recipe.sh"
  ( cd "$C/home" && env HOME="$C/home" PATH="$C/bin:/usr/bin:/bin" "$SH" "$C/recipe.sh" > "$C/out" 2> "$C/err" )
}
calls() { sort "$C/home/hermes-calls" 2>/dev/null | tr '\n' '|'; }

new_case "clearing the sub-agent pin skips '', \"\" and a missing key and clears a real pin"
models_box; change "" "" delegation.model delegation.provider "default jarvis mira grok-rapper"
expect "log" [ "$(sort "$H/swarmhub-model.log" | tr '\n' ' ')" = "DONE default ok grok-rapper ok jarvis ok mira ok " ]
expect "only default's pin is cleared" [ "$(calls)" = "-p default config set delegation.model |-p default config set delegation.provider |" ]
done_case

new_case "a pin a bot already has is skipped, quoted or not"
models_box; change gpt-6.1-sol openai-codex delegation.model delegation.provider "default jarvis"
expect "only jarvis changes" [ "$(calls)" = "-p jarvis config set delegation.model gpt-6.1-sol|-p jarvis config set delegation.provider openai-codex|" ]
models_box; rm -f "$C/home/hermes-calls"; change grok-4.1 openai-codex model.default model.provider "mira"
expect "mira's quoted model is skipped" [ ! -e "$C/home/hermes-calls" ]
done_case

echo "box-readings tests under $SH: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
