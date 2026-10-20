# Sourced by updater-bootstrap-test.sh (P2d): the interpreter cases. The installer must refuse an interpreter whose
# start-up the bot account could steer BEFORE running it at all. Uses that file's helpers (begin, expect, inst, ...).

# a copy of this python in $SAFE/fpy with only the start-up part of its library (os.py, encodings/). Python imports
# encodings while it starts, before any -c code, so a planted encodings/__init__.py runs as whoever runs the binary.
fakepy() {  # $1 writable: the bot can write encodings/__init__.py; link: it links to a file the bot can write;
            # other: bin/python3.N beside a clean lib/python3.(N-1) only (Python then takes the stdlib from elsewhere);
            # clean: nothing planted; pth / builddir / zip: a clean copy that a protected bin/python3._pth, a protected
            # bin/pybuilddir.txt, or a lib/python3NN.zip above the prefix steers to encodings the bot can write;
            # dynload: a clean copy without lib-dynload, with one in a folder above the prefix
  FP=$SAFE/fpy; rm -rf "$FP" "$SAFE/fpy-evil.py" "$SAFE/fpy-evil" "$SAFE/lib"
  PYINFO=$(python3 -I -S -c 'import encodings, os, sys; print(os.path.realpath(sys.executable)); print(os.path.dirname(os.path.dirname(encodings.__file__)))') || return 1
  REALPY=$(printf '%s\n' "$PYINFO" | sed -n 1p) PYLIB=$(printf '%s\n' "$PYINFO" | sed -n 2p)
  L=$FP/lib/$(basename "$PYLIB")
  [ -n "$REALPY" ] && [ -d "$PYLIB/encodings" ] || return 1
  PYNAME=$(basename "$PYLIB")
  if [ "$1" = other ]; then  # the binary keeps its versioned name; the only stdlib beside it is one version lower
    L=$FP/lib/python3.$(( ${PYNAME#python3.} - 1 ))
    mkdir -p "$FP/bin" "$L" && cp "$REALPY" "$FP/bin/$PYNAME" && cp "$PYLIB/os.py" "$L/" && cp -R "$PYLIB/encodings" "$L/" \
      && find "$FP" -name __pycache__ -exec rm -rf {} + && chmod -R go-w "$FP"
    return
  fi
  mkdir -p "$FP/bin" "$L" && cp "$REALPY" "$FP/bin/python3" && cp "$PYLIB/os.py" "$L/" \
    && cp -R "$PYLIB/encodings" "$L/" && find "$FP" -name __pycache__ -exec rm -rf {} + || return 1
  if [ "$1" = dynload ]; then mkdir -p "$SAFE/lib/$PYNAME/lib-dynload" || return 1
  else mkdir "$L/lib-dynload" || return 1; fi
  chmod -R go-w "$FP" || return 1
  case $1 in clean|dynload) return 0 ;; esac
  { printf '%s\n' "import os as _o; _f = _o.open('$MARK', _o.O_WRONLY | _o.O_CREAT | _o.O_APPEND, 0o644)" \
      "_o.write(_f, b'fake-stdlib $1\\n'); _o.close(_f); del _o, _f"  # builtins.open does not exist yet
    cat "$PYLIB/encodings/__init__.py"; } > "$W/enc" || return 1
  case $1 in
    writable) E=$L/encodings/__init__.py; cat "$W/enc" > "$E" ;;
    link) E=$SAFE/fpy-evil.py; cat "$W/enc" > "$E" && rm "$L/encodings/__init__.py" && ln -s "$E" "$L/encodings/__init__.py" ;;
    *) EV=$SAFE/fpy-evil  # a folder the bot can write, holding encodings/ with the planted __init__.py
      mkdir -p "$EV" && cp -R "$PYLIB/encodings" "$EV/" && find "$EV" -name __pycache__ -exec rm -rf {} + \
        && cat "$W/enc" > "$EV/encodings/__init__.py" || return 1
      case $1 in
        pth) printf '%s\n%s\n' "$EV" "$L" > "$FP/bin/python3._pth" ;;
        builddir) printf '%s\n' "$EV" > "$FP/bin/pybuilddir.txt" ;;
        zip) mkdir -p "$SAFE/lib" && (cd "$EV" && python3 -I -S -c 'import os, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    for f in sorted(os.listdir("encodings")):
        if f.endswith(".py"): z.write("encodings/" + f)' "$SAFE/lib/python$(echo "${PYNAME#python}" | tr -d .).zip") \
          && E=$(ls "$SAFE"/lib/python3*.zip) && chmod 0666 "$E" && { [ -z "$PRIV" ] || chown bot "$E"; } ;;
      esac || return 1
      chmod -R go-w "$FP" && chmod -R a+rwX "$EV" && { [ -z "$PRIV" ] || chown -R bot "$EV"; }
      return ;;
  esac
  chmod 0666 "$E" && { [ -z "$PRIV" ] || chown bot "$E"; }
}

interpreter_refusals() {
  for v in writable link pth builddir zip; do
    begin "an interpreter whose start-up the bot could steer ($v) is refused before it runs"
    fakepy "$v" || { PROBLEMS="; cannot build the fake interpreter"; done_case; continue; }
    (cd / && env -i "$FP/bin/python3" -I -S -B -c pass) > /dev/null 2>&1
    if ! has "fake-stdlib $v" "$MARK" 2> /dev/null; then
      [ "$(uname -s)" = Darwin ] && { skip "fake interpreter ($v)" "a framework python loads its library from the framework"; continue; }
      PROBLEMS="; control: the planted encodings/__init__.py did not run at start-up"
    fi
    rm -f "$MARK"
    expect "accepted it" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$FP/bin/python3"
    expect "no refusal message" has "no trusted python3" "$W/out"
    expect "ran the interpreter before refusing it, or left a prefix" no_trace
    done_case
    rm -rf "$MARK" "$PREFIX" "$SAFE/lib"  # a failure here must not leak into the later cases
  done

  begin "an interpreter without its own stdlib beside it (only another version's) is refused before it runs"
  if fakepy other; then
    expect "accepted it" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$FP/bin/$PYNAME"
    expect "no refusal message" has "cannot tell where" "$W/out"
    expect "left a prefix" no_trace
  else PROBLEMS="; cannot build the fake interpreter"; fi
  done_case

  begin "an interpreter without lib-dynload, with one in a folder above its prefix, is refused before it runs"
  if fakepy dynload; then
    expect "accepted it" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$FP/bin/python3"
    expect "no refusal message" has "which has no lib-dynload" "$W/out"
    expect "left a prefix" no_trace
  else PROBLEMS="; cannot build the fake interpreter"; fi
  done_case
  rm -rf "$SAFE/lib"

  begin "an interpreter with a ._pth beside a libpython in its prefix (read by 3.14+ shared builds) is refused before it runs"
  if fakepy clean && mkdir -p "$FP/lib/x86_64-test" && : > "$FP/lib/x86_64-test/libpython3.99.so.1.0" \
      && : > "$FP/lib/x86_64-test/libpython3.99.so.1.0._pth" && chmod -R go-w "$FP"; then
    expect "accepted it" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$FP/bin/python3"
    expect "no refusal message" has "beside a libpython" "$W/out"
    expect "left a prefix" no_trace
  else PROBLEMS="; cannot build the fake interpreter"; fi
  done_case

  link_target_refusals
  linked_library_refusals

  # $SAFE/fpy-via is a protected link to a link in a folder the bot can write, which points back at the protected
  # copy: every named folder and the final folder are protected, only the middle hop is not (the bot could retarget it)
  begin "an interpreter reached through a link hop the bot controls is refused before it runs; so is a link loop"
  # the walk stops at the first folder that fails: the bot's home itself (root + bot), the open hop folder (fallback)
  if [ -n "$PRIV" ]; then HOP=$BHOME/hop HOPBAD=$BHOME; as_bot /bin/sh -c "mkdir -p '$HOP'"
  else HOP=$W/hop HOPBAD=$W/hop; mkdir -p "$HOP"; chmod 0777 "$HOP"; fi
  if fakepy clean && rm -f "$HOP/redir" "$SAFE/fpy-via" && ln -s "$FP" "$HOP/redir" && ln -s "$HOP/redir" "$SAFE/fpy-via"; then
    [ -z "$PRIV" ] || chown -h bot "$HOP/redir"
    expect "control: the hop does not lead to the interpreter" [ -x "$SAFE/fpy-via/bin/python3" ]
    expect "accepted it" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$SAFE/fpy-via/bin/python3"
    expect "no refusal message" has "no trusted python3" "$W/out"
    expect "the refusal does not name the bot's folder $HOPBAD" has "untrusted $HOPBAD\$" "$W/out"
    expect "left a prefix" no_trace
    ln -s fpy-loop2 "$SAFE/fpy-loop1" && ln -s fpy-loop1 "$SAFE/fpy-loop2"
    expect "accepted a link loop" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$SAFE/fpy-loop1/bin/python3"
    expect "no loop message" has "link loop" "$W/out"
    expect "left a prefix after the loop" no_trace
  else PROBLEMS="; cannot build the fake interpreter or its links"; fi
  done_case
  rm -rf "$MARK" "$PREFIX" "$FP" "$SAFE/fpy-evil.py" "$SAFE/fpy-evil" "$SAFE/fpy-via" "$SAFE/fpy-loop1" "$SAFE/fpy-loop2" "$HOP"
}

# These cases also run in the focused preflight suite, without installing a package.
link_target_refusals() {
  begin "a link to python3 with a trailing newline is refused without executing its real target"
  if fakepy clean; then
    NL=$(printf '\n.'); NL=${NL%.}
    printf '#!/bin/sh\necho newline-target >> %s\nexit 0\n' "$MARK" > "$FP/bin/python3$NL"
    chmod 0777 "$FP/bin/python3$NL"
    ln -s "python3$NL" "$FP/bin/via"
    "$FP/bin/via"; expect "control: real link target did not run" has newline-target "$MARK"
    rm -f "$MARK"
    expect "accepted a newline link target" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$FP/bin/via"
    expect "executed the real target or left a prefix" no_trace
    expect "no control-character refusal" has 'control character' "$W/out"
  else PROBLEMS="; cannot build newline fixture"; fi
  done_case
  rm -rf "$FP" "$MARK" "$PREFIX"
}

# host() builds native fixtures before Docker starts: no compiler or network is needed in the container.
linked_library_refusals() {
  for variant in pth lib writable outside missing ambiguous search; do
    begin "actual linked libpython in a custom folder: $variant"
    if fakepy clean && mkdir -p "$FP/private/deep" && cp "$PKG/linkage/python3" "$FP/bin/python3" \
        && cp "$PKG/linkage/libpython3.bootstrap.so" "$FP/private/deep/"; then
      case $variant in
        pth) : > "$FP/private/deep/libpython3.bootstrap._pth" ;;
        lib) mkdir "$FP/private/deep/lib" ;;
        writable) chmod 0666 "$FP/private/deep/libpython3.bootstrap.so" ;;
        outside) mkdir -p "$SAFE/external"; mv "$FP/private/deep/libpython3.bootstrap.so" "$SAFE/external/"
          ln -s "$SAFE/external/libpython3.bootstrap.so" "$FP/private/deep/libpython3.bootstrap.so" ;;
        search) mkdir -p "$FP/open"; chmod 0777 "$FP/open"; cp "$PKG/linkage/search" "$FP/bin/python3" ;;
        missing) rm "$FP/private/deep/libpython3.bootstrap.so" ;;
        ambiguous) cp "$PKG/linkage/libpython3.other.so" "$FP/private/deep/"; cp "$PKG/linkage/ambiguous" "$FP/bin/python3" ;;
      esac
      rm -f "$MARK"
      if [ "$variant" != missing ]; then
        "$FP/bin/python3" > /dev/null 2>&1
        expect "control: linked fixture did not execute" has linkage-target "$MARK"
        rm -f "$MARK"
      fi
        expect "accepted $variant libpython" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$FP/bin/python3"
        expect "ran the interpreter or left a prefix" no_trace
        expect "no libpython refusal" has libpython "$W/out"
    else PROBLEMS="; cannot build linkage fixture"; fi
    done_case
    rm -rf "$FP" "$MARK" "$PREFIX" "$SAFE/external"
  done
}
