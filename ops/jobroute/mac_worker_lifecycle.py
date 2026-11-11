"""Finite, non-reaping supervision. Only in-memory, unreaped children authorize signals."""
import errno
import os
import select
import signal
import subprocess
import tempfile
import time

POLL = .05
LIVE, DRAINED, UNKNOWN = 'live', 'drained', 'unknown'


class Stops:
    def __enter__(self):
        self.first = None
        self.previous = {signal.SIGCHLD: signal.signal(signal.SIGCHLD, signal.SIG_DFL)}
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            self.previous[sig] = signal.signal(sig, self.latch)
        return self

    def latch(self, sig, frame=None):
        if self.first is None:
            self.first = sig

    def __exit__(self, *args):
        for sig, handler in self.previous.items():
            signal.signal(sig, handler)


def supported():
    if not (hasattr(select, 'kqueue') or (hasattr(os, 'waitid') and hasattr(os, 'WNOWAIT'))):
        raise OSError('non-reaping monitor unavailable')


class Child:
    def __init__(self, proc):
        # No registration can fail between Popen and saving the ownership anchor.
        self.proc, self.owned, self.drained, self.reaped = proc, True, False, False
        self.queue = None
        self.reasons = set()

    def exited(self):
        if not self.owned or self.proc.returncode is not None:
            self.owned = False
            raise ChildProcessError('child ownership lost')
        try:
            if hasattr(select, 'kqueue'):
                if self.queue is None:
                    self.queue = select.kqueue()
                    try:
                        self.queue.control([select.kevent(self.proc.pid, filter=select.KQ_FILTER_PROC,
                            flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT, fflags=select.KQ_NOTE_EXIT)], 0, 0)
                    except ProcessLookupError:
                        self.exit_seen = True
                        return True
                events = self.queue.control(None, 1, 0)
                for event in events:
                    if event.flags & select.KQ_EV_ERROR:
                        raise OSError(event.data, 'monitor failed')
                    if event.fflags & select.KQ_NOTE_EXIT:
                        self.exit_seen = True
                return getattr(self, 'exit_seen', False)
            return os.waitid(os.P_PID, self.proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None
        except ChildProcessError:
            self.owned = False
            raise

    def send(self, sig):
        if self.drained or self.reaped or not self.owned:
            return False
        try:
            self.exited()  # ECHILD revokes authority before the syscall.
        except ChildProcessError:
            return False
        except Exception:
            # A monitor registration failure does not consume our direct child's identity.
            # No other reaper exists in this scope; cleanup still owns the unreaped child.
            self.reasons.add('child_monitor_failed')
        if not self.owned:
            return False
        try:
            os.killpg(self.proc.pid, sig)
            return True
        except ProcessLookupError:
            return True  # absence of a group is not itself drain proof
        except Exception:
            self.reasons.add('owned_signal_failed')
            return False

    def reap(self, deadline):
        if not self.drained or not self.owned:
            return False
        try:
            self.proc.wait(timeout=max(0, deadline - time.monotonic()))
            self.reaped = True
            self.owned = False
            if self.queue is not None:
                self.queue.close()
            return True
        except Exception:
            return False


def membership(pgid, deadline, reasons=None):
    """Bounded ps capture and teardown; UNKNOWN is never permission to release a guardian."""
    def unknown(kind):
        if reasons is not None:
            reasons.update(('process_inspection_failed', 'inspection_' + kind))
        return UNKNOWN
    left = min(1, deadline - time.monotonic())
    if left <= 0:
        return unknown('timeout')
    proc = None
    try:
        # A file avoids pipe deadlocks and unbounded communicate() allocation.
        with tempfile.TemporaryFile() as output:
            proc = subprocess.Popen(['/bin/ps', '-axo', 'pgid=,stat='], stdout=output,
                                    stderr=subprocess.DEVNULL, close_fds=True)
            proc.wait(timeout=left)
            if proc.returncode:
                return unknown('nonzero')
            output.seek(0)
            raw = output.read(1048577)
            if len(raw) > 1048576:
                return unknown('malformed')
            found = False
            for row in raw.decode('ascii').splitlines():
                fields = row.split()
                if len(fields) != 2 or not fields[0].isdigit() or not fields[1].isalpha() and not all(
                        c.isalpha() or c in '<+NsLl' for c in fields[1]):
                    return unknown('malformed')
                if int(fields[0]) == pgid and not fields[1].startswith('Z'):
                    found = True
            return LIVE if found else DRAINED
    except subprocess.TimeoutExpired:
        return unknown('timeout')
    except Exception:
        return unknown('unavailable')
    finally:
        if proc is not None and proc.returncode is None:
            try:
                # Exact helper PID, never a process group. No blocking wait after expiry.
                os.kill(proc.pid, signal.SIGKILL)
                proc.wait(timeout=0)
            except Exception:
                pass


def pause(deadline):
    left = max(0, deadline - time.monotonic())
    if left:
        time.sleep(min(POLL, left))


def drain(child, grace, kill_limit=5, reap_limit=5):
    """One bounded attempt. Failed attempts retain ownership; never signal after drain/reap."""
    try:
        if child.drained:
            return child.reaped or child.reap(time.monotonic() + reap_limit)
        if child.proc.returncode is not None:
            child.owned = False
        if not child.owned:
            return False
        term_end = time.monotonic() + grace
        end = term_end + kill_limit
        # Normal exit still has to account for descendants, before reaping the leader.
        if membership(child.proc.pid, end, child.reasons) == DRAINED:
            child.drained = True
        else:
            child.send(signal.SIGTERM)
            # Inspection is charged to the shared drain budget, never the TERM grace.
            term_end = time.monotonic() + grace
            next_kill = term_end
            while time.monotonic() < end:
                now = time.monotonic()
                if now >= next_kill:
                    child.send(signal.SIGKILL)
                    next_kill = now + .1
                if membership(child.proc.pid, min(end, term_end) if now < term_end else end, child.reasons) == DRAINED:
                    child.drained = True
                    break
                pause(end)
        return child.drained and child.reap(time.monotonic() + reap_limit)
    except Exception:
        # A helper failure does not remove the ownership anchor or the guardian loop.
        return False


class Relay:
    """Runner descriptors are private files, so surviving guardians cannot hold SSH EOF open."""
    def __init__(self, directory_fd):
        self.files, self.offsets, self.flags = [], [0, 0], {}
        self.failed = False
        self.defer_stdout = False
        for name in ('stdout.log', 'stderr.log'):
            fd = os.open(name, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                         0o600, dir_fd=directory_fd)
            self.files.append(os.fdopen(fd, 'w+b', buffering=0))

    def pump(self, deadline):
        import fcntl
        for i, stream in enumerate(self.files):
            if i == 0 and self.defer_stdout:
                continue
            target = i + 1
            try:
                if target not in self.flags:
                    self.flags[target] = fcntl.fcntl(target, fcntl.F_GETFL)
                    fcntl.fcntl(target, fcntl.F_SETFL, self.flags[target] | os.O_NONBLOCK)
                while time.monotonic() < deadline:
                    data = os.pread(stream.fileno(), 16384, self.offsets[i])
                    if not data:
                        break
                    written = os.write(target, data)
                    self.offsets[i] += written
                    if written == 0:
                        raise OSError('output blocked')
            except Exception:
                self.failed = True

    def queue_ready(self):
        import json
        raw = os.pread(self.files[0].fileno(), 16385, 0)
        if len(raw) > 16384 or not isinstance(json.loads(raw), dict):
            raise ValueError('invalid queue snapshot')
        self.defer_stdout = False

    def close(self):
        import fcntl
        for fd, flags in self.flags.items():
            try:
                fcntl.fcntl(fd, fcntl.F_SETFL, flags)
            except OSError:
                pass
        for stream in self.files:
            stream.close()
