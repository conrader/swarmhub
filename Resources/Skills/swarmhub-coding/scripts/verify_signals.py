"""Signal supervisor for the verification sandbox's no-user-namespace fallback (Linux).

Without a PID namespace, a seccomp filter alone cannot say "signal only your own processes": BPF sees pid
numbers, not the process tree. The fallback therefore routes every pid-addressed signal call (kill, tkill, tgkill,
rt_sigqueueinfo, rt_tgsigqueueinfo) through seccomp user notification to the unconfined launcher, which performs
the signal itself after pinning the target with a pidfd and walking its parent chain to the sandbox root. The only
signal CONTINUE is a sigqueue aimed at the caller's own thread group, which the kernel then
handles with its own self-signal rules. verify_processes.py additionally continues self-only non-signal calls.
The launcher is a child subreaper, so orphaned verifier processes stay in
that tree. The verifier itself keeps pidfd_send_signal, pidfd_getfd, ptrace and process_vm_* denied
(/proc/<pid> directory fds would also be accepted by pidfd_send_signal), and cannot name a SIGIO owner
(F_SETOWN, FIOSETOWN), so no other syscall delivers a signal to a pid it chooses.

What is allowed: the caller itself, any descendant of the sandbox root, and process groups whose every member is
such a descendant. Denied with EPERM: kill(-1), the launcher, its parents, and everything else on the host.
"""
import ctypes
import errno
import fcntl
import os
from pathlib import Path
import select
import signal
import struct
import time

import verify_processes

# struct seccomp_notif {u64 id; u32 pid; u32 flags; struct seccomp_data {int nr; u32 arch; u64 ip; u64 args[6]}}
NOTIF_FORMAT, NOTIF_SIZE = 'QIIiIQ6Q', 80
RESP_FORMAT, RESP_SIZE = 'QqiI', 24
SECCOMP_IOCTL_NOTIF_RECV = 0xC0000000 | (NOTIF_SIZE << 16) | (ord('!') << 8) | 0
SECCOMP_IOCTL_NOTIF_SEND = 0xC0000000 | (RESP_SIZE << 16) | (ord('!') << 8) | 1
SECCOMP_IOCTL_NOTIF_ID_VALID = 0x40000000 | (8 << 16) | (ord('!') << 8) | 2
SECCOMP_IOCTL_NOTIF_ADDFD = 0x40000000 | (24 << 16) | (ord('!') << 8) | 3
SECCOMP_ADDFD_FLAG_SEND = 2  # Atomically transfer the exact opened fd and answer the pending request.
HANDLED = -2
SECCOMP_USER_NOTIF_FLAG_CONTINUE = 1
SUPERVISED_SYSCALLS = ('kill', 'tkill', 'tgkill', 'rt_sigqueueinfo', 'rt_tgsigqueueinfo')
HELPER_SYSCALLS = ('pidfd_send_signal',)  # Made by the launcher itself; denied to the verifier.
# Limited mode: every pid-addressed signal call is answered by the launcher (SUPERVISED_SYSCALLS);
# pidfd signalling is denied; pidfd_open is brokered below, kcmp is self-only in verify_processes.py. ptrace, process_vm_* and
# pidfd_getfd are denied in every mode (verify-sandbox.py's DENIED_SYSCALLS).
SIGNAL_SYSCALLS = ('kill', 'tkill', 'tgkill', 'rt_sigqueueinfo', 'rt_tgsigqueueinfo', 'pidfd_send_signal')
# A SIGIO/SIGURG owner is a pid or group the kernel signals later (fcntl F_SETOWN/F_SETOWN_EX, socket ioctls).
F_SETOWN, F_SETOWN_EX, FIOSETOWN, SIOCSPGRP = 8, 15, 0x8901, 0x8902
SIGNAL_OWNER_CALLS = (('fcntl', F_SETOWN), ('fcntl', F_SETOWN_EX), ('ioctl', FIOSETOWN), ('ioctl', SIOCSPGRP))
CMD_MASK = 0xffffffff  # fcntl/ioctl take an unsigned int command: the upper register half must not dodge the rule.
SIGINFO_SIZE = 128  # sizeof(siginfo_t) on every Linux architecture.
CONTINUE = -1  # decide(): let the kernel run the caller's own call (a sigqueue to its own thread group).
PROC = Path('/proc')


def int32(value):
    return ctypes.c_int32(value & 0xffffffff).value


def status_field(pid, key):
    """`PPid`/`Tgid` of /proc/<pid>/status, or None when the process is gone."""
    try:
        for line in (PROC / str(pid) / 'status').read_text().splitlines():
            if line.startswith(key + ':'):
                return int(line.split(':', 1)[1])
    except (OSError, ValueError):
        return None
    return None


def process_group(pid):
    """pgrp of /proc/<pid>/stat (the field after the parenthesised command name), or None."""
    try:
        after_comm = (PROC / str(pid) / 'stat').read_text().rsplit(')', 1)[1].split()
        return int(after_comm[2])
    except (OSError, ValueError, IndexError):
        return None


class Supervisor:
    def __init__(self, listener, root, syscall_names):
        self.listener, self.root, self.launcher = listener, root, os.getpid()
        self.names = syscall_names  # syscall number -> name, resolved by the caller through libseccomp
        self.numbers = {name: number for number, name in syscall_names.items()}
        self.libc = ctypes.CDLL(None, use_errno=True)

    def descendant(self, pid):
        """pid is the sandbox root or below it. A pid reused by a host process can only make this walk fail
        (its chain never reaches the root); reaching the root or the launcher (adopted orphans) needs a real
        descendant, because the launcher's only child is the root."""
        for _ in range(4096):
            if pid == self.root or pid == self.launcher:
                return True
            if pid <= 1:
                return False
            pid = status_field(pid, 'PPid')
            if pid is None:
                return False
        return False

    def pinned(self, pid):
        """A pidfd for pid, raising ProcessLookupError when it does not exist. Holding it keeps the pid number
        from being reused while the ancestry check and the signal happen."""
        if pid <= 0 or pid == self.launcher:
            raise PermissionError(errno.EPERM, 'outside the sandbox')
        return os.pidfd_open(pid)

    def call(self, name, *args):
        """A raw syscall made by the launcher; 0 or the errno it failed with."""
        number = self.numbers.get(name)
        if number is None:
            return errno.EPERM
        if self.libc.syscall(number, *args) != 0:
            return ctypes.get_errno() or errno.EPERM
        return 0

    def siginfo(self, notif_id, caller, address, sig):
        """The caller's siginfo_t, copied once from its memory before anything is sent; only the copy is used.

        The open of /proc/<tid>/mem is checked against the still-pending request (the tid could have been reused
        if the caller was killed meanwhile). si_signo is set to `sig`, as rt_sigqueueinfo itself does."""
        try:
            fd = os.open('/proc/%d/mem' % caller, os.O_RDONLY | os.O_CLOEXEC)
        except FileNotFoundError:
            raise ProcessLookupError(errno.ESRCH, 'caller gone')
        except OSError:
            raise PermissionError(errno.EPERM, 'caller memory unreadable')
        try:
            try:
                fcntl.ioctl(self.listener, SECCOMP_IOCTL_NOTIF_ID_VALID, struct.pack('Q', notif_id))
            except OSError:
                raise ProcessLookupError(errno.ESRCH, 'request no longer pending')
            try:
                data = os.pread(fd, SIGINFO_SIZE, address)
            except (OSError, OverflowError):
                data = b''
        finally:
            os.close(fd)
        if len(data) != SIGINFO_SIZE:
            raise OSError(errno.EFAULT, 'siginfo not readable')
        info = bytearray(data)
        struct.pack_into('i', info, 0, sig)
        return (ctypes.c_char * SIGINFO_SIZE).from_buffer(info)

    def signal_process(self, pid, sig, send=None):
        """kill/rt_sigqueueinfo to one process: `send(pidfd)` returns 0 or an errno (default: a plain signal)."""
        fd = self.pinned(pid)
        try:
            if not self.descendant(pid):
                return errno.EPERM
            if send is not None:
                return send(fd)
            signal.pidfd_send_signal(fd, sig)
        finally:
            os.close(fd)
        return 0

    def signal_group(self, pgid, sig):
        """kill(-pgid): every member must be a descendant, otherwise nothing is signalled."""
        members = [int(entry.name) for entry in PROC.iterdir() if entry.name.isdigit() and process_group(int(entry.name)) == pgid]
        fds = []
        try:
            for pid in members:
                try:
                    fds.append(self.pinned(pid))
                except ProcessLookupError:
                    continue  # Exited between the listing and now.
                if not self.descendant(pid):
                    return errno.EPERM
            if not fds:
                return errno.ESRCH
            for fd in fds:
                try:
                    signal.pidfd_send_signal(fd, sig)
                except ProcessLookupError:
                    pass
        finally:
            for fd in fds:
                os.close(fd)
        return 0

    def signal_thread(self, tgid, tid, sig, send=None):
        """tgkill/rt_tgsigqueueinfo: the thread group is pinned and checked; the kernel checks that tid belongs to it.
        `send()` returns 0 or an errno (default: tgkill)."""
        fd = self.pinned(tgid)
        try:
            if not self.descendant(tgid) or not (PROC / str(tgid) / 'task' / str(tid)).exists():
                return errno.EPERM
            return send() if send is not None else self.call('tgkill', tgid, tid, sig)
        finally:
            os.close(fd)

    def open_pidfd(self, pid, flags, notif_id):
        """Return only a pinned own-tree pidfd, never CONTINUE a checked foreign numeric PID.

        ADDFD + SEND installs this exact descriptor and replies atomically; cancellation
        cannot inject a descriptor into a later syscall. Needed by asyncio child watchers.
        """
        if pid <= 0 or pid == self.launcher:
            return errno.EPERM
        fd = os.pidfd_open(pid, flags)
        try:
            if not self.descendant(pid):
                return errno.EPERM
            addfd = bytearray(struct.pack('QIIII', notif_id, SECCOMP_ADDFD_FLAG_SEND, fd, 0, os.O_CLOEXEC))
            fcntl.ioctl(self.listener, SECCOMP_IOCTL_NOTIF_ADDFD, addfd, True)
            return HANDLED
        finally:
            os.close(fd)

    def decide(self, name, caller, args, notif_id=0):
        """Returns the errno for the response; 0 means the signal was sent, CONTINUE that the kernel runs the call.

        The sigqueue calls carry a caller-built siginfo. Aimed at the caller's own thread group they continue in the
        kernel (which allows any si_code to oneself); aimed elsewhere the launcher sends the copied siginfo, and the
        kernel then requires a negative si_code (SI_QUEUE), exactly as it would for the caller."""
        try:
            if name == 'pidfd_open':
                return self.open_pidfd(int32(args[0]), int32(args[1]), notif_id)
            if name in verify_processes.SYSCALLS:
                return verify_processes.decide(name, caller, args)
            if name == 'kill':
                pid, sig = int32(args[0]), int32(args[1])
                if pid == -1:
                    return errno.EPERM
                if pid == 0 or pid < -1:
                    pgid = process_group(caller) if pid == 0 else -pid
                    return errno.ESRCH if pgid is None else self.signal_group(pgid, sig)
                return self.signal_process(pid, sig)
            if name == 'tgkill':
                return self.signal_thread(int32(args[0]), int32(args[1]), int32(args[2]))
            if name == 'tkill':
                tid, sig = int32(args[0]), int32(args[1])
                tgid = status_field(tid, 'Tgid')
                return errno.ESRCH if tgid is None else self.signal_thread(tgid, tid, sig)
            if name == 'rt_sigqueueinfo':
                pid, sig, address = int32(args[0]), int32(args[1]), args[2]
                if pid == status_field(caller, 'Tgid'):
                    return CONTINUE
                if pid <= 0:
                    return errno.ESRCH  # The kernel looks the pid up; there are no groups or broadcast here.
                return self.signal_process(pid, sig, lambda fd: self.call(
                    'pidfd_send_signal', fd, sig, self.siginfo(notif_id, caller, address, sig), 0))
            if name == 'rt_tgsigqueueinfo':
                tgid, tid, sig, address = int32(args[0]), int32(args[1]), int32(args[2]), args[3]
                if tgid <= 0 or tid <= 0:
                    return errno.EINVAL
                if tgid == status_field(caller, 'Tgid'):
                    return CONTINUE
                return self.signal_thread(tgid, tid, sig, lambda: self.call(
                    'rt_tgsigqueueinfo', tgid, tid, sig, self.siginfo(notif_id, caller, address, sig)))
        except ProcessLookupError:
            return errno.ESRCH
        except OSError as exc:
            return exc.errno or errno.EPERM
        return errno.EPERM

    def handle_one(self):
        """One notification. A vanished requesting thread does not end supervision."""
        request = bytearray(NOTIF_SIZE)
        try:
            fcntl.ioctl(self.listener, SECCOMP_IOCTL_NOTIF_RECV, request, True)
        except OSError as exc:
            if exc.errno in (errno.ENOENT, errno.EINTR):
                # A task may exit/be killed between poll and RECV (e.g. a child
                # killed while its dynamic loader is asking for prlimit64).
                # ENOENT is a cancelled notification, not the end of the tree;
                # the root pidfd, not this race, decides when teardown is safe.
                return True
            raise
        notif_id, caller, _flags, number, _arch, _ip, *args = struct.unpack(NOTIF_FORMAT, bytes(request))
        error, flags = self.decide(self.names.get(number), caller, args, notif_id), 0
        if error == HANDLED:
            return True
        if error == CONTINUE:
            error, flags = 0, SECCOMP_USER_NOTIF_FLAG_CONTINUE
        response = struct.pack(RESP_FORMAT, notif_id, 0, -error, flags)
        try:
            fcntl.ioctl(self.listener, SECCOMP_IOCTL_NOTIF_SEND, bytearray(response), True)
        except OSError as exc:
            if exc.errno != errno.ENOENT:  # The caller was killed while we decided.
                raise
        return True

    def forward(self, signum, _frame):
        """The verifier runs in its own process group: a terminal interrupt or code-job's stop reaches it through us."""
        try:
            os.killpg(self.root, signum)
        except OSError:
            pass
        self.kill_tree()
        raise SystemExit(128 + signum)

    def kill_tree(self, timeout=5.0):
        """Pin, kill, acknowledge exit, then reap; success never means just signal delivery.

        Repeat discovery after each batch: descendants may fork during the first
        scan or be adopted while their parents exit. Preserve the root's wait
        status for linux(), but reap every adopted descendant before returning.
        """
        deadline = time.monotonic() + timeout
        while True:
            pinned = {}
            try:
                for entry in PROC.iterdir():
                    if not entry.name.isdigit() or int(entry.name) == self.launcher:
                        continue
                    pid = int(entry.name)
                    try:
                        fd = self.pinned(pid)
                    except ProcessLookupError:
                        continue
                    if not self.descendant(pid):
                        os.close(fd)
                        continue
                    pinned[fd] = pid
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                pending = set(pinned)
                poller = select.poll()
                for fd in pending:
                    poller.register(fd, select.POLLIN)
                while pending:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise OSError('verification descendant teardown timed out')
                    for fd, events in poller.poll(max(1, int(remaining * 1000))):
                        if events & select.POLLIN:
                            pending.discard(fd)
                            poller.unregister(fd)
                descendants = [pid for pid in pinned.values() if pid != self.root]
                for pid in descendants:
                    try:
                        os.waitpid(pid, os.WNOHANG)
                    except ChildProcessError:
                        pass  # Its parent reaped it, or adoption is still settling.
                if not descendants:
                    return
                if time.monotonic() >= deadline:
                    raise OSError('verification descendant reaping timed out')
            finally:
                for fd in pinned:
                    os.close(fd)

    def run(self):
        """Serve until the sandbox root exits, then kill what it left behind."""
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, self.forward)
        pidfd = os.pidfd_open(self.root)
        poller = select.poll()
        poller.register(self.listener, select.POLLIN)
        poller.register(pidfd, select.POLLIN)
        try:
            while True:
                for fd, events in poller.poll():
                    if fd == pidfd:
                        return
                    if events & select.POLLIN:
                        if not self.handle_one():
                            return
                    elif events & (select.POLLHUP | select.POLLERR):
                        return
        finally:
            os.close(pidfd)
            self.kill_tree()


def supervise(listener, root, syscall_names):
    Supervisor(listener, root, syscall_names).run()
