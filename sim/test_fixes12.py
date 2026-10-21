"""Fixes12 (Claude cross-review 2) regressions. Offline only: synthetic repositories, stub CLIs, FAKE or never-run
outbound, in-memory HTTP handler. Nothing contacts a network, a gateway or a provider.

On the MacBook:  cd <repo> && python3 -B -m unittest sim.test_fixes12 -v
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import base64
import http.client
import io
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch
import uuid

try:
    from sim import test_fixes6 as fixture
    from sim import goal_classifier
except ImportError:  # `python3 -m unittest discover` from inside sim/
    import test_fixes6 as fixture
    import goal_classifier

ROOT = fixture.ROOT
SCRIPTS = ROOT / 'Resources/Skills/swarmhub-coding/scripts'
sys.path.insert(0, str(ROOT / 'Resources/Skills/swarmhub-messages/scripts'))
import swarm_policy as policy  # noqa: E402
import swarm_remote as remote  # noqa: E402
from swarm_store import canonical  # noqa: E402

EXPLAIN_THEN_FIX = ["Explain why the parser crashes and then fix it", "Explain what went wrong and fix the bug",
                    "Explain why the tests fail, then fix them", "Tell me why the build fails and fix it",
                    "Explain where the crash happens and fix it",
                    "Explain how the parser works and then add a test for it",
                    "Explain what this does and then refactor it",
                    "Explain how to build and test the parser, and fix the crash"]
EXPLANATIONS = ["Explain how to build and test the parser", "Describe how to add and remove a Python package",
                "Explain why we add tests and remove Python packages",
                "Explain what we should add and remove in the package",
                "Explain how to install the package and configure the database"]


class GoalClassifierTests(unittest.TestCase):
    def test_explain_then_fix_phrasings_are_coding(self):
        for phrase in EXPLAIN_THEN_FIX:
            self.assertTrue(goal_classifier.looks_like_coding(phrase), phrase)

    def test_how_to_and_the_explained_clauses_own_verbs_stay_general(self):
        for phrase in EXPLANATIONS:
            self.assertFalse(goal_classifier.looks_like_coding(phrase), phrase)

    def test_every_phrase_is_in_the_swift_goal_table(self):
        source = (ROOT / 'Tests/AgentAppTests/GoalTests.swift').read_text()
        for phrase in EXPLAIN_THEN_FIX + EXPLANATIONS:
            self.assertIn('"%s"' % phrase, source)


class GitLayoutBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.vg = runpy.run_path(str(fixture.SANDBOX))['verify_git']

    def linked(self, main_name='main', name='linked'):
        main = self.root / main_name
        fixture.make_repo(main)
        linked = self.root / name
        self.assertEqual(fixture.git(main, 'worktree', 'add', '-q', str(linked)).returncode, 0)
        return main, linked, Path((linked / '.git').read_text()[8:].strip())

    def bare_worktree(self):
        origin = self.root / 'origin'
        fixture.make_repo(origin)
        bare = self.root / 'project.git'
        self.assertEqual(fixture.git(self.root, 'clone', '-q', '--bare', str(origin), str(bare)).returncode, 0)
        worktree = self.root / 'wt'
        result = fixture.git(bare, 'worktree', 'add', '-q', str(worktree))
        self.assertEqual(result.returncode, 0, result.stderr)
        return bare, worktree

    def submodule(self):
        library = self.root / 'library'
        fixture.make_repo(library)
        parent = self.root / 'super'
        fixture.make_repo(parent)
        result = fixture.git(parent, '-c', 'protocol.file.allow=always', 'submodule', 'add', '-q', str(library), 'lib')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((parent / 'lib/.git').is_file())
        return parent / 'lib'


class GitAuthorityTests(GitLayoutBase):
    def test_bare_common_directory_is_admitted_under_the_same_reciprocity_checks(self):
        bare, worktree = self.bare_worktree()
        self.assertEqual(self.vg.layout(worktree)['paths'][1], str(bare))
        target = Path((worktree / '.git').read_text()[8:].strip())
        (target / 'gitdir').write_text(str(self.root / 'origin/.git') + '\n')
        with self.assertRaisesRegex(OSError, 'backlink'):
            self.vg.layout(worktree)

    def test_relative_backlinks_are_admitted_and_must_name_this_worktree(self):
        _, linked, target = self.linked()
        (target / 'gitdir').write_text(os.path.relpath(linked / '.git', target) + '\n')
        (linked / '.git').write_text('gitdir: ' + os.path.relpath(target, linked) + '\n')
        self.assertEqual(len(self.vg.layout(linked)['paths']), 2)
        elsewhere = self.root / 'elsewhere'
        elsewhere.mkdir()
        (elsewhere / '.git').write_text((linked / '.git').read_text())
        (target / 'gitdir').write_text(os.path.relpath(elsewhere / '.git', target) + '\n')
        with self.assertRaisesRegex(OSError, 'backlink'):
            self.vg.layout(linked)

    def test_backlink_is_compared_by_file_identity_not_spelling(self):
        # A hard link is the same .git file under another name (as ~/Work and ~/work are on case-insensitive APFS).
        _, linked, target = self.linked()
        alias = self.root / 'alias-of-dot-git'
        os.link(str(linked / '.git'), str(alias))
        (target / 'gitdir').write_text(str(alias) + '\n')
        self.assertEqual(len(self.vg.layout(linked)['paths']), 2)
        copy = self.root / 'copy-of-dot-git'
        shutil.copyfile(str(linked / '.git'), str(copy))
        (target / 'gitdir').write_text(str(copy) + '\n')
        with self.assertRaisesRegex(OSError, 'backlink'):
            self.vg.layout(linked)

    def test_unsupported_layouts_are_recorded_and_verification_refuses_with_the_reason(self):
        workspace = self.submodule()
        with self.assertRaises(OSError):
            self.vg.capture(workspace, self.root / 'strict.json')  # The library default still refuses.
        state = self.vg.capture(workspace, self.root / 'trust.json', record_unsupported=True)
        self.assertIn('unsupported', state)
        self.assertEqual(json.loads((self.root / 'trust.json').read_text()), state)
        with self.assertRaisesRegex(OSError, 'not supported for verification'):
            self.vg.validated_paths(workspace, state)
        with self.assertRaisesRegex(OSError, 'outside the workspace'):
            self.vg.capture(workspace, workspace / 'inside.json', record_unsupported=True)

    def test_a_nul_byte_in_a_pointer_is_recorded_as_unsupported_not_a_crash(self):
        _, linked, target = self.linked()
        (target / 'gitdir').write_text(str(linked / '.git') + '\0x\n')
        state = self.vg.capture(linked, self.root / 'trust.json', record_unsupported=True)
        self.assertIn('null', state['unsupported'])
        with self.assertRaisesRegex(OSError, 'not supported for verification'):
            self.vg.validated_paths(linked, state)

    # Xrev2 finding 7: these forgeries pass every structure check, so only the pre-tool pin can refuse them.
    def test_structurally_valid_forged_gitfile_is_refused_by_the_pin(self):
        _, linked, _ = self.linked()
        snapshot = self.vg.layout(linked)
        _, other_link, other_target = self.linked('other', 'other-linked')
        (other_target / 'gitdir').write_text(str(linked / '.git') + '\n')
        (linked / '.git').write_text((other_link / '.git').read_text())
        self.assertEqual(self.vg.layout(linked)['paths'][1], str(self.root / 'other/.git'))
        with self.assertRaisesRegex(OSError, 'changed since pre-tool capture'):
            self.vg.validated_paths(linked, snapshot)

    def test_respelled_commondir_is_refused_by_the_pin(self):
        main, linked, target = self.linked()
        snapshot = self.vg.layout(linked)
        (target / 'commondir').write_text(str(main / '.git') + '\n')  # Same directory as the original "../..".
        self.assertEqual(self.vg.layout(linked)['paths'], snapshot['paths'])
        with self.assertRaisesRegex(OSError, 'changed since pre-tool capture'):
            self.vg.validated_paths(linked, snapshot)


class CodeJobLayoutTests(GitLayoutBase):
    """Xrev2 finding 2 and 5: git authority is captured only for verification, and kept out of the CLI's reach."""

    def setUp(self):
        super().setUp()
        self.scripts = self.root / 'isolated/coding/scripts'
        self.scripts.mkdir(parents=True)
        for path in SCRIPTS.iterdir():
            if path.is_file():
                shutil.copyfile(str(path), str(self.scripts / path.name))
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.stub('')

    def stub(self, extra):
        codex = self.bin / 'codex'
        codex.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > ' + shlex.quote(str(self.root / 'codex.args')) +
                         '\nprintf fresh > "$SWARMHUB_REPORT_FILE"\n' + extra + '\necho synthetic-tool-ran\n')
        codex.chmod(0o755)

    def job(self, directory, verify=None):
        args = ['/bin/sh', str(self.scripts / 'code-job'), '--bot', 'QA', '--order', 'codex', '--model', 'synthetic-model',
                '--report', 'REPORT.txt', '--dir', str(directory)]
        if verify is not None:
            args += ['--verify', verify]
        env = dict(fixture.GIT_ENV, HOME=str(self.home), PATH=str(self.bin) + ':/usr/bin:/bin', CODE_JOB_TICK='0.05',
                   SWARMHUB_VERIFY_NAMESPACES='0')
        # Preserve the tmp root used by the parent fixture (macOS normally uses /var/folders/.../T).
        # Without it, the child only knows /tmp and cannot recognize a HOME created under that root.
        env['TMPDIR'] = os.environ.get('TMPDIR', tempfile.gettempdir())
        return subprocess.run(args + ['--', 'synthetic task'], env=env, capture_output=True, text=True, timeout=60)

    def committed(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('synthetic-tool-ran', result.stdout)
        self.assertNotIn('verification will refuse', result.stderr)

    def test_bare_repository_worktree_job_runs_without_verify(self):
        _, worktree = self.bare_worktree()
        self.stub('git commit -q --allow-empty -m synthetic')
        self.committed(self.job(worktree))

    def test_submodule_job_runs_without_verify(self):
        workspace = self.submodule()
        self.stub('git commit -q --allow-empty -m synthetic')
        self.committed(self.job(workspace))

    def test_submodule_job_with_verify_runs_the_tool_and_reports_unverified(self):
        workspace = self.submodule()
        self.stub('git commit -q --allow-empty -m synthetic')
        result = self.job(workspace, 'printf ran > sub/verify-ran')
        self.assertEqual(result.returncode, 66, result.stdout + result.stderr)
        self.assertIn('synthetic-tool-ran', result.stdout)
        self.assertIn('verification will refuse: Git layout not supported', result.stderr)
        self.assertIn('verify exit 77', result.stderr)
        self.assertFalse((workspace / 'sub/verify-ran').exists())

    def test_bare_repository_worktree_is_verified(self):
        _, worktree = self.bare_worktree()
        # Limited mode refuses new top-level workspace entries, so the marker goes into an existing directory.
        result = self.job(worktree, 'git rev-parse HEAD > /dev/null && printf ran > sub/verify-ran')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual((worktree / 'sub/verify-ran').read_text(), 'ran')

    def test_tool_forged_structurally_valid_gitfile_is_refused_by_the_pin(self):
        _, linked, _ = self.linked()
        _, other_link, other_target = self.linked('other', 'other-linked')
        (self.root / 'other/.git/synthetic-secret').write_text('synthetic-secret-never-readable')
        (other_target / 'gitdir').write_text(str(linked / '.git') + '\n')
        self.stub('cp ' + shlex.quote(str(other_link / '.git')) + ' .git')
        result = self.job(linked, 'printf ran > sub/command-ran; cat ' +
                          shlex.quote(str(self.root / 'other/.git/synthetic-secret')))
        self.assertEqual(result.returncode, 66, result.stdout + result.stderr)
        self.assertIn('verify exit 77', result.stderr)
        self.assertFalse((linked / 'sub/command-ran').exists())
        self.assertNotIn('synthetic-secret-never-readable', result.stdout + result.stderr)
        self.assertEqual(self.vg.layout(linked)['paths'][1], str(self.root / 'other/.git'))  # Structure alone passes.

    def test_snapshot_is_kept_in_launcher_state_outside_codex_writable_roots(self):
        # The fixture HOME must lie outside /tmp and $TMPDIR (codex-writable), as a real one does.
        # Keep disposable files in the writable checkout, including when the user's HOME is read-only.
        base = ROOT.resolve()
        if any(base == Path(d).resolve() or Path(d).resolve() in base.parents
               for d in ('/tmp', os.environ.get('TMPDIR', '/tmp'))):
            self.skipTest('checkout is inside a temporary directory here')
        outside = tempfile.TemporaryDirectory(dir=str(base), prefix='.swarmhub-fixes12-')
        self.addCleanup(outside.cleanup)
        self.home = Path(outside.name) / 'home'
        self.home.mkdir()
        _, linked, _ = self.linked()
        listing = self.root / 'scratch.list'
        self.stub('ls "$HOME"/.hermes/swarmhub/scratch/*/ > ' + shlex.quote(str(listing)))
        result = self.job(linked, 'true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('git-trust.json', listing.read_text().split())
        self.assertNotIn('exclude_slash_tmp', (self.root / 'codex.args').read_text())
        self.assertEqual(list((self.home / '.hermes/swarmhub/scratch').iterdir()), [])  # Removed at exit.

    def test_fixture_home_under_tmp_also_falls_back_and_denies_codex_tmp(self):
        _, linked, _ = self.linked()
        result = self.job(linked, 'true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = (self.root / 'codex.args').read_text().splitlines()
        self.assertIn('sandbox_workspace_write.exclude_slash_tmp=true', args)
        self.assertIn('sandbox_workspace_write.exclude_tmpdir_env_var=true', args)

    def test_symlinked_tmpdir_outside_slash_tmp_falls_back_and_denies_codex_tmp(self):
        # Keep the physical HOME outside /tmp: otherwise Linux's /tmp check masks a lost TMPDIR.
        base = ROOT.resolve()
        if base == Path('/tmp').resolve() or Path('/tmp').resolve() in base.parents:
            self.skipTest('checkout is inside /tmp; this regression needs a separate temporary root')
        outside = tempfile.TemporaryDirectory(dir=str(base), prefix='.swarmhub-fixes12-')
        self.addCleanup(outside.cleanup)
        layout = Path(outside.name)
        physical_tmp = layout / 'private/var/folders/synthetic/T'
        physical_tmp.mkdir(parents=True)
        (layout / 'var').symlink_to(layout / 'private/var', target_is_directory=True)
        tmp_alias = layout / 'var/folders/synthetic/T'
        self.home = physical_tmp / 'home'
        self.home.mkdir()
        _, linked, _ = self.linked()
        listing = self.root / 'scratch.list'
        self.stub('ls -A "$HOME"/.hermes/swarmhub/scratch > ' + shlex.quote(str(listing)))
        # Exercise both physical and aliased HOME spellings, with TMPDIR's usual trailing slash.
        for home in (physical_tmp / 'home', tmp_alias / 'home'):
            with self.subTest(home=str(home)), patch.dict(os.environ, TMPDIR=str(tmp_alias) + '/'):
                self.home = home
                (linked / 'REPORT.txt').unlink(missing_ok=True)
                result = self.job(linked, 'true')
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                args = (self.root / 'codex.args').read_text().splitlines()
                self.assertIn('sandbox_workspace_write.exclude_slash_tmp=true', args)
                self.assertIn('sandbox_workspace_write.exclude_tmpdir_env_var=true', args)
                # The private snapshot must have moved out of HOME before the coding CLI starts.
                self.assertEqual(listing.read_text(), '')
                self.assertEqual(list((home / '.hermes/swarmhub/scratch').iterdir()), [])

    def test_home_workspace_falls_back_to_tmp_and_denies_codex_tmp(self):
        listing = self.root / 'scratch.list'
        self.stub('ls -A "$HOME"/.hermes/swarmhub/scratch > ' + shlex.quote(str(listing)))
        result = self.job(self.home, 'true')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(listing.read_text(), '')
        args = (self.root / 'codex.args').read_text().splitlines()
        self.assertIn('sandbox_workspace_write.exclude_slash_tmp=true', args)
        self.assertIn('sandbox_workspace_write.exclude_tmpdir_env_var=true', args)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, HOME=self.tmp.name)
        env.start()
        self.addCleanup(env.stop)
        for name in ('owner', 'worker'):
            (Path(self.tmp.name) / '.hermes/profiles' / name).mkdir(parents=True)
        policy.publish({'owner': 'owner', 'coordinator': 'owner'})

    def test_outbound_never_takes_a_caller_supplied_command(self):
        spec = {'kind': 'outbound', 'bot': 'worker', 'intent': 'draft', 'to': 'alice', 'text': 'hi',
                'argv': ['/bin/sh', '-c', 'printf synthetic-payload']}
        with self.assertRaisesRegex(ValueError, 'outbound argv must match'):
            policy.validate_spec(dict(spec, fake=True))
        policy.publish({'outbound': ['/bin/echo']})
        for variant in (spec, dict(spec, fake=True), dict(spec, argv=['/bin/echo', '--to', 'mallory', '--text', 'hi'])):
            with self.assertRaisesRegex(ValueError, 'outbound argv must match'):
                policy.validate_spec(dict(variant))
        exact = dict(spec, argv=['/bin/echo', '--to', 'alice', '--text', 'hi'])
        self.assertEqual(policy.validate_spec(exact), 'coordinator')
        del spec['argv']
        ident = policy.submit(spec)
        self.assertEqual(json.loads(policy.action(ident)['spec'])['argv'], exact['argv'])
        self.assertEqual(policy.action(ident)['status'], 'awaiting-coordinator')

    def test_integers_beyond_2_53_are_refused_anywhere_in_a_spec(self):
        base = {'kind': 'provision', 'bot': 'worker', 'intent': 'provision'}
        for value in (2 ** 53 + 1, -(2 ** 53) - 1, 10 ** 30):
            with self.assertRaisesRegex(ValueError, r'2\^53'):
                policy.validate_spec(dict(base, request={'count': value}))
        self.assertFalse(policy.exact_integers({'a': [{'b': 2 ** 60}]}))
        self.assertTrue(policy.exact_integers({'a': [True, -(2 ** 53), 2 ** 53, 'x', 1.5]}))
        policy.publish({'provisioner': ['/bin/true']})
        self.assertEqual(policy.validate_spec(dict(base, request={'count': 2 ** 53})), 'owner')


class RemoteHandlerTests(unittest.TestCase):
    """Xrev2 finding 4, driven through do_POST on in-memory streams (no socket)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        env = patch.dict(os.environ, HOME=self.tmp.name)
        env.start()
        self.addCleanup(env.stop)
        self.keys = {name: 'synthetic-' + name + '-key' for name in ('owner', 'worker')}
        for name, key in self.keys.items():
            root = Path(self.tmp.name) / '.hermes/profiles' / name
            root.mkdir(parents=True)
            (root / '.env').write_text('export API_SERVER_KEY="' + key + '"\n')
        policy.publish({'owner': 'owner', 'coordinator': 'owner'})
        self.wake = Mock()
        self.service = remote.ControlService('https://box.example.invalid', self.wake)
        self.task = policy.submit({'kind': 'outbound', 'bot': 'worker', 'intent': 'fixture', 'fake': True,
                                   'to': 'nobody@example.invalid', 'text': 'FAKE never sent', 'risks': ['money']})

    def decide(self):
        now = int(time.time())
        row = policy.action(self.task)
        return dict(version=1, origin=self.service.origin, profile='owner', verb='decide', task=self.task,
                    nonce=str(uuid.uuid4()), issued=now, expires=now + 60,
                    binding=dict(origin=self.service.origin, runtime=self.service.runtime, profile='owner'),
                    fingerprint=row['fingerprint'], gate=row['gate'], approved=True)

    def post(self, value):
        raw = canonical(value).encode()
        key = self.keys['owner']
        head = 'Content-Length: %d\r\nAuthorization: Bearer %s\r\nX-SwarmHub-Signature: %s\r\n\r\n' % (
            len(raw), key, remote.mac(key, 'request', raw))
        Handler = remote.handler(self.service)
        request = Handler.__new__(Handler)
        request.headers = http.client.parse_headers(io.BytesIO(head.encode()))
        request.rfile, request.wfile, request.connection = io.BytesIO(raw), io.BytesIO(), Mock()
        request.path, request.command, request.request_version = remote.PREFIX + 'owner', 'POST', 'HTTP/1.1'
        request.requestline, request.client_address = 'POST', ('127.0.0.1', 0)
        request.do_POST()
        head, _, body = request.wfile.getvalue().partition(b'\r\n\r\n')
        return int(head.split(b' ', 2)[1]), json.loads(body)

    def test_unexpected_exceptions_are_a_deterministic_403(self):
        for error in (sqlite3.OperationalError('database is locked'), RecursionError('synthetic nesting')):
            with self.subTest(error=type(error).__name__), patch.object(self.service, 'handle', side_effect=error):
                self.assertEqual(self.post(self.decide()), (403, {'error': 'control request refused'}))
        self.assertEqual(policy.action(self.task)['status'], 'awaiting-owner')

    def test_wake_failure_after_commit_still_returns_the_signed_receipt(self):
        self.wake.side_effect = OSError('synthetic worker start failure')
        status, response = self.post(self.decide())
        self.assertEqual(status, 200, response)
        payload = base64.b64decode(response['payload'])
        self.assertEqual(response['signature'], remote.mac(self.keys['owner'], 'response', payload))
        self.assertTrue(json.loads(payload)['record']['remoteReceipt']['approved'])
        self.assertNotEqual(policy.action(self.task)['status'], 'awaiting-owner')
        self.wake.assert_called_once()


@unittest.skipUnless(sys.platform == 'linux', 'Linux namespaced IPC')
class SendmsgIpcTests(unittest.TestCase):
    def test_mode_report_is_sent_with_sendmsg_never_sendall(self):
        module = runpy.run_path(str(fixture.SANDBOX))
        receiver, sender = socket.socketpair()
        self.addCleanup(receiver.close)
        self.addCleanup(sender.close)
        calls = []

        class Spy:
            def sendmsg(self, buffers, *rest):
                calls.append(list(buffers))
                return sender.sendmsg(buffers, *rest)

            def sendall(self, *_):
                raise AssertionError('sendall used for the mode report')
            send = sendall

            def close(self):
                sender.close()

        def namespaced(workspace, temporary, command, env, report):
            os.write(report, b'namespaced')
            return 0
        with tempfile.TemporaryDirectory() as tmp, \
                patch.dict(module['linux_child'].__globals__, namespaced_run=namespaced, namespaces_requested=lambda: True):
            self.assertEqual(module['linux_child'](Path(tmp), tmp, '', {}, Spy()), 0)
        self.assertEqual(calls, [[b'namespaced']])
        self.assertEqual(receiver.recv(32), b'namespaced')


class DarwinTeardownTests(unittest.TestCase):
    """Xrev2 finding 9: the Darwin verifier's process group is killed after it exits (runs on Linux and macOS)."""

    def test_background_descendants_are_killed_when_the_verifier_exits(self):
        darwin = runpy.run_path(str(fixture.SANDBOX))['verify_darwin']
        with tempfile.TemporaryDirectory() as tmp:
            code = darwin.run_grouped(['/bin/sh', '-c', 'sleep 59.41 & echo $! > pid; exit 3'],
                                      env={'PATH': '/usr/bin:/bin'}, cwd=tmp)
            self.assertEqual(code, 3)
            pid = (Path(tmp) / 'pid').read_text().strip()

        def alive():
            state = subprocess.run(['ps', '-o', 'stat=', '-p', pid], capture_output=True, text=True).stdout.strip()
            return bool(state) and not state.startswith('Z')
        deadline = time.time() + 5
        while alive() and time.time() < deadline:
            time.sleep(0.05)
        self.assertFalse(alive(), 'background verifier process survived')


if __name__ == '__main__':
    unittest.main()
