"""Policy, registration, action admission and decisions: the durable, box-local work contracts.

This is an execution boundary for managed jobs/messages, not a sandbox for an
arbitrary terminal command. All profiles share the owner's Unix account.
"""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import time
import uuid
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from swarm_store import canonical, database, invoking_profile, profile_exists, state

SIDE_EFFECT_KINDS = ("read", "outbound", "provision", "money", "prod", "secrets")


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
    keys = {"route", "codex_model", "allow_speculative", "coordinator", "owner", "timezone", "start", "end",
            "provisioner", "outbound", "webhook_base"}
    if not isinstance(change, dict) or not change or set(change) - keys:
        raise ValueError("unknown policy setting")
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        current = policy(db)
        current.update(change)
        if current["route"] not in ("auto", "codex") or type(current["allow_speculative"]) is not bool:
            raise ValueError("invalid coding policy")
        for hook in ("provisioner", "outbound"):
            argv = current.get(hook)
            if argv is not None and (not isinstance(argv, list) or not argv or not all(isinstance(a, str) and a for a in argv)
                                     or not Path(argv[0]).is_absolute()):
                raise ValueError(hook + " must be a nonempty argv list starting with an absolute path")
        base = current.get("webhook_base")
        if base is not None and (not isinstance(base, str) or not re.fullmatch(r"https?://[A-Za-z0-9_.:\[\]-]+(/[A-Za-z0-9_./-]*)?", base)):
            raise ValueError("invalid webhook base URL")
        if "codex_model" in current and (not isinstance(current["codex_model"], str) or
            not re.fullmatch(r"[A-Za-z0-9_./:-]{1,200}", current["codex_model"])):
            raise ValueError("invalid Codex model")  # Bounded: the policy prefix must fit a held batch.
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
               "model", "effort", "report", "speculative", "argv", "fake", "to", "text", "verify", "request"}
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
        if "verify" in spec and (not isinstance(spec["verify"], str) or not spec["verify"].strip() or "\n" in spec["verify"]):
            raise ValueError("verify must be a one-line command")
        coding_plan(spec.get("order", "codex"), spec.get("speculative", False))
    elif kind == "peer":
        if not profile_exists(spec.get("to", "")) or not spec.get("text"):
            raise ValueError("peer requires target and text")
    elif kind in SIDE_EFFECT_KINDS:
        if kind == "provision" and ("request" in spec or "argv" not in spec):
            composed = provisioner_argv(spec.get("request"))
            if "argv" in spec and spec["argv"] != composed:
                raise ValueError("provision argv must match the configured hook and request")
            spec["argv"] = composed  # Idempotent validation; replace validates before cancelling the old scope.
        if kind == "outbound" and "argv" not in spec and isinstance(spec.get("to"), str) and isinstance(spec.get("text"), str):
            spec["argv"] = outbound_argv(spec["to"], spec["text"], bool(spec.get("fake")))
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


SECRET_FIELD = re.compile(r"key|secret|token|password|passwd|credential", re.IGNORECASE)


def provisioner_argv(request):
    """The owner-configured provisioning hook plus the request as one JSON argument.

    The hook is policy, not caller input; the request is passed verbatim as a single
    argument, so nothing in it is shell-interpreted. Secret-like fields must name a
    `swarmctl secret intake` file, never carry a value.
    """
    hook = policy().get("provisioner")
    if not hook:
        raise ValueError("no provisioner configured: the owner publishes policy provisioner first")
    if not isinstance(request, dict) or not request or not all(isinstance(k, str) for k in request):
        raise ValueError("provision requires a request object or an explicit argv")
    if not all(isinstance(v, (str, int, bool)) for v in request.values()) or len(canonical(request)) > 16000:
        raise ValueError("provision request must be flat and under 16000 bytes")
    from swarm_intake import is_intake_path
    for key, value in request.items():
        if SECRET_FIELD.search(key) and not is_intake_path(value):
            raise ValueError("secret-like request fields must reference a swarmctl secret intake path")
    return list(hook) + ["--request", canonical(request)]


def outbound_argv(to, text, fake):
    """The owner-configured outbound sender with the exact recipient and text (a draft card's Send).

    A FAKE record without a configured sender gets `/bin/true`, which a dry run never
    executes anyway; a real record requires the owner's `outbound` policy.
    """
    hook = policy().get("outbound")
    if hook:
        return list(hook) + ["--to", to, "--text", text]
    if fake:
        return ["/bin/true"]
    raise ValueError("no outbound command configured: the owner publishes policy outbound first")


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
        db.execute("INSERT INTO actions(id,fingerprint,intent,spec,gate,status,created) VALUES(?,?,?,?,?,?,?)",
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
    """Only the deciding role, acting from its own gateway, can decide.

    The actor is verified against the invoking gateway's HERMES_HOME, so a bot
    cannot approve by naming the owner on its command line. Profiles share one
    Unix account, so this is a gateway-identity check plus an audit trail
    (actor, pid, time on the record), not authentication against a hostile shell.
    """
    caller = invoking_profile()
    if not caller:
        raise ValueError("decision must come from the deciding profile's own gateway (HERMES_HOME is not set)")
    if actor != caller:
        raise ValueError("actor does not match the invoking gateway profile")
    with database() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT * FROM actions WHERE id=?", (ident,)).fetchone()
        if not row or not row["status"].startswith("awaiting-"):
            raise ValueError("decision is final or task is not awaiting approval")
        expected = policy(db).get(row["gate"])
        if not expected or actor != expected:
            raise ValueError("decision requires " + row["gate"])
        db.execute("UPDATE actions SET status=?,decided_by=?,decided_pid=?,decided_at=? WHERE id=?",
                   ("queued" if approved else "denied", actor, os.getpid(), time.time(), ident))
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
    row = action(ident)
    return (row["status"] in ("queued", "running", "done") and not json.loads(row["spec"]).get("fake")
            and not (state() / "cancelled" / ident).exists())
