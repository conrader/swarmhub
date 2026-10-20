"""The per-file deadline covers DNS, TCP connect, proxy CONNECT and the TLS handshake, not only reads (fetch.py).
Fake resolvers and sockets, or loopback listeners that never answer; nothing reaches the real network."""

from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import ROOT  # noqa: E402,F401 (updater import path)
from swarmhub_update import fetch  # noqa: E402

BASE = "https://updates.invalid/"
PROXY = {"https": "http://proxy.invalid:3128"}


class BlackholeSocket:
    """Every connect waits out its whole timeout on the fake clock, like an address that drops SYNs."""

    def __init__(self, clock, *args):
        self.clock, self.timeout = clock, None

    def settimeout(self, value):
        self.timeout = value

    def connect(self, address):
        self.clock[0] += self.timeout
        raise socket.timeout("simulated connect timeout")

    def close(self):
        pass


class Listener:
    """A loopback port whose peer never speaks (TLS handshake stalls), or a proxy that accepts CONNECT and then
    stalls inside the tunnel."""

    def __init__(self, proxy=False):
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port, self.held, self.stop = self.sock.getsockname()[1], [], threading.Event()
        if proxy:
            threading.Thread(target=self.tunnel, daemon=True).start()

    def tunnel(self):
        try:
            peer, _ = self.sock.accept()
        except OSError:
            return
        self.held.append(peer)
        request = b""
        while b"\r\n\r\n" not in request:
            data = peer.recv(4096)
            if not data:
                return
            request += data
        peer.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
        self.stop.wait(10)

    def close(self):
        self.stop.set()
        for peer in self.held:
            peer.close()
        self.sock.close()


class WholeFetchDeadline(unittest.TestCase):
    def reason(self, fetcher, url=BASE + "keys.json"):
        start = time.monotonic()
        with self.assertRaises(fetch.FetchError) as caught:
            fetcher.get(url, 100)
        return caught.exception, time.monotonic() - start

    def test_hanging_dns_lookup_ends_at_the_deadline(self):
        for proxies in ({}, PROXY):
            with self.subTest(proxy=bool(proxies)):
                release = threading.Event()
                self.addCleanup(release.set)

                def hang(*args, **kwargs):
                    release.wait(5)  # a resolver that does not answer (released at cleanup)
                    raise socket.gaierror(socket.EAI_AGAIN, "no answer")

                fetcher = fetch.Fetcher([BASE], proxies=proxies, deadline=1.0)
                with patch("socket.getaddrinfo", hang):
                    error, elapsed = self.reason(fetcher)
                release.set()
                self.assertEqual(error.reason, "timeout")
                self.assertIn("DNS lookup", error.detail)
                self.assertLessEqual(elapsed, 1.0 + fetch.DEADLINE_SLACK)

    def test_every_address_connect_shares_the_deadline(self):
        clock = [0]
        addresses = [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("192.0.2.%d" % n, 443)) for n in (1, 2, 3)]
        fetcher = fetch.Fetcher([BASE], proxies={}, timeout=30, deadline=40, clock=lambda: clock[0])
        with patch("socket.getaddrinfo", lambda *args, **kwargs: addresses), \
                patch("socket.socket", lambda *args: BlackholeSocket(clock, *args)):
            error, _ = self.reason(fetcher)
        self.assertEqual(error.reason, "timeout")
        self.assertLessEqual(clock[0], 40 + fetch.DEADLINE_SLACK)  # create_connection alone spent 3 x 30 s

    def test_slow_lookup_then_stalled_tls_handshake_ends_at_the_deadline(self):
        for proxy in (False, True):
            with self.subTest(proxy=proxy):
                listener = Listener(proxy)
                self.addCleanup(listener.close)
                real = socket.getaddrinfo

                def slow(host, port, *args, **kwargs):
                    time.sleep(1.5)  # most of the deadline goes on the lookup
                    return real("127.0.0.1", listener.port, *args, **kwargs)

                base = "https://updates.invalid:%d/" % listener.port
                proxies = PROXY if proxy else {}
                fetcher = fetch.Fetcher([base], proxies=proxies, timeout=30, deadline=2.0)
                with patch("socket.getaddrinfo", slow):
                    error, elapsed = self.reason(fetcher, base + "keys.json")
                self.assertEqual(error.reason, "timeout")
                self.assertLessEqual(elapsed, 2.0 + fetch.DEADLINE_SLACK)


if __name__ == "__main__":
    unittest.main()
