"""Real POSIX signals/process trees in temporary homes; no Hermes or network."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

from test_peer_runtime import peer, RUNTIME


class ShutdownTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.folder = self.home / '.hermes/swarmhub'
        self.folder.mkdir(parents=True)
        self.env = dict(HOME=str(self.home), PATH='/usr/bin:/bin', PYTHONDONTWRITEBYTECODE='1')
        self.processes = []
        self.addCleanup(self.cleanup_processes)

    def cleanup_processes(self):
        for child in reversed(self.processes):
            if child.poll() is None:
                self.check_process(child)
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            child.wait(timeout=3)
            for stream in (child.stdout, child.stderr):
                if stream:
                    stream.close()

    def launch(self, *argv):
        child = subprocess.Popen([sys.executable, '-B', *map(str, argv)], env=self.env,
                                 start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(child)
        return child

    def boot(self, body):
        script = self.home / f'boot-{len(self.processes)}.py'
        script.write_text('import sys, runpy\n'
                          f'sys.path.insert(0, {str(RUNTIME.parent)!r})\n'
                          f'p = runpy.run_path({str(RUNTIME)!r})\n'
                          'import swarm_lifecycle as lifecycle\n' + body)
        return self.launch(script)

    def eventually(self, condition, timeout=5):
        deadline = time.monotonic() + timeout
        while not condition():
            self.assertLess(time.monotonic(), deadline, 'timed out waiting for fixture')
            time.sleep(.01)

    def live(self, pid):
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'stat='], capture_output=True, text=True, check=False)
        return result.returncode == 0 and bool(result.stdout.strip()) and not result.stdout.strip().startswith('Z')

    def stop(self, child, sig, limit=4):
        self.check_process(child)
        start = time.monotonic()
        child.send_signal(sig)
        result = child.wait(timeout=limit)
        stream = child.stderr or child.stdout
        self.assertEqual(result, 0, stream.read().decode() if stream else '')
        self.assertLess(time.monotonic() - start, limit)

    def check_process(self, child):
        result = subprocess.run(['ps', '-p', str(child.pid), '-o', 'pid=,pgid=,cmd='],
                                capture_output=True, text=True, check=True)
        pid, pgid, command = result.stdout.strip().split(None, 2)
        self.assertEqual(int(pid), child.pid)
        self.assertEqual(int(pgid), child.pid)
        self.assertIn('python', command)

    def gateway_supervisor(self, runtime=RUNTIME):
        """Real registry-owned Popen; only the Hermes registry itself is faked."""
        registry = types.SimpleNamespace(adopt_local=unittest.mock.Mock())
        modules = {'tools': types.ModuleType('tools'),
                   'tools.process_registry': types.SimpleNamespace(process_registry=registry)}
        with patch.dict(sys.modules, modules), patch.dict(os.environ, self.env), \
                patch.object(peer, '__file__', str(runtime)):
            pid = peer.start_worker(managed=True)
        child = registry.adopt_local.call_args.args[0]
        self.processes.append(child)
        self.assertEqual(pid, child.pid)
        self.assertTrue(registry.adopt_local.return_value.persist_on_release)
        return child

    def cli_supervisor(self):
        # Exercise the short-lived CLI launcher, not just a foreground supervisor.
        result = subprocess.run([sys.executable, '-B', str(RUNTIME), 'start'], env=self.env,
                                capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.eventually(lambda: (self.folder / 'job-wake.pid').exists())
        supervisor = int((self.folder / 'job-wake.supervisor.pid').read_text())
        worker = int((self.folder / 'job-wake.pid').read_text())
        self.addCleanup(self.kill_group, supervisor)
        self.addCleanup(self.kill_group, worker)
        return supervisor, worker

    def test_cli_first_supervisor_is_stopped_by_gateway_registry_shutdown(self):
        supervisor, worker = self.cli_supervisor()
        managed = self.gateway_supervisor()
        # The registered process must stay alive while the detached owner works.
        with self.assertRaises(subprocess.TimeoutExpired):
            managed.wait(timeout=.3)
        self.assertEqual((self.folder / 'job-wake.supervisor.pid').read_text(), str(supervisor))
        self.assertTrue(self.live(worker))
        self.stop(managed, signal.SIGTERM, limit=5)  # Gateway shutdown of its registry entry.
        self.eventually(lambda: not self.live(supervisor) and not self.live(worker))
        self.assertEqual((self.folder / 'job-wake.pid').read_text(), str(worker), 'no restart on shutdown')
        with (self.folder / 'job-wake.supervisor.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_gateway_shutdown_immediately_after_registration_reaches_cli_owner(self):
        supervisor, worker = self.cli_supervisor()
        managed = self.gateway_supervisor()
        self.stop(managed, signal.SIGTERM, limit=5)
        self.eventually(lambda: not self.live(supervisor) and not self.live(worker))

    @unittest.skipUnless(hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'), 'Linux pidfd')
    def test_gateway_shutdown_reaches_legacy_supervisor_without_instance_metadata(self):
        runtime = self.home / 'peer-runtime.py'
        # Same deployed script path, but the running pre-upgrade instance never
        # published a token. Leave its normal worker/signal handling intact.
        source = RUNTIME.read_text().replace('import swarm_control as control',
                    f'sys.path.insert(0, {str(RUNTIME.parent)!r})\nimport swarm_control as control')
        source = source.replace('elif command == "supervise":\n',
                    'elif command == "supervise":\n'
                    '            if os.environ.get("TEST_LEGACY_SUPERVISOR"):\n'
                    '                from contextlib import nullcontext\n'
                    '                lifecycle.supervisor_identity = lambda *args: nullcontext()\n')
        runtime.write_text(source)
        legacy = subprocess.Popen([sys.executable, str(runtime), 'supervise'],
                    env=dict(self.env, TEST_LEGACY_SUPERVISOR='1'), start_new_session=True,
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.processes.append(legacy)
        self.eventually(lambda: (self.folder / 'job-wake.pid').exists())
        self.assertEqual((self.folder / 'job-wake.supervisor.lock').read_text(), '')
        worker = int((self.folder / 'job-wake.pid').read_text())
        managed = self.gateway_supervisor(runtime)
        self.stop(managed, signal.SIGTERM, limit=5)
        self.assertEqual(legacy.wait(timeout=1), 0, legacy.stderr.read().decode())
        self.assertFalse(self.live(worker))

    def test_gateway_relay_takes_over_when_original_supervisor_exits(self):
        owner = self.launch(RUNTIME, 'supervise')
        self.eventually(lambda: (self.folder / 'job-wake.pid').exists())
        original_worker = int((self.folder / 'job-wake.pid').read_text())
        managed = self.gateway_supervisor()
        self.stop(owner, signal.SIGTERM)
        self.eventually(lambda: (self.folder / 'job-wake.supervisor.pid').read_text() == str(managed.pid)
                        and (self.folder / 'job-wake.pid').read_text() != str(original_worker))
        worker = int((self.folder / 'job-wake.pid').read_text())
        self.stop(managed, signal.SIGINT)
        self.assertFalse(self.live(worker))

    def test_relay_uses_instance_identity_even_if_pid_record_is_recycled(self):
        stranger = self.launch('-c', 'import time; time.sleep(60)')
        supervisor, worker = self.cli_supervisor()
        lockpath = self.folder / 'job-wake.supervisor.lock'
        owner = json.loads(lockpath.read_text())
        # Model a stale/recycled PID in both the legacy file and the lock record.
        (self.folder / 'job-wake.supervisor.pid').write_text(str(stranger.pid))
        owner['pid'] = stranger.pid
        lockpath.write_text(json.dumps(owner))
        (self.folder / ('job-wake.supervisor.stop-' + '0' * 32)).touch()
        managed = self.gateway_supervisor()
        with self.assertRaises(subprocess.TimeoutExpired):
            managed.wait(timeout=.3)
        self.assertTrue(self.live(supervisor), 'a stale instance request must be ignored')
        self.stop(managed, signal.SIGTERM, limit=5)
        self.eventually(lambda: not self.live(supervisor) and not self.live(worker))
        self.assertIsNone(stranger.poll(), 'a reused PID must never be signalled')

    def test_relay_never_signals_an_unrelated_lock_holder_with_stale_identity(self):
        stranger = self.boot(
            'import fcntl, json, os, time\nfrom pathlib import Path\n'
            f'folder = Path({str(self.folder)!r})\n'
            'with (folder / "job-wake.supervisor.lock").open("w+") as lock:\n'
            '    fcntl.flock(lock, fcntl.LOCK_EX)\n'
            '    json.dump({"pid": os.getpid(), "instance": "malformed-token"}, lock)\n'
            '    lock.flush()\n'
            '    (folder / "locked").touch()\n'
            '    time.sleep(60)\n')
        self.eventually(lambda: (self.folder / 'locked').exists())
        (self.folder / 'job-wake.supervisor.pid').write_text(str(stranger.pid))
        managed = self.gateway_supervisor()
        with self.assertRaises(subprocess.TimeoutExpired):
            managed.wait(timeout=.3)
        self.stop(managed, signal.SIGTERM, limit=6)
        self.assertIsNone(stranger.poll())
        self.assertFalse((self.folder / 'job-wake.pid').exists())
        self.assertIn('did not release its lock', (self.folder / 'job-wake.error').read_text())

    def test_supervisor_forwards_each_signal_and_never_restarts_worker(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                worker_pid = self.folder / 'job-wake.pid'
                worker_pid.unlink(missing_ok=True)
                child = self.launch(RUNTIME, 'supervise')
                self.eventually(lambda: worker_pid.exists() and worker_pid.read_text().strip())
                pid = int(worker_pid.read_text())
                self.assertTrue(self.live(pid))
                self.stop(child, sig)
                self.assertFalse(self.live(pid))
                self.assertEqual(worker_pid.read_text(), str(pid))
                # Clean shutdown releases both flocks; pending state is retained.
                for name in ('job-wake.lock', 'job-wake.supervisor.lock'):
                    with (self.folder / name).open('a') as lock:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_signal_during_supervisor_backoff_stops_without_next_launch(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                (self.folder / 'job-wake.error').unlink(missing_ok=True)
                runs = self.home / f'runs-{sig}'
                child = self.boot(
                    'from pathlib import Path\n'
                    f'runs = Path({str(runs)!r})\n'
                    'def run():\n    with runs.open("a") as f: f.write("run\\n")\n    return 7\n'
                    'p["supervise"].__globals__["backoff"] = lambda failures: 60\n'
                    'with lifecycle.termination():\n    p["supervise"](run=run)\n')
                self.eventually(lambda: (self.folder / 'job-wake.error').exists())
                self.stop(child, sig, limit=2)
                self.assertEqual(runs.read_text(), 'run\n')

    def test_direct_worker_forwards_signal_to_both_blocked_delivery_loops(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                helper = self.home / f'helper-{sig}.py'
                helper.write_text(
                    'import os, signal, sys, time\nfrom pathlib import Path\n'
                    'base = Path(sys.argv[1])\n'
                    'def stop(sig, frame):\n    base.with_suffix(".signal").write_text(str(sig))\n    sys.exit(0)\n'
                    'signal.signal(signal.SIGTERM, stop)\nsignal.signal(signal.SIGINT, stop)\n'
                    'base.with_suffix(".pid").write_text(str(os.getpid()))\n'
                    'while True: time.sleep(60)\n')
                main, scheduler = (self.home / f'{name}-{sig}' for name in ('main', 'scheduler'))
                child = self.boot(
                    'import subprocess\n'
                    f'helper = {str(helper)!r}\n'
                    f'def sweep(): lifecycle.call([sys.executable, helper, {str(main)!r}], timeout=60)\n'
                    f'def tick(): lifecycle.call([sys.executable, helper, {str(scheduler)!r}], timeout=60)\n'
                    'p["worker"].__globals__["sweep"] = sweep\n'
                    'p["control"].tick = tick\n'
                    'with lifecycle.termination(forward_group=True) as stopped:\n'
                    '    p["worker"](stopped=stopped)\n')
                self.eventually(lambda: all(base.with_suffix('.pid').exists() for base in (main, scheduler)))
                self.stop(child, sig)
                for base in (main, scheduler):
                    self.assertEqual(base.with_suffix('.signal').read_text(), str(sig))
                    self.assertFalse(self.live(int(base.with_suffix('.pid').read_text())))

    def test_worker_error_backoff_is_interrupted_and_state_survives(self):
        child = self.boot(
            'import sqlite3\n'
            'def broken(): raise sqlite3.OperationalError("fixture locked")\n'
            'p["worker"].__globals__["sweep"] = broken\n'
            'p["worker"].__globals__["backoff"] = lambda failures: 60\n'
            'p["control"].tick = lambda: None\n'
            'with lifecycle.termination(forward_group=True) as stopped:\n'
            '    p["worker"](stopped=stopped)\n')
        error = self.folder / 'job-wake.error'
        self.eventually(error.exists)
        self.stop(child, signal.SIGTERM, limit=2)
        self.assertIn('fixture locked', error.read_text())
        with (self.folder / 'job-wake.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def test_stubborn_worker_and_grandchild_are_killed_within_bound(self):
        helper = self.home / 'stubborn.py'
        helper.write_text(
            'import os, signal, subprocess, sys, time\nfrom pathlib import Path\n'
            'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
            'signal.signal(signal.SIGINT, signal.SIG_IGN)\n'
            'base = Path(sys.argv[1])\n'
            'if len(sys.argv) == 2:\n'
            '    subprocess.Popen([sys.executable, __file__, str(base), "leaf"])\n'
            '    base.with_suffix(".parent").write_text(str(os.getpid()))\n'
            'else: base.with_suffix(".leaf").write_text(str(os.getpid()))\n'
            'while True: time.sleep(60)\n')
        record = self.home / 'stubborn'
        child = self.boot(
            f'argv = [sys.executable, {str(helper)!r}, {str(record)!r}]\n'
            'with lifecycle.termination():\n'
            '    p["supervise"](run=lambda: lifecycle.run_child(argv))\n')
        self.eventually(lambda: record.with_suffix('.parent').exists() and record.with_suffix('.leaf').exists())
        worker_pid = int(record.with_suffix('.parent').read_text())
        self.addCleanup(self.kill_group, worker_pid)
        self.stop(child, signal.SIGTERM)
        self.eventually(lambda: all(not self.live(int(record.with_suffix(suffix).read_text()))
                                   for suffix in ('.parent', '.leaf')))
        self.assertFalse((self.folder / 'job-wake.error').exists(), 'shutdown must not schedule a restart')

    def kill_group(self, pid):
        result = subprocess.run(['ps', '-p', str(pid), '-o', 'pid=,pgid=,stat=,cmd='],
                                capture_output=True, text=True, check=False)
        if result.returncode != 0 or not result.stdout.strip():
            return
        actual_pid, pgid, stat, command = result.stdout.strip().split(None, 3)
        if stat.startswith('Z'):
            return
        self.assertEqual(int(actual_pid), pid)
        self.assertEqual(int(pgid), pid)
        self.assertIn('python', command)
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    def test_signal_during_popen_cannot_strand_an_unregistered_worker(self):
        for sig in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=sig):
                pidfile = self.home / f"spawned-{sig}"
                child = self.boot(
                    'import os, signal, subprocess\nfrom pathlib import Path\n'
                    'real_popen = subprocess.Popen\n'
                    'def spawn(*a, **kw):\n'
                    '    child = real_popen(*a, **kw)\n'
                    f'    Path({str(pidfile)!r}).write_text(str(child.pid))\n'
                    f'    os.kill(os.getpid(), {int(sig)})\n'
                    '    return child\n'
                    'subprocess.Popen = spawn\n'
                    'with lifecycle.termination():\n'
                    '    lifecycle.run_child([sys.executable, "-c", "import time; time.sleep(60)"])\n')
                self.assertEqual(child.wait(timeout=4), 0, child.stderr.read().decode())
                self.assertFalse(self.live(int(pidfile.read_text())))

    def test_signal_during_cleanup_is_deferred_until_child_is_reaped(self):
        pidfile = self.home / 'cleanup-child'
        child = self.boot(
            'import os, signal, subprocess\nfrom pathlib import Path\n'
            'child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"], start_new_session=True)\n'
            f'Path({str(pidfile)!r}).write_text(str(child.pid))\n'
            'real_killpg = os.killpg\n'
            'def send(pid, sig):\n'
            '    if sig == signal.SIGTERM: os.kill(os.getpid(), signal.SIGINT)\n'
            '    return real_killpg(pid, sig)\n'
            'os.killpg = send\n'
            'with lifecycle.termination():\n'
            '    lifecycle.stop_child(child)\n'
            'assert child.poll() is not None\n')
        self.assertEqual(child.wait(timeout=4), 0, child.stderr.read().decode())
        self.assertFalse(self.live(int(pidfile.read_text())))

    def test_direct_worker_bounds_stubborn_delivery_groups_in_both_threads(self):
        helper = self.home / 'blocked.py'
        helper.write_text(
            'import os, signal, sys, time\nfrom pathlib import Path\n'
            'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
            'Path(sys.argv[1]).write_text(str(os.getpid()))\n'
            'while True: time.sleep(60)\n')
        records = [self.home / name for name in ('blocked-main', 'blocked-scheduler')]
        child = self.boot(
            f'helper = {str(helper)!r}\n'
            f'def sweep(): lifecycle.call([sys.executable, helper, {str(records[0])!r}], timeout=60)\n'
            f'def tick(): lifecycle.call([sys.executable, helper, {str(records[1])!r}], timeout=60)\n'
            'p["worker"].__globals__["sweep"] = sweep\n'
            'p["control"].tick = tick\n'
            'with lifecycle.termination(forward_group=True) as stopped:\n'
            '    p["worker"](stopped=stopped)\n')
        self.eventually(lambda: all(path.exists() for path in records))
        self.stop(child, signal.SIGTERM)
        self.assertTrue(all(not self.live(int(path.read_text())) for path in records))

    def test_plugin_supervisor_is_adopted_by_gateway_shutdown_registry(self):
        registry = types.SimpleNamespace(adopt_local=unittest.mock.Mock())
        modules = {'tools': types.ModuleType('tools'),
                   'tools.process_registry': types.SimpleNamespace(process_registry=registry)}
        with patch.dict(sys.modules, modules), patch.object(peer.subprocess, 'Popen') as popen, \
                patch.object(peer, 'wait_supervisor_ready') as ready:
            self.assertEqual(peer.start_worker(managed=True), popen.return_value.pid)
            self.assertTrue(registry.adopt_local.return_value.persist_on_release)
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            self.assertEqual(popen.call_args.kwargs['stdout'], subprocess.PIPE)
            self.assertEqual(popen.call_args.args[0], [sys.executable, str(RUNTIME), 'supervise', '--managed'])
            ready.assert_called_once_with(popen.return_value)
            registry.adopt_local.assert_called_once_with(popen.return_value, command='SwarmHub peer recovery',
                                                        cwd=None, notify_on_complete=False)
        registry.adopt_local.side_effect = RuntimeError('fixture adoption failed')
        with patch.dict(sys.modules, modules), patch.object(peer.subprocess, 'Popen') as popen, \
                patch.object(peer.lifecycle, 'stop_child') as stop, patch.object(peer, 'wait_supervisor_ready'):
            with self.assertRaisesRegex(RuntimeError, 'adoption failed'):
                peer.start_worker(managed=True)
            stop.assert_called_once_with(popen.return_value)
            popen.return_value.stdout.close.assert_called_once()

    def test_unready_supervisor_is_cleaned_up_before_registry_adoption(self):
        registry = types.SimpleNamespace(adopt_local=unittest.mock.Mock())
        modules = {'tools': types.ModuleType('tools'),
                   'tools.process_registry': types.SimpleNamespace(process_registry=registry)}
        with patch.dict(sys.modules, modules), patch.object(peer.subprocess, 'Popen') as popen, \
                patch.object(peer.select, 'select', return_value=([], [], [])), \
                patch.object(peer.lifecycle, 'stop_child') as stop:
            with self.assertRaisesRegex(RuntimeError, 'did not initialize'):
                peer.start_worker(managed=True)
            registry.adopt_local.assert_not_called()
            stop.assert_called_once_with(popen.return_value)
            popen.return_value.stdout.close.assert_called_once()

    def test_gateway_without_process_registry_keeps_detached_recovery(self):
        with patch.dict(sys.modules, {'tools.process_registry': None}), \
                patch.object(peer.subprocess, 'Popen') as popen, patch.object(peer.control, 'spawn') as spawn:
            self.assertEqual(peer.start_worker(managed=True), spawn.return_value)
            popen.assert_not_called()
            spawn.assert_called_once_with([sys.executable, str(RUNTIME), 'supervise'])


if __name__ == '__main__':
    unittest.main()
