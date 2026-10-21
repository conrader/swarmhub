"""P01–P10 replay against shipped entrypoints; synthetic CLI/curl, no sockets/model calls."""
from datetime import datetime
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import test_peer_runtime as boundary

peer = boundary.peer
control = peer.control


class ObservedPatternTests(unittest.TestCase):
    setUp = boundary.PeerTests.setUp
    sync = boundary.PeerTests.sync
    requests = boundary.PeerTests.requests
    msg = boundary.PeerTests.msg
    turns = boundary.PeerTests.turns
    eventually = boundary.PeerTests.eventually
    completion = boundary.PeerTests.completion
    retry = boundary.PeerTests.retry
    stop_background = boundary.PeerTests.stop_background

    def decide(self, ident, actor, approved):
        # Decisions are verified against the invoking gateway (HERMES_HOME), never argv alone.
        with patch.dict(os.environ, {"HERMES_HOME": str(self.home / ".hermes/profiles" / actor)}):
            control.decide(ident, actor, approved)

    def cli(self):
        folder = self.home / "cli"
        folder.mkdir(exist_ok=True)
        script = '''#!/bin/sh
printf '%s\\n' "$@" > "$HOME/$(basename "$0").args"
echo $$ > "$HOME/$(basename "$0").pid"
case "$*" in *slow*)
  touch "$HOME/cli-started"
  sleep 30 & echo $! > "$HOME/cli-child"
  wait ;;
esac
case "$*" in *no-report*) PATTERN_MODE=missing ;; esac
if [ "${PATTERN_MODE:-ok}" != missing ] && [ "${PATTERN_MODE:-ok}" != empty ]; then
  printf 'verified work by %s\\n' "$$" > "$SWARMHUB_REPORT_FILE"
fi
[ "${PATTERN_MODE:-ok}" = empty ] || echo result
exit 0
'''
        for name in ("codex", "claude"):
            path = folder / name
            path.write_text(script)
            path.chmod(0o755)
        # POSIX shell builtin, independent of the platform location of true.
        # Trivial evidence for the other contract rules; the evidence gate itself is covered by test_gaps.py.
        self.env.update(PATH=str(folder) + ":" + self.env["PATH"], CODE_JOB_TICK="0.05", CODE_JOB_VERIFY="true")
        os.environ.update(self.env)

    def spec(self, intent, **changes):
        return dict({"bot": "worker", "origin": "sender", "intent": intent, "kind": "coding",
                     "task": intent, "directory": str(self.home), "order": "codex",
                     "model": "synthetic-model", "effort": "high", "report": intent + ".txt"}, **changes)

    def submit(self, intent, **changes):
        return control.submit(self.spec(intent, **changes))

    def job(self, ident):
        return peer.state() / "job-completions" / ident.replace("task.", "job.", 1)

    def code_job(self, *extra):
        # This is an end-to-end launcher, not a timed behavior assertion: policy checks, report hashing,
        # sandbox verification and wake startup each launch interpreters. The full parallel Swift suite can
        # starve those children past the old 12 s cap on macOS even though they finish correctly in isolation.
        # Keep a bounded hang guard, with enough room for that load; assert completion/exit evidence below.
        return subprocess.run(["/bin/sh", str(boundary.JOB), "--bot", "worker", "--origin", "sender",
                               "--order", "codex", "--dir", str(self.home), "--model", "synthetic-model",
                               "--effort", "high", "--report", "REPORT.txt", *extra, "--", "implement requested work"],
                              env=self.env, capture_output=True, text=True, timeout=60)

    def test_P01_result_next_step_standing_queue_and_receiver_dedupe(self):
        self.cli()
        first = self.submit("first")
        second = self.submit("second")
        control.tick()
        self.assertEqual(control.action(second)["status"], "queued")
        self.eventually(lambda: (self.job(first) / "ready").exists())
        control.tick()
        # A failed first job intentionally holds the queue. Diagnose its evidence
        # before waiting for a second job that would never be admitted.
        first_job = self.job(first)
        evidence = {key: (first_job / key).read_text().strip()
                    for key in ("status", "evidence", "verify-command", "verify-exit")}
        self.assertEqual(control.action(first)["status"], "done", evidence)
        self.eventually(lambda: (self.job(second) / "ready").exists())
        control.tick()
        self.assertEqual(control.action(first)["status"], "done")
        self.assertEqual(control.action(second)["status"], "done")
        self.eventually(lambda: (self.job(first) / "delivered").exists())
        # The second wake must have finished too, or its running receipt makes the session busy below.
        self.eventually(lambda: (self.job(second) / "delivered").exists())
        message = next(t[1]["input"] for t in self.turns() if self.job(first).name in t[1]["input"])
        self.assertIn("take the next step", message)
        self.assertIn("report exists: true", message)
        count = len(self.turns())
        (self.job(first) / "delivered").unlink()  # Sender lost its ACK; receiver retained it.
        self.retry(self.job(first))
        self.assertEqual(len(self.turns()), count)
        # Receiver post-turn commit wins even if the sending process crashes before its ACK.
        token = control.receipt_claim("sender", "job.lost-ack", "worker")
        self.assertNotIn(token, ("busy", "received"))
        self.assertEqual(control.receipt_claim("sender", "job.lost-ack", "worker"), "busy")
        peer.before_turn("sender", "swarmhub-from-worker", "result-turn", control.tagged("job.lost-ack", "same result"))
        peer.after_turn("sender", "swarmhub-from-worker", "result-turn", "NO_REPLY")
        self.assertEqual(control.deliver("worker", "sender", "same result", "job.lost-ack"), 0)
        self.assertEqual(len(self.turns()), count)

    def test_P02_bot_registration_and_unknown_origin_fallback(self):
        receipt = control.register("coordinator", coordinator=True)
        self.assertEqual(receipt["wake"], "profile-gateway")
        self.assertNotIn("synthetic-coordinator", json.dumps(receipt))
        self.assertIsNotNone(control.subscription("coordinator"))
        job = self.completion("missing-profile")
        self.retry(job)
        self.assertTrue((job / "delivered").exists())
        self.assertIn("/p/coordinator/", self.turns()[0][0])
        peer.install("recipient")
        self.assertTrue((self.home / ".hermes/profiles/recipient/plugins/swarmhub-peer/plugin.yaml").exists())
        # A recovery worker may inherit the terminal session that started it.
        # An explicitly unknown queued origin must still fall back, not borrow it.
        self.cli()
        os.environ["HERMES_SESSION_ID"] = "swarmhub-from-recipient"
        ident = self.submit("registered-fallback", origin="")
        control.tick()
        self.eventually(lambda: (self.job(ident) / "ready").exists())
        self.assertEqual((self.job(ident) / "origin").read_text().strip(), "")
        self.eventually(lambda: (self.job(ident) / "delivered").exists())
        actual = next(t for t in self.turns() if self.job(ident).name in t[1]["input"])
        self.assertIn("/p/coordinator/", actual[0])

    def test_P03_held_fyi_priority_action_and_quiet_reply(self):
        self.assertTrue(self.msg("--", "FYI held").stdout.startswith("held:"))
        self.assertEqual(self.turns(), [])
        context = peer.before_turn("recipient", "ordinary", "one")["context"]
        self.assertIn("FYI held", context)
        peer.after_turn("recipient", "ordinary", "one", "NO_REPLY")
        self.assertIsNone(peer.before_turn("recipient", "ordinary", "two"))
        self.assertEqual(self.msg("--priority", "--no-wait", "--", "do the requested action").returncode, 0)
        self.eventually(lambda: (peer.state() / "bot-messages.log").exists() and
                        "suppressed" in (peer.state() / "bot-messages.log").read_text())
        self.assertEqual(len(self.turns()), 1)

    def test_P04_explicit_execution_contract_rejects_empty_missing_and_stale_reports(self):
        self.cli()
        for mode in ("empty", "missing"):
            self.env["PATTERN_MODE"] = mode
            result = self.code_job()
            self.assertEqual(result.returncode, 65, result.stderr)
        self.env["PATTERN_MODE"] = "ok"
        result = self.code_job()
        self.assertEqual(result.returncode, 0, result.stderr)
        jobs = list((peer.state() / "job-completions").glob("job.*"))
        passed = next(j for j in jobs if (j / "status").read_text().strip() == "ok")
        self.assertEqual((passed / "cli-exit").read_text().strip(), "0")
        self.assertEqual((passed / "model").read_text().strip(), "synthetic-model")
        self.assertEqual((passed / "effort").read_text().strip(), "high")
        self.assertEqual((passed / "report-valid").read_text(), "true")
        args = (self.home / "codex.args").read_text()
        self.assertIn('--model\nsynthetic-model\n-c\nmodel_reasoning_effort="high"', args)
        self.env["PATTERN_MODE"] = "missing"  # Leaves the last good report untouched.
        self.assertEqual(self.code_job().returncode, 65)
        self.assertEqual(self.code_job("--model", "").returncode, 65)

    def test_P05_global_quota_subscriptions_and_job_admission(self):
        self.cli()
        for profile in ("worker", "recipient"):
            control.register(profile)
        rule = control.publish({"route": "codex", "codex_model": "synthetic-quota-model", "allow_speculative": False})
        update = peer.before_turn("recipient", "s", "t")["context"]
        self.assertIn('"route": "codex"', update)
        peer.after_turn("recipient", "s", "t", "NO_REPLY")
        self.assertIsNone(peer.before_turn("recipient", "s", "next"))
        self.assertEqual(control.subscription("worker")["revision"], rule["revision"])
        result = self.code_job("--order", "claude")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.home / "codex.args").exists())
        self.assertIn("synthetic-quota-model", (self.home / "codex.args").read_text())
        self.assertFalse((self.home / "claude.args").exists())
        self.assertEqual(self.code_job("--speculative").returncode, 77)
        with self.assertRaises(ValueError):
            self.submit("guess", speculative=True)

    def test_P06_priority_provisioning_owner_gate_and_secret_file_reference(self):
        control.publish({"owner": "sender", "coordinator": "coordinator"})
        secret_file = self.home / "qa-key"
        provision = self.home / "provision"
        provision.write_text("#!/bin/sh\numask 077\nprintf synthetic-key > \"$1\"\n")
        provision.chmod(0o755)
        ident = control.submit({"bot": "worker", "intent": "provision QA", "kind": "provision",
                                "risks": ["secrets"], "argv": [str(provision), str(secret_file)]})
        control.tick()
        self.assertFalse(secret_file.exists())
        with self.assertRaises(ValueError):
            self.decide(ident, "coordinator", True)
        self.decide(ident, "sender", True)
        control.tick()
        self.eventually(secret_file.exists)
        self.eventually(lambda: control.action(ident)["status"] == "done")
        self.assertEqual(secret_file.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("synthetic-key", json.dumps(control.action(ident)))

    def test_P07_final_denial_bound_outbound_scope_relaunch_and_peer_stop(self):
        self.cli()
        # fixes12: the outbound command comes from the owner's sender policy, never from the caller.
        control.publish({"owner": "sender", "coordinator": "coordinator", "outbound": ["/bin/true"]})
        for risk in ("money", "prod", "secrets"):
            ident = self.submit("risk-" + risk, risks=[risk])
            self.assertEqual(control.action(ident)["status"], "awaiting-owner")
            self.decide(ident, "sender", False)
            with self.assertRaises(ValueError):
                self.decide(ident, "sender", True)
            with self.assertRaises(ValueError):
                self.submit("risk-" + risk, task="same intent with changed words", risks=[risk])
        outbound = control.submit({"bot": "recipient", "intent": "send approved text", "kind": "outbound",
                                   "to": "customer", "text": "approved draft"})
        with self.assertRaises(ValueError):
            self.decide(outbound, "sender", True)
        self.decide(outbound, "coordinator", True)
        old = self.submit("slow old scope")
        child = control.submit({"bot": "recipient", "intent": "peer child", "kind": "peer", "parent": old,
                                "to": "coordinator", "text": "follow-up"})
        held = peer.hold("worker", "recipient", "obsolete peer work", child)
        control.tick()
        self.eventually(lambda: (self.home / "cli-started").exists())
        replacement = control.replace(old, self.spec("new corrected scope"))
        self.assertEqual(control.action(child)["status"], "cancelled")
        self.assertIsNone(peer.before_turn("recipient", "app", "after-stop"))
        self.assertTrue(held)
        self.eventually(lambda: (self.job(old) / "ready").exists())
        self.assertEqual((self.job(old) / "status").read_text().strip(), "cancelled")
        self.assertFalse(control.process_alive(int((self.home / "cli-child").read_text())))
        control.tick()
        self.eventually(lambda: (self.job(replacement) / "ready").exists())
        self.assertEqual((self.job(replacement) / "status").read_text().strip(), "ok")

    def test_P08_timezone_reporting_boundaries_and_dst(self):
        control.publish({"owner": "sender", "coordinator": "coordinator"})
        for date, expected in [("2026-10-19T05:59:00+00:00", ["coordinator"]),
                               ("2026-10-19T06:00:00+00:00", ["coordinator", "sender"]),
                               ("2026-10-19T20:59:59+00:00", ["coordinator", "sender"]),
                               ("2026-10-19T21:00:00+00:00", ["coordinator"]),
                               ("2026-12-19T07:00:00+00:00", ["coordinator", "sender"]),
                               ("2026-10-25T01:30:00+00:00", ["coordinator"])]:
            self.assertEqual(control.reporting_targets(datetime.fromisoformat(date).timestamp()), expected, date)
        control.publish({"start": 1380, "end": 480})
        self.assertEqual(control.reporting_targets(datetime.fromisoformat("2026-10-19T21:00:00+00:00").timestamp()),
                         ["coordinator", "sender"])

    def test_P09_reversible_allowlist_is_autonomous_and_outbound_fake_never_executes(self):
        read = control.submit({"bot": "worker", "kind": "read", "intent": "inspect cwd", "argv": ["/bin/pwd"]})
        self.assertEqual(control.action(read)["gate"], "auto")
        marker = self.home / "must-not-send"
        draft = {"bot": "recipient", "kind": "outbound", "intent": "draft only", "fake": True, "to": "QA", "text": "FAKE"}
        # fixes12: a caller-supplied command is refused outright; the configured sender would create the marker.
        with self.assertRaisesRegex(ValueError, "outbound argv must match"):
            control.submit(dict(draft, argv=["/usr/bin/touch", str(marker)]))
        control.publish({"outbound": ["/bin/sh", "-c", 'touch "$0"', str(marker)]})
        fake = control.submit(draft)
        control.tick()
        self.eventually(lambda: control.action(read)["status"] == "done")
        self.assertEqual(control.action(fake)["status"], "done")
        self.assertIn("FAKE", control.action(fake)["error"])
        self.assertFalse(marker.exists())

    def test_P10_unreachable_target_persistent_retry_and_truthful_pending_receipt(self):
        self.status = 503
        result = self.msg("--durable", "--", "retry the requested action when reachable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("pending:delivery."))
        ident = result.stdout.strip().removeprefix("pending:")
        def delivery():
            with control.database() as db:
                return dict(db.execute("SELECT * FROM deliveries WHERE id=?", (ident,)).fetchone())
        self.eventually(lambda: delivery()["attempts"] > 0)
        self.assertEqual(delivery()["status"], "pending")
        self.assertIn("retained for retry", delivery()["error"])
        self.status = 200
        self.keys["recipient"] = "synthetic-rotated"
        (self.home / ".hermes/profiles/recipient/.env").write_text("API_SERVER_KEY=synthetic-rotated\n")
        self.sync()
        with control.database() as db:
            db.execute("UPDATE deliveries SET due=0 WHERE id=?", (ident,))
        # A new interpreter uses only disk state, not a caller-owned retry loop.
        self.assertEqual(subprocess.run(["/usr/bin/python3", str(boundary.RUNTIME), "retry-once"],
                         env=self.env, capture_output=True, timeout=12).returncode, 0)
        self.eventually(lambda: delivery()["status"] == "delivered")
        self.assertEqual(self.turns()[-1][2], "Bearer synthetic-rotated")


class RuntimeEdgeTests(unittest.TestCase):
    setUp = boundary.PeerTests.setUp
    stop_background = boundary.PeerTests.stop_background
    sync = boundary.PeerTests.sync
    requests = boundary.PeerTests.requests
    msg = boundary.PeerTests.msg
    turns = boundary.PeerTests.turns
    eventually = boundary.PeerTests.eventually
    cli = ObservedPatternTests.cli
    spec = ObservedPatternTests.spec
    submit = ObservedPatternTests.submit
    job = ObservedPatternTests.job
    decide = ObservedPatternTests.decide

    def test_ordinary_unreachable_priority_send_retains_exit_three_and_queues_retry(self):
        self.sync()
        config = json.loads((self.curl_state / "config").read_text())
        config["gateway_offline"] = True
        (self.curl_state / "config").write_text(json.dumps(config))
        result = subprocess.run(["/bin/sh", str(boundary.MSG), "--from", "sender", "--to", "recipient",
                                 "--priority", "--", "recover when reachable"],
                                env=self.env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 3)
        self.assertIn("did not answer", result.stderr)
        self.assertIn("pending:delivery.", result.stderr)
        self.assertEqual(self.turns(), [])
        with control.database() as db:
            row = db.execute("SELECT status FROM deliveries").fetchone()
            self.assertEqual(row[0], "pending")
        self.sync()
        self.eventually(lambda: len(self.turns()) == 1)

    def test_denial_cannot_be_rewrapped_under_a_new_id_or_label(self):
        # fixes12: outbound argv is composed from the owner's sender, never caller input.
        control.publish({"owner": "sender", "coordinator": "coordinator", "outbound": ["/bin/true"]})
        spec = {"bot": "worker", "intent": "first draft", "kind": "outbound",
                "to": "customer", "text": "do not send this"}
        ident = control.submit(spec)
        self.decide(ident, "coordinator", False)
        with self.assertRaises(ValueError):
            control.submit(dict(spec, intent="same denied action with a new label", origin="recipient"))

    def test_subscriber_ack_does_not_lose_a_policy_changed_mid_turn(self):
        control.register("worker")
        first = control.publish({"route": "codex"})
        peer.before_turn("worker", "s", "t")
        second = control.publish({"allow_speculative": False})
        peer.after_turn("worker", "s", "t", "NO_REPLY")
        self.assertGreater(second["revision"], first["revision"])
        self.assertEqual(control.subscription("worker")["revision"], second["revision"])

    def test_failed_queue_holds_later_work_until_cancelled(self):
        self.cli()
        first, second = self.submit("no-report"), self.submit("next")
        control.tick()
        self.eventually(lambda: (self.job(first) / "ready").exists())
        control.tick()
        self.assertEqual(control.action(first)["status"], "failed")
        self.assertEqual(control.action(second)["status"], "queued")
        self.assertFalse(self.job(second).exists())
        control.stop(first)
        control.tick()
        self.eventually(lambda: (self.job(second) / "ready").exists())
        control.tick()
        self.assertEqual(control.action(second)["status"], "done")

    def test_coding_task_parameters_must_match_the_approved_record(self):
        self.cli()
        ident = self.submit("approved", risks=["prod"])
        control.publish({"owner": "sender"})
        self.decide(ident, "sender", True)
        with self.assertRaises(ValueError):
            control.check_job(ident, "worker", str(self.home), "different-model", "high",
                              str(self.home / "approved.txt"), "approved", "codex")
        self.assertEqual(control.action(ident)["status"], "queued")

    def test_cancel_stops_a_running_peer_stream_and_prevents_late_reply(self):
        ident = control.submit({"bot": "sender", "intent": "running peer", "kind": "peer",
                                "to": "recipient", "text": "work"})
        self.release.unlink()
        child = subprocess.Popen(["/bin/sh", str(boundary.MSG), "--from", "sender", "--to", "recipient",
                                  "--priority", "--task-id", ident, "--", "work"], env=self.env,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        self.eventually(lambda: len(self.turns()) == 1)
        control.stop(ident)
        stdout, stderr = child.communicate(timeout=6)
        self.assertNotEqual(child.returncode, 0, stdout + stderr)
        self.assertEqual(len(self.turns()), 1)

    def test_read_allowlist_does_not_trust_a_programs_basename(self):
        script = self.home / "ls"
        script.write_text("#!/bin/sh\nexit 0\n")
        ident = control.submit({"bot": "worker", "intent": "fake ls", "kind": "read", "argv": [str(script)]})
        self.assertEqual(control.action(ident)["status"], "awaiting-owner")

    def test_slow_completion_acknowledgement_does_not_hold_the_standing_queue(self):
        self.cli()
        self.release.unlink()
        first, second = self.submit("first"), self.submit("second")
        peer.start_worker()
        self.eventually(lambda: (self.job(first) / "ready").exists())
        self.eventually(lambda: len(self.turns()) == 1)
        self.eventually(lambda: (self.job(second) / "ready").exists())
        self.assertFalse((self.job(first) / "delivered").exists())
        self.release.touch()
        self.eventually(lambda: (self.job(second) / "delivered").exists())


if __name__ == "__main__":
    unittest.main()
