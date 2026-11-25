#!/usr/bin/env python3
"""Drive the native SwarmHub QA window on a logged-in Mac with PyObjC and Accessibility access."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
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



def group_restart(source_app):
    from AppKit import NSRunningApplication

    with tempfile.TemporaryDirectory(prefix="SwarmHub-group-qa-") as scratch:
        base = Path(scratch)
        app = base / "GroupQA.app"
        subprocess.run(["ditto", source_app, app], check=True)
        info = app / "Contents/Info.plist"
        plist = plistlib.loads(info.read_bytes())
        plist["CFBundleIdentifier"] = "com.konrad.agentapp.group-qa." + uuid.uuid4().hex
        info.write_bytes(plistlib.dumps(plist))
        subprocess.run(["codesign", "--force", "--sign", "-", app], check=True)

        home = base / "home"
        store = home / "Library/Application Support/AgentApp/store.json"
        store.parent.mkdir(parents=True)
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
            environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                               SWARMHUB_DISABLE_UPDATES="1", SWARMHUB_SERVICE_HOME=str(home))
            process = subprocess.Popen([app / "Contents/MacOS/AgentApp", "-setupState", "skipped",
                                        "-herdrBaseURL", "http://127.0.0.1:1"], env=environment)
            try:
                application = ax.AXUIElementCreateApplication(process.pid)
                windows = lambda: attribute(application, "AXWindows") or []
                wait_for("private workspace", windows, seconds=15)
                window = windows()[0]
                def group_button():
                    return next((b for b in buttons(window) if "Release crew" in label(b)), None)
                wait_for("group in sidebar", group_button)
                if ax.AXUIElementPerformAction(group_button(), "AXPress") != 0:
                    raise RuntimeError("Could not open the group")
                yield window
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


if __name__ == "__main__":
    if not ax.AXIsProcessTrusted():
        raise SystemExit("This test needs macOS Accessibility access.")
    if len(sys.argv) == 3 and sys.argv[1] == "--group-restart":
        group_restart(Path(sys.argv[2]).resolve(strict=True))
    elif len(sys.argv) == 2:
        main(int(sys.argv[1]))
    else:
        raise SystemExit("Usage: chat-window-smoke.py QA_PROCESS_ID | --group-restart /path/to/SwarmHub.app")
