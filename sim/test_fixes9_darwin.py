"""Seatbelt profile checks everywhere; real Xcode-shim and git probes only on macOS."""
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
