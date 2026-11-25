#!/usr/bin/env python3
"""Drive the native SwarmHub QA window on a logged-in Mac with PyObjC and Accessibility access."""

import re
import subprocess
import sys
import time

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
    if not ax.AXIsProcessTrusted():
        raise SystemExit("This test needs macOS Accessibility access.")
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


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python3 chat-window-smoke.py QA_PROCESS_ID")
    main(int(sys.argv[1]))
