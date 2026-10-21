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
are this process's group
(unless it leads it) and every process this process did not spawn, directly or through its children. Signal 0
(an existence probe that delivers nothing) may still name any pid above 1. Refusal raises PermissionError(EPERM).
Shell scripts started by the harness run their own guards (code-job's tree checks, Tests/Scripts validation).

`python3 -I -B sim/sim_isolation.py --check` prints the mode and exits 0, or prints the refusal and exits 78: shell
suites use it before they send any signal.
"""
import errno
import os
import signal
import subprocess
import sys
import weakref

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


def process_parents():
    """{pid: ppid} for every visible process (/proc on Linux, ps elsewhere)."""
    parents = {}
    if os.path.isdir("/proc/self"):
        for name in os.listdir("/proc"):
            if name.isdigit():
                ppid = _ppid("/proc", int(name))
                if ppid is not None:
                    parents[int(name)] = ppid
        return parents
    listing = subprocess.run(["/bin/ps", "-A", "-o", "pid=", "-o", "ppid="], capture_output=True, text=True,
                             timeout=10).stdout
    for line in listing.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[0].isdigit() and fields[1].isdigit():
            parents[int(fields[0])] = int(fields[1])
    return parents


def _plain_int(value):
    return type(value) is int  # bool, str, None and floats are refused


class SignalGuard:
    """Lets this process signal only itself and the processes it spawned (and their descendants)."""

    def __init__(self, kill=os.kill, killpg=os.killpg, parents=process_parents, getpid=os.getpid,
                 getpgrp=os.getpgrp, log=sys.stderr.write):
        self.spawned, self.reaped, self._popens = set(), set(), weakref.WeakValueDictionary()
        self._kill, self._killpg, self._parents, self._getpid, self._getpgrp = kill, killpg, parents, getpid, getpgrp
        self._log = log

    def record(self, pid, popen=None):
        if _plain_int(pid) and pid > 1:
            self.spawned.add(pid)
            self.reaped.discard(pid)
            if popen is not None:
                self._popens[pid] = popen
        return pid

    def live_child(self, pid):
        """A spawned pid not yet reaped: once reaped, the number may belong to an unrelated process."""
        popen = self._popens.get(pid)
        if popen is not None and popen.returncode is not None:
            self.reaped.add(pid)
        return pid in self.spawned and pid not in self.reaped

    def owned(self, pid, group=False):
        """True for spawned pids and their live descendants; None when no such process exists.

        A group keeps its number while any member lives, so a reaped leader still names its own group."""
        if (pid in self.spawned) if group else self.live_child(pid):
            return True
        parents, seen = self._parents(), set()
        if pid not in parents:
            return None
        current = parents.get(pid)
        while current is not None and current not in seen:
            if current in self.spawned or current == self._getpid():
                return True  # Includes orphans adopted by this process when it is pid 1 of its namespace.
            if current <= 1:
                return False
            seen.add(current)
            current = parents.get(current)
        return False

    def problem(self, target, signum, group=False):
        what = "group" if group else "pid"
        if not _plain_int(target):
            return "%s %r is not a plain integer" % (what, target)
        if not group and target == self._getpid():
            return None  # Itself, even as pid 1 of the namespace `unshare -f` made for it.
        if target <= 1:
            return "%s %d is broadcast, this group, init or negative" % (what, target)
        if group and target == self._getpgrp():
            return None if target == self._getpid() else "group %d is this process's own (not led by it)" % target
        if signum == 0:
            return None
        owned = self.owned(target, group)
        if owned is None and not group:
            raise ProcessLookupError(errno.ESRCH, "No such process")  # Stale pid: nothing to signal, as the kernel says.
        if not owned:
            return "%s %d was not spawned by this process or its children" % (what, target)
        return None

    def refuse(self, reason, signum):
        message = "sim_isolation: refused signal %r: %s" % (signum, reason)
        self._log(message + "\n")
        raise PermissionError(errno.EPERM, message)

    def kill(self, pid, signum):
        reason = self.problem(pid, signum)
        if reason:
            self.refuse(reason, signum)
        return self._kill(pid, signum)

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


def install(guard):
    """Route this process's signal and spawn primitives through `guard`."""
    os.kill, os.killpg = guard.kill, guard.killpg
    real_pidfd_send = getattr(signal, "pidfd_send_signal", None)
    if real_pidfd_send is not None:
        def pidfd_send_signal(fd, signum, siginfo=None, flags=0):
            target = _pidfd_target(fd)
            if target == -1:
                raise ProcessLookupError(errno.ESRCH, "No such process")  # fdinfo says the process has exited
            reason = guard.problem(target, signum)
            if reason:
                guard.refuse(reason, signum)
            return real_pidfd_send(fd, signum, siginfo, flags)
        signal.pidfd_send_signal = pidfd_send_signal
    real_waitpid = os.waitpid

    def waitpid(pid, options):
        result = real_waitpid(pid, options)
        if result[0] > 0 and (os.WIFEXITED(result[1]) or os.WIFSIGNALED(result[1])):
            guard.reaped.add(result[0])
        return result
    os.waitpid = waitpid
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
            setattr(os, name, lambda *args, real=real, **kwargs: guard.record(real(*args, **kwargs)))
    real_init = subprocess.Popen.__init__

    def popen_init(self, *args, **kwargs):
        real_init(self, *args, **kwargs)
        guard.record(getattr(self, "pid", None), self)
    subprocess.Popen.__init__ = popen_init
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
