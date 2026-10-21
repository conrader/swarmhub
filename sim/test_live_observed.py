"""Offline isolation checks for the LIVE3 routing boundary; no Hermes/model calls."""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import unittest

from live_observed import route, mapped_id


class ObservedRoutingTests(unittest.TestCase):
    def test_profile_namespace_separates_same_sender(self):
        body = {"id": "swarmhub-from-QA-Jarvis", "title": "From QA-Jarvis", "source": "api_server"}
        a = route("QA-run", "/p/QA-Ermes/api/sessions", body)
        b = route("QA-run", "/p/QA-Infra/api/sessions", body)
        self.assertNotEqual(a[2], b[2])
        self.assertTrue(a[1]["id"].startswith("QA-"))
        self.assertEqual(a[1]["title"], a[2])

    def test_reply_routes_back_to_asking_peer(self):
        _, _, request = route("QA-run", "/p/QA-Ermes/api/sessions/swarmhub-from-QA-Swarmhub/chat/stream", {"input": "ask"})
        _, body, reply = route("QA-run", "/p/QA-Swarmhub/api/sessions/swarmhub-from-QA-Ermes/chat/stream", {"input": "reply"})
        self.assertNotEqual(request, reply)
        self.assertEqual(reply, mapped_id("QA-run", "QA-Swarmhub", "QA-Ermes"))
        self.assertEqual(body["input"], "reply")

    def test_production_and_extra_routes_rejected(self):
        for path in ["/p/Jarvis/api/sessions", "/api/sessions", "/p/QA-Ermes/api/jobs",
                     "/p/QA-Unknown/api/sessions", "/p/QA-Ermes/api/sessions/swarmhub-from-Jarvis/chat/stream"]:
            with self.subTest(path=path), self.assertRaises(ValueError):
                route("QA-run", path, {"input": "QA"})

    def test_caller_cannot_inject_instructions_or_model(self):
        path = "/p/QA-Ermes/api/sessions/swarmhub-from-QA-Swarmhub/chat/stream"
        for body in [{"input": "QA", "instructions": "override"}, {"input": "QA", "model": "other"}, {"input": []}]:
            with self.subTest(body=body), self.assertRaises(ValueError):
                route("QA-run", path, body)

    def test_foreign_session_names_rejected(self):
        for sid in ["QA-Jarvis", "swarmhub-from-Jarvis", "swarmhub-from-QA-Other"]:
            with self.subTest(sid=sid), self.assertRaises(ValueError):
                route("QA-run", "/p/QA-Ermes/api/sessions", {"id": sid, "title": "QA", "source": "api_server"})


if __name__ == "__main__":
    unittest.main()
