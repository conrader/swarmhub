"""Off-app alert service: the systemd user unit / LaunchAgent (service managers stubbed), the lock-held fallback that
stops when its marker goes (no signal is sent), the app's `swarmctl alerts panel` call end to end against a loopback
ntfy, and the producers that spool an alert (`swarmctl report`, an accepted webhook call)."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

import test_alerts as base

fixtures, alerts, seal, store = base.fixtures, base.alerts, base.seal, base.store
import swarm_alerts_service as service  # noqa: E402
import swarm_webhook_receiver as receiver  # noqa: E402

SWARMCTL = base.SCRIPTS / "swarmctl"


class ServiceInstall(base.AlertsBase):
    def calls(self, codes=None):
        seen = []

        def fake(*args):
            seen.append(list(args))
            for prefix, answer in (codes or {}).items():
                if " ".join(args).startswith(prefix):
                    return answer
            return 0, "yes" if args[0] == "loginctl" else ""
        patcher = patch.object(receiver, "run", fake)
        patcher.start()
        self.addCleanup(patcher.stop)
        return seen

    def test_systemd_unit_is_written_once_enabled_and_started(self):
        os.environ["SWARMHUB_RECEIVER_MANAGER"] = "systemd"
        seen = self.calls()
        self.assertEqual(service.install(), {"manager": "systemd", "changed": True})
        unit = self.home / ".config/systemd/user/swarmhub-alerts.service"
        text = unit.read_text()
        self.assertIn(f"-B {SWARMCTL} alerts run\n", text)
        self.assertIn("Restart=on-failure", text)
        self.assertEqual(unit.stat().st_mode & 0o777, 0o600)
        systemctl = [args for args in seen if args[0] == "systemctl"]
        self.assertEqual(systemctl, [["systemctl", "--user", "daemon-reload"], ["systemctl", "--user", "enable", service.NAME],
                                     ["systemctl", "--user", "restart", service.NAME]])
        seen.clear()
        self.assertFalse(service.install()["changed"])
        self.assertEqual([args for args in seen if args[0] == "systemctl"][-1], ["systemctl", "--user", "start", service.NAME])
        self.assertEqual(service.status()["installed"], True)
        self.assertTrue(service.uninstall()["removed"])
        self.assertFalse(unit.exists())

    def test_without_a_lingering_user_manager_the_fallback_is_recorded_and_started(self):
        os.environ["SWARMHUB_RECEIVER_MANAGER"] = "systemd"
        self.calls({"loginctl": (0, "no")})
        started = []
        with patch.object(service, "spawn", started.append):
            self.assertEqual(service.install(), {"manager": "supervisor", "changed": True})
        self.assertEqual(len(started), 1)
        self.assertTrue(service.fallback_paths()["marker"].exists())
        self.assertEqual(service.status()["manager"], "supervisor")
        self.assertFalse((self.home / ".config/systemd/user/swarmhub-alerts.service").exists())

    def test_launchd_agent_runs_the_service(self):
        os.environ["SWARMHUB_RECEIVER_MANAGER"] = "launchd"
        seen = self.calls({"launchctl print": (113, "not found")})
        service.install()
        plist = plistlib.loads((self.home / "Library/LaunchAgents/com.swarmhub.alerts.plist").read_bytes())
        self.assertEqual(plist["ProgramArguments"][1:], ["-B", str(SWARMCTL), "alerts", "run"])
        self.assertEqual([args[1] for args in seen if args[0] == "launchctl"], ["print", "bootstrap", "kickstart"])

    def test_the_fallback_runs_under_its_lock_and_stops_when_its_marker_goes(self):
        service.start_fallback(sys.executable)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and not (service.fallback_running() and alerts.status()["running"]):
            time.sleep(0.2)
        self.assertTrue(service.fallback_running())
        self.assertTrue(alerts.status()["running"])
        service.start_fallback(sys.executable)  # Idempotent: a second start leaves the one service alone.
        self.assertTrue(service.uninstall()["removed"])
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and service.fallback_running() is not None:
            time.sleep(0.2)
        self.assertIsNone(service.fallback_running())
        self.assertIn("swarmhub-alerts: running", service.fallback_paths()["log"].read_text())


    def test_gateway_start_resumes_a_recorded_fallback_and_never_raises(self):
        import swarm_control
        started = []
        with patch.object(service, "spawn", started.append):
            swarm_control.resume_services()
            self.assertEqual(started, [])  # Nothing recorded: nothing starts, and no alerts folder appears.
            self.assertFalse((store.state() / "alerts").exists())
            service.fallback_paths()["marker"].write_text(json.dumps({"python": "/usr/bin/python3"}))
            swarm_control.resume_services()
            self.assertEqual(started, ["/usr/bin/python3"])
            service.fallback_paths()["marker"].write_text("{broken")
            swarm_control.resume_services()
        self.assertEqual(len(started), 1)


class PanelEndToEnd(base.AlertsBase):
    def swarmctl(self, *args):
        done = subprocess.run([sys.executable, "-B", str(SWARMCTL), *args], capture_output=True, text=True, timeout=60,
                              env=dict(os.environ))
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout.strip().splitlines()[-1]), done.stdout + done.stderr

    def test_status_configure_and_test_through_swarmctl(self):
        ntfy = fixtures.FakeNtfy()
        self.addCleanup(ntfy.close)
        status, _ = self.swarmctl("alerts", "panel", "status")
        self.assertEqual((status["schema"], status["config"]["configured"], status["service"]["running"]), ("swarmhub/alerts/1", False, False))
        settings = {"v": 1, "enabled": True, "ntfy": {"url": ntfy.url, "token": base.TOKEN}}
        blob = seal.seal(seal.unb64(status["box_key"]), json.dumps(settings).encode())
        saved, output = self.swarmctl("alerts", "panel", "configure", blob)
        self.assertEqual(saved["config"]["sinks"], ["ntfy"])
        tested, output2 = self.swarmctl("alerts", "panel", "test")
        self.assertEqual(tested["result"], {"sinks": {"ntfy": "sent"}})
        self.assertEqual(ntfy.posts[0]["headers"]["Authorization"], "Bearer " + base.TOKEN)
        self.assertEqual(ntfy.posts[0]["headers"]["Title"], "Swarm Hub test alert")
        for text in (output, output2, json.dumps(alerts.load_state())):
            self.assertNotIn(base.TOKEN, text)

    def test_a_refused_call_says_why_on_stderr(self):
        done = subprocess.run([sys.executable, "-B", str(SWARMCTL), "alerts", "panel", "configure", "v1.AAAA"],
                              capture_output=True, text=True, timeout=60, env=dict(os.environ))
        self.assertEqual(done.returncode, 64)
        self.assertIn("swarmctl: sealed alert settings are not readable", done.stderr)


class Producers(base.AlertsBase):
    def test_report_and_an_accepted_webhook_call_spool_one_alert_each(self):
        self.configure()
        loader = SourceFileLoader("swarmctl_alerts_test", str(SWARMCTL))
        control = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(control)
        control.control.publish({"coordinator": "jarvis", "owner": "default", "start": 0, "end": 0})
        with patch.object(control, "start", lambda: None):
            control.main(["report", "jarvis", "Deploy finished."])
            key = "synthetic-webhook-key"
            control.control.webhook.register("jarvis", "deploy", "sha256:" + hashlib.sha256(key.encode()).hexdigest())
            row = control.control.webhook.listing()[0]
            slug = row["url"].rstrip("/").rsplit("/", 1)[1]
            control.control.webhook.fire("jarvis", "deploy", slug, key, "Push to main")
        records = sorted((json.loads(p.read_text()) for p in alerts.paths()["spool"].glob("*.json")), key=lambda r: r["at"])
        self.assertEqual([(r["kind"], r["title"], r["body"]) for r in records],
                         [("report", "jarvis reported", "Deploy finished."), ("webhook", "Webhook deploy woke jarvis", "Push to main")])

    def test_a_box_without_alert_settings_spools_nothing(self):
        self.assertFalse(alerts.emit("webhook", "webhook:x", "t", "b"))
        self.assertFalse((store.state() / "alerts").exists())


if __name__ == "__main__":
    unittest.main()
