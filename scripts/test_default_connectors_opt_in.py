"""Workspaces, explicit opt-in and audit through the real helper, against offline homes."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parent))
from default_connectors_fixtures import DefaultsOnlyCase, helper  # noqa: E402


class DefaultsOnlyOptInTests(DefaultsOnlyCase):
    def test_openclaw_stock_main_manager_and_configured_custom_workspaces(self):
        stock = self.home / ".openclaw/workspace/config/mcporter.json"
        stock.parent.mkdir(parents=True)
        stock.write_text(json.dumps({"mcpServers": {"finance": {"baseUrl": "https://finance.invalid", "headers": {"Authorization": "selected-secret"}}}}))
        self.assertEqual(helper.config_path(self.home, "openclaw", "main"), stock)
        target = self.config("openclaw", "one", {})
        helper.opt_in(self.home, "openclaw", "one", "main", "finance")
        self.assertIn("finance", helper.read_config(target)["mcpServers"])
        self.assertIn("main", [r["bot"] for r in helper.audit(self.home, "openclaw")["bots_with_non_defaults"]])
        gateway = self.home / ".openclaw/openclaw.json"
        for inventory in ({"entries": {"main": {"workspace": "~/custom-manager"}, "one": {"workspace": "~/custom-bot"}}},
                          {"list": [{"id": "main", "workspace": "~/custom-manager"}, {"id": "one", "workspace": "~/custom-bot"}]}):
            with self.subTest(inventory=inventory):
                gateway.write_text(json.dumps({"agents": inventory}))
                manager = self.config("openclaw", "main", {"private": {"command": "private-mcp"}})
                target = self.config("openclaw", "one", {})
                self.assertEqual(manager, self.home / "custom-manager/config/mcporter.json")
                self.assertEqual(target, self.home / "custom-bot/config/mcporter.json")
                helper.opt_in(self.home, "openclaw", "one", "main", "private")
                before = self.snapshot()
                rows = helper.audit(self.home, "openclaw")["bots_with_non_defaults"]
                self.assertTrue(any(r["bot"] == "one" and r["source"] == str(manager) for r in rows))
                self.assertEqual(self.snapshot(), before)

    def test_keyed_openclaw_inventory_resolves_multiple_unpinned_workspaces_separately(self):
        gateway = self.home / ".openclaw/openclaw.json"
        gateway.parent.mkdir(parents=True)
        gateway.write_text(json.dumps({"agents": {"ownership": "explicit", "defaults": {"workspace": "~/bots"},
                                                    "entries": {"main": {"default": True}, "reports": {}}}}))
        self.assertEqual(helper.location(self.home, "openclaw", "main"), self.home / "bots/main")
        self.assertEqual(helper.location(self.home, "openclaw", "reports"), self.home / "bots/reports")

    def test_shared_openclaw_workspace_cannot_apply_an_opt_in_for_only_one_bot(self):
        gateway = self.home / ".openclaw/openclaw.json"
        gateway.parent.mkdir(parents=True)
        gateway.write_text(json.dumps({"agents": {"entries": {"one": {"workspace": "~/shared"}, "two": {"workspace": "~/shared"}}}}))
        self.config("openclaw", "one", {})
        self.manager("openclaw")
        before = self.snapshot()
        with self.assertRaises(ValueError):
            helper.opt_in(self.home, "openclaw", "one", "manager", "finance")
        self.assertEqual(self.snapshot(), before)

    def test_explicit_source_copies_one_inherited_manager_connector_only(self):
        self.manager("openclaw")
        target = self.config("openclaw", "one", {})
        source = self.home / ".mcporter/mcporter.json"
        source.parent.mkdir(parents=True)
        source.write_text(json.dumps({"mcpServers": {"inherited": {"baseUrl": "https://selected.invalid", "headers": {"Authorization": "selected-secret"}},
                                                     "unselected": {"command": "private", "env": {"KEY": "unselected-secret"}}}}))
        before = source.read_bytes()
        helper.opt_in(self.home, "openclaw", "one", "manager", "inherited", source)
        self.assertEqual(set(helper.read_config(target)["mcpServers"]), {"inherited"})
        self.assertNotIn("unselected-secret", target.read_text())
        self.assertEqual(source.read_bytes(), before)

    def test_missing_selected_credentials_fail_before_any_bot_write(self):
        self.manager("hermes")
        self.config("hermes", "one", {})
        (helper.location(self.home, "hermes", "manager") / ".env").write_text("")
        before = self.snapshot()
        with patch.dict(helper.os.environ, {}, clear=True), self.assertRaises(ValueError):
            helper.opt_in(self.home, "hermes", "one", "manager", "finance")
        self.assertEqual(self.snapshot(), before)

    def test_openclaw_http_aliases_and_credential_interpolation(self):
        for field in ("url", "baseUrl", "serverUrl"):
            with self.subTest(field=field):
                self.config("openclaw", "manager", {"finance": {
                    field: "https://finance.invalid/mcp", "headers": {
                        "Authorization": "Bearer $env:FINANCE_TOKEN", "X-Default": "${ABSENT:-fallback}"},
                    "env": {"OTHER": "${FINANCE_TOKEN}"}}})
                (helper.location(self.home, "openclaw", "manager") / ".env").write_text("FINANCE_TOKEN=selected-finance-secret\n")
                target = self.config("openclaw", "bot-" + field.lower(), {})
                helper.opt_in(self.home, "openclaw", "bot-" + field.lower(), "manager", "finance")
                entry = helper.read_config(target)["mcpServers"]["finance"]
                self.assertEqual(entry[field], "https://finance.invalid/mcp")
                self.assertEqual(entry["headers"]["Authorization"], "Bearer selected-finance-secret")
                self.assertEqual(entry["headers"]["X-Default"], "fallback")
                self.assertEqual(entry["env"]["OTHER"], "selected-finance-secret")

    def test_openclaw_discovery_uses_only_the_explicit_bot_config(self):
        self.config("openclaw", "one", helper.defaults(self.home))
        home_config = self.home / ".mcporter/mcporter.json"
        home_config.parent.mkdir()
        home_config.write_text(json.dumps({"mcpServers": {"private": {"command": "private-mcp"}}}))

        def isolated_mcporter(command, **kwargs):
            # MCPorter's --config contract bypasses home merging. Without it this fixture includes private.
            config = helper.read_config(Path(command[command.index("--config") + 1])) if "--config" in command else helper.read_config(home_config)
            self.assertEqual(set(config["mcpServers"]), {"sb"})
            return subprocess.CompletedProcess(command, 0, json.dumps({"status": "ok", "tools": []}))

        with patch.object(helper.shutil, "which", return_value="mcporter"), patch.object(helper.subprocess, "run", side_effect=isolated_mcporter):
            report = helper.inspect(self.home, "openclaw", "one")
        self.assertEqual([row["name"] for row in report["list"]], ["sb"])

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

    def test_openclaw_audit_includes_legacy_home_connectors_and_flags_unresolved_catalogs(self):
        self.config("openclaw", "legacy", {})
        self.config("openclaw", "new", {})
        root = helper.location(self.home, "openclaw", "new")
        (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
        helper.provision(self.home, "openclaw", "new")
        source = self.home / ".mcporter/mcporter.json"
        source.parent.mkdir()
        source.write_text(json.dumps({"mcpServers": {"private": {"command": "private", "env": {"TOKEN": "audit-secret"}}},
                                      "imports": ["sensitive-import-string"]}))
        before = self.snapshot()
        with patch.dict(helper.os.environ, {}, clear=True):
            result = helper.audit(self.home, "openclaw")
        self.assertEqual([(r["bot"], r["connector"], r["source"]) for r in result["bots_with_non_defaults"]],
                         [("legacy", "private", str(source))])
        self.assertTrue(result["unresolved_catalogs"])
        self.assertTrue(all(r["bot"] == "legacy" for r in result["unresolved_catalogs"]))
        self.assertNotIn("sensitive-import-string", json.dumps(result))
        self.assertNotIn("audit-secret", json.dumps(result))
        self.assertEqual(self.snapshot(), before)

    def test_bad_configuration_fails_with_nonzero_exit_without_echoing_credentials(self):
        path = self.config("hermes", "legacy", {})
        path.write_text("mcp_servers: [broken: secret-not-for-output")
        process = subprocess.run([sys.executable, str(Path(helper.__file__)), "--home", str(self.home), "audit", "hermes"], capture_output=True, text=True)
        self.assertEqual(process.returncode, 1)
        self.assertNotIn("secret-not-for-output", process.stdout + process.stderr)


if __name__ == "__main__":
    unittest.main()
