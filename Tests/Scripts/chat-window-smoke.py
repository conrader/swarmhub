#!/usr/bin/env python3
"""Drive the native SwarmHub QA window on a logged-in Mac with PyObjC and Accessibility access."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import re
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
def open_workspace(app, home, address="http://127.0.0.1:1", token=""):
    from AppKit import NSRunningApplication

    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                       SWARMHUB_DISABLE_UPDATES="1", SWARMHUB_SERVICE_HOME=str(home), SWARMHUB_HERDR_TOKEN=token)
    process = subprocess.Popen([app / "Contents/MacOS/AgentApp", "-setupState", "skipped",
                                "-herdrBaseURL", address], env=environment)
    try:
        application = ax.AXUIElementCreateApplication(process.pid)
        windows = lambda: attribute(application, "AXWindows") or []
        wait_for("private workspace", windows, seconds=15)
        instance = NSRunningApplication.runningApplicationWithProcessIdentifier_(process.pid)
        instance.activateWithOptions_(3)
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


if __name__ == "__main__":
    if not ax.AXIsProcessTrusted():
        raise SystemExit("This test needs macOS Accessibility access.")
    if len(sys.argv) == 3 and sys.argv[1] == "--group-restart":
        group_restart(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 3 and sys.argv[1] == "--media-reopen":
        media_reopen(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 2:
        main(int(sys.argv[1]))
    else:
        raise SystemExit("Usage: chat-window-smoke.py QA_PROCESS_ID | (--group-restart | --media-reopen) /path/to/SwarmHub.app")
