"""Self-only non-signal process operations for Linux's limited verifier.

PID-addressed CONTINUE uses only scalar self IDs: the blocked caller cannot have its PID
reused while executing the syscall. Never continue a checked foreign numeric PID.
PRIO_PGRP/USER and IOPRIO_WHO_PGRP/USER are refused, even with who=0: membership can
include host processes. Pointer arguments never contain a target PID here.

process_madvise uses a pidfd. The launcher discards inherited descriptors before
creating its own pipes; its private descriptors are CLOEXEC. A verifier can obtain
pidfds only for its own tree (brokered pidfd_open or CLONE_PIDFD); sockets/connect,
pidfd_getfd, io_uring and host /proc are unavailable. Thus even a concurrent fd
replacement after the fdinfo check cannot introduce a host-process pidfd.
"""
import ctypes
import errno
import os
from pathlib import Path
import stat

PID_CALLS = ('prlimit64', 'sched_setaffinity', 'sched_setscheduler', 'sched_setparam',
             'sched_setattr', 'move_pages', 'migrate_pages', 'get_robust_list')
SYSCALLS = PID_CALLS + ('setpriority', 'getpriority', 'ioprio_set', 'kcmp', 'pidfd_open', 'process_madvise')
CONTINUE = -1


def int32(value):
    return ctypes.c_int32(value & 0xffffffff).value


def tgid(caller):
    for line in Path('/proc/%d/status' % caller).read_text().splitlines():
        if line.startswith('Tgid:'):
            return int(line.split()[1])
    raise OSError(errno.ESRCH, 'caller gone')


def decide(name, caller, args):
    own = {caller, tgid(caller)}
    values = [int32(value) for value in args]
    if name in PID_CALLS:
        allowed = values[0] in own | {0}
    elif name in ('setpriority', 'getpriority', 'ioprio_set'):
        # priority uses PRIO_PROCESS=0; ioprio uses IOPRIO_WHO_PROCESS=1.
        allowed = values[0] == (1 if name == 'ioprio_set' else 0) and values[1] in own | {0}
    elif name == 'kcmp':
        allowed = values[0] in own and values[1] in own
    elif name == 'process_madvise':
        try:
            info = Path('/proc/%d/fdinfo/%d' % (caller, values[0])).read_text()
            allowed = any(line.startswith('Pid:') and int(line.split()[1]) in own for line in info.splitlines())
        except (OSError, ValueError):
            allowed = False
    else:
        allowed = False
    return CONTINUE if allowed else errno.EPERM


def close_inherited_descriptors():
    """No host pidfd/socket may enter the sandbox, including disguised stdio.

    Called before constructing the launcher's IPC. Keep ordinary stdio files,
    pipes and devices, but replace sockets/anonymous kernel handles with null.
    """
    for entry in Path('/proc/self/fd').iterdir():
        fd = int(entry.name)
        try:
            if fd > 2:
                os.close(fd)
            elif not any(check(os.fstat(fd).st_mode) for check in (stat.S_ISREG, stat.S_ISFIFO, stat.S_ISCHR)):
                null = os.open('/dev/null', os.O_RDWR)
                os.dup2(null, fd)
                if null != fd:
                    os.close(null)
        except OSError as exc:
            if exc.errno != errno.EBADF:
                raise
