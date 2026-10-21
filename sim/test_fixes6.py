"""Cross-review (REVIEW-CLAUDE-XREV findings 1-3) regressions for the verification sandbox.

Every test runs the shipped verify-sandbox.py for real on the current platform (Landlock/seccomp/namespaces on
Linux, sandbox-exec on macOS). Nothing here contacts a network, a gateway or a provider; the escape probes only try
to create marker files under the test's own temporary directory.

On the MacBook:  cd <repo> && python3 -B -m unittest sim.test_fixes6 -v
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
SANDBOX = ROOT / 'Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py'
GIT_ENV = {'GIT_AUTHOR_NAME': 'fixture', 'GIT_AUTHOR_EMAIL': 'fixture@example.invalid', 'GIT_COMMITTER_NAME': 'fixture',
           'GIT_COMMITTER_EMAIL': 'fixture@example.invalid', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_SYSTEM': '/dev/null'}


def git(repo, *args):
    return subprocess.run(['git', '-C', str(repo), *args], env=dict(os.environ, **GIT_ENV), capture_output=True, text=True,
                          timeout=30)


def make_repo(repo):
    repo.mkdir(parents=True, exist_ok=True)
    git(repo, 'init', '-q')
    (repo / 'sub').mkdir()
    (repo / 'sub/file.txt').write_text('content\n')
    git(repo, 'add', '-A')
    assert git(repo, 'commit', '-qm', 'init').returncode == 0


class SandboxBase(unittest.TestCase):
    namespaces = '1'

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'workspace'
        make_repo(self.repo)
        self.marker = self.root / 'ESCAPED'

    def trust_git(self):
        self.git_snapshot = self.root / 'git-trust.json'
        result = subprocess.run([sys.executable, '-B', str(SANDBOX), '--capture-git',
                                 str(self.repo), str(self.git_snapshot)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)

    def run_verify(self, command, timeout=60):
        env = dict(os.environ, QA_SECRET='synthetic-secret', SWARMHUB_VERIFY_NAMESPACES=self.namespaces)
        trust = ['', str(self.git_snapshot)] if hasattr(self, 'git_snapshot') else []
        return subprocess.run([sys.executable, '-B', str(SANDBOX), str(self.repo), command] + trust,
                              env=env, capture_output=True, text=True, timeout=timeout)

    def assert_refused_not_unavailable(self, result):
        # A refusal to initialize a sandbox (77) must not masquerade as a negative security test.
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn(result.returncode, (69, 77), result.stderr)
        self.assertNotIn('Xcode license', result.stdout + result.stderr)


class GitMetadataEscapeTests(SandboxBase):
    """Finding 1: the verifier must not be able to plant anything a later host git executes."""

    def test_control_fsmonitor_planted_on_the_host_really_runs_on_git_status(self):
        # The attack is real on this git: an unsandboxed writer of .git/config gets code execution from `git status`.
        control = self.root / 'control'
        make_repo(control)
        marker = self.root / 'CONTROL-ESCAPED'
        with (control / '.git/config').open('a') as config:
            config.write(f'[core]\n\tfsmonitor = touch {shlex.quote(str(marker))}\n')
        git(control, 'status', '--short')
        self.assertTrue(marker.exists(), 'host git did not run core.fsmonitor; the escape premise no longer holds')

    def test_verifier_cannot_write_git_config_or_hooks_and_host_git_status_runs_nothing(self):
        before = (self.repo / '.git/config').read_bytes()
        hook = self.repo / '.git/hooks/pre-commit'
        attempts = [
            'printf "[core]\\n\\tfsmonitor = touch %s\\n" >> .git/config' % shlex.quote(str(self.marker)),
            'printf "#!/bin/sh\\ntouch %s\\n" > .git/hooks/pre-commit' % shlex.quote(str(self.marker)),
            'git config core.fsmonitor "touch %s"' % shlex.quote(str(self.marker)),
            'git config core.hooksPath sub',
            '/usr/bin/python3 -c "open(\\".git/config\\", \\"a\\").write(\\"[core]\\\\n\\\\tfsmonitor = touch %s\\\\n\\")"'
            % str(self.marker),
        ]
        for command in attempts:
            with self.subTest(command=command):
                self.assert_refused_not_unavailable(self.run_verify(command))
        self.assertEqual((self.repo / '.git/config').read_bytes(), before)
        self.assertFalse(hook.exists())
        # The host-side trigger: the bots' auto-allowed `git status`, the user's own git, later CLI runs.
        self.assertEqual(git(self.repo, 'status', '--short').returncode, 0)
        self.assertFalse(self.marker.exists(), 'verifier-planted configuration executed on the host')

    def test_git_metadata_cannot_be_renamed_removed_or_replaced(self):
        for command in ['mv .git .git-old', 'rm -rf .git', 'rm -rf .git/hooks', 'mv sub .git',
                        'ln -sf /tmp .git', 'rm .git/HEAD']:
            with self.subTest(command=command):
                self.assert_refused_not_unavailable(self.run_verify(command))
        self.assertTrue((self.repo / '.git').is_dir() and (self.repo / '.git/HEAD').is_file())
        self.assertTrue((self.repo / '.git/hooks').is_dir())
        self.assertEqual(git(self.repo, 'status', '--short').returncode, 0)

    def test_linked_worktree_gitdir_and_common_dir_stay_read_only(self):
        linked = self.root / 'linked'
        self.assertEqual(git(self.repo, 'worktree', 'add', '-q', str(linked)).returncode, 0)
        self.repo = linked
        self.trust_git()
        gitdir = Path((linked / '.git').read_text().split('gitdir:', 1)[1].strip())
        before = (self.root / 'workspace/.git/config').read_bytes()
        attempts = ['printf x >> .git', 'printf "[core]\\n\\tfsmonitor = true\\n" >> %s' % shlex.quote(str(gitdir / 'config')),
                    'printf "[core]\\n\\tfsmonitor = true\\n" >> %s' % shlex.quote(str(self.root / 'workspace/.git/config'))]
        for command in attempts:
            with self.subTest(command=command):
                self.assert_refused_not_unavailable(self.run_verify(command))
        self.assertEqual((self.root / 'workspace/.git/config').read_bytes(), before)
        self.assertTrue((linked / '.git').read_text().startswith('gitdir:'))
        # Reading the linked repository still works for ordinary verifiers.
        self.assertEqual(self.run_verify('git status --short').returncode, 0)

    def test_symlinks_to_git_metadata_cannot_be_written_through(self):
        # Links that exist before the run (planted by the coding agent) and links the verifier creates itself.
        (self.repo / 'planted-relative').symlink_to('.git/config')
        (self.repo / 'planted-absolute').symlink_to(self.repo / '.git/config')
        (self.repo / 'planted-dir').symlink_to('.git')
        before = (self.repo / '.git/config').read_bytes()
        attempts = ['printf x >> planted-relative', 'printf x >> planted-absolute', 'printf x > planted-dir/hooks/pre-commit',
                    'ln -s .git/config fresh && printf x >> fresh', 'ln -s .git fresh-dir && printf x > fresh-dir/hooks/pre-commit',
                    'ln -s %s sub/deep && printf x >> sub/deep' % shlex.quote(str(self.repo / '.git/config'))]
        for command in attempts:
            with self.subTest(command=command):
                self.assert_refused_not_unavailable(self.run_verify(command))
        self.assertEqual((self.repo / '.git/config').read_bytes(), before)
        self.assertFalse((self.repo / '.git/hooks/pre-commit').exists())

    def test_workspace_remains_writable_and_outside_stays_closed(self):
        positive = self.run_verify('printf local > sub/local.txt && mkdir -p build && printf built > build/out')
        self.assertEqual(positive.returncode, 0, positive.stderr)
        self.assertEqual((self.repo / 'sub/local.txt').read_text(), 'local')
        self.assertNotEqual(self.run_verify('printf executed > ' + shlex.quote(str(self.marker))).returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertEqual(self.run_verify('test -z "${QA_SECRET-}"').returncode, 0)


PYTEST_STYLE = textwrap.dedent('''
    import asyncio, multiprocessing, os, signal, subprocess, sys, unittest

    class VerifierTests(unittest.TestCase):
        def test_dev_null_and_git(self):
            with open("/dev/null", "w") as sink:
                sink.write("discarded")
            self.assertEqual(subprocess.run(["git", "status", "--short"], capture_output=True).returncode, 0)
            self.assertEqual(subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True).returncode, 0)

        def test_asyncio_loop(self):
            async def work():
                proc = await asyncio.create_subprocess_exec("echo", "async", stdout=asyncio.subprocess.PIPE)
                out, _ = await proc.communicate()
                return out.strip()
            self.assertEqual(asyncio.run(work()), b"async")

        def test_multiprocessing_pool(self):
            with multiprocessing.Pool(2) as pool:
                self.assertEqual(pool.map(abs, [-1, -2, -3]), [1, 2, 3])

        def test_subprocess_timeout_kills_child(self):
            with self.assertRaises(subprocess.TimeoutExpired):
                subprocess.run(["sleep", "30"], timeout=0.3)

        def test_self_signal(self):
            seen = []
            signal.signal(signal.SIGUSR1, lambda *_: seen.append(1))
            os.kill(os.getpid(), signal.SIGUSR1)
            self.assertEqual(seen, [1])

    if __name__ == "__main__":
        unittest.main()
''')

NODE_CHILDREN = ('const c = require("child_process");'
                 'const out = c.execSync("echo child-ok").toString().trim();'
                 'const r = c.spawnSync("sleep", ["30"], {timeout: 300});'
                 'const p = c.spawn("sh", ["-c", "echo piped"], {stdio: ["ignore", "pipe", "inherit"]});'
                 'let piped = ""; p.stdout.on("data", d => piped += d);'
                 'p.on("close", code => { console.log(out, r.signal, piped.trim(), code); process.exit(out === "child-ok" && r.signal === "SIGTERM" && piped.trim() === "piped" && code === 0 ? 0 : 9); });')


class OrdinaryVerifierTests(SandboxBase):
    """Finding 2: real test commands must work inside the sandbox (false 'unverified' results)."""

    def test_pytest_style_module_passes_under_the_sandbox(self):
        (self.repo / 'test_verifier.py').write_text(PYTEST_STYLE)
        result = self.run_verify('/usr/bin/python3 -m unittest -v test_verifier')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Ran 5 tests', result.stderr)

    def test_shell_redirections_and_git_work(self):
        result = self.run_verify('echo hi > /dev/null && git status --short > /dev/null && git log --oneline | head -1 && printf ok')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.endswith('ok'), result.stdout)

    def test_node_child_processes_work(self):
        node = shutil.which('node', path='/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin')
        if not node:
            self.skipTest('node is not installed in a sandbox-visible location')
        (self.repo / 'children.js').write_text(NODE_CHILDREN)
        result = self.run_verify('node children.js')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('child-ok SIGTERM piped 0', result.stdout)

    def test_network_and_host_processes_stay_out_of_reach(self):
        for code in ['import socket; socket.socket(socket.AF_INET, socket.SOCK_STREAM)',
                     'import socket; socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)']:
            with self.subTest(code=code):
                result = self.run_verify('/usr/bin/python3 -c ' + shlex.quote(code))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('PermissionError', result.stderr)
        # Signalling the launcher's own parent (a host process) fails: invisible in a PID namespace, denied otherwise.
        self.assertNotEqual(self.run_verify('kill -0 %d' % os.getpid()).returncode, 0)
        result = self.run_verify('cat %s' % shlex.quote(str(Path.home() / '.bashrc')))
        self.assertNotEqual(result.returncode, 0)


@unittest.skipUnless(sys.platform == 'linux', 'Landlock fallback is Linux-only')
class LandlockFallbackTests(SandboxBase):
    """Without unprivileged user namespaces the workspace is granted entry by entry; `.git` stays read-only."""
    namespaces = '0'

    def test_fallback_keeps_git_read_only_and_denies_new_top_level_entries(self):
        before = (self.repo / '.git/config').read_bytes()
        attempts = ['printf "[core]\\n\\tfsmonitor = touch %s\\n" >> .git/config' % shlex.quote(str(self.marker)),
                    'printf x > .git/hooks/pre-commit', 'mv .git .git-old', 'mkdir build', 'printf x > top.txt',
                    'printf executed > ' + shlex.quote(str(self.marker)), 'kill -0 %d' % os.getpid()]
        for command in attempts:
            with self.subTest(command=command):
                self.assert_refused_not_unavailable(self.run_verify(command))
        self.assertEqual((self.repo / '.git/config').read_bytes(), before)
        self.assertFalse((self.repo / 'build').exists() or (self.repo / 'top.txt').exists() or self.marker.exists())
        self.assertEqual(git(self.repo, 'status', '--short').returncode, 0)
        self.assertFalse(self.marker.exists())

    def test_fallback_denies_writes_through_planted_symlinks(self):
        (self.repo / 'planted').symlink_to('.git/config')
        (self.repo / 'sub/planted').symlink_to(self.repo / '.git/config')
        before = (self.repo / '.git/config').read_bytes()
        for command in ['printf x >> planted', 'printf x >> sub/planted', 'ln -s .git/config sub/fresh && printf x >> sub/fresh']:
            with self.subTest(command=command):
                self.assert_refused_not_unavailable(self.run_verify(command))
        self.assertEqual((self.repo / '.git/config').read_bytes(), before)

    def test_fallback_still_runs_ordinary_verifiers_inside_existing_entries(self):
        result = self.run_verify('printf x > sub/new.txt && echo a | cat > /dev/null && git status --short > /dev/null && printf ok')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no user namespace', result.stderr)
        self.assertEqual((self.repo / 'sub/new.txt').read_text(), 'x')


class DarwinProfileTextTests(unittest.TestCase):
    """Finding 3, checkable everywhere: the Seatbelt profile grants named Mach services only and denies `.git`."""

    def profile(self, workspace):
        import runpy
        module = runpy.run_path(str(SANDBOX))
        module['git_dir'].__globals__['GIT_SNAPSHOT'] = module['verify_git'].layout(workspace)
        return module['darwin_profile'](workspace, '/private/tmp/swarmhub-verify-x')

    def test_mach_lookup_is_an_explicit_allowlist_without_pasteboard_or_launchservices(self):
        with tempfile.TemporaryDirectory() as temporary:
            profile = self.profile(Path(temporary))
        self.assertNotIn('(allow mach-lookup)', profile)
        self.assertIn('(allow mach-lookup (global-name "com.apple.system.opendirectoryd.libinfo")', profile)
        for service in ('pasteboard', 'launchservicesd', 'appleevents', 'SecurityServer', 'cfprefsd', 'lsd'):
            self.assertNotIn(service, profile)
        self.assertNotIn('(subpath "/Library")', profile)
        self.assertIn('(allow signal (target same-sandbox))', profile)
        self.assertNotIn('(allow network', profile)

    def test_git_metadata_is_denied_after_the_workspace_allow(self):
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary) / 'ws'
            make_repo(workspace)
            linked = Path(temporary) / 'linked'
            git(workspace, 'worktree', 'add', '-q', str(linked))
            profile = self.profile(workspace)
            allow = profile.index('(allow file-read* file-write* file-map-executable (subpath "%s"))' % workspace)
            deny = profile.index('(deny file-write* (subpath "%s"))' % (workspace / '.git'))
            self.assertLess(allow, deny, 'the deny must come after the allow so it wins')
            self.assertIn('(deny file-write* (literal "%s"))' % (workspace / '.git'), profile)
            linked_profile = self.profile(linked)
            gitdir = (workspace / '.git/worktrees/linked').resolve()
            self.assertIn('(deny file-write* (subpath "%s"))' % gitdir, linked_profile)
            self.assertIn('(deny file-write* (subpath "%s"))' % (workspace / '.git').resolve(), linked_profile)


MACH_PROBE = textwrap.dedent('''
    import ctypes, sys
    libc = ctypes.CDLL(None, use_errno=True)
    libc.bootstrap_look_up.argtypes = [ctypes.c_uint, ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint)]
    bootstrap = ctypes.c_uint.in_dll(libc, "bootstrap_port")
    port = ctypes.c_uint()
    kr = libc.bootstrap_look_up(bootstrap, sys.argv[1].encode(), ctypes.byref(port))
    print(sys.argv[1], kr)
    sys.exit(0 if kr == 0 else 3)
''')


@unittest.skipUnless(sys.platform == 'darwin', 'native Seatbelt checks run only on macOS')
class DarwinNativeSandboxTests(SandboxBase):
    """Finding 3: the Seatbelt profile executed natively. Run on the MacBook, see the module docstring."""

    def mach(self, service):
        (self.repo / 'mach.py').write_text(MACH_PROBE)
        return self.run_verify('/usr/bin/python3 mach.py ' + shlex.quote(service))

    def test_allowed_mach_services_resolve_so_denials_below_are_meaningful(self):
        result = self.mach('com.apple.system.opendirectoryd.libinfo')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_pasteboard_launchservices_appleevents_and_keychain_are_unreachable(self):
        for service in ['com.apple.pasteboard.1', 'com.apple.coreservices.launchservicesd', 'com.apple.coreservices.appleevents',
                        'com.apple.SecurityServer', 'com.apple.cfprefsd.daemon', 'com.apple.lsd.mapdb']:
            with self.subTest(service=service):
                result = self.mach(service)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn(service + ' ', result.stdout)

    def test_outside_write_secret_read_and_network_are_denied_natively(self):
        secret = self.root / 'outside-secret'
        secret.write_text('synthetic-host-secret')
        self.assertNotEqual(self.run_verify('printf executed > ' + shlex.quote(str(self.marker))).returncode, 0)
        self.assertFalse(self.marker.exists())
        self.assertNotEqual(self.run_verify('cat ' + shlex.quote(str(secret))).returncode, 0)
        # Creation alone must fail; never contact an endpoint even if the policy regresses.
        result = self.run_verify('/usr/bin/python3 -c ' + shlex.quote(
            'import socket; print("socket-probe-reached", flush=True); socket.socket()'))
        self.assert_refused_not_unavailable(result)
        self.assertIn('socket-probe-reached', result.stdout)
        self.assertIn('PermissionError', result.stderr)


if __name__ == '__main__':
    unittest.main()
