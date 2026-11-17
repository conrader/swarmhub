#!/bin/sh
# Builds the workspace server (HerdrWorkspace, `swarmhub-herdr`) for this machine and puts it in dist/workspace under
# the name a release gives it, with the fragment the release's manifest is made from:
#
#   dist/workspace/swarmhub-herdr-<version>-<arch>-<os>
#   dist/workspace/swarmhub-herdr-<version>-<arch>-<os>.asset.json
#
# Run it on each kind of machine a release should serve (a Linux server for x86_64-linux), then bring dist/workspace
# to the Mac that signs the release (scripts/release.sh). Nothing is signed or uploaded here.
# SWARMHUB_CARGO_FLAGS adds cargo flags, e.g. "--offline" on a build machine without network.
set -eu
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
for check_only in SWARMHUB_BRIDGE_VERSION SWARMHUB_UPDATE_PUBLIC_KEY SWARMHUB_BRIDGE_TEST_FAULT; do
  if [ -n "$(printenv "$check_only" || true)" ]; then
    echo "ERROR: $check_only is set. It makes a check build that trusts another key or names another version; unset it for a release." >&2
    exit 1
  fi
done
if [ -n "$(git -C "$ROOT_DIR" status --porcelain -- HerdrWorkspace)" ] && [ "${SWARMHUB_ALLOW_DIRTY:-}" != 1 ]; then
  echo "ERROR: HerdrWorkspace has uncommitted changes. Commit them, or set SWARMHUB_ALLOW_DIRTY=1 for a build you will not publish." >&2
  exit 1
fi
cd "$ROOT_DIR/HerdrWorkspace"
# shellcheck disable=SC2086
cargo build --release --locked ${SWARMHUB_CARGO_FLAGS:-}
BUILT="$ROOT_DIR/HerdrWorkspace/target/release/swarmhub-herdr"
NAME="$("$BUILT" version --json | python3 -c 'import json,sys; said=json.load(sys.stdin); print("swarmhub-herdr-%s-%s" % (said["version"], said["target"]))')"
mkdir -p "$ROOT_DIR/dist/workspace"
cp "$BUILT" "$ROOT_DIR/dist/workspace/$NAME"
chmod 755 "$ROOT_DIR/dist/workspace/$NAME"
python3 "$ROOT_DIR/scripts/workspace-manifest.py" asset "$ROOT_DIR/dist/workspace/$NAME"
echo "$ROOT_DIR/dist/workspace/$NAME"
