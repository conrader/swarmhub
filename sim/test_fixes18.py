"""Pre-release regressions: pure goal text, synthetic SQLite records and stubbed execution only."""
import json
import os
from pathlib import Path
import runpy
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

try:
    from sim.goal_run import GoalRun
except ImportError:
    from goal_run import GoalRun

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Resources/Skills/swarmhub-messages/scripts"))
import swarm_jobs as jobs
import swarm_policy as policy
from swarm_store import canonical, database


class GoalVisibilityTests(unittest.TestCase):
    def test_start_and_status_cover_auto_and_explicit_modes_with_swift_expectations(self):
        cases = [
            ("fix the failing build", "Evidence: coding (auto; commit or test pass + report required).", None),
            ("write the changelog", "Evidence: general (auto; chat deliverable; coding evidence not required).", None),
            ("--coding write the changelog", "Evidence: coding (explicit; commit or test pass + report required).", True),
            ("--general fix the failing build", "Evidence: general (explicit; chat deliverable; coding evidence not required).", False),
        ]
        swift = (ROOT / "Tests/AgentAppTests/GoalTests.swift").read_text()
        for command, expected, override in cases:
            with self.subTest(command=command):
                goal = GoalRun.from_command(command)
                self.assertIs(goal.coding_evidence, override)
                self.assertIn(expected, goal.start_notice)
                self.assertIn(expected, goal.status(60))
                self.assertIn('"' + expected + '"', swift)
                self.assertIn('"' + command + '"', swift)
                for notice in (goal.start_notice, goal.status(60)):
                    self.assertIn("To override, /goal clear, then /goal --coding <text> or /goal --general <text>.", notice)

    def test_restored_legacy_goal_and_offline_status_keep_auto_mode(self):
        goal = GoalRun(**json.loads('{"text":"fix the failing build"}'))
        goal.state, goal.paused_offline = "paused", True
        goal.subgoals, goal.need, goal.last_summary = ["keep API stable"], "test evidence", "work in progress"
        status = goal.status(120)
        self.assertIn("Paused (offline) · round 0/20 · 2 min of 120", status)
        self.assertIn("Evidence: coding (auto;", status)
        self.assertTrue(status.endswith("  1. keep API stable\nNeeds: test evidence\nLast: work in progress"))

    def test_swift_start_and_status_use_the_same_display_before_advancing(self):
        # Wiring check complements the native behavioural test; it is not a Swift execution claim.
        source = (ROOT / "Sources/AgentApp/Stores/AppStore+Goals.swift").read_text()
        start = source.split("func startGoal(", 1)[1].split("func resumeGoal(", 1)[0]
        self.assertLess(start.index("goal.evidenceStatus"), start.index("advanceGoal("))
        self.assertIn("lines.append(goal.evidenceStatus)", source)


class LegacyOutboundTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        env = patch.dict(os.environ, HOME=str(self.home), HERMES_HOME=str(self.home / ".hermes/profiles/owner"))
        env.start()
        self.addCleanup(env.stop)
        for profile in ("worker", "owner"):
            (self.home / ".hermes/profiles" / profile).mkdir(parents=True)
        # Never executable: the positive-path Popen is also a spy, so outbound stays fake in every test.
        self.hook = ["/synthetic/never-executed-sender", "--channel", "fake"]
        policy.publish({"owner": "owner", "coordinator": "owner", "outbound": self.hook})
        spawn_patch = patch.object(jobs.subprocess, "Popen")
        self.spawn = spawn_patch.start()
        self.addCleanup(spawn_patch.stop)
        self.spawn.return_value = Mock(returncode=0, poll=Mock(return_value=0))

    def legacy(self, **changes):
        spec = {"bot": "worker", "intent": "legacy-draft", "kind": "outbound", "to": "alice",
                "text": "literal $(not-a-command) draft", "argv": self.hook +
                ["--to", "alice", "--text", "literal $(not-a-command) draft"]}
        spec.update(changes)
        ident = "task.legacy"
        # Insert a pre-upgrade pending row directly, bypassing modern admission validation.
        with database() as db:
            db.execute("INSERT INTO actions(id,intent,spec,fingerprint,gate,status,created) VALUES(?,?,?,?,?,?,?)",
                       (ident, spec["intent"], canonical(spec), policy.operation_fingerprint(spec),
                        "coordinator", "awaiting-coordinator", 0))
        policy.decide(ident, "owner", True)
        with database() as db:
            db.execute("UPDATE actions SET status='running' WHERE id=?", (ident,))
        return ident

    def refused(self, ident):
        jobs.run_action(ident)
        self.spawn.assert_not_called()
        self.assertEqual(policy.action(ident)["status"], "failed")
        self.assertEqual(policy.action(ident)["error"], "Outbound sender/draft binding failed; resubmit for approval")

    def test_legacy_arbitrary_command_is_refused_after_approval(self):
        self.refused(self.legacy(argv=["/bin/sh", "-c", "synthetic-never-executed"]))

    def test_legacy_recipient_mismatch_is_refused(self):
        self.refused(self.legacy(to="mallory"))

    def test_legacy_text_mismatch_is_refused(self):
        self.refused(self.legacy(text="different draft"))

    def test_legacy_missing_or_malformed_draft_is_refused(self):
        self.refused(self.legacy(to=None))

    def test_hook_changed_after_approval_is_refused_without_rebinding(self):
        ident = self.legacy()
        policy.publish({"outbound": ["/synthetic/different-sender"]})
        self.refused(ident)

    def test_missing_sender_fails_closed(self):
        ident = self.legacy()
        policy.publish({"outbound": None})
        self.refused(ident)

    def test_exact_binding_reaches_only_the_mock_sender(self):
        ident = self.legacy()
        jobs.run_action(ident)
        self.spawn.assert_called_once_with(self.hook + ["--to", "alice", "--text", "literal $(not-a-command) draft"],
                                           stdin=jobs.subprocess.DEVNULL, stdout=jobs.subprocess.DEVNULL,
                                           stderr=jobs.subprocess.DEVNULL)
        self.assertEqual(policy.action(ident)["status"], "done")

    def test_legacy_fake_never_executes_even_a_stored_arbitrary_command(self):
        ident = self.legacy(fake=True, argv=["/bin/sh", "-c", "synthetic-never-executed"])
        jobs.run_action(ident)
        self.spawn.assert_not_called()
        self.assertEqual(policy.action(ident)["error"], "FAKE: no outbound operation executed")


class ScratchCleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sweep = runpy.run_path(str(ROOT / "Resources/Skills/swarmhub-coding/scripts/scratch.py"))["sweep"]
        self.now = time.time()

    def entry(self, name, old=True):
        directory = self.root / name
        directory.mkdir()
        (directory / "snapshot").write_text("synthetic launcher evidence")
        when = self.now - (90000 if old else 60)
        os.utime(directory, (when, when))
        return directory

    def test_only_old_dead_launcher_entries_are_removed(self):
        old = self.entry("code-job.23456.ABC123")
        recent = self.entry("code-job.23456.DEF123", old=False)
        legacy = self.entry("code-job.ABC123")
        unrelated = self.entry("other.23456.ABC123")
        with patch("os.kill", side_effect=ProcessLookupError) as probe:
            self.sweep(self.root, self.now)
        probe.assert_called_once_with(23456, 0)
        self.assertFalse(old.exists())
        self.assertTrue(all(p.exists() for p in (recent, legacy, unrelated)))

    def test_live_and_permission_denied_launchers_are_retained(self):
        directory = self.entry("code-job.23456.ABC123")
        for outcome in (None, PermissionError(), OSError("uncertain")):
            with self.subTest(outcome=outcome), patch("os.kill", side_effect=outcome):
                self.sweep(self.root, self.now)
                self.assertTrue(directory.exists())

    def test_symlinks_files_and_invalid_pids_are_never_followed_or_removed(self):
        target = self.entry("target")
        link = self.root / "code-job.23456.ABC123"
        link.symlink_to(target, target_is_directory=True)
        file = self.root / "code-job.23456.DEF123"
        file.write_text("not a directory")
        invalid = [self.entry("code-job.0.ABC123"), self.entry("code-job.1.ABC123"),
                   self.entry("code-job.9999999999.ABC123")]
        with patch("os.kill") as probe:
            self.sweep(self.root, self.now)
        probe.assert_not_called()
        self.assertTrue(link.is_symlink() and (target / "snapshot").exists() and file.exists())
        self.assertTrue(all(p.exists() for p in invalid))

    def test_new_scratch_is_cleaned_on_early_exit_and_swept_after_hard_kill(self):
        # HOME must be outside /tmp to exercise the private scratch location rather than its /tmp fallback.
        outside = tempfile.TemporaryDirectory(prefix=".fixes18-scratch-", dir=ROOT)
        self.addCleanup(outside.cleanup)
        home = Path(outside.name).resolve()
        if Path('/tmp').resolve() in home.parents:
            self.skipTest("checkout is under /tmp; private scratch integration needs a separate root")
        scripts = self.root / "isolated/scripts"
        shutil.copytree(ROOT / "Resources/Skills/swarmhub-coding/scripts", scripts)
        original = (scripts / "code-job").read_text()
        # Fault injection immediately after scratch setup, before the old late EXIT trap or any coding CLI.
        prefix = original.split("\nSLOT=", 1)[0]
        argv = ["/bin/sh", str(scripts / "code-job"), "--bot", "QA", "--order", "codex", "--dir", str(self.root),
                "--model", "synthetic", "--report", "REPORT.txt", "--", "synthetic task"]
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp"}
        scratch_file = home / "scratch-used"
        for ending, expected in (("exit 19", 19), ("kill -KILL $$", -signal.SIGKILL)):
            (scripts / "code-job").write_text(prefix + '\nprintf "%s" "$T" > "$HOME/scratch-used"\n' + ending + '\n')
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, expected, result.stderr)
            used = Path(scratch_file.read_text())
            self.assertEqual(used.parent, home / ".hermes/swarmhub/scratch")
            self.assertEqual(used.exists(), expected < 0)
        os.utime(used, (self.now - 90000, self.now - 90000))
        (scripts / "code-job").write_text(prefix + "\nexit 19\n")
        result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 19, result.stderr)
        self.assertFalse(used.exists(), "next startup must sweep the old SIGKILL orphan")
        self.assertEqual(list(used.parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
