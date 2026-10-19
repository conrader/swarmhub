"""Managed webhook routines: a registered, keyed URL that wakes one profile through the durable delivery journal.

The key lives only in an owner-only file (0600 under the 0700 state folder) and is never
printed, journaled or returned by any command. The URL carries an unguessable slug, not the
key; callers present the key in the `X-SwarmHub-Key` header. A fired routine becomes a
durable self-delivery to the profile, so it survives restarts and is acknowledged like any
other wake. The loopback receiver binds 127.0.0.1 only; exposing it is the reverse proxy's job.
"""
import hmac
import json
from pathlib import Path
import re
import secrets
import time

from swarm_delivery import TEXT_LIMIT, enqueue
from swarm_intake import write_private
from swarm_policy import policy
from swarm_store import NAME, database, profile_exists, state

PATH = re.compile(r"/swarmhub/webhook/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/([A-Za-z0-9_-]+)\Z")
DEFAULT_PORT = 8745
KEY_NOTE = "stored in key_file (owner-only); never printed"


class UnknownWebhook(ValueError):
    pass


def key_folder():
    folder = state() / "webhooks"
    if folder.is_symlink():
        raise ValueError("webhook folder must not be a symlink")
    folder.mkdir(mode=0o700, exist_ok=True)
    folder.chmod(0o700)
    return folder


def write_key(path):
    """A fresh key; the file is created 0600 and the value is not returned."""
    value = secrets.token_urlsafe(32)
    write_private(path, (value + "\n").encode())
    return None


def url(profile, routine, slug):
    base = policy().get("webhook_base") or f"http://127.0.0.1:{DEFAULT_PORT}"
    return base.rstrip("/") + f"/swarmhub/webhook/{profile}/{routine}/{slug}"


def describe(row):
    return {"profile": row["profile"], "routine": row["routine"], "url": url(row["profile"], row["routine"], row["slug"]),
            "key_file": row["key_file"], "key": KEY_NOTE, "created": row["created"], "rotated": row["rotated"],
            "fired": row["fired"], "header": "X-SwarmHub-Key"}


def record(profile, routine, db):
    row = db.execute("SELECT * FROM webhooks WHERE profile=? AND routine=?", (profile, routine)).fetchone()
    if not row:
        raise UnknownWebhook("unknown webhook routine")
    return row


def check(profile, routine):
    if not profile_exists(profile):
        raise ValueError("unknown profile")
    if not isinstance(routine, str) or not NAME.fullmatch(routine) or len(routine) > 64:
        raise ValueError("routine must be a short name")


def register(profile, routine):
    check(profile, routine)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        existing = db.execute("SELECT * FROM webhooks WHERE profile=? AND routine=?", (profile, routine)).fetchone()
        if existing:
            return describe(existing)  # Idempotent: re-registering never rotates or reveals the key.
        slug = secrets.token_urlsafe(18)
        path = key_folder() / f"{slug}.key"  # Dot-containing profile/routine pairs cannot collide.
        write_key(path)
        now = time.time()
        db.execute("INSERT INTO webhooks VALUES(?,?,?,?,?,?,0)", (profile, routine, slug, str(path), now, now))
        return describe(db.execute("SELECT * FROM webhooks WHERE profile=? AND routine=?", (profile, routine)).fetchone())


def show(profile, routine):
    check(profile, routine)
    with database() as db:
        return describe(record(profile, routine, db))


def rotate(profile, routine):
    """A new key in the same file; the previous key is rejected from the moment the file is rewritten."""
    check(profile, routine)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = record(profile, routine, db)
        write_key(Path(row["key_file"]))
        db.execute("UPDATE webhooks SET rotated=? WHERE profile=? AND routine=?", (time.time(), profile, routine))
        return describe(record(profile, routine, db))


def listing():
    with database() as db:
        return [describe(row) for row in db.execute("SELECT * FROM webhooks ORDER BY profile,routine")]


def fire(profile, routine, slug, key, text):
    """Verify the presented key in constant time, then journal one durable wake for the profile."""
    check(profile, routine)
    if not isinstance(key, str) or not key or not isinstance(text, str) or not text.strip():
        raise ValueError("key and text are required")
    if len(text) > TEXT_LIMIT - 200:
        raise ValueError("text too long")
    with database() as db:
        row = record(profile, routine, db)
    try:
        stored = Path(row["key_file"]).read_text().strip()
    except OSError as exc:
        raise ValueError("webhook key file unavailable") from exc
    if row["slug"] != slug or not hmac.compare_digest(stored.encode(), key.encode()):
        raise PermissionError("webhook rejected")
    ident = enqueue(profile, profile, f"[Webhook routine {routine} for {profile}]\n{text}")
    with database() as db:
        db.execute("UPDATE webhooks SET fired=fired+1 WHERE profile=? AND routine=?", (profile, routine))
    return {"profile": profile, "routine": routine, "delivery": ident, "status": "pending"}


def request_handler():
    """Build the HTTP handler separately so protocol validation can be tested without sockets."""
    from http.server import BaseHTTPRequestHandler

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):  # Keys and payloads never reach a log line.
            pass

        def answer(self, code, body):
            data = (json.dumps(body, sort_keys=True) + "\n").encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            match = PATH.match(self.path.split("?", 1)[0])
            if not match:
                return self.answer(404, {"error": "unknown webhook"})
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if not 0 < length <= TEXT_LIMIT or self.headers.get("Transfer-Encoding"):
                    raise ValueError("invalid request length")
                payload = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(payload, dict):
                    raise ValueError("expected object")
                result = fire(*match.groups(), self.headers.get("X-SwarmHub-Key", ""), payload.get("text", ""))
            except PermissionError:
                return self.answer(403, {"error": "webhook rejected"})
            except UnknownWebhook:
                return self.answer(404, {"error": "unknown webhook"})
            except (ValueError, OSError):
                return self.answer(400, {"error": "bad request"})
            self.answer(202, result)
    return Handler


def serve(port=DEFAULT_PORT, once=False, ready=None):
    """Loopback receiver: POST <url> with X-SwarmHub-Key and JSON {"text": ...}; never logs keys."""
    from http.server import ThreadingHTTPServer

    server = ThreadingHTTPServer(("127.0.0.1", int(port)), request_handler())
    if ready:
        ready(server.server_address[1])
    try:
        if once:
            server.handle_request()
        else:
            server.serve_forever()
    finally:
        server.server_close()
    return server.server_address[1]
