"""Python 3.9 config isolation coverage; synthetic files only, no CLI or network."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import builtins
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import patch

import test_fixes5


class PythonCompatibilityTests(unittest.TestCase):
    def legacy_module(self):
        original = builtins.__import__

        def no_toml(name, *args, **kwargs):
            if name in ('tomllib', 'tomli'):
                raise AssertionError('Python 3.9 must not require a TOML package')
            return original(name, *args, **kwargs)

        with patch.object(sys, 'version_info', (3, 9, 6)), patch('builtins.__import__', side_effect=no_toml):
            return runpy.run_path(test_fixes5.__file__)

    def isolation_case(self, module):
        return module['HarnessIsolationTests']('test_B2_unsafe_source_config_and_environment_capabilities_are_removed')

    def test_python39_import_and_config_isolation_without_toml_packages(self):
        module = self.legacy_module()
        self.assertIsNone(module['tomllib'])
        self.isolation_case(module).debug()

    def test_unsafe_config_mutations_are_rejected_with_and_without_tomllib(self):
        mutations = (
            lambda text: text.replace('network_access = false', 'network_access = true'),
            lambda text: text.replace('apps = false', 'apps = true'),
            lambda text: text.replace('writable_roots = []', 'writable_roots = ["/production"]'),
            lambda text: text + '[mcp_servers.production]\ncommand = "/production/sender"\n',
            lambda text: text.replace('"workspace-write"', '"danger-full-access"'),
            lambda text: text + '[unexpected]\ncapability = true\n',
        )
        for module in (self.legacy_module(), vars(test_fixes5)):
            original = module['writable_cli_state']
            for index, mutate in enumerate(mutations):
                def unsafe(*args):
                    private = original(*args)
                    config = Path(private['codex_home']) / 'config.toml'
                    config.write_text(mutate(config.read_text()))
                    return private

                with self.subTest(parser=module['tomllib'] is not None, mutation=index):
                    # runpy returns a copy; patch the dictionary the test reads.
                    method = self.isolation_case(module)._testMethodName
                    globals_ = getattr(module['HarnessIsolationTests'], method).__globals__
                    with patch.dict(globals_, writable_cli_state=unsafe), self.assertRaises(AssertionError):
                        self.isolation_case(module).debug()

    def test_python311_keeps_real_toml_parsing(self):
        # 3.9 still runs this case with a parser spy; on 3.11+ wrap the real parser.
        from types import SimpleNamespace
        parser = test_fixes5.tomllib or SimpleNamespace(loads=lambda text: {
            'mcp_servers': {}, 'features': {'apps': False},
            'sandbox_workspace_write': {'network_access': False, 'writable_roots': []},
        })
        with patch.object(test_fixes5, 'tomllib', parser), patch.object(parser, 'loads', wraps=parser.loads) as loads:
            self.isolation_case(vars(test_fixes5)).debug()
            loads.assert_called_once()


if __name__ == '__main__':
    unittest.main()
