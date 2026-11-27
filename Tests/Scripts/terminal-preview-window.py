#!/usr/bin/python3
"""Resize a real bot's terminal mirror through the private SwarmHub window on a logged-in Mac."""
import json
from pathlib import Path
import re
import runpy
import secrets
import select
import subprocess
import sys
import tempfile
import urllib.request
import uuid

import ApplicationServices as ax


def run(app, bridge, core):
    driver = runpy.run_path(str(Path(__file__).with_name("chat-window-smoke.py")))
    attr, label, walk = driver["attribute"], driver["label"], driver["descendants"]
    wait, press = driver["wait_for"], driver["press"]
    with tempfile.TemporaryDirectory(prefix="sw-pane-", dir="/tmp") as tmp, driver["private_workspace"](app) as (bundle, home, store):
        root = Path(tmp)
        for folder in ("cfg/herdr-core/templates", "run", "state", "agents"):
            (root / folder).mkdir(parents=True)
        (root / "screen.py").write_text(
            "import os, time\n"
            "for frame in range(240):\n"
            "    rows = os.get_terminal_size().lines\n"
            "    print(f'\\033[1;1HPreview fixture with a long line that wraps across several rows in a narrow panel.\\033[{rows};1HLAST-ROW-{frame}', end='', flush=True)\n"
            "    time.sleep(0.5)\n")
        (root / "cfg/herdr-core/templates/fixture.md").write_text(
            f"---\ndescription: Terminal preview fixture\ncommand: /usr/bin/python3 {root / 'screen.py'}\n---\n")
        env = dict(HOME=tmp, PATH=str(core.parent) + ":/usr/bin:/bin", HC_SESSION=root.name, HC_SOCKET=str(root / "core.sock"),
                   XDG_CONFIG_HOME=str(root / "cfg"), XDG_STATE_HOME=str(root / "state"), XDG_RUNTIME_DIR=str(root / "run"))
        token = secrets.token_hex(32)
        subprocess.run([core, "server", "start"], env=env, cwd=root, check=True)
        service = None
        try:
            service = subprocess.Popen([bridge], cwd=root, stdout=subprocess.PIPE, text=True,
                                       env=dict(env, SWARMHUB_PORT="0", SWARMHUB_ACCESS_TOKEN=token,
                                                SWARMHUB_DATA_DIR=str(root / "db"), SWARMHUB_AGENT_CWD=str(root / "agents")))
            assert select.select([service.stdout], [], [], 10)[0], "Workspace did not start"
            origin = re.search(r"http://127\.0\.0\.1:\d+", service.stdout.readline()).group()

            def api(path, body=None):
                data = None if body is None else json.dumps(body).encode()
                headers = {"Authorization": "Bearer " + token, "Content-Type": "application/json", "Origin": origin}
                with urllib.request.urlopen(urllib.request.Request(origin + path, data=data, headers=headers), timeout=8) as response:
                    return json.load(response)

            owner = str(uuid.uuid4())
            agent = api("/api/agents", dict(name="mirrorqa-" + owner[:6], template="fixture", warm=True))
            route = f"/api/agents/{agent['address']}/{agent['created_ms']}/geometry"
            geometry = api(route)
            store.write_text(json.dumps(dict(version=2, bots=[dict(id=owner, name="MirrorQA", backend="Herdr", messages=[])])))
            with driver["open_workspace"](bundle, home, origin, token) as window:
                def button(title):
                    return next((b for b in driver["buttons"](window) if label(b) == title), None)

                def select_owner():
                    if button("Preview MirrorQA in Details"):
                        return True
                    row = next((b for b in driver["buttons"](window) if "MirrorQA" in label(b).split(", ")), None)
                    if row:
                        press(window, label(row))
                        return True

                wait("bot in the sidebar", select_owner)
                wait("live terminal action", lambda: button("Preview MirrorQA in Details"))
                press(window, "Preview MirrorQA in Details")
                wait("docked terminal", lambda: button("Back to Details"))

                def last_row():
                    for element in walk(window):
                        text = str(attr(element, "AXValue") or label(element))
                        match = re.search(r"LAST-ROW-(\d+)", text)
                        if match:
                            return int(match[1])
                    return -1

                def text_size():
                    element = next(n for n in walk(window) if attr(n, "AXRole") == "AXStaticText" and
                                   "Preview fixture" in str(attr(n, "AXValue") or ""))
                    ok, size = ax.AXValueGetValue(attr(element, "AXSize"), ax.kAXValueCGSizeType, None)
                    assert ok
                    return size

                wait("last terminal row", lambda: last_row() >= 0, seconds=20)
                divider = [n for n in walk(window) if attr(n, "AXRole") == "AXSplitter"][-1]
                narrow, position, frame = text_size(), attr(divider, "AXValue"), last_row()
                assert ax.AXUIElementSetAttributeValue(divider, "AXValue", position - 96) == 0
                wait("wider text with fewer wrapped lines", lambda: text_size().width > narrow.width + 20 and text_size().height < narrow.height)
                wide = text_size()
                wait("new output on the last row", lambda: last_row() > frame)
                assert api(route) == geometry
                assert ax.AXUIElementSetAttributeValue(divider, "AXValue", position) == 0
                wait("restored width", lambda: abs(text_size().width - narrow.width) < 3)
                def mode(name):
                    option = next(n for n in walk(window) if label(n) == name and attr(n, "AXRole") in ("AXButton", "AXRadioButton"))
                    assert ax.AXUIElementPerformAction(option, "AXPress") == 0
                mode("Fit terminal")
                wait("original grid", lambda: any(attr(n, "AXRole") == "AXWebArea" for n in walk(window)))
                mode("Readable")
                wait("resumed text preview", lambda: last_row() > frame)
                assert api(route) == geometry
                press(window, "Back to Details")
                print(f"Verified live output at {narrow.width:.0f} and {wide.width:.0f} points. "
                      f"The terminal kept {geometry['cols']} columns and {geometry['rows']} rows.")
        finally:
            if service is not None:
                service.terminate()
                service.wait(timeout=10)
            subprocess.run([core, "server", "stop"], env=env, cwd=root, check=True)


if __name__ == "__main__":
    if len(sys.argv) != 4:
        raise SystemExit("Usage: terminal-preview-window.py SwarmHub.app swarmhub-herdr herdr-core")
    run(*(Path(arg).resolve(strict=True) for arg in sys.argv[1:]))
