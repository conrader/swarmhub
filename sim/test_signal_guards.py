"""Defence in depth for the remaining signal helpers: swarm_lifecycle's group stops and the shell suites' pid kills.

A bad group (<= 1, negative, non-int or this process's own) is never passed to killpg/pidfd_send_signal; recorders
stand in for both, so a broken guard records instead of signalling. Real signals go only to a private group this
test spawned. code-job's kill_tree, swarm_store.terminate and the verifiers are covered by test_killtree_guard.py.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
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


class OwnPidTests(unittest.TestCase):
    """Tests/Scripts/own-pid.sh, sourced by code-job-test.sh and bot-msg-test.sh: a pid is signalled only when it is a
    live descendant of the shell (and, given one, runs the expected command). `kill` is a recorder here."""
    HELPER = ROOT / "Tests/Scripts/own-pid.sh"

    def run_sh(self, body, *args):
        script = '. "$0"\nkill() { echo "kill $*"; }\n' + body
        return subprocess.run(["sh", "-c", script, str(self.HELPER)] + list(args), capture_output=True, text=True,
                              timeout=30)

    def own_pid(self, value, command=""):
        return self.run_sh('own_pid "$1" "$2" && kill -TERM "$1"', value, command).stdout == "kill -TERM %s\n" % value

    def foreign(self):
        """A live process that is not the shell's descendant: this runner's own sleeper, the shell's sibling."""
        child = subprocess.Popen(["sleep", "30"])
        self.addCleanup(lambda: child.poll() is None and (child.kill(), child.wait()))
        return child.pid

    def test_garbage_broadcast_and_the_shell_itself_are_refused(self):
        for value in ("", "0", "1", "-1", "abc", "12 13", "12\n13", "007", " 5", "5;6"):
            self.assertFalse(self.own_pid(value), repr(value))
        self.assertEqual(self.run_sh('own_pid $$ && kill $$').stdout, "")

    def test_a_live_process_that_is_not_a_descendant_is_refused(self):
        for pid in (self.foreign(), os.getpid()):  # A sibling, and the shell's own parent.
            self.assertFalse(self.own_pid(str(pid)), pid)

    def test_children_and_grandchildren_are_ours_and_the_command_must_match_when_given(self):
        out = self.run_sh("""
sleep 30 & child=$!
( sleep 31 & echo $! > "$1"; wait ) & sub=$!
i=0; while [ ! -s "$1" ] && [ $i -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
grand=$(cat "$1")
own_pid "$child" && echo child-ok
own_pid "$grand" && echo grand-ok
own_pid "$child" sleep && echo command-ok
own_pid "$child" code-job || echo command-mismatch-refused
command kill "$child" "$grand"; wait
own_pid "$child" || echo reaped-refused
""", str(Path(self.tmp()) / "grand"))
        self.assertEqual(out.stdout.split(), ["child-ok", "grand-ok", "command-ok", "command-mismatch-refused",
                                              "reaped-refused"], out.stderr)

    def tmp(self):
        path = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, path, True)
        return path

    def test_every_kill_in_the_shell_suites_names_a_checked_or_spawned_pid(self):
        for name in ("code-job-test.sh", "bot-msg-test.sh"):
            script = (ROOT / "Tests/Scripts" / name).read_text()
            self.assertIn('. "$(dirname "$0")/own-pid.sh"', script, name)
            self.assertNotRegex(script, r"(?m)^own_pid\(\)", name)  # One definition, in own-pid.sh.
            for line in script.splitlines():
                for match in re.finditer(r"(?<![\w-])kill +(?:-[A-Z]+ +)?(\"?\$\w+\"?|\$\(.*?\))", line):
                    if "kill -0" in match.group(0) or line.lstrip().startswith("kill()"):
                        continue
                    self.assertTrue("own_pid" in line or match.group(1).strip('"') == "$runner", line)
        code_job = (ROOT / "Tests/Scripts/code-job-test.sh").read_text()
        self.assertIn('own_pid "$pid" "$JOB" && kill -TERM "$pid"', code_job)  # A pid read from disk: code-job's.
        self.assertIn("own_pid \"$GW\" bot-msg-stub-gateway && kill", (ROOT / "Tests/Scripts/bot-msg-test.sh").read_text())

    def test_the_smoke_cap_signals_its_group_only_while_the_leader_is_unreaped(self):
        script = (ROOT / "sim/mac-codex-tmp-smoke.sh").read_text()
        cap = script[script.index("cap() {"):]
        self.assertLess(cap.index("if p.returncode is not None"), cap.index("os.killpg(p.pid"))


class VerificationSleeperTests(unittest.TestCase):
    """Run the real case-22 harness with recorded process listings and a kill recorder, never real signals."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="verification-sleeper-")
        self.addCleanup(shutil.rmtree, self.tmp)
        self.case = Path(self.tmp) / "case"
        (self.case / "work").mkdir(parents=True)
        completion = self.case / "home/.hermes/swarmhub/job-completions/job.fixture"
        completion.mkdir(parents=True)
        (completion / "pid").write_text("424242\n")
        script = (ROOT / "Tests/Scripts/code-job-test.sh").read_text()
        self.body = script[script.index("case_22() {"):script.index("\n# 23\n")]

    def run_case(self, listings):
        for index, listing in enumerate(listings, 1):
            (self.case / ("ps-%d" % index)).write_text(listing)
        (self.case / "count").write_text("0\n")
        fixture = r'''
C=$1 JOB=fixture TASK=fixture PROBLEMS=
new_case() { :; }
mode() { :; }
job() { :; }
sleep() { :; }
ps() {
  n=$(cat "$C/count"); n=$((n + 1)); echo "$n" > "$C/count"
  cat "$C/ps-$n" 2>/dev/null || :
}
own_pid() { [ "$1" = 424242 ] && [ "$2" = fixture ]; }
kill() { printf '%s\n' "$*" >> "$C/signals"; }
wait() { return 143; }
rec() { echo interrupted; }
expect() { what=$1; shift; "$@" || PROBLEMS="$PROBLEMS; $what"; }
done_case() { printf '%s\n' "PROBLEMS=$PROBLEMS"; }
'''
        out = subprocess.run(["sh", "-c", fixture + self.body + "\ncase_22\ncommand wait\n", "fixture",
                              str(self.case)], capture_output=True, text=True, timeout=10)
        self.assertEqual(out.returncode, 0, out.stderr)
        self.assertEqual((self.case / "signals").read_text(), "-TERM 424242\n")
        return out.stdout

    def test_another_suites_sleeper_cannot_claim_readiness_then_disappear(self):
        # The other shell's sleeper exits between the loop's query and expect's next query. Our verifier starts
        # later. The old global `sleep 59.37` match failed only "verification started", exactly as on the Mac.
        own = "%s/work/verification-sleeper 59.37\n" % self.case
        self.assertEqual(self.run_case(["sleep 59.37\n", "", own, own, "", ""]), "PROBLEMS=\n")

    def test_another_suites_survivor_does_not_count_as_our_leak(self):
        own = "%s/work/verification-sleeper 59.37\n" % self.case
        foreign = "/other/case/work/verification-sleeper 59.37\nsleep 59.37\n"
        self.assertEqual(self.run_case([own + foreign, own + foreign, foreign, foreign]), "PROBLEMS=\n")

    def test_our_survivor_is_still_detected_after_its_parent_exits(self):
        # ps args remain the same when init adopts the child; readiness and cleanup must use the same marker.
        own = "%s/work/verification-sleeper 59.37\n" % self.case
        self.assertEqual(self.run_case([own] * 44), "PROBLEMS=; verification child gone\n")


if __name__ == "__main__":
    unittest.main()
