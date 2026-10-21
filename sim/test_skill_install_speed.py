"""0.6.4 install speed: run the app's generated skill copy (SkillSync) and batch peer call under real shells.

The Swift literals are read from the sources and filled as the app fills them; Hermes and peer-runtime are stubs in a
temporary HOME. SkillInstallSpeedTests.swift runs the same commands as the app renders them on the Mac.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
SHELLS = [shell for shell in ('/bin/sh', '/bin/dash', '/bin/bash') if os.path.exists(shell)]
PM_SIGNS = ["permissionerror", "permission denied", "filesystem permissions", "dependency-sync", "dependency sync",
            "sync_venv", "sealed core", "sealed-core"]


def sync_script():
    source = (ROOT / 'Sources/AgentApp/Stores/SkillInstallSync.swift').read_text()
    literal = source.split('static let script = """\n', 1)[1].split('\n    """', 1)[0]
    return (textwrap.dedent(literal) + '\n').replace('\\\\0', '\\0').replace('\\(failure)', 'SWARMHUB_SYNC_FAILED')


def sync_command(src, dst, want, names, subs):
    args = [src, dst, want, ','.join(names)] + [part for pair in subs for part in pair]
    return 'python3 - ' + ' '.join("'%s'" % arg for arg in args) + " <<'SWARMHUB_SYNC'\n" + sync_script() + 'SWARMHUB_SYNC'


def digest(files):
    tree = hashlib.sha256()
    for path, data in files:
        tree.update(path.encode() + b'\0' + hashlib.sha256(data).digest())
    return tree.hexdigest()


def peer_command(profiles, skip):
    source = (ROOT / 'Sources/AgentApp/Stores/PeerPluginEnablement.swift').read_text()
    part = source.split('static func command(profiles: [String], skipEnable: Bool) -> String {', 1)[1]
    script = textwrap.dedent(part.split('return """\n', 1)[1].split('\n        """', 1)[0])
    rows = ', '.join("('%s', '~/.hermes/profiles/%s/skills/swarmhub/swarmhub-messages/scripts/peer-runtime.py')" % (p, p) for p in profiles)
    script = (script.replace('\\(skipEnable ? "True" : "False")', 'True' if skip else 'False')
              .replace('\\(pmBlockSigns.map { "\'\\($0)\'" }.joined(separator: ", "))', ', '.join("'%s'" % s for s in PM_SIGNS))
              .replace('\\(rows.joined(separator: ", "))', rows).replace("'\\(marker)'", "'SWARMHUB_PEER_ENABLE:'"))
    assert '\\(' not in script, script
    return script


class SkillSyncTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.home)
        self.src = Path(self.home, '.hermes/profiles/grok-a/skills/swarmhub/m')
        (self.src / 'scripts').mkdir(parents=True)
        (self.src / 'SKILL.md').write_text('name m\nbot grok-a at ~/.hermes/profiles/grok-a/skills/swarmhub/m\n')
        (self.src / 'scripts/x.py').write_text('print("grok-a stays")\n')
        self.want = [('SKILL.md', b'name m\nbot grok-b at ~/.hermes/profiles/grok-b/skills/swarmhub/m\n'),
                     ('scripts/x.py', b'print("grok-a stays")\n')]
        self.dst = Path(self.home, '.hermes/profiles/grok-b/skills/swarmhub/m')
        self.command = sync_command('~/.hermes/profiles/grok-a/skills/swarmhub/m', '~/.hermes/profiles/grok-b/skills/swarmhub/m',
                                    digest(self.want), ['SKILL.md*', 'scripts/x.py'],
                                    [('~/.hermes/profiles/grok-a/skills/swarmhub/m', '~/.hermes/profiles/grok-b/skills/swarmhub/m'),
                                     ('grok-a', 'grok-b')])

    def run_in(self, shell):
        return subprocess.run([shell, '-c', self.command], env={'HOME': self.home, 'PATH': '/usr/bin:/bin'},
                              capture_output=True, text=True)

    def test_copies_byte_for_byte_with_only_skill_md_renamed(self):
        for shell in SHELLS:
            with self.subTest(shell):
                shutil.rmtree(self.dst.parents[2], ignore_errors=True)
                result = self.run_in(shell)
                self.assertEqual(result.returncode, 0, result.stderr)
                for path, data in self.want:
                    self.assertEqual((self.dst / path).read_bytes(), data)
                self.assertEqual([p.name for p in self.dst.rglob('*.swarmhub-tmp')], [])

    def test_a_changed_source_writes_nothing(self):
        (self.src / 'scripts/x.py').write_text('print("grok-a stays")\n# edited\n')
        for shell in SHELLS:
            with self.subTest(shell):
                result = self.run_in(shell)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('SWARMHUB_SYNC_FAILED ~/.hermes/profiles/grok-b/skills/swarmhub/m', result.stderr)
                self.assertFalse(self.dst.exists())


class BatchPeerCallTests(unittest.TestCase):
    def run_batch(self, skip, blocked):
        home = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, home)
        log = os.path.join(home, 'calls.log')
        profiles = ['grok-a', 'grok-b', 'grok-c']
        for profile in profiles:
            folder = Path(home, '.hermes/profiles/%s/skills/swarmhub/swarmhub-messages/scripts' % profile)
            folder.mkdir(parents=True)
            (folder / 'peer-runtime.py').write_text("import sys\nopen(%r, 'a').write('runtime ' + ' '.join(sys.argv[1:]) + '\\n')\n" % log)
        enable = 'echo "PermissionError: [Errno 13] Permission denied"; exit 1' if blocked else 'echo enabled'
        listing = 'swarmhub-peer  disabled' if blocked else 'swarmhub-peer  enabled'
        Path(home, 'bin').mkdir()
        Path(home, 'bin/hermes').write_text('#!/bin/sh\necho "hermes $*" >> %s\ncase "$4" in\nenable) %s ;;\n*) echo "%s" ;;\nesac\n'
                                            % (log, enable, listing))
        os.chmod(os.path.join(home, 'bin/hermes'), 0o755)
        result = subprocess.run(['/bin/sh', '-c', peer_command(profiles, skip)], capture_output=True, text=True,
                                env={'HOME': home, 'PATH': os.path.join(home, 'bin') + ':/usr/bin:/bin'})
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = Path(log).read_text().splitlines()
        self.assertEqual(sorted(c for c in calls if c.startswith('runtime')),
                         sorted(['runtime install %s' % p for p in profiles] + ['runtime start'] * 3))
        receipts = [json.loads(line.split(':', 1)[1]) for line in result.stdout.splitlines() if line.startswith('SWARMHUB_PEER_ENABLE:')]
        self.assertEqual([r['profile'] for r in receipts], profiles)
        return [c for c in calls if c.startswith('hermes')], receipts

    def test_a_pm_block_on_the_first_profile_skips_the_rest(self):
        hermes, receipts = self.run_batch(skip=False, blocked=True)
        self.assertEqual(hermes, ['hermes -p grok-a plugins enable swarmhub-peer', 'hermes -p grok-a plugins list'])
        self.assertEqual([r['skipped'] for r in receipts], [False, True, True])
        self.assertIn('PermissionError', receipts[0]['enable_output'])

    def test_every_profile_is_enabled_when_hermes_allows_it(self):
        hermes, receipts = self.run_batch(skip=False, blocked=False)
        self.assertEqual(len(hermes), 6)
        self.assertTrue(all(r['enable_exit'] == 0 and not r['skipped'] for r in receipts))

    def test_a_known_block_never_starts_hermes(self):
        hermes, receipts = self.run_batch(skip=True, blocked=True)
        self.assertEqual(hermes, [])
        self.assertTrue(all(r['skipped'] for r in receipts))


if __name__ == '__main__':
    unittest.main()
