"""Exercise a real Claude Agent tool in a loopback-only workspace. --require-visible checks the sidebar contract."""
import argparse
import json
import secrets
import shlex
import sqlite3
import sys
import threading
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import quote

from claude_preview import smoke, until

TASK = "Delegate the sidebar audit to a helper."
CHILD = "CLAUDE-CHILD-RESULT"
PARENT = "CLAUDE-PARENT-RESULT"
RESUME = "Resume the same sidebar helper."
NEXT_TASK = "Check the nested session too."
NEXT_REPLY = "CLAUDE-RESUMED-RESULT"


class ChildScenario:
    def __init__(self, require_visible, stop=False):
        self.stop = stop
        self.require_visible = require_visible
        self.started = threading.Event()
        self.finish = threading.Event()
        self.resumed = threading.Event()
        self.finish_resume = threading.Event()

    def prepare(self, profile):
        # Observe Claude's own lifecycle independently of the workspace's reporting.
        self.sample = profile.parent / "project" / "sidebar.txt"
        self.sample.write_text("Child workspace fixture")
        self.receipts = profile / "qa-hook-events.jsonl"
        hook = profile / "observe.py"
        hook.write_text(
            "import json,sys\n"
            "event=json.load(sys.stdin)\n"
            "with open(sys.argv[1], 'a') as file: file.write(json.dumps(event)+'\\n')\n"
        )
        command = shlex.join([sys.executable, str(hook), str(self.receipts)])
        hooks = {event: [{"hooks": [{"type": "command", "command": command}]}]
                 for event in ("SubagentStart", "SubagentStop", "PostToolUse")}
        (profile / "settings.json").write_text(json.dumps({"hooks": hooks, "permissions": {"allow": ["Agent(general-purpose)", "SendMessage", "TaskStop", "Read", "Bash(cat:*)"]}}))

    @property
    def handler(self):
        scenario = self

        class Model(BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path.startswith("/v1/messages/count_tokens"):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"input_tokens":32}')
                    return
                if not self.path.startswith("/v1/messages"):
                    self.send_error(404)
                    return
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()

                def send(kind, **params):
                    self.wfile.write(f"event: {kind}\ndata: {json.dumps(dict(type=kind, **params))}\n\n".encode())
                    self.wfile.flush()

                send("message_start", message={
                    "id": "msg_" + secrets.token_hex(8), "type": "message", "role": "assistant",
                    "model": request["model"], "content": [], "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 30, "output_tokens": 0},
                })
                last = next(row for row in reversed(request["messages"]) if row["role"] == "user")
                text = json.dumps(last["content"])
                spawn = TASK in text and any(t.get("name") == "Agent" for t in request.get("tools", []))
                last_index = 0
                stop_request = "[SwarmHub stop request]" in text and "tool_result" not in text
                refused = "toolu_wrong_stop" in text and "tool_result" in text
                if scenario.stop and (stop_request or refused):
                    if refused:
                        assert "only to the selected helper run" in text
                    tool_id = "toolu_wrong_stop" if stop_request else "toolu_selected_stop"
                    target = scenario.sibling if stop_request else scenario.child
                    send("content_block_start", index=0, content_block={
                        "type": "tool_use", "id": tool_id, "name": "TaskStop", "input": {},
                    })
                    send("content_block_delta", index=0, delta={"type": "input_json_delta",
                         "partial_json": json.dumps({"task_id": target})})
                    spawn = True
                elif RESUME in text and "tool_result" not in text:
                    send("content_block_start", index=0, content_block={
                        "type": "tool_use", "id": "toolu_resume_sidebar", "name": "SendMessage", "input": {},
                    })
                    send("content_block_delta", index=0, delta={"type": "input_json_delta",
                         "partial_json": json.dumps({"to": scenario.child, "message": NEXT_TASK})})
                    spawn = True
                elif NEXT_TASK in text and "tool_result" not in text:
                    scenario.resumed.set()
                    assert scenario.finish_resume.wait(30), "Timed out observing the resumed helper"
                    send("content_block_start", index=0, content_block={"type": "text", "text": ""})
                    send("content_block_delta", index=0, delta={"type": "text_delta", "text": NEXT_REPLY})
                elif spawn:
                    titles = ["Read sidebar state", "Inspect the header"] if scenario.stop else ["Read sidebar state"]
                    for index, title in enumerate(titles):
                        if index:
                            send("content_block_stop", index=index - 1)
                        send("content_block_start", index=index, content_block={
                            "type": "tool_use", "id": f"toolu_sidebar_{index}", "name": "Agent", "input": {},
                        })
                        payload = {"description": title, "prompt": f"Reply with {CHILD}.", "subagent_type": "general-purpose"}
                        send("content_block_delta", index=index, delta={"type": "input_json_delta", "partial_json": json.dumps(payload)})
                        last_index = index
                else:
                    child_messages = [message for message in request["messages"] if message.get("role") == "user"]
                    is_child = any(CHILD in json.dumps(m["content"]) and "tool_result" not in json.dumps(m["content"])
                                   for m in child_messages) and not any(TASK in json.dumps(m["content"]) for m in child_messages)
                    if is_child and "tool_result" not in text and any(t.get("name") == "Read" for t in request.get("tools", [])):
                        send("content_block_start", index=0, content_block={
                            "type":"tool_use", "id":"toolu_child_read", "name":"Read", "input":{},
                        })
                        send("content_block_delta", index=0, delta={"type":"input_json_delta",
                             "partial_json":json.dumps({"file_path":str(scenario.sample)})})
                        spawn = True
                    elif is_child and not any("toolu_child_shell" in json.dumps(m) for m in child_messages):
                        send("content_block_start", index=0, content_block={
                            "type":"tool_use", "id":"toolu_child_shell", "name":"Bash", "input":{},
                        })
                        send("content_block_delta", index=0, delta={"type":"input_json_delta",
                             "partial_json":json.dumps({"command": "cat " + shlex.quote(str(scenario.sample))})})
                        spawn = True
                    else:
                        if is_child:
                            scenario.started.set()
                            assert scenario.finish.wait(30), "Timed out waiting for the sidebar observation"
                        send("content_block_start", index=0, content_block={"type": "text", "text": ""})
                        send("content_block_delta", index=0, delta={"type": "text_delta", "text": CHILD if is_child else PARENT})
                send("content_block_stop", index=last_index)
                send("message_delta", delta={"stop_reason": "tool_use" if spawn else "end_turn", "stop_sequence": None},
                     usage={"output_tokens": 12})
                send("message_stop")

        return Model

    def events(self):
        return [json.loads(line) for line in self.receipts.read_text().splitlines()] if self.receipts.exists() else []

    def exercise_stop(self, request, bot):
        base = f"/api/agents/{bot['address']}/{bot['created_ms']}"
        def children():
            return request(base + "/helpers").get("claude_threads", [])
        try:
            until(lambda: self.started.is_set() and len(children()) == 2)
            target, sibling = sorted(children(), key=lambda c: c["name"])
            assert target["name"] == "Inspect the header" and sibling["name"] == "Read sidebar state"
            self.child, self.sibling = target["id"], sibling["id"]
            route = base + "/claude-threads/" + self.child + "?core=" + quote(bot["core"], safe="")
            turn = request(route)["active_turn"]
            assert turn and request(route, {"turn": turn})["requested_turn"] == turn
            until(lambda: request(route)["state"] == "stopped")
            receipt = next(e["tool_response"] for e in self.events()
                           if e.get("tool_name") == "TaskStop" and e["hook_event_name"] == "PostToolUse")
            assert receipt["task_type"] == "local_agent" and receipt["task_id"] == self.child
            assert next(c for c in children() if c["id"] == self.sibling)["state"] == "working"
            try:
                request(route, {"turn": turn})
            except HTTPError as error:
                assert error.code == 409
            else:
                raise AssertionError("A completed run accepted another stop request")
        finally:
            self.finish.set()
        until(lambda: any(c["id"] == self.sibling and c["state"] == "answered" for c in children()))
        print("Claude stopped the selected helper and its sibling answered.")

    def exercise(self, request, profile, data):
        bot = request("/api/agents", {"name": "audit-claude", "template": "claude-preview", "task": TASK})
        if self.stop:
            return self.exercise_stop(request, bot)
        route = f"/api/agents/{bot['address']}/{bot['created_ms']}/helpers"
        try:
            assert self.started.wait(30), "Claude never invoked the child model"
            receipt = until(lambda: next((e["tool_response"] for e in self.events()
                                          if e["hook_event_name"] == "PostToolUse" and e.get("tool_name") == "Agent"
                                          and e.get("tool_response", {}).get("agentId")), None))
            child = receipt["agentId"]
            assert receipt["description"] == "Read sidebar state"
            # Give the workspace several normal observation cycles while the child is still working.
            def contains_child(value):
                if isinstance(value, dict):
                    return any(contains_child(item) for item in value.values())
                if isinstance(value, list):
                    return any(contains_child(item) for item in value)
                return value == child

            def listed():
                return contains_child(request(route))
            try:
                until(listed, seconds=4)
                live = True
            except AssertionError:
                live = False
            if self.require_visible:
                until(lambda: any(row["id"] == child and row["name"] == receipt["description"]
                                  and row["task"] == receipt["prompt"] and row["state"] == "working"
                                  for row in request(route).get("claude_threads", [])))
                base = route.removesuffix("/helpers")
                query = "?core=" + quote(bot["core"], safe="")
                activity = base + "/claude-threads/" + child
                running = request(activity + query)
                assert running["details"]["terminal"]["output"].strip() == "Child workspace fixture", running
                assert running["details"]["terminal"]["command"] == "cat " + shlex.quote(str(self.sample))
                assert "Read" in running["transcript"] and "sidebar.txt" in running["transcript"], running
                for url in (activity + "?core=unrelated", base + "/codex-threads/" + child + query):
                    try:
                        request(url)
                    except HTTPError as error:
                        assert error.code == 404
                    else:
                        raise AssertionError("A different Core or runtime returned this child")
        finally:
            self.finish.set()

        stopped = until(lambda: next((e for e in self.events() if e["hook_event_name"] == "SubagentStop"
                                      and e.get("agent_id") == child), None))
        assert stopped["last_assistant_message"] == CHILD
        assert any(e["hook_event_name"] == "SubagentStart" and e["agent_id"] == child
                   and e["session_id"] == stopped["session_id"] for e in self.events())
        transcript = Path(stopped["agent_transcript_path"]).resolve()
        assert transcript.is_relative_to(profile.resolve())
        items = [json.loads(line) for line in transcript.read_text().splitlines()]
        assert any(m.get("text") == CHILD for i in items if i.get("message", {}).get("role") == "assistant"
                   for m in i["message"]["content"] if isinstance(m, dict))

        def parent_reply():
            with sqlite3.connect(data / "workspace.sqlite3") as db:
                replies = db.execute("SELECT text FROM journal WHERE kind='reply' AND address=? AND created_ms=?",
                                     (bot["address"], bot["created_ms"])).fetchall()
                assert all(text != CHILD for (text,) in replies), "The child reply entered the parent chat"
                return any(text == PARENT for (text,) in replies)

        until(parent_reply)
        try:
            until(listed, seconds=4)
            saved = True
        except AssertionError:
            saved = False
        print(json.dumps({"cli_child_completed": True, "parent_reply_saved": True,
                          "child_listed_while_working": live, "child_listed_after_completion": saved}), flush=True)
        if self.require_visible:
            assert live and saved, "The owning bot must list its live and completed Claude child"
            final = until(lambda: next((row for row in request(route).get("claude_threads", [])
                                        if row["id"] == child and row["state"] == "answered"), None))
            assert final["reply"] == CHILD and final["completed_ms"] >= final["created_ms"]
            self.child = child
            request(base + "/messages", {"text": RESUME})
            try:
                assert self.resumed.wait(20), "The parent did not resume its child"
                def working_again():
                    rows = [row for row in request(route)["claude_threads"] if row["id"] == child]
                    return len(rows) == 1 and rows[0]["state"] == "working" and rows[0]["task"] == NEXT_TASK
                until(working_again, seconds=5)
                resumed = request(activity + query)
                assert resumed["details"]["reply"] == "" and resumed["details"]["terminal"] is None
                assert CHILD in resumed["transcript"] and "Child workspace fixture" in resumed["transcript"]
            finally:
                self.finish_resume.set()
            until(lambda: request(activity + query)["details"]["reply"] == NEXT_REPLY)
            request(base + "/end", {})
            archived = request(activity + query)
            assert archived["state"] == "answered" and archived["details"]["task"] == NEXT_TASK
            assert archived["details"]["reply"] == NEXT_REPLY and PARENT not in archived["transcript"]
            assert all(text in archived["transcript"] for text in (CHILD, NEXT_REPLY, "Read", "Child workspace fixture"))
            until(lambda: any(p["session"] == {"address": bot["address"], "created_ms": bot["created_ms"]}
                              for p in request("/api/workspace?codejobs=true").get("archived_helper_parents", [])))
            print("Resumed the same Claude helper, observed its new assignment while working and read both runs after closing the parent.")


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    for name in ("core", "workspace", "claude"):
        args.add_argument(name, type=Path)
    args.add_argument("--require-visible", action="store_true")
    args.add_argument("--stop", action="store_true", help="Stop one of two live helpers and verify the sibling finishes")
    options = args.parse_args()
    smoke(*[str(path.absolute()) for path in (options.core, options.workspace, options.claude)],
          scenario=ChildScenario(options.require_visible, options.stop))
