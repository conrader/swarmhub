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
import sys
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
          CREATE TABLE IF NOT EXISTS cancellation_markers(task TEXT PRIMARY KEY);
          CREATE TABLE IF NOT EXISTS approval_runtime(id INTEGER PRIMARY KEY CHECK(id=1), identity TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_receipts(task TEXT PRIMARY KEY, binding TEXT NOT NULL,
            approved INTEGER NOT NULL, receipt TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_nonces(nonce TEXT PRIMARY KEY, digest TEXT NOT NULL, expires REAL NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_devices(key_id TEXT PRIMARY KEY, public TEXT NOT NULL,
            profiles TEXT NOT NULL, revoked INTEGER NOT NULL, enrolled INTEGER NOT NULL, label TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_mode(id INTEGER PRIMARY KEY CHECK(id=1), required INTEGER NOT NULL,
            changed INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_challenges(nonce TEXT PRIMARY KEY, key_id TEXT NOT NULL,
            task TEXT NOT NULL, issued INTEGER NOT NULL, expires INTEGER NOT NULL, used INTEGER NOT NULL,
            binding TEXT NOT NULL);
          CREATE TABLE IF NOT EXISTS approval_expired(nonce TEXT PRIMARY KEY);
          CREATE TABLE IF NOT EXISTS approval_mode_changed(nonce TEXT PRIMARY KEY);
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
        # Durable outbox: filesystem effects happen only after the transaction commits.
        # A crash/write failure leaves rows to retry on the next database access;
        # the committed action status already prevents further managed work.
        pending = db.execute("SELECT task FROM cancellation_markers").fetchall()
        if pending:
            folder = state() / "cancelled"
            folder.mkdir(exist_ok=True, mode=0o700)
            for row in pending:
                (folder / row[0]).touch(mode=0o600)
            with db:
                db.executemany("DELETE FROM cancellation_markers WHERE task=?", [(row[0],) for row in pending])
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


def process_snapshot():
    """One ps view: pid -> (parent, process group, session, start time). Unknown identity fails closed."""
    try:
        listing = subprocess.check_output(
            ["ps", "-A", "-o", "pid=", "-o", "ppid=", "-o", "pgid=", "-o", "sess=", "-o", "lstart="],
            text=True, env=dict(os.environ, LC_ALL="C"))
        result = {}
        for line in listing.splitlines():
            fields = line.split()
            if len(fields) != 9:
                return {}
            pid, parent, group = map(int, fields[:3])
            result[pid] = (parent, group, fields[3], " ".join(fields[4:]))
        return result
    except (OSError, ValueError, subprocess.SubprocessError):
        return {}


def same_process(before, after, adopters=()):
    """Same incarnation and PGID/session; only explicitly allowed reparenting is accepted."""
    return bool(before and after and before[1:] == after[1:]
                and (before[0] == after[0] or after[0] in adopters))


def terminate(pid):
    # bot-msg invokes swarmctl for its STREAM_PID: that root is swarmctl's sibling, not its child.
    # Admit our descendants, or siblings in our own parent/group/session; never a foreign or ancestor root.
    if type(pid) is not int or pid <= 1 or pid == os.getpid():
        print(f"swarm_store: not signalling pid {pid!r}", file=sys.stderr)
        return
    rows = process_snapshot()
    me, parent = os.getpid(), os.getppid()
    parents = {child: row[0] for child, row in rows.items()}
    ancestors, up = set(), me
    while up not in ancestors and up > 0:
        ancestors.add(up)
        up = parents.get(up, 0)
    up, seen = pid, set()
    while up > 1 and up not in seen and up != me:
        seen.add(up)
        up = parents.get(up, 0)
    sibling = (parent > 1 and parents.get(me) == parent and parents.get(pid) == parent
               and rows[pid][1:3] == rows[me][1:3])
    if pid not in rows or pid in ancestors or not (up == me or sibling):
        print(f"swarm_store: not signalling pid {pid}: outside this process's child/sibling trees", file=sys.stderr)
        return
    ids = {pid}
    while True:
        expanded = ids | {child for child, parent in parents.items() if parent in ids}
        if expanded == ids:
            break
        ids = expanded
    ids = {child for child in ids if child > 1} - ancestors
    for child in reversed(sorted(ids)):
        try:
            os.kill(child, signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(.1)
    current = process_snapshot()
    for child in reversed(sorted(ids)):
        if same_process(rows.get(child), current.get(child), adopters=(1, me) if child != pid else ()):
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
