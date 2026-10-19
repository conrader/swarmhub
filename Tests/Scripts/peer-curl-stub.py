#!/usr/bin/python3
"""Synthetic curl boundary for offline peer tests; never opens a socket."""
import fcntl
import json
import os
from pathlib import Path
import sys
import time
from urllib.parse import urlsplit

args = sys.argv[1:]
state = Path(os.environ["PEER_CURL_STATE"])
config = json.loads((state / "config").read_text())
path = urlsplit(args[-1]).path
profile = path.split("/")[2]
body = json.loads(Path(args[args.index("--data-binary") + 1][1:]).read_text())
keyline = sys.stdin.read().strip()
auth = keyline.removeprefix('header = "').removesuffix('"')
with (state / "requests").open("a") as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write(json.dumps([path, body, auth.removeprefix("Authorization: ")]) + "\n")
if config.get("gateway_offline"):
    Path(args[args.index("-o") + 1]).write_text("")
    print("000", end="")
    sys.exit(7)
elif auth != "Authorization: Bearer " + config["keys"][profile]:
    status, output = 401, "{}"
elif path.endswith("/api/sessions"):
    status, output = 201, "{}"
else:
    deadline = time.monotonic() + 10
    while not (state / "release").exists() and time.monotonic() < deadline:
        time.sleep(.01)
    status = config["status"]
    if config["failed"]:
        events = [("run.failed", {"error": "synthetic failure"})]
    elif config["terminal"]:
        events = [("assistant.completed", {"content": config["reply"]}), ("run.completed", {})]
    else:
        events = [("assistant.delta", {"delta": "incomplete"})]
    output = "".join(f"event: {ev}\ndata: {json.dumps(data)}\n\n" for ev, data in events)
out = args[args.index("-o") + 1]
Path(out).write_text(output)
if "-w" in args:
    print(status, end="")
