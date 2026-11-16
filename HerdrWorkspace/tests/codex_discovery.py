"""Verify the installed Codex CLI discovers the wrapper's hooks without a model call."""

import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time


def verify(bridge, codex):
    with tempfile.TemporaryDirectory(prefix="swarmhub-codex-", dir="/var/tmp") as directory:
        root = Path(directory)
        home = root / "codex"
        project = root / "project"
        home.mkdir()
        project.mkdir()
        (home / "hooks.json").write_text(
            '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/bin/true"}]}]}}'
        )
        environment = {
            "PATH": os.environ["PATH"], "HOME": str(root), "CODEX_HOME": str(home),
            "SWARMHUB_CODEX_BIN": codex, "SWARMHUB_JOURNAL": str(root / "unused.sqlite3"),
            "SWARMHUB_LAUNCH_KEY": "0" * 32,
        }
        with (root / "startup.log").open("wb") as log:
            process = subprocess.Popen(
                [bridge, "run-codex", "--workspace-approvals", "app-server", "--listen", "stdio://"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                cwd=project, env=environment, bufsize=0,
            )
            buffered = b""

            def send(payload):
                process.stdin.write((json.dumps(payload) + "\n").encode())

            def response(message_id):
                nonlocal buffered
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    while b"\n" in buffered:
                        line, buffered = buffered.split(b"\n", 1)
                        message = json.loads(line)
                        if message.get("id") == message_id:
                            assert "result" in message, message
                            return message["result"]
                    if not select.select([process.stdout], [], [], 0.4)[0]:
                        continue
                    data = os.read(process.stdout.fileno(), 65_536)
                    if not data:
                        break
                    buffered += data
                raise AssertionError(f"No reply for request {message_id}; status {process.poll()}")

            try:
                send({"id": 1, "method": "initialize", "params": {
                    "clientInfo": {"name": "swarmhub-discovery", "version": "1.0"},
                    "capabilities": {"experimentalApi": True},
                }})
                response(1)
                send({"method": "initialized"})
                send({"id": 2, "method": "hooks/list", "params": {"cwds": [str(project)]}})
                result = response(2)
                hooks = result["data"][0]["hooks"]
                assert result["data"][0]["errors"] == []
                assert any(item["command"] == "/bin/true" and item["source"] == "user" for item in hooks)
                for command, event in (("capture-codex-reply", "stop"),
                                       ("review-codex-permission", "permissionRequest")):
                    matching = next(item for item in hooks if item["command"].endswith(" " + command))
                    assert matching["eventName"] == event and matching["source"] == "sessionFlags"
                    assert matching["trustStatus"] == "untrusted"
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=8)
                process.stdin.close()
                process.stdout.close()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("Usage: codex_discovery.py /path/to/swarmhub-herdr /path/to/codex")
    verify(*(str(Path(argument).absolute()) for argument in sys.argv[1:]))
    print("Installed Codex discovered both workspace hooks and preserved the existing user hook.")
