"""PR 6: receiver/nginx fixtures only, under the required sbtest PID namespace."""
from webhook_ops_support import FakeBox, probe, response  # first: runs sim_isolation

import json
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class FakeCurl:
    def __init__(self, base, key):
        self.calls = []

    def request(self, path, method="POST", payload=None, auth="valid", origin=None, chunked=False):
        self.calls.append((path, method, auth, payload))
        extra = {} if origin else {"cf-ray": "ray-e" if "/absent-" in path else "ray-a"}
        if method != "POST" or path.endswith("/health"):
            code = 404 if path.endswith("/health") else 403
            return response(code, f"<html>{code}</html>", "text/html", **extra)
        if isinstance(payload, bytes):
            code = 413 if len(payload) == 33000 else 400
            return response(code, "<html>413</html>" if code == 413 else {"error": "bad request"},
                            "text/html" if code == 413 else "application/json", **extra)
        if "/absent-" in path:
            return response(404, {"error": "unknown webhook"}, **extra)
        if auth == "none":
            return response(400, {"error": "bad request"}, **extra)
        if auth == "wrong" or path.endswith("/wrongslug"):
            return response(403, {"error": "webhook rejected"}, **extra)
        return response(202, {"status": "pending", "profile": "pilot", "delivery": "fixture-delivery"}, **extra)


class ProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "evidence.json"
        self.box = FakeBox()
        self.probe = probe.Probe(self.box, "pilot", "https://hooks.test", "192.0.2.1", 8745, 8746,
                                 "access", "error", "presence", self.path, delivery_timeout=0)

    def test_full_v1_v6_run_cleanup_and_independent_recheck(self):
        with patch.object(probe, "Curl", FakeCurl):
            self.probe.run()
        self.assertTrue(probe.verify_evidence(self.path))
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertFalse(self.probe.key in self.path.read_text())
        self.assertEqual(self.box.actions[-1][0], "delete")
        data = json.loads(self.path.read_text())
        for check in data["checks"]:
            if check["check"] == "V6.origin.PUT":
                check["response"] = response(501, "<html>501</html>", "text/html")
        self.path.write_text(json.dumps(data))
        self.assertFalse(probe.verify_evidence(self.path))

    def test_dns_only_fallback_has_no_rays_and_explicit_v4_inapplicability(self):
        class DirectDNS(FakeCurl):
            def request(self, *args, **kwargs):
                result = super().request(*args, **kwargs)
                result["headers"].pop("cf-ray", None)
                return result
        self.probe.dns_only = True
        with patch.object(probe, "Curl", DirectDNS):
            self.probe.run()
        self.assertTrue(probe.verify_evidence(self.path))
        data = json.loads(self.path.read_text())
        self.assertEqual(data["transport"], "dns-only")
        self.assertIn("not_applicable", next(row for row in data["checks"] if row["check"] == "V4"))

    def test_pre_pr2_message_status_is_explicit_and_replayed(self):
        class BeforePR2(FakeCurl):
            def request(self, *args, **kwargs):
                result = super().request(*args, **kwargs)
                if kwargs.get("payload") == {"message": "probe"}:
                    return response(400, {"error": "bad request"}, **{
                        key: value for key, value in result["headers"].items() if key == "cf-ray"})
                return result
        self.probe.message_status = 400
        with patch.object(probe, "Curl", BeforePR2):
            self.probe.run()
        self.assertTrue(probe.verify_evidence(self.path))
        data = json.loads(self.path.read_text())
        data["message_status"] = 202
        self.path.write_text(json.dumps(data))
        self.assertFalse(probe.verify_evidence(self.path))

    def test_cleanup_failure_is_never_green(self):
        real_rpc = self.box.rpc
        def rpc(action, **fields):
            if action == "delete":
                raise OSError("fixture cleanup failed")
            return real_rpc(action, **fields)
        self.box.rpc = rpc
        with patch.object(probe, "Curl", FakeCurl), self.assertRaises(OSError):
            self.probe.run()
        self.assertFalse(probe.verify_evidence(self.path))

    def test_v4_both_rays_must_be_present_and_canary_removed_on_red(self):
        self.box.logs["presence"] = "ray-a present\nray-e absent\n"
        with patch.object(probe, "Curl", FakeCurl), self.assertRaises(ValueError):
            self.probe.run()
        self.assertEqual(self.box.actions[-1][0], "delete")
        self.assertFalse(probe.verify_evidence(self.path))

    def test_wrong_account_control_f_404_means_move_incomplete(self):
        self.box.run = lambda argv: json.dumps(response(404, {"error": "unknown webhook"})).encode()
        with patch.object(probe, "Curl", FakeCurl), self.assertRaises(ValueError):
            self.probe.run()
        self.assertFalse(next(row for row in self.probe.records if row["check"] == "V2.f")["ok"])
        self.assertEqual(self.box.actions[-1][0], "delete")

    def test_cloudflare_stripping_diagnosed_from_a_and_e_400(self):
        class Stripped(FakeCurl):
            def request(self, *args, **kwargs):
                if not kwargs.get("origin"):
                    return response(400, {"error": "bad request"}, **{"cf-ray": "ray"})
                return super().request(*args, **kwargs)
        with patch.object(probe, "Curl", Stripped), self.assertRaises(ValueError):
            self.probe.run()
        reason = next(row["reason"] for row in self.probe.records if row["check"] == "diagnosis")
        self.assertIn("header stripped", reason)

    def test_content_type_body_missing_ray_and_nginx_errors_cannot_pass(self):
        valid = response(404, {"error": "unknown webhook"})
        self.assertTrue(probe.expected(valid, 404, "application/json", {"error": "unknown webhook"}))
        for invalid in (response(404, "<html>404</html>", "text/html"), response(404, {"error": "other"}),
                        response(404, "not JSON"), response(202, {"status": "pending"})):
            self.assertFalse(probe.expected(invalid, invalid["status"], "application/json",
                                            {"error": "unknown webhook"} if invalid["status"] == 404 else {"status": "pending"}))
        with self.assertRaises(ValueError):
            self.probe.check("missing-ray", FakeCurl("", ""), "/swarmhub/webhook/pilot/absent-x/x", 404,
                             body={"error": "unknown webhook"}, cloud=True, origin="192.0.2.1")

    def test_v5_requires_delivered_and_received_and_times_out(self):
        self.box.receipts = [["delivered", "pending"]]
        with patch.object(probe, "Curl", FakeCurl), self.assertRaises(ValueError):
            self.probe.run()
        self.assertFalse(next(row for row in self.probe.records if row["check"] == "V5")["ok"])

    def test_key_in_any_nginx_log_blocks_and_is_not_saved(self):
        self.box.logs["error"] = "fixture-private-key-long-enough"
        with patch.object(probe, "Curl", FakeCurl), self.assertRaises(ValueError):
            self.probe.run()
        self.assertFalse("fixture-private-key-long-enough" in self.path.read_text())
        self.assertFalse(probe.verify_evidence(self.path))


if __name__ == "__main__":
    unittest.main()
