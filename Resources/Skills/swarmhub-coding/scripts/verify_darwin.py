"""Explicit runtime and repository grants for deny-by-default Seatbelt verification."""
import errno
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import threading
import time

# Mach services a shell, Python, git and build tools need. Not the pasteboard, LaunchServices (`open`),
# AppleEvents (`osascript`), SecurityServer/keychain or preferences: those reach outside the sandbox.
DARWIN_MACH_SERVICES = ('com.apple.system.opendirectoryd.libinfo', 'com.apple.system.DirectoryService.libinfo_v1',
                        'com.apple.system.logger', 'com.apple.system.notification_center')
DARWIN_RUNTIME = ('/usr', '/bin', '/sbin', '/System', '/Library/Developer', '/Library/Frameworks', '/Library/Apple',
                  '/private/var/db/dyld', '/opt/homebrew', '/Applications/Xcode.app')

# Run in isolated system Python *inside* Seatbelt, before any workspace command.
# A parsed profile is not proof that this OS enforces socket creation restrictions.
# Probe without addresses, bind/connect/listen, DNS or sends, even if enforcement fails.
SOCKET_GUARD = '''import errno, os, socket, sys
def refuse(detail):
    print("code-job: verification refused: socket creation confinement " + detail, file=sys.stderr)
    sys.exit(77)
for family in (socket.AF_INET, socket.AF_INET6, socket.AF_UNIX):
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        try:
            endpoint = socket.socket(family, kind)
        except OSError as exc:
            if exc.errno not in (errno.EPERM, errno.EACCES):
                refuse("could not be verified: " + str(exc))
        else:
            endpoint.close()
            refuse("is unavailable for %s/%s" % (family, kind))
os.execv("/bin/sh", ["/bin/sh", "-c", sys.argv[1]])
'''


def guarded_command(command):
    # -I excludes workspace modules and user site packages from this check.
    return ['/usr/bin/python3', '-I', '-B', '-c', SOCKET_GUARD, command]


def darwin_profile(workspace, temporary, git_paths=()):
    quote = json.dumps
    profile = '(version 1)(deny default)(allow process*)(allow sysctl-read)(allow signal (target same-sandbox))'
    # network* controls use of endpoints, not socket(2) itself on the reported Mac.
    # WebKit also denies SYS_socket through syscall-unix. Leave socketpair available
    # for anonymous local IPC (asyncio and child stdio), as on Linux. These syscall
    # numbers are Darwin's bsd/kern/syscalls.master: socket=97, socket_delegate=450.
    # Numeric values avoid importing a system profile with additional grants.
    profile += '(allow syscall-unix)(deny syscall-unix (syscall-number 97 450))'
    profile += '(deny network*)(deny system-socket)'
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
    # The xcode-select shims read license state directly when cfprefsd is denied.
    selection = '/private/var/db/xcode_select_link'
    toolchain_files = ('/Library/Preferences/com.apple.dt.Xcode.plist',
                       '/Library/Preferences/com.apple.dt.CommandLineTools.plist', selection)
    for path in toolchain_files:
        profile += '(allow file-read* (literal ' + quote(path) + '))'
    selected = os.path.realpath(selection) if os.path.exists(selection) else None
    if selected:
        profile += '(allow file-read* file-map-executable (subpath ' + quote(selected) + '))'
    # Linked worktree gitdirs and commondir live outside the writable workspace.
    for path in git_paths:
        profile += '(allow file-read* (subpath ' + quote(str(path)) + '))'
    for path in DARWIN_RUNTIME:
        profile += '(allow file-read* file-map-executable (subpath ' + quote(path) + '))'
    for path in ('/private/etc', '/dev', '/private/var/db/xcode_select_link', '/private/var/select'):
        profile += '(allow file-read* (subpath ' + quote(path) + '))'
    for path in writable:
        profile += '(allow file-read* file-write* file-map-executable (subpath ' + quote(path) + '))'
    # realpath/getcwd must be able to stat ancestors, including macOS /tmp and
    # /var symlinks. Grant metadata on exact ancestors, not their other contents.
    ancestors = {'/etc', '/tmp', '/var', '/Library', '/Applications', '/opt'}
    for path in (*DARWIN_RUNTIME, '/private/etc', '/dev', *writable, *git_paths,
                 *toolchain_files, *([selected] if selected else [])):
        ancestors.update(str(parent) for parent in Path(path).parents)
    for path in sorted(ancestors):
        profile += '(allow file-read-metadata (literal ' + quote(path) + '))'
    # Later rules win: the repository metadata stays immutable (config, hooks, worktree gitdir).
    for path in (workspace / '.git', *git_paths):
        profile += '(deny file-write* (subpath ' + quote(str(path)) + '))'
        profile += '(deny file-write* (literal ' + quote(str(path)) + '))'
    return profile


# Teardown bounds. A killed group normally empties in milliseconds; members that outlive the deadline fail closed.
DRAIN_SECONDS = 5.0
MEMBERSHIP_INTERVAL = 0.25  # how often a group that still answers is checked for live (non-zombie) members
DESCENDANTS_REMAIN = 77
TEARDOWN_SIGNALS = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)  # code-job's kill_tree sends TERM first


class Interrupted(Exception):
    """Raised once by the launcher's signal handler to leave the wait; teardown still runs."""


def wait_exited(pid):
    """Block until child `pid` has exited, leaving it unreaped. The zombie keeps its PID, and so its process-group ID,
    from being reused while the group is signalled. macOS Python has no os.waitid; kqueue EVFILT_PROC reports exit."""
    if hasattr(select, 'kqueue'):
        return kqueue_wait(pid)
    if hasattr(os, 'waitid') and hasattr(os, 'WNOWAIT'):
        os.waitid(os.P_PID, pid, os.WEXITED | os.WNOWAIT)  # Linux (tests); the Linux verifier does not use this path.
        return None
    raise OSError('cannot wait for the verifier without reaping it')


def kqueue_wait(pid, kq=select):
    queue = kq.kqueue()
    try:
        try:
            queue.control([kq.kevent(pid, filter=kq.KQ_FILTER_PROC, flags=kq.KQ_EV_ADD | kq.KQ_EV_ONESHOT,
                                     fflags=kq.KQ_NOTE_EXIT)], 0)
        except ProcessLookupError:
            return None  # Already exited: only our unreaped child can hold this PID.
        while True:  # PEP 475: EINTR is retried unless a handler raises.
            for event in queue.control(None, 1):
                if event.flags & kq.KQ_EV_ERROR:
                    if event.data == errno.ESRCH:
                        return None
                    raise OSError(event.data, 'kqueue: ' + os.strerror(event.data))
                if event.ident == pid and event.fflags & kq.KQ_NOTE_EXIT:
                    return None
    finally:
        queue.close()


def signal_group(pgid, signum, killpg=os.killpg):
    """True while the group has members. EPERM means members remain that cannot be signalled."""
    try:
        killpg(pgid, signum)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def live_members(pgid, run=subprocess.run):
    """PIDs in the group that are not zombies; None if the process listing failed (callers fail closed)."""
    try:
        listing = run(['/bin/ps', '-A', '-o', 'pid=', '-o', 'pgid=', '-o', 'stat='], stdin=subprocess.DEVNULL,
                      capture_output=True, text=True, env={'PATH': '/usr/bin:/bin', 'LANG': 'C'}, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    if listing.returncode != 0:
        return None
    members = []
    for line in listing.stdout.splitlines():
        fields = line.split()
        if len(fields) < 3 or not fields[0].isdigit():
            return None  # Unparseable: unknown, not empty.
        if fields[1] == str(pgid) and not fields[2].startswith('Z'):
            members.append(int(fields[0]))
    return members


def drain(pgid, killpg=os.killpg, members=live_members, clock=time.monotonic, sleep=time.sleep, limit=DRAIN_SECONDS):
    """SIGKILL the group until it is empty. Returns [] when empty, else the live PIDs left (None if unknown).
    The kill is repeated: a member that was forking can add a child after the first one. Darwin's killpg skips
    zombies; where zombies still answer (Linux), the process listing decides."""
    start = checked = clock()
    pause = 0.005
    while signal_group(pgid, signal.SIGKILL, killpg):
        now = clock()
        if now - checked >= MEMBERSHIP_INTERVAL or now - start >= limit:
            checked = now
            remaining = members(pgid)
            if remaining == []:
                return []
            if now - start >= limit:
                return remaining
        sleep(pause)
        pause = min(pause * 2, 0.05)
    return []


def exit_code(returncode):
    return 128 - returncode if returncode < 0 else returncode


def run_grouped(argv, env, cwd, wait_exit=wait_exited, drain_group=drain):
    """Run the verifier as the leader of its own process group and tear the group down before the result is reported:
    background processes it left would otherwise keep changing the workspace. Order: wait for the leader's exit
    without reaping it, SIGKILL the group and wait (bounded) until it is empty, then reap. Every group signal is sent
    while the leader is alive or an unreaped zombie, so its group ID cannot have been reused. Members that survive
    fail closed (77). TERM/INT/HUP to the launcher stop the wait, run the same teardown and return 128+signal.
    A descendant that calls setsid() or setpgid() (or is spawned with POSIX_SPAWN_SETSID/SETPGROUP) leaves the group
    and is not reached: Seatbelt has no pidfd/subreaper equivalent."""
    state = {'waiting': False, 'signals': []}

    def interrupt(signum, _frame):
        state['signals'].append(signum)
        if state['waiting']:
            state['waiting'] = False
            raise Interrupted()

    main = threading.current_thread() is threading.main_thread()
    previous = {}
    if main:
        # An inherited SIGCHLD=SIG_IGN auto-reaps the leader on Darwin: its PID could be reused and wait() reports 0.
        previous[signal.SIGCHLD] = signal.signal(signal.SIGCHLD, signal.SIG_DFL)
        for signum in TEARDOWN_SIGNALS:
            previous[signum] = signal.signal(signum, interrupt)
    try:
        process = subprocess.Popen(argv, env=env, cwd=cwd, start_new_session=True)
        remaining = None
        try:
            try:
                state['waiting'] = True
                if not state['signals']:
                    wait_exit(process.pid)
                state['waiting'] = False
            except Interrupted:
                pass
            finally:
                state['waiting'] = False
                try:
                    remaining = drain_group(process.pid)
                except BaseException:
                    # Still unreaped, so both are safe; reaping a live leader would block forever.
                    for kill in (lambda: os.killpg(process.pid, signal.SIGKILL), process.kill):
                        try:
                            kill()
                        except OSError:
                            pass
                    raise
        finally:
            returncode = process.wait()  # The only reap; no group signal follows it.
        if remaining != []:
            detail = 'members that could not be listed' if remaining is None else 'live pids ' + ' '.join(map(str, remaining))
            print('code-job: verification refused: descendants outlived the verifier (process group %d still had %s '
                  'after SIGKILL)' % (process.pid, detail), file=sys.stderr)
            return DESCENDANTS_REMAIN
        if state['signals']:
            print('code-job: verification interrupted by signal %d; its process group was killed' % state['signals'][0],
                  file=sys.stderr)
            return 128 + state['signals'][0]
        return exit_code(returncode)
    finally:
        for signum, handler in previous.items():
            if handler is not None:  # None: installed outside Python; it cannot be restored from here.
                signal.signal(signum, handler)
