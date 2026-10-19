"""Fail-closed fault injection; real libseccomp otherwise, only disposable local fixtures."""
import os
from pathlib import Path
import runpy
import shlex
import socket
import shutil
import subprocess
import sys
import textwrap
import unittest
from unittest.mock import patch

try:
    from sim import test_fixes6 as fixture
    from sim import goal_classifier
except ImportError:
    import test_fixes6 as fixture
    import goal_classifier


class ExplanatoryScopeTests(unittest.TestCase):
    def test_coordinated_embedded_verbs_keep_explanatory_scope(self):
        for phrase in ('Explain how to build and test the parser',
                       'Describe how to add and remove a Python package',
                       'Can you explain how to build and then test the parser?',
                       'Explain why we add tests and remove Python packages'):
            self.assertFalse(goal_classifier.looks_like_coding(phrase), phrase)
        for phrase in ('Explain the failure and then fix it', 'Explain this function and fix the bug',
                       'Explain how to build the parser. Then fix the bug'):
            self.assertTrue(goal_classifier.looks_like_coding(phrase), phrase)


@unittest.skipUnless(sys.platform == 'linux', 'Linux seccomp fault injection')
class RequiredSyscallTests(fixture.SandboxBase):
    def inject(self, name, fault, namespaced):
        # Injection lives in the trusted test harness; no production env bypass.
        wrapper = self.root / 'inject.py'
        wrapper.write_text(textwrap.dedent('''
            import ctypes, runpy, sys
            module = runpy.run_path(sys.argv.pop(1))
            name, fault, namespaced = sys.argv[1:4]
            del sys.argv[1:4]
            original = ctypes.CDLL
            class Library:
                def __init__(self, real):
                    self.real = real
                def __getattr__(self, key):
                    return getattr(self.real, key)
                def seccomp_syscall_resolve_name(self, value):
                    if fault == 'resolve' and value.decode() == name:
                        return -1
                    return self.real.seccomp_syscall_resolve_name(value)
            def load(path, *args, **kwargs):
                real = original(path, *args, **kwargs)
                if path != 'libseccomp.so.2':
                    return real
                if fault == 'resolve':
                    return Library(real)
                if fault == 'load':
                    real.seccomp_load = lambda ctx: -22
                    return real
                number = real.seccomp_syscall_resolve_name(name.encode())
                attribute = 'seccomp_rule_add_array' if fault == 'array' else 'seccomp_rule_add'
                original_rule = getattr(real, attribute)
                original_rule.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint] + (
                    [ctypes.c_void_p] if fault == 'array' else [])
                def rule(ctx, action, syscall, count, *conditions):
                    if syscall == number:
                        return -22
                    return original_rule(ctx, action, syscall, count, *conditions)
                setattr(real, attribute, rule)
                return real
            ctypes.CDLL = load
            if namespaced == '1':
                # Install the real namespaced filter without needing userns on the test host.
                def child(workspace, temporary, command, env, report):
                    module['confine'](workspace, temporary, True, [])
                    import os
                    os.execve('/bin/sh', ['/bin/sh', '-c', command], env)
                module['linux'].__globals__['linux_child'] = child
            sys.exit(module['run']())
        '''))
        marker = self.repo / 'sub/command-ran'
        result = subprocess.run([sys.executable, '-B', str(wrapper), str(fixture.SANDBOX), name, fault,
                                 str(int(namespaced)), str(self.repo), 'printf ran > sub/command-ran'],
                                env=dict(os.environ, SWARMHUB_VERIFY_NAMESPACES='0'),
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertIn(name, result.stderr)
        self.assertFalse(marker.exists(), result.stdout + result.stderr)

    def test_each_required_unresolvable_name_refuses_before_workspace_command(self):
        module = runpy.run_path(str(fixture.SANDBOX))
        names = set(module['DENIED_SYSCALLS']) | set(module['verify_processes'].SYSCALLS)
        names |= set(module['verify_signals'].SIGNAL_SYSCALLS)
        names |= {'socketpair', 'clone', 'clone3', 'fcntl', 'ioctl', 'seccomp'}
        for name in sorted(names):
            with self.subTest(syscall=name):
                self.inject(name, 'resolve', False)

    def test_unresolvable_filter_rule_refuses_namespaced_command(self):
        self.inject('socket', 'resolve', True)

    def test_rule_installation_failures_name_the_syscall_in_both_modes(self):
        for namespaced in (False, True):
            for name, fault in (('socket', 'rule'), ('clone', 'array'), ('socketpair', 'array')):
                with self.subTest(namespaced=namespaced, syscall=name):
                    self.inject(name, fault, namespaced)
        self.inject('prlimit64', 'rule', False)
        self.inject('fcntl', 'array', False)
        self.inject('seccomp', 'load', True)

    def test_namespaced_mode_uses_private_sendmsg_ipc(self):
        module = runpy.run_path(str(fixture.SANDBOX))
        def namespaced(workspace, temporary, command, env, report):
            os.write(report, b'namespaced')
            return 0  # Only exercise IPC; no command or namespace setup in this test.
        receiver, sender = socket.socketpair()
        try:
            with patch.dict(module['linux_child'].__globals__, namespaced_run=namespaced,
                            namespaces_requested=lambda: True):
                self.assertEqual(module['linux_child'](self.repo, str(self.root), '', {}, sender), 0)
            self.assertEqual(receiver.recv(32), b'namespaced')
        finally:
            receiver.close()
            sender.close()

    def test_filter_and_listener_installation_fail_closed(self):
        # Kernel installation errors are independently exercised without running a command.
        module = runpy.run_path(str(fixture.SANDBOX))
        class Sec:
            def __init__(self):
                self.seccomp_export_bpf = lambda ctx, fd: os.write(fd, b'\0' * 8) and 0
            def seccomp_syscall_resolve_name(self, name):
                return 317
        class Lib:
            def syscall(self, *args):
                return -1
        with patch.dict(module['install_with_listener'].__globals__, libc=lambda: Lib()):
            with self.assertRaisesRegex(OSError, 'seccomp.*installation failed'):
                module['install_with_listener'](Sec(), 1)


class CodeJobGitTrustTests(fixture.SandboxBase):
    def attack(self, pointer):
        scripts = self.root / 'isolated/coding/scripts'
        scripts.mkdir(parents=True)
        for path in fixture.SANDBOX.parent.iterdir():
            if path.is_file():
                shutil.copyfile(path, scripts / path.name)
        linked = self.root / 'linked'
        self.assertEqual(fixture.git(self.repo, 'worktree', 'add', '-q', str(linked)).returncode, 0)
        target = Path((linked / '.git').read_text()[8:].strip())
        host = self.root / 'synthetic-home'; host.mkdir()
        (host / 'secret').write_text('synthetic-secret-never-readable')
        home = self.root / 'home'; home.mkdir()
        binary = self.root / 'bin'; binary.mkdir()
        if pointer == '.git':
            replacement = 'gitdir: ' + str(host)
            path = linked / '.git'
        else:
            replacement, path = str(host), target / 'commondir'
        stub = binary / 'codex'
        stub.write_text('#!/bin/sh\nprintf fresh > "$SWARMHUB_REPORT_FILE"\n'
                        'printf "%s\\n" ' + shlex.quote(replacement) + ' > ' + shlex.quote(str(path)) +
                        '\necho synthetic-tool-ran\n')
        stub.chmod(0o755)
        result = subprocess.run(['/bin/sh', str(scripts / 'code-job'), '--bot', 'QA', '--order', 'codex',
                                 '--model', 'synthetic-model', '--report', 'REPORT.txt', '--dir', str(linked),
                                 '--verify', 'printf command-ran > sub/command-ran; cat ' +
                                 shlex.quote(str(host / 'secret')), '--', 'synthetic task'],
                                env={'HOME': str(home), 'PATH': str(binary) + ':/usr/bin:/bin',
                                     'CODE_JOB_TICK': '0.05', 'SWARMHUB_VERIFY_NAMESPACES': '0'},
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 66, result.stdout + result.stderr)
        self.assertIn('synthetic-tool-ran', result.stdout)
        self.assertIn('verify exit 77', result.stderr)
        self.assertFalse((linked / 'sub/command-ran').exists())
        self.assertNotIn('synthetic-secret-never-readable', result.stdout + result.stderr)

    def test_tool_forged_gitfile_is_refused_against_pre_tool_snapshot(self):
        self.attack('.git')

    def test_tool_forged_commondir_is_refused_against_pre_tool_snapshot(self):
        self.attack('commondir')


@unittest.skipUnless(sys.platform == 'linux', 'Linux pidfd teardown')
class TeardownOrderingTests(unittest.TestCase):
    def test_pidfd_stays_open_until_exit_acknowledgement_and_reaping(self):
        module = runpy.run_path(str(fixture.SANDBOX))['verify_signals']
        supervisor = module.Supervisor.__new__(module.Supervisor)
        supervisor.root, supervisor.launcher = 100, 99
        supervisor.pinned = lambda pid: 42
        supervisor.descendant = lambda pid: True
        events = []
        class Proc:
            scans = 0
            def iterdir(self):
                self.scans += 1
                return [Path('101')] if self.scans == 1 else []
        class Poll:
            def register(self, *args):
                pass
            def unregister(self, *args):
                pass
            def poll(self, timeout):
                events.append('exit')
                return [(42, module.select.POLLIN)]
        with patch.object(module, 'PROC', Proc()), \
             patch.object(module.signal, 'pidfd_send_signal', side_effect=lambda *a: events.append('kill')), \
             patch.object(module.select, 'poll', Poll), \
             patch.object(module.os, 'waitpid', side_effect=lambda *a: events.append('reap')), \
             patch.object(module.os, 'close', side_effect=lambda *a: events.append('close')):
            supervisor.kill_tree()
        self.assertEqual(events, ['kill', 'exit', 'reap', 'close'])

    def test_unacknowledged_exit_refuses_completion_at_bounded_deadline(self):
        module = runpy.run_path(str(fixture.SANDBOX))['verify_signals']
        supervisor = module.Supervisor.__new__(module.Supervisor)
        supervisor.root, supervisor.launcher = 100, 99
        supervisor.pinned = lambda pid: 42
        supervisor.descendant = lambda pid: True
        with patch.object(module, 'PROC') as proc, \
             patch.object(module.signal, 'pidfd_send_signal'), \
             patch.object(module.select, 'poll'), \
             patch.object(module.time, 'monotonic', side_effect=[0, 6]), \
             patch.object(module.os, 'waitpid') as reap, \
             patch.object(module.os, 'close') as close:
            proc.iterdir.return_value = [Path('101')]
            with self.assertRaisesRegex(OSError, 'teardown timed out'):
                supervisor.kill_tree(timeout=5)
            reap.assert_not_called()
            close.assert_called_once_with(42)
