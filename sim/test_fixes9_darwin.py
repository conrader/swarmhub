"""Seatbelt profile checks everywhere; real Xcode-shim and git probes only on macOS."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
from pathlib import Path
import runpy
import shlex
import sys
import tempfile
import unittest
from unittest.mock import patch

try:
    from sim import test_fixes6 as fixture
except ImportError:
    import test_fixes6 as fixture


class DarwinToolchainProfileTests(unittest.TestCase):
    def setUp(self):
        self.module = runpy.run_path(str(fixture.SANDBOX))

    def test_license_selection_grants_are_read_only_and_exact(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = self.module['darwin_profile'](Path(directory), directory + '/tmp')
        for path in ('/Library/Preferences/com.apple.dt.Xcode.plist',
                     '/Library/Preferences/com.apple.dt.CommandLineTools.plist', '/private/var/db/xcode_select_link'):
            self.assertIn('(allow file-read* (literal ' + json.dumps(path) + '))', profile)
        for path in ('/Library/Preferences', '/Library', '/private/var/db', '/Users'):
            self.assertNotIn('(subpath ' + json.dumps(path) + ')', profile)
        self.assertNotIn('cfprefsd', profile)
        self.assertNotIn('(allow network', profile)
        self.assertIn('(deny default)', profile)

    def test_selected_developer_directory_is_readable_without_granting_its_siblings(self):
        module = self.module['verify_darwin']
        original_exists, original_realpath = module.os.path.exists, module.os.path.realpath
        selection = '/private/var/db/xcode_select_link'
        selected = '/Applications/Custom Xcode.app/Contents/Developer'
        with patch.object(module.os.path, 'exists', side_effect=lambda p: True if p == selection else original_exists(p)), \
             patch.object(module.os.path, 'realpath', side_effect=lambda p: selected if p == selection else original_realpath(p)):
            profile = module.darwin_profile(Path('/workspace'), '/private/tmp/verify')
        self.assertIn('(allow file-read* file-map-executable (subpath ' + json.dumps(selected) + '))', profile)
        self.assertNotIn('(subpath "/Applications")', profile)
        self.assertNotIn('(allow file-write* (subpath ' + json.dumps(selected), profile)

    def test_linked_gitdirs_are_readable_with_exact_ancestor_metadata_and_write_denials(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            main = root / 'private-parent/main'; fixture.make_repo(main)
            linked = root / 'linked'
            self.assertEqual(fixture.git(main, 'worktree', 'add', '-q', str(linked)).returncode, 0)
            self.module['git_dir'].__globals__['GIT_SNAPSHOT'] = self.module['verify_git'].layout(linked)
            profile = self.module['darwin_profile'](linked, str(root / 'temp'))
            for path in self.module['git_dir'](linked):
                self.assertIn('(allow file-read* (subpath ' + json.dumps(str(path)) + '))', profile)
                self.assertIn('(deny file-write* (subpath ' + json.dumps(str(path)) + '))', profile)
                for parent in path.parents:
                    self.assertIn('(allow file-read-metadata (literal ' + json.dumps(str(parent)) + '))', profile)
            self.assertNotIn('(subpath ' + json.dumps(str(main)) + ')', profile)


@unittest.skipUnless(sys.platform == 'darwin', 'real MacBook Seatbelt / Xcode toolchain required')
class DarwinToolchainNativeTests(fixture.SandboxBase):
    def python(self, code):
        return self.run_verify('/usr/bin/python3 -c ' + shlex.quote(code))

    def test_system_python_shim_reaches_the_actual_probe(self):
        result = self.python('import sys; print("python-probe-reached", sys.executable)')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('python-probe-reached', result.stdout)
        self.assertNotIn('Xcode license', result.stdout + result.stderr)

    def assert_write_denied(self, path):
        code = 'import errno, pathlib\nprint("write-probe-reached", flush=True)\n'
        code += 'try:\n    pathlib.Path(%r).write_text("denied")\n' % str(path)
        code += 'except OSError as e:\n    assert e.errno in (errno.EACCES, errno.EPERM), e\n    print("write-denied")\n'
        code += 'else:\n    raise AssertionError("write escaped")\n'
        result = self.python(code)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('write-probe-reached', result.stdout)
        self.assertIn('write-denied', result.stdout)

    def test_linked_worktree_git_runs_but_both_metadata_dirs_and_host_secrets_stay_closed(self):
        main = self.repo
        linked = self.root / 'linked'
        self.assertEqual(fixture.git(main, 'worktree', 'add', '-q', str(linked)).returncode, 0)
        self.repo = linked
        self.trust_git()
        gitdir = Path((linked / '.git').read_text().split('gitdir:', 1)[1].strip())
        result = self.run_verify('git status --short && git rev-parse HEAD && printf "git-probe-reached\\n"')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('git-probe-reached', result.stdout)
        for path in (linked / '.git', gitdir / 'config', main / '.git/config', self.marker):
            self.assert_write_denied(path)
        secret = self.root / 'host-secret'; secret.write_text('synthetic-host-secret')
        result = self.python('import errno\nprint("read-probe-reached", flush=True)\n'
                             'try:\n    open(%r).read()\n' % str(secret) +
                             'except OSError as e:\n    assert e.errno in (errno.EACCES, errno.EPERM), e\n    print("read-denied")\n'
                             'else:\n    raise AssertionError("secret escaped")\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('read-probe-reached', result.stdout)
        self.assertIn('read-denied', result.stdout)


class GitPointerAuthorityTests(fixture.SandboxBase):
    """The same trusted layout gates Linux limited grants and generated Seatbelt grants."""
    namespaces = '0'

    def setUp(self):
        super().setUp()
        self.module = runpy.run_path(str(fixture.SANDBOX))
        self.secret_dir = self.root / 'synthetic-home'
        self.secret_dir.mkdir()
        self.secret = self.secret_dir / 'secret'
        self.secret.write_text('synthetic-secret-never-readable')

    def linked(self):
        main = self.repo
        linked = self.root / 'linked'
        self.assertEqual(fixture.git(main, 'worktree', 'add', '-q', str(linked)).returncode, 0)
        self.repo = linked
        self.trust_git()
        return main, Path((linked / '.git').read_text()[8:].strip())

    def refused(self):
        # Refusal is the expected startup contract here, not proof of an in-sandbox denial.
        result = self.run_verify('printf command-ran; cat ' + shlex.quote(str(self.secret)))
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertNotIn('command-ran', result.stdout)
        self.assertNotIn('synthetic-secret-never-readable', result.stdout)
        self.module['git_dir'].__globals__['GIT_SNAPSHOT'] = json.loads(self.git_snapshot.read_text())
        with self.assertRaises(OSError):
            self.module['darwin_profile'](self.repo, str(self.root / 'temporary'))

    def test_trusted_linked_worktree_git_status_and_head_work_in_limited_mode(self):
        self.linked()
        result = self.run_verify('git status --short && git rev-parse HEAD')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertRegex(result.stdout, r'[0-9a-f]{40}')

    def test_canonical_backlink_alias_is_validated_before_capture(self):
        # /var and /private/var on Mac are aliases; reproduce that without Mac APIs.
        linked = self.root / 'linked'
        self.assertEqual(fixture.git(self.repo, 'worktree', 'add', '-q', str(linked)).returncode, 0)
        target = Path((linked / '.git').read_text()[8:].strip())
        alias = self.root / 'alias'; alias.symlink_to(linked, target_is_directory=True)
        (target / 'gitdir').write_text(str(alias / '.git') + '\n')
        self.repo = linked
        self.trust_git()
        result = self.run_verify('git status --short && git rev-parse HEAD')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_forged_gitfile_cannot_grant_synthetic_secret_directory(self):
        self.linked()
        (self.repo / '.git').write_text('gitdir: ' + str(self.secret_dir) + '\n')
        self.refused()

    def test_forged_commondir_cannot_grant_synthetic_secret_directory(self):
        _, target = self.linked()
        (target / 'commondir').write_text(str(self.secret_dir) + '\n')
        self.refused()

    def test_structurally_valid_replacement_roots_are_still_untrusted(self):
        self.linked()
        other = self.root / 'other'; fixture.make_repo(other)
        other_link = self.root / 'other-linked'
        self.assertEqual(fixture.git(other, 'worktree', 'add', '-q', str(other_link)).returncode, 0)
        target = Path((other_link / '.git').read_text()[8:].strip())
        (target / 'gitdir').write_text(str(self.repo / '.git') + '\n')
        (self.repo / '.git').write_text((other_link / '.git').read_text())
        self.refused()

    def test_standalone_linked_worktree_has_no_implicit_external_authority(self):
        self.linked()
        del self.git_snapshot
        result = self.run_verify('printf command-ran')
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertIn('pre-tool snapshot', result.stderr)
        with self.assertRaisesRegex(OSError, 'pre-tool snapshot'):
            self.module['darwin_profile'](self.repo, str(self.root / 'temporary'))

    def test_nested_linked_metadata_cannot_be_trusted_as_external_read_only_roots(self):
        workspace = self.root / 'outer'; workspace.mkdir()
        main = workspace / 'main'; fixture.make_repo(main)
        linked = self.root / 'registered'
        self.assertEqual(fixture.git(main, 'worktree', 'add', '-q', str(linked)).returncode, 0)
        target = Path((linked / '.git').read_text()[8:].strip())
        (workspace / '.git').write_text((linked / '.git').read_text())
        (target / 'gitdir').write_text(str(workspace / '.git') + '\n')
        with self.assertRaisesRegex(OSError, 'outside the writable workspace'):
            self.module['verify_git'].capture(workspace, self.root / 'nested.json')

    def test_preexisting_forged_pointers_are_refused_at_capture(self):
        for kind in ('gitfile', 'commondir'):
            with self.subTest(kind=kind):
                workspace = self.root / kind; workspace.mkdir()
                if kind == 'gitfile':
                    (workspace / '.git').write_text('gitdir: ' + str(self.secret_dir) + '\n')
                else:
                    fixture.make_repo(workspace)
                    (workspace / '.git/commondir').write_text(str(self.secret_dir) + '\n')
                with self.assertRaises(OSError):
                    self.module['verify_git'].capture(workspace, self.root / (kind + '.json'))
