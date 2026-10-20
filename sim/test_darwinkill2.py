"""Darwinkill2: fake-clock bounds for drain, ps timeout cleanup, and an unreapable leader.

All tests run on Linux and stock macOS Python 3.9; native kqueue/Seatbelt coverage stays in test_darwinkill1.
No providers, outbound messages, or real signals to fixture PIDs.
"""
import ast
import contextlib
import inspect
import io
import signal
import subprocess
import sys
import unittest
from unittest.mock import patch

try:
    from sim.test_darwinkill1 import DARWIN
except ImportError:
    from test_darwinkill1 import DARWIN


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        if seconds < 0:
            raise AssertionError('negative timeout')
        self.now += seconds


class BoundTests(unittest.TestCase):
    def test_signals_at_wait_handler_boundaries_cannot_escape_or_lose_ownership(self):
        # Trace before the first statement as well as inside str(exc): merely moving
        # waiting=False into each handler leaves its entry bytecodes interruptible.
        source = ast.parse(inspect.getsource(DARWIN.run_grouped))
        wait_try = next(node for node in ast.walk(source) if isinstance(node, ast.Try)
                        and any(isinstance(handler.type, ast.Name) and handler.type.id == 'ChildProcessError'
                                for handler in node.handlers))
        for error_type in (OSError, ChildProcessError):
            handler_name = 'ChildProcessError' if error_type is ChildProcessError else 'Exception'
            handler = next(handler for handler in wait_try.handlers if handler.type.id == handler_name)
            for boundary in ('dispatch', 'entry', 'format', 'finally'):
                for signum in DARWIN.TEARDOWN_SIGNALS:
                    with self.subTest(error=error_type.__name__, boundary=boundary, signum=signum):
                        clock, log, delivered, stderr = Clock(), [], [], io.StringIO()
                        signals = (*DARWIN.TEARDOWN_SIGNALS, signal.SIGCHLD)
                        before = {sig: signal.getsignal(sig) for sig in signals}

                        def interrupt():
                            delivered.append(signum)
                            signal.getsignal(signum)(signum, None)

                        class WaitError(error_type):
                            def __str__(self):
                                if boundary == 'format':
                                    interrupt()
                                return 'wait failed'

                        class Leader:
                            pid, returncode = 4242, None

                            def wait(self, timeout=None):
                                log.append(('reap', timeout))
                                clock.sleep(timeout)
                                raise subprocess.TimeoutExpired('verifier', timeout)

                        def wait_exit(pid):
                            raise WaitError()

                        def killpg(pid, sig):
                            self.assertFalse(any(item[0] == 'reap' for item in log))
                            log.append(('kill', pid, sig))

                        def drain(pid):
                            return DARWIN.drain(pid, killpg=killpg, members=lambda pid, timeout: [],
                                                clock=clock, sleep=clock.sleep)

                        target = (handler if boundary == 'dispatch' else
                                  handler.body[0] if boundary == 'entry' else wait_try.finalbody[0]).lineno
                        target += DARWIN.run_grouped.__code__.co_firstlineno - 1

                        def trace(frame, event, arg):
                            if (boundary != 'format' and not delivered and event == 'line'
                                    and frame.f_code is DARWIN.run_grouped.__code__ and frame.f_lineno == target):
                                interrupt()
                            return trace

                        previous_trace = sys.gettrace()
                        with patch.object(DARWIN.subprocess, 'Popen', return_value=Leader()), \
                             patch.object(DARWIN.os, 'killpg', killpg), \
                             patch.object(DARWIN.os, 'kill', lambda *args: log.append(('kill-leader',))), \
                             contextlib.redirect_stderr(stderr):
                            try:
                                sys.settrace(trace)
                                result = DARWIN.run_grouped(['verifier'], {}, '/', wait_exit=wait_exit,
                                                            drain_group=drain, clock=clock)
                            finally:
                                sys.settrace(previous_trace)
                                self.assertEqual({sig: signal.getsignal(sig) for sig in signals}, before)
                        self.assertEqual(delivered, [signum])
                        self.assertEqual(result, 77)
                        self.assertIn('wait failed', stderr.getvalue())
                        self.assertEqual([item for item in log if item[0] == 'reap'], [('reap', 0.25)])
                        self.assertEqual(log[-1], ('reap', 0.25))
                        self.assertEqual(any(item[0] == 'kill' for item in log), error_type is OSError)
                        self.assertLessEqual(clock(), 5.25)

    def test_launcher_signal_interrupts_wait_even_in_a_callers_exception_handler(self):
        for signum in DARWIN.TEARDOWN_SIGNALS:
            with self.subTest(signum=signum):
                log, stderr = [], io.StringIO()

                class Leader:
                    pid, returncode = 4242, None

                    def wait(self, timeout=None):
                        log.append(('reap', timeout))
                        return -signal.SIGKILL

                def wait_exit(pid):
                    signal.getsignal(signum)(signum, None)
                    self.fail('launcher signal did not interrupt the wait')

                with patch.object(DARWIN.subprocess, 'Popen', return_value=Leader()), \
                     contextlib.redirect_stderr(stderr):
                    try:
                        raise ValueError('unrelated caller error')
                    except ValueError:
                        result = DARWIN.run_grouped(['verifier'], {}, '/', wait_exit=wait_exit,
                                                    drain_group=lambda pid: log.append(('drain',)) or [], clock=Clock())
                self.assertEqual(result, 128 + signum)
                self.assertEqual(log, [('drain',), ('reap', 0.25)])

    def test_reap_uses_only_the_budget_left_after_a_delayed_drain(self):
        for drain_time in (5.2, 5.25, 5.3):
            with self.subTest(drain_time=drain_time):
                clock, waits, stderr = Clock(), [], io.StringIO()

                class Leader:
                    pid, returncode = 4242, None

                    def wait(self, timeout=None):
                        waits.append(timeout)
                        clock.sleep(timeout)
                        raise subprocess.TimeoutExpired('verifier', timeout)

                def drain(pid):
                    clock.sleep(drain_time)  # Simulated scheduling delay consumes the shared budget.
                    return []

                with patch.object(DARWIN.subprocess, 'Popen', return_value=Leader()), \
                     contextlib.redirect_stderr(stderr):
                    result = DARWIN.run_grouped(['verifier'], {}, '/', wait_exit=lambda pid: None,
                                                drain_group=drain, clock=clock)
                self.assertEqual(result, 77)
                self.assertAlmostEqual(waits[0], max(0, 5.25 - drain_time))
                self.assertEqual(clock(), max(5.25, drain_time))
                self.assertIn('leader pid 4242', stderr.getvalue())

    def test_successful_teardown_preserves_all_launcher_signal_statuses(self):
        for signum in DARWIN.TEARDOWN_SIGNALS:
            for during_drain in (False, True):
                with self.subTest(signum=signum, during_drain=during_drain):
                    clock, stderr = Clock(), io.StringIO()
                    before = {sig: signal.getsignal(sig) for sig in DARWIN.TEARDOWN_SIGNALS}

                    class Leader:
                        pid, returncode = 4242, None

                        def wait(self, timeout=None):
                            self_test.assertEqual(timeout, 0.25)
                            return -signal.SIGKILL

                    def wait_exit(pid):
                        if not during_drain:
                            signal.getsignal(signum)(signum, None)

                    def drain(pid):
                        if during_drain:
                            signal.getsignal(signum)(signum, None)
                            signal.getsignal(signum)(signum, None)  # Later signals cannot abort teardown.
                        clock.sleep(0.1)
                        return []

                    self_test = self
                    with patch.object(DARWIN.subprocess, 'Popen', return_value=Leader()), \
                         contextlib.redirect_stderr(stderr):
                        result = DARWIN.run_grouped(['verifier'], {}, '/', wait_exit=wait_exit,
                                                    drain_group=drain, clock=clock)
                    self.assertEqual(result, 128 + signum)
                    self.assertEqual({sig: signal.getsignal(sig) for sig in before}, before)

    def exercise(self, trigger='normal', stuck=True, slow_ps=False, broken_drain=False):
        clock, log, stderr = Clock(), [], io.StringIO()

        class Leader:
            pid = 4242
            returncode = None

            def wait(self, timeout=None):
                log.append(('reap', timeout))
                if timeout is None:
                    raise AssertionError('unbounded leader reap')
                if stuck:
                    clock.sleep(timeout)
                    raise subprocess.TimeoutExpired('verifier', timeout)
                self.returncode = -signal.SIGKILL if trigger != 'normal' else 9
                return self.returncode

        def wait_exit(pid):
            if trigger == 'kqueue':
                raise OSError('kqueue failed')
            if trigger == 'reaped':
                raise ChildProcessError('leader was already reaped')
            if trigger == 'popen-reaped':
                Leader.returncode = 9
            if trigger in DARWIN.TEARDOWN_SIGNALS:
                signal.getsignal(trigger)(trigger, None)

        def killpg(pid, sig):
            self.assertFalse(any(item[0] == 'reap' for item in log), 'group signalled after reap')
            log.append(('killpg', pid, sig))

        def listing(argv, **kwargs):
            timeout = kwargs['timeout']
            self.assertGreater(timeout, 0)
            self.assertLessEqual(clock() + timeout, DARWIN.DRAIN_SECONDS)
            log.append(('ps', timeout))
            if slow_ps:
                clock.sleep(timeout)
                raise subprocess.TimeoutExpired(argv, timeout)
            return subprocess.CompletedProcess(argv, 0, '4242 4242 S\n31337 4242 S\n', '')

        def drain(pid):
            if broken_drain:
                raise OSError('drain failed')
            return DARWIN.drain(pid, killpg=killpg, clock=clock, sleep=clock.sleep,
                                members=lambda pgid, timeout: DARWIN.live_members(pgid, run=listing, timeout=timeout))

        with patch.object(DARWIN.subprocess, 'Popen', return_value=Leader()), \
             patch.object(DARWIN.os, 'killpg', killpg), \
             patch.object(DARWIN.os, 'kill', lambda *a: log.append(('kill-leader',))), \
             contextlib.redirect_stderr(stderr):
            status = DARWIN.run_grouped(['verifier'], {}, '/', wait_exit=wait_exit, drain_group=drain, clock=clock)
        self.assertLessEqual(clock(), 5.25)
        self.assertEqual(status, 77)
        self.assertIn('process group 4242', stderr.getvalue())
        self.assertEqual(log[-1][0], 'reap')
        return clock(), log, stderr.getvalue()

    def test_unreapable_leader_is_bounded_on_every_entry_path(self):
        for trigger in ('normal', 'killed', 'kqueue', *DARWIN.TEARDOWN_SIGNALS):
            with self.subTest(trigger=trigger):
                elapsed, _, stderr = self.exercise(trigger)
                self.assertEqual(elapsed, 5.25)
                self.assertIn('leader pid 4242 could not be reaped', stderr)
                self.assertIn('live pids 4242 31337', stderr)

    def test_hanging_ps_and_unreapable_leader_share_the_total_bound(self):
        for trigger in ('normal', 'killed', 'kqueue', *DARWIN.TEARDOWN_SIGNALS):
            with self.subTest(trigger=trigger):
                elapsed, log, stderr = self.exercise(trigger, slow_ps=True)
                self.assertEqual(elapsed, 5.25)
                self.assertEqual(len([item for item in log if item[0] == 'ps']), 1)
                self.assertIn('could not be listed', stderr)

    def test_hanging_ps_refuses_even_if_leader_reaps(self):
        elapsed, _, stderr = self.exercise(stuck=False, slow_ps=True)
        self.assertEqual(elapsed, 5.0)
        self.assertNotIn('could not be reaped', stderr)

    def test_failed_drain_has_only_the_fixed_reap_budget(self):
        elapsed, log, stderr = self.exercise('kqueue', broken_drain=True)
        self.assertEqual(elapsed, 0.25)
        self.assertEqual([item[0] for item in log], ['killpg', 'kill-leader', 'reap'])
        self.assertIn('drain failed', stderr)

    def test_already_reaped_leader_is_never_signalled(self):
        for trigger in ('reaped', 'popen-reaped'):
            with self.subTest(trigger=trigger):
                _, log, stderr = self.exercise(trigger, stuck=False)
                self.assertEqual([item[0] for item in log], ['reap'])
                self.assertIn('already reaped', stderr)

    def test_slow_listings_use_remaining_budget_and_do_not_restart_it(self):
        clock, budgets = Clock(), []

        def members(pid, timeout):
            budgets.append(timeout)
            self.assertAlmostEqual(clock() + timeout, 5.0)
            clock.sleep(min(2, timeout))
            return [31337]
        result = DARWIN.drain(4242, killpg=lambda *a: None, members=members, clock=clock, sleep=clock.sleep)
        self.assertEqual(result, [31337])
        self.assertEqual(clock(), 5.0)
        self.assertEqual(len(budgets), 3)
        self.assertTrue(all(a > b for a, b in zip(budgets, budgets[1:])))

    def test_empty_listing_at_deadline_fails_closed(self):
        clock = Clock()

        def members(pid, timeout):
            clock.sleep(timeout)
            return []
        self.assertIsNone(DARWIN.drain(4242, killpg=lambda *a: None, members=members,
                                      clock=clock, sleep=clock.sleep))
        self.assertEqual(clock(), 5.0)

    def test_no_listing_or_signal_starts_after_deadline(self):
        clock = Clock()
        calls = []
        self.assertIsNone(DARWIN.drain(4242, limit=0, killpg=lambda *a: calls.append(a),
                                      members=lambda *a, **k: calls.append(a), clock=clock, sleep=clock.sleep))
        self.assertEqual(calls, [])

    def test_sleep_is_capped_to_remaining_budget(self):
        clock = Clock()
        self.assertIsNone(DARWIN.drain(4242, limit=0.013, killpg=lambda *a: None,
                                      clock=clock, sleep=clock.sleep))
        self.assertAlmostEqual(clock(), 0.013)


class ListingCleanupTests(unittest.TestCase):
    def test_ps_that_survives_kill_never_causes_a_blocking_cleanup_wait(self):
        clock, log = Clock(), []

        class StuckPS:
            returncode = None
            stdout = io.StringIO()

            def communicate(self, timeout=None):
                self_test.assertIsNotNone(timeout)
                log.append(('communicate', timeout))
                clock.sleep(timeout)
                raise subprocess.TimeoutExpired('ps', timeout)

            def kill(self):
                log.append(('kill',))

            def wait(self, timeout=None):
                self_test.assertEqual(timeout, 0, 'ps cleanup must be nonblocking')
                log.append(('wait', timeout))
                raise subprocess.TimeoutExpired('ps', timeout)

            def __enter__(self):
                raise AssertionError('Popen context manager has an unbounded __exit__')

        self_test, process = self, StuckPS()

        def spawn(*args, **kwargs):
            clock.sleep(0.1)  # Even helper startup comes out of the supplied budget.
            return process

        with patch.object(DARWIN.time, 'monotonic', clock), patch.object(DARWIN.subprocess, 'Popen', spawn):
            self.assertIsNone(DARWIN.live_members(4242, timeout=1.5))
        self.assertEqual(clock(), 1.5)
        self.assertEqual(log, [('communicate', 1.4), ('kill',), ('wait', 0)])
        self.assertTrue(process.stdout.closed)


if __name__ == '__main__':
    unittest.main()
