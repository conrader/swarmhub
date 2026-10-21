"""Fresh creation through the real helper: only the selected model credentials, never a manager clone."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from default_connectors_fixtures import DefaultsOnlyCase, helper  # noqa: E402


class DefaultsOnlyCreationTests(DefaultsOnlyCase):
    def test_fresh_backend_creation_never_clones_manager_credentials(self):
        for backend in ("hermes", "openclaw"):
            with self.subTest(backend=backend):
                source = self.manager(backend)
                if backend == "hermes":
                    config = helper.read_config(source)
                    config["model"] = {"default": "test-model", "provider": "openai-api"}
                    source.write_text(yaml.safe_dump(config))
                    (source.parent / ".env").write_text("OPENAI_API_KEY=model-secret\nFINANCE_TOKEN=finance-secret\nPRIVATE_TOKEN=dotenv-secret\n")
                before = source.read_bytes()

                def create_stub(command, **kwargs):
                    self.assertNotIn("--clone-from", command)
                    self.assertNotIn("--clone", command)
                    self.assertNotIn("manager", command)
                    self.config(backend, "new-bot", {})
                    return subprocess.CompletedProcess(command, 0)

                with patch.object(helper.subprocess, "run", side_effect=create_stub) as run:
                    result = helper.create(self.home, backend, "new-bot", "My bot", manager="manager")
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
                if backend == "hermes":
                    self.assertEqual(helper.environment_values([target.parent / ".env"])["OPENAI_API_KEY"], 'model-secret')
                    self.assertEqual(config["model"], {"default": "test-model", "provider": "openai-api"})
                else:
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

    def test_selected_shared_oauth_is_inherited_without_forking_refresh_tokens(self):
        shared = {"version": 1, "providers": {"openai-codex": {"tokens": {
            "access_token": "model-secret", "refresh_token": "model-refresh"}},
            "anthropic": {"api_key": "other-provider-secret"}},
            "credential_pool": {"openai-codex": [{"source": "device_code", "refresh_token": "model-refresh"}]}}
        self.model_manager(name="default", auth=shared)
        self.model_manager()  # Named manager reads through to root, as will the new bot.
        root = self.create_model_bot()
        self.assertFalse((root / "auth.json").exists())
        self.assertEqual((root / ".env").read_text(), "")
        # A root refresh remains immediately visible, with no stale local shadow.
        shared["providers"]["openai-codex"]["tokens"]["refresh_token"] = "rotated-refresh"
        (self.home / ".hermes/auth.json").write_text(json.dumps(shared))
        self.assertIsNone(helper.hermes_model_auth(self.home, "manager")[2])

    def test_private_manager_oauth_is_refused_before_copying_a_rotating_grant(self):
        self.model_manager(auth={"providers": {"openai-codex": {"tokens": {
            "access_token": "model-secret", "refresh_token": "model-refresh"}}}})
        before = self.snapshot()
        with patch.object(helper.subprocess, "run") as run, self.assertRaises(helper.ModelAuthError):
            helper.create(self.home, "hermes", "not-created", manager="manager")
        run.assert_not_called()
        self.assertEqual(before, self.snapshot())

    def test_api_key_model_endpoint_and_only_selected_env_are_transferred(self):
        self.model_manager("openai-api", env="OPENAI_API_KEY=model-secret\nOPENAI_BASE_URL=https://models.invalid/v1\nANTHROPIC_API_KEY=other-provider-secret")
        root = self.create_model_bot()
        self.assertEqual((root / ".env").read_text(),
                         'OPENAI_API_KEY="model-secret"\nOPENAI_BASE_URL="https://models.invalid/v1"\n')
        self.assertFalse((root / "auth.json").exists())

    def test_named_manager_overrides_root_static_credentials_per_provider(self):
        self.model_manager("openai-api", name="default", env="OPENAI_API_KEY=root-key", auth={
            "version": 1, "providers": {"openai-api": {"api_key": "root-model"}},
            "credential_pool": {"openai-api": [{"access_token": "root-pool", "auth_type": "api_key", "source": "manual"}]}})
        self.model_manager("openai-api", env="OPENAI_API_KEY=model-secret", auth={
            "version": 1, "providers": {"openai-api": {"api_key": "model-secret"}}})
        root = self.create_model_bot()
        auth = helper.read_config(root / "auth.json")
        self.assertEqual(auth["providers"]["openai-api"]["api_key"], "model-secret")
        self.assertEqual(auth["credential_pool"]["openai-api"], [{"access_token": "root-pool", "auth_type": "api_key", "source": "manual"}])
        self.assertEqual(helper.environment_values([root / ".env"])["OPENAI_API_KEY"], "model-secret")

    def test_default_manager_shared_oauth_is_supported_without_a_copy(self):
        self.model_manager(name="default", auth={"providers": {"openai-codex": {"tokens": {
            "access_token": "model-secret", "refresh_token": "model-refresh"}}}})
        root = self.create_model_bot(manager="default")
        self.assertFalse((root / "auth.json").exists())

    def test_provider_endpoint_overrides_and_key_priority_are_preserved(self):
        for provider, first, alias, endpoint in (
            ("anthropic", "ANTHROPIC_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_BASE_URL"),
            ("gemini", "GOOGLE_API_KEY", "GEMINI_API_KEY", "GEMINI_BASE_URL"),
            ("copilot", "COPILOT_GITHUB_TOKEN", "GH_TOKEN", "COPILOT_API_BASE_URL"),
            ("openrouter", "OPENROUTER_API_KEY", "OPENAI_API_KEY", "OPENROUTER_BASE_URL")):
            with self.subTest(provider=provider):
                self.model_manager(provider, env=f"{first}=model-secret\n{alias}=unused-key\n{endpoint}=https://models.invalid/v1")
                model, env, auth = helper.hermes_model_auth(self.home, "manager")
                self.assertEqual(env, {first: "model-secret", endpoint: "https://models.invalid/v1"})
                self.assertEqual(model["provider"], provider)

    def test_legacy_openrouter_openai_key_fallback_and_escaped_keys_roundtrip(self):
        value = 'model-secret-"quoted"-\\suffix'
        self.model_manager("openrouter", env="OPENAI_API_KEY=" + json.dumps(value))
        root = self.create_model_bot()
        self.assertEqual(helper.environment_values([root / ".env"])["OPENAI_API_KEY"], value)

    def test_selected_env_hints_nested_model_and_custom_endpoint_are_preserved(self):
        self.model_manager("custom", env="CUSTOM_BASE_URL=http://localhost:8080/v1\nPRIMARY_MODEL_KEY=model-secret\nOTHER_MODEL_KEY=unused-key",
                           key_env="PRIMARY_MODEL_KEY", api_key_env="OTHER_MODEL_KEY")
        source = helper.config_path(self.home, "hermes", "manager")
        config = helper.read_config(source)
        config["model"]["default"] = {"provider": "custom", "model": "nested-model"}
        source.write_text(yaml.safe_dump(config))
        root = self.create_model_bot()
        model = helper.read_config(root / "config.yaml")["model"]
        self.assertEqual(model["default"], "nested-model")
        self.assertEqual(model["base_url"], "http://localhost:8080/v1")
        self.assertEqual(model["api_key"], "model-secret")
        self.assertIn('PRIMARY_MODEL_KEY="model-secret"', (root / ".env").read_text())
        self.assertNotIn("unused-key", (root / ".env").read_text())

    def test_incomplete_codex_and_metadata_only_auth_do_not_create_a_bot(self):
        for provider, state in (("openai-codex", {"tokens": {"access_token": "model-secret"}}),
                                ("openai-api", {"endpoint": "https://models.invalid"})):
            self.model_manager(provider, auth={"providers": {provider: state}})
            with patch.object(helper.subprocess, "run") as run, self.assertRaises(helper.ModelAuthError):
                helper.create(self.home, "hermes", "not-created", manager="manager")
            run.assert_not_called()

    def test_local_custom_model_needs_no_login_and_keeps_endpoint(self):
        self.model_manager("ollama", base_url="http://localhost:11434/v1")
        root = self.create_model_bot()
        self.assertEqual(helper.read_config(root / "config.yaml")["model"], {
            "default": "selected-model", "provider": "custom", "base_url": "http://localhost:11434/v1"})

    def test_inline_selected_model_key_and_header_references_are_materialized(self):
        self.model_manager("custom", env="MODEL_KEY=model-secret\nOPENAI_API_KEY=other-provider-secret", api_key="${MODEL_KEY}",
                           base_url="https://models.invalid/v1", extra_headers={"X-Model": "${MODEL_KEY}"},
                           unrelated="connector-secret")
        root = self.create_model_bot()
        model = helper.read_config(root / "config.yaml")["model"]
        self.assertEqual(model["api_key"], "model-secret")
        self.assertEqual(model["extra_headers"], {"X-Model": "model-secret"})
        self.assertNotIn("unrelated", model)

    def test_local_custom_endpoint_does_not_receive_an_unrelated_openai_key(self):
        self.model_manager("custom", env="OPENAI_API_KEY=other-provider-secret", base_url="http://127.0.0.1:8080/v1")
        root = self.create_model_bot()
        self.assertNotIn("api_key", helper.read_config(root / "config.yaml")["model"])
        self.assertEqual((root / ".env").read_text(), "")

    def test_missing_unsupported_and_ambiguous_auth_fail_before_backend_or_writes(self):
        for provider, env in (("openai-codex", ""), ("unknown-future-provider", ""),
                              ("auto", "OPENAI_API_KEY=one\nANTHROPIC_API_KEY=two")):
            with self.subTest(provider=provider):
                self.model_manager(provider, env=env)
                before = self.snapshot()
                with patch.object(helper.subprocess, "run") as run, self.assertRaises(helper.ModelAuthError):
                    helper.create(self.home, "hermes", "not-created", manager="manager")
                run.assert_not_called()
                self.assertEqual(self.snapshot(), before)

    def test_missing_manager_is_a_redacted_cli_setup_failure(self):
        self.model_manager()
        before = self.snapshot()
        result = subprocess.run([sys.executable, "-B", helper.__file__, "--home", str(self.home),
                                 "create", "hermes", "not-created"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("requires --manager", result.stdout)
        self.assertNotIn("secret", result.stdout + result.stderr)
        self.assertEqual(self.snapshot(), before)

    def test_reprovision_never_replaces_model_credentials_or_later_opt_ins(self):
        self.model_manager("openai-api", env="OPENAI_API_KEY=model-secret")
        root = self.create_model_bot()
        (root / ".env").write_text("OPENAI_API_KEY=later-login\n")
        config = helper.read_config(root / "config.yaml")
        config["mcp_servers"]["later-opt-in"] = {"command": "later"}
        (root / "config.yaml").write_text(yaml.safe_dump(config))
        before = self.snapshot()
        helper.provision(self.home, "hermes", "new-model-bot")
        self.assertEqual(self.snapshot(), before)

    def test_openclaw_creation_uses_verified_cli_syntax_and_leaves_shared_auth_alone(self):
        state = self.home / ".openclaw"
        state.mkdir()
        (state / "openclaw.json").write_text(json.dumps({"agents": {"defaults": {
            "model": {"primary": "openai-codex/test-model"}}}}))
        auth = state / "agents/main/agent/auth-profiles.json"
        auth.parent.mkdir(parents=True)
        auth.write_text(json.dumps({"profiles": {"chosen": {"provider": "openai-codex", "access": "model-secret"}}}))
        before = self.snapshot()
        def stock(command, **kwargs):
            self.assertEqual(command, ["openclaw", "agents", "add", "new-agent", "--workspace",
                                      str(state / "workspace-new-agent"), "--non-interactive", "--json"])
            (state / "workspace-new-agent").mkdir()
            return subprocess.CompletedProcess(command, 0)
        with patch.object(helper.subprocess, "run", side_effect=stock) as run:
            helper.create(self.home, "openclaw", "new-agent")
        run.assert_called_once()
        for path, content in before.items():
            self.assertEqual((self.home / path).read_bytes(), content)
        for path in (state / "workspace-new-agent").rglob("*"):
            if path.is_file():
                self.assertNotIn(b"model-secret", path.read_bytes())

    def test_fresh_hermes_without_a_seeded_config_still_gets_defaults(self):
        root = helper.location(self.home, "hermes", "new")
        root.mkdir(parents=True)
        (root / ".swarmhub-new-bot").write_text("defaults-only-v1\n")
        helper.provision(self.home, "hermes", "new")
        self.assertEqual(set(helper.read_config(root / "config.yaml")["mcp_servers"]), {"sb"})


if __name__ == "__main__":
    unittest.main()
