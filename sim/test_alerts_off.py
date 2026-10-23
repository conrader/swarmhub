"""rel066: off-app alerts are switched off in this release (`swarm_alerts_service.ON`; the app's twin is
`AppStore.boxAlertsShipped`, BoxAlertsOffTests.swift). With the switch as shipped, nothing installs or resumes the alert
service, settings from any app (a 0.6.5 one too) turn alerts off, a service already running sends nothing, and no event is
spooled. When alerts come back, the switch goes to True and this file goes."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import os
import unittest
from unittest.mock import patch

from test_alerts import AlertsBase, TOKEN  # noqa: E402  (sys.path is set up there)
import swarm_alerts as alerts  # noqa: E402
import swarm_alerts_seal as seal  # noqa: E402
import swarm_alerts_service as service  # noqa: E402
import swarm_alerts_sinks as sinks  # noqa: E402
import swarm_store as store  # noqa: E402
import swarm_webhook_receiver as receiver  # noqa: E402

SHIPPED = getattr(service, "ON", True)  # Read at import, before any test turns it on; no switch = alerts on.
SETTINGS = {"v": 1, "enabled": True, "window": False, "ntfy": {"url": "https://ntfy.example/topic", "token": TOKEN},
            "profiles": ["default", "jarvis"]}


class SwitchedOff(AlertsBase):
    def setUp(self):
        super().setUp()
        switch = patch.object(service, "ON", SHIPPED, create=True)  # AlertsBase turns it on; back to the shipped value.
        switch.start()
        self.addCleanup(switch.stop)
        os.environ["SWARMHUB_RECEIVER_MANAGER"] = "systemd"  # A box with a user manager (lingering): a unit would go in.
        self.commands, self.spawns, self.deliveries = [], [], []
        run = lambda *args: self.commands.append(list(args)) or (0, "yes" if args[0] == "loginctl" else "")  # noqa: E731
        for target, name, fake in ((receiver, "run", run),
                                   (service, "spawn", lambda python: self.spawns.append(python)),
                                   (sinks, "deliver", lambda *args, **kw: self.deliveries.append(args[1]) or {"ntfy": "sent"})):
            patcher = patch.object(target, name, fake)
            patcher.start()
            self.addCleanup(patcher.stop)

    def saved_by_an_older_app(self):
        """Settings as a 0.6.5 app saved them (alerts on), and one event an older skill spooled."""
        alerts.paths()["config"].write_text(json.dumps(SETTINGS))
        spool = alerts.paths()["spool"]
        spool.mkdir(mode=0o700, exist_ok=True)
        (spool / "a.json").write_text(json.dumps({"id": "report:1", "kind": "report", "title": "jarvis reported",
                                                  "body": "Deploy finished.", "at": self.now}))

    def test_the_release_ships_with_alerts_off(self):
        self.assertIs(SHIPPED, False)

    def test_settings_from_any_app_turn_alerts_off_and_install_no_service(self):
        public = seal.public(seal.box_key(alerts.paths()["folder"]))
        answer = alerts.panel("configure", seal.seal(public, json.dumps(SETTINGS).encode()))
        self.assertFalse(answer["config"]["enabled"])
        self.assertFalse(json.loads(alerts.paths()["config"].read_text())["enabled"])
        answer = alerts.panel("install")
        self.assertIn("switched off", answer["result"]["error"])
        self.assertFalse(service.unit_path().exists(), "no unit written")
        started = [args for args in self.commands if args[0] == "systemctl" and {"enable", "start", "restart"} & set(args)]
        self.assertEqual(started, [], "no service enabled or started")
        self.assertFalse(answer["service"]["installed"])

    def test_a_running_service_sends_nothing_and_no_test_alert_goes(self):
        self.saved_by_an_older_app()
        for _ in range(3):
            self.tick()
        self.assertEqual((self.sent, self.deliveries), ([], []), "nothing sent")
        self.assertEqual(alerts.load_state()["pending"], [])
        self.assertEqual(list(alerts.paths()["spool"].glob("*.json")), [], "the spool does not grow")
        with self.assertRaisesRegex(ValueError, "switched off"):
            alerts.panel("test")
        self.assertEqual(self.deliveries, [])

    def test_no_event_is_spooled_and_the_gateway_resumes_no_service(self):
        alerts.paths()["config"].write_text(json.dumps(SETTINGS))
        self.assertFalse(alerts.emit("webhook", "webhook:x", "Webhook deploy woke jarvis", "Push to main"))
        self.assertFalse(alerts.paths()["spool"].exists() and any(alerts.paths()["spool"].iterdir()))
        (store.state() / "alerts" / "service.supervised").write_text(json.dumps({"python": "/usr/bin/python3"}) + "\n")
        service.resume()
        self.assertEqual(self.spawns, [], "no fallback service started at gateway start")


if __name__ == "__main__":
    unittest.main()
