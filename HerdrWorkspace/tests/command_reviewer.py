"""Exercise optional command advice and the independent human decision on the real approval socket."""
import json
import os
import socket
import sqlite3
import subprocess
from pathlib import Path


def exercise(root, executable, request, until, chrome, base, token):
    owner = "10000000-0000-4000-8000-000000000001"
    bot = request("/api/agents", {"name": "reviewed", "template": "fixture", "task": "Start", "workspace_id": owner}, status=201)
    settings = "/api/bot-agent-settings/" + owner
    with sqlite3.connect(root / "workspace/workspace.sqlite3") as db:
        key, = db.execute("SELECT launch_key FROM journal WHERE address=? AND created_ms=? AND launch_key IS NOT NULL",
                          (bot["address"], bot["created_ms"])).fetchone()
    executable.write_text("""#!/usr/bin/python3
import json, os, sys
from pathlib import Path
assert sys.argv[sys.argv.index('--tools')+1] == ''
assert '--strict-mcp-config' in sys.argv and '--safe-mode' in sys.argv and '--restricted' in sys.argv
assert 'SWARMHUB_ACCESS_TOKEN' not in os.environ and 'HC_SOCKET' not in os.environ
payload = json.load(sys.stdin)
assert Path.cwd() != Path(payload['working_directory'])
if payload['arguments']['command'] == 'printf hold':
    import time
    (Path(payload['working_directory']) / 'reviewer.pid').write_text(str(os.getpid()))
    time.sleep(40)
assert payload['arguments']['command'] == 'printf audit'
print('Would print audit.')
""")
    pending = lambda: next(iter(request("/api/approvals?pending_only=true")["pending"]), None)

    def review(tool, provider, expected, command="printf audit"):
        frame = json.dumps(dict(key=key, provider=provider, tool=tool, cwd=str(root),
                                input={"command": command})).encode()
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(5)
            peer.connect(str(root / "workspace/approval.sock"))
            peer.sendall(len(frame).to_bytes(4, "little") + frame)
            row = until(pending)
            if command == "printf hold":
                pid_file = root / "reviewer.pid"
                until(pid_file.exists)
                pid = int(pid_file.read_text())
                assert row["reviewer"] == {"model": "haiku", "assessment": None}
                request("/api/approvals/" + str(row["id"]), "deny", status=202)
                assert peer.recv(1) == b"D"

                def reviewer_exited():
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        return True
                    return False

                until(reviewer_exited)
                return
            if expected:
                row = until(lambda: (r if (r := pending()) and r.get("reviewer", {}).get("assessment") else None))
                assert row["reviewer"] == {"model": "haiku", "assessment": expected}, row
            else:
                assert "reviewer" not in row
            if chrome and expected:
                subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, str(root)],
                               check=True, timeout=35)
            else:
                request("/api/approvals/" + str(row["id"]), "deny", status=202)
            assert peer.recv(1) == b"D"
        until(lambda: pending() is None)

    assert request(settings)["command_reviewer"] == "off"
    review("Bash", "codex", None)
    assert request(settings, {"command_reviewer": "haiku"})["command_reviewer"] == "haiku"
    other = "/api/bot-agent-settings/20000000-0000-4000-8000-000000000002"
    assert request(other)["command_reviewer"] == "off"
    review("Bash", "codex", "Would print audit.")
    review("Bash", "codex", None, "printf hold")
    review("Bash", "claude", None)
    review("apply_patch", "codex", None)
    request(settings, {"command_reviewer": "off"})
    review("Bash", "codex", None)
