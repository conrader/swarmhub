#!/bin/bash
# Run the whole jobroute test suite on ovh inside the sbtest sandbox. Run as ubuntu:
#   ops/jobroute/tests/run-sandbox.sh
# Stages a copy that sbtest can read (the route, plus a copy of ~/sb's sb-codejob for the
# one integration test), then runs pytest and the ssh harness, each as
#   sudo -u sbtest -- unshare -r -p -f --mount-proc ...
# Nothing outside the stage directory is touched; no live key, sshd, unit or job is used.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
sb=${SB_ROOT:-/home/ubuntu/sb}
stage=$(sudo -u sbtest -- mktemp -d /tmp/jobroute-test.XXXXXX)
sudo -u sbtest -- mkdir "$stage/jobroute" "$stage/sb"
tar -C "$here" --exclude=__pycache__ -cf - . | sudo -u sbtest -- tar -C "$stage/jobroute" -xf -
tar -C "$sb" -cf - bin/sb-codejob bin/sb-codejob-watch lib/sbscan/job_process.py lib/sbscan/secretscan.py \
  | sudo -u sbtest -- tar -C "$stage/sb" -xf -
# pytest may live in ubuntu's user site, which sbtest cannot read: stage the packages too.
pylib=$(python3 -c 'import os, pytest; print(os.path.dirname(os.path.dirname(pytest.__file__)))')
sudo -u sbtest -- mkdir "$stage/pylib"
tar -C "$pylib" -cf - pytest _pytest pluggy iniconfig py.py 2>/dev/null | sudo -u sbtest -- tar -C "$stage/pylib" -xf - || true
echo "stage: $stage"
rc=0
sudo -u sbtest -- unshare -r -p -f --mount-proc \
  env -i -C "$stage" PATH=/usr/bin:/bin HOME="$stage" JOBROUTE_SB_COPY="$stage/sb" PYTHONPATH="$stage/pylib" \
  python3 -B -m pytest -q -p no:cacheprovider --basetemp="$stage/pytest" "$stage/jobroute/tests" "$@" || rc=1
sudo -u sbtest -- unshare -r -p -f --mount-proc \
  env -i -C "$stage" PATH=/usr/bin:/bin HOME="$stage" \
  bash "$stage/jobroute/tests/sandbox_ssh.sh" "$stage" || rc=1
echo "sandbox suite exit: $rc (stage left for inspection: $stage)"
exit $rc
