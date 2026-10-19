"""Shared state folder, SQLite schema and process helpers for the SwarmHub control modules.

Lowest layer: imported by swarm_policy, swarm_delivery and swarm_jobs; imports none of them.
"""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import threading
import time

NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*\Z", re.ASCII)

# Columns added after the first schema; applied with ALTER TABLE when missing.
ACTION_COLUMNS = {"decided_by": "TEXT", "decided_pid": "INTEGER", "decided_at": "REAL",
                  "pid_start": "TEXT", "launched": "TEXT"}


def spawn(command):
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    # Reap while a long-lived gateway owns us; an exited launcher leaves the
    # detached child to the OS, with durable state for the next worker.
    threading.Thread(target=child.wait, daemon=True).start()
    return child.pid


def process_start(pid):
    """The kernel start time of a process, so a recycled pid is not mistaken for ours."""
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True, text=True)
    return result.stdout.strip()


def spawn_recorded(command):
    """Spawn and return (pid, start time); the pair identifies the process, not the pid alone."""
    pid = spawn(command)
    return pid, process_start(pid)


def state():
    folder = Path.home() / ".hermes/swarmhub"
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    folder.chmod(0o700)
    return folder


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


@contextmanager
def database():
    path = state() / "control.sqlite"
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    path.chmod(0o600)
    db = sqlite3.connect(path, timeout=10)
    try:
        db.row_factory = sqlite3.Row
        db.executescript("""
          CREATE TABLE IF NOT EXISTS settings(id INTEGER PRIMARY KEY, revision INTEGER, body TEXT);
          CREATE TABLE IF NOT EXISTS subscribers(profile TEXT PRIMARY KEY, revision INTEGER);
          CREATE TABLE IF NOT EXISTS policy_turns(profile TEXT, session TEXT, turn TEXT, revision INTEGER,
            PRIMARY KEY(profile,session,turn));
          CREATE TABLE IF NOT EXISTS actions(id TEXT PRIMARY KEY, fingerprint TEXT, intent TEXT,
            spec TEXT, gate TEXT, status TEXT, pid INTEGER, error TEXT, created REAL);
          CREATE TABLE IF NOT EXISTS denials(intent TEXT PRIMARY KEY, fingerprint TEXT);
          CREATE TABLE IF NOT EXISTS deliveries(id TEXT PRIMARY KEY, sender TEXT, target TEXT,
            text TEXT, task TEXT, status TEXT, attempts INTEGER DEFAULT 0,
            due REAL DEFAULT 0, error TEXT);
          CREATE TABLE IF NOT EXISTS receipts(target TEXT, id TEXT, status TEXT, token TEXT,
            expires REAL, session TEXT, turn TEXT, PRIMARY KEY(target,id));
          CREATE TABLE IF NOT EXISTS approval_runtime(id INTEGER PRIMARY KEY CHECK(id=1), identity TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_receipts(task TEXT PRIMARY KEY, binding TEXT NOT NULL,
            approved INTEGER NOT NULL, receipt TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_nonces(nonce TEXT PRIMARY KEY, digest TEXT NOT NULL, expires REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS webhooks(profile TEXT, routine TEXT, slug TEXT, key_file TEXT,
            created REAL, rotated REAL, fired INTEGER DEFAULT 0, PRIMARY KEY(profile,routine));
        """)
        present = {row[1] for row in db.execute("PRAGMA table_info(actions)")}
        for column, kind in ACTION_COLUMNS.items():
            if column not in present:
                try:
                    db.execute(f"ALTER TABLE actions ADD COLUMN {column} {kind}")
                except sqlite3.OperationalError:
                    if column not in {row[1] for row in db.execute("PRAGMA table_info(actions)")}:
                        raise
        with db:
            yield db
    finally:
        db.close()


def profile_exists(profile):
    return isinstance(profile, str) and bool(NAME.fullmatch(profile)) and (profile == "default" or
        (Path.home() / ".hermes/profiles" / profile).is_dir())


def invoking_profile(environ=None):
    """The profile whose gateway runs this process, read from HERMES_HOME; never from argv.

    Hermes sets HERMES_HOME per profile gateway and tool subprocesses inherit it.
    Returns None outside a gateway (plain terminal) or for an unknown profile.
    """
    env = os.environ if environ is None else environ
    raw = env.get("HERMES_HOME", "").strip()
    if not raw:
        return None
    try:
        home = Path(os.path.expandvars(raw)).expanduser().resolve()
        base = (Path.home() / ".hermes").resolve()
    except (OSError, RuntimeError):
        return None
    if home == base:
        return "default"
    if home.parent == base / "profiles" and profile_exists(home.name):
        return home.name
    return None


def terminate(pid):
    # Used only with child PIDs held by bot-msg, not caller-supplied task metadata.
    pairs = subprocess.check_output(["ps", "-A", "-o", "pid=", "-o", "ppid="], text=True)
    ids = {int(pid)}
    rows = [tuple(map(int, line.split())) for line in pairs.splitlines()]
    while True:
        expanded = ids | {child for child, parent in rows if parent in ids}
        if expanded == ids:
            break
        ids = expanded
    for child in reversed(sorted(ids)):
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(.1)
    for child in reversed(sorted(ids)):
        if process_alive(child):
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass


def process_alive(pid, start=None):
    """True when the pid is a live, non-zombie process; with ``start`` also the same incarnation."""
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat=", "-o", "lstart="], capture_output=True, text=True)
    line = result.stdout.strip()
    if not line or line.startswith("Z"):
        return False
    if start:
        return line.split(None, 1)[1:] == [start]
    return True
