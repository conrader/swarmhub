"""Review 3 regressions; synthetic credentials/CLI only, no live Hermes or outbound sends."""
from contextlib import ExitStack
import io
import json
import os
from pathlib import Path
import re
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

if sys.version_info >= (3, 11):
    import tomllib
else:
    tomllib = None  # Xcode's Python 3.9 has no TOML parser; no third-party dependencies.

from live_cli import cli_env, writable_cli_state
from live_managed import ManagedSuite
import test_peer_runtime as boundary
import test_patterns as patterns

ROOT = Path(__file__).resolve().parents[1]
SANDBOX = ROOT / 'Resources/Skills/swarmhub-coding/scripts/verify-sandbox.py'
control = boundary.peer.control


class VerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / 'workspace'; self.repo.mkdir()
        self.outside = self.root / 'outside'

    def run_verify(self, command):
        return subprocess.run([sys.executable, '-B', str(SANDBOX), str(self.repo), command],
                              env=dict(os.environ, QA_SECRET='synthetic-secret'),
                              capture_output=True, text=True, timeout=15)

    def test_verifier_runs_builtins_and_workspace_executables_and_preserves_exit(self):
        # Exercise dyld startup on macOS as well as exec and cwd after startup.
        (self.repo / 'check').write_text('#!/bin/sh\nprintf checked > checked.txt\nexit 3\n')
        (self.repo / 'check').chmod(0o755)
        commands = [('true', 0), ('exit 5', 5), ('./check', 3), ('./missing-verifier', 127)]
        if sys.platform == 'darwin':
            commands.append(('printf checked > /dev/null', 0))
        for command, expected in commands:
            with self.subTest(command=command):
                result = self.run_verify(command)
                self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual((self.repo / 'checked.txt').read_text(), 'checked')

    def test_darwin_launch_allows_executable_mappings_without_opening_host_files(self):
        # Inspect the real Darwin launch on Linux too. This models the distinct
        # Seatbelt read/map checks; it does not emulate the macOS kernel or dyld.
        module = runpy.run_path(str(SANDBOX))
        def launch(argv, *, env, cwd):
            self.assertEqual(argv[:2], ['/usr/bin/sandbox-exec', '-p'])
            self.assertEqual(argv[3:7], ['/usr/bin/python3', '-I', '-B', '-c'])
            self.assertEqual(argv[7], module['verify_darwin'].SOCKET_GUARD)
            self.assertEqual(argv[8:], ['true'])
            self.assertEqual(cwd, self.repo.resolve())
            self.assertNotIn('QA_SECRET', env)
            self.assertTrue(argv[2].startswith('(version 1)(deny default)'))
            self.assertIn('(allow file-read* (literal "/"))', argv[2])
            rules = re.findall(r'\(allow ([\w* -]+) \((subpath|literal) ("(?:[^"\\]|\\.)*")\)\)', argv[2])

            def allowed(operation, path):
                for operations, kind, quoted in rules:
                    root = json.loads(quoted)
                    if not any(operation == op or op.endswith('*') and operation.startswith(op[:-1])
                               for op in operations.split()):
                        continue
                    if path == root or kind == 'subpath' and path.startswith(root.rstrip('/') + '/'):
                        return True
                return False

            self.assertTrue(allowed('file-read-data', '/'))
            self.assertFalse(allowed('file-write-data', '/'))
            self.assertFalse(allowed('file-map-executable', '/'))
            self.assertTrue(allowed('file-write-data', '/dev/null'))
            for path in ['/dev', '/dev/random', '/dev/tty']:
                self.assertFalse(allowed('file-write-data', path), path)
            for path in ['/bin/sh', '/usr/lib/dyld', '/System/Library/dyld/dyld_shared_cache_arm64e',
                         '/private/var/db/dyld/dyld_shared_cache_x86_64', str(cwd / 'check'),
                         str(Path(env['TMPDIR']) / 'check')]:
                self.assertTrue(allowed('file-read-data', path), path)
                self.assertTrue(allowed('file-map-executable', path), path)
            for parent in cwd.parents:
                self.assertTrue(allowed('file-read-metadata', str(parent)), str(parent))
            for path in [str(self.outside), '/Users/fixture/.ssh/id_rsa', '/private/tmp/unrelated',
                         '/host-secret']:
                self.assertFalse(allowed('file-read-data', path), path)
                self.assertFalse(allowed('file-write-data', path), path)
            self.assertFalse(allowed('file-write-data', '/usr/lib/dyld'))
            self.assertNotIn('(allow network', argv[2])
            return 0

        with patch.object(sys, 'argv', [str(SANDBOX), str(self.repo), 'true']), \
             patch.object(sys, 'platform', 'darwin'), \
             patch.object(module['verify_darwin'], 'run_grouped', side_effect=launch) as call:  # fixes12: group teardown
            self.assertEqual(module['main'](), 0)
            call.assert_called_once()

    def test_B1_outside_write_from_verify_command_is_denied(self):
        result = self.run_verify('printf executed > ' + shlex.quote(str(self.outside)))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.outside.exists())
        # A refusal to initialize a sandbox must not masquerade as a negative security test.
        positive = self.run_verify('printf local > local.txt')
        self.assertEqual(positive.returncode, 0, positive.stderr)
        self.assertEqual((self.repo / 'local.txt').read_text(), 'local')

    def test_B1_edited_test_cannot_write_outside_or_read_host_secret(self):
        self.outside.write_text('synthetic-host-secret')
        module = self.repo / 'edited.py'
        for statement in [f'Path({str(self.root / "escape")!r}).write_text("executed")',
                          f'Path({str(self.outside)!r}).read_text()']:
            with self.subTest(statement=statement):
                module.write_text('from pathlib import Path\n' + statement + '\n')
                result = self.run_verify('/usr/bin/python3 edited.py')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn('PermissionError', result.stderr)
        self.assertFalse((self.root / 'escape').exists())
        self.assertEqual(self.outside.read_text(), 'synthetic-host-secret')

    def test_B1_network_from_command_and_edited_test_is_denied(self):
        # Attempt socket creation only; no endpoint is ever contacted even on a broken sandbox.
        code = 'import socket; socket.socket(socket.AF_INET, socket.SOCK_STREAM)'
        (self.repo / 'edited.py').write_text(code)
        for command in ['/usr/bin/python3 -c ' + shlex.quote(code), '/usr/bin/python3 edited.py']:
            result = self.run_verify(command)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('PermissionError', result.stderr)

    def test_B1_environment_scrubbed_and_symlink_escape_denied(self):
        (self.repo / 'link').symlink_to(self.outside)
        result = self.run_verify('printf nope > link')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.outside.exists())
        self.assertEqual(self.run_verify('test -z "${QA_SECRET-}"').returncode, 0)

    def test_B1_admitted_code_job_cannot_execute_host_verification(self):
        scripts = self.root / 'isolated/coding/scripts'; scripts.mkdir(parents=True)
        shipped = SANDBOX.parent
        for name in ('code-job', 'completion-contract.py', 'scratch.py', 'verify-sandbox.py', 'verify_signals.py', 'verify_processes.py', 'verify_darwin.py', 'verify_git.py'):
            shutil.copyfile(shipped / name, scripts / name)
        fake_home = self.root / 'home'; fake_home.mkdir()
        stub_bin = self.root / 'bin'; stub_bin.mkdir()
        cli = stub_bin / 'codex'
        cli.write_text('#!/bin/sh\nprintf "%s" "$$" > "$SWARMHUB_REPORT_FILE"\necho synthetic-work\n')
        cli.chmod(0o755)
        (self.repo / 'edited.py').write_text('from pathlib import Path\nPath("probe-reached").write_text("python")\n' +
                                           f'Path({str(self.outside)!r}).write_text("executed")\n')
        commands = [('shell', 'printf shell > probe-reached; printf executed > ' + shlex.quote(str(self.outside))),
                    ('python', '/usr/bin/python3 edited.py')]
        for expected, command in commands:
            (self.repo / 'probe-reached').write_text('')
            result = subprocess.run(['/bin/sh', str(scripts / 'code-job'), '--bot', 'QA', '--order', 'codex',
                                     '--model', 'synthetic-model', '--report', 'REPORT.txt', '--dir', str(self.repo),
                                     '--verify', command, '--', 'synthetic task'],
                                    env={'HOME': str(fake_home), 'PATH': str(stub_bin) + ':/usr/bin:/bin',
                                         'CODE_JOB_TICK': '0.05', 'SWARMHUB_VERIFY_NAMESPACES': '0'}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 66, result.stderr)
            self.assertEqual((self.repo / 'probe-reached').read_text(), expected)
            self.assertNotIn('Xcode license', result.stdout + result.stderr)
            self.assertNotIn('ModuleNotFoundError', result.stdout + result.stderr)
            self.assertFalse(self.outside.exists())

    def test_B1_missing_sandbox_fails_closed(self):
        module = runpy.run_path(str(SANDBOX))
        with patch.object(sys, 'argv', [str(SANDBOX), str(self.repo), 'touch marker']), \
             patch.object(sys, 'platform', 'unsupported'):
            with self.assertRaises(OSError):
                module['main']()
        self.assertFalse((self.repo / 'marker').exists())


class RuntimeBindingTests(unittest.TestCase):
    setUp = boundary.PeerTests.setUp
    stop_background = boundary.PeerTests.stop_background
    sync = boundary.PeerTests.sync
    cli = patterns.ObservedPatternTests.cli
    spec = patterns.ObservedPatternTests.spec
    submit = patterns.ObservedPatternTests.submit
    job = patterns.ObservedPatternTests.job
    eventually = boundary.PeerTests.eventually

    def test_M1_owner_gated_verifier_is_frozen_before_defaults_change(self):
        self.cli()
        os.environ['CODE_JOB_VERIFY'] = 'printf frozen > frozen.txt'
        ident = self.submit('freeze-verifier', risks=['prod'])
        row = control.action(ident)
        self.assertEqual(json.loads(row['spec'])['verify'], 'printf frozen > frozen.txt')
        os.environ['CODE_JOB_VERIFY'] = 'printf changed > changed.txt'
        self.env['CODE_JOB_VERIFY'] = os.environ['CODE_JOB_VERIFY']
        (control.state() / 'coding.conf').write_text('VERIFY=printf config > config.txt\n')
        with patch.dict(os.environ, HERMES_HOME=str(self.home / '.hermes/profiles/coordinator')):
            control.publish({'owner': 'coordinator'})
            control.decide(ident, 'coordinator', True, row['fingerprint'], row['gate'])
        control.tick()
        self.eventually(lambda: (self.job(ident) / 'ready').exists())
        self.assertEqual((self.job(ident) / 'verify-command').read_text().strip(), 'printf frozen > frozen.txt')
        self.assertTrue((self.home / 'frozen.txt').exists())
        self.assertFalse((self.home / 'changed.txt').exists())
        self.assertFalse((self.home / 'config.txt').exists())

    def test_M1_explicit_no_verifier_ignores_environment_fallback(self):
        self.cli()
        os.environ['CODE_JOB_VERIFY'] = 'printf fallback > fallback.txt'
        ident = self.submit('no-verifier', verify='')
        control.tick()
        self.eventually(lambda: (self.job(ident) / 'ready').exists())
        self.assertEqual(json.loads(control.action(ident)['spec'])['verify'], '')
        self.assertEqual((self.job(ident) / 'verify-command').read_text().strip(), '')
        self.assertFalse((self.home / 'fallback.txt').exists())

    def test_B3_decision_rejects_wrong_fingerprint_or_gate(self):
        control.publish({'owner': 'coordinator'})
        # FAKE so even an accidental later scheduler tick cannot execute argv.
        ident = control.submit({'kind': 'prod', 'bot': 'worker', 'intent': 'B-operation',
                                'argv': ['/bin/echo', 'B-operation'], 'risks': ['prod'], 'fake': True})
        row = control.action(ident)
        with patch.dict(os.environ, HERMES_HOME=str(self.home / '.hermes/profiles/coordinator')):
            for fingerprint, gate in [('a' * 64, 'owner'), (row['fingerprint'], 'coordinator')]:
                with self.assertRaisesRegex(ValueError, 'mismatched'):
                    control.decide(ident, 'coordinator', True, fingerprint, gate)
            self.assertEqual(control.action(ident)['status'], 'awaiting-owner')
            control.decide(ident, 'coordinator', False, row['fingerprint'], 'owner')
        self.assertEqual(control.action(ident)['status'], 'denied')

    def test_B3_structured_control_returns_immutable_operation_B(self):
        ident = control.submit({'kind': 'prod', 'bot': 'worker', 'intent': 'B-operation',
                                'argv': ['/bin/echo', 'B-operation'], 'fake': True})
        result = subprocess.run([sys.executable, '-B', str(boundary.RUNTIME.with_name('swarmctl')),
                                 'control', 'get', ident], env=self.env, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        self.assertEqual(record['spec']['argv'], ['/bin/echo', 'B-operation'])
        self.assertEqual(record['fingerprint'], control.action(ident)['fingerprint'])

    def test_M3_swift_shared_intake_path_passes_real_provision_validator(self):
        # The native Swift test runs the actual writer + this same validator on macOS.
        folder = self.home / '.hermes/swarmhub/secrets'
        folder.mkdir(parents=True, mode=0o700)
        path = folder / 'qa-token'
        path.write_text('synthetic-key'); path.chmod(0o600)
        control.publish({'provisioner': ['/bin/echo', 'FAKE']})
        self.assertTrue(control.intake.is_intake_path(str(path)))
        argv = control.provisioner_argv({'api_key': str(path)})
        self.assertNotIn('synthetic-key', repr(argv))
        self.assertEqual(json.loads(argv[-1])['api_key'], str(path))


class HarnessIsolationTests(unittest.TestCase):
    def test_B2_unsafe_source_config_and_environment_capabilities_are_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source'; source.mkdir()
            unsafe = ('sandbox_mode="danger-full-access"\n[features]\napps=true\n'
                      '[sandbox_workspace_write]\nnetwork_access=true\nwritable_roots=["/production"]\n'
                      '[mcp_servers.production]\ncommand="/production/sender"\nenv={TOKEN="synthetic-production-token"}\n')
            (source / 'config.toml').write_text(unsafe)
            (source / 'auth.json').write_text('{"token":"synthetic-auth"}')
            private = writable_cli_state({'codex_home': str(source), 'bin': '/qa/bin'}, root / 'private')
            config = (Path(private['codex_home']) / 'config.toml').read_text()
            # Pin the entire known-valid TOML document on every Python version.
            # In particular, 3.9 must reject extra tables/keys, not approximate TOML
            # parsing with regexes or skip the capability-removal assertions.
            self.assertEqual(config, 'sandbox_mode = "workspace-write"\napproval_policy = "never"\n'
                             '[sandbox_workspace_write]\nnetwork_access = false\nwritable_roots = []\n'
                             '[features]\napps = false\nweb_search_request = false\n'
                             '[mcp_servers]\n')
            if tomllib is not None:
                effective = tomllib.loads(config)
                self.assertEqual(effective['mcp_servers'], {})
                self.assertFalse(effective['features']['apps'])
                self.assertFalse(effective['sandbox_workspace_write']['network_access'])
                self.assertEqual(effective['sandbox_workspace_write']['writable_roots'], [])
                self.assertNotIn('production', repr(effective))
            env = cli_env({'HOME': '/qa', 'PATH': '/production/bin', 'OPENAI_API_KEY': 'synthetic',
                           'HTTP_PROXY': 'http://production', 'BASH_ENV': '/production/hooks',
                           'CODEX_HOME': str(source), 'MCP_TOKEN': 'synthetic'}, private)
            for key in ('OPENAI_API_KEY', 'HTTP_PROXY', 'BASH_ENV', 'MCP_TOKEN'):
                self.assertNotIn(key, env)
            self.assertNotIn('/production', env['PATH'])
            self.assertEqual((source / 'config.toml').read_text(), unsafe)

    def suite_fixture(self, root):
        suite = ManagedSuite.__new__(ManagedSuite)
        suite._resources = ExitStack()
        suite.temp = Path(suite._resources.enter_context(tempfile.TemporaryDirectory(dir=root)))
        (suite.temp / 'auth.json').write_text('synthetic-auth')
        suite.home = suite.temp / 'home'
        suite.close_server = Mock(); suite.stop_local_processes = Mock(); suite.export_final = Mock()
        suite.capture_usage = Mock(); suite.cleanup = Mock(); suite.result = Mock(); suite.save = Mock()
        return suite

    def test_M5_export_failure_cannot_skip_process_session_or_credential_cleanup(self):
        with tempfile.TemporaryDirectory() as root:
            suite = self.suite_fixture(root)
            order = []
            suite.stop_local_processes.side_effect = lambda: order.append('stop')
            def export():
                order.append('export')
                raise OSError('synthetic export failure')
            suite.export_final.side_effect = export
            with patch('live_managed.children_by_home', return_value=[]):
                with self.assertRaisesRegex(OSError, 'export'):
                    suite.finish()
            self.assertEqual(order, ['stop', 'export'])
            suite.cleanup.assert_called_once()
            suite.close_server.assert_called_once()
            self.assertFalse(suite.temp.exists())

    def test_M5_server_and_session_cleanup_failures_still_delete_credentials(self):
        for stage in ('close_server', 'cleanup'):
            with self.subTest(stage=stage), tempfile.TemporaryDirectory() as root:
                suite = self.suite_fixture(root)
                getattr(suite, stage).side_effect = OSError('synthetic ' + stage)
                with patch('live_managed.children_by_home', return_value=[]):
                    with self.assertRaises(OSError):
                        suite.finish()
                suite.stop_local_processes.assert_called_once()
                suite.cleanup.assert_called_once()
                self.assertFalse(suite.temp.exists())

    def test_M5_initialization_failure_after_credential_copy_cleans_tree(self):
        seen = []
        def initialize(suite):
            seen.append(suite.temp)
            (suite.temp / 'auth.json').write_text('synthetic-auth')
            raise OSError('synthetic initialization failure')
        with patch('live_managed.BehaviorSuite.__init__'), patch.object(ManagedSuite, 'initialize_local', initialize):
            with self.assertRaises(OSError):
                ManagedSuite(Path('/unused'))
        self.assertTrue(seen)
        self.assertFalse(seen[0].exists())

    def test_M5_server_close_runs_when_shutdown_fails(self):
        suite = ManagedSuite.__new__(ManagedSuite)
        suite.server = Mock(); server = suite.server
        server.shutdown.side_effect = OSError('synthetic shutdown')
        with self.assertRaises(OSError):
            suite.close_server()
        server.server_close.assert_called_once()
        self.assertIsNone(suite.server)

    def test_M5_partial_cli_record_does_not_abort_export(self):
        with tempfile.TemporaryDirectory() as root:
            suite = ManagedSuite.__new__(ManagedSuite)
            suite.state = Path(root) / 'state'; suite.output = Path(root); suite.repo = None
            suite.cli = {'codex_home': str(Path(root) / 'cli')}; suite.clean = lambda value: value
            sessions = Path(suite.cli['codex_home']) / 'sessions'; sessions.mkdir(parents=True)
            (sessions / 'session.jsonl').write_text('{"type":"session_meta","payload":{"id":"QA"}}\n{"type":')
            suite.export_local('QA-final')
            audit = json.loads((suite.output / 'QA-cli-audit-session.json').read_text())
            self.assertEqual(audit[-1]['type'], 'incomplete-record')


if __name__ == '__main__':
    unittest.main()
