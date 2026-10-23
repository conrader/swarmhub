"""Off-app alerts scope (recsfix1, live finding #14): the box alerts only for the profiles the app connected (the
`profiles` allowlist it pushes with the sealed settings) and never for a script-only job (`no_agent`: no agent turn, so
no reply to alert with). Unknown or disconnected profiles alert nothing. Loopback fakes only."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import json
import unittest
from unittest.mock import patch

from test_alerts import AlertsBase, TOKEN  # noqa: E402  (sys.path is set up there)
import swarm_alerts as alerts  # noqa: E402
import swarm_alerts_seal as seal  # noqa: E402


class Scope(AlertsBase):
    def two_runs(self, profile, ident, name, **extra):
        """A first sighting, then a finished run with a reply."""
        self.job(profile, ident, name, "2026-10-23T07:00:00+00:00", **extra)
        self.tick()
        self.job(profile, ident, name, "2026-10-23T08:00:00+00:00", **extra)
        self.run_reply(profile, ident, "20261023_080000", f"{name} reply.")
        return self.tick()

    def test_only_connected_profiles_alert(self):
        self.configure(profiles=["jarvis"])
        self.two_runs("jarvis", "aaaaaaaaaaaa", "Morning brief")
        self.two_runs("default", "bbbbbbbbbbbb", "atlas-name-sync")
        self.assertEqual(self.sent, [("Morning brief finished (jarvis)", "Morning brief reply.")])

    def test_settings_without_profiles_alert_for_no_routine(self):
        # An older app pushes no allowlist: no profile is known to be connected, so no routine alerts (reports still go).
        self.configure(profiles=None)
        self.two_runs("jarvis", "aaaaaaaaaaaa", "Morning brief")
        self.job("default", "cccccccccccc", "Backup", "t1", last_status="error", last_error="disk full")
        self.tick()
        self.assertEqual(self.sent, [])
        alerts.emit("report", "report:a", "jarvis reported", "one")
        self.tick()
        self.assertEqual(self.sent, [("jarvis reported", "one")])

    def test_a_disconnected_profile_stops_alerting_and_starts_fresh_when_connected_again(self):
        self.configure(profiles=["jarvis"])
        self.two_runs("jarvis", "aaaaaaaaaaaa", "Morning brief")
        self.configure(profiles=["default"])
        self.job("jarvis", "aaaaaaaaaaaa", "Morning brief", "2026-10-23T09:00:00+00:00")
        self.run_reply("jarvis", "aaaaaaaaaaaa", "20261023_090000", "Not for an unconnected bot.")
        state = self.tick()
        self.assertEqual(len(self.sent), 1)
        self.assertFalse(any(key.startswith("jarvis/") for key in state["marks"]), "a disconnected profile keeps no marks")
        self.configure(profiles=["jarvis"])
        self.tick()
        self.assertEqual(len(self.sent), 1, "connected again: its first sighting is only recorded")

    def test_script_only_jobs_never_alert(self):
        self.configure(profiles=["default", "jarvis"])
        self.two_runs("default", "dddddddddddd", "atlas-name-sync", no_agent=True, script="atlas.py")
        self.job("default", "dddddddddddd", "atlas-name-sync", "2026-10-23T09:00:00+00:00", no_agent=True, script="atlas.py",
                 last_status="error", last_error="exit 1")
        self.tick()
        self.assertEqual(self.sent, [])
        # A script that feeds an agent turn (no_agent false) is a normal routine.
        self.two_runs("jarvis", "eeeeeeeeeeee", "Morning pulse", no_agent=False, script="pulse.py")
        self.assertEqual(self.sent, [("Morning pulse finished (jarvis)", "Morning pulse reply.")])

    def test_the_presence_lease_is_read_on_any_profile(self):
        self.configure(profiles=["jarvis"])
        self.hermes.jobs["default"] = [{"id": "ffffffffffff", "name": "swarmhub-presence", "enabled": False,
                                        "prompt": f"Swarm Hub presence lease; reply [SILENT]. until={int(self.now + 300)}"}]
        alerts.emit("report", "report:p", "jarvis reported", "one")
        state = self.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(state["sent"]["report:p"][1], "app")

    def test_a_handoff_of_a_profile_disconnected_since_is_paused_at_its_end_but_not_alerted(self):
        from test_alerts import Sources
        run_at = Sources.handed_off_loop(self)
        self.hermes.messages["chat1"] = [Sources.delivery(self, "swarmhub-loop-0123abcd", run_at - 30)]
        self.assertIn("jarvis/dddddddddddd", self.tick()["handoff"], "handed off while jarvis was connected")
        self.configure(profiles=["default"])
        self.hermes.messages["chat1"].append({"role": "assistant", "timestamp": run_at - 20,
                                              "content": 'Build is green.\n```swarmhub\n{"op":"loop","status":"done"}\n```'})
        state = self.tick()
        self.assertEqual(self.sent, [])
        self.assertEqual(self.hermes.paused, [("jarvis", "dddddddddddd")])
        self.assertEqual(state["handoff"], {})

    def test_the_allowlist_is_checked_saved_and_shown(self):
        public = seal.public(seal.box_key(alerts.paths()["folder"]))
        base = {"v": 1, "enabled": True, "ntfy": {"url": "https://ntfy.example/topic", "token": TOKEN}}
        for bad in ("jarvis", ["../etc"], [""], [7]):
            with self.assertRaisesRegex(ValueError, "profile"):
                alerts.panel("configure", seal.seal(public, json.dumps(dict(base, profiles=bad)).encode()))
        self.assertFalse(alerts.paths()["config"].exists())
        answer = alerts.panel("configure", seal.seal(public, json.dumps(dict(base, profiles=["jarvis", "default", "jarvis"])).encode()))
        self.assertEqual(json.loads(alerts.paths()["config"].read_text())["profiles"], ["default", "jarvis"])
        self.assertEqual(answer["config"]["profiles"], ["default", "jarvis"])
        self.assertNotIn(TOKEN, json.dumps(answer))


class DispatchScope(AlertsBase):
    """recsfix2: scope is checked again when an alert goes out, not only when it is queued. An alert waiting for a retry
    or in a digest, of a profile the app disconnected since (or never connected), is dropped; so is one an older skill
    queued, read by its id, and a digest line kept as a bare title."""
    failing = False

    def deliver(self, config, title, body):
        if self.failing:
            return {"ntfy": "error: synthetic outage"}
        return super().deliver(config, title, body)

    def two_runs(self, profile, ident, name):
        self.job(profile, ident, name, "2026-10-23T07:00:00+00:00")
        self.tick()
        self.job(profile, ident, name, "2026-10-23T08:00:00+00:00")
        self.run_reply(profile, ident, "20261023_080000", f"{name} reply.")
        return self.tick()

    def test_a_retry_of_a_profile_disconnected_since_is_dropped(self):
        self.configure(profiles=["jarvis"])
        self.failing = True
        state = self.two_runs("jarvis", "aaaaaaaaaaaa", "Morning brief")
        self.assertEqual([item["title"] for item in state["pending"]], ["Morning brief finished (jarvis)"], "kept for a retry")
        self.failing = False
        self.configure(profiles=[])
        state = self.tick(advance=3600)
        self.assertEqual(self.sent, [])
        self.assertEqual(state["pending"], [])
        self.assertEqual([value[1] for key, value in state["sent"].items() if key.startswith("routine:jarvis:")], ["out of scope"])

    def test_a_digest_leaves_out_the_lines_of_a_profile_disconnected_since(self):
        self.configure(profiles=["jarvis"], window=True)
        with patch("swarm_policy.in_report_window", return_value=False):
            self.two_runs("jarvis", "aaaaaaaaaaaa", "Morning brief")
            alerts.emit("report", "report:n1", "jarvis reported", "x")
            state = self.tick()
        self.assertEqual(len(state["deferred"]), 2, "the routine and the report wait for the digest")
        self.configure(profiles=[], window=True)
        with patch("swarm_policy.in_report_window", return_value=True):
            self.tick()
        self.assertEqual(self.sent, [("1 alerts from outside the report window", "• jarvis reported")])

    def test_what_an_older_skill_queued_is_scoped_by_its_id(self):
        self.configure(profiles=["default"])
        self.job("default", "dddddddddddd", "atlas-name-sync", "2026-10-23T07:00:00+00:00", no_agent=True, script="atlas.py")
        data = alerts.load_state()
        old = [{"id": "routine:jarvis:aaaaaaaaaaaa:2026-10-23T08:00:00+00:00", "kind": "routine", "title": "Morning brief finished (jarvis)"},
               {"id": "routine:default:dddddddddddd:2026-10-23T07:00:00+00:00", "kind": "routine", "title": "atlas-name-sync finished (default)"},
               {"id": "loop:jarvis/eeeeeeeeeeee:1800000000", "kind": "loop", "title": "Loop on the box (jarvis)"},
               {"id": "report:a", "kind": "report", "title": "jarvis reported"}]
        data["pending"] = [dict(item, body="x", attempts=0) for item in old]
        data["deferred"] = ["Morning brief finished (jarvis)"]
        alerts.save_state(data)
        state = self.tick()
        self.assertEqual(self.sent, [("jarvis reported", "x")])
        self.assertEqual(state["deferred"], [])
        self.assertEqual(sorted(value[1] for value in state["sent"].values()), ["out of scope"] * 3 + ["sent"])


if __name__ == "__main__":
    unittest.main()
