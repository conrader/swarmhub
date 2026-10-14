#!/usr/bin/env python3
"""Loopback-only synthetic Hermes wire fixture. No agents, tools or providers."""
import argparse
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

SESSIONS = {}
RUNS = {}
LOCK = threading.Lock()
FEATURES = {"session_chat_streaming": True, "run_stop": True, "run_steer": True, "run_approval_response": True}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *_):
        pass
    def reply(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def route(self):
        if self.headers.get("Authorization") != "Bearer mobile-fixture":
            self.reply({"error": "fixture key rejected"}, 401)
            return None, None
        path = urlparse(self.path).path
        profile = "default"
        if path.startswith("/p/"):
            _, _, profile, tail = path.split("/", 3)
            path = "/" + tail
        return path, profile
    def do_GET(self):
        path, profile = self.route()
        if path is None: return
        if path == "/v1/models":
            self.reply({"data": [{"id": "default" if profile == "mismatch" else profile}]})
        elif path == "/v1/capabilities":
            self.reply({"features": FEATURES})
        elif path == "/api/sessions":
            with LOCK: rows = [{"id": key, "title": value["title"], "source": "api_server"} for key,value in SESSIONS.items()]
            self.reply({"data": rows})
        elif path.startswith("/api/sessions/") and path.endswith("/messages"):
            identifier = path.split("/")[3]
            with LOCK: rows = list(SESSIONS.get(identifier, {}).get("messages", []))
            self.reply({"data": rows})
        elif path.startswith("/v1/runs/"):
            identifier = path.split("/")[3]
            with LOCK: run = RUNS.get(identifier)
            self.reply(run if run else {"error": "not found"}, 200 if run else 404)
        else: self.reply({"error": "not found"}, 404)
    def do_POST(self):
        path, profile = self.route()
        if path is None: return
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        if path == "/api/sessions":
            with LOCK: SESSIONS[body["id"]] = {"title": body["title"], "messages": []}
            self.reply({"session": {"id": body["id"]}}, 201)
        elif path.endswith("/chat/stream"):
            self.stream(path.split("/")[3], body)
        elif path.endswith("/approval"):
            self.reply({"resolved": 1 if body.get("choice") in ["once", "deny"] and body.get("request_id") == "req-fixture" else 0})
        elif path.endswith("/stop"):
            identifier = path.split("/")[3]
            with LOCK:
                RUNS[identifier] = {"run_id": identifier, "status": "cancelled"}
            self.reply({"status": "stopping"})
        elif path.endswith("/steer"):
            self.reply({"accepted": True})
        else: self.reply({"error": "not found"}, 404)
    def stream(self, session, body):
        text = body["input"]
        if isinstance(text, list): text = "\n".join(item["text"] for item in text if item.get("type") == "text")
        identifier = "run-" + session
        with LOCK:
            RUNS[identifier] = {"run_id": identifier, "status": "running"}
            SESSIONS[session]["messages"].append({"id": "user-" + identifier, "role": "user", "content": text})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        def emit(event, payload):
            payload["run_id"] = identifier
            self.wfile.write(f"event: {event}\ndata: {json.dumps(payload)}\n\n".encode())
            self.wfile.flush()
            time.sleep(.02)
        emit("run.started", {"session_id": session})
        emit("assistant.delta", {"delta": "Synthetic "})
        emit("assistant.delta", {"delta": "reply."})
        if text == "interrupt":
            self.close_connection = True
            return
        emit("approval.request", {"request_id": "req-fixture", "description": "Read synthetic notes?", "command": "cat fixture.txt", "choices": ["once", "deny"]})
        with LOCK:
            SESSIONS[session]["messages"].append({"id": "assistant-" + identifier, "role": "assistant", "content": "Synthetic reply."})
            RUNS[identifier] = {"run_id": identifier, "status": "completed"}
        emit("assistant.completed", {"content": "Synthetic reply."})
        emit("run.completed", {"completed": True})
        self.close_connection = True

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--port-file", required=True)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    Path(args.port_file).write_text(str(server.server_port))
    server.serve_forever()
