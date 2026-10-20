#!/bin/sh
# Focused tests of the real preflight functions. The full installer suite checks root ownership end to end.
# This harness checks real fixture ownership, but exempts ancestors/system files from node_ok: sandbox mounts can
# remap root to nobody and make HOME read-only. It never runs an install or weakens the shipped owner checks.
set -u
umask 022
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
W=$(mktemp -d /tmp/updater-preflight.XXXXXX) || exit 1
W=$(cd "$W" && pwd -P)
trap 'chmod -R u+w "$W"; rm -rf "$W"' EXIT
SAFE=$W PKG=$W/pkg MARK=$W/executed PREFIX=$W/prefix PRIV= PACKAGE=unused GOOD=unused
PASSED=0 FAILED=0 SKIPPED=0 OS=$(uname -s) TRUST_UID=$(id -u) TEST_MODE=1
PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
export PATH LC_ALL
. "$HERE/updater-bootstrap-linkage.sh"
. "$HERE/updater-bootstrap-interp.sh"
# --before uses precisely the functions at the reviewed commit, with the new tests.
if [ "${1:-}" = --before ]; then
  git -C "$REPO" show 793969f:Resources/Updater/install-bootstrap.sh | sed -n '/^acl_ok()/,/^# ---- small Python helpers/{ /^# ---- small Python helpers/d; p; }' > "$W/functions"
  git -C "$REPO" show 793969f:Resources/Updater/install-bootstrap.sh | sed -n '/^tree_ok()/,/^}/p' >> "$W/functions"
  . "$W/functions"
else
  . "$REPO/Resources/Updater/bootstrap-preflight.sh"
fi
# Preserve the shipped node check for every node of each test fixture.
# POSIX sh has no function printing: read the small definition from the same source instead.
if [ "${1:-}" = --before ]; then _source=$W/functions; else _source=$REPO/Resources/Updater/bootstrap-preflight.sh; fi
sed -n '/^node_ok()/,/^}/p' "$_source" | sed '1s/node_ok/fixture_node_ok/' > "$W/node"
. "$W/node"
node_ok() { case $1 in "$W"/*) fixture_node_ok "$1" ;; *) return 0 ;; esac; }
clean() { env -i PATH="$PATH" LC_ALL=C "$@"; }
begin() { NAME=$1; PROBLEMS=; }
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
has() { grep -q -- "$1" "$2"; }
fails() { ! "$@"; }
no_trace() { [ ! -e "$MARK" ] && [ ! -e "$PREFIX" ]; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1))
  else echo "FAIL: $NAME:$PROBLEMS"; cat "$W/out"; FAILED=$((FAILED + 1)); fi
}
inst() {
  # The shared regression cases supply normal installer arguments; only --python is needed here.
  while [ "$1" != --python ]; do shift; done
  BAD=
  python_ok "$2" > "$W/out" 2>&1; _status=$?
  [ "$_status" = 0 ] || printf '%s\n' "$BAD" >> "$W/out"
  return "$_status"
}
build_linkage "$PKG" "$MARK" || exit 1
link_target_refusals
linked_library_refusals
if [ "${1:-}" != --before ]; then
  begin "protected libpython in a custom folder passes without executing library constructors during discovery"
  fakepy clean && cp "$PKG/linkage/python3" "$FP/bin/python3" && mkdir -p "$FP/private/deep" &&
    cp "$PKG/linkage/libpython3.bootstrap.so" "$FP/private/deep/" || exit 1
  expect "safe linked library refused" linked_python_ok "$FP/bin/python3" "$FP"
  expect "loader inspection ran library constructors" no_trace
  done_case

  begin "builds with no shared libpython pass linkage discovery"
  printf 'int main(void) { return 0; }\n' > "$W/static.c"
  cc "$W/static.c" -o "$FP/bin/static-python" || exit 1
  expect "non-shared Python refused" linked_python_ok "$FP/bin/static-python" "$FP"
  if [ "$OS" = Linux ]; then
    cc -static "$W/static.c" -o "$FP/bin/static-python" || exit 1
    expect "fully static ELF refused" linked_python_ok "$FP/bin/static-python" "$FP"
  fi
  done_case

  begin "with no shared libpython, a library search folder another account can write is still refused"
  mkdir -p "$FP/open" && cp "$PKG/linkage/nolib-search" "$FP/bin/nolib-python" || exit 1
  expect "control: protected search folder refused" linked_python_ok "$FP/bin/nolib-python" "$FP"
  chmod 0777 "$FP/open"
  expect "accepted a writable search folder" fails linked_python_ok "$FP/bin/nolib-python" "$FP"
  done_case  # (a fully static ELF has no dynamic section: the linker drops its rpath and no loader runs)
  rm -rf "$FP/open"

  begin "without readelf (binutils) the refusal says binutils is missing, before anything runs"
  mkdir -p "$W/nobin"; rm -f "$MARK"
  (PATH=$W/nobin; die() { printf '%s\n' "$*"; exit 1; }; python_ok "$FP/bin/python3") > "$W/out" 2>&1
  expect "accepted without readelf" [ "$?" != 0 ]
  expect "no plain binutils message" has "binutils is not installed" "$W/out"
  expect "ran the interpreter" no_trace
  done_case
fi

for control in 10 13 9 27 127; do
  byte=$(printf "\\$(printf '%03o' "$control")."); byte=${byte%.}
  begin "path components and link targets containing control byte $control are refused"
  mkdir -p "$SAFE/controls"
  : > "$SAFE/controls/plain"; : > "$SAFE/controls/name$byte"
  ln -s "name$byte" "$SAFE/controls/link"
  expect "accepted a control in a path" fails trusted "$SAFE/controls/name$byte"
  expect "accepted a control in a link target" fails trusted "$SAFE/controls/link"
  expect "accepted a control in a tree entry" fails tree_ok "$SAFE/controls"
  done_case
  rm -rf "$SAFE/controls"
done

if [ "${1:-}" != --before ]; then
  # Deterministic otool tables test Darwin resolution here; the MacBook must also exercise real CLT binaries.
  _otool=$W/otool
  cat > "$_otool" <<'OTOOL'
#!/bin/sh
case $1 in -L) cat "$TABLE_DEPS" ;; -l) cat "$TABLE_RPATHS" ;; *) exit 1 ;; esac
OTOOL
  chmod 0755 "$_otool"
  TABLE_DEPS=$W/deps TABLE_RPATHS=$W/rpaths
  export TABLE_DEPS TABLE_RPATHS
  # mac_libraries calls clean(), so allow only these two TEST fixture variables in its fake tool's environment.
  clean() { env -i PATH="$PATH" LC_ALL=C TABLE_DEPS="$TABLE_DEPS" TABLE_RPATHS="$TABLE_RPATHS" "$@"; }
  LP_ROOT=$SAFE/framework
  mkdir -p "$LP_ROOT/bin" "$LP_ROOT/lib/python3.12" "$LP_ROOT/Resources/Python.app/Contents/MacOS"
  : > "$LP_ROOT/Python3"; : > "$LP_ROOT/bin/python3"
  for mode in absolute rpath loader app ambiguous unknown pth multiline badheader badrpath openrpath nolib nolibopen otherrpath; do
    begin "macOS framework libpython resolution: $mode"
    LP_LIBRARY=
    dep=$LP_ROOT/Python3
    case $mode in
      rpath|ambiguous|unknown|badrpath|openrpath) dep=@rpath/Python3 ;;
      loader) dep=@loader_path/../Python3 ;;
      multiline) dep="$LP_ROOT/missing
$LP_ROOT/Python3" ;;
    esac
    _candidate=$LP_ROOT/bin/python3
    [ "$mode" != app ] || { _candidate=$LP_ROOT/Resources/Python.app/Contents/MacOS/Python; dep=@executable_path/../../../../Python3; }
    printf '%s:\n\t%s (compatibility version 3.0.0, current version 3.12.0)\n' "$_candidate" "$dep" > "$TABLE_DEPS"
    printf '          cmd LC_RPATH\n      cmdsize 48\n         path %s (offset 12)\n' "$LP_ROOT" > "$TABLE_RPATHS"
    case $mode in
      app) _candidate=$LP_ROOT/Resources/Python.app/Contents/MacOS/Python ;;
      ambiguous) mkdir -p "$LP_ROOT/other"; : > "$LP_ROOT/other/Python3"
        printf '          cmd LC_RPATH\n         path %s/other (offset 12)\n' "$LP_ROOT" >> "$TABLE_RPATHS" ;;
      unknown) : > "$TABLE_RPATHS" ;;
      badheader) : > "$TABLE_DEPS" ;;
      badrpath) printf 'cmd LC_RPATH\npath bad\nname (offset 12)\n' > "$TABLE_RPATHS" ;;
      openrpath) mkdir -p "$LP_ROOT/open"; chmod 0777 "$LP_ROOT/open"
        printf 'cmd LC_RPATH\npath %s/open (offset 12)\n' "$LP_ROOT" >> "$TABLE_RPATHS" ;;
      pth) : > "$LP_ROOT/Python3._pth" ;;
      nolib|nolibopen|otherrpath)  # no libpython linked; dyld still searches LC_RPATH for any @rpath library
        dep=/usr/lib/libSystem.B.dylib; [ "$mode" != otherrpath ] || dep=@rpath/libz.1.dylib
        printf '%s:\n\t%s (compatibility version 1.0.0, current version 1.0.0)\n' "$_candidate" "$dep" > "$TABLE_DEPS"
        [ "$mode" = nolib ] || printf 'cmd LC_RPATH\npath %s/open/later (offset 12)\n' "$LP_ROOT" >> "$TABLE_RPATHS" ;;
    esac
    case $mode in
      ambiguous|unknown|pth|multiline|badheader|badrpath|openrpath|nolibopen|otherrpath) expect "accepted unsafe framework linkage" fails mac_libraries "$_candidate" ;;
      *) expect "refused normal framework linkage" mac_libraries "$_candidate" ;;
    esac
    done_case
    rm -f "$LP_ROOT/Python3._pth"
  done
fi
printf 'updater-bootstrap-preflight: %s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[ "$FAILED" = 0 ]
