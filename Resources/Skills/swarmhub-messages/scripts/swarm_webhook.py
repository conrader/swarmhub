"""Managed webhook routines: a registered, keyed URL that wakes one profile through the durable delivery journal.

The key lives only in an owner-only file (0600 under the 0700 state folder) and is never
printed, journaled or returned by any command. The URL carries an unguessable slug, not the
key; callers present the key in the `X-SwarmHub-Key` header. The app instead generates the key on the owner's Mac,
shows it there once and sends only `sha256:<hex>` (`--key-hash`), so the key never reaches this box, a turn or a log;
the key file then holds that digest and calls are checked against it. A fired routine becomes a
durable self-delivery to the profile, so it survives restarts and is acknowledged like any
other wake. The loopback receiver binds 127.0.0.1 only; exposing it is the reverse proxy's job.
"""
import hashlib
import hmac
import json
from pathlib import Path
import re
import secrets
import sys
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


KEY_HASH = re.compile(r"sha256:[0-9a-f]{64}\Z")


def write_key(path, key_hash=None):
    """A fresh key, or the digest of a key generated elsewhere; the file is created 0600 and nothing is returned."""
    if key_hash is not None and not (isinstance(key_hash, str) and KEY_HASH.fullmatch(key_hash)):
        raise ValueError("key hash must be sha256:<64 lowercase hex>")
    value = key_hash or secrets.token_urlsafe(32)
    write_private(path, (value + "\n").encode())
    return None


def matches(stored, key):
    if KEY_HASH.fullmatch(stored):
        stored, key = stored[7:], hashlib.sha256(key.encode()).hexdigest()
    return hmac.compare_digest(stored.encode(), key.encode())


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


def register(profile, routine, key_hash=None):
    check(profile, routine)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        existing = db.execute("SELECT * FROM webhooks WHERE profile=? AND routine=?", (profile, routine)).fetchone()
        if existing:
            if key_hash is not None and Path(existing["key_file"]).read_text().strip() != key_hash:
                raise ValueError("webhook routine already exists; rotate its key or choose another name")
            return describe(existing)  # Idempotent: re-registering never rotates or reveals the key.
        slug = secrets.token_urlsafe(18)
        path = key_folder() / f"{slug}.key"  # Dot-containing profile/routine pairs cannot collide.
        write_key(path, key_hash)
        now = time.time()
        db.execute("INSERT INTO webhooks VALUES(?,?,?,?,?,?,0)", (profile, routine, slug, str(path), now, now))
        return describe(record(profile, routine, db))


def show(profile, routine):
    check(profile, routine)
    with database() as db:
        return describe(record(profile, routine, db))


def rotate(profile, routine, key_hash=None):
    """A new key in the same file; the previous key is rejected from the moment the file is rewritten."""
    check(profile, routine)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = record(profile, routine, db)
        write_key(Path(row["key_file"]), key_hash)
        db.execute("UPDATE webhooks SET rotated=? WHERE profile=? AND routine=?", (time.time(), profile, routine))
        return describe(record(profile, routine, db))


def delete(profile, routine):
    """Forget the routine and remove its key file; the URL stops working at once. Deleting twice is not an error."""
    if not all(isinstance(v, str) and NAME.fullmatch(v) and len(v) <= 64 for v in (profile, routine)):
        raise ValueError("profile and routine must be short names")  # A removed profile's routines stay deletable.
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT * FROM webhooks WHERE profile=? AND routine=?", (profile, routine)).fetchone()
        if row:
            db.execute("DELETE FROM webhooks WHERE profile=? AND routine=?", (profile, routine))
    if row:
        path = Path(row["key_file"])
        if path.parent == key_folder() and path.name == row["slug"] + ".key":
            path.unlink(missing_ok=True)
    return {"profile": profile, "routine": routine, "deleted": bool(row)}


def listing():
    with database() as db:
        return [describe(row) for row in db.execute("SELECT * FROM webhooks ORDER BY profile,routine")]


PANEL_ACTIONS = ("list", "register", "rotate", "delete", "receiver-install")


def panel(profile, action, routine=None, key_hash=None):
    """The app's one call per click: do one action, then answer with the profile's routines and the receiver state.

    register/rotate take only the digest of a key the app generated (`key_hash`), so this answer never holds a key.
    """
    import swarm_webhook_receiver as receiver
    if not isinstance(profile, str) or not NAME.fullmatch(profile) or len(profile) > 64:
        raise ValueError("profile must be a short name")
    if action not in PANEL_ACTIONS:
        raise ValueError("panel action must be one of " + ", ".join(PANEL_ACTIONS))
    if action in ("register", "rotate") and key_hash is None:
        raise ValueError("the app's register and rotate need --key-hash")
    if (routine is None) != (action in ("list", "receiver-install")):
        raise ValueError("register, rotate and delete name a routine; list and receiver-install do not")
    result = None
    if action == "register":
        result = register(profile, routine, key_hash)
    elif action == "rotate":
        result = rotate(profile, routine, key_hash)
    elif action == "delete":
        result = delete(profile, routine)
    elif action == "receiver-install":
        try:
            result = receiver.install()
        except ValueError as exc:
            result = {"error": str(exc)}  # Still answer with the state so the app can show why.
    return {"schema": "swarmhub/webhooks/1", "profile": profile, "action": action, "result": result,
            "webhooks": [row for row in listing() if row["profile"] == profile], "receiver": receiver.status()}


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
    if row["slug"] != slug or not matches(stored, key):
        raise PermissionError("webhook rejected")
    ident = enqueue(profile, profile, f"[Webhook routine {routine} for {profile}]\n{text}")
    with database() as db:
        db.execute("UPDATE webhooks SET fired=fired+1 WHERE profile=? AND routine=?", (profile, routine))
    return {"profile": profile, "routine": routine, "delivery": ident, "status": "pending"}


def request_handler(on_fire=None):
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

        def do_GET(self):
            # Reachability for `webhook receiver status` and the app; says nothing about routines.
            if self.path.split("?", 1)[0] == "/swarmhub/webhook/health":
                return self.answer(200, {"ok": True, "service": "swarmhub-webhook"})
            return self.answer(404, {"error": "unknown webhook"})

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
            if on_fire:
                try:
                    on_fire()
                except Exception:  # noqa: BLE001  The wake is journalled; any later worker start delivers it.
                    pass
    return Handler


def serve(port=DEFAULT_PORT, once=False, ready=None, on_fire=None):
    """Loopback receiver: POST <url> with X-SwarmHub-Key and JSON {"text": ...}; never logs keys.

    `on_fire` runs after each accepted call (swarmctl passes the delivery worker's idempotent start)."""
    from http.server import ThreadingHTTPServer

    server = ThreadingHTTPServer(("127.0.0.1", int(port)), request_handler(on_fire))
    if ready:
        ready(server.server_address[1])
    if not once:
        print(f"swarmhub-webhook: listening on 127.0.0.1:{server.server_address[1]}", file=sys.stderr, flush=True)
    try:
        if once:
            server.handle_request()
        else:
            server.serve_forever()
    finally:
        server.server_close()
    return server.server_address[1]
