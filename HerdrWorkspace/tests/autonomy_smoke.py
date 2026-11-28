"""Goals kept by the workspace, autonomy levels, alerts and the AI list, against a real, isolated Herdr Core.

    python3 tests/autonomy_smoke.py "$(command -v hc)" target/debug/swarmhub-herdr

No model is called: the bot's agent is a small program that answers a goal step with the report line the
workspace asks for. Everything lives in a scratch folder under SWARMHUB_TEST_TMPDIR (default /var/tmp).
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

AGENT = r'''
import json
import os
from pathlib import Path
import subprocess

here = Path(__file__)
seen = here.with_suffix(".seen")
plan = here.with_suffix(".plan")
bridge = os.environ["QA_BRIDGE"]

def status(value):
    print("\x1b]7501;state=" + value + "\x1b\\", end="", flush=True)

def say(text):
    subprocess.run([bridge, "capture-reply"], input=text.encode(), check=True)

def read():
    line = input()
    with seen.open("a") as log:
        log.write(line + "\n")
    return line

status("idle")
while True:
    try:
        line = read()
        if line.startswith("[Goal step "):
            status("working")
            token = None
            while token is None:
                following = read()
                if following.startswith('{"iteration":"'):
                    token = json.loads(following)["iteration"]
            outcomes = json.loads(plan.read_text())
            outcome = outcomes.pop(0)
            plan.write_text(json.dumps(outcomes))
            report = {"iteration": token, "outcome": outcome, "evidence": "Evidence for " + outcome}
            say("I worked on the step.\n" + json.dumps(report))
            status("done")
        elif line == "ASK FOR PERMISSION":
            # What an agent program reports while it waits at a permission prompt in its terminal.
            print("\x1b]7501;state=blocked:kind=permission\x1b\\", end="", flush=True)
        elif line.startswith("PERSON: "):
            status("working")
            say("Understood: " + line[8:])
            status("done")
        elif line.startswith("[From SwarmHub] The person changed how much you ask"):
            status("working")
            say("I ask as the new level says.")
            status("done")
    except EOFError:
        break
'''


class Receiver(BaseHTTPRequestHandler):
    heard = []

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
        Receiver.heard.append((self.headers.get("Title", ""), body))
        self.send_response(200)
        self.end_headers()

    def log_message(self, *_):
        pass


def until(check, seconds=60, what="the expected state"):
    deadline = time.time() + seconds
    while time.time() < deadline:
        found = check()
        if found:
            return found
        time.sleep(0.25)
    raise AssertionError("timed out waiting for " + what)


def smoke(hc, bridge):
    sandbox = os.environ.get("SWARMHUB_TEST_TMPDIR", "/var/tmp")
    with tempfile.TemporaryDirectory(prefix="swarmhub-autonomy-", dir=sandbox) as temp:
        root = Path(temp)
        for folder in ("run", "state", "config"):
            (root / folder).mkdir(mode=0o700)
        agent = root / "agent.py"
        agent.write_text(AGENT)
        seen, plan = agent.with_suffix(".seen"), agent.with_suffix(".plan")
        seen.write_text("")
        plan.write_text("[]")
        templates = root / "config/herdr-core/templates"
        templates.mkdir(parents=True)
        (templates / "goal-agent.md").write_text(
            f"---\ndescription: Answers goal steps without a model\n"
            f"command: QA_BRIDGE={bridge} python3 {agent}\nstop: ctrl+c\n---\n"
        )
        (root / "config/herdr-core/config.toml").write_text("notes_quiet = 0\ndraft_wait = 0\n")
        token = secrets.token_hex(32)
        socket = root / "hc.sock"
        core_env = {
            "HOME": temp, "PATH": "/usr/bin:/bin", "HC_SESSION": "swarmhub-autonomy",
            "XDG_RUNTIME_DIR": str(root / "run"), "XDG_STATE_HOME": str(root / "state"),
            "XDG_CONFIG_HOME": str(root / "config"), "HC_SOCKET": str(socket),
            "HC_SETTLE_MS": "0", "HC_STARTED_MS": "5000", "LANG": "C.UTF-8",
        }

        def cli(*args):
            result = subprocess.run([hc, *args], env=core_env, cwd=root, capture_output=True, text=True, timeout=16)
            assert result.returncode == 0, result.stderr
            return result.stdout

        receiver = ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
        threading.Thread(target=receiver.serve_forever, daemon=True).start()
        cli("server", "start")
        process = None
        try:
            # For the install check npm puts programs into the scratch folder, and the server looks there first.
            npm = shutil.which("npm") if os.environ.get("SWARMHUB_TEST_NPM") == "1" else None
            search = ":".join([str(root / "npm/bin"), *([str(Path(npm).parent)] if npm else []), "/usr/bin", "/bin"])
            process = subprocess.Popen([bridge], env={
                **({"NPM_CONFIG_PREFIX": str(root / "npm"), "SWARMHUB_SERVICE_PATH": search} if npm else {}),
                # The same config folder as Core, as on a real server: a template the workspace writes is Core's.
                "XDG_CONFIG_HOME": str(root / "config"),
                "HOME": temp, "PATH": search if npm else "/usr/bin:/bin", "HC_SOCKET": str(socket),
                "SWARMHUB_ACCESS_TOKEN": token, "SWARMHUB_PORT": "0",
                "SWARMHUB_DATA_DIR": str(root / "workspace"), "SWARMHUB_AGENT_CWD": str(root),
            }, stdout=subprocess.PIPE, text=True)
            line = process.stdout.readline()
            assert line.startswith("SwarmHub · http://"), line
            base = line.strip().split(" · ", 1)[1]

            def request(path, body=None, status=200, timeout=20):
                headers = {"Authorization": f"Bearer {token}"}
                data = None
                if body is not None:
                    data = json.dumps(body).encode()
                    headers.update({"Content-Type": "application/json", "Origin": base})
                try:
                    response = urllib.request.urlopen(
                        urllib.request.Request(base + path, data=data, headers=headers), timeout=timeout)
                except urllib.error.HTTPError as error:
                    response = error
                with response:
                    answer = response.read()
                    assert response.status == status, (path, response.status, answer)
                    try:
                        return json.loads(answer)
                    except ValueError:
                        # A refusal of a malformed body is plain text.
                        return answer.decode(errors="replace")

            # The workspace says what it can do, so an app knows before it offers any of it.
            shown = request("/api/workspace")
            assert shown["bot_goals"] is True and shown["alerts"] is True and shown["server_ais"] is True
            assert any(template["name"] == "goal-agent" for template in shown["templates"])

            bot = "0e5c0de0-0000-4000-8000-00000000a001"
            request("/api/bots", {"bots": [{"id": bot, "name": "Goal QA", "template": "goal-agent"}]})
            history = lambda: request(f"/api/bots/history?bot={bot}&after=0&limit=200")
            said = lambda: [(item["code"], item["text"]) for item in history()["items"] if item["kind"] == "said"]
            notices = lambda: [item["text"] for item in history()["items"] if item["kind"] == "notice"]
            goal = lambda: request(f"/api/bots/{bot}/goal")["goal"]

            # Alerts: the test line arrives at once, and nothing older than the address is sent.
            address = f"http://127.0.0.1:{receiver.server_address[1]}/topic"
            request("/api/alerts", {"address": "ftp://example.test/x"}, status=422)
            saved = request("/api/alerts", {"address": address, "test": True})
            assert saved == {"address": address, "test": "sent"}, saved
            assert Receiver.heard == [("SwarmHub", "Alerts from this workspace arrive here.")], Receiver.heard
            assert request("/api/alerts")["address"] == address

            # Autonomy: Auto is the default, the level follows it until the person sets one, and a change is
            # typed into the bot's agent, which is started for it and reads its notes with the new rules.
            settings = f"/api/bot-agent-settings/{bot}"
            fresh = request(settings)
            assert fresh["auto_mode"] is True and fresh["autonomy"] is None, fresh
            request(settings, {"autonomy": "reckless"}, status=422)
            assert request(settings, {"autonomy": "full"})["autonomy"] == "full"
            until(lambda: "The person changed how much you ask" in seen.read_text(), what="the autonomy notice")
            notes = seen.read_text()
            assert "The person chose that you do not ask for permission" in notes
            assert "Standing operational approvals" not in notes, "a bot that does not ask gets no list of when to ask"
            until(lambda: any(text == "I ask as the new level says." for _, text in said()), what="the bot's answer")
            assert request(settings, {"autonomy": "balanced"})["autonomy"] == "balanced"
            until(lambda: "Ask the person and wait for their yes only before" in seen.read_text(),
                  what="the balanced rules")
            assert "Standing operational approvals" in seen.read_text()

            # A goal steps by itself: progress brings the next step with the last result, complete ends it.
            plan.write_text(json.dumps(["progress", "complete"]))
            request(f"/api/bots/{bot}/goal", {"objective": " "}, status=422)
            started = request(f"/api/bots/{bot}/goal", {"objective": "Tidy the fixture folder", "step_limit": 5}, status=201)["goal"]
            assert (started["state"], started["iteration"], started["step_limit"]) == ("queued", 0, 5), started
            done = until(lambda: goal() if goal()["state"] == "completed" else None, what="the goal to complete")
            assert (done["id"], done["iteration"], done["detail"]) == (started["id"], 2, "Evidence for complete"), done
            steps = seen.read_text()
            assert "[Goal step 1, from SwarmHub] The person set this goal for you: Tidy the fixture folder" in steps
            assert "[Goal step 2, from SwarmHub]" in steps and "Last result: Evidence for progress" in steps
            # The chat shows the bot's words without the report line, and the person is told when it is done.
            assert said().count(("goal", "I worked on the step.")) == 2, said()
            assert "Goal completed: Tidy the fixture folder" in notices(), notices()
            until(lambda: ("Goal QA", "Goal completed: Tidy the fixture folder") in Receiver.heard,
                  what="the alert that the goal is complete")
            assert all("iteration" not in body for _, body in Receiver.heard), "no report line leaves the workspace"
            assert [item["id"] for item in history()["goals"]] == [started["id"]]

            # A blocked goal waits for the person and goes on when they have answered in the chat.
            plan.write_text(json.dumps(["blocked", "complete"]))
            second = request(f"/api/bots/{bot}/goal", {"objective": "Rotate the staging keys"}, status=201)["goal"]
            assert second["step_limit"] == 40
            waits = until(lambda: goal() if goal()["state"] == "waiting" else None, what="the goal to wait")
            assert waits["pause"] == "blocked" and waits["detail"] == "Evidence for blocked", waits
            until(lambda: any("Goal QA needs your answer" in text for text in notices()), what="the question notice")
            # The person hears about it wherever they are: the question is an alert too.
            until(lambda: any(title == "Goal QA" and "needs your answer" in body for title, body in Receiver.heard),
                  what="the alert that the bot needs an answer")
            live = next(agent for agent in request("/api/workspace")["agents"]
                        if agent["state"] == "live" and agent.get("template") == "goal-agent")
            request(f"/api/agents/{live['address']}/{live['created_ms']}/messages", {"text": "PERSON: use the shared vault"})
            finished = until(lambda: goal() if goal()["state"] == "completed" else None, what="the answered goal")
            assert finished["id"] == second["id"] and finished["iteration"] == 2, finished
            assert "The person replied in chat after you reported: Evidence for blocked" in seen.read_text()

            # Stop and Resume answer for what is there, and refuse what is not.
            request(f"/api/bots/{bot}/goal/stop", {}, status=409)
            request(f"/api/bots/{bot}/goal/resume", {}, status=409)
            plan.write_text(json.dumps(["no_progress", "no_progress", "complete"]))
            third = request(f"/api/bots/{bot}/goal", {"objective": "Speed up the report"}, status=201)["goal"]
            stalled = until(lambda: goal() if goal()["state"] == "waiting" else None, what="the stalled goal")
            assert stalled["pause"] == "stalled" and stalled["detail"].startswith("Two steps produced no new progress."), stalled
            until(lambda: any("Two steps produced no new progress" in body for _, body in Receiver.heard),
                  what="the alert that the goal stalled")
            assert request(f"/api/bots/{bot}/goal/resume", {})["goal"]["state"] == "queued"
            until(lambda: goal() if goal()["state"] == "completed" else None, what="the resumed goal")
            plan.write_text(json.dumps(["progress", "progress", "progress"]))
            fourth = request(f"/api/bots/{bot}/goal", {"objective": "Review the queue"}, status=201)["goal"]
            stopped = request(f"/api/bots/{bot}/goal/stop", {})["goal"]
            assert (stopped["id"], stopped["state"], stopped["detail"]) == (fourth["id"], "stopped", "Stopped by you."), stopped
            assert third["id"] < fourth["id"]

            # A session started without Auto that sits at a permission prompt would wait for the person for
            # ever. Turning Auto on ends it, so the bot's next message starts one in Auto. A session that was
            # started in Auto is left alone.
            stuck = "0e5c0de0-0000-4000-8000-00000000a002"
            request("/api/bots", {"bots": [{"id": bot, "name": "Goal QA", "template": "goal-agent"},
                                           {"id": stuck, "name": "Stuck QA", "template": "goal-agent"}]})
            assert request(f"/api/bot-agent-settings/{stuck}", {"auto_mode": False, "existing_agents": []})["auto_mode"] is False
            # A session is its bot's when it runs under the bot's registered agent name, as the app starts it.
            name = next(entry["agent_name"] for entry in request("/api/bots")["bots"] if entry["id"] == stuck)
            launched = request("/api/agents", {"name": name, "template": "goal-agent", "task": "ASK FOR PERMISSION",
                                               "workspace_id": stuck}, status=201)
            session = f"{launched['address']}/{launched['created_ms']}"
            def agent_of(address):
                return next(agent for agent in request("/api/workspace")["agents"]
                            if f"{agent['address']}/{agent['created_ms']}" == address)
            until(lambda: agent_of(session).get("status") == {"state": "blocked", "kind": "permission"},
                  what="the agent to wait at its prompt")
            other = f"{live['address']}/{live['created_ms']}"
            assert agent_of(other)["state"] == "live"
            assert request(f"/api/bot-agent-settings/{stuck}", {"auto_mode": True, "existing_agents": []})["auto_mode"] is True
            until(lambda: agent_of(session)["state"] != "live", what="the stuck session to end")
            assert request(f"/api/bot-agent-settings/{bot}", {"auto_mode": True, "existing_agents": []})["auto_mode"] is True
            assert agent_of(other)["state"] == "live", "a session started in Auto stays"

            # The AI programs of this server, for an app on another machine.
            programs = {program["id"]: program for program in request("/api/ais")["programs"]}
            assert set(programs) == {"claude", "codex", "opencode", "gemini", "antigravity"}, programs
            assert all(isinstance(program["installed"], bool) and "can_install" in program for program in programs.values())
            request("/api/ais/not-an-ai", {}, status=409)
            # With SWARMHUB_TEST_NPM=1 the server installs one AI it does not have with npm, into the scratch
            # folder, and registers it: afterwards a bot can run on it.
            if npm:
                wanted = next((program for program in programs.values() if program["can_install"]), None)
                assert wanted, ("npm is here, yet nothing can be installed", programs)
                assert not wanted["installed"] and not wanted["template_written"]
                # npm can take minutes on a small server.
                installed = request(f"/api/ais/{wanted['id']}/install", {}, timeout=630)
                after = next(program for program in installed["programs"] if program["id"] == wanted["id"])
                assert after["installed"] and after["template_written"] and after["path"].startswith(str(root / "npm/bin")), after
                assert any(template["name"] == wanted["template"] for template in request("/api/workspace")["templates"])
                print("npm installed and registered", wanted["id"], "at", after["path"])

            # With SWARMHUB_TEST_NTFY=1 one test line goes to a fresh random topic on ntfy.sh and is read back,
            # to see that the address format the settings suggest works. Nothing else is sent there.
            if os.environ.get("SWARMHUB_TEST_NTFY") == "1":
                topic = "swarmhub-test-" + secrets.token_hex(12)
                public = request("/api/alerts", {"address": f"https://ntfy.sh/{topic}", "test": True})
                assert public["test"] == "sent", public
                def arrived():
                    with urllib.request.urlopen(f"https://ntfy.sh/{topic}/json?poll=1", timeout=15) as response:
                        lines = [json.loads(line) for line in response.read().decode().splitlines() if line.strip()]
                    return [line for line in lines if line.get("event") == "message"]
                message = until(arrived, seconds=30, what="the line on ntfy.sh")[0]
                assert (message.get("title"), message.get("message")) == ("SwarmHub", "Alerts from this workspace arrive here."), message
                print("ntfy.sh delivered the test line")

            # Turning alerts off stops them.
            assert request("/api/alerts", {"address": ""}) == {"address": None}
            print("autonomy smoke passed:", len(Receiver.heard), "alerts,", len(said()), "bot lines")
        finally:
            if process:
                process.terminate()
                process.wait(timeout=5)
                process.stdout.close()
            subprocess.run([hc, "server", "stop"], env=core_env, cwd=root, capture_output=True, timeout=16)
            receiver.shutdown()


if __name__ == "__main__":
    smoke(*(str(Path(arg).absolute()) for arg in sys.argv[1:3]))
