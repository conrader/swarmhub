"""macsmoke5 completion regressions; local files and fake CLIs only."""
import errno
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / 'Resources/Skills/swarmhub-coding/scripts'
spec = importlib.util.spec_from_file_location('completion_contract', SCRIPTS / 'completion-contract.py')
contract = importlib.util.module_from_spec(spec)
spec.loader.exec_module(contract)


class CompletionContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.job = Path(self.temp.name)
        self.report = self.job / 'REPORT.txt'

    def call(self, command):
        return contract.main(command, str(self.report), str(self.job))

    def test_unreadable_baseline_cannot_make_unchanged_report_fresh(self):
        for content in (b'', b'old report\n'):
            for operation in ('stat', 'open'):
                with self.subTest(content=content, operation=operation):
                    self.report.write_bytes(content)
                    original = os.stat if operation == 'stat' else open

                    def denied(path, *args, **kwargs):
                        if str(path) == str(self.report):
                            raise PermissionError(errno.EACCES, 'fixture denial')
                        return original(path, *args, **kwargs)

                    target = 'os.stat' if operation == 'stat' else 'builtins.open'
                    with patch(target, side_effect=denied):
                        self.assertEqual(self.call('baseline'), 65)
                        with self.assertRaises(OSError):
                            contract.fingerprint(str(self.report))
                    self.assertEqual((self.job / 'report-before-state').read_text(), 'unreadable-EACCES')
                    self.assertEqual((self.job / 'report-before').read_text(), 'invalid:unreadable-EACCES')
                    self.assertEqual(self.call('verify'), 65)
                    self.assertEqual((self.job / 'report-valid').read_text(), 'false')

    def test_baseline_never_creates_report_and_existing_bytes_are_preserved(self):
        self.assertEqual(self.call('baseline'), 0)
        self.assertFalse(self.report.exists())
        self.report.write_text('first report\n')
        self.assertEqual(self.call('verify'), 0)
        self.assertEqual(self.call('baseline'), 0)
        self.assertEqual(self.report.read_text(), 'first report\n')
        self.assertEqual(self.call('verify'), 65)
        self.report.write_text('second report\n')
        self.assertEqual(self.call('verify'), 0)

    def test_nonregular_baseline_and_invalid_baseline_record_fail_closed(self):
        self.report.mkdir()
        self.assertEqual(self.call('baseline'), 65)
        self.report.rmdir()
        self.report.write_text('new report\n')
        self.assertEqual(self.call('verify'), 65)
        (self.job / 'report-before').write_text('unrecognized-baseline')
        self.assertEqual(self.call('verify'), 65)

    def test_probe_rejects_successful_redirect_without_written_bytes(self):
        source = (ROOT / 'sim/mac-codex-tmp-smoke.sh').read_text()
        probe = source.split('cat > "$1/smoke-probe.sh" <<\'EOF\'\n', 1)[1].split('\nEOF', 1)[0]
        # Simulate an apparent successful write that only opens/truncates the destination.
        probe = probe.replace('printf \'%s\\n\' "$1" > "$2" || return 1', ': > "$2" || return 1')
        (self.job / 'smoke-probe.sh').write_text(probe)
        (self.job / 'smoke-targets').write_text(f'nonce fixture\nreport {self.report}\n')
        for shell in (['dash'], ['bash'], ['bash', '--posix']):
            if not shutil.which(shell[0]):
                continue
            with self.subTest(shell=shell):
                result = subprocess.run(shell + ['./smoke-probe.sh'], cwd=self.job, capture_output=True, text=True)
                self.assertNotIn(': WROTE', result.stdout)
                self.assertIn('write verification failed: bytes differ or cannot be read', result.stdout)
                self.assertEqual(self.report.read_bytes(), b'')

    def test_darwin_fallback_warning_precedes_cli_and_names_report_failure(self):
        # Isolated coding skill copy has no messaging sibling, policy or provider executable.
        scripts = self.job / 'skill/scripts'
        shutil.copytree(SCRIPTS, scripts)
        bin_dir = self.job / 'bin'
        bin_dir.mkdir()
        for name, text in {
            'uname': '#!/bin/sh\necho Darwin\n',
            'codex': '#!/bin/sh\necho stub-started >&2\n: > "$SWARMHUB_REPORT_FILE"\necho DONE\n',
        }.items():
            path = bin_dir / name
            path.write_text(text)
            path.chmod(0o755)
        home = self.job / 'home'
        home.mkdir()
        env = {k: v for k, v in os.environ.items() if not k.startswith(('CODE_JOB_', 'SWARMHUB_', 'HERMES_'))}
        env.update(HOME=str(home), PATH=str(bin_dir) + ':' + os.environ['PATH'], TMPDIR=str(self.job),
                   CODE_JOB_TICK='0.05')
        result = subprocess.run(['sh', str(scripts / 'code-job'), '--bot', 'fixture', '--order', 'codex',
                                 '--dir', str(home), '--model', 'fixture', '--report', 'REPORT.txt', '--', 'fixture'],
                                env=env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertLess(result.stderr.index('warning [macos-excluded-tmp-workspace]'),
                        result.stderr.index('stub-started'))
        journal, = (home / '.hermes/swarmhub/job-completions').iterdir()
        self.assertEqual((journal / 'status').read_text().strip(), 'report-failed-macos-excluded-tmp-workspace')
        self.assertEqual((journal / 'report-before-state').read_text(), 'missing')
        self.assertEqual((journal / 'report-state').read_text(), 'empty')


if __name__ == '__main__':
    unittest.main()
