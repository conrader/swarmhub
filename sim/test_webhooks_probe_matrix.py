"""The receiver's answers that ops/webhook-probe relies on (swapdesign3 §1), plus the two fallbacks for a job-done wake:
`message` when `text` is missing (what sb-codejob sends) and a body `key` when a proxy strips the X-SwarmHub-Key header
(KEY_IN=body). Then `webhook receiver install --port`, which gives a bot account its own loopback port that later
installs keep. Everything runs socketless or against stub service managers inside the temporary HOME."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import os
from pathlib import Path
import plistlib
import socket
import tempfile
import unittest
from unittest.mock import patch

from test_webhooks_live import Connection, ReceiverTestBase, control, fallback, receiver

webhook = control.webhook
ROUTINE = "canary-20261024"


class Answer:
    def __init__(self, raw):
        head, _, self.body = raw.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        self.status = int(lines[0].split()[1])
        self.headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}

    def json(self):
        return json.loads(self.body)


class ProbeMatrixBase(ReceiverTestBase):
    def setUp(self):
        super().setUp()
        self.record = webhook.register("recipient", ROUTINE)
        self.slug = self.record["url"].rsplit("/", 1)[1]
        self.key = Path(self.record["key_file"]).read_text().strip()
        self.fired = []

    def send(self, method, path, body=b"", key=None, headers=()):
        lines = [f"{method} {path} HTTP/1.0"]
        if body is not None and not any(name.lower() == "transfer-encoding" for name, _ in headers):
            lines.append(f"Content-Length: {len(body)}")
        if key is not None:
            lines.append(f"X-SwarmHub-Key: {key}")
        lines += [f"{name}: {value}" for name, value in headers]
        connection = Connection(("\r\n".join(lines) + "\r\n\r\n").encode() + (body or b""))
        webhook.request_handler(lambda: self.fired.append(1))(connection, ("127.0.0.1", 0), None)
        return Answer(connection.output)

    def post(self, path=None, payload=None, key=None, **kw):
        body = json.dumps({"text": "probe"} if payload is None else payload).encode()
        return self.send("POST", path or f"/swarmhub/webhook/recipient/{ROUTINE}/{self.slug}", body, key, **kw)

    def assertJSON(self, answer, status, body=None):
        self.assertEqual((answer.status, answer.headers.get("content-type")), (status, "application/json"), answer.body)
        if body is not None:
            self.assertEqual(answer.json(), body)
        self.assertNotIn(self.key.encode(), answer.body, "no answer ever echoes the key")

    def deliveries(self):
        with webhook.database() as db:
            return [row["text"] for row in db.execute("SELECT text FROM deliveries ORDER BY rowid")]


class StatusMatrixTests(ProbeMatrixBase):
    """Rows a–f, in the receiver's own check order: path, length, profile, key and text, routine, slug and key."""

    def test_a_the_right_key_is_accepted_and_journalled(self):
        answer = self.post(key=self.key)
        self.assertJSON(answer, 202)
        self.assertEqual((answer.json()["status"], answer.json()["routine"]), ("pending", ROUTINE))
        self.assertEqual(self.deliveries(), [f"[Webhook routine {ROUTINE} for recipient]\nprobe"])
        self.assertEqual(self.fired, [1])

    def test_b_no_header_is_400_not_403(self):
        self.assertJSON(self.post(), 400, {"error": "bad request"})
        self.assertJSON(self.post(key=""), 400, {"error": "bad request"})

    def test_c_a_wrong_key_is_403(self):
        self.assertJSON(self.post(key="wrong"), 403, {"error": "webhook rejected"})

    def test_d_a_wrong_slug_is_403_not_404(self):
        path = f"/swarmhub/webhook/recipient/{ROUTINE}/wrongslug"
        self.assertJSON(self.post(path, key=self.key), 403, {"error": "webhook rejected"})

    def test_e_an_absent_routine_with_a_dummy_key_is_the_unambiguous_404(self):
        path = "/swarmhub/webhook/recipient/absent-20261024/x"
        self.assertJSON(self.post(path, key="probe"), 404, {"error": "unknown webhook"})
        self.assertJSON(self.post(path), 400, {"error": "bad request"})  # Header stripped: 400, so e tells.
        # The other two JSON 404s with the same body: a two-segment path and a GET. A probe must not use them.
        self.assertJSON(self.post("/swarmhub/webhook/recipient/x", key="probe"), 404, {"error": "unknown webhook"})
        self.assertJSON(self.send("GET", path, body=None), 404, {"error": "unknown webhook"})
        self.assertEqual((self.deliveries(), self.fired), ([], []), "a probe never fires a wake")

    def test_f_another_accounts_receiver_answers_400_for_a_profile_it_does_not_hold(self):
        other = tempfile.TemporaryDirectory()
        self.addCleanup(other.cleanup)
        (Path(other.name) / ".hermes/profiles/someone-else").mkdir(parents=True)
        with patch.dict(os.environ, {"HOME": other.name}):
            self.assertJSON(self.post(key=self.key), 400, {"error": "bad request"})
            path = "/swarmhub/webhook/recipient/absent-20261024/x"
            self.assertJSON(self.post(path, key="probe"), 400, {"error": "bad request"})  # e from the wrong account
        self.assertEqual(self.deliveries(), [])

    def test_a_body_over_32000_bytes_is_400_json(self):
        payload = {"text": "x" * (32_500 - len('{"text": ""}'))}
        self.assertEqual(len(json.dumps(payload).encode()), 32_500)
        self.assertJSON(self.post(payload=payload, key=self.key), 400, {"error": "bad request"})

    def test_a_passed_through_transfer_encoding_is_400_json(self):
        chunk = b'{"text":"probe"}'
        body = f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n0\r\n\r\n"
        path = f"/swarmhub/webhook/recipient/{ROUTINE}/{self.slug}"
        chunked = self.send("POST", path, body, self.key, headers=[("Transfer-Encoding", "chunked")])
        self.assertJSON(chunked, 400, {"error": "bad request"})
        both = self.send("POST", path, chunk, self.key, headers=[("Content-Length", str(len(chunk))),
                                                                 ("Transfer-Encoding", "chunked")])
        self.assertJSON(both, 400, {"error": "bad request"})
        self.assertEqual(self.deliveries(), [])

    def test_put_is_the_stdlib_501_html_page(self):
        answer = self.send("PUT", f"/swarmhub/webhook/recipient/{ROUTINE}/{self.slug}", b'{"text":"probe"}', self.key)
        self.assertEqual(answer.status, 501)
        self.assertTrue(answer.headers.get("content-type", "").startswith("text/html"), answer.headers)
        self.assertEqual(self.deliveries(), [])

    def test_health_and_get_answer_json_from_the_receiver_itself(self):
        # What nginx must hide (V6): the receiver's own health is 200 JSON, its GET on a routine is 404 JSON.
        self.assertJSON(self.send("GET", "/swarmhub/webhook/health", body=None), 200, {"ok": True, "service": "swarmhub-webhook"})
        self.assertJSON(self.send("GET", f"/swarmhub/webhook/recipient/{ROUTINE}/{self.slug}", body=None), 404)

    def test_not_a_json_object_is_400(self):
        for body in (b"[1]", b"probe", b'"probe"', b"[" * 30_000):  # The last one is too deep for json.loads.
            answer = self.send("POST", f"/swarmhub/webhook/recipient/{ROUTINE}/{self.slug}", body, self.key)
            self.assertJSON(answer, 400, {"error": "bad request"})


class BodyFallbackTests(ProbeMatrixBase):
    def test_message_is_read_when_text_is_missing(self):
        self.assertJSON(self.post(payload={"message": "job done"}, key=self.key), 202)
        self.assertJSON(self.post(payload={"text": "  ", "message": "blank text"}, key=self.key), 202)
        self.assertJSON(self.post(payload={"text": "wins", "message": "ignored"}, key=self.key), 202)
        prefix = f"[Webhook routine {ROUTINE} for recipient]\n"
        self.assertEqual(self.deliveries(), [prefix + "job done", prefix + "blank text", prefix + "wins"])

    def test_neither_text_nor_message_is_400(self):
        for payload in ({}, {"text": ""}, {"message": ""}, {"text": None, "message": "  "}, {"message": 7}, {"text": 7}):
            self.assertJSON(self.post(payload=payload, key=self.key), 400, {"error": "bad request"})
        self.assertEqual(self.deliveries(), [])

    def test_a_body_key_is_used_only_when_the_header_is_missing(self):
        self.assertJSON(self.post(payload={"text": "a", "key": self.key}), 202)  # The header was stripped.
        self.assertJSON(self.post(payload={"text": "b", "key": self.key}, key=""), 202)  # Present but emptied.
        self.assertJSON(self.post(payload={"message": "c", "key": self.key}), 202)  # sb-codejob's shape.
        self.assertJSON(self.post(payload={"text": "x", "key": "wrong"}), 403, {"error": "webhook rejected"})
        self.assertJSON(self.post(payload={"text": "x", "key": self.key}, key="wrong"), 403,
                        {"error": "webhook rejected"})  # A header that arrived is never second-guessed by the body.
        self.assertJSON(self.post(payload={"text": "x", "key": 12345}), 400, {"error": "bad request"})
        self.assertJSON(self.post(payload={"text": "x", "key": ""}), 400, {"error": "bad request"})
        path = "/swarmhub/webhook/recipient/absent-20261024/x"
        self.assertJSON(self.post(path, payload={"text": "x", "key": "probe"}), 404, {"error": "unknown webhook"})
        texts = self.deliveries()
        self.assertEqual(len(texts), 3)
        self.assertFalse([text for text in texts if self.key in text], "the body key never reaches the journal")

    def test_cli_fire_also_reads_message(self):
        done = self.ctl("webhook", "fire", "recipient", ROUTINE, self.slug, payload={"key": self.key, "message": "m"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertIn(f"[Webhook routine {ROUTINE} for recipient]\nm", self.deliveries())


class ReceiverPortTests(ReceiverTestBase):
    def setUp(self):
        super().setUp()
        patcher = patch.object(receiver, "probe", return_value=False)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_systemd_install_port_is_kept_by_later_installs_status_and_urls(self):
        self.manager("systemd")
        self.calls()
        first = receiver.install(port=8801)
        text = receiver.unit_path("systemd").read_text()
        self.assertEqual(text.count("webhook serve 8801\n"), 1, text)
        self.assertIn("Description=Swarm Hub webhook receiver (127.0.0.1:8801)", text)
        self.assertEqual((first["port"], first["listen"], first["changed"]), (8801, "127.0.0.1:8801", True))
        again = receiver.install()  # Skill setup and the app's panel call install() without a port.
        self.assertEqual((again["port"], again["changed"]), (8801, False))
        self.assertEqual(receiver.ensure()["port"], 8801)
        self.assertEqual(receiver.status()["port"], 8801)
        self.assertEqual(webhook.panel("recipient", "receiver-install")["receiver"]["port"], 8801)
        record = webhook.register("recipient", "nightly")
        self.assertTrue(record["url"].startswith("http://127.0.0.1:8801/swarmhub/webhook/recipient/nightly/"), record)
        back = receiver.install(port=8745)
        self.assertEqual((back["port"], back["changed"]), (8745, True))
        self.assertIn("webhook serve 8745\n", receiver.unit_path("systemd").read_text())

    def test_launchd_install_port_is_kept(self):
        self.manager("launchd")
        self.calls({"launchctl print": 1})
        receiver.install(port=8802)
        body = plistlib.loads(receiver.unit_path("launchd").read_bytes())
        self.assertEqual(body["ProgramArguments"][-3:], ["webhook", "serve", "8802"])
        self.assertEqual(receiver.installed_port(), 8802)
        self.assertEqual((receiver.install()["port"], receiver.status()["port"]), (8802, 8802))

    def test_the_fallback_supervisor_records_and_keeps_the_port(self):
        self.manager("systemd")
        self.calls({"systemctl --user daemon-reload": (1, "Failed to connect to bus: No medium found")})
        spawned = []
        with patch.object(fallback, "spawn", side_effect=lambda python, port: spawned.append(port)):
            self.assertEqual(receiver.install(port=8803)["port"], 8803)
            self.assertEqual(json.loads(fallback.paths()["marker"].read_text())["port"], 8803)
            self.assertEqual(receiver.install()["port"], 8803)
        self.assertEqual(spawned, [8803, 8803])
        self.assertEqual(receiver.status()["port"], 8803)

    def test_without_an_install_the_port_is_8745_and_a_bad_record_is_ignored(self):
        self.manager("systemd")
        self.assertEqual((receiver.installed_port(), receiver.configured_port()), (None, 8745))
        path = receiver.unit_path("systemd")
        path.parent.mkdir(parents=True)
        path.write_text("ExecStart=/usr/bin/python3 -B swarmctl webhook serve 99999\n")
        self.assertEqual(receiver.configured_port(), 8745)
        for bad in (0, 65536, "8801", True, -1):
            with self.assertRaisesRegex(ValueError, "receiver port must be"):
                receiver.configured_port(bad)

    def test_cli_port_flag(self):
        for args, message in ((("install", "--port", "x"), "--port needs a number"),
                              (("install", "--port"), "--port needs a number"),
                              (("install", "--port", "0"), "receiver port must be"),
                              (("install", "--port", "70000"), "receiver port must be"),
                              (("uninstall", "--port", "8801"), "install \\[--port N\\]"),
                              (("status", "8801"), "install \\[--port N\\]")):
            refused = self.ctl("webhook", "receiver", *args)
            self.assertEqual(refused.returncode, 64, args)
            self.assertRegex(refused.stderr, message)
        status = self.ctl("webhook", "receiver", "status", "--port", "8804")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)["listen"], "127.0.0.1:8804")


class SupervisorPortTests(ReceiverTestBase):
    """A supervisor keeps the port it was started with (one from an older skill too), so a new port retires it through
    its marker and starts a fresh one. The installer signals nothing."""

    def free_port(self):
        try:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                return probe.getsockname()[1]
        except PermissionError:
            self.skipTest("sandbox forbids loopback sockets")

    def test_a_real_supervisor_moves_to_the_new_port(self):
        first, second = self.free_port(), self.free_port()
        fallback.start("/usr/bin/python3", first)
        self.addCleanup(lambda: (fallback.stop(), self.eventually(lambda: fallback.holder() is None)))
        self.eventually(lambda: receiver.probe(first, timeout=0.5))
        old = fallback.holder()
        with patch.object(fallback.os, "kill", side_effect=AssertionError("the installer never signals")):
            fallback.start("/usr/bin/python3", second)
        self.eventually(lambda: receiver.probe(second, timeout=0.5))
        self.assertFalse(receiver.probe(first, timeout=0.5), "the old port is closed")
        self.assertNotIn(fallback.holder(), (None, old), "a fresh supervisor holds the lock")
        self.assertEqual(json.loads(fallback.paths()["marker"].read_text())["port"], second)

    def test_the_same_port_keeps_the_running_supervisor(self):
        fallback.paths()["marker"].write_text('{"port": 8745, "python": "/usr/bin/python3"}')
        with patch.object(fallback, "holder", return_value=4_000_000), patch.object(fallback, "refresh") as refresh, \
                patch.object(fallback, "spawn") as spawn:
            fallback.start("/usr/bin/python3", 8745, sleep=lambda s: self.fail("waited"))
        refresh.assert_called_once_with()
        spawn.assert_not_called()

    def test_a_supervisor_that_does_not_stop_keeps_its_marker_and_the_install_fails(self):
        before = {"port": 8745, "python": "/usr/bin/python3"}
        fallback.paths()["marker"].write_text(json.dumps(before))
        with patch.object(fallback, "holder", return_value=4_000_000), patch.object(fallback, "spawn") as spawn:
            with self.assertRaisesRegex(ValueError, "did not stop for the port change"):
                fallback.start("/usr/bin/python3", 8808, sleep=lambda s: None)
        self.assertEqual(json.loads(fallback.paths()["marker"].read_text()), before)
        spawn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
