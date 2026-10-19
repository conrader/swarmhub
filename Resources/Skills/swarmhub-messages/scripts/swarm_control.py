"""Durable, box-local work contracts used by the shipped shell entrypoints.

This is an execution boundary for managed jobs/messages, not a sandbox for an
arbitrary terminal command. All profiles share the owner's Unix account.
"""
from contextlib import contextmanager
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import subprocess
import time
import uuid
import sys
import threading
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*\Z", re.ASCII)


def spawn(command):
    child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    # Reap while a long-lived gateway owns us; an exited launcher leaves the
    # detached child to the OS, with durable state for the next worker.
    threading.Thread(target=child.wait, daemon=True).start()
    return child.pid


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
        """)
        with db:
            yield db
    finally:
        db.close()


def profile_exists(profile):
    return isinstance(profile, str) and bool(NAME.fullmatch(profile)) and (profile == "default" or
        (Path.home() / ".hermes/profiles" / profile).is_dir())


def policy(db=None):
    if db is None:
        with database() as db:
            return policy(db)
    row = db.execute("SELECT revision,body FROM settings WHERE id=1").fetchone()
    return ({"revision": row[0], **json.loads(row[1])} if row else
            {"revision": 0, "route": "auto", "allow_speculative": True,
             "timezone": "Europe/Warsaw", "start": 480, "end": 1380})


def register(profile, coordinator=False):
    # Register a profile reference, never a copied API key or generated webhook secret.
    if not profile_exists(profile):
        raise ValueError("unknown profile")
    env = Path.home() / ".hermes"
    if profile != "default":
        env = env / "profiles" / profile
    if not (env / ".env").is_file():
        raise ValueError("profile gateway credentials are not configured")
    with database() as db:
        db.execute("INSERT OR IGNORE INTO subscribers VALUES(?, -1)", (profile,))
    if coordinator:
        publish({"coordinator": profile})
    return {"profile": profile, "wake": "profile-gateway", "credentials": "profile .env at delivery"}


def publish(change):
    keys = {"route", "codex_model", "allow_speculative", "coordinator", "owner", "timezone", "start", "end"}
    if not isinstance(change, dict) or not change or set(change) - keys:
        raise ValueError("unknown policy setting")
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        current = policy(db)
        current.update(change)
        if current["route"] not in ("auto", "codex") or type(current["allow_speculative"]) is not bool:
            raise ValueError("invalid coding policy")
        if "codex_model" in current and (not isinstance(current["codex_model"], str) or
            not re.fullmatch(r"[A-Za-z0-9_./:-]+", current["codex_model"])):
            raise ValueError("invalid Codex model")
        try:
            ZoneInfo(current["timezone"])
        except (TypeError, ZoneInfoNotFoundError) as exc:
            raise ValueError("invalid IANA timezone") from exc
        for key in ("start", "end"):
            if type(current[key]) is not int or not 0 <= current[key] < 1440:
                raise ValueError("invalid reporting minute")
        for key in ("coordinator", "owner"):
            if key in current and not profile_exists(current[key]):
                raise ValueError("unknown reporting/approval profile")
        revision = current.pop("revision") + 1
        db.execute("INSERT OR REPLACE INTO settings VALUES(1,?,?)", (revision, canonical(current)))
    return {"revision": revision, **current}


def subscription(profile):
    with database() as db:
        row = db.execute("SELECT revision FROM subscribers WHERE profile=?", (profile,)).fetchone()
        current = policy(db)
        if row is None or row[0] == current["revision"]:
            return None
        # Reading a subscription does not acknowledge it; post-turn does.
        return current


def acknowledge_policy(profile, revision):
    with database() as db:
        db.execute("UPDATE subscribers SET revision=MAX(revision,?) WHERE profile=?", (revision, profile))


def bind_policy(profile, session, turn, revision):
    with database() as db:
        db.execute("INSERT OR REPLACE INTO policy_turns VALUES(?,?,?,?)", (profile, session, str(turn), revision))


def acknowledge_turn_policy(profile, session, turn):
    with database() as db:
        row = db.execute("SELECT revision FROM policy_turns WHERE profile=? AND session=? AND turn=?",
                         (profile, session, str(turn))).fetchone()
        if row:
            db.execute("UPDATE subscribers SET revision=MAX(revision,?) WHERE profile=?", (row[0], profile))
            db.execute("DELETE FROM policy_turns WHERE profile=? AND session=? AND turn=?", (profile, session, str(turn)))


def reporting_targets(at=None):
    rule = policy()
    moment = datetime.fromtimestamp(time.time() if at is None else at, ZoneInfo(rule["timezone"]))
    minute = moment.hour * 60 + moment.minute
    start, end = rule["start"], rule["end"]
    in_window = (start <= minute < end if start < end else minute >= start or minute < end)
    if start == end:
        in_window = True
    coordinator = rule.get("coordinator")
    if not coordinator:
        raise ValueError("configure coordinator before reporting")
    targets = [coordinator]
    if in_window:
        if not rule.get("owner"):
            raise ValueError("configure owner before daytime reporting")
        targets.append(rule["owner"])
    return list(dict.fromkeys(targets))


def coding_plan(order, speculative=False):
    rule = policy()
    if speculative and not rule["allow_speculative"]:
        raise ValueError("global policy forbids speculative jobs")
    return "codex" if rule["route"] == "codex" else order


def coding_model(model):
    rule = policy()
    return rule.get("codex_model", model) if rule["route"] == "codex" else model


def validate_spec(spec):
    if not isinstance(spec, dict):
        raise ValueError("action must be an object")
    allowed = {"bot", "origin", "intent", "parent", "kind", "risks", "task", "directory", "order",
               "model", "effort", "report", "speculative", "argv", "fake", "to", "text"}
    if set(spec) - allowed:
        raise ValueError("unknown action field")
    if (not isinstance(spec.get("bot"), str) or not profile_exists(spec["bot"]) or
        not isinstance(spec.get("intent"), str) or not spec["intent"].strip()):
        raise ValueError("bot and stable intent are required")
    for key in ("fake", "speculative"):
        if key in spec and type(spec[key]) is not bool:
            raise ValueError(key + " must be a boolean")
    for key in ("origin", "parent", "order", "to", "text"):
        if key in spec and not isinstance(spec[key], str):
            raise ValueError(key + " must be text")
    kind = spec.get("kind")
    risks = spec.get("risks", [])
    if not isinstance(risks, list) or not all(isinstance(risk, str) for risk in risks) or set(risks) - {"money", "prod", "secrets"}:
        raise ValueError("unknown risk")
    if kind == "coding":
        if not all(isinstance(spec.get(k), str) and spec[k].strip() for k in
                   ("task", "directory", "model", "effort", "report")):
            raise ValueError("coding requires task, directory, model, effort and report")
        if spec["effort"] not in ("low", "medium", "high", "xhigh"):
            raise ValueError("invalid effort")
        if not re.fullmatch(r"[A-Za-z0-9_./:-]+", spec["model"]):
            raise ValueError("invalid model")
        if not Path(spec["directory"]).is_absolute() or not Path(spec["directory"]).is_dir():
            raise ValueError("coding directory must be an existing absolute path")
        if set(spec.get("order", "codex").split(",")) - {"claude", "codex", "hermes"}:
            raise ValueError("unknown coding agent")
        coding_plan(spec.get("order", "codex"), spec.get("speculative", False))
    elif kind == "peer":
        if not profile_exists(spec.get("to", "")) or not spec.get("text"):
            raise ValueError("peer requires target and text")
    elif kind in ("read", "outbound", "provision", "money", "prod", "secrets"):
        argv = spec.get("argv")
        if not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv):
            raise ValueError("action requires nonempty argv")
        if kind == "outbound" and not all(isinstance(spec.get(k), str) and spec[k].strip() for k in ("to", "text")):
            raise ValueError("outbound requires recipient and exact draft text")
    else:
        raise ValueError("unknown action kind")
    # Arbitrary commands and provisioning need the owner. Only a small reversible
    # read allowlist is automatic; arguments cannot smuggle an interpreter.
    safe_read = kind == "read" and Path(spec["argv"][0]).is_absolute() and Path(spec["argv"][0]).resolve() in {
        Path(prefix, tool).resolve() for prefix in ("/bin", "/usr/bin") for tool in ("pwd", "stat", "ls")}
    if risks or kind in ("money", "prod", "secrets", "provision") or kind == "read" and not safe_read:
        return "owner"
    return "coordinator" if kind == "outbound" and not spec.get("fake") else "auto"


def submit(spec):
    gate = validate_spec(spec)
    ident = "task." + uuid.uuid4().hex
    fingerprint = hashlib.sha256(canonical(spec).encode()).hexdigest()
    operation = operation_fingerprint(spec)
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        if db.execute("SELECT 1 FROM denials WHERE intent=? OR fingerprint=?",
                      (spec["intent"], operation)).fetchone():
            raise ValueError("denial is final for this intent")
        if spec.get("parent"):
            parent = db.execute("SELECT status FROM actions WHERE id=?", (spec["parent"],)).fetchone()
            if not parent or parent[0] in ("cancelled", "denied", "failed"):
                raise ValueError("parent is not active")
        existing = db.execute("SELECT id,fingerprint FROM actions WHERE intent=? ORDER BY created DESC LIMIT 1",
                              (spec["intent"],)).fetchone()
        if existing and existing[1] == fingerprint:
            return existing[0]  # Idempotent admission, even after completion.
        if existing:
            raise ValueError("scope changed: use replace, which cancels the old task tree")
        db.execute("INSERT INTO actions VALUES(?,?,?,?,?,?,NULL,NULL,?)",
                   (ident, fingerprint, spec["intent"], canonical(spec), gate,
                    "queued" if gate == "auto" else "awaiting-" + gate, time.time()))
    return ident


def action(ident):
    with database() as db:
        row = db.execute("SELECT * FROM actions WHERE id=?", (ident,)).fetchone()
        if not row:
            raise ValueError("unknown task")
        return dict(row)


def decide(ident, actor, approved):
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT * FROM actions WHERE id=?", (ident,)).fetchone()
        if not row or not row["status"].startswith("awaiting-"):
            raise ValueError("decision is final or task is not awaiting approval")
        expected = policy(db).get(row["gate"])
        if not expected or actor != expected:
            raise ValueError("decision requires " + row["gate"])
        db.execute("UPDATE actions SET status=? WHERE id=?", ("queued" if approved else "denied", ident))
        if not approved:
            db.execute("INSERT OR REPLACE INTO denials VALUES(?,?)", (row["intent"], operation_fingerprint(json.loads(row["spec"]))))
    if not approved:
        stop(ident)


def operation_fingerprint(spec):
    execution = {k: v for k, v in spec.items() if k not in ("intent", "origin", "parent")}
    return hashlib.sha256(canonical(execution).encode()).hexdigest()


def stop(ident):
    # Mark the complete tree atomically before signalling any process. Every
    # managed message and coding watchdog checks these persistent tombstones.
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        rows = db.execute("SELECT id,spec,status FROM actions").fetchall()
        ids = {ident}
        while True:
            expanded = ids | {r["id"] for r in rows if json.loads(r["spec"]).get("parent") in ids}
            if expanded == ids:
                break
            ids = expanded
        if not any(r["id"] == ident for r in rows):
            raise ValueError("unknown task")
        folder = state() / "cancelled"
        folder.mkdir(exist_ok=True, mode=0o700)
        for task in ids:
            (folder / task).touch(mode=0o600)
            db.execute("UPDATE actions SET status='cancelled' WHERE id=? AND status NOT IN ('done','denied')", (task,))
            db.execute("UPDATE deliveries SET status='cancelled',error='Task stopped' WHERE task=? AND status!='delivered'", (task,))
    return sorted(ids)


def replace(ident, spec):
    old = action(ident)
    if old["status"] == "denied":
        raise ValueError("denial is final")
    validate_spec(spec)  # Invalid replacement must not kill valid work.
    if spec.get("intent") == old["intent"]:
        raise ValueError("changed scope requires a new intent")
    stop(ident)
    return submit(spec)


def active(ident):
    if not ident:
        return True
    return action(ident)["status"] in ("queued", "running", "done") and not (state() / "cancelled" / ident).exists()


def check_job(ident, bot, directory, model, effort, report, task, order):
    row = action(ident)
    spec = json.loads(row["spec"])
    expected_report = Path(spec.get("report", ""))
    if not expected_report.is_absolute():
        expected_report = Path(spec.get("directory", ".")) / expected_report
    if (row["status"] not in ("queued", "running") or not active(ident) or spec.get("kind") != "coding" or
        (bot, str(Path(directory).resolve()), model, effort, str(Path(report).resolve()), task, order) !=
        (spec["bot"], str(Path(spec["directory"]).resolve()), coding_model(spec["model"]), spec["effort"],
         str(expected_report.resolve()), spec["task"], coding_plan(spec.get("order", "codex"), spec.get("speculative", False)))):
        raise ValueError("job parameters do not match the approved task")


def enqueue(sender, target, text, task="", ident=None):
    if not profile_exists(sender) or not profile_exists(target) or not text or len(text) > 32000:
        raise ValueError("invalid durable message")
    if task and not active(task):
        raise ValueError("task is not approved/active")
    ident = ident or "delivery." + uuid.uuid4().hex
    if not NAME.fullmatch(ident):
        raise ValueError("invalid delivery id")
    with database() as db:
        existing = db.execute("SELECT sender,target,text,task FROM deliveries WHERE id=?", (ident,)).fetchone()
        if existing and tuple(existing) != (sender, target, text, task):
            raise ValueError("delivery id already binds different content")
        db.execute("INSERT OR IGNORE INTO deliveries(id,sender,target,text,task,status) VALUES(?,?,?,?,?,'pending')",
                   (ident, sender, target, text, task))
    return ident


def receipt_claim(target, ident, sender):
    """Receiver journal: a post-turn acknowledgement survives lost sender ACKs.

    In-flight claims serialize a sender's reused gateway session. Unanswered
    claims have a lease, so an interrupted turn can recover after restart.
    """
    session = "swarmhub-from-" + sender
    token = uuid.uuid4().hex
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT status FROM receipts WHERE target=? AND id=?", (target, ident)).fetchone()
        if row and row[0] == "received":
            return "received"
        busy = db.execute("SELECT 1 FROM receipts WHERE target=? AND session=? AND status='running' AND expires>?",
                          (target, session, time.time())).fetchone()
        if busy:
            return "busy"
        db.execute("INSERT OR REPLACE INTO receipts VALUES(?,?,'running',?,?,?,NULL)",
                   (target, ident, token, time.time() + 3700, session))
    return token


def receipt_bind(profile, session, turn):
    with database() as db:
        db.execute("UPDATE receipts SET turn=? WHERE target=? AND session=? AND status='running' AND turn IS NULL",
                   (str(turn), profile, session))


def receipt_ack(profile, session, turn):
    with database() as db:
        db.execute("UPDATE receipts SET status='received' WHERE target=? AND session=? AND turn=? AND status='running'",
                   (profile, session, str(turn)))


def deliver(sender, target, text, ident, task=""):
    if task and not active(task):
        return 125
    token = receipt_claim(target, ident, sender)
    if token == "received":
        return 0
    if token == "busy":
        return 75
    command = ["/bin/sh", str(Path(__file__).with_name("bot-msg")), "--priority", "--no-reply", "--retry-attempt",
               "--from", sender, "--to", target, "--wait", "3600"]
    if task:
        command += ["--task-id", task]
    try:
        result = subprocess.run(command + ["--", text], stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3700)
        rc = result.returncode
    except (OSError, subprocess.TimeoutExpired):
        rc = 3
    with database() as db:
        # A receiver post hook may already have committed received after a lost
        # network ACK. Never erase that acknowledgement on a sender error.
        db.execute("UPDATE receipts SET status=? WHERE target=? AND id=? AND token=? AND status='running'",
                   ("received" if rc == 0 else "pending", target, ident, token))
        row = db.execute("SELECT status FROM receipts WHERE target=? AND id=?", (target, ident)).fetchone()
    return 0 if row and row[0] == "received" else rc


def retry_deliveries():
    with database() as db:
        rows = db.execute("SELECT * FROM deliveries WHERE status='pending' AND due<=? ORDER BY rowid", (time.time(),)).fetchall()
    for row in rows:
        try:
            rc = deliver(row["sender"], row["target"], row["text"], row["id"], row["task"])
        except ValueError:
            rc = 125
        count = row["attempts"] + 1
        with database() as db:
            db.execute("UPDATE deliveries SET status=?,attempts=?,due=?,error=? WHERE id=? AND status='pending'",
                       ("delivered" if rc == 0 else "cancelled" if rc == 125 else "pending", count,
                        time.time() + min(300, 2 ** min(count, 8)), None if rc == 0 else
                       f"Unacknowledged (exit {rc}); retained for retry" if rc != 125 else "Task stopped",
                        row["id"]))


def tick():
    """Launch at most one ordered job per bot. Completion is authoritative on disk.

    A failed job holds later work for that bot; cancelling/replacing explicitly
    releases it. A running job with a lost process is failed, never replayed.
    """
    code = Path(__file__).parents[2] / "swarmhub-coding/scripts/code-job"
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        rows = db.execute("SELECT * FROM actions ORDER BY created,id").fetchall()
        busy = set()
        for row in rows:
            spec = json.loads(row["spec"])
            bot, status = spec["bot"], row["status"]
            job = state() / "job-completions" / row["id"].replace("task.", "job.", 1)
            if status == "cancelled" and row["pid"] and process_alive(row["pid"]):
                busy.add(bot)  # Wait for the old scope to stop before relaunch.
                continue
            if status == "running":
                if spec["kind"] == "peer":
                    delivery = db.execute("SELECT status FROM deliveries WHERE task=?", (row["id"],)).fetchone()
                    if delivery and delivery[0] == "delivered":
                        status = "done"
                        db.execute("UPDATE actions SET status='done' WHERE id=?", (row["id"],))
                elif (job / "ready").exists():
                    status = "done" if (job / "status").read_text().strip() == "ok" else "failed"
                    db.execute("UPDATE actions SET status=? WHERE id=?", (status, row["id"]))
                elif row["pid"]:
                    if not process_alive(row["pid"]):
                        status = "failed"
                        db.execute("UPDATE actions SET status='failed',error='Worker exited without completion' WHERE id=?", (row["id"],))
            if status in ("running", "failed") or status.startswith("awaiting-"):
                busy.add(bot)
                continue
            if status != "queued" or bot in busy:
                continue
            try:
                if spec["kind"] == "coding":
                    order = coding_plan(spec.get("order", "codex"), spec.get("speculative", False))
                    command = ["/bin/sh", str(code), "--bot", bot, "--order", order,
                               "--origin", spec.get("origin", ""), "--dir", spec["directory"],
                               "--model", coding_model(spec["model"]), "--effort", spec["effort"], "--report", spec["report"],
                               "--task-id", row["id"], "--job-id", job.name, "--", spec["task"]]
                    pid = spawn(command)
                    db.execute("UPDATE actions SET status='running',pid=? WHERE id=?", (pid, row["id"]))
                    busy.add(bot)
                elif spec["kind"] == "peer":
                    # Admission is transactional with the action state.
                    delivery = "delivery." + row["id"][5:]
                    db.execute("INSERT OR IGNORE INTO deliveries(id,sender,target,text,task,status) VALUES(?,?,?,?,?,'pending')",
                               (delivery, bot, spec["to"], spec["text"], row["id"]))
                    db.execute("UPDATE actions SET status='running' WHERE id=?", (row["id"],))
                elif spec.get("fake") and spec["kind"] == "outbound":
                    db.execute("UPDATE actions SET status='done',error='FAKE: no outbound operation executed' WHERE id=?", (row["id"],))
                else:
                    pid = spawn([sys.executable, str(Path(__file__).with_name("swarmctl")), "run-action", row["id"]])
                    db.execute("UPDATE actions SET status='running',pid=? WHERE id=?", (pid, row["id"]))
                    busy.add(bot)
            except (ValueError, OSError, subprocess.TimeoutExpired) as exc:
                db.execute("UPDATE actions SET status='failed',error=? WHERE id=?", (type(exc).__name__, row["id"]))
                busy.add(bot)


def run_action(ident):
    row = action(ident)
    # The launcher publishes running in the transaction that admitted the child.
    # A fast child can arrive just before that transaction commits.
    for _ in range(200):
        if row["status"] != "queued":
            break
        time.sleep(.01)
        row = action(ident)
    if row["status"] != "running" or not active(ident):
        return
    spec = json.loads(row["spec"])
    # Only the immutable argv in the approved record reaches the process.
    try:
        child = subprocess.Popen(spec["argv"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL)
    except OSError:
        with database() as db:
            db.execute("UPDATE actions SET status='failed',error='Unable to start approved command' WHERE id=? AND status='running'", (ident,))
        return
    deadline = time.monotonic() + 1800
    while child.poll() is None:
        if (state() / "cancelled" / ident).exists() or time.monotonic() > deadline:
            terminate(child.pid)
            try:
                child.wait(timeout=2)
            except subprocess.TimeoutExpired:
                child.kill()
            break
        time.sleep(.1)
    with database() as db:
        db.execute("UPDATE actions SET status=?,error=? WHERE id=? AND status='running'",
                   ("done" if child.returncode == 0 else "failed", f"exit {child.returncode}", ident))


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


def process_alive(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith("Z")
