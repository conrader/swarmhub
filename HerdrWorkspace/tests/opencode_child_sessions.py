"""Real OpenCode subagent, backed by a local streaming model with a controllable child."""
import json
import re
import threading


class ChildSession:
    parent_task = "Launch the sidebar reader"
    child_task = "Read sidebar.txt and report its state."
    child_reply = "The sidebar is expanded."
    progress = "I found the sidebar flag and am checking its source."
    parent_reply = "The reader has reported."

    def __init__(self, root):
        self.file = root / "sidebar.txt"
        self.file.write_text("expanded")
        self.started = threading.Event()
        self.release = threading.Event()
        self.returned = threading.Event()
        self.finish_answer = threading.Event()
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
                return (({"role": "assistant", "content": self.progress}, None), *self.call("read", {"path": str(self.file)}))
            assert "expanded" in receipts[-1]
            assert self.finish_answer.wait(30)
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
            def progress_with_step():
                snapshot = request(activity + f"?core={core}")
                return snapshot if snapshot["details"]["steps"] and self.progress in snapshot["transcript"] else None
            progress = until(progress_with_step)
            assert progress["state"] == "working" and progress["details"]["reply"] == self.progress
            assert not child("working")["reply"]
            self.finish_answer.set()
            assert self.returned.wait(20)
            answered = until(lambda: child("answered"))
            assert answered["reply"] == self.child_reply and answered["model"] == "fixture/default"
            history = f"/api/history/{core}/{agent['address']}/{agent['created_ms']}"
            replies = [i["text"] for i in request(history)["items"] if i["kind"] == "reply"]
            assert self.parent_reply in replies and self.child_reply not in replies
        finally:
            self.finish_answer.set()
            self.release.set()
            request(path + "/end", {})
        assert child("answered") == answered
        saved = request(activity + f"?core={core}")
        assert "details" not in answered
        assert saved["details"]["reply"] == self.child_reply and saved["details"]["task"] == self.child_task
        assert any(str(self.file) in step["text"] for step in saved["details"]["steps"])
        transcript = saved["transcript"]
        assert self.child_task in transcript and self.child_reply in transcript
        assert "read" in transcript and str(self.file) in transcript
        assert self.parent_reply not in transcript
        print("Opened a live OpenCode child and its archived task, file read and independent reply.")


class InterruptChild(ChildSession):
    follow_up = "Can the parent still answer?"
    follow_up_reply = "The parent is available."

    resume_parent = "Send the reader a second assignment"
    resume_task = "Report the saved sidebar state."

    def __init__(self, root):
        super().__init__(root)
        self.finish_resumed = threading.Event()

    def model(self, request):
        messages = request["messages"]
        users = [m["content"] for m in messages if m["role"] == "user"]
        if self.resume_parent in users and request.get("tools"):
            latest = next(i for i, m in enumerate(messages) if m["content"] == self.resume_parent)
            if not any(m["role"] == "tool" for m in messages[latest + 1:]):
                return self.call("subagent", {"agent": "explore", "description": "Read sidebar again",
                                               "prompt": self.resume_task, "sessionID": self.session_id})
            return (({"role": "assistant", "content": "Sent the second assignment."}, None), ({}, "stop"))
        if any(self.resume_task in str(u) for u in users) and request.get("tools"):
            assert self.finish_resumed.wait(30)
            return (({"role": "assistant", "content": self.child_reply}, None), ({}, "stop"))
        if self.follow_up in users:
            return (({"role": "assistant", "content": self.follow_up_reply}, None), ({}, "stop"))
        if self.parent_task not in users and request.get("tools") and any(self.child_task in str(u) for u in users):
            self.started.set()
            assert self.release.wait(45)
            return None  # The provider cancelled this streaming request when its child was interrupted.
        return super().model(request)

    def stop(self, request, route, turn):
        assert request(route, {"turn": turn}) == {"interrupted_turn": turn}

    def exercise(self, request, core, until):
        agent = request("/api/agents", {"name": "patch-qa", "template": "local-model", "task": self.parent_task},
                        status=201, timeout=45)
        session = f"{agent['address']}/{agent['created_ms']}"
        path = "/api/agents/" + session
        try:
            assert self.started.wait(20)
            until(lambda: self.session_id)
            listing = path + "/helpers?core=" + core
            child = until(lambda: next((c for c in request(listing).get("opencode_threads", [])
                                        if c["id"] == self.session_id and c.get("active_turn")), None))
            route = f"{path}/opencode-threads/{self.session_id}?core={core}"
            turn = request(route)["active_turn"]
            assert turn == child["active_turn"]
            request(route, {"turn": "stale"}, status=409)
            request(route.replace(self.session_id, child["parent"]), {"turn": turn}, status=404)
            request(route.replace("?core=" + core, "?core=another"), {"turn": turn}, status=404)
            self.stop(request, route, turn)
            until(lambda: request(route)["state"] == "stopped")
            request(route, {"turn": turn}, status=409)
            self.release.set()
            request(path + "/messages", {"text": self.follow_up})
            until(lambda: any(m["kind"] == "reply" and m["text"] == self.follow_up_reply
                              for m in request("/api/history/" + core + "/" + session)["items"]), seconds=20)
            request(path + "/messages", {"text": self.resume_parent})
            newer = until(lambda: request(route).get("active_turn"), seconds=20)
            assert newer != turn
            request(route, {"turn": turn}, status=409)
            assert request(route)["active_turn"] == newer
            self.finish_resumed.set()
            until(lambda: request(route)["state"] == "answered")
        finally:
            self.release.set()
            self.finish_resumed.set()
            request(path + "/end", {})
        assert self.child_reply in request(route)["transcript"] and request(route)["active_turn"] is None
        print("Stopped the selected OpenCode child, read the parent's next answer and refused the old stop on the resumed child.")
