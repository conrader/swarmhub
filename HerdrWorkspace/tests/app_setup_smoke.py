"""Set up "This Mac" through the Mac app's own code, for real: the app's release check, its way of putting the
service in place and running it, its reading of the server, its Software Update, and its remove. macOS only.

    python3 tests/app_setup_smoke.py "$(command -v hc)" [BUILDS]

It serves a local releases folder signed with a throwaway key, gives the app's code a scratch home folder, stand-in
agent programs and a launchd job name of its own, and runs three checks of `Tests/AgentAppTests/HerdrLiveTests.swift`
with `swift test`: setup from the signed release (and refusal of a release signed with another key), an update
through Software Update's own client and state, and remove. No model calls; nothing of the account's own setup is
read or changed. BUILDS keeps the check builds between runs (`update_smoke.py` makes the same ones).
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from update_smoke import Releases, build, free_port, public  # noqa: E402

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

LABEL = "com.swarmhub.app-setup-smoke"
REPOSITORY = Path(__file__).resolve().parents[2]


def main(hc, builds):
    assert sys.platform == "darwin", "This Mac is a Mac"
    key = build(builds, Ed25519PrivateKey.generate())
    with tempfile.TemporaryDirectory(prefix="shapp-", dir="/tmp") as temp:
        root = Path(temp).resolve()
        for name in ("home", "tools"):
            (root / name).mkdir(mode=0o700)
        for name in ("claude", "codex"):
            (root / "tools" / name).write_text("#!/bin/sh\nexec /bin/sleep 600\n")
            (root / "tools" / name).chmod(0o755)
        (root / "tools/hc").symlink_to(hc)
        releases = Releases(root / "releases", builds, key)
        releases.publish("0.2.0")
        env = {**os.environ, "SWARMHUB_LOCAL_LIVE_HOME": str(root / "home"), "SWARMHUB_LOCAL_LIVE_FEED": releases.address,
               "SWARMHUB_LOCAL_LIVE_KEY": public(key), "SWARMHUB_LOCAL_LIVE_PORT": str(free_port()),
               "SWARMHUB_LOCAL_LIVE_LABEL": LABEL, "SWARMHUB_LOCAL_LIVE_PATH": f"{root / 'tools'}:/usr/bin:/bin",
               "SWARMHUB_LOCAL_LIVE_SESSION": "shapp"}
        env = {name: value for name, value in env.items() if not name.lower().endswith("_proxy")}
        tests = {"setup": "thisMacIsSetUpFromASignedReleaseAndNothingElse", "update": "softwareUpdateUpdatesThisMacLikeAnyServer",
                 "remove": "removingTheServiceLeavesConversationsAndNothingRunning"}

        def step(name):
            ran = subprocess.run(["swift", "test", "--filter", tests[name]], cwd=REPOSITORY, env={**env, "SWARMHUB_LOCAL_LIVE_STEP": name},
                                 capture_output=True, text=True, timeout=900)
            passed = ran.returncode == 0 and f"Test {tests[name]}() passed" in ran.stdout
            assert passed, f"{name}:\n{ran.stdout[-3000:]}\n{ran.stderr[-1500:]}"
            print(f"{name}: ok", flush=True)

        job = root / "home/Library/LaunchAgents" / f"{LABEL}.plist"
        core_env = {"HOME": str(root / "home"), "PATH": "/usr/bin:/bin", "HC_SESSION": "shapp"}
        try:
            step("setup")
            assert job.exists() and (root / "home/.local/bin/swarmhub-herdr").exists()
            releases.publish("0.2.1")
            step("update")
            step("remove")
            assert not job.exists() and not (root / "home/.local/bin/swarmhub-herdr").exists()
            assert (root / "home/.local/state/swarmhub-herdr/workspace.sqlite3").exists(), "conversations stay"
            print("app setup smoke: ok")
        finally:
            subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], capture_output=True)
            subprocess.run([str(root / "tools/hc"), "server", "stop"], env=core_env, capture_output=True, timeout=60)


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    keep = Path(sys.argv[2]) if len(sys.argv) == 3 else None
    with tempfile.TemporaryDirectory(prefix="swarmhub-update-builds-") as scratch:
        main(sys.argv[1], keep or Path(scratch))
