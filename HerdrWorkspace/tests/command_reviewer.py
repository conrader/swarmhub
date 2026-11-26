"""Exercise optional command advice and the independent human decision on the real approval socket."""
import json
import os
import socket
import sqlite3
import subprocess
from pathlib import Path


def exercise(root, executable, request, until, chrome, base, token, restart):
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

    # The workspace's persistent rule is bound to an exact request, owner, provider and working directory.
    def browser(focus):
        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, str(root)],
                       env={**os.environ, "SWARMHUB_TEST_FOCUS": focus}, check=True, timeout=35)

    def command_reply(cwd, input, choice=None, provider="codex", launch=key, eligible=None):
        frame = json.dumps(dict(key=launch, provider=provider, tool="Bash", cwd=str(cwd), input=input)).encode()
        with socket.socket(socket.AF_UNIX) as peer:
            peer.settimeout(8)
            peer.connect(str(root / "workspace/approval.sock"))
            peer.sendall(len(frame).to_bytes(4, "little") + frame)
            if choice is not None:
                row = until(pending)
                if eligible is not None:
                    assert row["can_remember_command"] == eligible
                if choice == "remember_command":
                    assert row["can_remember_command"]
                if chrome and choice == "remember_command":
                    browser("save-project-command")
                else:
                    request(f"/api/approvals/{row['id']}", choice, status=202)
            assert peer.recv(1) == (b"D" if choice == "deny" else b"A")
        until(lambda: pending() is None)

    project = root / "shop"
    project.mkdir()
    neighbor = root / "other-project"
    neighbor.mkdir()
    args = {"command": "swift test --filter ImporterTests"}
    command_reply(project, args, "remember_command")
    rule = until(lambda: next(iter(request("/api/project-command-rules")), None))
    assert rule["cwd"] == str(project.resolve()) and rule["command"] == args["command"]
    command_reply(project, args)
    restart()
    command_reply(project, args)
    command_reply(neighbor, args, "deny")
    command_reply(project, {"command": args["command"] + "Extra"}, "deny")
    command_reply(project, {**args, "workdir": str(neighbor)}, "deny", eligible=False)
    command_reply(project, {**args, "run_in_background": True}, "deny", eligible=False)
    command_reply(project, args, "deny", provider="claude")
    another = request("/api/agents", {"name": "second", "template": "fixture", "task": "Start",
                                      "workspace_id": "20000000-0000-4000-8000-000000000002"}, status=201)
    with sqlite3.connect(root / "workspace/workspace.sqlite3") as db:
        other_key, = db.execute("SELECT launch_key FROM journal WHERE address=? AND created_ms=? AND launch_key IS NOT NULL",
                                (another["address"], another["created_ms"])).fetchone()
    command_reply(project, args, "deny", launch=other_key)
    # A new session of the same bot, with a different runtime name, still owns its project rule.
    reopened = request("/api/agents", {"name": "reopened", "template": "fixture", "task": "Start",
                                       "workspace_id": owner}, status=201)
    with sqlite3.connect(root / "workspace/workspace.sqlite3") as db:
        reopened_key, = db.execute("SELECT launch_key FROM journal WHERE address=? AND created_ms=? AND launch_key IS NOT NULL",
                                   (reopened["address"], reopened["created_ms"])).fetchone()
    command_reply(project, args, launch=reopened_key)
    journal = root / "workspace/workspace.sqlite3"
    with sqlite3.connect(journal) as db:
        db.execute("UPDATE journal SET parent_bot_id=NULL WHERE launch_key=?", (reopened_key,))
        db.execute("INSERT INTO bots(id,name,agent_name,created_ms,updated_ms) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET agent_name=excluded.agent_name,noted_launch=NULL",
                   (owner,"Saved project bot","reopened",1,1))
    command_reply(project, args, "deny", launch=reopened_key, eligible=False)
    with sqlite3.connect(journal) as db:
        db.execute("UPDATE bots SET noted_launch=? WHERE id=?", (reopened_key, owner))
    command_reply(project, args, launch=reopened_key)
    if chrome:
        browser("revoke-project-command")
    else:
        assert request("/api/project-command-rules/" + str(rule["id"]) + "/revoke", {})["revoked"]
    command_reply(project, args, "deny")
    assert request("/api/project-command-rules") == []
    print("Exact command grant survived restart, stayed scoped to its folder, request, bot and provider, and was revoked.")
