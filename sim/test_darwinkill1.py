"""Darwinkill1: the Darwin verifier's process group is killed and drained before its leader is reaped.

Order under test (verify_darwin.run_grouped): wait for the leader's exit without reaping it (kqueue EVFILT_PROC on
macOS, waitid WNOWAIT on Linux), SIGKILL the group until it is empty, then reap. Every group signal is sent while
the leader still holds its PID, so the group ID cannot have been reused. Survivors fail closed (77).
The mocked tests and RealGroupTests run on Linux; DarwinNativeTests run only on macOS (sandbox-exec, real kqueue).
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import contextlib
import errno
import io
import os
from pathlib import Path
import runpy
import select
import signal
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

try:
    from sim import test_fixes6 as fixture
except ImportError:
    import test_fixes6 as fixture

DARWIN = runpy.run_path(str(fixture.SANDBOX))['verify_darwin']
SCRIPTS = fixture.SANDBOX.parent
CAN_WAIT_WITHOUT_REAPING = hasattr(select, 'kqueue') or (hasattr(os, 'waitid') and hasattr(os, 'WNOWAIT'))


def alive(pid):
    """Running or stopped; a zombie or a vanished PID is not alive."""
    state = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
    return bool(state) and not state.startswith('Z')


def wait_for_file(path, timeout=10):
    deadline = time.monotonic() + timeout
    while not (path.exists() and path.read_text().strip()):
        if time.monotonic() > deadline:
            raise AssertionError('%s was not written' % path)
        time.sleep(0.01)
    return int(path.read_text().split()[0])


class FakeProcess:
    pid = 4242

    def __init__(self, log, returncode=0):
        self.log, self.exit_status, self.returncode = log, returncode, None

    def wait(self, timeout=None):
        self.log.append(('reap',))
        self.returncode = self.exit_status
        return self.returncode


class Clock:
    def __init__(self, step):
        self.now, self.step = 0.0, step

    def __call__(self):
        self.now += self.step
        return self.now


class OrderingTests(unittest.TestCase):
    """Mocked: which calls happen, in which order, and what status comes back."""

    def run_grouped(self, returncode=0, wait_exit=None, killpg=None, members=None, clock=None):
        log = []
        calls = {'killpg': 0}

        def default_wait(pid):
            log.append(('exited', pid))

        def default_killpg(pgid, signum):  # The group empties after the second kill.
            log.append(('kill', pgid, signum))
            calls['killpg'] += 1
            if calls['killpg'] > 1:
                raise ProcessLookupError()

        def drain(pgid):
            log.append(('drain', pgid))
            return DARWIN.drain(pgid, killpg=killpg or default_killpg, members=lambda pid, timeout: members(pid) if members else [9],
                                clock=clock or Clock(0.001), sleep=lambda _: None)
        stderr = io.StringIO()
        with patch('subprocess.Popen', lambda *a, **k: FakeProcess(log, returncode)), \
             contextlib.redirect_stderr(stderr):
            result = DARWIN.run_grouped(['verifier'], env={}, cwd='/', wait_exit=wait_exit or default_wait, drain_group=drain)
        return result, log, stderr.getvalue()

    def assert_reaped_last(self, log):
        self.assertEqual(log[-1], ('reap',), log)
        self.assertEqual([entry for entry in log if entry == ('reap',)], [('reap',)], 'reaped exactly once')

    def test_group_is_killed_and_drained_after_exit_and_before_the_reap(self):
        result, log, _ = self.run_grouped(returncode=0)
        self.assertEqual(result, 0)
        self.assertEqual(log, [('exited', 4242), ('drain', 4242), ('kill', 4242, signal.SIGKILL),
                               ('kill', 4242, signal.SIGKILL), ('reap',)])

    def test_exit_status_is_preserved_and_signals_map_to_128_plus(self):
        for returncode, expected in ((0, 0), (5, 5), (77, 77), (-signal.SIGKILL, 137), (-signal.SIGTERM, 143)):
            with self.subTest(returncode):
                self.assertEqual(self.run_grouped(returncode=returncode)[0], expected)

    def test_live_survivors_fail_closed_after_the_deadline(self):
        kills = []
        result, log, stderr = self.run_grouped(returncode=0, killpg=lambda pgid, sig: kills.append(sig),
                                               members=lambda _: [31337], clock=Clock(0.3))
        self.assertEqual(result, DARWIN.DESCENDANTS_REMAIN)
        self.assertIn('descendants outlived the verifier', stderr)
        self.assertIn('live pids 31337', stderr)
        self.assertGreater(len(kills), 1, 'SIGKILL is repeated while members remain')
        self.assertEqual(set(kills), {signal.SIGKILL})
        self.assert_reaped_last(log)

    def test_unlistable_members_fail_closed(self):
        result, log, stderr = self.run_grouped(killpg=lambda *_: None, members=lambda _: None, clock=Clock(1.0))
        self.assertEqual(result, DARWIN.DESCENDANTS_REMAIN)
        self.assertIn('could not be listed', stderr)
        self.assert_reaped_last(log)

    def test_members_that_cannot_be_signalled_count_as_present(self):
        def refuse(*_):
            raise PermissionError(errno.EPERM, 'not permitted')
        result, _, _ = self.run_grouped(killpg=refuse, members=lambda _: [77], clock=Clock(1.0))
        self.assertEqual(result, DARWIN.DESCENDANTS_REMAIN)

    def test_a_group_where_only_zombies_answer_is_empty(self):
        # Linux keeps the unreaped leader in the group; the process listing shows no live member.
        result, log, stderr = self.run_grouped(returncode=3, killpg=lambda *_: None, members=lambda _: [], clock=Clock(0.3))
        self.assertEqual((result, stderr), (3, ''))
        self.assert_reaped_last(log)

    def test_launcher_termination_stops_the_wait_and_tears_the_group_down(self):
        # A placeholder handler keeps a regression from terminating the test runner itself.
        previous = signal.signal(signal.SIGTERM, lambda *_: None)
        self.addCleanup(signal.signal, signal.SIGTERM, previous)
        before = {signum: signal.getsignal(signum) for signum in DARWIN.TEARDOWN_SIGNALS}

        def wait_interrupted(pid):
            os.kill(os.getpid(), signal.SIGTERM)
            time.sleep(5)  # The handler interrupts this.
            raise AssertionError('the wait was not interrupted')
        started = time.monotonic()
        result, log, stderr = self.run_grouped(returncode=-signal.SIGKILL, wait_exit=wait_interrupted)
        self.assertLess(time.monotonic() - started, 4)
        self.assertEqual(result, 128 + signal.SIGTERM)
        self.assertIn('interrupted by signal %d' % signal.SIGTERM, stderr)
        self.assertEqual(log[0], ('drain', 4242))
        self.assert_reaped_last(log)
        self.assertEqual({signum: signal.getsignal(signum) for signum in DARWIN.TEARDOWN_SIGNALS}, before)

    def test_teardown_order_holds_when_the_wait_fails(self):
        log = []

        def broken(pid):
            raise OSError('kqueue unavailable')
        with patch('subprocess.Popen', lambda *a, **k: FakeProcess(log)), contextlib.redirect_stderr(io.StringIO()):
            result = DARWIN.run_grouped(['verifier'], env={}, cwd='/', wait_exit=broken,
                                        drain_group=lambda pgid: log.append(('drain', pgid)) or [])
        self.assertEqual(result, 77)
        self.assertEqual(log, [('drain', 4242), ('reap',)])

    def test_a_failed_drain_kills_the_leader_before_the_reap(self):
        log = []

        def broken(pgid):
            raise OSError(errno.EINVAL, 'killpg failed')
        process = FakeProcess(log)
        with patch('subprocess.Popen', lambda *a, **k: process), \
             patch.object(DARWIN.os, 'killpg', lambda pgid, sig: log.append(('kill', pgid, sig))), \
             patch.object(DARWIN.os, 'kill', lambda pid, sig: log.append(('kill-leader',))), \
             contextlib.redirect_stderr(io.StringIO()):
            result = DARWIN.run_grouped(['verifier'], env={}, cwd='/', wait_exit=lambda pid: None, drain_group=broken)
        self.assertEqual(result, 77)
        self.assertEqual(log, [('kill', 4242, signal.SIGKILL), ('kill-leader',), ('reap',)])

    def test_inherited_ignored_sigchld_is_reset_for_the_verifier(self):
        seen = []
        previous = signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        try:
            self.run_grouped(wait_exit=lambda pid: seen.append(signal.getsignal(signal.SIGCHLD)))
            self.assertEqual(seen, [signal.SIG_DFL])
            self.assertEqual(signal.getsignal(signal.SIGCHLD), signal.SIG_IGN)
        finally:
            signal.signal(signal.SIGCHLD, previous)


class FakeQueue:
    def __init__(self, script):
        self.script, self.changes, self.closed = list(script), [], False

    def control(self, changes, count, timeout=None):
        if changes:
            self.changes.extend(changes)
        step = self.script.pop(0)
        if isinstance(step, BaseException):
            raise step
        return step

    def close(self):
        self.closed = True


def fake_kq(script):
    queue = FakeQueue(script)
    module = types.SimpleNamespace(KQ_FILTER_PROC=-5, KQ_EV_ADD=0x1, KQ_EV_ONESHOT=0x10, KQ_EV_ERROR=0x4000,
                                   KQ_NOTE_EXIT=0x80000000, kqueue=lambda: queue,
                                   kevent=lambda ident, filter, flags, fflags: types.SimpleNamespace(
                                       ident=ident, filter=filter, flags=flags, fflags=fflags, data=0))
    return module, queue


def event(ident=4242, flags=0, fflags=0x80000000, data=0):
    return types.SimpleNamespace(ident=ident, filter=-5, flags=flags, fflags=fflags, data=data)


class KqueueWaitTests(unittest.TestCase):
    def test_waits_for_note_exit_on_the_leader_and_closes_the_queue(self):
        kq, queue = fake_kq([[], [event(ident=1, fflags=0x80000000)], [event()]])
        DARWIN.kqueue_wait(4242, kq)
        self.assertTrue(queue.closed)
        self.assertEqual([(c.ident, c.filter, c.flags, c.fflags) for c in queue.changes],
                         [(4242, -5, 0x11, 0x80000000)])
        self.assertEqual(queue.script, [])

    def test_an_already_exited_leader_is_not_waited_for(self):
        kq, queue = fake_kq([ProcessLookupError(errno.ESRCH, 'gone')])
        DARWIN.kqueue_wait(4242, kq)
        self.assertTrue(queue.closed)

    def test_error_events(self):
        kq, queue = fake_kq([[], [event(flags=0x4000, fflags=0, data=errno.ESRCH)]])
        DARWIN.kqueue_wait(4242, kq)
        kq, queue = fake_kq([[], [event(flags=0x4000, fflags=0, data=errno.EINVAL)]])
        with self.assertRaises(OSError):
            DARWIN.kqueue_wait(4242, kq)
        self.assertTrue(queue.closed)

    def test_kqueue_is_preferred_and_a_missing_facility_refuses(self):
        with patch.object(DARWIN, 'select', types.SimpleNamespace(kqueue=object)), \
             patch.object(DARWIN, 'kqueue_wait', lambda pid: 'kqueue'):
            self.assertEqual(DARWIN.wait_exited(1), 'kqueue')
        with patch.object(DARWIN, 'select', types.SimpleNamespace()), patch.object(DARWIN, 'os', types.SimpleNamespace()):
            with self.assertRaises(OSError):
                DARWIN.wait_exited(1)


class MembershipTests(unittest.TestCase):
    def test_zombies_and_other_groups_are_not_live_members(self):
        listing = '   10  4242 S\n   11  4242 Z\n   12   999 R\n   13  4242 R+\n   14 42420 S\n   15  4242 Z+\n'
        run = lambda *a, **k: subprocess.CompletedProcess(a, 0, listing, '')
        self.assertEqual(DARWIN.live_members(4242, run), [10, 13])

    def test_a_failed_listing_is_unknown(self):
        self.assertIsNone(DARWIN.live_members(1, lambda *a, **k: subprocess.CompletedProcess(a, 1, '', 'no')))
        for garbage in ('   10  4242\n', 'PID PGID STAT\n', '  x1  4242 S\n'):
            self.assertIsNone(DARWIN.live_members(4242, lambda *a, **k: subprocess.CompletedProcess(a, 0, garbage, '')))

        def missing(*a, **k):
            raise FileNotFoundError('/bin/ps')
        self.assertIsNone(DARWIN.live_members(1, missing))

    def test_the_real_listing_parses(self):
        self.assertIn(os.getpid(), DARWIN.live_members(os.getpgrp()) or [])


@unittest.skipUnless(CAN_WAIT_WITHOUT_REAPING, 'needs kqueue or waitid(WNOWAIT)')
class RealGroupTests(unittest.TestCase):
    """Real processes on Linux (waitid WNOWAIT) and macOS (kqueue). No sandbox: the teardown alone."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_grouped(self, script, **kwargs):
        return DARWIN.run_grouped(['/bin/sh', '-c', script], env={'PATH': '/usr/bin:/bin'}, cwd=self.root, **kwargs)

    def test_nested_descendants_are_dead_when_it_returns_and_status_is_preserved(self):
        script = ('sleep 59.42 & echo $! > a; (sh -c "sleep 59.43 & echo \\$! > b; wait") & '
                  '(sleep 59.44 & kill -STOP $!; echo $! > c; wait) & '
                  'while [ ! -s b ] || [ ! -s c ]; do sleep 0.01; done; exit 7')
        self.assertEqual(self.run_grouped(script), 7)
        for name in 'abc':
            self.assertFalse(alive(int((self.root / name).read_text())), 'descendant %s outlived verification' % name)

    def test_a_background_writer_stops_before_the_result(self):
        script = '(while :; do echo x >> log; sleep 0.01; done) & while [ ! -s log ]; do sleep 0.01; done; exit 0'
        self.assertEqual(self.run_grouped(script), 0)
        size = (self.root / 'log').stat().st_size
        time.sleep(0.3)
        self.assertEqual((self.root / 'log').stat().st_size, size)

    def test_killed_verifier_reports_128_plus_signal(self):
        self.assertEqual(self.run_grouped('kill -KILL $$'), 137)

    def test_the_leader_is_an_unreaped_zombie_while_its_group_is_signalled(self):
        states = []

        def checked(pgid):
            states.append(subprocess.run(['ps', '-o', 'stat=', '-p', str(pgid)], capture_output=True, text=True).stdout)
            return DARWIN.drain(pgid)
        self.assertEqual(self.run_grouped('sleep 59.45 & exit 2', drain_group=checked), 2)
        self.assertEqual(len(states), 1)
        # Still listed (not reaped) and exited: Z, or E while Darwin finishes the exit.
        self.assertTrue(states[0].strip()[:1] in ('Z', 'E'), states)

    def test_terminating_the_launcher_tears_the_group_down(self):
        launcher = ('import sys; sys.path.insert(0, sys.argv[1]); import verify_darwin; '
                    'sys.exit(verify_darwin.run_grouped(["/bin/sh", "-c", sys.argv[2]], env={"PATH": "/usr/bin:/bin"}, cwd=sys.argv[3]))')
        script = 'sleep 59.46 & echo $! > bg; echo $$ > leader; sleep 59.47'
        process = subprocess.Popen([sys.executable, '-B', '-c', launcher, str(SCRIPTS), script, str(self.root)],
                                   stderr=subprocess.PIPE, text=True)
        try:
            background, leader = wait_for_file(self.root / 'bg'), wait_for_file(self.root / 'leader')
            process.send_signal(signal.SIGTERM)
            _, stderr = process.communicate(timeout=20)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(process.returncode, 128 + signal.SIGTERM, stderr)
        self.assertIn('interrupted by signal %d' % signal.SIGTERM, stderr)
        self.assertFalse(alive(background))
        self.assertFalse(alive(leader))


@unittest.skipUnless(sys.platform == 'darwin', 'native kqueue and Seatbelt teardown require macOS')
class DarwinNativeTests(fixture.SandboxBase):
    def test_kqueue_is_the_wait_used_on_darwin(self):
        with patch.object(DARWIN, 'kqueue_wait', wraps=DARWIN.kqueue_wait) as spy:
            self.assertEqual(DARWIN.run_grouped(['/bin/sh', '-c', 'exit 4'], env={'PATH': '/usr/bin:/bin'}, cwd=self.root), 4)
        self.assertEqual(spy.call_count, 1)

    def test_a_zombie_leader_alone_drains_quickly(self):
        process = subprocess.Popen(['/bin/sh', '-c', 'exit 0'], start_new_session=True)
        DARWIN.kqueue_wait(process.pid)
        try:
            started = time.monotonic()
            self.assertEqual(DARWIN.drain(process.pid), [])
            elapsed = time.monotonic() - started
        finally:
            self.assertEqual(process.wait(), 0)
        self.assertLess(elapsed, 1.0)
        print('darwinkill1: zombie-only drain %.3fs (killpg skips zombies: %s)'
              % (elapsed, elapsed < DARWIN.MEMBERSHIP_INTERVAL), file=sys.stderr)

    def test_sandboxed_verifier_descendants_do_not_outlive_verification(self):
        command = ('(while :; do date >> bg.log; sleep 0.02; done) & echo $! > bg.pid; '
                   '(sleep 59.48 & echo $! > nested.pid; wait) & '
                   'while [ ! -s bg.log ] || [ ! -s nested.pid ]; do sleep 0.01; done; exit 6')
        result = self.run_verify(command)
        self.assertEqual(result.returncode, 6, result.stdout + result.stderr)
        for name in ('bg.pid', 'nested.pid'):
            self.assertFalse(alive(int((self.repo / name).read_text())), name)
        size = (self.repo / 'bg.log').stat().st_size
        time.sleep(0.3)
        self.assertEqual((self.repo / 'bg.log').stat().st_size, size)

    def test_sandboxed_verifier_status_is_preserved(self):
        for command, expected in (('exit 0', 0), ('exit 9', 9), ('kill -KILL $$', 137)):
            with self.subTest(command):
                result = self.run_verify(command)
                self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_terminated_launcher_kills_the_sandboxed_group(self):
        env = dict(os.environ, SWARMHUB_VERIFY_NAMESPACES=self.namespaces)
        command = 'sleep 59.49 & echo $! > bg.pid; sleep 59.5'
        process = subprocess.Popen([sys.executable, '-B', str(fixture.SANDBOX), str(self.repo), command],
                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            background = wait_for_file(self.repo / 'bg.pid', timeout=30)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=20)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        self.assertEqual(process.returncode, 128 + signal.SIGTERM, stdout + stderr)
        self.assertFalse(alive(background))


if __name__ == '__main__':
    unittest.main()
