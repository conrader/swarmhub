"""PR 6: receiver/nginx fixtures only, under the required sbtest PID namespace."""
from webhook_ops_support import ROOT, probe  # first: runs sim_isolation

import json
import os
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch


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
