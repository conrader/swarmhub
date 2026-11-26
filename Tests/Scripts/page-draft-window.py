#!/usr/bin/python3
"""Review two revisions through a private Mac window, Herdr Core and a scripted CLI."""
import json
import os
from pathlib import Path
import re
import runpy
import secrets
import select
import shlex
import subprocess
import sys
import tempfile
import urllib.request
import uuid

INITIAL = {"title": "Release notes", "markdown": "- Screenshots stay in the conversation.\n- Review permissions in the Inbox."}
REVISED = {"title": "Release notes", "markdown": "- Chat screenshots and Inbox approvals."}
SHORTEN = "Make this Page draft shorter and return a revised draft for review."
APPROVE = "I approve the wording of this Page draft."
START = "Prepare release notes for this review test."


def provider():
    settings = json.loads(sys.argv[sys.argv.index("--settings") + 1])
    stop = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
    def status(value):
        print("\x1b]7501;state=" + value + "\x1b\\", end="", flush=True)
    status("idle")
    while True:
        chunk = os.read(0, 65536)
        if not chunk:
            return
        while select.select([0], [], [], 0.2)[0]:
            more = os.read(0, 65536)
            if not more:
                break
            chunk += more
        prompt = chunk.decode().replace("\r", "")
        if SHORTEN in prompt or APPROVE in prompt:
            quoted = re.search(r'In reply to “(\{[^\n]+\})”', prompt)
            assert quoted, "missing selected Page"
            selected = json.loads(quoted.group(1))
            assert selected == (INITIAL if SHORTEN in prompt else REVISED), "wrong Page revision"
            answer = REVISED if SHORTEN in prompt else None
        elif START in prompt:
            answer = INITIAL
        else:
            continue
        status("working")
        reply = "```page-draft\n" + json.dumps(answer) + "\n```" if answer else "Approved wording received."
        subprocess.run(["/bin/sh", "-c", stop], check=True, input=json.dumps({
            "hook_event_name": "Stop", "turn_id": str(uuid.uuid4()), "last_assistant_message": reply}).encode())
        status("done")


def run(app, bridge, core):
    driver = runpy.run_path(str(Path(__file__).with_name("chat-window-smoke.py")))
    attr = driver["attribute"]
    wait, press = driver["wait_for"], driver["press"]
    with tempfile.TemporaryDirectory(prefix="sw-page-", dir="/tmp") as temporary, driver["private_workspace"](app) as (bundle, home, store):
        root = Path(temporary)
        for folder in ("state", "run", "config/herdr-core/templates", "agents"):
            (root / folder).mkdir(parents=True)
        provider_path = root / "page-cli"
        provider_path.symlink_to(Path(__file__).resolve())
        template = root / "config/herdr-core/templates/review.md"
        template.write_text("---\ndescription: Page review fixture\ncommand: SWARMHUB_CLAUDE_BIN=" +
                            shlex.quote(str(provider_path)) + " " + shlex.quote(str(bridge)) +
                            " run-claude --model fixture\nstop: ctrl+c\n---\n")
        env = dict(HOME=temporary, PATH="/usr/bin:/bin", HC_SOCKET=str(root / "core.sock"),
                   HC_SESSION=root.name, XDG_RUNTIME_DIR=str(root / "run"), XDG_CONFIG_HOME=str(root / "config"),
                   XDG_STATE_HOME=str(root / "state"), LANG="en_US.UTF-8")
        token = secrets.token_hex(32)
        subprocess.run([core, "server", "start"], env=env, cwd=root, check=True)
        service = None
        try:
            service = subprocess.Popen([bridge], cwd=root, stdout=subprocess.PIPE, text=True,
                                       env=dict(env, SWARMHUB_ACCESS_TOKEN=token, SWARMHUB_DATA_DIR=str(root / "data"),
                                                SWARMHUB_AGENT_CWD=str(root / "agents"), SWARMHUB_PORT="0"))
            assert select.select([service.stdout], [], [], 10)[0], "workspace failed to start"
            origin = re.search(r"http://127\.0\.0\.1:\d+", service.stdout.readline()).group()
            uid = str(uuid.uuid4())
            store.write_text(json.dumps(dict(version=2, bots=[dict(id=uid, name="PatchQA", backend="Herdr", messages=[])])))
            def window():
                return driver["open_workspace"](bundle, home, origin, token, {"SWARMHUB_DISABLE_UPDATES": "1"})
            # A warm session selects the fixture template before the first chat turn.
            endpoint = urllib.request.Request(origin + "/api/agents", headers={
                "Authorization": "Bearer " + token, "Origin": origin, "Content-Type": "application/json"},
                data=json.dumps(dict(name="patchqa-" + uid[:6], template="review", warm=True)).encode())
            with urllib.request.urlopen(endpoint, timeout=20) as response:
                assert response.status in (200, 201)
            with window() as w:
                press(w, "PatchQA", sidebar=True)
                field = next(e for e in driver["descendants"](w)
                             if attr(e, "AXRole") == "AXTextArea" and driver["label"](e) == "Message")
                driver["enter_draft"](field, START)
                press(w, "Send message")
                def buttons(title):
                    return [b for b in driver["buttons"](w) if driver["label"](b) == title and attr(b, "AXEnabled")]
                wait("actionable first draft", lambda: buttons("Make shorter"), seconds=35)
                press(w, "Make shorter")
                def messages():
                    return json.loads(store.read_text())["bots"][0]["messages"]
                wait("revised draft", lambda: any(json.dumps(REVISED) in m["content"] and m.get("turnState") == "finished"
                                                  for m in messages()), seconds=35)
                assert len(buttons("Approve")) == 1
                press(w, "Approve")
                wait("provider received approved revision", lambda: any(m["content"] == "Approved wording received." and
                     m.get("turnState") == "finished" for m in messages()), seconds=35)
                reviews = [m for m in messages() if m.get("metadata", {}).get("answeredChoiceKey") == "pageReview.0"]
                assert [json.loads(m["metadata"]["answeredChoiceQuote"]) for m in reviews] == [INITIAL, REVISED]
            with window() as w:
                press(w, "PatchQA", sidebar=True)
                def has(title):
                    return any(title in (attr(e, "AXValue"), driver["label"](e)) for e in driver["descendants"](w))
                wait("both decisions after restart", lambda: has("Shorter draft requested") and has("Draft approved"))
                assert not any(driver["label"](b) in ("Approve", "Make shorter") for b in driver["buttons"](w))
            print("Verified original draft, revision request, approval of the revised text, and both receipts after restart.")
        finally:
            if service is not None:
                service.terminate()
                service.wait(timeout=10)
            subprocess.run([core, "server", "stop"], env=env, cwd=root, check=True)


if __name__ == "__main__":
    if "--settings" in sys.argv:
        provider()
    elif len(sys.argv) == 4:
        run(*(Path(arg).resolve(strict=True) for arg in sys.argv[1:]))
    else:
        raise SystemExit("Usage: page-draft-window.py SwarmHub.app swarmhub-herdr herdr-core")
