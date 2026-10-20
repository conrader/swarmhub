"""P2a engine internals (Resources/Updater/swarmhub_update/{apply,stage,idle}.py): rollback when a swap fails part
way, recovery of a run that died mid-swap or mid-rotation, the rename fallback, atomic exchange, `previous` and
revert, the run lock, idle edge cases and the stdlib-only import rule. Acceptance tests are in test_apply.py.

    PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s Tests/Updater
"""

import ast
import os
from pathlib import Path
import sys
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from apply_fixtures import CODING, MESSAGES, PROFILES, ROOT, BoxCase, apply, box_snapshot, idle, stage  # noqa: E402


class Crash(BaseException):
    """Stands in for the process dying (not caught by the engine)."""


def failing_after(count, error):
    real = apply._swap_entry
    calls = []

    def swap_entry(category, txn, entry):
        if len(calls) >= count:
            raise error
        calls.append(entry["skill"])
        return real(category, txn, entry)
    return swap_entry


class Rollback(BoxCase):
    def setUp(self):
        super().setUp()
        self.v1, self.v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2", plugin="p2")
        self.apply(self.v1)
        apply.clear_reload_pending(str(self.state), "default")
        self.before = box_snapshot(self.category())

    def test_swap_error_part_way_restores_current_and_previous(self):
        with mock.patch.object(apply, "_swap_entry", failing_after(2, OSError(5, "disk gone"))):
            result = self.apply(self.v2, PROFILES[:1])[0]
        self.assertEqual(result.status, "failed")
        self.assertIn("current restored", result.detail)
        self.assertEqual(box_snapshot(self.category()), self.before)
        self.assertFalse(result.reload_pending)
        self.assert_no_transactions()

    def test_live_tree_changed_right_after_the_swap_is_rolled_back(self):
        real = apply._swap_entry

        def swap_entry(category, txn, entry):
            real(category, txn, entry)
            if entry["skill"] == CODING:  # something writes into the new live tree before the check
                (Path(category) / CODING / "scripts/extra.txt").write_text("x")
        with mock.patch.object(apply, "_swap_entry", swap_entry):
            result = self.apply(self.v2, PROFILES[:1])[0]
        self.assertEqual(result.status, "failed")
        self.assertIn("differs from the staged tree", result.detail)
        self.assertEqual(box_snapshot(self.category()), self.before)
        self.assert_no_transactions()

    def test_crash_mid_swap_is_rolled_back_by_the_next_run(self):
        with mock.patch.object(apply, "_swap_entry", failing_after(2, Crash())):
            with self.assertRaises(Crash):
                self.apply(self.v2, PROFILES[:1])
        self.assertNotEqual(box_snapshot(self.category()), self.before)  # half swapped, journal left
        self.assertEqual(apply.recover(str(self.category())), 1)
        self.assertEqual(box_snapshot(self.category()), self.before)

    def test_crash_mid_fallback_rename_is_rolled_back(self):
        real_rename, calls = os.rename, []

        def rename(a, b):
            calls.append(a)
            if len(calls) == 2:  # live moved to spare, staged not yet in place: the skill is briefly absent
                raise Crash()
            return real_rename(a, b)
        with mock.patch.object(apply, "ATOMIC_EXCHANGE", False), mock.patch.object(os, "rename", rename):
            with self.assertRaises(Crash):
                self.apply(self.v2, PROFILES[:1])
        self.assertFalse(self.live(CODING).exists())
        apply.recover(str(self.category()))
        self.assertEqual(box_snapshot(self.category()), self.before)

    def test_crash_after_commit_finishes_rotation(self):
        with mock.patch.object(apply, "_rotate", side_effect=Crash()):
            with self.assertRaises(Crash):
                self.apply(self.v2, PROFILES[:1])
        self.assert_live(self.v2)
        results = self.apply(self.v2, PROFILES[:1])  # recovery runs first, then nothing is left to do
        self.assertEqual(results[0].status, "unchanged")
        self.assertEqual(stage.snapshot(str(self.previous(CODING))), self.expected(self.v1, CODING))
        self.assert_no_transactions()


    def test_live_change_during_the_wait_defers(self):
        real = apply.idle.wait_for_idle

        def wait(*args, **kwargs):
            (self.live(CODING) / "scripts/late.txt").write_text("written while waiting")
            return real(*args, **kwargs)
        with mock.patch.object(apply.idle, "wait_for_idle", wait):
            result = self.apply(self.v2, PROFILES[:1])[0]
        self.assertEqual(result.status, "deferred")
        self.assertIn("changed while waiting", result.detail)
        self.assertEqual((self.live(CODING) / "scripts/late.txt").read_text(), "written while waiting")
        self.assert_no_transactions()

    def test_an_internal_error_fails_one_profile_and_the_others_still_apply(self):
        txn = Path(stage.work_dir(str(self.category()))) / "txn-1-1"
        txn.mkdir()
        (txn / "journal.json").write_text("{not json")
        results = self.apply(self.v2)
        self.assertEqual([r.status for r in results], ["failed", "applied"])
        self.assertIn("internal error", results[0].detail)
        self.assertEqual(box_snapshot(self.category()).keys() - {os.path.relpath(txn, self.category())}
                         - {os.path.relpath(txn / "journal.json", self.category())}, self.before.keys())
        self.assert_live(self.v2, PROFILES[1])


class Swap(BoxCase):
    def test_exchange_is_atomic_where_supported(self):
        a, b = self.tmp / "a", self.tmp / "b"
        a.mkdir()
        b.mkdir()
        (a / "f").write_text("a")
        (b / "f").write_text("b")
        if not apply.exchange(str(a), str(b)):
            self.skipTest("no atomic exchange on this OS or file system")
        self.assertEqual(((a / "f").read_text(), (b / "f").read_text()), ("b", "a"))
        if sys.platform.startswith("linux") or sys.platform == "darwin":
            self.assertTrue(apply.exchange(str(a), str(b)))

    def test_rename_fallback_applies_and_keeps_previous(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2")
        self.apply(v1)
        with mock.patch.object(apply, "ATOMIC_EXCHANGE", False):
            self.assertEqual({r.status for r in self.apply(v2)}, {"applied"})
        self.assert_live(v2)
        self.assertEqual(stage.snapshot(str(self.previous(CODING))), self.expected(v1, CODING))

    def test_unchanged_bundle_touches_nothing(self):
        v1 = self.source("v1")
        self.apply(v1)
        before = box_snapshot(self.category())
        self.assertEqual({r.status for r in self.apply(v1)}, {"unchanged"})
        self.assertEqual(box_snapshot(self.category()), before)

    def test_only_changed_skills_swap(self):
        v1 = self.source("v1")
        self.apply(v1)
        inode = os.stat(self.live("swarmhub-feedback")).st_ino
        self.apply(self.source("v2", note="v1", answer=42, files={CODING + "/scripts/new.txt": "n\n"}))
        self.assertEqual(os.stat(self.live("swarmhub-feedback")).st_ino, inode)
        self.assertTrue((self.live(CODING) / "scripts/new.txt").exists())

    def test_live_symlink_is_refused(self):
        os.makedirs(self.category())
        os.symlink(str(self.tmp), str(self.live(CODING)))
        result = self.apply(self.source("v1"), PROFILES[:1])[0]
        self.assertEqual(result.status, "failed")
        self.assertIn("link", result.detail)
        self.assertTrue(os.path.islink(self.live(CODING)))

    def test_missing_and_invalid_profiles_fail_without_writing(self):
        before = box_snapshot(self.home)
        results = self.apply(self.source("v1"), [stage.Profile("nobody", "codex", None),
                                                 stage.Profile("../x", "codex", None)])
        self.assertEqual([r.status for r in results], ["failed", "failed"])
        self.assertFalse((self.hermes / "profiles/nobody").exists())
        changes = [p for p in set(box_snapshot(self.home)) - set(before) if not p.startswith(".local")]
        self.assertEqual(changes, [])


class Revert(BoxCase):
    def test_revert_restores_previous_and_a_second_revert_redoes(self):
        v1, v2 = self.source("v1"), self.source("v2", version="1.1.0", note="v2", plugin="p2")
        self.apply(v1)
        self.apply(v2)
        apply.clear_reload_pending(str(self.state), "default")
        result = apply.revert(str(self.hermes), str(self.state), "default", max_wait=0)
        self.assertEqual(result.status, "reverted")
        self.assertEqual(result.versions[CODING], "1.0.0")
        self.assertTrue(result.reload_pending)  # the plugin code changed back
        self.assert_live(v1)
        self.assertEqual(stage.snapshot(str(self.previous(CODING))), self.expected(v2, CODING))
        self.assertEqual(apply.revert(str(self.hermes), str(self.state), "default", max_wait=0).status, "reverted")
        self.assert_live(v2)

    def test_revert_of_a_first_install_removes_it(self):
        self.apply(self.source("v1"))
        self.assertEqual(apply.revert(str(self.hermes), str(self.state), "coder_2", max_wait=0).status, "reverted")
        self.assertFalse(self.live(CODING, "coder_2").exists())
        self.assertEqual(apply.read_record(str(self.state), "coder_2")["skills"], {})

    def test_revert_waits_for_idle_and_needs_a_previous(self):
        self.assertEqual(apply.revert(str(self.hermes), str(self.state), "default", max_wait=0).status, "failed")
        self.apply(self.source("v1"))
        self.apply(self.source("v2", version="1.1.0", note="v2"))
        job = self.start_sleeper()
        self.swarm_job(job.pid)
        result = apply.revert(str(self.hermes), str(self.state), "default", max_wait=0)
        self.assertEqual(result.status, "deferred")
        self.assertEqual(apply.read_record(str(self.state), "default")["skills"][CODING], "1.1.0")

    def test_revert_checks_the_previous_copy(self):
        self.apply(self.source("v1"))
        self.apply(self.source("v2", version="1.1.0", note="v2"))
        (self.previous(CODING) / "scripts/tool.py").write_text("def broken(:\n")
        before = box_snapshot(self.category())
        result = apply.revert(str(self.hermes), str(self.state), "default", max_wait=0)
        self.assertEqual(result.status, "failed")
        self.assertEqual(box_snapshot(self.category()), before)


class Lock(BoxCase):
    def test_a_second_run_defers_while_one_holds_the_lock(self):
        with apply.locked(str(self.state)):
            results = self.apply(self.source("v1"))
            self.assertEqual({r.status for r in results}, {"deferred"})
            self.assertEqual(apply.revert(str(self.hermes), str(self.state), "default").status, "deferred")
        self.assertFalse(self.category().exists())


class Idle(BoxCase):
    def test_slot_states(self):
        self.assertEqual(idle.busy(str(self.hermes)), [])
        job = self.start_sleeper()
        dead = self.start_sleeper()
        dead.kill()
        dead.wait()
        self.code_job_slot(dead.pid, 1)
        self.assertEqual(idle.busy(str(self.hermes)), [])
        starting = self.code_job_slot(None, 2)
        self.assertEqual(idle.busy(str(self.hermes)), ["code-job starting (slot 2)"])
        old = time.time() - idle.STARTING_GRACE - 5
        os.utime(starting, (old, old))
        self.assertEqual(idle.busy(str(self.hermes)), [])
        (self.hermes / "swarmhub/slots/reclaim").mkdir()
        self.code_job_slot(job.pid, 3)
        self.assertEqual(idle.busy(str(self.hermes)), ["code-job pid %d (slot 3)" % job.pid])

    def test_swarm_job_states(self):
        job = self.start_sleeper()
        self.swarm_job(None, "running", "launching")
        self.swarm_job(job.pid, "cancelled", "cancelled-alive")
        self.swarm_job(job.pid, "queued", "queued")
        self.swarm_job(job.pid, "done", "done")
        self.assertEqual(sorted(idle.busy(str(self.hermes))),
                         ["swarm job cancelled-alive pid %d (cancelled)" % job.pid, "swarm job launching launching"])

    def test_impossible_pids_are_not_jobs(self):
        self.code_job_slot(10 ** 25)
        self.swarm_job(2 ** 40)
        self.assertEqual(idle.busy(str(self.hermes)), [])

    def test_unreadable_database_counts_as_busy(self):
        (self.hermes / "swarmhub/control.sqlite").write_bytes(b"not a database" * 100)
        self.assertEqual(idle.busy(str(self.hermes)), ["swarm job database unreadable"])

    def test_wait_is_bounded(self):
        clock = iter([0, 0, 1, 2, 3, 4, 5, 6]).__next__
        sleeps = []
        with mock.patch.object(idle, "busy", return_value=["x"]):
            ready, jobs, waited = idle.wait_for_idle("unused", 3, 1, clock=clock, sleep=sleeps.append)
        self.assertEqual((ready, jobs, waited), (False, ["x"], 3))
        self.assertEqual(sleeps, [1, 1, 1])


class Imports(unittest.TestCase):
    def test_new_modules_import_only_the_standard_library(self):
        allowed = set(getattr(sys, "stdlib_module_names", ())) or {
            "collections", "contextlib", "ctypes", "errno", "fcntl", "hashlib", "json", "os", "re", "shutil",
            "sqlite3", "stat", "subprocess", "sys", "time"}
        for name in ("apply", "stage", "idle"):
            tree = ast.parse((ROOT / "Resources/Updater/swarmhub_update" / (name + ".py")).read_text())
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    modules = [a.name.split(".")[0] for a in node.names]
                elif isinstance(node, ast.ImportFrom) and node.level == 0:
                    modules = [node.module.split(".")[0]]
                else:
                    continue
                self.assertTrue(set(modules) <= allowed, (name, modules))

    def test_source_files_stay_within_500_lines(self):
        for path in [ROOT / "Resources/Updater/swarmhub_update" / n for n in ("apply.py", "stage.py", "idle.py")] + \
                list((ROOT / "Tests/Updater").glob("*apply*.py")):
            self.assertLessEqual(len(path.read_text().splitlines()), 500, path)


if __name__ == "__main__":
    unittest.main()
