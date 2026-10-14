#!/usr/bin/env python3
"""swarmhub-bots: a small route for SwarmHub on a Hermes box (P22, D2a/D3).

Listens on 127.0.0.1 behind nginx at /swarmhub/v1/. Every call except /health needs the manager
bot's (Jarvis's) API key as a Bearer token. It lists bots and reads their instructions; the only
thing it changes is handing a new bot's key to SwarmHub ONCE (then the pending marker is removed).
Stdlib only, run with `python3 -B` as the hermes user; never imports Hermes core.
"""
import hmac
import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERMES_ROOT = Path(os.environ.get("SWARMHUB_HERMES_ROOT", "/home/hermes/.hermes"))
PROFILES = HERMES_ROOT / "profiles"
STATE = HERMES_ROOT / "swarmhub"
MANAGER = os.environ.get("SWARMHUB_MANAGER", "grok-jarvis")
PORT = int(os.environ.get("SWARMHUB_PORT", "8644"))
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
PREFIX = "/swarmhub/v1"


def env_key(name):
    try:
        for line in (PROFILES / name / ".env").read_text(encoding="utf-8").splitlines():
            if line.startswith("API_SERVER_KEY="):
                return line.split("=", 1)[1].strip().strip("'\"")
    except OSError:
        pass
    return ""


def is_live(name):
    d = PROFILES / name
    return (NAME_RE.match(name) is not None and d.is_dir()
            and ((d / "profile.yaml").exists() or (d / "SOUL.md").exists()))


def description(name):
    try:
        for line in (PROFILES / name / "profile.yaml").read_text(encoding="utf-8").splitlines():
            if line.startswith("description:"):
                raw = line.split(":", 1)[1].strip()
                try:
                    return json.loads(raw) if raw.startswith('"') else raw.strip("'")
                except ValueError:
                    return raw.strip('"')
    except OSError:
        pass
    return ""


def registry_file():
    try:
        return json.loads((STATE / "bots.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def mtime(path):
    try:
        import datetime as dt
        return dt.datetime.fromtimestamp(path.stat().st_mtime, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    except OSError:
        return None


def list_bots():
    data = registry_file()
    reg, avatars = data.get("bots", {}), data.get("avatars", {})
    bots = []
    for d in sorted(PROFILES.iterdir()):
        if not is_live(d.name):
            continue
        bots.append({"name": d.name, "description": description(d.name),
                     "managed_by_jarvis": d.name in reg,
                     "paused": (d / "gateway.parked").exists(),
                     "key_waiting": (STATE / "pending" / d.name).exists(),
                     "has_key": bool(env_key(d.name)),
                     "instructions_updated": mtime(d / "SOUL.md"),
                     "avatar": avatars.get(d.name)})
    retired = [{"name": n, "retired": m["retired"]} for n, m in sorted(reg.items()) if m.get("retired")]
    return {"manager": MANAGER, "bots": bots, "retired": retired}


class Handler(BaseHTTPRequestHandler):
    server_version = "swarmhub-bots/1"
    sys_version = ""

    def log_message(self, format, *args):  # path + status only; never headers or bodies
        sys.stderr.write((format % args) + "\n")

    def send_json(self, status, body):
        data = json.dumps(body, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        expected = env_key(MANAGER)
        got = self.headers.get("Authorization", "")
        token = got[7:].strip() if got.startswith("Bearer ") else ""
        return len(expected) >= 16 and hmac.compare_digest(token.encode(), expected.encode())

    def route(self):
        path = self.path.split("?", 1)[0].rstrip("/")
        if not path.startswith(PREFIX):
            return None
        return path[len(PREFIX):].strip("/").split("/") if path != PREFIX else [""]

    def do_GET(self):
        parts = self.route()
        if parts == ["health"]:
            return self.send_json(200, {"ok": True})
        if parts is None:
            return self.send_json(404, {"error": "not found"})
        if not self.authorized():
            return self.send_json(401, {"error": "use the manager bot's key"})
        if parts == ["bots"]:
            return self.send_json(200, list_bots())
        if len(parts) == 3 and parts[0] == "bots" and parts[2] == "instructions":
            name = parts[1]
            if not is_live(name):
                return self.send_json(404, {"error": "no such bot"})
            soul = PROFILES / name / "SOUL.md"
            text = soul.read_text(encoding="utf-8") if soul.exists() else ""
            return self.send_json(200, {"name": name, "text": text, "updated": mtime(soul)})
        return self.send_json(404, {"error": "not found"})

    def do_POST(self):
        parts = self.route()
        if parts is None:
            return self.send_json(404, {"error": "not found"})
        if not self.authorized():
            return self.send_json(401, {"error": "use the manager bot's key"})
        if len(parts) == 3 and parts[0] == "bots" and parts[2] == "claim-key":
            name = parts[1]
            marker = STATE / "pending" / name
            if not NAME_RE.match(name) or not is_live(name) or not marker.exists():
                return self.send_json(404, {"error": "no key waiting for this bot"})
            key = env_key(name)
            if len(key) < 16:
                return self.send_json(409, {"error": "bot has no usable key; ask Jarvis to reissue it"})
            try:
                marker.unlink()
            except FileNotFoundError:   # another request claimed it first
                return self.send_json(404, {"error": "no key waiting for this bot"})
            return self.send_json(200, {"name": name, "key": key})
        return self.send_json(404, {"error": "not found"})


def main():
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
