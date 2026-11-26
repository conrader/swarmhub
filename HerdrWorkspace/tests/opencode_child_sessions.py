"""Real OpenCode subagent, backed by a local streaming model with a controllable child."""
import json
import re
import threading


class ChildSession:
    parent_task = "Launch the sidebar reader"
    child_task = "Read sidebar.txt and report its state."
    child_reply = "The sidebar is expanded."
    parent_reply = "The reader has reported."

    def __init__(self, root):
        self.file = root / "sidebar.txt"
        self.file.write_text("expanded")
        self.started = threading.Event()
        self.release = threading.Event()
        self.returned = threading.Event()
        self.session_id = None

    @staticmethod
    def call(tool, arguments):
        call = {"index": 0, "id": "fixture_" + tool, "type": "function",
                "function": {"name": tool, "arguments": json.dumps(arguments)}}
        return (({"role": "assistant", "tool_calls": [call]}, None), ({}, "tool_calls"))

    def model(self, request):
        messages = request["messages"]
        users = [m["content"] for m in messages if m["role"] == "user"]
        receipts = [str(m["content"]) for m in messages if m["role"] == "tool"]
        if not request.get("tools"):
            text = "Sidebar reader"
        elif self.parent_task in users:
            if not receipts:
                return self.call("subagent", {"agent": "explore", "description": "Read sidebar state",
                                              "prompt": self.child_task})
            for receipt in receipts:
                match = re.search(r"\bses[_a-zA-Z0-9-]{8,}", receipt)
                if match:
                    self.session_id = match.group()
            if any("<background-result" in u and self.child_reply in u for u in users):
                self.returned.set()
            text = self.parent_reply
        else:
            assert any(self.child_task in u for u in users), users
            self.started.set()
            assert self.release.wait(45)
            if not receipts:
                return self.call("read", {"path": str(self.file)})
            assert "expanded" in receipts[-1]
            text = self.child_reply
        return (({"role": "assistant", "content": text}, None), ({}, "stop"))

    def exercise(self, request, core, until):
        agent = request("/api/agents", {"name": "patch-qa", "template": "local-model", "task": self.parent_task},
                        status=201, timeout=45)
        path = f"/api/agents/{agent['address']}/{agent['created_ms']}"
        listing = f"{path}/helpers?core={core}"

        def child(state):
            return next((c for c in request(listing).get("opencode_threads", [])
                         if c["id"] == self.session_id and c["state"] == state), None)

        try:
            assert self.started.wait(20)
            until(lambda: self.session_id)
            live = until(lambda: child("working"))
            assert live["runtime"] == "opencode" and live["name"] == "Read sidebar state" and live["task"] == self.child_task
            assert live["parent"] != live["id"]
            activity = f"{path}/opencode-threads/{self.session_id}"
            request(activity + "?core=another-core", status=404)
            request(activity.replace("opencode-threads", "claude-threads") + f"?core={core}", status=404)
            assert request(activity + f"?core={core}")["state"] == "working"
            self.release.set()
            assert self.returned.wait(20)
            answered = until(lambda: child("answered"))
            assert answered["reply"] == self.child_reply and answered["model"] == "fixture/default"
            history = f"/api/history/{core}/{agent['address']}/{agent['created_ms']}"
            replies = [i["text"] for i in request(history)["items"] if i["kind"] == "reply"]
            assert self.parent_reply in replies and self.child_reply not in replies
        finally:
            self.release.set()
            request(path + "/end", {})
        assert child("answered") == answered
        transcript = request(activity + f"?core={core}")["transcript"]
        assert self.child_task in transcript and self.child_reply in transcript
        assert "read" in transcript and str(self.file) in transcript
        assert self.parent_reply not in transcript
        print("Opened a live OpenCode child and its archived task, file read and independent reply.")
