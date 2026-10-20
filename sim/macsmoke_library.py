"""Fail-closed HOME/Library classification for the Darwin smoke-test harness."""
import importlib.util
import io
import marshal
import os
from pathlib import Path
import plistlib
import re
import stat
import types

ROOT = Path(__file__).resolve().parents[1]

# mactest2: Xcode's python3 sets sys.pycache_prefix to ~/Library/Caches/com.apple.python, so in a fresh fake HOME the
# smoke's helper `python3 -c` calls create ~/Library on their first import. run_smoke removes that cause
# (PYTHONDONTWRITEBYTECODE=1, and any prefix pointed into the fixture), so HOME must stay empty. If macOS still makes
# a Library (CFPreferences), os_library_problems accepts it on Darwin only, as an allowlist of exact OS shapes:
# stdlib-style bytecode under Caches/com.apple.python/<real source dir>/ and com.apple.*.plist directly in
# Preferences. Everything else fails: other names, empty dirs, symlinks, specials, and any walk/stat/read error.
PYC_PREFIX = ("Caches", "com.apple.python")
PYC_NAME = re.compile(r"(.+)\.cpython-\d+(?:\.opt-[12])?\.pyc")
PLIST_NAME = re.compile(r"com\.apple\.[A-Za-z0-9_.-]+\.plist")


def under(path, fixtures):
    paths = (str(path), os.path.realpath(path))
    return any(p == f or p.startswith(f.rstrip("/") + "/") for p in paths for f in fixtures)


def os_library_file(rel, data, fixtures):
    """Why the regular file <HOME>/Library/<rel> is not an OS-owned shape; None if it is."""
    parts = rel.parts
    if len(parts) == 2 and parts[0] == "Preferences" and PLIST_NAME.fullmatch(parts[1]):
        try:
            pending = [plistlib.loads(data)]
            seen = set()
            # Scan decoded keys/values too: XML escapes and binary UTF-16 can hide path bytes.
            while pending:
                value = pending.pop()
                if isinstance(value, (dict, list)):
                    if id(value) in seen:  # Binary plists can share or cycle container references.
                        continue
                    seen.add(id(value))
                if isinstance(value, dict):
                    pending.extend(value.keys())
                    pending.extend(value.values())
                elif isinstance(value, list):
                    pending.extend(value)
                elif isinstance(value, (str, bytes)):
                    raw = value.encode() if isinstance(value, str) else value
                    if any(os.fsencode(f) in raw for f in fixtures):
                        return "mentions a smoke fixture path"
            if any(os.fsencode(f) in data for f in fixtures):
                return "mentions a smoke fixture path"
        except Exception:
            return "not a property list"
        return None
    match = PYC_NAME.fullmatch(parts[-1])
    if not (len(parts) > 3 and parts[:2] == PYC_PREFIX and match):
        return "not an OS-owned file"
    source = Path("/", *parts[2:-1], match[1] + ".py")
    try:
        resolved = source.resolve(strict=True)
        if under(source, fixtures) or under(resolved, fixtures):
            return "bytecode of a fixture source"
        if not stat.S_ISREG(os.stat(source).st_mode):
            return "bytecode without a real source"
    except (OSError, ValueError, RuntimeError):
        return "bytecode without a real source"
    try:
        if (len(data) < 16 or data[:4] != importlib.util.MAGIC_NUMBER or
                int.from_bytes(data[4:8], "little") not in (0, 1, 3)):
            return "not CPython bytecode"
        payload = io.BytesIO(data[16:])
        code = marshal.load(payload)
        if not isinstance(code, types.CodeType) or payload.read(1):
            return "not CPython bytecode"
        if code.co_filename != str(source) or Path(code.co_filename).resolve(strict=True) != resolved:
            return "bytecode source does not match prefix layout"
    except Exception:
        return "not CPython bytecode"
    return None


def os_library_problems(library, markers, fixtures=()):
    """Reasons <HOME>/Library is not purely OS-created; [] if it is. Fails closed, never follows symlinks."""
    try:
        if not stat.S_ISDIR(library.lstat().st_mode):
            return ["Library: not a plain directory"]
    except OSError as error:
        return [f"Library: unreadable ({error.strerror})"]
    fixtures = {f for p in (*fixtures, ROOT) for f in (str(p), os.path.realpath(p))}
    label = lambda path: str(Path(path).relative_to(library)) if Path(path) != library else "Library"
    problems = []
    def unreadable(error):
        problems.append(f"{label(error.filename or library)}: unreadable ({error.strerror})")
    for dirpath, dirnames, filenames in os.walk(library, onerror=unreadable):
        if not dirnames and not filenames:
            problems.append(f"{label(dirpath)}: empty directory")
        for name in dirnames + filenames:
            path = Path(dirpath, name)
            rel = path.relative_to(library)
            try:
                mode = path.lstat().st_mode
                if stat.S_ISDIR(mode):
                    continue
                if not stat.S_ISREG(mode):
                    problems.append(f"{rel}: not a regular file or directory")
                    continue
                data = path.read_bytes()
            except OSError as error:
                problems.append(f"{rel}: unreadable ({error.strerror})")
                continue
            reason = os_library_file(rel, data, fixtures)
            if reason:
                problems.append(f"{rel}: {reason}")
            elif any(marker in data for marker in markers):
                problems.append(f"{rel}: mentions a smoke fixture path")
    return problems

