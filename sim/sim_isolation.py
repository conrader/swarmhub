"""Fail closed unless the sim harness runs isolated; guard every signal it sends.

2026-10-21: a Swift test on the Mac started this harness outside the safe namespace, and on ovh an earlier code-job
kill_tree() with a root of 0/1/empty sent SIGTERM and SIGKILL to every process of the user. Importing this module
(every sim entry point and test module does so first) therefore:

- Linux: exits 78 unless this process is inside a PID namespace other than the host's initial one, with its own
  /proc mounted, and pid 1 of that namespace is one of its ancestors. That is what
  `sudo -u sbtest -- unshare -r -p -f --mount-proc ...` gives; nothing in the environment can claim it.
  A signal from inside such a namespace cannot reach a process outside it.
- macOS: there are no PID namespaces, so the harness runs in signal-guarded mode only (see ISOLATION.md).
- Anything else: exits 78.

On both platforms os.kill/os.killpg (and so Popen.send_signal/terminate/kill), and signal.pidfd_send_signal where
present, are wrapped: pid/group <= 1 (except this process itself), negative, non-int or empty targets are refused, as
is this process's group (unless it leads it). Any other target must be a live descendant of this process in one fresh
snapshot of the process table; no pid this process once spawned counts by itself, because once reaped its number may
belong to anyone. On Linux the pid is pinned with a pidfd before the check, so a reuse cannot receive the signal.
Signal 0 (an existence probe that delivers nothing) may still name any pid above 1. Refusal raises
PermissionError(EPERM). Shell scripts started by the harness run their own guards (code-job's tree checks,
Tests/Scripts/own-pid.sh).

`python3 -I -B sim/sim_isolation.py --check` prints the mode and exits 0, or prints the refusal and exits 78: shell
suites use it before they send any signal.
"""
import errno
import os
import signal
import subprocess
import sys

INIT_PID_NS = "pid:[4026531836]"  # PROC_PID_INIT_INO: the host's initial PID namespace, fixed since Linux 3.8
REFUSED = 78  # EX_CONFIG
COMMAND = "sudo -u sbtest -- unshare -r -p -f --mount-proc"
EXAMPLE = COMMAND + " python3 -B -m unittest discover -s sim -p 'test_*.py'"


def linux_problem(proc="/proc", pid=None):
    """None when this process is isolated in its own PID namespace, else why not."""
    pid = os.getpid() if pid is None else pid
    try:
        own = os.readlink(os.path.join(proc, "self/ns/pid"))
        me = os.readlink(os.path.join(proc, "self"))
    except OSError as error:
        return "cannot read %s/self: %s" % (proc, error.strerror)
    if own == INIT_PID_NS:
        return "running in the host's initial PID namespace"
    if me != str(pid):
        return "%s belongs to another PID namespace (was --mount-proc given?)" % proc
    try:
        if os.readlink(os.path.join(proc, "1/ns/pid")) != own:
            return "pid 1 is in a different PID namespace"
    except OSError as error:
        return "cannot read pid 1 of this namespace: %s" % error.strerror
    current = pid
    for _ in range(256):
        if current == 1:
            return None
        current = _ppid(proc, current)
        if current is None or current < 1:
            return "pid 1 of this PID namespace is not an ancestor of this process"
    return "process ancestry too deep to verify"


def _ppid(proc, pid):
    try:
        with open(os.path.join(proc, str(pid), "status")) as status:
            for line in status:
                if line.startswith("PPid:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError):
        return None
    return None


def launched_by_swift_test():
    """Best-effort hint for the refusal message; the decision never depends on it."""
    if any(key.startswith("XCTest") for key in os.environ):
        return True
    try:
        with open("/proc/%d/comm" % os.getppid()) as comm:
            name = comm.read().strip()
    except OSError:
        return False
    return name.endswith(".xctest") or "xctest" in name or "swiftpm-testing" in name


def refusal(reason):
    lines = ["sim harness refused to start: not inside an isolated PID namespace (%s)." % reason]
    if launched_by_swift_test():
        lines.append("It was launched by a Swift/XCTest test; that test must not start the harness on this host.")
    lines += ["The sim harness, code-job stub tests and signal-sending tests run only as:",
              "  %s <command>" % COMMAND, "for example:", "  " + EXAMPLE,
              "macOS has no PID namespaces; there the harness runs in signal-guarded mode (sim/ISOLATION.md)."]
    return "\n".join(lines) + "\n"


def mode(platform=None, problem=linux_problem):
    """('pid-namespace' | 'darwin-guarded', None) when the harness may run, else (None, reason)."""
    platform = sys.platform if platform is None else platform
    if platform.startswith("linux"):
        reason = problem()
        return ("pid-namespace", None) if reason is None else (None, reason)
    if platform == "darwin":
        return "darwin-guarded", None
    return None, "unsupported platform %s" % platform


def process_table():
    """{pid: (ppid, pgid, start)} for every visible process, read in one pass (/proc on Linux, ps elsewhere).

    `start` (clock ticks since boot on Linux, ps lstart on macOS) tells a process from a later one reusing its number.
    Empty when the table cannot be read; the guard then refuses every signal it cannot prove is ours."""
    table = {}
    if os.path.isdir("/proc/self"):
        for name in os.listdir("/proc"):
            if name.isdigit():
                try:
                    with open("/proc/%s/stat" % name) as stat:
                        fields = stat.read().rsplit(")", 1)[1].split()  # comm may hold spaces or parentheses
                    table[int(name)] = (int(fields[1]), int(fields[2]), fields[19])
                except (OSError, ValueError, IndexError):
                    pass
        return table
    try:
        ps = subprocess.Popen(["/bin/ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "lstart="],
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                              env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"})
    except OSError:
        return table
    try:
        listing = ps.communicate(timeout=10)[0]
    except subprocess.TimeoutExpired:
        _REAL_KILL(ps.pid, signal.SIGKILL)  # Our unreaped child: the guarded kill would read this table again.
        ps.communicate()
        return table
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) > 3 and fields[0].isdigit() and fields[1].isdigit() and fields[2].isdigit():
            table[int(fields[0])] = (int(fields[1]), int(fields[2]), " ".join(fields[3:]))
    return table


_REAL_KILL = os.kill


def _plain_int(value):
    return type(value) is int  # bool, str, None and floats are refused


class SignalGuard:
    """Lets this process signal only itself and its live descendants, judged on one snapshot of the process table.

    Nothing historical makes a target ours: a number this process once spawned may have been reaped and reused by an
    unrelated process, whether or not the reaping was seen. `spawned`/`reaped` only report a known-reaped child as
    gone (ESRCH). Every group member must be a current descendant (or this process itself). An orphan adopted
    elsewhere is unverifiable and refused: a snapshot taken after wait cannot establish group ownership."""

    def __init__(self, kill=os.kill, killpg=os.killpg, table=process_table, getpid=os.getpid, getpgrp=os.getpgrp,
                 log=sys.stderr.write):
        self.spawned, self.reaped = set(), set()
        self._kill, self._killpg, self._table, self._getpid, self._getpgrp = kill, killpg, table, getpid, getpgrp
        self._log, self.pin = log, None  # pin: (pidfd_open, pidfd_send_signal) where the kernel has them

    def record(self, pid):
        """A child this process just spawned; its number grants no ownership after reaping."""
        if _plain_int(pid) and pid > 1:
            self.spawned.add(pid)
            self.reaped.discard(pid)
        return pid

    def reap(self, pid):
        """Every wait primitive reports here: the child is gone and its number free for reuse.

        Never capture members here: wait has already released the leader's identity, so even a group with
        this number may now be foreign. Without a pre-reap pin, only fresh ancestry may authorize a signal.
        """
        if pid not in self.spawned or pid in self.reaped:
            return
        self.reaped.add(pid)

    def snapshot(self):
        try:
            return self._table()
        except Exception:  # noqa: BLE001  An unreadable table proves nothing: the caller refuses.
            return {}

    def descends(self, pid, table):
        """pid's parent chain in this one table reaches this process."""
        current, seen = pid, set()
        while current in table and current not in seen:
            seen.add(current)
            current = table[current][0]
            if current == self._getpid():
                return True  # Includes orphans adopted by this process when it is pid 1 of its namespace.
        return False

    def owned(self, target, group=False):
        """True when the pid or group is this process's own now, False when not, None when it does not exist."""
        table = self.snapshot()
        if not table:
            return False
        if not group:
            return self.descends(target, table) if target in table else None
        members = [member for member, entry in table.items() if entry[1] == target]
        if not members:
            return None
        return all(member == self._getpid() or self.descends(member, table) for member in members)

    def problem(self, target, signum, group=False):
        what = "group" if group else "pid"
        if not _plain_int(target):
            return "%s %r is not a plain integer" % (what, target)
        if not group and target == self._getpid():
            return None  # Itself, even as pid 1 of the namespace `unshare -f` made for it.
        if target <= 1:
            return "%s %d is broadcast, this group, init or negative" % (what, target)
        if group and target == self._getpgrp() and target != self._getpid():
            return "group %d is this process's own (not led by it)" % target
        if signum == 0:
            return None
        if not group and target in self.reaped:
            raise ProcessLookupError(errno.ESRCH, "No such process")  # Our child, already reaped: never its reuse.
        owned = self.owned(target, group)
        if owned is None:
            raise ProcessLookupError(errno.ESRCH, "No such process")  # Nothing to signal, as the kernel would say.
        if not owned:
            return "%s %d is not a live descendant of this process (or the process table is unreadable)" % (
                what, target)
        return None

    def refuse(self, reason, signum):
        message = "sim_isolation: refused signal %r: %s" % (signum, reason)
        self._log(message + "\n")
        raise PermissionError(errno.EPERM, message)

    def kill(self, pid, signum):
        fd = None
        if self.pin is not None and _plain_int(pid) and pid > 1 and signum != 0 and pid != self._getpid():
            try:
                fd = self.pin[0](pid)  # Pins this very process: a reuse of its number cannot receive the signal.
            except ProcessLookupError:
                raise
            except OSError:
                fd = None  # No pidfd here (old kernel, fd limit): the table check alone decides.
        try:
            reason = self.problem(pid, signum)
            if reason:
                self.refuse(reason, signum)
            return self._kill(pid, signum) if fd is None else self.pin[1](fd, signum)
        finally:
            if fd is not None:
                os.close(fd)

    def killpg(self, pgid, signum):
        reason = self.problem(pgid, signum, group=True)
        if reason:
            self.refuse(reason, signum)
        return self._killpg(pgid, signum)


def _pidfd_target(fd):
    try:
        with open("/proc/self/fdinfo/%d" % fd) as info:
            for line in info:
                if line.startswith("Pid:"):
                    return int(line.split()[1])
    except (OSError, ValueError, IndexError, TypeError):
        return None
    return None


def _exited(status):
    return os.WIFEXITED(status) or os.WIFSIGNALED(status)


def _reaping(guard, real, pid_of):
    """Wrap a wait primitive so the child it reaps is reported to the guard."""
    def wait(*args, **kwargs):
        result = real(*args, **kwargs)
        pid = pid_of(result, *args, **kwargs)
        if pid:
            guard.reap(pid)
        return result
    return wait


def _waitid_pid(result, idtype=None, ident=None, options=0):
    done = {getattr(os, name, None) for name in ("CLD_EXITED", "CLD_KILLED", "CLD_DUMPED")} - {None}
    if result is None or options & getattr(os, "WNOWAIT", 0) or result.si_code not in done:
        return None
    return result.si_pid


def install(guard):
    """Route this process's signal, spawn and wait primitives through `guard`."""
    os.kill, os.killpg = guard.kill, guard.killpg
    real_pidfd_send = getattr(signal, "pidfd_send_signal", None)
    if real_pidfd_send is not None:
        if hasattr(os, "pidfd_open"):
            guard.pin = (os.pidfd_open, real_pidfd_send)

        def pidfd_send_signal(fd, signum, siginfo=None, flags=0):
            target = _pidfd_target(fd)
            if target == -1:
                raise ProcessLookupError(errno.ESRCH, "No such process")  # fdinfo says the process has exited
            reason = guard.problem(target, signum)
            if reason:
                guard.refuse(reason, signum)
            return real_pidfd_send(fd, signum, siginfo, flags)
        signal.pidfd_send_signal = pidfd_send_signal
    pid_status = lambda result, *args, **kwargs: result[0] if result[0] > 0 and _exited(result[1]) else None  # noqa
    for name in ("waitpid", "wait", "wait3", "wait4"):
        real = getattr(os, name, None)
        if real is not None:
            setattr(os, name, _reaping(guard, real, pid_status))
    if hasattr(os, "waitid"):
        os.waitid = _reaping(guard, os.waitid, _waitid_pid)
    for name in ("fork", "forkpty"):
        real = getattr(os, name, None)
        if real is not None:
            def spawn(real=real):
                result = real()
                guard.record(result[0] if isinstance(result, tuple) else result)
                return result
            setattr(os, name, spawn)
    for name in ("posix_spawn", "posix_spawnp"):
        real = getattr(os, name, None)
        if real is not None:
            def posix_spawn(*args, real=real, **kwargs):
                return guard.record(real(*args, **kwargs))
            setattr(os, name, posix_spawn)
    real_init = subprocess.Popen.__init__

    def popen_init(self, *args, **kwargs):
        real_init(self, *args, **kwargs)
        guard.record(getattr(self, "pid", None))
    subprocess.Popen.__init__ = popen_init
    # Popen reaps through this method even after its object was discarded (subprocess._cleanup polls those).
    real_exitstatus = getattr(subprocess.Popen, "_handle_exitstatus", None)
    if real_exitstatus is not None:
        def handle_exitstatus(self, *args, **kwargs):
            result = real_exitstatus(self, *args, **kwargs)
            if self.returncode is not None:
                guard.reap(self.pid)
            return result
        subprocess.Popen._handle_exitstatus = handle_exitstatus
    try:
        import multiprocessing.util as mp_util
        real_spawnv = mp_util.spawnv_passfds
        mp_util.spawnv_passfds = lambda *args, **kwargs: guard.record(real_spawnv(*args, **kwargs))
    except (ImportError, AttributeError):
        pass


GUARD = None
MODE = None


def require():
    """Exit 78 with the required command unless isolated; otherwise install the signal guard once."""
    global GUARD, MODE
    if GUARD is not None:
        return MODE
    found, reason = mode()
    if found is None:
        sys.stderr.write(refusal(reason))
        sys.stderr.flush()
        os._exit(REFUSED)  # Nothing has run yet; never let a test runner catch this and carry on.
    GUARD, MODE = SignalGuard(), found
    install(GUARD)
    return MODE


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        print(require())
        sys.exit(0)
    sys.stderr.write("usage: python3 -I -B sim/sim_isolation.py --check\n")
    sys.exit(64)
else:
    require()
