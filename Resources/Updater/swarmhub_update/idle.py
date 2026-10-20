"""Idle detection before a swap (CORE-PLAN.md §3.4, phase P2a): no running `code-job` and no running swarm job.

Both live in the box-wide SwarmHub state folder `<hermes home>/swarmhub/` (`code-job`: `S=$HOME/.hermes/swarmhub`;
`swarm_store.state()`), shared by every profile, so idleness is per box:
- `code-job` holds one of SLOTS slots as `slots/<i>.lock/` with its pid in `pid` (`try_slot`). A lock whose pid is
  alive is a running job. A lock without a pid file is a job that is starting, unless it is older than STARTING_GRACE
  (a job killed between `mkdir` and `echo $$`; code-job never reclaims such a lock, so it is ignored, not waited on).
- `swarm_jobs.py` records jobs in `control.sqlite` table `actions`: `status='running'` (pid may still be NULL while
  launching) and `status='cancelled'` whose pid is still alive (`tick` terminates those) are running.
The database is opened read-only (`mode=ro`); an unreadable database counts as busy, so doubt defers the swap.
Reading only: nothing here writes, signals (other than signal 0) or starts a process. Stdlib only, Python 3.8+.
"""

import os
import re
import sqlite3
import time

STARTING_GRACE = 120
DEFAULT_MAX_WAIT = 600
DEFAULT_POLL = 2.0
LOCK_NAME = re.compile(r"[0-9]+\.lock")


def pid_alive(pid):
    """True when `pid` names a live process (or one this user may not signal). Signal 0 only checks."""
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, OverflowError):  # a pid no process can have, as `kill -0` in code-job sees it
        return False
    except PermissionError:
        return True
    return True


def _read_pid(path):
    try:
        with open(path, "rb") as handle:
            text = handle.read(32).decode("ascii").strip()
    except (OSError, UnicodeDecodeError):
        return None
    return int(text) if text.isdigit() else None


def code_jobs(state, now=None):
    """Running code-job slots, as descriptions."""
    folder = os.path.join(state, "slots")
    try:
        names = sorted(os.listdir(folder))
    except FileNotFoundError:
        return []
    except OSError:
        return ["code-job slots unreadable"]
    now = time.time() if now is None else now
    busy = []
    for name in names:
        lock = os.path.join(folder, name)
        if not LOCK_NAME.fullmatch(name) or not os.path.isdir(lock):
            continue
        pid = _read_pid(os.path.join(lock, "pid"))
        if pid is None:
            try:
                young = now - os.lstat(lock).st_mtime < STARTING_GRACE
            except OSError:
                continue
            if young:
                busy.append("code-job starting (slot %s)" % name[:-5])
        elif pid_alive(pid):
            busy.append("code-job pid %d (slot %s)" % (pid, name[:-5]))
    return busy


def swarm_jobs(state):
    """Running swarm_jobs.py actions, as descriptions."""
    path = os.path.join(state, "control.sqlite")
    if not os.path.exists(path):
        return []
    try:
        db = sqlite3.connect("file:%s?mode=ro" % _uri_path(path), uri=True, timeout=5)
        try:
            rows = db.execute("SELECT id, status, pid FROM actions WHERE status IN ('running', 'cancelled')").fetchall()
        finally:
            db.close()
    except sqlite3.OperationalError as error:
        if "no such table" in str(error):
            return []
        return ["swarm job database unreadable"]
    except sqlite3.Error:
        return ["swarm job database unreadable"]
    busy = []
    for ident, status, pid in rows:
        if status == "running" and pid is None:
            busy.append("swarm job %s launching" % ident)
        elif pid_alive(pid):
            busy.append("swarm job %s pid %d (%s)" % (ident, pid, status))
    return busy


def _uri_path(path):
    """Percent-encode the characters SQLite URIs treat specially."""
    return "".join("%%%02X" % ord(c) if c in "%?#" else c for c in os.path.abspath(path))


def busy(hermes_home):
    """Everything that keeps the box from being idle; [] when idle."""
    state = os.path.join(hermes_home, "swarmhub")
    return code_jobs(state) + swarm_jobs(state)


def wait_for_idle(hermes_home, max_wait=DEFAULT_MAX_WAIT, poll=DEFAULT_POLL, clock=time.monotonic, sleep=time.sleep):
    """Poll until idle or `max_wait` seconds have passed (bounded deferral). Returns (idle, last busy list, waited)."""
    start = clock()
    while True:
        jobs = busy(hermes_home)
        waited = clock() - start
        if not jobs:
            return True, [], waited
        if waited >= max_wait:
            return False, jobs, waited
        sleep(min(poll, max(0.0, max_wait - waited)))
