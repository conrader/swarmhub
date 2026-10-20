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


if __name__ == "__main__":
    unittest.main()
