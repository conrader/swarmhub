"""Signal supervisor for the verification sandbox's no-user-namespace fallback (Linux).

Without a PID namespace, a seccomp filter alone cannot say "signal only your own processes": BPF sees pid
numbers, not the process tree. The fallback therefore routes kill/tkill/tgkill through seccomp user
notification to the unconfined launcher, which performs the signal itself (never SECCOMP_USER_NOTIF_FLAG_CONTINUE)
after pinning the target with a pidfd and walking its parent chain to the sandbox root. The launcher is a child
subreaper, so orphaned verifier processes stay in that tree. The verifier itself keeps pidfd_open and
pidfd_send_signal denied (/proc/<pid> directory fds would also be accepted there).

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

# struct seccomp_notif {u64 id; u32 pid; u32 flags; struct seccomp_data {int nr; u32 arch; u64 ip; u64 args[6]}}
NOTIF_FORMAT, NOTIF_SIZE = 'QIIiIQ6Q', 80
RESP_FORMAT, RESP_SIZE = 'QqiI', 24
SECCOMP_IOCTL_NOTIF_RECV = 0xC0000000 | (NOTIF_SIZE << 16) | (ord('!') << 8) | 0
SECCOMP_IOCTL_NOTIF_SEND = 0xC0000000 | (RESP_SIZE << 16) | (ord('!') << 8) | 1
SUPERVISED_SYSCALLS = ('kill', 'tkill', 'tgkill')
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
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.tgkill_number = next((n for n, name in syscall_names.items() if name == 'tgkill'), None)

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

    def signal_process(self, pid, sig):
        fd = self.pinned(pid)
        try:
            if not self.descendant(pid):
                return errno.EPERM
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

    def signal_thread(self, tgid, tid, sig):
        """tgkill: the thread group is pinned and checked; the kernel checks that tid belongs to it."""
        if self.tgkill_number is None:
            return errno.EPERM
        fd = self.pinned(tgid)
        try:
            if not self.descendant(tgid) or not (PROC / str(tgid) / 'task' / str(tid)).exists():
                return errno.EPERM
            if self.libc.syscall(self.tgkill_number, tgid, tid, sig) != 0:
                return ctypes.get_errno() or errno.EPERM
        finally:
            os.close(fd)
        return 0

    def decide(self, name, caller, args):
        """Returns the errno for the response; 0 means the signal was sent."""
        try:
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
        except ProcessLookupError:
            return errno.ESRCH
        except OSError as exc:
            return exc.errno or errno.EPERM
        return errno.EPERM

    def handle_one(self):
        """One notification: False when the filter has no processes left (ENOENT)."""
        request = bytearray(NOTIF_SIZE)
        try:
            fcntl.ioctl(self.listener, SECCOMP_IOCTL_NOTIF_RECV, request, True)
        except OSError as exc:
            if exc.errno in (errno.ENOENT, errno.EINTR):
                return exc.errno == errno.EINTR
            raise
        notif_id, caller, _flags, number, _arch, _ip, *args = struct.unpack(NOTIF_FORMAT, bytes(request))
        error = self.decide(self.names.get(number), caller, args)
        response = struct.pack(RESP_FORMAT, notif_id, 0, -error, 0)
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

    def kill_tree(self):
        """Like the PID namespace's teardown: when the root is gone, every remaining descendant is killed."""
        for entry in PROC.iterdir():
            if not entry.name.isdigit() or int(entry.name) in (self.root, self.launcher):
                continue
            try:
                fd = self.pinned(int(entry.name))
            except OSError:
                continue
            try:
                if self.descendant(int(entry.name)):
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
            except OSError:
                pass
            finally:
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
