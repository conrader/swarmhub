#!/bin/bash
set -euo pipefail
# In a logged-in mini-m4 desktop session, from the candidate checkout.
root=$(git rev-parse --show-toplevel)
base=${1:-7306c60c2c700d498fb978feb0dc0315f56cdbb1}
if [[ $(uname -s) != Darwin ]]; then
    echo "This comparison requires macOS and a visible desktop." >&2
    exit 1
fi
sparkle=${SPARKLE_XCFRAMEWORK:-"$root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework"}
if [[ ! -d "$sparkle" ]]; then sparkle="$root/.build/sparkle-2.10.0/Sparkle.xcframework"; fi
if [[ ! -d "$sparkle" ]]; then
    echo "Set SPARKLE_XCFRAMEWORK to the local Sparkle 2.10.0 xcframework from the app build." >&2
    exit 1
fi
mkdir -p "$root/out"
run=$(mktemp -d "$root/out/responsiveness.XXXXXX")
echo "Comparison and raw samples in $run"
mkdir "$run/baseline" "$run/candidate" "$run/tmp"
export TMPDIR="$run/tmp/"
git -C "$root" archive "$base" | tar -x -C "$run/baseline"
# Include unstaged Swift files in the candidate. Build products and user data stay out.
git -C "$root" archive HEAD | tar -x -C "$run/candidate"
rsync -a --delete "$root/Sources/" "$run/candidate/Sources/"
rsync -a --delete "$root/Tests/" "$run/candidate/Tests/"
fixture=Tests/AgentAppTests/ResponsivenessSmokeTests.swift
cp "$root/$fixture" "$run/baseline/$fixture"
{
    sw_vers
    xcrun swift --version
    sysctl -n machdep.cpu.brand_string
    git -C "$root" rev-parse "$base" HEAD
    git -C "$root" status --short
} > "$run/environment.txt"
for version in baseline candidate; do
    tree="$run/$version"
    # Use the already cached binary in both disposable manifests. No package download or updater.
    ditto "$sparkle" "$tree/Vendor/Sparkle.xcframework"
    python3 - "$tree/Package.swift" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
for old, new in [
    ('.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")', ''),
    ('targets: [\n        // Vendored', 'targets: [\n        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle.xcframework"),\n        // Vendored'),
    ('.product(name: "Sparkle", package: "Sparkle")', '"Sparkle"'),
]:
    if s.count(old) != 1:
        sys.exit("Unexpected manifest. Check the pinned Sparkle dependency.")
    s = s.replace(old, new)
p.write_text(s)
PY
    (cd "$tree" && xcrun swift build -c release --build-tests)
done

(cd "$run/candidate" && xcrun swift test -c release --skip-build \
    --filter 'TurnTextBufferTests|ConcurrentTurnsTests|mountedChatUpdatesAnEmptyReplyAsChunksArrive|aSteerDeliveredMidReply|aGroupSteerIsQueued|streamEventsDriveActivity')

measure() {
    local version=$1 count=$2 rep=$3
    local report="$run/$version-$count-$rep.json"
    (cd "$run/$version" && SWARM_RESPONSIVENESS_BOTS="$count" SWARM_RESPONSIVENESS_REPORT="$report" \
        xcrun swift test -c release --skip-build --filter syntheticWindowResponsiveness)
    test -s "$report"
}
# Reverse the ordering on the second pass to expose warm-up and machine-load effects.
for count in 1 4; do
    measure baseline "$count" 1
    measure candidate "$count" 1
done
for count in 4 1; do
    measure candidate "$count" 2
    measure baseline "$count" 2
done
python3 - "$run" <<'PY'
from pathlib import Path
import json
import sys
print("run                     click p95/max ms    frame gap p95/max ms   gaps >50ms / total")
for path in sorted(Path(sys.argv[1]).glob("*.json")):
    r = json.loads(path.read_text())
    c, g = r["click_to_visible_chat"], r["window_frame_gaps"]
    print(f"{path.stem:23s} {c['p95_ms']:7.1f}/{c['worst_ms']:<7.1f}     "
          f"{g['p95_ms']:7.1f}/{g['worst_ms']:<7.1f}     {g['over_50_ms']}/{g['count']}")
PY
