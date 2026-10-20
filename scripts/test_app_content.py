"""Linux mirror of P2c app launch resolution, using the existing TEST baseline/vector verification harness.

Swift behavior is covered by AppContentTests on the Mac. These tests also pin both app startup call sites so merely
adding an unused reader cannot satisfy first launch. No network or Swift toolchain is required here.
"""

import hashlib
import io
import json
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/release"))
import baseline  # noqa: E402
import check_baseline  # noqa: E402


def resolve(app, target, fetched_store=lambda: None):
    """Mirror the app's bundle-only, data-only fallback contract; verify with the Python vector harness."""
    try:
        fetched = fetched_store()
        if fetched is not None:
            return fetched
    except OSError:
        pass
    resources = app / "Contents/Resources"
    folder = resources / "Baseline"
    if app.suffix != ".app" or not folder.is_dir() or not folder.resolve().is_relative_to(resources.resolve()):
        return None
    problems = check_baseline.Problems()
    body = check_baseline.verify_baseline(folder, problems, [], ios=target == "ios")
    if problems or body is None:
        return None
    data = {}
    for item in body["components"]:
        if target not in item["targets"]:
            continue
        if item["class"] != "data" or item["kind"] not in ("config", "ui"):
            return None
        path = folder / "blobs/sha256" / item["sha256"]
        if not path.resolve().is_relative_to(folder.resolve()):
            return None
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != item["sha256"] or len(raw) != item["size"]:
            return None
        data[item["name"]] = raw
    return body["version"], data


class AppContentTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="p2c-app-content-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def app(self, target):
        app = self.tmp / (target + ".app")
        resources = app / "Contents/Resources"
        self.assertEqual(baseline.embed(resources, "debug", ios=target == "ios"), [])
        return app

    def test_first_launch_consumes_baseline_data_for_both_apps(self):
        for target in ("mac", "ios"):
            with self.subTest(target=target):
                version, archives = resolve(self.app(target), target)
                self.assertEqual(version, 1)
                self.assertEqual(set(archives), {"policy", "manager-prompts"} if target == "mac" else {"policy"})
                with tarfile.open(fileobj=io.BytesIO(archives["policy"])) as archive:
                    policy = json.load(archive.extractfile("policy.json"))
                self.assertEqual(policy["schema"], "swarmhub/policy-defaults/1")
                self.assertEqual(policy["codingOrder"], "claude,codex,hermes")

    def test_unreachable_host_changes_nothing(self):
        calls = []

        def unreachable():
            calls.append(True)
            raise ConnectionRefusedError("synthetic update host unreachable; no socket opened")

        for target in ("mac", "ios"):
            app = self.app(target)
            self.assertEqual(resolve(app, target, unreachable), resolve(app, target))
        self.assertEqual(len(calls), 2)

    def test_tampered_baseline_is_not_consumed(self):
        for target in ("mac", "ios"):
            app = self.app(target)
            blobs = app / "Contents/Resources/Baseline/blobs/sha256"
            components = json.loads((app / "Contents/Resources/Baseline/bundles/1.json").read_text())["signed"]["components"]
            policy = next(item for item in components if item["name"] == "policy")
            (blobs / policy["sha256"]).write_bytes(b"tampered")
            self.assertIsNone(resolve(app, target))

    def test_absent_bundle_never_uses_adjacent_or_linked_baseline(self):
        other = self.app("mac")
        empty = self.tmp / "empty.app"
        resources = empty / "Contents/Resources"
        resources.mkdir(parents=True)
        source = other / "Contents/Resources/Baseline"
        shutil.copytree(source, self.tmp / "Resources/Baseline")
        shutil.copytree(source, self.tmp / "AgentApp.resources/Baseline")
        self.assertIsNone(resolve(empty, "mac"))
        (resources / "Baseline").symlink_to(source, target_is_directory=True)
        self.assertIsNone(resolve(empty, "mac"))

    def test_app_stores_resolve_content_at_initialization(self):
        for path, target in (("Sources/AgentApp/Stores/AppStore.swift", "mac"),
                             ("Apps/iOS/Sources/MobileStore.swift", "ios")):
            self.assertIn(f"let appContent = AppContent.resolve(target: .{target})", (ROOT / path).read_text())
        view = (ROOT / "Sources/AgentApp/Updates/BootstrapExportView.swift").read_text()
        self.assertIn("store.appContent.baseline", view)
        export = (ROOT / "Sources/AgentApp/Updates/BootstrapExport.swift").read_text()
        self.assertNotIn("BotManagerText", export)
        self.assertNotIn("candidates", export)
        self.assertIn("Self.digest(of: bytes) == digest", export)


if __name__ == "__main__":
    unittest.main()
