"""Launcher negative tests: never build or launch the GUI; no network or credentials."""
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]


class UIAcceptanceLauncherTests(unittest.TestCase):
    def launch(self, extra):
        environment = {"PATH": "/usr/bin:/bin", "TMPDIR": "/tmp", **extra}
        return subprocess.run(["/bin/bash", str(ROOT / "scripts/run-ui-acceptance.sh")],
                              env=environment, capture_output=True, text=True, timeout=5)

    def test_requires_explicit_exact_opt_in(self):
        for extra in [{}, {"SWARMHUB_UI_ACCEPTANCE": "0"}, {"SWARMHUB_UI_ACCEPTANCE": "true"}]:
            with self.subTest(extra=extra):
                result = self.launch(extra)
                self.assertEqual(result.returncode, 78)
                self.assertIn("explicitly set", result.stderr)

    def test_conflicting_configuration_refuses_without_echoing_values(self):
        for key in ["HERMES_URL", "SWARMHUB_QA_HERMES_URL", "COMPOSIO_API_KEY", "OPENCLAW_URL",
                    "SWARMHUB_KEYCHAIN_SERVICE", "SWARMHUB_QA_MODE", "SWARMHUB_UI_ACCEPTANCE_STORE_PATH"]:
            with self.subTest(key=key):
                result = self.launch({"SWARMHUB_UI_ACCEPTANCE": "1", key: "private-dummy-value"})
                self.assertEqual(result.returncode, 78)
                self.assertIn("launch refused", result.stderr)
                self.assertNotIn("private-dummy-value", result.stdout + result.stderr)

    @unittest.skipUnless(os.uname().sysname != "Darwin", "Mac positive launch is manual")
    def test_non_mac_does_not_launch_remotely(self):
        result = self.launch({"SWARMHUB_UI_ACCEPTANCE": "1"})
        self.assertEqual(result.returncode, 2)
        self.assertIn("local Mac", result.stderr)
