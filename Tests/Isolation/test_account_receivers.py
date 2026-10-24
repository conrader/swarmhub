"""swapdesign2 §2: each account runs its own webhook receiver, so a webhook for A lands only in A's database.

Two real receivers (`swarmctl webhook serve <port>` from the shipped skill) run with A's and B's homes on their
registry ports. A's routine fires through A's receiver; B's receiver does not know profile a (probe f's 400).
"""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sim"))
import sim_isolation  # noqa: F401,E402  Exits unless isolated (sim/ISOLATION.md); keep it the first import.
import json  # noqa: E402
import subprocess  # noqa: E402
import unittest  # noqa: E402
import urllib.error  # noqa: E402
import urllib.request  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from world import SKILL_PATH, World  # noqa: E402


class AccountReceivers(unittest.TestCase):
    def setUp(self):
        self.w = World()
        self.addCleanup(lambda: self.w.close())
        self.receivers = []
        self.addCleanup(self.stop_receivers)

    def stop_receivers(self):
        for proc in self.receivers:
            if proc.poll() is None:
                proc.terminate()
                proc.wait(5)

    def swarmctl(self, account, profile, *args):
        script = self.w.profile(profile) / SKILL_PATH / "swarmctl"
        return subprocess.run([sys.executable, "-B", str(script), *args], env=self.w.env(account), capture_output=True,
                              text=True, timeout=30)

    def serve(self, account, profile, port):
        script = self.w.profile(profile) / SKILL_PATH / "swarmctl"
        errors = self.w.root / f"receiver-{port}.err"
        with open(errors, "wb") as handle:
            proc = subprocess.Popen([sys.executable, "-B", str(script), "webhook", "serve", str(port)],
                                    env=self.w.env(account), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                    stderr=handle)
        self.receivers.append(proc)
        health = f"http://127.0.0.1:{port}/swarmhub/webhook/health"
        self.assertTrue(self.w.until(lambda: self.get(health) == 200 or proc.poll() is not None, timeout=10))
        if proc.poll() is not None:
            self.fail(f"receiver on {port} exited: {errors.read_text()}")

    @staticmethod
    def get(url):
        try:
            with urllib.request.urlopen(url, timeout=2) as response:
                return response.status
        except urllib.error.HTTPError as exc:
            return exc.code
        except OSError:
            return None

    @staticmethod
    def post(port, path, key, text):
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps({"text": text}).encode(),
                                         headers={"X-SwarmHub-Key": key, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                return response.status, json.loads(response.read())
        except urllib.error.HTTPError as exc:
            return exc.code, json.loads(exc.read() or b"{}")

    def test_a_webhook_for_a_lands_only_in_a(self):
        w = self.w
        registered = self.swarmctl("hb-a", "a", "webhook", "register", "a", "canary")
        self.assertEqual(registered.returncode, 0, registered.stderr)
        info = json.loads(registered.stdout)
        path = "/" + info["url"].split("/", 3)[3]
        key = Path(info["key_file"]).read_text().strip()
        self.assertTrue(str(info["key_file"]).startswith(str(w.home("hb-a"))))
        ports = json.loads(w.registry.read_text())["bots"]
        self.serve("hb-a", "a", ports["a"]["receiver_port"])
        self.serve("hb-b", "b", ports["b"]["receiver_port"])
        status, body = self.post(ports["b"]["receiver_port"], path, key, "wrong account")
        self.assertEqual((status, body.get("error")), (400, "bad request"))
        status, body = self.post(ports["a"]["receiver_port"], path, key, "job done")
        self.assertEqual(status, 202, body)
        rows = w.query("hb-a", "control.sqlite", "SELECT sender,target FROM deliveries")
        self.assertEqual(len(rows), 1, rows)
        self.assertEqual(rows[0][1], "a")
        self.assertEqual(w.query("hb-b", "control.sqlite", "SELECT * FROM deliveries"), [])
        self.assertEqual(w.files_containing(w.home("hb-b"), key), [])


if __name__ == "__main__":
    unittest.main()
