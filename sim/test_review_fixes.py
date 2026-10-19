"""Regressions for the 2026-10-19 review findings (REVIEW-PATTERNS.md, findings 1–9).

Same synthetic boundary as test_peer_runtime: stub curl, stub CLIs, no sockets, no model calls.
"""
import os
from pathlib import Path
import shutil
import signal
import sqlite3
import subprocess
import unittest
from unittest.mock import patch

import test_peer_runtime as boundary

peer = boundary.peer
control = peer.control
SWARMCTL = boundary.RUNTIME.with_name("swarmctl")


class ReviewFixTests(unittest.TestCase):
    setUp = boundary.PeerTests.setUp
    sync = boundary.PeerTests.sync
    requests = boundary.PeerTests.requests
    msg = boundary.PeerTests.msg
    turns = boundary.PeerTests.turns
    eventually = boundary.PeerTests.eventually
    completion = boundary.PeerTests.completion
    retry = boundary.PeerTests.retry
    stop_background = boundary.PeerTests.stop_background

    def gateway(self, profile):
        return patch.dict(os.environ, {"HERMES_HOME": str(self.home / ".hermes/profiles" / profile)})

    def receipt(self, target, ident):
        with control.database() as db:
            row = db.execute("SELECT status,turn FROM receipts WHERE target=? AND id=?", (target, ident)).fetchone()
        return tuple(row) if row else None

    def cli(self):
        folder = self.home / "cli"
        folder.mkdir(exist_ok=True)
        for name in ("codex", "claude"):
            path = folder / name
            path.write_text('#!/bin/sh\nprintf \'%s\\n\' "$@" > "$HOME/$(basename "$0").args"\n'
                            'printf ok > "$SWARMHUB_REPORT_FILE"\necho result\nexit 0\n')
            path.chmod(0o755)
        self.env.update(PATH=str(folder) + ":" + self.env["PATH"], CODE_JOB_TICK="0.05")
        os.environ.update(self.env)

    def coding(self, intent, **changes):
        return control.submit(dict({"bot": "worker", "origin": "sender", "intent": intent, "kind": "coding",
                                    "task": intent, "directory": str(self.home), "order": "claude",
                                    "model": "synthetic-model", "effort": "high", "report": intent + ".txt"}, **changes))

    # 1. Receipts bind by delivery id carried in the turn's message, never by session alone.
    def test_receipt_binds_only_to_the_turn_that_carries_its_delivery_id(self):
        token = control.receipt_claim("recipient", "delivery.durable", "sender")
        self.assertNotIn(token, ("busy", "received"))
        session = "swarmhub-from-sender"
        # An ordinary priority send from the same sender, interleaved in the same session.
        self.assertIsNone(peer.before_turn("recipient", session, "t1", "[Message from sender via SwarmHub]\nordinary"))
        peer.after_turn("recipient", session, "t1", "answered the ordinary message")
        self.assertEqual(self.receipt("recipient", "delivery.durable"), ("running", None))
        # A quoted id in another session binds nothing either.
        peer.before_turn("recipient", "app-session", "t2", control.tagged("delivery.durable", "quoted"))
        peer.after_turn("recipient", "app-session", "t2", "answer")
        self.assertEqual(self.receipt("recipient", "delivery.durable"), ("running", None))
        # The turn carrying the id in its own session binds and acknowledges, also as a multimodal part list.
        parts = [{"type": "text", "text": control.tagged("delivery.durable", "the durable text")}]
        peer.before_turn("recipient", session, "t3", parts)
        self.assertEqual(self.receipt("recipient", "delivery.durable"), ("running", "t3"))
        peer.after_turn("recipient", session, "t3", "done")
        self.assertEqual(self.receipt("recipient", "delivery.durable")[0], "received")
        self.assertEqual(control.deliver("sender", "recipient", "the durable text", "delivery.durable"), 0)
        self.assertEqual(self.turns(), [])

    def test_delivered_text_carries_its_delivery_id_and_an_unbound_turn_cannot_complete_it(self):
        job = self.completion()
        self.assertEqual(self.retry(job).returncode, 0)
        self.assertIn(control.TAG.format(job.name), self.turns()[0][1]["input"])
        token = control.receipt_claim("sender", "job.pending", "worker")
        self.assertNotIn(token, ("busy", "received"))
        peer.before_turn("sender", "swarmhub-from-worker", "foreign")
        peer.after_turn("sender", "swarmhub-from-worker", "foreign", "NO_REPLY")
        self.assertEqual(self.receipt("sender", "job.pending")[0], "running")

    # 2. Held batches stay under the Hermes hook spill limit; overflow stays queued and undelivered.
    def test_held_batches_stay_under_the_spill_limit_and_overflow_stays_queued(self):
        for n in range(3):
            peer.hold("sender", "recipient", f"m{n}-" + "x" * 7990)
        seen = []
        for turn in ("t1", "t2", "t3"):
            context = peer.before_turn("recipient", "s", turn)["context"]
            self.assertLessEqual(len(context), peer.BATCH_MAX)
            seen.append([n for n in range(3) if f"m{n}-" in context])
            peer.after_turn("recipient", "s", turn, "ok")
        self.assertEqual(seen, [[0], [1], [2]])
        self.assertIsNone(peer.before_turn("recipient", "s", "t4"))
        control.register("recipient")
        control.publish({"route": "codex", "codex_model": "synthetic-quota-model"})
        peer.hold("sender", "recipient", "y" * peer.HELD_MAX)
        context = peer.before_turn("recipient", "s", "t5")["context"]
        self.assertLessEqual(len(context), peer.BATCH_MAX)
        self.assertIn("Global SwarmHub policy", context)
        self.assertIn("y" * peer.HELD_MAX, context)
        with self.assertRaises(ValueError):
            peer.hold("sender", "recipient", "z" * (peer.HELD_MAX + 1))
        with self.assertRaises(ValueError):  # The policy prefix is bounded too, so the batch always fits.
            control.publish({"codex_model": "m" * 201})
        result = self.msg("--no-wait", "--", "z" * (peer.HELD_MAX + 1))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.requests, [])

    # 3. fake: true is a dry run for every side-effecting kind.
    def test_fake_is_a_dry_run_for_every_side_effecting_kind(self):
        control.publish({"owner": "sender", "coordinator": "coordinator"})
        for kind in control.SIDE_EFFECT_KINDS:
            marker = self.home / f"marker-{kind}"
            spec = {"bot": "worker", "intent": "dry " + kind, "kind": kind, "fake": True,
                    "argv": ["/usr/bin/touch", str(marker)]}
            if kind == "outbound":
                spec.update(to="QA", text="draft")
            ident = control.submit(spec)
            if control.action(ident)["status"] == "awaiting-owner":
                with self.gateway("sender"):
                    control.decide(ident, "sender", True)
            control.tick()
            self.assertEqual(control.action(ident)["status"], "done", kind)
            self.assertEqual(control.action(ident)["error"], f"FAKE: no {kind} operation executed")
            self.assertFalse(marker.exists(), kind)
        # Defense in depth: a running fake record never reaches Popen either.
        ident = control.submit({"bot": "worker", "intent": "dry direct", "kind": "read", "fake": True,
                                "argv": ["/usr/bin/touch", str(self.home / "marker-direct")]})
        with control.database() as db:
            db.execute("UPDATE actions SET status='running' WHERE id=?", (ident,))
        control.run_action(ident)
        self.assertEqual(control.action(ident)["status"], "done")
        self.assertFalse((self.home / "marker-direct").exists())

    def test_fake_coding_and_peer_actions_launch_nothing(self):
        coding = self.coding("dry coding", fake=True)
        peer_action = control.submit({"bot": "worker", "intent": "dry peer", "kind": "peer", "fake": True,
                                      "to": "recipient", "text": "never queued"})
        control.tick()
        for ident in (coding, peer_action):
            self.assertEqual(control.action(ident)["status"], "done")
            self.assertIn("FAKE", control.action(ident)["error"])
        self.assertFalse((peer.state() / "job-completions").exists())
        with control.database() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM deliveries").fetchone()[0], 0)

    # 4. The recovery worker survives unexpected errors and is restarted after a crash.
    def test_recovery_sweep_records_unexpected_errors_and_backs_off(self):
        folder = peer.state()
        sleeps = []
        def broken():
            raise sqlite3.OperationalError("database is locked")
        failures = 0
        for _ in range(3):
            failures = peer.guarded(broken, folder, failures, sleep=sleeps.append)
        self.assertEqual(sleeps, [2, 4, 8])
        self.assertIn("OperationalError: database is locked", (folder / "job-wake.error").read_text())
        self.assertEqual(peer.guarded(lambda: None, folder, failures, sleep=sleeps.append), 0)

    def test_malformed_completion_record_does_not_block_other_jobs(self):
        bad = self.completion(name="job.aaa-malformed")
        (bad / "attempts").write_text("not a number")
        good = self.completion(name="job.bbb-good")
        self.assertEqual(self.retry(good).returncode, 0)
        self.assertTrue((good / "delivered").exists())
        self.assertFalse((bad / "delivered").exists())
        self.assertIn("ValueError", (bad / "last-error").read_text())

    def test_supervisor_restarts_the_worker_with_backoff_until_the_state_folder_goes(self):
        folder = peer.state()
        exits = iter([1, 1, peer.WORKER_BUSY, 0])
        runs, sleeps = [], []
        def run():
            code = next(exits, None)
            if code is None:
                shutil.rmtree(folder)
                return 0
            runs.append(code)
            return code
        peer.supervise(run=run, sleep=sleeps.append)
        self.assertEqual(runs, [1, 1, peer.WORKER_BUSY, 0])
        self.assertEqual(sleeps, [2, 4, 5, 2])

    def test_killed_worker_process_is_restarted_by_the_supervisor(self):
        peer.start_worker()
        pidfile = peer.state() / "job-wake.pid"
        self.eventually(lambda: pidfile.exists() and (peer.state() / "job-wake.supervisor.pid").exists())
        first = int(pidfile.read_text())
        self.assertTrue(control.process_alive(first))
        os.kill(first, signal.SIGKILL)
        def restarted():
            current = pidfile.read_text()
            return current != str(first) and control.process_alive(int(current))
        self.eventually(restarted)
        self.assertIn("worker exited", (peer.state() / "job-wake.error").read_text())

    # 5. The deciding actor is verified against the invoking gateway, not argv.
    def test_decision_actor_is_verified_against_the_invoking_gateway(self):
        control.publish({"owner": "sender", "coordinator": "coordinator"})
        ident = control.submit({"bot": "worker", "intent": "prod change", "kind": "prod", "argv": ["/bin/true"]})
        with self.assertRaises(ValueError):
            control.decide(ident, "sender", True)  # No gateway identity at all.
        with self.gateway("worker"), self.assertRaises(ValueError):
            control.decide(ident, "sender", True)  # A bot naming the owner.
        with self.gateway("worker"), self.assertRaises(ValueError):
            control.decide(ident, "worker", True)  # A bot that is not the owner.
        self.assertEqual(control.action(ident)["status"], "awaiting-owner")
        with self.gateway("sender"):
            control.decide(ident, "sender", True)
        row = control.action(ident)
        self.assertEqual((row["status"], row["decided_by"], row["decided_pid"]), ("queued", "sender", os.getpid()))
        self.assertGreater(row["decided_at"], 0)
        other = control.submit({"bot": "worker", "intent": "second prod change", "kind": "prod", "argv": ["/bin/true"]})
        result = subprocess.run(["/usr/bin/python3", str(SWARMCTL), "decide", other, "sender", "approve"],
                                env=self.env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 64)
        self.assertIn("gateway", result.stderr)
        self.assertEqual(control.action(other)["status"], "awaiting-owner")
        env = dict(self.env, HERMES_HOME=str(self.home / ".hermes/profiles/sender"))
        result = subprocess.run(["/usr/bin/python3", str(SWARMCTL), "decide", other, "sender", "approve"],
                                env=env, capture_output=True, text=True, timeout=12)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(control.action(other)["status"], "queued")
        # swarmctl started a supervisor; let it register its pid so cleanup can stop it.
        self.eventually(lambda: (peer.state() / "job-wake.supervisor.pid").exists())

    # 6. Liveness compares the process start time, so a recycled pid is not "still running".
    def test_process_liveness_requires_the_same_incarnation(self):
        pid, start = control.spawn_recorded(["/bin/sleep", "5"])
        self.addCleanup(control.terminate, pid)
        self.assertTrue(start)
        self.assertTrue(control.process_alive(pid, start))
        self.assertFalse(control.process_alive(pid, "Thu Jan  1 00:00:00 1970"))
        self.cli()
        old = self.coding("old scope")
        control.tick()
        self.eventually(lambda: (peer.state() / "job-completions" / old.replace("task.", "job.", 1) / "ready").exists())
        new = self.coding("new scope")
        with control.database() as db:
            db.execute("UPDATE actions SET status='cancelled',pid=?,pid_start=? WHERE id=?",
                       (os.getpid(), control.process_start(os.getpid()), old))
        control.tick()
        self.assertEqual(control.action(new)["status"], "queued")  # Same incarnation still alive: wait.
        with control.database() as db:
            db.execute("UPDATE actions SET pid_start='Thu Jan  1 00:00:00 1970' WHERE id=?", (old,))
        control.tick()
        self.assertEqual(control.action(new)["status"], "running")  # Recycled pid: not ours, go on.

    # 7. A policy-only turn is not told that held messages were delivered.
    def test_policy_only_turn_does_not_claim_held_messages_were_delivered(self):
        control.register("recipient")
        control.publish({"route": "codex"})
        context = peer.before_turn("recipient", "s", "t")["context"]
        self.assertIn("Global SwarmHub policy", context)
        self.assertNotIn("Held peer messages", context)
        peer.hold("sender", "recipient", "now there is one")
        context = peer.before_turn("recipient", "s", "t2")["context"]
        self.assertIn("Held peer messages delivered with this turn", context)

    # 8. A policy change after launch does not fail the running job as a parameter mismatch.
    def test_policy_change_after_launch_does_not_fail_the_running_job(self):
        self.cli()
        ident = self.coding("approved scope")
        control.tick()
        self.assertEqual(control.action(ident)["status"], "running")
        control.publish({"route": "codex", "codex_model": "other-model"})
        control.check_job(ident, "worker", str(self.home), "synthetic-model", "high",
                          str(self.home / "approved scope.txt"), "approved scope", "claude")
        with self.assertRaises(ValueError):
            control.check_job(ident, "worker", str(self.home), "other-model", "high",
                              str(self.home / "approved scope.txt"), "approved scope", "codex")
        job = peer.state() / "job-completions" / ident.replace("task.", "job.", 1)
        self.eventually(lambda: (job / "ready").exists())
        self.assertEqual((job / "status").read_text().strip(), "ok")
        self.assertTrue((self.home / "claude.args").exists())

    # 10. File-size rule and layering.
    def test_control_modules_stay_under_the_size_rule_without_cycles(self):
        for name in ("swarm_control", "swarm_store", "swarm_policy", "swarm_delivery", "swarm_jobs", "peer-runtime"):
            lines = (boundary.RUNTIME.with_name(name + ".py")).read_text().count("\n")
            self.assertLess(lines, 500, name)
        result = subprocess.run(["/usr/bin/python3", "-c", "import swarm_store, swarm_policy, swarm_delivery, swarm_jobs"],
                                cwd=boundary.RUNTIME.parent, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
