# Sourced by the bootstrap suites. Native TEST fixtures only; constructors mark actual execution so that a loader
# inspection which accidentally starts a candidate is caught too. Built on the host, never inside Docker.
build_linkage() {
  mkdir -p "$1/linkage" || return 1
  cat > "$1/linkage/library.c" <<'C'
#include <stdio.h>
#ifndef SYMBOL
#define SYMBOL fixture
#endif
int SYMBOL(void) { return 0; }
__attribute__((constructor)) static void started(void) {
    FILE *f = fopen(MARK, "a");
    if (f) { fputs("linkage-target\n", f); fclose(f); }
}
C
  cat > "$1/linkage/main.c" <<'C'
extern int fixture(void);
#ifdef OTHER
extern int other(void);
#endif
int main(void) {
#ifdef OTHER
    return fixture() + other();
#else
    return fixture();
#endif
}
C
  if [ "$(uname -s)" = Darwin ]; then
    cc -dynamiclib -DMARK="\"$2\"" -Wl,-install_name,@rpath/libpython3.bootstrap.so \
      "$1/linkage/library.c" -o "$1/linkage/libpython3.bootstrap.so" &&
    cc -dynamiclib -DMARK="\"$2\"" -DSYMBOL=other -Wl,-install_name,@rpath/libpython3.other.so \
      "$1/linkage/library.c" -o "$1/linkage/libpython3.other.so" || return 1
    _rpath='@loader_path/../private/deep'
  else
    cc -shared -fPIC -DMARK="\"$2\"" -Wl,-soname,libpython3.bootstrap.so \
      "$1/linkage/library.c" -o "$1/linkage/libpython3.bootstrap.so" &&
    cc -shared -fPIC -DMARK="\"$2\"" -DSYMBOL=other -Wl,-soname,libpython3.other.so \
      "$1/linkage/library.c" -o "$1/linkage/libpython3.other.so" || return 1
    _rpath='$ORIGIN/../private/deep'
  fi
  cc "$1/linkage/main.c" "$1/linkage/libpython3.bootstrap.so" -Wl,-rpath,"$_rpath/../../open" \
    -Wl,-rpath,"$_rpath" -o "$1/linkage/search" &&
  cc "$1/linkage/main.c" "$1/linkage/libpython3.bootstrap.so" -Wl,-rpath,"$_rpath" -o "$1/linkage/python3" &&
  cc -DOTHER "$1/linkage/main.c" "$1/linkage/libpython3.bootstrap.so" "$1/linkage/libpython3.other.so" \
    -Wl,-rpath,"$_rpath" -o "$1/linkage/ambiguous" || return 1
  # no shared libpython at all (as in a statically linked Python), but a search folder for its other libraries
  printf 'int main(void) { return 0; }\n' > "$1/linkage/nolib.c"
  cc "$1/linkage/nolib.c" -Wl,-rpath,"$_rpath/../../open" -o "$1/linkage/nolib-search"
}
