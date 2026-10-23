"""Off-app alerts: tell the owner (ntfy, optional email) what happened on this box while Swarm Hub on the Mac is not
there to show it. One service per box account (`swarmctl alerts run`, supervised by swarm_alerts_service.py).

What it watches, each with a stable id (an id is alerted at most once):
  routine runs   `/api/jobs` of each profile the app connected (settings `profiles`; none from an older app), agent
                 jobs only (a `no_agent` script has no reply) (swarm_alerts_hermes.py); a first sighting is only recorded
  code jobs      managed coding actions that reach done/failed in Swarm Hub's own database
  reports, webhook wakes   spooled by `swarmctl report` and an accepted webhook call (`emit`)
  loops/goals handed to the box   the bot's reply to the job's own delivery in its Bot Chat (matched by the job's name
                 and run, never the chat's newest reply); a done/blocked block pauses the job. Turning alerts off or
                 removing the service pauses every handed-off job first, and changes nothing if one can't be (pause_handoffs)

Before sending: an alert or digest line of a profile no longer in the settings' `profiles` (scope is checked again
here, not only when it was queued) is dropped, and so is `[SILENT]` / `NO_REPLY`; while the app's presence lease is fresh
nothing is sent (the app shows it itself; see docs/offapp-alerts.md); outside the policy's reporting window alerts wait
and go out as one digest when it opens; more than RATE_LIMIT in RATE_WINDOW are held and summarised in one digest. A
failed send is retried with backoff, at most RETRIES times. Settings (with the ntfy token and SMTP password) live only in
alerts/config.json, 0600; nothing here prints an alert, a setting or a secret.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sys
import time

from swarm_intake import write_private
import swarm_store as store
import swarm_alerts_hermes as hermes
import swarm_alerts_seal as seal
import swarm_alerts_service as service
import swarm_alerts_sinks as sinks

SCHEMA = "swarmhub/alerts/1"
TICK, RATE_WINDOW, RATE_LIMIT = 30, 600, 6
RETRIES, KEEP, HANDOFF_WAIT = 5, 7 * 86400, 1800
HERE = Path(__file__).resolve().parent
CODE = ("swarmctl", "swarm_alerts.py", "swarm_alerts_hermes.py", "swarm_alerts_seal.py", "swarm_alerts_service.py",
        "swarm_alerts_sinks.py", "swarm_intake.py", "swarm_policy.py", "swarm_store.py", "swarm_webhook_receiver.py")


def paths():
    folder = service.folder()
    return {"folder": folder, "config": folder / "config.json", "state": folder / "state.json", "spool": folder / "spool",
            "beat": folder / "heartbeat"}


def digest():
    hasher = hashlib.sha256()
    for name in CODE:
        try:
            hasher.update(name.encode() + b"\0" + (HERE / name).read_bytes())
        except OSError:
            hasher.update(name.encode() + b"\0missing")
    return hasher.hexdigest()[:16]


# MARK: settings

def load_config():
    try:
        config = json.loads(paths()["config"].read_text())
    except (OSError, ValueError):
        return None
    return config if isinstance(config, dict) else None


def validate(config):
    if not isinstance(config, dict) or config.get("v") != 1:
        raise ValueError("unsupported alert settings")
    clean = {"v": 1, "enabled": config.get("enabled", True) is not False, "window": config.get("window", True) is not False}
    clean["profiles"] = hermes.allowed_profiles(config.get("profiles"))
    if config.get("ntfy"):
        sinks.check_ntfy(config["ntfy"])
        clean["ntfy"] = {key: config["ntfy"][key] for key in ("url", "token", "priority") if config["ntfy"].get(key)}
    if config.get("email"):
        sinks.check_email(config["email"])
        clean["email"] = {key: config["email"][key] for key in ("host", "port", "security", "user", "password", "from", "to")
                          if config["email"].get(key) not in (None, "")}
    if clean["enabled"] and not (clean.get("ntfy") or clean.get("email")):
        raise ValueError("choose ntfy, email or both")
    return clean


def public_view(config):
    """What the app may see: which sinks are set, never their addresses' secrets."""
    if not config:
        return {"configured": False, "enabled": False, "window": True, "sinks": [], "profiles": []}
    return {"configured": True, "enabled": bool(config.get("enabled")), "window": bool(config.get("window", True)),
            "sinks": [name for name in ("ntfy", "email") if config.get(name)], "profiles": config.get("profiles", [])}


# MARK: state

def load_state():
    try:
        data = json.loads(paths()["state"].read_text())
    except (OSError, ValueError):
        data = {}
    data = data if isinstance(data, dict) else {}
    for key, empty in (("sent", {}), ("marks", {}), ("pending", []), ("deferred", []), ("rate", []), ("held", []),
                       ("handoff", {})):
        if not isinstance(data.get(key), type(empty)):
            data[key] = empty
    data.setdefault("codejobs", None)
    return data


def save_state(data):
    write_private(paths()["state"], json.dumps(data, sort_keys=True).encode())


def emit(kind, ident, title, body=""):
    """A producer's event (report, webhook wake): one spool file, only on a box with alert settings. Never raises."""
    try:
        if not (store.state() / "alerts" / "config.json").exists():
            return False
        spool = paths()["spool"]
        spool.mkdir(mode=0o700, exist_ok=True)
        record = {"id": str(ident)[:200], "kind": kind, "title": str(title)[:200], "body": str(body)[:2000], "at": time.time()}
        write_private(spool / (hashlib.sha256(record["id"].encode()).hexdigest()[:32] + ".json"), json.dumps(record).encode())
        return True
    except Exception:  # noqa: BLE001  An alert never fails the report or the webhook call that caused it.
        return False


def queue(data, alert):
    if alert["id"] in data["sent"] or any(item["id"] == alert["id"] for item in data["pending"]):
        return
    data["pending"].append(dict(alert, attempts=0))


# MARK: sources

def collect_spool(data):
    """Spooled events in the order they happened; the files are removed once the state holding them is saved."""
    files, records = sorted(paths()["spool"].glob("*.json"))[:500] if paths()["spool"].is_dir() else [], []
    for path in files:
        try:
            record = json.loads(path.read_text())
            if all(isinstance(record.get(key), str) for key in ("id", "kind", "title", "body")):
                records.append(record)
        except (OSError, ValueError, AttributeError):
            pass
    for record in sorted(records, key=lambda item: item.get("at") if isinstance(item.get("at"), (int, float)) else 0):
        queue(data, {key: record[key] for key in ("id", "kind", "title", "body")})
    return files


def collect_codejobs(data):
    try:
        with store.database() as db:
            rows = db.execute("SELECT id,spec,status,error FROM actions WHERE status IN ('done','failed')").fetchall()
    except Exception:  # noqa: BLE001  No database yet, or another schema: no code-job alerts.
        return
    finished = {}
    for row in rows:
        try:
            spec = json.loads(row["spec"])
        except (TypeError, ValueError):
            continue
        if spec.get("kind") == "coding" and not spec.get("fake"):
            finished[row["id"]] = (spec, row["status"], row["error"])
    if data["codejobs"] is not None:
        for ident in sorted(set(finished) - set(data["codejobs"])):
            spec, status, error = finished[ident]
            body = str(spec.get("task", ""))[:300] + (f"\n{error}" if status == "failed" and error else "")
            queue(data, {"id": "codejob:" + ident, "kind": "codejob", "body": body,
                         "title": f"Code job {'finished' if status == 'done' else 'failed'} ({spec.get('bot', '?')})"})
    data["codejobs"] = sorted(finished)


def collect_routines(data, now, allowed=(), scripts=None):
    """Queue finished runs of the `allowed` profiles' agent jobs; returns the freshest presence lease seen on any
    profile (0 when none), and adds each script-only job seen to `scripts`. Another profile keeps no marks, so once
    connected its jobs start from a first sighting."""
    present, scripts = 0, set() if scripts is None else scripts
    for profile, env in hermes.profiles():
        rows = hermes.jobs(profile, env)
        if rows is None:
            continue
        present = max(present, hermes.presence_until(rows))
        listed = set()
        scripts.update(f"{profile}/{job.get('id')}" for job in rows if not hermes.agent_job(job))
        for job in rows if profile in allowed else []:
            name = str(job.get("name", ""))
            if name == hermes.PRESENCE or not hermes.agent_job(job):
                continue
            key, last = f"{profile}/{job['id']}", str(job.get("last_run_at") or "")
            listed.add(key)
            if key not in data["marks"]:
                data["marks"][key] = last  # First sighting: only recorded, like the app.
                continue
            if not last or last == data["marks"][key]:
                continue
            previous, data["marks"][key] = data["marks"][key], last
            if hermes.HANDOFF.fullmatch(name):
                # This run's Bot Chat turn comes after the previous run (Hermes records last_run_at after delivering) and
                # after this job was made: the same chat's routine from an earlier quit has the same name.
                since = max(hermes.iso_seconds(previous), hermes.iso_seconds(job.get("created_at")))
                since = since or (hermes.iso_seconds(last) or now) - HANDOFF_WAIT
                item = data["handoff"].get(key)
                if item and item.get("job") == job["id"]:
                    item["until"] = now + HANDOFF_WAIT  # A run whose turn is not in yet keeps its window.
                else:
                    data["handoff"][key] = {"profile": profile, "job": job["id"], "name": name, "since": since,
                                            "until": now + HANDOFF_WAIT}
            else:
                queue(data, hermes.routine_alert(profile, env, job, last))
        for key in [key for key in data["marks"] if key.startswith(profile + "/") and key not in listed]:
            del data["marks"][key]
    return present


def follow_handoffs(data, now, allowed=()):
    """A loop or goal the app handed to the box answers in the Bot Chat: alert with each reply to the job's own
    deliveries (never another reply in the chat), and pause the job when one ends it (a loop's done block, a goal's done
    or blocked block). The handoff stays while a delivered turn has no reply yet, until HANDOFF_WAIT. A profile the app
    no longer connects is still paused at the end, but not alerted."""
    envs = dict(hermes.profiles())
    for key, item in list(data["handoff"].items()):
        env = envs.get(item.get("profile"))
        if item.get("ending"):  # Fails closed: past HANDOFF_WAIT, its pause is retried until confirmed, then alerted.
            if env is not None and hermes.confirm_paused(item["profile"], env, item["job"]):
                ending = data["handoff"].pop(key)["ending"]
                if item["profile"] in allowed:
                    queue(data, ending)
            continue
        if env is None or now > item.get("until", 0):
            del data["handoff"][key]
            continue
        turns = hermes.bot_chat_turns(item["profile"], env, item["name"], item["since"])
        if not turns:
            continue
        kind = "goal" if "-goal-" in item["name"] else "loop"
        for when, text in turns:
            if text is None:
                break  # Its reply is not in yet; later turns wait behind it.
            item["since"] = when
            block = hermes.block_status(text)
            ended = block is not None and block[0] == kind and (block[1] == "done" or kind == "goal")
            visible = hermes.FENCE.sub("", text).strip() or (f"{kind.capitalize()} {block[1]}." if block else "")
            title = f"{'Goal' if kind == 'goal' else 'Loop'} on the box ({item['profile']})" + (f": {block[1]}" if ended else "")
            item["ending"] = {"id": f"{kind}:{key}:{when}", "kind": kind, "title": title, "body": visible,
                              "profile": item["profile"], "job": item["job"]}
            if ended and not hermes.confirm_paused(item["profile"], env, item["job"]):
                break  # Still scheduled: kept, and paused (then alerted) on a later tick.
            ending = item.pop("ending")
            if item["profile"] in allowed:
                queue(data, ending)
        else:
            del data["handoff"][key]


# MARK: sending

def in_window(config, now):
    if not config.get("window", True):
        return True
    try:
        import swarm_policy
        return swarm_policy.in_report_window(now)
    except Exception:  # noqa: BLE001  An unreadable policy never holds an alert back.
        return True


def mark(data, ident, outcome, now):
    data["sent"][ident] = [now, outcome]


def send(data, config, title, body, now, deliver):
    results = deliver(config, title, body[:1500])
    failures = [f"{name}: {line[7:]}" for name, line in sorted(results.items()) if line != "sent"]
    data["last_error"] = "; ".join(failures) or None
    if failures:
        data["last_error_at"] = now
    if len(failures) < len(results):
        data["rate"].append(now)
        data["last_sent_at"] = now
        return True
    return False


def dispatch(data, config, now, present_until, deliver=None, scripts=()):
    """Sends the queue. Scope is checked here too (`hermes.in_scope`, the settings' `profiles`): an alert or digest line
    of a profile the app no longer connects, or of a script-only job, is dropped; so is a digest line an older skill
    kept as a bare title (its scope can't be told)."""
    deliver, allowed = deliver or sinks.deliver, config.get("profiles") or []

    def fits(alert):
        return isinstance(alert, dict) and hermes.in_scope(alert, allowed, scripts)
    data["sent"] = {key: value for key, value in data["sent"].items() if isinstance(value, list) and now - value[0] < KEEP}
    data["rate"] = [stamp for stamp in data["rate"] if now - stamp < RATE_WINDOW]
    present, open_now = present_until > now, in_window(config, now)
    keep = []
    for alert in data["pending"]:
        ident = alert["id"]
        if ident in data["sent"]:
            continue
        if not fits(alert):
            mark(data, ident, "out of scope", now)
        elif sinks.silent(alert.get("body", "")):
            mark(data, ident, "silent", now)
        elif present:
            mark(data, ident, "app", now)  # The app is there and shows it; see docs/offapp-alerts.md.
        elif not open_now:
            data["deferred"] = (data["deferred"] + [hermes.digest_entry(alert)])[-50:]
            mark(data, ident, "deferred", now)
        elif alert.get("retry_at", 0) > now:
            keep.append(alert)
        elif len(data["rate"]) >= RATE_LIMIT:
            data["held"] = (data["held"] + [hermes.digest_entry(alert)])[-50:]
            mark(data, ident, "held", now)
        elif send(data, config, alert["title"], alert.get("body", ""), now, deliver):
            mark(data, ident, "sent", now)
        else:
            alert["attempts"] = alert.get("attempts", 0) + 1
            alert["retry_at"] = now + 60 * 2 ** alert["attempts"]
            if alert["attempts"] < RETRIES:
                keep.append(alert)
            else:
                mark(data, ident, "failed", now)
    data["pending"] = keep
    for key in ("deferred", "held"):
        data[key] = [entry for entry in data[key] if fits(entry)]
    if present:
        data["deferred"], data["held"] = [], []
        return
    if open_now and data["deferred"] and send(data, config, f"{len(data['deferred'])} alerts from outside the report window",
                                              sinks.digest_body(data["deferred"]), now, deliver):
        data["deferred"] = []
    if open_now and data["held"] and len(data["rate"]) < RATE_LIMIT and send(
            data, config, f"{len(data['held'])} more alerts were held back", sinks.digest_body(data["held"]), now, deliver):
        data["held"] = []


def pause_handoffs():
    """Alerts going off (or the service going away) leave nothing to end a handed-off loop or goal when its reply says
    done: each one still scheduled is paused here, and the app takes it back paused at its next launch. Fails closed: a
    job list that can't be read or a pause that fails raises, before anything is saved or removed, so the service stays
    on and keeps ending them, and the next try pauses them again."""
    unread, failed = [], 0
    for profile, env in hermes.profiles():
        rows = hermes.jobs(profile, env)
        if rows is None:
            unread.append(profile)
            continue
        for job in rows:
            if hermes.HANDOFF.fullmatch(str(job.get("name", ""))) and job.get("enabled", True) is not False:
                failed += not hermes.pause(profile, env, job["id"])
    if unread or failed:
        why = (f"the routines of profile {', '.join(unread)} could not be read" if unread else "")
        why += ("; " if unread and failed else "") + (f"{failed} could not be paused" if failed else "")
        raise ValueError(f"alerts stay on: loops or goals handed to this box must be paused first, and {why}. "
                         "Try again when Hermes answers.")


def tick(now=None, deliver=None):
    now = now or time.time()
    p = paths()
    p["beat"].write_text(str(int(now)))
    config, data = load_config(), load_state()
    files = collect_spool(data)
    present = 0
    if config and config.get("enabled"):
        collect_codejobs(data)
        scripts = set()
        present = collect_routines(data, now, config.get("profiles") or [], scripts)
        follow_handoffs(data, now, config.get("profiles") or [])
        dispatch(data, config, now, present, deliver, scripts)
    else:
        data["pending"] = []
    data["presence_until"] = present
    save_state(data)
    for path in files:
        path.unlink(missing_ok=True)


def run(fallback=False, once=False, sleep=time.sleep):
    """The service loop. One per account (the lock); a second waits until the first hands over."""
    p = paths()
    lock_path = service.fallback_paths()["lock"]
    with lock_path.open("a+") as lock:
        while True:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if once or (fallback and not service.fallback_paths()["marker"].exists()):
                    return 0
                sleep(5)
        lock.seek(0)
        lock.truncate()
        lock.write(str(os.getpid()))
        lock.flush()
        code = digest()
        print(f"swarmhub-alerts: running (pid {os.getpid()}, code {code})", file=sys.stderr, flush=True)
        while True:
            if fallback and not service.fallback_paths()["marker"].exists():
                return 0
            try:
                tick()
            except Exception as exc:  # noqa: BLE001  The type only: an alert's text or a setting never reaches a log.
                print("swarmhub-alerts: tick failed: " + type(exc).__name__, file=sys.stderr, flush=True)
            if once:
                return 0
            for _ in range(TICK):
                if fallback and not service.fallback_paths()["marker"].exists():
                    return 0
                sleep(1)
            if digest() != code:
                print("swarmhub-alerts: code changed on disk; restarting", file=sys.stderr, flush=True)
                lock.seek(0)
                lock.truncate()
                fcntl.flock(lock, fcntl.LOCK_UN)
                os.execv(sys.executable, [sys.executable, "-B", str(HERE / "swarmctl"), "alerts", "run"]
                         + (["--fallback"] if fallback else []))
    return 0


# MARK: the app's panel call

def status(now=None):
    now = now or time.time()
    installed = service.status()
    try:
        beat = int(paths()["beat"].read_text().strip())
    except (OSError, ValueError):
        beat = 0
    data = load_state()
    running = now - beat < 3 * TICK
    if running:
        detail = "Running."
    elif not installed["installed"]:
        detail = "The alert service is not installed on this box. Save the settings to start it."
    else:
        detail = f"Installed ({installed['service']}) but not running. Logs: {installed['logs']}"
    return dict(installed, running=running, detail=detail, heartbeat=beat or None, last_error=data.get("last_error"),
                last_error_at=data.get("last_error_at"), last_sent_at=data.get("last_sent_at"),
                presence_until=data.get("presence_until") or None, pending=len(data["pending"]))


def configure(blob):
    plain = seal.open_sealed(seal.box_key(paths()["folder"]), blob)
    try:
        raw = json.loads(plain.decode("utf-8"))
    except ValueError:  # UnicodeDecodeError and JSONDecodeError both
        raise ValueError("the sealed alert settings are not valid JSON") from None
    config = validate(raw)
    if not config["enabled"]:
        pause_handoffs()
    previous = load_config() or {}
    write_private(paths()["config"], json.dumps(config, sort_keys=True).encode())
    if config["enabled"] and not previous.get("enabled"):
        data = load_state()
        data.update(marks={}, codejobs=None, pending=[], deferred=[], held=[], handoff={})  # Nothing from before.
        save_state(data)
    if config["enabled"]:
        return start()
    return dict(service.uninstall(), saved=True)


def start():
    try:
        return dict(service.install(), saved=True)
    except ValueError as exc:
        return {"saved": True, "error": str(exc)}


def test():
    config = load_config()
    if not config:
        raise ValueError("save the alert settings first")
    results = sinks.deliver(config, "Swarm Hub test alert", "This box can reach you. Real alerts come only while Swarm Hub "
                            "on your Mac is closed or you are away from it.")
    data = load_state()
    send(data, config, "", "", time.time(), lambda *_: results)
    save_state(data)
    return {"sinks": results}


def panel(action, blob=None):
    """One call of the app: the action, then the settings summary, the service state and the box's sealing key."""
    if action == "configure":
        result = configure(blob)
    elif action == "test":
        result = test()
    elif action == "install":
        result = start()
    elif action == "uninstall":
        pause_handoffs()
        result = service.uninstall()
    elif action != "status":
        raise ValueError("alerts panel status|configure <sealed>|test|install|uninstall")
    else:
        result = None
    return {"schema": SCHEMA, "action": action, "result": result, "config": public_view(load_config()),
            "service": status(), "box_key": seal.b64(seal.public(seal.box_key(paths()["folder"])))}
