"""Fixes7 (Codex review of fixes6: issue A, the mount-EPERM concern, the job result) for the limited verification sandbox.

Every test runs the shipped verify-sandbox.py for real on Linux, either with user namespaces disabled
(SWARMHUB_VERIFY_NAMESPACES=0) or with its mount() patched to fail the way AppArmor's unprivileged_userns
restriction fails (unshare succeeds, mount returns EPERM). Nothing here contacts a network, a gateway or a provider;
escape probes only try to create marker files under the test's own temporary directory or signal the test runner.

The sandbox tests are Linux-only (the limited mode does not exist on macOS); the job-result test runs everywhere.
"""
import importlib.util
import json
import os
from pathlib import Path
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import textwrap
import unittest

try:
    from sim.test_fixes6 import PYTEST_STYLE, ROOT, SANDBOX, SandboxBase
except ImportError:  # `python3 -m unittest discover` from inside sim/
    from test_fixes6 import PYTEST_STYLE, ROOT, SANDBOX, SandboxBase

LINUX = sys.platform == 'linux'


def user_namespaces_available():
    try:
        return subprocess.run(['unshare', '-Ur', 'true'], capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


# Signals from a verifier in the limited mode: its own processes and groups work, everything on the host is denied.
SIGNAL_SUITE = textwrap.dedent('''
    import os, signal, subprocess, sys, unittest
    LAUNCHER, RUNNER, RUNNER_GROUP = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])

    class ChildSignals(unittest.TestCase):
        def test_terminate_own_child(self):
            child = subprocess.Popen(["sleep", "30"])
            child.terminate()
            self.assertEqual(child.wait(timeout=5), -signal.SIGTERM)

        def test_timeout_expires_and_the_child_is_killed(self):
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run(["sleep", "30"], timeout=0.3)
            self.assertNotIn("sleep 30", subprocess.run(["ps", "-o", "args=", "--ppid", str(os.getpid())],
                                                        capture_output=True, text=True).stdout)

        def test_killpg_of_an_own_session_and_kill_zero(self):
            child = subprocess.Popen(["sleep", "30"], start_new_session=True)
            os.killpg(child.pid, signal.SIGTERM)
            self.assertEqual(child.wait(timeout=5), -signal.SIGTERM)
            os.kill(0, 0)

        def test_self_signal_and_raise_are_delivered_without_eintr(self):
            seen = []
            signal.signal(signal.SIGUSR1, lambda *_: seen.append(1))
            os.kill(os.getpid(), signal.SIGUSR1)
            signal.raise_signal(signal.SIGUSR1)
            self.assertEqual(seen, [1, 1])

        def test_host_processes_and_groups_are_denied(self):
            for pid in (1, LAUNCHER, RUNNER):
                with self.assertRaises(PermissionError):
                    os.kill(pid, 0)
            # Signal 0: the broker refuses kill(-1) whatever the signal, and a sandbox that failed open must not
            # TERM every process of the user (2026-10-21).
            with self.assertRaises(PermissionError):
                os.kill(-1, 0)
            with self.assertRaises(PermissionError):
                os.killpg(RUNNER_GROUP, 0)
            # Fixes9: self pidfds are safe; signalling via pidfds stays denied.
            os.close(os.pidfd_open(os.getpid()))

    if __name__ == "__main__":
        unittest.main(argv=[sys.argv[0]], verbosity=2)
''')

SHM_SUITE = textwrap.dedent('''
    import os
    from multiprocessing import shared_memory
    block = shared_memory.SharedMemory(create=True, size=16)
    block.buf[0] = 7
    block.close()
    block.unlink()
    for attempt in (lambda: os.listdir("/dev/shm"), lambda: os.mkdir("/dev/shm/swarmhub-fixes7-dir")):
        try:
            attempt()
        except PermissionError:
            continue
        raise SystemExit("the host /dev/shm was listed or got a directory")
    print("shm-by-name-ok")
''')


class LimitedBase(SandboxBase):
    namespaces = '0'

    def run_verify(self, command, timeout=60, mode_file=None, wrapper=None, namespaces=None):
        env = dict(os.environ, QA_SECRET='synthetic-secret', SWARMHUB_VERIFY_NAMESPACES=namespaces or self.namespaces)
        argv = [sys.executable, '-B', *(wrapper or [str(SANDBOX)]), str(self.repo), command]
        if mode_file:
            argv.append(str(mode_file))
        return subprocess.run(argv, env=env, capture_output=True, text=True, timeout=timeout)


@unittest.skipUnless(LINUX, 'the limited mode exists only on Linux')
class LimitedModeSuitesTests(LimitedBase):
    """Issue A: forced fallback runs timeouts, child SIGTERM and multiprocessing.Pool, signalling only its own tree."""

    def test_forced_fallback_runs_the_pytest_style_module_with_pool_timeout_and_self_signal(self):
        (self.repo / 'test_verifier.py').write_text(PYTEST_STYLE)
        result = self.run_verify('/usr/bin/python3 -m unittest -v test_verifier')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ran 5 tests', result.stderr)
        self.assertIn('no user namespace', result.stderr)

    def test_forced_fallback_child_sigterm_timeout_killpg_and_host_denials(self):
        (self.repo / 'signals.py').write_text(SIGNAL_SUITE)
        # $PPID inside the verifier is the launcher; the runner and its group are the host side of the boundary.
        result = self.run_verify('/usr/bin/python3 signals.py $PPID %d %d' % (os.getpid(), os.getpgrp()))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ran 5 tests', result.stderr)

    def test_forced_fallback_shared_memory_by_name_without_listing_and_without_leftovers(self):
        before = set(os.listdir('/dev/shm'))
        (self.repo / 'shm.py').write_text(SHM_SUITE)
        result = self.run_verify('/usr/bin/python3 shm.py')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('shm-by-name-ok', result.stdout)
        self.assertEqual(set(os.listdir('/dev/shm')) - before, set(), 'the verifier left objects in the host /dev/shm')
        self.assertFalse(Path('/dev/shm/swarmhub-fixes7-dir').exists())

    def test_forced_fallback_still_keeps_git_read_only_while_signals_work(self):
        before = (self.repo / '.git/config').read_bytes()
        command = ('sleep 30 & kill -TERM $! && wait $!; printf "[core]\\n\\tfsmonitor = touch %s\\n" >> .git/config'
                   % shlex.quote(str(self.marker)))
        result = self.run_verify(command)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotEqual(result.returncode, 77, result.stderr)
        self.assertEqual((self.repo / '.git/config').read_bytes(), before)
        self.assertFalse(self.marker.exists())

    def test_processes_left_behind_do_not_outlive_the_verification(self):
        # A global ps search for fixed sleep durations also sees concurrent runs.
        # These children acknowledge startup and live indefinitely; pin their
        # identities before letting the verifier exit, including a setsid child.
        probe = self.repo / 'sub/leftovers.py'
        probe.write_text(textwrap.dedent('''
            import json, os, signal, subprocess, sys
            if len(sys.argv) > 1:
                print(json.dumps([os.getpid(), os.getpgrp(), os.getsid(0)]), flush=True)
                while True:
                    signal.pause()
            children = [subprocess.Popen([sys.executable, '-B', __file__, 'child'],
                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True, start_new_session=detached) for detached in (False, True)]
            ready = [json.loads(child.stdout.readline()) for child in children]
            print(json.dumps([os.getpid(), os.getpgrp(), os.getsid(0), ready]), flush=True)
            assert sys.stdin.read(1) == '\\n', 'missing test release'
        '''))
        env = dict(os.environ, SWARMHUB_VERIFY_NAMESPACES='0')
        descriptors = []
        with tempfile.TemporaryFile(mode='w+') as errors:
            launcher = subprocess.Popen([sys.executable, '-B', str(SANDBOX), str(self.repo),
                                         'exec /usr/bin/python3 sub/leftovers.py'],
                                        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=errors, text=True)
            try:
                self.assertTrue(select.select([launcher.stdout], [], [], 30)[0], 'children never became ready')
                line = launcher.stdout.readline()
                self.assertTrue(line, 'verifier exited before both children acknowledged startup')
                root, group, session, children = json.loads(line)
                self.assertEqual(len(children), 2)
                for pid, _, _ in children:
                    descriptors.append(os.pidfd_open(pid))
                self.assertEqual(len({root, *(child[0] for child in children)}), 3)
                self.assertEqual(children[0][1:], [group, session], 'ordinary child left the verifier group')
                self.assertEqual(children[1], [children[1][0]] * 3, 'detached child did not call setsid')
                self.assertNotEqual(children[1][2], session)
                self.assertEqual(select.select(descriptors, [], [], 0)[0], [], 'child died before release')
                launcher.communicate('\n', timeout=30)
                errors.seek(0)
                self.assertEqual(launcher.returncode, 0, errors.read())
                # No grace period: both pinned processes must have exited when
                # verification returns. pidfds distinguish exit from PID reuse
                # and do not confuse unreaped zombies with running children.
                self.assertEqual(set(select.select(descriptors, [], [], 0)[0]), set(descriptors),
                                 'verifier left a running child behind')
            finally:
                for fd in descriptors:
                    try:
                        signal.pidfd_send_signal(fd, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    finally:
                        os.close(fd)
                if launcher.poll() is None:
                    launcher.terminate()
                launcher.communicate(timeout=10)

    def test_mode_is_recorded_by_the_launcher_for_the_job_result(self):
        mode = self.root / 'mode'
        self.assertEqual(self.run_verify('true', mode_file=mode).returncode, 0)
        self.assertEqual(mode.read_text().strip(), 'fallback')
        # The verifier cannot rewrite the record: the file lives outside its Landlock rules.
        result = self.run_verify('printf namespaced > %s' % shlex.quote(str(mode)), mode_file=mode)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(mode.read_text().strip(), 'fallback')
        if user_namespaces_available():
            self.assertEqual(self.run_verify('true', mode_file=mode, namespaces='1').returncode, 0)
            self.assertEqual(mode.read_text().strip(), 'namespaced')


WRAPPER = textwrap.dedent('''
    """Runs verify-sandbox.py with a failure injected into its namespace setup (never into its confinement)."""
    import errno, runpy, sys
    sandbox, failure = sys.argv[1], sys.argv[2]
    module = runpy.run_path(sandbox, run_name='verify_sandbox_under_test')
    code = errno.EPERM if failure.startswith('mount-eperm') else errno.EINVAL

    def mount(source, target, fstype, flags, data=None):
        raise OSError(code, 'mount ' + target)

    def landlock(rules):
        raise OSError('Landlock unavailable (simulated)')

    # runpy returns a copy of the module globals; patch the dictionary the functions actually read.
    namespace = module['private_mounts'].__globals__
    namespace['mount'] = mount
    if failure == 'mount-eperm-no-landlock':
        namespace['landlock'] = landlock
    sys.argv = [sandbox] + sys.argv[3:]
    sys.exit(module['run']())
''')


@unittest.skipUnless(LINUX, 'the limited mode exists only on Linux')
class MountDeniedAfterUnshareTests(LimitedBase):
    """Hosts where unshare succeeds but mount is denied (AppArmor's unprivileged_userns restriction) must not exit 77
    for every verification: the limited mode takes over, and only when it can confine."""
    namespaces = '1'

    def setUp(self):
        super().setUp()
        if not user_namespaces_available():
            self.skipTest('no user namespaces here: the real unshare path is already the fallback')
        self.wrapper = self.root / 'wrapper.py'
        self.wrapper.write_text(WRAPPER)

    def injected(self, failure, command, mode_file=None):
        return self.run_verify(command, mode_file=mode_file, wrapper=[str(self.wrapper), str(SANDBOX), failure])

    def test_mount_eperm_after_unshare_takes_the_limited_mode(self):
        mode = self.root / 'mode'
        result = self.injected('mount-eperm', 'printf x > sub/new.txt && (sleep 30 & kill -TERM $!; wait $!; test $? -ne 0) && printf ok',
                               mode_file=mode)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(result.stdout.endswith('ok'), result.stdout)
        self.assertIn('no user namespace', result.stderr)
        self.assertEqual(mode.read_text().strip(), 'fallback')
        self.assertEqual((self.repo / 'sub/new.txt').read_text(), 'x')
        before = (self.repo / '.git/config').read_bytes()
        for command in ['printf x >> .git/config', 'mkdir build', 'printf executed > ' + shlex.quote(str(self.marker)),
                        'kill -0 %d' % os.getpid()]:
            with self.subTest(command=command):
                denied = self.injected('mount-eperm', command)
                self.assertNotEqual(denied.returncode, 0)
                self.assertNotEqual(denied.returncode, 77, denied.stderr)
        self.assertEqual((self.repo / '.git/config').read_bytes(), before)
        self.assertFalse((self.repo / 'build').exists() or self.marker.exists())

    def test_other_mount_failures_still_refuse_without_running_anything(self):
        result = self.injected('mount-einval', 'printf ran > sub/ran.txt')
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertIn('verification refused', result.stderr)
        self.assertFalse((self.repo / 'sub/ran.txt').exists())

    def test_limited_mode_that_cannot_confine_refuses_without_running_anything(self):
        mode = self.root / 'mode'
        result = self.injected('mount-eperm-no-landlock', 'printf ran > sub/ran.txt', mode_file=mode)
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertIn('verification refused', result.stderr)
        self.assertFalse((self.repo / 'sub/ran.txt').exists())
        self.assertFalse(mode.exists(), 'no mode is recorded for a run that never started')


class JobResultModeTests(unittest.TestCase):
    """The limited mode is explicit in the completion wake, which is what the user sees of a verification."""

    def setUp(self):
        scripts = ROOT / 'Resources/Skills/swarmhub-messages/scripts'
        if str(scripts) not in sys.path:
            sys.path.insert(0, str(scripts))  # peer-runtime imports its siblings by bare name
        spec = importlib.util.spec_from_file_location('peer_runtime_under_test', scripts / 'peer-runtime.py')
        self.peer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.peer)

    def job(self, **fields):
        folder = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(['rm', '-rf', str(folder)], check=False))
        for key, value in {'evidence': 'tests', 'report-valid': 'true', 'commit-evidence': 'false', 'tests-passed': 'true',
                           'verify-exit': '0', 'verify-command': 'make check', 'cli-exit': '0', **fields}.items():
            (folder / key).write_text(value + '\n')
        return folder

    def test_limited_mode_is_named_in_the_wake_and_namespaced_is_not(self):
        text = self.peer.evidence_lines(self.job(**{'verify-mode': 'fallback'}))
        self.assertIn('verification command exit 0 in the limited sandbox (make check)', text)
        self.assertIn('Verification sandbox: limited (no user namespace)', text)
        self.assertIn("signals only to the verifier's own processes", text)
        for mode in ('namespaced', 'seatbelt', '-'):
            text = self.peer.evidence_lines(self.job(**{'verify-mode': mode}))
            self.assertIn('verification command exit 0 (make check)', text)
            self.assertNotIn('limited', text)
        text = self.peer.evidence_lines(self.job())  # Records from before the field existed.
        self.assertIn('verification command exit 0 (make check)', text)
        self.assertNotIn('limited', text)

    def test_failed_verification_in_the_limited_mode_and_a_refused_sandbox_are_explicit(self):
        failed = self.peer.evidence_lines(self.job(**{'verify-mode': 'fallback', 'tests-passed': 'false', 'verify-exit': '3',
                                                     'evidence': 'none'}))
        self.assertIn('verification command exit 3 in the limited sandbox (make check)', failed)
        self.assertIn('Verification sandbox: limited', failed)
        refused = self.peer.evidence_lines(self.job(**{'tests-passed': 'false', 'verify-exit': '77', 'evidence': 'none'}))
        self.assertIn('verification (the sandbox refused to start on this host, exit 77: make check)', refused)
        self.assertNotIn('limited', refused)


if __name__ == '__main__':
    unittest.main()
