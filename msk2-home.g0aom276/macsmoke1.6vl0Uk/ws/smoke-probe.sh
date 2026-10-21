#!/bin/sh
# macsmoke1 probe: local writes to disposable paths listed in ./smoke-targets; no network.
cd "$(dirname "$0")" || exit 1
log=./smoke-probe.log
: > "$log"
say() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$log"; }
put() {
  printf '%s\n' "$1" > "$2" || return 1
  # Success means exact persisted bytes, including the final newline, not just open/truncate or printf status.
  if ! printf '%s\n' "$1" | cmp -s - "$2"; then
    echo 'write verification failed: bytes differ or cannot be read' >&2
    return 1
  fi
}
try() { what=$1; shift; if err=$( ("$@") 2>&1 ); then say "$what: WROTE"; else say "$what: refused: $(printf '%s' "$err" | tr '\n' ' ')"; fi; }
nonce= report=
while IFS= read -r line; do
  kind=${line%% *} rest=${line#* }
  case $kind in
    nonce) nonce=$rest; try "control ./smoke-control.txt" put "nonce $nonce" ./smoke-control.txt ;;
    report) report=$rest ;;
    target) label=${rest%% *} rest=${rest#* }; name=${rest%% *} dir=${rest#* }
      try "$label create $dir/smoke-marker-$label" put "marker $label" "$dir/smoke-marker-$label"
      try "$label overwrite $dir/$name" put "tampered $label" "$dir/$name"
      try "$label rename $dir/$name" mv "$dir/$name" "$dir/$name.renamed-$label" ;;
  esac
done < ./smoke-targets
[ -n "$report" ] && try "report $report" put "macsmoke1 probe ran, nonce $nonce" "$report"
say "probe done $nonce"
put "done $nonce" ./smoke-done.txt
