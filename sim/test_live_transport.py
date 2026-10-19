"""QA transport harness safety and wire-framing tests; never contacts Hermes."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from live_transport import Suite, frames


class QALiveTransportTests(unittest.TestCase):
    def test_QA_refuses_remote_or_ambiguous_endpoint_before_output(self):
        for url in ["http://example.com:8742", "http://localhost:8742", "http://127.0.0.1:8742/other",
                    "http://QA-user@127.0.0.1:8742", "http://127.0.0.1:8742?QA-query", "https://127.0.0.1:8742"]:
            with self.subTest(url=url), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "QA-results"
                with patch.dict(os.environ, {"HERMES_BASE_URL": url, "HERMES_API_KEY": "QA-secret", "HERMES_MODEL": "QA-model"}):
                    with self.assertRaises(ValueError):
                        Suite(output)
                self.assertFalse(output.exists())

    def test_QA_never_overwrites_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {"HERMES_BASE_URL": "http://127.0.0.1:8742", "HERMES_API_KEY": "QA-secret", "HERMES_MODEL": "QA-model"}):
                with self.assertRaises(FileExistsError):
                    Suite(Path(directory))

    def test_QA_multiline_CRLF_comment_and_partial_frame(self):
        wire = b': QA-keepalive\r\n\r\nevent: QA-event\r\ndata: {"QA-value":\r\ndata: true}\r\n\r\ndata: QA-incomplete'
        parsed = frames(wire)
        self.assertEqual(len(parsed), 2)
        self.assertEqual(parsed[0]["comments"], ["QA-keepalive"])
        self.assertEqual(parsed[1]["event"], "QA-event")
        self.assertEqual(parsed[1]["data"], '{"QA-value":\ntrue}')

    def test_QA_evidence_redacts_key(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {"HERMES_BASE_URL": "http://127.0.0.1:8742", "HERMES_API_KEY": "QA-secret", "HERMES_MODEL": "QA-model"}):
                suite = Suite(Path(directory) / "QA-results")
                suite.traces.append({"name": "QA-echo", "body": "QA-secret"})
                suite.save()
            result = (suite.output / "results.json").read_text()
            self.assertNotIn("QA-secret", result)
            self.assertIn("[REDACTED]", result)

    def test_QA_budget_refuses_before_network(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.dict(os.environ, {"HERMES_BASE_URL": "http://127.0.0.1:8742", "HERMES_API_KEY": "QA-secret", "HERMES_MODEL": "QA-model"}):
                suite = Suite(Path(directory) / "QA-results")
                suite.requests = 160
                with patch("live_transport.http.client.HTTPConnection") as connection:
                    with self.assertRaises(RuntimeError):
                        suite.request("QA-over-budget", "/v1/models")
                    connection.assert_not_called()
