# A stub Hermes gateway for bot-msg-test.sh (python3 -I, standard library only, 127.0.0.1 on a free port).
#
#   python3 -I bot-msg-stub-gateway.py <state dir>
#
# <state>/reset (a new case): forget sessions and restart the input count.
# <state>/keys: "<profile> <key>" lines. <state>/mode: ok | slow | fail | down500 (read per request); slow holds the
# reply until the test creates <state>/release, then writes <state>/answered and answers.
# Writes <state>/port when listening; appends "<METHOD> <path> <auth ok|bad> <status> [title=… id=…]" to
# <state>/requests and the decoded chat input to <state>/input.<n>. Profiles: /p/<profile>/api/… else default.
import json, os, sys, time, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = sys.argv[1]
SESSIONS = set()
LOCK = threading.Lock()
COUNT = [0]


def read(name, default=""):
    try:
        with open(f"{STATE}/{name}") as f:
            return f.read().strip()
    except OSError:
        return default


def record(line):
    with LOCK, open(f"{STATE}/requests", "a") as f:
        f.write(line + "\n")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def split(self):
        path = self.path.split("?")[0]
        if path.startswith("/p/"):
            profile, _, rest = path[3:].partition("/")
            return profile, "/" + rest
        return "default", path

    def send(self, status, body, content_type="application/json"):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if os.path.exists(f"{STATE}/reset"):
            with LOCK:
                SESSIONS.clear()
                COUNT[0] = 0
            os.remove(f"{STATE}/reset")
        profile, path = self.split()
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        keys = dict(line.split(" ", 1) for line in read("keys").splitlines() if " " in line)
        auth = "ok" if keys.get(profile) and self.headers.get("Authorization") == f"Bearer {keys[profile]}" else "bad"
        if auth != "ok":
            record(f"POST {self.path} bad 401")
            return self.send(401, '{"error":{"message":"Invalid API key"}}')
        mode = read("mode", "ok")
        if path == "/api/sessions":
            sid = body.get("id", "")
            with LOCK:
                exists = (profile, sid) in SESSIONS
                SESSIONS.add((profile, sid))
            status = 409 if exists else 201
            record(f"POST {self.path} ok {status} title={body.get('title')} id={sid} source={body.get('source')}")
            if exists:
                return self.send(409, json.dumps({"error": {"message": f"Session already exists: {sid}", "code": "session_exists"}}))
            return self.send(201, json.dumps({"object": "hermes.session", "session": {"id": sid, "title": body.get("title")}}))
        if path.startswith("/api/sessions/") and path.endswith("/chat/stream"):
            sid = path[len("/api/sessions/"):-len("/chat/stream")]
            with LOCK:
                COUNT[0] += 1
                n = COUNT[0]
            with open(f"{STATE}/input.{n}", "w") as f:
                f.write(body.get("input", ""))
            known = (profile, sid) in SESSIONS
            if mode == "down500":
                record(f"POST {self.path} ok 500")
                return self.send(500, '{"error":{"message":"boom"}}')
            record(f"POST {self.path} ok 200 known={known}")
            if mode == "slow":
                # Released by the test, not after a time, so a loaded machine cannot answer early; the ceiling bounds a hang.
                deadline = time.monotonic() + 120
                while not os.path.exists(f"{STATE}/release") and time.monotonic() < deadline:
                    time.sleep(0.02)
                open(f"{STATE}/answered", "w").close()
            if mode == "fail":
                events = [("run.started", {}), ("run.failed", {"error": "Provider authentication failed"})]
            else:
                events = [("run.started", {"session_id": sid}), ("assistant.delta", {"delta": "partial "}),
                          ("assistant.completed", {"content": f"Hi from {profile}: Zażółć ✓ \"done\"\nline two"}),
                          ("run.completed", {})]
            stream = "".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events) + "event: done\ndata: {}\n\n"
            return self.send(200, stream, "text/event-stream")
        record(f"POST {self.path} {auth} 404")
        self.send(404, '{"error":"no route"}')


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(f"{STATE}/port.tmp", "w") as f:
    f.write(str(server.server_address[1]))
os.rename(f"{STATE}/port.tmp", f"{STATE}/port")
server.serve_forever()
