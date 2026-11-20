#!/bin/bash
# Install the signed release archive at its only supported path.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/unregister-app.sh
source "$root/unregister-app.sh"
target="/Applications/SwarmHub.app"
lock=/Applications/.swarmhub-install.lock
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 1 && -f "$1" ]] || die "Usage: $0 /path/to/SwarmHub-release.zip"
archive="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
mkdir "$lock" 2>/dev/null || die "Cannot start installation in /Applications. Check access and whether another installation is running."

staged="$lock/incoming/SwarmHub.app"
previous="$lock/previous"
replacement_started=0
verified=0
app_pid=
timer_pid=
cleanup() {
  local result=$?
  trap - EXIT
  if [[ -n "$timer_pid" ]]; then kill "$timer_pid" 2>/dev/null || true; fi
  if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; fi
  if [[ "$verified" == 0 && ( -d "$previous" || "$replacement_started" == 1 ) ]]; then
    if [[ ! -d "$staged" && -d "$target" ]]; then
      unregister_app "$target"
      /bin/rm -rf "$target"
    fi
    if [[ -d "$previous" ]]; then
      if ! /bin/mv -h "$previous" "$target"; then
        printf 'ERROR: Could not restore the previous app at %s. Recovery is at %s.\n' "$target" "$previous" >&2
        exit 1
      fi
    fi
  fi
  unregister_app "$staged"
  /bin/rm -rf "$lock"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

verify() {
  local bundle="$1"
  [[ -d "$bundle" && ! -L "$bundle" &&
     "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" == com.konrad.agentapp ]] || return 1
  /usr/bin/codesign --verify --deep --strict --all-architectures -R '=identifier "com.konrad.agentapp"' "$bundle"
}

[[ ! -L "$target" ]] || die "The Applications path is a symbolic link."
if [[ -e "$target" ]]; then
  [[ -d "$target" &&
     "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")" == com.konrad.agentapp ]] ||
    die "The Applications path contains a different item."
fi
# Give the launch check a scratch home and separate temporary folder.
mkdir "$lock/check" "$lock/check/tmp" "$lock/incoming"
/usr/bin/ditto -x -k "$archive" "$lock/incoming"
verify "$staged" || die "The archive does not contain an intact signed SwarmHub application."
if /usr/bin/pgrep -f '^/Applications/SwarmHub[.]app/Contents/MacOS/AgentApp([[:space:]]|$)' >/dev/null; then
  die "Quit SwarmHub before installing the replacement."
fi
unregister_app "$staged"
if [[ -d "$target" ]]; then /bin/mv -h "$target" "$previous"; fi
replacement_started=1
/bin/mv -h "$staged" "$target"
verify "$target" || die "The installed application's signature could not be verified."

/usr/bin/env -i PATH=/usr/bin:/bin HOME="$lock/check" CFFIXED_USER_HOME="$lock/check" TMPDIR="$lock/check/tmp/" \
  "$target/Contents/MacOS/AgentApp" --verify-install-launch >"$lock/check/launch.log" 2>&1 &
app_pid=$!
/bin/sleep 30 &
timer_pid=$!
while kill -0 "$app_pid" 2>/dev/null && kill -0 "$timer_pid" 2>/dev/null; do /bin/sleep 0.2; done
if ! kill -0 "$timer_pid" 2>/dev/null && kill -0 "$app_pid" 2>/dev/null; then die "The launch check timed out."; fi
kill "$timer_pid" 2>/dev/null || true
timer_pid=
if ! wait "$app_pid"; then die "SwarmHub did not pass the launch check."; fi
app_pid=
verified=1
/bin/rm -rf "$previous"
register=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$register" -f "$target" >/dev/null 2>&1 || true
printf 'Installed and verified %s\n' "$target"
