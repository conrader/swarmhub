"""Cross-review finding 4: coding jobs wait for the owner by default, and Claude Code never runs unapproved.

Synthetic CLIs and local records only; no gateway, provider or outbound operation.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import test_peer_runtime as boundary
import test_patterns as patterns

control = boundary.peer.control
SCRIPTS = boundary.RUNTIME.parent


class CodingGateTests(unittest.TestCase):
    stop_background = boundary.PeerTests.stop_background
    sync = boundary.PeerTests.sync
    eventually = boundary.PeerTests.eventually
    cli = patterns.ObservedPatternTests.cli
    spec = patterns.ObservedPatternTests.spec
    submit = patterns.ObservedPatternTests.submit
    job = patterns.ObservedPatternTests.job

    def setUp(self):
        boundary.PeerTests.setUp(self)
        # The shared fixture opts into the automatic Codex route; these tests start from the shipped default.
        control.publish({"coding_gate": "owner"})

    def owner_decides(self, ident, approved=True):
        row = control.action(ident)
        control.publish({"owner": "coordinator"})
        with patch.dict(os.environ, HERMES_HOME=str(self.home / ".hermes/profiles/coordinator")):
            control.decide(ident, "coordinator", approved, row["fingerprint"], row["gate"])

    def test_shipped_default_gates_coding_at_owner_and_rejects_other_values(self):
        with tempfile.TemporaryDirectory() as fresh:
            code = "import swarm_policy; print(swarm_policy.policy()['coding_gate'])"
            result = subprocess.run([sys.executable, "-B", "-c", code], cwd=SCRIPTS, capture_output=True, text=True,
                                    env={"HOME": fresh, "PATH": "/usr/bin:/bin", "PYTHONDONTWRITEBYTECODE": "1"}, timeout=20)
        self.assertEqual(result.stdout.strip(), "owner", result.stderr)
        with self.assertRaisesRegex(ValueError, "coding_gate"):
            control.publish({"coding_gate": "anyone"})
        self.assertEqual(control.policy()["coding_gate"], "owner")

    def test_codex_job_waits_for_the_owner_then_runs_after_the_bound_decision(self):
        self.cli()
        ident = self.submit("owner-gated-codex")
        row = control.action(ident)
        self.assertEqual((row["gate"], row["status"]), ("owner", "awaiting-owner"))
        control.tick()
        self.assertFalse(self.job(ident).exists(), "an undecided coding task must not launch")
        self.assertFalse((self.home / "codex.args").exists())
        self.owner_decides(ident)
        self.assertEqual(control.action(ident)["status"], "queued")
        control.tick()
        self.eventually(lambda: (self.job(ident) / "ready").exists())
        self.assertEqual((self.job(ident) / "status").read_text().strip(), "ok")
        self.assertTrue((self.home / "codex.args").exists())

    def test_owner_opt_in_makes_codex_automatic_but_claude_orders_still_wait(self):
        control.publish({"coding_gate": "auto"})
        self.assertEqual(control.action(self.submit("auto-codex", order="codex"))["status"], "queued")
        for order in ("claude", "claude,codex", "codex,claude,hermes"):
            with self.subTest(order=order):
                row = control.action(self.submit("gated-" + order.replace(",", "-"), order=order))
                self.assertEqual((row["gate"], row["status"]), ("owner", "awaiting-owner"))
        self.assertEqual(control.action(self.submit("auto-hermes", order="codex,hermes"))["status"], "queued")

    def test_owner_approved_claude_job_runs_claude_bound_to_its_record(self):
        self.cli()
        ident = self.submit("approved-claude", order="claude,codex")
        self.assertEqual(control.action(ident)["status"], "awaiting-owner")
        self.owner_decides(ident)
        control.tick()
        self.eventually(lambda: (self.job(ident) / "ready").exists())
        self.assertEqual((self.job(ident) / "agent").read_text().strip(), "claude")
        self.assertEqual((self.job(ident) / "status").read_text().strip(), "ok")
        args = (self.home / "claude.args").read_text()
        self.assertIn("--permission-mode\nacceptEdits\n", args)
        self.assertFalse((self.home / "codex.args").exists())

    def test_denied_claude_job_never_launches(self):
        self.cli()
        ident = self.submit("denied-claude", order="claude")
        self.owner_decides(ident, approved=False)
        self.assertEqual(control.action(ident)["status"], "denied")
        control.tick()
        self.assertFalse(self.job(ident).exists())
        self.assertFalse((self.home / "claude.args").exists())

    def test_check_job_refuses_claude_for_a_record_without_an_owner_decision(self):
        self.cli()
        ident = self.submit("legacy-claude", order="claude")
        spec = json.loads(control.action(ident)["spec"])
        spec["report"] = str(Path(spec["directory"]) / spec["report"])  # code-job passes the resolved report path
        # A record admitted before this rule (or tampered with) carries gate auto and no decision.
        with control.database() as db:
            db.execute("UPDATE actions SET gate='auto', status='queued' WHERE id=?", (ident,))
        with self.assertRaisesRegex(ValueError, "owner-approved"):
            control.check_job(ident, spec["bot"], spec["directory"], spec["model"], spec["effort"], spec["report"],
                              spec["task"], "claude", spec["verify"])
        # The launcher refuses (exit 125) before any completion record exists; the next tick marks it failed.
        self.eventually(lambda: (control.tick(), control.action(ident)["status"] == "failed")[1])
        self.assertFalse((self.home / "claude.args").exists())
        # The same record, decided by the owner, passes the check.
        with control.database() as db:
            db.execute("UPDATE actions SET gate='owner', decided_by='coordinator', status='queued' WHERE id=?", (ident,))
        control.check_job(ident, spec["bot"], spec["directory"], spec["model"], spec["effort"], spec["report"],
                          spec["task"], "claude", spec["verify"])

    def test_direct_code_job_skips_claude_for_approval_and_falls_through(self):
        self.cli()
        result = subprocess.run(["/bin/sh", str(boundary.JOB), "--bot", "worker", "--origin", "sender", "--order",
                                 "claude,codex", "--dir", str(self.home), "--model", "synthetic-model", "--effort",
                                 "high", "--report", "REPORT.txt", "--", "implement requested work"],
                                env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("skipped claude: approval", result.stderr)
        self.assertFalse((self.home / "claude.args").exists())
        self.assertTrue((self.home / "codex.args").exists())


if __name__ == "__main__":
    unittest.main()
