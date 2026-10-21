"""Gaps3 regressions. Parser fixtures mirror Swift; native Swift remains unexecuted on Linux."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import os
from pathlib import Path
import re
import stat
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from live_cli import cli_env, coding_cli, source_auth_snapshot, writable_cli_state
from test_peer_runtime import peer

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / 'Tests/Fixtures/managed_action_replies.json'


def objects(text):
    """Mirror ManagedActionObjects/SwarmhubBlock extraction, without searching prose for JSON."""
    lines, bodies, index = text.split('\n'), [], 0
    while index < len(lines):
        line = lines[index].strip(' \t\r')
        ticks = len(line) - len(line.lstrip('`'))
        if ticks < 3 or line[ticks:].strip().lower() != 'swarmhub':
            index += 1
            continue
        end = index + 1
        while end < len(lines):
            closing = lines[end].strip(' \t\r')
            if len(closing) >= ticks and set(closing) == {'`'}:
                break
            end += 1
        bodies.append('\n'.join(lines[index + 1:end]))
        index = end + 1
    def decode(body):
        try:
            return json.loads(body)
        except ValueError:
            return None
    if not bodies:
        obj = decode(text)
        return [obj] if isinstance(obj, dict) else []
    found = []
    for body in bodies:
        obj = decode(body)
        if isinstance(obj, dict):
            found.append(obj)
        elif isinstance(obj, list) and all(isinstance(item, dict) for item in obj):
            found.extend(obj)
    return found


def parsed_ids(text):
    """Mirror the unchanged required-field guards in ManagedApproval and SecretRequest."""
    tasks, names = [], []
    for obj in objects(text):
        if obj.get('op') == 'approval':
            task = obj.get('task')
            if (isinstance(task, str) and re.fullmatch(r'task\.[A-Za-z0-9_.-]{1,80}', task)
                    and isinstance(obj.get('kind'), str)
                    and obj['kind'] in {'coding', 'peer', 'read', 'outbound', 'provision', 'money', 'prod', 'secrets'}
                    and isinstance(obj.get('gate'), str) and obj['gate'] in {'owner', 'coordinator'}):
                tasks.append(task)
        elif obj.get('op') == 'secret_request':
            name = obj.get('name')
            if isinstance(name, str) and re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,63}', name):
                names.append(name)
    return tasks, names


class Gaps3Tests(unittest.TestCase):
    def test_login_status_mutates_only_disposable_auth_and_config(self):
        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / 'source'; source.mkdir()
            for name in ('auth.json', 'config.toml'):
                (source / name).write_text('QA source unchanged')
            cli = {'codex_home': str(source)}
            before = source_auth_snapshot(cli)
            private_paths = []
            def status(argv, **kwargs):
                private = Path(kwargs['env']['CODEX_HOME'])
                self.assertNotEqual(private, source)
                self.assertNotEqual(kwargs['env']['HOME'], temp)
                self.assertEqual(Path(kwargs['env']['HOME']).stat().st_mode & 0o777, 0o700)
                private_paths.append(private)
                for name in ('auth.json', 'config.toml'):
                    self.assertFalse((private / name).is_symlink())
                    (private / name).write_text('QA refresh or trust update')
                return SimpleNamespace(returncode=0, stdout='Logged in using ChatGPT', stderr='')
            with patch('live_cli.shutil.which', return_value='/installed/codex'), patch('live_cli.subprocess.run', side_effect=status):
                found = coding_cli({'HOME': temp, 'CODEX_HOME': str(source), 'PATH': '/installed'})
            self.assertEqual(found['codex_home'], str(source))
            self.assertEqual(before, source_auth_snapshot(cli))
            self.assertTrue(private_paths)
            self.assertTrue(all(not p.exists() for p in private_paths))

    def test_private_cli_runtime_and_auth_copies(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / 'source'; source.mkdir()
            for name in ('auth.json', 'config.toml'):
                (source / name).write_text('synthetic read-only reference')
                (source / name).chmod(0o400)
            before = {p.name: (p.read_bytes(), p.stat().st_mode) for p in source.iterdir()}
            cli = writable_cli_state({'codex_home': str(source), 'bin': '/installed'}, root / 'private')
            base = {'HOME': '/qa', 'PATH': '/usr/bin:/bin', 'TMPDIR': '/shared', 'XDG_RUNTIME_DIR': '/outer'}
            env = cli_env(base, cli)
            for key in ('codex_home', 'runtime_dir', 'tmp_dir'):
                path = Path(cli[key])
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o700)
                self.assertEqual(path.stat().st_uid, os.getuid())
            self.assertEqual(env['TMPDIR'], cli['tmp_dir'])
            self.assertEqual(env['XDG_RUNTIME_DIR'], cli['runtime_dir'])
            self.assertEqual(env['HOME'], '/qa')
            self.assertEqual(base['TMPDIR'], '/shared')
            for name in before:
                copy = Path(cli['codex_home']) / name
                self.assertFalse(copy.is_symlink())
                self.assertNotEqual(copy.stat().st_ino, (source / name).stat().st_ino)
                self.assertEqual(stat.S_IMODE(copy.stat().st_mode), 0o600)
                if name == "auth.json":
                    self.assertEqual(copy.read_bytes(), before[name][0])
                else:
                    self.assertIn(b"network_access = false", copy.read_bytes())
                # Exercise the original trust leak and a credential refresh.
                copy.write_text('QA private update: trusted project or refreshed auth')
            self.assertEqual(before, {p.name: (p.read_bytes(), p.stat().st_mode) for p in source.iterdir()})
            self.assertIsNone(writable_cli_state(None, root / 'unused'))
            self.assertFalse((root / 'unused').exists())

    def test_managed_action_reply_fixtures(self):
        for case in json.loads(FIXTURES.read_text()):
            with self.subTest(case=case['name']):
                self.assertEqual(parsed_ids(case['text']), (case['tasks'], case['names']))

    def test_skill_examples_are_valid_fences(self):
        skill = (ROOT / 'Resources/Skills/swarmhub-messages/SKILL.md').read_text()
        tasks, names = parsed_ids(skill)
        self.assertTrue(tasks)
        self.assertIn('openai-key', names)
        self.assertIn('Bare JSON, a `json` fence', skill)

    def test_receipt_distinguishes_configured_but_unrun_verification(self):
        with tempfile.TemporaryDirectory() as temp:
            job = Path(temp)
            for key, value in {'evidence': 'none', 'tests-passed': 'not-run', 'verify-command': 'grep -Fxq done NOTES.md'}.items():
                (job / key).write_text(value)
            text = peer.evidence_lines(job)
            self.assertIn('tests (verification configured but not run: grep -Fxq done NOTES.md)', text)
            self.assertNotIn('no verification command configured', text)
            (job / 'verify-command').write_text('')
            self.assertIn('tests (no verification command configured)', peer.evidence_lines(job))
            (job / 'verify-command').unlink()
            self.assertIn('tests (no verification command configured)', peer.evidence_lines(job))
