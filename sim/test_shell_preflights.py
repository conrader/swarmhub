"""Shell skip contracts, with synthetic interpreter failures and no network."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ShellPreflightTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="shell-preflight-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.env = {"HOME": str(self.home), "TMPDIR": str(self.home),
                    "PATH": str(self.bin) + ":/usr/bin:/bin"}

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def run_suite(self, suite, shell="/bin/sh", recipe=None):
        args = ([str(recipe or ROOT / "Resources/BotManager/recipes/accounts.md"), str(self.bin)]
                if suite == "accounts-recipes" else
                [str(ROOT / "Resources/Skills/swarmhub-messages/scripts/bot-msg")])
        return subprocess.run([shell, str(ROOT / "Tests/Scripts" / (suite + "-test.sh")), *args],
                              env=dict(self.env, BOX_SH=shell, BOT_MSG_SH=shell),
                              capture_output=True, text=True, timeout=30)

    def assert_failure(self, result):
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("FAIL:", result.stdout)
        self.assertNotIn("SKIP:", result.stdout)
        self.assertNotIn("passed,", result.stdout)

    def test_interpreter_errors_and_empty_success_are_failures(self):
        for shell in ("/bin/sh", "/bin/dash"):
            if not os.access(shell, os.X_OK):
                continue
            for suite, interpreter in (("bot-msg", "python3"), ("accounts-recipes", "node")):
                for body in ("exit 42", "exit 0"):
                    with self.subTest(shell=shell, suite=suite, body=body):
                        self.stub(interpreter, body)
                        self.assert_failure(self.run_suite(suite, shell))

    def test_missing_selected_node_is_an_explicit_skip(self):
        result = self.run_suite("accounts-recipes")
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertTrue(result.stdout.startswith("SKIP:"))
        self.assertEqual(result.stderr, "")

    def test_only_socket_permission_errors_skip(self):
        # Execute the actual Python preflight with a controlled socket failure.
        for errno in ("EPERM", "EACCES", "EINVAL"):
            code = ("import errno, socket, sys\n"
                    "def denied(*args, **kwargs):\n"
                    f"    raise OSError(errno.{errno}, 'synthetic error')\n"
                    "socket.socket = denied\n"
                    "exec(sys.argv[1])\n")
            fixture = self.home / "socket-failure.py"
            fixture.write_text(code)
            self.stub("python3", f'exec "{sys.executable}" -I "{fixture}" "$3"')
            result = self.run_suite("bot-msg")
            with self.subTest(errno=errno):
                if errno == "EINVAL":
                    self.assert_failure(result)
                else:
                    self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
                    self.assertEqual(len(result.stdout.splitlines()), 1)
                    self.assertTrue(result.stdout.startswith("SKIP:"))

    def test_only_node_permission_errors_skip(self):
        node = shutil.which("node", path="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        if not node:
            self.skipTest("node unavailable for actual JavaScript preflight regression")
        for error in ("EPERM", "EACCES", "EINVAL"):
            fixture = self.home / "node-failure.js"
            fixture.write_text('require("child_process").execSync = () => { '
                               f'throw Object.assign(new Error("synthetic"), {{code: "{error}"}});'
                               ' }; eval(process.argv[2]);\n')
            self.stub("node", f'exec "{node}" "{fixture}" "$2"')
            result = self.run_suite("accounts-recipes")
            with self.subTest(error=error):
                if error == "EINVAL":
                    self.assert_failure(result)
                else:
                    self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
                    self.assertEqual(len(result.stdout.splitlines()), 1)
                    self.assertTrue(result.stdout.startswith("SKIP:"))

    def test_accounts_redaction_assertion_rejects_each_leak(self):
        node = shutil.which("node", path="/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin")
        if not node:
            self.skipTest("node unavailable for accounts recipe redaction regression")
        (self.bin / "node").symlink_to(node)
        original = (ROOT / "Resources/BotManager/recipes/accounts.md").read_text()
        self.assertIn('{op:"accounts",', original)
        for leak in ("canary@example.invalid", "sk-ant-canary", "R-B"):
            recipe = self.home / "accounts.md"
            recipe.write_text(original.replace('{op:"accounts",', f'{{op:"accounts",canary:"{leak}",'))
            result = self.run_suite("accounts-recipes", recipe=recipe)
            with self.subTest(leak=leak):
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("no token, no email", result.stdout)


if __name__ == "__main__":
    unittest.main()
