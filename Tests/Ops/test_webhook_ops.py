"""PR 6: receiver/nginx fixtures only, under the required sbtest PID namespace."""
from webhook_ops_support import FakeBox, config, enroll, ops, probe, webhook  # first: runs sim_isolation

from contextlib import redirect_stdout
import concurrent.futures
import io
import json
import os
import shlex
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class ConfigTests(unittest.TestCase):
    def test_v1_vhost_profile_upstream_and_safety(self):
        self.assertTrue(probe.config_checks(config(), "hooks.test", "pilot", 8746))
        for text in (config().replace("8746", "8745"), config().replace("POST", "GET"),
                     config().replace("buffering on", "buffering off"),
                     config().replace("32k", "31k"), config().replace("return 404", "return 200"),
                     config().replace("/pilot/", "/another/"),
                     config().replace("http://127.0.0.1:8746;", "http://127.0.0.1:8746/;"),
                     config().replace("$http_cf_ray $swh_key", "$http_cf_ray $http_x_swarmhub_key"),
                     config().replace("listen 443 ssl", "listen 80")):
            with self.subTest(text_hash=hash(text)):
                self.assertFalse(probe.config_checks(text, "hooks.test", "pilot", 8746))
        self.assertFalse(probe.config_checks(config(), "elsewhere.test", "pilot", 8746))

    def test_v1_per_slug_regex_and_hidden_health_precedence(self):
        text = config().replace("location /swarmhub/webhook/pilot/", "location ~ ^/swarmhub/webhook/pilot/")
        self.assertTrue(probe.config_checks(text, "hooks.test", "pilot", 8746))

    def test_v1_nginx_T_includes_are_expanded_in_the_correct_http_scope(self):
        vhost = config().split("      server", 1)[1].rsplit("}", 1)[0]
        text = ("# configuration file /etc/nginx/nginx.conf:\nevents {} http { include /etc/nginx/sites-enabled/*; }\n"
                "# configuration file /etc/nginx/sites-enabled/hooks:\nserver" + vhost)
        self.assertTrue(probe.config_checks(text, "hooks.test", "pilot", 8746))

    def test_public_urls_and_names_reject_injection(self):
        self.assertEqual(ops.public_base("https://hooks.test/"), "https://hooks.test")
        for url in ("http://hooks.test", "https://user:key@hooks.test", "https://hooks.test?key=x",
                    "https://hooks.test/#key", "https://hooks.test/$(command)", "https://hooks.test:bad",
                    "https://hooks. test", "https://hooks.test/\ninjected"):
            with self.assertRaises(ValueError):
                ops.public_base(url)
        for value in ("../pilot", "--pilot", "pilot/other", "a\nb", "a" * 65):
            # --pilot is a legal profile name, but not an account option or SSH host.
            if value == "--pilot":
                continue
            with self.assertRaises(ValueError):
                ops.name(value)
        with self.assertRaises(ValueError):
            ops.Box("hb-pilot", "-oProxyCommand=bad")

    def test_ssh_argv_uses_captured_rpc_sudo_and_python_B(self):
        box = ops.Box("hb-pilot", "fixture-box", "/srv/our checkout")
        output = json.dumps({"key": "fixture-private-key"}).encode()
        def run(argv, **kwargs):
            self.assertEqual(argv[:5], ["ssh", "-T", "-oBatchMode=yes", "--", "fixture-box"])
            remote = shlex.split(argv[5])
            self.assertEqual(remote[:7], ["sudo", "-n", "-H", "-u", "hb-pilot", "--", "python3"])
            self.assertEqual(remote[7], "-B")
            self.assertTrue(kwargs["capture_output"])
            self.assertFalse(any("fixture-private-key" in arg for arg in argv))
            return subprocess.CompletedProcess(argv, 0, output, b"")
        with patch.object(ops.subprocess, "run", side_effect=run):
            result = box.rpc("register", profile="pilot", routine="job-done")
        self.assertTrue(result == {"key": "fixture-private-key"})


class EnvTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "wake.env"

    def test_backup_permissions_preservation_normalization_and_body_shadow(self):
        old = b"# keep this\nWAKE_URL=https://cursor.test\nWAKE_KEY=old-secret\nexport WAKE_AGENT_PILOTONE_URL=old\n"
        self.path.write_bytes(old)
        backup = enroll.update_env(self.path, "pilot-one", "https://hooks.test/p", "fixture-key",
                                   "body", "https://shadow.test/p")
        self.assertTrue(backup.read_bytes() == old)
        for path in (backup, self.path, self.path.with_name("wake.env.lock")):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        data = self.path.read_text()
        self.assertIn("WAKE_URL=https://cursor.test\nWAKE_KEY=old-secret\n", data)
        self.assertEqual(data.count("WAKE_AGENT_PILOTONE_URL="), 1)
        self.assertIn("WAKE_AGENT_PILOTONE_KEY_IN=body\n", data)
        self.assertIn("WAKE_AGENT_PILOTONE_AUTH_HEADER=X-SwarmHub-Key\n", data)
        self.assertIn("WAKE_AGENT_PILOTONE_SHADOW_URL=https://shadow.test/p\n", data)
        backup2 = enroll.update_env(self.path, "pilot-one", "https://hooks.test/p", "fixture-key")
        self.assertNotEqual(backup, backup2)
        self.assertIn("WAKE_AGENT_PILOTONE_KEY_IN=header", self.path.read_text())
        self.assertIn("WAKE_AGENT_PILOTONE_SHADOW_URL=", self.path.read_text())

    def test_concurrent_enrollments_do_not_lose_other_bots(self):
        with concurrent.futures.ThreadPoolExecutor() as pool:
            list(pool.map(lambda name: enroll.update_env(self.path, name, "https://hooks.test/" + name, "key"),
                          ("pilot", "second", "third")))
        for name in ("PILOT", "SECOND", "THIRD"):
            self.assertIn("WAKE_AGENT_" + name + "_KEY=key", self.path.read_text())
        self.assertEqual(len(list(self.path.parent.glob("wake.env.*Z"))), 3)

    def test_symlink_refused_and_original_survives_replace_failure(self):
        target = self.path.with_name("target")
        target.write_text("original")
        self.path.symlink_to(target)
        with self.assertRaises(ValueError):
            enroll.update_env(self.path, "pilot", "https://hooks.test", "key")
        self.path.unlink()
        self.path.write_text("original")
        with patch.object(enroll.os, "replace", side_effect=OSError("fixture")), self.assertRaises(OSError):
            enroll.update_env(self.path, "pilot", "https://hooks.test", "key")
        self.assertEqual(self.path.read_text(), "original")
        self.assertEqual(list(self.path.parent.glob(".wake-env-*")), [])

    def test_enrollment_cli_prints_no_key_and_uses_selected_account_rpc(self):
        box, out = FakeBox(), io.StringIO()
        argv = ["wake-enroll", "pilot", "--base-url", "https://hooks.test", "--wake-env", str(self.path)]
        with patch.object(sys, "argv", argv), patch.object(enroll, "box_from", return_value=box), redirect_stdout(out):
            enroll.main()
        self.assertFalse("fixture-private-key-long-enough" in out.getvalue())
        self.assertEqual(box.actions, [("register", {"profile": "pilot", "routine": "job-done"})])
        self.assertIn("WAKE_AGENT_PILOT_URL=https://hooks.test/swarmhub/webhook/pilot/job-done/fixture-slug", self.path.read_text())


class RPCtests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / ".hermes/profiles/pilot").mkdir(parents=True)
        self.env = patch.dict(os.environ, {"HOME": str(self.home)})
        self.env.start()
        self.addCleanup(self.env.stop)

    def test_register_rerun_keeps_slug_and_key_in_own_account(self):
        request = {"action": "register", "profile": "pilot", "routine": "job-done"}
        first, second = ops.account_rpc(request), ops.account_rpc(request)
        self.assertTrue(first == second)
        self.assertIn("key", first)
        with self.assertRaises(ValueError):
            ops.account_rpc({**request, "profile": "missing"})
        with self.assertRaises(ValueError):
            ops.account_rpc({**request, "action": "delete"})

    def test_v5_read_only_exact_profile_and_both_statuses(self):
        with webhook.database() as db:
            db.execute("INSERT INTO deliveries(id,target,status) VALUES('d1','pilot','delivered')")
            db.execute("INSERT INTO receipts(target,id,status) VALUES('pilot','d1','received')")
        path = self.home / ".hermes/swarmhub/control.sqlite"
        before = (path.read_bytes(), path.stat().st_mtime_ns)
        req = {"action": "receipts", "profile": "pilot", "deliveries": ["d1", "missing"]}
        self.assertEqual(ops.account_rpc(req), [["delivered", "received"], None])
        self.assertEqual(ops.account_rpc({**req, "profile": "other"}), [None, None])
        self.assertTrue(before == (path.read_bytes(), path.stat().st_mtime_ns))

    def test_hashed_key_is_refused_without_exposing_it(self):
        webhook.register("pilot", "job-done", "sha256:" + "f" * 64)
        with self.assertRaises(ValueError):
            ops.account_rpc({"action": "register", "profile": "pilot", "routine": "job-done"})


if __name__ == "__main__":
    unittest.main()
