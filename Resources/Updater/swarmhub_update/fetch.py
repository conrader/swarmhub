"""Outbound HTTPS fetch for `swarmhub-update pull` (CORE-PLAN.md §3.1, §3.4; phase P3a). The only module of the
updater that opens a network connection.

- HTTPS only, certificates and host names verified (TLS 1.2 or newer) against the system trust store. Plain HTTP is
  accepted only to a loopback host and only when the caller asks for it (`allow_loopback_http`, the tests' local
  `http.server` fixtures); the command line never does.
- Every request sends `Cache-Control: no-store` (and `Pragma: no-cache`), so a cache in between is asked not to answer
  with a stored copy. Freshness does not rely on it: the signed index `expires` and the persisted floors do.
- A redirect is followed only to an allowlisted origin (scheme, host and port of a configured origin, or an extra
  allowed host), at most `MAX_REDIRECTS` times. Anything else is `redirect_refused`; nothing is fetched from it.
  Redirect bodies are closed without reading, so they consume none of the file's byte budget.
- Size caps: a declared `Content-Length` above the cap is refused before reading, and reading stops one byte past it
  (`oversize`). Every underlying read has a timeout capped by the remaining file deadline, including HTTP headers,
  chunk framing and redirects, so a slow host cannot hold the timer.
- Errors are `FetchError(reason)`: `host_unreachable`, `timeout`, `http_status`, `redirect_refused`, `oversize`,
  `url_refused`. The updater keeps running on what it has (§3.1 "fail closed means do not apply").

No credentials, cookies or query strings are sent; nothing about the box is reported. Stdlib only, Python 3.8+.
"""

import http.client
import socket
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

from . import VERSION

DEFAULT_TIMEOUT = 30.0  # seconds per connect / read
DEFAULT_DEADLINE = 300.0  # seconds per file
MAX_REDIRECTS = 3
LOOPBACK = {"127.0.0.1", "::1", "localhost"}
HEADERS = {"Cache-Control": "no-store", "Pragma": "no-cache", "Accept-Encoding": "identity",
           "User-Agent": "swarmhub-update/" + VERSION}
CHUNK = 1 << 16


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

    def read(self, size):
        chunks = []
        while size > 0:
            data = self.read1(size)
            if not data:
                break
            chunks.append(data)
            size -= len(data)
        return b"".join(chunks)

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


def _connection(connection_type, remaining):
    """Install the guard before HTTPResponse.begin, so response headers share the file deadline too."""
    class Response(http.client.HTTPResponse):
        def __init__(self, sock, *args, **kwargs):
            super().__init__(sock, *args, **kwargs)
            self.fp = _DeadlineStream(self.fp, sock, remaining)

    def create(*args, **kwargs):
        connection = connection_type(*args, **kwargs)
        connection.response_class = Response
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
                        target = urllib.parse.urljoin(current, location.replace(" ", "%20"))
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
