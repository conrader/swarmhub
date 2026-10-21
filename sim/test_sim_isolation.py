"""The sim harness refuses to start unless isolated, and its signal guard refuses broadcast and foreign targets.

Refusal cases use a synthetic /proc and recorders in place of os.kill/os.killpg, so a broken guard records instead
of signalling. Real signals go only to children this test spawned. The end-to-end refusals start the guard (and a
Swift-style launch of live_observed.py) in a nested PID namespace without its own /proc, from inside the namespace
this suite must already run in.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import ast
import errno
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
GUARD_SCRIPT = ROOT / "sim/sim_isolation.py"
OTHER_NS = "pid:[4026532999]"


def fake_proc(root, own_ns=OTHER_NS, self_pid=7, init_ns=None, parents=None):
    """A /proc with self -> self_pid, its ns/pid link, pid 1's ns/pid link and status PPid lines."""
    root = Path(root)
    parents = {7: 3, 3: 1, 1: 0} if parents is None else parents
    for pid, ppid in parents.items():
        (root / str(pid) / "ns").mkdir(parents=True, exist_ok=True)
        (root / str(pid) / "status").write_text("Name:\tx\nPid:\t%d\nPPid:\t%d\n" % (pid, ppid))
    (root / "self").symlink_to(str(self_pid))
    ns = root / str(self_pid) / "ns"
    ns.mkdir(parents=True, exist_ok=True)
    (ns / "pid").symlink_to(own_ns)
    (root / "1/ns").mkdir(parents=True, exist_ok=True)
    if not (root / "1/ns/pid").is_symlink():
        (root / "1/ns/pid").symlink_to(init_ns or own_ns)
    return str(root)


class LinuxDetectionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="simiso-")
        self.addCleanup(shutil.rmtree, self.tmp)

    def problem(self, **kwargs):
        pid = kwargs.pop("pid", 7)
        return sim_isolation.linux_problem(fake_proc(self.tmp, **kwargs), pid=pid)

    def test_isolated_namespace_with_its_own_proc_and_pid_one_ancestor_is_accepted(self):
        self.assertIsNone(self.problem())

    def test_host_initial_pid_namespace_is_refused(self):
        self.assertIn("initial PID namespace", self.problem(own_ns=sim_isolation.INIT_PID_NS))

    def test_proc_of_another_namespace_is_refused(self):
        """unshare -p without --mount-proc: /proc/self names the host pid, not ours."""
        self.assertIn("--mount-proc", self.problem(pid=1))

    def test_pid_one_in_another_namespace_is_refused(self):
        self.assertIn("different PID namespace", self.problem(init_ns="pid:[4026533000]"))

    def test_pid_one_that_is_not_an_ancestor_is_refused(self):
        self.assertIn("not an ancestor", self.problem(parents={7: 3, 3: 0, 1: 0}))

    def test_unreadable_proc_is_refused(self):
        self.assertIn("cannot read", sim_isolation.linux_problem(os.path.join(self.tmp, "missing"), pid=7))

    def test_an_environment_variable_cannot_claim_isolation(self):
        for name in ("SWARMHUB_SIM_ISOLATED", "SIM_ISOLATED", "container"):
            os.environ[name] = "1"
            self.addCleanup(os.environ.pop, name, None)
        self.assertIn("initial PID namespace", self.problem(own_ns=sim_isolation.INIT_PID_NS))

    def test_modes_per_platform(self):
        self.assertEqual(sim_isolation.mode("linux", problem=lambda: None), ("pid-namespace", None))
        self.assertEqual(sim_isolation.mode("linux", problem=lambda: "nope"), (None, "nope"))
        self.assertEqual(sim_isolation.mode("darwin"), ("darwin-guarded", None))
        self.assertEqual(sim_isolation.mode("freebsd14")[0], None)

    def test_refusal_names_the_required_command_and_a_swift_launch(self):
        text = sim_isolation.refusal("running in the host's initial PID namespace")
        self.assertIn("sudo -u sbtest -- unshare -r -p -f --mount-proc", text)
        self.assertNotIn("Swift/XCTest", text)
        os.environ["XCTestConfigurationFilePath"] = "/tmp/x.xctestconfiguration"
        self.addCleanup(os.environ.pop, "XCTestConfigurationFilePath", None)
        self.assertIn("Swift/XCTest", sim_isolation.refusal("x"))


class RecordingGuard(sim_isolation.SignalGuard):
    """table: {pid: ppid} (each its own group) or {pid: (ppid, pgid, start)}, read live on every check. Nothing here
    can reach the kernel."""

    def __init__(self, table, pid=500, pgrp=400):
        self.sent = []
        rows = lambda: {p: v if isinstance(v, tuple) else (v, p, "t0") for p, v in table.items()}  # noqa: E731
        super().__init__(kill=lambda p, s: self.sent.append(("kill", p, s)),
                         killpg=lambda g, s: self.sent.append(("killpg", g, s)),
                         table=rows, getpid=lambda: pid, getpgrp=lambda: pgrp, log=lambda message: None)


class SignalGuardTests(unittest.TestCase):
    PARENTS = {1: 0, 400: 1, 500: 400, 600: 500, 601: 600, 602: 601, 900: 1}  # 600 spawned; 900 foreign

    def guard(self, **kwargs):
        guard = RecordingGuard(self.PARENTS, **kwargs)
        guard.record(600)
        return guard

    def assertRefused(self, call, *args):
        with self.assertRaises(PermissionError) as raised:
            call(*args)
        self.assertEqual(raised.exception.errno, errno.EPERM)

    def test_bad_pids_are_refused_for_every_signal(self):
        guard = self.guard()
        for pid in (0, 1, -1, -600, "", None, "600", True, 600.0):
            for sig in (signal.SIGTERM, signal.SIGKILL, 0):
                self.assertRefused(guard.kill, pid, sig)
        self.assertEqual(guard.sent, [])

    def test_foreign_parent_and_ancestor_pids_are_refused(self):
        guard = self.guard()
        for pid in (900, 400):
            self.assertRefused(guard.kill, pid, signal.SIGTERM)
        self.assertEqual(guard.sent, [])

    def test_spawned_children_their_descendants_and_self_are_allowed(self):
        guard = self.guard()
        guard.spawned.clear()  # 600 is still this process's direct child (500 -> 600) and so its own.
        for pid in (600, 601, 602, 500):
            guard.kill(pid, signal.SIGTERM)
        self.assertEqual([p for _, p, _ in guard.sent], [600, 601, 602, 500])

    def test_existence_probe_may_name_any_pid_above_one(self):
        guard = self.guard()
        guard.kill(900, 0)
        self.assertEqual(guard.sent, [("kill", 900, 0)])

    def test_a_stale_pid_is_reported_missing_without_a_signal(self):
        guard = self.guard()
        with self.assertRaises(ProcessLookupError):
            guard.kill(12345, signal.SIGTERM)
        self.assertEqual(guard.sent, [])

    def test_groups_broadcast_own_and_foreign_are_refused(self):
        guard = self.guard()
        for pgid in (0, 1, -1, 400, 900, None, ""):
            self.assertRefused(guard.killpg, pgid, signal.SIGTERM)
        self.assertEqual(guard.sent, [])

    def test_spawned_group_and_a_group_this_process_leads_are_allowed(self):
        guard = RecordingGuard(self.PARENTS, pid=500, pgrp=500)
        guard.record(600)
        guard.killpg(600, signal.SIGTERM)
        guard.killpg(500, signal.SIGTERM)
        self.assertEqual(guard.sent, [("killpg", 600, signal.SIGTERM), ("killpg", 500, signal.SIGTERM)])

    def test_pid_one_may_signal_only_itself(self):
        """`unshare -p -f python3 ...` makes the runner pid 1 of its namespace; it may still raise its own signals."""
        guard = RecordingGuard({1: 0, 600: 1}, pid=1, pgrp=0)
        guard.kill(1, signal.SIGTERM)
        for pgid in (0, 1):
            self.assertRefused(guard.killpg, pgid, signal.SIGTERM)
        self.assertRefused(guard.kill, -1, signal.SIGTERM)
        self.assertRefused(guard.kill, 0, signal.SIGTERM)
        guard.kill(600, signal.SIGTERM)  # An orphan it adopted as pid 1 is its own child.
        self.assertEqual(guard.sent, [("kill", 1, signal.SIGTERM), ("kill", 600, signal.SIGTERM)])

    def test_a_reaped_child_pid_is_reported_gone_even_if_its_number_is_ours_again(self):
        guard = RecordingGuard({1: 0, 400: 1, 500: 400, 701: 500}, pid=500)
        guard.record(701)
        guard.reap(701)  # What every wait wrapper reports; the caller means the old child, which is gone.
        with self.assertRaises(ProcessLookupError):
            guard.kill(701, signal.SIGTERM)
        self.assertEqual(guard.sent, [])

    def test_record_ignores_fork_children_and_garbage(self):
        guard = RecordingGuard({})
        for value in (0, 1, -1, None, "7"):
            guard.record(value)
        self.assertEqual(guard.spawned, set())


class InstalledGuardTests(unittest.TestCase):
    """The guard this process installed on import: real signals only to our own sleepers."""

    def sleeper(self, **kwargs):
        child = subprocess.Popen(["sleep", "30"], **kwargs)
        self.addCleanup(lambda: child.poll() is None and (sim_isolation.GUARD._kill(child.pid, signal.SIGKILL),
                                                          child.wait()))
        return child

    def test_import_installed_the_guard_for_this_platform(self):
        self.assertIn(sim_isolation.MODE, ("pid-namespace", "darwin-guarded"))
        self.assertEqual(os.kill, sim_isolation.GUARD.kill)
        self.assertEqual(os.killpg, sim_isolation.GUARD.killpg)
        if sys.platform.startswith("linux"):
            self.assertEqual(sim_isolation.MODE, "pid-namespace")
            self.assertIsNone(sim_isolation.linux_problem())
        if hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"):
            self.assertIsNotNone(sim_isolation.GUARD.pin)  # kill() signals through a pidfd, never a bare number.

    def test_popen_and_posix_spawn_children_are_recorded_and_signallable(self):
        child = self.sleeper()
        self.assertIn(child.pid, sim_isolation.GUARD.spawned)
        child.terminate()
        self.assertEqual(child.wait(timeout=10), -signal.SIGTERM)
        pid = os.posix_spawnp("sleep", ["sleep", "30"], dict(os.environ))
        self.assertIn(pid, sim_isolation.GUARD.spawned)
        os.kill(pid, signal.SIGKILL)
        self.assertEqual(os.waitpid(pid, 0)[0], pid)
        self.assertIn(pid, sim_isolation.GUARD.reaped)
        self.assertIn(child.pid, sim_isolation.GUARD.reaped)  # Popen reported its exit status.

    def orphan(self):
        """Our own sleeper whose parent exited: no longer this process's descendant, so foreign to the guard."""
        out = subprocess.run(["sh", "-c", "sleep 30 > /dev/null 2>&1 & echo $!"], capture_output=True, text=True,
                             timeout=10).stdout
        pid = int(out)

        def reap():
            try:
                sim_isolation.GUARD._kill(pid, signal.SIGKILL)  # Exactly the pid we started, bypassing the guard.
                os.waitpid(pid, 0)  # Reparented to us when this runner is pid 1 of the namespace.
            except (ProcessLookupError, ChildProcessError):
                pass
        self.addCleanup(reap)
        return pid

    def alive(self, pid):
        state = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        return bool(state) and not state.startswith("Z")

    def test_a_process_that_is_not_ours_is_not_signalled(self):
        pid = self.orphan()
        # As pid 1 of its namespace this runner adopts every orphan, so inside the namespace nothing is foreign. Make
        # the guard see another pid as its own, as on macOS where launchd (not the runner) adopts orphans.
        patcher = mock.patch.object(sim_isolation.GUARD, "_getpid", lambda: 2 ** 22 + 1)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.assertNotIn(pid, sim_isolation.GUARD.spawned)
        self.assertFalse(sim_isolation.GUARD.owned(pid))
        with self.assertRaises(PermissionError):
            os.kill(pid, signal.SIGTERM)
        if hasattr(signal, "pidfd_send_signal") and hasattr(os, "pidfd_open"):
            fd = os.pidfd_open(pid)
            self.addCleanup(os.close, fd)
            with self.assertRaises(PermissionError):
                signal.pidfd_send_signal(fd, signal.SIGTERM)
        os.kill(pid, 0)  # An existence probe is still allowed.
        time.sleep(.1)
        self.assertTrue(self.alive(pid))

    def test_a_direct_child_is_ours_even_if_its_spawn_was_not_recorded(self):
        child = self.sleeper()
        sim_isolation.GUARD.spawned.discard(child.pid)
        child.terminate()
        self.assertEqual(child.wait(timeout=10), -signal.SIGTERM)

    def test_own_group_is_refused_unless_led_and_spawned_session_group_is_allowed(self):
        if os.getpgrp() != os.getpid():
            sent = []
            with mock.patch.object(sim_isolation.GUARD, "_killpg", lambda *args: sent.append(args)):
                with self.assertRaises(PermissionError):
                    os.killpg(os.getpgrp(), signal.SIGTERM)
            self.assertEqual(sent, [])
        child = self.sleeper(start_new_session=True)
        os.killpg(child.pid, signal.SIGTERM)
        self.assertEqual(child.wait(timeout=10), -signal.SIGTERM)

    @unittest.skipUnless(hasattr(os, "pidfd_open"), "pidfd is Linux-only")
    def test_pidfd_of_an_exited_child_reports_it_gone(self):
        child = self.sleeper()
        fd = os.pidfd_open(child.pid)
        self.addCleanup(os.close, fd)
        child.kill()
        child.wait()
        with self.assertRaises(ProcessLookupError):
            signal.pidfd_send_signal(fd, signal.SIGTERM)


def nested_without_proc():
    """argv prefix for a nested PID namespace that keeps this namespace's /proc, or None if unavailable."""
    if not sys.platform.startswith("linux") or not shutil.which("unshare"):
        return None
    probe = subprocess.run(["unshare", "-r", "-p", "-f", "true"], capture_output=True, timeout=20)
    return ["unshare", "-r", "-p", "-f"] if probe.returncode == 0 else None


class EndToEndTests(unittest.TestCase):
    def test_check_passes_here(self):
        result = subprocess.run([sys.executable, "-I", "-B", str(GUARD_SCRIPT), "--check"], capture_output=True,
                                text=True, timeout=30)
        self.assertEqual((result.returncode, result.stdout.strip()), (0, sim_isolation.MODE), result.stderr)

    def test_check_refuses_a_namespace_without_its_own_proc(self):
        prefix = nested_without_proc()
        if prefix is None:
            self.skipTest("no nested unprivileged PID namespace on this host")
        result = subprocess.run(prefix + [sys.executable, "-I", "-B", str(GUARD_SCRIPT), "--check"],
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, sim_isolation.REFUSED, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertIn("sudo -u sbtest -- unshare -r -p -f --mount-proc", result.stderr)

    def swift_style(self, prefix, output):
        """ObservedPatternTests' launch: /usr/bin/python3 live_observed.py --offline with a minimal environment."""
        env = {"PATH": "/usr/bin:/bin", "HOME": str(output.parent), "PYTHONDONTWRITEBYTECODE": "1",
               "XCTestConfigurationFilePath": "/tmp/swift.xctestconfiguration"}
        return subprocess.run(prefix + [sys.executable, str(ROOT / "sim/live_observed.py"), "--offline", "--pattern",
                                        "P01", "--output", str(output)], env=env, capture_output=True, text=True,
                              timeout=300)

    def test_a_swift_launched_harness_is_refused_before_it_runs_anything(self):
        prefix = nested_without_proc()
        if prefix is None:
            self.skipTest("no nested unprivileged PID namespace on this host")
        with tempfile.TemporaryDirectory(prefix="simiso-swift-") as tmp:
            output = Path(tmp) / "out"
            result = self.swift_style(prefix, output)
            self.assertEqual(result.returncode, sim_isolation.REFUSED, result.stderr)
            self.assertIn("Swift/XCTest", result.stderr)
            self.assertFalse(output.exists(), "the harness ran before the guard refused")

    def test_a_swift_launched_harness_starts_inside_the_namespace_and_reports_its_mode(self):
        with tempfile.TemporaryDirectory(prefix="simiso-swift-") as tmp:
            output = Path(tmp) / "out"
            result = self.swift_style([], output)
            self.assertEqual(result.returncode, 0, result.stderr[-2000:])
            report = json.loads((output / "results.json").read_text())
            self.assertEqual(report["isolation"], sim_isolation.MODE)


SHELL_SUITES = ("Tests/Scripts/code-job-test.sh", "Tests/Scripts/bot-msg-test.sh", "sim/mac-codex-tmp-smoke.sh")
UNGUARDED = {"sim_isolation.py": "the guard itself",
             "mac-codex-tmp-smoke-stub.py": "a fake codex CLI run inside code-job's sandbox, under the guarded smoke"}


class EveryEntryPointIsGuarded(unittest.TestCase):
    def test_every_sim_module_imports_the_guard_first(self):
        offenders = []
        for path in sorted((ROOT / "sim").glob("*.py")):
            if path.name in UNGUARDED:
                continue
            imports = [node for node in ast.parse(path.read_text()).body if isinstance(node, (ast.Import, ast.ImportFrom))
                       and not (isinstance(node, ast.ImportFrom) and node.module == "__future__")]
            first = imports[0] if imports else None
            if not (isinstance(first, ast.Import) and [a.name for a in first.names] == ["sim_isolation"]):
                offenders.append(path.name)
        self.assertEqual(offenders, [])

    def test_signal_sending_shell_suites_check_before_anything_else(self):
        for rel in SHELL_SUITES:
            lines = (ROOT / rel).read_text().splitlines()
            check = next(i for i, line in enumerate(lines) if "sim_isolation.py\" --check" in line)
            self.assertTrue(lines[check].startswith("/usr/bin/python3 -I -B ") and "--check > /dev/null || exit 78" in
                            lines[check], rel)
            code = [i for i, line in enumerate(lines) if line.strip() and not line.lstrip().startswith("#")]
            self.assertEqual(code[0], check, rel)

    def test_the_swift_harness_launch_asserts_the_guarded_mode(self):
        swift = (ROOT / "Tests/AgentAppTests/ObservedPatternTests.swift").read_text()
        self.assertIn('report["isolation"]', swift)
        self.assertIn('"darwin-guarded"', swift)


if __name__ == "__main__":
    unittest.main()
