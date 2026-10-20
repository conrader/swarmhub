"""P8a acceptance: both channel drills pass end to end against a local static host with TEST keys
(scripts/release/drill.py), and the drill runner reports a failed check as a failure.

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts -p "test_release_drills.py"
"""

import os
from pathlib import Path
import sys
import unittest
from unittest import mock

os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parent / "release"))

import drill  # noqa: E402
import drill_world  # noqa: E402
import republish  # noqa: E402


class DrillTests(unittest.TestCase):
    def run_drill(self, name):
        lines = []
        result = drill.run([name], log=lines.append)
        return result[name], lines

    def test_rollforward_drill_passes(self):
        error, lines = self.run_drill("rollforward")
        self.assertIsNone(error, "\n".join(lines))
        self.assertTrue(any("republished bundle 1 as 3" in line for line in lines))
        self.assertTrue(any("Hermes files byte-identical" in line for line in lines))

    def test_rotation_drill_passes(self):
        error, lines = self.run_drill("rotate")
        self.assertIsNone(error, "\n".join(lines))
        self.assertTrue(any("refused index/unknown_key" in line for line in lines))
        self.assertTrue(any("refused keys/keys_rollback" in line for line in lines))

    def test_a_roll_forward_that_rebuilds_fails_the_drill(self):
        real = republish.republish

        def rebuilt(repo, old, new, **kwargs):  # a republish that does not carry the old blobs over
            raise republish.publish.PublishError("rebuilt instead of republished")

        with mock.patch.object(republish, "republish", rebuilt):
            error, _ = self.run_drill("rollforward")
        self.assertIn("rebuilt instead of republished", error or "")
        self.assertIs(republish.republish, real)


class AppPinRecoveryTests(unittest.TestCase):
    def app_after_failed_apply(self):
        app = drill_world.App("failed-apply", b"", "canary", "test-install")
        # Apply 12 wrote its floor but failed before switching the installed bundles.
        app.floors.update(keys_version=2, index_seq=6, bundle_version=12)
        app.current = {"bundle_version": 11, "blobs": {"policy": b"eleven"}}
        app.previous = {"bundle_version": 10, "blobs": {"policy": b"ten"}}
        return app

    def offline(self):
        fetcher = mock.Mock()
        fetcher.get.side_effect = drill_world.fetch.FetchError("unreachable", "http://127.0.0.1:1/keys.json")
        return mock.patch.object(drill_world, "loopback_fetcher", return_value=fetcher)

    def test_failed_apply_pin_clears_offline_and_keeps_ten_recoverable(self):
        for interruption in ("none", "beforePinSwap", "beforeClearCheck", "afterRestoreSwitch"):
            with self.subTest(interruption=interruption), self.offline():
                app = self.app_after_failed_apply()
                app.pin_previous()
                self.assertEqual(app.pin, {"mode": "previous", "at": drill_world.NOW, "bundle_version": 11})
                self.assertEqual(app.current["bundle_version"], 10)
                if interruption == "beforePinSwap":
                    app.current, app.previous = app.previous, app.current
                elif interruption in ("beforeClearCheck", "afterRestoreSwitch"):
                    app.restore_bundle, app.pin = app.pin["bundle_version"], None
                    if interruption == "afterRestoreSwitch":
                        app.current, app.previous = app.previous, app.current
                self.assertEqual(app.clear_pin("http://127.0.0.1:1/")["stage"], "fetch")
                self.assertEqual(app.current["bundle_version"], 11)
                self.assertEqual(app.previous, {"bundle_version": 10, "blobs": {"policy": b"ten"}})
                self.assertIsNone(app.pin)
                self.assertIsNone(app.restore_bundle)
                self.assertEqual(app.floors, {"keys_version": 2, "index_seq": 6, "bundle_version": 12})
                app.check("http://127.0.0.1:1/")
                self.assertEqual(app.current["bundle_version"], 11)

    def test_missing_restore_keeps_the_marker_for_a_later_check(self):
        app = self.app_after_failed_apply()
        app.pin_previous()
        saved, app.previous = app.previous, None
        with self.offline():
            app.clear_pin("http://127.0.0.1:1/")
            self.assertEqual(app.current["bundle_version"], 10)
            self.assertEqual(app.restore_bundle, 11)
            app.previous = saved
            app.check("http://127.0.0.1:1/")
        self.assertEqual(app.current["bundle_version"], 11)
        self.assertEqual(app.previous["bundle_version"], 10)
        self.assertIsNone(app.restore_bundle)


if __name__ == "__main__":
    unittest.main()
