"""Loopback stand-ins for the off-app alert tests: a Hermes API (jobs, sessions, pause), an ntfy server and an SMTP
relay. Nothing leaves 127.0.0.1; no real ntfy or mail service is ever contacted."""
import base64
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import socketserver
import threading
from urllib.parse import urlsplit


def serve(handler):
    server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


class FakeHermes:
    """Profiles' jobs and sessions behind one gateway (`SWARMHUB_GATEWAY`, `/p/<profile>/…`; default unprefixed)."""

    def __init__(self, keys):
        self.keys, self.jobs, self.sessions, self.messages = keys, {}, {}, {}
        self.requests, self.paused, self.down = [], [], False
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def answer(self, code, body):
                data = json.dumps(body).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def route(self, method):
                parts = urlsplit(self.path)
                path, profile = parts.path, "default"
                if path.startswith("/p/"):
                    profile, path = path[3:].split("/", 1)[0], "/" + path[3:].split("/", 1)[1]
                fake.requests.append((method, profile, path + ("?" + parts.query if parts.query else "")))
                if fake.down:
                    return self.answer(503, {"error": "down"})
                if self.headers.get("Authorization") != "Bearer " + fake.keys.get(profile, "\0"):
                    return self.answer(401, {"error": "unauthorized"})
                if method == "GET" and path == "/api/jobs":
                    return self.answer(200, {"jobs": fake.jobs.get(profile, [])})
                if method == "GET" and path == "/api/sessions":
                    return self.answer(200, {"data": fake.sessions.get(profile, [])})
                if method == "GET" and path.startswith("/api/sessions/") and path.endswith("/messages"):
                    return self.answer(200, {"data": fake.messages.get(path.split("/")[3], [])})
                if method == "POST" and path.startswith("/api/jobs/") and path.endswith("/pause"):
                    fake.paused.append((profile, path.split("/")[3]))
                    return self.answer(200, {"job": {"id": path.split("/")[3], "enabled": False}})
                return self.answer(404, {"error": "not found"})

            def do_GET(self):
                self.route("GET")

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length") or 0))
                self.route("POST")

        self.server = serve(Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FakeNtfy:
    def __init__(self, status=200):
        self.posts, self.status = [], status
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
                fake.posts.append({"path": self.path, "headers": dict(self.headers), "body": body})
                self.send_response(fake.status)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

        self.server = serve(Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}/swarm-alerts"

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class FakeSMTP:
    """Enough of RFC 5321 for smtplib: EHLO, AUTH PLAIN, MAIL, RCPT, DATA, QUIT. Plain TCP (security "none")."""

    def __init__(self):
        self.messages, self.auth = [], []
        fake = self

        class Handler(socketserver.StreamRequestHandler):
            def reply(self, line):
                self.wfile.write(line.encode() + b"\r\n")

            def handle(self):
                self.reply("220 fake ESMTP")
                envelope = {}
                while True:
                    line = self.rfile.readline().decode().rstrip("\r\n")
                    if not line:
                        return
                    verb = line.split(" ", 1)[0].upper()
                    if verb in ("EHLO", "HELO"):
                        self.wfile.write(b"250-fake\r\n250 AUTH PLAIN\r\n")
                    elif verb == "AUTH":
                        fake.auth.append(base64.b64decode(line.split(" ")[2]).split(b"\0")[1:])
                        self.reply("235 ok")
                    elif verb in ("MAIL", "RCPT", "RSET", "NOOP"):
                        envelope.setdefault(verb, []).append(line)
                        self.reply("250 ok")
                    elif verb == "DATA":
                        self.reply("354 go")
                        data = b""
                        while not data.endswith(b"\r\n.\r\n"):
                            chunk = self.rfile.readline()
                            if not chunk:
                                return
                            data += chunk
                        fake.messages.append({"envelope": envelope, "data": data.decode(errors="replace")})
                        self.reply("250 queued")
                    elif verb == "QUIT":
                        self.reply("221 bye")
                        return
                    else:
                        self.reply("502 no")

        self.server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.port = self.server.server_address[1]

    def close(self):
        self.server.shutdown()
        self.server.server_close()
