#!/usr/bin/env python3
"""Fail-closed verifier: workspace filesystem authority, no network, no inherited secrets.

Linux uses Landlock and seccomp inherited by every child (including edited tests),
plus a private user/mount/PID namespace when the kernel allows one: `.git` is then a
read-only bind mount, /proc and /dev/shm are private, and signals cannot leave the
sandbox. Without a usable namespace (Ubuntu's AppArmor userns restriction, containers:
unshare refused, or unshare granted but mount denied) the limited mode grants the
workspace entry by entry so `.git` stays read-only; new top-level entries are then not
possible, signals go through the launcher and reach only the verifier's own processes
(verify_signals.py), and shared memory is the host's /dev/shm by name, without listing.
The mode is recorded for the job result. macOS uses sandbox-exec with an explicit Mach
service allowlist and `.git` denied. There is deliberately no unsandboxed fallback.

The repository metadata must stay immutable: a verifier that could write
`.git/config` (core.fsmonitor, core.hooksPath, filters) or `.git/hooks` would get
unsandboxed host execution from the next `git status` anyone runs there.
"""
import ctypes
import errno
import json
import os
from pathlib import Path
import socket
import sys
import subprocess
import tempfile

sys.dont_write_bytecode = True  # The skill folder is installed file by file; no __pycache__ may appear in it.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verify_signals  # noqa: E402

# Landlock access rights (ABI 3: through TRUNCATE).
EXECUTE, WRITE_FILE, READ_FILE, READ_DIR = 1, 2, 4, 8
REMOVE_FILE, MAKE_REG, TRUNCATE = 1 << 5, 1 << 8, 1 << 14
ALL_ACCESS = (1 << 15) - 1
FILE_ACCESS = EXECUTE | WRITE_FILE | READ_FILE | TRUNCATE
READ_ONLY = EXECUTE | READ_FILE | READ_DIR
# Limited mode's /dev/shm: create, open, size and remove objects by name; no listing, no directories, no execution.
SHM_BY_NAME = READ_FILE | WRITE_FILE | TRUNCATE | MAKE_REG | REMOVE_FILE
CLONE_NEWNS, CLONE_NEWUSER, CLONE_NEWPID, CLONE_NEWNET = 0x20000, 0x10000000, 0x20000000, 0x40000000
MS_RDONLY, MS_REMOUNT, MS_BIND, MS_REC, MS_PRIVATE, MS_NOSUID, MS_NODEV = 1, 32, 4096, 16384, 1 << 18, 2, 4
SCMP_ACT_ALLOW, SCMP_ACT_ERRNO, SCMP_ACT_NOTIFY = 0x7fff0000, 0x50000, 0x7fc00000
SECCOMP_SET_MODE_FILTER, FLAG_NEW_LISTENER, FLAG_WAIT_KILLABLE_RECV = 1, 1 << 3, 1 << 5
PR_SET_NO_NEW_PRIVS, PR_SET_CHILD_SUBREAPER = 38, 36
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
MODE_NAMESPACED, MODE_LIMITED, MODE_SEATBELT = 'namespaced', 'fallback', 'seatbelt'
LIMITED_NOTE = ('no user namespace; .git is read-only entry by entry, new top-level workspace entries are denied, '
                'signals reach only the verifier\'s own processes, shared memory is the host\'s /dev/shm by name')


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
    """Install the filter. Returns the user-notification listener when signals are supervised instead of denied."""
    sec = ctypes.CDLL('libseccomp.so.2', use_errno=True)
    sec.seccomp_init.restype = ctypes.c_void_p
    sec.seccomp_rule_add.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint]
    sec.seccomp_rule_add_array.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint, ctypes.c_void_p]
    sec.seccomp_load.argtypes = [ctypes.c_void_p]
    sec.seccomp_notify_fd.argtypes = [ctypes.c_void_p]
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
        for name in DENIED_SYSCALLS:
            deny(name)
        if not signals_confined:
            # Without a PID namespace the launcher decides kill/tkill/tgkill against the process tree
            # (verify_signals.py); pidfd signalling stays denied outright.
            for name in verify_signals.SIGNAL_SYSCALLS:
                deny(name, SCMP_ACT_NOTIFY if name in verify_signals.SUPERVISED_SYSCALLS else eperm)
            # Without a PID namespace an owner pid names a host process; owning one's own fds needs no owner call.
            for name, command in verify_signals.SIGNAL_OWNER_CALLS:
                deny(name, eperm, ArgCmp(1, SCMP_CMP_MASKED_EQ, verify_signals.CMD_MASK, command))
        # AF_UNIX pairs (stdio pipes of node, asyncio's self-pipe) are not network; nothing else is created.
        deny('socketpair', eperm, ArgCmp(0, SCMP_CMP_NE, AF_UNIX, 0))
        namespace_flags = CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID | CLONE_NEWNET
        deny('clone', eperm, ArgCmp(0, SCMP_CMP_MASKED_EQ, namespace_flags, namespace_flags))
        for flag in (CLONE_NEWUSER, CLONE_NEWNS, CLONE_NEWPID, CLONE_NEWNET):
            deny('clone', eperm, ArgCmp(0, SCMP_CMP_MASKED_EQ, flag, flag))
        deny('clone3', SCMP_ACT_ERRNO | errno.ENOSYS)  # libc falls back to clone, which is filtered above.
        if signals_confined:
            if sec.seccomp_load(ctx) != 0:
                raise OSError('seccomp load failed')
            return None
        return install_with_listener(sec, ctx)
    finally:
        sec.seccomp_release(ctx)


class Program(ctypes.Structure):
    _fields_ = [('len', ctypes.c_ushort), ('filter', ctypes.c_void_p)]


def install_with_listener(sec, ctx):
    """Load the exported filter through seccomp(2) with WAIT_KILLABLE_RECV, which libseccomp 2.5 cannot set.

    Without it a signal delivered to the verifier while the launcher is answering its request (its own self-signal,
    a child's SIGCHLD) would cancel the request and return EINTR instead of the signal being sent."""
    sec.seccomp_export_bpf.argtypes = [ctypes.c_void_p, ctypes.c_int]
    reader, writer = os.pipe()
    try:
        if sec.seccomp_export_bpf(ctx, writer) != 0:
            raise OSError('seccomp export failed')
        os.close(writer)
        writer = None
        with os.fdopen(reader, 'rb') as pipe:
            program = pipe.read()
    finally:
        if writer is not None:
            os.close(writer)
    if not program or len(program) % 8:
        raise OSError('seccomp export produced no program')
    buffer = ctypes.create_string_buffer(program, len(program))
    prog = Program(len(program) // 8, ctypes.addressof(buffer))
    number = sec.seccomp_syscall_resolve_name(b'seccomp')
    lib = libc()
    listener = lib.syscall(number, SECCOMP_SET_MODE_FILTER, FLAG_NEW_LISTENER | FLAG_WAIT_KILLABLE_RECV, ctypes.byref(prog))
    return checked(listener, 'seccomp install with listener failed')


def supervised_syscalls():
    """Syscall number -> name for the signal calls the launcher answers and those it makes on their behalf,
    resolved for this architecture."""
    sec = ctypes.CDLL('libseccomp.so.2')
    numbers = {}
    for name in verify_signals.SUPERVISED_SYSCALLS + verify_signals.HELPER_SYSCALLS:
        number = sec.seccomp_syscall_resolve_name(name.encode())
        if number >= 0:
            numbers[number] = name
    return numbers


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
    """Irreversible: Landlock then seccomp. Returns the signal listener in limited mode, None when namespaced."""
    lib = libc()
    checked(lib.prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0))
    rules = [(p, READ_ONLY) for p in READABLE] + [(p, READ_FILE | WRITE_FILE) for p in WRITABLE_DEVICES]
    rules += [(str(p), READ_FILE | READ_DIR) for p in git_dir(workspace)]
    rules += workspace_rules(workspace, namespaced) + [(temporary, ALL_ACCESS)] + extras
    landlock(rules)
    return seccomp(signals_confined=namespaced)


def powerless_namespace(exc):
    """AppArmor's unprivileged_userns restriction: unshare succeeds, the namespace has no mount capability."""
    return isinstance(exc, OSError) and exc.errno in (errno.EPERM, errno.EACCES)


def namespaced_run(workspace, temporary, command, env, report):
    """Runs in its own forked process: enter the namespaces, fork their PID 1, mount, confine and exec the verifier.

    Writes b'namespaced' to `report` once the mounts are in place, b'fallback' when no usable namespace exists
    (unshare refused, or granted but mount/id maps denied); the caller then takes the limited mode. Returns the
    verifier's exit code (in the fallback case nothing ran)."""
    try:
        entered = unshare(CLONE_NEWUSER | CLONE_NEWNS | CLONE_NEWPID, optional=True)
    except OSError as exc:
        if not powerless_namespace(exc):
            raise
        entered = False
    if not entered:
        os.write(report, b'fallback')
        return 0
    init = os.fork()  # PID 1 of the new namespace; its exit kills every verifier process.
    if init == 0:
        try:
            extras = private_mounts(workspace)
            # A nested user namespace locks the inherited mounts: even with mount rights, `.git` cannot be remounted.
            unshare(CLONE_NEWUSER | CLONE_NEWNS)
        except OSError as exc:
            if not powerless_namespace(exc):
                raise
            os.write(report, b'fallback')
            os._exit(0)
        os.write(report, b'namespaced')
        confine(workspace, temporary, True, extras)
        os.chdir(workspace)
        os.execve('/bin/sh', ['/bin/sh', '-c', command], env)
    _, status = os.waitpid(init, 0)
    return os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)


def limited_run(workspace, temporary, command, env, to_launcher):
    """Limited mode in the launcher's child itself: own process group, Landlock entry by entry, supervised signals."""
    print('code-job: verification sandbox: ' + LIMITED_NOTE, file=sys.stderr)
    sys.stderr.flush()
    os.setpgid(0, 0)  # kill(0)/killpg from the verifier never name a host group.
    extras = [('/dev/shm', SHM_BY_NAME)] if os.path.isdir('/dev/shm') else []
    listener = confine(workspace, temporary, False, extras)
    socket.send_fds(to_launcher, [MODE_LIMITED.encode()], [listener])
    os.close(listener)
    to_launcher.close()
    os.chdir(workspace)
    os.execve('/bin/sh', ['/bin/sh', '-c', command], env)


def linux_child(workspace, temporary, command, env, to_launcher):
    """Runs in the launcher's child; reports the mode to the launcher, then returns the verifier's exit code or
    execs it. The namespace attempt happens in a further child so this process can still take the limited mode."""
    if namespaces_requested():
        reader, writer = os.pipe()
        attempt = os.fork()
        if attempt == 0:
            os.close(reader)
            os._exit(namespaced_run(workspace, temporary, command, env, writer))
        os.close(writer)
        with os.fdopen(reader, 'rb') as pipe:
            report = pipe.read()
        if report == b'namespaced':
            to_launcher.sendall(MODE_NAMESPACED.encode())
            to_launcher.close()
        _, status = os.waitpid(attempt, 0)
        if report == b'namespaced' or report == b'':
            # An empty report means the attempt failed before mounting; its error is on the launcher's pipe.
            return os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
    limited_run(workspace, temporary, command, env, to_launcher)


def linux(workspace, temporary, command, env, mode_file=None):
    """Fork so only the child receives irreversible restrictions; a setup failure is reported, never bypassed.

    The launcher stays unconfined: in limited mode it answers the verifier's signal requests."""
    lib = libc()
    checked(lib.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0))  # Orphaned verifier processes stay in this tree.
    reader, writer = os.pipe()
    launcher_end, child_end = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    pid = os.fork()
    if pid == 0:
        os.close(reader)
        launcher_end.close()
        try:
            code = linux_child(workspace, temporary, command, env, child_end)
        except BaseException as exc:  # noqa: BLE001 - any setup failure must refuse, not run unsandboxed
            os.write(writer, (str(exc) or type(exc).__name__).encode())
            os._exit(77)
        os._exit(code)
    os.close(writer)
    child_end.close()
    mode_bytes, fds, _, _ = socket.recv_fds(launcher_end, 32, 1)
    launcher_end.close()
    mode = mode_bytes.decode(errors='replace')
    if mode in (MODE_NAMESPACED, MODE_LIMITED):
        record_mode(mode_file, mode)
    if fds:
        try:
            verify_signals.supervise(fds[0], pid, supervised_syscalls())
        finally:
            os.close(fds[0])
    with os.fdopen(reader, 'rb') as pipe:
        message = pipe.read().decode(errors='replace')
    _, status = os.waitpid(pid, 0)
    if message:
        raise OSError(message)
    return os.waitstatus_to_exitcode(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)


def record_mode(mode_file, mode):
    """The sandbox mode for the job record: written by the unconfined launcher to a path the verifier cannot reach."""
    if mode_file:
        Path(mode_file).write_text(mode + '\n')


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
    mode_file = sys.argv[3] if len(sys.argv) > 3 else None  # code-job records the mode in the job result.
    # Host HOME, tokens, proxies, plugin variables, shell startup and Python paths are never inherited.
    with tempfile.TemporaryDirectory(prefix='swarmhub-verify-') as temporary:
        env = {'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': temporary, 'TMPDIR': temporary,
               'LANG': 'C', 'PYTHONDONTWRITEBYTECODE': '1', 'GIT_CONFIG_GLOBAL': '/dev/null',
               'GIT_CONFIG_SYSTEM': '/dev/null'}
        if sys.platform == 'darwin':
            env['PATH'] = '/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin'
            profile = darwin_profile(workspace, temporary)
            record_mode(mode_file, MODE_SEATBELT)
            return subprocess.call(['/usr/bin/sandbox-exec', '-p', profile, '/bin/sh', '-c', command], env=env, cwd=workspace)
        elif sys.platform == 'linux':
            # The standalone launcher is single-threaded; only its children receive irreversible restrictions.
            return linux(workspace, temporary, command, env, mode_file)
        else:
            raise OSError('unsupported verification sandbox')


def run():
    try:
        return main()
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print('code-job: verification refused: ' + str(exc), file=sys.stderr)
        return 77


if __name__ == '__main__':
    sys.exit(run())
