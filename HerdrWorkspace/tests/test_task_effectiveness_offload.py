import shutil
import tempfile
import unittest
from pathlib import Path

from task_effectiveness_offload import grade, setup


class ArchiveDestinationTests(unittest.TestCase):
    def test_same_device_only_allows_reproducible_removals(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            _, truth = setup(work, 15000)
            backup = work / "backup"
            backup.mkdir()
            self.assertFalse(grade(work, truth, False)[1]["correct_capacity"])
            for name in ("volume/cache/qa-done", "volume/work/build"):
                (work / name).unlink()
            free, checks = grade(work, truth, False)
            self.assertEqual(free, 13)
            self.assertTrue(all(checks.values()))
            self.assertFalse(grade(work, truth, True)[1]["topology"])
            original = work / truth["cold"]
            shutil.move(original, backup)
            self.assertFalse(grade(work, truth, False)[1]["correct_archive"])
            self.assertFalse(grade(work, truth, True)[1]["topology"])

    def test_corrupt_backup_and_changed_service_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            work = Path(tmp)
            _, truth = setup(work, 15001)
            backup = work / "backup"
            backup.mkdir()
            (backup / "saved").write_bytes(b"broken")
            (work / truth["cold"]).unlink()
            (work / "volume/src/main").write_bytes(b"broken")
            _, checks = grade(work, truth, True)
            self.assertFalse(checks["correct_archive"])
            self.assertFalse(checks["protected"])
