"""PR 6: receiver/nginx fixtures only, under the required sbtest PID namespace."""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "sim"))
import sim_isolation  # noqa: E402,F401

import base64
import concurrent.futures
from contextlib import redirect_stdout
import importlib.machinery
import importlib.util
import io
import json
import os
import shlex
import shutil
import socket
import sqlite3
import stat
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(ROOT / "ops"))
sys.path.insert(0, str(ROOT / "Resources/Skills/swarmhub-messages/scripts"))
import webhook_ops as ops
import webhook_probe as probe
import swarm_webhook as webhook

loader = importlib.machinery.SourceFileLoader("wake_enroll", str(ROOT / "ops/wake-enroll"))
spec = importlib.util.spec_from_loader(loader.name, loader)
enroll = importlib.util.module_from_spec(spec)
loader.exec_module(enroll)


def config(port=8746, host="hooks.test"):
    return '''events {} http {
      map $http_x_swarmhub_key $swh_key { "" absent; default present; }
      log_format swh_probe '$http_cf_ray $swh_key';
      server { listen 443 ssl; server_name HOST;
        location = /swarmhub/webhook/health { return 404; }
        location /swarmhub/webhook/pilot/ {
          limit_except POST { deny all; }
          client_max_body_size 32k;
          proxy_request_buffering on;
          proxy_pass http://127.0.0.1:PORT;
        }
      }
    }'''.replace("HOST", host).replace("PORT", str(port))


def response(code, body, kind="application/json", **headers):
    raw = body.encode() if isinstance(body, str) else json.dumps(body).encode()
    return {"status": code, "headers": {"content-type": kind, **headers},
            "body_b64": base64.b64encode(raw).decode(), "raw_headers": ""}


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


class FakeBox:
    checkout = str(ROOT)

    def __init__(self):
        self.actions, self.logs = [], {"access": "", "error": "", "presence": "ray-a present\nray-e present\n"}
        self.receipts = [["delivered", "received"]]

    def system(self, *argv):
        return config()

    def read(self, path):
        return self.logs[path]

    def rpc(self, action, **fields):
        self.actions.append((action, fields))
        if action == "register":
            return {"slug": "fixture-slug", "key": "fixture-private-key-long-enough"}
        if action == "receipts":
            return self.receipts * len(fields["deliveries"])
        return {}

    def run(self, argv):
        return json.dumps(response(400, {"error": "bad request"})).encode()


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


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class NginxReceiverTests(unittest.TestCase):
    """Real curl → temporary nginx → stock receiver. No service manager or Hermes gateway."""
    def setUp(self):
        if not shutil.which("nginx"):
            self.fail("nginx is required for PR 6's origin/TE integration tests")
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / ".hermes/profiles/pilot").mkdir(parents=True)
        self.env = {**os.environ, "HOME": str(self.home)}
        self.port, self.proxy_port = free_port(), free_port()
        self.server = self.start([sys.executable, "-B", "-c",
                                  "import swarm_webhook; swarm_webhook.serve(" + str(self.port) + ")"],
                                 env={**self.env, "PYTHONPATH": str(ROOT / "Resources/Skills/swarmhub-messages/scripts")})
        self.wait_port(self.port)
        answer = self.rpc("register", routine="canary-fixture")
        self.key, self.slug = answer["key"], answer["slug"]
        self.path = f"/swarmhub/webhook/pilot/canary-fixture/{self.slug}"
        conf = self.home / "nginx.conf"
        conf.write_text(f'''user root;
          pid {self.home}/nginx.pid;
          error_log {self.home}/error.log;
          events {{}} http {{ access_log {self.home}/access.log;
          client_body_temp_path {self.home}/body;
          proxy_temp_path {self.home}/proxy;
          fastcgi_temp_path {self.home}/fastcgi;
          scgi_temp_path {self.home}/scgi;
          uwsgi_temp_path {self.home}/uwsgi;
          server {{ listen 127.0.0.1:{self.proxy_port};
            location = /swarmhub/webhook/health {{ return 404; }}
            location /swarmhub/webhook/ {{
              limit_except POST {{ deny all; }} client_max_body_size 32k;
              proxy_request_buffering on;
              proxy_pass http://127.0.0.1:{self.port};
            }}
          }} }}''')
        self.nginx = self.start([shutil.which("nginx"), "-p", str(self.home), "-c", str(conf),
                                 "-g", "daemon off; master_process off;"])
        self.wait_port(self.proxy_port)
        self.client = probe.Curl(f"http://127.0.0.1:{self.proxy_port}", self.key)

    def start(self, argv, **kwargs):
        child = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, **kwargs)
        self.addCleanup(self.stop, child)
        return child

    def stop(self, child):
        if child.poll() is None:
            child.terminate()  # Exact PID of our own unreaped child; never a group or pattern.
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()  # Same exact, test-owned PID.
            child.wait(timeout=5)

    def wait_port(self, port):
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                    return
            except OSError:
                time.sleep(0.05)
        self.fail("fixture did not start")

    def rpc(self, action, **fields):
        result = subprocess.run([sys.executable, "-B", str(ROOT / "ops/webhook_ops.py"), "--rpc"],
                                env=self.env, capture_output=True, input=json.dumps(
                                    {"action": action, "profile": "pilot", **fields}).encode(), timeout=10)
        self.assertEqual(result.returncode, 0, "fixture RPC failed; output withheld")
        return json.loads(result.stdout)

    def test_v2_a_e_and_v6_real_origin_bodies_and_buffered_te(self):
        p = probe.Probe(None, "pilot", "", "127.0.0.1", 8745, self.port, "", "", "", self.home / "evidence",
                        message_status=400)
        p.matrix(self.client, self.path, "V2", origin="127.0.0.1")
        p.negatives(self.client, self.path, "V6.origin", origin="127.0.0.1")
        self.assertEqual(len(p.records), 12)
        self.assertTrue(all(row["ok"] for row in p.records))
        self.assertFalse(self.key in (self.home / "access.log").read_text())
        self.assertFalse(self.key in (self.home / "error.log").read_text())

    def test_f_wrong_home_and_raw_receiver_put_501_and_te_400(self):
        direct = probe.Curl(f"http://127.0.0.1:{self.port}", self.key)
        put = direct.request(self.path, method="PUT")
        self.assertTrue(probe.expected(put, 501, "text/html", {}))
        te = direct.request(self.path, chunked=True)
        self.assertTrue(probe.expected(te, 400, "application/json", {"error": "bad request"}))
        # The same three-segment dummy-key probe distinguishes an owning vs a wrong HOME.
        absent = "/swarmhub/webhook/pilot/absent-fixture/x"
        owned = direct.request(absent, auth="probe")
        self.assertTrue(probe.expected(owned, 404, "application/json", {"error": "unknown webhook"}))
        other = self.home / "shared-home"
        other.mkdir()
        wrong_port = free_port()
        self.start([sys.executable, "-B", "-c", "import swarm_webhook; swarm_webhook.serve(" + str(wrong_port) + ")"],
                   env={**self.env, "HOME": str(other), "PYTHONPATH": str(ROOT / "Resources/Skills/swarmhub-messages/scripts")})
        self.wait_port(wrong_port)
        wrong = probe.Curl(f"http://127.0.0.1:{wrong_port}", self.key).request(absent, auth="probe")
        self.assertTrue(probe.expected(wrong, 400, "application/json", {"error": "bad request"}))

    def test_curl_key_only_in_private_header_file_and_no_echo_in_evidence(self):
        real_run = subprocess.run
        def inspect(argv, **kwargs):
            self.assertFalse(any(self.key in arg for arg in argv))
            header = Path(argv[argv.index("--header") + 1][1:])
            self.assertEqual(stat.S_IMODE(header.stat().st_mode), 0o600)
            self.assertEqual(argv[:2], ["curl", "-q"])
            return real_run(argv, **kwargs)
        with patch.object(probe.subprocess, "run", side_effect=inspect):
            answer = self.client.request(self.path)
        self.assertEqual(answer["status"], 202)

    def test_curl_refuses_a_key_echo_before_returning_evidence(self):
        def echo(argv, **kwargs):
            Path(argv[argv.index("--dump-header") + 1]).write_text("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n")
            Path(argv[argv.index("--output") + 1]).write_text(self.key)
            return subprocess.CompletedProcess(argv, 0, b"200", b"")
        with patch.object(probe.subprocess, "run", side_effect=echo), self.assertRaises(ValueError):
            self.client.request(self.path)


if __name__ == "__main__":
    unittest.main()
