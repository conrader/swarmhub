"""Real interactive Claude preview against a network-isolated loopback mock."""

import json
import os
from pathlib import Path
import secrets
import shlex
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

FIRST_TASK = "Show the interactive Claude preview fixture"
FINAL_TASK = "Return the final-only fixture"
FIRST = "The rendered first line is ready.\n\n"
LAST = "The withheld line is complete."
FINAL_ONLY = "One line without a terminal newline."


def until(check, seconds=20):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("Timed out waiting for the Claude preview fixture.")


def smoke(hc, workspace, claude):
    assert set(name for _, name in socket.if_nameindex()) <= {"lo"}, "Run in a loopback-only network namespace."
    held = {FIRST_TASK: threading.Event(), FINAL_TASK: threading.Event()}
    started = {task: threading.Event() for task in held}
    models = []

    class Mock(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            if self.path.startswith("/v1/messages/count_tokens"):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'{"input_tokens":42}')
                return
            if not self.path.startswith("/v1/messages"):
                self.send_error(404)
                return
            request = json.loads(body)
            # The last user message, rather than earlier conversation context.
            user = next((row for row in reversed(request["messages"]) if row.get("role") == "user"), {})
            text = json.dumps(user.get("content"))
            task = next((candidate for candidate in held if candidate in text), None)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()

            def send(kind, **fields):
                self.wfile.write(f"event: {kind}\ndata: {json.dumps(dict(type=kind, **fields))}\n\n".encode())
                self.wfile.flush()

            send("message_start", message={
                "id": "msg_" + secrets.token_hex(8), "type": "message", "role": "assistant", "model": request["model"],
                "content": [], "stop_reason": None, "stop_sequence": None,
                "usage": {"input_tokens": 30, "output_tokens": 0},
            })
            send("content_block_start", index=0, content_block={"type": "text", "text": ""})
            first = FIRST if task == FIRST_TASK else FINAL_ONLY if task == FINAL_TASK else "Local mock"
            send("content_block_delta", index=0, delta={"type": "text_delta", "text": first})
            if task:
                models.append((task, request["model"]))
                started[task].set()
                assert held[task].wait(30), "Test did not release the local provider."
            if task == FIRST_TASK:
                send("content_block_delta", index=0, delta={"type": "text_delta", "text": LAST})
            send("content_block_stop", index=0)
            send("message_delta", delta={"stop_reason": "end_turn", "stop_sequence": None}, usage={"output_tokens": 14})
            send("message_stop")

    sandbox = os.environ.get("SWARMHUB_TEST_TMPDIR", "/var/tmp")
    with tempfile.TemporaryDirectory(prefix="swarmhub-claude-", dir=sandbox) as directory:
        root = Path(directory)
        data = root / "workspace"
        project = root / "project"
        profile = root / "claude"
        templates = root / "config/herdr-core/templates"
        for folder in (data, project, profile, templates, root / "run", root / "state"):
            folder.mkdir(mode=0o700, parents=True)
        preferences = {
            "hasCompletedOnboarding": True, "numStartups": 12,
            "projects": {str(project): {"hasTrustDialogAccepted": True, "hasCompletedProjectOnboarding": True}},
        }
        for path in (root / ".claude.json", profile / ".claude.json"):
            path.write_text(json.dumps(preferences))
        (templates / "claude-preview.md").write_text(
            "---\ndescription: Interactive Claude preview fixture\n"
            f"command: SWARMHUB_CLAUDE_BIN={shlex.quote(claude)} "
            f"{shlex.quote(workspace)} run-claude --workspace-preview\n---\n"
        )
        token = secrets.token_hex(32)
        endpoint = str(root / "core.sock")
        with ThreadingHTTPServer(("127.0.0.1", 0), Mock) as model:
            threading.Thread(target=model.serve_forever, daemon=True).start()
            env = {
                "PATH": "/usr/bin:/bin", "HOME": directory, "LANG": "C.UTF-8", "HC_SOCKET": endpoint,
                "HC_SESSION": "swarmhub-claude-preview", "HC_SETTLE_MS": "0", "XDG_RUNTIME_DIR": str(root / "run"),
                "XDG_CONFIG_HOME": str(root / "config"), "XDG_STATE_HOME": str(root / "state"),
                "CLAUDE_CONFIG_DIR": str(profile), "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{model.server_port}",
                "ANTHROPIC_AUTH_TOKEN": "synthetic-preview-fixture", "ANTHROPIC_MODEL": "claude-sonnet-4-5-20250929",
                "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
            }

            def core(*args):
                return subprocess.run([hc, "server", *args], cwd=project, env=env,
                                      check=True, capture_output=True, text=True, timeout=15)

            core("start")
            try:
                with subprocess.Popen([workspace], env={
                    "HC_SOCKET": endpoint, "SWARMHUB_ACCESS_TOKEN": token, "SWARMHUB_DATA_DIR": str(data),
                    "SWARMHUB_PORT": "0", "PATH": "/usr/bin:/bin",
                }, cwd=project, stdout=subprocess.PIPE, text=True) as bridge:
                    try:
                        base = bridge.stdout.readline().strip().split(" · ", 1)[1]

                        def request(path, body=None):
                            headers = {"Authorization": f"Bearer {token}", "Origin": base, "Content-Type": "application/json"}
                            encoded = None if body is None else json.dumps(body).encode()
                            with urllib.request.urlopen(urllib.request.Request(base + path, data=encoded, headers=headers),
                                                        timeout=60) as response:
                                return json.load(response)

                        launched = request("/api/agents", {"name": "native-claude", "template": "claude-preview", "task": FIRST_TASK})
                        address = f"{launched['address']}/{launched['created_ms']}"
                        agent = f"/api/agents/{address}"
                        history = f"/api/history/{launched['core']}/{address}"
                        assert launched["first_message"]["sent"], request(agent + "/output")
                        assert started[FIRST_TASK].wait(15), request(agent + "/output")
                        draft = until(lambda: request(history + "/draft")["draft"])
                        assert draft["text"] == FIRST, draft
                        assert not any(row["kind"] == "reply" for row in request(history)["items"])

                        with sqlite3.connect(data / "workspace.sqlite3") as db:
                            launch_key = db.execute("SELECT launch_key FROM journal WHERE address=? AND launch_key IS NOT NULL",
                                                    (launched["address"],)).fetchone()[0]
                        wrong = {"key": launch_key, "session": str(uuid.uuid4()), "claude_preview": "clear"}
                        with socket.socket(socket.AF_UNIX) as local:
                            local.settimeout(2)
                            local.connect(str(data / "replies.sock"))
                            local.sendall((json.dumps(wrong) + "\n").encode())
                            assert local.recv(1) == b"", "Server accepted a different Claude session."
                        assert request(history + "/draft")["draft"] == draft

                        held[FIRST_TASK].set()
                        def saved(text):
                            return any(row["kind"] == "reply" and row["text"] == text for row in request(history)["items"])
                        until(lambda: saved(FIRST + LAST))
                        until(lambda: request(history + "/draft")["draft"] is None)

                        request(agent + "/messages", {"text": FINAL_TASK})
                        assert started[FINAL_TASK].wait(15), request(agent + "/output")
                        assert request(history + "/draft")["draft"] is None
                        held[FINAL_TASK].set()
                        until(lambda: saved(FINAL_ONLY))
                        assert request(history + "/draft")["draft"] is None
                        assert models == [(FIRST_TASK, "claude-sonnet-4-5-20250929"),
                                          (FINAL_TASK, "claude-sonnet-4-5-20250929")], models
                    finally:
                        bridge.terminate()
            finally:
                for event in held.values():
                    event.set()
                core("stop")
                model.shutdown()


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("Usage: claude_preview.py /path/to/hc /path/to/swarmhub-herdr /path/to/claude")
    smoke(*(str(Path(argument).absolute()) for argument in sys.argv[1:]))
    print("Real interactive Claude preview, saved Stop reply, and final-only behavior passed.")
