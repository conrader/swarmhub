"""Gateway shutdown escalation against a 1.4.7 supervisor, with real signals and timing.

Hermes 0.22.0 stops a registry process in ProcessTerminationMixin._terminate_host_pid
(tools/process_registry_termination.py): SIGTERM the parent alone, wait one
terminal.daemon_term_grace_seconds window (2 s by default, configurable), SIGTERM
the descendants it snapshotted first, wait a second window, then SIGKILL the parent
and every descendant still alive. The registry here is that sequence without psutil;
nothing is mocked between it and the relay.
"""
import fcntl
import os
from pathlib import Path
import signal
import time
import unittest
from unittest.mock import patch

from test_peer_shutdown import ShutdownHarness, peer

GRACE = 2.0  # Hermes' default daemon_term_grace_seconds.
STOP_BOUND = 2.0 + 1.0 + 1  # swarm_lifecycle: STOP_GRACE + REAP_GRACE, plus resume.


def proc_stat(pid):
    """(state, ppid, start time) from /proc, or None once the process is gone."""
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        return fields[0], int(fields[1]), int(fields[19])
    except (OSError, IndexError, ValueError):
        return None


class Pinned:
    """A PID checked against its kernel start time before every signal, like psutil.Process."""

    def __init__(self, pid, start):
        self.pid, self.start = pid, start

    def alive(self):
        stat = proc_stat(self.pid)
        return stat is not None and stat[2] == self.start and stat[0] != 'Z'

    def signal(self, sig):
        if self.alive():
            try:
                os.kill(self.pid, sig)
            except ProcessLookupError:
                pass


def pinned(pid):
    stat = proc_stat(pid)
    return Pinned(pid, stat[2]) if stat else None


def descendants(pid):
    """Current descendants through ppid links (psutil children(recursive=True))."""
    children = {}
    for entry in Path('/proc').iterdir():
        if entry.name.isdigit() and (stat := proc_stat(int(entry.name))):
            children.setdefault(stat[1], []).append(int(entry.name))
    found, queue = [], [pid]
    while queue:
        for child in children.get(queue.pop(), []):
            found.append(child)
            queue.append(child)
    return [p for p in map(pinned, found) if p]


def hermes_terminate(pid, grace=GRACE):
    """The POSIX branch of _terminate_host_pid. Returns the PIDs it SIGKILLed."""
    parent = pinned(pid)
    snapshot = descendants(pid)
    parent.signal(signal.SIGTERM)

    def wait_for_exit(targets):
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline and any(p.alive() for p in targets):
            time.sleep(.05)

    wait_for_exit([parent])
    remaining = [p for p in snapshot if p.alive()]
    for proc in remaining:
        proc.signal(signal.SIGTERM)
    targets = [parent, *remaining]
    wait_for_exit(targets)
    if parent.alive():
        known = {p.pid for p in targets}
        targets.extend(p for p in descendants(pid) if p.pid not in known)
    killed = [p.pid for p in targets if p.alive()]
    for proc in targets:
        proc.signal(signal.SIGKILL)
    return killed


@unittest.skipUnless(hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'), 'Linux pidfd')
class EscalationTests(ShutdownHarness):
    def shut_down(self, grace):
        """Registry shutdown of the relay while a TERM-ignoring 1.4.7 delivery is in flight."""
        legacy, worker, delivery, runtime = self.legacy_supervisor(LEGACY_DELIVERY_IGNORES_TERM='1')
        managed = self.gateway_supervisor(runtime)
        self.check_process(managed)
        started = time.monotonic()
        killed = hermes_terminate(managed.pid, grace)
        relay = managed.wait(timeout=1)
        deadline = started + STOP_BOUND
        while legacy.poll() is None and time.monotonic() < deadline:
            time.sleep(.02)
        state = proc_stat(legacy.pid)
        self.assertIsNotNone(legacy.poll(), f'legacy supervisor left in state {state and state[0]}')
        # The group KILL that ends the stubborn delivery also reaches the frozen leader.
        self.assertIn(legacy.returncode, (-signal.SIGTERM, -signal.SIGKILL), legacy.stderr.read().decode())
        self.assertFalse(self.live(worker), '1.4.7 worker outlived its supervisor')
        self.assertFalse(self.live(delivery), 'TERM-ignoring delivery outlived its supervisor')
        with (self.folder / 'job-wake.supervisor.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        error = self.folder / 'job-wake.error'
        self.assertNotIn('did not release its lock', error.read_text() if error.exists() else '')
        return relay, killed

    def test_default_escalation_window_needs_no_sigkill(self):
        relay, killed = self.shut_down(GRACE)
        self.assertEqual((relay, killed), (0, []), 'the relay must finish inside the grace windows')

    def test_relay_sigkilled_mid_cleanup_cannot_leave_the_legacy_supervisor_stopped(self):
        # A short configured grace kills the relay while the TERM-ignoring
        # delivery still holds the legacy group in its drain window.
        relay, killed = self.shut_down(.4)
        self.assertEqual(relay, -signal.SIGKILL)
        self.assertNotEqual(killed, [])

    def test_lock_note_waits_for_an_in_flight_legacy_stop(self):
        lifecycle = peer.lifecycle
        path = self.folder / 'job-wake.supervisor.lock'
        notes = []
        with path.open('a') as held, path.open('a+') as lock:
            fcntl.flock(held, fcntl.LOCK_EX)  # Another open file description: still busy.
            for finished in (False, True):
                notes.clear()
                done, writer = os.pipe()
                if finished:
                    os.close(writer)
                with patch.object(lifecycle, 'STOP_GRACE', 0), patch.object(lifecycle, 'REAP_GRACE', 0), \
                        patch.object(lifecycle, 'stop_legacy_supervisor', return_value=done):
                    lifecycle.stop_supervisor_holder(lock, self.folder, 'runtime', lambda _, text: notes.append(text))
                if not finished:
                    os.close(writer)
                with self.subTest(finished=finished):
                    self.assertEqual(bool(notes), finished)
                    with self.assertRaises(OSError):
                        os.fstat(done)  # The relay closes its end.


if __name__ == '__main__':
    unittest.main()
