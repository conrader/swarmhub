"""Decision 2, per component (CORE-PLAN.md "Decision (Oct 20, 2026)" item 2; phase P2b).

- A data component auto-applies, also when the same bundle carries code.
- A code component whose content is not applied yet waits in `pending_confirm` until the box confirms this bundle
  version (`swarmhub-update apply`, or the Mac confirm in P4c). Re-applying the identical archive the box already
  applied (after `pin previous` is cleared) is not new code and does not wait.
- A data component that declares `requires_component`, directly or through other components, on a waiting code
  component at a version the box has not applied yet waits too, and applies together with that code. A dependency
  the applied version already satisfies does not hold it back.

Pure functions over manifest components and the applied record ({name: {version, sha256, ...}}). Stdlib only.
"""

from . import verify


def same_content(component, applied):
    """True when the box applied exactly this component (same version and archive) at some point."""
    record = applied.get(component["name"])
    return isinstance(record, dict) and record.get("version") == component["version"] \
        and record.get("sha256") == component["sha256"]


def changed(component, applied):
    """True when this component is not live as recorded: never applied, different, or reverted by a local pin."""
    return not same_content(component, applied) or bool(applied[component["name"]].get("reverted"))


def applied_version(name, applied):
    record = applied.get(name)
    version = record.get("version") if isinstance(record, dict) else None
    return verify.version_tuple(version) if isinstance(version, str) and verify.VERSION.fullmatch(version) else None


def _unmet(dep, applied):
    have = applied_version(dep["name"], applied)
    return have is None or have < verify.version_tuple(dep["min_version"])


def split(components, applied, confirmed):
    """(now, waiting) for one verified bundle. `now`: components to apply in this run, in manifest order.
    `waiting`: {name: sorted names of the code components it waits for} (code waits for itself). With
    `confirmed` (this bundle version was confirmed on this box) everything not yet applied goes in `now`."""
    todo = [c for c in components if changed(c, applied)]
    if confirmed:
        return todo, {}
    names = {c["name"] for c in components}
    # Code waits unless it is the very archive this box applied before (re-applied after a local pin).
    blocked = {c["name"]: {c["name"]} for c in todo if c["class"] == "code" and not same_content(c, applied)}
    grew = True
    while grew:  # fixed point: waiting spreads along unmet requires_component edges, transitively
        grew = False
        for component in todo:
            waits = set(blocked.get(component["name"], ()))
            for dep in component["requires_component"]:
                if dep["name"] in names and dep["name"] in blocked and _unmet(dep, applied):
                    waits |= blocked[dep["name"]]
            if waits and waits != blocked.get(component["name"]):
                blocked[component["name"]] = waits
                grew = True
    now = [c for c in todo if c["name"] not in blocked]
    return now, {name: sorted(waits) for name, waits in blocked.items()}


def settle(now, succeeded, applied):
    """Keep names whose dependencies are available, to a fixed point. Used before installation for prepared
    candidates, and afterward for successful results; an already applied dependency can satisfy an edge."""
    by_name = {c["name"]: c for c in now}
    ok = {c["name"] for c in now if c["name"] in succeeded}
    shrank = True
    while shrank:
        shrank = False
        for name in sorted(ok):
            for dep in by_name[name]["requires_component"]:
                if dep["name"] in by_name and dep["name"] not in ok and _unmet(dep, applied):
                    ok.discard(name)
                    shrank = True
                    break
    return ok
