"""Drive the strict pre-tool hook and the workspace's real approval inbox."""
import json
import os
import sqlite3
import subprocess


def exercise(root, bridge, request, until):
    owner = "10000000-0000-4000-8000-000000000001"
    policy_url = "/api/bot-agent-settings/" + owner
    assert request(policy_url)["review_every_tool"] is False
    request(policy_url, {"auto_mode": True})
    settings = request(policy_url, {"review_every_tool": True})
    assert settings["review_every_tool"] and not settings["auto_mode"]
    request(policy_url, {"auto_mode": True}, status=409)
    request("/api/agents", {"name":"blocked", "template":"fixture", "task":"Start",
                            "workspace_id":owner}, status=422)
    assert request("/api/bot-agent-settings/20000000-0000-4000-8000-000000000002")["review_every_tool"] is False
    templates = request("/api/workspace")["templates"]
    assert next(t for t in templates if t["name"] == "standard-claude")["supports_tool_review"]
    assert not next(t for t in templates if t["name"] == "fixture")["supports_tool_review"]
    protected = request("/api/agents", {"name":"reviewed", "template":"standard-claude", "task":"Start",
                                       "workspace_id":owner}, status=201)
    journal = root / "workspace/workspace.sqlite3"
    with sqlite3.connect(journal) as db:
        protected_key, active = db.execute("SELECT launch_key,launch_tool_review FROM journal WHERE address=? AND created_ms=?",
                                           (protected["address"], protected["created_ms"])).fetchone()
        assert active
    observed = root / "review-launches"
    until(lambda: observed.exists() and protected_key in observed.read_text().splitlines())
    env = dict(os.environ, SWARMHUB_LAUNCH_KEY=protected_key, SWARMHUB_JOURNAL=str(journal),
               SWARMHUB_APPROVAL_SOCKET=str(journal.with_name("approval.sock")))

    def check(tool, args, choice, expected):
        with subprocess.Popen([bridge, "review-claude-tool"], env=env, text=True, stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE) as hook:
            hook.stdin.write(json.dumps(dict(hook_event_name="PreToolUse", cwd=str(root), tool_name=tool, tool_input=args)))
            hook.stdin.close()
            try:
                row = until(lambda: next(iter(request("/api/approvals?pending_only=true")["pending"]), None))
                assert hook.poll() is None and row["tool"] == tool and json.loads(row["arguments"]) == args
                assert not any(row[k] for k in ("can_remember_read", "can_remember_command", "can_remember_command_hour"))
                url = "/api/approvals/" + str(row["id"])
                request(url, "remember_command", status=409)
                request(url, choice, status=202)
                assert hook.wait(timeout=5) == 0
                answer = json.load(hook.stdout)["hookSpecificOutput"]
                assert answer["hookEventName"] == "PreToolUse" and answer["permissionDecision"] == expected
            finally:
                if hook.poll() is None:
                    hook.kill()
        until(lambda: not request("/api/approvals?pending_only=true")["pending"])

    def spawn_helper(tier, success):
        request("/api/helper-policy", {"max_running": 2, "stop_after_seconds": 60, "difficulties": {"easy": tier}})
        result = subprocess.run([bridge, "helper", "start", "--name", "invoice-reader", "--difficulty", "easy", "Check invoice"],
                                env=env, capture_output=True, text=True, timeout=18)
        assert (result.returncode == 0) == success, (result.stdout, result.stderr)
        if success:
            until(lambda: len(set(observed.read_text().splitlines())) == 2)
        else:
            assert "requires each helper tool call" in result.stderr, result.stderr

    for choice, expected in [("approve", "allow"), ("deny", "deny")]:
        check("Read", {"file_path": "invoice.txt"}, choice, expected)
    check("mcp__invoices__prepare", {"invoice": "sample"}, "deny", "deny")
    check("Bash", {"command": "pwd"}, "terminal", "ask")
    broken = dict(env, SWARMHUB_APPROVAL_SOCKET=str(root / "missing"))
    for event in ("PreToolUse", "PostToolUse"):
        result = subprocess.run([bridge, "review-claude-tool"], env=broken, check=True, text=True,
                                input=json.dumps(dict(hook_event_name=event, cwd="/tmp", tool_name="Read", tool_input={})),
                                capture_output=True)
        assert json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"] == "deny"

    spawn_helper({"template":"standard-codex","model":"gpt-fixture"}, False)
    spawn_helper({"template":"standard-claude","model":"sonnet"}, True)
