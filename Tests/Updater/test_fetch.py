"""P3a transport rules (fetch.py) and the timer templates (Resources/Updater/units/), against local http.server
fixtures only. HTTPS is exercised with a throwaway self-signed loopback certificate when `openssl` is installed.

    python3 -m unittest discover -s Tests/Updater -p "test_fetch.py"
"""

import configparser
from pathlib import Path
import plistlib
import shutil
import ssl
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pull_fixtures import Service, closed_port, local_fetcher  # noqa: E402
from cli_fixtures import ROOT  # noqa: E402

from swarmhub_update import channel, fetch  # noqa: E402

UNITS = ROOT / "Resources/Updater/units"


class Transport(unittest.TestCase):
    def setUp(self):
        self.service = Service()
        self.addCleanup(self.service.close)
        self.service.responses["file"] = (200, b"x" * 100, {})

    def get(self, path, limit=1000, **kwargs):
        return local_fetcher([self.service.url], **kwargs).get(self.service.url + path, limit)

    def reason(self, call):
        with self.assertRaises(fetch.FetchError) as caught:
            call()
        return caught.exception.reason

    def test_body_and_headers(self):
        self.assertEqual(self.get("file"), b"x" * 100)
        headers = self.service.log[0][1]
        self.assertEqual((headers["cache-control"], headers["pragma"], headers["accept-encoding"]),
                         ("no-store", "no-cache", "identity"))
        self.assertTrue(headers["user-agent"].startswith("swarmhub-update/"))

    def test_size_caps(self):
        self.assertEqual(self.get("file", limit=100), b"x" * 100)
        self.assertEqual(self.reason(lambda: self.get("file", limit=99)), "oversize")  # declared length
        self.service.responses["lying"] = (200, b"y" * 5000, {"Content-Length": None})  # no length, then too long
        self.assertEqual(self.reason(lambda: self.get("lying", limit=1000)), "oversize")

    def test_http_errors_and_unreachable_hosts(self):
        self.assertEqual(self.reason(lambda: self.get("missing")), "http_status")
        self.service.responses["teapot"] = (500, b"", {})
        self.assertEqual(self.reason(lambda: self.get("teapot")), "http_status")
        down = "http://127.0.0.1:%d/" % closed_port()
        self.assertEqual(self.reason(lambda: local_fetcher([down]).get(down + "keys.json", 10)), "host_unreachable")

    def test_slow_host_times_out(self):
        self.service.stall = 1.5
        self.assertEqual(self.reason(lambda: self.get("file", timeout=0.5)), "timeout")

    def test_deadline_bounds_a_whole_file(self):
        ticks = iter(range(0, 10000, 400))
        self.service.responses["big"] = (200, b"z" * 200000, {})
        self.assertEqual(self.reason(lambda: self.get("big", limit=300000, deadline=300,
                                                      clock=lambda: next(ticks))), "timeout")

    def test_only_allowlisted_https_origins(self):
        refused = [("http://127.0.0.1:1/", {}), ("http://updates.example.com/", {"allow_loopback_http": True}),
                   ("ftp://127.0.0.1/", {"allow_loopback_http": True}),
                   ("https://user:pw@updates.example.com/", {}), ("https:///nohost", {})]
        for url, kwargs in refused:
            self.assertEqual(self.reason(lambda: fetch.origin_key(url, **kwargs)), "url_refused", url)
        self.assertEqual(fetch.origin_key("https://Updates.Example.com/x"), ("https", "updates.example.com", 443))
        fetcher = fetch.Fetcher(["https://updates.example.com/"])  # the command line's fetcher: no plain http
        self.assertEqual(self.reason(lambda: fetcher.get(self.service.url + "file", 10)), "url_refused")
        self.assertEqual(self.reason(lambda: fetcher.get("https://elsewhere.example.com/keys.json", 10)),
                         "url_refused")
        self.assertEqual(self.service.log, [])
        with self.assertRaises(ValueError):
            channel.origins(["http://127.0.0.1:8000/"])  # loopback http only with the tests' fetcher
        self.assertEqual(channel.origins(["https://a.example/u", "https://a.example/u/"]), ["https://a.example/u/"])
        with self.assertRaises(ValueError):
            channel.origins(["https://a.example/?q=1"])

    def test_redirects_stay_on_the_allowlist(self):
        other = Service()
        self.addCleanup(other.close)
        other.responses["file"] = (200, b"elsewhere", {})
        self.service.redirects["hop"] = other.url + "file"
        self.assertEqual(self.reason(lambda: self.get("hop")), "redirect_refused")
        self.assertEqual(other.log, [])
        fetcher = local_fetcher([self.service.url, other.url])  # a configured mirror is allowlisted
        self.assertEqual(fetcher.get(self.service.url + "hop", 100), b"elsewhere")
        self.service.redirects.update({"a": self.service.url + "b", "b": self.service.url + "c",
                                       "c": self.service.url + "d", "d": self.service.url + "file"})
        self.assertEqual(self.get("c"), b"x" * 100)
        self.assertEqual(self.reason(lambda: self.get("a")), "http_status")  # more than MAX_REDIRECTS hops


def _openssl_cert(folder):
    command = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1",
               "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", str(folder / "key.pem"),
               "-out", str(folder / "cert.pem")]
    try:
        done = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return folder / "cert.pem" if done.returncode == 0 else None


@unittest.skipUnless(shutil.which("openssl"), "openssl not installed: no throwaway TLS certificate")
class Https(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="p3a-tls-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.cert = _openssl_cert(self.tmp)
        if self.cert is None:
            self.skipTest("openssl could not make a loopback certificate")
        self.service = Service()
        self.addCleanup(self.service.close)
        self.service.responses["keys.json"] = (200, b"{}", {})
        server_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        server_context.load_cert_chain(str(self.cert), str(self.tmp / "key.pem"))
        self.service.server.socket = server_context.wrap_socket(self.service.server.socket, server_side=True)
        self.url = "https://127.0.0.1:%d/" % self.service.port

    def test_certificate_is_verified(self):
        with self.assertRaises(fetch.FetchError) as caught:  # system trust does not know the throwaway certificate
            fetch.Fetcher([self.url], proxies={}, timeout=5).get(self.url + "keys.json", 10)
        self.assertEqual(caught.exception.reason, "host_unreachable")
        self.assertIn("CERTIFICATE_VERIFY_FAILED", caught.exception.detail)
        context = ssl.create_default_context(cafile=str(self.cert))
        fetcher = fetch.Fetcher([self.url], proxies={}, timeout=5, context=context)
        self.assertEqual(fetcher.get(self.url + "keys.json", 10), b"{}")
        self.assertEqual(self.service.log[-1][1]["cache-control"], "no-store")


class Units(unittest.TestCase):
    """Timer templates: both disabled by default, run `pull` only, every 6 hours (CORE-PLAN.md §3.4)."""

    def test_systemd_user_units(self):
        service, timer = (configparser.ConfigParser(strict=False, interpolation=None) for _ in range(2))
        service.optionxform = timer.optionxform = str
        service.read(str(UNITS / "swarmhub-update.service"))
        timer.read(str(UNITS / "swarmhub-update.timer"))
        self.assertEqual(service["Service"]["Type"], "oneshot")
        self.assertEqual(service["Service"]["ExecStart"], "@PREFIX@/bin/swarmhub-update pull")
        self.assertNotIn("Install", service)  # started by the timer only
        self.assertEqual(timer["Timer"]["OnUnitActiveSec"], "6h")
        self.assertEqual(timer["Timer"]["Unit"], "swarmhub-update.service")
        for path in (UNITS / "swarmhub-update.service", UNITS / "swarmhub-update.timer"):
            settings = "\n".join(l for l in path.read_text().splitlines() if not l.startswith("#"))
            self.assertNotIn("apply", settings)  # never the confirm
            self.assertNotRegex(settings.lower(), r"restart|hermes|systemctl")  # never touches Hermes

    def test_launchd_agent_is_disabled(self):
        with open(str(UNITS / "com.konrad.swarmhub.update.plist"), "rb") as handle:
            agent = plistlib.load(handle)
        self.assertIs(agent["Disabled"], True)
        self.assertIs(agent["RunAtLoad"], False)
        self.assertEqual(agent["ProgramArguments"], ["@PREFIX@/bin/swarmhub-update", "pull"])
        self.assertEqual(agent["StartInterval"], 6 * 3600)
        self.assertNotIn("KeepAlive", agent)


if __name__ == "__main__":
    unittest.main()
