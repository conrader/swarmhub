"""Fixes8 item 1: in the limited verification sandbox a verifier signals or touches only its own process tree.

Every test runs the shipped verify-sandbox.py for real on Linux with user namespaces disabled
(SWARMHUB_VERIFY_NAMESPACES=0). The test harness starts a helper process outside the sandbox that records every
signal it receives; the verifier aims each process-signalling or process-access syscall at that helper and at the
launcher and must be refused, then signals its own child through the same syscall where the call is routed (or
through kill where it is denied outright). Nothing here contacts a network, a gateway or a provider.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import os
from pathlib import Path
import subprocess
import sys
import textwrap
import time
import unittest

try:
    from sim.test_fixes7 import LimitedBase, user_namespaces_available
except ImportError:  # `python3 -m unittest discover` from inside sim/
    from test_fixes7 import LimitedBase, user_namespaces_available

LINUX = sys.platform == 'linux'

# Started by the harness, outside the sandbox: records every signal it gets, never exits on one.
HELPER = textwrap.dedent('''
    import os, signal, sys, time
    record, ready = sys.argv[1], sys.argv[2]
    def seen(signum, _frame):
        with open(record, "a") as out:
            out.write("%d\\n" % signum)
    for signum in (signal.SIGUSR1, signal.SIGUSR2, signal.SIGIO, signal.SIGURG, signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, seen)
    open(ready, "w").close()
    deadline = time.monotonic() + 120
    while time.monotonic() < deadline:
        time.sleep(0.05)
''')

# Runs inside the sandbox: `probe.py <syscall> <helper pid> <launcher pid> <limited|namespaced>`.
PROBE = textwrap.dedent('''
    import ctypes, errno, fcntl, os, signal, socket, struct, subprocess, sys, threading
    NAME, HELPER, LAUNCHER, MODE = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
    # Namespaced, host pids do not exist for the verifier; limited, they exist and must be refused.
    REFUSED = (errno.EPERM,) if MODE == "limited" else (errno.EPERM, errno.ESRCH)
    if MODE == "namespaced":
        LAUNCHER = HELPER  # The launcher is outside the PID namespace ($PPID reads 0 there).
    SI_USER, SI_QUEUE, SI_TKILL = 0, -1, -6
    libc = ctypes.CDLL(None, use_errno=True)
    resolve = ctypes.CDLL("libseccomp.so.2").seccomp_syscall_resolve_name
    libc.syscall.restype = ctypes.c_long

    def call(name, *args):
        """errno of the raw syscall, 0 on success."""
        number = resolve(name.encode())
        assert number >= 0, name
        ctypes.set_errno(0)
        return 0 if libc.syscall(ctypes.c_long(number), *args) >= 0 else ctypes.get_errno()

    def refused(name, *args):
        error = call(name, *args)
        assert error in REFUSED, "%s%r was not refused: %s" % (name, args, os.strerror(error) if error else "allowed")

    def siginfo(sig, code=SI_QUEUE, value=42):
        info = ctypes.create_string_buffer(128)
        struct.pack_into("iii", info, 0, sig, 0, code)
        struct.pack_into("iIi", info, 16, os.getpid(), os.getuid(), value)
        return info

    CHILD = """
    import ctypes, signal, struct, sys
    libc = ctypes.CDLL(None, use_errno=True)
    signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGUSR1])
    mask = ctypes.create_string_buffer(128)
    libc.sigemptyset(mask)
    libc.sigaddset(mask, signal.SIGUSR1)
    print("ready", flush=True)
    signal.alarm(10)
    info = ctypes.create_string_buffer(128)
    if libc.sigwaitinfo(mask, info) != signal.SIGUSR1:
        sys.exit(3)
    code, = struct.unpack_from("i", info.raw, 8)
    pid, value = struct.unpack_from("ii", info.raw, 16)[0], struct.unpack_from("i", info.raw, 24)[0]
    print(code, pid, value, flush=True)
    """

    def own_child_receives(send):
        """Starts a child that waits for SIGUSR1, lets `send(pid)` signal it; returns (si_code, si_pid, si_value)."""
        child = subprocess.Popen([sys.executable, "-c", CHILD], stdout=subprocess.PIPE, text=True)
        assert child.stdout.readline().strip() == "ready"
        error = send(child.pid)
        if error:
            child.kill()
            child.wait()
            raise AssertionError("signalling the own child failed: " + os.strerror(error))
        out, _ = child.communicate(timeout=15)
        assert child.returncode == 0, child.returncode
        return tuple(int(field) for field in out.split())

    def own_child_via_kill():
        code, pid, _ = own_child_receives(lambda pid: call("kill", pid, signal.SIGUSR1))
        assert code == SI_USER, code

    def self_receives(send, expected_code):
        signal.pthread_sigmask(signal.SIG_BLOCK, [signal.SIGUSR1])
        error = send()
        assert error == 0, os.strerror(error)
        info = signal.sigtimedwait([signal.SIGUSR1], 5)
        assert info is not None and info.si_code == expected_code, info

    for target in (HELPER, LAUNCHER) + ((1,) if MODE == "limited" else ()):
        assert call("kill", target, 0) in REFUSED, target

    if NAME == "kill":
        refused("kill", HELPER, signal.SIGUSR1)
        refused("kill", LAUNCHER, signal.SIGUSR1)
        refused("kill", -HELPER, signal.SIGUSR1)  # The helper's group (it leads one: setsid by the harness).
        own_child_via_kill()
    elif NAME == "tkill":
        refused("tkill", HELPER, signal.SIGUSR1)
        refused("tkill", LAUNCHER, signal.SIGUSR1)
        code, _, _ = own_child_receives(lambda pid: call("tkill", pid, signal.SIGUSR1))
        assert code in (SI_USER, SI_TKILL), code  # Kernels before 6.9 report tkill/tgkill as SI_USER.
    elif NAME == "tgkill":
        refused("tgkill", HELPER, HELPER, signal.SIGUSR1)
        refused("tgkill", LAUNCHER, LAUNCHER, signal.SIGUSR1)
        refused("tgkill", os.getpid(), HELPER, signal.SIGUSR1)  # A host thread under the caller's own tgid.
        code, _, _ = own_child_receives(lambda pid: call("tgkill", pid, pid, signal.SIGUSR1))
        assert code in (SI_USER, SI_TKILL), code  # Kernels before 6.9 report tkill/tgkill as SI_USER.
    elif NAME == "rt_sigqueueinfo":
        refused("rt_sigqueueinfo", HELPER, signal.SIGUSR1, siginfo(signal.SIGUSR1))
        refused("rt_sigqueueinfo", LAUNCHER, signal.SIGUSR1, siginfo(signal.SIGUSR1))
        # The caller's siginfo arrives intact: SI_QUEUE, the caller's pid and the queued value.
        received = own_child_receives(lambda pid: call("rt_sigqueueinfo", pid, signal.SIGUSR1, siginfo(signal.SIGUSR1)))
        assert received == (SI_QUEUE, os.getpid(), 42), received
        # The kernel's own rules still apply: impersonating kill() towards another process is refused, ...
        child = subprocess.Popen(["sleep", "30"])
        assert call("rt_sigqueueinfo", child.pid, signal.SIGUSR1, siginfo(signal.SIGUSR1, SI_USER)) == errno.EPERM
        assert call("rt_sigqueueinfo", child.pid, signal.SIGUSR1, ctypes.c_void_p(16)) == errno.EFAULT
        child.kill()
        child.wait()
        # ... and towards oneself any si_code is allowed.
        self_receives(lambda: call("rt_sigqueueinfo", os.getpid(), signal.SIGUSR1, siginfo(signal.SIGUSR1, SI_USER)), SI_USER)
    elif NAME == "rt_tgsigqueueinfo":
        refused("rt_tgsigqueueinfo", HELPER, HELPER, signal.SIGUSR1, siginfo(signal.SIGUSR1))
        refused("rt_tgsigqueueinfo", LAUNCHER, LAUNCHER, signal.SIGUSR1, siginfo(signal.SIGUSR1))
        received = own_child_receives(
            lambda pid: call("rt_tgsigqueueinfo", pid, pid, signal.SIGUSR1, siginfo(signal.SIGUSR1)))
        assert received == (SI_QUEUE, os.getpid(), 42), received
        self_receives(lambda: call("rt_tgsigqueueinfo", os.getpid(), threading.get_native_id(), signal.SIGUSR1,
                                   siginfo(signal.SIGUSR1, SI_USER)), SI_USER)
    elif NAME == "pidfd_open":
        refused("pidfd_open", HELPER, 0)
        refused("pidfd_open", LAUNCHER, 0)
        if MODE == "limited":  # Denied outright: a pidfd could name any host process later.
            os.close(os.pidfd_open(os.getpid()))  # Fixes9 brokers self/own-tree pidfds.
        own_child_via_kill()
    elif NAME == "pidfd_send_signal":
        # No pidfd for a host process can be obtained (pidfd_open denied, /proc/<pid> outside the Landlock rules);
        # the call itself is refused before the kernel even looks at the descriptor (EPERM, not EBADF).
        try:
            os.open("/proc/%d" % HELPER, os.O_RDONLY | os.O_DIRECTORY)
            raise AssertionError("/proc/<helper> opened")
        except (PermissionError, FileNotFoundError):
            pass
        fd = os.open("/dev/null", os.O_RDONLY)
        if MODE == "limited":
            assert call("pidfd_send_signal", fd, signal.SIGUSR1, None, 0) == errno.EPERM
        own_child_via_kill()
    elif NAME == "pidfd_getfd":
        fd = os.open("/dev/null", os.O_RDONLY)
        refused("pidfd_getfd", fd, 0, 0)
        own_child_via_kill()
    elif NAME == "ptrace":
        PTRACE_TRACEME, PTRACE_ATTACH, PTRACE_SEIZE = 0, 16, 0x4206
        refused("ptrace", PTRACE_ATTACH, HELPER, None, None)
        refused("ptrace", PTRACE_SEIZE, HELPER, None, None)
        refused("ptrace", PTRACE_ATTACH, LAUNCHER, None, None)
        child = subprocess.Popen(["sleep", "30"])
        assert call("ptrace", PTRACE_ATTACH, child.pid, None, None) == errno.EPERM
        child.kill()
        child.wait()
        assert call("ptrace", PTRACE_TRACEME, 0, None, None) == errno.EPERM
        own_child_via_kill()
    elif NAME in ("process_vm_readv", "process_vm_writev"):
        class IoVec(ctypes.Structure):
            _fields_ = [("base", ctypes.c_void_p), ("len", ctypes.c_size_t)]
        buffer = ctypes.create_string_buffer(8)
        local = IoVec(ctypes.addressof(buffer), 8)
        remote = IoVec(0x400000, 8)
        refused(NAME, HELPER, ctypes.byref(local), 1, ctypes.byref(remote), 1, 0)
        refused(NAME, LAUNCHER, ctypes.byref(local), 1, ctypes.byref(remote), 1, 0)
        child = subprocess.Popen(["sleep", "30"])
        assert call(NAME, child.pid, ctypes.byref(local), 1, ctypes.byref(remote), 1, 0) == errno.EPERM
        child.kill()
        child.wait()
        own_child_via_kill()
    elif NAME == "kcmp":
        KCMP_FILE = 0
        refused("kcmp", os.getpid(), HELPER, KCMP_FILE, 0, 0)
        refused("kcmp", os.getpid(), LAUNCHER, KCMP_FILE, 0, 0)
        own_child_via_kill()
    elif NAME == "signal-owner":
        # A SIGIO owner is signalled by the kernel later, on I/O: F_SETOWN/F_SETOWN_EX on a pipe, FIOSETOWN and
        # SIOCSPGRP on a socket. An unsigned-int command with junk in the upper register half is refused too.
        F_SETOWN, F_SETOWN_EX, FIOSETOWN, SIOCSPGRP = 8, 15, 0x8901, 0x8902
        reader, writer = os.pipe()
        owner = struct.pack("ii", 1, HELPER)  # struct f_owner_ex {F_OWNER_PID, pid}
        for command, arg in ((F_SETOWN, HELPER), (F_SETOWN, -HELPER), (1 << 32 | F_SETOWN, HELPER),
                             (F_SETOWN_EX, ctypes.create_string_buffer(owner))):
            refused("fcntl", reader, ctypes.c_ulong(command), arg)
        fcntl.fcntl(reader, fcntl.F_SETSIG, signal.SIGUSR1)
        fcntl.fcntl(reader, fcntl.F_SETFL, os.O_ASYNC)
        os.write(writer, b"x")  # Nobody owns the pipe: no signal goes anywhere.
        left, right = socket.socketpair()
        target = ctypes.c_int(HELPER)
        for command in (FIOSETOWN, SIOCSPGRP, 1 << 32 | FIOSETOWN):
            refused("ioctl", left.fileno(), ctypes.c_ulong(command), ctypes.byref(target))
        fcntl.fcntl(left.fileno(), fcntl.F_SETFL, os.O_ASYNC)
        right.send(b"x")
        own_child_via_kill()
    else:
        raise SystemExit("unknown probe " + NAME)
    print("probe-ok", NAME)
''')


class HelperBase(LimitedBase):
    """Starts the out-of-tree helper process (its own session) and checks afterwards that nothing reached it."""

    def setUp(self):
        super().setUp()
        self.record = self.root / 'helper-signals'
        ready = self.root / 'helper-ready'
        self.helper = subprocess.Popen([sys.executable, '-c', HELPER, str(self.record), str(ready)],
                                       start_new_session=True)
        self.addCleanup(self.stop_helper)
        deadline = time.monotonic() + 10
        while not ready.exists():
            self.assertLess(time.monotonic(), deadline, 'helper did not start')
            time.sleep(0.02)
        (self.repo / 'probe.py').write_text(PROBE)

    def stop_helper(self):
        self.helper.kill()
        self.helper.wait()

    def probe(self, name, mode='limited', namespaces=None):
        command = '/usr/bin/python3 probe.py %s %d $PPID %s' % (name, self.helper.pid, mode)
        result = self.run_verify(command, namespaces=namespaces)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('probe-ok ' + name, result.stdout)
        time.sleep(0.1)  # A signal would be handled by the helper well within this.
        self.assertIsNone(self.helper.poll(), 'the helper process was killed')
        self.assertFalse(self.record.exists() and self.record.read_text(),
                         'signals reached the helper: %r' % (self.record.read_text() if self.record.exists() else ''))
        status = Path('/proc/%d/status' % self.helper.pid).read_text()
        self.assertIn('TracerPid:\t0\n', status)
        return result


@unittest.skipUnless(LINUX, 'the limited mode exists only on Linux')
class LimitedModeProcessIsolationTests(HelperBase):
    """One test per syscall: refused against the helper and the launcher; the own child is still signalled."""

    def test_kill_reaches_the_own_child_not_the_helper_or_the_launcher(self):
        self.probe('kill')

    def test_tkill_reaches_the_own_child_not_the_helper_or_the_launcher(self):
        self.probe('tkill')

    def test_tgkill_reaches_the_own_child_not_the_helper_or_the_launcher(self):
        self.probe('tgkill')

    def test_rt_sigqueueinfo_is_supervised_and_keeps_the_callers_siginfo(self):
        self.probe('rt_sigqueueinfo')

    def test_rt_tgsigqueueinfo_is_supervised_and_keeps_the_callers_siginfo(self):
        self.probe('rt_tgsigqueueinfo')

    def test_pidfd_open_is_denied(self):
        self.probe('pidfd_open')

    def test_pidfd_send_signal_is_denied(self):
        self.probe('pidfd_send_signal')

    def test_pidfd_getfd_is_denied(self):
        self.probe('pidfd_getfd')

    def test_ptrace_is_denied(self):
        self.probe('ptrace')

    def test_process_vm_readv_is_denied(self):
        self.probe('process_vm_readv')

    def test_process_vm_writev_is_denied(self):
        self.probe('process_vm_writev')

    def test_kcmp_is_denied(self):
        self.probe('kcmp')

    def test_a_sigio_owner_cannot_name_another_process(self):
        self.probe('signal-owner')


@unittest.skipUnless(LINUX and user_namespaces_available(), 'needs unprivileged user namespaces')
class NamespacedModeSignalTests(HelperBase):
    """The namespaced mode is unchanged: the sigqueue calls reach the own child, host pids do not exist there."""
    namespaces = '1'

    def test_sigqueue_calls_reach_the_own_child_in_the_namespaced_mode(self):
        for name in ('rt_sigqueueinfo', 'rt_tgsigqueueinfo', 'kill', 'tgkill'):
            with self.subTest(name):
                result = self.probe(name, mode='namespaced')
                self.assertNotIn('no user namespace', result.stderr)


if __name__ == '__main__':
    unittest.main()
