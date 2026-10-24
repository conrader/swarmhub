"""Durable peer deliveries: sender outbox, receiver receipts and the retry sweep.

A receipt binds to a turn only through the delivery id carried in the delivered
text, never through the sender/target session alone, so an unrelated turn in
the same session cannot acknowledge a delivery that was never seen.
"""
import re
import subprocess
import swarm_lifecycle as lifecycle
from pathlib import Path
import time
import uuid

from swarm_policy import active
from swarm_store import NAME, database, profile_exists

TAG = "[SwarmHub delivery id={}]"
TAG_PATTERN = re.compile(r"\[SwarmHub delivery id=([A-Za-z0-9_-][A-Za-z0-9_.-]*)\]")
TEXT_LIMIT = 32000


def tagged(ident, text):
    return TAG.format(ident) + "\n" + text


def delivery_ids(message):
    """Delivery ids named in a turn's user message (text, or Hermes' multimodal part list)."""
    if message is None:
        return []
    if isinstance(message, list):
        message = "\n".join(part.get("text", "") if isinstance(part, dict) else str(part) for part in message)
    elif not isinstance(message, str):
        message = str(message)
    return list(dict.fromkeys(TAG_PATTERN.findall(message)))


def enqueue(sender, target, text, task="", ident=None, bridged=False):
    # bridged: peer-bridge (as root) vouched for a sender that lives in another account, so it is not a local profile.
    known = bool(NAME.fullmatch(sender)) if bridged else profile_exists(sender)
    if not known or not profile_exists(target) or not text or len(text) > TEXT_LIMIT:
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


def receipt_bind(profile, session, turn, message):
    """Bind the turn to exactly the running receipts whose delivery id the turn's message carries."""
    ids = delivery_ids(message)
    if not ids:
        return []
    bound = []
    with database() as db:
        for ident in ids:
            cursor = db.execute("UPDATE receipts SET turn=? WHERE target=? AND id=? AND session=? AND status='running'",
                                (str(turn), profile, ident, session))
            if cursor.rowcount:
                bound.append(ident)
    return bound


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
        rc = lifecycle.call(command + ["--", tagged(ident, text)], timeout=3700)
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
        except OSError:
            rc = 3  # One unreadable record must not stop the sweep for the rest.
        count = row["attempts"] + 1
        with database() as db:
            db.execute("UPDATE deliveries SET status=?,attempts=?,due=?,error=? WHERE id=? AND status='pending'",
                       ("delivered" if rc == 0 else "cancelled" if rc == 125 else "pending", count,
                        time.time() + min(300, 2 ** min(count, 8)), None if rc == 0 else
                       f"Unacknowledged (exit {rc}); retained for retry" if rc != 125 else "Task stopped",
                        row["id"]))
