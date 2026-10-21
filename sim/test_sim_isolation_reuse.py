"""Pid and group reuse in the signal guard (gaps found by the 2026-10-21 review of the sim harness guard).

A number this process once spawned grants nothing by itself: after the child is reaped (seen or not) the number may
name an unrelated process. Ownership comes from one live process-table snapshot, a pidfd pins the pid on Linux, and
every wait primitive (also a discarded Popen) reports the reaping. Recorders stand in for os.kill/os.killpg, so a
broken guard records instead of signalling; real processes here are only this test's own short-lived children.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import errno
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import unittest

from test_sim_isolation import RecordingGuard

HERE = Path(__file__).resolve().parent
OWN = {1: (0, 1, "boot"), 400: (1, 400, "a"), 500: (400, 400, "a")}  # This process is 500, in its parent's group 400.


def table_with(rows):
    """{pid: (ppid, pgid, start)}: this process's ancestry plus rows."""
    table = dict(OWN)
    table.update(rows)
    return table


class ReuseTests(unittest.TestCase):
    def assertRefused(self, call, *args):
        with self.assertRaises(PermissionError) as raised:
            call(*args)
        self.assertEqual(raised.exception.errno, errno.EPERM)

    def test_a_recycled_pid_and_its_descendants_are_foreign_even_if_the_reaping_was_never_seen(self):
        """700 was spawned and reaped unseen (a discarded Popen, a C-level wait); 900 now owns the number 700."""
        table = table_with({900: (1, 900, "b"), 700: (900, 700, "c"), 701: (700, 700, "c")})
        guard = RecordingGuard(table, pid=500)
        guard.record(700, leader=True)
        self.assertNotIn(700, guard.reaped)
        for pid in (700, 701):
            self.assertRefused(guard.kill, pid, signal.SIGTERM)
        self.assertRefused(guard.killpg, 700, signal.SIGKILL)
        self.assertEqual(guard.sent, [])

    def test_a_reused_group_number_is_foreign_once_our_group_dissolved(self):
        table = table_with({700: (500, 700, "a")})
        guard = RecordingGuard(table, pid=500)
        guard.record(700, leader=True)
        del table[700]
        guard.reap(700)  # No member left: the number is free.
        table.update({900: (1, 900, "b"), 702: (1, 700, "d")})  # A foreign group 700 whose own leader already exited.
        self.assertRefused(guard.killpg, 700, signal.SIGTERM)
        self.assertEqual(guard.sent, [])

    def test_a_group_outlives_its_reaped_leader_only_through_the_members_seen_at_reaping(self):
        table = table_with({700: (500, 700, "a"), 701: (700, 700, "a")})
        guard = RecordingGuard(table, pid=500)
        guard.record(700, leader=True)
        del table[700]
        table[701] = (1, 700, "a")  # The leader exited; launchd/init adopted its child, still in group 700.
        guard.reap(700)
        guard.killpg(700, signal.SIGTERM)
        table[701] = (1, 700, "later")  # Same number, a different process (another start): not a member we saw.
        self.assertRefused(guard.killpg, 700, signal.SIGKILL)
        table[701] = (1, 700, "a")
        table[700] = (900, 700, "e")  # A live leader decides alone: this one is not ours.
        table[900] = (1, 900, "b")
        self.assertRefused(guard.killpg, 700, signal.SIGKILL)
        self.assertEqual(guard.sent, [("killpg", 700, signal.SIGTERM)])

    def test_a_live_group_is_ours_through_a_live_leader_or_a_descendant_member(self):
        table = table_with({700: (500, 700, "a"), 800: (500, 800, "a"), 801: (800, 750, "a")})
        guard = RecordingGuard(table, pid=500)  # Nothing recorded: the snapshot alone proves both.
        guard.killpg(700, signal.SIGTERM)
        guard.killpg(750, signal.SIGTERM)  # Leader 750 gone, member 801 is our grandchild.
        self.assertEqual(guard.sent, [("killpg", 700, signal.SIGTERM), ("killpg", 750, signal.SIGTERM)])

    def test_an_unreadable_process_table_refuses_even_a_recorded_child(self):
        guard = RecordingGuard({}, pid=500)
        guard.record(600, leader=True)
        self.assertRefused(guard.kill, 600, signal.SIGTERM)
        self.assertRefused(guard.killpg, 600, signal.SIGTERM)

        def broken():
            raise OSError(errno.EIO, "ps failed")
        guard._table = broken
        self.assertRefused(guard.kill, 600, signal.SIGTERM)
        self.assertEqual(guard.sent, [])

    def test_a_pid_is_pinned_before_the_check_and_signalled_only_through_its_pidfd(self):
        events = []
        table = table_with({600: (500, 600, "a"), 900: (1, 900, "b")})
        guard = RecordingGuard(table, pid=500)
        real_table = guard._table
        guard._table = lambda: events.append("table") or real_table()

        def pidfd_open(pid):
            events.append(("open", pid))
            return os.open(os.devnull, os.O_RDONLY)
        guard.pin = (pidfd_open, lambda fd, sig: events.append(("pidfd_send", sig)))
        guard.kill(600, signal.SIGTERM)
        self.assertRefused(guard.kill, 900, signal.SIGTERM)
        self.assertEqual(events, [("open", 600), "table", ("pidfd_send", signal.SIGTERM), ("open", 900), "table"])
        self.assertEqual(guard.sent, [])  # Never os.kill by number while a pidfd is available.

    def test_a_pid_that_cannot_be_pinned_is_gone(self):
        guard = RecordingGuard(table_with({600: (500, 600, "a")}), pid=500)

        def pidfd_open(pid):
            raise ProcessLookupError(errno.ESRCH, "No such process")
        guard.pin = (pidfd_open, lambda fd, sig: self.fail("signalled"))
        with self.assertRaises(ProcessLookupError):
            guard.kill(600, signal.SIGTERM)
        self.assertEqual(guard.sent, [])


TRACKING = r'''
import sys
sys.path.insert(0, sys.argv[1])
import sim_isolation
import gc, json, os, subprocess, time
guard, seen = sim_isolation.GUARD, {}
spawn = lambda: os.posix_spawn("/bin/sh", ["/bin/sh", "-c", "exit 0"], dict(os.environ))
pid = spawn(); os.waitpid(pid, 0); seen["waitpid"] = pid in guard.reaped
pid = spawn(); seen["wait"] = os.wait()[0] == pid and pid in guard.reaped
pid = spawn(); seen["wait3"] = os.wait3(0)[0] == pid and pid in guard.reaped
pid = spawn(); seen["wait4"] = os.wait4(pid, 0)[0] == pid and pid in guard.reaped
if hasattr(os, "waitid") and hasattr(os, "P_PID"):
    pid = spawn(); os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT); seen["waitid-nowait"] = pid not in guard.reaped
    os.waitid(os.P_PID, pid, os.WEXITED); seen["waitid"] = pid in guard.reaped
child = subprocess.Popen(["/bin/sh", "-c", "sleep 0.2"])
pid = child.pid
del child  # Discarded while running: subprocess._cleanup() reaps it later, with no reference left to it.
gc.collect()
time.sleep(0.6)
subprocess.run(["/bin/sh", "-c", "exit 0"])  # Every new Popen runs _cleanup() first.
seen["discarded-popen"] = pid in guard.reaped
print(json.dumps(seen))
'''


class CompletionTrackingTests(unittest.TestCase):
    def test_every_wait_primitive_and_a_discarded_popen_report_the_reaping(self):
        """In a separate guarded interpreter: os.wait()/wait3() reap any child, never one of this runner's."""
        out = subprocess.run([sys.executable, "-I", "-B", "-W", "ignore", "-c", TRACKING, str(HERE)],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(out.returncode, 0, out.stderr)
        seen = json.loads(out.stdout)
        self.assertTrue(seen and all(seen.values()), seen)
        self.assertTrue({"waitpid", "wait", "wait3", "wait4", "discarded-popen"} <= set(seen), seen)


if __name__ == "__main__":
    unittest.main()
