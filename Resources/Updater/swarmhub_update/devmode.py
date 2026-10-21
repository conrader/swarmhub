"""Per-bot skill dev mode on the box: the Mac app's per-bot toggle, carried as `dev_mode` in profiles.json.

While a profile's dev mode is on, the updater does not overwrite a skill the bot changed on its box. A skill is
"modified locally" when `~/.hermes/swarmhub/dev-overrides/<profile>/<skill>/` exists, or when its live folder is
neither the bundled copy about to be installed nor provably what SwarmHub last installed there: the content digest
recorded then (`~/.hermes/swarmhub/dev-baseline/<profile>/<skill>.sha256`, written only in dev mode, also by the
app's legacy install guard) or the tree the updater bound when it last applied the skill (the profile record's
`variants`). With no such record a differing skill is kept: dev mode never guesses in favour of overwriting. A kept
skill keeps its recorded version, is never a failure (the run stays applied/unchanged), and the status reports it in
the profile's `modified` list.

`reset` (the app's "Reset to bundled", pending in applied.json until installed) installs the bundled copy regardless,
then removes the override folder and records a fresh baseline. Dev mode off and no reset: nothing here runs, reads or
writes, and the engine behaves exactly as before.

The content digest must match the app's (`SkillDevMode.contentDigest`) and the legacy guard's
(`SkillDevMode.guardScript`): regular files only, `__pycache__` folders skipped, each file as its UTF-8 path, NUL,
"x" or "-" (owner execute bit), NUL and the SHA-256 of its bytes, in path byte order. Folder modes and the umask do not
count; a link or special file anywhere makes the folder unreadable (None), which counts as modified.
Stdlib only, Python 3.8+.
"""

import hashlib
import os
import re
import shutil
import stat

from . import render, stage

HEX64 = re.compile(r"\A[0-9a-f]{64}\Z")
GOOD = ("applied", "unchanged")


def active(profile):
    """True when this stage.Profile needs dev-mode handling at all."""
    return bool(profile.dev_mode or profile.reset)


def overrides_dir(hermes_home, profile, skill):
    return os.path.join(hermes_home, "swarmhub", "dev-overrides", profile, skill)


def baseline_path(hermes_home, profile, skill):
    return os.path.join(hermes_home, "swarmhub", "dev-baseline", profile, skill + ".sha256")


def _hash(items):
    """items: (path bytes, executable, data bytes) in any order."""
    hasher = hashlib.sha256()
    for path, executable, data in sorted(items, key=lambda item: item[0]):
        hasher.update(path + b"\0" + (b"x" if executable else b"-") + b"\0")
        hasher.update(hashlib.sha256(data).digest())
    return hasher.hexdigest()


def content_digest(folder):
    """The dev-mode digest of a live folder; None when it is missing or holds a link or special file."""
    if os.path.islink(folder) or not os.path.isdir(folder):
        return None
    items = []
    for directory, folders, names in os.walk(folder):
        if any(os.path.islink(os.path.join(directory, name)) for name in folders):
            return None
        folders[:] = [name for name in folders if name != "__pycache__"]
        for name in names:
            full = os.path.join(directory, name)
            info = os.lstat(full)
            if not stat.S_ISREG(info.st_mode):
                return None
            with open(full, "rb") as handle:
                data = handle.read()
            items.append((os.path.relpath(full, folder).replace(os.sep, "/").encode("utf-8"),
                          bool(info.st_mode & stat.S_IXUSR), data))
    return _hash(items)


def files_digest(files):
    """The digest a folder holding exactly `files` (render.SkillFile, as stage.write_tree writes them) has."""
    return _hash((f.path.encode("utf-8"), bool(stage.file_mode(f.path) & stat.S_IXUSR), f.content.encode("utf-8"))
                 for f in files)


def read_baseline(hermes_home, profile, skill):
    try:
        with open(baseline_path(hermes_home, profile, skill), "rb") as handle:
            value = handle.read(128).decode("ascii").strip()
    except (OSError, UnicodeDecodeError):
        return None
    return value if HEX64.fullmatch(value) else None


def _bound(record, skill, live):
    """The updater's own record of the tree it last applied for `skill` still matches the live folder."""
    variants = record.get("variants") if isinstance(record, dict) else None
    row = variants.get(skill) if isinstance(variants, dict) else None
    return isinstance(row, dict) and isinstance(row.get("tree"), str) and row["tree"] == stage.tree_digest(live)


def modified(hermes_home, record, profile, skill, live):
    """True when dev mode must treat live `skill` as the bot's own: an override folder, or a live folder that matches
    neither the recorded baseline nor the updater's bound tree. An absent skill is not modified."""
    if os.path.lexists(overrides_dir(hermes_home, profile, skill)):
        return True
    if not os.path.lexists(live):
        return False
    current = content_digest(live)
    if current is None:
        return True
    return current != read_baseline(hermes_home, profile, skill) and not _bound(record, skill, live)


def keeps(hermes_home, record, profile, skill, live, files):
    """`modified`, except that a live folder already identical to the bundled copy is never kept."""
    if os.path.lexists(overrides_dir(hermes_home, profile, skill)):
        return True
    current = content_digest(live) if os.path.lexists(live) else None
    if current is not None and current == files_digest(files):
        return False
    return modified(hermes_home, record, profile, skill, live)


def write_baseline(hermes_home, profile, skill, live):
    """Record what is live now as SwarmHub's install. Best effort: without it the skill later reads as modified."""
    digest = content_digest(live)
    if digest is None:
        return
    path = baseline_path(hermes_home, profile, skill)
    try:
        os.makedirs(os.path.dirname(path), 0o700, exist_ok=True)
        temporary = path + ".tmp"
        with open(temporary, "w") as handle:
            handle.write(digest + "\n")
        os.replace(temporary, path)
    except OSError:
        pass


def remove_override(hermes_home, profile, skill):
    """Delete the override folder of `skill`, only when its parent really is ~/.hermes/swarmhub/dev-overrides/<profile>
    (no link along the way can point the delete elsewhere)."""
    target = overrides_dir(hermes_home, profile, skill)
    parent = os.path.dirname(target)
    expected = os.path.join(os.path.realpath(hermes_home), "swarmhub", "dev-overrides", profile)
    if not os.path.lexists(target) or os.path.realpath(parent) != expected:
        return
    if os.path.islink(target) or not os.path.isdir(target):
        os.unlink(target)
    else:
        shutil.rmtree(target)


def run(apply_profile, read_record, hermes_home, state_dir, skills, manager_template, profile, deadline, poll):
    """apply.apply_profile with dev mode: kept skills are left alone, and after a good run every skill that was
    installed or found current gets its baseline and every reset skill loses its override folder."""
    if not active(profile):
        return apply_profile(hermes_home, state_dir, skills, manager_template, profile, deadline, poll)
    record = read_record(state_dir, profile.name)
    reset, kept = set(profile.reset), []

    def keep(category, skill, files):
        if not profile.dev_mode or skill in reset or \
                not keeps(hermes_home, record, profile.name, skill, os.path.join(category, skill), files):
            return False
        kept.append(skill)
        return True

    result = apply_profile(hermes_home, state_dir, skills, manager_template, profile, deadline, poll, keep=keep)
    if result.status in GOOD:
        category = stage.category_dir(hermes_home, profile.name)
        for skill in skills:
            name = skill.name
            if name in kept or (profile.skills is not None and name not in profile.skills):
                continue
            if name in reset:
                remove_override(hermes_home, profile.name, name)
            write_baseline(hermes_home, profile.name, name, os.path.join(category, name))
    return result


def split_reset(doc):
    """A staged swarmhub/profiles/1 document → (the document to persist, without `reset`; {profile: [skills]})."""
    if not isinstance(doc, dict) or not isinstance(doc.get("profiles"), list):
        return doc, {}
    rows, resets = [], {}
    for row in doc["profiles"]:
        if isinstance(row, dict) and "reset" in row:
            row = dict(row)
            resets[row.get("name")] = sorted(set(row.pop("reset") or []))
        rows.append(row)
    return dict(doc, profiles=rows), resets


def check_row(entry):
    """Validate a profile row's dev-mode keys; returns {"dev_mode": True} for the checked row when it is on, else {}.
    A `reset` is validated but never returned: requests (`split_reset`) queue it separately in applied.json, so a
    stale or hand-edited profiles.json can never reset a skill again on a later run."""
    if "dev_mode" in entry and not isinstance(entry["dev_mode"], bool):
        raise ValueError("profiles.json: dev_mode of %s must be true or false" % entry["name"])
    reset = entry.get("reset")
    if reset is not None and not (isinstance(reset, list) and all(render.is_valid_profile_name(s) for s in reset)):
        raise ValueError("profiles.json: reset of %s must be a list of names" % entry["name"])
    return {"dev_mode": True} if entry.get("dev_mode") is True else {}
