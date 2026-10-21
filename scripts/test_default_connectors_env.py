"""The shared dotenv reader on the existing opt-in path: values decode as python-dotenv (Hermes' runtime) reads them."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from default_connectors_fixtures import DefaultsOnlyCase, helper  # noqa: E402

# (manager .env value, value the opted-in bot receives), as python-dotenv 1.x decodes them.
ACCEPTED = {
    "plain": ("plain-secret", "plain-secret"),
    "plain with comment": ("plain-secret # rotated", "plain-secret"),
    "plain keeps hash": ("abc#def", "abc#def"),
    "plain keeps backslashes": (r"C:\keys\n1", r"C:\keys\n1"),
    "double": ('"quoted secret"', "quoted secret"),
    "double keeps hash": ('"a # b"', "a # b"),
    "double escapes": (r'"say \"hi\" \\ done"', 'say "hi" \\ done'),
    "double control escapes": (r'"tab\there\nline"', "tab\there\nline"),
    "double escaped single quote": (r'"it\'s"', "it's"),
    "double keeps JSON-only escapes": (r'"caf\u00e9\/x"', r"caf\u00e9\/x"),
    "double keeps unknown escapes": (r'"C:\data\x41"', r"C:\data\x41"),
    "double raw unicode": ('"café"', "café"),
    "single": ("'single $HOME'", "single $HOME"),
    "single escapes": (r"'it\'s \\ ok'", "it's \\ ok"),
    "single keeps other escapes": (r"'keep\nliteral'", r"keep\nliteral"),
    "single escaped backslash then quote": (r"'a\\\'b'", "a\\'b"),
}
MALFORMED = {"unterminated double": '"unterminated', "unterminated single": "'unterminated",
             "mismatched": "'mismatch\"", "lone quote": '"', "quoted then comment": '"x" # note'}


class OptInEnvironmentTests(DefaultsOnlyCase):
    def opt_in_with(self, line, reference="${FINANCE_TOKEN}", backend="hermes"):
        self.manager(backend)
        source = helper.config_path(self.home, backend, "manager")
        config = helper.read_config(source)
        key = "mcp_servers" if backend == "hermes" else "mcpServers"
        config[key]["finance"]["headers"]["Authorization"] = reference
        source.write_text(yaml.safe_dump(config) if backend == "hermes" else json.dumps(config))
        (helper.location(self.home, backend, "manager") / ".env").write_text(
            "# manager credentials\n" + line + "\nPRIVATE_TOKEN=unselected-dotenv-secret\n")
        target = self.config(backend, "reports", {})
        helper.opt_in(self.home, backend, "reports", "manager", "finance")
        return helper.read_config(target)[key]["finance"]["headers"]["Authorization"]

    def setUp(self):
        super().setUp()
        isolated = patch.dict(helper.os.environ, {"PATH": helper.os.environ.get("PATH", "")}, clear=True)
        isolated.start()
        self.addCleanup(isolated.stop)

    def fresh(self):
        DefaultsOnlyCase.setUp(self)  # A new offline home; the environment stays isolated.

    def test_plain_quoted_and_escaped_values_reach_only_the_selected_bot(self):
        for backend in ("hermes", "openclaw"):
            for name, (raw, expected) in ACCEPTED.items():
                for prefix in ("", "export "):
                    with self.subTest(backend=backend, case=name, prefix=prefix):
                        self.fresh()
                        self.assertEqual(self.opt_in_with(prefix + "FINANCE_TOKEN=" + raw, backend=backend), expected)
                        self.assertNotIn("unselected-dotenv-secret", json.dumps(helper.read_config(
                            helper.config_path(self.home, backend, "reports"))))

    def test_empty_values_are_empty_and_defaults_apply_only_to_empty_or_unset(self):
        for raw in ("", '""', "''", "   "):
            with self.subTest(raw=raw):
                self.fresh()
                self.assertEqual(self.opt_in_with("FINANCE_TOKEN=" + raw), "")
                self.fresh()
                self.assertEqual(self.opt_in_with("FINANCE_TOKEN=" + raw, "${FINANCE_TOKEN:-fallback}"), "fallback")
        self.fresh()
        self.assertEqual(self.opt_in_with("FINANCE_TOKEN=set", "${FINANCE_TOKEN:-fallback}"), "set")
        self.fresh()
        self.assertEqual(self.opt_in_with("OTHER=1", "${FINANCE_TOKEN:-fallback}"), "fallback")

    def test_unparseable_lines_are_ignored_and_later_files_win(self):
        self.assertEqual(self.opt_in_with("1BAD=x\nnot an assignment\nFINANCE_TOKEN=first\nFINANCE_TOKEN=last"), "last")
        self.fresh()
        (self.home / ".hermes").mkdir(parents=True, exist_ok=True)
        (self.home / ".hermes/.env").write_text("FINANCE_TOKEN=root-value\n")
        self.assertEqual(self.opt_in_with("FINANCE_TOKEN=manager-value"), "manager-value")

    def test_malformed_quoting_fails_before_any_write(self):
        for name, raw in MALFORMED.items():
            with self.subTest(case=name):
                self.fresh()
                with self.assertRaises(ValueError):
                    self.opt_in_with("FINANCE_TOKEN=" + raw)
                target = helper.config_path(self.home, "hermes", "reports")
                self.assertNotIn("finance", helper.read_config(target)["mcp_servers"])
                self.assertFalse((target.parent / ".swarmhub-connector-sources.json").exists())

    def test_malformed_quoting_is_a_redacted_cli_failure(self):
        self.manager("hermes")
        (helper.location(self.home, "hermes", "manager") / ".env").write_text("FINANCE_TOKEN='selected-finance-secret\n")
        self.config("hermes", "reports", {})
        result = subprocess.run([sys.executable, str(Path(helper.__file__)), "--home", str(self.home), "opt-in", "hermes", "reports",
                                 "--manager", "manager", "--connector", "finance"], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["list"][0]["state"], "failed")
        self.assertNotIn("selected-finance-secret", result.stdout + result.stderr)

    def test_written_model_keys_read_back_unchanged(self):
        for value in ("model-secret", 'quote-"-and-\\-slash', "clé-secret", "tab\tkey"):
            with self.subTest(value=value):
                self.fresh()
                self.model_manager("openrouter", env="OPENROUTER_API_KEY=" + json.dumps(value, ensure_ascii=False))
                root = self.create_model_bot()
                self.assertEqual(helper.environment_values([root / ".env"])["OPENROUTER_API_KEY"], value)
                self.assertNotIn("\\u", (root / ".env").read_text(), "Hermes' readers keep \\u escapes literally")


if __name__ == "__main__":
    unittest.main()
