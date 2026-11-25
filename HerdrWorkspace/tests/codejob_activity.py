"""Exercise the shipped probe against a private, gated wrapper and native executable.

--runner uses the installed runner's real launch, supervise and status writer.
--bridge exercises GET /api/workspace through a scratch Core RPC peer.
"""
import argparse
import base64
import contextlib
import fcntl
import json
import os
from pathlib import Path
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request

PROBE = (Path(__file__).resolve().parents[1] / "src/codejob_activity/probe.py").read_text()
OWNER = "00112233-4455-6677-8899-aabbccddeeff"
OTHER = "ffeeddcc-bbaa-9988-7766-554433221100"
TOKEN = "a" * 64
WRAPPER = """
import fcntl, pathlib, subprocess, sys
with open('gate', 'r') as gate:
    pathlib.Path('waiting').touch()
    fcntl.flock(gate, fcntl.LOCK_EX)
subprocess.run([sys.argv[1]], check=True)
"""
# Keep all children bounded and model-free. Both gates release on test failure.
WORKER = """
#include <fcntl.h>
#include <unistd.h>
int main(void) {
    close(open("working", O_WRONLY|O_CREAT, 0600));
    for (int i = 0; i < 3000 && access("finish", F_OK); ++i) usleep(50000);
    return 0;
}
"""


def wait(check):
    for _ in range(300):
        if check():
            return
        time.sleep(.05)
    raise AssertionError("fixture transition timed out")


def start_token(pid):
    if sys.platform == "darwin":
        return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                                       env={"LC_ALL": "C"}).decode().strip()
    return int(Path("/proc/%d/stat" % pid).read_text().rsplit(")", 1)[1].split()[19])


def save(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value))
    tmp.chmod(0o600)
    tmp.replace(path)


@contextlib.contextmanager
def job(root, scope, runner):
    work = Path(scope["owners"][0]["workdir"])
    work.mkdir()
    worker = scope["executables"]["codex"]
    subprocess.run(["cc", "-x", "c", "-", "-o", worker], input=WORKER.encode(), check=True)
    gate = (work / "gate").open("w")
    fcntl.flock(gate, fcntl.LOCK_EX)
    cmd = [sys.executable, "-I", "-c", WRAPPER, worker]
    directory = Path(scope["root"], "Swarmhub")
    env = {"HOME": str(root), "PATH": "/usr/bin:/bin", "LC_ALL": "C",
           "SB_CODEJOB_WORKROOT": scope["root"], "SB_CODEJOB_HOST": scope["runner_host"]}
    child = None
    try:
        if runner:
            # Substitute only the process-management and external delivery boundaries.
            # Never signal process groups, run a real provider, or send completion wakes.
            launch = """
import pathlib, runpy, subprocess, sys
runner = runpy.run_path(str(pathlib.Path(sys.argv[1]).resolve()))
runner['job_process'].GroupPopen = subprocess.Popen
runner['supervise'].__globals__['send_record'] = lambda *a: 'dormant'
sys.exit(runner['main'](sys.argv[2:]))
"""
            subprocess.run([sys.executable, "-I", "-B", "-c", launch, runner, "--agent", "Swarmhub",
                            "--slug", "sensitive-fixture-slug", "--workdir", str(work), "--"] + cmd,
                           env=env, cwd=root, stdout=subprocess.DEVNULL, check=True, timeout=15)
            status, = directory.glob("*.json")
        else:
            directory.mkdir(mode=0o700, parents=True)
            child = subprocess.Popen(cmd, cwd=work, env=env)
            status = directory / "20261125T060000Z-sensitive-fixture-slug.json"
            save(status, {"tool": "sb-codejob", "host": scope["runner_host"], "agent": "Swarmhub",
                          "pid": child.pid, "supervisor_pid": os.getpid(), "pid_starttime": start_token(child.pid),
                          "supervisor_starttime": start_token(os.getpid()), "started": "2026-11-25T06:00:00+00:00",
                          "boot_id": None if sys.platform == "darwin" else Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                          "workdir": str(work), "log": str(status.with_suffix(".log")), "cmd": cmd,
                          "primary_tool": None, "ended": None, "exit_code": None})
        wait((work / "waiting").exists)
        yield status, gate
    finally:
        gate.close()
        (work / "finish").touch()
        if child:
            child.wait(timeout=10)
            rec = json.loads(status.read_text())
            save(status, dict(rec, ended="2026-11-25T06:01:00+00:00", exit_code=0))
        elif runner and directory.exists():
            paths = list(directory.glob("*.json"))
            if paths:
                wait(lambda: json.loads(paths[0].read_text()).get("ended") is not None)


@contextlib.contextmanager
def bridge_reads(binary, root, host):
    """Only emulate Core's transport. Execute the bridge's exact, fixed argv on scratch data."""
    calls = []
    peer = {"state": "connected", "target": "fixture@host"}

    class RPC(socketserver.StreamRequestHandler):
        def handle(self):
            request = json.loads(self.rfile.readline())
            method, params = request["method"], request["params"]
            if method == "hello":
                result = dict(core={"id": "test"}, version="test", generation=1, methods=[
                    "templates.list", "terminal.get", "terminal.list", "terminal.run", "terminal.read",
                    "terminal.send", "terminal.interrupt", "terminal.kill", "machine.exec"])
            elif method == "terminal.list":
                result = {"terminals": []}
            elif method == "templates.list":
                result = {"templates": []}
            elif method == "machine.list":
                result = {"machines": [dict(name="worker", **peer)]}
            elif method == "machine.exec":
                argv = params["argv"]
                assert argv == ["/usr/bin/python3", "-I", "-B", "-c", PROBE, argv[-1]]
                assert json.loads(argv[-1]) == host["scope"] and params["on"] == "worker"
                assert params["cwd"] == "/" and "line" not in params
                calls.append(method)
                p = subprocess.run(argv, cwd="/", capture_output=True, timeout=4)
                result = dict(code=p.returncode, stdout=base64.b64encode(p.stdout).decode(),
                              stderr="", truncated=False, timed_out=False, ms=1)
            else:
                self.wfile.write((json.dumps(dict(jsonrpc="2.0", id=1, error=dict(code=-32601, message="unsupported"))) + "\n").encode())
                return
            self.wfile.write((json.dumps(dict(jsonrpc="2.0", id=1, result=result)) + "\n").encode())

    with socketserver.UnixStreamServer(str(root / "core.sock"), RPC) as core:
        threading.Thread(target=core.serve_forever, daemon=True).start()
        env = dict(HOME=str(root), PATH="/usr/bin:/bin", HC_SOCKET=core.server_address,
                   SWARMHUB_DATA_DIR=str(root / "db"), SWARMHUB_PORT="0", SWARMHUB_ACCESS_TOKEN=TOKEN,
                   SWARMHUB_CODEJOB_HOSTS=json.dumps([host]))
        bridge = subprocess.Popen([binary], env=env, cwd=root, stdout=subprocess.PIPE, text=True)
        try:
            url = bridge.stdout.readline().strip().split()[-1].rstrip("/")
            assert url.startswith("http://127.0.0.1:")
            def read(state="connected"):
                peer.update(state=state, target="other@host" if state == "replaced" else "fixture@host")
                if state == "replaced":
                    peer["state"] = "connected"
                before = len(calls)
                request = urllib.request.Request(url + "/api/workspace?codejobs=true",
                                                 headers={"Authorization": "Bearer " + TOKEN})
                opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                with opener.open(request, timeout=10) as reply:
                    roster = json.load(reply)
                assert len(calls) == before + int(state == "connected")
                return roster
            yield read
        finally:
            bridge.terminate()
            bridge.wait(timeout=5)
            core.shutdown()


@contextlib.contextmanager
def direct_reads(host):
    def read(state="connected"):
        if state == "connected":
            p = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", PROBE, json.dumps(host["scope"])],
                               check=True, capture_output=True)
            reading = json.loads(p.stdout)
        else:
            reading = dict(jobs=[], complete=False)
        return dict(core="fixture", templates=[], agents=[], codejob_activity=[dict(host=host["id"], **reading)])
    yield read


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", type=lambda s: str(Path(s).resolve()))
    parser.add_argument("--runner", type=lambda s: str(Path(s).resolve()))
    parser.add_argument("--write-rosters", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp).resolve()
        work = root / "project"
        scope = dict(hostname=socket.gethostname(), runner_host="fixture", root=str(root / "records"),
                     executables={"codex": str(root / "fixture-worker")}, owners=[
                         dict(agent="Swarmhub", workdir=str(work), bot_id=OWNER),
                         dict(agent="Swarmhub", workdir=str(work / "shared"), bot_id=OTHER)])
        host = dict(id="fixture-host", machine="worker", target="fixture@host", scope=scope)
        rosters = []
        with bridge_reads(args.bridge, root, host) if args.bridge else direct_reads(host) as read:
            def snapshot(state="connected"):
                value = read(state)
                assert value["agents"] == []
                wire = json.dumps(value["codejob_activity"])
                assert all(key not in wire for key in ("sensitive-fixture", str(root), "kill_guard", "workdir", "cmd"))
                rosters.append(value)
                item, = value["codejob_activity"]
                return item
            with job(root, scope, args.runner) as (status, gate):
                rec = json.loads(status.read_text())
                assert rec["primary_tool"] is None and rec["pid_starttime"] and rec["ended"] is None
                first = snapshot()
                waiting, = first["jobs"]
                assert first["complete"] and waiting["state"] in ("wrapper", "queued") and waiting["provider"] is None
                gate.close()
                wait((work / "working").exists)
                item = snapshot()
                working, = item["jobs"]
                assert item["complete"] and working == dict(waiting, state="working", provider="codex", owner=OWNER)
                save(status, dict(rec, pid_starttime="stale"))
                assert snapshot()["jobs"] == [dict(waiting, state="unknown", provider=None)]
                save(status, dict(rec, workdir=str(work / "shared")))
                ambiguous = snapshot()
                assert not ambiguous["complete"] and not ambiguous["jobs"]
                save(status, rec)
                for state in ("unreachable", "replaced"):
                    failed = snapshot(state)
                    assert not failed["complete"] and failed["jobs"] == []
                assert snapshot()["jobs"] == [working]
            ended = snapshot()
            assert ended["complete"] and ended["jobs"] == []
        if args.write_rosters:
            args.write_rosters.write_text(json.dumps(rosters))
        print("PASS: wrapper (%s), live descendant, PID reuse, ambiguous scope, offline, replaced target, recovery, completion" % waiting["state"])


if __name__ == "__main__":
    main()
