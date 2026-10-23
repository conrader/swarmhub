"""Off-app alerts (swarm_alerts*.py): sealed settings, the routine/code-job/spool sources, the filters (silent,
dedupe, presence lease, reporting window, rate limit, retries) and both sinks, against loopback fakes only."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "Resources/Skills/swarmhub-messages/scripts"
sys.path.insert(0, str(SCRIPTS))
sys.dont_write_bytecode = True

import alerts_fixtures as fixtures  # noqa: E402
import swarm_alerts as alerts  # noqa: E402
import swarm_alerts_hermes as hermes  # noqa: E402
import swarm_alerts_seal as seal  # noqa: E402
import swarm_alerts_sinks as sinks  # noqa: E402
import swarm_store as store  # noqa: E402

TOKEN, PASSWORD = "tk_synthetic_token_123", "synthetic-password-456"
# The same vector is asserted by the app (`BoxAlertsTests.theSealMatchesTheBoxsVector`).
VECTOR = ("v1.WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpntbpN003rAeWCpygn1YvbvZkWLEAaYz6LERav7U6ckCQmMdzCxqaMoCphvq5xicsC4"
          "VohICnqnsTTcffP5PbwE0aUd3EgWIcEjoisa7UbE")


class AlertsBase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.keys = {"default": "synthetic-default-key", "jarvis": "synthetic-jarvis-key"}
        (self.home / ".hermes/profiles/jarvis").mkdir(parents=True)
        (self.home / ".hermes/.env").write_text(f"API_SERVER_KEY={self.keys['default']}\n")
        (self.home / ".hermes/profiles/jarvis/.env").write_text(f"export API_SERVER_KEY='{self.keys['jarvis']}'\n")
        self.hermes = fixtures.FakeHermes(self.keys)
        self.addCleanup(self.hermes.close)
        env = {"HOME": str(self.home), "PATH": "/usr/bin:/bin", "SWARMHUB_GATEWAY": self.hermes.url,
               "SWARMHUB_RECEIVER_MANAGER": "none", "PYTHONDONTWRITEBYTECODE": "1"}
        patcher = patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.sent = []
        self.now = 1_800_000_000.0

    def deliver(self, config, title, body):
        self.sent.append((title, body))
        return {"ntfy": "sent"}

    def configure(self, **extra):
        config = dict({"v": 1, "enabled": True, "window": False, "ntfy": {"url": "https://ntfy.example/topic", "token": TOKEN}}, **extra)
        alerts.paths()["config"].write_text(json.dumps(alerts.validate(config)))

    def tick(self, advance=31):
        self.now += advance
        alerts.tick(now=self.now, deliver=self.deliver)
        return alerts.load_state()

    def job(self, profile, ident, name, last, **extra):
        rows = [row for row in self.hermes.jobs.get(profile, []) if row["id"] != ident]
        self.hermes.jobs[profile] = rows + [dict({"id": ident, "name": name, "last_run_at": last, "enabled": True}, **extra)]

    def run_reply(self, profile, ident, stamp, text):
        session = f"cron_{ident}_{stamp}"
        self.hermes.sessions.setdefault(profile, []).append({"id": session, "source": "cron", "started_at": self.now})
        self.hermes.messages[session] = [{"role": "user", "content": "go", "timestamp": self.now},
                                         {"role": "assistant", "content": text, "timestamp": self.now + 1}]


class Seal(unittest.TestCase):
    def test_x25519_matches_rfc7748(self):
        k = bytes.fromhex("a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4")
        u = bytes.fromhex("e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c")
        self.assertEqual(seal.x25519(k, u).hex(), "c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552")
        alice = bytes.fromhex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
        bob = bytes.fromhex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
        self.assertEqual(seal.public(alice).hex(), "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
        self.assertEqual(seal.x25519(alice, bob).hex(), "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")

    def test_sealed_settings_open_only_with_this_key_and_unaltered(self):
        private = os.urandom(32)
        blob = seal.seal(seal.public(private), b'{"v":1}')
        self.assertEqual(seal.open_sealed(private, blob), b'{"v":1}')
        for bad in (blob[:-2] + ("A" if blob[-2] != "A" else "B") + blob[-1], blob[:40], "v2." + blob[3:], "", None):
            with self.assertRaises(ValueError):
                seal.open_sealed(private, bad)
        with self.assertRaises(ValueError):
            seal.open_sealed(os.urandom(32), blob)

    def test_the_apps_vector_opens(self):
        box, ephemeral = bytes(range(1, 33)), bytes(range(33, 65))
        plain = b'{"v":1,"enabled":true,"ntfy":{"url":"https://ntfy.example/t"}}'
        self.assertEqual(seal.b64(seal.public(box)), "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9_AsrhtHHw")
        self.assertEqual(seal.seal(seal.public(box), plain, ephemeral), VECTOR)
        self.assertEqual(seal.open_sealed(box, VECTOR), plain)


class Settings(AlertsBase):
    def test_configure_keeps_secrets_in_one_private_file_and_out_of_the_answer(self):
        public = seal.b64(seal.public(seal.box_key(alerts.paths()["folder"])))
        config = {"v": 1, "enabled": True, "ntfy": {"url": "https://ntfy.example/topic", "token": TOKEN},
                  "email": {"host": "smtp.example", "port": 587, "user": "me", "password": PASSWORD, "from": "a@example", "to": "b@example"}}
        answer = alerts.panel("configure", seal.seal(seal.unb64(public), json.dumps(config).encode()))
        text = json.dumps(answer)
        self.assertNotIn(TOKEN, text)
        self.assertNotIn(PASSWORD, text)
        self.assertEqual(answer["schema"], "swarmhub/alerts/1")
        self.assertEqual(answer["config"], {"configured": True, "enabled": True, "window": True, "sinks": ["ntfy", "email"]})
        self.assertEqual(answer["box_key"], public)
        self.assertTrue(answer["result"]["saved"])
        self.assertIn("no supported service manager", answer["result"]["error"])
        folder = alerts.paths()["folder"]
        self.assertEqual(folder.stat().st_mode & 0o777, 0o700)
        for name in ("config.json", "box.key"):
            self.assertEqual((folder / name).stat().st_mode & 0o777, 0o600, name)
        self.assertEqual(json.loads((folder / "config.json").read_text())["email"]["password"], PASSWORD)

    def test_invalid_settings_are_refused_before_anything_is_written(self):
        public = seal.public(seal.box_key(alerts.paths()["folder"]))
        for config, reason in (({"v": 1, "enabled": True}, "choose ntfy"),
                               ({"v": 1, "ntfy": {"url": "http://ntfy.example/t"}}, "plain http"),
                               ({"v": 1, "ntfy": {"url": "https://ntfy.example/"}}, "topic"),
                               ({"v": 1, "email": {"host": "mail.example", "security": "none", "from": "a@x", "to": "b@x"}}, "unencrypted"),
                               ({"v": 2}, "unsupported")):
            with self.assertRaisesRegex(ValueError, reason):
                alerts.panel("configure", seal.seal(public, json.dumps(config).encode()))
        with self.assertRaisesRegex(ValueError, "do not match"):
            alerts.panel("configure", seal.seal(seal.public(os.urandom(32)), b'{"v":1}'))
        self.assertFalse(alerts.paths()["config"].exists())

    def test_turning_alerts_off_or_removing_the_service_pauses_every_handed_off_job(self):
        # Nothing else ends a handed-off loop or goal whose reply says done: alerts off must not leave one scheduled.
        self.job("jarvis", "aaaaaaaaaaaa", "swarmhub-loop-0123abcd", "")
        self.job("default", "bbbbbbbbbbbb", "swarmhub-goal-89abcdef", "")
        self.job("default", "cccccccccccc", "swarmhub-goal-00000000", "", enabled=False)
        self.job("jarvis", "dddddddddddd", "nightly report", "")
        self.job("jarvis", "eeeeeeeeeeee", hermes.PRESENCE, "", enabled=False)
        public = seal.public(seal.box_key(alerts.paths()["folder"]))
        answer = alerts.panel("configure", seal.seal(public, json.dumps({"v": 1, "enabled": False}).encode()))
        self.assertEqual(answer["config"]["enabled"], False)
        self.assertEqual(sorted(self.hermes.paused), [("default", "bbbbbbbbbbbb"), ("jarvis", "aaaaaaaaaaaa")])
        self.hermes.paused.clear()
        alerts.paths()["config"].unlink()  # Never set up: removing the service still leaves nothing running.
        alerts.panel("uninstall")
        self.assertEqual(sorted(self.hermes.paused), [("default", "bbbbbbbbbbbb"), ("jarvis", "aaaaaaaaaaaa")])

    def test_status_reports_the_heartbeat_and_the_last_error(self):
        self.assertFalse(alerts.status(now=self.now)["running"])
        alerts.paths()["beat"].write_text(str(int(self.now - 20)))
        data = alerts.load_state()
        data["last_error"] = "ntfy: ntfy answered HTTP 403"
        alerts.save_state(data)
        state = alerts.status(now=self.now)
        self.assertTrue(state["running"])
        self.assertEqual(state["last_error"], "ntfy: ntfy answered HTTP 403")
        self.assertFalse(alerts.status(now=self.now + 200)["running"])


class Sources(AlertsBase):
    def test_a_routine_run_alerts_once_after_its_first_sighting(self):
        self.configure()
        self.job("jarvis", "aaaaaaaaaaaa", "Morning brief", "2026-10-23T07:00:00+00:00")
        self.tick()
        self.assertEqual(self.sent, [])
        self.job("jarvis", "aaaaaaaaaaaa", "Morning brief", "2026-10-23T08:00:00+00:00")
        self.run_reply("jarvis", "aaaaaaaaaaaa", "20261023_080000", "Three meetings today.")
        self.tick()
        self.assertEqual(self.sent, [("Morning brief finished (jarvis)", "Three meetings today.")])
        self.tick()
        self.assertEqual(len(self.sent), 1)
        self.assertIn(("GET", "jarvis", "/api/jobs?include_disabled=true"), self.hermes.requests)

    def test_silent_and_no_reply_runs_are_not_sent(self):
        self.configure()
        self.job("default", "bbbbbbbbbbbb", "Heartbeat", "t0", deliver="bot-chat:default")
        self.tick()
        for stamp, reply in (("t1", "[SILENT]"), ("t2", "  no_reply \n")):
            self.job("default", "bbbbbbbbbbbb", "Heartbeat", stamp, deliver="bot-chat:default")
            self.run_reply("default", "bbbbbbbbbbbb", stamp, reply)
            state = self.tick()
            self.assertEqual(state["sent"][f"routine:default:bbbbbbbbbbbb:{stamp}"][1], "silent")
        self.assertEqual(self.sent, [])

    def test_a_failed_run_and_an_unreadable_result_still_alert(self):
        self.configure()
        self.job("jarvis", "cccccccccccc", "Backup", "t0")
        self.tick()
        self.job("jarvis", "cccccccccccc", "Backup", "t1", last_status="error", last_error="disk full")
        self.tick()
        self.assertEqual(self.sent[-1], ("Backup failed (jarvis)", "disk full"))
        self.job("jarvis", "cccccccccccc", "Backup", "t2")
        self.tick()
        self.assertIn("could not be read", self.sent[-1][1])

    def test_code_job_completions_alert_after_the_baseline(self):
        self.configure()
        with store.database() as db:
            db.execute("INSERT INTO actions(id,gate,status,spec) VALUES('task.old','owner','done',?)",
                       (json.dumps({"kind": "coding", "bot": "coder", "task": "old work"}),))
        self.tick()
        with store.database() as db:
            db.execute("INSERT INTO actions(id,gate,status,spec,error) VALUES('task.new','owner','failed',?,'tests failed')",
                       (json.dumps({"kind": "coding", "bot": "coder", "task": "Fix the parser"}),))
            db.execute("INSERT INTO actions(id,gate,status,spec) VALUES('task.fake','owner','done',?)",
                       (json.dumps({"kind": "coding", "bot": "coder", "task": "dry", "fake": True}),))
        self.tick()
        self.assertEqual(self.sent, [("Code job failed (coder)", "Fix the parser\ntests failed")])

    def test_spooled_events_need_settings_and_are_sent_once(self):
        self.assertFalse(alerts.emit("report", "report:1", "jarvis reported", "done"))
        self.configure()
        self.assertTrue(alerts.emit("report", "report:1", "jarvis reported", "Deploy finished."))
        self.assertTrue(alerts.emit("report", "report:1", "jarvis reported", "Deploy finished."))
        self.tick()
        self.assertEqual(self.sent, [("jarvis reported", "Deploy finished.")])
        self.assertEqual(list(alerts.paths()["spool"].glob("*.json")), [])
        alerts.emit("report", "report:1", "jarvis reported", "Deploy finished.")
        self.tick()
        self.assertEqual(len(self.sent), 1)

    def delivery(self, name, at):
        return {"role": "user", "timestamp": at,
                "content": f'[Cronjob "{name}" output — scheduled job, not the user. Review it, act on anything that needs '
                           f'action, and summarize for the chat.]\n\nReply with exactly the text'}

    def handed_off_loop(self, created="2026-10-23T07:00:00+00:00"):
        self.configure()
        self.job("jarvis", "dddddddddddd", "swarmhub-loop-0123abcd", "", deliver="bot-chat:jarvis", created_at=created)
        self.tick()
        self.job("jarvis", "dddddddddddd", "swarmhub-loop-0123abcd", "2026-10-23T08:00:00+00:00", deliver="bot-chat:jarvis",
                 created_at=created)
        run_at = hermes.iso_seconds("2026-10-23T08:00:00+00:00")
        self.hermes.sessions["jarvis"] = [{"id": "chat1", "title": "Bot Chat", "last_active": run_at + 30}]
        return run_at

    def test_a_handed_off_loop_alerts_with_its_bot_chat_reply_and_is_paused_when_done(self):
        run_at = self.handed_off_loop()
        # Hermes delivers (a full Bot Chat turn) before it records last_run_at.
        self.hermes.messages["chat1"] = [{"role": "assistant", "content": "older", "timestamp": run_at - 600},
                                         self.delivery("swarmhub-loop-0123abcd", run_at - 30),
                                         {"role": "assistant", "content": "", "tool_calls": [{"id": "t1"}], "timestamp": run_at - 25}]
        self.tick()
        self.assertEqual(self.sent, [])  # The Bot Chat has not answered yet.
        self.hermes.messages["chat1"].append({"role": "assistant", "timestamp": run_at - 20,
                                              "content": 'Build is green.\n```swarmhub\n{"op":"loop","status":"done"}\n```'})
        state = self.tick()
        self.assertEqual(self.sent, [("Loop on the box (jarvis): done", "Build is green.")])
        self.assertEqual(self.hermes.paused, [("jarvis", "dddddddddddd")])
        self.assertEqual(state["handoff"], {})
        self.tick()
        self.assertEqual(len(self.sent), 1)

    def test_replies_that_are_not_the_jobs_own_never_end_the_wait_alert_or_pause(self):
        run_at = self.handed_off_loop()
        done = 'Done.\n```swarmhub\n{"op":"loop","status":"done"}\n```'
        self.hermes.messages["chat1"] = [
            # The same chat's routine from an earlier quit (same name, before this job was made).
            self.delivery("swarmhub-loop-0123abcd", run_at - 7200), {"role": "assistant", "content": done, "timestamp": run_at - 7190},
            # Another routine's delivery and reply, and the user's own chat, all newer than the run.
            self.delivery("swarmhub-goal-89abcdef", run_at + 5), {"role": "assistant", "content": done, "timestamp": run_at + 10},
            {"role": "user", "content": "thanks", "timestamp": run_at + 15},
            {"role": "assistant", "content": done, "timestamp": run_at + 20}]
        state = self.tick()
        self.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.hermes.paused, [])
        self.assertEqual(list(state["handoff"]), ["jarvis/dddddddddddd"])
        self.hermes.messages["chat1"] += [self.delivery("swarmhub-loop-0123abcd", run_at + 40),
                                          {"role": "assistant", "content": "Still red.", "timestamp": run_at + 50}]
        state = self.tick()
        self.assertEqual(self.sent, [("Loop on the box (jarvis)", "Still red.")])
        self.assertEqual(self.hermes.paused, [])
        self.assertEqual(state["handoff"], {})

    def test_a_second_run_before_the_first_reply_keeps_the_first_runs_window(self):
        run_at = self.handed_off_loop()
        self.hermes.messages["chat1"] = [self.delivery("swarmhub-loop-0123abcd", run_at - 30)]
        self.tick()
        self.job("jarvis", "dddddddddddd", "swarmhub-loop-0123abcd", "2026-10-23T08:10:00+00:00", deliver="bot-chat:jarvis",
                 created_at="2026-10-23T07:00:00+00:00")
        self.hermes.messages["chat1"] += [{"role": "assistant", "content": "first", "timestamp": run_at + 60},
                                          self.delivery("swarmhub-loop-0123abcd", run_at + 570),
                                          {"role": "assistant", "content": "second", "timestamp": run_at + 580}]
        state = self.tick()
        self.assertEqual(self.sent, [("Loop on the box (jarvis)", "first"), ("Loop on the box (jarvis)", "second")])
        self.assertEqual(state["handoff"], {})


class Filters(AlertsBase):
    def test_a_fresh_presence_lease_means_the_app_shows_it(self):
        self.configure()
        self.hermes.jobs["default"] = [{"id": "eeeeeeeeeeee", "name": "swarmhub-presence", "enabled": False,
                                        "prompt": f"Swarm Hub presence lease; reply [SILENT]. until={int(self.now + 300)}"}]
        alerts.emit("report", "report:a", "jarvis reported", "one")
        state = self.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(state["sent"]["report:a"][1], "app")
        self.hermes.jobs["default"][0]["prompt"] = "until=0"
        alerts.emit("report", "report:b", "jarvis reported", "two")
        self.tick()
        self.assertEqual(self.sent, [("jarvis reported", "two")])

    def test_bursts_are_held_and_summarised(self):
        self.configure()
        for index in range(9):
            alerts.emit("report", f"report:{index}", f"report {index}", "x")
        state = self.tick()
        self.assertEqual(len(self.sent), alerts.RATE_LIMIT)
        self.assertEqual(len(state["held"]), 3)
        self.tick(advance=alerts.RATE_WINDOW + 1)
        self.assertEqual(self.sent[-1][0], "3 more alerts were held back")
        self.assertIn("• report 8", self.sent[-1][1])

    def test_outside_the_report_window_alerts_wait_for_one_digest(self):
        self.configure(window=True)
        with patch("swarm_policy.in_report_window", return_value=False):
            alerts.emit("report", "report:n1", "night one", "x")
            alerts.emit("report", "report:n2", "night two", "x")
            state = self.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(state["deferred"], ["night one", "night two"])
        with patch("swarm_policy.in_report_window", return_value=True):
            self.tick()
        self.assertEqual(self.sent, [("2 alerts from outside the report window", "• night one\n• night two")])

    def test_failed_sends_retry_with_backoff_then_stop_and_never_record_a_secret(self):
        self.configure()
        self.deliver = lambda config, title, body: {"ntfy": "error: " + sinks.redact(f"refused {TOKEN}", config)}
        alerts.emit("report", "report:r", "retry me", "x")
        state = self.tick()
        self.assertEqual(state["pending"][0]["attempts"], 1)
        self.assertNotIn(TOKEN, json.dumps(state))
        self.assertEqual(state["last_error"], "ntfy: refused …")
        for _ in range(alerts.RETRIES):
            state = self.tick(advance=60 * 2 ** alerts.RETRIES + 1)
        self.assertEqual(state["pending"], [])
        self.assertEqual(state["sent"]["report:r"][1], "failed")

    def test_disabled_settings_send_nothing(self):
        self.configure(enabled=False)
        alerts.emit("report", "report:d", "quiet", "x")
        self.tick()
        self.assertEqual(self.sent, [])


class Sinks(unittest.TestCase):
    def test_ntfy_posts_title_body_and_bearer_token_to_the_topic(self):
        ntfy = fixtures.FakeNtfy()
        self.addCleanup(ntfy.close)
        config = {"ntfy": {"url": ntfy.url, "token": TOKEN}}
        sinks.check_ntfy(config["ntfy"])
        self.assertEqual(sinks.deliver(config, "Backup finished (jarvis)", "All good."), {"ntfy": "sent"})
        post = ntfy.posts[0]
        self.assertEqual((post["path"], post["body"], post["headers"]["Title"]), ("/swarm-alerts", "All good.", "Backup finished (jarvis)"))
        self.assertEqual(post["headers"]["Authorization"], "Bearer " + TOKEN)
        ntfy.status = 403
        self.assertEqual(sinks.deliver(config, "t", "b"), {"ntfy": "error: ntfy answered HTTP 403"})

    def test_email_logs_in_and_sends_one_message(self):
        relay = fixtures.FakeSMTP()
        self.addCleanup(relay.close)
        config = {"email": {"host": "127.0.0.1", "port": relay.port, "security": "none", "user": "me", "password": PASSWORD,
                            "from": "box@example.invalid", "to": "owner@example.invalid"}}
        sinks.check_email(config["email"])
        self.assertEqual(sinks.deliver(config, "Code job finished (coder)", "Fix the parser"), {"email": "sent"})
        self.assertEqual(relay.auth, [[b"me", PASSWORD.encode()]])
        self.assertIn("Subject: Code job finished (coder)", relay.messages[0]["data"])
        self.assertIn("Fix the parser", relay.messages[0]["data"])

    def test_one_failing_sink_does_not_stop_the_other_and_errors_are_redacted(self):
        def boom(settings, title, body):
            raise ValueError("bad " + PASSWORD)
        config = {"ntfy": {"url": "x", "token": TOKEN}, "email": {"password": PASSWORD}}
        results = sinks.deliver(config, "t", "b", sinks={"email": boom, "ntfy": lambda *a: None})
        self.assertEqual(results, {"email": "error: bad …", "ntfy": "sent"})


if __name__ == "__main__":
    unittest.main()
