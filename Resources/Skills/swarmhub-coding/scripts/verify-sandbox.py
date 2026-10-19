#!/usr/bin/env python3
"""Fail-closed verifier: workspace filesystem authority, no network, no inherited secrets.

Linux uses Landlock and seccomp inherited by every child (including edited tests),
plus a private user/mount/PID namespace when the kernel allows one: `.git` is then a
read-only bind mount, /proc and /dev/shm are private, and signals cannot leave the
sandbox. Without namespaces (Ubuntu's AppArmor userns restriction, containers) the
workspace is granted entry by entry so `.git` stays read-only; new top-level entries
are then not possible and signals to other processes stay denied.
macOS uses sandbox-exec with an explicit Mach service allowlist and `.git` denied.
There is deliberately no unsandboxed fallback.

The repository metadata must stay immutable: a verifier that could write
`.git/config` (core.fsmonitor, core.hooksPath, filters) or `.git/hooks` would get
unsandboxed host execution from the next `git status` anyone runs there.
"""
import ctypes
import errno
import json
import os
from pathlib import Path
import sys
import subprocess
import tempfile

# Landlock access rights (ABI 3: through TRUNCATE).
EXECUTE, WRITE_FILE, READ_FILE, READ_DIR = 1, 2, 4, 8
ALL_ACCESS = (1 << 15) - 1
FILE_ACCESS = EXECUTE | WRITE_FILE | READ_FILE | (1 << 14)  # TRUNCATE
READ_ONLY = EXECUTE | READ_FILE | READ_DIR
CLONE_NEWNS, CLONE_NEWUSER, CLONE_NEWPID, CLONE_NEWNET = 0x20000, 0x10000000, 0x20000000, 0x40000000
MS_RDONLY, MS_REMOUNT, MS_BIND, MS_REC, MS_PRIVATE, MS_NOSUID, MS_NODEV = 1, 32, 4096, 16384, 1 << 18, 2, 4
SCMP_ACT_ALLOW, SCMP_ACT_ERRNO = 0x7fff0000, 0x50000
SCMP_CMP_NE, SCMP_CMP_MASKED_EQ = 1, 7
AF_UNIX = 1

READABLE = ['/usr', '/bin', '/lib', '/lib32', '/lib64', '/etc/ld.so.cache', '/etc/ld.so.conf', '/etc/ld.so.conf.d',
            '/etc/localtime', '/etc/timezone', '/etc/passwd', '/etc/group', '/etc/nsswitch.conf', '/etc/hosts',
            '/etc/resolv.conf', '/etc/ssl', '/etc/ca-certificates', '/etc/alternatives', '/etc/os-release',
            '/etc/python3', '/etc/python3.12', '/etc/python3.13', '/etc/python3.14', '/dev/urandom', '/dev/random']
WRITABLE_DEVICES = ['/dev/null', '/dev/zero', '/dev/full']
DENIED_SYSCALLS = ('socket', 'connect', 'bind', 'listen', 'accept', 'accept4', 'ptrace', 'process_vm_writev',
                   'process_vm_readv', 'mount', 'umount2', 'mount_setattr', 'open_tree', 'move_mount', 'fsopen',
                   'fsconfig', 'fsmount', 'fspick', 'pivot_root', 'unshare', 'setns', 'io_uring_setup', 'bpf',
                   'perf_event_open', 'keyctl', 'add_key', 'request_key', 'pidfd_getfd')
SIGNAL_SYSCALLS = ('kill', 'tkill', 'tgkill', 'pidfd_open', 'pidfd_send_signal')


class ArgCmp(ctypes.Structure):
    _fields_ = [('arg', ctypes.c_uint), ('op', ctypes.c_int), ('datum_a', ctypes.c_uint64), ('datum_b', ctypes.c_uint64)]


def libc():
    return ctypes.CDLL(None, use_errno=True)


def checked(value, what='verification sandbox unavailable'):
    if value < 0:
        raise OSError(ctypes.get_errno(), what)
    return value


def git_dir(workspace):
    """The repository metadata paths: `.git` and, for a gitfile (worktree), its target and common dir.

    Parsed by hand: running git here would execute the very config this sandbox protects.
    """
    dot = workspace / '.git'
    paths = []
    if dot.is_file():
        try:
            line = dot.read_text(errors='replace').splitlines()[0]
        except (OSError, IndexError):
            line = ''
        if line.startswith('gitdir:'):
            target = Path(line[7:].strip())
            target = (workspace / target).resolve() if not target.is_absolute() else target
            paths.append(target)
            common = target / 'commondir'
            if common.is_file():
                paths.append((target / common.read_text().strip()).resolve())
    return paths


def namespaces_requested():
    return os.environ.get('SWARMHUB_VERIFY_NAMESPACES', '1') != '0'


def write_id_maps(uid, gid):
    # Map the caller onto itself; inside the new namespace getuid() already reports the overflow id.
    for name, text in (('setgroups', 'deny'), ('gid_map', f'{gid} {gid} 1'), ('uid_map', f'{uid} {uid} 1')):
        fd = os.open('/proc/self/' + name, os.O_WRONLY)
        try:
            os.write(fd, text.encode())
        finally:
            os.close(fd)


def unshare(flags, optional=False):
    """Enter new namespaces mapped onto the caller. Returns False only when the kernel refuses the request
    outright (no unprivileged user namespaces); a failure after entering is an error, never a fallback."""
    lib = libc()
    uid, gid = os.getuid(), os.getgid()
    if lib.unshare(flags) != 0:
        if optional:
            return False
        raise OSError(ctypes.get_errno(), 'unshare')
    write_id_maps(uid, gid)
    return True


def mount(source, target, fstype, flags, data=None):
    lib = libc()
    rc = lib.mount(source.encode() if source else None, target.encode(), fstype.encode() if fstype else None,
                   ctypes.c_ulong(flags), data.encode() if data else None)
    if rc != 0:
        raise OSError(ctypes.get_errno(), 'mount ' + target)


def private_mounts(workspace):
    """Read-only `.git`, a /proc for this PID namespace and a private /dev/shm, none visible to the host."""
    mount(None, '/', None, MS_REC | MS_PRIVATE)  # Never propagate into the host's namespace.
    dot = workspace / '.git'
    if dot.exists():
        mount(str(dot), str(dot), None, MS_BIND)
        mount(None, str(dot), None, MS_BIND | MS_REMOUNT | MS_RDONLY)
    extras = []
    try:
        mount('proc', '/proc', 'proc', MS_NOSUID | MS_NODEV)
        extras.append(('/proc', READ_FILE | READ_DIR))
    except OSError:
        pass  # A masked /proc (containers) stays unreadable instead.
    if os.path.isdir('/dev/shm'):
        try:
            mount('tmpfs', '/dev/shm', 'tmpfs', MS_NOSUID | MS_NODEV, 'mode=1777')
            extras.append(('/dev/shm', ALL_ACCESS))
        except OSError:
            pass
    return extras


def landlock(rules):
    lib = libc()
    abi = checked(lib.syscall(444, 0, 0, 1))
    if abi < 3:
        raise OSError('Landlock ABI 3 required (truncate/refer protection)')

    class Ruleset(ctypes.Structure):
        _fields_ = [('handled_access_fs', ctypes.c_uint64)]

    class Rule(ctypes.Structure):
        _pack_ = 1
        _fields_ = [('allowed_access', ctypes.c_uint64), ('parent_fd', ctypes.c_int)]

    fd = checked(lib.syscall(444, ctypes.byref(Ruleset(ALL_ACCESS)), ctypes.sizeof(Ruleset), 0))
    try:
        for name, rights in rules:
            if not os.path.exists(name):
                continue
            parent = os.open(name, os.O_PATH | os.O_CLOEXEC)
            try:
                if not os.path.isdir(name):
                    rights &= FILE_ACCESS
                checked(lib.syscall(445, fd, 1, ctypes.byref(Rule(rights, parent)), 0))
            finally:
                os.close(parent)
        checked(lib.syscall(446, fd, 0))
    finally:
        os.close(fd)


def seccomp(signals_confined):
    sec = ctypes.CDLL('libseccomp.so.2', use_errno=True)
    sec.seccomp_init.restype = ctypes.c_void_p
    sec.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint]
    sec.seccomp_rule_add_array.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint, ctypes.c_void_p]
    sec.seccomp_load.argtypes = [ctypes.c_void_p]
    sec.seccomp_release.argtypes = [ctypes.c_void_p]
    ctx = sec.seccomp_init(SCMP_ACT_ALLOW)  # Prohibit sockets, namespace/mount changes and privilege escape mechanisms.
    if not ctx:
        raise OSError('seccomp unavailable')
    eperm = SCMP_ACT_ERRNO | errno.EPERM

    def deny(name, action=eperm, *conditions):
        number = sec.seccomp_syscall_resolve_name(name.encode())
        if number < 0:
            return
        if conditions:
            array = (ArgCmp * len(conditions))(*conditions)
            rc = sec.seccomp_rule_add_array(ctx, action, number, len(conditions), array)
        else:
            rc = sec.seccomp_rule_add(ctx, action, number, 0)
        if rc != 0:
            raise OSError('seccomp rule failed: ' + name)

    try:
        for name in DENIED_SYSCALLS + (() if signals_confined else SIGNAL_SYSCALLS):
            deny(name)
        # AF_UNIX pairs (stdio pipes of node, asyncio's self-pipe) are not network; nothing else is created.
        deny('socketpair', eperm, ArgCmp(0, SCMP_CMP_NE, AF_UNIX, 0))
        namespace_flags = CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWNET
        deny('clone', eperm, ArgCmp(0, SCMP_CMP_MASKED_EQ, namespace_flags, namespace_flags))
        for flag in (CLONE_NEWUSER, CLONE_NEWNS, CLONE_NEWPID, CLONE_NEWNET):
            deny('clone', eperm, ArgCmp(0, SCMP_CMP_MASKED_EQ, flag, flag))
        deny('clone3', SCMP_ACT_ERRNO | errno.ENOSYS)  # libc falls back to clone, which is filtered above.
        if sec.seccomp_load(ctx) != 0:
            raise OSError('seccomp load failed')
    finally:
        sec.seccomp_release(ctx)


def workspace_rules(workspace, namespaced):
    """Namespaced: the whole workspace (`.git` is a read-only mount). Otherwise entry by entry around `.git`."""
    if namespaced:
        return [(str(workspace), ALL_ACCESS)]
    rules = [(str(workspace), READ_ONLY)]
    for entry in sorted(workspace.iterdir()):
        # A rule is attached to the opened inode: granting a symlink would grant its target (a link to
        # .git/config would make the config writable). Links get no rule; access resolves against the target's path.
        if entry.is_symlink():
            continue
        rules.append((str(entry), READ_FILE | READ_DIR if entry.name == '.git' else ALL_ACCESS))
    return rules


def confine(workspace, temporary, namespaced, extras):
    lib = libc()
    checked(lib.prctl(38, 1, 0, 0, 0))  # NO_NEW_PRIVS
    rules = [(p, READ_ONLY) for p in READABLE] + [(p, READ_FILE | WRITE_FILE) for p in WRITABLE_DEVICES]
    rules += [(str(p), READ_FILE | READ_DIR) for p in git_dir(workspace)]
    rules += workspace_rules(workspace, namespaced) + [(temporary, ALL_ACCESS)] + extras
    landlock(rules)
    seccomp(signals_confined=namespaced)


def linux_child(workspace, temporary, command, env):
    """Runs in the launcher's child; returns the verifier's exit code or execs it."""
    namespaced = namespaces_requested() and unshare(CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID, optional=True)
    if not namespaced:
        print('code-job: verification sandbox: no user namespace; .git is read-only entry by entry, '
              'new top-level workspace entries and signals to other processes are denied', file=sys.stderr)
        sys.stderr.flush()
        confine(workspace, temporary, False, [])
        os.chdir(workspace)
        os.execve('/bin/sh', ['/bin/sh', '-c', command], env)
    init = os.fork()  # PID 1 of the new namespace; its exit kills every verifier process.
    if init == 0:
        extras = private_mounts(workspace)
        # A nested user namespace locks the inherited mounts: even with mount rights, `.git` cannot be remounted.
        unshare(CLONE_NEWUSER | CLONE_NEWNS)
        confine(workspace, temporary, True, extras)
        os.chdir(workspace)
        os.execve('/bin/sh', ['/bin/sh', '-c', command], env)
    _, status = os.waitpid(init, 0)
    return os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)


def linux(workspace, temporary, command, env):
    """Fork so only the child receives irreversible restrictions; a setup failure is reported, never bypassed."""
    reader, writer = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(reader)
        try:
            code = linux_child(workspace, temporary, command, env)
        except BaseException as exc:  # noqa: BLE001 - any setup failure must refuse, not run unsandboxed
            os.write(writer, (str(exc) or type(exc).__name__).encode())
            os._exit(77)
        os._exit(code)
    os.close(writer)
    with os.fdopen(reader, 'rb') as pipe:
        message = pipe.read().decode(errors='replace')
    _, status = os.waitpid(pid, 0)
    if message:
        raise OSError(message)
    return os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)


# Mach services a shell, Python, git and build tools need. Not the pasteboard, LaunchServices (`open`),
# AppleEvents (`osascript`), SecurityServer/keychain or preferences: those reach outside the sandbox.
DARWIN_MACH_SERVICES = ('com.apple.system.opendirectoryd.libinfo', 'com.apple.system.DirectoryService.libinfo_v1',
                        'com.apple.system.logger', 'com.apple.system.notification_center')
DARWIN_RUNTIME = ('/usr', '/bin', '/sbin', '/System', '/Library/Developer', '/Library/Frameworks', '/Library/Apple',
                  '/private/var/db/dyld', '/opt/homebrew', '/Applications/Xcode.app')


def darwin_profile(workspace, temporary):
    quote = json.dumps
    profile = '(version 1)(deny default)(allow process*)(allow sysctl-read)(allow signal (target same-sandbox))'
    profile += '(allow ipc-posix-sem)(allow ipc-posix-shm*)'
    profile += '(allow mach-lookup' + ''.join(' (global-name ' + quote(s) + ')' for s in DARWIN_MACH_SERVICES) + ')'
    # dyld also needs to read the root directory itself before the shell starts.
    # A literal rule grants no access to files below it.
    profile += '(allow file-read* (literal "/"))'
    for path in ('/dev/null', '/dev/zero'):
        profile += '(allow file-write* (literal ' + quote(path) + '))'
    # Seatbelt treats executable mappings separately from file reads. Without
    # this right dyld can abort before /bin/sh runs, even for the builtin true.
    writable = (str(workspace), temporary, os.path.realpath(temporary))
    for path in DARWIN_RUNTIME:
        profile += '(allow file-read* file-map-executable (subpath ' + quote(path) + '))'
    for path in ('/private/etc', '/dev', '/private/var/db/xcode_select_link', '/private/var/select'):
        profile += '(allow file-read* (subpath ' + quote(path) + '))'
    for path in writable:
        profile += '(allow file-read* file-write* file-map-executable (subpath ' + quote(path) + '))'
    # realpath/getcwd must be able to stat ancestors, including macOS /tmp and
    # /var symlinks. Grant metadata on exact ancestors, not their other contents.
    ancestors = {'/etc', '/tmp', '/var', '/Library', '/Applications', '/opt'}
    for path in (*DARWIN_RUNTIME, '/private/etc', '/dev', *writable):
        ancestors.update(str(parent) for parent in Path(path).parents)
    for path in sorted(ancestors):
        profile += '(allow file-read-metadata (literal ' + quote(path) + '))'
    # Later rules win: the repository metadata stays immutable (config, hooks, worktree gitdir).
    for path in (workspace / '.git', *git_dir(workspace)):
        profile += '(deny file-write* (subpath ' + quote(str(path)) + '))'
        profile += '(deny file-write* (literal ' + quote(str(path)) + '))'
    return profile


def main():
    workspace = Path(sys.argv[1]).resolve(strict=True)
    command = sys.argv[2]
    # Host HOME, tokens, proxies, plugin variables, shell startup and Python paths are never inherited.
    with tempfile.TemporaryDirectory(prefix='swarmhub-verify-') as temporary:
        env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': temporary, 'TMPDIR': temporary,
               'LANG': 'C', 'PYTHONDONTWRITEBYTECODE': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
               'GIT_CONFIG_SYSTEM': '/dev/null'}
        if sys.platform == 'darwin':
            env['PATH'] = '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin'
            profile = darwin_profile(workspace, temporary)
            return subprocess.call(['/usr/bin/sandbox-exec', '-p', profile, '/bin/sh', '-c', command], env=env, cwd=workspace)
        elif sys.platform == 'linux':
            # The standalone launcher is single-threaded; only its children receive irreversible restrictions.
            return linux(workspace, temporary, command, env)
        else:
            raise OSError('unsupported verification sandbox')


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print('code-job: verification refused: ' + str(exc), file=sys.stderr)
        sys.exit(77)
