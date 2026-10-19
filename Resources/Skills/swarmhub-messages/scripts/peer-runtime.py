#!/usr/bin/env python3
"""Box-local held inbox and coding completion outbox. Standard library only.

Loaded as a Hermes pre/post_llm_call plugin as well as by bot-msg. No model or
network work is performed by hold() or the pre-turn hook. Credentials stay in
bot-msg, which reads the destination profile's .env on each delivery attempt.
"""
import fcntl
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time
import threading
import uuid
sys.dont_write_bytecode = True
import swarm_control as control


NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*\Z", re.ASCII)
LEASE = 3600


def state():
    path = Path.home() / ".hermes/swarmhub"
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.chmod(0o700)
    return path


@contextmanager
def database():
    path = state() / "peer-inbox.sqlite"
    # Create privately, including SQLite's journals, even with a permissive caller umask.
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    os.close(fd)
    path.chmod(0o600)
    db = sqlite3.connect(path, timeout=2)
    try:
        db.execute("""CREATE TABLE IF NOT EXISTS inbox (
            id TEXT PRIMARY KEY, sender TEXT NOT NULL, recipient TEXT NOT NULL,
            text TEXT NOT NULL, created REAL NOT NULL, claim TEXT, expires REAL, delivered REAL)""")
        if "task" not in {row[1] for row in db.execute("PRAGMA table_info(inbox)")}:
            try:
                db.execute("ALTER TABLE inbox ADD COLUMN task TEXT NOT NULL DEFAULT ''")
            except sqlite3.OperationalError:
                if "task" not in {row[1] for row in db.execute("PRAGMA table_info(inbox)")}:
                    raise
        with db:
            yield db
    finally:
        db.close()


def valid(name):
    return bool(NAME.fullmatch(name))


def hold(sender, recipient, text, task=""):
    if not valid(sender) or not valid(recipient):
        raise ValueError("invalid profile")
    if not text or len(text) > 32000:
        raise ValueError("held message must have 1–32000 characters")
    if task and not control.active(task):
        raise ValueError("task is not approved/active")
    home = Path.home() / ".hermes"
    if recipient != "default" and not (home / "profiles" / recipient).is_dir():
        raise ValueError("unknown recipient")
    ident = uuid.uuid4().hex
    with database() as db:
        db.execute("INSERT INTO inbox(id,sender,recipient,text,created,task) VALUES(?,?,?,?,?,?)",
                   (ident, sender, recipient, text, time.time(), task))
    return ident


def before_turn(profile, session_id, turn_id):
    """Claim a bounded batch for one turn. Failure/crash leaves it recoverable after the lease.

    A new turn in the same session reclaims its previous batch immediately. Other
    simultaneous sessions cannot claim it while the first turn owns the lease.
    """
    control.receipt_bind(profile, session_id, turn_id)
    update = control.subscription(profile)
    if update:
        control.bind_policy(profile, session_id, turn_id, update["revision"])
    claim = json.dumps([session_id, turn_id])
    now = time.time()
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        rows = db.execute("""SELECT id,sender,text,claim,task FROM inbox
            WHERE recipient=? AND delivered IS NULL ORDER BY created,id""", (profile,)).fetchall()
        batch, size = [], 0
        for ident, sender, text, owner, task in rows:
            if task and not control.active(task):
                db.execute("UPDATE inbox SET delivered=? WHERE id=?", (now, ident))
                continue
            if owner:
                expiry = db.execute("SELECT expires FROM inbox WHERE id=?", (ident,)).fetchone()[0]
                if expiry > now and json.loads(owner)[0] != session_id:
                    continue
            if size + len(text) > 32000 and batch:
                break
            batch.append((ident, sender, text))
            size += len(text)
            if len(batch) == 50:
                break
        for ident, _, _ in batch:
            db.execute("UPDATE inbox SET claim=?,expires=? WHERE id=?", (claim, now + LEASE, ident))
    if not batch and not update:
        return None
    return {"context": ("Global SwarmHub policy (enforced by managed execution): " +
            json.dumps(update, sort_keys=True) + "\n\n" if update else "") +
            "Held peer messages delivered with this turn. Do not acknowledge FYIs. "
            "Use NO_REPLY only when the whole turn needs no answer.\n\n" +
            "\n\n".join(f"[Message from {sender} via SwarmHub]\n[Held message id={ident}]\n{text}"
                          for ident, sender, text in batch)}


def after_turn(profile, session_id, turn_id, assistant_response):
    if not assistant_response:
        return  # No answer: leave the batch pending.
    control.receipt_ack(profile, session_id, turn_id)
    control.acknowledge_turn_policy(profile, session_id, turn_id)
    with database() as db:
        db.execute("UPDATE inbox SET delivered=? WHERE recipient=? AND claim=? AND delivered IS NULL",
                   (time.time(), profile, json.dumps([session_id, turn_id])))


def config_coordinator():
    value = os.environ.get("SWARMHUB_COORDINATOR", "") or control.policy().get("coordinator", "")
    if not value:
        try:
            for line in (state() / "coding.conf").read_text().splitlines():
                if line.startswith("COORDINATOR="):
                    value = line.partition("=")[2].strip().strip("\"'")
        except FileNotFoundError:
            pass
    return value if valid(value) else ""


def bot_msg():
    return Path(__file__).with_name("bot-msg")


def retry_once():
    """At-least-once delivery: one private process lock, stable job IDs, no retry ceiling.

    Successful means bot-msg observed a terminal, nonfailed SSE reply, including
    NO_REPLY. An uncertain disconnect can redeliver the same job ID.
    """
    pending = False
    for job in sorted((state() / "job-completions").glob("job.*")):
        if not (job / "ready").is_file() or (job / "delivered").exists():
            continue
        pending = True
        try:
            def read(key):
                return (job / key).read_text().strip()
            if (job / "next-attempt").exists() and float(read("next-attempt")) > time.time():
                continue
            origin = read("origin")
            target = origin if valid(origin) and (origin == "default" or
                     (Path.home() / ".hermes/profiles" / origin).is_dir()) else config_coordinator()
            attempts = int(read("attempts")) + 1 if (job / "attempts").exists() else 1
            (job / "attempts").write_text(str(attempts))
            (job / "next-attempt").write_text(str(time.time() + min(300, 2 ** min(attempts, 8))))
            if not target:
                (job / "last-error").write_text("No ordering bot or configured COORDINATOR")
                continue
            sender = read("bot")
            if not valid(sender):
                raise ValueError("invalid job bot")
            message = (f"[Coding job completion {job.name} via SwarmHub]\n"
                       f"Worker: {sender}; agent: {read('agent')}; exit: {read('exit')}; status: {read('status')}.\n"
                       f"Durable record: {job}\n" +
                       (f"Model: {read('model')}; effort: {read('effort')}; "
                        f"report: {read('report')}; report exists: {read('report-exists')}.\n"
                        if (job / 'report-exists').exists() else "") +
                       "Review the result now and take the next step. This job ID may be redelivered; "
                       "do not repeat an action already taken for it. Reply NO_REPLY if no action remains.")
            rc = control.deliver(sender, target, message, job.name)
            if rc == 0:
                (job / "delivered").write_text(str(time.time()))
                (job / "last-error").unlink(missing_ok=True)
            else:
                (job / "last-error").write_text(f"bot-msg exited {rc}; delivery pending")
        except (OSError, ValueError, subprocess.TimeoutExpired):
            (job / "last-error").write_text("Delivery failed; record retained for retry")
    return pending


def worker(once=False):
    # flock is released by the OS even if the worker is killed. No stale PID lock.
    with (state() / "job-wake.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        (state() / "job-wake.pid").write_text(str(os.getpid()))
        # Stay alive to notice jobs published just after an otherwise empty sweep.
        folder = state()
        def schedule():
            while folder.exists():
                try:
                    control.tick()
                except (OSError, ValueError, sqlite3.Error):
                    pass  # Durable actions remain visible and recover on the next sweep.
                time.sleep(2)
        if not once:
            # A slow gateway acknowledgement must not hold the standing queue.
            threading.Thread(target=schedule, daemon=True).start()
        while folder.exists():
            if once:
                control.tick()
            retry_once()
            control.retry_deliveries()
            if once:
                return
            time.sleep(2)


def start_worker():
    control.spawn([sys.executable, str(Path(__file__).resolve()), "worker"])


def register(ctx):
    # Hermes loads one plugin per profile; bind its identity instead of consulting
    # mutable process environment during multiplexed turns.
    from hermes_constants import get_hermes_home
    home = get_hermes_home()
    profile = home.name if home.parent.name == "profiles" else "default"
    ctx.register_hook("pre_llm_call", lambda session_id, turn_id, **kw:
                      before_turn(profile, session_id, turn_id))
    ctx.register_hook("post_llm_call", lambda session_id, turn_id, assistant_response, **kw:
                      after_turn(profile, session_id, turn_id, assistant_response))
    start_worker()  # Also recovers pending completions after a gateway restart.


def install(profile):
    if not valid(profile):
        raise ValueError("invalid profile")
    home = Path.home() / ".hermes"
    if profile != "default":
        home = home / "profiles" / profile
    folder = home / "plugins/swarmhub-peer"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "plugin.yaml").write_text(
        "name: swarmhub-peer\nversion: 1.3.0\ndescription: SwarmHub held peer inbox and coding completion recovery\n"
        "provides_hooks:\n  - pre_llm_call\n  - post_llm_call\n")
    (folder / "__init__.py").write_text(
        "import runpy, sys\n" +
        "sys.path.insert(0, " + repr(str(Path(__file__).resolve().parent)) + ")\n" +
        "register = runpy.run_path(" + repr(str(Path(__file__).resolve())) + ")[\"register\"]\n")
    # Registration refers to the gateway's existing .env. No key is exposed or copied.
    control.register(profile)


if __name__ == "__main__":
    os.umask(0o077)
    try:
        command = sys.argv[1]
        if command == "hold":
            print("held:" + hold(*sys.argv[2:]))
        elif command == "worker":
            worker()
        elif command == "start":
            start_worker()
        elif command == "retry-once":
            worker(once=True)
        elif command == "install":
            install(sys.argv[2])
        else:
            raise ValueError("unknown operation")
    except (OSError, ValueError, sqlite3.Error):
        print("peer-runtime: operation failed; pending records retained", file=sys.stderr)
        sys.exit(1)
