"""Box verifier for device-signed approvals (v2): challenge, decide, receipt. No shared key, no network.

Each call runs in one BEGIN IMMEDIATE transaction that re-reads devices, mode, policy, the full spec,
the pending gate and the nonce, takes the box time after the lock is held, and only then marks the
nonce used and commits the decision with its receipt. Every refusal writes nothing. The check order
and reason codes follow DEVICE-APPROVALS.md and its vectors; the wake happens only after commit.
"""
import hashlib
import json
import secrets
import sys
import uuid

import swarm_device_state as ds
from swarm_device_state import Refusal, require
from swarm_policy import decide_in_transaction, policy
from swarm_store import canonical, database

PER_DEVICE = 8      # Unused, unexpired challenges one device may hold at once.
TOTAL = 1024        # Rows kept in approval_challenges (used rows stay until expiry).


def v1_allowed(db):
    """v1 dispatch checks the local mode before any v1 authentication. Doubt = not allowed.

    A corrupt device list is doubt too: it could be hiding an enrollment, so v1 refuses as well.
    """
    try:
        ds.devices(db)
        return not ds.device_required(db)
    except (Refusal, *ds.ERRORS):
        return False


def operation(db, task):
    """The stored action with its parsed spec, or None; a spec that fails either digest is state_invalid."""
    row = db.execute("SELECT * FROM actions WHERE id=?", (task,)).fetchone()
    if not row:
        return None
    try:
        record = dict(row)
        spec = ds.jcs.loads(record["spec"].encode())
        require(isinstance(spec, dict) and isinstance(record["gate"], str) and isinstance(record["status"], str)
                and hashlib.sha256(canonical(spec).encode()).hexdigest() == record["fingerprint"], "state_invalid")
        record["spec"] = spec
        return record, ds.fingerprint(spec)
    except ds.ERRORS as error:
        raise Refusal("state_invalid") from error


def stored_json(text):
    """Receipts are stored with swarm_store.canonical (times are floats), so not JCS; still strict."""
    def unique(pairs):
        require(len({k for k, _ in pairs}) == len(pairs), "state_invalid")
        return dict(pairs)
    return json.loads(text, object_pairs_hook=unique, parse_constant=lambda _: require(False, "state_invalid"))


def saved_receipt(db, task, origin, runtime):
    row = db.execute("SELECT binding,receipt FROM approval_receipts WHERE task=?", (task,)).fetchone()
    if not row:
        return None
    try:
        receipt = stored_json(row["receipt"])
        binding = stored_json(row["binding"])
        require(binding == receipt["remoteBinding"]
                == {"origin": origin, "runtime": runtime, "profile": receipt["decider"]}, "state_invalid")
        return receipt
    except ds.ERRORS as error:
        raise Refusal("state_invalid") from error


class DeviceApprovals:
    def __init__(self, origin, wake):
        self.origin = origin
        self.wake = wake

    # Decision -----------------------------------------------------------------------------------

    def evaluate(self, db, raw, destination, now):
        """Return ({verdict, reason}, context); first failure wins, in the documented order.

        `defer/legacy_v1` is dispatch advice for a v1 body on a legacy box, NOT approval.
        """
        try:
            state = ds.snapshot(db, self.origin)
        except (Refusal, *ds.ERRORS):
            return {"verdict": "reject", "reason": "state_invalid"}, None
        try:
            doc = ds.envelope(raw)
            if type(doc.get("version")) is int and doc["version"] == 1:
                require(not state["device_required"], "device_required")
                return {"verdict": "defer", "reason": "legacy_v1"}, None
            body, signature = ds.signed_parts(doc)
            ds.check_shape(body)
            require(body["version"] == 2 and body["domain"] == ds.DOMAIN, "protocol_unsupported")
            device = state["devices"].get(body["key_id"])
            ds.check_signature(device, ds.CONTEXT, body, signature)
            found = operation(db, body["task"])
            record, v2 = found if found else (None, None)
            require(body["origin"] == state["origin"] and body["runtime"] == state["runtime"], "box_mismatch")
            decider = policy(db).get(record["gate"]) if record else None
            require(body["profile"] == destination and (record is None or decider == destination),
                    "profile_mismatch")
            require(body["profile"] in device["profiles"], "device_unauthorized")
            require(record is not None, "task_mismatch")
            require(body["fingerprint"] == v2, "fingerprint_mismatch")
            require(body["gate"] == record["gate"], "gate_mismatch")
            require(record["status"] == "awaiting-" + record["gate"]
                    and saved_receipt(db, record["id"], state["origin"], state["runtime"]) is None,
                    "operation_not_pending")
            nonce = state["nonces"].get(body["nonce"])
            require(nonce is not None, "nonce_unknown")
            require(nonce["binding"] == {k: body[k] for k in ds.NONCE_FIELDS}, "nonce_mismatch")
            require(not nonce["used"], "nonce_replayed")
            require(body["issued"] <= now, "nonce_not_yet_valid")
            require(now < body["expires"], "nonce_expired")
            context = {"body": body, "record": record, "decider": decider, "v2": v2, "state": state,
                       "message": hashlib.sha256(ds.message(ds.CONTEXT, body)).hexdigest()}
            return {"verdict": "accept", "reason": "ok"}, context
        except Refusal as error:
            return {"verdict": "reject", "reason": str(error)}, None
        except ds.ERRORS:
            return {"verdict": "reject", "reason": "schema_invalid"}, None

    def decide(self, destination, raw):
        """Return (verdict, receipt or None). Exactly one concurrent consume of a nonce can accept."""
        receipt = None
        try:
            with database() as db:
                db.execute("BEGIN IMMEDIATE")
                try:
                    now = ds.box_now()  # Taken after the lock: a decision that waited past expiry rejects.
                except Refusal:
                    return {"verdict": "reject", "reason": "state_invalid"}, None
                verdict, context = self.evaluate(db, raw, destination, now)
                if verdict["verdict"] != "accept":
                    return verdict, None
                receipt = self.commit(db, context, now)
        except Refusal as error:  # Rolled back: the nonce stays unused and nothing was decided.
            return {"verdict": "reject", "reason": str(error)}, None
        except ds.ERRORS:
            return {"verdict": "reject", "reason": "state_invalid"}, None
        if receipt["remoteReceipt"]["approved"]:
            try:
                self.wake()
            except Exception:  # Committed: the client still gets its receipt.
                print("swarm_device_approvals: worker wake failed after a recorded decision", file=sys.stderr)
        return {"verdict": "accept", "reason": "ok"}, receipt

    def commit(self, db, context, now):
        body, record, state = context["body"], context["record"], context["state"]
        used = db.execute("UPDATE approval_challenges SET used=1 WHERE nonce=? AND used=0", (body["nonce"],))
        require(used.rowcount == 1, "nonce_replayed")
        decide_in_transaction(db, record["id"], body["profile"], body["approved"], record["fingerprint"],
                              record["gate"])
        decided = db.execute("SELECT status,decided_by,decided_at FROM actions WHERE id=?", (record["id"],)).fetchone()
        binding = {"origin": state["origin"], "runtime": state["runtime"], "profile": body["profile"]}
        receipt = {**record, **dict(decided), "decider": context["decider"], "remoteBinding": binding,
                   "remoteReceipt": {"id": str(uuid.uuid4()), "approved": body["approved"], "protocol": 2,
                                     "device": body["key_id"], "nonce": body["nonce"],
                                     "fingerprint": context["v2"], "message": context["message"]}}
        db.execute("INSERT INTO approval_receipts VALUES(?,?,?,?)",
                   (record["id"], canonical(binding), int(body["approved"]), canonical(receipt)))
        db.execute("DELETE FROM approval_challenges WHERE expires+?<=?", (ds.TTL, now))
        return receipt

    # Reads --------------------------------------------------------------------------------------

    def read(self, db, raw, destination, verb, now):
        try:
            state = ds.snapshot(db, self.origin)
        except (Refusal, *ds.ERRORS) as error:
            raise Refusal("state_invalid") from error
        doc = ds.envelope(raw)
        require(not (type(doc.get("version")) is int and doc["version"] == 1), "protocol_unsupported")
        body, signature = ds.signed_parts(doc)
        ds.check_request_shape(body, verb)
        device = state["devices"].get(body["key_id"])
        ds.check_signature(device, ds.REQUEST_CONTEXT, body, signature)
        require(body["origin"] == state["origin"], "box_mismatch")
        require(body["profile"] == destination, "profile_mismatch")
        require(body["profile"] in device["profiles"], "device_unauthorized")
        require(now - ds.TTL <= body["issued"] <= now + ds.SKEW, "request_expired")
        return state, body

    def challenge(self, destination, raw):
        """Issue a fresh one-use nonce for a pending operation and an enrolled, authorized device."""
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            now = ds.box_now()
            state, body = self.read(db, raw, destination, "challenge", now)
            found = operation(db, body["task"])
            require(found is not None, "task_mismatch")
            record, v2 = found
            decider = policy(db).get(record["gate"])
            require(decider == destination, "profile_mismatch")
            require(record["status"] == "awaiting-" + record["gate"]
                    and saved_receipt(db, record["id"], state["origin"], state["runtime"]) is None,
                    "operation_not_pending")
            # A box clock behind an issued challenge has gone backwards: refuse to issue more.
            require(all(n["binding"]["issued"] <= now for n in state["nonces"].values()), "state_invalid")
            db.execute("DELETE FROM approval_challenges WHERE expires+?<=?", (ds.TTL, now))
            mine = db.execute("SELECT count(*) FROM approval_challenges WHERE key_id=? AND used=0 AND expires>?",
                              (body["key_id"], now)).fetchone()[0]
            total = db.execute("SELECT count(*) FROM approval_challenges").fetchone()[0]
            require(mine < PER_DEVICE and total < TOTAL, "challenge_limited")
            nonce = secrets.token_bytes(32).hex()
            require(nonce not in state["nonces"], "state_invalid")
            binding = {"version": 2, "domain": ds.DOMAIN, "key_id": body["key_id"], "origin": state["origin"],
                       "runtime": state["runtime"], "profile": destination, "task": record["id"],
                       "fingerprint": v2, "gate": record["gate"], "nonce": nonce,
                       "issued": now, "expires": now + ds.TTL}
            db.execute("INSERT INTO approval_challenges VALUES(?,?,?,?,?,0,?)",
                       (nonce, body["key_id"], record["id"], now, now + ds.TTL, ds.jcs.canonical(binding).decode()))
        return {"challenge": binding, "record": {**record, "decider": decider}}

    def receipt(self, destination, raw):
        """Idempotent read of the committed receipt; it never authorizes anything."""
        with database() as db:
            db.execute("BEGIN IMMEDIATE")
            now = ds.box_now()
            state, body = self.read(db, raw, destination, "receipt", now)
            saved = saved_receipt(db, body["task"], state["origin"], state["runtime"])
            if saved:
                require(destination in (saved["decider"], saved["spec"].get("bot")), "profile_mismatch")
                return {"receipt": saved}
            found = operation(db, body["task"])
            if not found:
                return {"receipt": None, "status": "gone"}
            record = found[0]
            require(destination in (policy(db).get(record["gate"]), record["spec"].get("bot")), "profile_mismatch")
            return {"receipt": None, "status": record["status"]}

    # HTTP boundary ------------------------------------------------------------------------------

    def handle(self, profile, verb, raw):
        """Return (http status, response object). Reasons are codes, never operation content."""
        digest = hashlib.sha256(raw).hexdigest() if isinstance(raw, bytes) else None
        try:
            require(ds.matches(profile, ds.NAME) and verb in ("challenge", "decide", "receipt"), "schema_invalid")
            if verb == "decide":
                verdict, receipt = self.decide(profile, raw)
                if verdict["verdict"] == "accept":
                    return 200, {"request": digest, "receipt": receipt}
                # defer/legacy_v1 is not approval: v1 bodies belong on the v1 endpoint, never here.
                raise Refusal(verdict["reason"])
            result = (self.challenge if verb == "challenge" else self.receipt)(profile, raw)
            return 200, {"request": digest, **result}
        except Refusal as error:
            return 403, {"error": "control request refused", "reason": str(error)}
        except Exception:  # sqlite lock, recursion, anything unclassified: refuse.
            return 403, {"error": "control request refused", "reason": "schema_invalid"}
