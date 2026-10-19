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
# Hermes spills pre_llm_call context above hooks.output_spill.max_chars (default
# 10,000) to a file and injects only a 500-char head/tail preview. A batch must
# stay below that, prefix included, or "delivered" messages are mostly unseen.
BATCH_MAX = 9000
HELD_MAX = 8000  # One held message always fits a batch together with its prefix.
HEADER = ("Held peer messages delivered with this turn. Do not acknowledge FYIs. "
          "Use NO_REPLY only when the whole turn needs no answer.\n\n")
WORKER_BUSY = 75  # Another worker already holds the recovery lock.


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
    if not text or len(text) > HELD_MAX:
        raise ValueError(f"held message must have 1–{HELD_MAX} characters; use --priority or --durable for more")
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


def render(ident, sender, text):
    return f"[Message from {sender} via SwarmHub]\n[Held message id={ident}]\n{text}"


def before_turn(profile, session_id, turn_id, user_message=None):
    """Claim a batch that fits one turn's context. Failure/crash leaves it recoverable after the lease.

    A new turn in the same session reclaims its previous batch immediately. Other
    simultaneous sessions cannot claim it while the first turn owns the lease.
    Messages beyond BATCH_MAX stay unclaimed for a later turn; only the claimed
    ones are marked delivered after the turn answers.
    """
    control.receipt_bind(profile, session_id, turn_id, user_message)
    update = control.subscription(profile)
    prefix = ("Global SwarmHub policy (enforced by managed execution): " +
              json.dumps(update, sort_keys=True) + "\n\n" if update else "")
    if len(prefix) > BATCH_MAX:
        # Old policy records predate the bounded model name. Do not acknowledge
        # policy that the model would only see as a spilled preview.
        note(state(), "Oversized policy retained pending; publish a shorter policy")
        update, prefix = None, ""
    if update:
        control.bind_policy(profile, session_id, turn_id, update["revision"])
    claim = json.dumps([session_id, turn_id])
    now = time.time()
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        rows = db.execute("""SELECT id,sender,text,claim,task FROM inbox
            WHERE recipient=? AND delivered IS NULL ORDER BY created,id""", (profile,)).fetchall()
        batch, size = [], len(prefix) + len(HEADER)
        for ident, sender, text, owner, task in rows:
            if task and not control.active(task):
                db.execute("UPDATE inbox SET delivered=? WHERE id=?", (now, ident))
                continue
            if owner:
                expiry = db.execute("SELECT expires FROM inbox WHERE id=?", (ident,)).fetchone()[0]
                if expiry > now and json.loads(owner)[0] != session_id:
                    continue
            piece = render(ident, sender, text)
            if size + len(piece) + 2 > BATCH_MAX:
                if batch:
                    break
                # Pre-1.3.1 inboxes can contain 32,000-character messages. Keep
                # them intact and unacknowledged; allow later, fitting rows through.
                note(state(), "Oversized held message retained pending; resend with --priority or --durable")
                continue
            batch.append(piece)
            size += len(piece) + 2
            db.execute("UPDATE inbox SET claim=?,expires=? WHERE id=?", (claim, now + LEASE, ident))
            if len(batch) == 50:
                break
    if not batch and not update:
        return None
    if not batch:
        return {"context": prefix.rstrip()}
    return {"context": prefix + HEADER + "\n\n".join(batch)}


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
    folder = existing_state()
    if folder is None:
        return False  # A removed state folder is never recreated by a sweep.
    for job in sorted((folder / "job-completions").glob("job.*")):
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
        except Exception as exc:  # One malformed record must not block the other jobs.
            try:
                (job / "last-error").write_text(f"Delivery failed ({type(exc).__name__}); record retained for retry")
            except OSError:
                pass
    return pending


def note(folder, text):
    """Record the last recovery error without recreating a removed state folder."""
    if folder.exists():
        try:
            (folder / "job-wake.error").write_text(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {text}\n")
        except OSError:
            pass


def backoff(failures):
    return min(60, 2 ** min(failures, 6))


def sweep():
    if existing_state() is None:
        return
    retry_once()
    control.retry_deliveries()


def guarded(fn, folder, failures, sleep=time.sleep):
    """Run one sweep. Any exception is recorded and backed off, never fatal; returns the failure count."""
    try:
        fn()
        return 0
    except Exception as exc:
        failures += 1
        delay = backoff(failures)
        note(folder, f"{type(exc).__name__}: {exc}; next sweep in {delay}s")
        sleep(delay)
        return failures


def existing_state():
    """The state folder only if it exists: a late-starting worker must not recreate a removed one."""
    folder = Path.home() / ".hermes/swarmhub"
    return folder if folder.is_dir() else None


def worker(once=False):
    """Recovery loop. Returns WORKER_BUSY when another worker holds the lock, else 0.

    flock is released by the OS even if the worker is killed; no stale PID lock.
    In once mode (``swarmctl tick``) an error propagates to the caller instead.
    """
    folder = state() if once else existing_state()
    if folder is None:
        return 0
    with (folder / "job-wake.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return WORKER_BUSY
        (folder / "job-wake.pid").write_text(str(os.getpid()))
        # Stay alive to notice jobs published just after an otherwise empty sweep.
        def schedule():
            failures = 0
            while existing_state() is not None:
                failures = guarded(control.tick, folder, failures)  # Durable actions recover next sweep.
                time.sleep(2)
        if once:
            control.tick()
            sweep()
            return 0
        # A slow gateway acknowledgement must not hold the standing queue.
        threading.Thread(target=schedule, daemon=True).start()
        failures = 0
        while folder.exists():
            failures = guarded(sweep, folder, failures)
            time.sleep(2)
    return 0


def run_worker():
    return subprocess.call([sys.executable, str(Path(__file__).resolve()), "worker"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, close_fds=True)


def supervise(run=run_worker, sleep=time.sleep):
    """Keep one recovery worker alive: restart it after any exit, with backoff.

    A worker that ran for a minute resets the backoff. A worker that found the
    lock busy is not a crash; the supervisor just checks again later. Stops
    when the state folder goes away.
    """
    folder = existing_state()
    if folder is None:
        return
    with (folder / "job-wake.supervisor.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        (folder / "job-wake.supervisor.pid").write_text(str(os.getpid()))
        failures = 0
        while folder.exists():
            started = time.monotonic()
            rc = run()
            if not folder.exists():
                return
            if rc == WORKER_BUSY:
                failures, delay = 0, 5
            else:
                failures = 0 if time.monotonic() - started >= 60 else failures + 1
                delay = backoff(failures)
                note(folder, f"worker exited {rc}; restart in {delay}s")
            sleep(delay)


def start_worker():
    control.spawn([sys.executable, str(Path(__file__).resolve()), "supervise"])


def register(ctx):
    # Hermes loads one plugin per profile; bind its identity instead of consulting
    # mutable process environment during multiplexed turns.
    from hermes_constants import get_hermes_home
    home = get_hermes_home()
    profile = home.name if home.parent.name == "profiles" else "default"
    ctx.register_hook("pre_llm_call", lambda session_id, turn_id, user_message=None, **kw:
                      before_turn(profile, session_id, turn_id, user_message))
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
        "name: swarmhub-peer\nversion: 1.3.1\ndescription: SwarmHub held peer inbox and coding completion recovery\n"
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
            sys.exit(worker())
        elif command == "supervise":
            supervise()
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
