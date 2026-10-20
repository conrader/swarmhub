#!/bin/sh
# P2d tests for Resources/Updater/install-bootstrap.sh (CORE-PHASES.md P2d; CORE-PLAN.md §3.5). TEST keys only (the
# debug baseline from scripts/release/baseline.py). No network inside the container, no real box, Hermes never altered.
#
#   sh Tests/Scripts/updater-bootstrap-test.sh
#       BOOTSTRAP_SH        the shell that runs the installer (default /bin/sh)
#       BOOTSTRAP_TEST_MODE docker | fallback (default: docker when it works, else fallback)
#       BOOTSTRAP_TEST_IMAGE (default python:3.12, pulled once if absent; the container runs with --network none)
#
# docker: the installer runs as root in a container with a separate unprivileged `bot` account, which then uses the
# updater. Only host() starts that mode (--inside-container plus the BOOTSTRAP_TEST_CONTAINER launch marker); anywhere
# else it refuses, because it creates `bot` and uses /opt/swarmhub-updater. A second container runs as root WITHOUT the
# marker and must fall back. fallback (no Docker; also when run as root): the same checks as the invoking user with
# --unprivileged-test and a private prefix under $HOME; it never creates an account or uses a real path; the cases that
# need a second account are reported as skipped. Exit 0 all passed, 1 a failure, 77 nothing could run.

umask 022
HERE=$(cd "$(dirname "$0")" && pwd -P)
REPO=$(cd "$HERE/../.." && pwd -P)
SELF=$HERE/$(basename "$0")
PASSED=0 FAILED=0 SKIPPED=0
if [ -x /usr/bin/sha256sum ] || [ -x /bin/sha256sum ]; then HASH=sha256sum; else HASH='shasum -a 256'; fi

begin() { NAME=$1; PROBLEMS=; }
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
done_case() {
  if [ -z "$PROBLEMS" ]; then echo "pass: $NAME"; PASSED=$((PASSED + 1))
  else
    echo "FAIL: $NAME:${PROBLEMS#;}"; FAILED=$((FAILED + 1))
    for f in "$W/out" "$W/upd"; do [ -f "$f" ] && sed -n '1,6s/^/    | /p' "$f"; done
  fi
}
skip() { echo "skip: $1 ($2)"; SKIPPED=$((SKIPPED + 1)); }
has() { grep -q -- "$1" "$2"; }
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
fails() { ! "$@"; }
. "$HERE/updater-bootstrap-linkage.sh"
. "$HERE/updater-bootstrap-interp.sh"  # fakepy, interpreter_refusals

# ======================================== host: build the TEST packages, pick a mode ===============================
host() {
  # under HOME: a snap-confined Docker cannot bind-mount the host's /tmp
  T=$(mktemp -d "${HOME:-/tmp}/.updater-bootstrap-pkg.XXXXXX") || exit 1
  CONTAINER=swarmhub-p2d-test-$$
  trap 'rm -rf "$T"; [ -n "$DOCKER" ] && "$DOCKER" rm -f "$CONTAINER" "$CONTAINER-nomark" > /dev/null 2>&1' EXIT
  PYTHONDONTWRITEBYTECODE=1 python3 -B "$REPO/scripts/release/baseline.py" embed --configuration debug --out "$T/res" \
    > "$T/embed.log" 2>&1 || { cat "$T/embed.log"; echo "SKIP: cannot build the TEST bootstrap package"; exit 77; }
  mkdir "$T/pkg" && cp "$T"/res/Bootstrap/* "$T/pkg/" && cp -R "$T/res/Baseline" "$T/pkg/Baseline" || exit 1
  MARK=/tmp/swarmhub-p2d-executed.$$
  build_linkage "$T/pkg" "$MARK" || { echo "FAIL: cannot compile TEST linkage fixtures"; exit 1; }
  # bitflip.tar: one byte changed. tampered.tar: code that leaves $MARK when run, with a matching .sha256 beside it.
  python3 -I -B - "$T/pkg" "$MARK" <<'EOF' || exit 1
import glob, hashlib, io, os, sys, tarfile
folder, mark = sys.argv[1], sys.argv[2]
package = glob.glob(os.path.join(folder, "swarmhub-updater-*.tar"))[0]
data = bytearray(open(package, "rb").read())
data[600] ^= 1
open(os.path.join(folder, "bitflip.tar"), "wb").write(bytes(data))
plant = ("open(%r, 'a').write('tampered package code ran\\n')\n" % mark).encode()
out = io.BytesIO()
with tarfile.open(package) as source, tarfile.open(fileobj=out, mode="w", format=tarfile.USTAR_FORMAT) as target:
    for member in source.getmembers():
        body = source.extractfile(member).read() if member.isfile() else None
        if member.name.endswith(("swarmhub_update/__init__.py", "swarmhub_update/cli.py")):
            body = plant + body
        elif member.name.endswith("bin/swarmhub-update"):
            first, rest = body.split(b"\n", 1)
            body = first + b"\nimport os\n" + plant + rest
        if body is not None:
            member.size = len(body)
        target.addfile(member, io.BytesIO(body) if body is not None else None)
tampered = out.getvalue()
open(os.path.join(folder, "tampered.tar"), "wb").write(tampered)
open(os.path.join(folder, "tampered.tar.sha256"), "w").write(hashlib.sha256(tampered).hexdigest() + "  tampered.tar\n")
EOF
  MODE=${BOOTSTRAP_TEST_MODE:-}
  DOCKER=$(command -v docker 2>/dev/null || { [ -x /snap/bin/docker ] && echo /snap/bin/docker; })
  if [ "$MODE" != fallback ] && [ -n "$DOCKER" ] && "$DOCKER" info > /dev/null 2>&1; then
    IMAGE=${BOOTSTRAP_TEST_IMAGE:-python:3.12}
    "$DOCKER" image inspect "$IMAGE" > /dev/null 2>&1 || "$DOCKER" pull -q "$IMAGE" > /dev/null 2>&1 \
      || { [ "$MODE" = docker ] && { echo "SKIP: cannot pull $IMAGE"; exit 77; }; DOCKER=; }
  else
    [ "$MODE" = docker ] && { echo "SKIP: Docker is not available"; exit 77; }
    DOCKER=
  fi
  HOST_FAILED=0
  if [ "$(id -u)" = 0 ] && [ -f /.dockerenv ]; then  # here the probe would really run the privileged mode
    echo "skip: --inside-container refusal on this host (it is itself a root container)"
  elif BOOTSTRAP_TEST_CONTAINER=$CONTAINER sh "$SELF" --inside-container "$REPO" "$T/pkg" "$MARK" > "$T/refuse" 2>&1 \
      || ! grep -q 'refused' "$T/refuse"; then
    echo "FAIL: --inside-container ran outside the container launch:"; sed 's/^/    | /' "$T/refuse"; HOST_FAILED=1
  else echo "pass: --inside-container outside the container launch refuses before doing anything"; fi
  if [ -n "$DOCKER" ]; then
    in_container() { _n=$1; shift; "$DOCKER" run --rm --name "$_n" --network none -e BOOTSTRAP_SH="${BOOTSTRAP_SH:-/bin/sh}" \
      -v "$REPO:/repo:ro" -v "$T/pkg:/pkg:ro" "$@"; }
    in_container "$CONTAINER" -e BOOTSTRAP_TEST_CONTAINER="$CONTAINER" "$IMAGE" \
      /bin/sh /repo/Tests/Scripts/updater-bootstrap-test.sh --inside-container /repo /pkg "$MARK" || HOST_FAILED=1
    # root without the launch marker: --inside-container refuses, the plain run falls back to a private prefix
    in_container "$CONTAINER-nomark" "$IMAGE" /bin/sh -c '
      t=/repo/Tests/Scripts/updater-bootstrap-test.sh
      if /bin/sh "$t" --inside-container /repo /pkg "$1" > /tmp/refuse 2>&1 || ! grep -q refused /tmp/refuse; then
        echo "FAIL: root --inside-container without the launch marker was not refused"; exit 1; fi
      /bin/sh "$t" --inside /repo /pkg "$1"; rc=$?
      if id bot > /dev/null 2>&1 || [ -e /opt/swarmhub-updater ] || [ -L /opt/swarmhub-updater ]; then
        echo "FAIL: root without the container marker created a bot account or used /opt/swarmhub-updater"; exit 1; fi
      echo "pass: root without the container marker created no account and left /opt/swarmhub-updater alone"
      exit $rc' sh "$MARK" || HOST_FAILED=1
  else
    sh "$SELF" --inside "$REPO" "$T/pkg" "$MARK" || HOST_FAILED=1
  fi
  return $HOST_FAILED
}

# ======================================== inside: root + bot (container) or the invoking user (fallback) ===========
setup() {
  REPO=$1 PKG=$2 MARK=$3
  if [ -n "$IN_CONTAINER" ]; then  # refuse unless this is the container host() launched (before any side effect)
    why=
    case ${BOOTSTRAP_TEST_CONTAINER:-} in swarmhub-p2d-test-*) ;; *) why="no launch marker" ;; esac
    [ "$(id -u)" = 0 ] || why="${why:+$why, }not root"
    [ -f /.dockerenv ] || why="${why:+$why, }no /.dockerenv"
    [ -z "$why" ] || { echo "--inside-container refused ($why): it creates a bot account and uses /opt/swarmhub-updater"; exit 1; }
  fi
  S=$REPO/Resources/Updater/install-bootstrap.sh ISH=${BOOTSTRAP_SH:-/bin/sh}
  PACKAGE=$(ls "$PKG"/swarmhub-updater-*.tar) && GOOD=$(cut -d' ' -f1 "$PACKAGE.sha256") || exit 1
  if [ -n "$IN_CONTAINER" ]; then
    PRIV=1 MODE=docker W=/tmp/w TFLAG= PREFIX=/opt/swarmhub-updater BPATH=/usr/local/bin:/usr/bin:/bin SAFE=/opt/p2d-scratch
    mkdir -p "$W" "$SAFE" && chmod 0700 "$W" && chmod 0755 "$SAFE"
    id bot > /dev/null 2>&1 || useradd -m -s /bin/sh bot || adduser --disabled-password --gecos '' bot > /dev/null || exit 1
    BHOME=$(cd ~bot && pwd -P)
  else  # also as root: a private prefix, no second account, nothing outside $W
    PRIV= MODE=fallback TFLAG=--unprivileged-test BPATH=/usr/bin:/bin
    [ "$(id -u)" = 0 ] && MODE="fallback as root"
    W=$(mktemp -d "${HOME:-/nonexistent}/.updater-bootstrap-test.XXXXXX") || exit 1   # not under /tmp: the installer refuses it
    BHOME=$W/home PREFIX=$W/opt/swarmhub-updater SAFE=$W
    trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W" "$MARK"' EXIT
  fi
  rm -f "$MARK"
  ST=$BHOME/.local/state/swarmhub-update H=$BHOME/.hermes EVIL=$BHOME/evil STAGED=$BHOME/staged
  mkdir -p "$H/hermes-agent/gateway/platforms" "$H/skills/other-category/keep" \
    "$H/profiles/coder_2/plugins/swarmhub-peer" "$H/swarmhub" "$BHOME/pkg"
  cp "$REPO/Tests/Fixtures/hermes_v0.21.7_server.py" "$H/hermes-agent/gateway/platforms/api_server.py"
  printf 'model: test\n' > "$H/config.yaml"; printf 'API_SERVER_KEY=not-a-real-key\n' > "$H/.env"
  printf -- '---\nname: keep\n---\n' > "$H/skills/other-category/keep/SKILL.md"
  printf 'import runpy\n' > "$H/profiles/coder_2/plugins/swarmhub-peer/__init__.py"
  HERMES_FILES="hermes-agent/gateway/platforms/api_server.py config.yaml .env skills/other-category/keep/SKILL.md profiles/coder_2/plugins/swarmhub-peer/__init__.py"
  (cd "$H" && $HASH $HERMES_FILES) > "$W/hermes.before"
  cp -R "$PKG/Baseline" "$STAGED"
  printf '%s' '{"schema": "swarmhub/profiles/1", "profiles": [{"name": "default", "coding_order": "claude,codex,hermes", "skills": null}, {"name": "coder_2", "coding_order": "codex", "skills": ["swarmhub-coding", "swarmhub-messages"]}]}' > "$STAGED/profiles.json"
  cp "$PACKAGE" "$PACKAGE.sha256" "$BHOME/pkg/"
  PACKAGE=$BHOME/pkg/$(basename "$PACKAGE")
  [ -n "$PRIV" ] && chown -R bot:bot "$BHOME"
  HOME_TOUCHED= TESTKEYS=--allow-test-keys
}
as_bot_env() {  # env -i as the bot account (fallback: as this user)
  if [ -n "$PRIV" ]; then
    python3 -I -c 'import os, pwd, sys
p = pwd.getpwnam("bot"); os.setgroups([]); os.setgid(p.pw_gid); os.setuid(p.pw_uid); os.execv(sys.argv[1], sys.argv[1:])' \
      /usr/bin/env -i "$@"
  else /usr/bin/env -i "$@"; fi
}
as_bot() { as_bot_env HOME="$BHOME" PATH="$BPATH" LANG=C.UTF-8 "$@"; }
upd() { as_bot "$PREFIX/bin/swarmhub-update" --state-dir "$ST" --hermes-home "$H" --max-wait 0 "$@" > "$W/upd" 2>&1; }
snap() { (cd "$1" && find . -exec ls -ldn {} + | awk '{ $6 = $7 = $8 = ""; print }' && find . -type f -exec $HASH {} +) | sort; }
inst() {  # the installer as the operator; records whether it changed anything in the bot's home
  snap "$BHOME" > "$W/home.before"
  $ISH "$S" "$@" $TFLAG $TESTKEYS > "$W/out" 2>&1; _rc=$?
  snap "$BHOME" > "$W/home.after"
  cmp -s "$W/home.before" "$W/home.after" || HOME_TOUCHED="$HOME_TOUCHED $1"
  return $_rc
}
pins() { cat "$PREFIX/current/pins.json"; }
no_trace() { absent "$PREFIX" && absent "$MARK" && [ -z "$(ls -a "$(dirname "$PREFIX")" | grep '^\.swarmhub-bootstrap\.')" ]; }

refusals() {
  begin "an altered package (one flipped byte) fails the hash check before anything is extracted or run"
  cp "$PKG/bitflip.tar" "$BHOME/pkg/bitflip.tar"
  expect "installer accepted it" fails inst install --prefix "$PREFIX" --package "$BHOME/pkg/bitflip.tar" --sha256 "$GOOD"
  expect "no mismatch message" has "SHA-256 mismatch" "$W/out"
  expect "left a prefix, a staging folder or ran code" no_trace
  done_case

  begin "a tampered package with a matching .sha256 beside it is refused against the app value; its code never runs"
  cp "$PKG/tampered.tar" "$PKG/tampered.tar.sha256" "$BHOME/pkg/"
  expect "installer accepted it" fails inst install --prefix "$PREFIX" --package "$BHOME/pkg/tampered.tar" --sha256 "$GOOD"
  expect "no mismatch message" has "SHA-256 mismatch" "$W/out"
  expect "left a prefix, a staging folder or ran code" no_trace
  TAMPERED=$(cut -d' ' -f1 "$PKG/tampered.tar.sha256")
  inst install --prefix "$PREFIX-control" --package "$BHOME/pkg/tampered.tar" --sha256 "$TAMPERED"
  expect "control: with its own digest the planted code runs (so the check above had something to stop)" has ran "$MARK"
  inst uninstall --prefix "$PREFIX-control"; rm -f "$MARK"
  done_case

  begin "a .sha256 file that disagrees with the app value is refused"
  mkdir -p "$W/side" && cp "$PACKAGE" "$W/side/" && printf '%064d  x.tar\n' 0 > "$W/side/$(basename "$PACKAGE").sha256"
  expect "installer accepted it" fails inst install --prefix "$PREFIX" --package "$W/side/$(basename "$PACKAGE")" --sha256 "$GOOD"
  expect "no disagreement message" has "the app says" "$W/out"
  expect "left a prefix or a staging folder" no_trace
  done_case

  begin "a package that pins TEST- roots is refused without --allow-test-keys, after its hash matched"
  TESTKEYS=
  expect "installer accepted TEST roots" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD"
  expect "no TEST-key message" has "pins TEST- root keys" "$W/out"
  expect "hash was not checked first" has "matches" "$W/out"
  TESTKEYS=--allow-test-keys
  expect "left a prefix, a staging folder or ran code" no_trace
  done_case

  if [ -n "$PRIV" ] || [ "$(id -u)" != 0 ]; then
    begin "the installer refuses to run without root (and without the test flag)"
    if [ -n "$PRIV" ]; then
      as_bot /bin/sh "$S" install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" > "$W/out" 2>&1; rc=$?
    else
      $ISH "$S" install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" > "$W/out" 2>&1; rc=$?
    fi
    expect "rc $rc" [ "$rc" = 1 ]
    expect "no root message" has "run as root" "$W/out"
    expect "left a prefix" no_trace
    done_case
  else skip "the installer refuses to run without root" "this run is root with no second account: run with Docker"; fi

  begin "a prefix in a folder another account can write is refused"
  if [ -n "$PRIV" ]; then bad1=$BHOME/updater; else bad1=$W/open/updater; mkdir -p "$W/open"; chmod 0777 "$W/open"; fi
  expect "accepted $bad1" fails inst install --prefix "$bad1" --package "$PACKAGE" --sha256 "$GOOD"
  expect "accepted /tmp" fails inst install --prefix "/tmp/swarmhub-p2d-$$/updater" --package "$PACKAGE" --sha256 "$GOOD"
  expect "created something" absent "$bad1"
  expect "created something in /tmp" absent "/tmp/swarmhub-p2d-$$"
  done_case

  begin "an interpreter another account can write is refused before it runs"
  printf '#!/bin/sh\necho fake python ran >> %s\nexit 0\n' "$MARK" > "$W/py"; chmod 0777 "$W/py"
  expect "accepted a world-writable python" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$W/py"
  if [ -n "$PRIV" ]; then
    cp "$(readlink -f /usr/local/bin/python3)" "$BHOME/py3" && chown bot "$BHOME/py3"
    expect "accepted a bot-owned python" fails inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD" --python "$BHOME/py3"
    rm -f "$BHOME/py3"
  fi
  expect "no refusal message" has "no trusted python3" "$W/out"
  expect "left a prefix or ran the fake python" no_trace
  done_case

  interpreter_refusals  # updater-bootstrap-interp.sh
}

install_checks() {
  begin "the genuine package installs; verify passes; launcher pins an absolute interpreter with -IBS"
  expect "install failed" inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD"
  expect "verify failed" inst verify --prefix "$PREFIX"
  IFS= read -r first < "$PREFIX/current/bin/swarmhub-update"
  case $first in '#!/'*python3*' -IBS') ;; *) PROBLEMS="$PROBLEMS; shebang $first" ;; esac
  expect "pins differ from the package pins" cmp -s "$PREFIX/current/pins.json" "$PKG/Baseline/pins.json"
  if [ -n "$PRIV" ]; then
    expect "a file not owned by root or writable by others" [ -z "$(find "$PREFIX" \( ! -user 0 -o \( ! -type l -perm -0022 \) \) -print)" ]
  fi
  expect "the bot cannot run it" upd status
  done_case

  if [ -z "$PRIV" ]; then
    skip "the bot account cannot modify the updater, pins or checkpoint" "needs a second account: run with Docker"
    return
  fi
  begin "the bot account cannot modify the updater, the pins or the checkpoint"
  CUR=$PREFIX/current
  expect "control: as_bot is not the bot account" [ "$(as_bot id -u)" = "$(id -u bot)" ]
  expect "control: the bot cannot write its own home" as_bot /bin/sh -c "touch '$BHOME/.ctl' && rm '$BHOME/.ctl'"
  snap "$PREFIX" > "$W/prefix.before"
  for attempt in "echo x >> $CUR/pins.json" "rm -f $CUR/pins.json" "mv $CUR/pins.json $CUR/p" "cp /dev/null $CUR/pins.json" \
      "chmod 0666 $CUR/pins.json" "touch $CUR/swarmhub_update/evil.py" "echo x >> $CUR/swarmhub_update/cli.py" \
      "echo x >> $CUR/bin/swarmhub-update" "ln -sfn /tmp $PREFIX/current" "rm -f $PREFIX/bin/swarmhub-update" \
      "mkdir $PREFIX/releases/evil" "mv $PREFIX $PREFIX.x" "rm -rf $PREFIX" "echo x >> $PREFIX/bootstrap.log" \
      "ln -s /tmp $PREFIX/previous"; do
    as_bot /bin/sh -c "$attempt" > /dev/null 2>&1 && PROBLEMS="$PROBLEMS; bot could: $attempt"
  done
  snap "$PREFIX" > "$W/prefix.after"
  expect "the install changed" cmp -s "$W/prefix.before" "$W/prefix.after"
  done_case
}

isolation() {
  begin "the updater imports nothing from PYTHONPATH, PYTHONHOME, the cwd, the user site or PATH"
  PYI=$(sed -n '1s/^#!\([^ ]*\).*/\1/p' "$PREFIX/current/bin/swarmhub-update")
  USITE=$(as_bot "$PYI" -c 'import site; print(site.getusersitepackages())')
  mark() { printf "open(%s, 'a').write('%s\\\\n')\n" "'$MARK'" "$1"; }
  as_bot /bin/sh -c "mkdir -p '$EVIL/swarmhub_update' '$EVIL/bin' '$USITE/swarmhub_update'" || PROBLEMS="$PROBLEMS; cannot plant"
  for m in json argparse hashlib fcntl contextlib sitecustomize usercustomize swarmhub_update/__init__ swarmhub_update/cli; do
    mark "$m" > "$W/plant"; as_bot /bin/sh -c "cat > '$EVIL/$m.py'" < "$W/plant"
  done
  mark startup > "$W/plant"; as_bot /bin/sh -c "cat > '$EVIL/startup.py'" < "$W/plant"
  for m in usercustomize sitecustomize swarmhub_update/__init__; do
    mark "user-site $m" > "$W/plant"; as_bot /bin/sh -c "cat > '$USITE/$m.py'" < "$W/plant"
  done
  printf 'import os; open(%s, "a").write("pth\\n")\n' "'$MARK'" > "$W/plant"; as_bot /bin/sh -c "cat > '$USITE/evil.pth'" < "$W/plant"
  for b in python3 python3.12 env; do
    printf '#!/bin/sh\necho "PATH %s" >> %s\nexit 1\n' "$b" "$MARK" > "$W/plant"
    as_bot /bin/sh -c "cat > '$EVIL/bin/$b' && chmod 0755 '$EVIL/bin/$b'" < "$W/plant"
  done
  hostile() {
    (cd "$EVIL" && as_bot_env HOME="$BHOME" PATH="$EVIL/bin:$BPATH" PYTHONPATH="$EVIL" PYTHONHOME="$EVIL" \
      PYTHONSTARTUP="$EVIL/startup.py" PYTHONUSERBASE="$BHOME/.local" LANG=C.UTF-8 \
      "$PREFIX/bin/swarmhub-update" --state-dir "$ST" --hermes-home "$H" --max-wait 0 "$@" > "$W/upd" 2>&1 < /dev/null)
  }
  expect "status failed" hostile status
  expect "verify --staged failed" hostile verify --staged "$STAGED"
  expect "verify did not accept" has '"verdict": "accept"' "$W/upd"
  [ -e "$MARK" ] && PROBLEMS="$PROBLEMS; planted code ran: $(tr '\n' ' ' < "$MARK")"
  rm -f "$MARK"
  (cd "$EVIL" && as_bot_env HOME="$BHOME" PATH="$BPATH" PYTHONPATH="$EVIL" "$PYI" -c 'import json' > /dev/null 2>&1)
  (cd / && as_bot_env HOME="$BHOME" PATH="$BPATH" "$PYI" -c 'pass' > /dev/null 2>&1)
  (cd "$EVIL" && as_bot_env HOME="$BHOME" PATH="$EVIL/bin:$BPATH" python3 -c 'pass' > /dev/null 2>&1)
  expect "control: the planted json.py did not fire without -I" has '^json$' "$MARK"
  expect "control: the user site did not fire without -I" has 'user-site usercustomize' "$MARK"
  expect "control: the user-site .pth did not fire without -S" has '^pth$' "$MARK"
  expect "control: the planted python3 on PATH did not fire" has 'PATH python3' "$MARK"
  rm -f "$MARK"
  done_case
}

apply_and_maintenance() {
  begin "the bot applies the embedded TEST baseline through the installed updater"
  expect "apply --staged" upd apply --staged "$STAGED"
  expect "confirm" upd apply --version 1
  expect "not current" has '"state": "current"' "$W/upd"
  expect "status not protected" upd status
  if [ -n "$PRIV" ]; then expect "status does not say the pins are protected" has '"protected": true' "$W/upd"
  else expect "status claims protection for a same-account install" has '"protected": false' "$W/upd"; fi
  expect "no skill installed" [ -f "$H/skills/swarmhub/swarmhub-coding/SKILL.md" ]
  done_case

  begin "a maintenance pass raises the checkpoint; the bot cannot go below it, even after wiping its state"
  expect "maintenance failed" inst maintenance --prefix "$PREFIX" --min-bundle-version 2 --min-index-seq 1
  expect "pins lack the new floor" has '"min_bundle_version":2' "$PREFIX/current/pins.json"
  expect "accepted below the checkpoint" fails upd verify --staged "$STAGED"
  expect "not bundle_rollback" has bundle_rollback "$W/upd"
  as_bot /bin/sh -c "rm -rf '$ST'"
  expect "accepted after a state wipe" fails upd verify --staged "$STAGED"
  expect "not bundle_rollback after wipe" has bundle_rollback "$W/upd"
  done_case

  begin "a maintenance pass never lowers the checkpoint"
  pins > "$W/pins.before"
  expect "lowered" fails inst maintenance --prefix "$PREFIX" --min-bundle-version 1
  expect "no refusal message" has "never goes down" "$W/out"
  expect "pins changed" cmp -s "$W/pins.before" "$PREFIX/current/pins.json"
  done_case

  begin "a maintenance pass revokes a release key; the bot's verify refuses it"
  expect "revoke failed" inst maintenance --prefix "$PREFIX" --revoke TEST-release-1
  expect "accepted a revoked key" fails upd verify --staged "$STAGED"
  expect "not key_revoked" has key_revoked "$W/upd"
  done_case

  begin "installing again keeps the higher checkpoint and revocations; rollback keeps them too"
  FIRST=$(readlink "$PREFIX/current")
  sleep 1
  expect "reinstall failed" inst install --prefix "$PREFIX" --package "$PACKAGE" --sha256 "$GOOD"
  expect "previous is not the first release" [ "$(readlink "$PREFIX/previous")" = "$FIRST" ]
  expect "reinstall lost the checkpoint" has '"min_bundle_version":2' "$PREFIX/current/pins.json"
  expect "reinstall lost the revocation" has TEST-release-1 "$PREFIX/current/pins.json"
  expect "rollback failed" inst rollback --prefix "$PREFIX"
  expect "current is not the first release" [ "$(readlink "$PREFIX/current")" = "$FIRST" ]
  expect "rollback lost the checkpoint" has '"min_bundle_version":2' "$PREFIX/current/pins.json"
  expect "rollback lost the revocation" has TEST-release-1 "$PREFIX/current/pins.json"
  expect "verify after rollback" inst verify --prefix "$PREFIX"
  done_case

  begin "verify reports an installed file that differs from what was installed"
  F=$PREFIX/current/swarmhub_update/jcs.py
  cp "$F" "$W/jcs.py" && printf '# changed\n' >> "$F"
  expect "verify passed a changed file" fails inst verify --prefix "$PREFIX"
  cp "$W/jcs.py" "$F"
  expect "verify after restore" inst verify --prefix "$PREFIX"
  done_case

  begin "verify follows links: one to a file the bot can write, or to anything outside the install, is refused"
  D=$(cd -P "$PREFIX/current" && pwd -P)/swarmhub_update
  mkdir -p "$SAFE/outside" && printf '# planted\n' > "$SAFE/outside/evil.py" && cp "$SAFE/outside/evil.py" "$SAFE/outside/plain.py"
  chmod 0666 "$SAFE/outside/evil.py"; [ -z "$PRIV" ] || chown bot "$SAFE/outside/evil.py"
  for target in "$SAFE/outside/evil.py" "$SAFE/outside/plain.py" "$SAFE/outside"; do
    ln -s "$target" "$D/zz_link.py"
    expect "verify accepted a link to $target" fails inst verify --prefix "$PREFIX"
    expect "no link named in the refusal for $target" has zz_link "$W/out"
    rm -f "$D/zz_link.py"
  done
  rm -rf "$SAFE/outside"
  expect "verify after removing the links" inst verify --prefix "$PREFIX"
  done_case
}

finale() {
  begin "no bytecode in the install; the installer wrote nothing in the bot's home; Hermes files byte-identical"
  expect "__pycache__ in the install" [ -z "$(find "$PREFIX" -name __pycache__ -print)" ]
  expect "the installer changed the bot's home during:$HOME_TOUCHED" [ -z "$HOME_TOUCHED" ]
  expect "a Hermes file changed" sh -c "cd '$H' && $HASH $HERMES_FILES | cmp -s - '$W/hermes.before'"
  done_case

  begin "uninstall removes only the prefix; the bot's state and Hermes stay"
  expect "uninstall failed" inst uninstall --prefix "$PREFIX"
  expect "prefix remains" absent "$PREFIX"
  expect "installed skills removed" [ -f "$H/skills/swarmhub/swarmhub-coding/SKILL.md" ]
  expect "a Hermes file changed" sh -c "cd '$H' && $HASH $HERMES_FILES | cmp -s - '$W/hermes.before'"
  expect "the installer changed the bot's home during:$HOME_TOUCHED" [ -z "$HOME_TOUCHED" ]
  done_case
}

inside() {
  setup "$@"
  echo "updater-bootstrap ($MODE, installer under $ISH, $(uname -s))"
  refusals
  install_checks
  isolation
  apply_and_maintenance
  finale
  echo "updater-bootstrap ($MODE, $ISH): $PASSED passed, $FAILED failed, $SKIPPED skipped"
  [ "$FAILED" = 0 ]
}

IN_CONTAINER=
case ${1:-} in
  --inside) shift; inside "$@" ;;
  --inside-container) shift; IN_CONTAINER=1; inside "$@" ;;
  *) host ;;
esac
