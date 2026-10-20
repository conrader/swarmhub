"""Outbound HTTPS fetch for `swarmhub-update pull` (CORE-PLAN.md §3.1, §3.4; phase P3a). The only module of the
updater that opens a network connection.

- HTTPS only, certificates and host names verified (TLS 1.2 or newer) against the system trust store. Plain HTTP is
  accepted only to a loopback host and only when the caller asks for it (`allow_loopback_http`, the tests' local
  `http.server` fixtures); the command line never does.
- Every request sends `Cache-Control: no-store` (and `Pragma: no-cache`), so a cache in between is asked not to answer
  with a stored copy. Freshness does not rely on it: the signed index `expires` and the persisted floors do.
- A redirect is followed only to an allowlisted origin (scheme, host and port of a configured origin, or an extra
  allowed host), at most `MAX_REDIRECTS` times. Anything else is `redirect_refused`; nothing is fetched from it.
- Size caps: a declared `Content-Length` above the cap is refused before reading, and reading stops one byte past it
  (`oversize`). Every read has a timeout and a whole file has a deadline, so a slow host cannot hold the timer.
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


class _Refused(Exception):
    def __init__(self, error):
        super().__init__(str(error))
        self.error = error


class _Redirects(urllib.request.HTTPRedirectHandler):
    """Follows a redirect only to an allowlisted origin."""
    max_redirections = MAX_REDIRECTS

    def __init__(self, check):
        super().__init__()
        self.check = check

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            self.check(newurl)
        except FetchError as error:
            fp.close()
            raise _Refused(FetchError("redirect_refused", newurl, "redirect from %s" % req.full_url)) from error
        return super().redirect_request(req, fp, code, msg, headers, newurl)


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
                    urllib.request.HTTPSHandler(context=context), _Redirects(self.check)]
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
        request = urllib.request.Request(url, headers=dict(HEADERS), method="GET")
        try:
            response = self.opener.open(request, timeout=self.timeout)
        except _Refused as refused:
            raise refused.error from None
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
        with response:
            return self._read(url, response, limit)

    def _read(self, url, response, limit):
        if response.status != 200:
            raise FetchError("http_status", url, "HTTP %d" % response.status)
        self.check(response.geturl())  # where the body really came from
        declared = response.headers.get("Content-Length")
        if declared is not None and declared.strip().isdigit() and int(declared) > limit:
            raise FetchError("oversize", url, "Content-Length %s above %d" % (declared.strip(), limit))
        started, chunks, total = self.clock(), [], 0
        while True:
            try:
                chunk = response.read(min(CHUNK, limit + 1 - total))
            except (socket.timeout, TimeoutError) as error:
                raise FetchError("timeout", url, str(error)) from None
            except (http.client.HTTPException, OSError) as error:
                raise FetchError("host_unreachable", url, "%s: %s" % (type(error).__name__, error)) from None
            if not chunk:
                return b"".join(chunks)
            total += len(chunk)
            if total > limit:
                raise FetchError("oversize", url, "more than %d bytes" % limit)
            if self.clock() - started > self.deadline:
                raise FetchError("timeout", url, "slower than the %d s deadline" % self.deadline)
            chunks.append(chunk)
