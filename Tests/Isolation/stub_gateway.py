# Stub Hermes gateways for the isolation tests: one per state dir, each on its own 127.0.0.1 port (python3 -I).
#
#   python3 -I stub_gateway.py <all-keys file> <state dir>...
#
# <state>/keys: "<profile> <key>" lines this gateway accepts (/p/<profile>/… else "default"). <all-keys>: "<owner>
# <key>" for every key in the test, so a request can be logged with WHOSE key it carried (key=<owner>|none|unknown).
# <state>/mode, read per chat: ok | noreply | fail | delay:<seconds> | never; <state>/reply, if present, is the reply.
# delay/never send SSE comments every 0.2 s and log "left <session>" when the client goes away. Writes <state>/port,
# appends to <state>/requests and writes each chat as JSON {"session", "input", "profile", "key"} to <state>/input.<n>.
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ALL_KEYS = sys.argv[1]


def read(path, default=""):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read().strip()
    except OSError:
        return default


def pairs(path):
    return dict(line.split(" ", 1) for line in read(path).splitlines() if " " in line)


def serve(state):
    sessions, lock, count = set(), threading.Lock(), [0]

    def record(line):
        with lock, open(f"{state}/requests", "a", encoding="utf-8") as handle:
            handle.write(line + "\n")

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.0"  # A stream ends when the connection closes.

        def log_message(self, *args):
            pass

        def send(self, status, body, content_type="application/json"):
            data = body.encode()
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            path = self.path.split("?")[0]
            profile, rest = ("default", path)
            if path.startswith("/p/"):
                profile, _, tail = path[3:].partition("/")
                rest = "/" + tail
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length") or 0)) or b"{}")
            presented = (self.headers.get("Authorization") or "").removeprefix("Bearer ")
            owner = next((who for who, key in pairs(ALL_KEYS).items() if key == presented), None)
            who = owner or ("none" if not presented else "unknown")
            if not presented or pairs(f"{state}/keys").get(profile) != presented:
                record(f"POST {path} key={who} 401")
                return self.send(401, '{"error":{"message":"Invalid API key"}}')
            if rest == "/api/sessions":
                sid = body.get("id", "")
                with lock:
                    exists = (profile, sid) in sessions
                    sessions.add((profile, sid))
                record(f"POST {path} key={who} {409 if exists else 201} id={sid} title={body.get('title')}")
                return self.send(409 if exists else 201, json.dumps({"session": {"id": sid}}))
            if not (rest.startswith("/api/sessions/") and rest.endswith("/chat/stream")):
                record(f"POST {path} key={who} 404")
                return self.send(404, '{"error":"no route"}')
            sid = rest[len("/api/sessions/"):-len("/chat/stream")]
            with lock:
                count[0] += 1
                n = count[0]
            with open(f"{state}/input.{n}", "w", encoding="utf-8") as handle:
                json.dump({"session": sid, "input": body.get("input", ""), "profile": profile, "key": who}, handle)
            mode = read(f"{state}/mode", "ok")
            record(f"POST {path} key={who} 200 chat={n}")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            try:
                if mode.startswith("delay:") or mode == "never":
                    until = time.monotonic() + (float(mode[6:]) if mode != "never" else 120)
                    while time.monotonic() < until:
                        self.wfile.write(b": ping\n\n")
                        self.wfile.flush()
                        time.sleep(0.2)
                    if mode == "never":
                        return
                content = read(f"{state}/reply") or ("NO_REPLY" if mode == "noreply" else f"Hi from {profile}")
                events = ([("run.failed", {"error": "Provider authentication failed"})] if mode == "fail" else
                          [("run.started", {"session_id": sid}), ("assistant.completed", {"content": content}),
                           ("run.completed", {})])
                self.wfile.write("".join(f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events)
                                 .encode())
                self.wfile.flush()
                record(f"answered {sid} chat={n}")
            except (BrokenPipeError, ConnectionResetError):
                record(f"left {sid} chat={n}")

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    with open(f"{state}/port.tmp", "w") as handle:
        handle.write(str(server.server_address[1]))
    os.rename(f"{state}/port.tmp", f"{state}/port")
    server.serve_forever()


for folder in sys.argv[2:]:
    threading.Thread(target=serve, args=(folder,), daemon=True).start()
while True:
    time.sleep(3600)
