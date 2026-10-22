"""Webhook receiver fallback: where no lingering systemd user manager answers, a lock-guarded supervisor keeps the
loopback receiver running and the gateway resumes it. Service managers are stubs; the one real supervisor runs inside
the temporary HOME and is stopped by its test."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import unittest
from unittest.mock import patch
import urllib.request

from test_webhooks_live import SWARMCTL, ReceiverTestBase, control, fallback, receiver

# The supervisor and receiver modules as they shipped before the pidfile (58feb41), for the upgrade from that layout.
PRE_PIDFILE = Path(__file__).resolve().parent / "fixtures/webhooks-prepidfile"

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
            pid = 4_000_000  # Above any pid_max: never a live process.

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
            pid = 4_000_000

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

    def test_an_upgrade_restarts_only_the_receiver_whose_code_changed(self):
        port = self.free_port()
        scripts = self.home / "skill-copy/scripts"  # A live copy this test may change, like a skill update does.
        shutil.copytree(SWARMCTL.parent, scripts, ignore=shutil.ignore_patterns("__pycache__"))
        fallback.paths()["marker"].write_text(json.dumps({"port": port, "python": "/usr/bin/python3"}))
        self.addCleanup(fallback.stop)
        fallback.store.spawn(["/usr/bin/python3", "-B", str(scripts / "swarm_webhook_supervisor.py"), str(port)])
        self.eventually(lambda: receiver.probe(port, timeout=0.5) and fallback.receiver_pid()[0])
        supervisor, (old, record) = fallback.holder(), fallback.receiver_pid()
        self.assertEqual(record["cmd"], ["/usr/bin/python3", "-B", str(scripts / "swarmctl"), "webhook", "serve", str(port)])
        self.assertEqual(record["code"], fallback.digest(scripts))
        self.assertFalse(fallback.refresh(), "unchanged code is left running")
        fallback.start("/usr/bin/python3", port)
        self.assertEqual((fallback.holder(), fallback.receiver_pid()[0]), (supervisor, old))

        with (scripts / "swarm_webhook.py").open("a") as code:
            code.write("\n# a skill update\n")
        decoy = subprocess.Popen(["sleep", "60"], start_new_session=True)  # Not the supervisor's child.
        self.addCleanup(decoy.wait)
        self.addCleanup(decoy.kill)
        pidfile = fallback.paths()["pid"]
        for forged in ({**record, "cmd": record["cmd"][:-1] + ["1"]},  # another command line on that pid
                       {**record, "start": "Thu Jan  1 00:00:00 1970"},  # a recycled pid
                       {**record, "pid": decoy.pid, "cmd": ["sleep", "60"], "start": fallback.store.process_start(decoy.pid)}):
            pidfile.write_text(json.dumps(forged))
            self.assertFalse(fallback.refresh(), forged)
        self.assertIsNone(decoy.poll(), "a process outside the supervisor's group is never signalled")
        pidfile.write_text(json.dumps(record))

        fallback.start("/usr/bin/python3", port)  # The install after the update.
        self.eventually(lambda: fallback.receiver_pid()[0] not in (None, old) and receiver.probe(port, timeout=0.5))
        self.assertEqual(fallback.holder(), supervisor, "the supervisor keeps running; only its receiver restarted")
        self.assertEqual(fallback.receiver_pid()[1]["code"], fallback.digest(scripts))
        with self.assertRaises(ProcessLookupError):
            os.kill(old, 0)
        fallback.stop()
        self.eventually(lambda: fallback.holder() is None and not receiver.probe(port, timeout=0.5))
        self.assertFalse(pidfile.exists())

    def test_an_upgrade_from_a_pre_pidfile_supervisor_restarts_its_receiver_once(self):
        port = self.free_port()
        scripts = self.home / "skill-copy/scripts"
        shutil.copytree(SWARMCTL.parent, scripts, ignore=shutil.ignore_patterns("__pycache__"))
        for name in ("swarm_webhook_supervisor.py", "swarm_webhook_receiver.py"):
            shutil.copyfile(PRE_PIDFILE / name, scripts / name)
        time.sleep(1.1)  # The receiver's age is read in whole seconds: let it start surely after this code appeared.
        fallback.paths()["marker"].write_text(json.dumps({"port": port, "python": "/usr/bin/python3"}))
        self.addCleanup(fallback.stop)
        fallback.store.spawn(["/usr/bin/python3", "-B", str(scripts / "swarm_webhook_supervisor.py"), str(port)])
        self.eventually(lambda: receiver.probe(port, timeout=0.5) and fallback.legacy_receiver())
        pidfile, supervisor = fallback.paths()["pid"], fallback.holder()
        self.assertFalse(pidfile.exists(), "the old supervisor never writes the pidfile")
        old, cmd, folder = fallback.legacy_receiver()
        self.assertEqual((cmd, folder), (f"/usr/bin/python3 -B {scripts}/swarmctl webhook serve {port}", scripts))
        self.assertEqual(fallback.ps("-o", "ppid=", "-p", str(old)).strip(), str(supervisor))
        self.assertFalse(fallback.refresh(), "a receiver that started on the code on disk is left running")
        decoy = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.addCleanup(decoy.wait)
        self.addCleanup(decoy.kill)

        shutil.copytree(SWARMCTL.parent, scripts, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__"))
        fallback.start("/usr/bin/python3", port)  # The install after the skill update.
        self.eventually(lambda: (fallback.legacy_receiver() or [old])[0] != old and receiver.probe(port, timeout=0.5))
        with self.assertRaises(ProcessLookupError):
            os.kill(old, 0)
        self.assertEqual(fallback.holder(), supervisor, "the old supervisor restarted its receiver on the new code")
        self.assertIsNone(decoy.poll(), "nothing else is signalled")
        new = fallback.legacy_receiver()[0]
        self.assertFalse(fallback.refresh(), "the receiver it restarted runs the new code: later installs leave it")
        fallback.start("/usr/bin/python3", port)
        time.sleep(0.5)
        self.assertEqual(fallback.legacy_receiver()[0], new)
        fallback.stop()
        self.eventually(lambda: fallback.holder() is None and not receiver.probe(port, timeout=0.5))

    def test_a_pre_pidfile_receiver_is_only_the_supervisors_one_exact_child(self):
        lock = fallback.paths()["lock"]
        lock.write_text("4000")
        folder = "/home/x/.hermes/skills/swarmhub/swarmhub-messages/scripts"
        supervisor = f"4000 1 4000 /usr/bin/python3 -B {folder}/swarm_webhook_supervisor.py 8745"
        child = f"/usr/bin/python3 -B {folder}/swarmctl webhook serve 8745"
        cases = {"the one exact child": ([supervisor, f"4001 4000 4000 {child}"], 4001),
                 "another parent": ([supervisor, f"4001 1 4000 {child}"], None),
                 "another group": ([supervisor, f"4001 4000 4001 {child}"], None),
                 "another port": ([supervisor, f"4001 4000 4000 {child[:-4]}8746"], None),
                 "another folder": ([supervisor, f"4001 4000 4000 {child.replace('/x/', '/y/')}"], None),
                 "another python": ([supervisor, f"4001 4000 4000 /tmp/python3{child[16:]}"], None),
                 "two candidates": ([supervisor, f"4001 4000 4000 {child}", f"4002 4000 4000 {child}"], None),
                 "not our supervisor": ([supervisor.replace("swarm_webhook_supervisor.py", "other.py"),
                                         f"4001 4000 4000 {child}"], None)}
        for name, (rows, expected) in cases.items():
            with patch.object(fallback, "holder", return_value=4000), \
                    patch.object(fallback, "ps", return_value="\n".join(rows) + "\n"):
                found = fallback.legacy_receiver()
                self.assertEqual(found and found[0], expected, name)
                if expected:
                    self.assertEqual(found[1:], (child, Path(folder)))
        with patch.object(fallback, "holder", return_value=4000), \
                patch.object(fallback, "ps", return_value=f"{supervisor}\n4001 4000 4000 {child}\n"):
            fallback.paths()["pid"].write_text("{}")
            self.assertIsNone(fallback.legacy_receiver(), "a pidfile means a current supervisor: its record decides")

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
