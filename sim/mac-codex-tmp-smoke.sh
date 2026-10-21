#!/bin/sh
# macsmoke1: real-Codex /tmp-exclusion smoke test for the swarmhub-coding launcher on the Mac (FIXES18-REPORT.md,
# "Mac real-Codex /tmp exclusion smoke test"; REVIEW-CLAUDE-XREV3 finding 3). POSIX sh, python3 >= 3.9.
#
#   sh sim/mac-codex-tmp-smoke.sh [--model <id>] [--effort low|medium|high|xhigh] [--timeout <s>] [--outside-dir <dir>]
#                                 [--code-job <path>] [--stub <mode>] (modes listed in usage)
#
# Harmless: every file it creates, and every file the probe attacks, is in a disposable directory under /tmp or
# $TMPDIR, except one macsmoke1.XXXXXX directory in --outside-dir (default $HOME) for the non-fallback launcher run.
# Cleanup removes only those directories, by exact path. Codex is asked to run one local script, no network.
# The oracle is host-side file state (sentinel hashes, directory listings), never the model's prose.
# Output goes to stdout and to $SMOKE_LOG (default ./macsmoke1-<UTC>.log; SMOKE_LOG=- for none). The last line is
#   smoke: result=PASS|FAIL|REPORT_FAILURE|INCONCLUSIVE enforced=<list> writable=<list> unexpected=<list> codex=<version> ...
# Exit 1 whenever a path the settings should protect was writable (FAIL wins over all other results, early stops
# included); REPORT_FAILURE also exits 1 (completed CLI with invalid report); INCONCLUSIVE and PASS exit 0; 64 usage.

# Sends signals: run only inside an isolated PID namespace (Linux) or the macOS signal guard; see sim/ISOLATION.md.
/usr/bin/python3 -I -B "$(dirname "$0")/sim_isolation.py" --check > /dev/null || exit 78  # absolute: PATH cannot fake it
if [ -z "${SMOKE_TEED:-}" ] && [ "${SMOKE_LOG:-}" != - ]; then
  SMOKE_TEED=1; export SMOKE_TEED
  log=${SMOKE_LOG:-./macsmoke1-$(date -u +%Y%m%dT%H%M%SZ).log}
  rcf=$(mktemp "/tmp/macsmoke1-rc.XXXXXX") || exit 1
  { /bin/sh "$0" "$@"; echo $? > "$rcf"; } 2>&1 | tee "$log"
  rc=$(cat "$rcf"); rm -f "$rcf"; exit "${rc:-1}"
fi

usage() { echo "usage: sh $0 [--model <id>] [--effort low|medium|high|xhigh] [--timeout <s>] [--outside-dir <dir>] [--code-job <path>] [--stub [enforce|leaky|timeout|leaky-timeout|incomplete|stderr-only|missing-report|unchanged-report|emptied-report|existing-report-denied|rewrite-denied|cj-fail|cj-timeout]]" >&2; exit 64; }
HERE=$(cd "$(dirname "$0")" && pwd -P) || exit 1
MODEL= EFFORT=high TIMEOUT=300 OUTSIDE= STUB= CODEJOB=$HERE/../Resources/Skills/swarmhub-coding/scripts/code-job
while [ $# -gt 0 ]; do
  case $1 in
    --model|--effort|--timeout|--outside-dir|--code-job)
      [ $# -ge 2 ] || usage
      case $1 in --model) MODEL=$2 ;; --effort) EFFORT=$2 ;; --timeout) TIMEOUT=$2 ;; --outside-dir) OUTSIDE=$2 ;; --code-job) CODEJOB=$2 ;; esac
      shift 2 ;;
    --stub) STUB=enforce; case ${2:-} in enforce|leaky|timeout|leaky-timeout|incomplete|stderr-only|missing-report|unchanged-report|emptied-report|existing-report-denied|rewrite-denied|cj-fail|cj-timeout) STUB=$2; shift ;; esac; shift ;;
    *) usage ;;
  esac
done
case $EFFORT in low|medium|high|xhigh) ;; *) usage ;; esac
case $TIMEOUT in ''|*[!0-9]*|0) usage ;; esac
case $MODEL in *[!A-Za-z0-9_./:-]*) usage ;; esac

umask 077
say() { printf '%s\n' "$*"; }
q() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
argv_line() { line=; for a do line="$line $(q "$a")"; done; printf '%s\n' "${line# }"; }
phys() { (cd "$1" 2>/dev/null && pwd -P); }
under() { case $2/ in "$1"/*) return 0 ;; esac; return 1; }  # $2 is $1 or below it (physical paths)
hashf() { if [ -f "$1" ]; then python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; else echo missing; fi; }
redact() { sed -E 's/(sk-|sess-|Bearer )[A-Za-z0-9._-]{6,}/\1[REDACTED]/g'; }
# Runs argv in its own session, killed (group) after $1 seconds: exit 124. macOS has no timeout(1).
cap() {
  python3 -c '
import os, signal, subprocess, sys
p = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    rc = p.wait(timeout=float(sys.argv[1]))
except BaseException:
    for sig in (signal.SIGTERM, signal.SIGKILL):
        if p.returncode is not None:
            break  # Reaped: the group number may be reused now. Unreaped, the leader pins it.
        try:
            os.killpg(p.pid, sig); p.wait(timeout=5); break
        except Exception:
            pass
    sys.exit(124)
sys.exit(rc if rc >= 0 else 128 - rc)' "$@"
}

NL='
'
CLEAN= ENFORCED= WRITABLE= UNEXPECTED= INCONC= NOTES= CODEXV=unknown TMP_PHYS= TD_PHYS= OUT_PHYS= OUT_MADE=
REPORT_FAILURES=
# One mktemp result per line, exactly as created; paths with a newline never get here (refused up front).
register() { CLEAN="$CLEAN$NL$1"; }
add() { eval "_v=\$$1"; eval "$1=\"\${_v:+\$_v,}\$2\""; }
# A registered path may be removed only when it is absolute, named like this run's directories, and sits directly
# in /tmp, /private/tmp or $TMPDIR (physically) - or is the one directory this run created in the outside base.
removable() {
  case $1 in /?*/?*) ;; *) return 1 ;; esac
  case /$1/ in */./*|*/../*) return 1 ;; esac
  case ${1##*/} in macsmoke1*|code-job.*) ;; *) return 1 ;; esac
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  rp=$(phys "${1%/*}") || return 1
  if [ -n "$OUT_MADE" ] && [ "$1" = "$OUT_MADE" ]; then [ "$rp" = "$OUT_PHYS" ]; return; fi
  for r in /tmp /private/tmp "$TMP_PHYS" "$TD_PHYS"; do
    [ -n "$r" ] && [ "$r" != / ] && [ "$rp" = "$r" ] && return 0
  done
  return 1
}
cleanup() {
  [ -n "$CLEAN" ] || return 0
  # No word splitting or globbing: split on newlines only, with pathname expansion off, in a subshell.
  (set -f; IFS=$NL; left= refused=
   for d in $CLEAN; do
     { [ -e "$d" ] || [ -L "$d" ]; } || continue
     if ! removable "$d"; then refused="$refused [$d]"; continue; fi
     chmod -R u+rwx "$d" 2>/dev/null
     rm -rf "$d"
     { [ -e "$d" ] || [ -L "$d" ]; } && left="$left [$d]"
   done
   [ -z "$refused" ] || say "cleanup: REFUSED (not a disposable directory of this run, left in place)$refused"
   [ -z "$left" ] || say "cleanup: LEFT$left"
   [ -n "$left$refused" ] || say "cleanup: all disposable directories removed")
  CLEAN=
}
trap cleanup EXIT
# shellcheck disable=SC2317  # invoked from the INT/TERM traps
interrupted() { [ -n "$UNEXPECTED" ] && summary FAIL "interrupted"; cleanup; trap - EXIT; exit "$1"; }
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
summary() {  # $1 result, $2 reason. A detected unexpected write is FAIL whatever stopped the run.
  res=$1; [ -n "$UNEXPECTED" ] && res=FAIL
  cleanup; trap - EXIT
  say "smoke: result=$res${2:+ reason=$2} enforced=${ENFORCED:-none} writable=${WRITABLE:-none} unexpected=${UNEXPECTED:-none} codex=$CODEXV${INCONC:+ inconclusive=$INCONC}${REPORT_FAILURES:+ report-failures=$REPORT_FAILURES}"
  case $res in FAIL|REPORT_FAILURE) exit 1 ;; esac
  exit 0
}

say "== macsmoke1 $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
if command -v sw_vers >/dev/null 2>&1; then say "macOS: $(sw_vers -productVersion) ($(sw_vers -buildVersion)) $(uname -m)"; else say "os: $(uname -srm)"; fi
command -v python3 >/dev/null 2>&1 || { say "python3 missing"; summary INCONCLUSIVE python3-missing; }
say "python3: $(command -v python3) $(python3 --version 2>&1)"
say "sh: /bin/sh -> $(ls -l /bin/sh | sed 's/.* //') ${BASH_VERSION:+bash $BASH_VERSION}"
say "repo: $(git -C "$HERE/.." rev-parse --short HEAD 2>/dev/null || echo unknown) code-job: $CODEJOB"
[ -f "$CODEJOB" ] || summary INCONCLUSIVE code-job-missing

TMP_PHYS=$(phys /tmp) || summary INCONCLUSIVE no-tmp
TMPP=${TMPDIR:-/tmp}; TMPP=${TMPP%/}; [ -n "$TMPP" ] || TMPP=/tmp
case $TMPP in /*) ;; *) summary INCONCLUSIVE tmpdir-not-absolute ;; esac
case $TMPP$TMP_PHYS in *"$NL"*) summary INCONCLUSIVE tmpdir-has-newline ;; esac
TD_PHYS=$(phys "$TMPP") || summary INCONCLUSIVE tmpdir-missing
say "/tmp -> $TMP_PHYS; TMPDIR=${TMPDIR-<unset>} -> $TD_PHYS"
# cj-outside needs HOME and the workspace outside /tmp and $TMPDIR: one macsmoke1.XXXXXX dir in --outside-dir or $HOME.
if [ -n "$OUTSIDE" ]; then
  OUT_PHYS=$(phys "$OUTSIDE") || summary INCONCLUSIVE outside-dir-missing
  case $OUT_PHYS in *"$NL"*) summary INCONCLUSIVE outside-dir-has-newline ;; esac
  if under "$TMP_PHYS" "$OUT_PHYS" || under "$TD_PHYS" "$OUT_PHYS"; then summary INCONCLUSIVE outside-dir-is-temporary; fi
else
  OUT_PHYS=$(phys "${HOME:-/nonexistent}") || OUT_PHYS=
  case $OUT_PHYS in *"$NL"*|/) OUT_PHYS= ;; esac
  if [ -n "$OUT_PHYS" ] && { under "$TMP_PHYS" "$OUT_PHYS" || under "$TD_PHYS" "$OUT_PHYS"; }; then OUT_PHYS=; fi
  [ -n "$OUT_PHYS" ] || say "HOME (${HOME-<unset>}) is missing or temporary: cj-outside needs --outside-dir <dir>"
fi
say "outside base for cj-outside: ${OUT_PHYS:-none}"
[ "$TD_PHYS" = "$TMP_PHYS" ] && NOTES="TMPDIR is /tmp: exclude_tmpdir_env_var cannot be attributed"

BASE=$(mktemp -d /tmp/macsmoke1.XXXXXX) || summary INCONCLUSIVE mktemp; register "$BASE"
mkdir "$BASE/bin" "$BASE/skill" "$BASE/skill/swarmhub-coding" || summary INCONCLUSIVE mkdir
# code-job from a copy without swarmhub-messages: no policy lookups and no wake messages leave the box.
cp -R "$(dirname "$CODEJOB")" "$BASE/skill/swarmhub-coding/scripts" || summary INCONCLUSIVE copy
# The report as python3 (the launcher contract's states) and the shell see it; on macOS also its flags, xattrs and ACL.
# Run by the shim when the CLI exits and by the host after code-job, so a failed report check is placed in time.
cat > "$BASE/report-state" <<'EOF'
#!/bin/sh
[ -n "${1:-}" ] || { echo none; exit 0; }
py=$(python3 -c 'import errno, os, stat, sys
try:
    info = os.stat(sys.argv[1])
    if not stat.S_ISREG(info.st_mode):
        print("not-regular")
    elif info.st_size == 0:
        print("empty")
    else:
        open(sys.argv[1], "rb").close()
        print("bytes-%d" % info.st_size)
except (FileNotFoundError, NotADirectoryError):
    print("missing")
except OSError as error:
    print("unreadable-" + errno.errorcode.get(error.errno, str(error.errno)))' "$1" 2>/dev/null) || py=python-failed
sh=missing
if [ -f "$1" ]; then sh=empty; [ -s "$1" ] && sh=nonempty; elif [ -e "$1" ]; then sh=not-regular; fi
printf 'python:%s sh:%s\n' "$py" "$sh"
[ "$sh" = missing ] && exit 0
case $(uname -s) in Darwin) ls -lndO@e "$1" ;; *) ls -lnd "$1" ;; esac 2>&1 | sed 's/^/ls: /'
EOF
chmod 755 "$BASE/report-state"
CH=${CODEX_HOME:-$HOME/.codex}
if [ -n "$STUB" ]; then
  say "STUB MODE ($STUB): argv-recording stand-in, permission-bit sandbox emulation; says nothing about real Codex"
  mkdir "$BASE/stub"
  printf '#!/bin/sh\nexec python3 %s "$@"\n' "$(q "$HERE/mac-codex-tmp-smoke-stub.py")" > "$BASE/stub/codex"
  chmod 755 "$BASE/stub/codex"; CODEX=$BASE/stub/codex
  SMOKE_STUB_MODE=$STUB; export SMOKE_STUB_MODE
else
  CODEX=$(command -v codex) || summary INCONCLUSIVE codex-missing
fi
say "codex: $CODEX -> $(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$CODEX")"
v=$(cap 60 "$CODEX" --version < /dev/null 2>&1) || summary INCONCLUSIVE "codex-version-failed"
CODEXV=$(printf '%s' "$v" | tail -n 1 | tr -c 'A-Za-z0-9._()+-' '_' | sed 's/_*$//')
say "codex --version: $v"
# Exit status and a fixed phrase only: the status text can name the account or a masked key, so it is never shown.
cap 60 "$CODEX" login status < /dev/null > "$BASE/login" 2>&1; lrc=$?
if grep -qi 'not logged in' "$BASE/login"; then summary INCONCLUSIVE codex-not-logged-in
elif [ "$lrc" -eq 0 ] && grep -qi 'logged in' "$BASE/login"; then say "codex login status: logged in"
else say "codex login status: unknown (exit $lrc); a login failure would show in the first run"; fi
rm -f "$BASE/login"
if [ -z "$STUB" ] && [ -f "$CH/config.toml" ]; then
  cfg=$(grep -nE '^[[:space:]]*(writable_roots|exclude_slash_tmp|exclude_tmpdir_env_var|sandbox_mode|profile)[[:space:]]*=|^\[(sandbox_workspace_write|profiles)' "$CH/config.toml")
  say "codex config sandbox keys (applies to the launcher too): ${cfg:-none}"
fi
say "model: ${MODEL:-<none: the codex configured default>} effort: $EFFORT timeout: ${TIMEOUT}s"

PROMPT='Run this exact command once with your shell tool, then reply DONE: sh ./smoke-probe.sh
It only touches disposable test files. The script writes and verifies the completion report requested below; retain that report without rewriting it. If the report write fails, describe the failure and stop. Do not retry or work around refused operations. Use no network.'
PLACEHOLDER=macsmoke1-codex-default

# The probe runs inside Codex's sandbox and reports each attempt; the host decides from file state afterwards.
write_probe() {
  cat > "$1/smoke-probe.sh" <<'EOF'
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
EOF
}

# A disposable /tmp/code-job.* and $TMPDIR location, each holding a host-owned synthetic git-trust.json.
make_locations() {
  A=$(mktemp -d /tmp/code-job.XXXXXX) && register "$A" &&
  B=$(mktemp -d "$TMPP/macsmoke1-tmpdir.XXXXXX") && register "$B" &&
  LK=$(mktemp -d "$TMPP/macsmoke1-links.XXXXXX") && register "$LK" || summary INCONCLUSIVE mktemp
  for d in "$A" "$B"; do printf '{"synthetic": "macsmoke1 sentinel", "nonce": "%s"}\n' "$NONCE" > "$d/git-trust.json"; done
  ln -s "$A" "$LK/a"; ln -s "$B" "$LK/b"
  HA=$(hashf "$A/git-trust.json") HB=$(hashf "$B/git-trust.json")
  A_P=$(phys "$A") B_P=$(phys "$B")
  A_TMP=yes A_TD=no B_TMP=no B_TD=no
  [ -n "${TMPDIR:-}" ] && under "$TD_PHYS" "$A_P" && A_TD=yes
  [ -n "${TMPDIR:-}" ] && B_TD=yes
  under "$TMP_PHYS" "$B_P" && B_TMP=yes
}
target_lines() {  # label dir: the dir as given, its physical spelling (/private/...), and a symlink alias
  printf 'target %s.given git-trust.json %s\n' "$1" "$2"
  p=$(phys "$2"); [ "$p" != "$2" ] && printf 'target %s.phys git-trust.json %s\n' "$1" "$p"
  printf 'target %s.link git-trust.json %s\n' "$1" "$3"
}
check_location() {  # dir recorded-hash -> prints "denied" or "writable: <evidence>"
  extra=$(ls -A "$1" | grep -vx git-trust.json | tr '\n' ' ')
  now=$(hashf "$1/git-trust.json")
  if [ "$now" = "$2" ] && [ -z "$extra" ]; then echo denied; return; fi
  state=unchanged; [ "$now" = "$2" ] || state="sentinel $( [ "$now" = missing ] && echo missing || { printf 'now: '; head -c 60 "$1/git-trust.json"; } )"
  echo "writable: $state; new entries: ${extra:-none}"
}
protected() {  # in-/tmp in-$TMPDIR exclude-slash exclude-tmpdir
  [ "$1" = yes ] && [ "$3" != yes ] && return 1
  [ "$2" = yes ] && [ "$4" != yes ] && return 1
  return 0
}
judge() {  # run loc dir hash in-tmp in-td xs xt
  r=$(check_location "$3" "$4")
  say "  $2 ($3): $r"
  eval "R_$(printf '%s' "$1" | tr - _)_$2=\${r%%:*}"
  case $r in writable*) add WRITABLE "$1:$2"
    protected "$5" "$6" "$7" "$8" && { add UNEXPECTED "$1:$2"; say "  !! $2 should be protected in run $1"; } ;;
  *) protected "$5" "$6" "$7" "$8" || say "  note: $2 denied though no exclusion covers it in run $1" ;; esac
}
show() {  # title file
  say "  --- $1 ---"
  if [ -f "$2" ]; then redact < "$2" | sed 's/^/  | /'; else say "  | (none)"; fi
}

# Sets WHY (empty when the run counts): the run exited 0, the probe wrote the control (first) and the completion
# marker (last). A timed-out or failed run never counts, whatever files it managed to write.
completed() {  # rc dir exit-label transcript
  WHY= c=missing m=missing
  [ "$(cat "$2/smoke-control.txt" 2>/dev/null)" = "nonce $NONCE" ] && c=written
  [ "$(cat "$2/smoke-done.txt" 2>/dev/null)" = "done $NONCE" ] && m=written
  [ "$c" = written ] || WHY=tool-not-run
  [ -z "$WHY" ] && [ "$m" != written ] && WHY=probe-incomplete
  [ "$1" -ne 0 ] && WHY=$3-exit-$1
  [ "$1" -eq 124 ] && WHY=timeout
  # 401 as a word only: random mktemp/job names in the transcript (job.x401AbCd) are not a login failure.
  [ -n "$WHY" ] && tail -n 20 "$4" | grep -Eiq 'not logged in|codex login|(^|[^[:alnum:]])401([^[:alnum:]]|$)|unauthorized' && WHY=codex-login
  say "  positive control: $c; completion marker: $m; exit: $1${WHY:+ -> inconclusive ($WHY)}"
  [ -z "$WHY" ]
}

direct_run() {  # name exclude-slash exclude-tmpdir
  NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
  W=$(mktemp -d /tmp/macsmoke1-ws.XXXXXX) || summary INCONCLUSIVE mktemp; register "$W"
  make_locations
  { echo "nonce $NONCE"; target_lines tmp "$A" "$LK/a"; target_lines tmpdir "$B" "$LK/b"; } > "$W/smoke-targets"
  write_probe "$W"
  wp=$(phys "$W"); { under "$wp" "$A_P" || under "$wp" "$B_P"; } && summary INCONCLUSIVE workspace-contains-sentinel
  set -- "$1" "$2" "$3" exec --skip-git-repo-check -c 'sandbox_mode="workspace-write"' -c 'approval_policy="never"'
  [ "$2" = yes ] && set -- "$@" -c sandbox_workspace_write.exclude_slash_tmp=true
  [ "$3" = yes ] && set -- "$@" -c sandbox_workspace_write.exclude_tmpdir_env_var=true
  [ -n "$MODEL" ] && set -- "$@" --model "$MODEL"
  set -- "$@" -c "model_reasoning_effort=\"$EFFORT\"" "$PROMPT"
  run=$1 xs=$2 xt=$3; shift 3
  say ""; say "== run $run: exclude_slash_tmp=$xs exclude_tmpdir_env_var=$xt =="
  say "  workspace: $W ($(phys "$W"))"; say "  /tmp sentinel: $A ($A_P)"; say "  TMPDIR sentinel: $B ($B_P)"
  say "  cwd $W; argv: $(argv_line "$CODEX" "$@")"
  (cd "$W" && unset ANTHROPIC_API_KEY && cap "$TIMEOUT" "$CODEX" "$@") < /dev/null > "$BASE/out-$run" 2>&1; rc=$?
  say "  codex exit: $rc"
  show "codex transcript (stdout+stderr)" "$BASE/out-$run"
  show "probe log (tool side)" "$W/smoke-probe.log"
  judge "$run" tmp "$A" "$HA" "$A_TMP" "$A_TD" "$xs" "$xt"
  judge "$run" tmpdir "$B" "$HB" "$B_TMP" "$B_TD" "$xs" "$xt"
  completed "$rc" "$W" codex "$BASE/out-$run" && return 0
  add INCONC "$run:$WHY"
  return 1
}

cj_run() {  # name home dir fallback(yes|no) with-sentinels(yes|no)
  run=$1 H=$2 D=$3 fb=$4 ab=$5
  NONCE=$(python3 -c 'import secrets; print(secrets.token_hex(8))')
  { echo "nonce $NONCE"; echo "report $(phys "$D")/REPORT.txt"; } > "$D/smoke-targets"
  if [ "$ab" = yes ]; then make_locations; { target_lines tmp "$A" "$LK/a"; target_lines tmpdir "$B" "$LK/b"; } >> "$D/smoke-targets"; fi
  write_probe "$D"
  # Negative fixtures only: pre-existing empty report, or stale bytes restored by the stub after the probe.
  [ "$STUB" = existing-report-denied ] && : > "$D/REPORT.txt"
  [ "$STUB" = unchanged-report ] && printf 'stale smoke report\n' > "$D/REPORT.txt"
  ls -d /tmp/code-job.* > "$BASE/pre-$run" 2>/dev/null
  say ""; say "== run $run: code-job, HOME=$H, --dir $D (expect fallback=$fb) =="
  set -- /bin/sh "$BASE/skill/swarmhub-coding/scripts/code-job" --bot macsmoke1 --order codex --dir "$D" \
    --model "${MODEL:-$PLACEHOLDER}" --effort "$EFFORT" --report REPORT.txt --verify true --timeout "$TIMEOUT" -- "$PROMPT"
  say "  argv: $(argv_line "$@")"
  [ -n "$MODEL" ] || say "  (the host shim drops --model $PLACEHOLDER so codex uses its configured default)"
  ns=; [ -n "$STUB" ] && ns=0
  (unset ANTHROPIC_API_KEY CODE_JOB_VERIFY CODE_JOB_MODEL CODE_JOB_REPORT
   HOME=$H CODEX_HOME=$CH PATH=$BASE/bin:$PATH SMOKE_REAL_CODEX=$CODEX SMOKE_PRE=$BASE/pre-$run \
   SMOKE_SHIM_RECORD=$BASE/shim-$run SMOKE_PLACEHOLDER=$PLACEHOLDER SWARMHUB_VERIFY_NAMESPACES=${ns:-${SWARMHUB_VERIFY_NAMESPACES:-}}
   SMOKE_REPORT_STATE=$BASE/report-state
   export HOME CODEX_HOME PATH SMOKE_REAL_CODEX SMOKE_PRE SMOKE_SHIM_RECORD SMOKE_PLACEHOLDER SWARMHUB_VERIFY_NAMESPACES SMOKE_REPORT_STATE
   [ -n "$SWARMHUB_VERIFY_NAMESPACES" ] || unset SWARMHUB_VERIFY_NAMESPACES
   cap $((TIMEOUT + 120)) "$@") < /dev/null > "$BASE/out-$run" 2>&1; rc=$?
  say "  code-job exit: $rc"
  show "code-job + codex transcript (stdout+stderr)" "$BASE/out-$run"
  show "probe log (tool side)" "$D/smoke-probe.log"
  show "host shim record" "$BASE/shim-$run"
  # Preserve the launcher's actual contract results before cleanup. The old merged transcript hid which
  # half of exit 65 failed (report freshness or stdout); never infer it from the model's prose.
  vstate=
  for job in "$H"/.hermes/swarmhub/job-completions/job.*; do
    [ -d "$job" ] || continue
    say "  --- launcher completion record ---"
    for field in sandbox-warning status report report-before-state report-before report-sha256 report-valid report-state report-bytes report-exists report-final \
      cli-exit exit verify-exit; do
      say "  | $field=$(cat "$job/$field" 2>/dev/null || echo unavailable)"
    done
    [ "$(cat "$job/report-valid" 2>/dev/null)" = false ] && vstate=$(cat "$job/report-state" 2>/dev/null)
    # Where the report went wrong: probe (log above), CLI exit (shim), launcher check, launcher finish, host now.
    say "  report timeline: cli-exit $(sed -n 's/^report-at-cli-exit=//p' "$BASE/shim-$run" 2>/dev/null);" \
      "verify $(cat "$job/report-state" 2>/dev/null || echo unavailable) ($(cat "$job/report-bytes" 2>/dev/null || echo -) bytes);" \
      "finish $(cat "$job/report-final" 2>/dev/null || echo unavailable); host now $("$BASE/report-state" "$(cat "$job/report")" | head -n 1)"
  done
  ok=yes rec=$BASE/shim-$run u0=$UNEXPECTED
  [ "$ab" = yes ] && { judge "$run" tmp "$A" "$HA" "$A_TMP" "$A_TD" yes yes; judge "$run" tmpdir "$B" "$HB" "$B_TMP" "$B_TD" yes yes; }
  if [ ! -f "$rec" ]; then
    say "  host shim record missing (the launcher may have killed the shim)"
    completed "$rc" "$D" code-job "$BASE/out-$run"
    add INCONC "$run:${WHY:-codex-not-recorded}"; return 1
  fi
  snap=$(sed -n 's/^snapshot=//p' "$rec") sp=$(sed -n 's/^phys=//p' "$rec")
  keys=$(grep -cE '^arg=sandbox_workspace_write\.exclude_(slash_tmp|tmpdir_env_var)=true$' "$rec")
  if [ "$fb" = yes ] && [ "$keys" -ne 2 ]; then say "  !! fallback run but $keys of 2 exclusion keys reached codex"; add NOTES "$run:keys=$keys"; ok=no; fi
  if [ "$fb" = no ] && [ "$keys" -ne 0 ]; then say "  note: non-fallback run but codex got $keys exclusion keys"; add NOTES "$run:keys=$keys"; ok=no; fi
  case $snap in ''|none|ambiguous) say "  launcher snapshot not identified ($snap)"; add INCONC "$run:snapshot-$snap"; return 1 ;; esac
  if [ "$fb" = yes ]; then under "$TMP_PHYS" "$sp" || { say "  !! fallback scratch $sp is not in system /tmp"; ok=no; }
  else under "$(phys "$H")/.hermes/swarmhub/scratch" "$sp" || { say "  !! scratch $sp is not in \$HOME/.hermes/swarmhub/scratch"; ok=no; }; fi
  under "$(phys "$D")" "$sp" && { say "  !! scratch $sp is inside the workspace"; ok=no; }
  if [ "$(sed -n 's/^pre=//p' "$rec")" = "$(sed -n 's/^post=//p' "$rec")" ] && [ "$(sed -n 's/^markers=//p' "$rec")" = "" ]; then
    say "  launcher snapshot $snap: denied (hash unchanged, no new entries)"
  else
    say "  !! launcher snapshot $snap: WRITABLE"; add WRITABLE "$run:snapshot"; add UNEXPECTED "$run:snapshot"
  fi
  crc=$(sed -n 's/^codex-exit=//p' "$rec"); case $crc in ''|*[!0-9]*) crc=255 ;; esac
  [ "$rc" -eq 0 ] && [ "$crc" -ne 0 ] && rc=$crc
  # A completed CLI with a failed completion contract is a named job failure, not uncertain isolation evidence.
  if [ "$rc" -eq 65 ] && [ "$crc" -eq 0 ] && [ -n "$vstate" ] && [ "$vstate" != ok ]; then
    label=report; [ "$fb" = yes ] && label=fallback-report
    add REPORT_FAILURES "$run:$label-$vstate"
    say "  report contract: REPORT_FAILURE ($label-$vstate); launcher exit 65"
    return 1
  fi
  completed "$rc" "$D" code-job "$BASE/out-$run" || {
    add INCONC "$run:$WHY"; return 1; }
  [ "$UNEXPECTED" = "$u0" ] || return 1
  if [ "$ok" = yes ]; then add ENFORCED "$run"; else add INCONC "$run:launcher-layout"; fi
}

# Host-side wrapper named `codex` for code-job runs: records argv, finds the launcher's scratch ($T) by its
# git-trust.json naming this workspace, adds it to the probe targets, and checks it again after codex exits.
cat > "$BASE/bin/codex" <<'EOF'
#!/bin/sh
ws=$(pwd -P) snap=
for d in /tmp/code-job.* "$HOME"/.hermes/swarmhub/scratch/code-job.*; do
  [ -f "$d/git-trust.json" ] || continue
  grep -Fxq "$d" "$SMOKE_PRE" 2>/dev/null && continue
  grep -Fq "\"workspace\": \"$ws\"" "$d/git-trust.json" || continue
  if [ -n "$snap" ]; then snap=ambiguous; break; fi
  snap=$d
done
sp=
case $snap in ''|ambiguous) ;; *)
  sp=$(cd "$snap" && pwd -P)
  printf 'target snap.given git-trust.json %s\n' "$snap" >> smoke-targets
  [ "$sp" != "$snap" ] && printf 'target snap.phys git-trust.json %s\n' "$sp" >> smoke-targets ;;
esac
h() { if [ -f "$1" ]; then python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; else echo missing; fi; }
pre=$(h "$snap/git-trust.json")
args=$(for a do printf 'arg=%s\n' "$a"; done)
held= started=
for a do
  [ -z "$started" ] && { set --; started=1; }
  if [ -n "$held" ]; then held=; [ "$a" = "$SMOKE_PLACEHOLDER" ] || set -- "$@" --model "$a"; continue; fi
  [ "$a" = --model ] && { held=1; continue; }
  set -- "$@" "$a"
done
# Keep the CLI's stdout separate from its stderr transcript for diagnosis. The launcher requires stdout as
# well as a fresh report; a cooperative probe must not depend on the model choosing to print final prose there.
"$SMOKE_REAL_CODEX" "$@" > "$SMOKE_SHIM_RECORD.stdout"; rc=$?
cat "$SMOKE_SHIM_RECORD.stdout"
stdout_bytes=$(wc -c < "$SMOKE_SHIM_RECORD.stdout" | tr -d ' ')
# The report (code-job exports its path) as soon as the CLI exits, before the launcher checks it.
rstate=$("$SMOKE_REPORT_STATE" "${SWARMHUB_REPORT_FILE:-}")
post=$(h "$snap/git-trust.json")
markers=$(ls -A "$snap" 2>/dev/null | grep -E '^smoke-|\.renamed-' | tr '\n' ' ')
rm -f "$SMOKE_SHIM_RECORD"
printf 'snapshot=%s\nphys=%s\npre=%s\npost=%s\nmarkers=%s\ncodex-exit=%s\ncodex-stdout-bytes=%s\nreport=%s\nreport-at-cli-exit=%s\n%s\n' \
  "${snap:-none}" "$sp" "$pre" "$post" "$markers" "$rc" "$stdout_bytes" "${SWARMHUB_REPORT_FILE:-}" "$rstate" "$args" > "$SMOKE_SHIM_RECORD"
# Harness output, not completion evidence: code-job still checks the report, and the host still requires
# both nonce files, both exit statuses, the exclusion argv and every unchanged protected target.
printf 'smoke shim: codex exited %s\n' "$rc"
exit "$rc"
EOF
chmod 755 "$BASE/bin/codex"

# Steps 2-4: launcher settings, exclusions off (control), then each exclusion alone.
if ! direct_run on yes yes; then
  case $INCONC in *codex-login*|*codex-exit-*|*timeout*) summary INCONCLUSIVE "first-run:${INCONC#on:}" ;; esac
fi
direct_run off no no
direct_run slash yes no
direct_run tmpdir no yes
for k in slash tmpdir; do
  for loc in tmp tmpdir; do
    eval "on=\${R_on_$loc:-} off=\${R_off_$loc:-} alone=\${R_${k}_$loc:-}"
    if [ "$loc" = tmp ]; then intmp=$A_TMP intd=$A_TD; else intmp=$B_TMP intd=$B_TD; fi
    # Attributable: the location sits in exactly the root this key removes.
    if [ "$k" = slash ]; then [ "$intmp" = yes ] && [ "$intd" = no ] || continue; key=exclude_slash_tmp
    else [ "$intd" = yes ] && [ "$intmp" = no ] || continue; key=exclude_tmpdir_env_var; fi
    [ "$off" = writable ] && [ "$alone" = denied ] && [ "$on" = denied ] && { case ,$ENFORCED, in *,$key,*) ;; *) add ENFORCED "$key" ;; esac; }
  done
done
for key in exclude_slash_tmp exclude_tmpdir_env_var; do
  case ,$ENFORCED, in *,$key,*) ;; *) add INCONC "$key:unattributed" ;; esac
done

# Step 5: the real launcher, HOME-scoped (fallback to system /tmp) and a sibling workspace with HOME in temp.
H1=$(mktemp -d "$TMPP/macsmoke1-home.XXXXXX") || summary INCONCLUSIVE mktemp; register "$H1"
cj_run cj-home "$H1" "$H1" yes yes
H2=$(mktemp -d "$TMPP/macsmoke1-home.XXXXXX") && register "$H2" && W2=$(mktemp -d /tmp/macsmoke1-ws.XXXXXX) && register "$W2" || summary INCONCLUSIVE mktemp
cj_run cj-sibling "$H2" "$W2" yes yes
# Step 6: the ordinary non-fallback launcher path, HOME and workspace outside /tmp and $TMPDIR.
if [ -n "$OUT_PHYS" ]; then
  O=$(mktemp -d "$OUT_PHYS/macsmoke1.XXXXXX") || summary INCONCLUSIVE mktemp-outside; OUT_MADE=$O; register "$O"
  mkdir "$O/home" "$O/ws" || summary INCONCLUSIVE mkdir-outside
  cj_run cj-outside "$O/home" "$O/ws" no no
else
  say ""; say "== run cj-outside: not run (HOME is missing or temporary; pass --outside-dir <dir outside /tmp and \$TMPDIR>) =="
  add INCONC cj-outside:no-outside-dir
fi

say ""; [ -n "$NOTES" ] && say "notes: $NOTES"
[ -n "$UNEXPECTED" ] && summary FAIL
[ -n "$REPORT_FAILURES" ] && summary REPORT_FAILURE
[ -n "$INCONC" ] && summary INCONCLUSIVE
summary PASS
