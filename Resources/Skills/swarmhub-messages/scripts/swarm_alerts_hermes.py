"""The alert service's read of this box's own Hermes API, the same public endpoints the app uses (`/api/jobs`,
`/api/sessions`), on loopback with each profile's API_SERVER_KEY read from its .env at call time (never copied).
Gateway URL like bot-msg: $SWARMHUB_GATEWAY/p/<profile>, else the profile's own API_SERVER_PORT, else :8642/p/<profile>.
Every call fails soft (None): a Hermes update that moves an endpoint costs alerts for routines, never the service.
"""
import json
import os
from pathlib import Path
import re
import time
import urllib.error
import urllib.parse
import urllib.request

from swarm_store import NAME

PRESENCE = "swarmhub-presence"
HANDOFF = re.compile(r"\Aswarmhub-(loop|goal)-[0-9a-f]{8}\Z")
UNTIL = re.compile(r"\buntil=(\d{1,12})\b")
FENCE = re.compile(r"```swarmhub[ \t]*\n(.*?)\n?```", re.S)
JOB_ID = re.compile(r"\A[0-9a-f]{12}\Z")


def env_value(path, name):
    value = ""
    try:
        lines = path.read_text().splitlines()
    except OSError:
        return ""
    for line in lines:
        match = re.fullmatch(r"\s*(?:export\s+)?" + name + r"=(.*)", line.rstrip("\r"))
        if match:
            value = match[1].strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
    return value


def profiles():
    """(profile, .env path) for each Hermes profile on this account that has an API key."""
    root = Path.home() / ".hermes"
    found = [("default", root / ".env")]
    try:
        found += [(p.name, p / ".env") for p in sorted((root / "profiles").iterdir()) if NAME.fullmatch(p.name)]
    except OSError:
        pass
    return [(name, env) for name, env in found if env.is_file() and env_value(env, "API_SERVER_KEY")]


def base_url(profile, env):
    gateway = os.environ.get("SWARMHUB_GATEWAY", "")
    port = env_value(env, "API_SERVER_PORT")
    if gateway:
        base, prefixed = gateway.rstrip("/"), True
    elif port.isdigit():
        base, prefixed = f"http://127.0.0.1:{port}", False
    else:
        base, prefixed = "http://127.0.0.1:8642", True
    base = base[:-3] if base.endswith("/v1") else base
    return f"{base}/p/{profile}" if prefixed and profile != "default" else base


def call(profile, env, path, method="GET", body=None, timeout=10):
    key = env_value(env, "API_SERVER_KEY")
    if not key or any(c.isspace() for c in key):
        return None
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(base_url(profile, env) + "/" + path, data=data, method=method)
    request.add_header("Authorization", "Bearer " + key)
    if data is not None:
        request.add_header("Content-Type", "application/json")
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))  # Loopback never goes through a proxy.
    try:
        with opener.open(request, timeout=timeout) as response:
            return json.loads(response.read(4 * 1024 * 1024) or b"{}")
    except (urllib.error.URLError, OSError, ValueError):
        return None


def jobs(profile, env):
    answer = call(profile, env, "api/jobs?include_disabled=true")
    rows = answer.get("jobs") if isinstance(answer, dict) else None
    return [row for row in rows if isinstance(row, dict) and isinstance(row.get("id"), str)] if isinstance(rows, list) else None


def presence_until(rows):
    """The app's lease: a paused job named swarmhub-presence whose prompt says until=<unix seconds>."""
    best = 0
    for row in rows:
        if row.get("name") == PRESENCE:
            match = UNTIL.search(str(row.get("prompt", "")))
            best = max(best, int(match[1]) if match else 0)
    return best


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(part.get("text", "") if isinstance(part, dict) else str(part) for part in content)
    return ""


def stamp(row, *keys):
    for key in keys:
        value = row.get(key)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return float(value)
    return 0.0


def latest_reply(profile, env, session, after=0.0):
    """(timestamp, text) of the newest assistant message of a session, if it is later than `after`."""
    answer = call(profile, env, f"api/sessions/{urllib.parse.quote(session, safe='')}/messages?order=latest&limit=50")
    rows = answer.get("data") if isinstance(answer, dict) else None
    best = None
    for index, row in enumerate(rows if isinstance(rows, list) else []):
        if not isinstance(row, dict) or row.get("role") != "assistant":
            continue
        text = text_of(row.get("content")).strip()
        when = stamp(row, "timestamp", "created_at")
        if text and (best is None or (when, index) > best[:2]):
            best = (when, index, text)
    if best is None or (after and best[0] and best[0] <= after):
        return None
    return best[0], best[2]


def sessions(profile, env, query):
    answer = call(profile, env, "api/sessions?" + query)
    rows = answer.get("data") if isinstance(answer, dict) else None
    return [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []


def run_output(profile, env, job):
    """The last run's output (the cron session's last reply), like the app's `HermesJobsClient.runResult`: the
    scheduler runs a job in a session `cron_<job id>_<time>` titled `<name> · <time>` or `cron <job id>`."""
    ident, name = job["id"], " ".join(str(job.get("name", "")).split())[:60]
    for query in ("source=cron&limit=50&offset=0", "limit=100&offset=0"):
        matches = [row for row in sessions(profile, env, query)
                   if str(row.get("id", "")).startswith(f"cron_{ident}_") or row.get("title") == f"cron {ident}"
                   or (name and str(row.get("title", "")).startswith(name + " · "))]
        if matches:
            newest = max(matches, key=lambda row: (stamp(row, "started_at"), str(row.get("id", ""))))
            reply = latest_reply(profile, env, str(newest["id"]))
            return reply[1] if reply else ""
    return None


def bot_chat_reply(profile, env, after):
    """The newest reply in the profile's "Bot Chat" session (where `bot-chat:` routines answer) later than `after`."""
    rows = [row for row in sessions(profile, env, "limit=100&offset=0") if row.get("title") == "Bot Chat"]
    if not rows:
        return None
    newest = max(rows, key=lambda row: stamp(row, "last_active", "started_at"))
    return latest_reply(profile, env, str(newest.get("id", "")), after)


def pause(profile, env, job_id):
    if not JOB_ID.fullmatch(job_id):
        return False
    return call(profile, env, f"api/jobs/{job_id}/pause", method="POST", body={}) is not None


def block_status(text):
    """("loop"|"goal", status) of the last ```swarmhub block in a reply that ends a loop or a goal, else None."""
    found = None
    for body in FENCE.findall(text or ""):
        try:
            block = json.loads(body)
        except ValueError:
            continue
        if isinstance(block, dict) and block.get("op") in ("loop", "goal") and block.get("status") in ("done", "blocked"):
            found = (block["op"], block["status"])
    return found


def iso_seconds(value):
    """Unix seconds of a Hermes ISO time (`2026-10-23T08:00:00+02:00`, `…Z`, or naive local), else 0."""
    from datetime import datetime
    if not isinstance(value, str) or not value:
        return 0.0
    try:
        moment = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
    except ValueError:
        return 0.0
    return moment.timestamp() if moment.tzinfo else time.mktime(moment.timetuple())
