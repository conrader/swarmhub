"""Decision 2 on a verified bundle, through the P2a apply engine, and the status file (phase P2b).

`apply_bundle` splits the bundle (policy.split): what may apply now goes through apply.apply for skills (rendered
per profile, checked, idle wait, atomic swap) and is recorded for the other kinds; code and the data waiting on it
stay `pending_confirm` until this bundle version is confirmed on this box. A component counts as applied only when
every profile that installs it applied it and nothing it needs from the same run failed (policy.settle).

Profiles come from the state's profiles.json (written by `apply --staged` from a staged profiles.json). Without one
the updater only updates skills already installed in a profile, and holds a skill that renders a coding order
(its order is not recorded on the box) rather than guess it. `tool`, `config` and `ui` components are recorded and
kept in the state's blob store; `manager-prompts` feeds the manager skill's render. Nothing else on the box reads
them yet, and nothing outside `skills/swarmhub/` and the state directory is written. Stdlib only, Python 3.8+.
"""

from collections import namedtuple
import os
import time

from . import VERSION, apply, bundle, idle, pins as pinfile, policy, render, stage

Report = namedtuple("Report", "succeeded errors held results")
GOOD = ("applied", "unchanged")


class Box:
    def __init__(self, hermes_home, state, pins, now, max_wait=idle.DEFAULT_MAX_WAIT, poll=idle.DEFAULT_POLL):
        self.hermes_home, self.state, self.pins, self.now = hermes_home, state, pins, now
        self.max_wait, self.poll = max_wait, poll


def discover(hermes_home, skill_names=None):
    """Profiles with swarmhub skills installed: [{name, coding_order None, skills}]. Never adds a skill."""
    homes = [("default", hermes_home)]
    folder = os.path.join(hermes_home, "profiles")
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name != "default" and render.is_valid_profile_name(name):
            homes.append((name, os.path.join(folder, name)))
    found = []
    for name, home in homes:
        category = os.path.join(home, *stage.CATEGORY_PARTS)
        present = sorted(n for n in os.listdir(category) if not n.startswith(".")) if os.path.isdir(category) else []
        installed = [n for n in present if os.path.isdir(os.path.join(category, n))
                     and (skill_names is None or n in skill_names)]
        if installed:
            found.append({"name": name, "coding_order": None, "skills": installed})
    return found


def profiles_for(box, skill_names=None):
    """Configured profiles (ValueError when profiles.json is malformed), else the discovered ones."""
    configured = box.state.profiles()
    return configured if configured is not None else discover(box.hermes_home, skill_names)


def _manager_text(box, verified, names_now, comps, errors):
    work = box.state.path("work")
    component = next((c for c in verified.apply if c["name"] == bundle.MANAGER_PROMPTS), None)
    try:
        if component is not None and component["name"] in names_now:
            return bundle.manager_template(work, component, verified.blobs[component["name"]])
        record = comps.get(bundle.MANAGER_PROMPTS)
        blob = box.state.blob(record.get("sha256")) if isinstance(record, dict) else None
        if blob is not None:
            return bundle.manager_template(work, {"name": bundle.MANAGER_PROMPTS, "kind": "config"}, blob)
    except bundle.ComponentError as error:
        if component is not None and component["name"] in names_now:
            errors[component["name"]] = str(error)
    return None


def _apply_now(box, verified, now, waiting, comps):
    names_now = {c["name"] for c in now}
    errors, held, results = {}, {}, {}
    template = _manager_text(box, verified, names_now, comps, errors)
    skills = [c for c in now if c["kind"] == "skill"]
    manager = next((c for c in verified.apply if c["name"] == render.MANAGER_SKILL), None)
    if bundle.MANAGER_PROMPTS in names_now and bundle.MANAGER_PROMPTS not in errors and manager is not None \
            and manager["name"] not in names_now and manager["name"] not in waiting:
        skills.append(manager)  # unchanged skill, rendered again with the new manager text
    loaded = {}
    for component in skills:
        try:
            skill = bundle.load_skill(box.state.path("work"), component, verified.blobs[component["name"]])
        except bundle.ComponentError as error:
            errors[component["name"]] = str(error)
            continue
        if "{{MANAGER_TEXT}}" in skill.template and template is None:
            errors[component["name"]] = "no applied %s to render the manager text from" % bundle.MANAGER_PROMPTS
            continue
        loaded[component["name"]] = skill
    targets, entries = [], []
    try:
        entries = profiles_for(box, set(loaded)) if loaded else []
    except ValueError as error:
        errors.update((name, str(error)) for name in loaded)
        loaded = {}
    if loaded:
        for entry in entries:
            wanted = set(loaded) if entry["skills"] is None else set(entry["skills"]) & set(loaded)
            if entry["coding_order"] is None:
                for name in sorted(wanted):
                    if render.variant(loaded[name], render.STANDARD_ORDER):
                        held.setdefault(name, []).append(entry["name"])
                        wanted.discard(name)
            if wanted:
                targets.append(stage.Profile(entry["name"], entry["coding_order"] or render.STANDARD_ORDER,
                                             tuple(sorted(wanted))))
    # Settle preparation failures before passing anything to the engine: adjusting records after a swap
    # cannot undo dependent data that already landed. Include held/dropped skills and transitive edges.
    targeted = {name for p in targets for name in p.skills}
    unavailable = set(errors) | set(held) | (set(loaded) - targeted)
    ready = policy.settle(now, names_now - unavailable, comps)
    while True:  # A dependency also has to be eligible in each profile that would install its data.
        blocked = set()
        for target in targets:
            available = ready - (set(loaded) - set(target.skills))
            allowed = policy.settle(now, available, comps)
            blocked |= (set(target.skills) & ready) - allowed
        if not blocked:
            break
        ready = policy.settle(now, ready - blocked, comps)
    for name in names_now - unavailable - ready:
        errors[name] = "held: required component unavailable before install"
    loaded = {name: skill for name, skill in loaded.items() if name not in names_now or name in ready}
    eligible = []
    for target in targets:
        wanted = tuple(n for n in target.skills if n in loaded)
        if wanted:
            eligible.append(stage.Profile(target.name, target.coding_order, wanted))
    targets = eligible
    if targets:
        for result in apply.apply(box.hermes_home, box.state.root, [loaded[n] for n in sorted(loaded)], template,
                                  targets, max_wait=box.max_wait, poll=box.poll):
            results[result.profile] = result
    succeeded = set()
    for component in now:
        name = component["name"]
        if name not in ready:
            continue
        if component["kind"] == "skill" and not all(results[p.name].status in GOOD
                                                     for p in targets if name in p.skills):
            continue
        succeeded.add(name)
    return Report(succeeded, errors, {k: sorted(v) for k, v in held.items()}, results)


def is_confirmed(record, verified):
    """A confirm covers one bundle version on this box, and only the manifest that was confirmed."""
    return record.get("confirmed_version") == verified.version \
        and record.get("confirmed_manifest_sha256") == verified.manifest_sha256


def apply_bundle(box, verified, confirm=False):
    """Apply what decision 2 allows of `verified` now (all of it once confirmed). Returns the run summary."""
    record = box.state.applied()
    comps = record["components"]
    if confirm:
        record.update(confirmed_version=verified.version, confirmed_manifest_sha256=verified.manifest_sha256)
        box.state.save_applied(record)
    confirmed = is_confirmed(record, verified)
    now, waiting = policy.split(verified.apply, comps, confirmed)
    if record.get("pin"):
        return {"state": "pinned", "detail": "local pin (%s): nothing applies" % record["pin"].get("mode"),
                "waiting": waiting, "not_applied": [c["name"] for c in now], "report": Report(set(), {}, {}, {})}
    report = _apply_now(box, verified, now, waiting, comps)
    done = policy.settle(now, report.succeeded, comps)
    for component in now:
        if component["name"] in done:
            comps[component["name"]] = {key: component[key] for key in ("version", "sha256", "kind", "class")}
    not_applied = [c["name"] for c in now if c["name"] not in done]
    if not not_applied and not waiting:
        record["bundle_version"] = verified.version
    box.state.save_applied(record)
    keep = {r["sha256"] for r in comps.values() if isinstance(r, dict)} | {c["sha256"] for c in verified.apply}
    box.state.prune_blobs(keep)
    return {"state": _state(report, not_applied, waiting), "detail": _detail(report, not_applied, waiting),
            "waiting": waiting, "not_applied": not_applied, "report": report}


def _state(report, not_applied, waiting):
    statuses = {r.status for r in report.results.values()}
    if "recovery_pending" in statuses:
        return "recovery_pending"
    if report.errors or "failed" in statuses:
        return "failed"
    if "deferred" in statuses:
        return "deferred"
    if waiting:
        return "pending_confirm"
    return "held" if report.held or not_applied else "current"


def _detail(report, not_applied, waiting):
    parts = ["%s: %s" % (name, error) for name, error in sorted(report.errors.items())]
    parts += ["%s %s: %s" % (p, r.status, r.detail) for p, r in sorted(report.results.items()) if r.status not in GOOD]
    parts += ["%s held in %s: coding order unknown (no profiles.json)" % (n, ", ".join(p))
              for n, p in sorted(report.held.items())]
    if waiting:
        parts.append("waiting for confirm: %s" % ", ".join(sorted(waiting)))
    return "; ".join(parts) if parts or not_applied else "up to date"


# ---- status file -------------------------------------------------------------------------------------------------

def pending_confirm(verified, waiting):
    if not waiting:
        return None
    by_name = {c["name"]: c for c in verified.apply}
    code = [{"name": n, "version": by_name[n]["version"], "kind": by_name[n]["kind"]}
            for n in sorted(waiting) if by_name[n]["class"] == "code"]
    data = [{"name": n, "version": by_name[n]["version"], "kind": by_name[n]["kind"], "waits_for": waiting[n]}
            for n in sorted(waiting) if by_name[n]["class"] == "data"]
    return {"bundle_version": verified.version, "label": verified.label, "code": code, "data": data}


def _profiles_view(box):
    view = {}
    try:
        entries = profiles_for(box)
    except ValueError:
        entries = discover(box.hermes_home)
    for entry in entries:
        record = apply.read_record(box.state.root, entry["name"])
        record = record if isinstance(record, dict) else {}
        try:
            category = stage.category_dir(box.hermes_home, entry["name"])
        except stage.StageError:
            continue
        present = sorted(n for n in os.listdir(category) if not n.startswith(".")) if os.path.isdir(category) else []
        view[entry["name"]] = {"status": record.get("status"), "detail": record.get("detail"),
                               "reload_pending": bool(record.get("reload_pending")),
                               "advertised": {n: bundle.live_advertised(category, n) for n in present
                                              if os.path.isdir(os.path.join(category, n))}}
    return view


def write_status(box, command, verdict, run=None, verified=None, stale=None):
    """Merge this command's outcome into status.json. A refused bundle never changes what is reported as applied."""
    status = box.state.status() or {"state": "unknown", "detail": "nothing applied yet"}
    record = box.state.applied()
    meta = box.state.read_json("latest.json")
    if run is not None:
        status.update(state=run["state"], detail=run["detail"],
                      pending_confirm=pending_confirm(verified, run["waiting"]) if verified else None,
                      skipped=verified.skipped if verified else [])
    if stale is not None:
        status["stale"] = stale
    if meta and meta.get("verified_at") and status.get("stale") is None:
        status["stale"] = False
    if box.pins is not None:
        status["pins"] = pinfile.summary(box.pins)
        status["floors"] = {"state": box.state.floors(), "checkpoint": dict(box.pins.checkpoint),
                            "effective": pinfile.effective_floors(box.pins.checkpoint, box.state.floors())}
    profiles = _profiles_view(box)
    status.update(updater=VERSION, at=box.now, bundle=meta, applied_bundle_version=record.get("bundle_version", 0),
                  confirmed_version=record.get("confirmed_version", 0), pin=record.get("pin"),
                  components={n: {"version": r.get("version"), "kind": r.get("kind"), "class": r.get("class")}
                              for n, r in sorted(record["components"].items()) if isinstance(r, dict)},
                  profiles=profiles, reload_pending=any(p["reload_pending"] for p in profiles.values()),
                  last=dict(verdict, command=command, at=box.now))
    if record.get("pin"):
        status["state"] = "pinned"
    elif status.get("state") == "pinned":  # pin cleared with nothing stored to apply
        status["state"], status["detail"] = ("current" if record.get("bundle_version") else "unknown"), "pin cleared"
    box.state.save_status(status)
    return status


def utc_now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
