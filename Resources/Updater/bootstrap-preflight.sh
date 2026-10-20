# Sourced by install-bootstrap.sh. No candidate Python code may execute until all on-disk checks pass.
no_controls() { case $1 in *[[:cntrl:]]*) return 1 ;; esac; }

link_target() {  # preserve every target byte, then remove only readlink's delimiter newline
  LINK_TARGET=$(readlink "$1" && printf '.') || { BAD="$1 (its link cannot be read)"; return 1; }
  LINK_TARGET=${LINK_TARGET%.}; LINK_TARGET=${LINK_TARGET%"
"}
  [ -n "$LINK_TARGET" ] && no_controls "$LINK_TARGET" \
    || { BAD="$1 (control character in link target, or empty target)"; return 1; }
}

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
trusted() {  # $1 absolute, walked one name at a time from /: every folder entered, every link (each hop of each link,
             # also links inside a link's target, at most 40 in all) and the last entry must pass node_ok. Refuses
             # loops, too many hops, anything it cannot read and a non-folder in the middle; sets RESOLVED (physical)
  no_controls "$1" || { BAD="$1 (control character in path)"; return 1; }
  case $1 in /*) ;; *) BAD="$1 (not an absolute path)"; return 1 ;; esac
  node_ok / || { BAD=/; return 1; }
  _kc= _kr=${1#/} _kn=0
  while [ -n "$_kr" ]; do
    case $_kr in */*) _kp=${_kr%%/*} _kr=${_kr#*/} ;; *) _kp=$_kr _kr= ;; esac
    case $_kp in ''|.) continue ;; ..) _kc=${_kc%/*}; continue ;; esac
    _kx=$_kc/$_kp
    [ -e "$_kx" ] || [ -L "$_kx" ] || { BAD="$_kx (missing)"; return 1; }
    node_ok "$_kx" || { BAD=$_kx; return 1; }
    if [ -L "$_kx" ]; then
      _kn=$((_kn + 1)); [ "$_kn" -le 40 ] || { BAD="$1 (a link loop, or more than 40 link hops)"; return 1; }
      link_target "$_kx" || return 1
      _kl=$LINK_TARGET
      case $_kl in /*) _kc= ;; esac
      _kr=${_kl#/}${_kr:+/$_kr}
    elif [ -d "$_kx" ] || [ -z "$_kr" ]; then _kc=$_kx
    else BAD="$_kx (not a folder, but a path goes through it)"; return 1; fi
  done
  RESOLVED=${_kc:-/}
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
# Python reads its library (encodings, ...) while starting, before any -c code, and -I -S do not stop the start-up
# overrides in getpath (3.8-3.14). So first, for the bin folder as named and as resolved: none of pyvenv.cfg, a ._pth
# file, pybuilddir.txt, Modules/ (a build tree) or bin/lib* (they move or replace where the library is looked up), in
# the bin folder, the prefix or a framework's Resources/Python.app/Contents/MacOS (whose whole Resources tree must be
# trusted: a framework's bin/python3.N only starts the binary there); a trusted prefix, trusted lib/lib64
# folders, libpython and pythonNN.zip, whole trusted lib*/python3.N trees (links followed), and the binary's own stdlib
# beside it: lib*/python3.N/os.py for the N in its name (python3.N), or the only one there when the name has none. A
# libpython actually linked by the binary is located without starting Python and checked too. No
# folder above the prefix may hold lib*/python3NN.zip, nor lib*/python3.N/lib-dynload when the prefix has none (Python
# searches upward for both). Otherwise Python would look elsewhere, which nothing here checked. Only then is it run,
# and its -I -S sys.path checked again.
prefix_ok() {  # $1 a bin folder Python may start from; $2 the resolved binary's name: its prefix must hold its stdlib
  _pb=$1 _pp=$(dirname "$1") _pf= _pn=0
  case ${2:-} in python3.[0-9]*) _pw=python${2#python} ;; *) _pw= ;; esac
  _pm=$_pp/Resources/Python.app/Contents/MacOS  # a framework's bin/python3.N execs the Python in this app bundle
  for _pv in "$_pb/pyvenv.cfg" "$_pp/pyvenv.cfg" "$_pb/lib" "$_pb/lib64" "$_pb/pybuilddir.txt" "$_pb/Modules" \
      "$_pp/pybuilddir.txt" "$_pp/Modules" "$_pm/pyvenv.cfg" "$_pm/pybuilddir.txt" "$_pm/Modules" "$_pm/lib" \
      "$_pb"/*._pth "$_pb"/.*._pth "$_pp"/*._pth "$_pp"/.*._pth "$_pm"/*._pth "$_pm"/.*._pth; do
    [ ! -e "$_pv" ] && [ ! -L "$_pv" ] || { BAD="$_pv (it changes where Python loads its library from)"; return 1; }
  done
  trusted "$_pp" || return 1
  if [ -e "$_pp/Resources" ] || [ -L "$_pp/Resources" ]; then  # the app bundle holds the binary that really runs
    trusted "$_pp/Resources" && tree_ok "$RESOLVED" || { BAD="$BAD (in $_pp/Resources, where a framework Python runs from)"; return 1; }
  fi
  for _pv in "$_pp"/lib/libpython3* "$_pp"/lib64/libpython3* "$_pp"/lib/*/libpython3* "$_pp"/lib64/*/libpython3*; do
    [ -e "$_pv" ] || [ -L "$_pv" ] || continue  # 3.14+ reads <libpython>._pth and searches upward from its folder
    _pl=$(dirname "$_pv")
    for _pq in "$_pl"/*._pth "$_pl"/.*._pth "$_pl/lib" "$_pl/lib64" "$_pp/lib/lib" "$_pp/lib/lib64" "$_pp/lib64/lib" "$_pp/lib64/lib64"; do
      [ ! -e "$_pq" ] && [ ! -L "$_pq" ] || { BAD="$_pq (beside a libpython: it changes where Python loads its library from)"; return 1; }
    done
  done
  for _pv in "$_pp/lib" "$_pp/lib64" "$_pp/Python" "$_pp/Python3" "$_pp"/lib/libpython3* "$_pp"/lib64/libpython3* "$_pp"/lib/*/libpython3* \
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
  _pd=
  for _pv in "$_pp"/lib/${_pw:-python3.[0-9]*}/lib-dynload "$_pp"/lib64/${_pw:-python3.[0-9]*}/lib-dynload; do
    [ -d "$_pv" ] && _pd=1
  done
  _pa=$_pp
  while [ "$_pa" != / ]; do
    _pa=$(dirname "$_pa")
    for _pv in "${_pa%/}"/lib/python3[0-9]*.zip "${_pa%/}"/lib64/python3[0-9]*.zip; do
      [ -e "$_pv" ] || [ -L "$_pv" ] || continue
      BAD="$_pv (above $_pp: Python would take its library from there)"; return 1
    done
    [ -z "$_pd" ] || continue
    for _pv in "${_pa%/}"/lib/python3.[0-9]*/lib-dynload "${_pa%/}"/lib64/python3.[0-9]*/lib-dynload; do
      [ -e "$_pv" ] || [ -L "$_pv" ] || continue
      BAD="$_pv (above $_pp, which has no lib-dynload: Python would load modules from there)"; return 1
    done
  done
}
python_ok() {
  case $1 in /*) ;; *) return 1 ;; esac
  case $1 in *[!A-Za-z0-9._/+-]*) return 1 ;; esac
  trusted "$1" || return 1
  [ -f "$RESOLVED" ] && [ -x "$RESOLVED" ] || { BAD="$1 (not an executable file)"; return 1; }
  PYC=$1 _real=$RESOLVED
  prefix_ok "$(dirname "$_real")" "$(basename "$_real")" || return 1
  linked_python_ok "$_real" "$(dirname "$(dirname "$_real")")" || return 1
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

tree_ok() {  # $1 folder: nothing in it is owned by or writable for another account, and every link resolves (each hop
             # and its folders) to a trusted file, or to a folder inside $1; $2 = inside: every link stays inside $1
  _controls=$(find "$1" -exec /bin/sh -c 'for p do case $p in *[[:cntrl:]]*) printf x; break ;; esac; done' sh {} +) \
    || { BAD="$1 (cannot inspect path names)"; return 1; }
  [ -z "$_controls" ] || { BAD="$1 (control character in a path component)"; return 1; }
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

# Locate the loaded libpython without executing the candidate (even library constructors must not run).
# Linux needs readelf (binutils) and a trusted glibc loader's --list; never use ldd on an unvetted executable.
# Darwin uses otool's dependency/load-command tables, including framework and @rpath layouts.
linked_python_ok() {
  _lb=$1
  trusted "$2" || return 1
  LP_ROOT=$RESOLVED LP_LIBRARY=
  if [ "$OS" = Darwin ]; then
    _otool=/usr/bin/otool
    [ -x "$_otool" ] || _otool=$(clean /usr/bin/xcrun -f otool 2>/dev/null)
    trusted "$_otool" || { BAD="libpython discovery needs a trusted otool: $BAD"; return 1; }
    mac_libraries "$_lb" || return 1
    # Framework bin/python3.N can exec a second Mach-O in its app bundle. Inspect it as well.
    for _app in "$LP_ROOT"/Resources/Python.app/Contents/MacOS/*; do
      [ -f "$_app" ] || continue
      trusted "$_app" && mac_libraries "$_app" || return 1
    done
  elif [ "$OS" = Linux ]; then
    _reader=$(command -v readelf) && trusted "$_reader" || { BAD="libpython discovery needs trusted readelf (binutils)"; return 1; }
    _dyn=$(clean "$_reader" -dW "$_lb" 2>/dev/null) && _ph=$(clean "$_reader" -lW "$_lb" 2>/dev/null) \
      || { BAD="libpython linkage cannot be determined (not a readable ELF binary)"; return 1; }
    _ld=$(printf '%s\n' "$_ph" | sed -n 's/.*\[Requesting program interpreter: \(.*\)\]/\1/p')
    if [ -z "$_ld" ]; then
      case $_dyn in *NEEDED*) BAD="libpython linkage has dependencies but no ELF loader"; return 1 ;; esac
      return 0  # fully static ELF; a dynamic ELF with statically linked Python is handled below
    fi
    no_controls "$_ld" && trusted "$_ld" || { BAD="libpython loader is untrusted: $BAD"; return 1; }
    case ${RESOLVED##*/} in ld-linux*.so.*|ld-2.*.so) ;; *) BAD="libpython discovery: unsupported ELF loader $_ld"; return 1 ;; esac
    _loaded=$(cd / && clean "$_ld" --list "$_lb" 2>/dev/null) \
      || { BAD="libpython linkage cannot be resolved by $_ld"; return 1; }
    _libs=$(printf '%s\n' "$_loaded" | sed -n '/[Ll][Ii][Bb][Pp][Yy][Tt][Hh][Oo][Nn]/p')
    if [ -z "$_libs" ]; then
      case $_dyn in *libpython*|*libPython*) BAD="libpython dependency missing from loader report"; return 1 ;; esac
      return 0  # Python is linked statically (system Python often still links libc dynamically).
    fi
    elf_search_ok || return 1
    # A single library is required. Treat even a second alias/report line as ambiguous.
    no_controls "$(printf '%s' "$_libs" | tr -d '\t')" \
      || { BAD="libpython linkage is ambiguous or contains control characters"; return 1; }
    _lib=$(printf '%s\n' "$_libs" | sed -n 's/^[[:space:]]*[^[:space:]]* => \(\/.*\) (0x[0-9a-fA-F]*)$/\1/p; s/^[[:space:]]*\(\/[^[:space:]]*libpython[^[:space:]]*\) (0x[0-9a-fA-F]*)$/\1/p')
    [ -n "$_lib" ] && no_controls "$_lib" || { BAD="libpython location cannot be determined unambiguously"; return 1; }
    library_ok "$_lib" || return 1
  else BAD="libpython discovery is unsupported on $OS"; return 1; fi
}

# Protect explicitly configured ELF search folders too, including absent earlier candidates. The empty environment
# removes LD_LIBRARY_PATH; unsupported dynamic tokens/relative paths cannot establish a stable libpython location.
elf_search_ok() {
  _search=$(printf '%s\n' "$_dyn" | sed -n '/(RPATH)\|(RUNPATH)/s/.*\[\(.*\)\].*/\1/p')
  [ -n "$_search" ] || return 0
  no_controls "$_search" || { BAD="libpython ELF search path contains controls or is ambiguous"; return 1; }
  case $_search in :*|*:|*::*) BAD="libpython ELF search path includes the working directory"; return 1 ;; esac
  _sifs=$IFS; IFS=:; set -f
  for _sr in $_search; do
    IFS=$_sifs
    case $_sr in
      '$ORIGIN') _sr=$(dirname "$_lb") ;;
      '$ORIGIN/'*) _sr=$(dirname "$_lb")/${_sr#'$ORIGIN/'} ;;
      '${ORIGIN}'/*) _sr=$(dirname "$_lb")/${_sr#'${ORIGIN}/'} ;;
      /*) ;;
      *) set +f; BAD="libpython ELF search path cannot be resolved: $_sr"; return 1 ;;
    esac
    case $_sr in *[!A-Za-z0-9._/+-]*) set +f; BAD="libpython ELF search path is unsupported: $_sr"; return 1 ;; esac
    _probe=$_sr
    while [ ! -e "$_probe" ] && [ ! -L "$_probe" ]; do _probe=$(dirname "$_probe"); done
    trusted "$_probe" || { set +f; BAD="libpython ELF search path is untrusted: $BAD"; return 1; }
  done
  IFS=$_sifs; set +f
}

library_ok() {
  _lf=$1
  trusted "$_lf" || { BAD="libpython $_lf is untrusted: $BAD"; return 1; }
  [ -f "$RESOLVED" ] || { BAD="libpython $_lf is not a file"; return 1; }
  _lr=$RESOLVED
  [ -z "$LP_LIBRARY" ] || [ "$LP_LIBRARY" = "$_lr" ] || { BAD="libpython linkage is ambiguous"; return 1; }
  LP_LIBRARY=$_lr
  case $_lr in "$LP_ROOT"/*) ;; *) BAD="libpython $_lr is outside the trusted interpreter tree $LP_ROOT"; return 1 ;; esac
  for _lo in "$(dirname "$_lf")" "$(dirname "$_lr")"; do
    trusted "$_lo" || { BAD="libpython folder is untrusted: $BAD"; return 1; }
    _lo=$RESOLVED
    for _override in "$_lo"/*._pth "$_lo"/.*._pth; do
      [ ! -e "$_override" ] && [ ! -L "$_override" ] || { BAD="$_override (beside actual libpython: startup override)"; return 1; }
    done
    # Refuse shadow libraries between the actual libpython and prefix. Frameworks put Python/Python3 directly in
    # the prefix; its normal lib/ is already checked by prefix_ok and must remain usable for the CLT Python.
    while [ "$_lo" != "$LP_ROOT" ]; do
      case $_lo in "$LP_ROOT"/*) ;; *) BAD="libpython folder $_lo is outside $LP_ROOT"; return 1 ;; esac
      for _override in "$_lo/lib" "$_lo/lib64"; do
        [ ! -e "$_override" ] && [ ! -L "$_override" ] || { BAD="$_override (beside actual libpython: shadow library)"; return 1; }
      done
      _lo=$(dirname "$_lo")
    done
  done
}

mac_expand() {
  case $1 in
    /*) MAC_PATH=$1 ;;
    @loader_path) MAC_PATH=$(dirname "$_mb") ;;
    @executable_path) MAC_PATH=$(dirname "$_mb") ;;
    @loader_path/*) MAC_PATH=$(dirname "$_mb")/${1#@loader_path/} ;;
    @executable_path/*) MAC_PATH=$(dirname "$_mb")/${1#@executable_path/} ;;
    *) BAD="libpython: unsupported dyld path $1"; return 1 ;;
  esac
}
mac_libraries() {
  _mb=$1
  _deps=$(clean "$_otool" -L "$_mb" 2>/dev/null) || { BAD="libpython dependencies unreadable: $_mb"; return 1; }
  # A broken/multiline dependency row must never be silently dropped by the parser.
  printf '%s\n' "$_deps" | awk -v binary="$_mb" '
    $0 == binary ":" || (index($0, binary " (architecture ") == 1 && /\):$/) { header = 1; next }
    NR == 1 { exit 1 }
    /^[ \t]+.* \(compatibility version .*\)$/ { next } { exit 1 } END { if (!header) exit 1 }' \
    || { BAD="libpython dependency table is malformed"; return 1; }
  _ml=$(printf '%s\n' "$_deps" | sed -n 's/^[[:space:]]*\(.*\) (compatibility version .*$/\1/p' \
    | grep -E '(^|/)(lib[Pp]ython[^/]*|Python|Python3)$' | sort -u)
  [ -n "$_ml" ] || return 0  # no shared libpython: statically linked Python
  no_controls "$_ml" || { BAD="libpython dependencies are ambiguous or contain control characters"; return 1; }
  case $_ml in
    @rpath/*)
      _commands=$(clean "$_otool" -l "$_mb" 2>/dev/null) || { BAD="libpython rpaths unreadable"; return 1; }
      printf '%s\n' "$_commands" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") }
        r && $1 == "path" && $0 !~ / \(offset [0-9]+\)$/ { exit 1 }' \
        || { BAD="libpython rpath table is malformed"; return 1; }
      _rpaths=$(printf '%s\n' "$_commands" | awk '$1 == "cmd" { r = ($2 == "LC_RPATH") } r && $1 == "path" { sub(/^[ \t]*path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print }')
      _saveifs=$IFS; IFS='
'
      _found=; set -f
      for _rp in $_rpaths; do
        IFS=$_saveifs
        mac_expand "$_rp" || { set +f; return 1; }
        _try=$MAC_PATH/${_ml#@rpath/}
        no_controls "$_try" || { set +f; BAD="libpython rpath contains a control character"; return 1; }
        # Missing earlier candidates must also be protected: otherwise another account can plant the next load.
        _probe=$_try
        while [ ! -e "$_probe" ] && [ ! -L "$_probe" ]; do _probe=$(dirname "$_probe"); done
        trusted "$_probe" || { set +f; BAD="libpython rpath is untrusted: $BAD"; return 1; }
        if [ -e "$_try" ] || [ -L "$_try" ]; then
          trusted "$_try" || { set +f; return 1; }
          [ -z "$_found" ] || [ "$_found" = "$RESOLVED" ] || { set +f; BAD="libpython @rpath is ambiguous"; return 1; }
          _found=$RESOLVED
          library_ok "$_try" || { set +f; return 1; }
        fi
      done
      IFS=$_saveifs; set +f
      [ -n "$_found" ] || { BAD="libpython @rpath location is unknown"; return 1; } ;;
    *) mac_expand "$_ml" && library_ok "$MAC_PATH" || return 1 ;;
  esac
}
