#!/usr/bin/env python3
"""Unit tests for export-grokbot.py. Synthetic fixtures only (Tests/Fixtures/grok-cache)."""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import stat
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "Tests", "Fixtures", "grok-cache")
spec = importlib.util.spec_from_file_location("export_grokbot", os.path.join(HERE, "export-grokbot.py"))
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

def read_json(path):
    with open(path) as handle:
        return json.load(handle)


JARVIS = "00000000-0000-4000-8000-000000000001"
GROUP = "00000000-0000-4000-8000-000000000004"


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.out = os.path.join(self.tmp, "SwarmHub Grok Export")

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def test_default_out_prefers_swarmhub_and_falls_back_to_the_torvli_folder(self):
        docs = os.path.join(self.tmp, "Documents")
        new, old = os.path.join(docs, "SwarmHub Grok Export"), os.path.join(docs, "Torvli Grok Export")
        self.assertEqual(exporter.default_out(self.tmp), new)
        os.makedirs(old)
        self.assertEqual(exporter.default_out(self.tmp), old)
        os.makedirs(new)
        self.assertEqual(exporter.default_out(self.tmp), new)

    def run_export(self):
        with contextlib.redirect_stdout(io.StringIO()) as printed:
            self.assertEqual(exporter.main(["--cache", FIXTURE, "--out", self.out]), 0)
        return printed.getvalue()

    def bundle(self, source_id):
        index = read_json((os.path.join(self.out, "index.json")))
        entry = next(b for b in index["bots"] if b["source_id"] == source_id)
        return read_json((os.path.join(self.out, entry["bundle"])))

    def test_decodes_base32_names(self):
        name = [n for n in os.listdir(FIXTURE) if exporter.decode_name(n) and exporter.decode_name(n).endswith("last-roster")]
        self.assertEqual(len(name), 1)
        self.assertIsNone(exporter.decode_name("!!!.blob"))

    def test_index_and_profiles(self):
        self.run_export()
        index = read_json((os.path.join(self.out, "index.json")))
        self.assertEqual(index["format"], "agentapp-bot-bundle/v1")
        profiles = {b["name"]: b["profile"] for b in index["bots"]}
        self.assertEqual(profiles["Jarvis"], "grok-jarvis")
        self.assertEqual(profiles["Finance Controller"], "grok-finance-controller")
        self.assertIsNone(profiles["Konrad, Jarvis, Plain Bot"])

    def test_message_mapping_order_and_drops(self):
        self.run_export()
        bundle = self.bundle(JARVIS)
        self.assertEqual([m["id"] for m in bundle["messages"]], ["j1", "j2", "j3", "j4", "j5", "j9", "j10", "j12"])
        self.assertEqual([m["seq"] for m in bundle["messages"]], sorted(m["seq"] for m in bundle["messages"]))
        roles = {m["id"]: (m["role"], m["channel"], m["author"], m["to"]) for m in bundle["messages"]}
        self.assertEqual(roles["j1"], ("user", "chat", None, None))
        self.assertEqual(roles["j2"], ("assistant", "chat", "Jarvis", None))
        self.assertEqual(roles["j3"], ("assistant", "agent", "Jarvis", "Finance Controller"))
        self.assertEqual(roles["j4"], ("assistant", "agent", "Finance Controller", "Jarvis"))
        self.assertEqual(roles["j9"][0], "system")
        stats = bundle["statistics"]
        self.assertEqual(stats["cards_dropped"], 1)
        self.assertEqual(stats["events_dropped"], 1)
        self.assertEqual(stats["tool_entries_dropped"], 1)
        self.assertTrue(bundle["messages"][0]["timestamp"].endswith("Z"))

    def test_hidden_prompt_flagged_not_dropped(self):
        self.run_export()
        hidden = [m for m in self.bundle(JARVIS)["messages"] if m["hidden"]]
        self.assertEqual([m["id"] for m in hidden], ["j10"])

    def test_rename_event(self):
        self.run_export()
        events = self.bundle(JARVIS)["events"]
        self.assertEqual(events, [{"id": "j7", "seq": 7, "timestamp_ms": 1760000008000,
                                   "event": {"type": "name-changed", "from": "Jarv", "to": "Jarvis"}}])

    def test_secret_filter(self):
        self.run_export()
        bundle = self.bundle(JARVIS)
        text = json.dumps(bundle)
        self.assertNotIn("FAKETOKENVALUE1234", text)
        self.assertNotIn("FAKEFAKE1234", text)
        self.assertIn("[REDACTED]", bundle["description"])
        self.assertEqual(bundle["redactions"]["total"], 2)
        redact = exporter.Redactor()
        self.assertEqual(redact("x -----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n"), "x [REDACTED]")
        self.assertEqual(redact("AKIAABCDEFGHIJKLMNOP"), "[REDACTED]")
        self.assertEqual(redact("https://user:pw@example.invalid"), "https[REDACTED]example.invalid")
        self.assertEqual(redact("Authorization: Basic dXNlcjpwYXNz"), "[REDACTED]")
        self.assertEqual(redact("Basic aGVsbG8="), "Basic aGVsbG8=")  # no colon -> not a credential
        self.assertEqual(redact("plain words"), "plain words")

    def test_secret_filter_hardened_like_the_app(self):
        # Mirrors ImportRedactionTests.swift: case variants, wider AWS ids and encoded secrets.
        redact = exporter.Redactor()
        for text in ["akia1234567890abcdef", "ASIAABCDEFGHIJKLMNOP", "GITHUB_PAT_syntheticMarker1234567890",
                     "EyJsyntheticheader.syntheticpayload.syntheticsign", "XAPP-syntheticMarker123456",
                     "https://syntheticUser%3AsyntheticPass@example.invalid/feed", "c3ludGhldGljVXNlcjpzeW50aGV0aWNQYXNz"]:
            self.assertEqual(redact(text), "[REDACTED]", text)
        self.assertEqual(redact.counts, {"aws_key": 2, "github_pat": 1, "jwt": 1, "slack_app_token": 1, "encoded_credential": 2})
        prose = "Please use basic judgement; token gestures are welcome, 100% sure, a%20b."
        self.assertEqual(exporter.Redactor()(prose), prose)

    def test_secret_filter_is_linear_on_crafted_input(self):
        import time
        for text in ["token=abcdefgh " * 50000, "-eyJxxxxxxxx" * 50000, "a%zz" * 150000 + " %41"]:
            started = time.monotonic()
            exporter.Redactor()(text)
            self.assertLess(time.monotonic() - started, 2.0)

    def test_attachment_reference_is_safe(self):
        self.run_export()
        attachment = next(m for m in self.bundle(JARVIS)["messages"] if m["id"] == "j12")
        self.assertEqual(attachment["attachments"], [{"file": "attachments/report_final.pdf", "available": False}])
        self.assertNotIn("example.invalid", json.dumps(attachment))

    def test_group_members(self):
        self.run_export()
        group = self.bundle(GROUP)
        self.assertTrue(group["is_group"])
        self.assertEqual([m["name"] for m in group["members"]], ["Jarvis", "Plain Bot"])
        self.assertEqual([m["profile"] for m in group["members"]], ["grok-jarvis", "grok-plain-bot"])
        self.assertEqual([m["author"] for m in group["messages"]], [None, "Jarvis", "Plain Bot"])

    def test_empty_avatar_is_null(self):
        self.run_export()
        index = read_json((os.path.join(self.out, "index.json")))
        plain = next(b for b in index["bots"] if b["name"] == "Plain Bot")
        self.assertEqual(self.bundle(plain["source_id"])["avatar"], {"shape": None, "colour": None})

    def test_permissions(self):
        self.run_export()
        for root, dirs, files in os.walk(self.out):
            self.assertEqual(stat.S_IMODE(os.stat(root).st_mode), 0o700, root)
            for name in files:
                self.assertEqual(stat.S_IMODE(os.stat(os.path.join(root, name)).st_mode), 0o600, name)

    def test_prints_counts_only(self):
        printed = self.run_export()
        for secret in ["Hello Jarvis", "synthetic", "Ledger", "Pick one"]:
            self.assertNotIn(secret, printed)
        self.assertIn("messages=", printed)

    def test_reexport_replaces_atomically(self):
        self.run_export()
        marker = os.path.join(self.out, "stale.txt")
        open(marker, "w").close()
        self.run_export()
        self.assertFalse(os.path.exists(marker))
        self.assertEqual([n for n in os.listdir(self.tmp) if n.startswith(".")], [])

    def test_missing_cache_fails_without_output(self):
        with self.assertRaises(SystemExit):
            exporter.main(["--cache", os.path.join(self.tmp, "nope"), "--out", self.out])
        self.assertFalse(os.path.exists(self.out))


if __name__ == "__main__":
    unittest.main(verbosity=2)
