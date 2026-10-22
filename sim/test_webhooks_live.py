"""Webhooks out of the box: the supervised loopback receiver (systemd user unit / LaunchAgent), its idempotent install
from the skill's setup path, the app's panel call (key generated on the Mac, only its sha256 on the box), delete and
the receiver's health check. Service managers are stubs: nothing is installed or enabled outside the temporary HOME."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import socket
import stat
import subprocess
import threading
import unittest
from unittest.mock import patch
import urllib.error
import urllib.request

import test_peer_runtime as boundary

peer = boundary.peer
control = peer.control
receiver = control.receiver
fallback = receiver.fallback
SWARMCTL = boundary.RUNTIME.with_name("swarmctl")


def digest(key):
    return "sha256:" + hashlib.sha256(key.encode()).hexdigest()


class Connection:
    """A socketless HTTP connection for the receiver's handler."""
    def __init__(self, raw):
        self.raw, self.output = raw, b""

    def makefile(self, *args):
        return io.BytesIO(self.raw)

    def sendall(self, data):
        self.output += data


class ReceiverTestBase(unittest.TestCase):
    setUp = boundary.PeerTests.setUp
    sync = boundary.PeerTests.sync
    stop_background = boundary.PeerTests.stop_background
    eventually = boundary.PeerTests.eventually

    def calls(self, codes=None):
        """Patch the receiver's service-manager runner; record every argv and answer from `codes`."""
        seen = []

        def fake(*args):
            seen.append(list(args))
            for prefix, code in (codes or {}).items():
                if " ".join(args).startswith(prefix):
                    return code if isinstance(code, tuple) else (code, "stub " + prefix)
            return 0, "active"
        patcher = patch.object(receiver, "run", side_effect=fake)
        patcher.start()
        self.addCleanup(patcher.stop)
        return seen

    def manager(self, kind):
        self.env["SWARMHUB_RECEIVER_MANAGER"] = kind
        os.environ["SWARMHUB_RECEIVER_MANAGER"] = kind

    def ctl(self, *args, payload=None):
        env = dict(self.env)
        env.setdefault("SWARMHUB_RECEIVER_MANAGER", "none")
        return subprocess.run(["/usr/bin/python3", "-B", str(SWARMCTL), *args], env=env, capture_output=True, text=True,
                              input=json.dumps(payload) if payload is not None else None, timeout=20)


class ReceiverUnitTests(ReceiverTestBase):
    def test_systemd_unit_install_is_idempotent_supervised_loopback_and_keyless(self):
        self.manager("systemd")
        seen = self.calls()
        record = control.webhook.register("recipient", "nightly")
        key = Path(record["key_file"]).read_text().strip()
        first = receiver.install()
        unit = self.home / ".config/systemd/user/swarmhub-webhook.service"
        text = unit.read_text()
        self.assertTrue(first["changed"])
        self.assertEqual(stat.S_IMODE(unit.stat().st_mode), 0o600)
        self.assertIn(f"ExecStart={receiver.interpreter()} -B {SWARMCTL.resolve()} webhook serve 8745\n", text)
        for line in ("Restart=on-failure", "RestartSec=10", "StartLimitIntervalSec=300", "StartLimitBurst=10", "Environment=PYTHONDONTWRITEBYTECODE=1", "UMask=0077",
                     "NoNewPrivileges=yes", "WantedBy=default.target", "Description=Swarm Hub webhook receiver (127.0.0.1:8745)"):
            self.assertIn(line + "\n", text)
        self.assertNotIn(key, text, "the unit never carries a webhook key")
        self.assertNotIn("0.0.0.0", text)
        self.assertEqual(seen, [["loginctl", "show-user", str(os.getuid()), "--property=Linger", "--value"],
                                ["systemctl", "--user", "daemon-reload"],
                                ["systemctl", "--user", "enable", "swarmhub-webhook.service"],
                                ["systemctl", "--user", "restart", "swarmhub-webhook.service"],
                                ["systemctl", "--user", "is-active", "swarmhub-webhook.service"]])
        seen.clear()
        again = receiver.install()
        self.assertFalse(again["changed"])
        self.assertEqual(unit.read_text(), text)
        self.assertEqual(seen[1:3], [["systemctl", "--user", "enable", "swarmhub-webhook.service"],
                                    ["systemctl", "--user", "start", "swarmhub-webhook.service"]],
                         "an unchanged unit is not reloaded or restarted")
        self.assertEqual((again["manager"], again["installed"], again["logs"]),
                         ("systemd", True, "journalctl --user -u swarmhub-webhook.service"))

    def test_a_new_skill_version_rewrites_and_restarts_and_an_existing_copy_is_kept(self):
        self.manager("systemd")
        seen = self.calls()
        # Another profile's copy of the skill installed the unit first; a batch over profiles keeps that copy.
        other = self.home / ".hermes/profiles/worker/skills/swarmhub/swarmhub-messages/scripts"
        other.mkdir(parents=True)
        for name in receiver.CODE:
            (other / name).write_bytes((SWARMCTL.parent / name).read_bytes())
        unit = receiver.unit_path("systemd")
        unit.parent.mkdir(parents=True)
        unit.write_text(receiver.systemd_text(receiver.interpreter(), other / "swarmctl"))
        self.assertFalse(receiver.install()["changed"])
        self.assertIn(f"-B {other / 'swarmctl'} webhook serve", unit.read_text())
        (other / "swarm_webhook.py").write_text((other / "swarm_webhook.py").read_text() + "# next version\n")
        seen.clear()
        self.assertTrue(receiver.install()["changed"], "a changed receiver module changes the unit's code digest")
        self.assertIn(["systemctl", "--user", "restart", "swarmhub-webhook.service"], seen)
        (other / "swarmctl").unlink()
        receiver.install()
        self.assertIn(f"-B {SWARMCTL.resolve()} webhook serve", unit.read_text(), "a vanished copy is replaced by this one")

    def test_launchd_agent_restarts_on_failure_and_logs_under_the_user_library(self):
        self.manager("launchd")
        codes = {"launchctl print": 113}
        seen = self.calls(codes)
        receiver.install()
        plist = self.home / "Library/LaunchAgents/com.swarmhub.webhook.plist"
        body = plistlib.loads(plist.read_bytes())
        self.assertEqual(body["ProgramArguments"][1:], ["-B", str(SWARMCTL.resolve()), "webhook", "serve", "8745"])
        self.assertEqual((body["Label"], body["RunAtLoad"], body["KeepAlive"]), ("com.swarmhub.webhook", True, {"SuccessfulExit": False}))
        log = str(self.home / "Library/Logs/SwarmHub/webhook-receiver.log")
        self.assertEqual((body["StandardOutPath"], body["StandardErrorPath"]), (log, log))
        self.assertTrue(Path(log).parent.is_dir())
        domain = f"gui/{os.getuid()}"
        self.assertEqual([c for c in seen if c[1] != "print"],
                         [["launchctl", "bootstrap", domain, str(plist)], ["launchctl", "kickstart", f"{domain}/com.swarmhub.webhook"]])
        self.assertEqual(receiver.current_target("launchd"), SWARMCTL.resolve())
        seen.clear()
        codes.clear()  # Now loaded: an unchanged agent is only kicked.
        self.assertFalse(receiver.install()["changed"])
        self.assertEqual([c for c in seen if c[1] != "print"], [["launchctl", "kickstart", f"{domain}/com.swarmhub.webhook"]])

    def test_a_refusing_manager_raises_for_the_cli_and_never_breaks_the_setup_path(self):
        self.manager("systemd")
        self.calls({"systemctl --user enable": 1})
        with self.assertRaisesRegex(ValueError, "systemctl --user enable failed"):
            receiver.install()
        answer = receiver.ensure()
        self.assertFalse(answer["running"])
        self.assertIn("webhook receiver not started", answer["detail"])

    def test_a_temporary_home_never_reaches_the_real_service_manager(self):
        os.environ.pop("SWARMHUB_RECEIVER_MANAGER", None)
        seen = self.calls()
        self.assertEqual(receiver.manager(), "none")
        with self.assertRaisesRegex(ValueError, "no supported service manager"):
            receiver.install()
        self.assertEqual(seen, [])
        self.assertFalse(receiver.unit_path("systemd").exists())
        state = receiver.status(port=1)
        self.assertEqual((state["manager"], state["installed"], state["running"]), ("none", False, False))

    def test_status_names_the_problem_and_uninstall_removes_the_unit(self):
        self.manager("systemd")
        seen = self.calls({"systemctl --user is-active": 3})
        missing = receiver.status(port=1)
        self.assertEqual((missing["installed"], missing["running"]), (False, False))
        self.assertIn("not installed", missing["detail"])
        receiver.install(port=1)
        stuck = receiver.status(port=1)
        self.assertEqual((stuck["installed"], stuck["running"], stuck["listen"]), (True, False, "127.0.0.1:1"))
        self.assertIn("installed", stuck["detail"])
        self.assertIn("journalctl --user -u swarmhub-webhook.service", stuck["detail"])
        seen.clear()
        self.assertEqual(receiver.uninstall(), {"manager": "systemd", "removed": True})
        self.assertFalse(receiver.unit_path().exists())
        self.assertEqual(seen, [["systemctl", "--user", "disable", "--now", "swarmhub-webhook.service"],
                                ["systemctl", "--user", "daemon-reload"]])
        self.assertEqual(receiver.uninstall()["removed"], False)

    def test_peer_install_also_ensures_the_receiver(self):
        ensured = []
        with patch.object(control.receiver, "ensure", side_effect=lambda: ensured.append(1) or {"running": True}):
            peer.install("recipient")
        self.assertEqual(ensured, [1])
        self.assertTrue((self.home / ".hermes/profiles/recipient/plugins/swarmhub-peer/plugin.yaml").exists())

    def test_cli_receiver_verbs(self):
        status = self.ctl("webhook", "receiver", "status")
        self.assertEqual(status.returncode, 0, status.stderr)
        self.assertEqual(json.loads(status.stdout)["manager"], "none")
        refused = self.ctl("webhook", "receiver", "install")
        self.assertEqual(refused.returncode, 64)
        self.assertIn("no supported service manager", refused.stderr)
        self.assertEqual(self.ctl("webhook", "receiver", "restart").returncode, 64)


class ReceiverHealthTests(ReceiverTestBase):
    def handle(self, raw, on_fire=None):
        connection = Connection(raw)
        control.webhook.request_handler(on_fire)(connection, ("127.0.0.1", 0), None)
        return int(connection.output.split()[1]), connection.output

    def test_health_answers_without_naming_routines_and_accepted_calls_start_the_worker(self):
        record = control.webhook.register("recipient", "nightly")
        status, body = self.handle(b"GET /swarmhub/webhook/health HTTP/1.0\r\n\r\n")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body.split(b"\r\n\r\n", 1)[1]), {"ok": True, "service": "swarmhub-webhook"})
        self.assertNotIn(b"nightly", body)
        self.assertEqual(self.handle(b"GET /swarmhub/webhook/recipient HTTP/1.0\r\n\r\n")[0], 404)
        key = Path(record["key_file"]).read_text().strip()
        path = record["url"].split("8745", 1)[1]
        started = []
        for presented, expected in (("wrong", 403), (key, 202)):
            payload = b'{"text":"run"}'
            raw = (f"POST {path} HTTP/1.0\r\nContent-Length: {len(payload)}\r\nX-SwarmHub-Key: {presented}\r\n\r\n").encode() + payload
            self.assertEqual(self.handle(raw, on_fire=lambda: started.append(1))[0], expected)
        self.assertEqual(started, [1], "only an accepted call starts the delivery worker")

    def test_probe_tells_our_receiver_from_another_program(self):
        try:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
        except PermissionError:
            self.skipTest("sandbox forbids loopback sockets; the health handler is covered without sockets")
        ready, ports = threading.Event(), []
        thread = threading.Thread(target=control.webhook.serve, kwargs={"port": 0, "once": True,
                                  "ready": lambda p: (ports.append(p), ready.set())}, daemon=True)
        thread.start()
        self.assertTrue(ready.wait(5))
        self.assertTrue(receiver.probe(ports[0]))
        thread.join(5)
        self.assertFalse(receiver.probe(ports[0]), "nothing listens any more")
        with socket.socket() as other:
            other.bind(("127.0.0.1", 0))
            other.listen(1)
            self.assertFalse(receiver.probe(other.getsockname()[1], timeout=0.5))


class AppPanelTests(ReceiverTestBase):
    def panel(self, *args):
        return self.ctl("webhook", "panel", *args)

    def test_the_app_key_never_reaches_the_box_and_its_digest_verifies_calls(self):
        key = secrets.token_urlsafe(32)
        created = self.panel("recipient", "register", "nightly", "--key-hash", digest(key))
        self.assertEqual(created.returncode, 0, created.stderr)
        answer = json.loads(created.stdout)
        self.assertEqual((answer["schema"], answer["profile"], answer["action"]), ("swarmhub/webhooks/1", "recipient", "register"))
        self.assertEqual([row["routine"] for row in answer["webhooks"]], ["nightly"])
        self.assertEqual(answer["receiver"]["manager"], "none")
        record = answer["result"]
        key_file = Path(record["key_file"])
        self.assertEqual(key_file.read_text().strip(), digest(key))
        self.assertEqual(stat.S_IMODE(key_file.stat().st_mode), 0o600)
        self.assertNotIn(key, created.stdout + created.stderr)
        slug = record["url"].rsplit("/", 1)[1]
        self.assertEqual(control.webhook.fire("recipient", "nightly", slug, key, "from the app key")["status"], "pending")
        for wrong in ("wrong", digest(key), digest(key)[7:]):
            with self.assertRaises(PermissionError):
                control.webhook.fire("recipient", "nightly", slug, wrong, "the digest itself is not a key")
        same = self.panel("recipient", "register", "nightly", "--key-hash", digest(key))
        self.assertEqual(same.returncode, 0, "repeating the same create (a retried turn) is idempotent")
        other = self.panel("recipient", "register", "nightly", "--key-hash", digest("another"))
        self.assertEqual(other.returncode, 64)
        self.assertIn("already exists", other.stderr)
        self.assertEqual(key_file.read_text().strip(), digest(key), "a clashing create never changes the key")

    def test_rotate_with_a_new_digest_rejects_the_old_key_at_once(self):
        old, new = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        record = json.loads(self.panel("recipient", "register", "nightly", "--key-hash", digest(old)).stdout)["result"]
        slug = record["url"].rsplit("/", 1)[1]
        rotated = json.loads(self.panel("recipient", "rotate", "nightly", "--key-hash", digest(new)).stdout)
        self.assertEqual(rotated["result"]["url"], record["url"], "rotation keeps the URL")
        self.assertGreaterEqual(rotated["result"]["rotated"], record["rotated"])
        with self.assertRaises(PermissionError):
            control.webhook.fire("recipient", "nightly", slug, old, "stale")
        self.assertEqual(control.webhook.fire("recipient", "nightly", slug, new, "fresh")["status"], "pending")
        # The CLI's own rotate still generates a key on the box and prints none of it.
        plain = self.ctl("webhook", "rotate", "recipient", "nightly")
        stored = Path(record["key_file"]).read_text().strip()
        self.assertFalse(stored.startswith("sha256:"))
        self.assertNotIn(stored, plain.stdout + plain.stderr)

    def test_delete_forgets_the_routine_and_its_key_file(self):
        record = json.loads(self.panel("recipient", "register", "nightly", "--key-hash", digest("k" * 40)).stdout)["result"]
        control.webhook.register("recipient", "weekly")
        deleted = json.loads(self.panel("recipient", "delete", "nightly").stdout)
        self.assertEqual(deleted["result"], {"profile": "recipient", "routine": "nightly", "deleted": True})
        self.assertEqual([row["routine"] for row in deleted["webhooks"]], ["weekly"])
        self.assertFalse(Path(record["key_file"]).exists())
        with self.assertRaises(control.webhook.UnknownWebhook):
            control.webhook.fire("recipient", "nightly", record["url"].rsplit("/", 1)[1], "k" * 40, "gone")
        again = json.loads(self.ctl("webhook", "delete", "recipient", "nightly").stdout)
        self.assertFalse(again["deleted"], "deleting twice is not an error")
        # A routine whose profile was removed stays deletable.
        control.webhook.register("worker", "orphan")
        shutil.rmtree(self.home / ".hermes/profiles/worker")
        self.assertTrue(control.webhook.delete("worker", "orphan")["deleted"])
        self.assertEqual(self.ctl("webhook", "delete", "recipient", "../x").returncode, 64)

    def test_panel_lists_one_profile_and_refuses_malformed_calls(self):
        control.webhook.register("recipient", "nightly")
        control.webhook.register("worker", "other")
        listed = json.loads(self.panel("recipient", "list").stdout)
        self.assertEqual([(row["profile"], row["routine"]) for row in listed["webhooks"]], [("recipient", "nightly")])
        self.assertIsNone(listed["result"])
        self.assertEqual(listed["receiver"]["running"], False)
        self.assertIn("service manager", listed["receiver"]["detail"])
        self.assertNotIn("sha256", json.dumps(listed))
        self.assertEqual([r["profile"] for r in json.loads(self.ctl("webhook", "list", "worker").stdout)], ["worker"])
        for args in (("recipient", "register", "x"), ("recipient", "register", "x", "--key-hash"),
                     ("recipient", "register", "x", "--key-hash", "sha256:" + "A" * 64),
                     ("recipient", "register", "x", "--key-hash", "md5:abc"), ("recipient", "list", "x"),
                     ("recipient", "delete"), ("recipient", "explode"), ("../etc", "list"), ("recipient", "rotate", "nightly")):
            result = self.panel(*args)
            self.assertEqual(result.returncode, 64, args)
            self.assertTrue(result.stderr.startswith("swarmctl: "), args)
        with control.database() as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM webhooks WHERE routine='x'").fetchone()[0], 0)

    def test_panel_receiver_install_answers_with_the_state_even_when_refused(self):
        answer = json.loads(self.panel("recipient", "receiver-install").stdout)
        self.assertIn("no supported service manager", answer["result"]["error"])
        self.assertEqual(answer["receiver"]["installed"], False)
        stub = self.home / "stub-bin/systemctl"
        stub.write_text("#!/bin/sh\necho \"$@\" >> \"$HOME/systemctl.log\"\necho inactive\n")
        stub.chmod(0o755)
        self.env["SWARMHUB_RECEIVER_MANAGER"] = "systemd"
        installed = json.loads(self.panel("recipient", "receiver-install").stdout)
        self.assertTrue(installed["result"]["changed"])
        self.assertEqual(installed["receiver"]["installed"], True)
        self.assertIn("--user enable swarmhub-webhook.service", (self.home / "systemctl.log").read_text())

    def test_an_account_without_lingering_uses_the_fallback_even_when_its_user_manager_answers(self):
        self.manager("systemd")
        codes = {}
        seen = self.calls(codes)
        receiver.install()  # Lingering (or unknown): the unit.
        self.assertTrue(receiver.unit_path("systemd").exists())
        codes["loginctl show-user"] = (0, "no")
        seen.clear()
        with patch.object(fallback, "spawn") as spawn, patch.object(receiver, "probe", return_value=False):
            answer = receiver.install()
        spawn.assert_called_once_with(receiver.interpreter(), 8745)
        self.assertEqual(answer["manager"], "supervisor")
        self.assertFalse(receiver.unit_path("systemd").exists())
        self.assertIn(["systemctl", "--user", "disable", "--now", "swarmhub-webhook.service"], seen)
        self.assertNotIn(["systemctl", "--user", "enable", "swarmhub-webhook.service"], seen)

    def test_a_listener_that_is_not_our_receiver_never_breaks_status(self):
        try:
            server = socket.socket()
            server.bind(("127.0.0.1", 0))
        except PermissionError:
            self.skipTest("sandbox forbids loopback sockets")
        server.listen(4)
        self.addCleanup(server.close)

        def answer(raw):
            connection, _ = server.accept()
            with connection:
                connection.recv(4096)
                connection.sendall(raw)
        for raw in (b"garbage that is not HTTP\r\n\r\n", b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\n[]",
                    b"HTTP/1.0 200 OK\r\nContent-Length: 4\r\n\r\nnull"):
            thread = threading.Thread(target=answer, args=(raw,), daemon=True)
            thread.start()
            self.assertFalse(receiver.probe(server.getsockname()[1], timeout=2), raw)
            thread.join(5)


if __name__ == "__main__":
    unittest.main()
