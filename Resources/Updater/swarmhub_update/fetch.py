"""Outbound HTTPS fetch for `swarmhub-update pull` (CORE-PLAN.md §3.1, §3.4; phase P3a). The only module of the
updater that opens a network connection.

- HTTPS only, certificates and host names verified (TLS 1.2 or newer) against the system trust store. Plain HTTP is
  accepted only to a loopback host and only when the caller asks for it (`allow_loopback_http`, the tests' local
  `http.server` fixtures); the command line never does.
- Every request sends `Cache-Control: no-store` (and `Pragma: no-cache`), so a cache in between is asked not to answer
  with a stored copy. Freshness does not rely on it: the signed index `expires` and the persisted floors do.
- A redirect is followed only to an allowlisted origin (scheme, host and port of a configured origin, or an extra
  allowed host), at most `MAX_REDIRECTS` times. The Location is normalised first (`redirect_target`): control
  characters refused, unsafe bytes percent-encoded, resolved against the current URL; then it must be https (or the
  tests' loopback http) without userinfo. Anything else is `redirect_refused`; nothing is fetched from it.
  Redirect bodies are closed without reading, so they consume none of the file's byte budget.
- Size caps: a declared `Content-Length` above the cap is refused before reading, and reading stops one byte past it
  (`oversize`). The response stream only reads what it is asked for: no read-ahead (`peek`) and no unbounded read.
- Deadline: one per file, shared by every step of every hop: DNS lookup (on a helper thread, since getaddrinfo has
  no timeout), TCP connect (each address), proxy CONNECT, TLS handshake, response headers, chunk framing and body
  reads. Each step's timeout is the smaller of `DEFAULT_TIMEOUT` and what is left, so a file's wall time stays within
  the deadline plus `DEADLINE_SLACK` (scheduling slack only); past it the fetch fails with `timeout`.
- Errors are `FetchError(reason)`: `host_unreachable`, `timeout`, `http_status`, `redirect_refused`, `oversize`,
  `url_refused`. The updater keeps running on what it has (§3.1 "fail closed means do not apply").

No credentials, cookies or query strings are sent; nothing about the box is reported. Stdlib only, Python 3.8+.
"""

import http.client
import io
import re
import socket
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

from . import VERSION

DEFAULT_TIMEOUT = 30.0  # seconds per connect / read
DEFAULT_DEADLINE = 300.0  # seconds per file
DEADLINE_SLACK = 1.0  # seconds a file may run past its deadline (thread and timer scheduling); tests assert it
MAX_REDIRECTS = 3
LOOPBACK = {"127.0.0.1", "::1", "localhost"}
HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache", "Accept-Encoding": "identity",
           "User-Agent": "swarmhub-update/" + VERSION}
CHUNK = 1 << 16
URL_SAFE = "-._~:/?#[]@!$&'()*+,;=%"  # RFC 3986 unreserved punctuation, reserved characters, existing escapes
LONE_PERCENT = re.compile(r"%(?![0-9A-Fa-f]{2})")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")


class FetchError(Exception):
    def __init__(self, reason, url, detail=""):
        super().__init__("%s: %s%s" % (reason, url, " (%s)" % detail if detail else ""))
        self.reason, self.url, self.detail = reason, url, detail


def origin_key(url, allow_loopback_http=False):
    """(scheme, host, port) of an absolute URL the updater may contact, or FetchError `url_refused`."""
    try:
        parts = urllib.parse.urlsplit(url)
        port = parts.port
    except ValueError as error:
        raise FetchError("url_refused", url, str(error)) from None
    host = (parts.hostname or "").lower()
    if not host or parts.username is not None or parts.password is not None:
        raise FetchError("url_refused", url, "no host, or credentials in the URL")
    if parts.scheme == "https":
        return "https", host, port or 443
    if parts.scheme == "http" and allow_loopback_http and host in LOOPBACK:
        return "http", host, port or 80
    raise FetchError("url_refused", url, "only https is allowed")


def normalize_origin(url, allow_loopback_http=False):
    """A base URL for the service layout: absolute, no query or fragment, ending in `/`."""
    origin_key(url, allow_loopback_http)
    parts = urllib.parse.urlsplit(url)
    if parts.query or parts.fragment:
        raise FetchError("url_refused", url, "an origin has no query or fragment")
    return url if url.endswith("/") else url + "/"


def redirect_target(current, location):
    """The absolute URL a `Location` (or `URI`) header points to, or ValueError. http.client decodes header bytes as
    ISO-8859-1, so those bytes are recovered and every one outside URL_SAFE is percent-encoded (a `%` that does not
    start an escape too), then the result is resolved against `current`. Scheme, host and userinfo are checked by
    the caller's allowlist (origin_key). Control characters (tab included) are refused on the raw value, before
    surrounding spaces are stripped."""
    if CONTROL.search(location):
        raise ValueError("control character in the redirect location")
    value = location.strip(" ")
    quoted = urllib.parse.quote(LONE_PERCENT.sub("%25", value), safe=URL_SAFE, encoding="iso-8859-1")
    return urllib.parse.urljoin(current, quoted)


class _Redirects(urllib.request.HTTPRedirectHandler):
    """Return redirects untouched. Fetcher closes them without draining any body bytes."""

    def http_error_302(self, req, fp, code, msg, headers):
        return fp

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


class _DeadlineStream:
    """Guard every underlying read, including HTTPResponse's chunk headers and trailers.

    read1 returns available bytes rather than waiting for a full buffer. read/readline build on it so a peer
    dripping bytes cannot keep a single HTTP parser call alive past the deadline. Nothing reads ahead here.
    """

    def __init__(self, stream, sock, remaining):
        self.stream, self.sock, self.remaining = stream, sock, remaining

    def read1(self, size):
        self.sock.settimeout(self.remaining())
        data = self.stream.read1(size)
        self.remaining()  # also reject a late EOF
        return data

    def read(self, size=-1):
        if size is None or size < 0:
            raise io.UnsupportedOperation("unbounded read: the fetcher reads with a size cap")
        chunks = []
        while size > 0:
            data = self.read1(size)
            if not data:
                break
            chunks.append(data)
            size -= len(data)
        return b"".join(chunks)

    def readinto(self, buffer):
        """Fill `buffer` from read1 calls (each under the deadline), stopping early only at EOF."""
        view, filled = memoryview(buffer).cast("B"), 0
        while filled < len(view):
            data = self.read1(len(view) - filled)
            if not data:
                break
            view[filled:filled + len(data)] = data
            filled += len(data)
        return filled

    def peek(self, size=0):
        raise io.UnsupportedOperation("peek reads ahead a whole buffer: not allowed past the size cap")

    def readline(self, limit):
        data = bytearray()
        while len(data) < limit:
            byte = self.read1(1)
            if not byte:
                break
            data.extend(byte)
            if byte == b"\n":
                break
        return bytes(data)

    def close(self):
        self.stream.close()

    def flush(self):
        self.stream.flush()


def _resolve(host, port, timeout):
    """getaddrinfo has no timeout of its own: run it on a daemon thread and stop waiting after `timeout`. A lookup
    that never returns leaves only that idle thread behind (the command exits anyway); the fetch fails closed."""
    outcome = []

    def lookup():
        try:
            outcome.append(socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM))
        except Exception as error:  # handed to the waiting thread below
            outcome.append(error)

    thread = threading.Thread(target=lookup, name="swarmhub-update-dns", daemon=True)
    thread.start()
    thread.join(timeout)
    if not outcome:
        raise socket.timeout("DNS lookup of %s timed out" % host)
    if isinstance(outcome[0], Exception):
        raise outcome[0]
    return outcome[0]


def _open_socket(address, remaining, source_address=None):
    """socket.create_connection with every step under the file deadline: the lookup, and each address's connect
    (create_connection gives every address the full timeout). The socket leaves with the time still left for the
    next step (a proxy CONNECT send, or the TLS handshake, bounded as a whole by it); _connection resets it after
    each later step."""
    host, port = address
    error = OSError("no address for %s" % host)
    for family, kind, proto, _, sockaddr in _resolve(host, port, remaining()):
        sock = socket.socket(family, kind, proto)
        try:
            sock.settimeout(remaining())
            if source_address:
                sock.bind(source_address)
            sock.connect(sockaddr)
            sock.settimeout(remaining())
            return sock
        except OSError as caught:
            sock.close()
            error = caught
        except BaseException:
            sock.close()
            raise
    raise error


def _connection(connection_type, remaining):
    """Install the guard before HTTPResponse.begin, so response headers share the file deadline too, and open the
    socket under the same deadline. A socket timeout is only as fresh as when it was set, so it is reset to the time
    left after the proxy CONNECT reply (before the TLS handshake) and after connect (before the request send)."""
    class Response(http.client.HTTPResponse):
        def __init__(self, sock, *args, **kwargs):
            super().__init__(sock, *args, **kwargs)
            self.fp = _DeadlineStream(self.fp, sock, remaining)

    def create(*args, **kwargs):
        connection = connection_type(*args, **kwargs)
        connection.response_class = Response
        connection._create_connection = (
            lambda address, timeout=None, source_address=None: _open_socket(address, remaining, source_address))
        tunnel, connect = connection._tunnel, connection.connect

        def tunnel_then_reset():
            tunnel()
            connection.sock.settimeout(remaining())

        def connect_then_reset():
            connect()
            connection.sock.settimeout(remaining())

        connection._tunnel, connection.connect = tunnel_then_reset, connect_then_reset
        return connection

    return create


class _HTTPHandler(urllib.request.HTTPHandler):
    def http_open(self, req):
        return self.do_open(_connection(http.client.HTTPConnection, req.update_remaining), req)


class _HTTPSHandler(urllib.request.HTTPSHandler):
    def https_open(self, req):
        return self.do_open(_connection(http.client.HTTPSConnection, req.update_remaining), req,
                            context=self._context)


class Fetcher:
    """GETs files from allowlisted origins. `origins`: base URLs; `allow_hosts`: extra https hosts a redirect may
    reach (a mirror's download host). `context`: TLS context (default: system trust, TLS 1.2+). `proxies`: as
    urllib.request.ProxyHandler (None = the environment's proxy settings)."""

    def __init__(self, origins, allow_hosts=(), *, timeout=DEFAULT_TIMEOUT, deadline=DEFAULT_DEADLINE, context=None,
                 allow_loopback_http=False, proxies=None, clock=time.monotonic):
        self.loopback_http = allow_loopback_http
        self.allowed = {origin_key(url, allow_loopback_http) for url in origins}
        self.allowed |= {("https", host.lower(), 443) for host in allow_hosts}
        self.timeout, self.deadline, self.clock = timeout, deadline, clock
        if context is None:
            context = ssl.create_default_context()
            context.minimum_version = ssl.TLSVersion.TLSv1_2
        handlers = [urllib.request.ProxyHandler(proxies) if proxies is not None else urllib.request.ProxyHandler(),
                    _HTTPHandler(), _HTTPSHandler(context=context), _Redirects()]
        self.opener = urllib.request.build_opener(*handlers)
        self.opener.addheaders = []
        self.requests = []  # URLs asked for, in order (status and tests)

    def check(self, url):
        if origin_key(url, self.loopback_http) not in self.allowed:
            raise FetchError("url_refused", url, "not an allowlisted origin")

    def get(self, url, limit):
        """The body of `url` (HTTP 200), at most `limit` bytes."""
        self.check(url)
        self.requests.append(url)
        expires = self.clock() + self.deadline
        current = url
        try:
            for hop in range(MAX_REDIRECTS + 1):
                request = urllib.request.Request(current, headers=dict(HEADERS), method="GET")
                request.update_remaining = lambda: self._remaining(url, expires)
                response = self.opener.open(request, timeout=self._remaining(url, expires))
                with response:
                    if response.status not in (301, 302, 303, 307, 308):
                        return self._read(url, response, limit, expires)
                    location = response.headers.get("Location", response.headers.get("URI"))
                    if location is None or hop == MAX_REDIRECTS:
                        raise FetchError("http_status", current, "invalid or excessive redirects")
                    try:
                        target = redirect_target(current, location)
                        self.check(target)
                    except (FetchError, ValueError):
                        raise FetchError("redirect_refused", current, "redirect to %s" % location) from None
                # Closing, rather than consuming, the redirect body spends zero bytes of the file's limit.
                current = target
        except urllib.error.HTTPError as error:
            error.close()
            raise FetchError("http_status", url, "HTTP %d" % error.code) from None
        except urllib.error.URLError as error:
            timed_out = isinstance(error.reason, (socket.timeout, TimeoutError))
            raise FetchError("timeout" if timed_out else "host_unreachable", url, str(error.reason)) from None
        except (socket.timeout, TimeoutError) as error:
            raise FetchError("timeout", url, str(error)) from None
        except (http.client.HTTPException, OSError) as error:
            raise FetchError("host_unreachable", url, "%s: %s" % (type(error).__name__, error)) from None

    def _remaining(self, url, expires):
        remaining = expires - self.clock()
        if remaining <= 0:
            raise FetchError("timeout", url, "file deadline exceeded")
        return min(self.timeout, remaining)

    def _read(self, url, response, limit, expires=None):
        if response.status != 200:
            raise FetchError("http_status", url, "HTTP %d" % response.status)
        self.check(response.geturl())  # where the body really came from
        declared = response.headers.get("Content-Length")
        if declared is not None and declared.strip().isdigit() and int(declared) > limit:
            raise FetchError("oversize", url, "Content-Length %s above %d" % (declared.strip(), limit))
        if expires is None:
            expires = self.clock() + self.deadline
        if not isinstance(response.fp, _DeadlineStream):
            try:
                # Test/injected HTTPResponses must provide the same enforceable socket bounds as our handlers.
                sock, stream = response.fp.raw._sock, response.fp
                if not callable(sock.settimeout) or not callable(stream.read1):
                    raise AttributeError("unbounded response stream")
            except AttributeError:
                raise FetchError("timeout", url, "cannot enforce the socket deadline") from None
            response.fp = _DeadlineStream(stream, sock, lambda: self._remaining(url, expires))
        chunks, total = [], 0
        while True:
            try:
                self._remaining(url, expires)
                chunk = response.read1(min(CHUNK, limit + 1 - total))
            except (socket.timeout, TimeoutError) as error:
                raise FetchError("timeout", url, str(error)) from None
            except (http.client.HTTPException, OSError) as error:
                raise FetchError("host_unreachable", url, "%s: %s" % (type(error).__name__, error)) from None
            self._remaining(url, expires)
            if not chunk:
                return b"".join(chunks)
            total += len(chunk)
            if total > limit:
                raise FetchError("oversize", url, "more than %d bytes" % limit)
            chunks.append(chunk)
