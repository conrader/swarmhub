"""P2c: a fresh box takes the app-embedded baseline with no network, using only the embedded bootstrap package.

The operator flow of CORE-PLAN.md §3.5, minus the admin-owned install (P2d): check the package's SHA-256 with an OS
tool against the value the app build recorded, extract it with `tar`, then run its own launcher on the embedded
`Baseline/` (the service layout) as a staged folder. Where unprivileged user namespaces exist, the updater runs inside
an empty network namespace (`unshare -rn`), so no host is reachable at all. Hermes files stay byte-identical.
TEST keys only (the debug baseline).
"""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_fixtures import HERMES, PROFILES, ROOT, BoxCase, box_snapshot, changed  # noqa: E402

BASELINE_PY = ROOT / "scripts/release/baseline.py"
PROFILES_DOC = {"schema": "swarmhub/profiles/1", "profiles": [
    {"name": p.name, "coding_order": p.coding_order, "skills": None if p.skills is None else list(p.skills)}
    for p in PROFILES]}
ALLOWED = (".hermes/skills/swarmhub", ".hermes/profiles/coder_2/skills", ".local/state/swarmhub-update")


def _no_network_prefix():
    try:
        ok = subprocess.run(["unshare", "-rn", "true"], capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        ok = False
    return ["unshare", "-rn"] if ok else []


NO_NETWORK = _no_network_prefix()


class BaselineOfflineTest(BoxCase):
    def setUp(self):
        super().setUp()
        self.resources = self.tmp / "AgentApp.resources"
        # A subprocess, so the release tooling never enters this process (test_verify.py proves the updater
        # does not use the reference implementation).
        subprocess.run([sys.executable, "-B", str(BASELINE_PY), "embed", "--configuration", "debug", "--out",
                        str(self.resources)], check=True, capture_output=True, timeout=120)
        self.package = next((self.resources / "Bootstrap").glob("*.tar"))
        self.prefix = self.tmp / "opt" / "swarmhub-updater"

    def install(self):
        """Check the digest with the OS tool, then extract (the operator's steps). Returns the launcher."""
        tool = ["sha256sum", "-c"] if shutil.which("sha256sum") else ["shasum", "-a", "256", "-c"]
        subprocess.run(tool + [self.package.name + ".sha256"], cwd=str(self.package.parent), check=True,
                       capture_output=True, timeout=30)
        self.prefix.parent.mkdir(parents=True)
        subprocess.run(["tar", "-xf", str(self.package), "-C", str(self.prefix.parent)], check=True, timeout=30)
        return self.prefix / "bin/swarmhub-update"

    def staged(self):
        folder = self.tmp / "staged"
        shutil.copytree(str(self.resources / "Baseline"), str(folder))
        (folder / "profiles.json").write_text(json.dumps(PROFILES_DOC))
        return folder

    def run_updater(self, launcher, *argv):
        env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": str(self.home), "LANG": "C.UTF-8"}
        result = subprocess.run(NO_NETWORK + [str(launcher), "--state-dir", str(self.state), "--hermes-home",
                                              str(self.hermes), "--max-wait", "0"] + list(argv),
                                env=env, capture_output=True, text=True, timeout=120)
        return result.returncode, json.loads(result.stdout or "{}"), result.stderr

    def test_fresh_box_applies_the_embedded_baseline_offline(self):
        before = box_snapshot(str(self.home))
        hermes_bytes = HERMES.read_bytes()
        launcher = self.install()
        manifest = json.loads(next((self.resources / "Baseline/bundles").glob("*.json")).read_text())["signed"]
        code = sorted(c["name"] for c in manifest["components"] if c["class"] == "code" and "box" in c["targets"])
        box = sorted(c["name"] for c in manifest["components"] if "box" in c["targets"])

        rc, out, err = self.run_updater(launcher, "apply", "--staged", str(self.staged()))
        self.assertEqual(rc, 0, (out, err))
        self.assertEqual(out["state"], "pending_confirm" if code else "current", out)
        self.assertEqual(sorted(c["name"] for c in out["pending_confirm"]["code"]) if code else [], code)
        rc, out, err = self.run_updater(launcher, "apply", "--version", str(manifest["version"]))
        self.assertEqual((rc, out["state"]), (0, "current"), (out, err))
        self.assertEqual(out["applied_bundle_version"], manifest["version"])
        self.assertEqual(sorted(out["components"]), box)
        versions = {c["name"]: c["version"] for c in manifest["components"]}
        for skill in [c["name"] for c in manifest["components"] if c["kind"] == "skill"]:
            text = (self.live(skill) / "SKILL.md").read_text()
            self.assertIn("SwarmHub, v%s" % versions[skill], text)

        outside = [p for p in changed(before, box_snapshot(str(self.home)))
                   if not p.startswith(ALLOWED) and p not in (".local", ".local/state")]
        self.assertEqual(outside, [])
        self.assertEqual((self.hermes / "hermes-agent/gateway/platforms/api_server.py").read_bytes(), hermes_bytes)
        self.assertEqual(list(self.prefix.rglob("__pycache__")), [])

    def test_the_package_pins_are_the_baseline_pins(self):
        self.install()
        self.assertEqual((self.prefix / "pins.json").read_bytes(), (self.resources / "Baseline/pins.json").read_bytes())
        recorded = (self.package.parent / (self.package.name + ".sha256")).read_text().split()[0]
        self.assertEqual(recorded, hashlib.sha256(self.package.read_bytes()).hexdigest())

    def test_an_altered_package_fails_the_hash_check_before_extraction(self):
        data = bytearray(self.package.read_bytes())
        data[600] ^= 1
        self.package.write_bytes(bytes(data))
        with self.assertRaises(subprocess.CalledProcessError):
            self.install()
        self.assertFalse(self.prefix.exists())

    @unittest.skipUnless(NO_NETWORK, "unprivileged user namespaces are not available")
    def test_the_namespace_really_has_no_network(self):
        probe = ("import socket\ntry:\n    socket.create_connection(('1.1.1.1', 443), timeout=3)\n    print('reached')\n"
                 "except OSError:\n    print('unreachable')\n")
        result = subprocess.run(NO_NETWORK + [sys.executable, "-I", "-c", probe], capture_output=True, text=True,
                                timeout=30)
        self.assertEqual(result.stdout.strip(), "unreachable")


if __name__ == "__main__":
    unittest.main()
