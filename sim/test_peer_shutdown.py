"""Real POSIX signals/process trees in temporary homes; no Hermes or network."""
import fcntl
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
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait(timeout=3)
            if child.stderr:
                child.stderr.close()

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
        start = time.monotonic()
        child.send_signal(sig)
        self.assertEqual(child.wait(timeout=limit), 0, child.stderr.read().decode())
        self.assertLess(time.monotonic() - start, limit)

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
        with patch.dict(sys.modules, modules), patch.object(peer.subprocess, 'Popen') as popen:
            self.assertEqual(peer.start_worker(managed=True), popen.return_value.pid)
            self.assertTrue(registry.adopt_local.return_value.persist_on_release)
            self.assertTrue(popen.call_args.kwargs['start_new_session'])
            self.assertEqual(popen.call_args.kwargs['stdout'], subprocess.PIPE)
            registry.adopt_local.assert_called_once_with(popen.return_value, command='SwarmHub peer recovery',
                                                        cwd=None, notify_on_complete=False)
        registry.adopt_local.side_effect = RuntimeError('fixture adoption failed')
        with patch.dict(sys.modules, modules), patch.object(peer.subprocess, 'Popen') as popen, \
                patch.object(peer.lifecycle, 'stop_child') as stop:
            with self.assertRaisesRegex(RuntimeError, 'adoption failed'):
                peer.start_worker(managed=True)
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
