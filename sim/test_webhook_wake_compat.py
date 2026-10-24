"""swapdesign PR 2 (the receiver half of the job-done wake): the receiver accepts sb-codejob's `message` when `text` is
missing, a body `key` when a proxy strips the X-SwarmHub-Key header (KEY_IN=body), and `receiver install --port` so a
per-bot account serves on its own registry port. Also the full status matrix the webhook probe relies on
(swapdesign3 §1: probes a-f, 32,500 B, chunked, `message`, PUT), each answer checked for its Content-Type too.

Service managers are stubs (test_webhooks_live.ReceiverTestBase): nothing outside the temporary HOME is touched."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import os
from pathlib import Path
import plistlib
import unittest

from test_webhooks_live import Connection, ReceiverTestBase, SWARMCTL, control, fallback, receiver

JSON = "application/json"


class Answer:
    def __init__(self, output):
        head, _, self.raw = output.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        self.status = int(lines[0].split()[1])
        self.headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
        self.type = self.headers.get("content-type", "")
        self.body = json.loads(self.raw) if self.type == JSON else None


class WakeTestBase(ReceiverTestBase):
    def setUp(self):
        super().setUp()
        self.record = control.webhook.register("recipient", "canary")
        self.key = Path(self.record["key_file"]).read_text().strip()
        self.slug = self.record["url"].rsplit("/", 1)[1]
        self.path = f"/swarmhub/webhook/recipient/canary/{self.slug}"

    def post(self, body=None, key=None, path=None, method="POST", extra=""):
        """One request through the real handler, no socket. `key=None` sends no header; `body` is bytes or a dict."""
        data = body if isinstance(body, bytes) else json.dumps({"text": "probe"} if body is None else body).encode()
        head = f"{method} {path or self.path} HTTP/1.0\r\n"
        if extra != "no-length":
            head += f"Content-Length: {len(data)}\r\n"
        if key is not None:
            head += f"X-SwarmHub-Key: {key}\r\n"
        if extra and extra != "no-length":
            head += extra
        connection = Connection((head + "\r\n").encode() + data)
        control.webhook.request_handler()(connection, ("127.0.0.1", 0), None)
        answer = Answer(connection.output)
        self.assertNotIn(self.key.encode(), connection.output, "no answer ever carries the key")
        return answer

    def delivered(self, ident):
        with control.database() as db:
            return db.execute("SELECT sender,target,text,status FROM deliveries WHERE id=?", (ident,)).fetchone()


class ProbeMatrixTests(WakeTestBase):
    """swapdesign3 §1: every probe's status, Content-Type and body, straight from the receiver."""

    def expect(self, answer, status, error=None):
        self.assertEqual((answer.status, answer.type), (status, JSON))
        if error:
            self.assertEqual(answer.body, {"error": error})

    def test_probes_a_to_f(self):
        a = self.post(key=self.key)
        self.expect(a, 202)
        self.assertEqual(a.body["status"], "pending")
        self.expect(self.post(key=None), 400, "bad request")                           # b: no header (and no body key)
        self.expect(self.post(key="wrong"), 403, "webhook rejected")                   # c
        self.expect(self.post(key=self.key, path=self.path.rsplit("/", 1)[0] + "/wrongslug"), 403, "webhook rejected")  # d
        e = self.post(key="probe", path="/swarmhub/webhook/recipient/absent-20261024/x")
        self.expect(e, 404, "unknown webhook")                                         # e: the unambiguous 404
        f = self.post(key="probe", path="/swarmhub/webhook/elsewhere/absent-20261024/x")
        self.expect(f, 400, "bad request")                                             # f: P is not in this home
        # e's look-alikes: a two-segment path and a GET also give a JSON 404, so the probe must use three segments.
        self.expect(self.post(key="probe", path="/swarmhub/webhook/recipient/absent"), 404, "unknown webhook")
        self.expect(self.post(key=self.key, method="GET", extra="no-length", body=b""), 404, "unknown webhook")
        with control.database() as db:
            self.assertEqual(db.execute("SELECT fired FROM webhooks WHERE routine='canary'").fetchone()[0], 1,
                             "only probe a fired; e never wakes anything")

    def test_v6_receiver_side_negatives(self):
        over = json.dumps({"text": "x" * 32480}).encode()
        over += b" " * (32500 - len(over))
        self.assertEqual(len(over), 32500)
        self.expect(self.post(over, key=self.key), 400, "bad request")                 # 32,500 B: over TEXT_LIMIT
        chunked = self.post(key=self.key, extra="Transfer-Encoding: chunked\r\n")
        self.expect(chunked, 400, "bad request")  # nginx must buffer: a passed-through TE is refused here
        self.expect(self.post({"message": "probe"}, key=self.key), 202)                # 400 before this PR
        put = self.post(key=self.key, method="PUT")
        self.assertEqual(put.status, 501)                                              # the stdlib's page, not ours
        self.assertNotEqual(put.type, JSON)


class MessageFieldTests(WakeTestBase):
    def test_message_is_the_fallback_and_text_wins_when_both_are_sent(self):
        for body, journaled in (({"message": "job abc done"}, "job abc done"),
                                ({"text": "from text", "message": "from message"}, "from text"),
                                ({"text": "  ", "message": "blank text falls back"}, "blank text falls back"),
                                ({"text": None, "message": "null text falls back"}, "null text falls back")):
            with self.subTest(body=body):
                answer = self.post(body, key=self.key)
                self.assertEqual(answer.status, 202, answer.body)
                row = self.delivered(answer.body["delivery"])
                self.assertEqual((row["sender"], row["target"], row["status"]), ("recipient", "recipient", "pending"))
                self.assertEqual(row["text"], f"[Webhook routine canary for recipient]\n{journaled}")

    def test_neither_or_a_non_string_is_still_a_bad_request(self):
        for body in ({}, {"text": ""}, {"message": ""}, {"message": 7}, {"text": 7, "message": "x"}, {"message": ["x"]},
                     {"text": "", "message": "   "}):
            with self.subTest(body=body):
                self.assertEqual(self.post(body, key=self.key).status, 400)

    def test_cli_fire_reads_message_too(self):
        done = self.ctl("webhook", "fire", "recipient", "canary", self.slug, payload={"key": self.key, "message": "cli"})
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(self.delivered(json.loads(done.stdout)["delivery"])["text"],
                         "[Webhook routine canary for recipient]\ncli")
        self.assertNotIn(self.key, done.stdout + done.stderr)


class BodyKeyTests(WakeTestBase):
    def test_a_body_key_counts_only_when_the_header_is_missing(self):
        for header, body_key, status in ((None, "KEY", 202),       # Cloudflare stripped the header
                                         ("", "KEY", 202),         # the header arrived empty
                                         (None, "wrong", 403),
                                         ("wrong", "KEY", 403),    # a header that arrives always wins
                                         ("KEY", "wrong", 202),
                                         (None, "", 400),
                                         (None, 7, 400)):
            with self.subTest(header=header, body_key=body_key):
                fix = lambda value: self.key if value == "KEY" else value  # noqa: E731
                answer = self.post({"text": "wake", "key": fix(body_key)}, key=fix(header))
                self.assertEqual(answer.status, status, answer.body)

    def test_a_body_key_works_with_message_and_with_a_digest_stored_key(self):
        secret = "app-generated-key-for-the-body-path"
        import hashlib
        record = control.webhook.register("recipient", "hashed", "sha256:" + hashlib.sha256(secret.encode()).hexdigest())
        path = record["url"].split("8745", 1)[1]
        answer = self.post({"message": "job x done", "key": secret}, path=path)
        self.assertEqual(answer.status, 202, answer.body)
        self.assertNotIn(secret, json.dumps(answer.body))
        digest = "sha256:" + hashlib.sha256(secret.encode()).hexdigest()
        self.assertEqual(self.post({"text": "x", "key": digest}, path=path).status, 403, "the digest is not a key")


class ReceiverPortTests(WakeTestBase):
    def test_systemd_install_on_a_chosen_port_is_kept_by_later_installs_and_status(self):
        self.manager("systemd")
        seen = self.calls()
        first = receiver.install(8761)
        unit = receiver.unit_path("systemd").read_text()
        self.assertIn(f"ExecStart={receiver.interpreter()} -B {SWARMCTL.resolve()} webhook serve 8761\n", unit)
        self.assertIn("Description=Swarm Hub webhook receiver (127.0.0.1:8761)\n", unit)
        self.assertEqual((first["port"], first["listen"], first["changed"]), (8761, "127.0.0.1:8761", True))
        self.assertEqual(receiver.installed_port(), 8761)
        seen.clear()
        again = receiver.install()  # the setup path (ensure) and the app's panel call pass no port
        self.assertEqual((again["port"], again["changed"]), (8761, False))
        self.assertNotIn(["systemctl", "--user", "restart", receiver.NAME], seen, "an unchanged port is not restarted")
        self.assertEqual(receiver.ensure()["port"], 8761)
        self.assertEqual(receiver.status()["port"], 8761)
        self.assertTrue(control.webhook.show("recipient", "canary")["url"].startswith("http://127.0.0.1:8761/"))
        moved = receiver.install(8745)
        self.assertEqual((moved["port"], moved["changed"]), (8745, True))
        self.assertIn("webhook serve 8745\n", receiver.unit_path("systemd").read_text())

    def test_launchd_and_the_fallback_supervisor_remember_the_port(self):
        self.manager("launchd")
        self.calls()
        receiver.install(8762)
        plist = plistlib.loads(receiver.unit_path("launchd").read_bytes())
        self.assertEqual(plist["ProgramArguments"][-3:], ["webhook", "serve", "8762"])
        self.assertEqual((receiver.installed_port(), receiver.status()["port"]), (8762, 8762))
        receiver.uninstall()
        self.manager("systemd")
        self.calls({"loginctl": (0, "no")})  # no lingering: the fallback supervisor, which records its port
        started = []
        fallback_start = fallback.start
        try:
            fallback.start = lambda python, port: (started.append(port),
                                                   fallback.paths()["marker"].write_text(json.dumps({"port": port})))
            receiver.install(8763)
        finally:
            fallback.start = fallback_start
        self.assertEqual(started, [8763])
        self.assertEqual((receiver.installed_port(), receiver.status()["port"]), (8763, 8763))

    def test_nothing_installed_means_the_default_and_bad_ports_are_refused(self):
        self.assertIsNone(receiver.installed_port())
        self.assertEqual(receiver.status()["port"], 8745)
        self.manager("systemd")  # a manager that would install: only the port check can refuse
        seen = self.calls()
        for bad in (0, 65536, -1, "x", "87 45", True, 1.5, ""):
            with self.subTest(port=bad), self.assertRaisesRegex(ValueError, "receiver port must be"):
                receiver.install(bad)
        self.assertEqual(seen, [], "a refused port reaches no service manager")
        self.assertFalse(receiver.unit_path("systemd").exists())
        unit = receiver.unit_path("systemd")
        unit.parent.mkdir(parents=True)
        for text in ("ExecStart=/usr/bin/python3 -B swarmctl webhook serve banana\n",
                     "# webhook serve 8799\nExecStart=/usr/bin/python3 -B swarmctl webhook serve \n",
                     "ExecStart=/usr/bin/python3 -B swarmctl alerts serve 8799\n"):
            with self.subTest(unit=text):
                unit.write_text(text)
                self.assertIsNone(receiver.installed_port(), "an unreadable port falls back to the default")
                self.assertEqual(receiver.status()["port"], 8745)
        unit.write_text("ExecStart=/usr/bin/python3 -B swarmctl webhook serve 8799 \n")  # trailing space
        self.assertEqual(receiver.installed_port(), 8799)
        unit.unlink()
        self.manager("launchd")
        plist = receiver.unit_path("launchd")
        plist.parent.mkdir(parents=True)
        for args in ("8745", ["python3", "swarmctl", "other", "8799"]):
            with self.subTest(plist=args):
                plist.write_bytes(plistlib.dumps({"Label": receiver.LABEL, "ProgramArguments": args}))
                self.assertIsNone(receiver.installed_port())

    def test_cli_receiver_port_flag(self):
        status = self.ctl("webhook", "receiver", "status", "--port", "8764")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)["port"], 8764)
        for argv, why in ((("install", "--port", "0"), "receiver port must be"),
                          (("status", "--port", "x"), "receiver port must be"),
                          (("install", "--port"), "webhook receiver install|status"),
                          (("uninstall", "--port", "8764"), "webhook receiver install|status"),
                          (("install", "8764"), "webhook receiver install|status"),
                          (("restart",), "webhook receiver install|status")):
            with self.subTest(argv=argv):
                done = self.ctl("webhook", "receiver", *argv)
                self.assertEqual(done.returncode, 64)
                self.assertIn(why, done.stderr)
        refused = self.ctl("webhook", "receiver", "install", "--port", "8764")
        self.assertEqual(refused.returncode, 64)  # manager "none" in a temporary HOME: refused, but the flag parsed
        self.assertIn("no supported service manager", refused.stderr)


if __name__ == "__main__":
    unittest.main()
