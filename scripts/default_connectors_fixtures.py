"""Shared loader and offline-home fixtures for the default-connectors helper tests."""
import importlib.util
import json
import os
from pathlib import Path
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
# The read-only half; patch its names (e.g. mcporter_status) where its own functions look them up.
core = sys.modules["connectors_core"]


class DefaultsOnlyCase(unittest.TestCase):
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

    def model_manager(self, provider="openai-codex", name="manager", env="", auth=None, **fields):
        if not getattr(self, "model_env_isolated", False):
            isolated = patch.dict(os.environ, {"PATH": os.environ.get("PATH", os.defpath), "HOME": str(self.home)}, clear=True)
            isolated.start()
            self.addCleanup(isolated.stop)
            self.model_env_isolated = True
        root = helper.location(self.home, "hermes", name)
        root.mkdir(parents=True, exist_ok=True)
        (root / "config.yaml").write_text(yaml.safe_dump({
            "model": {"default": "selected-model", "provider": provider, **fields},
            "delegation": {"provider": "unselected", "api_key": "delegation-secret"},
            "mcp_servers": {"finance": {"command": "secret-tool", "env": {"TOKEN": "connector-secret"}}}}))
        (root / ".env").write_text(env + "\nCONNECTOR_TOKEN=connector-secret\nUNSELECTED_API_KEY=other-provider-secret\n")
        if auth is not None:
            (root / "auth.json").write_text(json.dumps(auth))
        return root

    def create_model_bot(self, manager="manager"):
        before = self.snapshot()

        def stock(command, **kwargs):
            self.assertEqual(command[:5], ["hermes", "profile", "create", "new-model-bot", "--no-alias"])
            root = helper.location(self.home, "hermes", "new-model-bot")
            root.mkdir(parents=True)
            # Defend against a future stock seeder copying root credentials.
            (root / ".env").write_text("CONNECTOR_TOKEN=stock-secret\n")
            (root / "auth.json").write_text('{"providers":{"unselected":{"key":"stock-secret"}}}')
            return subprocess.CompletedProcess(command, 0)

        with patch.object(helper.subprocess, "run", side_effect=stock) as run:
            report = helper.create(self.home, "hermes", "new-model-bot", manager=manager)
        run.assert_called_once()
        root = helper.location(self.home, "hermes", "new-model-bot")
        for path, content in before.items():
            self.assertEqual((self.home / path).read_bytes(), content)
        for path in root.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"connector-secret", path.read_bytes())
                self.assertNotIn(b"other-provider-secret", path.read_bytes())
                self.assertNotIn(b"delegation-secret", path.read_bytes())
                self.assertNotIn(b"stock-secret", path.read_bytes())
        for name in ("config.yaml", ".env", "auth.json"):
            if (root / name).exists():
                self.assertEqual((root / name).stat().st_mode & 0o777, 0o600)
        self.assertEqual(set(helper.read_config(root / "config.yaml")["mcp_servers"]), {"sb"})
        self.assertNotIn("model-secret", json.dumps(report))
        return root
