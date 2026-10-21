"""Execute the shipped new-bot helper against synthetic homes, configs, logs and SQLite catalogs."""
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("default_connectors", ROOT / "Resources/ConnectorDefaults/default-connectors.py")
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)


class DefaultConnectorsTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sbdefault-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)
        (self.home / ".ssh").mkdir()
        (self.home / ".ssh/sb_mcp_ed25519").write_text("synthetic credential: never print")
        (self.home / ".ssh/known_hosts").write_text("synthetic known host")

    def profile(self, name="brand-new"):
        root = self.home / ".hermes/profiles" / name
        root.mkdir(parents=True)
        (root / "config.yaml").write_text(yaml.safe_dump({
            "model": {"default": "test-model"}, "mcp_servers": {
                "existing": {"command": "existing"},
                "sb": {"enabled": False, "command": "wrong", "tools": {"include": ["write"]}}}}))
        return root

    def database(self, root, names, at=1_792_000_000):
        with sqlite3.connect(root / "state.db") as db:
            db.executescript("CREATE TABLE sessions (tool_names TEXT, started_at REAL);"
                             "CREATE TABLE system_prompts (hash TEXT, prompt TEXT);")
            tools = [{"function": {"name": "terminal"}}, {"function": {
                "name": "tool_search", "description": "sb tools (5):\n" + "\n".join("- " + n + ": Read" for n in names)}}]
            db.execute("INSERT INTO system_prompts VALUES (?, ?)", ("catalog-hash", json.dumps({"tools": tools})))
            db.execute("INSERT INTO sessions VALUES (?, ?)", ("catalog-hash", at))

    def test_every_new_profile_gets_narrow_sb_and_preserves_other_settings(self):
        for name in ("brand-new", "other-bot", "new-team-bot"):
            with self.subTest(name=name):
                root = self.profile(name)
                report = helper.provision(self.home, "hermes", name)
                first = (root / "config.yaml").read_bytes()
                helper.provision(self.home, "hermes", name)
                self.assertEqual((root / "config.yaml").read_bytes(), first)
                config = yaml.safe_load(first)
                self.assertEqual(config["model"], {"default": "test-model"})
                self.assertEqual(config["mcp_servers"]["existing"], {"command": "existing"})
                sb = config["mcp_servers"]["sb"]
                self.assertEqual(sb["tools"]["include"], helper.SB_TOOLS)
                self.assertNotIn("enabled", sb)
                self.assertEqual(sb["connect_timeout"], 60)
                self.assertIn("StrictHostKeyChecking=yes", sb["args"])
                self.assertIn("BatchMode=yes", sb["args"])
                self.assertIn(str(self.home / ".ssh/sb_mcp_ed25519"), sb["args"])
                self.assertEqual(sb["args"][-1], "ubuntu@145.239.94.119")
                self.assertNotIn("synthetic credential", first.decode())
                self.assertEqual(report["list"][0]["state"], "never_attempted")
                self.assertEqual((root / "config.yaml").stat().st_mode & 0o777, 0o600)

    def test_general_defaults_reference_an_existing_config_with_a_read_tool_allowlist(self):
        root = self.profile()
        source = self.home / "shared.json"
        source.write_text(json.dumps({"mcpServers": {"knowledge": {"command": "docs-mcp", "args": ["--read-only"]}}}))
        policy = self.home / ".config/swarmhub/default-connectors.json"
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps({"connectors": [{"name": "docs", "source": str(source), "server": "knowledge", "tools": ["read_page"]}]}))
        helper.provision(self.home, "hermes", "brand-new")
        entry = yaml.safe_load((root / "config.yaml").read_text())["mcp_servers"]["docs"]
        self.assertEqual(entry, {"command": "docs-mcp", "args": ["--read-only"], "tools": {"include": ["read_page"]}})
        self.assertEqual(json.loads(source.read_text())["mcpServers"]["knowledge"], {"command": "docs-mcp", "args": ["--read-only"]})
        before = (root / "config.yaml").read_bytes()
        policy.write_text(json.dumps({"connectors": [{"name": "docs", "source": str(source), "server": "knowledge", "tools": ["*"]}]}))
        with self.assertRaises(ValueError):
            helper.provision(self.home, "hermes", "brand-new")
        self.assertEqual(before, (root / "config.yaml").read_bytes())

    def test_openclaw_writes_only_the_new_workspace_config_and_references_the_same_key(self):
        root = helper.location(self.home, "openclaw", "new-agent")
        root.mkdir(parents=True)
        agents = root / "AGENTS.md"
        agents.write_text("My instructions")
        gateway = self.home / ".openclaw/openclaw.json"
        gateway.write_text('{"do_not_change":true}')
        with patch.object(helper.shutil, "which", return_value="/bin/mcporter"):
            result = helper.provision(self.home, "openclaw", "new-agent")
        config = json.loads((root / "config/mcporter.json").read_text())
        self.assertEqual(config["imports"], [])
        self.assertEqual(set(config["mcpServers"]), {"sb"})
        self.assertEqual(config["mcpServers"]["sb"]["command"], "ssh")
        self.assertIn(str(self.home / ".ssh/sb_mcp_ed25519"), config["mcpServers"]["sb"]["args"])
        self.assertEqual(agents.read_text(), "My instructions")
        self.assertEqual(gateway.read_text(), '{"do_not_change":true}')
        self.assertEqual(result["list"][0]["state"], "never_attempted")

    def test_missing_credentials_are_an_explicit_setup_failure(self):
        self.profile()
        (self.home / ".ssh/sb_mcp_ed25519").unlink()
        report = helper.provision(self.home, "hermes", "brand-new")
        self.assertEqual(report["list"][0]["state"], "failed")
        self.assertIn("identity is missing", report["list"][0]["detail"])

    def test_deferred_catalog_proves_five_tools_despite_adoption_summary(self):
        root = self.profile()
        helper.provision(self.home, "hermes", "brand-new")
        self.database(root, ["mcp__sb__" + n for n in helper.SB_TOOLS])
        (root / "logs").mkdir()
        (root / "logs/agent.log").write_text("2026-10-21 12:19:34,874 INFO tools.mcp_tool: MCP: registered 4 already-connected server(s) into this profile scope\n"
                                               "2026-10-21 12:19:34,874 INFO tools.mcp_tool: MCP: 0 tool(s) from 0 server(s) (4 failed: sb (not attempted (in retry cooldown)))\n")
        before = (root / "state.db").read_bytes()
        rows = helper.inspect(self.home, "hermes", "brand-new")["list"]
        sb = next(row for row in rows if row["name"] == "sb")
        self.assertEqual((sb["state"], sb["tool_count"]), ("loaded", 5))
        self.assertIn("deferred", sb["detail"])
        self.assertEqual(before, (root / "state.db").read_bytes())

    def test_newer_real_failure_overrides_old_catalog_and_redacts_log_secrets(self):
        root = self.profile()
        helper.provision(self.home, "hermes", "brand-new")
        self.database(root, ["mcp__sb__wiki_page"], at=1)
        (root / "logs").mkdir()
        (root / "logs/agent.log").write_text("2026-10-21 12:19:34,874 WARNING MCP server 'sb' failed initial connection: Permission denied token=DO_NOT_EXPOSE\n")
        report = helper.inspect(self.home, "hermes", "brand-new")
        sb = next(row for row in report["list"] if row["name"] == "sb")
        self.assertEqual(sb["state"], "failed")
        self.assertEqual(sb["detail"], "SSH authentication was rejected.")
        self.assertNotIn("DO_NOT_EXPOSE", json.dumps(report))
        self.assertNotIn("tool_count", sb)

    def test_never_attempted_unknown_disabled_and_missing_are_distinct(self):
        root = self.profile()
        helper.provision(self.home, "hermes", "brand-new")
        self.assertEqual(next(r for r in helper.inspect(self.home, "hermes", "brand-new")["list"] if r["name"] == "sb")["state"], "never_attempted")
        (root / ".swarmhub-connectors.json").unlink()
        self.assertEqual(next(r for r in helper.inspect(self.home, "hermes", "brand-new")["list"] if r["name"] == "sb")["state"], "unknown")
        (root / "config.yaml").write_text("mcp_servers:\n  sb:\n    enabled: false\n")
        self.assertEqual(helper.inspect(self.home, "hermes", "brand-new")["list"][0]["state"], "disabled")
        (root / "config.yaml").write_text("mcp_servers: {}\n")
        self.assertEqual(helper.inspect(self.home, "hermes", "brand-new")["list"][0]["state"], "failed")

    def test_bad_names_cannot_touch_another_profile(self):
        for name in ("../default", "a; echo secret", "$(id)", ""):
            with self.assertRaises(ValueError):
                helper.provision(self.home, "hermes", name)

    def test_openclaw_additional_defaults_reference_sources_and_enforce_the_read_tool_filter(self):
        root = helper.location(self.home, "openclaw", "new-agent")
        root.mkdir(parents=True)
        upstream = self.home / "upstream.py"
        upstream.write_text('''import json, sys
for line in sys.stdin:
    request = json.loads(line)
    if request.get('method') == 'tools/list':
        result = {'tools': [{'name': 'read_page'}, {'name': 'write_page'}]}
    elif request.get('method') == 'tools/call':
        result = {'content': [{'type': 'text', 'text': request['params']['name']}]}
    else:
        result = {}
    print(json.dumps({'jsonrpc': '2.0', 'id': request['id'], 'result': result}), flush=True)
''')
        source = self.home / "shared.json"
        source.write_text(json.dumps({"mcpServers": {"knowledge": {
            "command": sys.executable, "args": [str(upstream)], "env": {"DOCS_TOKEN": "synthetic-do-not-copy"}}}}))
        policy = self.home / ".config/swarmhub/default-connectors.json"
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps({"connectors": [{"name": "docs", "source": str(source), "server": "knowledge", "tools": ["read_page"]}]}))
        with patch.object(helper.shutil, "which", return_value="mcporter"):
            helper.provision(self.home, "openclaw", "new-agent")
        contents = (root / "config/mcporter.json").read_text()
        self.assertNotIn("synthetic-do-not-copy", contents)
        entry = json.loads(contents)["mcpServers"]["docs"]
        # Run the installed adapter, not a mirror of its filtering logic. These tests run in a PID namespace.
        process = subprocess.Popen([sys.executable] + entry["args"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        def call(method, params=None):
            process.stdin.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())
        try:
            self.assertEqual(call("tools/list")["result"]["tools"], [{"name": "read_page"}])
            self.assertIn("error", call("tools/call", {"name": "write_page"}))
            self.assertEqual(call("tools/call", {"name": "read_page"})["result"]["content"][0]["text"], "read_page")
        finally:
            process.stdin.close()
            process.wait(timeout=10)
            process.stdout.close()

    def test_openclaw_discovery_reports_real_schema_counts_and_fixed_failure_reasons(self):
        root = helper.location(self.home, "openclaw", "new-agent")
        with patch.object(helper.shutil, "which", return_value="mcporter"), patch.object(helper.subprocess, "run") as run:
            run.return_value = subprocess.CompletedProcess([], 0, json.dumps({"status": "ok", "tools": [{"name": t} for t in helper.SB_TOOLS]}))
            self.assertEqual(helper.mcporter_status(root, "sb")["tool_count"], 5)
            argv = run.call_args.args[0]
            self.assertIn("--no-oauth", argv)
            self.assertIn(str(root / "config/mcporter.json"), argv)
            self.assertNotIn("call", argv)
            run.return_value = subprocess.CompletedProcess([], 1, json.dumps({"status": "auth", "error": "401 Bearer secret-do-not-print"}))
            result = helper.mcporter_status(root, "sb")
            self.assertEqual(result["state"], "failed")
            self.assertIn("HTTP 401", result["detail"])
            self.assertNotIn("secret-do-not-print", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
