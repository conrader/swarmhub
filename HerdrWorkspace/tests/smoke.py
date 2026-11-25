"""Exercise the browser bridge against a real, isolated Herdr Core; no model calls."""

import json
import hmac
import os
import http.client
from contextlib import ExitStack, contextmanager
from pathlib import Path
import secrets
import shlex
import socket as socket_module
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

FIXTURE = r'''
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import threading
import time

def post_thread_answer(command):
    release = Path(__file__).with_suffix(".reply-release")
    for _ in range(250):
        if release.exists():
            subprocess.run(command, input=b"I kept the original venue.", check=True)
            return
        time.sleep(.1)

def status(value):
    print("\x1b]7501;state=" + value + "\x1b\\", end="", flush=True)

def interrupted(*_):
    raise InterruptedError

signal.signal(signal.SIGINT, interrupted)
status("idle")
while True:
    try:
        task = input()
        if task.startswith("When this run finishes, pipe a short outcome report to this command: "):
            command = shlex.split(task.split("command: ",1)[1])
            assert command[1] == "routine-result" and command[-1] == "succeeded"
            assert input().startswith("Use failed instead of succeeded")
            assert input() == ""
            task = input()
            if task in ("Check outcome reporting", "Review the weekly notes"):
                with Path(__file__).with_suffix(".routine-outcomes").open("a") as log:
                    log.write(json.dumps(command) + "\n")
        if task.startswith("The user is replying to this excerpt from your earlier message"):
            command = shlex.split(task.partition("(leave the token out of your answer): ")[2])
            assert len(command) == 3 and command[1] == "thread-reply"
            quote = json.loads(input())
            assert input() == ""
            assert input() == "Current task:"
            task = input()
            with Path(__file__).with_suffix(".direct-reply").open("a") as log:
                log.write(json.dumps({"quote":quote,"task":task}) + "\n")
            if task == "Keep the original venue.":
                threading.Thread(target=post_thread_answer, args=(command,), daemon=True).start()
        if task.startswith("Apply the standing_instructions in this JSON to the current_task: "):
            context = json.loads(task.split(": ", 1)[1])
            with Path(__file__).with_suffix(".launches").open("a") as log:
                log.write(json.dumps(context) + "\n")
        if task == "bridge went away":
            time.sleep(30)
        status("working")
        print("fixture received: " + task, flush=True)
        if task.startswith("Produce automatic results | ") or task == "Revise automatic result":
            folder = Path(os.environ["SWARMHUB_RESULTS"])
            temp = folder / ".report-staging"
            temp.write_text("The finished report" if task.startswith("Produce") else "Revised report")
            temp.replace(folder / "Automatic report.txt")
            if task.startswith("Produce"):
                ambient = Path(__file__).with_suffix(".private")
                ambient.write_text("Outside the results folder.")
                (folder / "Link.txt").symlink_to(ambient)
                os.link(ambient, folder / "Hard link.txt")
                (folder / "nested").mkdir()
                (folder / "nested" / "Hidden relative file.txt").write_text("Not a top-level result.")
                (folder / ".unfinished").write_text("Draft still in progress.")
                with (folder / "Oversize.bin").open("wb") as oversized:
                    oversized.truncate(8 * 1024 * 1024 + 1)
        if task == "wait here":
            time.sleep(120)
        status("done")
    except InterruptedError:
        print("fixture interrupted", flush=True)
        status("done")
    except EOFError:
        break
'''

VAULT_AGENT_FIXTURE = r'''
import json
import os
from pathlib import Path
import subprocess

def status(value):
    print("\x1b]7501;state=" + value + "\x1b\\", end="", flush=True)

def controlling_tty():
    try:
        with open("/dev/tty"):
            return True
    except OSError:
        return False

scratch = Path(__file__).parent
(scratch / "vault-agent-ready").write_text(json.dumps({
    "key_path": bool(os.environ.get("SWARMHUB_VAULT_KEY_FILE")),
    "session": bool(os.environ.get("SWARMHUB_VAULT_SESSION")),
    "tty": controlling_tty(),
}))
status("idle")
while True:
    task = input()
    if not task.startswith("Vault fixture: "):
        status("done")
        continue
    serial, *args = json.loads(task[len("Vault fixture: "):])
    result = subprocess.run([os.environ["SWARMHUB_PUBLISHER"], "vault", *args],
                            capture_output=True, text=True, timeout=25)
    tmp = scratch / "vault-agent-result.tmp"
    tmp.write_text(json.dumps([result.returncode, result.stdout, result.stderr]))
    tmp.replace(scratch / ("vault-agent-result-" + str(serial)))
    status("done")
'''

CLAUDE_FIXTURE = r'''#!/usr/bin/python3
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import time

args = sys.argv[1:]
codex = args[0] == "-c"
if codex:
    assert args[:2] == ["-c", "check_for_update_on_startup=false"]
    args = args[2:]
    commands = {}
    while args[0] == "-c":
        match = re.fullmatch(r'hooks\.(\w+)=\[\{hooks=\[\{type="command",command=(.*),timeout=\d+\}\]\}\]', args[1])
        assert match, args[1]
        commands[match[1]] = json.loads(match[2])
        args = args[2:]
    hook, approval = commands["Stop"], commands.get("PermissionRequest")
else:
    assert args[0] == "--settings"
    hooks = json.loads(args[1])["hooks"]
    hook = hooks["Stop"][0]["hooks"][0]["command"]
    approval = hooks.get("PermissionRequest", [{"hooks":[{"command": None}]}])[0]["hooks"][0]["command"]
    args = args[2:]
expected_model = os.environ.get("PICKER_MODEL") or (("gpt-fixture" if codex else "sonnet[1m]") if os.environ.get("PICKER_TEST") else None)
assert args == ["--model", expected_model or "fixture-model"]
if expected_model:
    assert approval, "Model selection dropped the approval hook"
    print("fixture selected model: " + args[1], flush=True)
workspace = shlex.split(hook)[0]

def status(state):
    print("\x1b]7501;state=" + state + "\x1b\\", end="", flush=True)

def send_hook(event, text, turn):
    result = subprocess.run(["sh", "-c", hook], check=True, capture_output=codex, input=json.dumps({
        "hook_event_name": event,
        "turn_id": str(turn),
        "last_assistant_message": text,
        "transcript_path": "/file-must-not-be-read.jsonl",
    }).encode())
    if codex:
        assert json.loads(result.stdout) == {}

status("idle")
grouped = False
group_task_next = False
group_files_next = False
group_quote_next = False
reply_args = None
for turn, line in enumerate(sys.stdin, start=1):
    task = line.strip()
    if task.startswith("SwarmHub group:"):
        grouped = True
        status("working")
        continue
    if grouped:
        if group_task_next:
            assert reply_args
            reply = ("Group answer to " + task).encode()
            if task.endswith("Check live group progress"):
                command = [*reply_args, "--draft"]
                gate = Path(__file__).with_name("group-draft-gate")
                assert subprocess.run(command, input=b"X" * 2049, capture_output=True).returncode != 0
                for step, update in enumerate([b"Checking <em>sample rows</em>.", b"Reviewing the last row."], 1):
                    subprocess.run(command, input=update, check=True)
                    deadline = time.monotonic() + 28
                    while not gate.exists() or gate.read_text().strip() != str(step):
                        assert time.monotonic() < deadline, "Browser did not see group progress"
                        time.sleep(0.05)
                subprocess.run(reply_args, input=reply, check=True)
                assert subprocess.run(command, input=b"Late progress update", capture_output=True).returncode != 0
            elif task.endswith("Return a downloadable report"):
                with tempfile.TemporaryDirectory() as temp:
                    report = Path(temp) / "Agent report.txt"
                    report.write_bytes(b"Agent report contents")
                    command = [*reply_args, "--file", str(report)]
                    subprocess.run(command, input=reply, check=True)
                    assert subprocess.run(command, input=reply, capture_output=True).returncode != 0
            elif task.endswith("Ask a group question"):
                subprocess.run([*reply_args, "--question"], input=b"Which report section should I use?", check=True)
            elif task.endswith("Ask for a group form"):
                fields = [
                    {"key": "section", "label": "Report section", "choices": ["Summary", "Timeline"]},
                    {"key": "notes", "label": "Notes <draft>", "required": False},
                ]
                form = {"title": "Review preferences", "fields": fields}
                command = [*reply_args, "--form"]
                invalid = {**form, "fields": [fields[0], fields[0]]}
                assert subprocess.run(command, input=json.dumps(invalid).encode(), capture_output=True).returncode != 0
                subprocess.run(command, input=json.dumps(form).encode(), check=True)
            elif task != "Wait for explicit group result":
                subprocess.run(reply_args, input=reply, check=True)
                assert subprocess.run(reply_args, input=reply, capture_output=True).returncode != 0
            grouped = group_task_next = False
            reply_args = None
            status("done")
        elif task == "Current task:":
            group_task_next = True
        elif group_quote_next:
            group_quote_next = False
            print("fixture quote: " + task, flush=True)
        elif task.startswith("Question from ") and task.endswith("that you are responding to:"):
            group_quote_next = True
        elif group_files_next:
            group_files_next = False
            paths = json.loads(task)
            for item in paths:
                item["sha256"] = hashlib.sha256(Path(item["path"]).read_bytes()).hexdigest()
            with Path(__file__).with_name("group-attachment-reads").open("a") as log:
                log.write(json.dumps(paths) + "\n")
        elif task == "Attached files for your session (names and paths):":
            group_files_next = True
        elif task.startswith("User:"):
            print("fixture context: " + task, flush=True)
        elif "group-reply" in task:
            candidate = shlex.split(task)
            if len(candidate) == 3 and candidate[0] == workspace and candidate[1] == "group-reply":
                reply_args = candidate
        continue
    if task.startswith("Routine: "):
        continue
    if task.startswith("When this run finishes, pipe a short outcome report to this command: "):
        assert next(sys.stdin).startswith("Use failed instead of succeeded")
        assert next(sys.stdin).strip() == ""
        task = next(sys.stdin).strip()
    if task.startswith("approval ") and approval:
        status("working")
        permission = "AskUserQuestion" if task.endswith("interactive") else "Bash"
        result = subprocess.run(["sh", "-c", approval], check=True, capture_output=True, input=json.dumps({
            "hook_event_name": "PermissionRequest",
            "cwd": "/synthetic/review",
            "tool_name": permission,
            "tool_input": {"command": "printf fixture", "exact_number": 9007199254740993},
        }).encode())
        if result.stdout:
            event = json.loads(result.stdout)["hookSpecificOutput"]
            assert event["hookEventName"] == "PermissionRequest"
            assert set(event["decision"]) == {"behavior"}
            outcome = event["decision"]["behavior"]
        else:
            outcome = "terminal"
        print(f"{task}: permission outcome {outcome}", flush=True)
    if task.startswith("SwarmHub page request."):
        payload = json.loads(task[task.index("{"):])
        source = subprocess.run(shlex.split(payload["read_command"]), capture_output=True, check=True).stdout
        revised = source + ("\n\nAmended: " + payload["request"]).encode()
        subprocess.run(shlex.split(payload["save_command"]), input=revised, check=True)
        send_hook("Stop", "Updated the comparison page.", turn)
        status("working")
        print("fixture received: page revision request", flush=True)
        status("done")
        continue
    send_hook("SubagentStop", "do not display this subagent output", turn)
    send_hook("Stop", "Structured reply for " + task + "\n<em>literal text</em>", turn)
    if task == "make a comparison page":
        subprocess.run([workspace, "publish-page", "Agent comparison"],
                       input=b"# Comparison\n\n| Option | Notes |\n| - | - |\n| A | Ready |\n", check=True)
    if codex:
        send_hook("Stop", "Duplicate reply must not appear", turn)
    if task in ("while bridge is offline", "browser follow-up"):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            text = folder / "Agent result.txt"
            text.write_text("Generated for " + task + "\n<script>plain text</script>")
            binary = folder / "binary.dat"
            binary.write_bytes(b"\x00\xff\x11")
            for artifact in (text, binary):
                subprocess.run([workspace, "publish-file", str(artifact)], check=True)
            alias = folder / "alias.txt"
            alias.symlink_to(text)
            assert subprocess.run([workspace, "publish-file", str(alias)], capture_output=True).returncode != 0
    status("working")
    print("fixture received: " + task, flush=True)
    if task == "terminal stream load":
        for _ in range(3800):
            print("Terminal test output " + "x" * 67)
        print("end of large terminal output", flush=True)
    status("done")
'''


GEMINI_FIXTURE = r"""#!/usr/bin/python3
# Stands in for Gemini CLI: reads the hooks from the settings file in the bot's folder and runs them in the
# order Gemini CLI 0.70.0 does. It reports no status itself; the hooks do.
import json
import os
from pathlib import Path
import subprocess
import sys
import termios
import time
import tty

args = sys.argv[1:]
assert args in ([], ["--model", "flash"]), args
assert os.environ["GEMINI_CLI_TRUST_WORKSPACE"] == "true"
assert "SWARMHUB_LAUNCH_MODEL" not in os.environ
folder = Path.cwd()
assert (folder / ".swarmhub-workspace").is_file()
settings = json.loads((folder / ".gemini/settings.json").read_text())
assert settings["general"] == {"enableAutoUpdate": False}
hooks = settings["hooks"]
assert sorted(hooks) == ["AfterAgent", "AfterTool", "BeforeAgent", "BeforeTool", "Notification",
                         "SessionEnd", "SessionStart"]

def note(text):
    with Path(__file__).with_suffix(".log").open("a") as log:
        log.write(folder.name + ": " + text + "\n")

def fire(event, **fields):
    hook = hooks[event][0]["hooks"][0]
    assert hook["type"] == "command" and hook["timeout"] >= 5000
    result = subprocess.run(["sh", "-c", hook["command"]], capture_output=True, input=json.dumps({
        "session_id": "fixture", "transcript_path": "/file-must-not-be-read.jsonl", "cwd": str(folder),
        "hook_event_name": event, "timestamp": "2026-01-01T00:00:00.000Z", **fields}).encode())
    # A hook that fails, or says anything but {}, would stop Gemini CLI or change what it does.
    assert result.returncode == 0 and json.loads(result.stdout) == {}, (event, result)

def line():
    text = b""
    while not text.endswith(b"\n"):
        byte = os.read(0, 1)
        if not byte:
            sys.exit(0)
        text += byte
    return text.decode().strip().lstrip("\x1b")

def answer():
    file = folder / "permission-answer"
    for _ in range(300):
        if file.exists():
            text = file.read_text().strip()
            file.unlink()
            return text
        time.sleep(.1)
    return "refuse"

note("args " + json.dumps(args))
fire("SessionStart", source="startup")
while True:
    task = line()
    if not task:
        continue
    note("received " + task)
    fire("BeforeAgent", prompt=task)
    if task in ("use a tool", "ask permission"):
        tool = {"tool_name": "run_shell_command",
                "tool_input": {"command": "printf fixture", "description": "Print a word"}}
        fire("BeforeTool", **tool)
        if task == "ask permission":
            fire("Notification", notification_type="ToolPermission",
                 message="Tool Confirm Shell Command requires execution",
                 details={"type": "exec", "title": "Confirm Shell Command", "command": "printf fixture",
                          "rootCommand": "printf"})
            if answer() != "allow":
                # Gemini CLI runs no hook when a permission is refused: the turn just ends.
                note("refused")
                continue
        fire("AfterTool", **tool, tool_response={"llmContent": "fixture", "returnDisplay": "fixture"})
        fire("AfterAgent", prompt=task, prompt_response="I will run a command.\nThe command finished.",
             stop_hook_active=False)
    elif task == "wait here":
        # A turn that runs until Escape. Gemini CLI runs no hook when a turn is cancelled either.
        was = termios.tcgetattr(0)
        tty.setcbreak(0)
        try:
            while os.read(0, 1) != b"\x1b":
                pass
        finally:
            termios.tcsetattr(0, termios.TCSADRAIN, was)
        note("cancelled")
    elif task == "say nothing":
        fire("AfterAgent", prompt=task, prompt_response="[no response text]", stop_hook_active=False)
    else:
        fire("AfterAgent", prompt=task, prompt_response="Gemini reply for " + task, stop_hook_active=False)
"""

def seed_legacy_database(directory, version):
    directory.mkdir(mode=0o700)
    path = directory / "workspace.sqlite3"
    path.touch(mode=0o600)
    with sqlite3.connect(str(path)) as db:
        db.executescript("""
            CREATE TABLE journal (
              id INTEGER PRIMARY KEY, launch_key TEXT UNIQUE, core_id TEXT NOT NULL,
              address TEXT, created_ms INTEGER, agent TEXT NOT NULL,
              kind TEXT NOT NULL,
              state TEXT NOT NULL, text TEXT NOT NULL, detail TEXT, at_ms INTEGER NOT NULL
            );
            CREATE INDEX by_session ON journal (core_id,address,created_ms,id);
            CREATE INDEX by_kind ON journal (kind,id);
            INSERT INTO journal VALUES (35, NULL, 'legacy-core', 't5', 1, 'Legacy agent',
                                        'task', 'sent', 'Preserve this task', NULL, 123);
            INSERT INTO journal VALUES (36, NULL, 'legacy-core', 't5', 1, 'Legacy agent',
                                        'snapshot', 'saved', 'Preserve this snapshot', 'Legacy snapshot', 124);
        """)
        if version == "1":
            db.executescript("""
                ALTER TABLE journal ADD COLUMN reply_for TEXT REFERENCES journal (launch_key);
                UPDATE journal SET launch_key = 'legacy-launch' WHERE id = 35;
                INSERT INTO journal (id, reply_for, core_id, address, created_ms, agent, kind, state, text, detail, at_ms)
                VALUES (37, 'legacy-launch', 'legacy-core', 't5', 1, 'Legacy agent',
                        'reply', 'received', 'Preserve this reply', 'Claude Code', 125);
                PRAGMA user_version=1;
            """)

def until(function, seconds=15):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        result = function()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("timed out waiting for runtime state")


OPENCODE_STARTUP_FIXTURE = r'''
import json
import os
import socket
import subprocess
import sys
import time

if sys.argv[1] == "report-ready":
    # Test-only: Mini does not publish a native initial OSC 7501 status.
    # Wait for the real composer before asking Herdr to type the first task.
    deadline = time.monotonic() + 20
    request = (json.dumps({"jsonrpc": "2.0", "id": 1, "method": "terminal.read",
                           "params": {"terminal": os.environ["HC_TERMINAL_ID"], "lines": 0}}) + "\n").encode()
    while time.monotonic() < deadline:
        try:
            with socket.socket(socket.AF_UNIX) as conn:
                conn.settimeout(0.5)
                conn.connect(os.environ["HC_SOCKET"])
                conn.sendall(request)
                with conn.makefile("rb") as stream:
                    screenshot = json.loads(stream.readline(128 * 1024))
            if "Ask anything, / for commands" in screenshot.get("result", {}).get("text", ""):
                fd = os.open(sys.argv[2], os.O_WRONLY | os.O_NOCTTY | os.O_NONBLOCK)
                try:
                    os.write(fd, b"\x1b]7501;state=idle\x1b\\")
                finally:
                    os.close(fd)
                break
        except (OSError, ValueError):
            pass
        time.sleep(0.1)
    sys.exit()

args = sys.argv[1:]
if args == ["--standalone", "models"]:
    scratch = os.path.dirname(__file__)
    with open(os.path.join(scratch, "model-list-invocations"), "a") as counter:
        counter.write("models\n")
    deadline = time.monotonic() + 12
    while not os.path.exists(os.path.join(scratch, "release-model-list")):
        if time.monotonic() >= deadline:
            sys.exit("Model-list fixture timed out")
        time.sleep(0.02)
if args and args[0] == "serve":
    with open(os.path.join(os.path.dirname(__file__), "opencode-fixture-server-pids"), "a") as pids:
        pids.write(str(os.getpid()) + "\n")
# The API path admits the task without waiting for Mini. Emit output and leave
# a quiet gap on the terminal before exec so an accidental PTY send is exposed.
if args and args[0] == "mini" and "--server" in args:
    os.write(1, b"\x1b[?2004h")
    scratch = os.path.dirname(__file__)
    if HOLD_FIRST_MINI:
        try:
            with open(os.path.join(scratch, "opencode-mini-held"), "x"):
                pass
        except FileExistsError:
            time.sleep(3)
        else:
            deadline = time.monotonic() + 45
            while not os.path.exists(os.path.join(scratch, "opencode-mini-release")):
                if time.monotonic() >= deadline:
                    sys.exit("The fixture did not release OpenCode Mini.")
                time.sleep(0.1)
    else:
        time.sleep(3)
if args[:2] == ["--standalone", "mini"]:
    subprocess.Popen([sys.executable, __file__, "report-ready", os.ttyname(1)],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Force terminal output before startup, with a pause longer than Herdr's
    # quiet-readiness threshold. PTY delivery before the composer loses input.
    os.write(1, b"\x1b[?2004h")
    time.sleep(3)
os.execv(OPENCODE_BINARY, [OPENCODE_BINARY] + args)
'''


def opencode_reply(root, bridge, request, core, browser):
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    import re

    focus = os.environ.get("SWARMHUB_TEST_FOCUS")
    opencode = str(Path(os.environ["SWARMHUB_TEST_OPENCODE_BIN"]).resolve())
    launcher = root / "opencode-fixture"
    launcher.write_text(f"#!/usr/bin/env python3\nOPENCODE_BINARY = {opencode!r}\n"
                        f"HOLD_FIRST_MINI = {focus == 'opencode'!r}\n"
                        + OPENCODE_STARTUP_FIXTURE)
    launcher.chmod(0o700)
    reply = "Reply from the local test endpoint."
    follow_up = "Second reply from the local test endpoint."
    first_part = "Reply from the local"
    first_task = "Open local chat"
    first_prompt = json.dumps(first_task)
    early_tasks = {
        "Direct follow-up before Mini": "Direct reply before Mini.",
        "Group follow-up before Mini": "Group reply before Mini.",
        "Routine follow-up before Mini": "Routine reply before Mini.",
    }
    changed_task = "Follow-up after model switch"
    reset_task = "Follow-up after model reset"
    changed_reply = "Reply with the switched model."
    reset_reply = "Reply with the restored default."
    saved_replies = [reply, *early_tasks.values(), changed_reply, reset_reply, follow_up]
    second_part = "Second reply from the local"
    cancelled_part = "This partial reply should disappear"
    fast = {"id": "fixture/fast", "label": "Fast fixture", "provider": "Local fixture"}
    detailed = {"id": "fixture/detailed", "label": "Detailed fixture", "provider": "Local fixture"}
    calls = []
    release = threading.Event()
    release_follow_up = threading.Event()
    release_group = threading.Event()
    group_part = "Group reply before"
    cancelled = threading.Event()
    guarded = root / "permission-fixture.txt"
    guarded.write_text("A test file that requires permission.\n")

    class Model(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def do_GET(self):
            gate = {"/finish-follow-up": release_follow_up, "/finish-group": release_group}.get(self.path)
            if not gate:
                return self.send_error(404)
            gate.set()
            self.send_response(204)
            self.end_headers()

        def do_POST(self):
            if self.path != "/v1/chat/completions":
                return self.send_error(404)
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            prompt = request["messages"][-1]["content"]
            calls.append((request["model"], json.dumps(prompt)))
            second = "Second local question" in json.dumps(prompt)
            first = json.dumps(prompt) == first_prompt
            cancel = "Cancel local question" in json.dumps(prompt)
            permission = "Pause for file permission" in json.dumps(prompt)
            group = "Group follow-up before Mini" in json.dumps(prompt)
            if isinstance(prompt, str) and prompt.endswith("Reply with only the title."):
                answer = part = "Local model fixture"
            elif "Model choice from browser" in json.dumps(prompt):
                answer, part = "Model selected: " + request["model"], "Model selected: "
            elif cancel:
                answer, part = cancelled_part + ".", cancelled_part
            elif prompt == changed_task:
                answer = part = changed_reply
            elif prompt == reset_task:
                answer = part = reset_reply
            elif group:
                answer, part = early_tasks["Group follow-up before Mini"], group_part
            else:
                early = next((answer for task, answer in early_tasks.items() if task in json.dumps(prompt)), None)
                answer, part = (early, early) if early else (follow_up, second_part) if second else (reply, first_part)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if permission and any(tool["function"]["name"] == "read" for tool in request.get("tools", [])):
                tool = {"index": 0, "id": "call_permission_fixture", "type": "function",
                        "function": {"name": "read", "arguments": json.dumps({"path": str(guarded)})}}
                chunks = (({"role": "assistant", "tool_calls": [tool]}, None), ({}, "tool_calls"))
            else:
                chunks = (({"role": "assistant", "content": part}, None),
                          ({"content": answer[len(part):]}, None), ({}, "stop"))
            for index, (delta, finish) in enumerate(chunks):
                if index == 1 and first:
                    release.wait(12)
                elif index == 1 and second:
                    release_follow_up.wait(20)
                elif index == 1 and group:
                    release_group.wait(38)
                elif index == 1 and cancel:
                    cancelled.wait(12)
                    return
                chunk = {"id": "chatcmpl-local", "object": "chat.completion.chunk", "created": int(time.time()),
                         "model": request["model"], "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
                self.wfile.flush()
            self.wfile.write(b"data: [DONE]\n\n")

    journal = root / "workspace/workspace.sqlite3"
    browser_approvals = focus == "opencode-approvals"
    api_first_task = focus != "opencode-status"
    legacy_body_marker = "Template-body sentinel must not be delivered in API mode."
    with ThreadingHTTPServer(("127.0.0.1", 0), Model) as endpoint:
        worker = threading.Thread(target=endpoint.serve_forever, daemon=True)
        worker.start()
        config = {"model": "fixture/default",
                  "permissions": [{"action": "read", "resource": "*permission-fixture.txt", "effect": "ask"}],
                  "providers": {"fixture": {"name": "Local fixture", "env": ["FIXTURE_API_KEY"],
                  "package": "@opencode/ai/providers/openai-compatible",
                  "models": {name: {"name": name.title(), "capabilities": {"tools": True}} for name in ("default", "fast", "detailed", "discovered")},
                  "settings": {"baseURL": f"http://127.0.0.1:{endpoint.server_port}/v1"}}}}
        path = root / "opencode.json"
        path.write_text(json.dumps(config))
        # Give the real renderer time to process the paste before Enter on a loaded host.
        (root / "config/herdr-core/templates/local-model.md").write_text(
            "---\ndescription: OpenCode with a local test endpoint\nstop: ctrl+c\npaste_gap_ms: 1500\n"
            f"command: OPENCODE_DISABLE_MODELS_FETCH=1 OPENCODE_DISABLE_FREE_MODELS=1 FIXTURE_API_KEY=local-test "
            f"SWARMHUB_OPENCODE_BIN={shlex.quote(str(launcher))} {shlex.quote(bridge)} run-opencode "
            + ("--workspace-approvals " if browser_approvals else "")
            + ("--api-first-task " if api_first_task else "") + "mini\n---\n"
            + (legacy_body_marker + "\n" if api_first_task else "")
        )
        (root / "workspace/runtime-catalog.json").write_text(json.dumps({
            "local-model": {"harness": "OpenCode", "models": [fast, detailed], "discover_models": True},
            "fixture": {"harness": "Custom agent", "models": [detailed]},
        }))
        model_probe = "/api/runtime-models/local-model"
        request(model_probe, {}, status=401, authorized=False)
        request(model_probe, {}, status=403, origin="http://other.example")
        request("/api/runtime-models/fixture", {}, status=409)
        expected_models = {"models": [
            {"id": f"fixture/{name}", "provider": "fixture"}
            for name in ("default", "detailed", "discovered", "fast")
        ], "truncated": False}
        from concurrent.futures import ThreadPoolExecutor
        with ThreadPoolExecutor(max_workers=2) as pool:
            first = pool.submit(request, model_probe, {}, timeout=45)
            count = root / "model-list-invocations"
            try:
                until(count.is_file, seconds=10)
                second = pool.submit(request, model_probe, {}, timeout=45)
                # Keep discovery active while another inspector asks for the same catalog.
                time.sleep(0.5)
            finally:
                (root / "release-model-list").touch()
            for inspector in (first, second):
                assert inspector.result() == expected_models
        assert count.read_text().splitlines() == ["models"], "Concurrent inspectors started duplicate list commands"
        assert not calls, "Model discovery must not send an inference request"
        if api_first_task:
            (root / "config/herdr-core/templates/malformed-opencode.md").write_text(
                f"---\ndescription: Quoted OpenCode option\n"
                f"command: {shlex.quote(bridge)} run-opencode --api-first-task 'mini'\n---\n")
            before = {agent["address"] for agent in request("/api/workspace")["agents"]}
            request("/api/agents", {"name":"malformed-launch", "template":"malformed-opencode",
                                    "task":"Must never start a terminal"}, status=422)
            assert before == {agent["address"] for agent in request("/api/workspace")["agents"]}
            assert not (root / "opencode-fixture-server-pids").exists()

        def server_stopped(pid):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return True
            proc = Path(f"/proc/{pid}/status")
            if proc.is_file():
                try:
                    return "\nState:\tZ" in proc.read_text()
                except FileNotFoundError:
                    return True
            return False

        def verify_handoff():
            blocked = request("/api/agents", {"name":"opencode-needs-input", "template":"local-model",
                              "task":"Pause for file permission", "model_choice":detailed}, status=201, timeout=45)
            blocked_url = f"/api/agents/{blocked['address']}/{blocked['created_ms']}"
            def permission_status():
                return next(item for item in request("/api/workspace")["agents"]
                            if item["address"] == blocked["address"]).get("status")
            try:
                until(lambda: permission_status() == {"state":"blocked", "kind":"permission"}, seconds=15)
                if api_first_task:
                    request(blocked_url + "/messages", {"text": "Do not bypass the pending OpenCode permission"}, status=409)
                    assert not any("Do not bypass" in prompt for _, prompt in calls)
                if browser_approvals:
                    inbox = "/api/approvals"
                    review = until(lambda: next((item for item in request(inbox)["pending"] if item["agent"] == "opencode-needs-input"), None))
                    assert review["tool"] == "read" and review["provider"] == "OpenCode"
                    assert json.loads(review["arguments"]) == {"resources":["permission-fixture.txt"]}
                    request(inbox, status=401, authorized=False)
                    if browser:
                        subprocess.run(browser, check=True, timeout=55, env={**os.environ,"SWARMHUB_TEST_FOCUS":"opencode-inbox"})
                    else:
                        request(f"{inbox}/{review['id']}", "approve", status=202)
                    until(lambda: any(item["id"] == review["id"] and item["state"] == "approved" for item in request(inbox)["history"]))
                    until(lambda: permission_status() == {"state":"done"}, seconds=12)
                    request(f"{inbox}/{review['id']}", "deny", status=409)
                    request(blocked_url + "/messages", {"text":"Pause for file permission again"})
                    second = until(lambda: next((item for item in request(inbox)["pending"] if item["agent"] == "opencode-needs-input"), None))
                    request(f"{inbox}/{second['id']}", "terminal", status=202)
                    until(lambda: any(item["id"] == second["id"] and item["state"] == "terminal" for item in request(inbox)["history"]))
                    assert permission_status() == {"state":"blocked", "kind":"permission"}
                elif browser:
                    assert request("/api/approvals")["pending"] == []
                    subprocess.run(browser, check=True, timeout=55, env={**os.environ,"SWARMHUB_TEST_FOCUS":"opencode-blocked"})
            except AssertionError as error:
                raise AssertionError(("OpenCode permission prompt not observed", permission_status(), request(blocked_url + "/output"))) from error
            finally:
                request(blocked_url + "/end", {})

        try:
            if os.environ.get("SWARMHUB_TEST_FOCUS") in ("opencode-status", "opencode-approvals"):
                verify_handoff()
                return
            launches = {item["name"]: item for item in request("/api/workspace")["templates"]}
            assert launches["local-model"]["models"] == [fast, detailed] and "models" not in launches["fixture"]
            proposed = {"name": "local-opencode", "template": "local-model", "task": first_task}
            request("/api/agents", {**proposed, "model_choice": {**detailed, "label": "Stale label"}}, status=409)
            request("/api/agents", {**proposed, "template":"fixture", "model_choice": detailed}, status=409)
            agent = request("/api/agents", {**proposed, "model_choice": detailed}, status=201, timeout=45)
            session = f"{agent['address']}/{agent['created_ms']}"
            url = f"/api/agents/{session}"
            history = f"/api/history/{core}/{session}"
            assert agent["first_message"]["sent"], request(url + "/output")
            assert agent["open_code_first_task"] == "submitted"
            assert agent["template"] == "local-model"
            assert next(item for item in request("/api/workspace")["agents"] if item["address"] == agent["address"])["template"] == "local-model"
            model_url = url + "/model"
            model_query = model_url + "?expected_core=" + core
            initial_model = {"current": "fixture/detailed", "default_model": "fixture/default"}
            assert request(model_query) == initial_model
            request(model_query, status=401, authorized=False)
            request(model_url + "?expected_core=wrong-core", status=409)
            def change_model(reviewed, operation, status=200):
                return request(model_url, {
                    "expected_core": core, "expected_current": reviewed["current"],
                    "expected_default": reviewed["default_model"], "change": operation
                }, status=status)
            server_pid = int((root / "opencode-fixture-server-pids").read_text().splitlines()[0])
            assert not server_stopped(server_pid)
            seen = lambda text: any(item["kind"] == "reply" and item["text"] == text for item in request(history)["items"])
            def agent_status():
                return next(item for item in request("/api/workspace")["agents"] if item["address"] == agent["address"]).get("status")
            def wait_early(task):
                until(lambda: seen(early_tasks[task]), seconds=15)
                until(lambda: agent_status() == {"state": "done"})
                prompts = [json.loads(prompt) for model, prompt in calls if model == "detailed" and task in prompt]
                assert len(prompts) == 1, prompts
                return prompts[0]
            try:
                until(lambda: ("detailed", first_prompt) in calls, seconds=12)
                until(lambda: (request(history + "/draft")["draft"] or {}).get("text") == first_part, seconds=9)
                until(lambda: agent_status() == {"state": "working"}, seconds=5)
                change_model(initial_model, {"action": "select", "id": "fixture/fast"}, status=409)
                assert request(model_query) == initial_model
                assert not any(item["kind"] == "reply" for item in request(history)["items"])
                request(history + "/draft", status=401, authorized=False)
                assert request(f"/api/history/wrong-core/{session}/draft")["draft"] is None
                release.set()
                until(lambda: seen(reply), seconds=20)
                until(lambda: agent_status() == {"state": "done"}, seconds=9)
                until(lambda: request(history + "/draft")["draft"] is None)
                until(lambda: (root / "opencode-mini-held").is_file())
                assert reply not in request(url + "/output")["text"]
                direct, group_task, routine_task = early_tasks
                boundary = secrets.token_hex(16)
                meta = json.dumps({"text": direct, "expected_core": core})
                multipart = (
                    f'--{boundary}\r\nContent-Disposition: form-data; name="message"\r\n\r\n{meta}\r\n'
                    f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="fixture.txt"\r\n'
                    f'Content-Type: text/plain\r\n\r\nAttachment for OpenCode.\r\n--{boundary}--\r\n'
                ).encode()
                request(url + "/messages/with-files", multipart, media_type=f"multipart/form-data; boundary={boundary}")
                attachment = json.loads(wait_early(direct).rsplit("Attached files (name and terminal path):\n", 1)[1])[0]
                assert attachment["name"] == "fixture.txt"
                assert Path(attachment["path"]).read_bytes() == b"Attachment for OpenCode."

                target = {key:agent[key] for key in ("address", "created_ms")}
                helper = request("/api/agents", {"name": "open-code-test-partner", "template": "fixture",
                                                  "task": "Start group test partner"}, status=201)
                group = request("/api/groups", {"name": "OpenCode group fixture", "members": [
                    target, {key:helper[key] for key in ("address", "created_ms")}
                ]}, status=201)
                feed = f"/api/groups/{group['id']}/messages"
                other_group = request("/api/groups", {"name": "Unrelated OpenCode group fixture", "members": [
                    target, {key:helper[key] for key in ("address", "created_ms")}
                ]}, status=201)
                unrelated_feed = f"/api/groups/{other_group['id']}/messages"
                request(feed, {"text": group_task, "recipients": [target], "revision": group["revision"]}, status=202)
                until(lambda: (request(feed).get("live_drafts") or [{}])[0].get("text") == group_part, seconds=12)
                live_page = request(feed)
                task_message = next(item for item in live_page["items"] if item["text"] == group_task)
                with sqlite3.connect(journal) as db:
                    delivery_id = db.execute("SELECT id FROM group_deliveries WHERE message_id=? AND address=?",
                                             (task_message["id"], target["address"])).fetchone()[0]
                assert live_page["live_drafts"] == [{
                    "delivery_id": delivery_id, "task_id": task_message["id"],
                    "author": "local-opencode", "task": group_task, "text": group_part,
                }]
                assert not live_page.get("drafts") and not any(item.get("author") for item in live_page["items"])
                assert not request(unrelated_feed).get("live_drafts")
                assert not request(feed + f"?before={task_message['id'] + 1}").get("live_drafts")
                assert request(history + "/draft")["draft"] is None
                if browser:
                    subprocess.run(browser, check=True, timeout=40, env={
                        **os.environ, "SWARMHUB_TEST_FOCUS": "opencode-group-preview",
                        "SWARMHUB_TEST_OPENCODE_GROUP_RELEASE":
                            f"http://127.0.0.1:{endpoint.server_port}/finish-group",
                        "SWARMHUB_TEST_OPENCODE_GROUP_TASK": str(task_message["id"]),
                    })
                release_group.set()
                group_prompt = wait_early(group_task)
                group_token = re.search(r"group-reply ([0-9a-f]{32})", group_prompt).group(1)
                until(lambda: request(feed)["items"][0]["deliveries"][0]["state"] == "sent")
                until(lambda: not request(feed).get("live_drafts"))
                assert not any(item.get("author") for item in request(feed)["items"])

                routine = request("/api/routines", {"name": "OpenCode routine fixture", "task": routine_task,
                                  "target": target, "schedule": {"kind": "interval", "minutes": 60}}, status=201)
                route = f"/api/routines/{routine['id']}"
                request(route + "/state", "pause")
                run = request(route + "/test", {}, status=202)
                routine_prompt = wait_early(routine_task)
                routine_token = re.search(r"routine-result ([0-9a-f]{32})", routine_prompt).group(1)
                until(lambda: any(row["id"] == run["id"] and row["state"] == "sent" for row in request(route)["runs"]))
                with sqlite3.connect(journal) as db:
                    key = db.execute("SELECT launch_key FROM journal WHERE kind='task' AND address=? AND created_ms=? "
                                     "AND launch_key IS NOT NULL", (agent["address"], agent["created_ms"])).fetchone()[0]
                child_env = {"SWARMHUB_JOURNAL": str(journal), "SWARMHUB_LAUNCH_KEY": key}
                subprocess.run([bridge, "group-reply", group_token], input="Attributed group answer.", text=True, check=True, env=child_env)
                assert request(feed)["items"][-1]["author"] == "local-opencode"
                subprocess.run([bridge, "routine-result", routine_token, "succeeded"], input="Attributed routine result.",
                               text=True, check=True, env=child_env)
                assert any(row["id"] == run["id"] and row["result"]["summary"] == "Attributed routine result."
                           for row in request(route)["runs"])
                assert reply not in request(url + "/output")["text"]
                change_model(initial_model, {"action": "select", "id": "not-a-provider-model"}, status=422)
                change_model({"current": "fixture/discovered", "default_model": "fixture/default"},
                             {"action": "select", "id": "fixture/fast"}, status=409)
                changed = change_model(initial_model, {"action": "select", "id": "fixture/fast"})
                assert changed == {"current": "fixture/fast", "default_model": "fixture/default"}
                assert request(model_query) == changed
                request(url + "/messages", {"text": changed_task})
                until(lambda: seen(changed_reply))
                until(lambda: agent_status() == {"state": "done"})
                assert calls.count(("fast", json.dumps(changed_task))) == 1, calls
                change_model({**changed, "default_model": "fixture/discovered"}, {"action": "reset"}, status=409)
                reset = change_model(changed, {"action": "reset"})
                assert reset == {"current": "fixture/default", "default_model": "fixture/default"}
                request(url + "/messages", {"text": reset_task})
                until(lambda: seen(reset_reply))
                until(lambda: agent_status() == {"state": "done"})
                assert calls.count(("default", json.dumps(reset_task))) == 1, calls
                assert change_model(reset, {"action": "select", "id": "fixture/detailed"}) == initial_model
                (root / "opencode-mini-release").touch()
                # Later terminal takeover sees the same session and its replies.
                until(lambda: early_tasks[routine_task] in request(url + "/output")["text"], seconds=20)
                if browser:
                    subprocess.run(browser, check=True, timeout=95, env={
                        **os.environ, "SWARMHUB_TEST_OPENCODE_FINISH_URL": f"http://127.0.0.1:{endpoint.server_port}/finish-follow-up",
                    })
                else:
                    request(url + "/messages", {"text":"Second local question"})
                    until(lambda: (request(history + "/draft")["draft"] or {}).get("text") == second_part, seconds=9)
                    release_follow_up.set()
                until(lambda: seen(follow_up), seconds=20)
                until(lambda: agent_status() == {"state": "done"}, seconds=9)
                request(url + "/messages", {"text":"Cancel local question"})
                until(lambda: (request(history + "/draft")["draft"] or {}).get("text") == cancelled_part, seconds=9)
                request(url + "/end", {})
                until(lambda: server_stopped(server_pid))
                until(lambda: request(history + "/draft")["draft"] is None, seconds=8)
                if browser:
                    other = next(item for item in request("/api/workspace")["agents"] if item["name"] == "browser-model")
                    request(f"/api/agents/{other['address']}/{other['created_ms']}/end", {})
            except (AssertionError, subprocess.CalledProcessError) as error:
                diagnostics = []
                for item in request("/api/workspace")["agents"]:
                    identity = f"{item['address']}/{item['created_ms']}"
                    diagnostics.append((item["name"], item["status"], request(f"/api/agents/{identity}/output"),
                                        request(f"/api/history/{core}/{identity}")))
                raise AssertionError(("OpenCode workflow failed", diagnostics, calls)) from error
            for task in (first_task, "Second local question", "Cancel local question"):
                assert ("detailed", json.dumps(task)) in calls, calls
            assert sum(prompt == first_prompt for _, prompt in calls) == 1, calls
            assert all(legacy_body_marker not in prompt for _, prompt in calls), calls
            assert legacy_body_marker not in request(url + "/output")["text"]
            if browser:
                assert ("discovered", json.dumps("Model choice from browser")) in calls, calls
            profiles = {item["name"]:item for item in request("/api/profiles")}
            assert profiles["local-opencode"]["sessions"][0]["runtime"]["model_id"] == "fixture/detailed"
            if browser:
                assert profiles["browser-model"]["sessions"][0]["runtime"]["model_id"] == "fixture/discovered"
        finally:
            (root / "opencode-mini-release").touch()
            release.set()
            release_follow_up.set()
            release_group.set()
            cancelled.set()
            endpoint.shutdown()
            worker.join()
    with sqlite3.connect(journal) as db:
        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                            (agent["address"], core)).fetchone()[0]
        records = db.execute("SELECT text, detail, event_key FROM journal WHERE reply_for=? AND kind='reply' AND detail='OpenCode' ORDER BY id",
                             (launch,)).fetchall()
        assert [(text, source) for text, source, _ in records] == [(text, "OpenCode") for text in saved_replies], records
        event = records[0][2]
        assert event.startswith("opencode:") and records[1][2] != event, records
        payload = json.dumps({"id":event[len("opencode:"):],"text":"Duplicate shouldn't overwrite the saved reply"})
    subprocess.run([bridge, "capture-opencode-reply"], input=payload, text=True, check=True,
                   env={"SWARMHUB_JOURNAL":str(journal), "SWARMHUB_LAUNCH_KEY":launch})
    with sqlite3.connect(journal) as db:
        assert db.execute("SELECT text FROM journal WHERE reply_for=? AND kind='reply' AND detail='OpenCode' ORDER BY id",
                          (launch,)).fetchall() == [(text,) for text in saved_replies]


@contextmanager
def webdav_fixture(root):
    import base64
    import html
    import http.server
    import ssl

    def openssl(*args):
        subprocess.run(["openssl", *args], cwd=root, check=True, capture_output=True, timeout=15)

    (root / "ca.cnf").write_text(
        "[req]\nprompt=no\ndistinguished_name=subject\nx509_extensions=ca\n"
        "[subject]\nCN=Test WebDAV CA\n"
        "[ca]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n"
    )
    openssl("req","-new","-x509","-nodes","-newkey","rsa:2048","-days","3","-config","ca.cnf",
            "-keyout","ca.key","-out","ca.pem")
    openssl("req","-new","-nodes","-newkey","rsa:2048","-subj","/CN=127.0.0.1",
            "-keyout","webdav.key","-out","webdav.csr")
    (root / "webdav.ext").write_text("subjectAltName=IP:127.0.0.1\nextendedKeyUsage=serverAuth\n")
    openssl("x509","-req","-in","webdav.csr","-CA","ca.pem","-CAkey","ca.key","-CAcreateserial",
            "-days","2","-extfile","webdav.ext","-out","webdav.pem")
    password = root / "webdav-password"
    secret = "fixture-only-webdav-password"
    password.touch(mode=0o600)
    password.write_text(secret + "\n")
    authorization = "Basic " + base64.b64encode(f"fixture:{secret}".encode()).decode()
    calls = []
    uploads = {}
    payload = "The original connected notes.\n".encode()
    filename = "Policy & notes.txt"
    named_path = "/reports/Team%20blue/" + urllib.parse.quote(filename, safe="")

    class WebDav(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *_):
            pass

        def reply(self, status, data=b"", **headers):
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def allowed(self):
            calls.append((self.command, self.path))
            if self.headers.get("Authorization") != authorization:
                self.reply(401)
                return False
            return True

        @staticmethod
        def resource(href, folder=False, size=None):
            kind = "<d:collection/>" if folder else ""
            size_xml = f"<d:getcontentlength>{size}</d:getcontentlength>" if size is not None else ""
            return (f"<d:response><d:href>{html.escape(href)}</d:href><d:propstat><d:prop>"
                    f"<d:resourcetype>{kind}</d:resourcetype>{size_xml}</d:prop><d:status>HTTP/1.1 200 OK</d:status>"
                    "</d:propstat></d:response>")

        def do_PROPFIND(self):
            self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if not self.allowed():
                return
            if self.headers.get("Depth") != "1":
                self.reply(400)
                return
            if self.path == "/reports/":
                children = [
                    self.resource("/reports/", True), self.resource("/reports/Team%20blue/", True),
                    self.resource("/reports/huge.bin", size=9*1024*1024),
                    self.resource("/reports/redirect.txt"), self.resource("/reports/stream.bin"),
                    self.resource("/outside/ignored.txt"), self.resource("https://elsewhere.invalid/reports/other.txt"),
                    self.resource("/reports/bad%2Fname.txt"), self.resource("/reports/nested/ignored.txt"),
                ]
            elif self.path == "/reports/Team%20blue/":
                target = "https://127.0.0.1:" + str(self.server.server_port) + named_path
                children = [self.resource(self.path, True), self.resource(target, size=len(payload))]
            else:
                self.reply(404)
                return
            xml = ("<d:multistatus xmlns:d=\"DAV:\">" + "".join(children) + "</d:multistatus>").encode()
            self.reply(207,xml,**{"Content-Type":"application/xml"})

        def do_GET(self):
            if not self.allowed():
                return
            if urllib.parse.unquote(self.path) == urllib.parse.unquote(named_path):
                self.reply(200,payload)
            elif self.path == "/reports/redirect.txt":
                self.reply(302,Location="/outside/redirect-target")
            elif self.path == "/reports/stream.bin":
                self.send_response(200)
                self.send_header("Transfer-Encoding","chunked")
                self.end_headers()
                chunk = b"x" * (512 * 1024)
                try:
                    for _ in range(18):
                        self.wfile.write(b"80000\r\n" + chunk + b"\r\n")
                    self.wfile.write(b"0\r\n\r\n")
                except (BrokenPipeError,ConnectionResetError,ssl.SSLError):
                    self.close_connection = True
            else:
                self.reply(404)

        def do_PUT(self):
            data = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            if not self.allowed():
                return
            target = urllib.parse.unquote(self.path)
            if self.headers.get("If-None-Match") != "*":
                self.reply(400)
            elif target == urllib.parse.unquote(named_path) or target in uploads:
                self.reply(412)
            elif target.rsplit("/", 1)[0] not in ("/reports", "/reports/Team blue"):
                self.reply(409)
            else:
                uploads[target] = data
                self.reply(201)

    server = http.server.ThreadingHTTPServer(("127.0.0.1",0), WebDav)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(str(root/"webdav.pem"), str(root/"webdav.key"))
    server.socket = context.wrap_socket(server.socket,server_side=True)
    thread = threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    try:
        yield {
            "SWARMHUB_WEBDAV_URL":f"https://127.0.0.1:{server.server_port}/reports",
            "SWARMHUB_WEBDAV_USERNAME":"fixture", "SWARMHUB_WEBDAV_PASSWORD_FILE":str(password),
            "SWARMHUB_WEBDAV_CA_FILE":str(root/"ca.pem"),
        }, calls, filename, payload, uploads
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


@contextmanager
def github_project_fixture(hold=None):
    import http.server
    calls = []
    prefix = "/repos/fixture/release-board/"
    issue = {"number":5,"title":"Release issue","state":"open"}
    pull = {"number":12,"title":"Prepare release notes","state":"open"}
    pull_text = "Review the café notes. <img src=x onerror=alert(1)>"

    class GitHub(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def reply(self, status, body, **headers):
            data = json.dumps(body).encode()
            self.send_response(status)
            for key, value in headers.items():
                self.send_header(key, value)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length",str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            path = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(path.query)
            calls.append((self.command,path.path,query))
            if (self.headers.get("Authorization") != "Bearer swarmhub-fixture-only"
                or self.headers.get("Accept") != "application/vnd.github.text+json"
                or self.headers.get("X-GitHub-Api-Version") != "2022-11-28"):
                self.reply(401,{"message":"Fixture auth missing"})
            elif path.path == prefix+"issues" and query == {"state":["open"],"page":["1"],"per_page":["25"]}:
                self.reply(200,[issue,{**pull,"pull_request":{"url":"http://outside.invalid/trap"}}],
                           Link='<http://outside.invalid/trap>; rel="next"')
            elif path.path == prefix+"issues" and query == {"state":["open"],"page":["2"],"per_page":["25"]}:
                self.reply(200,[{"number":16,"title":"Another open issue","state":"open"}])
            elif path.path == prefix+"issues/5":
                self.reply(200,{**issue,"body_text":"Offline-ready test notes. <script>window.projectInjected=true</script>"})
            elif path.path == prefix+"pulls/12":
                self.reply(200,{**pull,"body_text":pull_text,"body":"Do not use the Markdown when body_text exists.",
                                "html_url":"http://outside.invalid/fake"})
            elif path.path == prefix+"issues/88":
                self.reply(307,{},Location="/escaped-repository")
            elif hold and path.path == prefix+"issues/98":
                started, release = hold
                started.set()
                release.wait(8)
                try:
                    self.reply(200,{"number":98,"title":"Delayed private issue","state":"open","body_text":"Do not return a revoked reply."})
                except (BrokenPipeError, ConnectionResetError):
                    pass
            elif hold and path.path == prefix+"issues/99":
                self.reply(200,{"number":99,"title":"Reflected fixture credential","state":"open","body_text":"Ignore swarmhub-fixture-only."})
            else:
                self.reply(404,{"message":"No fixture item."})

        def do_POST(self):
            calls.append((self.command,self.path,{}))
            self.reply(405,{})

    server = http.server.ThreadingHTTPServer(("127.0.0.1",0),GitHub)
    thread = threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    try:
        yield {"SWARMHUB_GITHUB_REPOSITORY":"fixture/release-board",
               "SWARMHUB_GITHUB_TEST_ORIGIN":f"http://127.0.0.1:{server.server_port}"},calls,pull_text
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)


def smoke(hc, bridge, chrome=None):
    sandbox = os.environ.get("SWARMHUB_TEST_TMPDIR", "/var/tmp")
    with tempfile.TemporaryDirectory(prefix="swarmhub-", dir=sandbox) as temp, ExitStack() as test_resources:
        root = Path(temp)
        selected_focus = os.environ.get("SWARMHUB_TEST_FOCUS")
        slack_secret = secrets.token_hex(16) if selected_focus == "slack-events" else None
        dav = (test_resources.enter_context(webdav_fixture(root))
               if selected_focus in ("connected-files", "connected-save", "vault") else None)
        github_hold = (threading.Event(),threading.Event()) if selected_focus == "github-access" else None
        github = (test_resources.enter_context(github_project_fixture(github_hold))
                  if selected_focus in ("github-project", "github-access") else None)
        vault_key = root / "vault-key" if selected_focus in ("vault", "vault-request", "drive-oauth") else None
        if vault_key:
            vault_key.touch(mode=0o600)
            vault_key.write_text(secrets.token_hex(32)+"\n")
        if selected_focus == "vault":
            password_file = Path(dav[0].pop("SWARMHUB_WEBDAV_PASSWORD_FILE"))
            vault_password = password_file.read_text().rstrip("\n")
            password_file.unlink()
            dav[0]["SWARMHUB_WEBDAV_VAULT_ENTRY"] = "Reports credential"
        drive_oauth_file = root / "drive-oauth.json" if selected_focus in ("drive-oauth", "agent-drive-ui") else None
        if drive_oauth_file:
            drive_oauth_file.touch(mode=0o600)
            drive_oauth_file.write_text(json.dumps({"folder_id":"fixture-folder","client_id":"fixture-client.apps.googleusercontent.com",
                                                   "client_secret":"fixture-client-secret",
                                                   **({"browser_oauth":True} if selected_focus == "drive-oauth" else {"refresh_token":"fixture-unused-token"})}))
        for folder in ("run", "state", "config"):
            (root / folder).mkdir(mode=0o700)
        fixture = root / "fixture.py"
        fixture.write_text(FIXTURE)
        claude = root / "fake-claude"
        claude.write_text(CLAUDE_FIXTURE)
        claude.chmod(0o700)
        templates = root / "config/herdr-core/templates"
        templates.mkdir(parents=True)
        (templates / "fixture.md").write_text(
            f"---\ndescription: Model-free test agent\ncommand: python3 {fixture}\nstop: ctrl+c\n---\n"
        )
        if selected_focus == "vault-request":
            vault_fixture = root / "vault-agent.py"
            vault_fixture.write_text(VAULT_AGENT_FIXTURE)
            (templates / "vault-fixture.md").write_text(
                f"---\ndescription: Model-free Vault agent\ncommand: python3 {vault_fixture}\n---\n"
            )
        if selected_focus == "desktop-teaching":
            desktop_fixture = root / "desktop-click-fixture.py"
            desktop_fixture.write_text(Path(__file__).with_name("desktop-click-fixture.py").read_text())
            command = shlex.join([bridge, "run-desktop", "--", "/usr/bin/python3", str(desktop_fixture), str(root / "desktop-clicks.log")])
            (templates / "desktop-fixture.md").write_text(f"---\ndescription: Scratch X11 test agent\ncommand: {command}\n---\n")
        if selected_focus == "bot-helper-model":
            (templates / "coding-fixture.md").write_text((templates / "fixture.md").read_text())
            fixture.write_text(FIXTURE.replace('status("idle")', 'print("Launch model=" + os.environ.get("SWARMHUB_MODEL_ID", "") + " auto=" + os.environ.get("SWARMHUB_PROJECT_AUTO", ""), flush=True)\nstatus("idle")', 1))
        (templates / "invalid.md").write_text("missing frontmatter\n")
        (templates / "claude-fixture.md").write_text(
            f"---\ndescription: Claude Stop hook test\n"
            f"command: SWARMHUB_CLAUDE_BIN={shlex.quote(str(claude))} "
            f"{shlex.quote(bridge)} run-claude --model fixture-model\n---\n"
        )
        (templates / "approval-fixture.md").write_text(
            f"---\ndescription: Claude permission hook test\n"
            f"command: SWARMHUB_CLAUDE_BIN={shlex.quote(str(claude))} "
            f"{shlex.quote(bridge)} run-claude --workspace-approvals --model fixture-model\n---\n"
        )
        (templates / "codex-fixture.md").write_text(
            f"---\ndescription: Codex hooks test\n"
            f"command: SWARMHUB_CODEX_BIN={shlex.quote(str(claude))} "
            f"{shlex.quote(bridge)} run-codex --workspace-approvals --model fixture-model\n---\n"
        )
        gemini = root / "fake-gemini"
        gemini.write_text(GEMINI_FIXTURE)
        gemini.chmod(0o700)
        # Gemini CLI keeps the chosen way to sign in in its own settings; the hook only reads it.
        for home, chosen in (("gemini-home", {"security": {"auth": {"selectedType": "oauth-personal"}}}),
                             ("gemini-new-home", {})):
            (root / home / ".gemini").mkdir(parents=True)
            (root / home / ".gemini/settings.json").write_text(json.dumps(chosen))
            (templates / ("gemini-fixture.md" if chosen else "gemini-unsigned.md")).write_text(
                f"---\ndescription: Gemini CLI hooks test\n"
                f"command: GEMINI_CLI_HOME={shlex.quote(str(root / home))} "
                f"SWARMHUB_GEMINI_BIN={shlex.quote(str(gemini))} {shlex.quote(bridge)} run-gemini\n---\n"
            )
        legacy_version = os.environ.get("SWARMHUB_TEST_SCHEMA", "1")
        seed_legacy_database(root / "workspace", legacy_version)
        (root / "config/herdr-core/config.toml").write_text("notes_quiet = 0\ndraft_wait = 0\n")
        token = secrets.token_hex(32)
        socket = root / "hc.sock"
        core_env = {
            "HOME": temp, "PATH": "/usr/bin:/bin", "HC_SESSION": "swarmhub-test",
            "XDG_RUNTIME_DIR": str(root / "run"), "XDG_STATE_HOME": str(root / "state"),
            "XDG_CONFIG_HOME": str(root / "config"), "HC_SOCKET": str(socket),
            "HC_SETTLE_MS": "0", "HC_STARTED_MS": "5000", "LANG": "C.UTF-8",
        }

        if selected_focus == "vault-request":
            # A separately started Core may have inherited the bridge's setting.
            core_env["SWARMHUB_VAULT_KEY_FILE"] = str(vault_key)

        def cli(*args):
            result = subprocess.run([hc, *args], env=core_env, cwd=root,
                                    capture_output=True, text=True, timeout=16)
            assert result.returncode == 0, result.stderr
            return result.stdout

        def start_bridge(port="0", agents=None):
            process = subprocess.Popen([bridge], env={
                # The folder bots get their private workspace folders in; without one they start in Core's.
                **({"SWARMHUB_AGENT_CWD": str(agents)} if agents else {}),
                "HC_SOCKET": str(socket), "SWARMHUB_ACCESS_TOKEN": token, "SWARMHUB_PORT": port,
                "SWARMHUB_DATA_DIR": str(root / "workspace"),
                **(dav[0] if dav else {}),
                **(github[0] if github else {}),
                **({"SWARMHUB_VAULT_KEY_FILE":str(vault_key)} if vault_key else {}),
                **({"SWARMHUB_SLACK_VAULT_ENTRY":"Slack credential"} if selected_focus == "vault" else {}),
                **({"SWARMHUB_DRIVE_CREDENTIALS_FILE":str(drive_oauth_file)} if drive_oauth_file else {}),
                **({"SWARMHUB_SLACK_SIGNING_SECRET":slack_secret} if slack_secret else {}),
                **({"SWARMHUB_WEBDAV_ALLOW_UPLOADS":"1"} if selected_focus == "connected-save" else {}),
            }, stdout=subprocess.PIPE, text=True)
            line = process.stdout.readline()
            if not line.startswith("SwarmHub · http://"):
                process.terminate()
                process.wait(timeout=5)
                raise AssertionError(line)
            return process, line.strip().split(" · ", 1)[1]

        def stop(process):
            process.terminate()
            process.wait(timeout=5)
            process.stdout.close()

        cli("server", "start")
        core_running = True
        try:
            cli("run", "--bg", "--name", "outside", "/bin/sleep", "120")
            with socket_module.socket(socket_module.AF_UNIX) as client:
                client.connect(str(socket))
                request_line = {"jsonrpc": "2.0", "id": 1, "method": "terminal.get",
                                "params": {"terminal": "outside"}}
                client.sendall(json.dumps(request_line).encode() + b"\n")
                with client.makefile("rb") as messages:
                    unrelated = json.loads(messages.readline())["result"]
            process, base = start_bridge()

            def request(path, body=None, status=200, authorized=True, origin=None, host=None, media_type=None, timeout=20):
                headers = {"Authorization": f"Bearer {token}"} if authorized else {}
                if host:
                    headers["Host"] = host
                data = None
                if body is not None:
                    raw = isinstance(body, bytes)
                    data = body if raw else json.dumps(body).encode()
                    headers.update({"Content-Type": media_type or ("application/octet-stream" if raw else "application/json"),
                                    "Origin": origin or base})
                try:
                    response = urllib.request.urlopen(
                        urllib.request.Request(base + path, data=data, headers=headers), timeout=timeout)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    assert response.status == status, (path, response.status, response.read())
                    if response.headers.get_content_type() == "application/json":
                        return json.load(response)
                    return response.read()

            def test_approvals():
                nonlocal process, base
                port = base.rsplit(":", 1)[1]
                approved_agent = request("/api/agents", {"name": "review-agent", "template": "approval-fixture",
                                                          "task": "review startup"}, status=201)
                review_url = f"/api/agents/{approved_agent['address']}/{approved_agent['created_ms']}"
                request("/api/approvals", status=401, authorized=False)

                def pending_approval():
                    rows = request("/api/approvals")["pending"]
                    return rows[0] if len(rows) == 1 else None

                for action, outcome, key in (("approve", "allow", "approved"),
                                             ("deny", "deny", "denied"),
                                             ("terminal", "terminal", "terminal")):
                    token_task = "approval " + action
                    request(review_url + "/messages", {"text": token_task})
                    review = until(pending_approval)
                    assert review["agent"] == "review-agent" and review["tool"] == "Bash"
                    assert "9007199254740993" in review["arguments"] and "printf fixture" in review["arguments"]
                    action_url = f"/api/approvals/{review['id']}"
                    request(action_url, action, status=202)
                    request(action_url, action, status=409)
                    until(lambda: f"{token_task}: permission outcome {outcome}" in request(review_url + "/output")["text"])
                    def recorded():
                        items = request("/api/approvals")["history"]
                        return items[0] if items and items[0]["id"] == review["id"] else None
                    summary = until(recorded)
                    assert summary["state"] == key and "arguments" not in summary and "cwd" not in summary
                request(review_url + "/messages", {"text": "approval interactive"})
                until(lambda: "approval interactive: permission outcome terminal" in request(review_url + "/output")["text"])
                assert request("/api/approvals")["pending"] == []
                request(review_url + "/messages", {"text": "approval restart"})
                pending = until(pending_approval)
                stop(process)
                process = None
                process, base = start_bridge(port)
                until(lambda: "approval restart: permission outcome terminal" in request(review_url + "/output")["text"])
                inbox = request("/api/approvals")
                assert inbox["pending"] == []
                assert inbox["history"][0]["id"] == pending["id"] and inbox["history"][0]["state"] == "terminal"
                request(f"/api/approvals/{pending['id']}", "approve", status=409)

            def test_codex(core):
                launched = request("/api/agents", {"name": "codex-agent", "template": "codex-fixture",
                                                    "task": "Codex first task"}, status=201)
                key = f"{launched['address']}/{launched['created_ms']}"
                path = f"/api/agents/{key}"
                history_path = f"/api/history/{core}/{key}"
                events = request(history_path)["items"]
                assert [event["kind"] for event in events] == ["task", "reply"]
                assert events[1]["detail"] == "Codex" and "Structured reply for Codex first task" in events[1]["text"]
                request(path + "/messages", {"text": "approval codex"})
                review = until(lambda: next((r for r in request("/api/approvals")["pending"]
                                             if r["agent"] == "codex-agent"), None))
                assert review["provider"] == "Codex" and review["tool"] == "Bash"
                assert "printf fixture" in review["arguments"]
                request(f"/api/approvals/{review['id']}", "deny", status=202)
                until(lambda: "approval codex: permission outcome deny" in request(path + "/output")["text"])
                def codex_replies():
                    items = request(history_path)["items"]
                    return items if len(items) >= 4 else None
                events = until(codex_replies)
                assert [event["kind"] for event in events] == ["task", "reply", "task", "reply"]
                assert all("Duplicate reply" not in event["text"] for event in events)
                assert any(row["id"] == review["id"] and row["provider"] == "Codex" and row["state"] == "denied"
                           for row in request("/api/approvals")["history"])

            def test_gemini(core):
                # Gemini CLI only starts in a bot's own folder, so this part runs with a place for those.
                nonlocal process, base
                port = base.rsplit(":", 1)[1]
                agents = root / "gemini-agents"
                agents.mkdir(mode=0o700)
                stop(process)
                process = None
                process, base = start_bridge(port, agents)
                shown = request("/api/workspace")["templates"]
                choice = next(t for t in shown if t["name"] == "gemini-fixture")
                assert choice["runtime"] == {"harness": "Gemini CLI", "provider": None, "model": None,
                                             "display_name": "Gemini"}
                assert choice["beta"] is True and "beta" in choice["note"] and choice["model_agent"] == "Gemini CLI"
                # Beta programs are listed last, so none of them is "the first one" while another program is there.
                assert {t["name"] for t in shown[-2:]} == {"gemini-fixture", "gemini-unsigned"}
                assert all("beta" not in t and "note" not in t for t in shown[:-2])
                log = root / "fake-gemini.log"
                journal = root / "workspace/workspace.sqlite3"

                def status(agent):
                    return next(a for a in request("/api/workspace")["agents"]
                                if a["address"] == agent["address"])["status"]

                # Not signed in: Gemini CLI shows its sign-in question. The bot must never look ready, and
                # its first message must not be typed into that question.
                fresh = request("/api/agents", {"name": "gemini-new", "template": "gemini-unsigned",
                                                 "task": "Gemini unsigned task"}, status=201)
                assert not fresh["first_message"]["sent"], fresh
                until(lambda: status(fresh) == {"state": "blocked", "kind": "auth"})
                fresh_url = f"/api/agents/{fresh['address']}/{fresh['created_ms']}"
                request(fresh_url + "/messages", {"text": "Gemini typed anyway"}, status=409)
                # Stop does not make a program that waits for a sign-in look ready either.
                request(fresh_url + "/interrupt", {})
                time.sleep(1.5)
                assert status(fresh) == {"state": "blocked", "kind": "auth"}
                assert "agent-gemini-new: received" not in log.read_text()
                request(fresh_url + "/end", {})

                launched = request("/api/agents", {"name": "gemini-agent", "template": "gemini-fixture",
                                                    "task": "Gemini first task"}, status=201)
                assert launched["first_message"]["sent"], launched
                key = f"{launched['address']}/{launched['created_ms']}"
                path = f"/api/agents/{key}"
                history_path = f"/api/history/{core}/{key}"

                def rows(count):
                    def read():
                        items = request(history_path)["items"]
                        return items if len(items) >= count else None
                    return until(read)

                events = rows(2)
                assert [event["kind"] for event in events] == ["task", "reply"]
                assert events[1]["detail"] == "Gemini CLI"
                assert events[1]["text"] == "Gemini reply for Gemini first task"
                until(lambda: status(launched) == {"state": "done"})
                folder = agents / "agent-gemini-agent"
                assert (folder / ".gemini/settings.json").is_file()

                # A tool call shows as activity, and the reply is all the turn wrote.
                request(path + "/messages", {"text": "use a tool"})
                events = rows(4)
                assert events[3]["text"] == "I will run a command.\nThe command finished."
                stream = urllib.request.urlopen(urllib.request.Request(
                    base + path + "/events", headers={"Authorization": f"Bearer {token}"}), timeout=8)
                with stream:
                    while not (data := stream.readline()).startswith(b"data:"):
                        assert data, "the event stream ended"
                tools = json.loads(data[5:])["tools"]
                assert [(t["tool"], t["detail"], t["finished"], t["failed"]) for t in tools] == [
                    ("run_shell_command", "printf fixture", True, False)], tools

                # A turn without text saves no reply.
                request(path + "/messages", {"text": "say nothing"})
                until(lambda: "agent-gemini-agent: received say nothing" in log.read_text())
                until(lambda: status(launched) == {"state": "done"})
                assert len(request(history_path)["items"]) == 5

                # A permission question blocks; another task is not typed into it.
                request(path + "/messages", {"text": "ask permission"})
                until(lambda: status(launched) == {"state": "blocked", "kind": "permission"})
                request(path + "/messages", {"text": "typed into the question"}, status=409)
                (folder / "permission-answer").write_text("allow")
                events = rows(8)
                assert events[7]["kind"] == "reply"
                until(lambda: status(launched) == {"state": "done"})

                # Refused in the terminal: Gemini CLI says nothing more, so the bot still reads as asking.
                # The app's Stop is the way out, and the next task goes through.
                request(path + "/messages", {"text": "ask permission"})
                until(lambda: status(launched) == {"state": "blocked", "kind": "permission"})
                (folder / "permission-answer").write_text("refuse")
                until(lambda: "agent-gemini-agent: refused" in log.read_text())
                assert status(launched) == {"state": "blocked", "kind": "permission"}
                request(path + "/interrupt", {})
                until(lambda: status(launched) == {"state": "idle"})
                request(path + "/messages", {"text": "after the refusal"})
                until(lambda: any(e["text"] == "Gemini reply for after the refusal"
                                  for e in request(history_path)["items"]))

                # A cancelled turn ends without a hook too. Stop leaves the bot idle, not working for ever.
                request(path + "/messages", {"text": "wait here"})
                until(lambda: status(launched) == {"state": "working"})
                assert request(path + "/interrupt", {})["outcome"] == "stopped"
                until(lambda: "agent-gemini-agent: cancelled" in log.read_text())
                until(lambda: status(launched) == {"state": "idle"})
                request(path + "/messages", {"text": "after the stop"})
                until(lambda: any(e["text"] == "Gemini reply for after the stop"
                                  for e in request(history_path)["items"]))
                assert not any("typed" in e["text"] for e in request(history_path)["items"] if e["kind"] == "reply")

                # A chosen model reaches Gemini CLI as its own option.
                picked = request("/api/agents", {"name": "gemini-flash", "template": "gemini-fixture",
                                                  "task": "Gemini model task", "model_id": "flash"}, status=201)
                assert picked["first_message"]["sent"], picked
                until(lambda: 'agent-gemini-flash: args ["--model", "flash"]' in log.read_text())

                # What run-gemini refuses, it refuses in a sentence; a hook outside a session does nothing.
                env = {"PATH": "/usr/bin:/bin", "SWARMHUB_JOURNAL": str(journal), "SWARMHUB_LAUNCH_KEY": "0" * 32,
                       "SWARMHUB_GEMINI_BIN": "/bin/true"}
                refused = subprocess.run([bridge, "run-gemini", "--workspace-approvals"], env=env, cwd=folder,
                                         capture_output=True, text=True)
                assert refused.returncode != 0 and "Remove --workspace-approvals" in refused.stderr, refused
                outside = subprocess.run([bridge, "run-gemini"], env=env, cwd=root, capture_output=True, text=True)
                assert outside.returncode != 0 and "only starts in a bot" in outside.stderr, outside
                assert not (root / ".gemini").exists()
                for stdin, hook_env in ((b'{"hook_event_name":"SessionStart"}', {"PATH": "/usr/bin:/bin"}),
                                        (b"not json", env)):
                    quiet = subprocess.run([bridge, "gemini-hook"], input=stdin, env=hook_env, capture_output=True)
                    assert quiet.returncode == 0 and json.loads(quiet.stdout) == {}, quiet
                for agent in (launched, picked):
                    request(f"/api/agents/{agent['address']}/{agent['created_ms']}/end", {})
                # Without a place for bot folders, run-gemini says why it will not start instead of hanging.
                stop(process)
                process = None
                process, base = start_bridge(port)
                homeless = request("/api/agents", {"name": "gemini-homeless", "template": "gemini-fixture",
                                                    "task": "Gemini nowhere"}, status=201)
                assert not homeless["first_message"]["sent"]
                homeless_url = f"/api/agents/{homeless['address']}/{homeless['created_ms']}"
                until(lambda: "only starts in a bot" in request(homeless_url + "/output")["text"])

            def test_skills(core):
                request("/api/skills", status=401, authorized=False)
                request("/api/skills", {"name": "Oversized", "summary": "", "instructions": "x" * 10241}, status=422)
                first = request("/api/agents", {"name": "skills-one", "template": "fixture",
                                               "task": "initialize"}, status=201)
                other = request("/api/agents", {"name": "skills-two", "template": "fixture",
                                               "task": "initialize"}, status=201)
                one = {field: first[field] for field in ("address", "created_ms")}
                two = {field: other[field] for field in ("address", "created_ms")}
                original = {"name": "Review an input", "summary": "When a report needs review",
                            "instructions": "Inspect the report and summarize the findings."}
                skill = request("/api/skills", original, status=201)
                url = f"/api/skills/{skill['id']}"
                assert skill["version"] == 1 and not skill["archived"]
                updated = {**original, "instructions": "Return the three most important findings.", "version": 1}
                assert request(url, updated)["version"] == 2
                request(url, updated, status=409)
                request(url + "/availability", {"core": core, "target": one, "enabled": False})
                for target, expected in ((one, False), (two, True)):
                    query = urllib.parse.urlencode({"core": core, **target})
                    assert request(url + "?" + query)["enabled"] is expected
                assert request(url + "/archive", True)["archived"]
                assert not request(url + "/archive", False)["archived"]

            try:
                if selected_focus == "bot-helper-model":
                    catalog = {"harness": "Fixture", "model_transport": "environment"}
                    (root / "workspace/runtime-catalog.json").write_text(json.dumps({"fixture": catalog, "coding-fixture": catalog}))
                    default = {"template": "fixture", "model": "by-difficulty"}
                    chosen = {"template": "coding-fixture", "model": "coding-model"}
                    request("/api/helper-policy", {"max_running": 4, "stop_after_seconds": 60, "difficulties": {"easy": default}})
                    owner = "10000000-0000-4000-8000-000000000001"
                    other = "20000000-0000-4000-8000-000000000002"
                    def parent(name, bot=None):
                        args = {"name": name, "template": "fixture", "task": "Initialize", "model_id": "chat-model"}
                        if bot:
                            args["workspace_id"] = bot
                        return request("/api/agents", args, status=201)
                    direct = parent("direct", owner)
                    group = parent("group-legacy")
                    second = parent("other", other)
                    url = "/api/bot-agent-settings/" + owner
                    assert request(url) == {"choice": None, "auto_mode": False}
                    assert request(url, {"choice": chosen, "existing_agents": ["group-legacy"]})["choice"] == chosen
                    request(url, {"choice": {"template": "missing", "model": "x"}}, status=422)
                    assert request(url)["choice"] == chosen
                    assert request(url, {"auto_mode": True}) == {"choice": chosen, "auto_mode": True}
                    fresh = parent("fresh", owner)
                    assert "Launch model=chat-model auto=1" in request(f"/api/agents/{fresh['address']}/{fresh['created_ms']}/output")["text"]
                    def spawn(agent, name, expected, difficulty="easy", auto=True):
                        journal = root / "workspace/workspace.sqlite3"
                        with sqlite3.connect(journal) as db:
                            key, = db.execute("SELECT launch_key FROM journal WHERE address=? AND created_ms=? AND launch_key IS NOT NULL",
                                              (agent["address"], agent["created_ms"])).fetchone()
                        cmd = [bridge, "helper", "start", "--name", name, "--difficulty", difficulty, "Read the task."]
                        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30,
                                                env={**core_env, "SWARMHUB_JOURNAL": str(journal), "SWARMHUB_LAUNCH_KEY": key})
                        if expected is None:
                            assert result.returncode != 0, result.stdout
                            return
                        assert result.returncode == 0, result.stderr
                        route = f"/api/agents/{agent['address']}/{agent['created_ms']}/helpers"
                        helper = until(lambda: next((h for h in request(route)["helpers"] if h["name"] == name), None))
                        assert (helper["template"], helper["model"]) == (expected["template"], expected["model"])
                        output = f"/api/agents/{helper['address']}/{helper['created_ms']}/output"
                        stamp = "Launch model=" + expected["model"] + " auto=" + ("1" if auto else "")
                        assert until(lambda: stamp in request(output)["text"])
                    # Run the production wrappers against an argument recorder, without contacting a provider.
                    probe = root / "probe-agent"
                    server_log = root / "codex-server-args.json"
                    probe.write_text(f"#!/usr/bin/python3\nimport json,os,pathlib,socket,sys,time\nif 'app-server' in sys.argv and '--listen' in sys.argv:\n    pathlib.Path({str(server_log)!r}).write_text(json.dumps(sys.argv[1:]))\n    sock_path = sys.argv[sys.argv.index('--listen') + 1].removeprefix('unix://')\n    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n    srv.bind(sock_path)\n    srv.listen(4)\n    time.sleep(2)\n    sys.exit(0)\nprint(json.dumps(sys.argv[1:]))\n")
                    probe.chmod(0o700)
                    agy_ws = root / "agy-bot-ws"
                    agy_ws.mkdir(mode=0o700, exist_ok=True)
                    (agy_ws / ".swarmhub-workspace").write_bytes(b"")
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        key, = db.execute("SELECT launch_key FROM journal WHERE agent='direct' AND launch_key IS NOT NULL").fetchone()
                    for auto in ("", "1"):
                        env = {**core_env, "SWARMHUB_JOURNAL": str(journal), "SWARMHUB_LAUNCH_KEY": key,
                               "SWARMHUB_CODEX_STREAM": "off", "SWARMHUB_CODEX_BIN": str(probe),
                               "SWARMHUB_CLAUDE_BIN": str(probe), "SWARMHUB_ANTIGRAVITY_BIN": str(probe),
                               "SWARMHUB_PROJECT_AUTO": auto}
                        def wrapper(cmd, extra_env=None, cwd=None):
                            merged = {**env, **(extra_env or {})}
                            return json.loads(subprocess.check_output([bridge, cmd, "--workspace-approvals"] if cmd != "run-antigravity" else [bridge, cmd], env=merged, cwd=cwd, timeout=15))
                        args = wrapper("run-codex")
                        assert ('sandbox_mode="workspace-write"' in args) == bool(auto)
                        # Remote streaming mode must pass Auto mode overrides to both app-server and TUI client,
                        # while keeping writable_roots on the server only (Codex --remote rejects writable_roots).
                        remote_args = wrapper("run-codex", {"SWARMHUB_CODEX_STREAM": "on", "SWARMHUB_HELPER_SPOOL": str(agy_ws)})
                        server_args = json.loads(server_log.read_text())
                        assert "--remote" in remote_args
                        assert ('sandbox_mode="workspace-write"' in remote_args) == bool(auto)
                        assert ('approvals_reviewer="auto_review"' in remote_args) == bool(auto)
                        assert ('computer_use.default_app_access="allow"' in remote_args) == bool(auto)
                        assert any("mcp_elicitations=false" in arg for arg in remote_args) == bool(auto)
                        assert not any("writable_roots" in arg for arg in remote_args)
                        assert ('sandbox_mode="workspace-write"' in server_args) == bool(auto)
                        assert ('approvals_reviewer="auto_review"' in server_args) == bool(auto)
                        assert ('computer_use.default_app_access="allow"' in server_args) == bool(auto)
                        assert any("PermissionRequest" in arg for arg in server_args) == (not bool(auto))
                        assert any("writable_roots" in arg for arg in server_args) == bool(auto)
                        args = wrapper("run-claude")
                        assert ("--permission-mode" in args) == bool(auto)
                        if auto:
                            assert args[args.index("--permission-mode") + 1] == "auto"
                        settings = json.loads(args[args.index("--settings") + 1])
                        assert (settings.get("permissions", {}).get("defaultMode") == "acceptEdits") == bool(auto)
                        assert settings.get("sandbox", {}).get("autoAllowBashIfSandboxed", False) == bool(auto)
                        assert ("PermissionRequest" in settings["hooks"]) == (not bool(auto))
                        agy_args = wrapper("run-antigravity", {"SWARMHUB_LAUNCH_MODEL": "antigravity:gemini-4-neon-high"}, cwd=agy_ws)
                        assert agy_args[:3] == ["--model", "gemini-4-neon-high", "--settings"]
                        agy_settings = json.loads(agy_args[3])
                        assert str(agy_ws) in agy_settings["trustedWorkspaces"]
                        assert (agy_settings.get("allowNonWorkspaceAccess") is True) == bool(auto)
                        assert (agy_settings.get("artifactReviewPolicy") == "always-proceed") == bool(auto)
                        assert (agy_args[4:] == ["--mode", "auto", "--dangerously-skip-permissions"]) == bool(auto)
                    spawn(direct, "custom", chosen)
                    spawn(group, "legacy", chosen)
                    spawn(second, "other", default, auto=False)
                    spawn(direct, "blocked", None, difficulty="hard")
                    assert request(url, {"choice": None})["choice"] is None
                    assert request(url, {"auto_mode": False}) == {"choice": None, "auto_mode": False}
                    spawn(direct, "reset", default, auto=False)
                    assert "Launch model=chat-model" in request(f"/api/agents/{direct['address']}/{direct['created_ms']}/output")["text"]
                    return
                assert b"SwarmHub" in request("/", authorized=False)
                request("/api/workspace", status=401, authorized=False)
                request("/api/attention", status=401, authorized=False)
                request("/api/workspace", status=403, host="external.test")
                request("/api/agents", {}, status=403, origin="http://external.test")
                state = request("/api/workspace")
                assert state["version"] and state["agents"] == [] and state["attachments"]
                assert state["terminal_attach"]
                foreign = http.client.HTTPConnection("127.0.0.1", int(base.rsplit(":", 1)[1]), timeout=8)
                try:
                    foreign.request("GET", "/attach/t1/1", headers={
                        "Origin": "http://external.test", "Connection": "Upgrade", "Upgrade": "websocket",
                        "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "MDEyMzQ1Njc4OUFCQ0RFRg==",
                    })
                    assert foreign.getresponse().status == 403
                finally:
                    foreign.close()
                core = state["core"]
                expected_templates = {
                    "fixture": False, "invalid": True, "claude-fixture": False, "approval-fixture": False, "codex-fixture": False,
                    "gemini-fixture": False, "gemini-unsigned": False,
                }
                if selected_focus == "desktop-teaching":
                    expected_templates["desktop-fixture"] = False
                if selected_focus == "vault-request":
                    expected_templates["vault-fixture"] = False
                assert {t["name"]: bool(t["error"]) for t in state["templates"]} == expected_templates
                assert request("/api/history/legacy-core/t5/1")["items"][0]["text"] == "Preserve this task"
                def agent_done(agent):
                    return any(row["address"] == agent["address"] and row["status"] == {"state": "done"}
                               for row in request("/api/workspace")["agents"])

                def test_groups(linked):
                    linked_key = f"{linked['address']}/{linked['created_ms']}"
                    reviewer = request("/api/agents", {"name": "reviewer", "template": "claude-fixture",
                                                        "task": "review startup"}, status=201)
                    def target(agent):
                        return {field: agent[field] for field in ("address", "created_ms")}
                    left, right = target(linked), target(reviewer)
                    request("/api/groups", {"name": "Invalid", "members": [left, left]}, status=422)
                    team = request("/api/groups", {"name": "Spec review", "members": [left, right]}, status=201)
                    group_url = f"/api/groups/{team['id']}"
                    feed = group_url + "/messages"
                    edit = {"name": "Release review", "members": [left, right], "revision": team["revision"]}
                    team = request(group_url, edit)
                    def group_task(text, recipients, status=202):
                        return request(feed, {"text": text, "recipients": recipients, "revision": team["revision"]},
                                       status=status)
                    group_task("Wrong agent", [target(unrelated)], status=422)
                    group_task("One recipient only", [left])
                    def group_answer():
                        rows = request(feed)["items"]
                        return rows if len(rows) == 2 and rows[0]["deliveries"][0]["state"] == "sent" else None
                    group_rows = until(group_answer)
                    assert group_rows[1]["author"] == "claude-capture"
                    assert group_rows[1]["text"] == "Group answer to One recipient only"
                    assert [row["name"] for row in group_rows[0]["deliveries"]] == ["claude-capture"]
                    assert "token" not in json.dumps(group_rows)
                    reviewer_url = f"/api/agents/{right['address']}/{right['created_ms']}"
                    assert "One recipient only" not in request(reviewer_url + "/output")["text"]
                    request(reviewer_url + "/end", {})
                    group_task("One session already ended", [left, right])
                    def partial_delivery():
                        rows = request(feed)["items"]
                        if len(rows) == 4 and all(item["state"] != "pending" for item in rows[2]["deliveries"]):
                            return rows[2]["deliveries"]
                        return None
                    assert [(item["name"], item["state"]) for item in until(partial_delivery)] == [
                        ("claude-capture", "sent"), ("reviewer", "not_sent"),
                    ]
                    until(lambda: agent_done(linked))
                    alternate = request("/api/agents", {"name": "substitute", "template": "claude-fixture",
                                                        "task": "substitute startup"}, status=201)
                    substitute = target(alternate)
                    prior_revision = team["revision"]
                    new_edit = {"name": team["name"], "members": [left, substitute], "revision": prior_revision}
                    request(group_url, new_edit, status=401, authorized=False)
                    request(group_url, {**new_edit, "members": [left, left]}, status=422)
                    team = request(group_url, new_edit)
                    assert [row["name"] for row in team["members"]] == ["claude-capture", "substitute"]
                    request(group_url, new_edit, status=409)
                    request(feed, {"text": "Stale draft", "recipients": [left], "revision": prior_revision}, status=409)
                    group_task("Removed member", [right], status=422)
                    assert request(feed)["items"][0]["deliveries"] == group_rows[0]["deliveries"]
                    group_task("Task after the member change", [left, substitute])
                    until(lambda: any(row["author"] == "substitute" for row in request(feed)["items"]))
                    until(lambda: agent_done(linked))
                    updated = request(feed)["items"][4]
                    assert updated["text"] == "Task after the member change"
                    output_substitute = f"/api/agents/{substitute['address']}/{substitute['created_ms']}/output"
                    assert "fixture context: User: One session already ended" not in request(output_substitute)["text"]
                    assert "fixture context: User: One session already ended" in request(f"/api/agents/{linked_key}/output")["text"]
                    group_task("Follow-up for the new member", [substitute])
                    until(lambda: "fixture context: User: Task after the member change" in request(output_substitute)["text"])
                    until(lambda: any(row["author"] == "substitute" and row["text"] == "Group answer to Follow-up for the new member"
                                      for row in request(feed)["items"]))
                    until(lambda: agent_done(alternate))
                    assert "fixture context: User: One session already ended" not in request(output_substitute)["text"]
                    if os.environ.get("SWARMHUB_TEST_FOCUS") == "groups":
                        waiting = group_task("Wait for explicit group result", [left])
                        task_id = waiting["id"]
                        until(lambda: request(feed)["items"][-1]["deliveries"][0]["state"] == "sent")
                        journal = root / "workspace/workspace.sqlite3"
                        with sqlite3.connect(journal) as store:
                            reply_token, launch = store.execute(
                                "SELECT token,launch_key FROM group_deliveries WHERE message_id=?", (task_id,)
                            ).fetchone()
                            other, = store.execute(
                                "SELECT launch_key FROM group_members WHERE group_id=? AND address=?",
                                (team["id"], substitute["address"]),
                            ).fetchone()
                        def publish(*options, key=launch):
                            return subprocess.run([bridge, "group-reply", reply_token, *options],
                                                  input=b"Checking the summary.", capture_output=True,
                                                  env={"SWARMHUB_JOURNAL":str(journal), "SWARMHUB_LAUNCH_KEY":key})
                        assert publish("--draft", key=other).returncode != 0
                        assert publish("--draft", "--question").returncode != 0
                        assert publish("--draft").returncode == 0
                        page = request(feed)
                        assert page["items"][-1]["id"] == task_id
                        assert page["drafts"] == [{"author":"claude-capture", "task":"Wait for explicit group result",
                                                     "text":"Checking the summary."}]
                        assert not request(feed + "?before=" + str(task_id + 1)).get("drafts")
                        request(feed, status=401, authorized=False)
                        another = request("/api/groups", {"name":"Unrelated group","members":[left,substitute]}, status=201)
                        assert not request(f"/api/groups/{another['id']}/messages").get("drafts")
                        with sqlite3.connect(journal) as store:
                            store.execute("UPDATE group_deliveries SET draft_ms=1 WHERE message_id=?", (task_id,))
                        assert not request(feed).get("drafts")
                        assert publish("--draft").returncode == 0
                        assert publish().returncode == 0
                        assert publish("--draft").returncode != 0
                        assert not request(feed).get("drafts") and request(feed)["items"][-1]["text"] == "Checking the summary."
                        downloaded = request(group_url + "/transcript")
                        assert b"Checking the summary." in downloaded and reply_token.encode() not in downloaded
                        request(group_url + "/transcript", authorized=False, status=401)
                        request("/api/groups/999999/transcript", status=404)
                    return group_url, feed

                focus = os.environ.get("SWARMHUB_TEST_FOCUS")
                if focus == "read-approval-rules":
                    from concurrent.futures import ThreadPoolExecutor
                    directory = root.resolve()
                    file = directory / "review-notes.md"
                    file.write_text("Read this revision.")
                    link = directory / "alias.md"
                    link.symlink_to(file)
                    journal = directory / "workspace/workspace.sqlite3"
                    keys = []
                    for name in ("Read reviewer", "Other reader"):
                        profile = request("/api/profiles", {"name":name}, status=201)
                        agent = request("/api/agents", {"name":profile["runtime_name"],"profile_id":profile["id"],
                                        "template":"fixture","task":"Start read review"}, status=201)
                        with sqlite3.connect(journal) as db:
                            keys.append(db.execute("SELECT launch_key FROM journal WHERE address=? AND launch_key IS NOT NULL",
                                                  (agent["address"],)).fetchone()[0])

                    def native_read(key=keys[0], target=file, tool="read", session="ses_rulePrimary123"):
                        native = socket_module.socket(socket_module.AF_UNIX)
                        native.settimeout(48)
                        native.connect(str(journal.with_name("approval.sock")))
                        frame = json.dumps({"key":key,"provider":"open_code","tool":tool,"cwd":str(directory),"native_session":session,
                                            "input":{"resources":[str(target)]}}).encode()
                        native.sendall(len(frame).to_bytes(4,"little") + frame)
                        return native

                    def answer(native, expected, confirm=True):
                        with native:
                            assert native.recv(1) == expected
                            if confirm:
                                native.sendall(b"K")

                    def waiting():
                        return until(lambda: next(iter(request("/api/approvals")["pending"]), None))

                    def read_rules():
                        return request("/api/approvals")["read_rules"]

                    def resolution(id):
                        return until(lambda: next((r for r in request("/api/approvals")["history"] if r["id"] == id), None))

                    def repeat(native):
                        answer(native, b"A")
                        until(read_rules)
                        answer(native_read(), b"A")
                        return until(lambda: next((item for item in request("/api/approvals")["history"] if item["automatic"]), None))

                    native = native_read()
                    pending = waiting()
                    assert pending["can_remember_read"]
                    with ThreadPoolExecutor(max_workers=1) as worker:
                        repeated = worker.submit(repeat, native)
                        if chrome:
                            subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=90)
                        else:
                            request(f"/api/approvals/{pending['id']}", "remember_read", status=202)
                        assert repeated.result(timeout=20)["state"] == "approved"
                    original, = read_rules()
                    assert original["path"] == str(file)

                    def reject(native, eligible):
                        candidate = waiting()
                        assert candidate["can_remember_read"] == eligible
                        endpoint = f"/api/approvals/{candidate['id']}"
                        if not eligible:
                            request(endpoint, "remember_read", status=409)
                        request(endpoint, "deny", status=202)
                        answer(native, b"D")
                        assert resolution(candidate["id"])["state"] == "denied"

                    reject(native_read(key=keys[1]), True)
                    reject(native_read(session="ses_anotherOpenCodeSession"), True)
                    reject(native_read(session=None), False)
                    reject(native_read(target=link), False)
                    reject(native_read(tool="glob"), False)
                    revoke = f"/api/approval-rules/{original['id']}/revoke"
                    request(revoke, {}, authorized=False, status=401)
                    request(revoke, {}, origin="https://outside.test", status=403)
                    assert request(revoke, {}) == {"revoked":True}
                    assert not read_rules()
                    reject(native_read(), True)

                    def remember(confirm=True):
                        native = native_read()
                        pending = waiting()
                        request(f"/api/approvals/{pending['id']}", "remember_read", status=202)
                        answer(native, b"A", confirm=confirm)
                        outcome = resolution(pending["id"])
                        assert outcome["state"] == ("approved" if confirm else "terminal")
                        assert outcome["unconfirmed"] == (not confirm)

                    remember(confirm=False)
                    assert not read_rules()
                    remember()
                    file.write_text("The revised file requires review again.")
                    reject(native_read(), True)
                    stop(process)
                    process, base = start_bridge()
                    assert not read_rules() and any(row["automatic"] for row in request("/api/approvals")["history"])
                    reject(native_read(), True)
                    return
                if focus == "runtime-setup":
                    for item in templates.glob("*.md"):
                        if item.name != "invalid.md":
                            item.rename(root / item.name)
                    (templates / "invalid-api.md").write_text(
                        "---\ndescription: Invalid API template\ncommand: swarmhub-herdr run-opencode --api-first-task 'mini'\n---\n")
                    rows = {item["name"]:item for item in request("/api/workspace")["templates"]}
                    assert set(rows) == {"invalid","invalid-api"} and all(row["error"] for row in rows.values())
                    assert "literal" in rows["invalid-api"]["error"]
                    request("/api/profiles", {"name":"Setup draft"}, status=201)
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=95)
                        assert not request("/api/workspace")["agents"]
                    return
                if focus == "grok-export-helper":
                    import base64
                    import zipfile
                    cli("server", "stop")
                    core_running = False
                    route = "/api/grok-imports/export-helper"
                    request(route, authorized=False, status=401)
                    data = request(route)
                    helper = root / "swarmhub-grok-export.pyz"
                    helper.write_bytes(data)
                    with zipfile.ZipFile(helper) as package:
                        assert package.testzip() is None
                        assert set(package.namelist()) == {"__main__.py","export_grokbot.py","grokbot_staged.py"}
                    cache = root / "local cache"
                    cache.mkdir()
                    account = "sand.client.slice.account.fixture"
                    bot = "00000000-0000-4000-8000-000000000001"
                    def cache_blob(key, value, owner=account):
                        name = base64.b32encode((owner + key).encode()).decode().rstrip("=").lower() + ".blob"
                        (cache / name).write_text(json.dumps({"value":value}))
                    cache_blob(".roster.last-roster", {"rows":[{"id":bot,"name":"Migration reviewer password: fixture-name-secret","description":"Use plain English."}]})
                    cache_blob(".transcript.replicas." + bot, {"entries":[
                        {"kind":"message","role":"user","content":"Review this invoice.","id":"user-first","seq":1},
                        {"kind":"send-message","message":{"type":"text","content":"Report ready. password: fixture-secret"},"id":"reply-first","seq":2},
                        {"kind":"send-message","message":{"type":"attachment","file_name":"password=fixture-file-secret.txt"},"id":"reply-second","seq":3},
                    ]})
                    cache_blob(".transcript.replicas." + bot, {"entries":[{"kind":"notice","text":"Wrong account","id":"foreign","seq":1}]}, account + "2")
                    output = root / "SwarmHub Grok Export"
                    args = [sys.executable,str(helper),"--cache",str(cache),"--out",str(output)]
                    completed = subprocess.run(args, capture_output=True, text=True, check=True, timeout=10)
                    assert "Exported 1 conversations and 3 messages" in completed.stdout and "fixture-secret" not in completed.stdout
                    index_text = (output / "index.json").read_text()
                    assert "fixture-name-secret" not in index_text
                    index = json.loads(index_text)
                    item = output / index["bots"][0]["bundle"]
                    bundle = item.read_bytes()
                    assert b"Report ready. [REDACTED]" in bundle and b"fixture-secret" not in bundle and b"fixture-name-secret" not in bundle
                    assert b"Wrong account" not in bundle and b"fixture-file-secret" not in bundle
                    assert json.loads(bundle)["messages"][-1]["attachments"] == []
                    assert output.stat().st_mode & 0o777 == 0o700 and item.stat().st_mode & 0o777 == 0o600
                    assert subprocess.run(args, capture_output=True, timeout=10).returncode != 0 and item.read_bytes() == bundle
                    assert subprocess.run(args + ["--fetch-server-history"], capture_output=True, timeout=10).returncode != 0
                    assert request("/api/grok-imports/preview", bundle)["visible_messages"] == 3
                    assert request("/api/grok-imports", bundle)["added"] == 3
                    cache_blob(".roster.last-roster", {"rows":[{"id":bot,"name":"Another account"}]}, account + "2")
                    second_path = root / "ambiguous cache export"
                    ambiguous = subprocess.run(args[:-1] + [str(second_path)], capture_output=True, timeout=10)
                    assert ambiguous.returncode != 0 and b"multiple Grok Bot rosters" in ambiguous.stderr and not second_path.exists()
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=75)
                        assert (root / "export-helper-download" / helper.name).read_bytes() == data
                    return
                if focus == "email-drafts":
                    from email import policy
                    from email.parser import BytesParser
                    source = request("/api/agents",{"name":"email-source","template":"fixture",
                                     "task":"Suggest an email for review"},status=201)
                    other = request("/api/agents",{"name":"email-other","template":"fixture",
                                    "task":"Unrelated session"},status=201)
                    history_path = f"/api/history/{core}/{source['address']}/{source['created_ms']}"
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND launch_key IS NOT NULL",
                                            (source["address"],)).fetchone()[0]
                        db.execute("UPDATE journal SET address=NULL,created_ms=NULL WHERE launch_key=?", (launch,))

                    def propose(value, key=launch):
                        return subprocess.run([bridge,"propose-email"],input=json.dumps(value).encode(),capture_output=True,timeout=10,
                                              env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":key}).returncode

                    def draft_rows():
                        return [row for row in request(history_path)["items"] if "email_draft" in row]

                    original = {"to":"reviewer@example.test","subject":"Draft <review>","body":"Check the release note. <script>literal</script>"}
                    dismissable = {**original,"subject":"Discard me"}
                    assert propose(original,"f"*32) != 0
                    assert propose({**original,"subject":"Injected\r\nBcc: copy@example.test"}) != 0
                    assert propose({**original,"to":"reviewer@example.test\nBcc: copy@example.test"}) != 0
                    assert propose({**original,"to":"Name <reviewer@example.test>"}) != 0
                    assert propose({**original,"body":"x"*(24*1024+1)}) != 0
                    assert propose(original) == propose({**original,"to":" reviewer@example.test "}) == 0
                    assert draft_rows() == []
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE journal SET address=?,created_ms=? WHERE launch_key=?",
                                   (source["address"],source["created_ms"],launch))
                    assert propose(dismissable) == 0
                    rows = draft_rows()
                    assert len(rows) == 2 and all(row["text"] == "An email draft was suggested." for row in rows)
                    first, second = [history_path+f"/email-drafts/{row['id']}" for row in rows]
                    assert request(first) == {"state":"suggested","revision":1,"draft":original}
                    request(first,status=401,authorized=False)
                    request(first.replace(f"/{source['address']}/{source['created_ms']}/",
                                          f"/{other['address']}/{other['created_ms']}/"),status=404)
                    request(first+"/download",{"revision":1,"draft":original},status=403,origin="https://outside.test")
                    request(first+"/download",{"revision":1,"draft":{**original,"subject":"Line break\rBcc: x@example.test"}},status=422)
                    assert request(first)["revision"] == 1
                    cli("server","stop")
                    core_running = False
                    edited = {"to":"qa+release@example.test, editor@example.test",
                              "subject":"Revisión: " + "café 🔍 "*14 + "fin",
                              "body":"Café notes.\nBcc: literal@example.test\n<img onerror=alert(1)>"}
                    payload = {"revision":1,"draft":edited}
                    if chrome:
                        browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                        subprocess.run(browser,check=True,timeout=75)
                        file = (root/"email-draft-downloads/swarmhub-email-draft.eml").read_bytes()
                    else:
                        file = request(first+"/download",payload)
                        request(second+"/dismiss",{"revision":1})
                    message = BytesParser(policy=policy.default).parsebytes(file)
                    assert not message.defects and message["X-Unsent"] == "1"
                    assert [address.addr_spec for address in message["To"].addresses] == edited["to"].split(", ")
                    assert str(message["Subject"]) == edited["subject"]
                    assert message.get_content_type() == "text/plain" and message.get_content_charset() == "utf-8"
                    assert message.get_content().replace("\r\n","\n") == edited["body"]
                    assert not any(name in message for name in ("From","Bcc","Cc","Received","Return-Path"))
                    assert b"\r" not in file.replace(b"\r\n",b"") and b"\n" not in file.replace(b"\r\n",b"")
                    assert request(first+"/download",payload) == file
                    assert request(first) == {"state":"reviewed","revision":2,"draft":edited}
                    request(first+"/download",{"revision":1,"draft":original},status=409)
                    assert request(second)["state"] == "dismissed" and request(second)["draft"] is None
                    request(second+"/download",{"revision":1,"draft":dismissable},status=409)
                    assert propose(original) == propose(dismissable) == 0
                    assert len(draft_rows()) == 2
                    blank = request(first+"/download",{"revision":2,"draft":{**edited,"to":""}})
                    assert "To" not in BytesParser(policy=policy.default).parsebytes(blank)
                    request(first+"/dismiss",{"revision":2},status=409)
                    request(first+"/dismiss",{"revision":3})
                    assert request(first)["draft"] is None
                    return
                if focus == "memory-proposals":
                    from concurrent.futures import ThreadPoolExecutor
                    base_instructions = "Keep reports factual."
                    source = request("/api/agents",{"name":"memory-source","template":"fixture",
                                     "task":"Propose a reviewed display preference","standing_instructions":base_instructions},status=201)
                    foreign = request("/api/profiles",{"name":"Another agent"},status=201)
                    account = source["profile_id"]
                    history_path = f"/api/history/{core}/{source['address']}/{source['created_ms']}"
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND launch_key IS NOT NULL",
                                            (source["address"],)).fetchone()[0]
                        db.execute("UPDATE journal SET address=NULL,created_ms=NULL,profile_id=NULL WHERE launch_key=?", (launch,))

                    def propose(value, key=launch):
                        return subprocess.run([bridge,"propose-memory"],input=value.encode(),capture_output=True,timeout=10,
                                              env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":key}).returncode

                    def profile():
                        return next(item for item in request("/api/profiles") if item["id"] == account)

                    def edit(item, instructions, status=200):
                        body = {key:item[key] for key in ("name","subtitle","avatar","pinned","hidden","revision")}
                        request(f"/api/profiles/{account}",{**body,"instructions":instructions},status=status)

                    def proposal_paths():
                        return [f"{history_path}/memory-proposals/{row['id']}" for row in request(history_path)["items"]
                                if row.get("memory_proposal") == "pending"]

                    suggestion = "Prefer short tables for project summaries."
                    dismissed = "Prefer a weekly status note."
                    changed = "Prefer compact tables for project summaries."
                    assert propose(suggestion,"f"*32) != 0
                    assert all(propose(text) != 0 for text in ("", "x"*513, "embedded\nline", "Bad\x00control",
                                                               "password: fixture-only-value", "Token sk-fake0123456789abcdefghijklmn"))
                    assert propose(suggestion+"\n") == propose(suggestion) == 0
                    assert not proposal_paths()
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE journal SET address=?,created_ms=? WHERE launch_key=?",
                                   (source["address"],source["created_ms"],launch))
                    first, = proposal_paths()
                    assert request(first)["profile"] is None
                    request(first,{"profile_id":account,"text":changed},status=409)
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE journal SET profile_id=? WHERE launch_key=?",(account,launch))
                    assert propose(dismissed) == 0
                    first, second = proposal_paths()
                    before = profile()
                    assert before["instructions"] == base_instructions
                    assert request(first)["text"] == suggestion and request(first)["profile"]["id"] == account
                    assert all(suggestion not in row["text"] for row in request(history_path)["items"])
                    request(first,status=401,authorized=False)
                    request(first.replace(f"/{core}/","/another-core/"),status=404)
                    request(first,{"profile_id":account,"text":changed},status=403,origin="https://outside.test")
                    request(first,{"profile_id":foreign["id"],"text":changed},status=409)
                    request(first,{"profile_id":account,"text":"password: fixture-only-value"},status=422)
                    cli("server","stop")
                    core_running = False
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser,check=True,timeout=75)
                    else:
                        request(first,{"profile_id":account,"text":changed})
                        request(second+"/dismiss",{})
                    expected = base_instructions + "\n\n" + changed
                    assert profile()["instructions"] == expected
                    assert request(first)["state"] == "saved" and request(first)["text"] is None
                    assert request(second)["state"] == "dismissed" and request(second)["text"] is None
                    request(first+"/dismiss",{},status=409)
                    request(second,{"profile_id":account,"text":dismissed},status=409)
                    replay = request(first,{"profile_id":account,"text":"A replay must not append a second time."})
                    assert replay["revision"] == before["revision"]+1 and profile()["instructions"] == expected
                    request(first,{"profile_id":foreign["id"],"text":changed},status=409)
                    edit(before,"An old profile edit must not overwrite the accepted memory.",status=409)
                    inserted = "Keep the manual profile note."
                    expected += "\n\n" + inserted
                    edit(profile(),expected)
                    parallel = ("Prefer ISO dates.", "Use a totals row.")
                    assert all(propose(text) == 0 for text in parallel)
                    with ThreadPoolExecutor(max_workers=2) as pool:
                        saved = list(pool.map(lambda item: request(item[0],{"profile_id":account,"text":item[1]}),
                                              zip(proposal_paths(),parallel)))
                    assert len({item["revision"] for item in saved}) == 2
                    assert profile()["instructions"].startswith(expected+"\n\n")
                    assert set(profile()["instructions"][len(expected)+2:].split("\n\n")) == set(parallel)
                    full = "x" * (6*1024)
                    edit(profile(),full)
                    assert propose("A suggestion with no remaining space.") == 0
                    final, = proposal_paths()
                    assert request(final)["profile"]["remaining_bytes"] == 0
                    request(final,{"profile_id":account,"text":"Cannot fit."},status=422)
                    assert request(final)["state"] == "pending" and profile()["instructions"] == full
                    return
                if focus == "routine-proposals":
                    initial = {"name":"routine-source","template":"fixture","task":"Routine proposal source"}
                    source = request("/api/agents", initial, status=201)
                    unrelated = request("/api/agents", {**initial,"name":"routine-unrelated"}, status=201)
                    path = f"/api/history/{core}/{source['address']}/{source['created_ms']}"
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND launch_key IS NOT NULL",
                                            (core,source["address"])).fetchone()[0]
                        db.execute("UPDATE journal SET address=NULL,created_ms=NULL WHERE launch_key=?", (launch,))
                    draft = {"name":"Morning checks","task":"Check the project notes.","schedule":{
                        "kind":"daily","hour":9,"minute":15,"weekdays":True,"timezone":"Europe/Warsaw"}}
                    dismissable = {**draft,"name":"Discard these reminders","schedule":{"kind":"interval","minutes":60}}

                    def propose(value, key=launch):
                        return subprocess.run([bridge,"propose-routine"],input=json.dumps(value).encode(),capture_output=True,
                                              timeout=10,env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":key}).returncode

                    assert propose(draft,"f"*32) != 0
                    assert propose({**draft,"schedule":{"kind":"interval","minutes":0}}) != 0
                    assert propose({**draft,"task":"x" * (12*1024+1)}) != 0
                    assert propose(draft) == propose(draft) == 0
                    assert not any(row.get("routine_proposal") for row in request(path)["items"])
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE journal SET address=?,created_ms=? WHERE launch_key=?",
                                   (source["address"],source["created_ms"],launch))
                    assert propose(dismissable) == 0
                    proposals = [row for row in request(path)["items"] if row.get("routine_proposal") == "pending"]
                    assert [row["text"] for row in proposals] == [draft["name"],dismissable["name"]]
                    first, second = [path+f"/routine-proposals/{row['id']}" for row in proposals]
                    assert request(first)["profile_id"] == source["profile_id"]
                    request(first,status=401,authorized=False)
                    request(first.replace(f"/{core}/","/another-core/"),status=404)
                    target = {key: source[key] for key in ("address","created_ms")}
                    request(first,{**draft,"target":target},status=403,origin="https://outside.test")
                    request(first,{**draft,"schedule":{"kind":"interval","minutes":0},"target":target},status=422)
                    request(first,{**draft,"target":{key:unrelated[key] for key in target}},status=409)
                    assert request("/api/routines") == []
                    cli("server","stop")
                    core_running = False
                    request(first,{**draft,"target":target},status=503)
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser,env={**os.environ,"SWARMHUB_TEST_FOCUS":"routine-proposals-offline"},check=True,timeout=75)
                    else:
                        request(second+"/dismiss",{})
                    assert request(first)["state"] == "pending"
                    assert request(second)["state"] == "dismissed"
                    assert request("/api/routines") == []
                    cli("server","start")
                    core_running = True
                    replacement = request("/api/agents",{**initial,"profile_id":source["profile_id"],
                                          "task":"New session for routine proposals"},status=201)
                    target = {key: replacement[key] for key in ("address","created_ms")}
                    approved = {**draft,"name":"Reviewed morning checks","task":"Summarize the project notes.",
                                "schedule":{**draft["schedule"],"hour":10,"minute":20},"target":target}
                    if chrome:
                        subprocess.run(browser,check=True,timeout=75)
                    else:
                        request(first,approved)
                    proposal = request(first)
                    assert proposal["state"] == "saved"
                    saved = request(f"/api/routines/{proposal['routine']}")
                    assert saved["routine"]["state"] == "paused" and saved["routine"]["next_at"] is None
                    assert saved["routine"]["target"] == target and saved["runs"] == []
                    assert all(saved["routine"][key] == approved[key] for key in ("name","task","schedule"))
                    assert request(first,approved)["id"] == proposal["routine"]
                    assert len(request("/api/routines")) == 1
                    request(first+"/dismiss",{},status=409)
                    request(second,approved,status=409)
                    output = request(f"/api/agents/{target['address']}/{target['created_ms']}/output")["text"]
                    assert approved["task"] not in output
                    return
                if focus == "skill-proposals":
                    agent = request("/api/agents",{"name":"proposal-agent","template":"fixture","task":"Propose a reusable checklist"},status=201)
                    path = f"/api/history/{core}/{agent['address']}/{agent['created_ms']}"
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND launch_key IS NOT NULL",
                                            (core,agent["address"])).fetchone()[0]
                    draft = {"name":"Review checklist","summary":"Before checking a report","instructions":"1. Read the report.\n2. Check the numbers."}
                    def propose(value, key=launch):
                        return subprocess.run([bridge,"propose-skill"],input=json.dumps(value).encode(),capture_output=True,timeout=10,
                                              env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":key}).returncode
                    assert propose(draft,"f"*32) != 0
                    assert propose({**draft,"instructions":""}) != 0
                    # A fast first task can propose a skill before Core reports the new address.
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE journal SET address=NULL,created_ms=NULL WHERE launch_key=?", (launch,))
                    assert propose(draft) == propose(draft) == 0
                    assert not any(row.get("skill_proposal") for row in request(path)["items"])
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE journal SET address=?,created_ms=? WHERE launch_key=?",
                                   (agent["address"],agent["created_ms"],launch))
                    assert propose({**draft,"name":"Dismiss this proposal"}) == 0
                    proposed = [row for row in request(path)["items"] if row.get("skill_proposal") == "pending"]
                    assert [row["text"] for row in proposed] == ["Review checklist","Dismiss this proposal"]
                    first, second = [path+f"/skill-proposals/{row['id']}" for row in proposed]
                    request(first,status=401,authorized=False)
                    request(first,draft,status=403,origin="https://outside.test")
                    request(first.replace(f"/{core}/","/another-core/"),status=404)
                    assert request(first)["instructions"] == draft["instructions"] and not request("/api/skills")
                    with sqlite3.connect(journal) as db:
                        db.executemany(
                            "INSERT INTO journal (reply_for,core_id,address,created_ms,agent,kind,state,text,detail,at_ms) "
                            "SELECT launch_key,core_id,address,created_ms,agent,'reply','received',?2,'Skill proposal',at_ms "
                            "FROM journal WHERE launch_key=?1",
                            [(launch,f"Ordinary reply {index}") for index in range(30)],
                        )
                    recent = request(path)
                    assert recent["before"] and not any(row.get("skill_proposal") for row in recent["items"])
                    cli("server","stop")
                    core_running = False
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=75)
                    else:
                        request(first,{**draft,"name":"Edited review checklist"})
                        request(second+"/dismiss",{})
                    assert request(first)["state"] == "saved"
                    assert request(first,draft)["id"] == request(first)["skill"]
                    assert request("/api/skills")[0]["name"] == "Edited review checklist" and len(request("/api/skills")) == 1
                    request(first+"/dismiss",{},status=409)
                    request(second,draft,status=409)
                    return
                if focus == "agent-drive-ui":
                    agent = request("/api/agents", {"name":"drive-reviewer", "template":"fixture", "task":"Check the report"}, status=201)
                    route = f"/api/agents/{agent['address']}/{agent['created_ms']}/drive-access"
                    initial = request(route + "?core=" + core)
                    assert initial["available"] and not initial["allowed"]
                    assert request(route, {"core":core,"allowed":True})["allowed"]
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        key = db.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND launch_key IS NOT NULL",
                                         (core,agent["address"])).fetchone()[0]
                    denied = subprocess.run([bridge,"drive-read","../outside"], capture_output=True, timeout=10,
                                            env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":key})
                    assert denied.returncode != 0 and b"valid path" in denied.stderr and not denied.stdout
                    assert not request(route, {"core":core,"allowed":False})["allowed"]
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=75)
                        assert not request(route + "?core=" + core)["allowed"]
                    return
                if focus == "drive-oauth":
                    route = "/api/drive-files/connect"
                    assert request("/api/drive-files/status") == {"configured":False,"uploads":False,"connectable":True}
                    assert not request("/api/workspace")["connected_files"]
                    request(route, {}, status=401, authorized=False)
                    request(route, {}, status=403, origin="https://outside.test")
                    request("/api/drive-files/disconnect",{},status=401,authorized=False)
                    request("/api/drive-files/disconnect",{},status=403,origin="https://outside.test")
                    request("/api/drive-files?path=",status=409)
                    issued = urllib.parse.urlparse(request(route,{})["url"])
                    params = urllib.parse.parse_qs(issued.query)
                    assert issued.hostname == "accounts.google.com" and params["code_challenge_method"] == ["S256"]
                    assert params["redirect_uri"] == [base + "/drive/oauth/callback"]
                    assert b"setup incomplete" in request("/drive/oauth/callback?state=invalid&code=untrusted",authorized=False)
                    assert not request("/api/drive-files/status")["configured"]
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=65)
                    assert request("/api/drive-files/disconnect",{}) == {"configured":False}
                    assert request("/api/vault")["entries"] == []
                    return
                if focus in ("opencode", "opencode-status", "opencode-approvals"):
                    browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp] if chrome else None
                    opencode_reply(root, bridge, request, core, browser)
                    return
                if focus == "webhook-review":
                    agent = request("/api/agents", {"name":"review-events","template":"fixture","task":"Start up"},status=201)
                    body = {"name":"Review incoming events","task":"Review the incoming event",
                        "schedule":{"kind":"webhook","review":True,"filters":[{"field":"action","equals":"opened"}]}}
                    routine = request("/api/routines",{**body,"target":{k:agent[k] for k in ("address","created_ms")}},status=201)
                    route = f"/api/routines/{routine['id']}"
                    key_info = request(route + "/webhook-key", {})

                    def notify(key, data, expected=202):
                        headers = {"Authorization":"Bearer " + key_info["key"],"Content-Type":"application/json",
                                   "Idempotency-Key":key}
                        try:
                            response = urllib.request.urlopen(urllib.request.Request(base+key_info["path"],
                                data=json.dumps(data).encode(),headers=headers),timeout=12)
                        except urllib.error.HTTPError as error:
                            response = error
                        with response:
                            assert response.status == expected, (response.status,response.read())
                            return json.load(response)

                    assert notify("ignored",{"action":"closed"},expected=200)["ignored"]
                    one = {"action":"opened","summary":"<em>Review fixture</em>"}
                    second = {"action":"opened","summary":"Dismiss fixture"}
                    first = notify("review:1",one)
                    skipped = notify("review:2",second)
                    assert first["awaiting_review"] and not first["duplicate"]
                    assert notify("review:1",one) == {**first,"duplicate":True}
                    approve = f"{route}/reviews/{first['review_id']}"
                    dismiss = f"{route}/reviews/{skipped['review_id']}"
                    request(approve,"approve",authorized=False,status=401)
                    request(route + "/state","pause")
                    request(approve,"approve",status=409)
                    request(route + "/state","resume")
                    assert request(route)["runs"] == []
                    stop(process)
                    process = None
                    process, base = start_bridge()
                    queued = request(route)["reviews"]
                    assert [row["payload"] for row in queued] == [one,second] and not any(row["stale"] for row in queued)
                    inbox = request("/api/attention")["webhook_reviews"]
                    assert [row["id"] for row in inbox] == [skipped["review_id"],first["review_id"]]
                    assert all(row["routine"] == routine["id"] and row["terminal"][1] == agent["address"] for row in inbox)
                    assert "Review fixture" not in json.dumps(inbox) and "Dismiss fixture" not in json.dumps(inbox)
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                    else:
                        request(approve,"approve",status=202)
                        request(dismiss,"dismiss")
                    run = until(lambda: row if (row := request(route)["runs"][0])["state"] in ("sent","start_not_observed") else None)
                    assert run["kind"]=="webhook"
                    assert notify("review:1",one) == {"id":run["id"],"duplicate":True}
                    assert notify("review:2",second,expected=200) == {"ignored":True,"reason":"dismissed"}
                    request(approve,"approve",status=404)
                    assert not request(route)["reviews"]
                    assert not request("/api/attention")["webhook_reviews"]
                    output = f"/api/agents/{agent['address']}/{agent['created_ms']}/output"
                    delivered = until(lambda: text if "Review fixture" in (text := request(output)["text"]) else None)
                    assert "Dismiss fixture" not in delivered
                    stale = notify("review:3",{"action":"opened","summary":"Old configuration"})
                    request(route,{**body,"task":"Updated instructions."})
                    current = request(route)["reviews"][0]
                    assert current["stale"]
                    stale_route = f"{route}/reviews/{stale['review_id']}"
                    request(stale_route,"approve",status=409)
                    request(stale_route,"dismiss")
                    assert len(request(route)["runs"]) == 1
                    notify("review:4",{"action":"opened","summary":"Remove on archive"})
                    cli("server","stop")
                    core_running = False
                    assert len(request("/api/attention")["webhook_reviews"]) == 1
                    request(route+"/state","archive")
                    assert not request(route)["reviews"]
                    assert not request("/api/attention")["webhook_reviews"]
                    with sqlite3.connect(root / "workspace/workspace.sqlite3") as db:
                        assert db.execute("SELECT count(*) FROM webhook_reviews WHERE payload IS NOT NULL").fetchone()[0] == 0
                    return
                if focus == "slack-events":
                    agents = [request("/api/agents", {"name":name,"template":"fixture","task":"Start up"},status=201)
                              for name in ("slack-review","slack-follow-up")]
                    schedule = {"kind":"webhook","source":"slack","filters":[
                        {"field":"team_id","equals":"T123WORK"},
                        {"field":"channel","equals":"C123DOCS"},
                    ]}
                    body = {"name":"Slack channel review","task":"Review the Slack mention",
                            "target":{k:agents[0][k] for k in ("address","created_ms")},"schedule":schedule}
                    request("/api/routines", {**body,"schedule":{"kind":"webhook","source":"slack"}},status=422)
                    app_routine = request("/api/routines",body,status=201)
                    follow_up = request("/api/routines",{**body,"name":"Slack follow-up",
                        "target":{k:agents[1][k] for k in ("address","created_ms")}},status=201)
                    other = request("/api/routines",{**body,"name":"Other Slack channel",
                        "schedule":{**schedule,"filters":[schedule["filters"][0],{"field":"channel","equals":"C456OTHER"}]}},status=201)
                    route = lambda item: f"/api/routines/{item['id']}"
                    assert request(route(app_routine))["slack_ready"]
                    request(route(app_routine)+"/webhook-key",{},status=404)

                    def slack(payload, expected=200, timestamp=None, signature=None, origin=None):
                        timestamp = str(int(time.time()) if timestamp is None else timestamp)
                        data = json.dumps(payload).encode()
                        signed = f"v0:{timestamp}:".encode() + data
                        headers = {"Content-Type":"application/json","X-Slack-Request-Timestamp":timestamp,
                                   "X-Slack-Signature":signature or "v0=" + hmac.new(slack_secret.encode(),signed,"sha256").hexdigest()}
                        if origin:
                            headers["Origin"] = origin
                        try:
                            response = urllib.request.urlopen(urllib.request.Request(base+"/hooks/slack",data=data,headers=headers),timeout=12)
                        except urllib.error.HTTPError as error:
                            response = error
                        with response:
                            assert response.status == expected, (response.status,response.read())
                            raw = response.read()
                            return json.loads(raw) if response.headers.get_content_type()=="application/json" else raw

                    challenge = {"type":"url_verification","challenge":"fixture-challenge","token":"must-not-copy"}
                    assert slack(challenge) == {"challenge":"fixture-challenge"}
                    slack(challenge,expected=401,timestamp=int(time.time())-301)
                    slack(challenge,expected=401,signature="v0=" + "0"*64)
                    slack(challenge,expected=403,origin="https://outside.test")
                    event = {"type":"event_callback","team_id":"T123WORK","event_id":"EvFixture106",
                             "token":"must-not-copy","event":{"type":"app_mention","channel":"C123DOCS",
                             "text":"<@U123BOT> Please check the docs fixture","user":"U8844"}}
                    counts = {"accepted":0,"duplicates":0,"retry":False}
                    assert slack({**event,"team_id":"T456OTHER"}) == counts
                    assert slack({**event,"event":{**event["event"],"type":"message"}}) == {"ignored":True}
                    assert slack({**event,"event":{**event["event"],"bot_id":"B123"}}) == {"ignored":True}
                    assert slack(event) == {**counts,"accepted":2}
                    assert slack(event) == {**counts,"duplicates":2}
                    for item, agent in zip((app_routine,follow_up),agents):
                        feed = f"/api/agents/{agent['address']}/{agent['created_ms']}/output"
                        seen = until(lambda: output if "Please check the docs fixture" in (output := request(feed)["text"]) else None)
                        assert "must-not-copy" not in seen and "U8844" not in seen
                        assert len(request(route(item))["runs"]) == 1
                    assert not request(route(other))["runs"]
                    stop(process)
                    process = None
                    process, base = start_bridge()
                    assert slack(event) == {**counts,"duplicates":2}
                    request(route(follow_up),{"name":"Slack follow-up","task":"Review the Slack mention",
                            "schedule":{**schedule,"review":True}})
                    next_event = {**event,"event_id":"EvFixture107","event":{**event["event"],"text":"Review before dispatch"}}
                    assert slack(next_event) == {**counts,"accepted":1,"awaiting_review":1}
                    queued = request(route(follow_up))["reviews"][0]
                    assert queued["payload"]["text"] == "Review before dispatch" and len(request(route(follow_up))["runs"])==1
                    request(route(follow_up)+f"/reviews/{queued['id']}","dismiss")
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                    return
                if focus == "routine-webhooks":
                    agent = request("/api/agents",{"name":"webhook-agent","template":"fixture","task":"Start up"},status=201)
                    item = request("/api/routines",{"name":"Webhook review","task":"Review the incoming test event",
                                   "target":{k:agent[k] for k in ("address","created_ms")},"schedule":{"kind":"webhook"}},status=201)
                    route = f"/api/routines/{item['id']}"
                    hook = f"/hooks/routines/{item['id']}"
                    assert item["next_at"] is None and not item["webhook_ready"]

                    def trigger(secret, key, data=b"", status=202, origin=None, content_type="application/json"):
                        headers = {"Content-Type":content_type}
                        if secret:
                            headers["Authorization"] = "Bearer " + secret
                        if key is not None:
                            headers["Idempotency-Key"] = key
                        if origin:
                            headers["Origin"] = origin
                        try:
                            response = urllib.request.urlopen(urllib.request.Request(base+hook,data=data,headers=headers),timeout=12)
                        except urllib.error.HTTPError as err:
                            response = err
                        with response:
                            assert response.status == status, (response.status,response.read())
                            raw = response.read()
                            return json.loads(raw) if response.headers.get_content_type()=="application/json" else raw

                    trigger(token,"no-key",status=401)
                    request(route+"/webhook-key",{},authorized=False,status=401)
                    first = request(route+"/webhook-key",{})["key"]
                    second = request(route+"/webhook-key",{})["key"]
                    assert first != second and len(second)==64
                    assert second not in json.dumps(request(route)) and request(route)["routine"]["webhook_ready"]
                    trigger(first,"old-key",status=401)
                    trigger(second,"cross-origin",origin="https://outside.test",status=403)
                    trigger(second,None,status=422)
                    trigger(second,"bad-payload",b"[]",status=422)
                    trigger(second,"large",b"x"*4000,status=413)
                    trigger(second,"bad-type",b"{}",content_type="text/plain",status=415)
                    request(route+"/state","pause")
                    trigger(second,"paused",status=409)
                    assert request(route)["runs"] == []
                    request(route+"/state","resume")
                    event = b'{"department":"Research","request":"review","flag":"webhook-payload-009"}'
                    accepted = trigger(second,"review:1",event)
                    assert accepted["duplicate"] is False
                    assert trigger(second,"review:1",event)=={"id":accepted["id"],"duplicate":True}
                    run = until(lambda: rows[0] if (rows := request(route)["runs"]) and rows[0]["state"] in ("sent","start_not_observed") else None)
                    assert run["kind"]=="webhook" and run["id"]==accepted["id"]
                    output = f"/api/agents/{agent['address']}/{agent['created_ms']}/output"
                    until(lambda: "webhook-payload-009" in request(output)["text"])
                    rules = [{"field":"department", "equals":"Research"},
                             {"field":"request.action", "equals":"review"}]
                    edit = {"name":item["name"], "task":item["task"], "schedule":{"kind":"webhook","filters":rules}}
                    request(route, {**edit, "schedule":{"kind":"webhook","filters":[rules[0], rules[0]]}}, status=422)
                    request(route, {**edit, "schedule":{"kind":"webhook","filters":[{"field":"request..action","equals":"review"}]}},
                            status=422)
                    changed = request(route, edit)
                    assert changed["schedule"] == edit["schedule"] and changed["webhook_ready"] and changed["state"] == "active"
                    ignored = {"ignored":True,"reason":"filter_mismatch"}
                    assert trigger(second, "filter:0", status=200) == ignored
                    assert trigger(second, "filter:0", event, status=200) == ignored
                    assert trigger(second, "filter:0", b'{"department":"Research","request":{"action":"Review"}}', status=200) == ignored
                    assert trigger(second, "filter:0", b'{"department":"Research","request":{"action":true}}', status=200) == ignored
                    assert trigger(second, "filter:0", b'{"department":"Finance","request":{"action":"review"}}', status=200) == ignored
                    assert len(request(route)["runs"]) == 1
                    matched = b'{"department":"Research","request":{"action":"review"},"flag":"filtered-payload-012"}'
                    filtered = trigger(second, "filter:0", matched)
                    assert filtered["duplicate"] is False
                    until(lambda: "filtered-payload-012" in request(output)["text"])
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert trigger(second,"review:1",event)=={"id":accepted["id"],"duplicate":True}
                    assert trigger(second,"filter:0",matched)=={"id":filtered["id"],"duplicate":True}
                    assert len(request(route)["runs"])==2 and request(route)["routine"]["schedule"] == edit["schedule"]
                    github_schedule = {"kind":"webhook", "source":"github", "filters":[
                        {"field":"repository.full_name", "equals":"example/docs"}, {"field":"action","equals":"opened"},
                    ]}
                    github_edit = {"name":"GitHub issue review", "task":"Summarize the GitHub record", "schedule":github_schedule}
                    github = request("/api/routines", {**github_edit, "target":{k:agent[k] for k in ("address","created_ms")}}, status=201)
                    github_route = f"/api/routines/{github['id']}"
                    github_hook = f"/hooks/routines/{github['id']}/github"
                    key_info = request(github_route + "/webhook-key", {})
                    assert key_info["path"] == github_hook and key_info["key"] not in json.dumps(request(github_route))
                    key = key_info["key"]
                    issue = {"action":"opened","repository":{"full_name":"example/docs","private":True},
                             "issue":{"title":"Documentation fixture 927","number":9,"body":"Do not copy the issue body"},
                             "sender":{"email":"fixture email must not be copied"}}
                    signed = json.dumps(issue).encode()

                    def github_event(data, event="issues", secret=key, status=202, delivery="eff936cd-55e9-4388-ae3a-f01ac9ea741b",
                                     signature=None, origin=None, path=github_hook):
                        headers = {
                            "X-Hub-Signature-256":signature or "sha256=" + hmac.new(secret.encode(), data, "sha256").hexdigest(),
                            "X-GitHub-Event":event, "X-GitHub-Delivery":delivery, "Content-Type":"application/json",
                        }
                        if origin:
                            headers["Origin"] = origin
                        try:
                            response = urllib.request.urlopen(urllib.request.Request(base+path,data=data,headers=headers),timeout=12)
                        except urllib.error.HTTPError as err:
                            response = err
                        with response:
                            assert response.status == status, (path,response.status,response.read())
                            raw = response.read()
                            return json.loads(raw) if response.headers.get_content_type()=="application/json" else raw

                    github_event(signed, signature="sha256=" + "0"*64, status=401)
                    github_event(signed, origin="https://outside.test", status=403)
                    github_event(signed, path=hook + "/github", secret=second, status=401)
                    github_event(signed, event="pull_request", status=422)
                    assert github_event(b'{"zen":"fixture"}', event="ping", status=200)["ignored"]
                    assert github_event(json.dumps({**issue,"action":"closed"}).encode(),status=200) == ignored
                    assert request(github_route)["runs"] == []
                    gh_run = github_event(signed)
                    assert github_event(signed, delivery="53bd9b12-fe54-4c78-ae71-89da5ae53767") == {
                        "id":gh_run["id"],"duplicate":True,
                    }
                    until(lambda: request(github_route)["runs"][0]["state"] in ("sent","start_not_observed"))
                    gh_output = until(lambda: value if "Documentation fixture 927" in (value := request(output)["text"]) else None)
                    assert "Do not copy the issue body" not in gh_output and "fixture email must not be copied" not in gh_output
                    new_key = request(github_route + "/webhook-key", {})["key"]
                    assert new_key != key
                    github_event(signed, status=401)
                    assert github_event(signed, secret=new_key)["duplicate"]
                    pull = {"action":"opened", "repository":issue["repository"], "pull_request":{"number":14,"title":"Review docs fixture 861"}}
                    assert not github_event(json.dumps(pull).encode(), event="pull_request", secret=new_key)["duplicate"]
                    until(lambda: "Review docs fixture 861" in request(output)["text"])
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                    assert request(github_route, {**github_edit,"schedule":{"kind":"webhook"}})["webhook_ready"] is False
                    github_event(signed, secret=new_key, status=401)
                    request(route+"/state","archive")
                    trigger(second,"archived",status=401)
                    return
                if focus == "routine-outcomes":
                    agents = [request("/api/agents",{"name":name,"template":"fixture","task":"Start up"},status=201)
                              for name in ("routine-reporter","routine-other")]
                    agent = agents[0]
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch, other = [db.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND launch_key IS NOT NULL",
                                                    (core,row["address"])).fetchone()[0] for row in agents]
                    routine = request("/api/routines",{"name":"Outcome check","task":"Check outcome reporting",
                                      "target":{k:agent[k] for k in ("address","created_ms")},
                                      "schedule":{"kind":"interval","minutes":60}},status=201)
                    route = f"/api/routines/{routine['id']}"
                    request(route+"/state","pause")
                    test = request(route+"/test",{},status=202)
                    log = fixture.with_suffix(".routine-outcomes")
                    def commands():
                        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
                    def report(command, key, outcome, text):
                        return subprocess.run([*command[:-1],outcome],input=text.encode(),capture_output=True,
                                              env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":key})
                    first = until(lambda: data[0] if (data := commands()) else None)
                    sent = until(lambda: rows[0] if (rows := request(route)["runs"]) and rows[0]["state"]=="sent" else None)
                    assert sent["id"]==test["id"] and sent["awaiting_result"] and "result" not in sent
                    assert first[-2] not in json.dumps(sent)
                    assert report(first,other,"succeeded","Wrong session").returncode != 0
                    assert report(first,launch,"succeeded","Readiness checks passed.").returncode == 0
                    assert report(first,launch,"failed","Duplicate result").returncode != 0
                    test_result = request(route)["runs"][0]["result"]
                    assert test_result["state"]=="succeeded" and test_result["summary"]=="Readiness checks passed."
                    request(route+"/state","resume")
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE routines SET next_at=? WHERE id=?",(int(time.time()*1000),routine["id"]))
                    pending = until(lambda: rows[0] if (rows := request(route)["runs"]) and rows[0]["kind"]=="schedule" and rows[0]["state"]=="sent" else None)
                    second = until(lambda: data[1] if len(data := commands()) == 2 else None)
                    assert pending["awaiting_result"] and second[-2] != first[-2]
                    cli("server","stop")
                    core_running = False
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    assert report(second,launch,"failed","The source report was unavailable.").returncode == 0
                    process, base = start_bridge(port)
                    runs = request(route)["runs"]
                    assert runs[0]["state"]=="sent" and runs[0]["result"]["state"]=="failed"
                    assert runs[1]["result"]==test_result
                    key = f"{agent['address']}/{agent['created_ms']}"
                    records = {row["id"]:row for row in request(f"/api/history/{core}/{key}")["items"]}
                    assert all((records[run["task_id"]]["state"],records[run["task_id"]]["detail"]) ==
                               (run["state"],"Routine: Outcome check") for run in runs)
                    assert records[runs[0]["result"]["id"]]["text"]=="The source report was unavailable."
                    assert records[runs[1]["result"]["id"]]["text"]=="Readiness checks passed."
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                    return
                if focus == "routine-move":
                    launch_args = {"name":"move-agent","template":"fixture","task":"Start the first session"}
                    old = request("/api/agents", launch_args, status=201)
                    wrong = request("/api/agents", {**launch_args,"name":"different-owner"}, status=201)
                    def binding(agent):
                        return {"core":core,"target":{k:agent[k] for k in ("address","created_ms")}}
                    schedule = {"kind":"webhook"}
                    routine = request("/api/routines", {"name":"Movable review","task":"Review the weekly notes",
                        "schedule":schedule,"target":binding(old)["target"]}, status=201)
                    route = f"/api/routines/{routine['id']}"
                    hook_info = request(route + "/webhook-key", {})
                    old_run = request(route + "/test", {}, status=202)
                    log = fixture.with_suffix(".routine-outcomes")
                    command = until(lambda: json.loads(lines[0]) if log.exists() and (lines := log.read_text().splitlines()) else None)
                    until(lambda: request(route)["runs"][0]["state"] == "sent")
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch, = db.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND launch_key IS NOT NULL",
                                             (core,old["address"])).fetchone()
                    subprocess.run(command, input=b"Result from the original session.", check=True, capture_output=True,
                                   env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch})
                    request(f"/api/agents/{old['address']}/{old['created_ms']}/end", {})
                    new = request("/api/agents", {**launch_args,"profile_id":old["profile_id"],
                                                  "task":"Start the replacement session"}, status=201)
                    assert old["address"] != new["address"] or old["created_ms"] != new["created_ms"]
                    move = {"from":binding(old), "to":binding(new)}
                    request(route + "/move", move, authorized=False, status=401)
                    request(route + "/move", {**move,"to":binding(wrong)}, status=422)
                    with sqlite3.connect(journal) as db:
                        busy = db.execute("INSERT INTO routine_runs (routine,kind,at_ms,state) VALUES (?,'test',?,'pending')",
                                          (routine["id"],int(time.time()*1000))).lastrowid
                    request(route + "/move", move, status=409)
                    with sqlite3.connect(journal) as db:
                        db.execute("DELETE FROM routine_runs WHERE id=?", (busy,))
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp], check=True,timeout=85)
                    else:
                        request(route + "/move", move)
                    detail = request(route)
                    switched = detail["routine"]
                    assert switched["profile_id"] == old["profile_id"] and switched["target"] == binding(new)["target"]
                    assert switched["state"] == "paused" and switched["next_at"] is None and switched["schedule"] == schedule and switched["webhook_ready"]
                    assert len(detail["runs"]) == 1 and detail["runs"][0]["id"] == old_run["id"]
                    assert detail["runs"][0]["conversation"] == {**binding(old)["target"],"core":core,"agent":"move-agent"}
                    assert detail["runs"][0]["result"]["summary"] == "Result from the original session."
                    request(route + "/move", move, status=409)
                    request(route + "/state", "resume")
                    incoming = urllib.request.Request(base+hook_info["path"], data=b"", headers={
                        "Authorization":"Bearer "+hook_info["key"], "Idempotency-Key":"after-move",
                    })
                    with urllib.request.urlopen(incoming, timeout=12) as response:
                        assert response.status == 202
                    delivered = until(lambda: latest if (latest := request(route)["runs"][0])["state"]=="sent" else None)
                    assert delivered["kind"] == "webhook" and delivered["conversation"] == {**binding(new)["target"],"core":core,"agent":"move-agent"}
                    replacement = request(f"/api/history/{core}/{new['address']}/{new['created_ms']}")["items"]
                    assert [row["text"] for row in replacement if row["kind"]=="task"] == ["Start the replacement session","Review the weekly notes"]
                    return
                if focus == "desktop-notices":
                    from concurrent.futures import ThreadPoolExecutor

                    agents = {}
                    for name, template in (("notice-source","claude-fixture"),("notice-muted","fixture"),("notice-active","fixture")):
                        agents[name] = request("/api/agents",{"name":name,"template":template,"task":"Review the plan"},status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        keys = {name:db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                                (agent["address"],core)).fetchone()[0] for name,agent in agents.items()}
                    def capture(name,text):
                        subprocess.run([bridge,"capture-reply"],input=text.encode(),check=True,capture_output=True,
                                       env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":keys[name]})

                    signals = "/api/activity/signals"
                    request(signals,status=401,authorized=False)
                    baseline = request(signals)
                    assert baseline["items"] == []
                    chosen = agents["notice-source"]
                    with sqlite3.connect(journal) as db:
                        early = db.execute("INSERT INTO journal (core_id,agent,kind,state,text,at_ms,reply_for) VALUES (?,?,'reply','received',?,?,?)",
                                           (core,"notice-source","Early buffered reply.",int(time.time()*1000),keys["notice-source"])).lastrowid
                    # An unpublished launch identity must stay out of the feed until it can be opened.
                    invisible = request(signals + f"?after={baseline['cursor']}")
                    assert all(row["message"] != early for row in invisible["items"])
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE journal SET address=?,created_ms=? WHERE id=?",
                                   (chosen["address"],chosen["created_ms"],early))
                    awake = request(signals + f"?after={invisible['cursor']}")
                    assert any(row["message"]==early and row["profile"]==chosen["profile_id"] and "text" not in row
                               and "name" not in row for row in awake["items"])
                    capture("notice-source","Old background result before permission.")
                    members = [{k:agents[name][k] for k in ("address","created_ms")} for name in ("notice-source","notice-active")]
                    group = request("/api/groups",{"name":"Private notices group","members":members},status=201)
                    review = request("/api/routines",{"name":"Review a desktop webhook","task":"Review the fixture event",
                                     "schedule":{"kind":"webhook","review":True},"target":members[0]},status=201)
                    hook = request(f"/api/routines/{review['id']}/webhook-key",{})

                    def events():
                        for gate,name,text in (
                            ("focused","notice-active","Focused result."),
                            ("muted","notice-muted","Muted background result."),
                            ("background","notice-source","Private background result is ready."),
                        ):
                            until(lambda: (root / ("notice-" + gate)).exists(), seconds=25)
                            capture(name,text)
                        until(lambda: (root / "notice-attention").exists(), seconds=25)
                        request(f"/api/groups/{group['id']}/messages",
                                {"text":"Ask a group question","recipients":[members[0]],"revision":group["revision"]},status=202)
                        until(lambda: (root / "notice-webhook").exists(), seconds=25)
                        incoming = urllib.request.Request(base+hook["path"],
                            data=b'{"text":"Private webhook fixture payload"}',headers={
                                "Authorization":"Bearer "+hook["key"],"Idempotency-Key":"notice:webhook",
                                "Content-Type":"application/json",
                            })
                        with urllib.request.urlopen(incoming,timeout=12) as response:
                            assert response.status == 202 and json.load(response)["awaiting_review"]
                    if chrome:
                        with ThreadPoolExecutor(max_workers=1) as runner:
                            producer = runner.submit(events)
                            subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                           check=True,timeout=115)
                            producer.result(timeout=5)
                    return
                if focus == "activity":
                    author = request("/api/agents",{"name":"activity-author","template":"fixture","task":"Draft a result"},status=201)
                    reviewer = request("/api/agents",{"name":"activity-reviewer","template":"claude-fixture","task":"Review startup"},status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                            (author["address"],core)).fetchone()[0]
                    env = {"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch}
                    def capture(text):
                        subprocess.run([bridge,"capture-reply"],input=text.encode(),env=env,check=True,capture_output=True)
                    reviewer_history = f"/api/history/{core}/{reviewer['address']}/{reviewer['created_ms']}"
                    reviewer_reply = until(lambda: next((m for m in request(reviewer_history)["items"] if m["kind"]=="reply"), None))
                    unread = "/api/activity/unread"
                    activity = "/api/activity"
                    mark = activity + "/read"
                    request(activity,status=401,authorized=False)
                    request(unread,status=401,authorized=False)
                    initial = request(activity)["items"][0]
                    assert initial["message"] == reviewer_reply["id"]
                    request(mark,{"kind":"through","id":initial["id"]},origin="http://external.test",status=403)
                    request(mark,{"kind":"through","id":initial["id"]},authorized=False,status=401)
                    capture("Background reply is ready.")
                    summary = request(mark,{"kind":"through","id":initial["id"]})
                    assert len(summary)==1 and summary[0]["address"]==author["address"] and summary[0]["count"]==1
                    report = root / "Review report.txt"
                    report.write_text("A review result")
                    subprocess.run([bridge,"publish-file",str(report)],env=env,check=True,capture_output=True)
                    targets = [{k:a[k] for k in ("address","created_ms")} for a in (author,reviewer)]
                    group = request("/api/groups",{"name":"Activity review","members":targets},status=201)
                    feed = f"/api/groups/{group['id']}/messages"
                    task = request(feed,{"text":"Wait for explicit group result","recipients":[targets[1]],"revision":group["revision"]},status=202)
                    until(lambda: request(feed)["items"][0]["deliveries"][0]["state"] == "sent")
                    with sqlite3.connect(journal) as db:
                        reply_token, reviewer_launch = db.execute("SELECT token,launch_key FROM group_deliveries WHERE message_id=?",
                                                                   (task["id"],)).fetchone()
                    subprocess.run([bridge,"group-reply",reply_token],input=b"The group review is ready.",check=True,capture_output=True,
                                   env={**env,"SWARMHUB_LAUNCH_KEY":reviewer_launch})
                    with sqlite3.connect(journal) as db:
                        db.executemany("INSERT INTO group_messages (group_id,text,at_ms) VALUES (?,?,?)",
                                       [(group["id"],f"Newer group message {i}",int(time.time()*1000)) for i in range(34)])
                    current = request(activity+"?unread=true")["items"]
                    assert [item["kind"] for item in current] == ["group","file","reply"]
                    assert current[0]["group_name"]=="Activity review" and current[1]["excerpt"]=="Review report.txt"
                    assert len(request(activity)["items"]) > len(current)
                    assert not any(m["author"] for m in request(feed)["items"])
                    cli("server","stop")
                    core_running = False
                    if chrome:
                        browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                        subprocess.run(browser,check=True,timeout=90)
                    else:
                        request(mark,{"kind":"item","id":current[0]["id"]})
                        request(mark,{"kind":"direct","core":core,"address":author["address"],"created_ms":author["created_ms"],
                                      "through":current[1]["message"]})
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request(unread) == [] and request(activity+"?unread=true")["items"] == []
                    assert {"reply","file","group"} <= {item["kind"] for item in request(activity)["items"]}
                    return
                if focus == "reply-markdown":
                    agent = request("/api/agents", {"name":"markdown-author","template":"fixture","task":"Draft a release plan"}, status=201)
                    peer = request("/api/agents", {"name":"markdown-reviewer","template":"claude-fixture","task":"Review startup"}, status=201)
                    key = f"{agent['address']}/{agent['created_ms']}"
                    source = (
                        "# Release plan\n\n- **Confirmed**\n- Review the checklist\n\n"
                        "| Stage | Owner |\n| --- | --- |\n| Review | Jordan |\n\n"
                        "```text\nRelease notes, ready for review.\n" + "Long example " * 25 + "\n```\n\n"
                        "<img src=https://outside.test/tracker onerror=alert(1)>\n\n"
                        "![Remote picture](https://outside.test/picture) [Blocked](javascript:alert%281%29) "
                        "[Release guide](https://example.test/guide)"
                    )
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                            (agent["address"],core)).fetchone()[0]
                    subprocess.run([bridge,"capture-reply"],input=source.encode(),check=True,capture_output=True,
                                   env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch})
                    targets = [{k:a[k] for k in ("address","created_ms")} for a in (agent,peer)]
                    team = request("/api/groups", {"name":"Markdown review", "members":targets}, status=201)
                    feed = f"/api/groups/{team['id']}/messages"
                    task = request(feed, {"text":"Wait for explicit group result","recipients":[targets[1]],
                                          "revision":team["revision"]},status=202)
                    until(lambda: request(feed)["items"][0]["deliveries"][0]["state"] == "sent")
                    with sqlite3.connect(journal) as db:
                        reply_token, reviewer = db.execute("SELECT token,launch_key FROM group_deliveries WHERE message_id=?",
                                                           (task["id"],)).fetchone()
                    subprocess.run([bridge,"group-reply",reply_token],input=source.encode(),check=True,capture_output=True,
                                   env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":reviewer})
                    cli("server","stop")
                    core_running = False
                    direct = request(f"/api/history/{core}/{key}")["items"][-1]
                    shared = request(feed)["items"][-1]
                    assert direct["text"] == shared["text"] == source
                    assert direct["rendered"] == shared["rendered"]
                    assert "<img" not in direct["rendered"] and "href=\"javascript:" not in direct["rendered"]
                    thread = request(f"/api/history/{core}/{key}/threads/{direct['id']}")
                    assert thread["original"]["rendered"] == direct["rendered"]
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                    return
                if focus == "direct-replies":
                    agents = [request("/api/agents", {"name":name,"template":"fixture","task":"Review the proposal"}, status=201)
                              for name in ("reply-author", "reply-peer")]
                    key, foreign_key = [f"{a['address']}/{a['created_ms']}" for a in agents]
                    history = f"/api/history/{core}/{key}"
                    messages = f"/api/agents/{key}/messages"
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch, peer_launch = [
                            db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                       (agent["address"], core)).fetchone()[0] for agent in agents]
                    text = "The draft uses Tuesday.\n<em>Quoted literally</em>\r\n" + "✓" * 310 + "Unquoted tail"
                    subprocess.run([bridge,"capture-reply"],input=text.encode(),check=True,capture_output=True,
                                   env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch})
                    items = request(history)["items"]
                    original = items[-1]
                    assert original["kind"] == "reply" and original["text"] == text
                    thread = f"{history}/threads/{original['id']}"
                    request(thread,status=401,authorized=False)
                    request(f"/api/history/{core}/{foreign_key}/threads/{original['id']}",status=404)
                    request(f"{history}/threads/{items[0]['id']}",status=404)
                    assert request(thread)["items"] == []
                    payload = {"text":"Use Thursday instead.","reply_to":{"core":core,"id":original["id"]}}
                    followup = {**payload, "text":"Keep the original venue."}
                    request(messages,payload,status=401,authorized=False)
                    request(messages,{**payload,"reply_to":{"core":"other-core","id":original["id"]}},status=404)
                    request(messages,{**payload,"reply_to":{"core":core,"id":items[0]["id"]}},status=404)
                    request(f"/api/agents/{foreign_key}/messages",payload,status=404)
                    request(messages,{**payload,"text":"x"*(14*1024+1)},status=422)
                    assert request(history)["items"] == items
                    with sqlite3.connect(journal) as db:
                        db.executemany(
                            "INSERT INTO journal (core_id,address,created_ms,agent,kind,state,text,at_ms) VALUES (?,?,?,?, 'task','sent',?,?)",
                            [(core,agents[0]["address"],agents[0]["created_ms"],"reply-author",f"Unrelated entry {i}",int(time.time()*1000))
                             for i in range(33)])
                    assert original["id"] not in [item["id"] for item in request(history)["items"]]
                    if chrome:
                        browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                        subprocess.run(browser,check=True,timeout=90)
                    else:
                        request(messages,payload)
                        fixture.with_suffix(".reply-release").touch()
                        request(messages,followup)
                    receipt = fixture.with_suffix(".direct-reply")
                    logs = until(lambda: lines if receipt.exists() and len(lines := receipt.read_text().splitlines()) == 2 else None)
                    delivered = [json.loads(line) for line in logs]
                    excerpt = text.replace("\r","")[:320] + "…"
                    assert delivered == [{"quote":excerpt,"task":entry["text"]} for entry in (payload,followup)]
                    thread_rows = until(lambda: rows if len(rows := request(thread)["items"]) == 3 else None)
                    first, final, answer = thread_rows
                    assert final["text"] == followup["text"] and final["state"] in ("sent","start_not_observed")
                    assert final["reply_to"] == {"id":original["id"],"text":excerpt}
                    assert answer["answer_to"] == {"id": final["id"], "text": followup["text"]}
                    assert answer["text"] == "I kept the original venue."
                    request(f"{history}/threads/{answer['id']}",status=404)
                    with sqlite3.connect(journal) as db:
                        links = [db.execute("SELECT thread_reply_token FROM journal WHERE id=?", (row["id"],)).fetchone()[0]
                                 for row in (first, final)]
                    assert all(isinstance(link,str) and len(link)==32 and link not in json.dumps(thread_rows) for link in links)
                    def post(link, who, text):
                        return subprocess.run([bridge,"thread-reply",link],input=text.encode(),capture_output=True,
                                              env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":who})
                    assert post(links[0],peer_launch,"Cross-session test").returncode != 0
                    assert post(links[1],launch,"Duplicate answer").returncode != 0
                    cli("server","stop")
                    core_running = False
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    assert post(links[0],launch,"Thursday is confirmed.").returncode == 0
                    process, base = start_bridge(port)
                    assert request(history)["items"][-1]["answer_to"] == {"id": first["id"], "text": payload["text"]}
                    with sqlite3.connect(journal) as db:
                        db.executemany(
                            "INSERT INTO journal (core_id,address,created_ms,agent,kind,state,text,at_ms,in_reply_to,reply_excerpt) VALUES (?,?,?,?, 'task','sent',?,?,?,?)",
                            [(core,agents[0]["address"],agents[0]["created_ms"],"reply-author",f"Thread note {i}",int(time.time()*1000),original["id"],excerpt)
                             for i in range(31)])
                    recent = request(thread)
                    assert recent["original"]["id"] == original["id"]
                    assert len(recent["items"]) == 30 and recent["items"][0]["text"] == "Thread note 1"
                    earlier = request(thread + f"?before={recent['before']}")
                    assert earlier["before"] is None and [row["text"] for row in earlier["items"]] == [
                        payload["text"],followup["text"],answer["text"],"Thursday is confirmed.","Thread note 0"]
                    if chrome:
                        subprocess.run(browser,env={**os.environ,"SWARMHUB_TEST_FOCUS":"direct-replies-offline"},check=True,timeout=90)
                    return
                if focus == "reactions":
                    def launch_agent(name, task):
                        return request("/api/agents", {"name": name, "template": "claude-fixture", "task": task}, status=201)

                    agent = launch_agent("reaction-author", "Draft the review")
                    reviewer = launch_agent("reaction-reviewer", "Prepare the review")
                    key = f"{agent['address']}/{agent['created_ms']}"
                    direct = f"/api/history/{core}/{key}"
                    reply = until(lambda: next((m for m in request(direct)["items"] if m["kind"] == "reply"), None))
                    snapshot = request(f"/api/agents/{key}/snapshots", {"title": "Review snapshot"}, status=201)["id"]
                    members = [{k:a[k] for k in ("address", "created_ms")} for a in (agent, reviewer)]
                    group = request("/api/groups", {"name":"Reaction review", "members":members}, status=201)
                    other = request("/api/groups", {"name":"Other reaction group", "members":members}, status=201)
                    feed = f"/api/groups/{group['id']}/messages"
                    request(feed, {"text":"Review the notes","recipients":[members[1]],"revision":group["revision"]}, status=202)
                    group_reply = until(lambda: next((m for m in request(feed)["items"] if m["author"]), None))
                    cli("server", "stop")
                    core_running = False
                    direct_reaction = f"{direct}/{reply['id']}/reaction"
                    group_reaction = f"{feed}/{group_reply['id']}/reaction"
                    like = {"reaction":"like"}
                    for path in (direct_reaction, group_reaction):
                        request(path,like,authorized=False,status=401)
                        request(path,like,origin="http://external.test",status=403)
                        request(path,{"reaction":"custom"},status=422)
                    request(f"{direct}/{snapshot}/reaction",like,status=404)
                    request(f"/api/history/{core}/{reviewer['address']}/{reviewer['created_ms']}/{reply['id']}/reaction",like,status=404)
                    request(f"/api/groups/{other['id']}/messages/{group_reply['id']}/reaction",like,status=404)
                    assert request(direct_reaction,like) == like
                    if chrome:
                        browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                        subprocess.run(browser,check=True,timeout=90)
                    else:
                        request(direct_reaction,{"reaction":"thanks"})
                        request(group_reaction,{"reaction":"celebrate"})
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request("/api/workspace",status=503)
                    assert next(m for m in request(direct)["items"] if m["id"] == reply["id"])["reaction"] == "thanks"
                    remaining = request(feed)["items"]
                    assert len(remaining) == 2 and remaining[-1]["reaction"] == "celebrate"
                    assert request(group_reaction,{"reaction":"remove"}) == {"reaction":None}
                    assert "reaction" not in request(feed)["items"][-1]
                    return
                if focus == "vault-request":
                    endpoint = "/api/vault"
                    requests = endpoint + "/requests"
                    first = "VAULT_FIXTURE_TOKEN"
                    second = "VAULT_FIXTURE_CANCEL"
                    synthetic = "fixture-browser-private-value"
                    agent = request("/api/agents", {"name":"vault-requester","template":"vault-fixture","task":"Start up"}, status=201)
                    core = request("/api/workspace")["core"]
                    profile_path = f"/api/agents/{agent['address']}/{agent['created_ms']}"
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch_key, = db.execute(
                            "SELECT launch_key FROM journal WHERE agent='vault-requester' AND kind='task'"
                        ).fetchone()
                    session_env = {key:value for key,value in core_env.items() if key != "SWARMHUB_VAULT_KEY_FILE"}
                    session_env.update(SWARMHUB_JOURNAL=str(journal), SWARMHUB_LAUNCH_KEY=launch_key)
                    ready = root / "vault-agent-ready"
                    until(lambda: ready.exists() and ready.stat().st_size)
                    launch_checks = json.loads(ready.read_text())
                    assert launch_checks == {"key_path":False, "session":True, "tty":True}, launch_checks
                    serial = 0

                    def vault_cmd(verb, name, *args, ok=True):
                        nonlocal serial
                        serial += 1
                        path = root / f"vault-agent-result-{serial}"
                        cli("send", "vault-requester", "Vault fixture: " + json.dumps([serial, verb, "--name", name, *args]))
                        until(path.exists)
                        code, stdout, stderr = json.loads(path.read_text())
                        assert (code == 0) == ok, (verb, code, stderr)
                        assert synthetic not in stdout + stderr
                        if not ok:
                            return None
                        return (stdout, stderr) if verb == "exec" else json.loads(stdout)

                    # This is the exact row a process with write access to the old approval table could forge.
                    entry = request(endpoint, {"name":first,"value":synthetic}, status=201)
                    with sqlite3.connect(journal) as db:
                        db.execute("""
                            INSERT INTO vault_requests (id,launch,name,label,description,state,expires_ms,entry_id,entry_revision)
                            SELECT 'forged',id,?, 'Reports','Read a report','approved',?,?,?
                            FROM journal WHERE launch_key=?
                            """, (first, int(time.time() * 1000) + 300_000, entry["id"], entry["revision"], launch_key))
                    assert vault_cmd("status", first) == {"status":"unavailable","name":first}
                    vault_cmd("exec", first, "--", "/bin/true", ok=False)
                    forged = subprocess.run([bridge, "vault", "exec", "--name", first, "--", "/bin/true"],
                                            env=session_env, capture_output=True, timeout=15)
                    assert forged.returncode != 0 and synthetic.encode() not in forged.stdout + forged.stderr
                    request(endpoint + "/" + entry["id"] + "/remove", {"revision":entry["revision"]})
                    assert request(requests, authorized=False, status=401)
                    for name in (first, second):
                        assert vault_cmd("request", name, "--label", "Report credential",
                                         "--description", "Read the synthetic report") == {"status":"pending","name":name}
                    entries = request(requests)
                    assert len(entries) == 2
                    assert entries[0]["bot"] == "vault-requester" and entries[0]["needs_value"]
                    assert all(set(entry) == {"id","bot","name","label","description","needs_value"} for entry in entries)
                    decision = requests + "/" + entries[0]["id"]
                    request(decision, {"action":"save","value":synthetic}, status=401, authorized=False)
                    request(decision, {"action":"save","value":synthetic}, status=403, origin="https://outside.test")
                    bad = request(decision, {"action":"save","value": {"data":synthetic}}, status=422)
                    assert synthetic not in json.dumps(bad)
                    vault_cmd("exec", first, "--", "/bin/false", ok=False)
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                    else:
                        for entry in entries:
                            if entry["name"] == first:
                                assert request(requests + "/" + entry["id"], {"action":"allow_repeated","value":synthetic}) == {
                                    "status":"resolved","name":first}
                            else:
                                request(requests + "/" + entry["id"], {"action":"cancel"})
                    assert request(requests) == []
                    assert vault_cmd("status", first) == {"status":"approved","name":first}
                    assert vault_cmd("status", second) == {"status":"cancelled","name":second}
                    saved, = request(endpoint)["entries"]
                    assert set(saved) == {"id","name","revision","updated_ms"} and saved["name"] == first
                    request(endpoint + "/" + saved["id"], status=404)
                    command = (
                        'test -z "${SWARMHUB_VAULT_SESSION+x}" || exit 24; '
                        'if (printf "%s\\n" "$VAULT_FIXTURE_TOKEN" >/dev/tty) 2>/dev/null; then exit 23; fi; '
                        'printf "%s\\n" "$VAULT_FIXTURE_TOKEN"; printf "%s\\n" "$VAULT_FIXTURE_TOKEN" >&2'
                    )
                    stdout, stderr = vault_cmd("exec", first, "--", "/bin/sh", "-c", command)
                    assert stdout == stderr == "[REDACTED]\n"
                    for _ in range(9):
                        vault_cmd("exec", first, "--", "/bin/true")
                    subprocess.run([bridge, "capture-reply"], env=session_env, text=True,
                                   input="Vault tool result: " + stdout, check=True, timeout=12)
                    conversation = f"/api/history/{core}/{agent['address']}/{agent['created_ms']}"
                    for _ in range(80):
                        rows = json.dumps(request(conversation))
                        assert synthetic not in rows
                        if "Vault tool result: [REDACTED]" in rows:
                            break
                        time.sleep(.1)
                    else:
                        raise AssertionError("The journal did not capture the filtered reply")
                    transcript = request(conversation + "/transcript")
                    assert b"Vault tool result: [REDACTED]" in transcript and synthetic.encode() not in transcript
                    headers = {"Authorization": f"Bearer {token}", "Accept":"text/event-stream"}
                    stream = urllib.request.Request(base + profile_path + "/events", headers=headers)
                    with urllib.request.urlopen(stream, timeout=10) as events:
                        assert events.headers.get_content_type() == "text/event-stream"
                        for _ in range(25):
                            line = events.readline()
                            assert synthetic.encode() not in line
                            if b"Vault tool result: [REDACTED]" in line:
                                break
                        else:
                            raise AssertionError("The event stream did not send the filtered reply")
                    assert vault_cmd("status", first) == {"status":"used","name":first}
                    vault_cmd("exec", first, "--", "/bin/true", ok=False)
                    renamed = request(endpoint + "/" + saved["id"] + "/rename", {"name":"VAULT_FIXTURE_ROTATED","revision":1})
                    assert renamed["revision"] == 2 and renamed["name"] == "VAULT_FIXTURE_ROTATED"
                    request(endpoint + "/" + saved["id"] + "/remove", {"revision":2})
                    assert request(endpoint)["entries"] == []
                    assert all(synthetic.encode() not in file.read_bytes() for file in journal.parent.glob("workspace.sqlite3*"))
                    return
                if focus == "vault":
                    endpoint = "/api/vault"
                    folder = "/api/connected-files"
                    named = {"name":"Reports credential","value":vault_password}
                    request(endpoint,status=401,authorized=False)
                    request(endpoint,named,status=403,origin="https://outside.test")
                    assert request(endpoint) == {"configured":True,"entries":[],"bindings":[
                        {"name":"Reports credential","used_by":["Connected files"],"present":False},
                        {"name":"Slack credential","used_by":["Slack events"],"present":False},
                    ]}
                    request(folder,status=502)
                    secret = request(endpoint,named,status=201)
                    assert secret["revision"] == 1 and vault_password not in json.dumps(secret)
                    request(endpoint,{**named,"name":"reports credential"},status=409)
                    request(endpoint,{**named,"name":"../../outside"},status=422)
                    assert request(folder)["entries"]
                    row = endpoint + "/" + secret["id"]
                    request(row,status=404)
                    request(row+"/replace",{"revision":0,"value":"wrong fixture password"},status=409)
                    replaced = request(row+"/replace",{"revision":1,"value":"wrong fixture password"})
                    request(folder,status=502)
                    restored = request(row+"/replace",{"revision":replaced["revision"],"value":vault_password})
                    assert request(folder)["entries"] and request(endpoint)["entries"] == [restored]
                    recipient = request("/api/agents",{"name":"vault-signing","template":"fixture","task":"Start up"},status=201)
                    slack = request("/api/routines",{"name":"Vault-backed Slack","task":"Review the mention",
                        "target":{k:recipient[k] for k in ("address","created_ms")},
                        "schedule":{"kind":"webhook","source":"slack","filters":[
                            {"field":"team_id","equals":"T123TEST"},{"field":"channel","equals":"C123TEST"},
                        ]}},status=201)
                    detail = f"/api/routines/{slack['id']}"
                    assert not request(detail)["slack_ready"]
                    def challenge(secret,expected=200):
                        timestamp = str(int(time.time()))
                        data = b'{"type":"url_verification","challenge":"vault-fixture"}'
                        signed = f"v0:{timestamp}:".encode() + data
                        headers = {"Content-Type":"application/json","X-Slack-Request-Timestamp":timestamp,
                                   "X-Slack-Signature":"v0="+hmac.new(secret.encode(),signed,"sha256").hexdigest()}
                        try:
                            response = urllib.request.urlopen(urllib.request.Request(base+"/hooks/slack",data=data,headers=headers),timeout=12)
                        except urllib.error.HTTPError as error:
                            response = error
                        with response:
                            assert response.status == expected, (response.status,response.read())
                            return json.load(response)
                    first_signer = secrets.token_hex(16)
                    next_signer = secrets.token_hex(16)
                    challenge(first_signer,expected=503)
                    bound = request(endpoint,{"name":"Slack credential","value":first_signer},status=201)
                    assert request(detail)["slack_ready"] and challenge(first_signer) == {"challenge":"vault-fixture"}
                    assert all(binding["present"] for binding in request(endpoint)["bindings"])
                    slack_item = endpoint+"/"+bound["id"]
                    changed = request(slack_item+"/replace",{"revision":bound["revision"],"value":next_signer})
                    challenge(first_signer,expected=401)
                    assert challenge(next_signer) == {"challenge":"vault-fixture"}
                    request(slack_item+"/remove",{"revision":changed["revision"]})
                    challenge(next_signer,expected=503)
                    assert not request(detail)["slack_ready"]
                    with sqlite3.connect(root / "workspace/workspace.sqlite3") as db:
                        nonce, ciphertext = db.execute("SELECT nonce,ciphertext FROM vault_secrets").fetchone()
                        assert len(nonce)==12 and len(ciphertext)==len(vault_password)+16
                    assert all(all(value.encode() not in file.read_bytes() for value in (vault_password,first_signer,next_signer))
                               for file in (root/"workspace").glob("workspace.sqlite3*"))
                    cli("server","stop")
                    core_running = False
                    master = vault_key.read_text()
                    stop(process)
                    process = None
                    vault_key.write_text(secrets.token_hex(32)+"\n")
                    process,base = start_bridge()
                    request(endpoint,status=409)
                    request(endpoint,named,status=409)
                    request(folder,status=502)
                    stop(process)
                    process = None
                    vault_key.write_text(master)
                    process,base = start_bridge()
                    assert request(folder)["entries"]
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                    request(row+"/remove",{"revision":restored["revision"]})
                    request(folder,status=502)
                    assert request(endpoint)["entries"] == []
                    return
                if focus == "connected-files":
                    _, calls, name, payload, _ = dav
                    assert request("/api/workspace")["connected_files"]
                    endpoint = "/api/connected-files"
                    request("/api/drive-files/status",status=401,authorized=False)
                    assert request("/api/drive-files/status") == {"configured":False,"uploads":False,"connectable":False}
                    request(endpoint, status=401, authorized=False)
                    request(endpoint + "/file?path=Team+blue%2FPolicy.txt", status=401, authorized=False)
                    request(endpoint + "?path=..%2Foutside", status=422)
                    assert request(endpoint + "/capabilities") == {"configured":True,"uploads":False}
                    request(endpoint + "/export", {"source":{"kind":"library","id":1},"folder":"","name":"Test.txt"}, status=422)
                    assert not calls
                    listing = request(endpoint)
                    assert listing["configured"] and not listing["truncated"]
                    assert [item["name"] for item in listing["entries"]] == ["Team blue","huge.bin","redirect.txt","stream.bin"]
                    assert request(endpoint + "?path=Team+blue")["entries"] == [{"name":name,"folder":False,"bytes":len(payload)}]
                    agent = request("/api/agents", {"name":"files-agent","template":"fixture","task":"Read only the starter task"}, status=201)
                    key = f"{agent['address']}/{agent['created_ms']}"
                    route = f"/api/agents/{key}/connected-file"
                    request(route, {"path":"redirect.txt"}, status=502)
                    request(route, {"path":"stream.bin"}, status=422)
                    assert all("/outside/" not in sent for _, sent in calls)
                    assert [item["kind"] for item in request(f"/api/history/{core}/{key}")["items"]] == ["task"]
                    if chrome:
                        browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                        subprocess.run(browser, check=True, timeout=90)
                    else:
                        request(route, {"path":"Team blue/" + name}, status=201)
                    history = request(f"/api/history/{core}/{key}")["items"]
                    if chrome:
                        assert [item["kind"] for item in history] == ["task","task","task"]
                        assert history[1]["text"] == "Keep this draft." and history[1]["state"] in ("sent","start_not_observed")
                        file = history[1]["files"][0]
                        assert file["name"] == name and file["bytes"] == len(payload)
                        assert request(f"/api/history/{core}/{key}/files/{history[1]['id']}/{file['id']}") == payload
                        copied = history[2]["files"][0]
                        assert copied["name"] == "Launch notes.docx"
                        assert request(f"/api/history/{core}/{key}/files/{history[2]['id']}/{copied['id']}") == b"Drive export fixture"
                    else:
                        assert [item["kind"] for item in history] == ["task","attachment"]
                        assert history[1]["detail"] == name and Path(history[1]["text"]).read_bytes() == payload
                    cli("server","stop")
                    core_running = False
                    assert request(endpoint + "?path=Team+blue")["entries"][0]["name"] == name
                    previous = list(calls)
                    request(route, {"path":"Team blue/" + name}, status=503)
                    assert calls == previous
                    if chrome:
                        subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"connected-files-offline"},
                                       check=True,timeout=65)
                    assert all(method in ("PROPFIND","GET") and path.startswith("/reports/") for method,path in calls)
                    return
                if focus == "connected-save":
                    _, calls, existing, original, uploads = dav
                    endpoint = "/api/connected-files"
                    agents = [request("/api/agents", {"name":name,"template":"fixture","task":"Draft a report"}, status=201)
                              for name in ("report-author", "report-reviewer")]
                    group = request("/api/groups", {"name":"Report review", "members":[
                        {k:a[k] for k in ("address", "created_ms")} for a in agents]}, status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    group_payload = b"Group attachment, copied intact.\n"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                            (agents[0]["address"], core)).fetchone()[0]
                        message = db.execute("INSERT INTO group_messages (group_id,text,at_ms) VALUES (?,?,?)",
                                             (group["id"],"Read the report",int(time.time()*1000))).lastrowid
                        group_file = db.execute("INSERT INTO group_attachments (message_id,name,data) VALUES (?,?,?)",
                                                (message,"Group notes.txt",group_payload)).lastrowid
                    report = root / "Workspace report.txt"
                    payload = b"Workspace report\nThe original saved bytes.\n"
                    report.write_bytes(payload)
                    subprocess.run([bridge,"publish-file",str(report)],check=True,capture_output=True,
                                   env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch})
                    file_id = request("/api/library/files")[0]["id"]
                    cli("server","stop")
                    core_running = False
                    request("/api/workspace", status=503)
                    request(endpoint + "/capabilities",status=401,authorized=False)
                    assert request(endpoint + "/capabilities") == {"configured":True,"uploads":True}
                    dest = {"source":{"kind":"library","id":file_id}, "folder":"Team blue", "name":"Published notes.txt"}
                    request("/api/drive-files/export",dest,status=401,authorized=False)
                    request("/api/drive-files/export",dest,status=403,origin="https://outside.test")
                    request("/api/drive-files/export",dest,status=422)
                    route = endpoint + "/export"
                    request(route,dest,status=401,authorized=False)
                    request(route,{**dest,"folder":"../outside"},status=422)
                    request(route,{**dest,"name":"report/notes.txt"},status=422)
                    request(route,{**dest,"source":{"kind":"group","id":group_file,"group":group["id"]+1}},status=404)
                    assert not calls
                    if chrome:
                        browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                        subprocess.run(browser,check=True,timeout=80)
                    else:
                        request(route,{**dest,"name":existing},status=409)
                        assert request(route,dest,status=201) == {"path":"Team blue/Published notes.txt","bytes":len(payload)}
                    request(route,dest,status=409)
                    request(route,{**dest,"folder":"Missing folder"},status=409)
                    group_dest = {"source":{"kind":"group","id":group_file,"group":group["id"]},
                                  "folder":"","name":"Group notes.txt"}
                    assert request(route,group_dest,status=201) == {"path":"Group notes.txt","bytes":len(group_payload)}
                    assert uploads == {"/reports/Team blue/Published notes.txt":payload, "/reports/Group notes.txt":group_payload}
                    assert request(endpoint + "?path=Team+blue")["entries"][0]["bytes"] == len(original)
                    assert all(path.startswith("/reports/") for _,path in calls)
                    return
                if focus == "grok-skill-import":
                    folder = root / "Indexed skill export"
                    source = [{"file":"skills/release/SKILL.md","name":"Release review",
                               "instructions":"---\nname: release-review\n---\n# Release steps\n<script>window.importedSkillRan=true</script>\n"},
                              {"file":"skills/legacy/SKILL.md","name":"Legacy checklist","instructions":"Use the dated checklist.\n"}]
                    for record in [*source,{"file":"skills/unlisted/SKILL.md","instructions":"This file is not listed in the index."}]:
                        path = folder / record["file"]
                        path.parent.mkdir(parents=True)
                        path.write_text(record["instructions"],encoding="utf-8")
                    index = [{"file":row["file"],"name":row["name"]} for row in source] + [
                        {"file":"skills/missing/SKILL.md","name":"Missing written copy"},
                        {"file":"skills/../index.json","name":"Unsafe reference"},
                    ]
                    (folder/"index.json").write_text(json.dumps({"format":"agentapp-bot-bundle/v1","bots":[],"skills":index}))
                    route = "/api/grok-imports/skill-drafts"
                    request(route,status=401,authorized=False)
                    request(route,source[0],status=403,origin="https://outside.test")
                    request(route,{**source[0],"file":"skills/../SKILL.md"},status=422)
                    request(route,{**source[0],"file":"https://outside.test/skills/example/SKILL.md"},status=422)
                    request(route,{**source[0],"name":"Line\ncontrol"},status=422)
                    request(route,{**source[0],"instructions":"x"*(10*1024+1)},status=422)
                    assert request(route) == [] and request("/api/skills") == []
                    cli("server","stop")
                    core_running = False
                    accepted = {"name":"Reviewed release notes","summary":"After preparing a release",
                                "instructions":"Check the date and include the full changelog."}
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=75)
                    else:
                        add,dismiss = [request(route,row) for row in source]
                        assert len(request(route)) == 2 and request("/api/skills") == []
                        request(route+f"/{add['id']}",accepted)
                        request(route+f"/{dismiss['id']}/dismiss",{})
                    saved = request("/api/skills")
                    assert len(saved) == 1 and saved[0]["name"] == accepted["name"]
                    assert request(f"/api/skills/{saved[0]['id']}")["instructions"] == accepted["instructions"]
                    add,dismiss = [request(route,row) for row in source]
                    assert add["state"] == "saved" and dismiss["state"] == "dismissed"
                    assert request(route) == [] and request(route+f"/{add['id']}")["instructions"] is None
                    assert request(route+f"/{add['id']}",accepted)["id"] == saved[0]["id"]
                    request(route+f"/{dismiss['id']}",accepted,status=409)
                    assert request("/api/grok-imports") == [] and request("/api/profiles") == []
                    return
                if focus == "grok-import":
                    if not chrome:
                        raise AssertionError("The Grok Bot import smoke requires Chrome.")
                    folder = root / "Grok export"
                    bot_dir = folder / "scout-archive"
                    group_dir = folder / "review-archive"
                    bot_dir.mkdir(parents=True)
                    group_dir.mkdir()
                    chunk = [{"id":f"m{seq}", "seq":seq, "role":"assistant", "author":"Scout",
                              "text":f"Original line {seq}", "timestamp":f"2025-10-09T08:53:{seq:02d}.000Z"}
                             for seq in range(10,45)]
                    chunk[0].update(role="user", author=None, text="Review <em>migration</em> literally")
                    attachment_name = "Plan & notes.txt"
                    attachment_data = b"Archive attachment copied intact.\n"
                    copies = bot_dir / "attachments"
                    copies.mkdir()
                    (copies / attachment_name).write_bytes(attachment_data)
                    (copies / "hidden.txt").write_text("Not part of a visible message.")
                    (copies / "bundle.json").write_text("An unrelated file in the attachments folder.")
                    chunk[1]["attachments"] = [
                        {"file":"attachments/review.pdf", "available":False},
                        {"file":"attachments/" + attachment_name, "available":False},
                    ]
                    chunk.append({"id":"hidden", "seq":8, "role":"assistant", "text":"Never show this hidden entry", "hidden":True,
                                  "attachments":[{"file":"attachments/hidden.txt", "available":False}]})
                    bundle = {"format":"agentapp-bot-bundle/v1", "source_id":"001-source-scout",
                              "slug":"workspace-scout","name":"Workspace Scout","description":"Research agent",
                              "avatar":{"shape":"gem","colour":"yellow"},
                              "instructions":"Use headings in research notes.", "messages":chunk,
                              "routines":[
                                  {"id":"grok-automation-0001","name":"Old weekly job","prompt":"","schedule":None,
                                   "trigger":None,"timezone":None,"enabled":False},
                                  {"id":"grok-automation-0002","name":"Morning review","prompt":"Summarize the open questions.",
                                   "schedule":"30 8 * * 1-5","timezone":"Europe/Warsaw","enabled":True},
                                  {"id":"grok-automation-0003","name":"Custom timing","prompt":"","schedule":"5 */3 * * *",
                                   "timezone":"Europe/Warsaw","enabled":True},
                              ],
                              "connectors":[{"name":"Old connector"}]}
                    group = {"format":bundle["format"], "source_id":"002-source-group", "name":"Migration review", "is_group":True,
                             "members":[{"name":"Workspace Scout"}], "messages":[
                                 {"id":"g1","seq":1,"role":"user","text":"Group notes in the archived chat."},
                                 {"id":"g2","seq":2,"role":"assistant","author":"Reviewer","text":"Archived group answer."},
                             ]}
                    (bot_dir / "bundle.json").write_text(json.dumps(bundle))
                    (group_dir / "bundle.json").write_text(json.dumps(group))
                    (folder / "index.json").write_text('{"format":"agentapp-bot-bundle/v1","bots":[]}')
                    raw = json.dumps(bundle).encode()
                    importing = "/api/grok-imports"
                    request(importing,raw,status=401,authorized=False)
                    request(importing + "/preview",b'{"format":"wrong"}',status=422)
                    preview = request(importing + "/preview",raw)
                    assert preview["visible_messages"] == 35 and preview["routines"] == 3
                    assert preview["attachment_names"] == [attachment_name, "review.pdf"]
                    assert request(importing) == [] and request("/api/profiles") == []
                    cli("server","stop")
                    core_running = False
                    legacy = "/api/history/legacy-core/t5/1/transcript"
                    assert b"#" in request(legacy) and b"Preserve this task" in request(legacy)
                    request(legacy, status=401, authorized=False)
                    request("/api/history/legacy-core/t5/99/transcript", status=404)
                    browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                    subprocess.run(browser, check=True, timeout=100)
                    archives = {item["agent"]:item for item in request(importing)}
                    assert len(archives) == 2 and archives["Migration review"]["is_group"] and archives["Migration review"]["profile_id"] is None
                    scout = archives["Workspace Scout"]
                    profile = request("/api/profiles")[0]
                    assert not profile["sessions"] and scout["profile_id"] == profile["id"]
                    assert profile["avatar"] == "layers" and profile["instructions"] == bundle["instructions"]
                    assert profile["imported_archive"] == scout
                    assert request("/api/routines") == [] and request("/api/groups") == []
                    draft_url = "/api/routines/imported"
                    drafts = {item["name"]:item for item in request(draft_url)}
                    assert len(drafts) == 3 and all(item["profile_id"] == profile["id"] for item in drafts.values())
                    assert drafts["Old weekly job"]["schedule"] is None and drafts["Old weekly job"]["task"] == ""
                    assert drafts["Morning review"]["schedule"] == {
                        "kind":"daily","hour":8,"minute":30,"timezone":"Europe/Warsaw","weekdays":True,
                    }
                    assert drafts["Custom timing"]["schedule"] is None and "5 */3 * * *" in drafts["Custom timing"]["source_hint"]
                    request(draft_url, status=401, authorized=False)
                    request(f"{draft_url}/{drafts['Custom timing']['id']}/dismiss",{},status=401,authorized=False)
                    def archive_path(archive):
                        return f"/api/history/{archive['core']}/{archive['address']}/0"
                    first_page = request(archive_path(scout))
                    assert [item["id"] for item in first_page["items"]] == list(range(15,45))
                    older = request(archive_path(scout) + f"?before={first_page['before']}")["items"]
                    assert [item["id"] for item in older] == list(range(10,15))
                    assert older[0]["text"] == chunk[0]["text"] and older[0]["detail"] == "You"
                    assert "1 attachment unavailable" in older[1]["text"] and older[1]["attachments"] == [attachment_name]
                    archive_id = scout["address"].split("-", 1)[1]
                    files = f"{importing}/{archive_id}/attachments"
                    plan = files + "/Plan%20%26%20notes.txt"
                    assert request(plan) == attachment_data
                    request(plan, status=401, authorized=False)
                    request(files + "/hidden.txt", status=404)
                    request(files + "/bundle.json", status=404)
                    request(files + "/review.pdf", status=404)

                    def upload_copies(copies, status=200, authorized=True):
                        boundary = secrets.token_hex(16)
                        parts = []
                        for field, name, data in [("bundle", "bundle.json", raw)] + [
                            ("file", name, data) for name, data in copies
                        ]:
                            parts.extend([f'--{boundary}\r\nContent-Disposition: form-data; name="{field}"; '
                                          f'filename="{name}"\r\n\r\n'.encode(), data, b"\r\n"])
                        parts.append(f"--{boundary}--\r\n".encode())
                        return request(importing + "/with-files", b"".join(parts), status=status,
                                       authorized=authorized, media_type=f"multipart/form-data; boundary={boundary}")

                    upload_copies([("hidden.txt", b"Hidden")], status=422)
                    upload_copies([("review.pdf", b"PDF fixture")], status=401, authorized=False)
                    upload_copies([("review.pdf", bytes(8 * 1024 * 1024 + 1))], status=413)
                    restored = upload_copies([(attachment_name, b"Do not replace"), ("review.pdf", b"PDF fixture")])
                    assert restored["added"] == 0 and restored["added_files"] == 1
                    restored_line = request(archive_path(scout) + "?before=15")["items"][1]
                    assert restored_line["text"] == chunk[1]["text"]
                    assert restored_line["attachments"] == [attachment_name, "review.pdf"]
                    assert request(files + "/review.pdf") == b"PDF fixture" and request(plan) == attachment_data
                    restored_transcript = request(archive_path(scout) + "/transcript")
                    assert b"File: review.pdf" in restored_transcript and b"attachment unavailable" not in restored_transcript
                    request(importing + "/999999/attachments/review.pdf",status=404)
                    assert request(archive_path(archives["Migration review"]))["items"][-1]["detail"] == "Reviewer"
                    assert request("/api/search?q=Never+show+this+hidden+entry") == []
                    profile_path = f"/api/profiles/{profile['id']}"
                    request(profile_path,{"name":"Scout on DMT","subtitle":"Edited locally","avatar":"target",
                                          "instructions":"Use short notes.","pinned":False,"hidden":False,"revision":profile["revision"]})
                    assert request(importing + "/preview",raw)["already_saved"]
                    already_saved = request(importing,raw)
                    assert already_saved["added"] == 0 and already_saved["routine_drafts"] == 0
                    supplemented = {**bundle, "name":"New export name","messages":[chunk[0], {
                        "seq":2, "id":"old2", "role":"user", "text":"Earlier imported detail",
                        "timestamp":"2025-10-08T09:12:00Z",
                    }]}
                    assert request(importing,json.dumps(supplemented).encode())["added"] == 1
                    assert request("/api/profiles")[0]["name"] == "Scout on DMT"
                    assert request("/api/profiles")[0]["instructions"] == "Use short notes."
                    assert request(archive_path(scout) + "?before=15")["items"][0]["id"] == 2
                    request(importing,json.dumps({**bundle,"is_group":True}).encode(),status=409)
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    cli("server","start")
                    core_running = True
                    process, base = start_bridge(port)
                    hits = request("/api/search?q=Earlier+imported+detail&kind=messages")
                    assert len(hits) == 1 and hits[0]["id"] == 2 and hits[0]["core"] == scout["core"]
                    subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"grok-import-launch"},check=True,timeout=90)
                    started = request("/api/profiles")[0]
                    assert started["imported_archive"]["address"] == scout["address"] and len(started["sessions"]) == 1
                    session = started["sessions"][0]
                    live = request(f"/api/history/{session['core']}/{session['address']}/{session['created_ms']}")["items"]
                    assert [item["text"] for item in live] == ["First task on Herdr"] and live[0]["launch_instructions"] == "Use short notes."
                    routines = request("/api/routines")
                    assert len(routines) == 1 and routines[0]["name"] == "Old weekly job"
                    assert routines[0]["state"] == "paused" and routines[0]["next_at"] is None
                    assert routines[0]["target"] == {key:session[key] for key in ("address","created_ms")}
                    assert routines[0]["task"] == "Review one sample note." and routines[0]["schedule"] == {"kind":"interval","minutes":90}
                    assert not request(f"/api/routines/{routines[0]['id']}")["runs"]
                    others = request("/api/agents", {"name":"different-agent","template":"fixture","task":"Verify session ownership"}, status=201)
                    foreign = {key:others[key] for key in ("address","created_ms")}
                    request(f"{draft_url}/{drafts['Morning review']['id']}/configure",
                            {"target":foreign,"name":"Morning review","task":"Keep drafts scoped.",
                             "schedule":{"kind":"interval","minutes":60}},status=409)
                    request(f"{draft_url}/{drafts['Old weekly job']['id']}/configure",
                            {"target":routines[0]["target"],"name":"Retry already configured","task":"Do not duplicate.",
                             "schedule":{"kind":"interval","minutes":60}},status=409)
                    assert request(importing,raw)["routine_drafts"] == 0
                    assert [item["name"] for item in request(draft_url)] == ["Morning review"]
                    assert len(request("/api/routines")) == 1
                    return
                if focus == "profile-avatar":
                    import base64
                    import struct
                    import zlib
                    if not chrome:
                        raise AssertionError("The profile avatar smoke requires Chrome.")

                    def image(width, height):
                        def chunk(kind, payload):
                            return struct.pack(">I",len(payload)) + kind + payload + struct.pack(">I",zlib.crc32(kind + payload))
                        pixels = bytearray()
                        for y in range(height):
                            pixels.append(0)
                            for x in range(width):
                                right = x >= width // 2
                                mountain = right and 90 < x - width // 2 + y < 160 and 45 < y < 100
                                color = (237,240,255) if mountain else (55,105,190) if right else (201,105,75)
                                pixels.extend(color)
                        return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">IIBBBBB",width,height,8,2,0,0,0))
                                + chunk(b"tEXt", b"Comment\x00Private source caption")
                                + chunk(b"IDAT",zlib.compress(pixels)) + chunk(b"IEND",b""))

                    source = image(320,140)
                    (root / "Wide picture.png").write_bytes(source)
                    (root / "Not an image.png").write_bytes(b"<svg><text>Not a raster</text></svg>")
                    agent = request("/api/agents", {"name":"avatar-agent", "template":"fixture", "task":"Keep this history"}, status=201)
                    profile_id = agent["profile_id"]
                    route = f"/api/profiles/{profile_id}"
                    edit = {"name":"avatar-agent","subtitle":"Studio","avatar":"image","pinned":False,"hidden":False,"revision":1}
                    request(route, edit, status=422)
                    request(route, {**edit,"avatar_png":base64.b64encode(source).decode()}, status=422)
                    request(route, {**edit,"avatar_png":base64.b64encode(b"<svg/>").decode()}, status=422)
                    request(route, {**edit,"avatar":"target","avatar_png":base64.b64encode(image(160,160)).decode()}, status=422)
                    assert request("/api/profiles")[0]["revision"] == 1
                    cli("server","stop")
                    core_running = False
                    browser = ["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp]
                    subprocess.run(browser, check=True, timeout=80)
                    record = request("/api/profiles")[0]
                    assert record["avatar"] == "image" and record["subtitle"] == "Studio"
                    path = route + "/avatar/" + record["avatar_key"]
                    cropped = request(path)
                    assert cropped.startswith(b"\x89PNG\r\n\x1a\n") and struct.unpack(">II",cropped[16:24]) == (160,160)
                    assert b"Private source caption" not in cropped
                    request(path, status=401, authorized=False)
                    request(route + "/avatar/" + "a"*32, status=404)
                    copy = request(route + "/duplicate", {"name":"Avatar copy", "revision":record["revision"]}, status=201)
                    assert copy["avatar"] == "image" and not copy["sessions"]
                    copy_path = f"/api/profiles/{copy['id']}/avatar/{copy['avatar_key']}"
                    assert request(copy_path) == cropped
                    request(route, {**edit, "revision":record["revision"]})
                    assert request(path) == cropped  # A label-only edit preserves its image.
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request(path) == cropped and request(copy_path) == cropped
                    request(route, {**edit,"avatar":"target","revision":record["revision"]+1})
                    request(path, status=404)
                    assert request(copy_path) == cropped
                    subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"profile-avatar-copy"}, check=True, timeout=70)
                    return
                if focus == "roster-sections":
                    if not chrome:
                        raise AssertionError("The roster sections smoke requires Chrome.")
                    def profiles():
                        return {row["name"]:row for row in request("/api/profiles")}
                    for name in ("atlas", "summit", "private"):
                        request("/api/agents", {"name":name, "template":"fixture", "task":f"Keep {name} history"}, status=201)
                    prepared = profiles()
                    sections = "/api/roster-sections"
                    planning = request(sections, {"name":"Planning"}, status=201)
                    request(sections, {"name":"planning"}, status=409)
                    request(sections, {"name":"Pinned"}, status=422)
                    request(sections, {"name":"Outside request"}, status=401, authorized=False)
                    move = f"/api/profiles/{prepared['atlas']['id']}/section"
                    request(move, {"destination":"new", "name":"Rolled back", "revision":0}, status=409)
                    assert request(sections) == [planning]
                    for name in ("summit","private"):
                        row = prepared[name]
                        route = f"/api/profiles/{row['id']}"
                        request(route + "/section", {"destination":"existing", "id":planning["id"], "revision":row["revision"]})
                        request(route, {"name":name, "subtitle":"", "avatar":"initial",
                                        "pinned":name == "summit", "hidden":name == "private",
                                        "revision":row["revision"] + 1})
                    browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                    subprocess.run(browser, check=True, timeout=110)
                    remaining = request(sections)
                    assert [row["name"] for row in remaining] == ["Client delivery"]
                    assert all(row["section_id"] is None for row in profiles().values())
                    assert profiles()["private"]["hidden"] and profiles()["summit"]["pinned"]
                    assert all(row["sessions"] == prepared[name]["sessions"] for name,row in profiles().items())
                    request(move, {"destination":"existing", "id":planning["id"], "revision":profiles()["atlas"]["revision"]}, status=409)
                    request(sections + f"/{remaining[0]['id']}", {"action":"remove", "revision":1}, status=409)
                    port = base.rsplit(":", 1)[1]
                    cli("server", "stop")
                    core_running = False
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"roster-sections-offline"},
                                   check=True, timeout=75)
                    assert profiles()["atlas"]["section_id"] == remaining[0]["id"]
                    hits = request("/api/search?q=Client+delivery&kind=agents")
                    assert [hit["title"] for hit in hits] == ["atlas"]
                    return
                if focus == "profile-copy":
                    template = "claude-copy-source"
                    (templates / f"{template}.md").write_text(
                        f"---\ndescription: Copy settings fixture\n"
                        f"command: SWARMHUB_CLAUDE_BIN={shlex.quote(str(claude))} PICKER_TEST=1 "
                        f"{shlex.quote(bridge)} run-claude --workspace-approvals\n---\n"
                    )
                    model = {"id":"sonnet[1m]", "label":"Fixture Sonnet", "provider":"Anthropic"}
                    (root / "workspace/runtime-catalog.json").write_text(json.dumps({
                        template: {"harness":"Claude Code", "models":[model]},
                    }))
                    original = request("/api/agents", {
                        "name":"original", "template":template, "task":"Original scope and history",
                        "model_choice":model, "collect_results":True, "standing_instructions":"Keep source notes.",
                    }, status=201)
                    targets = {key: original[key] for key in ("address","created_ms")}
                    source_id = original["profile_id"]
                    source_route = f"/api/profiles/{source_id}"
                    request(source_route, {"name":"Client research", "subtitle":"Planning", "avatar":"spark",
                                           "pinned":True, "hidden":False, "revision":1})
                    source = next(profile for profile in request("/api/profiles") if profile["id"] == source_id)
                    assert source["instructions"] == "Keep source notes."
                    skill = request("/api/skills", {"name":"Source-only skill", "summary":"",
                                                   "instructions":"Keep each client separate."}, status=201)
                    request(f"/api/skills/{skill['id']}/availability", {"core":core, "target":targets, "enabled":False})
                    routine = request("/api/routines", {"target":targets, "name":"Weekly review", "task":"Read new notes.",
                                                        "schedule":{"kind":"interval","minutes":10080}}, status=201)
                    routine_url = f"/api/routines/{routine['id']}"
                    request(routine_url + "/test", {}, status=202)
                    original_runs = until(lambda: [run for run in request(routine_url)["runs"] if run["state"] != "pending"])
                    archived = request("/api/routines", {"target":targets, "name":"Old check", "task":"Old task",
                                                          "schedule":{"kind":"interval","minutes":60}}, status=201)
                    request(f"/api/routines/{archived['id']}/state", "archive")
                    group_peer = request("/api/agents", {"name":"group-peer", "template":"fixture", "task":"Test group membership"}, status=201)
                    group = request("/api/groups", {"name":"Original conversations", "members":[targets,
                                   {key:group_peer[key] for key in ("address","created_ms")}]}, status=201)
                    source_folder = Path(source["sessions"][0]["results_folder"])
                    published = source_folder / "Original artifact.txt"
                    published.write_text("Only the original profile gets this result.")
                    assert until(lambda: request("/api/library/files"))[0]["agent"] == "original"
                    request(source_route + "/duplicate", {"name":"Wrong revision", "revision":1}, status=409)
                    request(source_route + "/duplicate", {"name":" \t", "revision":source["revision"]}, status=422)
                    request(source_route + "/duplicate", {"name":"No access", "revision":source["revision"]}, status=401, authorized=False)
                    assert len(request("/api/profiles")) == 2

                    cli("server", "stop")
                    core_running = False
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"profile-copy-create"}, check=True, timeout=80)
                    else:
                        request(source_route + "/duplicate", {"name":"West research", "revision":source["revision"]}, status=201)
                    copy = next(profile for profile in request("/api/profiles") if profile["name"] == "West research")
                    assert copy["id"] != source_id and copy["runtime_name"] != source["runtime_name"]
                    assert not copy["sessions"] and not copy["pinned"] and not copy["hidden"]
                    assert [copy[key] for key in ("subtitle","avatar","instructions")] == ["Planning","spark","Keep source notes."]
                    assert copy["copied_setup"] == {
                        "template":template, "runtime":source["sessions"][0]["runtime"], "collect_results":True, "routines":1,
                    }
                    duplicate_again = request(f"/api/profiles/{copy['id']}/duplicate",
                                              {"name":"Pending copy", "revision":1}, status=201)
                    assert duplicate_again["copied_setup"] == copy["copied_setup"] and not duplicate_again["sessions"]
                    assert len(request("/api/routines")) == 2
                    request(source_route, {"name":source["name"], "subtitle":"Changed later", "avatar":"target",
                                          "pinned":True, "hidden":False, "revision":source["revision"],
                                          "instructions":"Only the original sees this edit."})
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    cli("server", "start")
                    core_running = True
                    process, base = start_bridge(port)
                    if chrome:
                        subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"profile-copy-launch"}, check=True, timeout=80)
                    else:
                        request("/api/agents", {"name":copy["runtime_name"], "template":template, "task":"West first task",
                                                "profile_id":copy["id"], "instructions_revision":copy["revision"],
                                                "model_choice":model, "collect_results":True}, status=201)
                    started = next(profile for profile in request("/api/profiles") if profile["id"] == copy["id"])
                    assert len(started["sessions"]) == 1 and "copied_setup" not in started
                    assert started["instructions"] == "Keep source notes." and started["subtitle"] == "Planning"
                    session = started["sessions"][0]
                    terminal = f"{session['address']}/{session['created_ms']}"
                    assert session["runtime"]["model_id"] == model["id"]
                    assert session["results_folder"] != str(source_folder)
                    history = request(f"/api/history/{session['core']}/{terminal}")["items"]
                    assert [item["text"] for item in history if item["kind"] == "task"] == ["West first task"]
                    assert all(item["kind"] != "artifact" for item in history)
                    assert next(item for item in history if item["kind"] == "task")["launch_instructions"] == copy["instructions"]
                    target = {key:session[key] for key in ("address","created_ms")}
                    copied_routines = [row for row in request("/api/routines") if row["core"] == session["core"]
                                       and row["target"] == target]
                    assert len(copied_routines) == 1
                    new_routine = copied_routines[0]
                    assert new_routine["id"] != routine["id"] and new_routine["state"] == "paused" and new_routine["next_at"] is None
                    assert [new_routine[k] for k in ("name","task","schedule")] == [routine[k] for k in ("name","task","schedule")]
                    assert not request(f"/api/routines/{new_routine['id']}")["runs"]
                    original_routine = request(routine_url)
                    assert original_routine["routine"]["state"] == "active" and original_routine["runs"] == original_runs
                    scope = urllib.parse.urlencode({key:session[key] for key in ("core","address","created_ms")})
                    assert not next(row for row in request("/api/skills?" + scope) if row["id"] == skill["id"])["enabled"]
                    assert [member["name"] for member in request(f"/api/groups/{group['id']}")["members"]] == ["group-peer","original"]
                    return
                if focus == "storage-contention":
                    agent = request("/api/agents", {"name":"busy-journal", "template":"fixture",
                                    "task":"Keep the workspace responsive", "collect_results":True}, status=201)
                    target = {key: agent[key] for key in ("address","created_ms")}
                    routine = request("/api/routines", {
                        "target":target, "name":"Contended routine", "task":"Read the delivery note",
                        "schedule":{"kind":"interval","minutes":60},
                    }, status=201)
                    profile = next(item for item in request("/api/profiles") if item["name"] == "busy-journal")
                    folder = Path(profile["sessions"][0]["results_folder"])
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal, isolation_level=None) as writer:
                        writer.execute("UPDATE routines SET next_at=? WHERE id=?",
                                       (int(time.time()*1000) + 1500, routine["id"]))
                        writer.execute("BEGIN IMMEDIATE")
                        try:
                            (folder / "Contended result.txt").write_text("Saved after the writer released its lock.")
                            # Keep reading throughout the routine's due time and multiple collection ticks.
                            end = time.monotonic() + 7
                            while time.monotonic() < end:
                                req = urllib.request.Request(base + "/api/library/files",
                                                            headers={"Authorization":f"Bearer {token}"})
                                with urllib.request.urlopen(req, timeout=1.5) as response:
                                    assert json.load(response) == []
                                time.sleep(0.15)
                            assert writer.execute("SELECT count(*) FROM routine_runs").fetchone() == (0,)
                        finally:
                            writer.execute("ROLLBACK")
                    routine_url = f"/api/routines/{routine['id']}"
                    runs = until(lambda: [run for run in request(routine_url)["runs"] if run["state"] == "sent"])
                    assert len(runs) == 1 and runs[0]["kind"] == "schedule"
                    key = f"{agent['address']}/{agent['created_ms']}"
                    until(lambda: "Read the delivery note" in request(f"/api/agents/{key}/output")["text"])
                    data = until(lambda: request("/api/library/files"))
                    assert len(data) == 1 and data[0]["title"] == "Contended result.txt"
                    assert request(f"/api/library/files/{data[0]['id']}/download") == b"Saved after the writer released its lock."
                    assert len(request(routine_url)["runs"]) == 1
                    return
                if focus == "results-auto":
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser, check=True, timeout=80)
                    else:
                        request("/api/agents", {"name":"auto-results", "template":"fixture", "task":"Produce automatic results",
                                                "collect_results":True}, status=201)
                    profile = next(item for item in request("/api/profiles") if item["name"] == "auto-results")
                    session = profile["sessions"][0]
                    folder = Path(session["results_folder"])
                    assert folder.parent == root / "workspace/results" and not folder.stat().st_mode & 0o077
                    key = f"{session['address']}/{session['created_ms']}"
                    def report(count):
                        files = request("/api/library/files")
                        return files if len(files) == count else None
                    first = until(lambda: report(1))[0]
                    assert first["title"] == "Automatic report.txt" and first["agent"] == "auto-results"
                    assert request(f"/api/library/files/{first['id']}/download") == b"The finished report"
                    request(f"/api/agents/{key}/messages", {"text":"Revise automatic result"})
                    revised = until(lambda: report(2))[0]
                    assert revised["title"] == first["title"] and request(f"/api/library/files/{revised['id']}/download") == b"Revised report"
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    (folder / "Offline result.txt").write_text("Saved while the workspace was stopped.")
                    process, base = start_bridge(port)
                    last = until(lambda: report(3))[0]
                    assert last["title"] == "Offline result.txt"
                    request("/api/workspace", status=503)
                    assert request(f"/api/library/files/{last['id']}/download") == b"Saved while the workspace was stopped."
                    assert sorted(item["title"] for item in request("/api/library/files")) == ["Automatic report.txt", "Automatic report.txt", "Offline result.txt"]
                    return
                if focus == "pdf":
                    from reportlab.lib.colors import HexColor
                    from reportlab.lib.pdfencrypt import StandardEncryption
                    from reportlab.pdfgen import canvas

                    agents = [request("/api/agents", {"name": name, "template": "fixture", "task": "Review reports"},
                                      status=201) for name in ("pdf-agent", "pdf-peer")]
                    targets = [{k: a[k] for k in ("address", "created_ms")} for a in agents]
                    group = request("/api/groups", {"name": "PDF review", "members": targets}, status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                            (agents[0]["address"], core)).fetchone()[0]

                    def publish(file):
                        subprocess.run([bridge,"publish-file",str(file)],check=True,capture_output=True,
                                       env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch})

                    report = root / "Workspace review.pdf"
                    pdf = canvas.Canvas(str(report), pagesize=(600, 440))
                    for headline, body in (("Workspace review", "Three reports are ready for review."),
                                           ("Next steps", "Confirm the dates before sharing.")):
                        pdf.setFillColor(HexColor("#232944"))
                        pdf.rect(0, 280, 600, 160, stroke=0, fill=1)
                        pdf.setFillColor(HexColor("#a9b9ff"))
                        pdf.setFont("Helvetica", 13)
                        pdf.drawString(36, 392, "SWARMHUB  /  PROJECT NOTES")
                        pdf.setFillColor(HexColor("#ffffff"))
                        pdf.setFont("Helvetica-Bold", 32)
                        pdf.drawString(36, 336, headline)
                        pdf.setFillColor(HexColor("#232944"))
                        pdf.setFont("Helvetica", 16)
                        pdf.drawString(36, 232, body)
                        pdf.linkURL("https://example.invalid/", (36, 220, 325, 250))
                        pdf.showPage()
                    pdf.save()
                    publish(report)

                    locked = root / "Locked report.pdf"
                    protected = canvas.Canvas(str(locked), encrypt=StandardEncryption("fixture-password"))
                    protected.drawString(72, 700, "Protected fixture")
                    protected.save()
                    publish(locked)
                    broken = root / "Broken report.pdf"
                    broken.write_bytes(b"%PDF-1.7\nThis document has no PDF objects.\n")
                    publish(broken)

                    items = {row["title"]: row["id"] for row in request("/api/library/files")}
                    path = f"/api/library/files/{items[report.name]}"
                    assert request(path)["pdf"] and request(path)["preview"] is None
                    request(path + "/download", status=401, authorized=False)
                    assert request(path + "/download") == report.read_bytes()
                    with urllib.request.urlopen(base + "/vendor/pdfjs/pdf.worker.min.mjs") as response:
                        assert response.headers.get_content_type() == "text/javascript"
                        assert "'wasm-unsafe-eval'" in response.headers["Content-Security-Policy"]
                    with urllib.request.urlopen(base + "/") as response:
                        assert "'wasm-unsafe-eval'" not in response.headers["Content-Security-Policy"]
                    request("/vendor/pdfjs/wasm/quickjs-eval.wasm", status=404)
                    request("/vendor/pdfjs/missing.mjs", status=404)

                    boundary = "swarmhub-pdf-fixture"
                    message = json.dumps({"text":"Review the attached report", "recipients": targets[:1],
                                          "revision": group["revision"]}).encode()
                    parts = [f"--{boundary}\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\n".encode(),
                             message, f"\r\n--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
                             'filename="Group review.pdf"\r\nContent-Type: application/pdf\r\n\r\n'.encode(),
                             report.read_bytes(), f"\r\n--{boundary}--\r\n".encode()]
                    feed = f"/api/groups/{group['id']}/messages"
                    request(feed + "/with-files", b"".join(parts), status=202,
                            media_type=f"multipart/form-data; boundary={boundary}")
                    file_id = request(feed)["items"][0]["files"][0]["id"]
                    group_file = f"/api/groups/{group['id']}/files/{file_id}"
                    assert request(group_file + "/info")["pdf"]
                    request(f"/api/groups/{group['id']+1}/files/{file_id}/info", status=404)
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser, check=True, timeout=90)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request(group_file) == report.read_bytes()
                    assert request(path + "/download") == report.read_bytes()
                    if chrome:
                        subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"pdf-offline"}, check=True, timeout=75)
                    return
                if focus == "appearance":
                    assert chrome, "Appearance verification requires Chrome."
                    request("/api/agents", {"name":"appearance-fixture", "template":"fixture", "task":"Prepare the workspace appearance fixture"}, status=201)
                    subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                   check=True, timeout=80)
                    return
                if focus == "desktop-teaching":
                    assert chrome, "Desktop teaching verification requires Chrome."
                    request("/api/agents", {"name":"teaching-fixture", "template":"desktop-fixture", "task":"Scratch desktop"},
                            status=201, timeout=75)
                    until(lambda: (root / "desktop-clicks.log").is_file(), seconds=35)
                    before = request("/api/skills")
                    subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                   check=True, timeout=90)
                    rows = [row for row in request("/api/skills") if row not in before]
                    assert len(rows) == 1 and rows[0]["name"] == "Weekly menu demonstration"
                    skill = request(f"/api/skills/{rows[0]['id']}")
                    assert "Open the report menu" in skill["instructions"]
                    assert "Right click" not in skill["instructions"] and "Do not retain" not in skill["instructions"]
                    return
                if focus == "pwa":
                    assert chrome, "PWA verification requires Chrome."
                    agent = request("/api/agents", {"name":"pwa-fixture", "template":"fixture", "task":"Private history for the PWA fixture"}, status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                            (agent["address"], core)).fetchone()[0]
                    private = root / "pwa-fixture.txt"
                    private.write_text("Private file for the PWA fixture")
                    subprocess.run([bridge, "publish-file", str(private)], check=True, capture_output=True,
                                   env={"SWARMHUB_JOURNAL":str(journal), "SWARMHUB_LAUNCH_KEY":launch})
                    file_id = next(row["id"] for row in request("/api/library/files") if row["title"] == private.name)
                    browser = subprocess.Popen(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                               env={**os.environ, "SWARMHUB_TEST_PWA_FILE_ID":str(file_id)})
                    try:
                        def wait_for_pwa(name):
                            flag = root / name
                            until(lambda: flag.exists() or browser.poll() is not None, seconds=30)
                            assert flag.exists(), "Chrome did not reach " + name
                        wait_for_pwa("pwa-go-offline")
                        port = base.rsplit(":", 1)[1]
                        stop(process)
                        process = None
                        wait_for_pwa("pwa-go-online")
                        process, base = start_bridge(port)
                        assert browser.wait(timeout=25) == 0
                    finally:
                        if browser.poll() is None:
                            browser.terminate()
                            browser.wait(timeout=5)
                    return
                if focus == "dictation":
                    assert chrome, "Dictation verification requires Chrome."
                    agents = [request("/api/agents", {"name": name, "template": "fixture", "task": "Prepare dictation fixture"},
                                      status=201) for name in ("dictation-direct", "dictation-peer")]
                    targets = [{k: agent[k] for k in ("address", "created_ms")} for agent in agents]
                    group = request("/api/groups", {"name": "Dictation group", "members": targets}, status=201)
                    browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                    subprocess.run(browser, check=True, timeout=95)
                    assert request(f"/api/groups/{group['id']}/messages")["items"] == []
                    for agent in agents:
                        history = f"/api/history/{core}/{agent['address']}/{agent['created_ms']}"
                        assert [row["text"] for row in request(history)["items"] if row["kind"] == "task"] == ["Prepare dictation fixture"]
                    return
                if focus == "voice-memos":
                    assert chrome, "Voice memo verification requires Chrome."
                    agents = [request("/api/agents", {"name": name, "template": "fixture", "task": "Prepare voice memo fixture"},
                                      status=201) for name in ("voice-direct", "voice-peer")]
                    targets = [{k: agent[k] for k in ("address", "created_ms")} for agent in agents]
                    group = request("/api/groups", {"name": "Voice memo group", "members": targets}, status=201)
                    browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                    subprocess.run(browser, check=True, timeout=95)
                    feed = f"/api/groups/{group['id']}/messages"
                    group_messages = request(feed)["items"]
                    assert len(group_messages) == 1 and group_messages[0]["text"] == "Group voice draft"
                    file_id = group_messages[0]["files"][0]["id"]
                    group_file = f"/api/groups/{group['id']}/files/{file_id}"
                    assert request(group_file + "/info")["media"]["kind"] == "audio"
                    assert 0 < len(request(group_file)) <= 1024 * 1024
                    return
                if focus == "media":
                    import struct
                    import zlib
                    agents = [request("/api/agents", {"name": name, "template": "fixture", "task": "Prepare saved media"},
                                      status=201) for name in ("media-agent", "media-peer")]
                    targets = [{k: agent[k] for k in ("address","created_ms")} for agent in agents]
                    group = request("/api/groups", {"name":"Media review","members":targets}, status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE address=? AND core_id=? AND launch_key IS NOT NULL",
                                            (agents[0]["address"],core)).fetchone()[0]

                    def chunk(kind, data):
                        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
                    scan = bytearray()
                    for y in range(180):
                        scan.append(0)
                        for x in range(320):
                            bars = ((42, 98, (134, 114, 244)), (132, 62, (100, 203, 189)), (222, 84, (160, 143, 255)))
                            color = next((rgb for left, top, rgb in bars if left <= x < left+54 and top <= y < 151),
                                         (60, 69, 92) if y in (40,77,114,151) else (28, 32, 47))
                            scan.extend(color)
                    image = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR",struct.pack(">IIBBBBB",320,180,8,2,0,0,0))
                             + chunk(b"IDAT",zlib.compress(scan)) + chunk(b"IEND",b""))
                    table = b'Team,Note\r\n"North, Q2","Two\nlines"\r\nWest,<svg onload=alert(1)>\r\n' + b"South,Ready\r\n"*53

                    def recording(extension, source, encoder):
                        path = root / f"preview.{extension}"
                        subprocess.run(["ffmpeg","-nostdin","-v","error","-f","lavfi","-i",source,
                                        "-t","2",*encoder,str(path)],check=True,capture_output=True)
                        return path.read_bytes()

                    picture = "testsrc2=size=160x90:rate=10"
                    mp4 = recording("mp4",picture,["-c:v","libx264","-threads","1","-movflags","+faststart"])
                    webm = recording("webm",picture,["-c:v","libvpx","-threads","1"])
                    wav = recording("wav","sine=frequency=440:sample_rate=8000",["-c:a","pcm_s16le"])
                    bad_mp4 = mp4[:struct.unpack(">I", mp4[:4])[0]]
                    mislabeled = b"<html><script>alert(1)</script></html>"
                    for name,data in (("Progress chart.png",image),("Status table.csv",table),
                                      ("Mislabeled.png",b"<svg onload=alert(1)>"),
                                      ("Progress recording.mp4",mp4),("Audio notes.wav",wav),
                                      ("Incomplete recording.mp4",bad_mp4),("Mislabeled.mp4",mislabeled)):
                        file = root / name
                        file.write_bytes(data)
                        subprocess.run([bridge,"publish-file",str(file)],check=True,capture_output=True,
                                       env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch})
                    inputs = {f["title"]: f["id"] for f in request("/api/library/files")}
                    image_url = f"/api/library/files/{inputs['Progress chart.png']}"
                    metadata = request(image_url)
                    assert metadata["image"] == {"mime":"image/png","width":320,"height":180} and metadata["preview"] is None
                    assert request(image_url + "/image") == image
                    request(image_url + "/image", status=401, authorized=False)
                    request(f"/api/library/files/{inputs['Mislabeled.png']}/image", status=404)
                    csv = request(f"/api/library/files/{inputs['Status table.csv']}")["table"]
                    assert csv["headers"] == ["Team","Note"] and csv["rows"][0] == ["North, Q2","Two\nlines"]
                    assert len(csv["rows"]) == 50 and csv["truncated"]
                    video_url = f"/api/library/files/{inputs['Progress recording.mp4']}"
                    assert request(video_url)["media"] == {"kind":"video","mime":"video/mp4","label":"MP4 video"}
                    assert request(video_url + "/download") == mp4
                    request(video_url + "/download", status=401, authorized=False)
                    audio_url = f"/api/library/files/{inputs['Audio notes.wav']}"
                    assert request(audio_url)["media"]["mime"] == "audio/wav"
                    assert request(audio_url + "/download") == wav
                    mislabeled_url = f"/api/library/files/{inputs['Mislabeled.mp4']}"
                    assert request(mislabeled_url)["media"] is None
                    assert request(mislabeled_url + "/download") == mislabeled
                    with sqlite3.connect(journal) as db:
                        message = db.execute("INSERT INTO group_messages (group_id,text,at_ms) VALUES (?,?,?)",
                                             (group["id"],"Read the report",int(time.time()*1000))).lastrowid
                        file_id = db.execute("INSERT INTO group_attachments (message_id,name,data) VALUES (?,?,?)",
                                             (message,"Group table.csv",table)).lastrowid
                        video_id = db.execute("INSERT INTO group_attachments (message_id,name,data) VALUES (?,?,?)",
                                              (message,"Group recording.webm",webm)).lastrowid
                    group_file = f"/api/groups/{group['id']}/files/{file_id}"
                    group_video = f"/api/groups/{group['id']}/files/{video_id}"
                    assert request(group_file + "/info")["table"] == csv
                    request(group_file + "/image", status=404)
                    request(f"/api/groups/{group['id']+1}/files/{file_id}/info",status=404)
                    assert request(group_video + "/info")["media"]["mime"] == "video/webm"
                    request(group_video, status=401, authorized=False)
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser, check=True, timeout=80)
                    cli("server","stop")
                    core_running = False
                    port = base.rsplit(":",1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request(group_file) == table and request(image_url + "/image") == image
                    assert request(group_video) == webm and request(video_url + "/download") == mp4
                    if chrome:
                        subprocess.run(browser, env={**os.environ,"SWARMHUB_TEST_FOCUS":"media-offline"},check=True,timeout=65)
                    return
                if focus == "search":
                    path = "/api/search?"
                    def lookup(text, kind=None, **options):
                        params = {"q":text}
                        if kind:
                            params["kind"] = kind
                        return request(path + urllib.parse.urlencode(params), **options)
                    lookup("search", status=401, authorized=False)
                    lookup("invalid", kind="unknown", status=422)
                    lookup("x" * 121, status=422)
                    assert lookup(" ") == []
                    creator = request("/api/agents", {"name": "search-agent", "template": "claude-fixture",
                                                    "task": "Older archive marker"}, status=201)
                    peer = request("/api/agents", {"name": "search-peer", "template": "claude-fixture",
                                                 "task": "browser follow-up"}, status=201)
                    members = [{field:a[field] for field in ("address","created_ms")} for a in (creator,peer)]
                    group = request("/api/groups", {"name":"Search group", "members":members}, status=201)
                    made = request("/api/pages", {"title":"Search comparison", "markdown": "## Summary\n\n" + "start " * 70 + "Rare comparison marker"}, status=201)
                    skill = request("/api/skills", {"name":"Search checklist", "summary":"Review instructions",
                                                   "instructions":"The cobalt review marker"}, status=201)
                    routine = request("/api/routines", {"name":"Search check-in", "task":"The calendar comparison marker",
                                                       "schedule":{"kind":"interval","minutes":60}, "target":members[0]}, status=201)
                    request(f"/api/routines/{routine['id']}/state", "pause")
                    bundle = {"format":"agentapp-bot-bundle/v1", "source_id":"search-imported-draft-a",
                              "name":"Saved planning", "routines":[{"id":"r-search", "name":"Imported follow-up",
                                                                      "prompt":"Pacific planning marker"}]}
                    request("/api/grok-imports", json.dumps(bundle).encode())
                    agent_key = f"{creator['address']}/{creator['created_ms']}"
                    request(f"/api/agents/{agent_key}/snapshots", {"title":"Search terminal snapshot"}, status=201)
                    until(lambda: lookup("Agent result.txt", "files"))
                    with sqlite3.connect(str(root / "workspace/workspace.sqlite3")) as db:
                        args = (core, creator["address"], creator["created_ms"], creator["name"], int(time.time()*1000))
                        older_task = db.execute("SELECT id FROM journal WHERE address=? AND kind='task' AND text=?",
                                                (creator["address"], "Older archive marker")).fetchone()[0]
                        db.execute("INSERT INTO direct_task_files (task_id,name,data) VALUES (?,?,?)",
                                   (older_task, "Direct search notes.txt", b"Direct search copy"))
                        db.executemany("INSERT INTO journal (core_id,address,created_ms,agent,at_ms,kind,state,text) "
                                       "VALUES (?,?,?,?,?,'task','sent',?)",
                                       [(*args, f"Later message {index}") for index in range(40)])
                        older_group_message = db.execute("INSERT INTO group_messages (group_id,text,at_ms) VALUES (?,?,?)",
                                                        (group["id"], "Quartz group marker", args[-1])).lastrowid
                        db.executemany("INSERT INTO group_messages (group_id,text,at_ms) VALUES (?,?,?)",
                                       [(group["id"], f"Later group {index}", args[-1]) for index in range(40)])
                        message = db.execute("INSERT INTO group_messages (group_id,text,at_ms) VALUES (?,?,?)",
                                             (group["id"],"Saved input",args[-1])).lastrowid
                        db.execute("INSERT INTO group_attachments (message_id,name,data) VALUES (?,?,?)",
                                   (message,"Group search file.txt",b"Saved group search file"))
                    assert {item["kind"] for item in lookup("search")} >= {"agent","group","page","snapshot","group-file"}
                    assert lookup("rare comparison", "pages")[0]["id"] == made["id"]
                    assert "Rare comparison marker" in lookup("rare comparison", "pages")[0]["excerpt"]
                    hits = lookup("older archive", "messages")
                    assert hits and all(hit["address"] == creator["address"] for hit in hits)
                    expected = [
                        ("Quartz group marker", "messages", {"kind":"group-message", "id":older_group_message, "group_id":group["id"]}),
                        ("cobalt review marker", "skills", {"kind":"skill", "id":skill["id"]}),
                        ("calendar comparison marker", "routines", {"kind":"routine", "id":routine["id"]}),
                        ("Pacific planning marker", "routines", {"kind":"routine-draft"}),
                        ("Direct search notes", "files", {"kind":"task-file", "task_id":older_task}),
                    ]
                    def saved_matches():
                        results = [lookup(term, category) for term, category, _ in expected]
                        for found, (_, _, fields) in zip(results, expected):
                            assert len(found) == 1 and all(found[0][key] == val for key, val in fields.items()), found
                        return results
                    saved = saved_matches()
                    assert lookup("%_") == [] and lookup("' OR 1=1 --") == []
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser, check=True, timeout=85)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert lookup("rare comparison", "pages")[0]["id"] == made["id"]
                    assert lookup("older archive", "messages") == hits
                    assert saved_matches() == saved
                    if chrome:
                        subprocess.run(browser, env={**os.environ, "SWARMHUB_TEST_FOCUS":"search-offline"},
                                       check=True, timeout=65)
                    return
                if focus == "chat-links":
                    for name in ("chat-link-live", "chat-link-idle"):
                        agent = request("/api/agents", {"name":name,"template":"fixture","task":"Start link fixture"}, status=201)
                        if name.endswith("idle"):
                            request(f"/api/agents/{agent['address']}/{agent['created_ms']}/end", {})
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=85)
                    assert all(len(profile["sessions"]) == 1 for profile in request("/api/profiles"))
                    return
                if focus == "agent-library":
                    source = {"name":"library-agent", "template":"claude-fixture", "task":"make a comparison page"}
                    original = request("/api/agents", source, status=201)
                    first_session = f"{original['address']}/{original['created_ms']}"
                    profile = original["profile_id"]
                    catalog = f"/api/library/agent?profile={profile}"
                    request(catalog, status=401, authorized=False)
                    request("/api/library/agent?profile=0", status=422)
                    request(catalog + "&core=other", status=422)
                    until(lambda: any(row["kind"] == "page" for row in request(catalog)))
                    request(f"/api/agents/{first_session}/snapshots", {"title":"First session snapshot"}, status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        launch = db.execute("SELECT launch_key FROM journal WHERE profile_id=? AND address=? AND launch_key IS NOT NULL",
                                            (profile,original["address"])).fetchone()[0]
                    report = root / "First session report.txt"
                    report.write_text("Saved bytes from the first session.")
                    subprocess.run([bridge,"publish-file",str(report)], capture_output=True, check=True, timeout=10,
                                   env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch})
                    request(f"/api/agents/{first_session}/end", {})
                    replacement = request("/api/agents", {**source,"profile_id":profile,"task":"Start replacement session"}, status=201)
                    latest = f"{replacement['address']}/{replacement['created_ms']}"
                    wait_output = lambda session: until(lambda: request(f"/api/agents/{session}/output")["text"].strip())
                    wait_output(latest)
                    request(f"/api/agents/{latest}/snapshots", {"title":"Replacement session snapshot"}, status=201)
                    peer = request("/api/agents", {"name":"other-library-agent","template":"fixture","task":"Separate history"},status=201)
                    peer_session = f"{peer['address']}/{peer['created_ms']}"
                    wait_output(peer_session)
                    request(f"/api/agents/{peer_session}/snapshots", {"title":"Different agent snapshot"}, status=201)
                    request("/api/pages", {"title":"Standalone Page","markdown":"Workspace only"}, status=201)
                    saved = request(catalog)
                    assert [(row["kind"], row["title"]) for row in saved[:2]] == [
                        ("snapshot", "Replacement session snapshot"),("file", "First session report.txt")]
                    assert {row["title"] for row in request(catalog + "&kind=snapshot")} == {"Replacement session snapshot","First session snapshot"}
                    assert [row["title"] for row in request(catalog + "&kind=page")] == ["Agent comparison"]
                    scoped = "/api/library/agent?" + urllib.parse.urlencode({"core":core,"address":original["address"],"created_ms":original["created_ms"]})
                    assert {row["title"] for row in request(scoped)} == {"First session report.txt","First session snapshot","Agent comparison"}
                    oldest = next(row for row in saved if row["title"] == "First session snapshot")
                    pin = f"/api/library/pins/snapshot/{oldest['id']}"
                    request(pin, {"pinned":True}, status=401, authorized=False)
                    request(pin, {"pinned":True}, status=403, origin="https://outside.test")
                    request(f"/api/library/pins/file/{oldest['id']}", {"pinned":True}, status=404)
                    request(pin, {"pinned":True})
                    assert request(pin, {"pinned":True}) == {"pinned":True}
                    assert request(catalog)[0] == {**oldest,"pinned":True}
                    assert request("/api/library")[0]["id"] == oldest["id"]
                    request(pin, {"pinned":False})
                    cli("server", "stop")
                    core_running = False
                    assert request(catalog) == saved
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=85)
                    file_id = next(row["id"] for row in saved if row["kind"] == "file")
                    request(f"/api/library/pins/file/{file_id}", {"pinned":True})
                    stop(process)
                    process = None
                    process, base = start_bridge()
                    assert request(catalog)[0]["title"] == "First session report.txt"
                    assert request("/api/library/files")[0]["pinned"]
                    return
                if focus == "page-share":
                    cli("server", "stop")
                    core_running = False
                    first = request("/api/pages", {"title":"Share sample", "markdown":"First saved draft"}, status=201)
                    request("/api/pages", {"title":"Private sample", "markdown":"Never in the viewer"}, status=201)
                    route = f"/api/pages/{first['id']}"
                    share = route + "/share"
                    change = {"action":"create", "revision":1, "follow_latest":False}
                    shell = request("/view/page", authorized=False)
                    assert b'Shared Page' in shell and b'First saved draft' not in shell
                    request(share, change, authorized=False, status=401)
                    request(share, change, origin="http://outside.invalid", status=403)
                    request(share, {**change, "revision":99}, status=409)
                    def viewer(secret=None, suffix="", status=200, target="/view/page/content"):
                        headers = {"Authorization": f"PageLink {secret}"} if secret else {}
                        req = urllib.request.Request(base + target + suffix, headers=headers)
                        try:
                            response = urllib.request.urlopen(req, timeout=5)
                        except urllib.error.HTTPError as error:
                            response = error
                        with response:
                            assert response.status == status, (target, response.status)
                            assert response.headers["Cache-Control"] == "no-store" or status == 401
                            return json.load(response) if response.headers.get_content_type() == "application/json" else response.read()
                    viewer(status=404)
                    viewer(token, status=404)
                    fixed = request(share, change, status=201)
                    assert len(fixed["token"]) == 43 and request(share) == {"link":fixed["link"]}
                    viewer(fixed["token"], target=route, status=401)
                    viewer(fixed["token"], target="/api/library", status=401)
                    request(share, change, status=409)
                    request(route, {"title":"Next draft", "markdown":"Not in the fixed link", "revision":1})
                    result = viewer(fixed["token"])
                    assert set(result) == {"title", "revision", "html"} and result["revision"] == 1
                    assert "First saved draft" in result["html"] and "Never in the viewer" not in result["html"]
                    viewer(fixed["token"], "?after=1", status=204)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        saved = db.execute("SELECT token_digest FROM page_shares").fetchone()[0]
                        assert len(saved) == 32 and fixed["token"].encode() not in journal.read_bytes()
                    assert request(share, {"action":"revoke", "id":fixed["link"]["id"]}) == {"link":None}
                    viewer(fixed["token"], "?after=1", status=404)
                    live_share = request(share, {**change,"revision":2,"follow_latest":True}, status=201)
                    request(share, {"action":"revoke", "id":fixed["link"]["id"]}, status=409)
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert viewer(live_share["token"])["revision"] == 2
                    request(route, {"title":"Updated sample", "markdown":"An update at the same link", "revision":2})
                    assert "An update at the same link" in viewer(live_share["token"], "?after=2")["html"]
                    with sqlite3.connect(journal) as db:
                        db.execute("UPDATE page_shares SET expires_ms=0 WHERE page=?", [first["id"]])
                    assert request(share) == {"link":None}
                    viewer(live_share["token"], status=404)
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    def expired_removed():
                        with sqlite3.connect(journal) as db:
                            return db.execute("SELECT COUNT(*) FROM page_shares WHERE page=?", [first["id"]]).fetchone()[0] == 0
                    until(expired_removed)
                    retained = request(share, {**change,"revision":3}, status=201)
                    with sqlite3.connect(journal) as db:
                        for revision in range(4, 55):
                            db.execute("UPDATE workspace_pages SET markdown=?,revision=? WHERE id=?",
                                       (f"Later content {revision}", revision, first["id"]))
                    request(route+"/revisions/3", status=404)
                    assert "An update at the same link" in viewer(retained["token"])["html"]
                    if chrome:
                        markdown = ("A source review for the team.\n\n- [x] Reviewed\n\n| Team | Count |\n| --- | --- |\n| North | 12 |\n| South | 4 |\n\n"
                                    "[Reference](https://example.invalid/) ![Remote pixel](https://outside.invalid/pixel)\n\n"
                                    "<script>window.shareExecuted = true</script>\n\n"
                                    '```chart\n{"type":"line","title":"Weekly totals","points":[{"label":"A","value":1},{"label":"B","value":4}]}\n```')
                        browser_page = request("/api/pages", {"title":"Field report", "markdown":markdown}, status=201)
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=90, env={**os.environ,"SWARMHUB_TEST_PAGE":str(browser_page["id"])})
                        browser_route = f"/api/pages/{browser_page['id']}"
                        assert request(browser_route+"/share") == {"link":None}
                        assert request(browser_route)["revision"] == 2
                    return
                if focus == "page-html-export":
                    markdown = (
                        "## Archived release notes\n\n- [x] Tested\n- [ ] Awaiting review\n\n"
                        "| Topic | Count |\n| --- | --- |\n| Café | 2 |\n\n"
                        '![Remote file](https://outside.invalid/example.png)\n\n'
                        '[Reference](https://example.invalid/docs) [unsafe](javascript:alert%281%29)\n\n'
                        '<img src="https://outside.invalid/pixel" onerror="window.exportExecuted=true">\n'
                        '<script>window.exportExecuted=true</script>\n\n'
                        '~~Removed as requested~~\n\n'
                        '```chart\n{"type":"line","title":"Release <data>","unit":"%","points":['
                        '{"label":"Earlier","value":0.12345678901234567890},{"label":"Later <value>","value":3.50}]}\n```\n\n'
                        '```chart\n{"type":"bar","title":"Unknown unit","unit":null,"points":[{"label":"a","value":2}]}\n```\n'
                    )
                    title = "Quarterly <notes>"
                    original = request("/api/pages",{"title":title,"markdown":markdown},status=201)
                    route = f"/api/pages/{original['id']}"
                    new = request(route,{"title":"Current report","markdown":"NEWER REPORT MUST NOT EXPORT","revision":1})
                    assert new["revision"] == 2
                    html_path = route + "/download/html?revision=1"
                    request(html_path,authorized=False,status=401)
                    request(route+"/download/html",status=400)
                    request(route+"/download/html?revision=99",status=409)
                    cli("server","stop")
                    core_running = False
                    with urllib.request.urlopen(urllib.request.Request(base+html_path,
                                                headers={"Authorization":f"Bearer {token}"}),timeout=20) as response:
                        assert response.headers.get_content_type() == "text/html"
                        assert response.headers["Content-Disposition"] == "attachment; filename*=UTF-8''Quarterly%20%3Cnotes%3E.html"
                        html = response.read().decode()
                    assert "Revision 1" in html and "NEWER REPORT MUST NOT EXPORT" not in html
                    assert "0.12345678901234567890" in html and "Café" in html
                    assert "https://example.invalid/docs" in html and token not in html
                    assert not any(tag in html for tag in ("<script", "<img", "<link", "<a ", "<iframe"))
                    assert request(route+"/download?revision=1").decode() == markdown
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=75)
                    return
                if focus == "page-checklist":
                    tracker = ("# Launch tracker\n\n| Task | State | Estimate |\n| --- | --- | --- |\n"
                               "| Queue migration | Open | 10 |\n| Café follow-up | Done | -2.5 |\n"
                               "| Prepare open agenda | Done | 2 |\n\n| Note | Owner |\n| --- | --- |\n"
                               "| Draft | Alex |\n| Review | Sam |\n")
                    bar = {"type":"bar","title":"Weekly <em>changes</em>","unit":"tasks","points":[
                        {"label":"Removed","value":-2},{"label":"Added","value":3}]}
                    line = {"type":"line","title":"Pipeline trend","points":[
                        {"label":"Monday","value":-2.5},{"label":"Tuesday","value":0},{"label":"Wednesday","value":3}]}
                    tracker += "\n" + "\n\n".join("```chart\n" + json.dumps(chart) + "\n```" for chart in (bar,line))
                    tracker += '\n\n```chart\n{"type":"line","points":<script>literal text</script>}\n```\n'
                    tracker_page = request("/api/pages", {"title":"Launch tracker","markdown":tracker},status=201)
                    text = "# Release café\n\n- [ ] Prepare café notes\n  - [x] Review backups\n\n```md\n- [ ] Sample in code\n```\n\n<input type=\"checkbox\" checked>\n"
                    page = request("/api/pages",{"title":"Launch checklist","markdown":text},status=201)
                    route = f"/api/pages/{page['id']}"
                    check_url = route + "/checklist"
                    change = {"revision":page["revision"],"index":1,"checked":False}
                    request(check_url,change,authorized=False,status=401)
                    request(check_url,change,origin="https://outside.test",status=403)
                    request(check_url,{**change,"index":2},status=422)
                    changed = request(check_url,change)
                    expected = text.replace("[x] Review backups","[ ] Review backups")
                    assert changed["markdown"] == expected and changed["revision"] == 2
                    assert request(check_url,{**change,"revision":2})["revision"] == 2
                    request(check_url,{**change,"checked":True},status=409)
                    cli("server","stop")
                    core_running = False
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],
                                       check=True,timeout=85)
                        page_after = request(f"/api/pages/{tracker_page['id']}")
                        assert page_after["revision"] == 1 and page_after["markdown"] == tracker
                        saved = request(route)
                        assert saved["revision"] == 6 and saved["markdown"] == expected
                        version5 = request(route+"/revisions/5")
                        assert version5["current_revision"] == 6 and version5["markdown"] == "- [x] Added elsewhere\n\n" + expected.replace(
                            "[ ] Prepare café notes","[x] Prepare café notes")
                        assert request(f"{route}/download?revision=5") == version5["markdown"].encode()
                        assert [row["revision"] for row in request(route+"/revisions")["items"]] == [6,5,4,3,2,1]
                        request(route+"/revisions/2/restore",{"current_revision":5},status=409)
                        request(route+"/revisions/2/restore",{"current_revision":6},authorized=False,status=401)
                    bounded = request("/api/pages",{"title":"History bound","markdown":"# Initial"},status=201)
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        for revision in range(2,54):
                            db.execute("UPDATE workspace_pages SET markdown=?,revision=? WHERE id=?",
                                       (f"# Revision {revision}",revision,bounded["id"]))
                    bounded_route = f"/api/pages/{bounded['id']}/revisions"
                    assert [row["revision"] for row in request(bounded_route)["items"]] == list(range(53,3,-1))
                    request(bounded_route+"/3",status=404)
                    stop(process)
                    process = None
                    with sqlite3.connect(journal) as db:
                        db.executescript("DROP TRIGGER workspace_page_created; DROP TRIGGER workspace_page_revised; "
                                         "DROP TABLE page_shares; DROP TABLE grok_skill_drafts; "
                                         "DROP TABLE workspace_page_versions; DROP TABLE library_pins; DROP TABLE direct_task_files; "
                                         "DROP TABLE approval_rule_audit; DROP TABLE group_handoff_dispatches; DROP TABLE group_handoffs; "
                                         "DROP TABLE email_drafts; DROP TABLE memory_proposals; DROP TABLE routine_proposals; "
                                         "DROP TABLE skill_proposals; PRAGMA user_version=35;")
                    process, base = start_bridge()
                    migrated = request(bounded_route)
                    assert [row["revision"] for row in migrated["items"]] == [53]
                    return
                if focus in ("pages", "page-tasks"):
                    request("/api/pages", status=401, authorized=False)
                    agent = request("/api/agents", {"name": "page-agent", "template": "claude-fixture",
                                                    "task": "make a comparison page"}, status=201)
                    other = request("/api/agents", {"name": "another-agent", "template": "fixture",
                                                    "task": "Check page ownership"}, status=201)
                    session = f"{agent['address']}/{agent['created_ms']}"
                    endpoint = f"/api/history/{core}/{session}"
                    card = until(lambda: next((row for row in request(endpoint)["items"] if row["kind"] == "page"), None))
                    page_id = card["page_id"]
                    route = f"/api/pages/{page_id}"
                    first = request(route)
                    assert first["title"] == "Agent comparison" and first["revision"] == 1 and "<table>" in first["html"]
                    assert request("/api/library/files") == [] and request("/api/pages")[0]["id"] == page_id
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        keys = [db.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND launch_key IS NOT NULL",
                                           (core, row["address"])).fetchone()[0] for row in (agent, other)]

                    def page_command(*args, text=b"", owner=keys[0]):
                        return subprocess.run([bridge, *args], input=text, capture_output=True, timeout=10,
                                              env={"SWARMHUB_JOURNAL": str(journal), "SWARMHUB_LAUNCH_KEY": owner})
                    assert page_command("read-page", str(page_id)).stdout == first["markdown"].encode()
                    assert page_command("read-page", str(page_id), owner=keys[1]).returncode != 0
                    assert page_command("update-page", str(page_id), "1", owner=keys[1], text=b"Other agent").returncode != 0
                    changed = request(route, {"title": "Revised comparison", "markdown": "# Updated report", "revision": 1})
                    assert changed["revision"] == 2
                    request(route, {"title": "Stale", "markdown": "Stale draft", "revision": 1}, status=409)
                    assert page_command("update-page", str(page_id), "1", text=b"Stale").returncode != 0
                    assert page_command("update-page", str(page_id), "2", text=b"# Latest agent report").returncode == 0
                    assert request(route)["revision"] == 3
                    assert request(route + "/download?revision=3") == b"# Latest agent report"
                    assert request(route + "/download?revision=2") == b"# Updated report"
                    card = next(row for row in request(endpoint)["items"] if row["kind"] == "page")
                    assert card["detail"] == "Revised comparison" and card["page_id"] == page_id
                    request("/api/pages", {"title": "", "markdown": "not valid"}, status=422)
                    request("/api/pages", {"title": "Too large", "markdown": "x" * (96 * 1024 + 1)}, status=422)
                    if focus == "page-tasks":
                        task_route = route + "/tasks"
                        request(task_route, status=401, authorized=False)
                        request(task_route, {"revision": 2, "text": "Reject stale revision"}, status=409)
                        assert request(task_route)["items"] == []
                        assert page_command("read-page", str(page_id), "2").returncode != 0
                        note = "Clarify the deadline.\nInclude the review date."
                        request(task_route, {"revision": 3, "text": note})
                        until(lambda: request(route)["revision"] == 4)
                        assert request(route)["markdown"].endswith("Amended: " + note)
                        thread = request(task_route)
                        assert thread["owner"] == {"core": core, "address": agent["address"],
                                                   "created_ms": agent["created_ms"], "name": agent["name"]}
                        assert len(thread["items"]) == 1 and thread["items"][0]["state"] == "sent"
                        linked = next(row for row in request(endpoint)["items"] if row.get("page_revision"))
                        assert linked["kind"] == "task" and linked["text"] == note and linked["page_revision"] == 3
                        assert linked["page_id"] == page_id and linked["page_title"] == "Revised comparison"
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=75)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    if focus == "page-tasks":
                        assert request(route)["markdown"].startswith("# Latest agent report")
                        assert request(route + "/tasks")["items"][0]["text"] == note
                    else:
                        assert request(route)["markdown"] == "# Latest agent report"
                    assert request("/api/pages")[0]["revision"] >= 2
                    return
                if focus == "github-access":
                    owner, peer = [request("/api/agents", {"name":name,"template":"fixture","task":"Start GitHub access fixture"}, status=201)
                                   for name in ("github-access-owner", "github-access-peer")]
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as db:
                        keys = [db.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND created_ms=?",
                                           (core, row["address"], row["created_ms"])).fetchone()[0] for row in (owner, peer)]
                    session = f"/api/agents/{owner['address']}/{owner['created_ms']}"
                    route = session + "/github-access"
                    peer_route = f"/api/agents/{peer['address']}/{peer['created_ms']}/github-access"
                    query = "?" + urllib.parse.urlencode({"core":core})
                    grant = {"core":core,"allowed":True}
                    revoke = {"core":core,"allowed":False}

                    def command(*args, key=keys[0], pending=False):
                        env = {"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":key}
                        spec = [bridge,"github-read",*args]
                        if pending:
                            return subprocess.Popen(spec, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        return subprocess.run(spec, capture_output=True, timeout=8, env=env)

                    request(route+query, status=401, authorized=False)
                    request(route, grant, status=403, origin="https://outside.invalid")
                    request(route, {**grant,"core":"different-core"}, status=409)
                    request(f"/api/agents/{owner['address']}/{owner['created_ms']+1}/github-access", grant, status=409)
                    assert request(route+query)["minutes_remaining"] is None
                    assert command("issue","5").returncode != 0 and github[1] == []
                    assert request(route, grant)["minutes_remaining"] == 60
                    assert command("issue","5",key=keys[1]).returncode != 0
                    assert command("issue","https://outside.invalid").returncode != 0
                    assert command("pr","4294967296").returncode != 0
                    assert command("issue","5","extra").returncode != 0
                    raw = json.dumps({"launch":keys[0],"kind":"issue","number":5,"repository":"outside/repo"}).encode()
                    with socket_module.socket(socket_module.AF_UNIX) as connection:
                        connection.settimeout(3)
                        connection.connect(str(journal.with_name("github-agent.sock")))
                        connection.sendall(len(raw).to_bytes(4,"little") + raw)
                        assert connection.recv(1) == b""
                    assert github[1] == []

                    issue = command("issue","5")
                    assert issue.returncode == 0 and b"Offline-ready test notes." in issue.stdout
                    pull = command("pr","12")
                    assert pull.returncode == 0 and github[2].encode() in pull.stdout
                    reflected = command("issue","99")
                    assert reflected.returncode == 0 and b"[credential removed]" in reflected.stdout
                    assert b"swarmhub-fixture-only" not in reflected.stdout
                    assert command("issue","88").returncode != 0
                    started, release = github_hold
                    with command("issue","98",pending=True) as delayed:
                        try:
                            assert started.wait(6), "GitHub fixture did not receive the delayed read"
                            assert request(route,revoke)["minutes_remaining"] is None
                            stdout, _ = delayed.communicate(timeout=4)
                            assert delayed.returncode != 0 and stdout == b""
                        finally:
                            release.set()
                            if delayed.poll() is None:
                                delayed.kill()
                    recent = until(lambda: (rows if (rows := request(route+query)["recent"]) and rows[0]["number"] == 98 else None))
                    assert [(row["number"],row["succeeded"]) for row in recent] == [(98,False),(88,False),(99,True),(12,True),(5,True)]
                    assert all(set(row) == {"kind","number","at_ms","succeeded"} for row in recent)
                    assert request(peer_route+query)["recent"] == []
                    assert all(method == "GET" and path.startswith("/repos/fixture/release-board/") for method,path,_ in github[1])
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=65)

                    request(route,grant)
                    request(session+"/end",{})
                    count = len(github[1])
                    assert command("issue","5").returncode != 0 and len(github[1]) == count
                    print("GitHub exact-session broker, audit, typed reads, revocation, and ended-session checks passed.")
                    return
                if focus == "github-project":
                    route = "/api/github-project"
                    request(route+"/status",status=401,authorized=False)
                    assert request(route+"/status") == {"repository":"fixture/release-board"}
                    listing = request(route+"/items")
                    assert [(item["kind"],item["number"]) for item in listing["entries"]] == [("issue",5),("pull_request",12)]
                    assert listing["next_page"] == 2 and request(route+"/items?page=2")["next_page"] is None
                    request(route+"/items?repository=outside%2Fother",status=400)
                    request(route+"/items?page=999",status=422)
                    request(route+"/items",{},status=405)
                    request(route+"/item?kind=issue&number=88",status=502)
                    item = request(route+"/item?kind=pull_request&number=12")
                    assert item["excerpt"] == github[2] and item["source"] == "https://github.com/fixture/release-board/pull/12"
                    assert "swarmhub-fixture-only" not in json.dumps([listing,item])
                    agents = [request("/api/agents",{"name":name,"template":"fixture","task":"Start GitHub test"},status=201)
                              for name in ("github-browser","github-partner")]
                    group = request("/api/groups",{"name":"GitHub review group","members":[
                        {key:agent[key] for key in ("address","created_ms")} for agent in agents]},status=201)
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=80)
                        agent = agents[0]
                        history = f"/api/history/{core}/{agent['address']}/{agent['created_ms']}"
                        sent = next(row for row in request(history)["items"] if row["text"] == "Review the attached GitHub excerpt.")
                        assert len(sent["files"]) == 1 and sent["files"][0]["name"] == item["file_name"]
                        attached = request(history+f"/files/{sent['id']}/{sent['files'][0]['id']}").decode()
                        assert attached == item["attachment"]
                        assert request(f"/api/groups/{group['id']}/messages")["items"] == []
                    cli("server","stop")
                    core_running = False
                    assert request(route+"/item?kind=issue&number=5")["excerpt"].startswith("Offline-ready")
                    assert github[1] and all(method == "GET" and path.startswith("/repos/fixture/release-board/")
                                             for method,path,_ in github[1])
                    return
                if focus == "group-handoffs":
                    source, target, observer = [
                        request("/api/agents",{"name":name,"template":"fixture","task":"Start handoff fixture"},status=201)
                        for name in ("handoff-reader","handoff-editor","handoff-observer")
                    ]
                    members = [{key:agent[key] for key in ("address","created_ms")} for agent in (source,target,observer)]
                    group = request("/api/groups",{"name":"Handoff team","members":members},status=201)
                    another = request("/api/groups",{"name":"Different group","members":members[:2]},status=201)
                    route = f"/api/groups/{group['id']}"
                    feed = route + "/messages"
                    journal = root / "workspace/workspace.sqlite3"

                    def delivery(message):
                        with sqlite3.connect(journal) as db:
                            return db.execute("SELECT token,launch_key FROM group_deliveries WHERE message_id=?", (message,)).fetchone()

                    def send(text):
                        record = request(feed,{"text":text,"revision":group["revision"],"recipients":members[:1]},status=202)["id"]
                        until(lambda: any(row["id"] == record and row["deliveries"][0]["state"] == "sent" for row in request(feed)["items"]))
                        return record

                    def propose(binding, to="handoff-editor", task="Review the release draft.", command="group-handoff"):
                        key, launch = binding
                        body = json.dumps({"to":to,"task":task}) if command == "group-handoff" else task
                        return subprocess.run([bridge,command,key],input=body,text=True,capture_output=True,
                                              timeout=10,env={"SWARMHUB_JOURNAL":str(journal),"SWARMHUB_LAUNCH_KEY":launch}).returncode

                    def output(agent):
                        return request(f"/api/agents/{agent['address']}/{agent['created_ms']}/output")["text"]

                    first = send("Gather the release requirements.")
                    bind = delivery(first)
                    until(lambda: "group-handoff " + bind[0] in output(source))
                    assert "handoff-editor" in output(source)
                    assert propose(("f"*32,bind[1])) != 0 and propose((bind[0],"f"*32)) != 0
                    assert propose(bind,to="handoff-reader") != 0 and propose(bind,to="not-a-member") != 0
                    assert propose(bind,task="Do not leak: " + bind[0].upper()) != 0
                    assert propose(bind) == propose(bind) == 0
                    assert propose(bind,command="group-reply") != 0
                    second = send("Collect possible release dates.")
                    assert propose(delivery(second),task="This suggestion should be dismissed.") == 0
                    rows = request(feed)["items"]
                    assert len(rows) == 4 and sum(row.get("handoff")=="pending" for row in rows) == 2
                    pending, dismissable = [route+f"/handoffs/{row['id']}" for row in rows if row.get("handoff") == "pending"]
                    review = request(pending)
                    assert review["source"] == first and review["target"] == members[1] and review["eligible"]
                    assert review["excerpt"] == "Gather the release requirements."
                    assert all(private not in json.dumps([review,rows]) for private in bind)
                    request(pending,status=401,authorized=False)
                    request(pending.replace(route,f"/api/groups/{another['id']}"),status=404)
                    edited = "Review the release draft and flag the date."
                    approval = {"revision":group["revision"],"task":edited}
                    request(pending+"/approve",approval,status=403,origin="https://outside.test")
                    request(pending+"/approve",{**approval,"task":bind[0]},status=422)
                    assert len(request(feed)["items"]) == 4 and "Review the release draft" not in output(target)
                    if chrome:
                        subprocess.run(["node",str(Path(__file__).with_name("browser.mjs")),chrome,base,token,temp],check=True,timeout=75)
                    else:
                        request(pending+"/approve",approval,status=202)
                        request(dismissable+"/dismiss",{})
                    approved = request(pending)["approved"]
                    assert request(pending+"/approve",approval,status=202)["id"] == approved
                    request(pending+"/dismiss",{},status=409)
                    request(dismissable+"/approve",approval,status=409)
                    until(lambda: any(row["id"] == approved and row["deliveries"][0]["state"] == "sent" for row in request(feed)["items"]))
                    final_rows = request(feed)["items"]
                    assert len(final_rows) == 5
                    outbound = next(row for row in final_rows if row["id"] == approved)
                    assert outbound["text"] == edited and len(outbound["deliveries"]) == 1 and outbound["deliveries"][0]["address"] == target["address"]
                    until(lambda: edited in output(target))
                    assert edited not in output(observer) and "group-handoff " not in output(target)
                    child = delivery(approved)
                    assert propose(child,to="handoff-observer") != 0
                    assert propose(child,task="Completed the follow-up.",command="group-reply") == 0
                    pending_member = send("Review again after a roster change.")
                    assert propose(delivery(pending_member),task="Unapproved before roster edit.") == 0
                    waiting = next(row for row in request(feed)["items"] if row.get("handoff") == "pending")
                    path = route+f"/handoffs/{waiting['id']}"
                    changed = request(route,{"name":"Handoff team","revision":group["revision"],"members":[members[0],members[2]]})
                    assert not request(path)["eligible"]
                    request(path+"/approve",{"revision":changed["revision"],"task":"Do not send to a removed member."},status=409)
                    request(path+"/dismiss",{})
                    return
                if focus == "group-forms":
                    agents = [request("/api/agents", {"name": name, "template": "claude-fixture",
                                                     "task": "Start form fixture"}, status=201)
                              for name in ("claude-capture", "substitute")]
                    targets = [{key: agent[key] for key in ("address", "created_ms")} for agent in agents]
                    group = request("/api/groups", {"name": "Preferences", "members": targets}, status=201)
                    feed = f"/api/groups/{group['id']}/messages"
                    request(feed, {"text": "Ask for a group form", "recipients": targets[:1],
                                   "revision": group["revision"]}, status=202)
                    form = until(lambda: next((row for row in request(feed)["items"] if row["form"]), None))
                    assert form["is_question"] and form["form"]["title"] == "Review preferences"
                    assert form["form"]["fields"][0]["choices"] == ["Summary", "Timeline"]
                    base_answer = {"text": "", "recipients": targets[:1], "revision": group["revision"], "reply_to": form["id"]}
                    for values in ({}, {"section": "Other"}, {"section": "Summary", "new_key": "x"},
                                   {"section": "Summary", "notes": "a" * 301}):
                        request(feed, {**base_answer, "form_values": values}, status=422)
                    answer = {**base_answer, "form_values": {"section": "Summary", "notes": ""}}
                    request(feed, {**base_answer, "text": "Use Summary"}, status=422)
                    request(feed, {**answer, "recipients": targets}, status=422)
                    assert next(row for row in request(feed)["items"] if row["id"] == form["id"])["answer_state"] is None
                    result = request(feed, answer, status=202)
                    request(feed, answer, status=409)
                    expected = 'Form response: {"section":"Summary"}'
                    until(lambda: any(row["author"] == "claude-capture"
                                      and row["text"] == "Group answer to " + expected for row in request(feed)["items"]))
                    sent = next(row for row in request(feed)["items"] if row["id"] == result["id"])
                    assert sent["text"] == expected and sent["reply_to"]["is_form"]
                    assert [delivery["name"] for delivery in sent["deliveries"]] == ["claude-capture"]
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=85)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    saved = next(row for row in request(feed)["items"] if row["id"] == form["id"])
                    assert saved["answer_state"] == "sent" and saved["form"] == form["form"]
                    return
                if focus == "group-questions":
                    agents = [request("/api/agents", {"name": name, "template": "claude-fixture",
                                                     "task": "Start question fixture"}, status=201)
                              for name in ("claude-capture", "substitute")]
                    targets = [{k: agent[k] for k in ("address", "created_ms")} for agent in agents]
                    group = request("/api/groups", {"name": "Clarifications", "members": targets}, status=201)
                    another = request("/api/groups", {"name": "Other conversation", "members": targets}, status=201)
                    feed = f"/api/groups/{group['id']}/messages"
                    request(feed, {"text": "Ask a group question", "recipients": targets[:1], "revision": group["revision"]},
                            status=202)
                    question = until(lambda: next((row for row in request(feed)["items"] if row["is_question"]), None))
                    assert question["text"] == "Which report section should I use?" and question["target"] == targets[0]
                    pending = request("/api/attention")["requests"]
                    assert [(item["group"], item["id"], item["form"]) for item in pending] == [(group["id"], question["id"], False)]
                    answer = {"text": "Use the waterfront section", "recipients": targets[:1], "revision": group["revision"],
                              "reply_to": question["id"]}
                    request(f"/api/groups/{another['id']}/messages", {**answer, "revision": another["revision"]}, status=404)
                    request(feed, {**answer, "recipients": targets[1:]}, status=422)
                    request(feed, {**answer, "recipients": targets}, status=422)
                    sent = request(feed, answer, status=202)
                    request(feed, answer, status=409)
                    def accepted_answer():
                        rows = request(feed)["items"]
                        return rows if any(row["text"] == "Group answer to Use the waterfront section"
                                           for row in rows) else None
                    rows = until(accepted_answer)
                    assert request("/api/attention")["requests"] == []
                    response = next(row for row in rows if row["id"] == sent["id"])
                    assert response["reply_to"] == {"id": question["id"], "author": "claude-capture",
                                                    "text": question["text"], "is_question": True}
                    assert [r["name"] for r in response["deliveries"]] == ["claude-capture"]
                    output = f"/api/agents/{targets[0]['address']}/{targets[0]['created_ms']}/output"
                    assert "fixture quote: Which report section should I use?" in request(output)["text"]
                    request(feed, { "text": "Do a different follow-up", "recipients": targets[1:],
                                    "revision": group["revision"] }, status=202)
                    until(lambda: any(row["text"] == "Group answer to Do a different follow-up"
                                      for row in request(feed)["items"]))
                    other_output = f"/api/agents/{targets[1]['address']}/{targets[1]['created_ms']}/output"
                    assert "fixture context: User: Use the waterfront section" not in request(other_output)["text"]
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=75)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert next(row for row in request(feed)["items"] if row["id"] == question["id"])["answer_state"] == "sent"
                    return
                if focus == "group-results":
                    agents = [request("/api/agents", {"name": name, "template": "claude-fixture",
                                                     "task": "Start group result fixture"}, status=201)
                              for name in ("claude-capture", "substitute")]
                    targets = [{k: agent[k] for k in ("address", "created_ms")} for agent in agents]
                    group = request("/api/groups", {"name": "Result files", "members": targets}, status=201)
                    another = request("/api/groups", {"name": "Other project", "members": targets}, status=201)
                    feed = f"/api/groups/{group['id']}/messages"
                    task = request(feed, {"text": "Wait for explicit group result", "recipients": targets[:1],
                                          "revision": group["revision"]}, status=202)
                    until(lambda: request(feed)["items"][0]["deliveries"][0]["state"] == "sent")
                    until(lambda: agent_done(agents[0]))
                    journal = root / "workspace/workspace.sqlite3"
                    with sqlite3.connect(journal) as store:
                        reply_token, launch = store.execute("SELECT token,launch_key FROM group_deliveries WHERE message_id=?",
                                                      (task["id"],)).fetchone()
                        other = store.execute("SELECT launch_key FROM journal WHERE core_id=? AND address=? AND launch_key IS NOT NULL",
                                              (core, targets[1]["address"])).fetchone()[0]
                    assert reply_token not in json.dumps(request(feed))
                    one, two = root / "group result.bin", root / "summary.txt"
                    contents = b"\x00\xff\x01\x81"
                    one.write_bytes(contents)
                    two.write_bytes(b"summary text")
                    alias = root / "alias.txt"
                    alias.symlink_to(two)
                    large_a, large_b = root / "large-a.bin", root / "large-b.bin"
                    for path, size in ((large_a, 5), (large_b, 4)):
                        with path.open("wb") as file:
                            file.truncate(size * 1024 * 1024)

                    def reply(*paths, launch_key=launch, text=b""):
                        env = {"SWARMHUB_JOURNAL": str(journal), "SWARMHUB_LAUNCH_KEY": launch_key}
                        options = [arg for path in paths for arg in ("--file", str(path))]
                        return subprocess.run([bridge, "group-reply", reply_token, *options], input=text,
                                              env=env, capture_output=True, timeout=10)

                    assert reply(one, launch_key=other).returncode != 0
                    assert reply(one, alias).returncode != 0
                    assert reply(one, large_a, large_b).returncode != 0
                    assert reply(one, one, one, one, one).returncode != 0
                    assert len(request(feed)["items"]) == 1 and request(feed)["items"][0]["files"] == []
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=75)
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    assert reply(one, two).returncode == 0
                    assert reply(one, text=b"duplicate").returncode != 0
                    one.unlink()
                    two.unlink()
                    cli("server", "stop")
                    core_running = False
                    process, base = start_bridge(port)
                    rows = request(feed)["items"]
                    assert len(rows) == 2 and rows[-1]["author"] == "claude-capture" and rows[-1]["text"] == ""
                    a, b = rows[-1]["files"]
                    assert [a["name"], b["name"]] == [one.name, two.name]
                    path = f"/api/groups/{group['id']}/files/{a['id']}"
                    request(path, status=401, authorized=False)
                    request(f"/api/groups/{another['id']}/files/{a['id']}", status=404)
                    assert request(path) == contents
                    assert request(f"/api/groups/{group['id']}/files/{b['id']}") == b"summary text"
                    assert request("/api/library/files") == []
                    return
                if focus == "group-files":
                    from hashlib import sha256
                    agents = [request("/api/agents", {"name": name, "template": "claude-fixture",
                                                     "task": "Start attachment fixture"}, status=201)
                              for name in ("claude-capture", "substitute")]
                    targets = [{k: agent[k] for k in ("address", "created_ms")} for agent in agents]
                    group = request("/api/groups", {"name": "File review", "members": targets}, status=201)
                    feed = f"/api/groups/{group['id']}/messages"
                    boundary = secrets.token_hex(16)
                    media = f"multipart/form-data; boundary={boundary}"

                    def post_files(route, message, files, status, authorized=True):
                        content = json.dumps(message).encode()
                        parts = [f"--{boundary}\r\nContent-Disposition: form-data; name=\"message\"\r\n\r\n".encode(),
                                 content, b"\r\n"]
                        for filename, data in files:
                            parts.extend([f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
                                          f"filename=\"{filename}\"\r\nContent-Type: application/octet-stream\r\n\r\n".encode(),
                                          data, b"\r\n"])
                        parts.append(f"--{boundary}--\r\n".encode())
                        return request(route + "/with-files", b"".join(parts), status=status, authorized=authorized,
                                       media_type=media)

                    def upload(text, recipients, files, status=202, authorized=True, revision=None):
                        return post_files(feed, {"text":text,"recipients":recipients,
                                                "revision": group["revision"] if revision is None else revision},
                                          files,status,authorized)

                    binary = b"\x00\xff\x81\x00" * 42_000
                    source = [("report.bin", binary), ("notes.txt", b"working notes")]
                    upload("invalid path", targets, [("../notes.txt", b"payload")], status=422)
                    upload("too many files", targets, source * 3, status=422)
                    upload("too large", targets, [("over.bin", bytes(8 * 1024 * 1024 + 1))], status=413)
                    upload("far too large", targets, [("over.bin", bytes(9 * 1024 * 1024))], status=413)
                    upload("not authorized", targets, source, status=401, authorized=False)
                    upload("stale group", targets, source, status=409, revision=group["revision"] - 1)
                    assert request(feed)["items"] == []
                    message = upload("Read the attached inputs", targets[:1], source)

                    def settled(message_id):
                        rows = request(feed)["items"]
                        row = next((row for row in rows if row["id"] == message_id), None)
                        return row if row and all(d["state"] != "pending" for d in row["deliveries"]) else None

                    first = until(lambda: settled(message["id"]))
                    assert [(d["name"], d["state"]) for d in first["deliveries"]] == [("claude-capture", "sent")]
                    reads = root / "group-attachment-reads"
                    until(lambda: reads.exists() and reads.stat().st_size)
                    read_rows = [json.loads(line) for line in reads.read_text().splitlines()]
                    assert len(read_rows) == 1
                    paths = {item["name"]: item for item in read_rows[0]}
                    assert paths["report.bin"]["sha256"] == sha256(binary).hexdigest()
                    assert Path(paths["report.bin"]["path"]).parent.name == targets[0]["address"]
                    assert paths["notes.txt"]["sha256"] == sha256(source[1][1]).hexdigest()
                    assert [(f["name"], f["bytes"]) for f in first["files"]] == [(n, len(b)) for n, b in source]
                    first_file = first["files"][0]["id"]
                    download = f"/api/groups/{group['id']}/files/{first_file}"
                    request(download, status=401, authorized=False)
                    request(f"/api/groups/{group['id'] + 1}/files/{first_file}", status=404)
                    assert request(download) == binary
                    until(lambda: agent_done(agents[0]))
                    folder = Path(paths["report.bin"]["path"]).parent
                    stored = folder.with_name(folder.name + "-saved")
                    direct_id = f"{agents[0]['address']}/{agents[0]['created_ms']}"
                    direct_route = f"/api/agents/{direct_id}/messages"
                    task = {"text":"Do not send this attachment test task","expected_core":core}
                    post_files(direct_route, {**task,"expected_core":"other-core"}, source,409)
                    post_files(direct_route, task, [("../notes.txt",b"invalid")],422)
                    folder.rename(stored)
                    try:
                        folder.write_bytes(b"prevent Core from creating the upload directory")
                        post_files(direct_route,task,source,409)
                        assert all(row["text"] != task["text"] for row in request(f"/api/history/{core}/{direct_id}")["items"])
                        failed = upload("Try with one broken upload", targets, [("partial.txt", b"partial")])
                        receipt = until(lambda: settled(failed["id"]))["deliveries"]
                        assert [r["state"] for r in receipt] == ["not_sent", "sent"]
                        assert "Could not attach partial.txt" in receipt[0]["detail"]
                        until(lambda: len(reads.read_text().splitlines()) == 2)
                        uploaded = json.loads(reads.read_text().splitlines()[-1])[0]
                        assert Path(uploaded["path"]).parent.name == targets[1]["address"]
                        assert not any(row["text"] == "Group answer to Try with one broken upload"
                                       and row["author"] == "claude-capture" for row in request(feed)["items"])
                    finally:
                        folder.unlink(missing_ok=True)
                        stored.rename(folder)
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser,check=True,timeout=85)
                        browser_agent = next(agent for agent in request("/api/workspace")["agents"] if agent["name"] == "browser-test")
                        history_path = f"/api/history/{core}/{browser_agent['address']}/{browser_agent['created_ms']}"
                        rows = request(history_path)["items"]
                        saved = next(row for row in rows if row["text"] == "Check the direct attachment")
                        assert len(saved["files"]) == 1 and saved["files"][0]["name"] == "drop.txt"
                        direct_file = f"{history_path}/files/{saved['id']}/{saved['files'][0]['id']}"
                        request(direct_file,status=401,authorized=False)
                        request(direct_file.replace(f"/files/{saved['id']}/",f"/files/{saved['id']-1}/"),status=404)
                        assert request(direct_file) == b"Dropped document"
                        assert b"File: drop.txt" in request(history_path+"/transcript")
                        direct_paths = list((folder.parent / browser_agent["address"]).glob("*drop.txt"))
                        assert len(direct_paths) == 1 and direct_paths[0].read_bytes() == b"Dropped document"
                        direct_paths[0].unlink()
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request(download) == binary
                    if chrome:
                        assert request(direct_file) == b"Dropped document"
                        subprocess.run(browser,env={**os.environ,"SWARMHUB_TEST_FOCUS":"direct-files-offline"},check=True,timeout=65)
                    return
                if focus == "instructions":
                    role = 'Keep a short research log.\nUse "sources" for related notes.'
                    task = "Research product names\nand cite sources."
                    launch = {"name": "instruction-probe", "template": "fixture", "task": task}
                    request("/api/agents", {**launch, "standing_instructions": "a" * 6145}, status=422)
                    request("/api/agents", {**launch, "standing_instructions": "a\x1b"}, status=422)
                    request("/api/agents", {**launch, "standing_instructions": role, "task": "a" * 16384}, status=422)
                    started = request("/api/agents", {**launch, "standing_instructions": role}, status=201)
                    profile_id = started["profile_id"]
                    terminal_id = f"{started['address']}/{started['created_ms']}"
                    first_launch = f"/api/history/{core}/{terminal_id}"
                    log = (root / "fixture.launches")
                    until(lambda: log.exists() and log.stat().st_size)
                    assert [json.loads(line) for line in log.read_text().splitlines()] == [
                        {"standing_instructions": role, "current_task": task},
                    ]
                    assert request(first_launch)["items"][0]["text"] == task
                    assert request(first_launch)["items"][0]["launch_instructions"] == role
                    first_profile = request("/api/profiles")[0]
                    assert first_profile["instructions"] == role
                    edit = {key: first_profile[key] for key in ("name", "subtitle", "avatar", "pinned", "hidden", "revision")}
                    new_role = "Next role: highlight uncertainty."
                    request(f"/api/profiles/{profile_id}", {**edit, "instructions": new_role})
                    request(f"/api/agents/{terminal_id}/end", {})
                    current = request("/api/profiles")[0]
                    relaunch = {"name": started["name"], "template": "claude-fixture",
                                "task": "Run without saved instructions", "profile_id": profile_id}
                    request("/api/agents", {**relaunch, "instructions_revision": edit["revision"]}, status=409)
                    request("/api/agents", {**relaunch, "standing_instructions": ""}, status=422)
                    skipped = request("/api/agents", relaunch, status=201)
                    skipped_id = f"{skipped['address']}/{skipped['created_ms']}"
                    row = request(f"/api/history/{core}/{skipped_id}")["items"][0]
                    assert "launch_instructions" not in row and row["text"] == relaunch["task"]
                    request(f"/api/agents/{skipped_id}/end", {})
                    sent = request("/api/agents", {**relaunch, "instructions_revision": current["revision"],
                                                   "task": "Run with saved instructions"}, status=201)
                    sent_id = f"{sent['address']}/{sent['created_ms']}"
                    latest_launch = f"/api/history/{core}/{sent_id}"
                    actual = until(lambda: next((row for row in request(latest_launch)["items"] if row["kind"] == "reply"), None))
                    assert new_role in actual["text"] and "Run with saved instructions" in actual["text"]
                    assert request(latest_launch)["items"][0]["launch_instructions"] == new_role
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=85)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request(first_launch)["items"][0]["launch_instructions"] == role
                    assert request(latest_launch)["items"][0]["launch_instructions"] == new_role
                    return
                if focus == "runtimes":
                    wrapper = root / "custom-runner"
                    wrapper.write_text(
                        "#!/bin/sh\n"
                        'test -z "$SWARMHUB_LAUNCH_MODEL" || exit 1\n'
                        'printf "Custom model: %s\\n" "${SWARMHUB_MODEL_ID:-runner-default}"\n'
                        f"exec python3 {shlex.quote(str(fixture))}\n"
                    )
                    wrapper.chmod(0o700)
                    (templates / "custom-choice.md").write_text(
                        f"---\ndescription: Custom chooser fixture\ncommand: {shlex.quote(str(wrapper))}\n---\n"
                    )
                    for command in ("codex", "claude"):
                        binary = "SWARMHUB_" + command.upper() + "_BIN"
                        (templates / f"{command}-choice.md").write_text(
                            f"---\ndescription: {command.title()} picker fixture\n"
                            f"command: {binary}={shlex.quote(str(claude))} PICKER_TEST=1 "
                            f"{shlex.quote(bridge)} run-{command} --workspace-approvals\n---\n"
                        )
                    (templates / "codex-manual.md").write_text((templates / "codex-choice.md").read_text().replace(
                        "PICKER_TEST=1", "PICKER_TEST=1 PICKER_MODEL=gpt-outside-catalog"))
                    codex_model_fixture = root / "codex-model-fixture"
                    codex_model_fixture.write_text("#!/usr/bin/env python3\n"
                        + f"PICKER_BINARY = {str(claude)!r}\n"
                        + """import json, os, sys
if sys.argv[1:2] != ["app-server"]:
    os.execv(PICKER_BINARY, [PICKER_BINARY, *sys.argv[1:]])
assert sys.argv[1:] == ["app-server", "--listen", "stdio://", "-c", "analytics.enabled=false",
                       "-c", "check_for_update_on_startup=false"]
def reply(message, result):
    print(json.dumps({"id": message["id"], "result": result}), flush=True)
first = json.loads(sys.stdin.readline())
assert first["method"] == "initialize"
reply(first, {"userAgent":"SYNTHETIC-PRIVATE-PROTOCOL-DATA"})
assert json.loads(sys.stdin.readline()) == {"method":"initialized"}
first = json.loads(sys.stdin.readline())
assert first["method"] == "model/list" and first["params"] == {"includeHidden":False, "limit":64, "cursor":None}
reply(first, {"data":[{"id":"alias-is-not-launch-id","model":"gpt-fixture-listed","hidden":False},
                       {"id":"hidden","model":"gpt-hidden","hidden":True}],
              "nextCursor":"second-page"})
second = json.loads(sys.stdin.readline())
assert second["method"] == "model/list" and second["params"]["cursor"] == "second-page"
reply(second, {"data":[{"id":"other-alias","model":"provider/gpt-exact","hidden":False}],
               "nextCursor":None})
""")
                    codex_model_fixture.chmod(0o700)
                    (templates / "codex-discovery.md").write_text(
                        f"---\ndescription: Codex app-server fixture\n"
                        f"command: SWARMHUB_CODEX_BIN={shlex.quote(str(codex_model_fixture))} "
                        f"PICKER_TEST=1 PICKER_MODEL=gpt-fixture-listed {shlex.quote(bridge)} run-codex --workspace-approvals\n---\n"
                    )
                    (templates / "custom-manual.md").write_text((templates / "custom-choice.md").read_text())
                    catalog = root / "workspace/runtime-catalog.json"
                    known = {"harness": "Claude Code", "provider": "Fixture Provider", "model": "fixture-model"}
                    local = {"harness": "Local runner", "provider": "Local test", "model": "local-demo"}
                    codex_selection = {"id": "gpt-fixture", "label": "Fixture GPT", "provider": "OpenAI"}
                    claude_selection = {"id": "sonnet[1m]", "label": "Fixture Sonnet", "provider": "Anthropic"}
                    custom_selection = {"id": "local/adapter:model-v2", "label": "Adapter v2", "provider": "Local endpoint"}
                    entries = {
                        "approval-fixture": {**known, "models": [claude_selection]},
                        "fixture": local,
                        "codex-choice": {"harness": "Codex", "models": [codex_selection]},
                        "codex-discovery": {"harness": "Codex", "discover_models": True},
                        "claude-choice": {"harness": "Claude Code", "models": [claude_selection]},
                        "custom-choice": {"harness": "Custom runner", "model_transport": "environment", "models": [custom_selection]},
                        "custom-manual": {"harness": "Custom runner", "model_transport": "environment"},
                    }
                    (templates / "invalid.md").write_text("---\nSYNTHETIC-PRIVATE-COMMAND\n---\n")
                    catalog.write_text(json.dumps(entries))
                    model_route = "/api/runtime-models/codex-discovery"
                    request(model_route, {}, status=401, authorized=False)
                    request(model_route, {}, status=403, origin="http://outside.example")
                    request("/api/runtime-models/codex-choice", {}, status=409)
                    assert request(model_route, {}) == {
                        "models": [{"id": "gpt-fixture-listed"}, {"id": "provider/gpt-exact"}],
                        "truncated": False,
                    }
                    state = request("/api/workspace")
                    options = {choice["name"]: choice for choice in state["templates"]}
                    assert options["approval-fixture"]["runtime"] == {**known, "display_name": "Claude"}
                    assert options["fixture"]["runtime"] == local
                    assert options["codex-fixture"]["runtime"] == {"harness": "Codex", "provider": None, "model": None, "display_name": "Codex"}
                    assert "models" not in options["approval-fixture"]
                    assert options["codex-choice"]["model_agent"] == "Codex" and options["codex-choice"]["models"] == [codex_selection]
                    assert options["claude-choice"]["model_agent"] == "Claude Code" and options["claude-choice"]["models"] == [claude_selection]
                    assert options["custom-choice"]["model_agent"] == "Custom runner" and options["custom-choice"]["models"] == [custom_selection]
                    assert options["codex-manual"]["model_agent"] == "Codex" and "models" not in options["codex-manual"]
                    assert options["codex-discovery"]["model_agent"] == "Codex" and options["codex-discovery"]["discover_models"] is True
                    assert options["custom-manual"]["model_agent"] == "Custom runner" and "models" not in options["custom-manual"]
                    assert "model_agent" not in options["fixture"]
                    assert all("command" not in option for option in options.values())
                    assert "SYNTHETIC-PRIVATE-COMMAND" not in json.dumps(state)
                    catalog.write_text('{"fixture": {"harness": "x", "unexpected": "SYNTHETIC-INVALID-CATALOG"}}')
                    invalid = request("/api/workspace")
                    assert invalid["runtime_catalog_warning"] and "SYNTHETIC-INVALID-CATALOG" not in json.dumps(invalid)
                    assert all(not item["error"] for item in invalid["templates"] if item["name"] == "fixture")
                    catalog.write_text(json.dumps(entries))
                    launch = {"name": "runtime-probe", "template": "fixture", "task": "runtime selection test"}
                    request("/api/agents", {**launch, "expected_runtime": {**local, "model": "old-model"}}, status=409)
                    assert request("/api/profiles") == []
                    launched = request("/api/agents", {**launch, "expected_runtime": local}, status=201)
                    launch_key = f"{launched['address']}/{launched['created_ms']}"
                    until(lambda: "fixture received: runtime selection test"
                          in request(f"/api/agents/{launch_key}/output")["text"])
                    entries["fixture"] = {**local, "model": "new-model"}
                    catalog.write_text(json.dumps(entries))
                    assert next(item for item in request("/api/workspace")["templates"] if item["name"] == "fixture")[
                        "runtime"]["model"] == "new-model"
                    args = {"name":"codex-picked", "template":"codex-choice", "task":"Confirm model selection"}
                    request("/api/agents", {**args, "model_choice": claude_selection}, status=409)
                    request("/api/agents", {**args, "template":"approval-fixture", "model_choice": claude_selection}, status=409)
                    request("/api/agents", {**args, "model_choice": codex_selection, "model_id":"gpt-other"}, status=422)
                    request("/api/agents", {**args, "template":"fixture", "model_id":"gpt-other"}, status=422)
                    for invalid_id in ("", "--version", "provider id", "a" * 161):
                        request("/api/agents", {**args, "template":"codex-manual", "model_id":invalid_id}, status=422)
                    picked = request("/api/agents", {**args, "model_choice": codex_selection}, status=201)
                    codex_url = f"/api/agents/{picked['address']}/{picked['created_ms']}"
                    until(lambda: "fixture selected model: gpt-fixture" in request(codex_url + "/output")["text"])
                    custom_args = {"name":"custom-picked", "template":"custom-choice", "task":"Confirm custom model"}
                    request("/api/agents", {**custom_args, "model_choice":{**custom_selection,"id":"unspecified"}}, status=409)
                    request("/api/agents", {**custom_args, "model_choice":{**custom_selection,"provider":"Other"}}, status=409)
                    default = request("/api/agents", {**custom_args, "name":"custom-default"}, status=201)
                    default_url = f"/api/agents/{default['address']}/{default['created_ms']}"
                    until(lambda: "Custom model: runner-default" in request(default_url + "/output")["text"])
                    manual_id = "local/new-model:latest"
                    manual = request("/api/agents", {**custom_args,"name":"custom-entered","template":"custom-manual",
                                                     "model_id":manual_id}, status=201)
                    manual_url = f"/api/agents/{manual['address']}/{manual['created_ms']}"
                    until(lambda: f"Custom model: {manual_id}" in request(manual_url + "/output")["text"])
                    if not chrome:
                        picked_claude = request("/api/agents", {"name":"claude-picked", "template":"claude-choice",
                                                "task":"Confirm model selection", "model_choice":claude_selection}, status=201)
                        claude_url = f"/api/agents/{picked_claude['address']}/{picked_claude['created_ms']}"
                        until(lambda: "fixture selected model: sonnet[1m]" in request(claude_url + "/output")["text"])
                        picked_custom = request("/api/agents", {**custom_args, "model_choice":custom_selection}, status=201)
                        custom_url = f"/api/agents/{picked_custom['address']}/{picked_custom['created_ms']}"
                        until(lambda: "Custom model: local/adapter:model-v2" in request(custom_url + "/output")["text"])
                    if chrome:
                        subprocess.run(["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                                       check=True, timeout=75)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    profiles = request("/api/profiles")
                    assert next(p for p in profiles if p["id"] == launched["profile_id"])["sessions"][0]["runtime"] == local
                    for name, model in (("codex-picked", codex_selection), ("claude-picked", claude_selection)):
                        stored = next(p for p in profiles if p["name"] == name)["sessions"][0]["runtime"]
                        assert (stored["model_id"], stored["model"], stored["provider"]) == (model["id"], model["label"], model["provider"])
                    stored = next(p for p in profiles if p["name"] == "custom-picked")["sessions"][0]["runtime"]
                    assert stored == {"harness":"Custom runner", "model_id":custom_selection["id"],
                                      "model":custom_selection["label"], "provider":custom_selection["provider"]}
                    stored = next(p for p in profiles if p["name"] == "custom-entered")["sessions"][0]["runtime"]
                    assert stored == {"harness":"Custom runner","model_id":manual_id,"model":manual_id,"provider":None}
                    if chrome:
                        assert next(p for p in profiles if p["name"] == "browser-test")["sessions"][0]["runtime"] == {**known, "display_name": "Claude"}
                        entered = next(p for p in profiles if p["name"] == "codex-entered")
                        assert entered["sessions"][0]["runtime"]["model_id"] == "gpt-outside-catalog"
                    return
                if focus == "profile-create":
                    cli("server", "stop")
                    core_running = False
                    request("/api/profiles", {"name": "Denied"}, status=401, authorized=False)
                    request("/api/profiles", {"name": "Denied"}, status=403, origin="https://example.invalid")
                    for name in ("", "x" * 61, "bad\nname"):
                        request("/api/profiles", {"name": name}, status=422)
                    request("/api/profiles", {"name":"Valid", "instructions":"x" * 6145}, status=422)
                    assert request("/api/profiles") == []
                    instructions = "Check sources before writing."
                    first = request("/api/profiles", {"name":" Help desk ", "instructions":instructions}, status=201)
                    second = request("/api/profiles", {"name":"Help desk"}, status=201)
                    assert first["runtime_name"] != second["runtime_name"]
                    assert first["name"] == second["name"] == "Help desk"
                    assert first["instructions"] == instructions and second["instructions"] == ""
                    assert first["sessions"] == second["sessions"] == []
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser, check=True, timeout=50)
                    else:
                        request("/api/profiles", {"name":"Café research"}, status=201)
                    saved = next(p for p in request("/api/profiles") if p["name"] == "Café research")
                    assert saved["sessions"] == []
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    cli("server", "start")
                    core_running = True
                    process, base = start_bridge(port)
                    assert next(p for p in request("/api/profiles") if p["id"] == first["id"]) == first
                    assert next(p for p in request("/api/profiles") if p["id"] == saved["id"]) == saved
                    if chrome:
                        subprocess.run(browser, env={**os.environ, "SWARMHUB_TEST_FOCUS":"profile-create-launch"}, check=True, timeout=60)
                    else:
                        agent = request("/api/agents", {"name":saved["runtime_name"], "profile_id":saved["id"],
                                                       "template":"fixture", "task":"Review the edited project notes."}, status=201)
                        assert agent["profile_id"] == saved["id"] and agent["first_message"]["sent"]
                    profile = next(p for p in request("/api/profiles") if p["id"] == saved["id"])
                    assert profile["name"] == "Café research" and len(profile["sessions"]) == 1
                    return
                if focus == "profiles":
                    request("/api/profiles", status=401, authorized=False)
                    assert request("/api/profiles") == []
                    launch = {"name": "profile-probe", "template": "fixture", "task": "profile test task"}
                    test_agent = request("/api/agents", launch, status=201)
                    assert test_agent["core"] == core and test_agent["profile_id"]
                    saved = request("/api/profiles")[0]
                    assert saved["id"] == test_agent["profile_id"] and saved["sessions"][0]["core"] == core
                    request("/api/agents", {**launch, "profile_id": saved["id"]}, status=409)
                    request("/api/agents", {**launch, "name": "other", "profile_id": saved["id"]}, status=422)
                    path = f"/api/profiles/{saved['id']}"
                    edit = {key: saved[key] for key in ("name", "subtitle", "avatar", "pinned", "hidden", "revision")}
                    request(path, {**edit, "avatar": "invalid"}, status=422)
                    request(path, edit, status=401, authorized=False)
                    request(path, edit)
                    request(path, edit, status=409)
                    if chrome:
                        browser = ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp]
                        subprocess.run(browser, check=True, timeout=85)
                    cli("server", "stop")
                    core_running = False
                    port = base.rsplit(":", 1)[1]
                    stop(process)
                    process = None
                    process, base = start_bridge(port)
                    assert request("/api/profiles")[-1]["id"] == saved["id"]
                    if chrome:
                        profile = next(p for p in request("/api/profiles") if p["name"] == "Studio Research")
                        assert profile["pinned"] and not profile["hidden"] and len(profile["sessions"]) == 2
                        assert all(p["id"] != profile["id"] for p in request("/api/profiles")[1:])
                        subprocess.run(browser, env={**os.environ, "SWARMHUB_TEST_FOCUS": "profiles-offline"},
                                       check=True, timeout=45)
                    return
                if focus in ("approvals", "codex", "gemini", "groups", "skills"):
                    if focus == "codex":
                        test_codex(core)
                    elif focus == "gemini":
                        test_gemini(core)
                    elif focus == "groups":
                        linked = request("/api/agents", {"name": "claude-capture", "template": "claude-fixture",
                                                          "task": "first structured task"}, status=201)
                        test_groups(linked)
                    elif focus == "skills":
                        test_skills(core)
                    else:
                        test_approvals()
                    if chrome:
                        subprocess.run(
                            ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                            check=True, timeout=90,
                        )
                    return

                assert request("/api/library/36")["text"] == "Preserve this snapshot"
                if legacy_version == "1":
                    assert request("/api/history/legacy-core/t5/1")["items"][-1]["text"] == "Preserve this reply"
                request(f"/api/agents/{unrelated['address']}/{unrelated['created_ms']}/output", status=404)
                request("/api/agents", {"name": "test", "template": "unknown", "task": "do not run"}, status=422)
                request("/api/agents", {"name": "test", "template": "fixture", "task": "\x1b"}, status=422)

                agent = request("/api/agents", {"name": "test", "template": "fixture", "task": "first task"}, status=201)
                assert agent["first_message"]["sent"] and agent["template"] == "fixture"
                key = f"{agent['address']}/{agent['created_ms']}"
                url = f"/api/agents/{key}"
                history = f"/api/history/{core}/{key}"
                until(lambda: "fixture received: first task" in request(url + "/output")["text"])
                assert [(item["text"], item["state"]) for item in request(history)["items"]] == [
                    ("first task", "sent"),
                ]
                request(f"/api/agents/{agent['address']}/0/messages", {"text": "wrong session"}, status=404)
                request(url + "/messages", {"text": "wait here"})
                until(lambda: request("/api/workspace")["agents"][0]["status"] == {"state": "working"})
                assert request(url + "/interrupt", {})["outcome"] == "stopped"
                until(lambda: "fixture interrupted" in request(url + "/output")["text"])
                snapshot_id = request(url + "/snapshots", {"title": "Interrupt result"}, status=201)["id"]
                assert "fixture interrupted" in request(f"/api/library/{snapshot_id}")["text"]
                assert request("/api/library")[0]["title"] == "Interrupt result"
                request("/api/library", status=401, authorized=False)

                # Kill the bridge mid-delivery. The replacement must retain the
                # task without inventing an acknowledgement or replaying it.
                failed = []
                def pending_send():
                    try:
                        request(url + "/messages", {"text": "bridge went away"})
                    except OSError:
                        failed.append(True)

                thread = threading.Thread(target=pending_send, daemon=True)
                thread.start()
                until(lambda: any(row["text"] == "bridge went away" and row["state"] == "pending"
                                  for row in request(history)["items"]))
                port = base.rsplit(":", 1)[1]
                stop(process)
                process = None
                thread.join(timeout=5)
                assert failed == [True]
                process, base = start_bridge(port)
                assert request("/api/workspace")["agents"][0]["address"] == agent["address"]
                rows = request(history)["items"]
                assert [(row["text"], row["state"]) for row in rows if row["kind"] == "task"] == [
                    ("first task", "sent"), ("wait here", "sent"), ("bridge went away", "unconfirmed"),
                ]
                assert rows[2]["kind"] == "snapshot" and rows[2]["id"] == snapshot_id and not rows[2]["text"]
                assert request(f"/api/history/another-core/{key}")["items"] == []
                assert "fixture interrupted" in request(f"/api/library/{snapshot_id}")["text"]
                assert request(url + "/end", {})["state"] == "finished"
                request(url + "/messages", {"text": "must not send"}, status=422)

                for index in range(31):
                    request(url + "/snapshots", {"title": f"Page item {index}"}, status=201)
                first_page = request(history)
                previous_page = request(f"{history}?before={first_page['before']}")
                entries = previous_page["items"] + first_page["items"]
                assert len(first_page["items"]) == 30 and previous_page["before"] is None
                assert len({row["id"] for row in entries}) == len(entries) == 35
                assert [row["id"] for row in entries] == sorted(row["id"] for row in entries)

                linked = request("/api/agents", {"name": "claude-capture", "template": "claude-fixture",
                                                  "task": "first structured task"}, status=201)
                linked_key = f"{linked['address']}/{linked['created_ms']}"
                linked_history = f"/api/history/{core}/{linked_key}"
                events = request(linked_history)["items"]
                assert [event["kind"] for event in events] == ["task", "reply"]
                assert events[-1]["detail"] == "Claude Code"
                assert events[-1]["text"] == "Structured reply for first structured task\n<em>literal text</em>"
                attachment = f"/api/agents/{linked_key}/attachments"
                content = b"\x00\xff" * 100_000
                request(attachment + "?name=%2Fetc%2Ftest", content, status=422)
                request(attachment + "?name=too-large.bin", bytes(8 * 1024 * 1024 + 1), status=413)
                staged = request(attachment + "?name=browser%20input.bin", content, status=201)
                assert staged["recorded"] and staged["bytes"] == len(content)
                assert Path(staged["path"]).name == "browser_input.bin"
                assert Path(staged["path"]).read_bytes() == content
                assert request(linked_history)["items"][-1]["kind"] == "attachment"
                stop(process)
                process = None
                cli("send", "claude-capture", "while bridge is offline")
                process, base = start_bridge(port)
                events = request(linked_history)["items"]
                assert [event["kind"] for event in events] == ["task", "reply", "attachment", "reply", "artifact", "artifact"]
                assert "while bridge is offline" in events[3]["text"]
                generated = request("/api/library/files")
                assert {item["title"] for item in generated} == {"Agent result.txt", "binary.dat"}
                binary_id = next(item["id"] for item in generated if item["title"] == "binary.dat")
                text_id = next(item["id"] for item in generated if item["title"] == "Agent result.txt")
                assert request(f"/api/library/files/{binary_id}")["preview"] is None
                assert request(f"/api/library/files/{binary_id}/download") == b"\x00\xff\x11"
                assert "<script>plain text</script>" in request(f"/api/library/files/{text_id}")["preview"]
                request(f"/api/library/files/{binary_id}/download", status=401, authorized=False)

                group_url, feed = test_groups(linked)

                inputs = {"name": "Recurring check", "task": "Routine fixture task",
                          "schedule": {"kind": "interval", "minutes": 60}}
                routine_target = {field: linked[field] for field in ("address", "created_ms")}
                checked = request("/api/routines", {**inputs, "target": routine_target}, status=201)
                routine_url = f"/api/routines/{checked['id']}"
                assert checked["state"] == "active" and checked["next_at"] > int(time.time() * 1000)
                request(routine_url + "/state", "pause")
                assert request(routine_url)["routine"]["next_at"] is None
                request(routine_url + "/test", {}, status=202)
                def routine_done(kind, state):
                    rows = request(routine_url)["runs"]
                    return rows[0] if rows and (rows[0]["kind"], rows[0]["state"]) == (kind, state) else None
                until(lambda: routine_done("test", "sent"))
                until(lambda: agent_done(linked))
                assert request(routine_url)["routine"]["state"] == "paused"
                request(routine_url + "/state", "resume")
                def force_due(seconds_ago):
                    with sqlite3.connect(str(root / "workspace/workspace.sqlite3")) as journal:
                        journal.execute("UPDATE routines SET next_at=? WHERE id=?",
                                        (int((time.time() - seconds_ago) * 1000), checked["id"]))
                force_due(1)
                until(lambda: routine_done("schedule", "sent"))
                assert request(routine_url)["routine"]["next_at"] > int(time.time() * 1000)
                force_due(3_600)
                skipped = until(lambda: routine_done("schedule", "skipped"))
                assert "missed" in skipped["detail"]
                assert sum(row.get("detail") == "Routine: Recurring check"
                           for row in request(linked_history)["items"]) == 2
                changed = request(routine_url, {**inputs, "schedule": {
                    "kind": "daily", "hour": 9, "minute": 5, "timezone": "Europe/Warsaw", "weekdays": True,
                }})
                assert changed["schedule"]["timezone"] == "Europe/Warsaw" and changed["schedule"]["weekdays"]
                assert request(routine_url + "/state", "archive")["state"] == "archived"
                request(routine_url + "/test", {}, status=404)

                test_approvals()
                test_gemini(core)

                if chrome:
                    roster = {a["name"]: a for a in request("/api/workspace")["agents"]}
                    for name in ("claude-capture", "substitute"):
                        member = roster.get(name)
                        if not member or member["state"] != "live" or member["reason"]:
                            output = (request(f"/api/agents/{member['address']}/{member['created_ms']}/output")["text"]
                                      if member else "")
                            raise AssertionError((name, member, output))
                    subprocess.run(
                        ["node", str(Path(__file__).with_name("browser.mjs")), chrome, base, token, temp],
                        check=True, timeout=110,
                    )
                cli("server", "stop")
                core_running = False
                request("/api/workspace", status=503)
                assert request(f"/api/library/{snapshot_id}")["detail"] == "Interrupt result"
                archived = request("/api/library/conversations")
                assert any(row["core"] == core and row["address"] == agent["address"] for row in archived)
                assert request(f"{history}?before={first_page['before']}")["items"][3]["state"] == "unconfirmed"
                assert request(linked_history)["items"][3]["detail"] == "Claude Code"
                assert request(f"/api/library/files/{binary_id}/download") == b"\x00\xff\x11"
                assert request(group_url)["name"] == "Release review"
                assert request(feed)["items"][1]["text"] == "Group answer to One recipient only"
                assert request(routine_url)["routine"]["state"] == "archived"
                assert len(request(routine_url)["runs"]) == 3
            finally:
                if process is not None:
                    stop(process)
        finally:
            if core_running:
                cli("server", "stop")


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        sys.exit("Usage: smoke.py /path/to/hc /path/to/swarmhub-herdr [/path/to/chrome]")
    smoke(*(str(Path(arg).absolute()) for arg in sys.argv[1:]))
    print("Herdr workspace smoke passed.")
