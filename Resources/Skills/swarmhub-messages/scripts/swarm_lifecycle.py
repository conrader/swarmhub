"""POSIX recovery-process shutdown. Signal handlers belong only to CLI processes."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import threading
import time
import uuid

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


def request_stop():
    """Cooperative shutdown of this instance; never signal a PID from disk."""
    if _stopped is not None:
        _stopped.set()


def wait(delay):
    if _stopped is None:
        time.sleep(delay)
    else:
        _stopped.wait(delay)


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


def request_supervisor_stop(lock, folder):
    """Address the lock holder's instance, never its possibly recycled PID.

    Only a supervisor holding this flock publishes an instance token and watches
    its matching request. Stale metadata (including pre-token PID files) cannot
    authorize an OS signal. Read through the same descriptor we tried to lock so
    replacing the lock pathname cannot redirect a request to another instance.
    """
    try:
        lock.seek(0)
        owner = json.loads(lock.read())
        token = owner["instance"]
        if not isinstance(token, str) or re.fullmatch(r"[0-9a-f]{32}", token) is None:
            return False
        request = folder / ("job-wake.supervisor.stop-" + token)
        try:
            fd = os.open(request, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            os.close(fd)
        except FileExistsError:
            pass
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False  # Owner not published yet, already stopping, or not one of ours.


def stop_legacy_supervisor(lock, folder, runtime):
    """Linux upgrade path for an already-running supervisor without a token.

    Pin the process with pidfd BEFORE checking its identity. Even if it exits and
    its PID is reused during these checks, a signal can reach only the pinned
    instance or the group it still leads. Require our exact script/operation,
    HOME, uid, private group and kernel proof that this process holds this
    particular flock. Other platforms use only the cooperative protocol; never
    fall back to kill(pid).
    """
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        return False
    try:
        pid = int((folder / "job-wake.supervisor.pid").read_text())
        if pid <= 1 or pid == os.getpid():
            return False
        fd = os.pidfd_open(pid)
    except (OSError, ValueError):
        return False
    try:
        proc = Path("/proc") / str(pid)
        argv = (proc / "cmdline").read_bytes().split(b"\0")[:-1]
        if len(argv) != 3 or argv[1:] != [os.fsencode(runtime), b"supervise"]:
            return False
        if not os.path.samefile(proc / "exe", sys.executable) or proc.stat().st_uid != os.getuid():
            return False
        if os.fsencode("HOME=" + str(Path.home())) not in (proc / "environ").read_bytes().split(b"\0"):
            return False
        inspected = subprocess.run(["ps", "-p", str(pid), "-o", "pid=,pgid=,cmd="],
                                   capture_output=True, text=True, timeout=1)
        fields = inspected.stdout.split(None, 2)
        if inspected.returncode or len(fields) != 3 or fields[:2] != [str(pid), str(pid)]:
            return False
        info = os.fstat(lock.fileno())
        inode = (os.major(info.st_dev), os.minor(info.st_dev), info.st_ino)
        for line in Path("/proc/locks").read_text().splitlines():
            row = line.split()
            if len(row) < 6 or row[1:5] != ["FLOCK", "ADVISORY", "WRITE", str(pid)]:
                continue
            major, minor, number = row[5].split(":")
            if (int(major, 16), int(minor, 16), int(number)) == inode:
                stop_legacy_group(fd, pid)
                return True
    except (OSError, ValueError, subprocess.SubprocessError):
        pass
    finally:
        os.close(fd)
    return False


def exited(fd):
    return bool(select.select([fd], [], [], 0)[0])


def group_members(pgid, leader):
    """Live processes in this group other than its leader; zombies do no work."""
    members = []
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit() or int(entry.name) == leader:
            continue
        try:
            fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            continue  # Exited while we listed /proc.
        if fields[0] != "Z" and int(fields[2]) == pgid:
            members.append(int(entry.name))
    return members


def stop_legacy_group(fd, pid):
    """Stop a verified pre-token supervisor together with its worker and deliveries.

    1.4.7 installs no handlers, so TERM kills only the supervisor. Its worker
    (subprocess.call) and their deliveries share the supervisor's private group
    and would keep running after the lock is released. Freeze the pinned leader
    first: a stopped process cannot exit by itself, and while it exists its
    number cannot be reused, so killpg(pid) reaches exactly its own tree. A
    group signal also reaches a child that is being forked at that moment.
    """
    if pid <= 1:
        return
    signal.pidfd_send_signal(fd, signal.SIGSTOP)
    try:
        deadline = time.monotonic() + REAP_GRACE
        while not exited(fd):
            if (Path("/proc") / str(pid) / "stat").read_text().rsplit(")", 1)[1].split()[0] == "T":
                break
            if time.monotonic() >= deadline:
                return  # Not frozen: never signal its group by number.
            time.sleep(.01)
        for sig, grace in ((signal.SIGTERM, STOP_GRACE), (signal.SIGKILL, REAP_GRACE)):
            if exited(fd):
                return  # Pinned leader gone: its number no longer names this group.
            os.killpg(pid, sig)
            deadline = time.monotonic() + grace
            while group_members(pid, pid) and time.monotonic() < deadline:
                time.sleep(.02)
            if not group_members(pid, pid):
                return
    finally:
        # The leader holds TERM pending while stopped; it exits once continued.
        for sig in (signal.SIGTERM, signal.SIGCONT):
            try:
                signal.pidfd_send_signal(fd, sig)
            except ProcessLookupError:
                pass


def stop_supervisor_holder(lock, folder, runtime, note):
    """Relay gateway shutdown until the actual holder has drained and unlocked."""
    deadline = time.monotonic() + STOP_GRACE + REAP_GRACE + 1
    legacy_sent = False
    while folder.exists():
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return  # No holder remains. Do not launch recovery during shutdown.
        except BlockingIOError:
            if not request_supervisor_stop(lock, folder) and not legacy_sent:
                legacy_sent = stop_legacy_supervisor(lock, folder, runtime)
        if time.monotonic() >= deadline:
            note(folder, "Recovery supervisor did not release its lock after shutdown request")
            return  # Never escalate using an unverified/stale PID.
        time.sleep(.02)


@contextmanager
def supervisor_identity(lock, folder):
    """A fresh capability for this lock tenure; no PID can inherit it by reuse."""
    token = uuid.uuid4().hex
    request = folder / ("job-wake.supervisor.stop-" + token)
    lock.seek(0)
    lock.truncate()
    json.dump({"pid": os.getpid(), "instance": token}, lock)
    lock.flush()
    done = threading.Event()

    def watch():
        while not done.wait(.02):
            if request.exists():
                request_stop()
                return

    watcher = threading.Thread(target=watch, daemon=True)
    watcher.start()
    try:
        yield
    finally:
        done.set()
        watcher.join()
        request.unlink(missing_ok=True)
