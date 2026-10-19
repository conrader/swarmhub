"""SwarmHub-owned HTTPS control transport. No Hermes plugin/API changes.

Run behind the existing Hermes TLS reverse proxy on a loopback-only port. Keys
are resolved from the existing profile .env on each request, never copied. The
public origin is operator configuration, never inferred from forwarded headers.
"""
import base64
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import re
import time
from urllib.parse import urlsplit
import uuid

from swarm_policy import decide_in_transaction, policy
from swarm_store import NAME, canonical, database, profile_exists

LIMIT = 1024 * 1024
TTL = 60
PREFIX = "/swarmhub/control/v1/"


def origin_url(value):
    parts = urlsplit(value)
    if (parts.scheme != "https" or not parts.hostname or parts.username or parts.password
            or parts.query or parts.fragment or parts.path not in ("", "/")
            or parts.netloc != parts.netloc.lower()):
        raise ValueError("control requires a canonical HTTPS origin without a path")
    return value.rstrip("/")


def profile_key(profile):
    if not profile_exists(profile):
        raise ValueError("unknown profile")
    root = Path.home() / ".hermes"
    if profile != "default":
        root = root / "profiles" / profile
    # Same API_SERVER_KEY source and quoting as bot-msg; never source shell code.
    key = ""
    for line in (root / ".env").read_text().splitlines():
        match = re.fullmatch(r"\s*(?:export\s+)?API_SERVER_KEY=(.*)", line)
        if match:
            key = match[1].strip()
            if len(key) >= 2 and key[0] == key[-1] and key[0] in "\"'":
                key = key[1:-1]
    if not key or any(c.isspace() or c in '\\"' for c in key):
        raise ValueError("profile key unavailable")
    return key


def mac(key, purpose, payload):
    return hmac.new(key.encode(), b"swarmhub-approval-v1:" + purpose.encode() + b"\n" + payload,
                    hashlib.sha256).hexdigest()


def load_json(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate JSON key")
            result[key] = value
        return result
    return json.loads(raw, object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid number")))


class ControlService:
    def __init__(self, origin, wake):
        self.origin = origin_url(origin)
        self.wake = wake
        with database() as db:
            db.execute("INSERT OR IGNORE INTO approval_runtime VALUES(1,?)", (str(uuid.uuid4()),))
            self.runtime = db.execute("SELECT identity FROM approval_runtime WHERE id=1").fetchone()[0]

    def handle(self, path, authorization, signature, raw):
        """Pure HTTP boundary, also exercised without sockets by the offline tests."""
        if not path.startswith(PREFIX) or len(raw) > LIMIT:
            raise ValueError("invalid request")
        profile = path[len(PREFIX):]
        if not NAME.fullmatch(profile):
            raise ValueError("invalid profile")
        key = profile_key(profile)  # Rotation takes effect without restarting this service.
        if (not hmac.compare_digest(authorization, "Bearer " + key)
                or not hmac.compare_digest(signature, mac(key, "request", raw))):
            raise ValueError("authentication failed")
        request = load_json(raw)
        required = {"version", "origin", "profile", "verb", "task", "nonce", "issued", "expires"}
        if not isinstance(request, dict) or not required <= request.keys():
            raise ValueError("invalid request")
        verb = request["verb"]
        fields = required | ({"binding", "fingerprint", "gate", "approved"} if verb == "decide" else set())
        now = time.time()
        if (set(request) != fields or request["version"] != 1 or verb not in ("get", "decide")
                or request["origin"] != self.origin or request["profile"] != profile
                or not isinstance(request["task"], str) or not re.fullmatch(r"task\.[a-f0-9]{32}", request["task"])
                or not isinstance(request["nonce"], str) or not re.fullmatch(r"[a-f0-9-]{36}", request["nonce"])
                or type(request["issued"]) is not int or type(request["expires"]) is not int
                or not now - TTL <= request["issued"] <= now + 5
                or not now < request["expires"] <= request["issued"] + TTL):
            raise ValueError("wrong destination, invalid or expired request")
        digest = hashlib.sha256(raw).hexdigest()
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            row = db.execute("SELECT * FROM actions WHERE id=?", (request["task"],)).fetchone()
            if not row:
                raise ValueError("unknown operation")
            record = dict(row)
            record["spec"] = load_json(record["spec"])
            if hashlib.sha256(canonical(record["spec"]).encode()).hexdigest() != record["fingerprint"]:
                raise ValueError("corrupt operation")
            record["decider"] = policy(db).get(record["gate"])
            binding = {"origin": self.origin, "runtime": self.runtime, "profile": record["decider"]}
            record["remoteBinding"] = binding
            if profile not in (record["decider"], record["spec"].get("bot")):
                raise ValueError("profile cannot read this operation")
            saved = db.execute("SELECT * FROM approval_receipts WHERE task=?", (record["id"],)).fetchone()
            if saved:
                # Return the durable decision even if the worker has since completed/cancelled.
                receipt = load_json(saved["receipt"])
                if (load_json(saved["binding"]) != binding or receipt["fingerprint"] != record["fingerprint"]
                        or receipt["spec"] != record["spec"] or receipt["gate"] != record["gate"]):
                    raise ValueError("receipt scope changed")
                record = receipt
            if verb == "decide":
                if time.time() >= request["expires"]:
                    raise ValueError("request expired while waiting for the runtime")
                if (type(request["approved"]) is not bool or request["binding"] != binding
                        or profile != record["decider"] or request["fingerprint"] != record["fingerprint"]
                        or request["gate"] != record["gate"]):
                    raise ValueError("decision binding mismatch")
                old = db.execute("SELECT digest FROM approval_nonces WHERE nonce=?", (request["nonce"],)).fetchone()
                if old and old[0] != digest:
                    raise ValueError("nonce reused with different content")
                if saved:
                    if bool(saved["approved"]) != request["approved"]:
                        raise ValueError("decision is final")
                else:
                    decide_in_transaction(db, record["id"], profile, request["approved"],
                                          record["fingerprint"], record["gate"])
                    decided = db.execute("SELECT status,decided_by,decided_at FROM actions WHERE id=?", (record["id"],)).fetchone()
                    record.update(dict(decided))
                    record["remoteReceipt"] = {"id": str(uuid.uuid4()), "approved": request["approved"]}
                    db.execute("INSERT INTO approval_receipts VALUES(?,?,?,?)",
                               (record["id"], canonical(binding), int(request["approved"]), canonical(record)))
                db.execute("DELETE FROM approval_nonces WHERE expires<?", (now,))
                db.execute("INSERT OR IGNORE INTO approval_nonces VALUES(?,?,?)",
                           (request["nonce"], digest, request["expires"]))
        # Decision + receipt commit together. Lost response/restart can never re-execute a decision.
        if verb == "decide" and request["approved"]:
            self.wake()  # Idempotent worker startup; an ACK lost here is reconciled by get.
        payload = canonical({"request": digest, "expires": request["expires"], "record": record}).encode()
        return {"payload": base64.b64encode(payload).decode(), "signature": mac(key, "response", payload)}


def serve(origin, port, wake):
    service = ControlService(origin, wake)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass  # No request bodies, credentials or operation content in HTTP logs.

        def do_POST(self):
            self.connection.settimeout(10)
            try:
                lengths = self.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or self.headers.get("Transfer-Encoding"):
                    raise ValueError("invalid framing")
                size = int(lengths[0])
                if not 0 < size <= LIMIT:
                    raise ValueError("invalid size")
                raw = self.rfile.read(size)
                if len(raw) != size:
                    raise ValueError("incomplete body")
                result = service.handle(self.path, self.headers.get("Authorization", ""),
                                        self.headers.get("X-SwarmHub-Signature", ""), raw)
                data = canonical(result).encode()
                self.send_response(200)
            except (ValueError, OSError, KeyError, TypeError):
                data = b'{"error":"control request refused"}'
                self.send_response(403)
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    # Never expose the plaintext hop or trust X-Forwarded-* as authentication.
    with ThreadingHTTPServer(("127.0.0.1", port), Handler) as server:
        server.serve_forever()
