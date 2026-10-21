"""Socket creation confinement; no addresses, listeners, connections or network sends."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import contextlib
import errno
import io
import os
from pathlib import Path
import runpy
import shlex
import socket
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

try:
    from sim import test_fixes6 as fixture
except ImportError:
    import test_fixes6 as fixture

DARWIN = runpy.run_path(str(fixture.SANDBOX))['verify_darwin']


class SocketGuardTests(unittest.TestCase):
    def guard(self, creation):
        output = io.StringIO()
        with patch.object(socket, 'socket', creation), patch.object(os, 'execv') as execute, \
             patch.object(sys, 'argv', ['-c', 'printf "command with spaces"']), contextlib.redirect_stderr(output):
            try:
                exec(DARWIN.SOCKET_GUARD, {})
            except SystemExit as exc:
                return exc.code, execute, output.getvalue()
        return 0, execute, output.getvalue()

    def test_only_permission_denials_for_every_family_and_kind_admit_the_command(self):
        for error in (errno.EPERM, errno.EACCES):
            creation = Mock(side_effect=OSError(error, 'synthetic denial'))
            code, execute, output = self.guard(creation)
            self.assertEqual((code, output), (0, ''))
            self.assertEqual(creation.call_args_list,
                             [unittest.mock.call(family, kind)
                              for family in (socket.AF_INET, socket.AF_INET6, socket.AF_UNIX)
                              for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM)])
            execute.assert_called_once_with('/bin/sh', ['/bin/sh', '-c', 'printf "command with spaces"'])

    def test_one_permitted_socket_at_any_position_refuses_without_executing_command(self):
        for position in range(6):
            endpoint = Mock()
            creation = Mock(side_effect=[PermissionError(errno.EPERM, 'denied')] * position + [endpoint])
            code, execute, output = self.guard(creation)
            self.assertEqual(code, 77)
            execute.assert_not_called()
            endpoint.close.assert_called_once_with()
            self.assertIn('verification refused: socket creation confinement is unavailable', output)

    def test_unrelated_socket_errors_are_not_successful_confinement(self):
        for error in (errno.EAFNOSUPPORT, errno.EMFILE, errno.EINVAL, errno.ENOSYS):
            code, execute, output = self.guard(Mock(side_effect=OSError(error, 'synthetic error')))
            self.assertEqual(code, 77)
            execute.assert_not_called()
            self.assertIn('could not be verified', output)

    def test_profile_denies_socket_syscalls_without_disabling_anonymous_socketpair(self):
        profile = DARWIN.darwin_profile(Path('/workspace'), '/private/tmp/verify')
        self.assertIn('(allow syscall-unix)(deny syscall-unix (syscall-number 97 450))', profile)
        self.assertIn('(deny network*)(deny system-socket)', profile)
        self.assertNotIn('(allow network', profile)
        self.assertNotIn('(allow system-socket', profile)
        self.assertNotIn('(import ', profile)
        self.assertEqual(DARWIN.guarded_command('echo ok')[:4], ['/usr/bin/python3', '-I', '-B', '-c'])


SOCKET_PROBE = '''import ctypes, errno, os, socket, sys
lib = ctypes.CDLL(None, use_errno=True)
lib.socket.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
lib.socket.restype = ctypes.c_int
print("socket-probe-reached", flush=True)
for family in (socket.AF_INET, socket.AF_INET6, socket.AF_UNIX):
    for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
        ctypes.set_errno(0)
        fd = lib.socket(family, kind, 0)
        error = ctypes.get_errno()
        if fd >= 0:
            os.close(fd)
        assert fd == -1 and error in (errno.EPERM, errno.EACCES), (family, kind, fd, error)
        print("socket-denied", family, kind, flush=True)
print("socket-probe-complete", flush=True)
'''


class SocketCreationTests(fixture.SandboxBase):
    # Linux's limited mode is available on OVH; Darwin ignores this selector.
    namespaces = '0'

    def test_python_socket_creation_is_denied_before_any_endpoint_is_used(self):
        for family in ('AF_INET', 'AF_INET6', 'AF_UNIX'):
            for kind in ('SOCK_STREAM', 'SOCK_DGRAM'):
                with self.subTest(family=family, kind=kind):
                    code = ('import socket\nprint("socket-probe-reached", flush=True)\n'
                            'socket.socket(socket.%s, socket.%s)' % (family, kind))
                    result = self.run_verify('/usr/bin/python3 -c ' + shlex.quote(code))
                    self.assert_refused_not_unavailable(result)
                    self.assertIn('socket-probe-reached', result.stdout)
                    self.assertIn('PermissionError', result.stderr)

    def test_libc_socket_creation_is_denied_in_the_verifier_and_its_exec_child(self):
        child = ('import subprocess\n'
                 'raise SystemExit(subprocess.run(["/usr/bin/python3", "-I", "-c", %r]).returncode)' % SOCKET_PROBE)
        for code in (SOCKET_PROBE, child):
            with self.subTest(child=code == child):
                result = self.run_verify('/usr/bin/python3 -c ' + shlex.quote(code))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(result.stdout.count('socket-denied '), 6)
                self.assertIn('socket-probe-complete', result.stdout)

    def test_anonymous_socketpair_and_asyncio_still_work(self):
        code = '''import asyncio, socket
a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
a.close()
b.close()
async def work():
    child = await asyncio.create_subprocess_exec("/bin/echo", "child-ok", stdout=asyncio.subprocess.PIPE)
    output, _ = await child.communicate()
    assert output == b"child-ok\\n" and child.returncode == 0
asyncio.run(work())
print("anonymous-ipc-ok")
'''
        result = self.run_verify('/usr/bin/python3 -c ' + shlex.quote(code))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('anonymous-ipc-ok', result.stdout)


@unittest.skipUnless(sys.platform == 'darwin', 'native Seatbelt enforcement requires macOS')
class DarwinSocketNativeTests(fixture.SandboxBase):
    def test_direct_socket_syscalls_are_denied(self):
        code = '''import ctypes, errno, os, socket
lib = ctypes.CDLL(None, use_errno=True)
lib.syscall.argtypes = [ctypes.c_int]  # Fixed argument of the variadic ABI on Apple Silicon.
lib.syscall.restype = ctypes.c_int
print("syscall-probe-reached", flush=True)
for number in (97, 450):
    for family in (socket.AF_INET, socket.AF_INET6, socket.AF_UNIX):
        for kind in (socket.SOCK_STREAM, socket.SOCK_DGRAM):
            ctypes.set_errno(0)
            fd = lib.syscall(ctypes.c_int(number), ctypes.c_int(family), ctypes.c_int(kind),
                             ctypes.c_int(0), ctypes.c_int(os.getpid()))
            error = ctypes.get_errno()
            if fd >= 0:
                os.close(fd)
            assert fd == -1 and error in (errno.EPERM, errno.EACCES), (number, family, kind, fd, error)
print("syscall-probe-complete", flush=True)
'''
        result = self.run_verify('/usr/bin/python3 -c ' + shlex.quote(code))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('syscall-probe-complete', result.stdout)

    def test_ineffective_policy_never_runs_workspace_code_even_with_a_shadow_socket_module(self):
        # Deliberately ineffective policy; no connect, bind or sends even in this negative control.
        profile = DARWIN.darwin_profile(self.repo.resolve(), str(self.root.resolve()))
        profile += '(allow syscall-unix)(allow network*)(allow system-socket)'
        (self.repo / 'socket.py').write_text('raise RuntimeError("workspace socket module imported")')
        command = 'printf should-not-run > sub/guard-escaped'
        result = subprocess.run(['/usr/bin/sandbox-exec', '-p', profile, *DARWIN.guarded_command(command)],
                                cwd=self.repo, env={'PATH': '/usr/bin:/bin', 'HOME': str(self.root), 'LANG': 'C'},
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertIn('socket creation confinement is unavailable', result.stderr)
        self.assertFalse((self.repo / 'sub/guard-escaped').exists())
        self.assertNotIn('workspace socket module imported', result.stderr)


if __name__ == '__main__':
    unittest.main()
