"""Webhook receiver fallback: where no lingering systemd user manager answers, a lock-guarded supervisor keeps the
loopback receiver running and the gateway resumes it. Service managers are stubs; the one real supervisor runs inside
the temporary HOME and is stopped by its test."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import os
from pathlib import Path
import socket
import subprocess
import unittest
from unittest.mock import patch
import urllib.request

from test_webhooks_live import SWARMCTL, ReceiverTestBase, control, fallback, receiver

class FallbackSupervisorTests(ReceiverTestBase):
    def free_port(self):
        try:
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                return probe.getsockname()[1]
        except PermissionError:
            self.skipTest("sandbox forbids loopback sockets")

    def test_without_a_user_manager_install_falls_back_to_the_supervisor(self):
        self.manager("systemd")
        self.calls({"systemctl --user daemon-reload": (1, "Failed to connect to bus: No medium found")})
        spawned = []
        with patch.object(fallback, "spawn", side_effect=lambda python, port: spawned.append((python, port))), \
                patch.object(receiver, "probe", return_value=False):
            answer = receiver.install()
            self.assertEqual(spawned, [(receiver.interpreter(), 8745)])
            self.assertFalse(receiver.unit_path("systemd").exists(), "the unused unit is not left behind")
            self.assertEqual(json.loads(fallback.paths()["marker"].read_text()), {"port": 8745, "python": receiver.interpreter()})
            self.assertEqual((answer["manager"], answer["installed"], answer["service"], answer["running"]),
                             ("supervisor", True, "stopped", False))
            self.assertEqual(answer["logs"], str(self.home / ".hermes/swarmhub/logs/webhook-receiver.log"))
            self.assertIn("Logs: " + answer["logs"], answer["detail"])
            self.assertEqual(receiver.uninstall(), {"manager": "supervisor", "removed": True})
            self.assertFalse(fallback.enabled())
        self.calls({"systemctl": (127, "systemctl not found")})  # No systemctl at all: the same fallback.
        with patch.object(fallback, "spawn"), patch.object(receiver, "probe", return_value=False):
            self.assertEqual(receiver.install()["manager"], "supervisor")

    def test_other_systemctl_failures_still_raise(self):
        self.manager("systemd")
        self.calls({"systemctl --user restart": (1, "Job for swarmhub-webhook.service failed")})
        with self.assertRaisesRegex(ValueError, "restart failed"):
            receiver.install()
        self.assertFalse(fallback.enabled())

    def test_supervisor_restarts_a_crashing_receiver_with_backoff_and_stops_with_its_marker(self):
        fallback.paths()["marker"].write_text('{"port": 1}')
        starts, sleeps = [], []

        class Crashed:
            def poll(self):
                return 1

        def popen(argv, **kw):
            starts.append(argv)
            self.assertIsNotNone(fallback.holder(), "the lock names the running supervisor")
            self.assertEqual(fallback.supervise(1, popen=lambda *a, **k: self.fail("second supervisor ran")), 0)
            return Crashed()

        def sleep(seconds):
            sleeps.append(len(starts))
            if len(starts) == 4:
                fallback.stop()
        self.assertEqual(fallback.supervise(1, python="/usr/bin/python3", sleep=sleep, popen=popen), 0)
        self.assertEqual(len(starts), 4)
        self.assertEqual(starts[0], ["/usr/bin/python3", "-B", str(SWARMCTL.resolve()), "webhook", "serve", "1"])
        self.assertEqual([sleeps.count(n) for n in (1, 2, 3)], [2, 4, 8], "1 s doubles after each quick crash")
        self.assertIsNone(fallback.holder())
        self.assertTrue(fallback.paths()["log"].parent.is_dir())

    def test_removing_the_marker_terminates_the_running_receiver(self):
        fallback.paths()["marker"].write_text('{"port": 1}')
        events = []

        class Running:
            def poll(self):
                return None if "terminate" not in events else 0

            def terminate(self):
                events.append("terminate")

            def wait(self, timeout=None):
                events.append("wait")
        self.assertEqual(fallback.supervise(1, sleep=lambda s: fallback.stop(), popen=lambda *a, **k: Running()), 0)
        self.assertEqual(events, ["terminate", "wait"])

    def test_a_real_supervisor_serves_and_stops(self):
        port = self.free_port()
        record = control.webhook.register("recipient", "nightly")
        fallback.start("/usr/bin/python3", port)
        self.addCleanup(fallback.stop)
        self.eventually(lambda: receiver.probe(port, timeout=0.5))
        pid = fallback.holder()
        self.assertTrue(pid and pid != os.getpid())
        key = Path(record["key_file"]).read_text().strip()
        request = urllib.request.Request(f"http://127.0.0.1:{port}" + record["url"].split("8745", 1)[1],
                                         data=b'{"text": "via the supervisor"}', method="POST",
                                         headers={"X-SwarmHub-Key": key, "Content-Type": "application/json"})
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=5) as response:
            self.assertEqual(response.status, 202)
        log = fallback.paths()["log"].read_text()
        self.assertIn(f"swarmhub-webhook: listening on 127.0.0.1:{port}", log)
        self.assertNotIn(key, log)
        self.assertNotIn("via the supervisor", log)
        fallback.stop()
        self.eventually(lambda: fallback.holder() is None and not receiver.probe(port, timeout=0.5))

    def test_gateway_start_resumes_only_a_recorded_fallback(self):
        spawned = []
        with patch.object(fallback, "spawn", side_effect=lambda python, port: spawned.append((python, port))):
            receiver.resume()
            self.assertEqual(spawned, [])
            fallback.paths()["marker"].write_text('{"port": 8800, "python": "/usr/bin/python3"}')
            receiver.resume()
            self.assertEqual(spawned, [("/usr/bin/python3", 8800)])
            fallback.paths()["marker"].write_text("not json")
            receiver.resume()  # Never raises into the plugin.
        self.assertEqual(len(spawned), 1)

    def test_systemctl_finds_the_user_manager_without_the_gateway_env(self):
        seen = {}

        def fake(argv, **kw):
            seen["env"] = kw["env"]
            return subprocess.CompletedProcess(argv, 0, "active", "")
        os.environ.pop("XDG_RUNTIME_DIR", None)
        with patch.object(receiver.subprocess, "run", side_effect=fake), patch.object(receiver.os.path, "isdir", return_value=True):
            self.assertEqual(receiver.run("systemctl", "--user", "is-active", "x"), (0, "active"))
        self.assertEqual(seen["env"]["XDG_RUNTIME_DIR"], f"/run/user/{os.getuid()}")


if __name__ == "__main__":
    unittest.main()
