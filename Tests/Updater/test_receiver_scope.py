"""The receiver install the timer's updater runs must outlive the updater (runner.own_scope).

The timer runs the updater as a oneshot systemd user service; when it exits, systemd kills what is left in its control
group. Without lingering, `swarmctl webhook receiver install` starts the fallback supervisor as a detached child, so
the updater runs that install in a transient scope of its own. The stub tests drive the real `pull` with the timer's
environment (INVOCATION_ID) and a stand-in `systemd-run` that runs its command the way a scope does. LiveUserManager
crosses the real boundary: a transient oneshot service on this account's own systemd user manager runs
runner.ensure_receiver against a stub swarmctl that leaves a detached sleeper, as the fallback supervisor would; it
needs a reachable user manager and SWARMHUB_LIVE_USER_MANAGER=1. Nothing is signalled by the tests: the sleepers end
on their own, and systemd stops only the transient units these tests start.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import MESSAGES, ROOT  # noqa: E402
from pull_fixtures import PullCase  # noqa: E402
from test_mac_code_confirm import MacCommand  # noqa: E402

from swarmhub_update import runner  # noqa: E402

# Stands in for systemd-run: records its arguments, then runs the command after `--` with a mark in its environment,
# as the scope would hold it; with SCOPE_FAILS it refuses the way a missing user manager does, running nothing.
SYSTEMD_RUN_STUB = '''#!/usr/bin/env python3
import json, os, sys
with open(%r, "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\\n")
if os.environ.get("SCOPE_FAILS"):
    sys.stderr.write("Failed to connect to bus: No medium found\\n")
    sys.exit(1)
argv = sys.argv[sys.argv.index("--") + 1:]
os.execve(argv[0], argv, dict(os.environ, IN_SCOPE="1"))
'''
# The swarmctl stub, also noting whether it ran inside the scope.
SCOPED_RECEIVER_STUB = '''#!/usr/bin/env python3
import json, os, sys
with open(%r, "a") as calls:
    calls.write(json.dumps(sys.argv[1:] + (["in-scope"] if os.environ.get("IN_SCOPE") else [])) + "\\n")
'''
INSTALL = ["webhook", "receiver", "install"]


class TimerPullScope(MacCommand, PullCase):
    def setUp(self):
        super().setUp()
        self.calls = self.tmp / "receiver-calls"
        self.scopes = self.tmp / "systemd-run-calls"
        tools = self.tmp / "tools"
        tools.mkdir()
        (tools / "systemd-run").write_text(SYSTEMD_RUN_STUB % str(self.scopes))
        (tools / "systemd-run").chmod(0o755)
        self.path = str(tools) + os.pathsep + os.environ.get("PATH", "")

    def land(self, **env):
        """Publish v11 with a swarmhub-messages swarmctl stub, defer its confirm, then let the timer's pull land it."""
        _, components = self.release("v11", files={MESSAGES + "/scripts/swarmctl": SCOPED_RECEIVER_STUB % str(self.calls)})
        self.publish(11, components)
        self.assertEqual(self.pull(self.service.url)[0], 0)
        idle = self.defer_confirm(11, self.calls)
        idle()
        with mock.patch.dict(os.environ, dict(env, PATH=self.path)):
            if "INVOCATION_ID" not in env:
                os.environ.pop("INVOCATION_ID", None)
            code, status = self.pull(self.service.url)
        self.assertEqual((code, status["state"], status["applied_bundle_version"]), (0, "current", 11), status)
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def scope_calls(self):
        return [json.loads(line) for line in self.scopes.read_text().splitlines()] if self.scopes.exists() else []

    def test_the_timer_runs_the_install_in_a_scope_of_its_own(self):
        self.assertEqual(self.land(INVOCATION_ID="0123456789abcdef0123456789abcdef"), [INSTALL + ["in-scope"]],
                         "run by the timer, the install (and any supervisor it starts) is outside the updater's unit")
        (scope,) = self.scope_calls()
        separator = scope.index("--")
        self.assertEqual(scope[:separator], ["--user", "--scope", "--quiet", "--collect",
                                             "--description=Swarm Hub webhook receiver install"])
        live = self.live(MESSAGES) / "scripts/swarmctl"
        self.assertEqual(scope[separator + 1:], [sys.executable, "-B", str(live)] + INSTALL)
        with mock.patch.dict(os.environ, {"INVOCATION_ID": "fedcba9876543210fedcba9876543210", "PATH": self.path}):
            self.assertEqual(self.pull(self.service.url)[1]["state"], "current")  # the timer's next, unchanged run
        self.assertEqual(len(self.scope_calls()), 1, "nothing new landed: no second scope")
        self.assertEqual(len(self.calls.read_text().splitlines()), 1, "nothing new landed: no second install")
        self.assert_hermes_unchanged()

    def test_without_a_scope_the_install_still_runs_directly(self):
        self.assertEqual(self.land(INVOCATION_ID="0123456789abcdef0123456789abcdef", SCOPE_FAILS="1"), [INSTALL],
                         "a user manager that refuses the scope leaves the direct install, as before")
        self.assertEqual(len(self.scope_calls()), 1)

    def test_from_a_shell_the_install_is_not_wrapped(self):
        self.assertEqual(self.land(), [INSTALL], "outside a unit (an owner's `pull`, the Mac over SSH) nothing changes")
        self.assertEqual(self.scope_calls(), [])


class OwnScope(unittest.TestCase):
    def test_only_a_linux_systemd_unit_gets_a_scope(self):
        argv = ["/usr/bin/python3", "-B", "/x/swarmctl"] + INSTALL
        with mock.patch.object(runner.shutil, "which", return_value="/usr/bin/systemd-run"):
            with mock.patch.dict(os.environ, {"INVOCATION_ID": "1"}), mock.patch.object(runner.sys, "platform", "linux"):
                self.assertEqual(runner.own_scope(argv)[-len(argv) - 1:], ["--"] + argv)
            with mock.patch.dict(os.environ, {"INVOCATION_ID": "1"}), mock.patch.object(runner.sys, "platform", "darwin"):
                self.assertIsNone(runner.own_scope(argv))
            with mock.patch.dict(os.environ, {"INVOCATION_ID": ""}), mock.patch.object(runner.sys, "platform", "linux"):
                self.assertIsNone(runner.own_scope(argv))
        with mock.patch.dict(os.environ, {"INVOCATION_ID": "1"}), mock.patch.object(runner.shutil, "which", return_value=None):
            self.assertIsNone(runner.own_scope(argv))


# Runs inside the transient oneshot service: ensure_receiver for one GOOD profile whose live swarmctl is the sleeper
# stub, with INVOCATION_ID as systemd set it, or removed for the control run.
UNIT_MAIN = '''
import os, sys
from collections import namedtuple
sys.path.insert(0, sys.argv[1])
from swarmhub_update import runner
if sys.argv[3] == "control":
    os.environ.pop("INVOCATION_ID", None)
Box = namedtuple("Box", "hermes_home")
Result = namedtuple("Result", "status")
print(runner.ensure_receiver(Box(sys.argv[2]), runner.Report(set(), {}, {}, {"default": Result("applied")})))
'''
# The live swarmctl stub: like the fallback supervisor's start, it leaves a detached child in a session of its own
# (store.spawn) and exits once the child has recorded its pid and control group; the child ends by itself.
SLEEPER_STUB = '''#!/usr/bin/env python3
import os, subprocess, sys, time
subprocess.Popen([sys.executable, "-c", "import os, time\\n"
                  "open(%r, 'w').write(str(os.getpid()) + ' ' + open('/proc/self/cgroup').read().strip())\\n"
                  "time.sleep(15)"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                 start_new_session=True, close_fds=True)
for _ in range(100):
    if os.path.exists(%r) and open(%r).read().strip():
        break
    time.sleep(0.05)
'''


def user_manager():
    try:
        return subprocess.run(["systemctl", "--user", "show", "--property=Version"], capture_output=True,
                              timeout=10).returncode == 0 and bool(shutil.which("systemd-run"))
    except (OSError, subprocess.SubprocessError):
        return False


@unittest.skipUnless(os.environ.get("SWARMHUB_LIVE_USER_MANAGER") == "1" and sys.platform.startswith("linux")
                     and user_manager(), "needs SWARMHUB_LIVE_USER_MANAGER=1 and this account's systemd user manager")
class LiveUserManager(unittest.TestCase):
    def run_unit(self, mode):
        tmp = Path(tempfile.mkdtemp(prefix="swarmhub-scope-"))
        self.addCleanup(shutil.rmtree, str(tmp), True)
        scripts = tmp / "home/skills/swarmhub" / MESSAGES / "scripts"
        scripts.mkdir(parents=True)
        record = tmp / "sleeper"
        (scripts / "swarmctl").write_text(SLEEPER_STUB % ((str(record),) * 3))
        (scripts / "swarmctl").chmod(0o755)
        (tmp / "unit_main.py").write_text(UNIT_MAIN)
        unit = "swarmhub-scope-test-%s-%d" % (mode, os.getpid())
        done = subprocess.run(["systemd-run", "--user", "--wait", "--quiet", "--collect", "--unit", unit,
                               "-p", "Type=oneshot", "-E", "PYTHONDONTWRITEBYTECODE=1",
                               sys.executable, "-B", str(tmp / "unit_main.py"), str(ROOT / "Resources/Updater"),
                               str(tmp / "home"), mode], capture_output=True, text=True, timeout=120)
        self.assertEqual(done.returncode, 0, done.stderr)
        for _ in range(50):  # the sleeper writes its record just after it starts
            if record.exists() and record.read_text().strip():
                break
            time.sleep(0.1)
        pid, cgroup = record.read_text().split(" ", 1)
        time.sleep(1)  # systemd has stopped the oneshot by the time --wait returns; let any cleanup land
        return int(pid), cgroup, unit

    @staticmethod
    def alive(pid):
        try:
            with open("/proc/%d/stat" % pid) as stat:
                return stat.read().rsplit(")", 1)[1].split()[0] != "Z"
        except OSError:
            return False

    def test_the_install_started_by_the_oneshot_outlives_it(self):
        pid, cgroup, unit = self.run_unit("scoped")
        self.assertNotIn(unit + ".service", cgroup)
        self.assertTrue(cgroup.endswith(".scope"), cgroup)
        self.assertTrue(self.alive(pid), "the detached child of a scoped install survives the updater's exit")

    def test_control_without_the_scope_systemd_kills_it_with_the_oneshot(self):
        pid, cgroup, unit = self.run_unit("control")
        self.assertTrue(cgroup.endswith("/" + unit + ".service"), cgroup)
        self.assertFalse(self.alive(pid), "the reviewer's case: left in the updater's control group, it is killed")


if __name__ == "__main__":
    unittest.main()
