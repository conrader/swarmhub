"""Oracles and isolation checks for LIVE2; no external requests/model calls."""
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
from unittest.mock import patch

from live_behavior import BehaviorSuite, objects, successful
from live_usage import snapshot


def wire(events):
    return {"status": 200, "body": "".join("event: " + e + "\ndata: " + json.dumps(o) + "\n\n" for e, o in events)}


class LiveBehaviorTests(unittest.TestCase):
    def test_failure_and_unsuccessful_flags_beat_completion(self):
        for extra in [("run.failed", {}), ("run.cancelled", {}), ("error", {}),
                      ("assistant.completed", {"completed": False}),
                      ("assistant.completed", {"partial": True})]:
            self.assertFalse(successful(wire([("run.completed", {}), extra])))
        self.assertTrue(successful(wire([("assistant.completed", {"completed": True}), ("run.completed", {})])))

    def test_legacy_marker_must_be_reassembled_from_deltas(self):
        t = wire([("message", {"choices": [{"delta": {"content": s}}]}) for s in ["QA-", "LEGACY-", "✓"]])
        self.assertNotIn("QA-LEGACY-✓", t["body"])
        self.assertEqual("".join(o["choices"][0]["delta"]["content"] for _, o in objects(t)), "QA-LEGACY-✓")

    def test_turn_budget_refuses_before_network(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            "HERMES_BASE_URL": "http://127.0.0.1:8742", "HERMES_MODEL": "QA-model", "HERMES_API_KEY": "QA-secret"}):
            s = BehaviorSuite(Path(directory) / "QA-results")
            s.turns = 28
            with patch("live_behavior.http.client.HTTPConnection") as conn:
                with self.assertRaises(RuntimeError):
                    s.request("QA-over-budget", "/v1/runs", "POST", {"input": "QA-test"})
                conn.assert_not_called()

    def test_usage_refuses_non_QA_before_database_access(self):
        with patch("live_usage.sqlite3.connect") as conn:
            with self.assertRaises(ValueError):
                snapshot(Path("QA-not-opened.db"), ["production"])
            conn.assert_not_called()

    def test_usage_reads_exact_owned_ids_and_does_not_modify_database(self):
        with tempfile.TemporaryDirectory() as directory:
            db = Path(directory) / "QA-state.db"
            with sqlite3.connect(db) as conn:
                conn.execute("CREATE TABLE sessions (id TEXT, model TEXT, api_call_count INT, tool_call_count INT, input_tokens INT, output_tokens INT, cache_read_tokens INT, reasoning_tokens INT)")
                conn.executemany("INSERT INTO sessions VALUES (?, 'QA-model', 2, 0, 10, 1, 0, 0)", [("QA-owned",), ("QA-other",), ("production",)])
            before = db.read_bytes()
            self.assertEqual([r["id"] for r in snapshot(db, ["QA-owned"])], ["QA-owned"])
            self.assertEqual(db.read_bytes(), before)
