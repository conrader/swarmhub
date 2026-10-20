"""The apply engine (CORE-PLAN.md §3.4, phase P2a): stage, check, wait for idle, swap, keep `previous`, revert.

Per profile, `apply` renders the given skills (render.py), writes every changed skill into a transaction folder under
`skills/swarmhub/.archive/swarmhub-update/txn-*/swap/<skill>` and runs the post-apply checks there (stage.py). Only
when all pass does it wait for the box to be idle (idle.py, bounded: past the bound the run is `deferred` and nothing
live changes). Then each live `skills/swarmhub/<skill>` is exchanged with its staged folder in one atomic rename
(`renameat2(RENAME_EXCHANGE)` on Linux, `renamex_np(RENAME_SWAP)` on macOS; three plain renames where the file
system refuses). Running processes keep their open files: a rename never touches the inodes they hold. The live
trees are then compared with what was staged; any error before the commit swaps every changed skill back, so
`current` ends byte-identical. After the commit the replaced folders move to `previous/<skill>` (a newly installed
skill leaves `previous/<skill>.absent`), and `revert` swaps `previous` back in through the same path.

A journal written before the first swap records each skill's old and new tree digests, so a run that dies
mid-swap is rolled back (or, if it had committed, finished) by the next run, deciding from the digests on disk.
A change to the peer plugin's code sets `reload_pending` in the profile's state record; nothing is ever restarted
or signalled. Writes: the profile's `skills/swarmhub/` and `state_dir` only. Stdlib only, Python 3.8+.
"""

from collections import namedtuple
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import json
import os
import shutil
import sys
import time

from . import idle, render, stage

Result = namedtuple("Result", "profile status detail versions reload_pending")  # status: see STATUSES
STATUSES = ("applied", "reverted", "unchanged", "deferred", "failed")
MESSAGES_SKILL = "swarmhub-messages"
JOURNAL = "journal.json"
LOCK = "apply.lock"
ATOMIC_EXCHANGE = True  # tests turn it off to exercise the rename fallback
_UNSUPPORTED = {errno.ENOSYS, errno.EINVAL, errno.ENOTSUP, getattr(errno, "EOPNOTSUPP", errno.ENOTSUP)}


class Busy(Exception):
    """Another updater run holds the lock."""


def exchange(a, b):
    """Atomically exchange two existing paths. False when this OS or file system cannot; raises other errors."""
    if not ATOMIC_EXCHANGE:
        return False
    try:
        libc = ctypes.CDLL(None, use_errno=True)
    except OSError:
        return False
    if sys.platform.startswith("linux"):
        call = getattr(libc, "renameat2", None)
        if call is None:
            return False
        call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        result = call(-100, os.fsencode(a), -100, os.fsencode(b), 2)  # AT_FDCWD, RENAME_EXCHANGE
    elif sys.platform == "darwin":
        call = getattr(libc, "renamex_np", None)
        if call is None:
            return False
        call.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        result = call(os.fsencode(a), os.fsencode(b), 2)  # RENAME_SWAP
    else:
        return False
    if result == 0:
        return True
    code = ctypes.get_errno()
    if code in _UNSUPPORTED:
        return False
    raise OSError(code, os.strerror(code), a)


def _swap(slot, live, spare):
    """Swap the contents of `slot` and `live` (both exist): atomic exchange, else live→spare, slot→live, spare→slot."""
    if exchange(slot, live):
        return
    os.rename(live, spare)
    os.rename(slot, live)
    os.rename(spare, slot)


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_json(path, value, mode):
    temporary = "%s.%d.tmp" % (path, os.getpid())
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    try:
        os.write(fd, (json.dumps(value, sort_keys=True, indent=1) + "\n").encode("utf-8"))
        os.fchmod(fd, mode)
        os.fsync(fd)
    finally:
        os.close(fd)
    os.replace(temporary, path)
    _fsync_dir(os.path.dirname(path))


@contextmanager
def locked(state_dir):
    """One updater run at a time per state dir (flock on `state_dir/apply.lock`); Busy when another holds it."""
    os.makedirs(state_dir, 0o700, exist_ok=True)
    fd = os.open(os.path.join(state_dir, LOCK), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Busy() from None
        yield
    finally:
        os.close(fd)


# ---- transaction folders --------------------------------------------------------------------------------------

def _paths(category, txn, skill):
    return (os.path.join(category, skill), os.path.join(txn, "swap", skill), os.path.join(txn, "spare", skill))


def _previous(category):
    return os.path.join(stage.work_dir(category), "previous")


def _new_txn(category):
    work = stage.work_dir(category)
    os.makedirs(work, stage.DIR_MODE, exist_ok=True)
    txn = os.path.join(work, "txn-%d-%d" % (time.time_ns(), os.getpid()))
    os.mkdir(txn, 0o700)
    os.mkdir(os.path.join(txn, "swap"), 0o700)
    os.mkdir(os.path.join(txn, "spare"), 0o700)
    return txn


def _discard(txn):
    """Remove a finished or abandoned transaction folder; whatever cannot be removed now, `recover` retries."""
    shutil.rmtree(txn, ignore_errors=True)


def _swap_entry(category, txn, entry):
    live, slot, spare = _paths(category, txn, entry["skill"])
    if entry["action"] == "replace":
        _swap(slot, live, spare)
    elif entry["action"] == "install":
        os.rename(slot, live)
    else:  # remove
        os.rename(live, slot)


def _undo_entry(category, txn, entry, swapped=None):
    """Put the old tree back live. `swapped` True/False: this run knows whether the entry's swap completed, so the
    exact inverse runs (even if something wrote into the new tree meanwhile). None (recovery after a crash): decide
    from the digests on disk."""
    live, slot, spare = _paths(category, txn, entry["skill"])
    if os.path.lexists(spare):  # the rename fallback stopped part way: spare holds the old tree
        if os.path.lexists(live):
            os.rename(live, slot)
        os.rename(spare, live)
        return
    if swapped is not None:
        if swapped and entry["action"] == "replace":
            _swap(slot, live, spare)
        elif swapped:
            os.rename(*((live, slot) if entry["action"] == "install" else (slot, live)))
        return
    current = stage.tree_digest(live)
    if current == entry["old"]:
        return
    if entry["action"] == "replace" and current == entry["new"] and os.path.lexists(slot):
        _swap(slot, live, spare)
    elif entry["action"] == "install" and current == entry["new"]:
        os.rename(live, slot)
    elif entry["action"] == "remove" and current == "absent" and os.path.lexists(slot):
        os.rename(slot, live)
    else:
        raise OSError(errno.EIO, "live %s matches neither its old nor its new tree" % entry["skill"])


def _clear_previous(category, txn, skill):
    previous = _previous(category)
    marker = os.path.join(previous, skill + ".absent")
    if os.path.lexists(marker):
        os.unlink(marker)
    folder = os.path.join(previous, skill)
    if os.path.lexists(folder):
        os.makedirs(os.path.join(txn, "trash"), 0o700, exist_ok=True)
        os.rename(folder, os.path.join(txn, "trash", skill))


def _rotate(category, txn, entries):
    """After the commit: each replaced or removed tree becomes `previous/<skill>`; an install leaves a marker.
    Safe to repeat (recovery finishes a rotation that was cut short)."""
    previous = _previous(category)
    os.makedirs(previous, stage.DIR_MODE, exist_ok=True)
    for entry in entries:
        skill = entry["skill"]
        _, slot, _ = _paths(category, txn, skill)
        marker = os.path.join(previous, skill + ".absent")
        if entry["action"] == "install":
            if not os.path.lexists(marker):
                _clear_previous(category, txn, skill)
                os.close(os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o644))
        elif os.path.lexists(slot):
            _clear_previous(category, txn, skill)
            os.rename(slot, os.path.join(previous, skill))


def recover(category):
    """Finish or roll back transactions a dead run left behind. Returns how many it found."""
    work = stage.work_dir(category)
    try:
        names = sorted(n for n in os.listdir(work) if n.startswith("txn-"))
    except FileNotFoundError:
        return 0
    for name in names:
        txn = os.path.join(work, name)
        try:
            with open(os.path.join(txn, JOURNAL), "rb") as handle:
                journal = json.loads(handle.read().decode("utf-8"))
        except FileNotFoundError:
            journal = None  # died before the first swap: nothing live changed
        if journal is not None and journal["state"] == "committed":
            _rotate(category, txn, journal["entries"])
        elif journal is not None:
            for entry in reversed(journal["entries"]):
                _undo_entry(category, txn, entry)
        _discard(txn)
    return len(names)


# ---- state record ---------------------------------------------------------------------------------------------

def record_path(state_dir, profile):
    return os.path.join(state_dir, "profiles", profile + ".json")


def read_record(state_dir, profile):
    try:
        with open(record_path(state_dir, profile), "rb") as handle:
            return json.loads(handle.read().decode("utf-8"))
    except (OSError, ValueError):
        return {}


def _record(state_dir, profile, status, detail, versions=None, reload_pending=False):
    """Write the profile's state record and return the Result. `versions` maps skill → version (None = removed);
    `reload_pending` stays set until cleared by whoever reloads the gateway (the app, P2b/P4)."""
    record = read_record(state_dir, profile)
    skills = dict(record.get("skills") or {})
    for skill, version in (versions or {}).items():
        if version is None:
            skills.pop(skill, None)
        else:
            skills[skill] = version
    pending = bool(record.get("reload_pending")) or reload_pending
    record.update(profile=profile, status=status, detail=detail, at=int(time.time()), skills=skills,
                  reload_pending=pending)
    os.makedirs(os.path.dirname(record_path(state_dir, profile)), 0o700, exist_ok=True)
    _write_json(record_path(state_dir, profile), record, 0o600)
    return Result(profile, status, detail, skills, pending)


def clear_reload_pending(state_dir, profile):
    """For whoever reloaded the gateway's plugins: the profile no longer waits for a reload."""
    record = read_record(state_dir, profile)
    if record.get("reload_pending"):
        record["reload_pending"] = False
        _write_json(record_path(state_dir, profile), record, 0o600)


# ---- apply / revert -------------------------------------------------------------------------------------------

def _swap_in(hermes_home, state_dir, category, txn, entries, profile, deadline, poll, versions, done):
    ready, jobs, _ = idle.wait_for_idle(hermes_home, max(0.0, deadline - time.monotonic()), poll)
    if not ready:
        _discard(txn)
        return _record(state_dir, profile, "deferred", "box busy: " + "; ".join(jobs))
    moved = [e["skill"] for e in entries if stage.tree_digest(os.path.join(category, e["skill"])) != e["old"]]
    if moved:  # the journal's old digests must be what is live, or recovery could not tell old from new
        _discard(txn)
        return _record(state_dir, profile, "deferred", "live %s changed while waiting" % ", ".join(moved))
    messages = os.path.join(category, MESSAGES_SKILL)
    plugin_before = stage.plugin_digest(messages)
    _write_json(os.path.join(txn, JOURNAL), {"state": "open", "entries": entries}, 0o600)
    swapped = []
    try:
        for entry in entries:
            _swap_entry(category, txn, entry)
            swapped.append(entry["skill"])
        for entry in entries:
            if stage.tree_digest(os.path.join(category, entry["skill"])) != entry["new"]:
                raise OSError(errno.EIO, "live %s differs from the staged tree after the swap" % entry["skill"])
    except OSError as error:
        try:
            for entry in reversed(entries):
                _undo_entry(category, txn, entry, entry["skill"] in swapped)
            _discard(txn)
        except OSError as undo_error:
            return _record(state_dir, profile, "failed", "swap failed (%s); rollback incomplete (%s), the next run "
                           "finishes it" % (error, undo_error))
        return _record(state_dir, profile, "failed", "swap failed, current restored: %s" % error)
    _write_json(os.path.join(txn, JOURNAL), {"state": "committed", "entries": entries}, 0o600)
    _rotate(category, txn, entries)
    _discard(txn)
    reload = stage.plugin_digest(messages) != plugin_before
    return _record(state_dir, profile, done, "%d skill(s) swapped" % len(entries), versions, reload)


def _prepare(hermes_home, profile):
    home = stage.profile_home(hermes_home, profile)
    if not os.path.isdir(home):
        raise stage.StageError("no such profile on this box")
    category = stage.category_dir(hermes_home, profile)
    os.makedirs(category, stage.DIR_MODE, exist_ok=True)
    recover(category)
    return category


def apply_profile(hermes_home, state_dir, skills, manager_template, profile, deadline, poll=idle.DEFAULT_POLL):
    """Stage, check, wait for idle and swap one profile (a stage.Profile). Returns a Result."""
    try:
        category = _prepare(hermes_home, profile.name)
        rendered = stage.render_profile(skills, manager_template, profile)
    except (stage.StageError, OSError) as error:
        return _record(state_dir, profile.name, "failed", str(error)) if render.is_valid_profile_name(profile.name) \
            else Result(profile.name, "failed", str(error), {}, False)
    versions = {s.name: s.version for s in skills if s.name in rendered}
    planned = []
    for name, files in sorted(rendered.items()):
        expected = stage.expected_snapshot(files)
        new, old = stage.digest(expected), stage.tree_digest(os.path.join(category, name))
        if old is None:
            return _record(state_dir, profile.name, "failed", "%s: live folder holds a link or special file" % name)
        if new != old:
            planned.append((name, files, expected, new, old))
    if not planned:
        return _record(state_dir, profile.name, "unchanged", "current matches", versions)
    txn = _new_txn(category)
    try:
        for name, files, expected, _, _ in planned:
            slot = os.path.join(txn, "swap", name)
            stage.write_tree(slot, files)
            stage.check_skill(slot, name, expected, versions[name])
    except (stage.StageError, stage.CheckError, OSError) as error:
        _discard(txn)
        return _record(state_dir, profile.name, "failed", "check failed, current untouched: %s" % error)
    entries = [{"skill": name, "action": "install" if old == "absent" else "replace", "new": new, "old": old}
               for name, _, _, new, old in planned]
    return _swap_in(hermes_home, state_dir, category, txn, entries, profile.name, deadline, poll,
                    {e["skill"]: versions[e["skill"]] for e in entries}, "applied")


def _guarded(profile, function, *args):
    """One profile's error never stops the others; a half-done swap is left to `recover` on the next run."""
    try:
        return function(*args)
    except Exception as error:  # noqa: BLE001 - reported per profile, never swallowed silently
        return Result(profile, "failed", "internal error (%s: %s); the next run recovers" % (type(error).__name__,
                                                                                            error), {}, False)


def apply(hermes_home, state_dir, skills, manager_template, profiles, max_wait=idle.DEFAULT_MAX_WAIT,
          poll=idle.DEFAULT_POLL):
    """Apply `skills` (render.Skill list, already verified) to each stage.Profile. The idle wait is bounded by
    `max_wait` seconds for the whole run. Returns one Result per profile."""
    deadline = time.monotonic() + max_wait
    try:
        with locked(state_dir):
            return [_guarded(p.name, apply_profile, hermes_home, state_dir, skills, manager_template, p, deadline, poll)
                    for p in profiles]
    except Busy:
        return [Result(p.name, "deferred", "another updater run is active", {}, False) for p in profiles]


def revert(hermes_home, state_dir, profile, max_wait=idle.DEFAULT_MAX_WAIT, poll=idle.DEFAULT_POLL):
    """Swap every `previous/<skill>` back in (removing skills that were newly installed), with the same checks,
    idle wait and rollback as `apply`. What was current becomes `previous`, so a second revert re-applies."""
    deadline = time.monotonic() + max_wait
    try:
        with locked(state_dir):
            return _guarded(profile, _revert, hermes_home, state_dir, profile, deadline, poll)
    except Busy:
        return Result(profile, "deferred", "another updater run is active", {}, False)


def _revert(hermes_home, state_dir, profile, deadline, poll):
    try:
        category = _prepare(hermes_home, profile)
    except (stage.StageError, OSError) as error:
        return Result(profile, "failed", str(error), {}, False)
    previous = _previous(category)
    names = sorted(os.listdir(previous)) if os.path.isdir(previous) else []
    if not names:
        return _record(state_dir, profile, "failed", "no previous version to revert to")
    txn = _new_txn(category)
    entries, versions = [], {}
    try:
        for name in names:
            skill = name[:-len(".absent")] if name.endswith(".absent") else name
            if not render.is_valid_profile_name(skill):
                raise stage.StageError("unexpected entry %r in previous" % name)
            old = stage.tree_digest(os.path.join(category, skill))
            if old is None:
                raise stage.StageError("%s: live folder holds a link or special file" % skill)
            if name.endswith(".absent"):
                if old != "absent":
                    entries.append({"skill": skill, "action": "remove", "new": "absent", "old": old})
                    versions[skill] = None
                continue
            slot = os.path.join(txn, "swap", skill)
            snap = stage.copy_tree(os.path.join(previous, name), slot)
            new = stage.digest(snap)
            if new == old:
                shutil.rmtree(slot)
                continue
            versions[skill] = stage.check_skill(slot, skill, snap)
            entries.append({"skill": skill, "action": "install" if old == "absent" else "replace", "new": new,
                            "old": old})
    except (stage.StageError, stage.CheckError, OSError) as error:
        _discard(txn)
        return _record(state_dir, profile, "failed", "revert check failed, current untouched: %s" % error)
    if not entries:
        _discard(txn)
        return _record(state_dir, profile, "unchanged", "current already matches previous")
    return _swap_in(hermes_home, state_dir, category, txn, entries, profile, deadline, poll, versions, "reverted")
