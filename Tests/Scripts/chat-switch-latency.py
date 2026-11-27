#!/usr/bin/env python3
"""Time Next Chat until its newest message is inside the native scroll viewport."""
import argparse
import json
import math
from pathlib import Path
import runpy
import shutil
import subprocess
import time
from types import SimpleNamespace
import uuid

import ApplicationServices as ax
import Quartz

window_qa = SimpleNamespace(**runpy.run_path(str(Path(__file__).with_name("chat-window-smoke.py"))))
attribute = window_qa.attribute
ROSTER = 50
HISTORY = 96


def frame_code(index):
    return str(715100 + index)


def seed(store, *, verify_frames=False):
    def identifier(name):
        return str(uuid.uuid5(uuid.NAMESPACE_URL, "urn:swarmhub:chat-switch:" + name))

    bots = []
    for index in range(ROSTER):
        name = f"Bench{index:02d}"
        messages = [{
            "id": identifier(f"{name}/{row}"), "role": "user", "createdAt": 799000000 + row,
            "content": f"{name} row {row}. " + "Earlier conversation. " * 3,
        } for row in range(HISTORY)]
        if verify_frames:
            messages[-1]["content"] = latest(index) + " Frame " + frame_code(index)
        bots.append({"id": identifier(name), "name": name, "backend": "Mock", "messages": messages})
    store.write_text(json.dumps({"version": 2, "bots": bots, "groups": []}))


def indexed(element, path=()):
    yield element, path
    for index, child in enumerate(attribute(element, "AXChildren") or ()):
        yield from indexed(child, path + (index,))


def follow(element, path):
    for index in path:
        children = attribute(element, "AXChildren") or ()
        if index >= len(children):
            return None
        element = children[index]
    return element


def latest(index):
    return f"Bench{index:02d} row {HISTORY - 1}."


def row_paths(window):
    for area, area_path in indexed(window):
        if attribute(area, "AXRole") == "AXScrollArea":
            for row, row_path in indexed(area):
                if attribute(row, "AXRole") in ("AXStaticText", "AXTextArea"):
                    if str(attribute(row, "AXValue") or "").startswith(latest(0)):
                        return area_path, row_path
    return None


def press_next(pid):
    for down in (True, False):
        event = Quartz.CGEventCreateKeyboardEvent(None, 125, down)
        Quartz.CGEventSetFlags(event, Quartz.kCGEventFlagMaskAlternate | Quartz.kCGEventFlagMaskCommand)
        Quartz.CGEventPostToPid(pid, event)


def verify_draft(window, previous, replacement=None):
    field = next((e for e in window_qa.descendants(window)
                  if attribute(e, "AXRole") == "AXTextArea" and window_qa.label(e) == "Message"), None)
    if field is None or attribute(field, "AXValue") != previous:
        raise RuntimeError("The selected chat did not restore its draft")
    if replacement:
        selected = ax.AXValueCreate(ax.kAXValueCFRangeType, (0, len(previous)))
        if ax.AXUIElementSetAttributeValue(field, "AXSelectedTextRange", selected) != 0:
            raise RuntimeError("Could not select the previous draft")
        window_qa.enter_draft(field, replacement)


def summary(samples):
    values = sorted(samples)
    return {name: round(values[math.ceil(len(values) * fraction) - 1], 1)
            for name, fraction in (("p50", .5), ("p95", .95), ("maximum", 1))}


class FrameVerifier:
    def __init__(self, directory, report):
        self.snapshot = directory / "chat-window.png"
        self.trigger = directory / "chat-window.png.request"
        self.failure = report.with_suffix(".failed-frame.png")
        self.observations = []
        library = directory / "capture.dylib"
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-fobjc-arc",
                        str(Path(__file__).with_name("qa-window-capture.m")), "-framework", "Cocoa",
                        "-framework", "ScreenCaptureKit", "-o", library], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", library], check=True)
        self.environment = {"DYLD_INSERT_LIBRARIES": str(library), "SWARMHUB_QA_SNAPSHOT_PATH": str(self.snapshot)}

    @staticmethod
    def rectangle(element):
        position = ax.AXValueGetValue(attribute(element, "AXPosition"), ax.kAXValueCGPointType, None)[1]
        extent = ax.AXValueGetValue(attribute(element, "AXSize"), ax.kAXValueCGSizeType, None)[1]
        return position.x, position.y, extent.width, extent.height

    def check(self, window, area, index, start):
        from Foundation import NSURL
        import Vision

        # Exclude the sidebar, which also previews the last message. Vision measures y from the bottom.
        wx, wy, ww, wh = self.rectangle(window)
        x, y, w, h = self.rectangle(area)
        left, right = max(0, (x - wx + 3) / ww), min(1, (x + w - wx - 3) / ww)
        top, bottom = max(0, (y - wy + 4) / wh), min(1, (y + h - wy - 4) / wh)
        for attempt in range(1, 4):
            self.trigger.touch()
            window_qa.wait_for("image of the private Mac window",
                               lambda: self.snapshot.exists() and not self.trigger.exists(), seconds=12)
            captured_ms = round((time.monotonic() - start) * 1000, 1)
            request = Vision.VNRecognizeTextRequest.alloc().init()
            request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
            request.setUsesLanguageCorrection_(False)
            request.setRegionOfInterest_(((left, 1 - bottom), (right - left, bottom - top)))
            handler = Vision.VNImageRequestHandler.alloc().initWithURL_options_(
                NSURL.fileURLWithPath_(str(self.snapshot)), {})
            ok, error = handler.performRequests_error_([request], None)
            if not ok:
                raise RuntimeError(f"Could not read the captured chat: {error}")
            for observation in request.results():
                candidates = observation.topCandidates_(1)
                if candidates and frame_code(index) in candidates[0].string():
                    self.observations.append({"bot": index, "captured_ms": captured_ms, "attempt": attempt})
                    return
        shutil.copyfile(self.snapshot, self.failure)
        raise RuntimeError(f"Missing rendered message for {latest(index)} See {self.failure}")


def measure(window, passes, frames=None):
    pid = ax.AXUIElementGetPid(window, None)[1]
    window_qa.wait_for("fleet sidebar", lambda: any(window_qa.label(b).startswith("Bench00,")
                                                    for b in window_qa.buttons(window)))
    window_qa.press(window, "Bench00", sidebar=True)
    window_qa.wait_for("initial transcript", lambda: row_paths(window))
    area_path, row_path = row_paths(window)

    def visible(index):
        area = follow(window, area_path)
        row = follow(area, row_path) if area is not None else None
        if row is None or not str(attribute(row, "AXValue") or "").startswith(latest(index)):
            return False
        viewport, frame = window_qa.bounds(area), window_qa.bounds(row)
        return viewport and frame and frame[0] < viewport[1] and frame[1] > viewport[0]

    window_qa.wait_for("first visible row", lambda: visible(0))
    overhead = []
    for _ in range(12):
        start = time.monotonic()
        if not visible(0):
            raise RuntimeError("Initial row moved outside the viewport")
        overhead.append((time.monotonic() - start) * 1000)
    timings = []
    draft = ""
    for step in range(ROSTER * passes):
        index = (step + 1) % ROSTER
        start = time.monotonic()
        press_next(pid)
        while not visible(index):
            if time.monotonic() - start > 10:
                raise RuntimeError(f"Switch {step + 1} never showed {latest(index)}")
            time.sleep(.004)
        timings.append(round((time.monotonic() - start) * 1000, 2))
        if frames is not None:
            frames.check(window, follow(window, area_path), index, start)
        if index == 1:
            replacement = f"Bench01 draft, pass {step // ROSTER + 1}"
            verify_draft(window, draft, replacement)
            draft = replacement
        elif index == 2:
            verify_draft(window, "")
    return {"bots": ROSTER, "messages_per_bot": HISTORY, "switches": len(timings),
            "observations_ms": timings, "observer_ms": overhead, "summary_ms": summary(timings)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("report", type=Path)
    parser.add_argument("--passes", type=int, default=4)
    parser.add_argument("--verify-frames", action="store_true", help="Check the last message in captured window pixels")
    parser.add_argument("--appearance", choices=("Dark", "Light"))
    args = parser.parse_args()
    if args.passes < 1:
        parser.error("--passes must be positive")
    with window_qa.private_workspace(args.app) as (app, home, store):
        seed(store, verify_frames=args.verify_frames)
        frames = FrameVerifier(home, args.report) if args.verify_frames else None
        environment = frames.environment if frames else None
        with window_qa.open_workspace(app, home, extra_environment=environment, appearance=args.appearance) as window:
            result = measure(window, args.passes, frames)
        if frames:
            result["rendered_frames"] = frames.observations
            result["capture_summary_ms"] = summary([item["captured_ms"] for item in frames.observations])
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(result["summary_ms"])
