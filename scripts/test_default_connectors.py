"""Execute the shipped new-bot helper against synthetic homes, configs, logs and SQLite catalogs."""
import hashlib
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
SCHEMAS = ROOT / "Tests/Fixtures/hermes-state"
spec = importlib.util.spec_from_file_location("default_connectors", ROOT / "Resources/Skills/swarmhub-manager/scripts/default-connectors.py")
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
        (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
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
                self.assertEqual(set(config["mcp_servers"]), {"sb"})
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
        self.assertEqual(entry, {"command": "python3", "args": [str(root / "swarmhub-connectors.py"), "proxy", str(source.resolve()),
                                                               "knowledge", '["read_page"]'], "tools": {"include": ["read_page"]}})
        self.assertEqual(json.loads(source.read_text())["mcpServers"]["knowledge"], {"command": "docs-mcp", "args": ["--read-only"]})
        before = (root / "config.yaml").read_bytes()
        policy.write_text(json.dumps({"connectors": [{"name": "docs", "source": str(source), "server": "knowledge", "tools": ["*"]}]}))
        helper.provision(self.home, "hermes", "brand-new")  # Upgrade/retry never narrows an existing bot.
        self.assertEqual(before, (root / "config.yaml").read_bytes())

    def test_openclaw_writes_only_the_new_workspace_config_and_references_the_same_key(self):
        root = helper.location(self.home, "openclaw", "new-agent")
        root.mkdir(parents=True)
        (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
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

    def schema_database(self, root, version):
        # The real Hermes DDL (copied read-only from installed state.db files); rows here are synthetic.
        with sqlite3.connect(root / "state.db") as db:
            db.executescript((SCHEMAS / ("schema-v%d.sql" % version)).read_text())
            db.execute("INSERT INTO schema_version VALUES (?)", (version,))
            db.execute("INSERT INTO sessions (id, source, started_at) VALUES ('no-pin', 'cli', 1)")
        return root / "state.db"

    def sb_row(self):
        return next(r for r in helper.inspect(self.home, "hermes", "brand-new")["list"] if r["name"] == "sb")

    def test_real_hermes_schemas_without_a_tool_catalog_report_a_specific_status(self):
        root = self.profile()
        helper.provision(self.home, "hermes", "brand-new")
        for version in (14, 26):
            with self.subTest(version=version):
                self.schema_database(root, version)
                before = (root / "state.db").read_bytes()
                sb = self.sb_row()
                self.assertEqual((sb["state"], sb["detail"]), ("unknown", helper.CATALOG_UNAVAILABLE))
                self.assertEqual(before, (root / "state.db").read_bytes())
                (root / "state.db").unlink()
        (root / "state.db").write_bytes(b"not a database")
        self.assertEqual(self.sb_row()["detail"], helper.CATALOG_UNREADABLE)

    def test_real_hermes_schema_31_resolves_hashed_legacy_and_swept_tool_pins(self):
        root = self.profile()
        helper.provision(self.home, "hermes", "brand-new")
        db = self.schema_database(root, 31)
        deferred = "\n".join("- mcp__sb__" + n + ": Read" for n in helper.SB_TOOLS)
        pin = json.dumps({"version": "synthetic", "tools": [{"type": "function", "function": {"name": "terminal"}},
                          {"type": "function", "function": {"name": "tool_search", "description": deferred}}]})
        digest = hashlib.sha256(pin.encode()).hexdigest()
        with sqlite3.connect(db) as connection:
            connection.execute("INSERT INTO system_prompts VALUES (?, ?)", (digest, pin))
            connection.execute("INSERT INTO sessions (id, source, started_at, tool_names) VALUES ('hashed', 'cli', 10, ?)", (digest,))
        self.assertEqual((self.sb_row()["state"], self.sb_row()["tool_count"]), ("loaded", 5))
        with sqlite3.connect(db) as connection:
            # Newer: an inline legacy name list (Hermes still resolves these).
            connection.execute("INSERT INTO sessions (id, source, started_at, tool_names) VALUES ('legacy', 'cli', 20, ?)",
                               (json.dumps(["mcp__sb__wiki_page", "mcp__sb__wiki_list"]),))
        self.assertEqual(self.sb_row()["tool_count"], 2)
        with sqlite3.connect(db) as connection:
            # Newest: a pin hash whose system_prompts row was swept is skipped, not a generic failure.
            connection.execute("INSERT INTO sessions (id, source, started_at, tool_names) VALUES ('swept', 'cli', 30, ?)", ("ab" * 32,))
        self.assertEqual(self.sb_row()["tool_count"], 2)
        with sqlite3.connect(db) as connection:
            connection.execute("DELETE FROM sessions WHERE id IN ('hashed', 'legacy')")
        sb = self.sb_row()
        self.assertEqual((sb["state"], sb["detail"]), ("unknown", helper.CATALOG_UNRECOGNISED))

    def test_hermes_additional_defaults_reference_secrets_instead_of_copying_them(self):
        root = self.profile()
        source = self.home / ".hermes/config.yaml"
        source.write_text(yaml.safe_dump({"mcp_servers": {
            "knowledge": {"command": "docs-mcp", "args": ["--read-only"], "env": {"DOCS_TOKEN": "synthetic-env-secret"}},
            "remote": {"url": "https://docs.invalid/mcp", "headers": {"Authorization": "Bearer synthetic-header-secret"}}}}))
        policy = self.home / ".config/swarmhub/default-connectors.json"
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps({"connectors": [
            {"name": "docs", "source": "~/.hermes/config.yaml", "server": "knowledge", "tools": ["read_page"]},
            {"name": "remote", "source": "~/.hermes/config.yaml", "server": "remote", "tools": ["search"]},
            {"name": "gone", "source": "~/.hermes/config.yaml", "server": "missing", "tools": ["search"]}]}))
        report = helper.provision(self.home, "hermes", "brand-new")
        written = (root / "config.yaml").read_text() + json.dumps(report) + (root / ".swarmhub-connectors.json").read_text()
        for secret in ("synthetic-env-secret", "synthetic-header-secret", "DOCS_TOKEN", "docs.invalid"):
            self.assertNotIn(secret, written)
        servers = yaml.safe_load((root / "config.yaml").read_text())["mcp_servers"]
        self.assertEqual(servers["docs"]["args"][1:4], ["proxy", str(source.resolve()), "knowledge"])
        self.assertNotIn("env", servers["docs"])
        self.assertNotIn("remote", servers)
        self.assertEqual((root / "swarmhub-connectors.py").read_text(), Path(helper.__file__).read_text())
        states = {row["name"]: (row["state"], row["detail"]) for row in report["list"]}
        self.assertEqual(states["sb"][0], "never_attempted")
        self.assertEqual(states["docs"][0], "never_attempted")
        self.assertEqual(states["remote"][0], "failed")
        self.assertIn("only stdio", states["remote"][1])
        self.assertEqual(states["gone"], ("failed", "Default connector source or server cannot be read on this computer."))

    def test_skipped_defaults_inherited_from_the_manager_clone_do_not_stay_active(self):
        inherited = {
            "remote": {"url": "https://docs.invalid/mcp", "headers": {"Authorization": "Bearer synthetic-header-secret"}},
            "gone": {"command": "docs-mcp", "env": {"DOCS_TOKEN": "synthetic-env-secret"}}}
        source = self.home / ".hermes/config.yaml"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_text(yaml.safe_dump({"mcp_servers": {"remote": inherited["remote"]}}))
        policy = self.home / ".config/swarmhub/default-connectors.json"
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps({"connectors": [
            {"name": "remote", "source": "~/.hermes/config.yaml", "server": "remote", "tools": ["search"]},
            {"name": "gone", "source": "~/.hermes/config.yaml", "server": "missing", "tools": ["search"]}]}))
        hermes = self.profile()
        config = yaml.safe_load((hermes / "config.yaml").read_text())
        config["mcp_servers"].update(inherited)
        (hermes / "config.yaml").write_text(yaml.safe_dump(config))
        openclaw = helper.location(self.home, "openclaw", "brand-new")
        (openclaw / "config").mkdir(parents=True)
        (openclaw / "config/mcporter.json").write_text(json.dumps({"mcpServers": dict(inherited), "imports": []}))
        (openclaw / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
        for backend, path, key in (("hermes", hermes / "config.yaml", "mcp_servers"),
                                   ("openclaw", openclaw / "config/mcporter.json", "mcpServers")):
            with self.subTest(backend=backend), patch.object(helper.shutil, "which", return_value="/usr/bin/mcporter"), \
                    patch.object(helper, "mcporter_status", return_value={}):
                report = helper.provision(self.home, backend, "brand-new")
                text = path.read_text()
                for secret in ("synthetic-header-secret", "synthetic-env-secret", "DOCS_TOKEN", "docs.invalid"):
                    self.assertNotIn(secret, text)
                servers = helper.read_config(path)[key]
                self.assertNotIn("remote", servers)
                self.assertNotIn("gone", servers)
                self.assertIn("sb", servers)
                # The setup report and a later read of the config agree: failed, not configured.
                states = {row["name"]: row for row in report["list"]}
                inspected = {row["name"]: row for row in helper.inspect(self.home, backend, "brand-new")["list"]}
                for name in ("remote", "gone"):
                    self.assertEqual(states[name]["state"], "failed")
                    self.assertIn("inherited from the manager was removed", states[name]["detail"])
                    self.assertEqual(inspected[name]["state"], "failed")

    def test_refused_defaults_remove_aliased_entries_from_the_manager_clone(self):
        for backend in ("hermes", "openclaw"):
            for refusal in ("http", "missing-source", "missing-server"):
                with self.subTest(backend=backend, refusal=refusal), \
                        patch.object(helper.shutil, "which", return_value="/usr/bin/mcporter"), \
                        patch.object(helper, "mcporter_status", return_value={}):
                    bot = backend + "-" + refusal
                    root = helper.location(self.home, backend, bot)
                    path = root / ("config.yaml" if backend == "hermes" else "config/mcporter.json")
                    key = "mcp_servers" if backend == "hermes" else "mcpServers"
                    inherited = {"knowledge": {
                        "url": "https://docs.invalid/mcp", "headers": {"Authorization": "synthetic-alias-secret"}}
                        if refusal == "http" else {
                            "command": "docs-mcp", "env": {"DOCS_TOKEN": "synthetic-alias-secret"}},
                        "unrelated": {"command": "keep-this-connector"}}
                    source = self.home / (bot + "-source.json")
                    if refusal != "missing-source":
                        source.write_text(json.dumps({"mcpServers": inherited if refusal == "http" else {}}))
                    policy = self.home / ".config/swarmhub/default-connectors.json"
                    policy.parent.mkdir(parents=True, exist_ok=True)
                    policy.write_text(json.dumps({"connectors": [{
                        "name": "docs", "source": str(source), "server": "knowledge", "tools": ["search"]}]}))
                    path.parent.mkdir(parents=True, exist_ok=True)
                    (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
                    config = {key: inherited, "unrelated_setting": "preserve"}
                    path.write_text(yaml.safe_dump(config) if backend == "hermes" else json.dumps(config))
                    source_before = source.read_bytes() if source.exists() else None
                    report = helper.provision(self.home, backend, bot)
                    written = helper.read_config(path)
                    self.assertNotIn("synthetic-alias-secret", path.read_text())
                    self.assertNotIn("DOCS_TOKEN", path.read_text())
                    self.assertEqual(set(written[key]), {"sb"})
                    self.assertEqual(written["unrelated_setting"], "preserve")
                    row = next(r for r in report["list"] if r["name"] == "docs")
                    self.assertEqual(row["state"], "failed")
                    self.assertIn("inherited from the manager was removed", row["detail"])
                    inspected = {r["name"]: r for r in helper.inspect(self.home, backend, bot)["list"]}
                    self.assertEqual(inspected["docs"]["state"], "failed")
                    self.assertNotIn("knowledge", inspected)
                    self.assertEqual(source.read_bytes() if source.exists() else None, source_before)

    def test_refused_alias_preserves_successful_defaults_sharing_its_source_name(self):
        source = self.home / "source.json"
        source.write_text(json.dumps({"mcpServers": {
            "knowledge": {"url": "https://docs.invalid/mcp", "headers": {"Authorization": "synthetic-alias-secret"}},
            "readable": {"command": "docs-mcp"}}}))
        policy = self.home / ".config/swarmhub/default-connectors.json"
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps({"connectors": [
            {"name": "docs", "source": str(source), "server": "knowledge", "tools": ["search"]},
            {"name": "knowledge", "source": str(source), "server": "readable", "tools": ["search"]}]}))
        for backend in ("hermes", "openclaw"):
            with self.subTest(backend=backend), patch.object(helper.shutil, "which", return_value="/usr/bin/mcporter"):
                root = helper.location(self.home, backend, "new-bot")
                path = root / ("config.yaml" if backend == "hermes" else "config/mcporter.json")
                key = "mcp_servers" if backend == "hermes" else "mcpServers"
                path.parent.mkdir(parents=True)
                (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
                config = {key: {"knowledge": json.loads(source.read_text())["mcpServers"]["knowledge"]}}
                path.write_text(yaml.safe_dump(config) if backend == "hermes" else json.dumps(config))
                report = helper.provision(self.home, backend, "new-bot")
                servers = helper.read_config(path)[key]
                self.assertEqual(set(servers), {"sb", "knowledge"})
                self.assertEqual(servers["knowledge"]["command"], "python3")
                self.assertEqual(servers["knowledge"]["args"][1:4], ["proxy", str(source.resolve()), "readable"])
                self.assertNotIn("synthetic-alias-secret", path.read_text())
                self.assertEqual({r["name"]: r["state"] for r in report["list"]}, {
                    "sb": "never_attempted", "docs": "failed", "knowledge": "never_attempted"})

    def test_invalid_source_server_does_not_abort_narrowing_other_defaults(self):
        source = self.home / "source.json"
        source.write_text('{"mcpServers": {}}')
        policy = self.home / ".config/swarmhub/default-connectors.json"
        policy.parent.mkdir(parents=True)
        for backend in ("hermes", "openclaw"):
            for index, server in enumerate((["knowledge"], {"name": "knowledge"})):
                with self.subTest(backend=backend, server=server), \
                        patch.object(helper.shutil, "which", return_value="/usr/bin/mcporter"):
                    bot = backend + "-invalid-" + str(index)
                    root = helper.location(self.home, backend, bot)
                    path = root / ("config.yaml" if backend == "hermes" else "config/mcporter.json")
                    key = "mcp_servers" if backend == "hermes" else "mcpServers"
                    path.parent.mkdir(parents=True)
                    (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
                    config = {key: {name: {"command": "broad-mcp", "env": {"TOKEN": "synthetic-invalid-secret"}}
                                    for name in ("sb", "docs")}}
                    path.write_text(yaml.safe_dump(config) if backend == "hermes" else json.dumps(config))
                    policy.write_text(json.dumps({"connectors": [{
                        "name": "docs", "source": str(source), "server": server, "tools": ["search"]}]}))
                    report = helper.provision(self.home, backend, bot)
                    self.assertNotIn("synthetic-invalid-secret", path.read_text())
                    servers = helper.read_config(path)[key]
                    self.assertEqual(set(servers), {"sb"})
                    self.assertEqual(servers["sb"]["command"], "ssh")
                    self.assertEqual({r["name"]: r["state"] for r in report["list"]}, {
                        "sb": "never_attempted", "docs": "failed"})

    def test_bad_names_cannot_touch_another_profile(self):
        for name in ("../default", "a; echo secret", "$(id)", "", "default"):
            with self.assertRaises(ValueError):
                helper.provision(self.home, "hermes", name)

    def test_openclaw_additional_defaults_reference_sources_and_enforce_the_read_tool_filter(self):
        root = helper.location(self.home, "openclaw", "new-agent")
        root.mkdir(parents=True)
        (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
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


class DefaultsOnlyTests(unittest.TestCase):
    """Exercise the real configuration commands using offline homes; never contact Hermes."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="sbdefonly-")
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name)

    def config(self, backend, bot, servers):
        path = helper.config_path(self.home, backend, bot)
        path.parent.mkdir(parents=True, exist_ok=True)
        config = {"model": {"default": "synthetic"},
                  "mcp_servers" if backend == "hermes" else "mcpServers": servers}
        path.write_text(yaml.safe_dump(config) if backend == "hermes" else json.dumps(config))
        return path

    def snapshot(self):
        return {str(p.relative_to(self.home)): p.read_bytes() for p in self.home.rglob("*") if p.is_file()}

    def manager(self, backend):
        path = self.config(backend, "manager", {
            "finance": {"url": "https://finance.invalid/mcp", "headers": {"Authorization": "Bearer ${FINANCE_TOKEN}"}},
            "private": {"command": "private-mcp", "args": ["inline-private-secret"],
                        "env": {"SECRET": "unselected-private-secret"}}})
        (helper.location(self.home, backend, "manager") / ".env").write_text(
            "FINANCE_TOKEN='selected-finance-secret'\nPRIVATE_TOKEN=unselected-dotenv-secret\n")
        return path

    def test_fresh_backend_creation_never_clones_manager_credentials(self):
        for backend in ("hermes", "openclaw"):
            with self.subTest(backend=backend):
                source = self.manager(backend)
                before = source.read_bytes()

                def create_stub(command, **kwargs):
                    self.assertNotIn("--clone-from", command)
                    self.assertNotIn("--clone", command)
                    self.assertNotIn("manager", command)
                    self.config(backend, "new-bot", {})
                    return subprocess.CompletedProcess(command, 0)

                with patch.object(helper.subprocess, "run", side_effect=create_stub) as run:
                    result = helper.create(self.home, backend, "new-bot", "My bot")
                command = run.call_args.args[0]
                self.assertEqual(command[:3], ["hermes", "profile", "create"] if backend == "hermes" else ["openclaw", "agents", "add"])
                target = helper.config_path(self.home, backend, "new-bot")
                config = helper.read_config(target)
                self.assertEqual(set(config["mcp_servers" if backend == "hermes" else "mcpServers"]), {"sb"})
                for file in helper.location(self.home, backend, "new-bot").rglob("*"):
                    if file.is_file():
                        self.assertNotIn(b"private-secret", file.read_bytes())
                        self.assertNotIn(b"finance-secret", file.read_bytes())
                        self.assertNotIn(b"dotenv-secret", file.read_bytes())
                self.assertFalse((target.parent / ".env").exists())
                self.assertEqual(source.read_bytes(), before)
                self.assertEqual(result["name"], "new-bot")

    def test_creation_refuses_existing_bots_before_calling_a_backend(self):
        for backend in ("hermes", "openclaw"):
            self.manager(backend)
            before = self.snapshot()
            with patch.object(helper.subprocess, "run") as run, self.assertRaises(ValueError):
                helper.create(self.home, backend, "manager")
            run.assert_not_called()
            self.assertEqual(self.snapshot(), before)

    def test_opt_in_copies_one_connector_and_its_credentials_to_one_bot(self):
        for backend in ("hermes", "openclaw"):
            with self.subTest(backend=backend):
                self.manager(backend)
                target = self.config(backend, "one", helper.defaults(self.home))
                self.config(backend, "two", helper.defaults(self.home))
                before = self.snapshot()
                report = helper.opt_in(self.home, backend, "one", "manager", "finance")
                after = self.snapshot()
                changes = {p for p in after if before.get(p) != after[p]}
                self.assertEqual(changes, {str(target.relative_to(self.home)), str((helper.location(self.home, backend, "one") / ".swarmhub-connector-sources.json").relative_to(self.home))})
                servers = helper.read_config(target)["mcp_servers" if backend == "hermes" else "mcpServers"]
                self.assertEqual(set(servers), {"sb", "finance"})
                self.assertEqual(servers["finance"]["headers"]["Authorization"], "Bearer selected-finance-secret")
                self.assertNotIn("unselected", target.read_text())
                self.assertEqual(target.stat().st_mode & 0o777, 0o600)
                self.assertEqual(report["list"][0]["name"], "finance")
                self.assertNotIn("secret", json.dumps(report))

    def test_existing_bots_and_legacy_provisioned_bots_are_unchanged_after_upgrade(self):
        for backend in ("hermes", "openclaw"):
            self.manager(backend)
            root = helper.location(self.home, backend, "manager")
            before = self.snapshot()
            with self.assertRaises(ValueError):
                helper.provision(self.home, backend, "manager")
            self.assertEqual(self.snapshot(), before)
            marker = root / ".swarmhub-connectors.json"
            marker.write_text(json.dumps({"op": "connectors", "name": "manager", "list": []}))
            before = self.snapshot()
            helper.provision(self.home, backend, "manager")
            self.assertEqual(self.snapshot(), before)

    def test_provision_retry_preserves_later_opt_in(self):
        for backend in ("hermes", "openclaw"):
            self.manager(backend)
            self.config(backend, "new", {})
            root = helper.location(self.home, backend, "new")
            (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
            helper.provision(self.home, backend, "new")
            helper.opt_in(self.home, backend, "new", "manager", "finance")
            before = self.snapshot()
            helper.provision(self.home, backend, "new")
            self.assertEqual(self.snapshot(), before)

    def test_opt_in_refuses_default_aliases_overwrites_and_invalid_targets(self):
        source = self.manager("hermes")
        target = self.config("hermes", "one", {"finance": {"command": "keep-me"}})
        policy = self.home / ".config/swarmhub/default-connectors.json"
        policy.parent.mkdir(parents=True)
        policy.write_text(json.dumps({"connectors": [{"name": "docs", "source": str(source), "server": "private", "tools": ["read"]}]}))
        for bot, manager, name in [("one", "manager", "finance"), ("one", "manager", "sb"),
                                   ("one", "manager", "docs"), ("one", "manager", "private"),
                                   ("../escape", "manager", "finance"), ("one", "../escape", "finance"),
                                   ("manager", "manager", "finance"), ("default", "manager", "finance")]:
            before = self.snapshot()
            with self.subTest(bot=bot, manager=manager, connector=name), self.assertRaises(ValueError):
                helper.opt_in(self.home, "hermes", bot, manager, name)
            self.assertEqual(self.snapshot(), before)
        self.assertEqual(helper.read_config(target)["mcp_servers"]["finance"], {"command": "keep-me"})

    def test_symlinked_target_cannot_change_another_bot(self):
        for backend in ("hermes", "openclaw"):
            self.manager(backend)
            self.config(backend, "one", {})
            helper.location(self.home, backend, "alias").symlink_to(helper.location(self.home, backend, "one"), target_is_directory=True)
            before = self.snapshot()
            with self.assertRaises(ValueError):
                helper.opt_in(self.home, backend, "alias", "manager", "finance")
            self.assertEqual(self.snapshot(), before)

    def test_audit_reports_names_sources_and_provenance_without_writes_or_discovery(self):
        for backend in ("hermes", "openclaw"):
            source = self.manager(backend)
            self.config(backend, "one", helper.defaults(self.home))
            legacy = self.config(backend, "legacy", {"private": {"command": "test", "env": {"TOKEN": "audit-must-not-print"}}})
            helper.opt_in(self.home, backend, "one", "manager", "finance")
            before = self.snapshot()
            with patch.object(helper.subprocess, "run") as run:
                result = helper.audit(self.home, backend)
            run.assert_not_called()
            self.assertEqual(self.snapshot(), before)
            rows = result["bots_with_non_defaults"]
            self.assertEqual([(r["bot"], r["connector"]) for r in rows], [("legacy", "private"), ("manager", "finance"), ("manager", "private"), ("one", "finance")])
            self.assertEqual(rows[0]["source"], str(legacy))
            self.assertFalse(rows[0]["origin_known"])
            self.assertEqual(rows[-1]["source"], str(source))
            self.assertTrue(rows[-1]["origin_known"])
            self.assertNotIn("secret", json.dumps(result))
            self.assertNotIn("audit-must-not-print", json.dumps(result))

    def test_audit_cli_uses_fixture_home_and_returns_exact_json(self):
        self.manager("hermes")
        before = self.snapshot()
        command = [sys.executable, str(Path(helper.__file__)), "--home", str(self.home), "audit", "hermes"]
        process = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(process.stdout), helper.audit(self.home, "hermes"))
        self.assertEqual(process.stderr, "")
        self.assertEqual(self.snapshot(), before)

    def test_bad_configuration_fails_with_nonzero_exit_without_echoing_credentials(self):
        path = self.config("hermes", "legacy", {})
        path.write_text("mcp_servers: [broken: secret-not-for-output")
        process = subprocess.run([sys.executable, str(Path(helper.__file__)), "--home", str(self.home), "audit", "hermes"], capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertNotIn("secret-not-for-output", process.stdout + process.stderr)


if __name__ == "__main__":
    unittest.main()
