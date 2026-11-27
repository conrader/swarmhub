#!/usr/bin/env python3
"""Drive the native SwarmHub QA window on a logged-in Mac with PyObjC and Accessibility access."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from threading import Event, Thread, Timer
import time
import uuid

import ApplicationServices as ax


def attribute(element, key):
    error, value = ax.AXUIElementCopyAttributeValue(element, key, None)
    return value if error == 0 else None


def descendants(element):
    # SwiftUI can expose the same accessibility element under more than one parent.
    pending = [element]
    seen = set()
    while pending:
        node = pending.pop()
        if node in seen:
            continue
        seen.add(node)
        yield node
        pending.extend(reversed(attribute(node, "AXChildren") or ()))


def label(element):
    return attribute(element, "AXTitle") or attribute(element, "AXDescription") or ""


def buttons(window):
    return [e for e in descendants(window) if attribute(e, "AXRole") == "AXButton"]


def press(window, title, sidebar=False):
    for button in buttons(window):
        name = label(button)
        if sidebar:
            name = name.removeprefix("Needs attention, ")
        if (name.startswith(title + ",") if sidebar else name == title):
            if ax.AXUIElementPerformAction(button, "AXPress") == 0:
                return
    raise RuntimeError(f"Button unavailable: {title}")


def press_link(window, title):
    def activate():
        for item in descendants(window):
            if attribute(item, "AXRole") == "AXLink" and label(item) == title:
                return ax.AXUIElementPerformAction(item, "AXPress") == 0
        return False
    wait_for(title, activate)


def open_detail_section(window, name):
    def button(title):
        return next((b for b in buttons(window) if label(b) == title), None)
    if not button("Overview"):
        press(window, "Details")
        wait_for("Details sections", lambda: button("Overview"))
    if button(name):
        press(window, name)
        return
    press(window, "More Details sections")
    application = ax.AXUIElementCreateApplication(ax.AXUIElementGetPid(window, None)[1])
    def item():
        return next((b for w in attribute(application, "AXWindows") or [] for b in buttons(w)
                     if label(b) == name), None)
    wait_for("section " + name, item)
    assert ax.AXUIElementPerformAction(item(), "AXPress") == 0
    wait_for("selected section " + name, lambda: attribute(button("More Details sections"), "AXValue") == name)


def enter_draft(field, text):
    if field is None or ax.AXUIElementSetAttributeValue(field, "AXFocused", True) != 0:
        raise RuntimeError("Could not focus the composer")
    if ax.AXUIElementSetAttributeValue(field, "AXSelectedText", text) != 0:
        raise RuntimeError("Could not enter the draft")
    wait_for("draft in the composer", lambda: attribute(field, "AXValue") == text)


def bounds(element):
    position = attribute(element, "AXPosition")
    size = attribute(element, "AXSize")
    if position is None or size is None:
        return None
    point = ax.AXValueGetValue(position, ax.kAXValueCGPointType, None)[1]
    extent = ax.AXValueGetValue(size, ax.kAXValueCGSizeType, None)[1]
    return point.y, point.y + extent.height


def visible_messages(window):
    # Only count a marker if its rendered text intersects its scroll area's viewport.
    # SwiftUI also exposes offscreen rows through Accessibility.
    for area in descendants(window):
        if attribute(area, "AXRole") != "AXScrollArea":
            continue
        visible = bounds(area)
        if not visible:
            continue
        result = set()
        for row in descendants(area):
            if attribute(row, "AXRole") not in ("AXTextArea", "AXStaticText"):
                continue
            marker = re.match(r"QA message (\d+)\b", str(attribute(row, "AXValue") or ""))
            if marker:
                frame = bounds(row)
                if frame and frame[0] < visible[1] and frame[1] > visible[0]:
                    result.add(int(marker[1]))
        if result:
            return result
    return set()


def wait_for(description, condition, seconds=5):
    start = time.monotonic()
    while time.monotonic() - start < seconds:
        if condition():
            return time.monotonic() - start
        time.sleep(0.05)
    raise RuntimeError("Timed out waiting for " + description)


def main(pid):
    command = subprocess.check_output(["ps", "-p", str(pid), "-o", "command="], text=True)
    if "--agent-qa-window" not in command.split():
        raise SystemExit("Choose the PID of a fresh --agent-qa-window instance.")
    app = ax.AXUIElementCreateApplication(pid)
    wait_for("workspace window", lambda: attribute(app, "AXWindows"))
    window = attribute(app, "AXWindows")[0]
    wait_for("saved message 243", lambda: 243 in visible_messages(window))
    press(window, "Jump to latest message")
    elapsed = wait_for("latest message 486", lambda: 486 in visible_messages(window))
    print(f"Saved position and jump verified. Message 486 appeared within {elapsed:.2f} seconds after AXPress.")
    press(window, "Earlier messages")
    wait_for("earlier page", lambda: 463 in visible_messages(window) and 486 not in visible_messages(window))
    press(window, "Reply")
    press(window, "Patch", sidebar=True)
    wait_for("Patch header", lambda: any(label(b) == "Patch" for b in buttons(window)))

    def has_quote():
        return any("Replying to " in str(attribute(e, "AXValue") or "") for e in descendants(window)
                   if attribute(e, "AXRole") == "AXStaticText")

    if has_quote():
        raise RuntimeError("The reply draft from Atlas appeared in Patch.")
    press(window, "Atlas", sidebar=True)
    wait_for("restored quote", has_quote)
    wait_for("reopened history", lambda: visible_messages(window))
    print("Earlier history, bot switching and per-chat reply drafts verified.")



@contextmanager
def private_workspace(source_app):
    with tempfile.TemporaryDirectory(prefix="SwarmHub-window-qa-") as scratch:
        base = Path(scratch)
        app = base / "WindowQA.app"
        subprocess.run(["ditto", source_app, app], check=True)
        info = app / "Contents/Info.plist"
        plist = plistlib.loads(info.read_bytes())
        plist["CFBundleIdentifier"] = "com.konrad.agentapp.window-qa." + uuid.uuid4().hex
        info.write_bytes(plistlib.dumps(plist))
        subprocess.run(["codesign", "--force", "--sign", "-", app], check=True)
        home = base / "home"
        store = home / "Library/Application Support/AgentApp/store.json"
        store.parent.mkdir(parents=True)
        yield app, home, store


@contextmanager
def open_workspace(app, home, address="http://127.0.0.1:1", token="", extra_environment=None, appearance=None):
    from AppKit import NSRunningApplication

    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                       SWARMHUB_DISABLE_UPDATES="1", SWARMHUB_SERVICE_HOME=str(home), SWARMHUB_HERDR_TOKEN=token)
    environment.update(extra_environment or {})
    arguments = [app / "Contents/MacOS/AgentApp", "-setupState", "skipped", "-herdrBaseURL", address]
    if appearance is not None:
        arguments.extend(["-appearance", appearance])
    process = subprocess.Popen(arguments, env=environment)
    try:
        application = ax.AXUIElementCreateApplication(process.pid)
        def windows():
            return [window for window in attribute(application, "AXWindows") or ()
                    if attribute(window, "AXRole") == "AXWindow"]
        running = lambda: NSRunningApplication.runningApplicationWithProcessIdentifier_(process.pid)
        wait_for("private app launch", lambda: running() and running().isFinishedLaunching(), seconds=15)
        running().activateWithOptions_(3)
        if not windows():
            # A direct executable launch can be running without an open-document event.
            subprocess.run(["open", "-a", str(app)], check=True)
        wait_for("private workspace window in the logged-in desktop session", windows, seconds=15)
        yield windows()[0]
    finally:
        if process.poll() is None:
            instance = NSRunningApplication.runningApplicationWithProcessIdentifier_(process.pid)
            if instance:
                instance.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise RuntimeError("Private workspace did not quit normally")


def group_restart(source_app):
    with private_workspace(source_app) as (app, home, store):
        bots = [{"id": str(uuid.uuid4()), "name": name, "backend": "Mock"} for name in ("Mira", "Patch")]
        group_id = str(uuid.uuid4()).upper()
        messages = []
        for number in range(1, 621):
            message = {"id": str(uuid.uuid4()).upper(), "role": "user", "createdAt": 800000000 + number,
                       "content": f"QA message {number} in this group. " + "Context from a previous session. " * 4}
            if number % 2:
                message.update(role="assistant", authorID=bots[(number // 2) % 2]["id"])
            messages.append(message)
        group = {"id": group_id, "name": "Release crew", "memberIDs": [bot["id"] for bot in bots], "messages": messages}
        store.write_text(json.dumps({"version": 2, "groups": [group], "bots": bots,
                                     "scrollPositions": {group_id: messages[311]["id"]}}))

        @contextmanager
        def open_group():
            with open_workspace(app, home) as window:
                def group_button():
                    return next((b for b in buttons(window) if "Release crew" in label(b)), None)
                wait_for("group in sidebar", group_button)
                if ax.AXUIElementPerformAction(group_button(), "AXPress") != 0:
                    raise RuntimeError("Could not open the group")
                yield window

        with open_group() as window:
            wait_for("saved group message 312", lambda: 312 in visible_messages(window))
            press(window, "Jump to latest message")
            wait_for("newest group message", lambda: 620 in visible_messages(window))
        with open_group() as window:
            wait_for("newest group message after relaunch", lambda: 620 in visible_messages(window))
            press(window, "Earlier messages")
            wait_for("earlier page", lambda: max(visible_messages(window), default=620) < 620)
        saved = json.loads(store.read_text())
        if [m["id"].upper() for m in saved["groups"][0]["messages"]] != [m["id"] for m in messages]:
            raise RuntimeError("Saved group history changed during restart")
        anchor = saved.get("scrollPositions", {}).get(group_id)
        anchor_number = next((i for i, m in enumerate(messages, 1) if m["id"] == anchor), None)
        if not anchor_number or anchor_number == 620:
            raise RuntimeError("Earlier page position was not saved")
        with open_group() as window:
            wait_for("earlier page after relaunch", lambda: anchor_number in visible_messages(window))
        print(f"Verified 620 group messages across two restarts, including saved message {anchor_number}.")


def verify_workspace_columns(window):
    def dividers():
        return [e for e in descendants(window) if attribute(e, "AXRole") == "AXSplitter"]

    def dimensions():
        sides = dividers()
        width = ax.AXValueGetValue(attribute(window, "AXSize"), ax.kAXValueCGSizeType, None)[1].width
        assert len(sides) == 2, sides
        sidebar, chat = [float(attribute(e, "AXValue")) for e in sides]
        return sidebar, chat, width - sidebar - chat - 2

    sidebar, chat, details = dimensions()
    assert abs(sidebar - 236) <= 1 and abs(details - 256) <= 1, (sidebar, chat, details)
    print(f"Window columns: {sidebar:g} / {chat:g} / {details:g} pt", flush=True)
    original_size = ax.AXValueGetValue(attribute(window, "AXSize"), ax.kAXValueCGSizeType, None)[1]
    shrink = min(64, original_size.width - 980)
    if shrink > 0:
        reduced = ax.AXValueCreate(ax.kAXValueCGSizeType, (original_size.width - shrink, original_size.height))
        assert ax.AXUIElementSetAttributeValue(window, "AXSize", reduced) == 0
        wait_for("chat absorbs window resize", lambda: abs(dimensions()[1] - (chat - shrink)) <= 1)
        assert ax.AXUIElementSetAttributeValue(window, "AXSize", ax.AXValueCreate(ax.kAXValueCGSizeType, original_size)) == 0
        wait_for("chat restores after resize", lambda: abs(dimensions()[1] - chat) <= 1)
    right = dividers()[1]
    if ax.AXUIElementSetAttributeValue(right, "AXValue", chat - 48) != 0:
        raise RuntimeError("Could not widen the Details column")
    wait_for("manually enlarged Details", lambda: abs(dimensions()[2] - details - 48) <= 1)
    right = dividers()[1]
    assert ax.AXUIElementSetAttributeValue(right, "AXValue", chat) == 0
    wait_for("original Details width", lambda: abs(dimensions()[2] - details) <= 1)


def verify_media(window):
    import Quartz

    def video_control():
        image = next((b for b in buttons(window) if label(b) == "render.png"), None)
        video = next((b for b in buttons(window) if label(b) == "Open clip.mp4"), None)
        if image is None or video is None:
            return None
        # AVKit reveals its controls when the pointer enters the player above the file button.
        position = attribute(video, "AXPosition")
        point = ax.AXValueGetValue(position, ax.kAXValueCGPointType, None)[1]
        move = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (point.x + 80, point.y - 25), 0)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, move)
        return next((e for e in descendants(window) if label(e).lower() == "play/pause"), None)

    wait_for("image preview and video controls", video_control)
    play = video_control()
    if ax.AXUIElementPerformAction(play, "AXPress") != 0:
        raise RuntimeError("Could not play the video")
    wait_for("video playing", lambda: int(attribute(play, "AXValue") or 0) == 1)
    press(window, "render.png")
    wait_for("image preview sheet", lambda: any(label(b) == "Done" for b in buttons(window)))
    press(window, "Done")
    wait_for("image preview closed", lambda: all(label(b) != "Done" for b in buttons(window)))


def steer_reopen(source_app):
    import base64
    import hashlib

    token = uuid.uuid4().hex
    bots = []
    answers = {}
    for index, name in enumerate(("BeforeOutputQA", "AfterSplitQA")):
        def row(role, text, **fields):
            return dict(id=str(uuid.uuid4()).upper(), role=role, createdAt=800000000 + len(rows), content=text, **fields)

        rows = []
        question = row("user", "Check the rendering.")
        rows.append(question)
        prefix = "The render has started." if index else "Up"
        original = row("assistant", prefix, metadata={"for": question["id"]}, turnState="incomplete")
        rows.append(original)
        guidance = "Use blue for " + name
        rows.append(row("user", guidance, metadata={"steer": "delivered", "partOrigin": original["id"]}))
        answer = "Updated " + name
        if index:
            original.update(turnState="finished")
            original["metadata"].update(part="1", partOrigin=original["id"])
            pending = row("assistant", "Still rendering.", turnState="incomplete",
                          metadata={"for": question["id"], "part": "2", "partOrigin": original["id"]})
            rows.append(pending)
        else:
            pending = original
        address = "session-" + str(index)
        pending["deliveryReceipt"] = dict(server="default", core="qa", address=address, createdMs=50, after=0,
                                          taskDigest=base64.b64encode(hashlib.sha256(question["content"].encode()).digest()).decode())
        answers["/api/history/qa/" + address + "/50"] = [
            dict(id=1, kind="task", text=question["content"]),
            dict(id=2, kind="reply", text=prefix + "\n\n" + answer if index else answer)]
        bots.append(dict(id=str(uuid.uuid4()), name=name, backend="Herdr", messages=rows))

    owner = bots[0]
    group_question = "Finish the group build"
    group_answer = "Group build finished after the connection dropped."
    group_reply = dict(id=str(uuid.uuid4()), role="assistant", content="Building…", authorID=owner["id"],
                       createdAt=800000012, turnState="stopped", metadata={"why": "stop-pending"},
                       deliveryReceipt=dict(server="default", core="qa", address="group-session", createdMs=70, after=0,
                                            taskDigest=base64.b64encode(hashlib.sha256(group_question.encode()).digest()).decode()))
    group = dict(id=str(uuid.uuid4()), name="Build team", memberIDs=[owner["id"]], messages=[
        dict(id=str(uuid.uuid4()), role="user", content=group_question, createdAt=800000011), group_reply])
    answers["/api/history/qa/group-session/70"] = [dict(id=1, kind="task", text=group_question), dict(id=2, kind="reply", text=group_answer)]
    parent = dict(address="session-0", created_ms=50)
    agent = dict(**parent, name=owner["name"].lower() + "-" + owner["id"][:6], state="live")
    helper = dict(address="worker", created_ms=51, name="RenderQA", state="live",
                  status={"state": "working"}, task="Verify the render.")
    online = False
    submissions = []

    class History(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.headers.get("Authorization") != "Bearer " + token or not online:
                self.send_error(503)
                return
            if self.path in answers:
                body = {"items": answers[self.path]}
            elif self.path.split("?")[0] == "/api/workspace":
                body = dict(core="qa", templates=[], agents=[agent, dict(helper, parent=parent)])
            elif self.path == "/api/agents/session-0/50/helpers":
                body = dict(core="qa", parent=parent, helpers=[helper])
            else:
                self.send_error(404)
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.path.startswith("/api/agents"):
                submissions.append(self.path)
            self.send_error(503)

        def log_message(self, *args):
            pass

    def text_positions(window):
        return {str(attribute(e, "AXValue") or label(e)): bounds(e) for e in descendants(window)
                if attribute(e, "AXRole") in ("AXStaticText", "AXTextArea")}

    with private_workspace(source_app) as (app, home, store), ThreadingHTTPServer(("127.0.0.1", 0), History) as server:
        reader = dict(id=str(uuid.uuid4()), name="ReadingQA", backend="Herdr",
                      messages=[dict(id=str(uuid.uuid4()), createdAt=800000001, role="assistant", content="Still reading this chat.")])
        store.write_text(json.dumps({"version": 2, "bots": bots + [reader], "groups": [group], "sidebar": {"pinned": [bots[1]["id"]]}}))
        def unread_counts():
            return [b.get("unreadCount", 0) for b in json.loads(store.read_text())["bots"] if b["name"] != reader["name"]]

        def unread_badge(window, name):
            return any(name + "," in label(b) and attribute(b, "AXValue") == "Unread" for b in buttons(window))

        Thread(target=server.serve_forever, daemon=True).start()
        try:
            for launch in range(2):
                with open_workspace(app, home, f"http://127.0.0.1:{server.server_port}", token) as window:
                    if launch == 0:
                        press(window, group["name"], sidebar=True)
                        wait_for("unconfirmed group stop", lambda: "Stop unconfirmed. The bot may still be running." in text_positions(window))
                        press(window, bots[0]["name"], sidebar=True)
                        wait_for("offline recovery footer", lambda: "Checking the workspace for your reply…" in text_positions(window))
                        if any("Needs attention" in label(b) and owner["name"] in label(b) for b in buttons(window)):
                            raise RuntimeError("The sidebar flagged an automatically recovering reply for user action")
                        press(window, reader["name"], sidebar=True)
                        wait_for("reading another conversation", lambda: "Still reading this chat." in text_positions(window))
                        def composer():
                            return next((e for e in descendants(window) if attribute(e, "AXRole") == "AXTextArea" and label(e) == "Message"), None)

                        draft = "Keep this draft while the bots finish."
                        field = composer()
                        enter_draft(field, draft)
                        online = True
                        wait_for("both replies saved", lambda: all(
                            any(m.get("turnState") == "finished" and m["content"] == "Updated " + bot["name"] for m in bot["messages"])
                            for bot in json.loads(store.read_text())["bots"] if bot["name"] != reader["name"]), seconds=15)
                        if unread_counts() != [1, 1]:
                            raise RuntimeError(f"Both replies arrived in the background. Saved unread counts: {unread_counts()}")
                        for bot in bots:
                            wait_for("unread sidebar badge on " + bot["name"], lambda: unread_badge(window, bot["name"]))
                        if "Still reading this chat." not in text_positions(window):
                            raise RuntimeError("A recovered answer switched the foreground chat")

                        field = composer()
                        if field is None or attribute(field, "AXValue") != draft or not attribute(field, "AXFocused"):
                            raise RuntimeError("Reply recovery interrupted the foreground draft")

                        def helper_button():
                            return next((label(b) for b in buttons(window) if label(b).startswith("Helper RenderQA,")), None)

                        wait_for("coding helper in the sidebar", helper_button, seconds=25)
                        disclosure = "Sessions for " + owner["name"]
                        press(window, disclosure)
                        wait_for("collapsed bot hides its helper", lambda: not helper_button())
                        # Activate the focused disclosure with Space in the private app.
                        import Quartz
                        toggle = next(b for b in buttons(window) if label(b) == disclosure)
                        if ax.AXUIElementSetAttributeValue(toggle, "AXFocused", True) != 0:
                            raise RuntimeError("Cannot focus the session disclosure")
                        pid = ax.AXUIElementGetPid(window, None)[1]
                        for down in (True, False):
                            Quartz.CGEventPostToPid(pid, Quartz.CGEventCreateKeyboardEvent(None, 49, down))
                        wait_for("expanded bot shows its helper", helper_button)
                        press(window, helper_button())
                        back = "Back to " + owner["name"]
                        wait_for("coding helper details", lambda: any(label(b) == back for b in buttons(window)))
                        if not unread_badge(window, owner["name"]) or unread_counts() != [1, 1]:
                            raise RuntimeError("Opening a helper cleared its parent chat’s unread answer")
                        press(window, back)
                    else:
                        if unread_counts() != [0, 1]:
                            raise RuntimeError(f"Unread state changed on restart: {unread_counts()}")
                        wait_for("restored unread badge", lambda: unread_badge(window, bots[1]["name"]))
                    for bot in (bots[:1] if launch == 0 else bots):
                        name = bot["name"]
                        if launch:
                            press(window, name, sidebar=True)
                        guidance, answer = "Use blue for " + name, "Updated " + name

                        def correct_order():
                            positions = text_positions(window)
                            return positions.get(guidance) and positions.get(answer) and positions[guidance][1] <= positions[answer][0]

                        wait_for("saved answer below " + guidance, correct_order, seconds=15)
                        wait_for("cleared unread badge on " + name, lambda: not unread_badge(window, name))
                    wait_for("unread group answer after reconnection", lambda: unread_badge(window, group["name"]), seconds=15)
                    if launch:
                        press(window, group["name"], sidebar=True)
                        wait_for("finished group command", lambda: group_answer in text_positions(window))
                        stored = json.loads(store.read_text())["groups"][0]
                        final = next(m for m in stored["messages"] if m["id"].lower() == group_reply["id"].lower())
                        if final["content"] != group_answer or final.get("turnState") != "finished" or stored["unreadCount"] != 0:
                            raise RuntimeError("Recovered group answer did not settle its original reply")
                    online = False
        finally:
            server.shutdown()
        if unread_counts() != [0, 0]:
            raise RuntimeError(f"Opening the chats left unread replies: {unread_counts()}")
        if submissions:
            raise RuntimeError(f"Recovery submitted work: {submissions}")
        print("Verified reply order, unread badges for pinned and unpinned chats, helper navigation and offline relaunch.")


def sample_workspace(source_app):
    with private_workspace(source_app) as (app, home, store):
        for reopened in (False, True):
            with open_workspace(app, home) as window:
                def button(title):
                    return any(label(b) == title for b in buttons(window))

                def has_text(text):
                    return any(text in str(attribute(e, "AXValue") or label(e)) for e in descendants(window))

                def pane(identifier):
                    return next((e for e in descendants(window) if attribute(e, "AXIdentifier") == identifier), None)

                def model_picker(bot):
                    return next((e for e in descendants(window) if attribute(e, "AXRole") == "AXMenuButton"
                                 and attribute(e, "AXHelp") == "Choose sample model for " + bot), None)

                tests = "Claude agent tests, Working"
                rename = "Codex agent rename, Answered"
                if reopened:
                    wait_for("saved sample disclosure", lambda: button("Sessions for Jarvis") and not button(rename))
                    press(window, "Sessions for Jarvis")
                    wait_for("saved stopped sample", lambda: button("Claude agent tests, Stopped") and button(rename))
                    press(window, "Patch", sidebar=True)
                    wait_for("restored Patch model", lambda: model_picker("Patch") and attribute(model_picker("Patch"), "AXValue") == "Claude · Sonnet")
                    wait_for("resolved sample inbox after restart", lambda: any(label(b) == "Needs Attention" and attribute(b, "AXValue") == "0" for b in buttons(window)))
                    assert any(b["name"] == "Payments" for b in json.loads(store.read_text())["bots"])
                    continue
                entry = "Look around with sample bots"
                wait_for("empty workspace sample entry", lambda: button(entry))
                press(window, entry)
                wait_for("Patch chat and both Jarvis children", lambda: button("Patch") and button(tests) and button(rename))
                assert [b["name"] for b in json.loads(store.read_text())["bots"]] == ["Jarvis", "Patch", "Scout", "Legal"]
                open_detail_section(window, "Overview")
                wait_for("Patch context and projects", lambda: has_text("34% ctx") and has_text("/srv/shop") and has_text("Drafts release notes"))
                open_detail_section(window, "Approvals")
                wait_for("Patch scoped rule", lambda: has_text("Reviewer: Scout") and has_text("Allow swift test"))
                open_detail_section(window, "Routines")
                wait_for("Patch CI watcher", lambda: has_text("Watch PR #142") and has_text("Changelog"))
                picker = model_picker("Patch")
                assert picker and ax.AXUIElementPerformAction(picker, "AXPress") == 0

                def choose_claude():
                    item = next((e for e in descendants(picker) if attribute(e, "AXRole") == "AXMenuItem"
                                 and "Claude · Sonnet" in label(e)), None)
                    return item and ax.AXUIElementPerformAction(item, "AXPress") == 0

                wait_for("select sample Claude model", choose_claude)
                wait_for("Patch model saved", lambda: json.loads(store.read_text())["bots"][1].get("sampleModel") == "Claude · Sonnet")
                press(window, "Scout", sidebar=True)
                wait_for("Scout routine", lambda: has_text("Morning brief") and has_text("08:55"))
                press(window, "Legal", sidebar=True)
                open_detail_section(window, "Approvals")
                wait_for("Legal approval policy", lambda: has_text("Ask everything") and has_text("Read-only documents"))
                open_detail_section(window, "Overview")
                wait_for("Legal spend cap and projects", lambda: has_text("$0.06 / $2.00 cap") and has_text("Saved documents"))
                wait_for("two sample inbox requests", lambda: any(label(b) == "Needs Attention" and attribute(b, "AXValue") == "2" for b in buttons(window)))
                press(window, "Needs Attention")
                wait_for("both decisions", lambda: button("Always allow in /srv/shop") and button("Create bot"))
                press(window, "Always allow in /srv/shop")
                wait_for("command resolved", lambda: not button("Always allow in /srv/shop") and button("Create bot"))
                press(window, "Create bot")
                wait_for("empty inbox", lambda: has_text("No pending items"))
                press(window, "Patch", sidebar=True)
                open_detail_section(window, "Approvals")
                wait_for("saved project rule", lambda: has_text("Allow swift test --filter ImporterTests in /srv/shop"))
                open_detail_section(window, "Overview")
                press(window, "Sessions for Jarvis")
                wait_for("folded samples", lambda: not button(tests) and not button(rename))
                press(window, "Sessions for Jarvis")
                wait_for("expanded samples", lambda: button(tests))
                press(window, tests)
                wait_for("sample command, steps and failure", lambda: button("Stop helper") and has_text("Steps (2)") and has_text("testEmptyTitle failed"))
                press(window, "Show terminal in Details")
                wait_for("docked sample output", lambda: pane("inspector.terminal") and has_text("expected throw"))
                press(window, "Back to Details")
                press(window, "Stop helper")
                wait_for("stopped in the sidebar", lambda: button("Claude agent tests, Stopped") and not button("Stop helper"))
                press(window, rename)
                wait_for("completed sample result", lambda: has_text("Steps (3)") and has_text("14 call sites") and has_text("Build complete!"))
                press(window, "Steer via Jarvis")
                wait_for("parent guidance composer", lambda: button("Send helper guidance") and has_text("Steering rename"))
                press(window, "Sessions for Jarvis")
                wait_for("fold before quitting", lambda: not button(rename))
        print("Verified the offline sample entry, both Jarvis sessions, a per-bot model change, inspector profiles, two inbox decisions and restoration after reopening.")


def sample_stories(source_app):
    with private_workspace(source_app) as (app, home, store):
        for reopened in (False, True):
            with open_workspace(app, home) as window:
                def present(text):
                    return any(text in str(attribute(e, "AXValue") or label(e)) for e in descendants(window))

                def has_button(name):
                    return any(label(b) == name for b in buttons(window))

                def pick_story(title):
                    menu = next(e for e in descendants(window) if attribute(e, "AXHelp") == "Choose a sample walkthrough")
                    assert ax.AXUIElementPerformAction(menu, "AXPress") == 0
                    def choose():
                        item = next((e for e in descendants(menu) if attribute(e, "AXRole") == "AXMenuItem" and label(e) == title), None)
                        return item and ax.AXUIElementPerformAction(item, "AXPress") == 0
                    wait_for(title, choose)

                if not reopened:
                    wait_for("sample entry", lambda: has_button("Look around with sample bots"))
                    press(window, "Look around with sample bots")
                    wait_for("release opening", lambda: has_button("Hand off to Scout") and present("Step 1 of 3"))
                    press(window, "Hand off to Scout")
                    def received_handoff():
                        sample = {b.get("sampleRole"): b for b in json.loads(store.read_text())["bots"]}
                        last = sample["patch"]["messages"][-1]
                        return last.get("authorID") == sample["scout"]["id"] and "unified Inbox" in last["content"]
                    wait_for("Scout handoff", lambda: has_button("Read Patch’s draft") and received_handoff())
                    continue

                press(window, "Patch", sidebar=True)
                wait_for("persisted handoff", lambda: has_button("Read Patch’s draft") and present("Step 2 of 3"))
                press(window, "Read Patch’s draft")
                wait_for("release draft", lambda: has_button("Make shorter") and has_button("Approve"))
                press(window, "Make shorter")
                wait_for("shortened draft", lambda: present("Paste screenshots into bot chats."))
                press(window, "Approve")
                wait_for("local approval receipt", lambda: present("Release notes approved in this sample."))
                press(window, "Replay walkthrough")
                wait_for("replay", lambda: has_button("Hand off to Scout"))
                pick_story("CI & reviewer bot")
                wait_for("CI opening", lambda: has_button("Review the failing check"))
                press(window, "Review the failing check")
                press(window, "Review the test command")
                wait_for("local command approval", lambda: has_button("Allow once"))
                press(window, "Allow once")
                wait_for("command receipt", lambda: present("28 tests passed"))
                pick_story("Team & helpers")
                wait_for("Jarvis story", lambda: has_button("Review the new roles"))
                press(window, "Review the new roles")
                press(window, "Open the Payments proposal")
                press(window, "Not now")
                wait_for("proposal dismissed", lambda: present("Payments proposal dismissed"))
                pick_story("Routines & brief")
                wait_for("brief opening", lambda: has_button("Gather server status"))
                press(window, "Gather server status")
                press(window, "Read the morning brief")
                wait_for("published sample brief", lambda: has_button("Open Morning brief"))
                press(window, "Open Morning brief")
                wait_for("reader revision and current inbox count", lambda: present("Revision 1") and present("0 pending items"))
                press(window, "Done")
                open_detail_section(window, "Media")
                press(window, "Browse published Pages…")
                wait_for("library lists the brief", lambda: has_button("Morning brief"))
                press(window, "Morning brief")
                wait_for("library opens the saved brief", lambda: present("Revision 1") and present("0 pending items"))
        print("Verified all four native sample walkthroughs, Scout’s handoff after relaunch, draft revision and approval, replay, shared Inbox decisions, and the published brief in the Pages library.")


def sidebar_focus(source_app):
    import Quartz

    bots = [dict(id=str(uuid.uuid4()), name=name, backend="Mock") for name in ("WriterQA", "PinnedQA")]
    with private_workspace(source_app) as (app, home, store):
        store.write_text(json.dumps(dict(version=2, bots=bots, groups=[], sidebar=dict(pinned=[bots[1]["id"]]))))
        with open_workspace(app, home) as window:
            pid = ax.AXUIElementGetPid(window, None)[1]

            def focused_draft():
                return next((attribute(e, "AXValue") for e in descendants(window)
                             if attribute(e, "AXRole") == "AXTextArea" and label(e) == "Message"
                             and attribute(e, "AXFocused")), None)

            def type_text(text):
                for down in (True, False):
                    key = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
                    Quartz.CGEventKeyboardSetUnicodeString(key, len(text), text)
                    Quartz.CGEventPostToPid(pid, key)

            for name, before, typed in [("WriterQA", "", "alpha"), ("PinnedQA", "", "beta"),
                                        ("WriterQA", "alpha", ""), ("WriterQA", "alpha", "")]:
                press(window, name, sidebar=True)
                wait_for(name + " composer automatically focused", lambda: any(label(b) == name for b in buttons(window)) and focused_draft() == before)
                if typed:
                    type_text(typed)
                    wait_for(name + " received keystrokes", lambda: focused_draft() == typed)
            print("Verified typing directly after selecting ordinary and pinned bots, reselecting a bot, and restoring its draft.")


def workspace_activity(source_app):
    import Quartz

    def message(text, state="finished"):
        return dict(id=str(uuid.uuid4()), role="assistant", content=text, turnState=state, createdAt=800000000)

    reader = dict(id=str(uuid.uuid4()), name="ReaderQA", backend="Mock")
    blocked = dict(id=str(uuid.uuid4()), name="BuildQA", backend="Mock", messages=[message("Build interrupted", "incomplete")])
    hidden = dict(id=str(uuid.uuid4()), name="HiddenQA", backend="Mock", manualUnread=True, isHidden=True)
    group = dict(id=str(uuid.uuid4()), name="Release team", memberIDs=[reader["id"]],
                 unreadCount=1, messages=[message("The release notes are ready")])

    with private_workspace(source_app) as (app, home, store):
        store.write_text(json.dumps(dict(version=2, bots=[reader, blocked, hidden], groups=[group])))
        with open_workspace(app, home) as window:
            def sheet():
                return next((e for e in descendants(window) if attribute(e, "AXRole") == "AXSheet"), None)

            def names():
                return [label(b) for b in buttons(sheet())] if sheet() else []

            def composer():
                return next((e for e in descendants(window) if label(e) == "Message" and attribute(e, "AXRole") == "AXTextArea"), None)

            press(window, reader["name"], sidebar=True)
            enter_draft(composer(), "Keep my draft")
            press(window, "Activity")
            target = "Release team, The release notes are ready"
            wait_for("unread group and interrupted bot", lambda: target in names() and "BuildQA, Reply is incomplete" in names())
            if any("HiddenQA" in value or "ReaderQA" in value for value in names()):
                raise RuntimeError("Hidden or idle chat appeared in Activity")
            press(sheet(), target)
            wait_for("group reply on screen", lambda: not sheet() and any(attribute(e, "AXValue") == "The release notes are ready" for e in descendants(window)))
            press(window, reader["name"], sidebar=True)
            wait_for("draft retained", lambda: composer() and attribute(composer(), "AXValue") == "Keep my draft")
            press(window, "Send message")
            press(window, "Activity")
            wait_for("working bot", lambda: any(s.startswith("ReaderQA,") and "sample bot" not in s for s in names()))
            wait_for("incoming reply while viewing Activity", lambda: any(s.startswith("ReaderQA,") and "sample bot" in s for s in names()))
            if target in names():
                raise RuntimeError("Group remained unread after viewing its reply")
            press(sheet(), next(s for s in names() if s.startswith("ReaderQA,")))
            wait_for("return to reader", lambda: not sheet() and composer())
            press(window, "Activity")
            wait_for("reader cleared on opening", lambda: sheet() and names() == ["Done", "BuildQA, Reply is incomplete"])
            press(sheet(), "BuildQA, Reply is incomplete")
            wait_for("incomplete reply visible", lambda: not sheet() and any(attribute(e, "AXValue") == "Build interrupted" for e in descendants(window)))
            press(window, "Hide sidebar")
            wait_for("sidebar hidden", lambda: any(label(b) == "Show sidebar" for b in buttons(window)))
            pid = ax.AXUIElementGetPid(window, None)[1]
            for down in (True, False):
                event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
                Quartz.CGEventSetFlags(event, Quartz.kCGEventFlagMaskCommand | Quartz.kCGEventFlagMaskShift)
                Quartz.CGEventPostToPid(pid, event)
            wait_for("Activity shortcut with sidebar hidden", lambda: "BuildQA, Reply is incomplete" in names())
            press(sheet(), "Done")
            print("Verified Activity navigation, live completion, draft retention and the hidden-sidebar shortcut.")


def window_unread(source_app):
    from AppKit import NSRunningApplication
    import Quartz

    with private_workspace(source_app) as (app, home, store):
        bot = dict(id=str(uuid.uuid4()), name="WindowQA", backend="Mock")
        group = dict(id=str(uuid.uuid4()), name="Window team", memberIDs=[bot["id"]])
        store.write_text(json.dumps(dict(version=2, bots=[bot], groups=[group])))

        with open_workspace(app, home) as window:
            pid = ax.AXUIElementGetPid(window, None)[1]
            running = NSRunningApplication.runningApplicationWithProcessIdentifier_(pid)
            application = attribute(window, "AXParent")
            finder = next(iter(NSRunningApplication.runningApplicationsWithBundleIdentifier_("com.apple.finder")), None)
            for state in ("minimized", "hidden", "another app is active", "Settings is open", "Search is open"):
                for name, collection in ((bot["name"], "bots"), (group["name"], "groups")):
                    press(window, name, sidebar=True)
                    def snapshot():
                        return json.loads(store.read_text())[collection][0]

                    previous = len(snapshot().get("messages", []))
                    field = next(e for e in descendants(window)
                                 if attribute(e, "AXRole") == "AXTextArea" and label(e) == "Message")
                    enter_draft(field, f"Reply while {state}.")
                    wait_for("enabled send control", lambda: any(label(b) == "Send message" and attribute(b, "AXEnabled") for b in buttons(window)))
                    press(window, "Send message")
                    if state == "minimized":
                        if ax.AXUIElementSetAttributeValue(window, "AXMinimized", True) != 0:
                            raise RuntimeError("Could not minimize the workspace")
                        wait_for("workspace minimized", lambda: attribute(window, "AXMinimized"))
                    elif state == "hidden":
                        if ax.AXUIElementSetAttributeValue(application, "AXHidden", True) != 0:
                            raise RuntimeError("Could not hide the workspace app")
                        wait_for("app hidden", lambda: attribute(application, "AXHidden"))
                    elif state == "another app is active":
                        if finder is None or not finder.activateWithOptions_(3):
                            raise RuntimeError("Could not switch to Finder")
                        wait_for("Finder in front", lambda: not attribute(application, "AXFrontmost"))
                    elif state == "Search is open":
                        press(window, "Search")
                        def sheet():
                            return next((e for e in descendants(window) if attribute(e, "AXRole") == "AXSheet"), None)
                        wait_for("Search sheet", sheet)
                    else:
                        press(window, "Settings")
                        def other_window():
                            return next((w for w in attribute(application, "AXWindows") or []
                                         if w != window and attribute(w, "AXMain")), None)
                        wait_for("Settings in front", other_window)
                    def finished():
                        return any(m.get("turnState") == "finished" for m in snapshot().get("messages", [])[previous:])

                    wait_for(f"{name} reply saved while {state}", finished)
                    if snapshot().get("unreadCount", 0) != 1:
                        raise RuntimeError(f"{name} reply finished while {state}, unread count {snapshot().get('unreadCount', 0)}")
                    if state == "minimized":
                        ax.AXUIElementSetAttributeValue(window, "AXMinimized", False)
                    elif state == "hidden":
                        ax.AXUIElementSetAttributeValue(application, "AXHidden", False)
                    elif state == "Search is open":
                        press(sheet(), "Done")
                    elif state == "Settings is open":
                        if ax.AXUIElementPerformAction(attribute(other_window(), "AXCloseButton"), "AXPress") != 0:
                            raise RuntimeError("Could not close Settings")
                    running.activateWithOptions_(3)
                    ax.AXUIElementPerformAction(window, "AXRaise")
                    wait_for("workspace restored", lambda: attribute(application, "AXFrontmost") and attribute(window, "AXMain")
                             and not attribute(window, "AXMinimized"))
                    wait_for("chat read on return", lambda: snapshot().get("unreadCount") == 0)
                    print(f"{name} reply stayed unread while {state} and cleared on return.")


def media_reopen(source_app):
    fixture = Path(__file__).resolve().parents[1] / "Fixtures/chat-media"
    files = {"/api/library/files/51/download": "render.png", "/api/library/files/52/download": "clip.mp4"}
    results = [{"id": i, "kind": "file", "title": name} for i, name in [(51, "render.png"), (52, "clip.mp4")]]
    message = {"id": str(uuid.uuid4()), "createdAt": 800000000, "role": "assistant", "content": "Two results for review.",
               "publishedResults": {"serverID": "default", "items": results}}
    token = uuid.uuid4().hex
    requests = []
    online = True

    class Files(BaseHTTPRequestHandler):
        def do_GET(self):
            name = files.get(self.path)
            if not name:
                self.send_error(404)
                return
            requests.append(name)
            if self.headers.get("Authorization") != "Bearer " + token or not online:
                self.send_error(503)
                return
            data = (fixture / name).read_bytes()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    with private_workspace(source_app) as (app, home, store), ThreadingHTTPServer(("127.0.0.1", 0), Files) as server:
        bots = [{"id": str(uuid.uuid4()), "name": name, "backend": "Mock", "messages": history}
                for name, history in [("MediaQA", [message]), ("OtherQA", [])]]
        store.write_text(json.dumps({"version": 2, "bots": bots}))
        Thread(target=server.serve_forever, daemon=True).start()
        address = f"http://127.0.0.1:{server.server_port}"
        try:
            for launch in range(2):
                with open_workspace(app, home, address, token) as window:
                    wait_for("media chat", lambda: any(label(b).startswith("MediaQA,") for b in buttons(window)))
                    press(window, "MediaQA", sidebar=True)
                    verify_media(window)
                    if launch == 0:
                        press(window, "OtherQA", sidebar=True)
                        wait_for("other chat", lambda: all(label(b) != "Open render.png" for b in buttons(window)))
                        online = False
                        press(window, "MediaQA", sidebar=True)
                        verify_media(window)
        finally:
            server.shutdown()
        if sorted(requests) != ["clip.mp4", "render.png"]:
            raise RuntimeError(f"Unexpected media download requests: {requests}")
        print("Image opened and video played online, after switching back offline, and after relaunch. Each file downloaded once.")


def workspace_pages(source_app, service_binary):
    import secrets
    import select
    import urllib.request

    with private_workspace(source_app) as (app, home, store), tempfile.TemporaryDirectory(dir="/tmp", prefix="sw-pages-") as scratch:
        token = secrets.token_hex(32)
        root = Path(scratch)
        environment = dict(HOME=scratch, PATH="/usr/bin:/bin", HC_SOCKET=str(root / "core.sock"),
                           SWARMHUB_ACCESS_TOKEN=token, SWARMHUB_DATA_DIR=str(root / "workspace"), SWARMHUB_PORT="0")
        bridge = subprocess.Popen([service_binary], cwd=root, env=environment, stdout=subprocess.PIPE, text=True)
        try:
            if not select.select([bridge.stdout], [], [], 10)[0]:
                raise RuntimeError("Private workspace did not start")
            origin = re.search(r"http://127\.0\.0\.1:\d+", bridge.stdout.readline()).group()

            def post(path, body):
                headers = {"Authorization": "Bearer " + token, "Origin": origin, "Content-Type": "application/json"}
                request = urllib.request.Request(origin + path, headers=headers, data=json.dumps(body).encode())
                with urllib.request.urlopen(request, timeout=5) as response:
                    return json.load(response)

            first = post("/api/pages", dict(title="QA C++ & status", markdown="Amber revision first"))
            post("/api/pages/" + str(first["id"]), dict(title=first["title"], revision=first["revision"],
                                                       markdown="Indigo revision latest"))
            other = post("/api/pages", dict(title="QA remote only", markdown="Search marker C++ & test"))
            card = dict(id=94, kind="page", pageID=first["id"], revision=first["revision"], title=first["title"])
            message = dict(id=str(uuid.uuid4()), role="assistant", createdAt=800000000, content="Read the attached result.",
                           publishedResults=dict(serverID="default", items=[card]))
            bot = dict(id=str(uuid.uuid4()), name="PagesQA", backend="Herdr", messages=[message])
            store.write_text(json.dumps(dict(version=2, bots=[bot])))
            with open_workspace(app, home, origin, token) as window:
                application = ax.AXUIElementCreateApplication(ax.AXUIElementGetPid(window, None)[1])

                def sheets():
                    return [s for w in attribute(application, "AXWindows") or [] for s in descendants(w)
                            if attribute(s, "AXRole") == "AXSheet"]

                def has_text(root, text):
                    return any(text == attribute(e, "AXValue") for e in descendants(root)
                               if attribute(e, "AXRole") == "AXStaticText")

                def button(root, prefix):
                    return next((b for b in buttons(root) if label(b).startswith(prefix)), None)

                def panel(description, predicate):
                    def current():
                        return next((s for s in reversed(sheets()) if predicate(s)), None)
                    wait_for(description, current)
                    return current()

                def click(root, prefix):
                    wait_for(prefix, lambda: button(root, prefix))
                    assert ax.AXUIElementPerformAction(button(root, prefix), "AXPress") == 0

                def enter(root, query):
                    field = next(e for e in descendants(root) if attribute(e, "AXRole") == "AXTextField")
                    assert ax.AXUIElementSetAttributeValue(field, "AXFocused", True) == 0
                    assert ax.AXUIElementSetAttributeValue(field, "AXValue", query) == 0

                def close_page_containing(text):
                    press(panel(text, lambda s: has_text(s, text)), "Done")

                wait_for("Page author", lambda: button(window, "PagesQA,"))
                press(window, "PagesQA", sidebar=True)
                open_detail_section(window, "Media")
                click(window, "Browse published Pages")
                media_library = panel("bot workspace library", lambda s: has_text(s, "Published Pages"))
                click(media_library, other["title"])
                close_page_containing("Search marker C++ & test")
                press(media_library, "Done")
                wait_for("media library dismissed", lambda: not sheets())
                press(window, "Search")
                palette = panel("Quick Switcher", lambda s: button(s, "Pages"))
                enter(palette, first["title"])
                click(palette, first["title"])
                close_page_containing("Amber revision first")

                press(palette, "Pages")
                library = panel("Page library", lambda s: has_text(s, "Published Pages"))
                click(library, first["title"])
                close_page_containing("Indigo revision latest")
                enter(library, "C++ & test")
                click(library, other["title"])
                close_page_containing("Search marker C++ & test")
                press(library, "Done")
                wait_for("library dismissed", lambda: not any(has_text(s, "Published Pages") for s in sheets()))

                enter(palette, "remote only")
                click(palette, "Search Pages in")
                library = panel("prefilled workspace search", lambda s: button(s, other["title"]))
                bridge.terminate()
                bridge.wait(timeout=5)
                click(library, other["title"])
                press(panel("offline Page retry", lambda s: button(s, "Retry")), "Done")
                press(library, "Done")
                wait_for("library dismissed offline", lambda: not any(has_text(s, "Published Pages") for s in sheets()))
                enter(palette, "PagesQA")
                click(palette, "PagesQA")
                wait_for("local chat open offline", lambda: not sheets())
                print("Verified the saved revision, current Page, workspace search, offline failure and local chat navigation.")
        finally:
            if bridge.poll() is None:
                bridge.terminate()
                bridge.wait(timeout=5)
            bridge.stdout.close()


def ai_inventory(source_app, service_binary):
    """Register an AI while the workspace is offline, then rescan from the same bot's model inspector."""
    with private_workspace(source_app) as (app, home, store):
        installed = home / ".local/bin"
        installed.mkdir(parents=True)
        shutil.copy2(service_binary, installed / "swarmhub-herdr")
        config = home / ".config"
        registration = config / "herdr-core/templates/swarmhub-antigravity.md"
        launched = installed / "unexpected-launch"
        offline = False
        listing_ready = False
        model_error = "OpenCode could not list models from the test provider."

        class Catalog(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.split("?")[0] != "/api/workspace":
                    self.send_error(404)
                    return
                if offline:
                    self.send_error(503)
                    return
                templates = [{"name": "qa-claude", "runtime": {"harness": "Claude Code", "display_name": "Claude"}}]
                if (registration.parent / "swarmhub-opencode.md").is_file():
                    templates.append({"name": "swarmhub-opencode", "model_agent": "OpenCode",
                                      "discover_models": True, "runtime": {"harness": "OpenCode", "display_name": "OpenCode"}})
                if registration.is_file():
                    templates.append({"name": "swarmhub-antigravity",
                                      "runtime": {"harness": "Antigravity CLI", "display_name": "Gemini"}})
                data = json.dumps({"core": "qa", "agents": [], "templates": templates}).encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                if self.path != "/api/runtime-models/swarmhub-opencode":
                    self.send_error(404)
                    return
                offered = [{"id": f"qa/recovered-{i}"} for i in range(13)]
                data = json.dumps({"models": offered} if listing_ready else {"error": model_error}).encode()
                self.send_response(200 if listing_ready else 409)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        def has_text(window, value):
            return any(attribute(e, "AXValue") == value for e in descendants(window)
                       if attribute(e, "AXRole") == "AXStaticText")

        with ThreadingHTTPServer(("127.0.0.1", 0), Catalog) as server:
            Thread(target=server.serve_forever, daemon=True).start()
            address = f"http://127.0.0.1:{server.server_port}"
            local = {"id": "default", "name": "QA Mac", "kind": "local", "address": address}
            bot = {"id": str(uuid.uuid4()), "name": "InventoryQA", "backend": "Herdr"}
            other = {"id": str(uuid.uuid4()), "name": "OtherQA", "backend": "Herdr"}
            store.write_text(json.dumps({"version": 2, "bots": [bot, other]}))
            # cfprefsd resolves preferences by bundle identifier in the Mac login session.
            domain = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
            subprocess.run(["defaults", "write", domain, "herdrServers", "-string", json.dumps([local])], check=True)
            isolated = {"XDG_CONFIG_HOME": str(config), "XDG_STATE_HOME": str(home / "state"),
                        "HC_SOCKET": str(home / "hc.sock"), "SWARMHUB_DATA_DIR": str(home / "data"),
                        "SWARMHUB_SERVICE_LABEL": domain, "SWARMHUB_SERVICE_PATH": str(installed)}
            try:
                with open_workspace(app, home, address, uuid.uuid4().hex, isolated) as window:
                    wait_for("QA bot", lambda: any(label(b).startswith("InventoryQA,") for b in buttons(window)))
                    press(window, "InventoryQA", sidebar=True)
                    model = lambda: next((b for b in buttons(window) if attribute(b, "AXIdentifier") == "chat.bot.model"), None)
                    wait_for("chat model button", model)
                    if ax.AXUIElementPerformAction(model(), "AXPress") != 0:
                        raise RuntimeError("Could not open model settings")
                    wait_for("existing provider", lambda: any(label(b) == "Claude, Default" for b in buttons(window)))
                    press(window, "Manage AIs on this Mac…")
                    app_element = attribute(window, "AXParent")

                    def settings_window():
                        return next((w for w in attribute(app_element, "AXWindows") or []
                                     if any(label(b) == "Scan again" for b in buttons(w))), None)

                    wait_for("AI settings window", settings_window)
                    settings = settings_window()
                    wait_for("initial inventory", lambda: has_text(settings, "Antigravity CLI"))
                    for bin_name in ("agy", "opencode2"):
                        executable = installed / bin_name
                        executable.write_text('#!/bin/sh\n: > "${0%/*}/unexpected-launch"\n')
                        executable.chmod(0o700)
                    press(settings, "Scan again")
                    wait_for("OpenCode V2-only installation", lambda: any(label(b) == "Add OpenCode" for b in buttons(settings)))
                    press(settings, "Add OpenCode")
                    wait_for("OpenCode registration", (registration.parent / "swarmhub-opencode.md").is_file)
                    wait_for("newly installed Antigravity", lambda: any(label(b) == "Add Antigravity CLI" and attribute(b, "AXEnabled") for b in buttons(settings)))
                    offline = True
                    press(settings, "Add Antigravity CLI")
                    wait_for("template written by the service", registration.is_file)
                    wait_for("local registration receipt", lambda: has_text(settings, "Registered on this Mac"))
                    if has_text(settings, "Added"):
                        raise RuntimeError("An offline workspace was shown as having accepted the new AI")
                    # Wait for the failed catalog read to finish before requesting another scan.
                    wait_for("completed offline scan", lambda: any(label(b) == "Scan again" and attribute(b, "AXEnabled")
                                                                 for b in buttons(settings)))
                    offline = False
                    press(settings, "Scan again")
                    wait_for("workspace registration confirmed", lambda: has_text(settings, "Added"))
                    if ax.AXUIElementPerformAction(attribute(settings, "AXCloseButton"), "AXPress") != 0:
                        raise RuntimeError("Could not close Settings")
                    wait_for("Antigravity in the open picker",
                             lambda: any(label(b) == "Gemini · Antigravity" for b in buttons(window)))
                    wait_for("OpenCode in the open picker", lambda: any(label(b) == "OpenCode" for b in buttons(window)))
                    press(window, "OpenCode")
                    wait_for("model catalog error", lambda: has_text(window, model_error))
                    listing_ready = True
                    press(window, "Reload models")
                    # The search field appears only when more than twelve models have actually loaded.
                    wait_for("recovered provider catalog", lambda: any(
                        attribute(e, "AXPlaceholderValue") == "Find a provider or model" for e in descendants(window)))
                    if has_text(window, model_error):
                        raise RuntimeError("The model error remained after the catalog loaded")
                    press(window, "Gemini · Antigravity")
                prefs = plistlib.loads(subprocess.check_output(["defaults", "export", domain, "-"]))
                if prefs.get("herdrTemplate." + bot["id"]) != "swarmhub-antigravity":
                    raise RuntimeError("The chosen bot did not save the Antigravity template")
                if prefs.get("herdrTemplate") or prefs.get("herdrTemplate." + other["id"]):
                    raise RuntimeError("Selecting a bot's AI changed another bot or the shared default")
                if launched.exists():
                    raise RuntimeError("Discovery launched the fixture AI")
            finally:
                server.shutdown()
                subprocess.run(["defaults", "delete", domain], check=False)
            print("OpenCode V2 and Antigravity discovered without launching either. Recovered the OpenCode catalog and saved Antigravity for one bot.")


def message_search(source_app):
    with private_workspace(source_app) as (app, home, store):
        bot, group = str(uuid.uuid4()), str(uuid.uuid4())

        def messages(start, markers):
            rows = []
            if start == 0:
                markers.update({n: "shared lookup term" for n in range(128, 149)})
            for number in range(start, start + 400):
                text = f"QA message {number}. " + markers.get(number, "Context from an earlier conversation. " * 3)
                rows.append({"id": str(uuid.uuid4()), "role": "user", "createdAt": 800000000 + number, "content": text})
            return rows

        large_history = os.environ.get("SWARMHUB_QA_LARGE_HISTORY") == "1"
        archive_count = 16_500 if large_history else 500
        archive_text = "Conversation material from an earlier session. " * 18 if large_history else "An imported message."
        archive = store.parent / "grok-history"
        archive.mkdir()
        for owner, first, phrase in [(bot, 1000, "original archived plan"), (group, 2000, "imported group decision")]:
            history = [{"id": "" if i == 260 else f"old-{i}", "seq": i, "role": "assistant",
                        "channel": "chat", "hidden": i == 261,
                        "text": f"QA message {first + i}. " + (phrase if i in (260, 261) else archive_text)}
                       for i in range(archive_count)]
            (archive / f"{owner}.json").write_text(json.dumps({"sourceID": owner, "messages": history}))
        store.write_text(json.dumps({
            "version": 2, "bots": [{"id": bot, "name": "LookupQA", "backend": "Mock",
                                     "grokSourceID": bot, "grokHistoryCount": archive_count,
                                     "messages": messages(0, {37: "original project brief", 88: "revised project brief"})}],
            "groups": [{"id": group, "name": "Launch QA", "memberIDs": [bot],
                        "grokSourceID": group, "grokHistoryCount": archive_count,
                        "messages": messages(400, {452: "the competitor brief"})}]}))
        with open_workspace(app, home) as window:
            wait_for("fixture bot", lambda: any(label(b).startswith("LookupQA,") for b in buttons(window)))
            press(window, "LookupQA", sidebar=True)
            wait_for("newest bot row", lambda: 399 in visible_messages(window))

            def search(term, target, keyboard=False, down=0):
                press(window, "Search")
                sheet = lambda: next((e for e in descendants(window) if attribute(e, "AXRole") == "AXSheet"), None)
                wait_for("search sheet", sheet)
                panel = sheet()
                field = next(e for e in descendants(panel) if attribute(e, "AXRole") == "AXTextField")
                if ax.AXUIElementSetAttributeValue(field, "AXValue", "Context from an earlier") != 0:
                    raise RuntimeError("Could not start a broad search")
                entered = time.monotonic()
                if ax.AXUIElementSetAttributeValue(field, "AXValue", term) != 0:
                    raise RuntimeError("Could not enter the search phrase")
                result = lambda: next((b for b in buttons(panel) if f"QA message {target + down}." in label(b)), None)
                wait_for("message search result", result)
                print(f"Found {term!r} in {time.monotonic() - entered:.2f}s")
                if any("Context from an earlier" in label(b) for b in buttons(panel)):
                    raise RuntimeError("An earlier query overwrote the final results")
                if target in (1260, 2260):
                    names = [label(b) for b in buttons(panel)]
                    if not any("Grok history" in name for name in names) or any(f"QA message {target + 1}." in name for name in names):
                        raise RuntimeError("Imported result lacks its source or contains a hidden prompt")
                started = time.monotonic()
                if keyboard:
                    import Quartz
                    if ax.AXUIElementSetAttributeValue(field, "AXFocused", True) != 0:
                        raise RuntimeError("Could not focus the search field")
                    pid = ax.AXUIElementGetPid(field, None)[1]
                    for key in [125] * down + [36]:  # Down Arrow, then Return.
                        for pressed in (True, False):
                            event = Quartz.CGEventCreateKeyboardEvent(None, key, pressed)
                            Quartz.CGEventSetFlags(event, 0)
                            Quartz.CGEventPostToPid(pid, event)
                        time.sleep(0.06)
                elif ax.AXUIElementPerformAction(result(), "AXPress") != 0:
                    raise RuntimeError("Could not open the matching message")
                try:
                    wait_for(f"message {target} in viewport", lambda: not sheet() and target in visible_messages(window))
                except RuntimeError as error:
                    raise RuntimeError(f"Expected {target}, visible {sorted(visible_messages(window))}, search open {bool(sheet())}") from error
                print(f"Opened visible message {target} in {time.monotonic() - started:.2f}s")

            search("competitor brief", 452)
            search("original project brief", 37)
            search("revised project brief", 88, keyboard=True)
            search("shared lookup term", 138, keyboard=True, down=10)
            search("imported group decision", 2260)
            press(window, "Earlier imported messages")
            wait_for("preceding archive page", lambda: 2240 in visible_messages(window))
            press(window, "Later imported messages")
            wait_for("original archive page", lambda: 2260 in visible_messages(window))
            search("original archived plan", 1260, keyboard=True)
            press(window, "Launch QA", sidebar=True)
            wait_for("group archive position after switching back", lambda: 2260 in visible_messages(window))
        with open_workspace(app, home) as window:
            press(window, "LookupQA", sidebar=True)
            wait_for("bot archive position after relaunch", lambda: 1260 in visible_messages(window))
        (archive / f"{bot}.json").unlink()
        with open_workspace(app, home) as window:
            press(window, "LookupQA", sidebar=True)
            wait_for("latest live message when the archive is missing", lambda: 399 in visible_messages(window))
        print("Verified live and imported search, archive paging, restored positions, and recovery from a missing archive.")


def live_terminals(source_app, screenshots=None, appearance=None, library=None, long_sidebar=False):
    import hashlib

    owner = dict(id=str(uuid.uuid4()), name="Patch", backend="Herdr")
    reader = dict(id=str(uuid.uuid4()), name="ReaderQA", backend="Mock")
    standby = dict(id=str(uuid.uuid4()), name="StandbyQA", backend="Herdr")
    pinned = dict(id=str(uuid.uuid4()), name="PinnedQA", backend="Herdr")
    group = dict(id=str(uuid.uuid4()), name="ReleaseQA", memberIDs=[owner["id"]], messages=[])
    group["messages"] = [dict(id=str(uuid.uuid4()), role="user", createdAt=800000000 + i,
                              content=f"QA message {i} in the group") for i in range(160)]
    session = "group-" + group["id"] + "-" + owner["id"]
    group["sessions"] = {owner["id"]: session}
    agent_names = ["patch-" + owner["id"][:6], "HelperQA",
                   "group-" + hashlib.sha256(session.encode()).hexdigest()[:24], "GroupHelperQA", "NestedQA"]
    agents = [dict(name=name, address="terminal" + str(i), created_ms=100 + i,
                   state="live", status=dict(state="working")) for i, name in enumerate(agent_names)]
    agents.append(dict(name="pinnedqa-" + pinned["id"][:6], address="pinned", created_ms=110,
                       state="live", status=dict(state="working")))
    agents[0]["template"] = "active-cli"
    templates = [dict(name="next-cli", runtime=dict(harness="Claude Code")), dict(name="active-cli", runtime=dict(harness="Codex"))]
    for child, parent in [(1, 0), (3, 2), (4, 3)]:
        agents[child]["parent"] = {k: agents[parent][k] for k in ("address", "created_ms")}
    job = "b" * 64
    token = str(uuid.uuid4())
    screens = []
    archives = []
    child_finished = Event()
    child_started_ms = int(time.time() * 1000) - 72000
    history_reads = []
    workers = [dict(host="test-host", complete=True, jobs=[
        dict(job=job, owner=owner["id"], state="working", provider="codex")])]

    class Workspace(BaseHTTPRequestHandler):
        def do_GET(self):
            route = self.path.split("?")[0]
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(403)
                return
            if route == "/api/workspace":
                reply = dict(core="qa", agents=agents, templates=templates, helper_results=True, archived_helper_parents=list(archives), helper_session_parents=[dict(address="terminal0", created_ms=100)], codejob_activity=workers)
            elif route == "/api/approvals":
                reply = dict(pending=[])
            elif route == "/api/attention":
                reply = dict(ci_failures=[])
            elif route.endswith("/output"):
                screens.append(route)
                reply = dict(text=route + " line " + str(screens.count(route)))
            elif route == "/api/agents/terminal0/100/opencode-threads/ses_layout":
                reply = dict(state="answered" if child_finished.is_set() else "working",
                             details=dict(task="Check the full header assignment.",
                                          reply="Complete sidebar result." if child_finished.is_set() else "I am checking the header.",
                                          terminal=dict(command="cat sidebar.txt", output="The sidebar is expanded."),
                                          steps=[dict(text="Read sidebar.txt", state="completed")]),
                             transcript="Task Check header.\n\ncompleted · read · sidebar.txt")
            elif route.endswith("/helpers"):
                _, _, _, address, created, _ = route.split("/")
                core = "prior" if "core=prior" in self.path else "qa"
                if "core=" in self.path:
                    history_reads.append((core, address, int(created)))
                reply = dict(core=core, helpers=[], parent=dict(address=address, created_ms=int(created)))
                for child in agents:
                    if child.get("parent") == reply["parent"]:
                        reply["helpers"].append(dict(child, task="Assigned to " + child["name"]))
                if core == "prior" or (address == "terminal2" and archives):
                    name = "PriorCoreQA" if core == "prior" else "GroupArchiveQA"
                    reply["recent_sessions"] = [dict(address="finished", created_ms=65, name=name, state="gone",
                                                       answered=True, reply=dict(id=1, text="Result from " + name))]
                elif address == "terminal0" and created == "100":
                    reply["opencode_threads"] = [dict(id="ses_layout",parent="ses_owner",runtime="opencode",
                        name="Layout reader", model="fixture/default", created_ms=child_started_ms,
                        completed_ms=child_started_ms + 74000 if child_finished.is_set() else None,
                        state="answered" if child_finished.is_set() else "working", task="Check header.",
                        reply="Sidebar result." if child_finished.is_set() else "")]
                    reply["opencode_threads"].append(dict(id="ses_nested", parent="ses_layout", runtime="opencode",
                        name="Nested reader", model="fixture/default", created_ms=105, completed_ms=110,
                        state="answered", task="Inspect the header", reply="Header checked."))
                    reply["last_result"] = dict(address="finished", created_ms=99, name="AnsweredQA", state="finished",
                                                answered=True, task="Check the import", reply=dict(id=18, text="The import passed."))
                    reply["recent_sessions"] = [dict(address="finished", created_ms=65, name="EarlierQA", state="gone",
                                                     answered=True, task="Check the export", reply=dict(id=17, text="The export passed."))]
            else:
                self.send_error(404)
                return
            data = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    with private_workspace(source_app) as (app, home, store), ThreadingHTTPServer(("127.0.0.1", 0), Workspace) as server:
        bots = [reader, owner, standby, pinned]
        if long_sidebar:
            bots.extend(dict(id=str(uuid.uuid4()), name=f"Z fixture {i:02}", backend="Mock", messages=[]) for i in range(50))
        store.write_text(json.dumps(dict(version=2, bots=bots, groups=[group], sidebar=dict(pinned=[pinned["id"]]),
                                         scrollPositions={group["id"].upper(): group["messages"][77]["id"]})))
        environment = {}
        if screenshots is not None:
            snapshot = home / "helper-window.png"
            trigger = home / "helper-window.png.request"
            environment = {"DYLD_INSERT_LIBRARIES": str(library), "SWARMHUB_QA_SNAPSHOT_PATH": str(snapshot)}

        def capture(state):
            if screenshots is not None:
                trigger.touch()
                wait_for("image of the private Mac window", lambda: snapshot.exists() and not trigger.exists(), seconds=15)
                shutil.copyfile(snapshot, screenshots / f"{appearance.lower()}-{state}.png")

        Thread(target=server.serve_forever, daemon=True).start()
        try:
            with open_workspace(app, home, "http://127.0.0.1:" + str(server.server_port), token, environment, appearance) as window:
                press(window, "ReaderQA", sidebar=True)
                field = next(e for e in descendants(window) if attribute(e, "AXRole") == "AXTextArea" and label(e) == "Message")
                enter_draft(field, "Draft stays in ReaderQA")
                wait_for("Patch’s live Codex label before opening its chat", lambda: any(
                    "Patch" in label(b).split(", ") and "Codex" in label(b).split(", ") for b in buttons(window)))
                wait_for("idle bot’s configured Claude label without opening it", lambda: any(
                    "StandbyQA" in label(b).split(", ") and "Claude" in label(b).split(", ") for b in buttons(window)))
                child_label = "OpenCode agent Layout reader, Working"
                wait_for("native child under Patch", lambda: any(label(b) == child_label for b in buttons(window)))
                def has_nested():
                    return any(label(b) == "OpenCode agent Nested reader, Answered" for b in buttons(window))
                wait_for("nested session under its provider parent", has_nested)
                press(window, "Sessions for Layout reader")
                wait_for("nested session folded", lambda: not has_nested())
                press(window, "Sessions for Patch")
                wait_for("parent bot folded", lambda: not any(label(b) == child_label for b in buttons(window)))
                press(window, "Sessions for Patch")
                wait_for("parent bot expanded", lambda: any(label(b) == child_label for b in buttons(window)))
                assert not has_nested()
                press(window, "Sessions for Layout reader")
                wait_for("nested session reopened", has_nested)
                press(window, "Preview terminal for Layout reader")
                def panel(identifier):
                    return next((n for n in descendants(window) if attribute(n, "AXIdentifier") == identifier), None)
                wait_for("cross-chat child preview", lambda: panel("inspector.terminal"))
                assert attribute(field, "AXValue") == "Draft stays in ReaderQA"
                assert any(label(b) == "Open session" for b in buttons(panel("inspector.terminal")))
                if long_sidebar:
                    area = next(a for a in descendants(window) if attribute(a, "AXRole") == "AXScrollArea"
                                and any(label(b) == child_label for b in buttons(a)))

                    def visible_child():
                        row = next((b for b in buttons(area) if label(b) == child_label), None)
                        viewport, frame = bounds(area), bounds(row) if row else None
                        return frame and viewport and viewport[0] <= frame[0] and frame[1] <= viewport[1]

                    bar = attribute(area, "AXVerticalScrollBar")
                    assert ax.AXUIElementSetAttributeValue(bar, "AXValue", 1.0) == 0
                    wait_for("helper preview beside an independently scrolled sidebar", lambda: not visible_child())
                    press(panel("inspector.terminal"), "Open session")
                    wait_for("central session details", lambda: panel("nativeSession.details"))
                    wait_for("opened helper visible in the sidebar", visible_child)
                    print("Opened the previewed session and revealed its row among 50 additional chats.", flush=True)
                    return
                press(window, "Back to Details")
                # Select the name directly from ReaderQA. The separate terminal icon previews in place.
                press(window, child_label)
                expected = {"Layout reader · Helper of Patch", "OpenCode · fixture/default", "Task", "Steps (1)", "Latest reply", "Check the full header assignment.",
                            "Read sidebar.txt", "I am checking the header.", "$ cat sidebar.txt", "The sidebar is expanded."}
                def shows_details():
                    center = panel("nativeSession.details")
                    return center and expected <= {str(attribute(n, "AXValue") or label(n)) for n in descendants(center)}
                wait_for("child task, step and reply in the center", shows_details)
                # AX exposes the full string even when SwiftUI draws an ellipsis. In
                # the default window both labels fit on separate lines if necessary.
                from AppKit import NSFont, NSFontAttributeName, NSFontWeightSemibold
                from Foundation import NSString
                title = "Layout reader · Helper of Patch"
                title_text = next(n for n in descendants(panel("nativeSession.details")) if attribute(n, "AXValue") == title)
                title_size = ax.AXValueGetValue(attribute(title_text, "AXSize"), ax.kAXValueCGSizeType, None)[1]
                window_size = ax.AXValueGetValue(attribute(window, "AXSize"), ax.kAXValueCGSizeType, None)[1]
                if window_size.width >= 1120:
                    font = NSFont.systemFontOfSize_weight_(14, NSFontWeightSemibold)
                    width = NSString.stringWithString_(title).sizeWithAttributes_({NSFontAttributeName: font}).width
                    assert title_size.width >= width - 2, f"Truncated helper owner at {title_size.width} pt, needs {width} pt"

                assert not panel("inspector.terminal") and panel("nativeSession.commandOutput")
                native_preview = "Preview output for Layout reader, helper of Patch"
                def overview_preview():
                    return any(label(b) == native_preview and attribute(b, "AXIdentifier") == "overview.activeHelpers"
                               for b in buttons(window))
                wait_for("working OpenCode session in Overview", overview_preview)
                verify_workspace_columns(window)
                capture("working")
                press(window, native_preview)
                wait_for("terminal from the active helper card", lambda: panel("inspector.terminal") and shows_details())
                press(window, "Back to Details")
                child_finished.set()
                expected.remove("I am checking the header.")
                expected.add("Complete sidebar result.")
                wait_for("completed reply without reopening the session", shows_details)
                wait_for("answered helper leaves Overview", lambda: panel("overview.activeHelpers") and not overview_preview())
                capture("answered")
                press(window, "Preview Layout reader in Details")
                wait_for("docked transcript beside child details", lambda: panel("inspector.terminal") and shows_details())
                press(window, "Back to Details")
                press(window, "Back to Patch")
                wait_for("parent composer", lambda: any(attribute(n, "AXRole") == "AXTextArea" and label(n) == "Message"
                                                         for n in descendants(window)))
                press(window, "ReaderQA", sidebar=True)
                field = next(e for e in descendants(window) if attribute(e, "AXRole") == "AXTextArea" and label(e) == "Message")
                wait_for("draft after navigating through a child", lambda: attribute(field, "AXValue") == "Draft stays in ReaderQA")
                print("Verified central native session details, docked transcript, return to parent and cross-chat draft.", flush=True)
                if screenshots is not None:
                    return
                press(window, "Live terminals")

                application = ax.AXUIElementCreateApplication(ax.AXUIElementGetPid(window, None)[1])
                def sheet():
                    floating = next((w for w in attribute(application, "AXWindows") or [] if label(w) == "Live terminals"), None)
                    return floating or next((n for n in descendants(window) if attribute(n, "AXIdentifier") == "inspector.terminal"), None)

                def choose(name):
                    wait_for(name, lambda: sheet() and any(label(b) == name for b in buttons(sheet())))
                    press(sheet(), name)

                def output(route, updates=1):
                    def displayed():
                        return sheet() and any(str(attribute(e, "AXValue") or "").replace("\n", "").startswith(route + " line ")
                                               for e in descendants(sheet())) and screens.count(route) >= updates
                    try:
                        wait_for("output from " + route, displayed)
                    except RuntimeError:
                        print("Preview contents", [(attribute(e, "AXRole"), label(e), str(attribute(e, "AXValue"))[:160])
                                                   for e in descendants(sheet())][-32:], "reads", screens[-5:], flush=True)
                        raise

                for title, route in [("Patch", "/api/agents/terminal0/100/output"),
                                     ("HelperQA", "/api/agents/terminal1/101/output"),
                                     ("NestedQA", "/api/agents/terminal4/104/output"),
                                     ("Patch · Codex working", "/api/codejobs/test-host/" + owner["id"] + "/" + job + "/output")]:
                    choose("Preview " + title)
                    output(route, updates=2)
                    choose("All terminals")
                choose("Done")
                wait_for("terminal window closed", lambda: not sheet())
                wait_for("return to existing draft", lambda: attribute(field, "AXValue") == "Draft stays in ReaderQA")
                press(window, "Preview terminal for PinnedQA")
                output("/api/agents/pinned/110/output")
                choose("Back to Details")
                worker_label = "Codex working for Patch · test-host · " + job[:8]
                press(window, worker_label)
                output("/api/codejobs/test-host/" + owner["id"] + "/" + job + "/output")
                choose("Back to Details")
                wait_for("ReaderQA draft after pinned bot and detached worker previews",
                         lambda: any(attribute(e, "AXRole") == "AXTextArea" and attribute(e, "AXValue") == "Draft stays in ReaderQA"
                                     for e in descendants(window)))
                press(window, "ReleaseQA", sidebar=True)
                wait_for("original group reading position", lambda: 77 in visible_messages(window))
                def group_composer():
                    return next((n for n in descendants(window) if attribute(n, "AXRole") == "AXTextArea"
                                 and label(n) == "Message"), None)
                enter_draft(group_composer(), "Group draft before opening a helper")

                def nested_button():
                    return next((b for b in buttons(window) if label(b).startswith("Helper NestedQA,")), None)
                wait_for("nested helper beneath its group parent", nested_button)
                press(window, "Sessions for GroupHelperQA")
                wait_for("nested branch collapsed", lambda: not nested_button())
                press(window, "Sessions for GroupHelperQA")
                wait_for("nested branch expanded", nested_button)
                press(window, label(nested_button()))
                wait_for("nested helper assignment", lambda: any(attribute(n, "AXValue") == "Assigned to NestedQA"
                                                                for n in descendants(window)))
                press(window, "Preview NestedQA in Details")
                wait_for("embedded preview", lambda: any(attribute(n, "AXIdentifier") == "inspector.terminal" for n in descendants(window)))
                output("/api/agents/terminal4/104/output", updates=2)
                choose("Back to Details")
                wait_for("helper assignment still open", lambda: any(attribute(n, "AXValue") == "Assigned to NestedQA" for n in descendants(window)))
                press(window, "Preview terminal for NestedQA")
                output("/api/agents/terminal4/104/output")
                choose("Back to Details")
                press(window, "Back to GroupHelperQA")
                wait_for("delegating helper assignment", lambda: any(attribute(n, "AXValue") == "Assigned to GroupHelperQA"
                                                                     for n in descendants(window)))
                press(window, "Back to ReleaseQA")
                wait_for("restored group reading position", lambda: 77 in visible_messages(window))
                wait_for("restored group draft", lambda: group_composer() and
                         attribute(group_composer(), "AXValue") == "Group draft before opening a helper")
                press(window, "Group terminals")
                choose("Preview Patch")
                output("/api/agents/terminal2/102/output")
                choose("All terminals")
                choose("Preview NestedQA")
                output("/api/agents/terminal4/104/output")
                choose("All terminals")
                choose("Preview GroupHelperQA")
                output("/api/agents/terminal3/103/output")
                # Replace the process at the same terminal address while its preview is open.
                agents[3]["created_ms"] = 999
                wait_for("stale terminal stopped", lambda: any(attribute(e, "AXValue") == "This terminal session has ended."
                                                               for e in descendants(sheet())))
                assert "/api/agents/terminal3/999/output" not in screens
                choose("Back to Details")
                wait_for("group terminal window closed", lambda: not sheet())
                wait_for("orphan removed after its parent address was reused", lambda: not nested_button())
                def owner_row():
                    return next((b for b in buttons(window) if "Patch" in label(b).split(", ")), None)
                try:
                    wait_for("Patch in the sidebar", owner_row)
                except RuntimeError:
                    print("Sidebar buttons", [label(b) for b in buttons(window)], flush=True)
                    raise
                press(window, label(owner_row()))
                press(window, "Preview Patch in Details")
                output("/api/agents/terminal0/100/output", updates=2)
                choose("Back to Details")
                def sidebar_worker():
                    return any(label(b) == worker_label for b in buttons(window))
                wait_for("detached worker beneath Patch", sidebar_worker)
                press(window, "Sessions for Patch")
                wait_for("worker hidden when Patch collapses", lambda: not sidebar_worker())
                press(window, "Sessions for Patch")
                wait_for("worker restored after expanding Patch", sidebar_worker)
                press(window, worker_label)
                output("/api/codejobs/test-host/" + owner["id"] + "/" + job + "/output")
                choose("Back to Details")
                def answered_button():
                    return next((b for b in buttons(window) if label(b).startswith("Helper AnsweredQA,")), None)
                wait_for("answered helper in the same tree", answered_button)
                press(window, label(answered_button()))
                wait_for("saved helper reply", lambda: any(attribute(n, "AXValue") == "The import passed." for n in descendants(window)))
                press(window, "Steer via Patch")
                press(window, "ReaderQA", sidebar=True)
                press(window, label(owner_row()))
                def earlier():
                    return next((b for b in buttons(window) if label(b).startswith("Helper EarlierQA,")), None)
                wait_for("earlier helper after returning to Patch", earlier)
                press(window, label(earlier()))
                wait_for("distinct earlier reply", lambda: any(attribute(n, "AXValue") == "The export passed." for n in descendants(window)))
                # The old parent's terminal is reaped. A replacement at its address has no helpers.
                old_ref = dict(address="terminal0", created_ms=100)
                archives.extend([
                    dict(core="qa", agent=agent_names[0], session=old_ref, revision=21),
                    dict(core="prior", agent=agent_names[0], session=old_ref, revision=12),
                    dict(core="qa", agent=agent_names[2], session=dict(address="terminal2", created_ms=102), revision=25),
                ])
                agents[0]["created_ms"] = 200
                del agents[1:]
                workers.clear()
                wait_for("old parent fetched by core and launch", lambda: ("qa","terminal0",100) in history_reads, 20)
                wait_for("selected result after parent replacement", lambda: any(attribute(n, "AXValue") == "The export passed." for n in descendants(window)))
                press(window, "ReaderQA", sidebar=True)
            with open_workspace(app, home, "http://127.0.0.1:" + str(server.server_port), token) as window:
                press(window, "ReaderQA", sidebar=True)
                def restored():
                    return {name for button in buttons(window) for name in ["AnsweredQA", "EarlierQA"]
                            if label(button).startswith("Helper " + name + ",")}
                wait_for("both closed sessions after relaunch", lambda: restored() == {"AnsweredQA", "EarlierQA"})
                def archived_button(name):
                    return next((b for b in buttons(window) if label(b).startswith("Helper " + name + ",")), None)
                for name, back in [("PriorCoreQA", "Back to Patch"), ("GroupArchiveQA", "Back to ReleaseQA")]:
                    wait_for(name, lambda: archived_button(name))
                    press(window, label(archived_button(name)))
                    wait_for("result from " + name, lambda: any(attribute(n, "AXValue") == "Result from " + name for n in descendants(window)))
                    press(window, back)
                print("Verified saved direct and group helper results after parent replacement, Core replacement, and app relaunch.")
                print("Verified pinned bot and detached worker previews preserve the current draft, live terminal identities, and two closed helpers after relaunch.")
        finally:
            server.shutdown()


def session_usage_overview(source_app):
    token = str(uuid.uuid4())
    bots = [dict(id=str(uuid.uuid4()), name=name, backend="Herdr", messages=[])
            for name in ("Patch", "Legal", "ArchiveQA")]
    previous = dict(id=str(uuid.uuid4()), createdAt=800000000, role="assistant", content="Keep the original chat.")
    bots[2]["messages"].append(previous)
    agents = [dict(name=b["name"].lower() + "-" + b["id"][:6], address="session" + str(i),
                   state="live", created_ms=100+i, status=dict(state="working")) for i, b in enumerate(bots[:2])]
    agents[0]["session_usage"] = dict(context_tokens=3400, window_tokens=10000, total_tokens=14000)
    agents[1]["session_usage"] = dict(total_tokens=1200, opencode_cost_usd=0.06)
    offline = False
    summary_session = []

    class Workspace(BaseHTTPRequestHandler):
        def do_GET(self):
            route = self.path.split("?")[0]
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(403)
                return
            if route == "/api/workspace":
                if offline:
                    self.send_error(503)
                    return
                body = dict(core="qa", agents=agents + summary_session, templates=[dict(name="qa-template")],
                            attachments=True, launch_attachments=True, codejob_activity=[])
            elif route == "/api/profiles":
                body = []
            elif route == "/api/history/qa/summary/300":
                body = dict(items=[dict(id=1, kind="reply", state="received", text="Keep the original chat.")])
            elif route == "/api/history/qa/summary/300/preview":
                body = dict(tools=[])
            elif route in ["/api/attention", "/api/approvals"]:
                body = dict(pending=[], ci_failures=[])
            else:
                self.send_error(404)
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(403)
                return
            if self.path == "/api/agents/with-files":
                from email.parser import BytesParser
                from email.policy import default
                raw = self.rfile.read(int(self.headers["Content-Length"]))
                payload = BytesParser(policy=default).parsebytes(
                    ("Content-Type: " + self.headers["Content-Type"] + "\r\n\r\n").encode() + raw)
                parts = list(payload.iter_parts())
                message = json.loads(parts[0].get_payload(decode=True))
                assert message["name"].startswith("handoff-") and b"Keep the original chat." in raw
                body = dict(name=message["name"], address="summary", created_ms=300, state="live",
                            template="qa-template", status=dict(state="done"))
                summary_session.append(body)
            elif self.path == "/api/agents/summary/300/end":
                summary_session.clear()
                body = dict(ended=True)
            else:
                self.send_error(404)
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    with private_workspace(source_app) as (app, home, store), ThreadingHTTPServer(("127.0.0.1", 0), Workspace) as server:
        store.write_text(json.dumps(dict(version=2, bots=bots, groups=[])))
        Thread(target=server.serve_forever, daemon=True).start()
        try:
            preferences = home / "Library/Preferences"
            preferences.mkdir(exist_ok=True, parents=True)
            domain = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
            for appearance in ["Dark", "Light"]:
                (preferences / (domain + ".plist")).write_bytes(plistlib.dumps({"appearance": appearance}))
                with open_workspace(app, home, "http://127.0.0.1:" + str(server.server_port), token) as window:
                    def select_bot(name):
                        def match():
                            return next((label(b) for b in buttons(window) if name in label(b).split(", ")), None)
                        try:
                            wait_for("sidebar bot " + name, match)
                            press(window, match())
                        except RuntimeError:
                            print("Sidebar buttons", [label(b) for b in buttons(window)], flush=True)
                            raise
                    select_bot("Patch")
                    if not any(label(b) == "Overview" for b in buttons(window)):
                        press(window, "Details")
                    press(window, "Overview")
                    def values():
                        panel = next((e for e in descendants(window) if attribute(e, "AXIdentifier") == "overview.sessionUsage"), None)
                        return [str(attribute(e, "AXValue") or label(e)) for e in descendants(panel)] if panel else []
                    def shows(test):
                        try:
                            wait_for("session usage", lambda: test(values()), seconds=18)
                        except RuntimeError:
                            print("Session usage", values(), "window buttons", [label(b) for b in buttons(window)], flush=True)
                            raise
                    shows(lambda v: "34% ctx" in v and "No priced usage reported" in v)
                    select_bot("Legal")
                    shows(lambda v: any("0.06" in t.replace(",", ".") for t in v) and "34% ctx" not in v)
                    agents[1]["session_usage"]["opencode_cost_usd"] = 0.09
                    shows(lambda v: any("0.09" in t.replace(",", ".") for t in v))
                    offline = True
                    shows(lambda v: "Last reported before the workspace disconnected" in v)
                    offline = False
                    del agents[1]["session_usage"]
                    shows(lambda v: "Usage has not been reported for this session" in v and not any("0.09" in t.replace(",", ".") for t in v))
                    select_bot("ArchiveQA")
                    shows(lambda v: "No active session" in v)
                    press(window, "Summarize & start fresh")
                    shows(lambda v: any("Summary ready" in t for t in v))
                    assert any(previous["id"].lower() == m["id"].lower() for b in json.loads(store.read_text())["bots"]
                               if b["id"].lower() == bots[2]["id"].lower() for m in b["messages"])
                    agents[1]["session_usage"] = dict(total_tokens=1200, opencode_cost_usd=0.06)
            print("Verified per-bot context and priced usage, live updates, disconnection, missing counters and a saved chat summary.")
        finally:
            server.shutdown()


def qa_inbox_proposals(window, store, command, decisions):
    press(window, "ReaderQA", sidebar=True)
    def count(n):
        return any(label(b) == "Needs Attention" and str(attribute(b, "AXValue")) == str(n) for b in buttons(window))
    wait_for("command and both bot proposals in the badge", lambda: count(3), seconds=15)
    press(window, "Needs Attention")
    def shown(text):
        return any(label(e) == text or attribute(e, "AXValue") == text for e in descendants(window))
    wait_for("command and proposal cards together", lambda: shown("swift test --filter ImporterTests") and shown("Create Payments with Claude") and shown("Sensitive role") and shown("Prepares supplier payments."))
    wait_for("scoped actions on the inbox card", lambda: shown("Always allow in /srv/shop") and shown("Allow once") and shown("Deny"))
    press(window, "Inspect Bash request")
    wait_for("pending command review", lambda: shown("Reviewing command…"))
    command["reviewer"].update(bot_name="Scout", model="opus", assessment="Runs only the named tests.")
    wait_for("open request stays open when Scout answers", lambda: shown("Runs only the named tests.") and shown("Deny"), seconds=12)
    assert not decisions
    press(window, "Done")
    press(window, "Needs Attention")
    wait_for("finished review credited on the collapsed request", lambda: shown("Reviewed by Scout") and shown("Inspect Bash request"))
    press(window, "Inspect Bash request")
    wait_for("review remains available", lambda: shown("Runs only the named tests."))
    press(window, "Deny")
    wait_for("exact command denied", lambda: decisions == [(2, "deny")])
    press(window, "Dismiss proposal for Legal")
    wait_for("dismissed proposal", lambda: not shown("Create Legal") and count(1))
    press(window, "Create Payments with Claude")
    def saved():
        return [b for b in json.loads(store.read_text())["bots"] if b["name"] in ("Payments", "Legal")]
    wait_for("approved bot persisted", lambda: len(saved()) == 1 and saved()[0]["name"] == "Payments" and count(0), seconds=12)
    assert saved()[0]["persona"] == "Prepare supplier invoices." and shown("No pending items")
    press(window, "Done")
    print("Handled both bot proposals and the live named command review in Needs Attention while ReaderQA stayed open.")


def activity_decisions(source_app, named_review_only=False, proposals_only=False):
    import Quartz
    from threading import Thread

    owner = dict(id=str(uuid.uuid4()), name="Patch", backend="Herdr")
    reader = dict(id=str(uuid.uuid4()), name="ReaderQA", backend="Mock")
    agent = dict(name="patch-" + owner["id"][:6], address="session", created_ms=80, state="live")
    agent["session_usage"] = dict(total_tokens=1200, opencode_cost_usd=2.0)
    token = str(uuid.uuid4())
    pending = [dict(id=i, agent=agent["name"], provider="Codex", tool=tool, cwd="/qa",
                    arguments="argument-" + str(i), core="qa", address="session", created_ms=created)
               for i, tool, created in [(1, "Read", 80), (2, "Bash", 80), (3, "Previous", 79)]]
    decisions = []
    rules = []
    reviewed = []

    if proposals_only:
        owner["canManageBots"] = True
        requests = [dict(op="create_bot", name=name, decision="ask", instructions=work)
                    for name, work in [("Payments", "Prepare supplier invoices."), ("Legal", "Review contracts.")]]
        requests[0].update(decision="decided", review_reason="Prepares supplier payments.")
        owner["messages"] = [dict(id=str(uuid.uuid4()), role="assistant", createdAt=800000010,
            content="".join("\n```swarmhub\n" + json.dumps(r) + "\n```\n" for r in requests))]
        pending[:] = [dict(pending[1], cwd="/srv/shop", can_remember_command=True, arguments=json.dumps({"command":"swift test --filter ImporterTests"}),
                           reviewer=dict(bot_id=str(uuid.uuid4()), model="", assessment=None))]
        reviewed.append(7)

    tool_reviews = set()

    class Inbox(BaseHTTPRequestHandler):
        def reply(self, body):
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            route = self.path.split("?")[0]
            if self.headers.get("Authorization") != "Bearer " + token:
                self.send_error(403)
            elif route == "/api/workspace":
                self.reply(dict(core="qa", agents=[agent], templates=[dict(name="claude", supports_tool_review=True)] if proposals_only else []))
            elif route == "/api/project-command-rules":
                self.reply(rules.copy())
            elif route == "/api/attention":
                failures = [] if reviewed else [dict(id=7, bot="Patch", pull_request="repo/pull/12", check_run="CI")]
                self.reply(dict(ci_failures=failures, completions=[]))
            elif route == "/api/approvals":
                self.reply(dict(pending=[r for r in pending if r["id"] not in dict(decisions)]))
            else:
                self.send_error(404)

        def do_POST(self):
            if proposals_only and self.path.startswith("/api/bot-agent-settings/") and self.headers.get("Authorization") == "Bearer " + token:
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert body["review_every_tool"] is True
                tool_reviews.add(self.path.rsplit("/", 1)[1])
                self.reply(dict(auto_mode=False, review_every_tool=True))
                return
            if self.path == "/api/attention/ci/7/review" and self.headers.get("Authorization") == "Bearer " + token:
                reviewed.append(7)
                self.reply(dict(reviewed=True))
            elif self.path.startswith("/api/approvals/") and self.headers.get("Authorization") == "Bearer " + token:
                request_id = int(self.path.split("/")[-1])
                decision = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if decision in ("remember_command", "remember_command_hour"):
                    rule = dict(id=8, bot=owner["id"], agent=agent["name"], provider="Codex",
                                      cwd="/qa", command="swift test --filter ImporterTests")
                    if decision == "remember_command_hour":
                        rule["expires_ms"] = int(time.time() * 1000) + 3600000
                        Timer(2.5, rules.append, args=(rule,)).start()
                    else:
                        rules.append(rule)
                decisions.append((request_id, decision))
                self.reply(dict(id=request_id))
            elif self.path == "/api/project-command-rules/8/revoke" and self.headers.get("Authorization") == "Bearer " + token:
                rules.clear()
                self.reply(dict(revoked=True))
            else:
                self.send_error(404)

        def log_message(self, *args):
            pass

    with private_workspace(source_app) as (app, home, store), ThreadingHTTPServer(("127.0.0.1", 0), Inbox) as server:
        store.write_text(json.dumps(dict(version=2, bots=[reader, owner], groups=[])))
        Thread(target=server.serve_forever, daemon=True).start()
        try:
            with open_workspace(app, home, "http://127.0.0.1:" + str(server.server_port), token) as window:
                if proposals_only:
                    qa_inbox_proposals(window, store, pending[0], decisions)
                    payment = next(b for b in json.loads(store.read_text())["bots"] if b["name"] == "Payments")
                    assert payment["requiresToolReview"] and payment["id"].lower() in tool_reviews
                    return
                if named_review_only:
                    # Watch a named review arrive while the chat remains open on the same request.
                    reviewer = dict(bot_id=str(uuid.uuid4()), bot_name=None, model="", assessment=None)
                    pending[:] = [dict(pending[1], id=9, reviewer=reviewer)]
                    press(window, "Patch", sidebar=True)
                    def chat_text(line):
                        return any(attribute(e, "AXValue") == line for e in descendants(window))
                    wait_for("command review in progress in chat", lambda: chat_text("Reviewing command…"), seconds=12)
                    reviewer.update(bot_name="Scout", model="opus", assessment="This command prints orchid.")
                    wait_for("attributed review live in chat", lambda: chat_text("Scout · Claude review")
                             and chat_text("This command prints orchid."), seconds=12)
                    assert not decisions
                    press(window, "Deny")
                    wait_for("user decided after reading Scout’s review", lambda: (9, "deny") in decisions)
                    print("Scout’s background review appeared in the open Patch chat. The decision waited for the person.")
                    return
                press(window, "ReaderQA", sidebar=True)
                def count_is(expected):
                    return any(label(b) == "Needs Attention" and str(attribute(b, "AXValue")) == str(expected)
                               for b in buttons(window))

                wait_for("two approvals and one failing check", lambda: count_is(3))
                footer = [attribute(e, "AXValue") for e in descendants(window)]
                assert "0 SSH hosts" in footer and "2 bots" in footer
                press(window, "Needs Attention")

                def sheet():
                    return next((e for e in descendants(window) if attribute(e, "AXIdentifier") == "workspace.attention"), None)

                def names():
                    return [label(b) for b in buttons(sheet())] if sheet() else []

                wait_for("CI entry in inbox", lambda: "Mark reviewed" in names())
                press(sheet(), "Mark reviewed")
                wait_for("CI review receipt", lambda: reviewed == [7])
                pid = ax.AXUIElementGetPid(window, None)[1]
                for request_id, tool, decision, key in [(2, "Bash", "deny", 51), (1, "Read", "approve", 36)]:
                    inspect = "Inspect " + tool + " request"
                    wait_for(inspect, lambda: inspect in names())
                    assert "Inspect Previous request" not in names()
                    press(sheet(), inspect)
                    wait_for("matching command details", lambda: any(
                        attribute(e, "AXValue") == "argument-" + str(request_id) for e in descendants(sheet())))
                    for down in (True, False):
                        event = Quartz.CGEventCreateKeyboardEvent(None, key, down)
                        Quartz.CGEventSetFlags(event, Quartz.kCGEventFlagMaskCommand)
                        Quartz.CGEventPostToPid(pid, event)
                    wait_for("exact keyboard decision", lambda: (request_id, decision) in decisions)
                    assert sheet()
                assert decisions == [(2, "deny"), (1, "approve")]
                wait_for("both requests cleared", lambda: "Done" in names() and not any(n.startswith("Inspect ") or n.startswith("Patch,") for n in names()))
                press(sheet(), "Done")
                wait_for("Activity dismissed", lambda: not sheet())
                wait_for("empty sidebar badge", lambda: count_is(0))
                press(window, "Patch", sidebar=True)
                wait_for("writable bot composer", lambda: any(label(b) == "/goal" for b in buttons(window)))
                if not any(label(b) == "Approvals" for b in buttons(window)):
                    press(window, "Details")
                press(window, "Approvals")
                wait_for("bot approvals clear", lambda: any(attribute(e, "AXValue") == "No pending requests"
                                                            for e in descendants(window)))
                pending.append(dict(pending[1], id=4, can_remember_command=True,
                                    arguments=json.dumps({"command": "swift test --filter ImporterTests"})))
                wait_for("project-specific permission", lambda: any(label(b) == "Always allow here" for b in buttons(window)), seconds=12)
                assert not any(label(b) == "Allow here for 1 hour" for b in buttons(window))
                press(window, "Always allow here")
                wait_for("saved project rule", lambda: bool(rules) and any(label(b) == "Revoke" for b in buttons(window)), seconds=12)
                press(window, "Revoke")
                wait_for("project rule removed", lambda: not rules and not any(label(b) == "Revoke" for b in buttons(window)))
                pending.append(dict(pending[-1], id=5, can_remember_command_hour=True))
                wait_for("one-hour permission", lambda: any(label(b) == "Allow here for 1 hour" for b in buttons(window)), seconds=12)
                press(window, "Allow here for 1 hour")
                wait_for("saved deadline", lambda: (5, "remember_command_hour") in decisions and any(
                    str(attribute(e, "AXValue") or "").startswith("Until ") for e in descendants(window)), seconds=20)
                press(window, "Revoke")
                wait_for("timed rule removed", lambda: not rules)
                print("Verified a one-hour command decision, visible expiry and revocation; older workspaces retain their original actions.")
                composer = next(e for e in descendants(window) if attribute(e, "AXRole") == "AXTextArea" and label(e) == "Message")
                enter_draft(composer, "--budget 2.00 inspect this build")
                press(window, "/goal")
                wait_for("goal preserves the draft", lambda: attribute(composer, "AXValue") == "/goal --budget 2.00 inspect this build")
                press(window, "Send message")

                def stopped_at_budget():
                    goal = next(b for b in json.loads(store.read_text())["bots"] if b["name"] == "Patch").get("goal") or {}
                    return goal.get("state") == "stopped" and goal["iteration"] == 0 and goal["lastSpend"]["usd"] == 2

                wait_for("goal stopped before issuing a paid step", stopped_at_budget)
                press(window, "+ Screenshot")
                application = ax.AXUIElementCreateApplication(pid)
                def cancel_button():
                    return next((b for w in attribute(application, "AXWindows") or [] for b in buttons(w) if label(b) == "Cancel"), None)
                wait_for("screenshot picker", cancel_button)
                assert ax.AXUIElementPerformAction(cancel_button(), "AXPress") == 0
                print("Verified saving and revoking a scoped command in the bot inspector, the screenshot picker and a zero-dispatch USD limit.")
                print("Verified sidebar counts and CI review. Reviewed two requests from a different chat, denied and approved by keyboard, and excluded a stale session.")
        finally:
            server.shutdown()


def team_pack(source_app, appearance):
    import Quartz
    from AppKit import NSRunningApplication

    with private_workspace(source_app) as (app, home, store):
        bots = [dict(id=str(uuid.uuid4()), name=name, title=role, persona=instructions, backend="Mock")
                for name, role, instructions in (("ScoutQA", "Tester", "Check the fixtures."),
                                                ("PatchQA", "Writer", "Write the release notes."))]
        group = dict(id=str(uuid.uuid4()), name="Release crew", memberIDs=[b["id"] for b in bots], messages=[])
        store.write_text(json.dumps(dict(version=2, bots=bots, groups=[group])))
        preferences = home / "Library/Preferences"
        preferences.mkdir(exist_ok=True, parents=True)
        domain = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        (preferences / (domain + ".plist")).write_bytes(plistlib.dumps({"appearance": appearance}))
        destination = home / "SwarmHub Team Pack.json"
        with open_workspace(app, home) as window:
            application = attribute(window, "AXParent")
            pid = ax.AXUIElementGetPid(window, None)[1]
            command = Quartz.kCGEventFlagMaskCommand
            shift = Quartz.kCGEventFlagMaskShift

            def key(code, flags=0, text=None):
                def frontmost():
                    focused = attribute(ax.AXUIElementCreateSystemWide(), "AXFocusedApplication")
                    return focused is not None and ax.AXUIElementGetPid(focused, None)[1] == pid
                if not frontmost():
                    NSRunningApplication.runningApplicationWithProcessIdentifier_(pid).activateWithOptions_(3)
                    wait_for("private QA app keyboard focus", frontmost)
                # The macOS file dialogs forward real keyboard events to the panel service.
                for down in (True, False):
                    if not frontmost():
                        raise RuntimeError("The private QA app lost keyboard focus")
                    event = Quartz.CGEventCreateKeyboardEvent(None, code, down)
                    Quartz.CGEventSetFlags(event, flags)
                    if text:
                        Quartz.CGEventKeyboardSetUnicodeString(event, len(text), text)
                    Quartz.CGEventPost(Quartz.kCGHIDEventTap, event)

            def find_button(title):
                return next((b for w in attribute(application, "AXWindows") or []
                             for b in buttons(w) if label(b) == title), None)

            def click(title):
                wait_for(title, lambda: find_button(title))
                assert ax.AXUIElementPerformAction(find_button(title), "AXPress") == 0

            def go_to(path):
                key(5, command | shift)
                time.sleep(0.4)
                key(0, command)
                path = str(path)
                for i in range(0, len(path), 10):
                    key(0, text=path[i:i+10])
                time.sleep(0.4)
                key(36)
                time.sleep(0.7)

            wait_for("group row", lambda: any(label(b).startswith("Release crew,") for b in buttons(window)))
            press(window, "Release crew", sidebar=True)
            if not find_button("Export Team Pack…"):
                click("Details")
            click("Export Team Pack…")
            wait_for("save dialog", lambda: find_button("Save"))
            go_to(home)
            dialog = next(w for w in attribute(application, "AXWindows") if label(w) == "Save")
            assert any(attribute(e, "AXRole") == "AXPopUpButton" and attribute(e, "AXValue") == home.name
                       for e in descendants(dialog)), "The Save dialog must point to the scratch folder"
            click("Save")
            wait_for("pack export", destination.exists)
            assert [m["name"] for m in json.loads(destination.read_text())["members"]] == ["ScoutQA", "PatchQA"]
            key(45, command | shift)
            click("Import Team Pack…")
            wait_for("open dialog", lambda: find_button("Open"))
            go_to(destination)
            if not find_button("Import group"):
                click("Open")
            wait_for("pack preview", lambda: find_button("Import group"))
            assert len(json.loads(store.read_text())["groups"]) == 1
            click("Import group")
            wait_for("group import", lambda: len(json.loads(store.read_text())["groups"]) == 2)
            saved = json.loads(store.read_text())
            by_id = {b["id"]: b for b in saved["bots"]}
            imported_ids = saved["groups"][-1]["memberIDs"]
            imported = [by_id[i] for i in imported_ids]
            assert [b["persona"] for b in imported] == [b["persona"] for b in bots]
            assert all(b["backend"] == "Herdr" and not b["messages"] for b in imported)
            assert set(imported_ids).isdisjoint(saved["groups"][0]["memberIDs"])
            wait_for("group preview closed", lambda: not find_button("Import group"))
            # Quit through the same app after the file panels have relinquished keyboard focus.
            key(12, command)
            wait_for("private workspace to quit", lambda: not attribute(application, "AXWindows"), seconds=12)
            print(f"{appearance}: exported, reviewed and imported a two-bot group through the native file dialogs.")


def team_inspector(source_app, appearance):
    token = uuid.uuid4().hex
    bots = [dict(id=str(uuid.uuid4()), name=name, title=title, backend="Herdr")
            for name, title in (("Patch", "Releases and pull requests"), ("Scout", "Build verification"))]
    owners = {b["id"]: b["name"] for b in bots}
    watch = "Watch public PR 142"
    exchange = dict(id=7, kind="ask", state="answered", text="Verified three changes for the release.",
                    **{"from": {"name": "Patch"}, "to": {"name": "Scout"}})

    catalog_online = False
    catalog_reads = []
    skills_online = False
    long_skill = "format-" + "generated-file-" * 8 + "names"
    skills = [dict(name=name, enabled=True) for name in
              ("Changelog", "Code review", long_skill, "Docs", "Lint", "Accessibility", "Test runner")]
    skills.append(dict(name="Disabled fixture skill", enabled=False))
    catalog = [dict(id=1, name="Shop", machine="web-1", folder="/srv/shop", note=""),
               dict(id=2, name="Docs", machine="local", folder="/code/docs", note="")]

    scout_id = bots[1]["id"].lower()
    selected_reviewers = {}
    tool_review = {}
    def settings_for(owner):
        patch = owner == bots[0]["id"].lower()
        selected = selected_reviewers.get(owner)
        return dict(auto_mode=patch and not tool_review.get(owner, False), review_every_tool=tool_review.get(owner, False), command_reviewer="sonnet" if patch and not selected else "off",
                    reviewer_bot_id=selected, reviewer_bots=[dict(id=scout_id, name="Scout", model="opus")] if patch else [])

    class Team(BaseHTTPRequestHandler):
        def do_GET(self):
            parts = self.path.split("/")
            body = None
            if self.headers.get("Authorization") == "Bearer " + token:
                if self.path.split("?")[0] == "/api/workspace":
                    body = dict(core="qa", agents=[], templates=[{"name":"claude","supports_tool_review":True}])
                elif self.path == "/api/machines":
                    body = dict(machines=[])
                elif self.path.startswith("/api/bot-agent-settings/"):
                    body = settings_for(parts[-1].lower())
                elif self.path == "/api/project-command-rules":
                    body = [dict(id=1, bot=bots[0]["id"], agent="patch", provider="Codex", cwd="/srv/shop", command="swift test")]
                elif self.path == "/api/skillshare":
                    if not skills_online:
                        self.send_error(503)
                        return
                    body = dict(installed=True, skills=skills)
                elif self.path == "/api/projects":
                    catalog_reads.append(catalog_online)
                    if not catalog_online:
                        self.send_error(503)
                        return
                    body = dict(projects=catalog)
                elif len(parts) == 5 and parts[2] == "bots" and parts[3] in owners:
                    patch = owners[parts[3]] == "Patch"
                    body = {"exchanges": {"exchanges": []},
                            "exchanges?all=1": {"exchanges": [exchange] if patch else []},
                            "promises": {"promises": []},
                            "checkins": {"checkins": [dict(id=6, what=watch, paused=False,
                                schedule=dict(kind="ci", url="https://github.com/example/tool/pull/142"))] if patch else []}
                            }.get(parts[4])
            if body is None:
                self.send_error(404)
                return
            data = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_POST(self):
            if self.path.startswith("/api/bot-agent-settings/") and self.headers.get("Authorization") == "Bearer " + token:
                owner = self.path.rsplit("/", 1)[1]
                incoming = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if "review_every_tool" in incoming:
                    tool_review[owner] = incoming["review_every_tool"]
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(json.dumps(settings_for(owner)).encode())
                    return
                if incoming.get("reviewer_bot_id") != scout_id or owner != bots[0]["id"].lower():
                    self.send_error(400)
                    return
                selected_reviewers[owner] = scout_id
                self.send_response(200)
                self.end_headers()
                self.wfile.write(json.dumps(settings_for(owner)).encode())
                return
            if self.path == "/api/bots" and self.headers.get("Authorization") == "Bearer " + token:
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"{}")
            else:
                self.send_error(404)

        def log_message(self, *args):
            pass

    with private_workspace(source_app) as (app, home, store), ThreadingHTTPServer(("127.0.0.1", 0), Team) as server:
        preferences = home / "Library/Preferences"
        preferences.mkdir(exist_ok=True, parents=True)
        domain = plistlib.loads((app / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
        (preferences / (domain + ".plist")).write_bytes(plistlib.dumps({"appearance": appearance}))
        bots[0]["messages"] = [dict(id=str(uuid.uuid4()), role=role, content=text, createdAt=800000010 + index)
                               for index, (role, text) in enumerate((
                                   ("user", "Check the changes in this release with Scout."),
                                   ("assistant", "Scout verified the three changes. I’m watching pull request 142 for a failed check.")))]
        store.write_text(json.dumps(dict(version=2, groups=[], bots=bots)))
        Thread(target=server.serve_forever, daemon=True).start()
        try:
            catalog_online = True
            with open_workspace(app, home, "http://127.0.0.1:" + str(server.server_port), token) as window:
                wait_for("Patch in sidebar", lambda: any(label(b).startswith("Patch,") for b in buttons(window)))
                press(window, "Patch", sidebar=True)
                open_detail_section(window, "Overview")
                press_link(window, "Edit bot projects")
                shop = next(e for e in descendants(window) if label(e) == "Patch may use Shop")
                assert ax.AXUIElementPerformAction(shop, "AXPress") == 0
                press_link(window, "Finish editing projects")
                wait_for("shop selected before quit", lambda: any("web-1 · /srv/shop" in
                         (attribute(e, "AXValue"), label(e)) for e in descendants(window)))
            catalog_online = False
            with open_workspace(app, home, "http://127.0.0.1:" + str(server.server_port), token) as w:
                def element(title):
                    return next((e for e in descendants(w) if str(attribute(e, "AXValue") or "") == title
                                 or label(e) == title), None)

                wait_for("Patch sidebar row", lambda: any(label(b).startswith("Patch,") for b in buttons(w)))
                press(w, "Patch", sidebar=True)
                import Quartz
                size = ax.AXValueCreate(ax.kAXValueCGSizeType, Quartz.CGSizeMake(980, 620))
                assert ax.AXUIElementSetAttributeValue(w, "AXSize", size) == 0
                open_detail_section(w, "Overview")
                wait_for("saved project after a failed catalog read", lambda: False in catalog_reads and element("web-1 · Shop"))
                catalog_online = True
                press_link(w, "Reload bot projects")
                wait_for("selected folder after catalog recovery", lambda: element("web-1 · /srv/shop"))
                assert not element("local · /code/docs")
                press_link(w, "Edit bot projects")
                toggle = lambda: next((e for e in descendants(w) if label(e) == "Patch may use Docs"), None)
                wait_for("Docs project switch", toggle)
                assert ax.AXUIElementPerformAction(toggle(), "AXPress") == 0
                press_link(w, "Finish editing projects")
                wait_for("new project beside original assignment", lambda: element("local · /code/docs") and element("web-1 · /srv/shop"))
                press(w, "Scout", sidebar=True)
                wait_for("Scout’s empty assignment list", lambda: element("No projects selected"))
                assert not element("local · /code/docs")
                press(w, "Patch", sidebar=True)
                wait_for("Patch’s restored projects", lambda: element("web-1 · /srv/shop") and element("local · /code/docs"))
                primary = [element(title) for title in ("Overview", "Approvals", "Routines")]
                positions = [ax.AXValueGetValue(attribute(e, "AXPosition"), ax.kAXValueCGPointType, None)[1] for e in primary]
                assert max(p.y for p in positions) - min(p.y for p in positions) <= 1
                assert positions[0].x < positions[1].x < positions[2].x
                def frame(e):
                    position = ax.AXValueGetValue(attribute(e, "AXPosition"), ax.kAXValueCGPointType, None)[1]
                    size = ax.AXValueGetValue(attribute(e, "AXSize"), ax.kAXValueCGSizeType, None)[1]
                    return position.x, position.y, size.width

                shop = frame(element("web-1 · /srv/shop"))
                docs = frame(element("local · /code/docs"))
                right = frame(w)[0] + frame(w)[2] - 14
                if shop[0] + shop[2] + 5 + docs[2] <= right:
                    assert abs(shop[1] - docs[1]) <= 1 and shop[0] != docs[0], (shop, docs)
                else:
                    assert docs[1] > shop[1] and abs(shop[0] - docs[0]) <= 1, (shop, docs)
                open_detail_section(w, "Routines")
                wait_for("failed skill read offers retry", lambda: element("Reload shared skills"))
                skills_online = True
                press_link(w, "Reload shared skills")
                wait_for("shared skill names", lambda: element("Changelog") and element(long_skill))
                assert not element("Disabled fixture skill") and not element("Test runner")
                changelog = frame(element("Changelog"))
                review = frame(element("Code review"))
                long_tag = frame(element(long_skill))
                assert abs(changelog[1] - review[1]) <= 1 and long_tag[1] > review[1]
                left, _, width = frame(w)
                assert left <= long_tag[0] and long_tag[0] + long_tag[2] <= left + width
                press_link(w, "Show 1 more")
                wait_for("expanded skills", lambda: element("Test runner"))
                press_link(w, "Show fewer skills")
                wait_for("collapsed skills", lambda: not element("Test runner"))
                press_link(w, "Manage shared skills")
                wait_for("Skills section selected", lambda: attribute(element("More Details sections"), "AXValue") == "Skills")
                open_detail_section(w, "Approvals")
                wait_for("Patch approval controls", lambda: element("New sessions: Auto") and element("Command reviewer: Claude Sonnet"))
                wait_for("Patch’s scoped command", lambda: element("swift test"))
                press_link(w, "Edit approval controls")
                wait_for("approval editor", lambda: element("Auto mode"))
                popup = next(e for e in descendants(w) if attribute(e, "AXIdentifier") == "bot.commandReviewer"
                             and attribute(e, "AXRole") == "AXPopUpButton")
                assert ax.AXUIElementPerformAction(popup, "AXPress") == 0
                def choose_scout():
                    option = next((e for e in descendants(popup) if attribute(e, "AXRole") == "AXMenuItem"
                                   and "Scout" in label(e)), None)
                    return option and ax.AXUIElementPerformAction(option, "AXPress") == 0
                wait_for("choose Scout as command reviewer", choose_scout)
                wait_for("Patch’s selected reviewer", lambda: element("Command reviewer: Scout · opus"))
                def switch(identifier):
                    return next((e for e in descendants(w) if attribute(e, "AXIdentifier") == identifier
                                 and attribute(e, "AXRole") in ("AXCheckBox", "AXSwitch")), None)
                wait_for("review every tool switch", lambda: switch("bot.reviewEveryTool"))
                assert ax.AXUIElementPerformAction(switch("bot.reviewEveryTool"), "AXPress") == 0
                wait_for("per-call policy enabled", lambda: element("New sessions: Ask every tool"))
                assert tool_review == {bots[0]["id"].lower(): True}
                assert not attribute(switch("bot.autoMode"), "AXEnabled")
                press_link(w, "Finish editing approval controls")
                press(w, "Scout", sidebar=True)
                wait_for("Scout approval controls", lambda: element("New sessions: Standard") and element("Command reviewer: Off"))
                wait_for("Scout’s empty scoped rules", lambda: element("No saved command rules"))
                assert not element("swift test")
                press(w, "Patch", sidebar=True)
                wait_for("restored Patch rule", lambda: element("swift test"))
                wait_for("restored Patch policy", lambda: element("New sessions: Ask every tool"))
                for name in ("Model", "Media", "Team"):
                    open_detail_section(w, name)
                wait_for("Patch’s scheduled CI watch", lambda: element(watch))
                def right_edge(e):
                    x = ax.AXValueGetValue(attribute(e, "AXPosition"), ax.kAXValueCGPointType, None)[1].x
                    width = ax.AXValueGetValue(attribute(e, "AXSize"), ax.kAXValueCGSizeType, None)[1].width
                    return x + width

                assert right_edge(element("More Details sections")) <= right_edge(w) and right_edge(element("Close")) <= right_edge(w)
                wait_for("completed exchange", lambda: element("Recent exchanges"))
                disclosure = next(e for e in descendants(w) if "Patch → Scout" in label(e))
                assert ax.AXUIElementPerformAction(disclosure, "AXPress") == 0
                wait_for("completed handoff text", lambda: element(exchange["text"]))
                assert not element("Stop open exchanges")
                press(w, "Scout", sidebar=True)
                wait_for("Scout’s empty activity", lambda: element("No open handoffs, check-ins or promises."))
                assert not element(watch) and not element(exchange["text"])
                press(w, "Close")
                wait_for("Details opener", lambda: element("Details"))
                press(w, "Details")
                wait_for("restored Team panel", lambda: element("No open handoffs, check-ins or promises."))
                press(w, "Patch", sidebar=True)
                wait_for("restored CI watch", lambda: element(watch))
                print(f"Verified the three primary sections on one row, all four More destinations, saved per-bot folders after a failed catalog read and retry, wrapping projects and skills, skill retry and expansion, completed exchanges, CI watches and reopening Details in {appearance}.")
        finally:
            server.shutdown()


if __name__ == "__main__":
    if not ax.AXIsProcessTrusted():
        raise SystemExit("This test needs macOS Accessibility access.")
    if len(sys.argv) == 3 and sys.argv[1] == "--group-restart":
        group_restart(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--activity-decisions":
        activity_decisions(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--inbox-proposals":
        activity_decisions(Path(sys.argv[2]).resolve(strict=True), proposals_only=True)
    elif len(sys.argv) == 3 and sys.argv[1] == "--named-review":
        activity_decisions(Path(sys.argv[2]).resolve(strict=True), named_review_only=True)
    elif len(sys.argv) == 3 and sys.argv[1] == "--team-pack":
        for appearance in ("Dark", "Light"):
            team_pack(Path(sys.argv[2]).resolve(strict=True), appearance)
    elif len(sys.argv) == 3 and sys.argv[1] == "--team":
        for appearance in ("Dark", "Light"):
            team_inspector(Path(sys.argv[2]).resolve(strict=True), appearance)
    elif len(sys.argv) == 3 and sys.argv[1] == "--steer-reopen":
        steer_reopen(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--session-usage":
        session_usage_overview(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 4 and sys.argv[1] == "--helper-screenshots":
        import platform
        if tuple(int(n) for n in platform.mac_ver()[0].split(".")[:2]) < (14, 4):
            raise SystemExit("Capturing the private test window requires macOS 14.4 or later.")
        source_app = Path(sys.argv[2]).resolve(strict=True)
        destination = Path(sys.argv[3]).resolve()
        destination.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="SwarmHub-capture-") as scratch:
            library = Path(scratch) / "capture.dylib"
            subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc", str(Path(__file__).with_name("qa-window-capture.m")),
                            "-framework", "AppKit", "-framework", "ScreenCaptureKit", "-o", str(library)], check=True)
            subprocess.run(["codesign", "--force", "--sign", "-", library], check=True)
            for appearance in ("Dark", "Light"):
                live_terminals(source_app, destination, appearance, library)
    elif len(sys.argv) == 3 and sys.argv[1] == "--sidebar-reveal":
        live_terminals(Path(sys.argv[2]).resolve(strict=True), long_sidebar=True)
    elif len(sys.argv) == 3 and sys.argv[1] == "--terminals":
        live_terminals(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--sample-stories":
        sample_stories(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--sample-workspace":
        sample_workspace(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--sidebar-focus":
        sidebar_focus(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--activity":
        workspace_activity(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--window-unread":
        window_unread(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--message-search":
        message_search(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--media-reopen":
        media_reopen(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 4 and sys.argv[1] == "--pages":
        workspace_pages(Path(sys.argv[2]).resolve(strict=True), Path(sys.argv[3]).resolve(strict=True))
    elif len(sys.argv) == 4 and sys.argv[1] == "--ai-inventory":
        ai_inventory(Path(sys.argv[2]).resolve(strict=True), Path(sys.argv[3]).resolve(strict=True))
    elif len(sys.argv) == 2:
        main(int(sys.argv[1]))
    else:
        raise SystemExit("Usage: chat-window-smoke.py QA_PROCESS_ID | (--sample-stories | --sample-workspace | --sidebar-focus | --session-usage | --terminals | --sidebar-reveal | --group-restart | --media-reopen | --message-search | --steer-reopen | --team-pack | --team | --activity-decisions | --window-unread | --activity) /path/to/SwarmHub.app | (--pages | --ai-inventory) APP SERVICE | --helper-screenshots APP OUTPUT_DIRECTORY")
