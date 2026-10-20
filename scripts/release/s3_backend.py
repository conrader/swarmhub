"""Minimal stdlib S3 SigV4 client for R2/B2-style path-addressed endpoints.

Explicit credentials only: no environment, AWS config, metadata, or SDK discovery.
No redirects (including region redirects); configure the correct endpoint/region.
The injectable opener and clock allow fully offline request/signature tests.
"""

from datetime import datetime, timezone
import hashlib
import hmac
import re
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from backends import BackendError


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class S3Client:
    def __init__(self, endpoint, bucket, region, access_key, secret_key, *, session_token=None,
                 prefix="", opener=None, clock=None):
        url = urlsplit(endpoint)
        if (url.scheme != "https" or not url.netloc or url.username or url.password or url.query or
                url.fragment or url.path not in ("", "/")):
            raise BackendError("S3 endpoint must be an HTTPS origin without credentials or a path")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", bucket) or not region or not access_key or not secret_key:
            raise BackendError("S3 bucket, region and explicit credentials are required")
        if prefix and any(p in ("", ".", "..") for p in prefix.split("/")):
            raise BackendError("invalid S3 prefix")
        self.origin, self.host = endpoint.rstrip("/"), url.netloc
        self.bucket, self.region, self.prefix = bucket, region, prefix
        self.access_key, self.secret_key, self.session_token = access_key, secret_key, session_token
        self.opener = opener or build_opener(NoRedirect())
        self.clock = clock or (lambda: datetime.now(timezone.utc))

    def _request(self, method, key, data=b"", headers=None):
        if any(p in ("", ".", "..") for p in key.split("/")):
            raise BackendError("invalid object key")
        path = quote("/" + "/".join(p for p in (self.bucket, self.prefix, key) if p), safe="/-_.~")
        timestamp = self.clock().strftime("%Y%m%dT%H%M%SZ")
        day = timestamp[:8]
        digest = hashlib.sha256(data).hexdigest()
        signed = {"host": self.host, "x-amz-date": timestamp, "x-amz-content-sha256": digest}
        signed.update({k.lower(): v for k, v in (headers or {}).items()})
        if self.session_token:
            signed["x-amz-security-token"] = self.session_token
        signed = {k: " ".join(v.split()) for k, v in signed.items()}
        names = ";".join(sorted(signed))
        canonical_headers = "".join(f"{k}:{signed[k]}\n" for k in sorted(signed))
        canonical = "\n".join((method, path, "", canonical_headers, names, digest))
        scope = f"{day}/{self.region}/s3/aws4_request"
        message = f"AWS4-HMAC-SHA256\n{timestamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
        signing_key = ("AWS4" + self.secret_key).encode()
        for part in (day, self.region, "s3", "aws4_request"):
            signing_key = hmac.new(signing_key, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(signing_key, message.encode(), hashlib.sha256).hexdigest()
        signed["authorization"] = (f"AWS4-HMAC-SHA256 Credential={self.access_key}/{scope}, "
                                   f"SignedHeaders={names}, Signature={signature}")
        req = Request(self.origin + path, data=data if method == "PUT" else None, headers=signed, method=method)
        try:
            with self.opener.open(req, timeout=60) as response:
                return response.read(), response.headers.get("ETag")
        except HTTPError as error:
            if method == "GET" and error.code == 404:
                return None
            raise BackendError(f"S3 {method} {key}: HTTP {error.code}") from error

    def get(self, key):
        result = self._request("GET", key)
        if result is not None and not result[1]:
            raise BackendError(f"S3 {key}: missing ETag; refusing unsafe write")
        return result

    def put(self, key, data, *, cache_control, content_type, if_none_match, if_match):
        headers = {"Cache-Control": cache_control, "Content-Type": content_type}
        if if_none_match:
            headers["If-None-Match"] = "*"
        elif if_match:
            headers["If-Match"] = if_match
        else:
            raise BackendError("S3 put requires a conditional write")
        self._request("PUT", key, data, headers)
