"""Independent-review regressions: transaction scope, commit errors, reload recovery and atomic swaps."""

import errno
from pathlib import Path
import sys
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_fixtures import CODING, MESSAGES, PROFILES, BoxCase, apply, stage  # noqa: E402


class Crash(BaseException):
    """Process death, outside the engine's exception handlers."""


class ReviewRegressions(BoxCase):
    def test_partial_update_revert_preserves_unchanged_skills(self):
        v1 = self.source("v1")
        self.apply(v1, PROFILES[:1])
        # Keep every version and template identical; only A's files change.
        v2 = self.source("v2", files={CODING + "/scripts/new.txt": "new\n"})
        self.apply(v2, PROFILES[:1])
        result = apply.revert(str(self.hermes), str(self.state), "default", max_wait=0)
        self.assertEqual(result.status, "reverted")
        self.assert_live(v1)
        self.assertEqual(result.versions[MESSAGES], "1.0.0")
        self.assertEqual(apply.revert(str(self.hermes), str(self.state), "default", max_wait=0).status,
                         "reverted")
        self.assert_live(v2)

    def test_partial_update_revert_ignores_older_backup_folders(self):
        v1 = self.source("v1")
        self.apply(v1, PROFILES[:1])
        v2 = self.source("v2", version="1.1.0", note="v2")
        self.apply(v2, PROFILES[:1])
        v3 = self.source("v3", version="1.1.0", note="v2", files={CODING + "/scripts/new.txt": "new\n"})
        self.apply(v3, PROFILES[:1])
        self.assertEqual(apply.revert(str(self.hermes), str(self.state), "default", max_wait=0).status,
                         "reverted")
        self.assert_live(v2)

    def test_commit_write_failure_keeps_a_truthful_recoverable_result(self):
        self._commit_failure(after_replace=False)

    def test_commit_directory_fsync_failure_keeps_a_truthful_recoverable_result(self):
        self._commit_failure(after_replace=True)

    def _commit_failure(self, after_replace):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", plugin="p2")
        self.apply(v1, PROFILES[:1])
        apply.clear_reload_pending(str(self.state), "default")
        real = apply._write_json

        def write(path, value, mode):
            if value.get("state") == "committed":
                if after_replace:
                    real(path, value, mode)
                raise OSError(errno.ENOSPC, "injected journal failure")
            return real(path, value, mode)

        with mock.patch.object(apply, "_write_json", side_effect=write):
            result = self.apply(v2, PROFILES[:1])[0]
        self.assertEqual(result.status, "recovery_pending")
        self.assertIn("next run", result.detail)
        self.assert_live(v2)
        self.assertTrue(list(Path(stage.work_dir(str(self.category()))).glob("txn-*")))
        # Retrying really recovers (open journal rolls back; committed journal finishes).
        retry = self.apply(v2, PROFILES[:1])[0]
        self.assertIn(retry.status, ("applied", "unchanged"))
        self.assertTrue(retry.reload_pending)
        self.assert_live(v2)
        self.assert_no_transactions()

    def test_committed_plugin_crash_retry_retains_reload_pending(self):
        self._committed_crash("_rotate", plugin="p2")

    def test_committed_state_write_crash_retry_retains_reload_pending(self):
        self._committed_crash("_record", plugin="p2")

    def test_rotation_error_and_failed_recovery_keep_the_committed_journal(self):
        self._post_commit_error("_rotate")

    def test_state_error_and_failed_recovery_keep_the_committed_journal(self):
        self._post_commit_error("_record")

    def _post_commit_error(self, point):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", plugin="p2")
        self.apply(v1, PROFILES[:1])
        apply.clear_reload_pending(str(self.state), "default")
        with mock.patch.object(apply, point, side_effect=OSError(errno.ENOSPC, "injected commit error")):
            for _ in range(2):
                result = self.apply(v2, PROFILES[:1])[0]
                self.assertEqual(result.status, "recovery_pending")
                self.assertTrue(result.reload_pending)
                self.assert_live(v2)
                self.assertTrue(list(Path(stage.work_dir(str(self.category()))).glob("txn-*")))
        retry = self.apply(v2, PROFILES[:1])[0]
        self.assertEqual(retry.status, "unchanged")
        self.assertTrue(retry.reload_pending)
        self.assert_no_transactions()

    def test_incomplete_rollback_and_recovery_never_report_plain_failure(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0")
        self.apply(v1, PROFILES[:1])
        real = apply._swap_entry
        calls = []

        def swap(*args):
            if calls:
                raise OSError(errno.EIO, "injected swap error")
            calls.append(True)
            return real(*args)

        with mock.patch.object(apply, "_undo_entry", side_effect=OSError(errno.EIO, "injected undo error")):
            with mock.patch.object(apply, "_swap_entry", side_effect=swap):
                result = self.apply(v2, PROFILES[:1])[0]
            self.assertEqual(result.status, "recovery_pending")
            self.assertEqual(self.apply(v2, PROFILES[:1])[0].status, "recovery_pending")
        self.assertEqual(self.apply(v2, PROFILES[:1])[0].status, "applied")
        self.assert_live(v2)
        self.assert_no_transactions()

    def _committed_crash(self, point, **kwargs):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", **kwargs)
        self.apply(v1, PROFILES[:1])
        apply.clear_reload_pending(str(self.state), "default")
        with mock.patch.object(apply, point, side_effect=Crash()):
            with self.assertRaises(Crash):
                self.apply(v2, PROFILES[:1])
        self.assert_live(v2)
        retry = self.apply(v2, PROFILES[:1])[0]
        self.assertEqual(retry.status, "unchanged")
        self.assertTrue(retry.reload_pending)
        self.assertTrue(apply.read_record(str(self.state), "default")["reload_pending"])
        self.assert_no_transactions()

    def test_unsupported_atomic_exchange_never_renames_live_away(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2")
        self.apply(v1, PROFILES[:1])
        with mock.patch.object(apply, "exchange", return_value=False), \
                mock.patch.object(apply.os, "rename", wraps=apply.os.rename) as rename:
            result = self.apply(v2, PROFILES[:1])[0]
        self.assertEqual(rename.call_count, 0)
        self.assertEqual(result.status, "failed")
        self.assertIn("atomic", result.detail)
        self.assert_live(v1)
        self.assert_no_transactions()


if __name__ == "__main__":
    unittest.main()
