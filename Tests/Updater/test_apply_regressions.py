"""Independent-review regressions: transaction scope, commit errors, reload recovery and atomic swaps."""

import errno
import json
import os
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


    # ---- P2a2 review: old fallback clean-up without exchange; a reported reload flag is a saved one ----------

    def test_old_fallback_after_second_rename_recovers_without_exchange(self):
        self._old_fallback(after_second_rename=True)

    def test_old_fallback_after_first_rename_recovers_without_exchange(self):
        self._old_fallback(after_second_rename=False)

    def _old_fallback(self, after_second_rename):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2")
        self.apply(v1, PROFILES[:1])
        live = self.live(CODING)
        old = stage.tree_digest(str(live))
        # What the removed three-rename fallback left behind: live renamed to spare/, the new tree in slot or live.
        txn = Path(apply._new_txn(str(self.category())))
        os.rename(str(live), str(txn / "spare" / CODING))
        target = live if after_second_rename else txn / "swap" / CODING
        stage.write_tree(str(target), stage.render_profile(v2[0], v2[1], PROFILES[0])[CODING])
        entry = {"skill": CODING, "action": "replace", "new": stage.tree_digest(str(target)), "old": old}
        (txn / apply.JOURNAL).write_text(json.dumps({"state": "open", "entries": [entry]}))
        with mock.patch.object(apply, "ATOMIC_EXCHANGE", False):
            result = self.apply(v1, PROFILES[:1])[0]
        self.assertEqual(result.status, "unchanged", result.detail)
        self.assert_live(v1)
        self.assert_no_transactions()

    def _fail_commit_journal(self, also_record=False):
        real = apply._write_json

        def write(path, value, mode):
            if value.get("state") == "committed" or (also_record and path.endswith("default.json")):
                raise OSError(errno.ENOSPC, "injected write failure")
            return real(path, value, mode)
        return mock.patch.object(apply, "_write_json", side_effect=write)

    def test_commit_journal_failure_saves_the_reload_flag_it_reports(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", plugin="p2")
        self.apply(v1, PROFILES[:1])
        apply.clear_reload_pending(str(self.state), "default")
        with self._fail_commit_journal():
            result = self.apply(v2, PROFILES[:1])[0]
        self.assertEqual(result.status, "recovery_pending")
        self.assertTrue(result.reload_pending)
        self.assertTrue(apply.read_record(str(self.state), "default")["reload_pending"])
        # The next run rolls the open journal back; the new plugin was live meanwhile, so the flag stays.
        retry = self.apply(v1, PROFILES[:1])[0]
        self.assertEqual(retry.status, "unchanged")
        self.assertTrue(retry.reload_pending)
        self.assert_live(v1)
        self.assert_no_transactions()

    def test_an_unsaved_reload_flag_is_not_reported_and_recovery_saves_it(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", plugin="p2")
        self.apply(v1, PROFILES[:1])
        apply.clear_reload_pending(str(self.state), "default")
        with self._fail_commit_journal(also_record=True):
            result = self.apply(v2, PROFILES[:1])[0]
        self.assertEqual(result.status, "recovery_pending")
        self.assertFalse(result.reload_pending)
        self.assertIn("reload_pending not saved", result.detail)
        self.assertFalse(apply.read_record(str(self.state), "default").get("reload_pending"))
        retry = self.apply(v1, PROFILES[:1])[0]  # rollback of the open journal saves the flag
        self.assertTrue(retry.reload_pending)
        self.assertTrue(apply.read_record(str(self.state), "default")["reload_pending"])
        self.assert_live(v1)


if __name__ == "__main__":
    unittest.main()
