"""Kill-tree guards: an empty, garbage, broadcast or foreign root signals nothing.

2026-10-21: every uid-1000 process on the ovh host got SIGTERM, then SIGKILL about a second later. code-job's
kill_tree() walked `ps -A` from its root, and a root of 0 or 1 is the parent of every process on the host. These
tests never send a real signal: code-job's functions run with `kill`, `sleep` and `ps` replaced by shell functions
that record or print, and the Python helpers run with os.kill/os.killpg patched. Each shell case first proves the
`kill` it would call is the recorder, so a broken override fails the test instead of signalling.
"""
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Resources/Skills"
CODE_JOB = SCRIPTS / "swarmhub-coding/scripts/code-job"
sys.path.insert(0, str(SCRIPTS / "swarmhub-messages/scripts"))
sys.path.insert(0, str(SCRIPTS / "swarmhub-coding/scripts"))

import swarm_store  # noqa: E402
import verify_darwin  # noqa: E402

BAD_ROOTS = ("", "0", "1", "-1", "abc", "12 13", "1;2", " ", "007x", "99999999999999999999999")


def functions(*names):
    text = CODE_JOB.read_text()
    out = []
    for name in names:
        found = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.M | re.S)
        assert found, name
        out.append(found.group(0))
    return "".join(out)


# A synthetic host: init and kthreadd, this shell's parent and grandparent (ancestors), this shell, a child with a
# grandchild (the job's own tree), and a foreign process. $$ and $PPID are the real ones of the `sh` running this.
HARNESS = r'''
set -u
: > "$LOG"
kill() { printf 'kill %s\n' "$*" >> "$LOG"; }
sleep() { :; }
ps() { printf '%s\n' "1 0" "2 0" "900 1" "$PPID 900" "$$ $PPID" "5001 $$" "5002 5001" "5003 5002" "6001 1" "6002 6001" "33 2"; }
case $(command -V kill) in *function*) ;; *) echo "kill is not the recorder" >&2; exit 99 ;; esac
'''


def run_shell(body):
    with tempfile.TemporaryDirectory() as d:
        logfile = Path(d) / "kills"
        script = HARNESS + functions("tree", "tree_pids", "signalable", "kill_tree") + body
        proc = subprocess.run(["sh", "-c", script, "sh"], env=dict(os.environ, LOG=str(logfile)),
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        assert proc.returncode != 99, proc.stderr
        return proc, logfile.read_text() if logfile.exists() else ""


class CodeJobKillTreeTests(unittest.TestCase):
    def test_bad_roots_signal_nothing_and_say_so(self):
        for root in BAD_ROOTS:
            with self.subTest(root=root):
                proc, kills = run_shell('kill_tree %s; echo done=$?' % shlex.quote(root))
                self.assertEqual(kills, "", proc.stderr)
                self.assertIn("done=0", proc.stdout)
                if root.strip():
                    self.assertIn("code-job: not signalling", proc.stderr)

    def test_this_shell_its_ancestors_and_foreign_processes_are_refused(self):
        for root in ('"$$"', '"$PPID"', "900", "6001", "6002", "33", "2", "5002", "424242"):
            with self.subTest(root=root):
                proc, kills = run_shell("kill_tree %s; echo done=$?" % root)
                self.assertEqual(kills, "", proc.stderr)
                self.assertIn("done=0", proc.stdout)
                self.assertIn("code-job: not signalling", proc.stderr)

    def test_tree_lists_nothing_for_bad_roots_and_never_an_ancestor(self):
        for root in [shlex.quote(r) for r in BAD_ROOTS] + ['"$$"', '"$PPID"', "900", "6001", "5002"]:
            with self.subTest(root=root):
                proc, _ = run_shell("tree %s" % root)
                self.assertEqual(set(proc.stdout.split()) - {"end"}, set(), proc.stdout)

    def test_own_child_tree_is_signalled_term_then_kill_and_nothing_else(self):
        proc, kills = run_shell('kill_tree 5001; echo done=$?')
        self.assertIn("done=0", proc.stdout)
        lines = kills.splitlines()
        self.assertEqual(lines[0].split(), ["kill", "-TERM", "5001", "5002", "5003"], kills)
        self.assertEqual(lines[1].split()[:2], ["kill", "-KILL"], kills)
        self.assertEqual(set(lines[1].split()[2:]), {"5001", "5002", "5003"}, kills)
        self.assertEqual(len(lines), 2, kills)

    def test_signalable_accepts_only_plain_pids_above_one_other_than_this_shell(self):
        proc, kills = run_shell(
            'for p in "" 0 1 -1 abc "1 2" "$$" 5001 6001; do signalable "$p" && echo "yes:$p" || echo "no:$p"; done')
        self.assertEqual(kills, "")
        got = proc.stdout.split()
        self.assertEqual([g for g in got if g.startswith("yes:")], ["yes:5001", "yes:6001"], got)

    def test_code_job_never_falls_back_to_the_bare_root(self):
        """The old kill_tree killed `${READ_OUTPUT:-$1}`: an empty listing still signalled the root itself."""
        self.assertNotIn("${READ_OUTPUT:-$1}", CODE_JOB.read_text())


class SwarmStoreTerminateTests(unittest.TestCase):
    LISTING = "1 0\n2 0\n900 1\n%d 900\n%d %d\n5001 %d\n5002 5001\n6001 1\n6002 6001\n" % (
        os.getppid(), os.getpid(), os.getppid(), os.getpid())

    def run_terminate(self, pid):
        with mock.patch.object(swarm_store.subprocess, "check_output", return_value=self.LISTING), \
             mock.patch.object(swarm_store.os, "kill") as kill, \
             mock.patch.object(swarm_store.time, "sleep"), \
             mock.patch.object(swarm_store, "process_alive", return_value=True):
            swarm_store.terminate(pid)
        return kill.call_args_list

    def test_bad_roots_signal_nothing(self):
        for pid in (None, "", "abc", 0, 1, -1, -5001, "0", "1", "5001", 5001.0, True, os.getpid(), os.getppid(), 900):
            with self.subTest(pid=pid):
                self.assertEqual(self.run_terminate(pid), [])

    def test_a_recorded_tree_is_signalled_without_this_process_or_its_ancestors(self):
        for pid, tree in ((5001, {5001, 5002}), (6001, {6001, 6002})):
            with self.subTest(pid=pid):
                calls = self.run_terminate(pid)
                self.assertEqual({c.args[0] for c in calls}, tree)
                self.assertEqual({c.args[1] for c in calls}, {signal.SIGTERM, signal.SIGKILL})


class VerifierGuardTests(unittest.TestCase):
    def test_darwin_signal_group_refuses_broadcast_groups(self):
        for pgid in (0, 1, -1, os.getpgrp()):
            with self.subTest(pgid=pgid):
                killpg = mock.Mock()
                self.assertFalse(verify_darwin.signal_group(pgid, signal.SIGKILL, killpg))
                killpg.assert_not_called()

    @unittest.skipUnless(sys.platform == "linux", "the seccomp supervisor exists only on Linux")
    def test_linux_supervisor_refuses_a_root_of_one_or_less(self):
        import verify_signals
        for root in (0, 1, -1, os.getpid()):
            with self.subTest(root=root), self.assertRaises(ValueError):
                verify_signals.Supervisor(None, root, {})


class TestsNeverBroadcast(unittest.TestCase):
    def test_no_sim_test_sends_a_real_signal_to_minus_one(self):
        """fixes7 asked the sandbox to deny a SIGTERM to pid -1; had it not, every process of the user died."""
        pattern = re.compile(r"os\.kill\(\s*-1\s*,(?!\s*0\s*\))")
        offenders = [p.name for p in (ROOT / "sim").glob("*.py") if pattern.search(p.read_text())]
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
