"""Execute the app's generated peer installer with subprocesses stubbed: no Hermes or box access."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import contextlib
import io
import json
from pathlib import Path
import subprocess
import textwrap
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def installer():
    source = (ROOT / 'Sources/AgentApp/Stores/PeerPluginEnablement.swift').read_text()
    literal = source.split('        return """\n', 1)[1].split('        """', 1)[0]
    script = textwrap.dedent(literal).split('\n', 1)[1].rsplit('SWARMHUB_PEER_ENABLE', 1)[0]
    return script.replace(r'\(folder)', '~/.hermes/profiles/test-bot/skills/swarmhub/swarmhub-messages').replace(
        r'\(profile)', 'test-bot').replace(r'\(marker)', 'SWARMHUB_PEER_ENABLE:')


class PeerEnablementTests(unittest.TestCase):
    def run_installer(self, enable_exit=0, list_exit=0, diagnostic='', listing='swarmhub-peer enabled', install_fails=False):
        calls = []

        def run(argv, **kwargs):
            calls.append(argv)
            if argv[0] == 'python3':
                self.assertEqual(argv[-2:], ['install', 'test-bot'])
                self.assertTrue(kwargs['check'])
                if install_fails:
                    raise subprocess.CalledProcessError(1, argv)
                return subprocess.CompletedProcess(argv, 0)
            self.assertEqual(argv[:3], ['hermes', '-p', 'test-bot'])
            if argv[3:] == ['plugins', 'enable', 'swarmhub-peer']:
                return subprocess.CompletedProcess(argv, enable_exit, diagnostic)
            self.assertEqual(argv[3:], ['plugins', 'list'])
            return subprocess.CompletedProcess(argv, list_exit, listing)

        output = io.StringIO()
        with patch('subprocess.run', side_effect=run), contextlib.redirect_stdout(output):
            if install_fails:
                with self.assertRaises(subprocess.CalledProcessError):
                    exec(compile(installer(), '<app peer installer>', 'exec'), {})
                self.assertEqual(len(calls), 1)
                self.assertEqual(output.getvalue(), '')
                return
            exec(compile(installer(), '<app peer installer>', 'exec'), {})
        self.assertEqual(len(calls), 3, 'one install, one enable, one verification; no retries or gateway reload')
        return json.loads(output.getvalue().removeprefix('SWARMHUB_PEER_ENABLE:'))

    def test_success_is_verified_with_plugins_list(self):
        receipt = self.run_installer()
        self.assertEqual(receipt['profile'], 'test-bot')
        self.assertEqual(receipt['enable_exit'], 0)
        self.assertEqual(receipt['list_output'], 'swarmhub-peer enabled')

    def test_pm_failure_still_verifies_and_returns_a_receipt(self):
        diagnostic = 'PermissionError: [Errno 13] Permission denied: environments/gen/workspace/pyproject.toml'
        receipt = self.run_installer(enable_exit=1, diagnostic=diagnostic, listing='swarmhub-peer disabled')
        self.assertEqual(receipt['enable_exit'], 1)
        self.assertEqual(receipt['enable_output'], diagnostic)
        self.assertEqual(receipt['list_exit'], 0)
        self.assertEqual(receipt['list_output'], 'swarmhub-peer disabled')

    def test_failed_verification_is_not_lost(self):
        receipt = self.run_installer(list_exit=1, listing='dependency-sync failed')
        self.assertEqual(receipt['list_exit'], 1)

    def test_install_failure_never_attempts_enablement(self):
        self.run_installer(install_fails=True)

    def test_diagnostics_are_bounded(self):
        receipt = self.run_installer(enable_exit=1, diagnostic='x' * 100_000, listing='y' * 100_000)
        self.assertEqual(len(receipt['enable_output']), 16_384)
        self.assertEqual(len(receipt['list_output']), 16_384)


if __name__ == '__main__':
    unittest.main()
