"""Set up a Mac for real, as the app does for "This Mac": `service install` with a job name of its own, an
isolated Herdr Core, scratch folders, a local releases folder and a throwaway release key. macOS only. No model
calls; nothing of the account's own setup is read or changed, and everything it made is removed at the end.

    python3 tests/service_smoke.py "$(command -v hc)" [BUILDS]

It covers: install and what it reports, the access key, the starter templates for stand-in agent programs, the
server being started again by launchd when it is ended, an update under launchd (the same process becomes the new
version), a new version that cannot start, a new version that hangs (the watcher has launchd start the previous
one), and remove. BUILDS keeps the check builds between runs (`update_smoke.py` makes the same ones).
"""

import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from update_smoke import Releases, Server, build, free_port  # noqa: E402

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey  # noqa: E402

LABEL = "com.swarmhub.service-smoke"


def main(hc, builds):
    assert sys.platform == "darwin", "service install sets up a Mac"
    key = build(builds, Ed25519PrivateKey.generate())
    # A short folder name: Herdr Core's sockets live under it, and macOS allows a socket path 103 bytes.
    with tempfile.TemporaryDirectory(prefix="shsvc-", dir="/tmp") as temp:
        root = Path(temp).resolve()
        for name in ("state", "config", "bin", "agents", "tools"):
            (root / name).mkdir(mode=0o700)
        # Stand-ins for the agent programs, found through PATH: only that they are there matters here.
        for name in ("claude", "codex"):
            (root / "tools" / name).write_text("#!/bin/sh\nexec /bin/sleep 600\n")
            (root / "tools" / name).chmod(0o755)
        releases = Releases(root / "releases", builds, key)
        program = root / "bin/swarmhub-herdr"
        program.write_bytes((builds / "0.2.0").read_bytes())
        program.chmod(0o755)
        port = free_port()
        job = Path.home() / "Library/LaunchAgents" / f"{LABEL}.plist"
        # Herdr Core's command beside them, so the folders the service looks in hold nothing of the account's own.
        (root / "tools/hc").symlink_to(hc)
        env = {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin", "SWARMHUB_SERVICE_PATH": f"{root / 'tools'}:/usr/bin:/bin",
               "HC_SESSION": "shsvc", "XDG_STATE_HOME": str(root / "state"), "XDG_CONFIG_HOME": str(root / "config"),
               "SWARMHUB_AGENT_CWD": str(root / "agents"), "SWARMHUB_UPDATE_FEED": releases.address,
               }

        def service(*args, ok=True):
            ran = subprocess.run([str(program), "service", *args, "--label", LABEL, "--json"], env=env,
                                 capture_output=True, text=True, timeout=180)
            answer = json.loads(ran.stdout)
            assert answer["ok"] == ok, (ran.stdout, ran.stderr)
            return answer

        def core(*args):
            return subprocess.run([str(root / "tools/hc"), *args], env=env, capture_output=True, text=True, timeout=60).stdout

        def job_pid():
            printed = subprocess.run(["launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True, text=True)
            pids = [line.split("=")[1].strip() for line in printed.stdout.splitlines() if line.strip().startswith("pid = ")]
            return int(pids[0]) if pids else None

        try:
            before = service("status")
            assert not before["service"]["installed"] and not before["service"]["loaded"] and not before["access_key"]
            assert before["can_install"] and before["core"]["installed"] and before["port"] == 8787

            # A port something else holds is refused before anything is installed.
            import socket
            with socket.socket() as taken:
                taken.bind(("127.0.0.1", 0))
                taken.listen()
                refused = service("install", "--port", str(taken.getsockname()[1]), ok=False)
                assert refused["kind"] == "port_busy", refused
            assert not job.exists()

            installed = service("install", "--port", str(port))
            assert installed["port"] == port and installed["access_key"]
            assert installed["service"] == {**installed["service"], "installed": True, "loaded": True, "answers": True}
            assert installed["core"]["running"] and installed["core"]["socket"].startswith(str(root / "state"))
            assert {entry["id"]: entry["installed"] for entry in installed["programs"]} == {"claude": True, "codex": True}
            assert any("access key" in line for line in installed["did"]), installed["did"]
            token_file = root / "config/swarmhub-herdr/token"
            assert token_file.stat().st_mode & 0o777 == 0o600
            token = token_file.read_text().strip()
            server = Server(port, token)
            status = server.becomes("0.2.0")
            pid = status["pid"]
            assert pid == job_pid() and status["can_update"]
            code, workspace = server.call("/api/workspace")
            names = sorted(template["name"] for template in workspace["templates"])
            assert code == 200 and workspace["core"] and names == ["swarmhub-claude", "swarmhub-codex"], workspace
            assert all(template["error"] is None and template["models"] if template["name"] == "swarmhub-claude"
                       else template["discover_models"] for template in workspace["templates"]), workspace
            # An agent started through the server gets the person's PATH, so its program is found.
            code, agent = server.call("/api/agents", {"name": "check", "template": "swarmhub-claude", "warm": True})
            assert code == 201 and agent["state"] == "live", agent
            time.sleep(1)
            assert "check" in core("ls"), core("ls")

            # Installing again changes nothing a person made: the same key, the same templates.
            again = service("install", "--port", str(port))
            assert token_file.read_text().strip() == token and not any("template" in line for line in again["did"])
            pid = server.becomes("0.2.0")["pid"]

            # Ended from outside, the server is started again by launchd, and the agent is still there.
            os.kill(pid, signal.SIGKILL)
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline and server.version() != "0.2.0":
                time.sleep(0.5)
            pid, old = server.becomes("0.2.0")["pid"], pid
            assert pid != old and pid == job_pid() and "check" in core("ls")

            # An update: the same process becomes the new version, and launchd still knows it.
            releases.publish("0.2.1")
            code, answer = server.call("/api/update/apply", {"version": "0.2.1"})
            assert code == 200 and answer["state"] == "restarting", answer
            assert server.becomes("0.2.1", last="done")["pid"] == pid == job_pid()

            # A new version that cannot start gives the process back.
            releases.publish("0.2.2")
            code, answer = server.call("/api/update/apply", {"version": "0.2.2"})
            assert code == 200, answer
            status = server.becomes("0.2.1", last="rolled_back")
            assert status["pid"] == pid == job_pid()

            # A new version that hangs: the watcher puts the previous one back and has launchd start it.
            if os.environ.get("SWARMHUB_UPDATE_SKIP_HANG") != "1":
                releases.publish("0.2.4")
                code, answer = server.call("/api/update/apply", {"version": "0.2.4"})
                assert code == 200 and answer["to"] == "0.2.4", answer
                print("waiting for the watcher (about 90 s)…", flush=True)
                status = server.becomes("0.2.1", within=150, last="rolled_back")
                assert status["pid"] != pid and status["pid"] == job_pid(), "launchd runs the previous version"
                assert "did not start serving in time" in status["last"]["error"], status
                time.sleep(12)
                assert server.version() == "0.2.1" and status["pid"] == job_pid(), "and only one server"
            assert "check" in core("ls"), "the agent ran through all of it"

            removed = service("remove")
            assert any("Stopped" in line for line in removed["did"]) and any("agents" in line for line in removed["did"]), removed
            assert not job.exists() and job_pid() is None and not program.exists() and not token_file.exists()
            assert not list((root / "config/herdr-core/templates").glob("*.md"))
            assert server.version() is None and "check" not in core("ls")
            assert (root / "state/swarmhub-herdr/workspace.sqlite3").exists(), "conversations stay"
            print("service smoke: ok")
        finally:
            subprocess.run(["launchctl", "bootout", f"gui/{os.getuid()}/{LABEL}"], capture_output=True)
            job.unlink(missing_ok=True)
            core("server", "stop")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    keep = Path(sys.argv[2]) if len(sys.argv) == 3 else None
    with tempfile.TemporaryDirectory(prefix="swarmhub-update-builds-") as scratch:
        main(sys.argv[1], keep or Path(scratch))
