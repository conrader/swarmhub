"""Fallback supervisor for the webhook receiver where no systemd user manager is reachable (Hermes run as a system
service, no lingering): one per box account, held by a lock file. It restarts `swarmctl webhook serve` with backoff and
appends the receiver's own output (its start line and any crash; requests are never logged) to
~/.hermes/swarmhub/logs/webhook-receiver.log. The marker file records that this account uses it, so the peer plugin
resumes it at every gateway start; removing the marker (`webhook receiver uninstall`) stops the receiver and the
supervisor within a couple of seconds. Only the supervisor's own child is ever signalled.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time

import swarm_store as store
from swarm_store import state

HERE = Path(__file__).resolve().parent


def paths():
    folder = state()
    return {"lock": folder / "webhook-receiver.lock", "marker": folder / "webhook-receiver.supervised",
            "log": folder / "logs/webhook-receiver.log"}


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
    """Record the fallback and start the supervisor unless one already runs (the lock makes a second one exit)."""
    marker = paths()["marker"]
    marker.write_text(json.dumps({"port": int(port), "python": python}) + "\n")
    if holder() is None:
        spawn(python, port)


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
            with p["log"].open("ab") as log:
                child = popen([python or sys.executable, "-B", str(HERE / "swarmctl"), "webhook", "serve", str(int(port))],
                              stdin=subprocess.DEVNULL, stdout=log, stderr=log)
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
            delay = 1 if time.monotonic() - began > 60 else min(delay * 2, 60)
            for _ in range(delay):
                if halted():
                    break
                sleep(1)
        lock.seek(0)
        lock.truncate()
    return 0


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(supervise(int(sys.argv[1]), python=sys.executable))
