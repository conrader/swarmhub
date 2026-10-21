"""Staging and post-apply checks for one profile (CORE-PLAN.md §3.4, phase P2a).

Box layout (`SkillLibrary.skillsRoot` / `installPath`): a profile's live skills are
`<profile home>/skills/swarmhub/<skill>/`, the "current" copy Hermes reads. The updater's work area is
`skills/swarmhub/.archive/swarmhub-update/` (`txn-*/` staging, `previous/`): Hermes' skill scan
(`agent/skill_utils.py` `EXCLUDED_SKILL_DIRS`, 0.20.5 and later) skips any `.archive` folder, so staged and previous
copies never register as skills, and the work area sits on the same file system as the live folders, so swaps are
renames. Nothing here writes outside `skills/swarmhub/`.

Checks, run on the staged tree before anything live changes: SKILL.md frontmatter name and version parse (and
match), every `scripts/` Python file compiles (in memory: `compile()`, no `__pycache__`), every `scripts/` shell file
passes `<shell> -n`, and a script whose text names `--self-test` is run with that flag (through its interpreter
line; a `.py` module without one runs under this Python; PYTHONDONTWRITEBYTECODE=1, no stdin, bounded time) and
must exit 0. Afterwards the staged tree must still be byte-identical to what was
written, so a check cannot leave caches or edits behind. Stdlib only, Python 3.8+.
"""

from collections import namedtuple
import hashlib
import os
import shutil
import stat
import subprocess
import sys

from . import render

CATEGORY_PARTS = ("skills", render.CATEGORY)
WORK_PARTS = (".archive", "swarmhub-update")
SELF_TEST_FLAG = "--self-test"
SELF_TEST_TIMEOUT = 60
SHELL_TIMEOUT = 30
SHELLS = ("sh", "dash", "bash")
DIR_MODE = 0o755
_O_NEW_FILE = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)

# skills: names to install, None = every given skill; dev_mode and reset (skill names): devmode.py
Profile = namedtuple("Profile", "name coding_order skills dev_mode reset", defaults=(False, ()))
Entry = namedtuple("Entry", "kind mode data")  # one snapshot entry: kind "dir"/"file", permission bits, bytes or None


class StageError(ValueError):
    """Rendering or writing the staged tree failed; nothing live has changed."""


class CheckError(ValueError):
    """A post-apply check failed on the staged tree; nothing live has changed."""


def profile_home(hermes_home, profile):
    if not render.is_valid_profile_name(profile):
        raise StageError("invalid profile name")
    return hermes_home if profile == "default" else os.path.join(hermes_home, "profiles", profile)


def category_dir(hermes_home, profile):
    """`<profile home>/skills/swarmhub`: the only folder of a profile the updater writes."""
    return os.path.join(profile_home(hermes_home, profile), *CATEGORY_PARTS)


def work_dir(category):
    return os.path.join(category, *WORK_PARTS)


def run(argv, **kwargs):
    """Every process the updater starts goes through here (the tests audit it): checks only, never a restart."""
    return subprocess.run(argv, **kwargs)


def load_source(folder):
    """Skills and manager template from a folder laid out like `Resources/` (`Skills/`, `BotManager/`): the list of
    loadable skills (as `SkillLibrary.bundled`) and the manager template text. Raises StageError when the manager
    references or template are missing."""
    references = render.load_manager_references(os.path.join(folder, "BotManager"))
    if references is None:
        raise StageError("manager references missing")
    skills_folder = os.path.join(folder, "Skills")
    skills = [render.load_skill(skills_folder, name, references) for name in sorted(os.listdir(skills_folder))]
    try:
        with open(os.path.join(folder, "BotManager", "manager-hermes.md"), "rb") as handle:
            manager = handle.read().decode("utf-8")
    except (OSError, UnicodeDecodeError):
        raise StageError("manager template missing") from None
    return [s for s in skills if s is not None], manager


def render_profile(skills, manager_template, profile):
    """{skill name: [SkillFile]} for `profile` (a Profile), each as the app's install turn writes it."""
    wanted = None if profile.skills is None else set(profile.skills)
    by_name = {s.name: s for s in skills}
    if wanted is not None and not wanted <= set(by_name):
        raise StageError("profile names a skill the bundle lacks: %s" % ", ".join(sorted(wanted - set(by_name))))
    rendered = {}
    for name in sorted(by_name):
        if wanted is not None and name not in wanted:
            continue
        try:
            files = render.install_files(by_name[name], profile.name, manager_template, profile.coding_order)
        except render.RenderError as error:
            raise StageError("%s: %s" % (name, error)) from None
        if files is None:
            raise StageError("%s: no manager template to render" % name)
        rendered[name] = files
    return rendered


def file_mode(path):
    """`SkillFile.isExecutable`: the install turn runs `chmod 755` on `scripts/` files; the rest stay 0644."""
    return 0o755 if path.startswith("scripts/") else 0o644


def expected_snapshot(files):
    """The snapshot a folder holding exactly `files` (as written by `write_tree`) must have."""
    entries = {}
    for item in files:
        parts = item.path.split("/")
        for depth in range(1, len(parts)):
            entries["/".join(parts[:depth])] = Entry("dir", DIR_MODE, None)
        entries[item.path] = Entry("file", file_mode(item.path), item.content.encode("utf-8"))
    return entries


def _write_new(target, data, mode):
    fd = os.open(target, _O_NEW_FILE, 0o600)
    try:
        while data:
            data = data[os.write(fd, data):]
        os.fchmod(fd, mode)
        os.fsync(fd)
    finally:
        os.close(fd)


def write_tree(folder, files):
    """Create `folder` (must not exist) holding exactly `files`, modes fixed regardless of umask."""
    for item in files:
        if not render.is_safe_relative_path(item.path):
            raise StageError("unsafe path %r" % item.path)
    os.mkdir(folder, DIR_MODE)
    os.chmod(folder, DIR_MODE)
    for item in files:
        target = os.path.join(folder, *item.path.split("/"))
        parent = os.path.dirname(target)
        missing = []
        while not os.path.isdir(parent):
            missing.append(parent)
            parent = os.path.dirname(parent)
        for directory in reversed(missing):
            os.mkdir(directory, DIR_MODE)
            os.chmod(directory, DIR_MODE)
        _write_new(target, item.content.encode("utf-8"), file_mode(item.path))


def copy_tree(source, folder):
    """Copy a previous skill folder for a revert: regular files and folders only, modes kept, nothing followed."""
    snap = snapshot(source)
    if snap is None:
        raise StageError("previous copy holds a link or special file")
    os.mkdir(folder, DIR_MODE)
    os.chmod(folder, DIR_MODE)
    for path in sorted(snap):
        entry, target = snap[path], os.path.join(folder, *path.split("/"))
        if entry.kind == "dir":
            os.mkdir(target, entry.mode)
            os.chmod(target, entry.mode)
            continue
        _write_new(target, entry.data, entry.mode)
    return snap


def snapshot(folder):
    """{relative path: Entry} for every entry below `folder`, or None when one is a symlink or special file."""
    entries = {}
    for directory, folders, names in os.walk(folder):
        folders.sort()
        for name in folders + sorted(names):
            full = os.path.join(directory, name)
            info = os.lstat(full)
            path = os.path.relpath(full, folder).replace(os.sep, "/")
            if stat.S_ISDIR(info.st_mode):
                entries[path] = Entry("dir", stat.S_IMODE(info.st_mode), None)
            elif stat.S_ISREG(info.st_mode):
                with open(full, "rb") as handle:
                    entries[path] = Entry("file", stat.S_IMODE(info.st_mode), handle.read())
            else:
                return None
    return entries


def digest(entries):
    """SHA-256 over a snapshot: path, kind, mode and content of every entry, in path order."""
    if entries is None:
        return None
    hasher = hashlib.sha256()
    for path in sorted(entries, key=lambda p: p.encode("utf-8")):
        entry = entries[path]
        hasher.update(b"%s\0%s\0%o\0" % (path.encode("utf-8"), entry.kind.encode(), entry.mode))
        if entry.data is not None:
            hasher.update(hashlib.sha256(entry.data).digest())
    return hasher.hexdigest()


def tree_digest(folder):
    """Digest of `folder` ("absent" when it does not exist, None when it holds a link or special file)."""
    if not os.path.lexists(folder):
        return "absent"
    if os.path.islink(folder) or not os.path.isdir(folder):
        return None
    return digest(snapshot(folder))


def plugin_digest(folder):
    """Digest of the peer plugin's code inside a swarmhub-messages folder: `scripts/peer-runtime.py` and the
    `scripts/*.py` modules it loads through `swarm_control` (the plugin's `__init__.py` runs peer-runtime.py from
    the live skill folder). "absent" when the skill is not installed."""
    if not os.path.isdir(folder):
        return "absent"
    snap = snapshot(folder) or {}
    return digest({p: e for p, e in snap.items() if p.startswith("scripts/") and p.endswith(".py") and "/" not in p[8:]})


def script_kind(path, data):
    """"python" for a `.py` file or a python shebang, the shell name for a sh/dash/bash shebang, else None."""
    first = data.split(b"\n", 1)[0]
    words = first[2:].decode("utf-8", "replace").split() if first.startswith(b"#!") else []
    if words and os.path.basename(words[0]) == "env":
        words = words[1:]
    interpreter = os.path.basename(words[0]) if words else ""
    if path.endswith(".py") or interpreter.startswith("python"):
        return "python"
    return interpreter if interpreter in SHELLS else None


def _check_frontmatter(folder, name, version):
    try:
        with open(os.path.join(folder, "SKILL.md"), "rb") as handle:
            fields = render.frontmatter(handle.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError, render.RenderError) as error:
        raise CheckError("%s: SKILL.md unreadable (%s)" % (name, error)) from None
    parsed = render.parse_version(fields.get("version"))
    if fields.get("name") != name or parsed is None:
        raise CheckError("%s: frontmatter name/version do not parse" % name)
    if version is not None and parsed != version:
        raise CheckError("%s: frontmatter version %s, expected %s" % (name, parsed, version))
    return parsed


def _environment():
    env = dict(os.environ)
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    return env


def _check_script(folder, name, path, data):
    full = os.path.join(folder, *path.split("/"))
    kind = script_kind(path, data)
    if kind == "python":
        try:
            compile(data, full, "exec", dont_inherit=True)
        except (SyntaxError, ValueError) as error:
            raise CheckError("%s: %s does not compile (%s)" % (name, path, error)) from None
    elif kind is not None:
        shell = shutil.which(kind)
        if shell is None:
            raise CheckError("%s: %s needs %s, which is not installed" % (name, path, kind))
        result = run([shell, "-n", full], stdin=subprocess.DEVNULL, capture_output=True, timeout=SHELL_TIMEOUT,
                     env=_environment())
        if result.returncode != 0:
            raise CheckError("%s: %s fails %s -n" % (name, path, kind))
    if SELF_TEST_FLAG.encode() in data:
        if data.startswith(b"#!"):
            argv = [full, SELF_TEST_FLAG]
        elif kind == "python":
            argv = [sys.executable, full, SELF_TEST_FLAG]
        else:
            raise CheckError("%s: %s names --self-test but has no interpreter line" % (name, path))
        try:
            result = run(argv, cwd=folder, stdin=subprocess.DEVNULL, capture_output=True,
                         timeout=SELF_TEST_TIMEOUT, env=_environment())
        except subprocess.TimeoutExpired:
            raise CheckError("%s: %s --self-test timed out" % (name, path)) from None
        except OSError as error:
            raise CheckError("%s: %s --self-test did not start (%s)" % (name, path, error)) from None
        if result.returncode != 0:
            raise CheckError("%s: %s --self-test exited %d" % (name, path, result.returncode))


def check_skill(folder, name, expected, version=None):
    """Run every post-apply check on a staged skill folder; `expected` is its snapshot as staged. Returns the
    frontmatter version. Raises CheckError on the first failure."""
    if snapshot(folder) != expected:
        raise CheckError("%s: staged tree differs from what was written" % name)
    parsed = _check_frontmatter(folder, name, version)
    for path in sorted(expected):
        entry = expected[path]
        if entry.kind == "file" and path.startswith("scripts/"):
            try:
                _check_script(folder, name, path, entry.data)
            except subprocess.TimeoutExpired:
                raise CheckError("%s: %s check timed out" % (name, path)) from None
    if snapshot(folder) != expected:
        raise CheckError("%s: a check changed the staged tree" % name)
    return parsed
