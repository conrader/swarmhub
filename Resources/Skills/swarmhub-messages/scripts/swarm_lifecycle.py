"""POSIX recovery-process shutdown. Signal handlers belong only to CLI processes."""
from contextlib import contextmanager
import os
import signal
import subprocess
import threading
import time

STOP_GRACE = 2.0
REAP_GRACE = 1.0
_stopped = None
_signum = signal.SIGTERM
_children = {}
_deferred = 0


class Stopping(BaseException):
    # Deliberately bypass guarded() and malformed-record retry handlers.
    def __init__(self, signum):
        self.signum = signum


@contextmanager
def termination(forward_group=False):
    """Interrupt waits/backoff, stop both worker loops and restore caller handlers."""
    global _stopped, _signum
    stopped = threading.Event()
    previous_stop, previous_signal = _stopped, _signum
    _stopped, _signum = stopped, signal.SIGTERM
    signals = (signal.SIGTERM, signal.SIGINT)
    previous = {sig: signal.getsignal(sig) for sig in signals}

    def stop(signum, frame):
        global _signum
        _signum = signum
        stopped.set()
        # Repeated signals must not interrupt bounded cleanup. Ignore ourselves
        # when forwarding to the worker's private group (including delivery I/O).
        for sig in signals:
            signal.signal(sig, signal.SIG_IGN)
        for child in _children.copy().values():
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass
        if forward_group and os.getpgrp() == os.getpid():
            os.killpg(os.getpgrp(), signum)
        if not _deferred:
            raise Stopping(signum)

    for sig in signals:
        signal.signal(sig, stop)
    try:
        yield stopped
    except Stopping:
        pass
    finally:
        stopped.set()
        _stopped, _signum = previous_stop, previous_signal
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def is_stopping():
    return _stopped is not None and _stopped.is_set()


@contextmanager
def deferred():
    """A signal records shutdown during spawn/reap; polling finishes cleanup.

    Raising between Popen and its finally block, or inside that cleanup, could
    strand a child. Only the main thread receives Python signal callbacks.
    """
    global _deferred
    main = threading.current_thread() is threading.main_thread()
    if main:
        _deferred += 1
    try:
        yield
    finally:
        if main:
            _deferred -= 1


def stop_child(child, signum=signal.SIGTERM, grace=STOP_GRACE):
    """Signal a private child group, bound its drain, kill survivors, reap the child.

    The group can outlive its leader, so wait for it as well as the Popen handle.
    Only children launched with start_new_session=True may be passed here.
    """
    with deferred():
        def send(sig):
            try:
                os.killpg(child.pid, sig)
                return True
            except ProcessLookupError:
                return False

        deadline = time.monotonic() + grace
        send(signum)
        while True:
            child.poll()  # Reap promptly so our own zombie cannot keep the group alive.
            if not send(0):
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                send(signal.SIGKILL)
                break
            time.sleep(min(.02, remaining))
        child.wait(timeout=REAP_GRACE)


def run_child(argv):
    """Wait for a worker and always clean its group before allowing a restart."""
    with deferred():
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        try:
            while not is_stopping():
                try:
                    return child.wait(timeout=.1)
                except subprocess.TimeoutExpired:
                    pass
            return child.poll()
        finally:
            # Give the worker time to drain its own delivery groups first.
            stop_child(child, _signum, grace=STOP_GRACE + REAP_GRACE)


def call(argv, timeout):
    """Delivery I/O: allow TERM/INT to drain before subprocess.run could kill it.

    Both worker threads share the stop event. Each delivery owns a private group
    so a slow shell/curl tree can be stopped even after its shell has exited.
    Other CLI callers retain subprocess.run's existing behavior.
    """
    with deferred():
        stopped = _stopped
        if stopped is None:
            return subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL, timeout=timeout).returncode
        if stopped.is_set():
            return 128 + _signum  # Retry after shutdown; 125 cancels the durable delivery.
        child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        _children[child.pid] = child
        deadline = time.monotonic() + timeout
        try:
            while not stopped.is_set():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(argv, timeout)
                try:
                    return child.wait(timeout=min(.1, remaining))
                except subprocess.TimeoutExpired:
                    pass
            return 128 + _signum
        finally:
            try:
                stop_child(child, _signum)
            finally:
                _children.pop(child.pid, None)
