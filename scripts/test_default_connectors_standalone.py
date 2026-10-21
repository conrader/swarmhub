"""connectors_core.py runs alone: the piped connector check and each bot's proxy copy have no sibling modules."""
import ast
import json
import os
from pathlib import Path
import select
import shutil
import subprocess
import sys
import tempfile
import unittest

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from default_connectors_fixtures import core, helper  # noqa: E402

CORE = Path(core.__file__)
ENTRY = Path(helper.__file__)


class StandaloneCoreTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sbcore-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name) / "home"
        self.alone = Path(temporary.name) / "alone"  # A working directory without any helper module.
        self.alone.mkdir()
        self.env = {key: value for key, value in os.environ.items() if key != "PYTHONPATH"}

    def run_python(self, *args, **kwargs):
        return subprocess.run([sys.executable, *args], cwd=self.alone, env=self.env, capture_output=True, text=True,
                              timeout=60, **kwargs)

    def test_core_imports_only_the_standard_library_at_load_time(self):
        tree = ast.parse(CORE.read_text())
        top = [node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom))]
        names = {alias.name for node in top if isinstance(node, ast.Import) for alias in node.names}
        names |= {node.module for node in top if isinstance(node, ast.ImportFrom)}
        self.assertFalse({name for name in names if name.startswith("connectors_")})
        self.assertTrue(names <= set(sys.stdlib_module_names), names - set(sys.stdlib_module_names))

    def test_piped_check_reports_exactly_what_the_installed_helper_reports(self):
        root = helper.location(self.home, "hermes", "reports")
        root.mkdir(parents=True)
        (root / "config.yaml").write_text(yaml.safe_dump({"mcp_servers": {
            "sb": {"command": "ssh"}, "paused": {"command": "paused-mcp", "enabled": False}}}))
        # BotConnectorCheck's command, plus a fixture home.
        piped = self.run_python("-", "--home", str(self.home), "inspect", "hermes", "reports", input=CORE.read_text())
        installed = self.run_python(str(ENTRY), "--home", str(self.home), "inspect", "hermes", "reports")
        self.assertEqual((piped.returncode, piped.stderr), (0, ""))
        self.assertEqual(json.loads(piped.stdout), json.loads(installed.stdout))
        self.assertEqual({row["name"]: row["state"] for row in json.loads(piped.stdout)["list"]},
                         {"sb": "failed", "paused": "disabled"})

    def test_core_alone_cannot_write_and_fails_closed(self):
        result = self.run_python("-", "--home", str(self.home), "create", "hermes", "reports", input=CORE.read_text())
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["list"][0]["state"], "failed")
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.home.exists())

    def test_a_bots_proxy_copy_enforces_the_allowlist_on_its_own(self):
        upstream = self.alone / "upstream.py"
        upstream.write_text("import json, sys\nfor line in sys.stdin:\n    message = json.loads(line)\n"
                            "    print(json.dumps({'jsonrpc': '2.0', 'id': message['id'], 'result': "
                            "{'tools': [{'name': 'read'}, {'name': 'write'}]}}), flush=True)\n")
        source = self.alone / "mcporter.json"
        source.write_text(json.dumps({"mcpServers": {"docs": {"command": sys.executable, "args": [str(upstream)]}}}))
        proxy = self.alone / "swarmhub-connectors.py"
        shutil.copy(CORE, proxy)
        process = subprocess.Popen([sys.executable, str(proxy), "proxy", str(source), "docs", json.dumps(["read"])],
                                   cwd=self.alone, env=self.env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        replies = []
        try:
            for request in ({"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "write"}}):
                process.stdin.write(json.dumps(request) + "\n")
                process.stdin.flush()
                ready, _, _ = select.select([process.stdout], [], [], 30)
                self.assertTrue(ready, "the proxy did not answer")
                replies.append(json.loads(process.stdout.readline()))
        finally:
            process.stdin.close()  # EOF ends the proxy and its upstream; no signals.
            process.wait(timeout=30)
            process.stdout.close()
        self.assertEqual(replies[0]["result"]["tools"], [{"name": "read"}])
        self.assertEqual(replies[1]["error"]["code"], -32601)
        self.assertEqual(process.returncode, 0)


if __name__ == "__main__":
    unittest.main()
