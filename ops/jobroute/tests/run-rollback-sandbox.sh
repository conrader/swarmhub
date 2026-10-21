#!/bin/bash
# Run as ubuntu, passing an exact generated installer. All execution tests run as sbtest
# under unshare -r -p -f --mount-proc. Only marked scratch HOMEs receive an install.
set -euo pipefail
inst=$(realpath "$1")
here=$(cd "$(dirname "$0")" && pwd)
want=$(sha256sum "$inst" | cut -d' ' -f1)
ak_before=$(sha256sum /home/ubuntu/.ssh/authorized_keys | cut -d' ' -f1)
kh_before=$(sha256sum /home/ubuntu/.ssh/known_hosts | cut -d' ' -f1)
stage=$(sudo -u sbtest -- mktemp -d /tmp/jobroute-fix2-rbtest.XXXXXX)
echo "stage: $stage; installer: $inst; sha256: $want"
mirror=$(mktemp -d)
GIT_SSH_COMMAND='ssh -o StrictHostKeyChecking=yes -o UpdateHostKeys=no' \
  git clone -q --mirror git@github.com:conrader/swarmhub.git "$mirror/swarmhub.git"
echo "GitHub branch head: $(git -C "$mirror/swarmhub.git" rev-parse feat/hermes-jobroute)"
tar -C "$mirror" -cf - swarmhub.git | sudo -u sbtest -- tar -C "$stage" -xf -
rm -rf "$mirror"
sudo -u sbtest -- tee "$stage/installer.sh" < "$inst" >/dev/null
sudo -u sbtest -- tee "$stage/rollback_sandbox.py" < "$here/rollback_sandbox.py" >/dev/null
rc=0
sudo -u sbtest -- unshare -r -p -f --mount-proc \
  env -i PATH=/usr/bin:/bin python3 -B "$stage/rollback_sandbox.py" "$stage" "$want" || rc=1
for path in /home/ubuntu/.local/lib/jobroute /home/ubuntu/.config/jobroute /home/ubuntu/.local/state/jobroute; do
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then echo "PASS  real $path absent";
  else echo "FAIL  real $path exists"; rc=1; fi
done
if [ "$ak_before" = "$(sha256sum /home/ubuntu/.ssh/authorized_keys | cut -d' ' -f1)" ]; then
  echo 'PASS  real authorized_keys unchanged'; else echo 'FAIL  real authorized_keys changed'; rc=1; fi
if [ "$kh_before" = "$(sha256sum /home/ubuntu/.ssh/known_hosts | cut -d' ' -f1)" ]; then
  echo 'PASS  real known_hosts unchanged'; else echo 'FAIL  real known_hosts changed'; rc=1; fi
sudo -u sbtest -- rm -rf "$stage"
echo "TOTAL failures: $rc"
exit "$rc"
