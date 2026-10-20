"""Review regressions using real urllib/HTTPResponse parsers over in-memory sockets; no network."""

import http.client
import io
from pathlib import Path
import socket
import sys
import unittest
from unittest.mock import patch
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cli_fixtures import ROOT  # noqa: E402,F401 (updater import path)
from swarmhub_update import fetch  # noqa: E402

BASE = "https://updates.invalid/"


class Wire(io.RawIOBase):
    def __init__(self, data, clock, head_size):
        self.data, self.offset, self.clock, self.head_size = data, 0, clock, head_size
        self.drip, self.stall = False, False
        self.timeout, self.timeouts = 30, []
        self._sock = self  # same layout as socket.SocketIO, used by the transport

    def readable(self):
        return True

    def settimeout(self, value):
        self.timeout = value
        self.timeouts.append(value)

    def readinto(self, target):
        if self.offset == len(self.data):
            return 0
        delay = 1 if self.drip else 0
        if self.stall or delay > self.timeout:
            self.clock[0] += self.timeout
            raise socket.timeout("simulated socket timeout")
        self.clock[0] += delay
        count = min(len(target), len(self.data) - self.offset, 1 if self.drip else len(target))
        if self.offset < self.head_size:
            count = min(count, self.head_size - self.offset)
        target[:count] = self.data[self.offset:self.offset + count]
        self.offset += count
        return count


class MemorySocket:
    def __init__(self, wire):
        self.wire = wire

    def makefile(self, mode):
        return io.BufferedReader(self.wire)

    def settimeout(self, value):
        self.wire.settimeout(value)

    def sendall(self, data):
        pass  # the HTTPConnection may send its request; this socket is entirely in memory

    def close(self):
        pass  # a real socket's makefile holds a reference after the connection itself closes


def response(body, clock, status=200, headers=()):
    head = ("HTTP/1.1 %d OK\r\n" % status).encode()
    head += b"".join(("%s: %s\r\n" % pair).encode() for pair in headers) + b"\r\n"
    wire = Wire(head + body, clock, len(head))
    reply = http.client.HTTPResponse(MemorySocket(wire))
    reply.begin()
    reply.url = BASE + "file"
    return reply, wire, len(head)


class MemoryHandler(urllib.request.HTTPSHandler):
    handler_order = 100  # before the normal HTTPS handler

    def __init__(self, replies):
        super().__init__()
        self.replies, self.paths = iter(replies), []

    def https_open(self, request):
        self.paths.append(request.full_url)
        reply = next(self.replies)
        reply.url = request.full_url
        return reply


class FetchLimits(unittest.TestCase):
    def through_handler(self, data, deadline=300, limit=1000, drip=False, scheme="https"):
        clock = [0]
        head_size = data.index(b"\r\n\r\n") + 4
        wire = Wire(data, clock, head_size)
        wire.drip = drip
        sock = MemorySocket(wire)

        def connect(connection):
            connection.sock = sock

        connection_type = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
        base = BASE if scheme == "https" else "http://127.0.0.1/"
        fetcher = fetch.Fetcher([base], proxies={}, deadline=deadline, clock=lambda: clock[0],
                                allow_loopback_http=scheme == "http")
        with patch.object(connection_type, "connect", connect):
            return fetcher.get(base + "file", limit), wire, clock

    def test_http_handlers_read_plain_and_chunked_bodies(self):
        for scheme in ("http", "https"):
            for headers, body in ((b"Content-Length: 2\r\n", b"ok"),
                                  (b"Transfer-Encoding: chunked\r\n", b"2\r\nok\r\n0\r\nExtra: yes\r\n\r\n"),
                                  (b"", b"ok")):
                with self.subTest(scheme=scheme, headers=headers):
                    data, _, _ = self.through_handler(b"HTTP/1.1 200 OK\r\n" + headers + b"\r\n" + body,
                                                      scheme=scheme, drip=True)
                    self.assertEqual(data, b"ok")

    def test_dripping_response_headers_share_the_deadline(self):
        with self.assertRaises(fetch.FetchError) as caught:
            self.through_handler(b"HTTP/1.1 200 OK\r\nX-Slow: " + b"x" * 1000 + b"\r\n\r\nok",
                                 deadline=3, drip=True)
        self.assertEqual(caught.exception.reason, "timeout")

    def test_body_limit_stops_network_reads_at_the_detection_byte(self):
        data = b"HTTP/1.1 200 OK\r\n\r\n" + b"x" * 1000
        clock = [0]
        head_size = data.index(b"\r\n\r\n") + 4
        wire = Wire(data, clock, head_size)

        def connect(connection):
            connection.sock = MemorySocket(wire)

        fetcher = fetch.Fetcher([BASE], proxies={})
        with patch.object(http.client.HTTPSConnection, "connect", connect):
            with self.assertRaises(fetch.FetchError) as caught:
                fetcher.get(BASE + "file", 7)
        self.assertEqual(caught.exception.reason, "oversize")
        self.assertEqual(wire.offset - head_size, 8)

    def test_redirect_bodies_are_closed_without_reading(self):
        limit = 1 << 20
        for status in (301, 302, 303, 307, 308):
            for declared in (False, True):
                with self.subTest(status=status, declared=declared):
                    clock = [0]
                    headers = [("Location", "/next")]
                    if declared:
                        headers.append(("Content-Length", str(2 * limit)))
                    redirect, wire, head_size = response(b"x" * (2 * limit), clock, status, headers)
                    final, final_wire, final_head = response(b"ok", clock, headers=[("Content-Length", "2")])
                    before = wire.offset
                    self.addCleanup(redirect.close)
                    self.addCleanup(final.close)
                    fetcher = fetch.Fetcher([BASE], proxies={})
                    handler = MemoryHandler([redirect, final])
                    fetcher.opener.add_handler(handler)
                    self.assertEqual(fetcher.get(BASE + "file", limit), b"ok")
                    self.assertEqual(wire.offset, before, "redirect body was drained")
                    self.assertTrue(wire.closed)
                    self.assertLessEqual(max(0, wire.offset - head_size)
                                         + max(0, final_wire.offset - final_head), limit)
                    self.assertEqual(handler.paths, [BASE + "file", BASE + "next"])

    def test_dripping_body_cannot_overrun_deadline_inside_a_read(self):
        for chunked in (False, True):
            with self.subTest(chunked=chunked):
                clock = [0]
                # Drip the chunk header too: a read1 alone still blocks in its readline parser.
                body = b"1000;" + b"x" * 1000 + b"\r\n" + b"x" * 4096 + b"\r\n0\r\n\r\n" if chunked else b"x" * 1000
                headers = [("Transfer-Encoding", "chunked")] if chunked else [("Content-Length", "1000")]
                reply, wire, _ = response(body, clock, headers=headers)
                self.addCleanup(reply.close)
                wire.drip = True
                fetcher = fetch.Fetcher([BASE], proxies={}, deadline=300, clock=lambda: clock[0])
                with self.assertRaises(fetch.FetchError) as caught:
                    fetcher._read(BASE + "file", reply, 5000)
                self.assertEqual(caught.exception.reason, "timeout")
                self.assertLessEqual(clock[0], 300)

    def test_read_timeout_shrinks_to_remaining_deadline(self):
        clock = [0]
        reply, wire, _ = response(b"xy", clock, headers=[("Content-Length", "2")])
        self.addCleanup(reply.close)
        wire.stall = True
        fetcher = fetch.Fetcher([BASE], proxies={}, timeout=30, deadline=3, clock=lambda: clock[0])
        with self.assertRaises(fetch.FetchError) as caught:
            fetcher._read(BASE + "file", reply, 100)
        self.assertEqual(caught.exception.reason, "timeout")
        self.assertLessEqual(clock[0], 3)
        self.assertTrue(wire.timeouts)


class StreamGuard(unittest.TestCase):
    """HTTPResponse.readinto/peek/read() go through the same guard as read1, or are refused."""

    def guarded(self, body, headers, deadline=300):
        clock = [0]
        reply, wire, head_size = response(body, clock, headers=headers)
        self.addCleanup(reply.close)
        fetcher = fetch.Fetcher([BASE], proxies={}, clock=lambda: clock[0])
        reply.fp = fetch._DeadlineStream(reply.fp, wire, lambda: fetcher._remaining(BASE + "file", deadline))
        return reply, wire, head_size, clock

    def test_readinto_reads_only_what_fits_and_keeps_the_deadline(self):
        for chunked in (False, True):
            with self.subTest(chunked=chunked):
                body = b"8\r\n12345678\r\n0\r\n\r\n" if chunked else b"12345678"
                headers = [("Transfer-Encoding", "chunked")] if chunked else [("Content-Length", "8")]
                reply, wire, head_size, _ = self.guarded(body, headers)
                buffer = bytearray(5)
                self.assertEqual(reply.readinto(buffer), 5)
                self.assertEqual(bytes(buffer), b"12345")
                if not chunked:
                    self.assertEqual(wire.offset - head_size, 5)  # nothing read ahead
                slow = b"3e8\r\n" + b"x" * 1000 + b"\r\n0\r\n\r\n" if chunked else b"x" * 1000
                headers = [("Transfer-Encoding", "chunked")] if chunked else [("Content-Length", "1000")]
                reply, wire, _, clock = self.guarded(slow, headers, deadline=3)
                wire.drip = True
                with self.assertRaises(fetch.FetchError) as caught:
                    reply.readinto(bytearray(1000))
                self.assertEqual(caught.exception.reason, "timeout")
                self.assertLessEqual(clock[0], 3)

    def test_peek_and_unbounded_read_are_refused(self):
        reply, wire, _, _ = self.guarded(b"x" * 1000, [])
        before = wire.offset
        with self.assertRaises(io.UnsupportedOperation):
            reply.peek(1)
        with self.assertRaises(io.UnsupportedOperation):
            reply.read()  # no Content-Length: http.client would read to EOF
        self.assertEqual(wire.offset, before)


class RedirectLocation(unittest.TestCase):
    """Location is normalised (control characters refused, unsafe bytes escaped, resolved) before the allowlist."""

    def follow(self, location, start=BASE + "dir/file"):
        clock = [0]
        redirect, _, _ = response(b"", clock, 302, [("Location", location), ("Content-Length", "0")])
        final, _, _ = response(b"ok", clock, headers=[("Content-Length", "2")])
        self.addCleanup(redirect.close)
        self.addCleanup(final.close)
        fetcher = fetch.Fetcher([BASE], proxies={})
        handler = MemoryHandler([redirect, final])
        fetcher.opener.add_handler(handler)
        try:
            self.assertEqual(fetcher.get(start, 100), b"ok")
        except fetch.FetchError as error:
            return error.reason
        return handler.paths[-1]

    def test_unsafe_bytes_are_percent_encoded_and_relative_urls_resolved(self):
        # response() writes headers as UTF-8: the two bytes of "\xfc" come back as their own escapes.
        cases = {"/a b/\xfc\"<>`{|}^\\x": BASE + "a%20b/%C3%BC%22%3C%3E%60%7B%7C%7D%5E%5Cx",
                 "/50%off/%2Fkept%2f": BASE + "50%25off/%2Fkept%2f",
                 "next?v=1": BASE + "dir/next?v=1", "../up": BASE + "up", " /padded ": BASE + "padded",
                 "https://updates.invalid/abs": BASE + "abs", "//updates.invalid/net": BASE + "net"}
        for location, expected in cases.items():
            with self.subTest(location=location):
                self.assertEqual(self.follow(location), expected)

    def test_refused_locations_fetch_nothing(self):
        for location in ("/x\x00y", "/x\x01", "/x\x7f", "/a\tb", "/trailing\t", " /padded\t", "http://updates.invalid/x", "ftp://updates.invalid/x",
                         "https://user@updates.invalid/x", "https://u:p@updates.invalid/x", "//evil.invalid/x",
                         "https://updates.invalid\\@evil.invalid/", "https://updates%2Einvalid/x",
                         "https://\xfcpdates.invalid/x", "javascript:alert(1)", "data:text/plain,x"):
            with self.subTest(location=location):
                self.assertEqual(self.follow(location), "redirect_refused")


    def test_control_characters_are_refused_before_any_stripping(self):
        # http.client already drops a header value's leading whitespace, so the raw function is checked directly too.
        for char in ("\t", "\r", "\n", "\x00", "\x0b", "\x1f", "\x7f"):
            for location in (char + "/lead", "/trail" + char, "/in" + char + "side", " /x" + char + " "):
                with self.subTest(location=location):
                    with self.assertRaises(ValueError):
                        fetch.redirect_target(BASE + "dir/file", location)
        self.assertEqual(fetch.redirect_target(BASE + "dir/file", "  /spaces  "), BASE + "spaces")


if __name__ == "__main__":
    unittest.main()
