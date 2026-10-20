#!/bin/sh
# Swarm Hub box updater: the operator bootstrap installer (CORE-PHASES.md P2d; CORE-PLAN.md §3.2, §3.5). Deterministic,
# no model, no network, Linux and macOS (POSIX sh, BSD and GNU tools). Run as root (sudo) at the box console or over
# an authenticated SSH session. It writes only under PREFIX, never in Hermes paths, and restarts nothing.
#
#   install-bootstrap.sh install --package FILE.tar --sha256 HEX [--prefix DIR] [--python PATH] [--allow-test-keys]
#   install-bootstrap.sh maintenance [--prefix DIR] [--min-keys-version N] [--min-index-seq N]
#                                    [--min-bundle-version N] [--revoke KEY_ID]...
#   install-bootstrap.sh verify [--prefix DIR]
#   install-bootstrap.sh rollback [--prefix DIR]
#   install-bootstrap.sh uninstall [--prefix DIR]
#
# install: --sha256 is the value the signed app shows (Settings > Advanced > About). The package is copied into a
# root-private folder and that copy is hashed BEFORE anything is extracted or run; a mismatch (or a disagreeing
# FILE.tar.sha256 beside it) stops with nothing written. P2c provides no separate package signature: the digest from
# the signed app is the trust root. Installing again (a newer app) keeps the higher checkpoint and every revoked key.
# Layout (root-owned, 0755/0644, no bot-account write access):
#   PREFIX/bin/swarmhub-update -> ../current/bin/swarmhub-update   the fixed path callers use
#   PREFIX/current, PREFIX/previous -> releases/<id>              switched atomically (rename)
#   PREFIX/releases/<id>/{bin/swarmhub-update, swarmhub_update/*.py, pins.json, files.sha256, INSTALL.txt}
#   PREFIX/bootstrap.log
# The installed launcher is the package's, with line 1 replaced by "#!<python> -IBS": a vetted root-owned interpreter
# (no PATH lookup), isolated (-I: no PYTHON* variables, script folder, cwd or user site), no site module (-S: no
# site-packages or .pth files), no bytecode (-B). Run it by its absolute path, never as "python3 <launcher>".
# maintenance: raises the protected floor checkpoint in pins.json and adds revoked key IDs; it never lowers either.
# A package whose pins name a TEST- root (a debug build: its seeds are public) is refused unless --allow-test-keys
# (test machines only). --unprivileged-test (tests only): the trusted owner is the invoking user instead of root; needs --prefix.
# Exit codes: 0 done, 1 refused or failed (nothing half-installed), 64 usage.

PATH=/usr/bin:/bin:/usr/sbin:/sbin
LC_ALL=C
export PATH LC_ALL
unset CDPATH ENV BASH_ENV
IFS=$(printf ' \t\n.'); IFS=${IFS%.}
umask 022

ME=install-bootstrap
OS=$(uname -s)
STAGE= LOCK=
die() { printf '%s: %s\n' "$ME" "$*" >&2; exit 1; }
usage() { printf '%s: %s\n' "$ME" "$*" >&2; exit 64; }
note() { printf '%s: %s\n' "$ME" "$*"; }
cleanup() {
  [ -n "$STAGE" ] && rm -rf "$STAGE"
  [ -n "$LOCK" ] && rmdir "$LOCK" 2>/dev/null
  STAGE= LOCK=
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
clean() { env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C "$@"; }

if [ -x /usr/bin/sha256sum ] || [ -x /bin/sha256sum ]; then SHA_CMD=sha256sum
elif [ -x /usr/bin/shasum ]; then SHA_CMD='shasum -a 256'
else SHA_CMD=; fi
sha256_of() { (clean $SHA_CMD "$1") | { read -r h _ && printf '%s\n' "$h"; }; }

# ---- trust checks: owner root (or the test user), not writable by group/other, no ACL that grants writing ----------
acl_ok() {
  if [ "$OS" = Darwin ]; then
    ! ls -lde "$1" 2>/dev/null | sed 1d | grep -Eq ' allow .*(write|append|add_file|add_subdirectory|delete|chown)'
  else
    command -v getfacl >/dev/null 2>&1 || return 1
    ! getfacl -cp "$1" 2>/dev/null | grep -Eq '^(user|group):[^:]+:.w'
  fi
}
node_ok() {
  _l=$(ls -ldn "$1" 2>/dev/null) || return 1
  set -f; set -- "$1" $_l; set +f
  _p=$2 _u=$4 _g=$5
  [ "$_u" = 0 ] || [ "$_u" = "$TRUST_UID" ] || return 1
  case $_p in l*) return 0 ;; esac
  case $_p in ?????w*) [ "$_g" = 0 ] || return 1 ;; esac
  case $_p in ????????w*) return 1 ;; esac
  case $_p in *+) acl_ok "$1" || return 1 ;; *) [ "$OS" != Darwin ] || acl_ok "$1" || return 1 ;; esac
  return 0
}
chain_ok() {  # $1 and every ancestor, as named
  _c=$1
  while :; do
    node_ok "$_c" || { BAD=$_c; return 1; }
    [ "$_c" = / ] && return 0
    _c=$(dirname "$_c")
  done
}
trusted() {  # $1 absolute: every symlink hop, the named and the physical ancestors are trusted; sets RESOLVED
  _t=$1 _n=0
  while :; do
    chain_ok "$_t" || return 1
    _d=$(cd -P "$(dirname "$_t")" 2>/dev/null && pwd -P) || { BAD=$_t; return 1; }
    chain_ok "$_d" || return 1
    [ -L "$_t" ] || break
    _n=$((_n + 1)); [ "$_n" -le 20 ] || { BAD=$1; return 1; }
    _r=$(readlink "$_t") || { BAD=$_t; return 1; }
    case $_r in /*) _t=$_r ;; *) _t=${_d%/}/$_r ;; esac
  done
  RESOLVED=${_d%/}/$(basename "$_t")
}
reachable() {  # other accounts can traverse every ancestor (root installs only)
  [ -n "$TEST_MODE" ] && return 0
  _c=$1
  while [ "$_c" != / ]; do
    case $(ls -ldnL "$_c") in d????????[xt]*) ;; *) BAD=$_c; return 1 ;; esac
    _c=$(dirname "$_c")
  done
}

# ---- the interpreter: checked on disk BEFORE it runs at all, then run isolated (-I -S -B, empty env, cwd /) ---------
# Python reads its library (encodings, ...) while starting, before any -c code. So first, for the bin folder as named
# and as resolved: no pyvenv.cfg or bin/lib* (they move where the library is looked up), a trusted prefix, trusted
# lib/lib64 folders, libpython and pythonNN.zip, whole trusted lib*/python3.N trees (links followed), and the binary's
# own stdlib beside it: lib*/python3.N/os.py for the N in its name (python3.N), or the only one there when the name has
# none. Otherwise Python would look further up or at its built-in prefix, which nothing here checked. Only then is it
# run, and its -I -S sys.path checked again.
prefix_ok() {  # $1 a bin folder Python may start from; $2 the resolved binary's name: its prefix must hold its stdlib
  _pb=$1 _pp=$(dirname "$1") _pf= _pn=0
  case ${2:-} in python3.[0-9]*) _pw=python${2#python} ;; *) _pw= ;; esac
  for _pv in "$_pb/pyvenv.cfg" "$_pp/pyvenv.cfg" "$_pb/lib" "$_pb/lib64"; do
    [ ! -e "$_pv" ] && [ ! -L "$_pv" ] || { BAD="$_pv (it changes where Python loads its library from)"; return 1; }
  done
  trusted "$_pp" || return 1
  for _pv in "$_pp/lib" "$_pp/lib64" "$_pp/Python" "$_pp/Python3" "$_pp"/lib/libpython3* "$_pp"/lib64/libpython3* \
      "$_pp"/lib/python3[0-9]*.zip "$_pp"/lib64/python3[0-9]*.zip "$_pp"/lib/python3.[0-9]* "$_pp"/lib64/python3.[0-9]*; do
    [ -e "$_pv" ] || [ -L "$_pv" ] || continue
    trusted "$_pv" || return 1
    case $_pv in */python3.[0-9]*) [ -d "$_pv" ] || continue
      tree_ok "$RESOLVED" || { BAD="$BAD (in $_pv, the library the interpreter loads)"; return 1; }
      if [ -f "$_pv/os.py" ]; then _pn=$((_pn + 1)); [ "${_pv##*/}" != "$_pw" ] || _pf=1; fi ;;
    esac
  done
  [ -n "${2:-}" ] || return 0
  [ -n "$_pw" ] || [ "$_pn" != 1 ] || _pf=1
  [ -n "$_pf" ] || { BAD="$_pp holds no lib/${_pw:-python3.N}/os.py (or several): cannot tell where $PYC loads its library from"; return 1; }
}
python_ok() {
  case $1 in /*) ;; *) return 1 ;; esac
  case $1 in *[!A-Za-z0-9._/+-]*) return 1 ;; esac
  [ -f "$1" ] && [ -x "$1" ] && trusted "$1" || return 1
  PYC=$1 _real=$RESOLVED
  prefix_ok "$(dirname "$_real")" "$(basename "$_real")" || return 1
  _named=$(cd -P "$(dirname "$1")" && pwd -P) || { BAD=$1; return 1; }
  [ "$_named" = "$(dirname "$_real")" ] || prefix_ok "$_named" || return 1
  (cd / && clean "$1" -I -S -B -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 3)') 2>/dev/null \
    || { BAD="$1 (needs Python 3.8 or later)"; return 1; }
  _paths=$(cd / && clean "$1" -I -S -B -c 'import sys; print("\n".join(p for p in sys.path if p))') || return 1
  _old=$IFS; IFS='
'
  set -f
  for _e in $_paths; do
    IFS=$_old; set +f
    case $_e in /*) ;; *) BAD="$1: relative sys.path entry $_e"; return 1 ;; esac
    _x=$_e
    while [ ! -e "$_x" ] && [ ! -L "$_x" ]; do _x=$(dirname "$_x"); done
    trusted "$_x" || return 1  # a missing entry: its nearest folder must be trusted, so nobody else can create it
    if [ "$_x" = "$_e" ] && [ -d "$_x" ] && ! tree_ok "$RESOLVED"; then BAD="$BAD (in $_x, which the bot account could change)"; return 1; fi
  done
  IFS=$_old; set +f
}
pick_python() {
  if [ -n "$PY_ARG" ]; then set -- "$PY_ARG"
  elif [ "$OS" = Darwin ]; then
    set -- "$(clean /usr/bin/xcrun -f python3 2>/dev/null)" /Library/Developer/CommandLineTools/usr/bin/python3 \
      /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /usr/local/bin/python3 /opt/homebrew/bin/python3
  else set -- /usr/bin/python3 /usr/local/bin/python3; fi
  for _cand do
    [ -n "$_cand" ] || continue
    BAD=
    if python_ok "$_cand"; then PY=$_cand; return 0; fi
    note "not using $_cand: untrusted ${BAD:-or missing}" >&2
  done
  die "no trusted python3 >= 3.8 (root-owned, not writable by others); name one with --python"
}

# ---- small Python helpers (stdlib only, isolated, run from /) -------------------------------------------------------
MERGE_PY='
import json, sys
src, old, out, strict = sys.argv[1:5]
wanted = dict(zip(("min_keys_version", "min_index_seq", "min_bundle_version"), sys.argv[5:8]))
def read(path):
    with open(path, "rb") as handle:
        doc = json.loads(handle.read().decode("utf-8"))
    if not isinstance(doc, dict) or not isinstance(doc.get("checkpoint", {}), dict):
        raise SystemExit("%s is not a pin file" % path)
    return doc
doc = read(src)
checkpoint, revoked = dict(doc.get("checkpoint", {})), list(doc.get("revoked_key_ids", []))
if old:
    previous = read(old)
    for name, value in previous.get("checkpoint", {}).items():
        checkpoint[name] = max(checkpoint.get(name, 0), value)
    revoked += [k for k in previous.get("revoked_key_ids", []) if k not in revoked]
for name, value in wanted.items():
    if value:
        if strict == "1" and int(value) < checkpoint.get(name, 0):
            raise SystemExit("%s %s is below the installed %d: a checkpoint never goes down" % (name, value, checkpoint[name]))
        checkpoint[name] = max(checkpoint.get(name, 0), int(value))
revoked += [k for k in sys.argv[8:] if k not in revoked]
if checkpoint:
    doc["checkpoint"] = checkpoint
if revoked:
    doc["revoked_key_ids"] = sorted(revoked)
with open(out, "xb") as handle:
    handle.write(json.dumps(doc, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("ascii"))
'
LOAD_PY='
import json, sys
sys.path.insert(0, sys.argv[1])
from swarmhub_update import pins
p = pins.load(sys.argv[2])
print(json.dumps({"roots": [r["key_id"] for r in p.doc["roots"]], "threshold": p.doc["threshold"],
                  "checkpoint": {"min_" + k: v for k, v in sorted(p.checkpoint.items())}, "revoked_key_ids": sorted(p.revoked), "sha256": p.sha256}, sort_keys=True))
'
REPLACE_PY='import os, sys; os.replace(sys.argv[1], sys.argv[2])'
pyrun() { (cd / && clean "$PY" -I -S -B -c "$@"); }
relink() {  # atomically point PREFIX/$1 at releases/$2
  rm -f "$PREFIX/.$1.new"
  ln -s "releases/$2" "$PREFIX/.$1.new" || die "cannot create the $1 link"
  pyrun "$REPLACE_PY" "$PREFIX/.$1.new" "$PREFIX/$1" || { rm -f "$PREFIX/.$1.new"; die "cannot switch $1"; }
}
link_id() { [ -L "$PREFIX/$1" ] || return 1; _r=$(readlink "$PREFIX/$1") && printf '%s\n' "${_r#releases/}"; }
interpreter_of() { IFS= read -r _line < "$1/bin/swarmhub-update" || return 1; _line=${_line#\#!}; printf '%s\n' "${_line% -IBS}"; }
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$PREFIX/bootstrap.log"; }

# ---- arguments ---------------------------------------------------------------------------------------------------
COMMAND=${1:-}
[ $# -gt 0 ] && shift
PREFIX= PACKAGE= WANT= PY_ARG= TEST_MODE= ALLOW_TEST= MK= MI= MB= REVOKE=
need() { [ $# -ge 2 ] || usage "$1 needs a value"; }
number() { case $2 in ''|*[!0-9]*) usage "$1 needs a non-negative integer" ;; esac; }
while [ $# -gt 0 ]; do
  case $1 in
    --prefix) need "$@"; PREFIX=$2; shift ;;
    --package) need "$@"; PACKAGE=$2; shift ;;
    --sha256) need "$@"; WANT=$2; shift ;;
    --python) need "$@"; PY_ARG=$2; shift ;;
    --min-keys-version) need "$@"; number "$1" "$2"; MK=$2; shift ;;
    --min-index-seq) need "$@"; number "$1" "$2"; MI=$2; shift ;;
    --min-bundle-version) need "$@"; number "$1" "$2"; MB=$2; shift ;;
    --revoke) need "$@"
      case $2 in ''|*[!A-Za-z0-9._-]*) usage "--revoke needs a key ID" ;; esac
      REVOKE="$REVOKE $2"; shift ;;
    --unprivileged-test) TEST_MODE=1 ;;
    --allow-test-keys) ALLOW_TEST=1 ;;
    *) usage "unknown argument $1" ;;
  esac
  shift
done
case $COMMAND in install|maintenance|verify|rollback|uninstall) ;; *) usage "choose install, maintenance, verify, rollback or uninstall" ;; esac
[ -n "$SHA_CMD" ] || die "no sha256sum or shasum on this system"
if [ -n "$TEST_MODE" ]; then
  TRUST_UID=$(id -u)
  [ -n "$PREFIX" ] || usage "--unprivileged-test needs --prefix"
  note "TEST MODE: trusted owner is uid $TRUST_UID, not root; this install protects nothing"
else
  TRUST_UID=0
  [ "$(id -u)" = 0 ] || die "run as root (sudo): the updater must be owned by an account the bot cannot use"
fi
PREFIX=${PREFIX:-/opt/swarmhub-updater}
while :; do case $PREFIX in */) PREFIX=${PREFIX%/} ;; *) break ;; esac; done
case $PREFIX in /?*) ;; *) usage "--prefix must be an absolute path" ;; esac
case $PREFIX in *[!A-Za-z0-9._/-]*|*/./*|*/../*|*/.|*/..|*//*) usage "--prefix must be a plain absolute path" ;; esac
case $PREFIX in */.hermes|*/.hermes/*) die "refusing a prefix inside a Hermes folder" ;; esac

lock() {
  mkdir "$PREFIX/.lock" 2>/dev/null || die "another run holds $PREFIX/.lock (remove it if no run is active)"
  LOCK=$PREFIX/.lock
}
installed() {  # PREFIX is our install and trusted; sets CUR
  [ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] || die "$PREFIX is not installed"
  trusted "$PREFIX" || die "$PREFIX is not protected: $BAD is writable by or owned by another account"
  CUR=$(link_id current) && [ -d "$PREFIX/releases/$CUR" ] || die "$PREFIX has no current release"
}
tree_ok() {  # $1 folder: nothing in it is owned by or writable for another account, and every link resolves (each hop
             # and its folders) to a trusted file, or to a folder inside $1; $2 = inside: every link stays inside $1
  _bad=$(find "$1" \( ! -user 0 ! -user "$TRUST_UID" \) -print -o \( ! -type l -perm -0002 \) -print \
         -o \( ! -type l -perm -0020 ! -group 0 \) -print 2>/dev/null | sed -n 1p)
  [ -z "$_bad" ] || { BAD=$_bad; return 1; }
  if [ "$OS" = Darwin ]; then  # ACLs (also inherited ones) that grant writing
    ! ls -leAR "$1" 2>/dev/null | grep -Eq ' allow .*(write|append|add_file|add_subdirectory|delete|chown)' \
      || { BAD="$1 (an ACL grants writing)"; return 1; }
  else  # any POSIX ACL entry fails closed
    ! ls -lAR "$1" 2>/dev/null | grep -q '^[-dlpcbs][-rwxsStT]\{9\}+' || { BAD="$1 (an entry has an ACL)"; return 1; }
  fi
  _troot=$(cd -P "$1" 2>/dev/null && pwd -P) && _tlinks=$(find "$1" -type l -print) || { BAD="$1 (cannot list its links)"; return 1; }
  _tifs=$IFS; IFS='
'
  set -f
  for _tl in $_tlinks; do
    IFS=$_tifs; set +f
    trusted "$_tl" || { BAD="$_tl links through $BAD, which is not protected"; return 1; }
    if [ -d "$RESOLVED" ]; then
      _tt=$(cd -P "$RESOLVED" 2>/dev/null && pwd -P) || { BAD="$_tl (its target cannot be resolved)"; return 1; }
      case $_tt/ in "$_troot"/*) ;; *) BAD="$_tl links to the folder $_tt, outside $1"; return 1 ;; esac
    elif [ -f "$RESOLVED" ]; then
      [ "${2:-}" != inside ] || case $RESOLVED in "$_troot"/*) ;; *) BAD="$_tl links to $RESOLVED, outside $1"; return 1 ;; esac
    else BAD="$_tl links to $RESOLVED, which is not a plain file or folder"; return 1; fi
  done
  IFS=$_tifs; set +f
}
finish_release() {  # $1 release folder: modes, owner, pin file and import check
  find "$1" -type d -exec chmod 0755 {} + && find "$1" -type f -exec chmod 0644 {} + \
    && chmod 0755 "$1/bin/swarmhub-update" || die "cannot set modes"
  [ -n "$TEST_MODE" ] || chown -R 0:0 "$1" || die "cannot set the owner"
  pyrun "$LOAD_PY" "$1" "$1/pins.json" > "$STAGE/pins-summary" || die "the pin file does not load; nothing changed"
  (cd / && clean "$1/bin/swarmhub-update" --state-dir "$STAGE/smoke" --hermes-home "$STAGE/smoke/none" status) \
    > /dev/null || die "the installed updater does not start with $PY; nothing changed"
  rm -rf "$STAGE/smoke"
}
stage_dir() { STAGE=$(mktemp -d "$PREFIX/.stage.XXXXXX") || die "cannot create a staging folder"; }

# ---- commands ----------------------------------------------------------------------------------------------------
cmd_install() {
  [ -n "$PACKAGE" ] && [ -n "$WANT" ] || usage "install needs --package FILE.tar and --sha256 HEX (the app's value)"
  WANT=$(printf '%s' "$WANT" | tr 'A-F' 'a-f')
  case $WANT in *[!0-9a-f]*) usage "--sha256 must be 64 hex digits" ;; esac
  [ ${#WANT} -eq 64 ] || usage "--sha256 must be 64 hex digits"
  [ -f "$PACKAGE" ] || die "no package at $PACKAGE"
  pick_python
  PARENT=$(dirname "$PREFIX") _x=$PARENT
  while [ ! -e "$_x" ]; do _x=$(dirname "$_x"); done
  trusted "$_x" || die "refusing $PREFIX: $BAD is writable by or owned by another account"
  mkdir -p "$PARENT" && trusted "$PARENT" && reachable "$PARENT" || die "refusing $PREFIX: $BAD is not protected or not reachable"
  # 1. hash a root-private copy BEFORE anything is extracted, run or created under PREFIX
  STAGE=$(mktemp -d "$PARENT/.swarmhub-bootstrap.XXXXXX") || die "cannot create a staging folder in $PARENT"
  cp "$PACKAGE" "$STAGE/package.tar" || die "cannot copy the package"
  GOT=$(sha256_of "$STAGE/package.tar")
  [ "$GOT" = "$WANT" ] || die "SHA-256 mismatch: package $GOT, expected $WANT. Nothing was extracted or installed."
  if [ -f "$PACKAGE.sha256" ]; then
    read -r SIDE _ < "$PACKAGE.sha256" || SIDE=
    [ "$SIDE" = "$WANT" ] || die "$PACKAGE.sha256 says $SIDE, the app says $WANT. Nothing was extracted or installed."
  fi
  note "package sha256 $GOT matches"
  # 2. only the expected members, then extract and refuse anything that is not a plain file or folder
  clean tar -tf "$STAGE/package.tar" > "$STAGE/members" || die "the package is not a tar archive"
  while IFS= read -r m; do
    case $m in
      swarmhub-updater/|swarmhub-updater/bin/|swarmhub-updater/bin/swarmhub-update|swarmhub-updater/pins.json) ;;
      swarmhub-updater/swarmhub_update/) ;;
      swarmhub-updater/swarmhub_update/*.py)
        case ${m#swarmhub-updater/swarmhub_update/} in *[!a-z0-9_.]*|.*) die "unexpected package member $m" ;; esac ;;
      *) die "unexpected package member $m" ;;
    esac
  done < "$STAGE/members"
  mkdir "$STAGE/x" && clean tar -x --no-same-owner -f "$STAGE/package.tar" -C "$STAGE/x" || die "cannot extract the package"
  X=$STAGE/x/swarmhub-updater
  [ -z "$(find "$STAGE/x" ! -type f ! -type d -print | sed -n 1p)" ] || die "the package holds links or special files"
  [ -f "$X/bin/swarmhub-update" ] && [ -f "$X/pins.json" ] && [ -f "$X/swarmhub_update/cli.py" ] \
    || die "the package lacks the launcher, pins.json or swarmhub_update/"
  IFS= read -r FIRST < "$X/bin/swarmhub-update"
  case $FIRST in '#!'*) ;; *) die "the package launcher has no #! line" ;; esac
  if grep -Eq '"key_id" *: *"TEST-' "$X/pins.json" && [ -z "$ALLOW_TEST" ]; then
    die "the package pins TEST- root keys (a debug build; their seeds are public). Not for a real box; nothing installed."
  fi
  if [ -e "$PREFIX" ] || [ -L "$PREFIX" ]; then
    [ -d "$PREFIX" ] && [ ! -L "$PREFIX" ] && trusted "$PREFIX" || die "$PREFIX exists and is not protected: $BAD"
    link_id current > /dev/null || [ -d "$PREFIX/releases" ] || [ -z "$(ls -A "$PREFIX")" ] \
      || die "$PREFIX exists and is not a Swarm Hub updater install"
  else
    mkdir -m 0755 "$PREFIX" || die "cannot create $PREFIX"
    trusted "$PREFIX" || die "$PREFIX is not protected: $BAD"
  fi
  lock
  # 3. the release: pinned interpreter, the package's files, pins with max(installed, package) checkpoint
  R=$STAGE/rel
  mkdir -p "$R/bin" "$R/swarmhub_update" || die "cannot build the release"
  { printf '#!%s -IBS\n' "$PY"; sed 1d "$X/bin/swarmhub-update"; } > "$R/bin/swarmhub-update" || die "cannot write the launcher"
  cp "$X"/swarmhub_update/*.py "$R/swarmhub_update/" || die "cannot copy the package"
  OLD=
  if CUR=$(link_id current); then OLD=$PREFIX/releases/$CUR/pins.json; fi
  pyrun "$MERGE_PY" "$X/pins.json" "$OLD" "$R/pins.json" 0 "" "" "" || die "cannot merge the pin file"
  (cd "$R" && clean $SHA_CMD bin/swarmhub-update swarmhub_update/*.py) > "$R/files.sha256" || die "cannot record hashes"
  printf 'package %s\nsha256 %s\npython %s\ninstalled %s\n' "$(basename "$PACKAGE")" "$GOT" "$PY" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$R/INSTALL.txt"
  finish_release "$R"
  # 4. switch: releases/<id> appears, then current (and previous) move by rename
  mkdir -p "$PREFIX/releases" "$PREFIX/bin" && chmod 0755 "$PREFIX/releases" "$PREFIX/bin" || die "cannot create folders"
  ID=$(date -u +%Y%m%dT%H%M%SZ)-$(printf '%.12s' "$GOT")
  [ ! -e "$PREFIX/releases/$ID" ] || die "release $ID exists; run again in a second"
  mv "$R" "$PREFIX/releases/$ID" || die "cannot move the release into place"
  relink current "$ID"
  [ -n "$CUR" ] && relink previous "$CUR"
  [ -L "$PREFIX/bin/swarmhub-update" ] || ln -s ../current/bin/swarmhub-update "$PREFIX/bin/swarmhub-update" \
    || die "cannot create the launcher link"
  PREV=$(link_id previous || true)
  for old in $(ls "$PREFIX/releases"); do
    [ "$old" = "$ID" ] || [ "$old" = "$PREV" ] || rm -rf "$PREFIX/releases/$old"
  done
  log "install $ID package-sha256 $GOT python $PY pins $(cat "$STAGE/pins-summary")"
  [ -n "$TEST_MODE" ] || chown -h 0:0 "$PREFIX/current" "$PREFIX/bin/swarmhub-update" "$PREFIX/bootstrap.log" \
    ${PREV:+"$PREFIX/previous"}
  chmod 0644 "$PREFIX/bootstrap.log"
  tree_ok "$PREFIX" inside || die "after install, $BAD is not protected"
  note "installed $ID at $PREFIX (python $PY)"
  note "pins $(cat "$STAGE/pins-summary")"
  note "run it as the bot account by its absolute path: $PREFIX/bin/swarmhub-update status"
}

rewrite_pins() {  # $1 release id, $2 extra pin file to merge ('' none), $3 strict: write a new pins.json atomically
  _rel=$PREFIX/releases/$1
  pyrun "$MERGE_PY" "$_rel/pins.json" "$2" "$STAGE/pins.json" "$3" "$MK" "$MI" "$MB" $REVOKE \
    || die "the checkpoint was not changed"
  mkdir "$STAGE/check" && cp -R "$_rel/swarmhub_update" "$STAGE/check/" && cp "$STAGE/pins.json" "$STAGE/check/pins.json" \
    && pyrun "$LOAD_PY" "$STAGE/check" "$STAGE/check/pins.json" > "$STAGE/pins-summary" \
    || die "the new pin file does not load; the checkpoint was not changed"
  rm -rf "$STAGE/check"
  cp "$STAGE/pins.json" "$_rel/.pins.json.new" && chmod 0644 "$_rel/.pins.json.new" \
    && { [ -n "$TEST_MODE" ] || chown 0:0 "$_rel/.pins.json.new"; } \
    && pyrun "$REPLACE_PY" "$_rel/.pins.json.new" "$_rel/pins.json" || die "cannot replace pins.json"
  rm -f "$STAGE/pins.json"
}

cmd_maintenance() {
  installed; lock; stage_dir
  PY=$(interpreter_of "$PREFIX/releases/$CUR") && python_ok "$PY" || die "the installed interpreter is not trusted: $BAD"
  pyrun "$LOAD_PY" "$PREFIX/releases/$CUR" "$PREFIX/releases/$CUR/pins.json" > "$STAGE/before" || die "pins.json does not load"
  note "checkpoint before: $(cat "$STAGE/before")"
  if [ -z "$MK$MI$MB$REVOKE" ]; then note "nothing to advance (give --min-* or --revoke)"; return 0; fi
  rewrite_pins "$CUR" "" 1
  log "maintenance $CUR pins $(cat "$STAGE/pins-summary")"
  note "checkpoint after: $(cat "$STAGE/pins-summary")"
}

cmd_verify() {
  installed
  tree_ok "$PREFIX" inside || die "NOT PROTECTED: $BAD"
  reachable "$PREFIX" || die "$BAD is not reachable by the bot account"
  REL=$PREFIX/releases/$CUR
  [ "$(readlink "$PREFIX/bin/swarmhub-update")" = ../current/bin/swarmhub-update ] || die "the launcher link is wrong"
  (cd "$REL" && clean $SHA_CMD -c files.sha256 > /dev/null) || die "installed files differ from files.sha256"
  PY=$(interpreter_of "$REL") && python_ok "$PY" || die "the interpreter is not trusted: $BAD"
  pyrun "$LOAD_PY" "$REL" "$REL/pins.json" || die "pins.json does not load"
  note "OK: $PREFIX current $CUR, python $PY; nothing writable by other accounts; files match files.sha256"
}

cmd_rollback() {
  installed; lock; stage_dir
  PREV=$(link_id previous) && [ -d "$PREFIX/releases/$PREV" ] || die "there is no previous release"
  PY=$(interpreter_of "$PREFIX/releases/$PREV") && python_ok "$PY" || die "the previous interpreter is not trusted: $BAD"
  MK= MI= MB= REVOKE=
  rewrite_pins "$PREV" "$PREFIX/releases/$CUR/pins.json" 0  # the checkpoint never goes back with the code
  relink current "$PREV"
  relink previous "$CUR"
  log "rollback current $PREV previous $CUR pins $(cat "$STAGE/pins-summary")"
  note "current is $PREV again (checkpoint kept: $(cat "$STAGE/pins-summary"))"
}

cmd_uninstall() {
  installed; lock
  LOCK=
  rm -rf "$PREFIX" || die "cannot remove $PREFIX"
  note "removed $PREFIX. The bot's own update state (~/.local/state/swarmhub-update) and installed skills stay as they are."
}

"cmd_$COMMAND"
