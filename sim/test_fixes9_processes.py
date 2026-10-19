"""Real limited-mode probes plus policy positives when the host kernel lacks authority.

Every call is attempted against an out-of-tree helper and self. Self errno must
match an unsandboxed control using the same arguments (kcmp/NUMA/madvise can need
host capabilities). No skipped negative probes and no network or providers.
"""
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

try:
    from sim.test_fixes8 import HelperBase
    from sim.test_fixes6 import SANDBOX
except ImportError:
    from test_fixes8 import HelperBase
    from test_fixes6 import SANDBOX

sys.path.insert(0, str(SANDBOX.parent))
import verify_processes as processes
import verify_signals as signals

PROBE = r'''
import ctypes, errno, json, mmap, os, resource, sys
name, mode = sys.argv[1:3]
lib = ctypes.CDLL(None, use_errno=True)
lib.syscall.restype = ctypes.c_long
resolve = ctypes.CDLL('libseccomp.so.2').seccomp_syscall_resolve_name
class Iovec(ctypes.Structure):
    _fields_ = [('base', ctypes.c_void_p), ('length', ctypes.c_size_t)]
page = mmap.mmap(-1, 4096, flags=mmap.MAP_PRIVATE | mmap.MAP_ANONYMOUS)
buffer = (ctypes.c_char * 4096).from_buffer(page)
vector = Iovec(ctypes.addressof(buffer), 4096)

def call(*args):
    ctypes.set_errno(0)
    value = lib.syscall(resolve(name.encode()), *args)
    return ctypes.get_errno() if value < 0 else 0

def args(pid):
    if name == 'prlimit64':
        limits = (ctypes.c_ulonglong * 2)(*resource.getrlimit(resource.RLIMIT_NOFILE))
        return pid, resource.RLIMIT_NOFILE, limits, 0
    if name in ('setpriority', 'getpriority'):
        return 0, pid, os.getpriority(os.PRIO_PROCESS, 0)
    if name == 'sched_setaffinity':
        mask = (ctypes.c_ubyte * 128)()
        for cpu in os.sched_getaffinity(0):
            mask[cpu // 8] |= 1 << (cpu % 8)
        return pid, ctypes.sizeof(mask), mask
    if name in ('sched_setparam', 'sched_setscheduler'):
        param = ctypes.c_int(0)
        return (pid, 0, ctypes.byref(param)) if name == 'sched_setscheduler' else (pid, ctypes.byref(param))
    if name == 'sched_setattr':
        import struct
        attr = ctypes.create_string_buffer(struct.pack('IIQiIQQQ', 48, 0, 0, os.getpriority(os.PRIO_PROCESS, 0), 0, 0, 0, 0))
        return pid, attr, 0
    if name == 'ioprio_set':
        return 1, pid, 0
    if name == 'kcmp':
        return pid, pid, 0, 0, 0
    if name == 'move_pages':
        return pid, 0, 0, 0, 0, 0
    if name == 'migrate_pages':
        return pid, 64, (ctypes.c_ulong * 1)(1), (ctypes.c_ulong * 1)(1)
    if name == 'process_madvise':
        return pid, ctypes.byref(vector), 1, 3, 0  # pidfd, valid self IOV, MADV_WILLNEED
    if name == 'get_robust_list':
        return pid, ctypes.byref(ctypes.c_void_p()), ctypes.byref(ctypes.c_size_t())
    raise AssertionError(name)

if mode == 'sandbox':
    helper, inherited = map(int, sys.argv[3:5])
    # For process_madvise the launcher must discard the inherited foreign pidfd.
    targets = (inherited,) if name == 'process_madvise' else (helper, os.getppid(), 1)
    for target in targets:
        assert call(*args(target)) == errno.EPERM, (name, target)
        if name != 'process_madvise':
            junk = list(args(target))
            position = 1 if name in ('setpriority', 'getpriority', 'ioprio_set') else 0
            junk[position] = ctypes.c_ulonglong((1 << 32) | target)
            assert call(*junk) == errno.EPERM, (name, 'upper bits')
    if name in ('setpriority', 'getpriority', 'ioprio_set'):
        for which in ((2, 3) if name == 'ioprio_set' else (1, 2)):
            for who in (0, os.getuid(), os.getpgrp(), helper):
                assert call(which, who, 0) == errno.EPERM, (name, which, who)
    if name == 'process_madvise':
        try:
            os.pidfd_open(helper)
        except PermissionError:
            pass
        else:
            raise AssertionError('foreign pidfd_open allowed')
    print('foreign-refused', name, flush=True)
self_target = os.pidfd_open(os.getpid()) if name == 'process_madvise' else os.getpid()
results = [call(*args(self_target))]
if name not in ('kcmp', 'process_madvise'):
    results.append(call(*args(0)))
print('self-result', json.dumps(results), flush=True)
'''


@unittest.skipUnless(sys.platform == 'linux', 'Linux seccomp process operations')
class NonSignalIsolationTests(HelperBase):
    def test_pidfds_watch_own_children_and_inherited_foreign_stdio_is_discarded(self):
        code = r'''import ctypes, errno, os, select, subprocess
lib = ctypes.CDLL(None, use_errno=True)
resolve = ctypes.CDLL('libseccomp.so.2').seccomp_syscall_resolve_name
# stdin was a host-helper pidfd before the verifier launched; it must now be null.
assert os.read(0, 1) == b''
assert lib.syscall(resolve(b'process_madvise'), 0, 0, 0, 0, 0) == -1
assert ctypes.get_errno() == errno.EPERM
child = subprocess.Popen(['/bin/sleep', '10'])
fd = os.pidfd_open(child.pid)
assert not os.get_inheritable(fd)
assert not select.select([fd], [], [], 0)[0]
child.terminate()
child.wait(timeout=5)
assert select.select([fd], [], [], 1)[0] == [fd]
os.close(fd)
print('child-pidfd-ok')
'''
        (self.repo / 'child_pidfd.py').write_text(code)
        foreign = os.pidfd_open(self.helper.pid)
        try:
            result = subprocess.run([sys.executable, '-B', str(SANDBOX), str(self.repo),
                                     '/usr/bin/python3 child_pidfd.py'], stdin=foreign,
                                    env=dict(os.environ, SWARMHUB_VERIFY_NAMESPACES='0'),
                                    capture_output=True, text=True, timeout=30)
        finally:
            os.close(foreign)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('child-pidfd-ok', result.stdout)
        self.assertIsNone(self.helper.poll())

    def check_call(self, name):
        # Independently pin the policy's self path even when host seccomp/capabilities
        # deny the underlying syscall. This is not a substitute for the real probe below.
        values = [os.getpid(), 0, 0, 0, 0, 0]
        if name in ('setpriority', 'getpriority', 'ioprio_set'):
            values[:2] = [1 if name == 'ioprio_set' else 0, os.getpid()]
        if name == 'kcmp':
            values[1] = os.getpid()
        fd = os.pidfd_open(os.getpid())
        try:
            if name == 'process_madvise':
                values[0] = fd
            self.assertEqual(processes.decide(name, os.getpid(), values), processes.CONTINUE)
        finally:
            os.close(fd)
        (self.repo / 'process_probe.py').write_text(PROBE)
        control = subprocess.run(['/usr/bin/python3', '-c', PROBE, name, 'control'], capture_output=True, text=True, timeout=20)
        self.assertEqual(control.returncode, 0, control.stderr)
        foreign = os.pidfd_open(self.helper.pid)
        try:
            command = '/usr/bin/python3 process_probe.py %s sandbox %d %d' % (name, self.helper.pid, foreign)
            result = subprocess.run([sys.executable, '-B', str(SANDBOX), str(self.repo), command],
                                    env=dict(os.environ, SWARMHUB_VERIFY_NAMESPACES='0'), pass_fds=(foreign,),
                                    capture_output=True, text=True, timeout=30)
        finally:
            os.close(foreign)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('foreign-refused ' + name, result.stdout)
        self.assertEqual(result.stdout.split('self-result ')[1], control.stdout.split('self-result ')[1])
        self.assertIsNone(self.helper.poll())
        self.assertFalse(self.record.exists())


def make_test(name):
    def test(self):
        self.check_call(name)
    return test


for _name in processes.PID_CALLS + ('setpriority', 'getpriority', 'ioprio_set', 'kcmp', 'process_madvise'):
    setattr(NonSignalIsolationTests, 'test_' + _name + '_foreign_refused_self_allowed', make_test(_name))


class ProcessPolicyTests(unittest.TestCase):
    def test_cancelled_notification_does_not_tear_down_live_verifiers(self):
        supervisor = signals.Supervisor.__new__(signals.Supervisor)
        supervisor.listener = -1
        for error in (errno.ENOENT, errno.EINTR):
            with patch.object(signals.fcntl, 'ioctl', side_effect=OSError(error, 'requesting child exited')):
                self.assertTrue(supervisor.handle_one())

    def test_pid_arguments_are_signed_low_32_bits_and_foreign_never_continue(self):
        with patch.object(processes, 'tgid', return_value=101):
            for name in processes.PID_CALLS:
                self.assertEqual(processes.decide(name, 102, [101 | (1 << 32)]), processes.CONTINUE)
                for foreign in (1, -1, 999, 999 | (1 << 32)):
                    self.assertEqual(processes.decide(name, 102, [foreign]), errno.EPERM)
            for name in ('setpriority', 'getpriority', 'ioprio_set'):
                for which in ((2, 3) if name == 'ioprio_set' else (1, 2)):
                    self.assertEqual(processes.decide(name, 102, [which, 0]), errno.EPERM)

    def test_kcmp_requires_both_targets_to_be_self(self):
        with patch.object(processes, 'tgid', return_value=101):
            for pair in ([101, 999], [999, 101], [999, 999]):
                self.assertEqual(processes.decide('kcmp', 102, pair), errno.EPERM)
