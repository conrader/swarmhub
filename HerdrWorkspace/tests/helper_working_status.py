"""Exercise the sidebar and the parent's wait command while two helper tools overlap."""
import json
import sqlite3
import subprocess


def exercise(root, bridge, core_env, request, until):
    (root / "workspace/runtime-catalog.json").write_text(json.dumps({
        "fixture": {"harness": "Fixture", "model_transport": "environment"}
    }))
    choice = {"template": "fixture", "model": "fixture"}
    request("/api/helper-policy", {"max_running": 2, "stop_after_seconds": 60, "difficulties": {"easy": choice}})
    parent = request("/api/agents", {"name": "status-parent", "template": "fixture", "task": "Initialize"}, status=201)
    journal = root / "workspace/workspace.sqlite3"

    def session(agent):
        with sqlite3.connect(journal) as db:
            key, = db.execute("SELECT launch_key FROM journal WHERE address=? AND created_ms=? AND launch_key IS NOT NULL",
                              (agent["address"], agent["created_ms"])).fetchone()
        return {**core_env, "SWARMHUB_JOURNAL": str(journal), "SWARMHUB_LAUNCH_KEY": key}

    owner = session(parent)

    def command(*args):
        return subprocess.check_output([bridge, "helper", *args], env=owner, text=True, timeout=30)

    command("start", "--name", "reader", "--difficulty", "easy", "Read the task.")
    route = f"/api/agents/{parent['address']}/{parent['created_ms']}/helpers"

    def child():
        return next((h for h in request(route)["helpers"] if h["name"] == "reader"), None)

    helper = until(child)
    actor = session(helper)
    until(lambda: (child().get("status") or {}).get("state") == "done")
    with sqlite3.connect(journal) as db:
        db.execute("UPDATE journal SET at_ms=at_ms-30000 WHERE kind='task' AND address=? AND created_ms=?",
                   (helper["address"], helper["created_ms"]))
    assert child()["open_task"] is False

    def hook(name, phase):
        fields = dict(hook_event_name=phase, tool_name="Read", tool_use_id=name, tool_input={"file_path": name + ".swift"})
        subprocess.run([bridge, "tool-activity"], input=json.dumps(fields), env=actor, text=True, capture_output=True, check=True)

    hook("slow", "PreToolUse")
    hook("quick", "PreToolUse")
    until(lambda: child().get("sidebar_summary") == "Read · quick.swift")
    hook("quick", "PostToolUse")
    def slow_still_running():
        state = child()
        if state and state.get("sidebar_summary") == "Read · slow.swift":
            return state
    active = until(slow_still_running)
    assert active["open_task"] and active["status"]["state"] == "working"
    assert "Still working" in command("wait", "reader", "--seconds", "1")
    hook("slow", "PostToolUse")
    until(lambda: child()["open_task"] is False)
    assert "Still working" not in command("wait", "reader", "--seconds", "1")
    hook("orphan", "PreToolUse")
    until(lambda: child()["open_task"])
    subprocess.run([bridge, "capture-reply"], input="Both reads are complete.", env=actor, text=True, check=True)
    until(lambda: child()["answered"])
    answered = child()
    assert not answered.get("sidebar_summary") and not answered["open_task"]
    assert "Both reads are complete." in command("wait", "reader", "--seconds", "1")
    print("Helper roster and parent wait followed the outstanding tool, then settled after completion.")
