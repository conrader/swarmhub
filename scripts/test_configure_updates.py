import base64
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/configure-updates.py"
spec = importlib.util.spec_from_file_location("configure_updates", SCRIPT)
updates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(updates)
KEY = base64.b64encode(bytes(range(32))).decode()


class ConfigureUpdatesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.plist = Path(self.directory.name) / "Info.plist"
        self.plist.write_bytes((ROOT / "Resources/Info.plist").read_bytes())

    def test_release_requires_key_and_failure_keeps_plist_unchanged(self):
        info = plistlib.loads(self.plist.read_bytes())
        info["SUPublicEDKey"] = ""
        self.plist.write_bytes(plistlib.dumps(info))
        original = self.plist.read_bytes()
        with self.assertRaisesRegex(ValueError, "setup-updates"):
            updates.configure(self.plist, {})
        self.assertEqual(self.plist.read_bytes(), original)

    def test_release_overrides_preserve_bundle_identity_and_defaults(self):
        info = updates.configure(self.plist, {"SWARMHUB_UPDATE_PUBLIC_KEY": KEY,
            "SWARMHUB_UPDATE_FEED_URL": "https://updates.example.com/appcast.xml"})
        self.assertEqual(plistlib.loads(self.plist.read_bytes()), info)
        self.assertEqual(info["CFBundleIdentifier"], "com.konrad.agentapp")
        self.assertEqual(info["SUPublicEDKey"], KEY)
        self.assertEqual(info["SUFeedURL"], "https://updates.example.com/appcast.xml")
        self.assertIs(info["SUEnableAutomaticChecks"], True)
        self.assertIs(info["SUAutomaticallyUpdate"], False)
        self.assertIs(info["SUVerifyUpdateBeforeExtraction"], True)

    def test_rejects_invalid_keys_even_for_development_override(self):
        for key in ["garbage", base64.b64encode(b"short").decode(), base64.b64encode(bytes(64)).decode()]:
            with self.subTest(key=key), self.assertRaises(ValueError):
                updates.configure(self.plist, {"SWARMHUB_UPDATE_PUBLIC_KEY": key}, require_key=False)

    def test_rejects_unsafe_feed_urls(self):
        for feed in ["http://example.com/feed", "file:///tmp/feed", "https:///feed", "https://user:pass@example.com/feed", "https://example.com/feed#fragment"]:
            with self.subTest(feed=feed), self.assertRaises(ValueError):
                updates.configure(self.plist, {"SWARMHUB_UPDATE_PUBLIC_KEY": KEY, "SWARMHUB_UPDATE_FEED_URL": feed})

    def test_cli_applies_public_key_without_private_key_material(self):
        result = subprocess.run(["python3", str(SCRIPT), str(self.plist)], capture_output=True, text=True,
            env={**os.environ, "SWARMHUB_UPDATE_PUBLIC_KEY": KEY})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(self.plist.read_bytes())["SUPublicEDKey"], KEY)

    def test_rejects_non_numeric_build_or_disabled_signature_validation(self):
        info = updates.configure(self.plist, {"SWARMHUB_UPDATE_PUBLIC_KEY": KEY})
        for build in ["", "v1", "1-beta", "1.2.3.4"]:
            with self.subTest(build=build), self.assertRaisesRegex(ValueError, "CFBundleVersion"):
                updates.validate({**info, "CFBundleVersion": build})
        with self.assertRaisesRegex(ValueError, "SUVerifyUpdateBeforeExtraction"):
            updates.validate({**info, "SUVerifyUpdateBeforeExtraction": False})


if __name__ == "__main__":
    unittest.main()
