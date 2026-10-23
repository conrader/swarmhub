#!/usr/bin/env python3
"""Routines and connector requests in export-grokbot.py bundles (scripts/grokbot_staged.py). Synthetic entries only;
GrokRoutinesImportTests.swift checks the same vectors on the native builder."""
import hashlib
import importlib.util
import json
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("export_grokbot", os.path.join(HERE, "export-grokbot.py"))
exporter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exporter)

BOT = "00000000-0000-4000-8000-0000000000aa"
TOKEN = "FAKETOKENVALUE1234"


def automation(seq, action, automation_id, name=None):
    event = {"type": "automation-changed", "action": action, "automationId": automation_id}
    if name is not None:
        event["automationName"] = name
    return {"kind": "event", "id": "e%d" % seq, "seq": seq, "timestampMs": 1760000000000 + seq, "event": event}


def connector(seq, name=None):
    message = {"type": "connector", "serverId": "srv-SECRETSERVER9", "variant": "connect",
               "reauth": {"accountKey": "acct-FAKEACCOUNTKEY77"}}
    if name is not None:
        message["connector"] = name
    return {"kind": "send-message", "id": "c%d" % seq, "seq": seq, "requestId": "r%d" % seq, "message": message}


ENTRIES = [
    automation(1, "created", "a1", "Morning"),
    automation(2, "created", "a2", "Old"),
    automation(3, "updated", "a1", "Morning brief"),
    automation(4, "deleted", "a2", "Old"),
    automation(5, "disabled", "a3", "Night"),
    automation(6, "enabled", "a3"),
    automation(7, "created", "a4", "Deploy Bearer " + TOKEN),
    {"kind": "event", "id": "e8", "seq": 8, "event": {"type": "automation-changed", "action": "created"}},
    connector(9, "GoogleDrive"), connector(10, "google_drive"), connector(11, "googledrive"), connector(12, "Slack"),
    connector(13, "Bearer " + TOKEN), connector(14),
]


def build(entries):
    row = {"id": BOT, "name": "Atlas"}
    return exporter.build_bundle(row, entries, {BOT: "Atlas"}, {BOT: "atlas"})


class StagedTests(unittest.TestCase):
    def test_routines_latest_state_wins_deleted_skipped_never_enabled(self):
        bundle = build(ENTRIES)
        routines = bundle["routines"]
        self.assertEqual([r["id"] for r in routines],
                         ["grok-automation-" + hashlib.sha256(i.encode()).hexdigest()[:24] for i in ("a1", "a3", "a4")])
        self.assertEqual([r["name"] for r in routines[:2]], ["Morning brief", "Night"])
        self.assertIn("[REDACTED]", routines[2]["name"])
        for routine in routines:
            self.assertEqual({k: routine[k] for k in ("prompt", "schedule", "trigger", "timezone", "enabled")},
                             {"prompt": "", "schedule": None, "trigger": None, "timezone": None, "enabled": False})
        self.assertEqual(bundle["statistics"]["events_dropped"], 1)  # the event without an automationId
        self.assertIn(exporter.ROUTINES_LIMITATION, bundle["limitations"])
        self.assertEqual(bundle["memory_facts"], [])  # Grok Bot has no memory source

    def test_connectors_are_names_only(self):
        bundle = build(ENTRIES)
        self.assertEqual(bundle["connectors"], [{"name": "googledrive"}, {"name": "google-drive"}, {"name": "slack"}])
        self.assertEqual(bundle["statistics"]["cards_dropped"], 1)  # the card without a connector
        self.assertIn(exporter.CONNECTORS_LIMITATION, bundle["limitations"])
        text = json.dumps(bundle)
        for secret in (TOKEN, "SECRETSERVER9", "FAKEACCOUNTKEY77", "accountKey", "serverId", '"a1"', '"a4"'):
            self.assertNotIn(secret, text)
        self.assertGreaterEqual(bundle["redactions"]["total"], 2)

    def test_a_conversation_without_automations_keeps_empty_lists(self):
        bundle = build([{"kind": "message", "id": "m1", "seq": 1, "role": "user", "content": "hi"}])
        self.assertEqual((bundle["routines"], bundle["connectors"]), ([], []))
        self.assertNotIn(exporter.ROUTINES_LIMITATION, bundle["limitations"])


if __name__ == "__main__":
    unittest.main()
