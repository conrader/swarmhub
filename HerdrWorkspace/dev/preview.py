#!/usr/bin/env python3
"""Run a private, disposable Herdr workspace with example agents on this machine."""
import argparse
import json
import os
from pathlib import Path
import re
import secrets
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request


def executable(value, default, hint):
    resolved = shutil.which(str(value) if value is not None else default)
    if resolved is None:
        raise SystemExit(hint)
    return str(Path(resolved).resolve())


def request(base, token, endpoint, body=None):
    headers = {"Authorization": "Bearer " + token}
    data = None
    if body is not None:
        headers.update({"Origin": base, "Content-Type": "application/json"})
        data = json.dumps(body).encode()
    # The address comes from a verified local listener. Ignore system proxy config.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(urllib.request.Request(base + endpoint, data=data, headers=headers), timeout=28) as response:
        return json.load(response)


def check_cancel(exiting):
    if exiting.is_set():
        raise InterruptedError


def wait_for_listener(stream, exiting):
    deadline = time.monotonic() + 28
    output = bytearray()
    while len(output) < 512:
        check_cancel(exiting)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        ready, _, _ = select.select([stream], [], [], min(0.25, remaining))
        if not ready:
            continue
        chunk = os.read(stream.fileno(), 512 - len(output))
        if not chunk:
            break
        output.extend(chunk)
        if b"\n" in output:
            line = bytes(output).split(b"\n", 1)[0].decode("utf8").rstrip("\r")
            match = re.fullmatch(r"SwarmHub · (http://127\.0\.0\.1:[1-9][0-9]{0,4})", line)
            if match:
                return match.group(1)
            break
    raise RuntimeError("The preview bridge did not start on a local port.")


def seed(base, token, exiting):
    entries = []
    for role, name, task in (
        ("briefing", "Briefing agent", "Put together a short release briefing."),
        ("planner", "Planning agent", "What should the announcement plan look like?"),
    ):
        check_cancel(exiting)
        profile = request(base, token, "/api/profiles", {"name": name})
        check_cancel(exiting)
        agent = request(base, token, "/api/agents", {
            "name": profile["runtime_name"], "profile_id": profile["id"],
            "template": "demo-" + role, "task": task,
        })
        if not agent.get("first_message", {}).get("sent"):
            raise RuntimeError("Herdr did not deliver the preview agent’s first task.")
        entries.append({"address": agent["address"], "created_ms": agent["created_ms"]})
    check_cancel(exiting)
    request(base, token, "/api/groups", {"name": "Launch planning", "members": entries})
    check_cancel(exiting)
    request(base, token, "/api/pages", {"title": "Release checklist",
        "markdown": "# Release checklist\n\n- [x] Draft release notes\n- [ ] Pick announcement date\n- [ ] Confirm support coverage\n"})


def stop_bridge(bridge):
    if bridge is None or bridge.poll() is not None:
        return
    bridge.terminate()
    try:
        bridge.wait(timeout=7)
    except subprocess.TimeoutExpired:
        bridge.kill()
        bridge.wait(timeout=7)


def main():
    workspace = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hc", help="path to Herdr Core’s hc binary (otherwise use PATH)")
    parser.add_argument("--bridge", help="path to a built swarmhub-herdr binary")
    parser.add_argument("--port", type=int, default=0, help="local port, defaults to a free port")
    parser.add_argument("--tmpdir", type=Path, default=Path("/var/tmp"), help="parent for private preview files")
    args = parser.parse_args()
    if not 0 <= args.port <= 65535:
        parser.error("port must be between 0 and 65535")
    if os.geteuid() == 0:
        parser.error("run the preview under an ordinary user account")
    hc = executable(args.hc, "hc", "Herdr Core (hc) not found. Pass --hc with the path to an installed binary.")
    bridge_bin = executable(args.bridge, str(workspace / "target/debug/swarmhub-herdr"),
                            "SwarmHub bridge not found. Run cargo build --locked in HerdrWorkspace or pass --bridge.")
    args.tmpdir = args.tmpdir.resolve()
    if len(os.fsencode(args.tmpdir)) > 50 or not args.tmpdir.is_dir():
        parser.error("choose an existing, short --tmpdir path for the local sockets")
    root = Path(tempfile.mkdtemp(prefix="swarmhub-preview-", dir=args.tmpdir))
    exiting = threading.Event()
    for action in (signal.SIGINT, signal.SIGTERM):
        signal.signal(action, lambda *_: exiting.set())
    bridge = None
    core_attempted = False
    stopped = True
    code = 1
    token = secrets.token_hex(32)
    try:
        for name in ("home", "run", "state", "config"):
            (root / name).mkdir(mode=0o700)
        config = root / "config/herdr-core"
        templates = config / "templates"
        templates.mkdir(parents=True, mode=0o700)
        (config / "config.toml").write_text("notes_quiet = 0\ndraft_wait = 0\n", encoding="utf8")
        for role in ("briefing", "planner"):
            command = shlex.join([sys.executable, str(Path(__file__).with_name("demo_agent.py").resolve()), bridge_bin, role])
            (templates / f"demo-{role}.md").write_text(f"---\ndescription: Model-free {role} agent\ncommand: {command}\n---\n", encoding="utf8")
        core_env = {
            "HOME": str(root / "home"), "PATH": os.environ.get("PATH", os.defpath),
            "LANG": "C.UTF-8", "PYTHONUTF8": "1",
            "XDG_RUNTIME_DIR": str(root / "run"), "XDG_STATE_HOME": str(root / "state"),
            "XDG_CONFIG_HOME": str(root / "config"), "HC_SOCKET": str(root / "core.sock"),
            "HC_SESSION": "preview-" + secrets.token_hex(4), "HC_SETTLE_MS": "0", "HC_STARTED_MS": "5000",
        }
        core_attempted = True
        subprocess.run([hc, "server", "start"], env=core_env, cwd=root, check=True, timeout=28, stdout=subprocess.DEVNULL)
        if not exiting.is_set():
            bridge = subprocess.Popen([bridge_bin], cwd=root, env={
                **core_env, "SWARMHUB_ACCESS_TOKEN": token, "SWARMHUB_PORT": str(args.port),
                "SWARMHUB_DATA_DIR": str(root / "workspace"), "SWARMHUB_DEMO": "1",
            }, stdout=subprocess.PIPE, start_new_session=True)
            assert bridge.stdout is not None
            base = wait_for_listener(bridge.stdout, exiting)
            seed(base, token, exiting)
            check_cancel(exiting)
            access = root / "access-token"
            fd = os.open(access, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="ascii") as output:
                output.write(token + "\n")
            print(f"Preview ready: {base}", flush=True)
            print(f"Workspace token file: {access}", flush=True)
            print("Open the local address and enter the token. Press Ctrl+C to stop the preview.", flush=True)
            while bridge.poll() is None and not exiting.wait(0.5):
                pass
            if not exiting.is_set():
                raise RuntimeError("The preview bridge exited.")
        code = 0
    except InterruptedError:
        code = 0
    except (OSError, subprocess.SubprocessError, RuntimeError, KeyError, ValueError) as error:
        print(f"Preview could not run: {error}", file=sys.stderr)
    finally:
        try:
            stop_bridge(bridge)
        except (OSError, subprocess.SubprocessError):
            stopped = False
            code = 1
            print(f"The preview bridge did not confirm shutdown; preview files remain at {root}.", file=sys.stderr)
        if core_attempted:
            try:
                subprocess.run([hc, "server", "stop"], env=core_env, cwd=root, check=True, timeout=35, stdout=subprocess.DEVNULL)
            except (OSError, subprocess.SubprocessError):
                stopped = False
                code = 1
                print(f"The isolated Core did not confirm shutdown; preview files remain at {root}.", file=sys.stderr)
        if stopped:
            shutil.rmtree(root)
    return code


if __name__ == "__main__":
    sys.exit(main())
