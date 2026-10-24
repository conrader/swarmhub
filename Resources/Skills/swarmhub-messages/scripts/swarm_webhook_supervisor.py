"""Fallback supervisor for the webhook receiver where no systemd user manager is reachable (Hermes run as a system
service, no lingering): one per box account, held by a lock file. It restarts `swarmctl webhook serve` with backoff and
appends the receiver's own output (its start line and any crash; requests are never logged) to
~/.hermes/swarmhub/logs/webhook-receiver.log. The marker file records that this account uses it, so the peer plugin
resumes it at every gateway start; removing the marker (`webhook receiver uninstall`) stops the receiver and the
supervisor within a couple of seconds. A pidfile records the running receiver and the digest of the code it started
with; installing again after a skill update or on another port terminates that one receiver (its exact pid, checked against `ps`), and the
supervisor starts it again on the new code. A supervisor from before the pidfile records nothing: its receiver is found
as its one direct child running exactly that supervisor's receiver command, and restarted once if it started before the
code on disk appeared. Only the supervisor's own child is ever signalled.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import threading
import time

from swarm_intake import write_private
import swarm_store as store
from swarm_store import state

HERE = Path(__file__).resolve().parent
# The modules the receiver loads; their digest is in the unit and the pidfile, so a skill update restarts it.
CODE = ("swarmctl", "swarm_control.py", "swarm_webhook.py", "swarm_delivery.py", "swarm_store.py", "swarm_policy.py",
        "swarm_intake.py", "swarm_jobs.py", "swarm_lifecycle.py", "swarm_webhook_receiver.py", "swarm_webhook_supervisor.py",
        "swarm_alerts.py", "swarm_alerts_hermes.py", "swarm_alerts_seal.py", "swarm_alerts_service.py", "swarm_alerts_sinks.py")
# The command line spawn() gives every supervisor, before and after the pidfile: python -B <folder>/<this file> <port>.
SUPERVISOR = re.compile(r"\A(/\S+) -B (/\S+)/swarm_webhook_supervisor\.py (\d+)\Z")


def paths():
    folder = state()
    return {"lock": folder / "webhook-receiver.lock", "marker": folder / "webhook-receiver.supervised",
            "log": folder / "logs/webhook-receiver.log", "pid": folder / "webhook-receiver.pid"}


def digest(folder):
    hasher = hashlib.sha256()
    for name in CODE:
        try:
            hasher.update(name.encode() + b"\0" + (folder / name).read_bytes())
        except OSError:
            hasher.update(name.encode() + b"\0missing")
    return hasher.hexdigest()[:16]


def enabled():
    return paths()["marker"].exists()


def holder():
    """The running supervisor's pid (0 if unreadable) while one holds the lock, else None."""
    try:
        handle = paths()["lock"].open("r")
    except FileNotFoundError:
        return None
    with handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            text = handle.read().strip()
            return int(text) if text.isdigit() else 0
        fcntl.flock(handle, fcntl.LOCK_UN)
        return None


def spawn(python, port):
    # Detached in its own session and reaped while this process lives, like the delivery worker.
    store.spawn([python, "-B", str(Path(__file__).resolve()), str(int(port))])


def start(python, port):
    """Record the fallback and start the supervisor unless one already runs (the lock makes a second one exit); a
    running one whose receiver started on other code than its swarmctl folder now holds gets that receiver restarted."""
    marker = paths()["marker"]
    marker.write_text(json.dumps({"port": int(port), "python": python}) + "\n")
    if holder() is None:
        spawn(python, port)
    else:
        refresh()


def receiver_pid():
    """(pid, record) of the supervised receiver when its pidfile, the lock and `ps` all agree, else (None, record).
    `ps` must show that pid in the supervisor's own process group (the supervisor leads a session of its own), with the
    exact command line and start time the supervisor recorded: a recycled pid or anything else is never signalled."""
    try:
        record = json.loads(paths()["pid"].read_text())
        pid, supervisor = int(record["pid"]), holder()
    except (OSError, ValueError, KeyError, TypeError):
        return None, {}
    if not supervisor or pid <= 1 or pid == supervisor or not shows(pid, supervisor, " ".join(record.get("cmd", []))):
        return None, record
    if not record.get("start") or store.process_start(pid) != record["start"]:
        return None, record
    return pid, record


def ps(*args):
    return subprocess.run(["ps", "-ww", *args], stdin=subprocess.DEVNULL, capture_output=True, text=True).stdout


def shows(pid, group, cmd):
    """`ps -o pid,pgid,cmd` shows exactly this pid, in this process group, running exactly this command line."""
    return ps("-o", "pid=,pgid=,cmd=", "-p", str(pid)).strip().split(None, 2) == [str(pid), str(group), cmd]


def legacy_receiver():
    """(pid, command line, folder) of the receiver a pre-pidfile supervisor runs, else None. It is the supervisor's one
    direct child, in its process group, whose command line is exactly `<python> -B <folder>/swarmctl webhook serve
    <port>` for that supervisor's own python, folder and port. Nothing is matched by pattern alone."""
    supervisor = holder()
    if not supervisor or supervisor <= 1 or paths()["pid"].exists():
        return None
    rows = [row for row in (line.split(None, 3) for line in ps("-A", "-o", "pid=,ppid=,pgid=,cmd=").splitlines())
            if len(row) == 4]
    own = [row[3] for row in rows if row[0] == str(supervisor) and row[2] == str(supervisor)]
    match = SUPERVISOR.match(own[0]) if len(own) == 1 else None
    if not match:
        return None
    python, folder, port = match.groups()
    tail = f" -B {folder}/swarmctl webhook serve {port}"
    children = [(int(row[0]), row[3]) for row in rows if row[1] == row[2] == str(supervisor) and row[3].endswith(tail)
                and os.path.realpath(row[3][:-len(tail)]) == os.path.realpath(python)]
    return (*children[0], Path(folder)) if len(children) == 1 and children[0][0] > 1 else None


def started_before_code(pid, folder):
    """True unless the process surely started after the code in `folder` appeared: the newest ctime of its receiver
    modules, the folder and the skill folder the updater swaps in (a write or rename sets ctime; archived mtimes do
    not). `etimes` is whole seconds, so allow one. An unreadable age reads as False and nothing is signalled."""
    elapsed = ps("-o", "etimes=", "-p", str(pid)).strip()
    if not elapsed.isdigit():
        return False
    try:
        appeared = max(os.stat(path).st_ctime for path in [folder, folder.parent, *(folder / name for name in CODE)]
                       if path.exists())
    except OSError:
        return False
    return appeared > time.time() - int(elapsed) - 1


def refresh_legacy():
    """A pre-pidfile supervisor's receiver that started before the code on disk: SIGTERM to its exact pid, verified
    again with `ps` (same pid, group, command line and start time) just before. Its supervisor starts it on the new
    code, and that one has started after the code, so later installs leave it alone."""
    found = legacy_receiver()
    if found is None:
        return False
    pid, cmd, folder = found
    began = store.process_start(pid)
    if not began or not started_before_code(pid, folder):
        return False
    if not shows(pid, holder(), cmd) or store.process_start(pid) != began or paths()["pid"].exists():
        return False
    try:
        os.kill(pid, signal.SIGTERM)  # This receiver's exact pid only, never a group.
    except ProcessLookupError:
        return False
    return True


def refresh():
    """Terminate the running receiver when its code changed on disk since it started, or the marker names another port;
    the supervisor starts it again.
    True when a receiver was signalled."""
    if not paths()["pid"].exists():
        return refresh_legacy()
    pid, record = receiver_pid()
    if pid is None or len(record.get("cmd", [])) < 3:
        return False
    serving = record["cmd"][-1]
    if record.get("code") == digest(Path(record["cmd"][2]).parent) and str(marker_port(serving)) == serving:
        return False  # Same code and the marker's port (`receiver install --port` changes it): nothing to restart.
    try:
        os.kill(pid, signal.SIGTERM)  # This receiver's exact pid only, never a group.
    except ProcessLookupError:
        return False
    return True


def marker_port(default):
    try:
        return int(json.loads(paths()["marker"].read_text())["port"])
    except (OSError, ValueError, KeyError, TypeError):
        return default


def resume():
    """Gateway start: bring a recorded fallback back after a reboot. Never raises into the plugin."""
    try:
        marker = paths()["marker"]
        if marker.exists() and holder() is None:
            recorded = json.loads(marker.read_text())
            spawn(recorded.get("python") or sys.executable, recorded.get("port") or 8745)
    except Exception:  # noqa: BLE001  A malformed marker must never fail the gateway's plugin load.
        pass


def stop():
    paths()["marker"].unlink(missing_ok=True)


def supervise(port, python=None, sleep=time.sleep, popen=subprocess.Popen):
    p = paths()
    p["log"].parent.mkdir(mode=0o700, exist_ok=True)
    stopping = []
    if threading.current_thread() is threading.main_thread():
        signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    halted = lambda: bool(stopping) or not p["marker"].exists()  # noqa: E731
    with p["lock"].open("a+") as lock:
        for attempt in range(5):  # holder() takes the lock for an instant; only a lasting holder is another supervisor.
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if attempt == 4:
                    return 0  # One supervisor per account.
                time.sleep(0.05)
        lock.seek(0)
        lock.truncate()
        lock.write(str(os.getpid()))
        lock.flush()
        delay = 1
        while not halted():
            began = time.monotonic()
            if p["log"].exists() and p["log"].stat().st_size > 1_000_000:
                os.replace(p["log"], p["log"].with_name(p["log"].name + ".1"))  # A crash loop keeps two small files.
            port = marker_port(port)  # A port changed by a later install applies from the next start.
            argv = [python or sys.executable, "-B", str(HERE / "swarmctl"), "webhook", "serve", str(int(port))]
            code = digest(HERE)  # before the start: a change while it starts reads as changed, so it is restarted
            with p["log"].open("ab") as log:
                child = popen(argv, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
                write_private(p["pid"], json.dumps({"pid": child.pid, "start": store.process_start(child.pid),
                                                    "cmd": argv, "code": code}).encode())
                while child.poll() is None:
                    if halted():
                        child.terminate()
                        try:
                            child.wait(10)
                        except subprocess.TimeoutExpired:
                            child.kill()
                            child.wait()
                        break
                    sleep(1)
            p["pid"].unlink(missing_ok=True)
            delay = 1 if time.monotonic() - began > 60 else min(delay * 2, 60)
            for _ in range(delay):
                if halted():
                    break
                sleep(1)
        p["pid"].unlink(missing_ok=True)
        lock.seek(0)
        lock.truncate()
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(supervise(int(sys.argv[1]), python=sys.executable))
