"""Offline chain tests: synthetic model replies/job receipts, real local git/builds.

These fixtures are never used by the live harness. No provider or socket calls.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock

from live_chains import ACTION_RULES, digest, parse_action
from live_cli import qa_git_env, qa_repo
from live_managed import ManagedSuite


def trace(target, text, reply):
    return {"name": "QA-test-receiver", "path": "/sessions/QA-" + target + "/chat/stream",
            "request_body": json.dumps({"input": text}), "status": 200,
            "body": 'event: assistant.completed\ndata: ' + json.dumps({"content": json.dumps(reply)}) +
                    '\n\nevent: run.completed\ndata: {}\n\n'}


class OfflineChain(ManagedSuite):
    """Emulates provider/job boundaries only; executes actual bounded git/verifier ops."""
    def __init__(self, root):
        self.temp, self.output = root, root / "results"
        self.output.mkdir()
        self.repo = qa_repo(root / "repo", writable_git=True)
        self.child_env = qa_git_env(self.repo, {"PATH": "/usr/bin:/bin", "HOME": str(root), "PYTHONDONTWRITEBYTECODE": "1"})
        self.cli, self.model, self.home = {"agent": "codex"}, "QA-model", root / "home"
        self.init_chain_verifier()
        self.traces, self.chain_steps, self.jobs, self.submitted, self.operations = [], [], {}, [], []
        self.admissions = []
        self.result, self.snapshot = Mock(), Mock()
        self.reject_review, self.bad_choice, self.fail_rebuild = False, False, False

    def clean(self, value):
        return value

    def command(self, label, argv, **kwargs):
        self.operations.append(label)
        proc = subprocess.run(argv, env=self.child_env, capture_output=True, text=True, timeout=10)
        if proc.returncode:
            raise ValueError(label + ": " + proc.stderr)
        return proc.stdout.strip()

    def decoded_ctl(self, label, *args, payload=None):
        self.admissions.append(args)
        self.assert_no_preload = len(self.submitted) == 0 or any(e["label"] == "P01-ordering-commit-rebuilt"
                                                               for e in getattr(self, "chain_events", []))
        self.submitted.append(payload)
        ident = "task." + str(len(self.submitted))
        intent = payload["intent"]
        report = Path(payload["report"])
        before = self.local_git("fixture-head-before", "rev-parse", "HEAD")
        if intent == "QA-P04-empty":
            fields = {"status": "failed", "exit": "65", "cli-exit": "0", "report-valid": "false",
                      "report": str(report), "model": self.model, "effort": "high"}
            reply = {"op": "correct", "job": ident.replace("task.", "job."), "model": self.model,
                     "effort": "high", "instruction": "Relaunch with explicit model/high, verify fresh file and tests before reporting."}
        else:
            source = self.repo / "qa_work.py"
            if intent == "QA-P01-first" or intent == "QA-P04-corrected":
                source.write_text("def add(a, b):\n    return a + b\n")
            else:
                mode = intent.rsplit("-", 1)[1]
                with source.open("a") as output:
                    output.write(f"\ndef {mode}(a, b):\n    return a {'*' if mode == 'multiply' else '-'} b\n")
            (self.repo / "NOTES.md").write_text(intent + " done\n")
            if "Do not commit:" not in payload["task"]:
                self.local_git("fixture-stage", "add", "qa_work.py", "NOTES.md")
                self.local_git("fixture-commit", "commit", "-m", intent)
            report.write_text("Changed actual arithmetic implementation; local build/test command passed. " + intent)
            fields = {"status": "ok", "exit": "0", "cli-exit": "0", "model": self.model, "effort": "high",
                      "report": str(report), "report-valid": "true", "report-sha256": digest(report),
                      "head-before": before, "head-after": self.local_git("fixture-head-after", "rev-parse", "HEAD"),
                      "commit-evidence": "false" if "Do not commit:" in payload["task"] else "true",
                      "verify-exit": "0", "tests-passed": "true"}
            reply = ({"op": "relay", "job": ident.replace("task.", "job."),
                      "instruction": "Review the arithmetic fix, commit review, rebuild and choose next useful work."}
                     if intent == "QA-P01-first" else
                     {"op": "await_independent_check", "job": ident.replace("task.", "job.")})
        self.jobs[ident] = fields
        self.traces.append(trace("Jarvis", f"Completion {ident.replace('task.', 'job.')} {report}", reply))
        return ident

    def job_field(self, ident, name):
        return self.jobs[ident].get(name)

    def action_status(self, ident):
        return "failed" if self.jobs[ident]["status"] == "failed" else "done"

    def wait_job(self, ident):
        pass

    def msg(self, label, sender, target, text, *flags):
        if label == "P01-ordering-review":
            job = self.jobs["task.1"]
            reply = {"op": "review_commit_rebuild", "job": "task.1", "report_sha256": job["report-sha256"],
                     "head": job["head-after"], "review": "Reviewed add fix: subtraction became addition; signed and zero inputs pass."}
            if self.reject_review:
                reply = "NO_REPLY"
            if self.fail_rebuild:
                (self.repo / "qa_work.py").write_text("def add(a,b): return 0\n")
        elif label == "P01-ordering-pick-next":
            reply = {"op": "launch_next", "head": self.local_git("fixture-new-head", "rev-parse", "HEAD"),
                     "build_sha256": digest(self.output / "QA-P01-ordering-build.json"),
                     "next": "network-send" if self.bad_choice else "subtract"}
        elif label == "P04-deliver-actionable-correction":
            reply = {"op": "relaunch", "failed_job": "task.1", "model": self.model, "effort": "high"}
        elif label == "P04-verified-result-for-report":
            proof = self.chain_events[-1]
            reply = {"op": "report_success", "job": "task.2", "proof_sha256": proof["proof_sha256"],
                     "summary": "Fresh corrected report checked; compilation and two tests passed."}
        else:
            raise AssertionError("Unexpected message " + label)
        self.traces.append(trace(target.removeprefix("QA-"), text, reply))


class LiveChainTests(unittest.TestCase):
    def test_detached_metadata_and_index_are_writable_without_dot_git(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = OfflineChain(Path(temporary))
            self.assertFalse((suite.repo / ".git").exists())
            self.assertTrue((suite.repo / "QA-git-store/index").is_file())
            self.assertTrue((suite.repo / "QA-git-store").is_dir())
            self.assertNotEqual(suite.local_git("head", "rev-parse", "HEAD"), "")
            # Tests use the same explicit metadata path as real CLI tool shells.
            self.assertIn(str(suite.repo), suite.coding("QA-local")["task"])

    def test_p01_actual_relay_review_commit_build_then_bot_selected_submission(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = OfflineChain(Path(temporary))
            suite.p01_chain()
            self.assertEqual([s["intent"] for s in suite.submitted], ["QA-P01-first", "QA-P01-next-subtract"])
            self.assertTrue(suite.assert_no_preload)
            labels = [e["label"] for e in suite.chain_events]
            self.assertLess(labels.index("P01-Jarvis-relay"), labels.index("P01-ordering-reviewed"))
            self.assertLess(labels.index("P01-ordering-commit-rebuilt"), labels.index("P01-ordering-selected-next"))
            self.assertLess(labels.index("P01-ordering-commit-rebuilt"), labels.index("P01-next-launched-unasked"))
            commit = next(e for e in suite.chain_events if e["label"] == "P01-ordering-commit-rebuilt")
            self.assertNotEqual(commit["head_before"], commit["head_after"])
            self.assertEqual(suite.jobs["task.1"]["commit-evidence"], "false")
            self.assertEqual(suite.jobs["task.2"]["commit-evidence"], "true")
            committed = suite.local_git("test-ordering-commit", "show", commit["head_after"] + ":qa_work.py")
            self.assertIn("return a + b", committed)
            self.assertIn("Reviewed add fix", (suite.repo / "QA-REVIEW.md").read_text())
            self.assertEqual(json.loads((suite.output / "QA-P01-ordering-build.json").read_text())["tests_run"], 2)

    def test_p01_no_reply_invalid_choice_and_failed_rebuild_cannot_launch_next(self):
        for setting in ("reject_review", "bad_choice", "fail_rebuild"):
            with self.subTest(setting=setting), tempfile.TemporaryDirectory() as temporary:
                suite = OfflineChain(Path(temporary))
                setattr(suite, setting, True)
                with self.assertRaises(ValueError):
                    suite.p01_chain()
                self.assertEqual(len(suite.submitted), 1)

    def test_p04_real_job_boundary_correction_relaunch_check_before_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = OfflineChain(Path(temporary))
            suite.p04_chain()
            self.assertEqual([s["intent"] for s in suite.submitted], ["QA-P04-empty", "QA-P04-corrected"])
            self.assertEqual(suite.admissions, [("submit",), ("replace", "task.1")])
            self.assertEqual((suite.submitted[1]["model"], suite.submitted[1]["effort"]), ("QA-model", "high"))
            self.assertNotEqual(suite.submitted[0]["report"], suite.submitted[1]["report"])
            labels = [e["label"] for e in suite.chain_events]
            self.assertLess(labels.index("P04-success-report-held-for-check"),
                            labels.index("P04-fresh-output-independently-verified"))
            self.assertLess(labels.index("P04-fresh-output-independently-verified"),
                            labels.index("P04-success-after-independent-check"))

    def test_independent_check_rejects_stale_report_missing_commit_or_failed_tests(self):
        for field, value in (("report-sha256", "stale"), ("commit-evidence", "false"),
                             ("tests-passed", "false"), ("cli-exit", "69")):
            with self.subTest(field=field), tempfile.TemporaryDirectory() as temporary:
                suite = OfflineChain(Path(temporary))
                ident = suite.decoded_ctl("fixture", "submit", payload=suite.coding("QA-P01-first"))
                suite.jobs[ident][field] = value
                with self.assertRaises(ValueError):
                    suite.independent_check("QA-check", ident, "QA-P01-first")
                self.assertFalse((suite.output / "QA-check-build.json").exists())

    def test_real_verifier_compiles_and_rejects_wrong_code_even_with_passing_job_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = OfflineChain(Path(temporary))
            ident = suite.decoded_ctl("fixture", "submit", payload=suite.coding("QA-P01-first"))
            (suite.repo / "qa_work.py").write_text("def add(a,b): return a-b\n")
            with self.assertRaises(ValueError):
                suite.independent_check("QA-check", ident, "QA-P01-first")
            self.assertFalse(json.loads((suite.output / "QA-check-build.json").read_text())["passed"])

    def test_actions_reject_wrong_bindings_unknown_ops_and_prose(self):
        for reply in ('NO_REPLY', 'Here is {"op":"relaunch"}', '{"op":"send"}',
                      '{"op":"relaunch","model":"default"}', '[]'):
            with self.subTest(reply=reply), self.assertRaises(ValueError):
                parse_action(reply, "relaunch", {"model": "explicit", "effort": "high"})

    def test_action_is_consumed_once_and_failed_receiving_turn_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = OfflineChain(Path(temporary))
            suite.arm_step("QA-Swarmhub", "token", "request relay")
            suite.traces.append(trace("Swarmhub", "token", {"op": "relay", "job": "job.1"}))
            suite.traces[-1]["body"] += 'event: run.failed\ndata: {}\n\n'
            with self.assertRaises(ValueError):
                suite.model_action("QA-action", "QA-Swarmhub", "token", "relay", {"job": "job.1"})
            suite.traces.pop()
            suite.traces.append(trace("Swarmhub", "token", {"op": "relay", "job": "job.1"}))
            suite.model_action("QA-action", "QA-Swarmhub", "token", "relay", {"job": "job.1"})
            with self.assertRaises(ValueError):
                suite.model_action("QA-action", "QA-Swarmhub", "token", "relay", {"job": "job.1"})

    def test_action_rules_replace_passive_rules_only_for_armed_role_and_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = OfflineChain(Path(temporary))
            suite.arm_step("QA-Jarvis", "QA-P01-first.txt", "relay this")
            self.assertTrue(suite.chain_rules("QA-Jarvis", "receipt QA-P01-first.txt").startswith(ACTION_RULES))
            self.assertIsNone(suite.chain_rules("QA-Infra", "receipt QA-P01-first.txt"))
            self.assertIsNone(suite.chain_rules("QA-Jarvis", "unrelated"))

    def test_failed_chain_stops_its_work_disarms_and_allows_other_chain(self):
        with tempfile.TemporaryDirectory() as temporary:
            suite = OfflineChain(Path(temporary))
            suite.ctl = Mock()
            suite.action_status = Mock(return_value="failed")

            def failed():
                suite.chain_jobs.append("task.failed")
                suite.arm_step("QA-Jarvis", "failed", "relay")
                raise ValueError("No new HEAD")

            suite.run_chain("P01-full-chain", failed)
            suite.ctl.assert_called_once_with("P01-full-chain-stop-task.failed", "stop", "task.failed")
            self.assertEqual(suite.chain_steps, [])
            suite.result.assert_any_call("P01-full-chain", False, "No new HEAD")
            other = Mock()
            suite.run_chain("P04-full-chain", other)
            other.assert_called_once()


if __name__ == "__main__":
    unittest.main()
