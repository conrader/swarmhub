"""Defence in depth for the remaining signal helpers: swarm_lifecycle's group stops and code-job-test.sh's pid kills.

A bad group (<= 1, negative, non-int or this process's own) is never passed to killpg/pidfd_send_signal; recorders
stand in for both, so a broken guard records instead of signalling. Real signals go only to a private group this
test spawned. code-job's kill_tree, swarm_store.terminate and the verifiers are covered by test_killtree_guard.py.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Resources/Skills/swarmhub-messages/scripts"))

import swarm_lifecycle  # noqa: E402

BAD_GROUPS = (0, 1, -1, -4242, None, "4242", True, 4242.0)


class FakeChild:
    def __init__(self, pid):
        self.pid, self.calls, self.returncode = pid, [], None

    def poll(self):
        return self.returncode

    def terminate(self):
        self.calls.append("terminate")
        self.returncode = -signal.SIGTERM

    def kill(self):
        self.calls.append("kill")

    def wait(self, timeout=None):
        self.calls.append("wait")
        return self.returncode


class LifecycleGroupGuardTests(unittest.TestCase):
    def setUp(self):
        self.sent = []
        record = lambda *args: self.sent.append(args)  # noqa: E731
        for target, name in ((os, "killpg"), (os, "kill"), (signal, "pidfd_send_signal")):
            patcher = mock.patch.object(target, name, record, create=True)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(os, "getpgrp", lambda: 4243)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_private_group_refuses_broadcast_garbage_and_this_process_group(self):
        for pgid in BAD_GROUPS + (4243,):
            self.assertFalse(swarm_lifecycle.private_group(pgid), pgid)
        self.assertTrue(swarm_lifecycle.private_group(4244))

    def test_stop_child_never_signals_a_non_private_group(self):
        for pid in (1, 0, 4243):
            child = FakeChild(pid)
            swarm_lifecycle.stop_child(child, grace=.05)
            self.assertEqual(child.calls[0], "terminate", pid)
        self.assertEqual(self.sent, [])

    def test_stop_legacy_group_refuses_bad_and_own_groups(self):
        for pid in BAD_GROUPS + (4243,):
            if isinstance(pid, int) and not isinstance(pid, bool):
                swarm_lifecycle.stop_legacy_group(-1, pid)
        self.assertEqual(self.sent, [])

    def test_the_termination_forwarder_skips_children_that_are_not_private_groups(self):
        swarm_lifecycle._children.update({"a": FakeChild(1), "b": FakeChild(4243)})
        self.addCleanup(swarm_lifecycle._children.clear)
        with swarm_lifecycle.termination():
            try:
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
            except swarm_lifecycle.Stopping:
                pass
        self.assertEqual(self.sent, [])


class LifecycleRealGroupTests(unittest.TestCase):
    def test_stop_child_still_stops_a_real_private_group(self):
        child = subprocess.Popen(["sh", "-c", "sleep 30 & echo $!; wait"], stdout=subprocess.PIPE, text=True,
                                 start_new_session=True)
        grandchild = int(child.stdout.readline())
        child.stdout.close()
        swarm_lifecycle.stop_child(child, grace=2)
        self.assertIsNotNone(child.returncode)
        for _ in range(100):  # Gone or a zombie (pid 1 of the namespace may be this runner, which reaps late).
            state = subprocess.run(["ps", "-o", "stat=", "-p", str(grandchild)], capture_output=True, text=True).stdout
            if not state.strip() or state.strip().startswith("Z"):
                break
            subprocess.run(["sleep", "0.05"])
        self.assertTrue(not state.strip() or state.strip().startswith("Z"), state)


class CodeJobTestPidGuardTests(unittest.TestCase):
    def own_pid(self, value):
        script = (ROOT / "Tests/Scripts/code-job-test.sh").read_text()
        function = re.search(r"^own_pid\(\) \{.*\}$", script, re.M).group(0)
        return subprocess.run(["sh", "-c", function + '\nown_pid "$1"', "sh", value]).returncode == 0

    def test_only_plain_pids_above_one_other_than_the_shell_are_signalled(self):
        for value in ("", "0", "1", "-1", "abc", "12 13", "12\n13", "007", " 5", "5;6"):
            self.assertFalse(self.own_pid(value), repr(value))
        self.assertTrue(self.own_pid("4242"))

    def test_every_kill_in_code_job_test_names_a_checked_or_spawned_pid(self):
        script = (ROOT / "Tests/Scripts/code-job-test.sh").read_text()
        for line in script.splitlines():
            for match in re.finditer(r"(?<![\w-])kill +(?:-[A-Z]+ +)?(\"?\$\w+\"?|\$\(.*?\))", line):
                target = match.group(1)
                if "kill -0" in match.group(0) or line.lstrip().startswith("kill()"):
                    continue
                self.assertTrue("own_pid" in line or target.strip('"') in ("$P", "$runner"), line)


if __name__ == "__main__":
    unittest.main()
