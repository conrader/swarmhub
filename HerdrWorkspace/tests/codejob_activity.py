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
import shutil
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


def wait(check, description="fixture transition"):
    for _ in range(300):
        result = check()
        if result:
            return result
        time.sleep(.05)
    raise AssertionError(description + " timed out")


def start_token(pid):
    if sys.platform == "darwin":
        return subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "lstart="],
                                       env={"LC_ALL": "C"}, timeout=5).decode().strip()
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
    subprocess.run(["cc", "-x", "c", "-", "-o", worker], input=WORKER.encode(), check=True, timeout=30)
    gate = (work / "gate").open("w")
    fcntl.flock(gate, fcntl.LOCK_EX)
    cmd = [sys.executable, "-I", "-c", WRAPPER, worker]
    directory = Path(scope["root"], "Swarmhub")
    env = {"HOME": str(root), "PATH": "/usr/bin:/bin", "LC_ALL": "C",
           "SB_CODEJOB_WORKROOT": scope["root"], "SB_CODEJOB_HOST": scope["runner_host"]}
    child = None
    try:
        if runner:
            # The fixture worker joins before its wrapper exits. Suppress only post-exit
            # group cleanup and the external completion wake. Keep runner topology.
            launch = """
import os, pathlib, runpy, sys
os.umask(0o077)
runner = runpy.run_path(str(pathlib.Path(sys.argv[1]).resolve()))
def finished(proc):
    assert proc.poll() is not None
runner['job_process'].stop_group = finished
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
        timeout = 5

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
        try:
            with running_bridge(binary, root, core.server_address, host) as get_roster:
                def read(state="connected"):
                    peer.update(state=state, target="other@host" if state == "replaced" else "fixture@host")
                    if state == "replaced":
                        peer["state"] = "connected"
                    before = len(calls)
                    roster = get_roster()
                    assert len(calls) == before + int(state == "connected")
                    return roster
                yield read
        finally:
            core.shutdown()


@contextlib.contextmanager
def running_bridge(binary, root, endpoint, host):
    env = dict(HOME=str(root), PATH="/usr/bin:/bin", HC_SOCKET=str(endpoint),
               SWARMHUB_DATA_DIR=str(root / "db"), SWARMHUB_PORT="0", SWARMHUB_ACCESS_TOKEN=TOKEN,
               SWARMHUB_CODEJOB_HOSTS=json.dumps([host]))
    banner = root / "bridge.stdout"
    with banner.open("w") as stdout:
        bridge = subprocess.Popen([binary], env=env, cwd=root, stdout=stdout)
    try:
        def startup_line():
            if bridge.poll() is not None:
                raise RuntimeError("fixture bridge exited during startup (status %d)" % bridge.returncode)
            line, newline, _ = banner.read_bytes().partition(b"\n")
            return line.decode() if newline else None
        url = wait(startup_line, "fixture bridge startup").split()[-1].rstrip("/")
        assert url.startswith("http://127.0.0.1:")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        def read():
            request = urllib.request.Request(url + "/api/workspace?codejobs=true",
                                             headers={"Authorization": "Bearer " + TOKEN})
            with opener.open(request, timeout=10) as reply:
                return json.load(reply)
        yield read
    finally:
        bridge.terminate()
        try:
            bridge.wait(timeout=5)
        except subprocess.TimeoutExpired:
            bridge.kill()
            bridge.wait(timeout=5)
            raise


@contextlib.contextmanager
def local_core_reads(binary, hc, root, host):
    root.mkdir()
    endpoint = root / "core.sock"
    env = dict(HOME=str(root), PATH="/usr/bin:/bin", HC_SOCKET=str(endpoint), HC_SESSION="activity-test",
               XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"),
               XDG_RUNTIME_DIR=str(root / "run"))
    (root / "run").mkdir(mode=0o700)
    def server(action):
        subprocess.run([hc, "server", action], cwd=root, env=env, check=True, timeout=15, capture_output=True)
    server("start")
    try:
        with running_bridge(binary, root, endpoint, dict(id=host["id"], scope=host["scope"])) as read:
            yield read
    finally:
        server("stop")


@contextlib.contextmanager
def direct_reads(host):
    def read(state="connected"):
        if state == "connected":
            p = subprocess.run(["/usr/bin/python3", "-I", "-B", "-c", PROBE, json.dumps(host["scope"])],
                               check=True, capture_output=True, timeout=5)
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
    parser.add_argument("--integration", action="store_true",
                        help="Require the installed runner, candidate bridge and a private Herdr Core")
    parser.add_argument("--check-prerequisites", action="store_true",
                        help="Check integration executables without starting them; exit 77 if unavailable")
    parser.add_argument("--core", type=lambda s: str(Path(s).resolve()))
    args = parser.parse_args()
    if args.check_prerequisites and not args.integration:
        parser.error("--check-prerequisites requires --integration")
    if args.integration:
        target = Path(os.environ.get("CARGO_TARGET_DIR", Path(__file__).resolve().parents[1] / "target"))
        args.bridge = args.bridge or os.environ.get("SWARMHUB_TEST_BRIDGE")
        defaults = {"bridge": str(target / "debug/swarmhub-herdr"), "runner": "sb-codejob", "core": "hc"}
        missing = []
        for name, default in defaults.items():
            supplied = getattr(args, name)
            path = supplied if supplied is not None else shutil.which(default)
            if path and Path(path).is_file() and os.access(path, os.X_OK):
                setattr(args, name, str(Path(path).absolute()))
            elif supplied is not None:
                parser.error("configured --%s is not executable: %s" % (name, supplied))
            else:
                missing.append(default)
        if missing:
            reason = "missing detached integration prerequisite(s): " + ", ".join(missing)
            if args.check_prerequisites:
                print("SKIP: " + reason)
                return 77
            parser.error(reason)
        if args.check_prerequisites:
            return 0
    if args.core and not args.bridge:
        parser.error("--core requires --bridge")
    if args.write_rosters and not args.bridge:
        parser.error("roster capture requires --bridge")
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
            native = local_core_reads(args.bridge, args.core, root / "native", host) if args.core else contextlib.nullcontext()
            with native as local_read, job(root, scope, args.runner) as (status, gate):
                rec = json.loads(status.read_text())
                assert rec["primary_tool"] is None and rec["pid_starttime"] and rec["ended"] is None
                first = snapshot()
                waiting, = first["jobs"]
                assert first["complete"] and waiting["state"] in ("wrapper", "queued") and waiting["provider"] is None
                if sys.platform.startswith("linux"):
                    assert waiting["state"] == "queued", waiting["state"]
                if args.runner:
                    assert os.getsid(rec["pid"]) == rec["pid"] == os.getpgid(rec["pid"])
                gate.close()
                wait((work / "working").exists)
                item = snapshot()
                working, = item["jobs"]
                assert item["complete"] and working == dict(waiting, state="working", provider="codex", owner=OWNER)
                if local_read:
                    # Real local Core receives the full fixed -c argument, without "on".
                    assert local_read()["codejob_activity"] == [item]
                save(status, dict(rec, pid_starttime=None))
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
            # A supervisor may exit before filling in ended. Restore its last live
            # record after the fixture exits, then simulate reuse and a previous boot.
            reused = start_token(os.getpid()) - 1 if sys.platform.startswith("linux") else "Thu Jan  1 00:00:01 1970"
            for stale in [rec, dict(rec, pid=os.getpid(), pid_starttime=reused)]:
                save(status, stale)
                gone = read()["codejob_activity"][0]
                assert gone["complete"] and not gone["jobs"]
            for n in range(257):
                orphan = status.with_name("20261125T060000Z-old-wrapper-%d.json" % n)
                save(orphan, dict(rec, log=str(orphan.with_suffix(".log"))))
            after_orphans = read()["codejob_activity"][0]
            assert after_orphans["complete"] and not after_orphans["jobs"]
            if sys.platform.startswith("linux"):
                save(status, dict(rec, boot_id="00000000-0000-4000-8000-000000000000"))
                gone = read()["codejob_activity"][0]
                assert gone["complete"] and not gone["jobs"]
        if args.write_rosters:
            args.write_rosters.write_text(json.dumps(rosters))
        print("PASS %s + %s: %s, live descendant, unknown identity, ambiguous scope, completion and 257 orphan records"
              % ("installed runner" if args.runner else "fixture record",
                 "workspace GET" if args.bridge else "direct probe", waiting["state"]))
        if args.bridge:
            print("PASS remote workspace GET: offline, replaced target and recovery")
        if args.core:
            print("PASS local workspace GET: private Herdr Core machine.exec")


if __name__ == "__main__":
    sys.exit(main())
