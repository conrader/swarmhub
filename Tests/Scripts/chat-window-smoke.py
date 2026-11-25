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
from threading import Thread
import time
import uuid

import ApplicationServices as ax


def attribute(element, key):
    return ax.AXUIElementCopyAttributeValue(element, key, None)[1]


def descendants(element):
    yield element
    for child in attribute(element, "AXChildren") or ():
        yield from descendants(child)


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
def open_workspace(app, home, address="http://127.0.0.1:1", token="", extra_environment=None):
    from AppKit import NSRunningApplication

    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                       SWARMHUB_DISABLE_UPDATES="1", SWARMHUB_SERVICE_HOME=str(home), SWARMHUB_HERDR_TOKEN=token)
    environment.update(extra_environment or {})
    process = subprocess.Popen([app / "Contents/MacOS/AgentApp", "-setupState", "skipped",
                                "-herdrBaseURL", address], env=environment)
    try:
        application = ax.AXUIElementCreateApplication(process.pid)
        windows = lambda: attribute(application, "AXWindows") or []
        running = lambda: NSRunningApplication.runningApplicationWithProcessIdentifier_(process.pid)
        wait_for("private app launch", lambda: running() and running().isFinishedLaunching(), seconds=15)
        running().activateWithOptions_(3)
        if not windows():
            # A direct executable launch can be running without an open-document event.
            subprocess.run(["open", "-a", str(app)], check=True)
        wait_for("private workspace", windows, seconds=15)
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
    import Quartz

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
                        if field is None or ax.AXUIElementSetAttributeValue(field, "AXFocused", True) != 0:
                            raise RuntimeError("Could not focus the foreground chat composer")
                        pid = ax.AXUIElementGetPid(field, None)[1]
                        for pressed in (True, False):
                            event = Quartz.CGEventCreateKeyboardEvent(None, 0, pressed)
                            Quartz.CGEventKeyboardSetUnicodeString(event, len(draft), draft)
                            Quartz.CGEventPostToPid(pid, event)
                        wait_for("foreground draft", lambda: attribute(composer(), "AXValue") == draft)
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

            def enter(text):
                field = composer()
                if ax.AXUIElementSetAttributeValue(field, "AXFocused", True) != 0:
                    raise RuntimeError("Could not focus the composer")
                pid = ax.AXUIElementGetPid(field, None)[1]
                for down in (True, False):
                    event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
                    Quartz.CGEventKeyboardSetUnicodeString(event, len(text), text)
                    Quartz.CGEventPostToPid(pid, event)

            press(window, reader["name"], sidebar=True)
            enter("Keep my draft")
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
                    if ax.AXUIElementSetAttributeValue(field, "AXFocused", True) != 0:
                        raise RuntimeError("Could not focus the composer")
                    text = f"Reply while {state}."
                    for down in (True, False):
                        event = Quartz.CGEventCreateKeyboardEvent(None, 0, down)
                        Quartz.CGEventKeyboardSetUnicodeString(event, len(text), text)
                        Quartz.CGEventPostToPid(pid, event)
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

        class Catalog(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path.split("?")[0] != "/api/workspace":
                    self.send_error(404)
                    return
                if offline:
                    self.send_error(503)
                    return
                templates = [{"name": "qa-claude", "runtime": {"harness": "Claude Code", "display_name": "Claude"}}]
                if registration.is_file():
                    templates.append({"name": "swarmhub-antigravity",
                                      "runtime": {"harness": "Antigravity CLI", "display_name": "Gemini"}})
                data = json.dumps({"core": "qa", "agents": [], "templates": templates}).encode()
                self.send_response(200)
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
                    executable = installed / "agy"
                    executable.write_text('#!/bin/sh\ntouch "$(dirname "$0")/unexpected-launch"\n')
                    executable.chmod(0o700)
                    press(settings, "Scan again")
                    wait_for("newly installed Antigravity", lambda: any(label(b) == "Add Antigravity CLI" for b in buttons(settings)))
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
            print("Antigravity discovered, registered offline, and available in the original bot picker after one rescan.")


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
                    pid = ax.AXUIElementGetPid(field, None)[1]
                    for key in [125] * down + [36]:  # Down Arrow, then Return.
                        for pressed in (True, False):
                            event = Quartz.CGEventCreateKeyboardEvent(None, key, pressed)
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


def team_inspector(source_app, appearance):
    token = uuid.uuid4().hex
    bots = [dict(id=str(uuid.uuid4()), name=name, title=title, backend="Herdr")
            for name, title in (("Patch", "Releases and pull requests"), ("Scout", "Build verification"))]
    owners = {b["id"]: b["name"] for b in bots}
    watch = "Watch public PR 142"
    exchange = dict(id=7, kind="ask", state="answered", text="Verified three changes for the release.",
                    **{"from": {"name": "Patch"}, "to": {"name": "Scout"}})

    class Team(BaseHTTPRequestHandler):
        def do_GET(self):
            parts = self.path.split("/")
            body = None
            if self.headers.get("Authorization") == "Bearer " + token:
                if self.path.split("?")[0] == "/api/workspace":
                    body = dict(core="qa", agents=[], templates=[])
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
            with open_workspace(app, home, "http://127.0.0.1:" + str(server.server_port), token) as w:
                def element(title):
                    return next((e for e in descendants(w) if str(attribute(e, "AXValue") or "") == title
                                 or label(e) == title), None)

                wait_for("Patch sidebar row", lambda: any(label(b).startswith("Patch,") for b in buttons(w)))
                press(w, "Patch", sidebar=True)
                if not element("Team"):
                    press(w, "Details")
                press(w, "Team")
                import Quartz
                size = ax.AXValueCreate(ax.kAXValueCGSizeType, Quartz.CGSizeMake(980, 620))
                assert ax.AXUIElementSetAttributeValue(w, "AXSize", size) == 0
                wait_for("Patch’s scheduled CI watch", lambda: element(watch))
                def right_edge(e):
                    x = ax.AXValueGetValue(attribute(e, "AXPosition"), ax.kAXValueCGPointType, None)[1].x
                    width = ax.AXValueGetValue(attribute(e, "AXSize"), ax.kAXValueCGSizeType, None)[1].width
                    return x + width

                assert right_edge(element("Media")) <= right_edge(w) and right_edge(element("Close")) <= right_edge(w)
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
                print("Verified the Team tab, completed exchanges, CI watches, bot switching and reopening Details.")
        finally:
            server.shutdown()


if __name__ == "__main__":
    if not ax.AXIsProcessTrusted():
        raise SystemExit("This test needs macOS Accessibility access.")
    if len(sys.argv) == 3 and sys.argv[1] == "--group-restart":
        group_restart(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--team":
        for appearance in ("Dark", "Light"):
            team_inspector(Path(sys.argv[2]).resolve(strict=True), appearance)
    elif len(sys.argv) == 3 and sys.argv[1] == "--steer-reopen":
        steer_reopen(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--activity":
        workspace_activity(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--window-unread":
        window_unread(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--message-search":
        message_search(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--media-reopen":
        media_reopen(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 4 and sys.argv[1] == "--ai-inventory":
        ai_inventory(Path(sys.argv[2]).resolve(strict=True), Path(sys.argv[3]).resolve(strict=True))
    elif len(sys.argv) == 2:
        main(int(sys.argv[1]))
    else:
        raise SystemExit("Usage: chat-window-smoke.py QA_PROCESS_ID | (--group-restart | --media-reopen | --message-search | --steer-reopen | --team | --window-unread | --activity) /path/to/SwarmHub.app | --ai-inventory APP SERVICE")
