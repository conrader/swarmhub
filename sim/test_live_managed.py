"""Offline tests of the live runner's bridge and coding-job construction. No provider or socket calls."""
import io
import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import Mock, patch

from live_managed import ManagedSuite
from live_cli import RULES, qa_repo


class ManagedHarnessTests(unittest.TestCase):
    def test_bridge_supplies_rules_and_fallback_environment(self):
        suite = ManagedSuite.__new__(ManagedSuite)
        suite.run, suite.key, suite.sequence = "QA-test", "synthetic-key", 0
        suite.lock = threading.Lock()
        suite.owned = {"QA-test-QA-Infra-from-QA-Jarvis"}
        suite.child_env, suite.base_env = {}, {}
        suite.hook = Mock(return_value={"context": "held context"})
        suite.request = Mock(return_value={"status": 200, "body": ""})
        server = Mock(server_port=12345)
        with patch("live_managed.ThreadingHTTPServer", return_value=server) as factory, patch("live_managed.threading.Thread"):
            suite.bridge()
        handler = factory.call_args.args[1]
        payload = json.dumps({"input": "QA task"}).encode()
        raw = ("POST /p/QA-Infra/api/sessions/swarmhub-from-QA-Jarvis/chat/stream HTTP/1.0\r\n"
               f"Authorization: Bearer {suite.key}\r\nContent-Length: {len(payload)}\r\n\r\n").encode() + payload

        class Connection:
            output = b""

            def makefile(self, *args):
                return io.BytesIO(raw)

            def sendall(self, data):
                self.output += data

        connection = Connection()
        handler(connection, ("127.0.0.1", 0), server)
        self.assertIn(b"200 OK", connection.output)
        suite.request.assert_called_once()
        body = suite.request.call_args.args[3]
        self.assertEqual(body["input"], "QA task")
        self.assertTrue(body["instructions"].startswith(RULES))
        self.assertIn("held context", body["instructions"])
        self.assertIn('```swarmhub\n{"op":"secret_request"', body["instructions"])
        self.assertIn('Bare JSON, a `json` fence', body["instructions"])
        self.assertEqual(suite.base_env["SWARMHUB_GATEWAY"], suite.child_env["SWARMHUB_GATEWAY"])

    def test_real_jobs_keep_reports_in_the_cli_workspace_and_require_exact_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = ManagedSuite.__new__(ManagedSuite)
            suite.cli, suite.model = {"agent": "codex"}, "test-model"
            suite.repo = qa_repo(Path(temporary) / "repo")
            suite.home = Path(temporary) / "home"
            suite.temp = Path(temporary)
            suite.init_chain_verifier()
            spec = suite.coding("QA-P01-first")
            self.assertEqual(spec["directory"], str(suite.repo))
            self.assertEqual(Path(spec["report"]).parent, suite.repo)
            self.assertEqual(spec["verify"], suite.verify_command("QA-P01-first"))
            self.assertIn("A new commit is required", spec["task"])
            self.assertEqual(spec["order"], "codex")
            self.assertNotIn("fake", spec)
            suite.cli = None
            fallback = suite.coding("QA-P01-first")
            self.assertNotIn("verify", fallback)
            self.assertEqual(fallback["directory"], str(suite.home))


if __name__ == "__main__":
    unittest.main()
