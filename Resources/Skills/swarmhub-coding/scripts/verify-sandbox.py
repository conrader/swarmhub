#!/usr/bin/env python3
"""Fail-closed verifier: workspace filesystem authority, no network, no inherited secrets.

Linux uses Landlock and seccomp inherited by every child (including edited tests).
macOS uses sandbox-exec. There is deliberately no unsandboxed fallback.
"""
import ctypes
import errno
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile


def linux(workspace, temporary):
    libc = ctypes.CDLL(None, use_errno=True)
    def checked(value):
        if value < 0:
            raise OSError(ctypes.get_errno(), 'verification sandbox unavailable')
        return value
    checked(libc.prctl(38, 1, 0, 0, 0))  # NO_NEW_PRIVS
    abi = checked(libc.syscall(444, 0, 0, 1))
    if abi < 3:
        raise OSError('Landlock ABI 3 required (truncate/refer protection)')
    access = (1 << 15) - 1  # FS rights through TRUNCATE
    class Ruleset(ctypes.Structure):
        _fields_ = [('handled_access_fs', ctypes.c_uint64)]
    class Rule(ctypes.Structure):
        _pack_ = 1
        _fields_ = [('allowed_access', ctypes.c_uint64), ('parent_fd', ctypes.c_int)]
    rules = Ruleset(access)
    fd = checked(libc.syscall(444, ctypes.byref(rules), ctypes.sizeof(rules), 0))
    try:
        # No host home, credentials, other projects, /proc or sockets are visible.
        readable = ['/usr', '/bin', '/lib', '/lib64', '/etc/ld.so.cache', '/etc/localtime',
                    '/dev/null', '/dev/urandom', '/dev/random']
        for name, rights in [(p, 1 | 4 | 8) for p in readable] + [(str(workspace), access), (temporary, access)]:
            if not os.path.exists(name):
                continue
            parent = os.open(name, os.O_PATH | os.O_CLOEXEC)
            try:
                if not os.path.isdir(name):
                    rights &= ~(8 | 16 | 32 | 64 | 128 | 256 | 512 | 1024 | 2048 | 4096 | 8192)
                rule = Rule(rights, parent)
                checked(libc.syscall(445, fd, 1, ctypes.byref(rule), 0))
            finally:
                os.close(parent)
        checked(libc.syscall(446, fd, 0))
    finally:
        os.close(fd)
    sec = ctypes.CDLL('libseccomp.so.2', use_errno=True)
    sec.seccomp_init.restype = ctypes.c_void_p
    sec.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint]
    sec.seccomp_load.argtypes = [ctypes.c_void_p]
    sec.seccomp_release.argtypes = [ctypes.c_void_p]
    ctx = sec.seccomp_init(0x7fff0000)  # ALLOW; prohibit all socket creation and privilege escape mechanisms.
    if not ctx:
        raise OSError('seccomp unavailable')
    try:
        for name in ('socket', 'socketpair', 'connect', 'bind', 'listen', 'accept', 'accept4',
                     'ptrace', 'process_vm_writev', 'process_vm_readv', 'mount', 'io_uring_setup',
                     'kill', 'tkill', 'tgkill', 'pidfd_open', 'pidfd_getfd', 'pidfd_send_signal',
                     'bpf', 'perf_event_open', 'keyctl', 'add_key', 'request_key'):
            number = sec.seccomp_syscall_resolve_name(name.encode())
            if number >= 0 and sec.seccomp_rule_add(ctx, 0x50000 | errno.EPERM, number, 0) != 0:
                raise OSError('seccomp rule failed')
        if sec.seccomp_load(ctx) != 0:
            raise OSError('seccomp load failed')
    finally:
        sec.seccomp_release(ctx)


def main():
    workspace = Path(sys.argv[1]).resolve(strict=True)
    command = sys.argv[2]
    # Host HOME, tokens, proxies, plugin variables, shell startup and Python paths are never inherited.
    with tempfile.TemporaryDirectory(prefix='swarmhub-verify-') as temporary:
        env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': temporary, 'TMPDIR': temporary,
               'LANG': 'C', 'PYTHONDONTWRITEBYTECODE': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
               'GIT_CONFIG_SYSTEM': '/dev/null'}
        if sys.platform == 'darwin':
            quote = json.dumps
            profile = '(version 1)(deny default)(allow process*)(allow sysctl-read)(allow mach-lookup)'
            for path in ('/usr', '/bin', '/sbin', '/System', '/Library', '/private/etc', '/dev'):
                profile += '(allow file-read* (subpath ' + quote(path) + '))'
            for path in (str(workspace), temporary, os.path.realpath(temporary)):
                profile += '(allow file-read* file-write* (subpath ' + quote(path) + '))'
            return subprocess.call(['/usr/bin/sandbox-exec', '-p', profile, '/bin/sh', '-c', command], env=env, cwd=workspace)
        elif sys.platform == 'linux':
            # The standalone launcher is single-threaded; only its child receives irreversible restrictions.
            return subprocess.call(['/bin/sh', '-c', command], env=env, cwd=workspace,
                                   preexec_fn=lambda: linux(workspace, temporary))
        else:
            raise OSError('unsupported verification sandbox')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print('code-job: verification refused: ' + str(exc), file=sys.stderr)
        sys.exit(77)
