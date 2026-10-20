"""Component archives: strict POSIX ustar reader, archive rules and a contained extractor (SCHEMAS.md §9).

`check(data, kind, limits)` applies every archive rule and returns the parsed entries plus whether the content
needs class `code`. `extract(data, kind, limits, target)` runs the same checks before writing anything, then
creates `target` (which must not exist) and writes through directory file descriptors opened with O_NOFOLLOW, so
no entry can land outside `target`, follow a symlink, or create anything but regular files and directories with
modes 0644/0755. Errors raise ArchiveError(reason) with the verdict reason. Stdlib only, Python 3.8+.
"""

import os
import posixpath
import re

BLOCK = 512
SAFE_PART = re.compile(r"[A-Za-z0-9._-]+")
DATA_EXTENSIONS = {"skill": {".md"}, "config": {".json", ".md", ".txt"}, "ui": {".json"}}
LIMIT_NAMES = ("max_entries", "max_file_size", "max_total_size", "max_path_bytes", "max_depth")
_O_DIR = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
_O_NEW_FILE = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)


class ArchiveError(ValueError):
    def __init__(self, reason, detail=""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason = reason


def safe_relative(path):
    """Relative path of `[A-Za-z0-9._-]+` segments, none `.` or `..`, matched in full (no trailing newline)."""
    parts = path.split("/") if isinstance(path, str) else []
    return bool(parts) and all(SAFE_PART.fullmatch(p) is not None and p not in (".", "..") for p in parts)


def extension(name):
    """The last segment from its last `.`, when that dot is neither its first nor last character (`..md` → `.md`,
    `.md` → none), as pathlib's suffix and the P0a reference define it."""
    base = name.rsplit("/", 1)[-1]
    dot = base.rfind(".")
    return base[dot:] if 0 < dot < len(base) - 1 else ""


def _field(block, start, length):
    return block[start:start + length].split(b"\0", 1)[0]


def _number(block, start, length):
    text = _field(block, start, length).strip(b" ")
    if not text or any(c not in b"01234567" for c in text):
        raise ArchiveError("archive_malformed", "bad numeric field")
    return int(text, 8)


def read(data):
    """Parse headers into [{name, typeflag, mode, size, data}] without judging them. Raises ArchiveError."""
    entries, offset = [], 0
    while True:
        if offset + BLOCK > len(data):
            raise ArchiveError("archive_malformed", "missing end-of-archive blocks")
        block = data[offset:offset + BLOCK]
        if block == b"\0" * BLOCK:
            if data[offset + BLOCK:offset + 2 * BLOCK] != b"\0" * BLOCK or data[offset + 2 * BLOCK:].strip(b"\0"):
                raise ArchiveError("archive_malformed", "bad end of archive")
            return entries
        if block[257:263] != b"ustar\0" or block[263:265] != b"00":
            raise ArchiveError("archive_malformed", "not a ustar header")
        if _number(block, 148, 8) != sum(block[:148]) + 8 * 32 + sum(block[156:]):
            raise ArchiveError("archive_malformed", "header checksum")
        name, prefix = _field(block, 0, 100), _field(block, 345, 155)
        try:
            full = (prefix + b"/" + name if prefix else name).decode("utf-8")
        except UnicodeDecodeError as error:
            raise ArchiveError("archive_unsafe_path", "name is not UTF-8") from error
        typeflag = chr(block[156]) if block[156] else "0"
        size, mode = _number(block, 124, 12), _number(block, 100, 8)
        offset += BLOCK
        body = 0 if typeflag in "123456" else size  # links, devices, fifos and dirs carry no data
        if offset + body > len(data):
            raise ArchiveError("archive_malformed", "truncated entry")
        entries.append({"name": full, "typeflag": typeflag, "mode": mode, "size": size,
                        "data": bytes(data[offset:offset + body])})
        offset += (body + BLOCK - 1) // BLOCK * BLOCK


def check(data, kind, limits):
    """Apply the §9 rules. Returns (entries, needs_code); entry names are normalised (no trailing `/`)."""
    missing = [name for name in LIMIT_NAMES if name not in limits]
    if missing:
        raise ValueError(f"limits missing {missing}")
    entries = read(data)
    if len(entries) > limits["max_entries"]:
        raise ArchiveError("archive_oversize", "too many entries")
    paths, dirs, total, needs_code = set(), set(), 0, False
    for entry in entries:
        flag = entry["typeflag"]
        if flag in ("1", "2"):
            raise ArchiveError("archive_link", entry["name"])
        if flag in ("3", "4", "6"):
            raise ArchiveError("archive_special_file", entry["name"])
        if flag not in ("0", "5"):
            raise ArchiveError("archive_unsupported_entry", repr(flag))
        name = entry["name"]
        if flag == "5" and name.endswith("/"):
            name = entry["name"] = name[:-1]
        if (len(name.encode("utf-8")) > limits["max_path_bytes"] or name.count("/") + 1 > limits["max_depth"]
                or not safe_relative(name)):
            raise ArchiveError("archive_unsafe_path", repr(name))
        if name in paths:
            raise ArchiveError("archive_duplicate_path", name)
        paths.add(name)
        if entry["mode"] not in ({0o755} if flag == "5" else {0o644, 0o755}):
            raise ArchiveError("archive_bad_mode", f"{name} {entry['mode']:o}")
        if flag == "5":
            dirs.add(name)
            continue
        if entry["size"] > limits["max_file_size"]:
            raise ArchiveError("archive_oversize", name)
        total += entry["size"]
        if total > limits["max_total_size"]:
            raise ArchiveError("archive_oversize", "total size")
        if entry["mode"] == 0o755 or extension(name) not in DATA_EXTENSIONS.get(kind, set()):
            needs_code = True
    files = paths - dirs
    for name in paths:
        parent = posixpath.dirname(name)
        while parent:
            if parent in files:
                raise ArchiveError("archive_path_conflict", name)
            parent = posixpath.dirname(parent)
    return entries, needs_code


def extract(data, kind, limits, target):
    """Check the archive, then write it into the new directory `target`. Returns needs_code.

    `target` must not exist; its parent must. Nothing is written when a check fails. If writing fails part way
    (storage error, a symlink planted in `target` meanwhile, or two names that collide on a case-insensitive
    file system), the partial `target` is left for the caller's staging cleanup and the OSError propagates;
    nothing outside `target` is touched either way.
    """
    entries, needs_code = check(data, kind, limits)
    target = os.fspath(target)
    os.mkdir(target, 0o700)
    root = os.open(target, _O_DIR)
    try:
        write_entries(root, entries)
        os.fchmod(root, 0o755)
    finally:
        os.close(root)
    return needs_code


def write_entries(root_fd, entries):
    """Write checked entries below the directory open at root_fd. Every path step is O_NOFOLLOW; files are O_EXCL."""
    for entry in entries:
        parts = entry["name"].split("/")
        if not safe_relative(entry["name"]):
            raise ArchiveError("archive_unsafe_path", repr(entry["name"]))  # defence in depth; check() ran first
        is_dir = entry["typeflag"] == "5"
        parent = _open_dirs(root_fd, parts if is_dir else parts[:-1])
        try:
            if is_dir:
                os.fchmod(parent, 0o755)
                continue
            fd = os.open(parts[-1], _O_NEW_FILE, 0o600, dir_fd=parent)
            try:
                view = memoryview(entry["data"])
                while view:
                    view = view[os.write(fd, view):]
                os.fchmod(fd, entry["mode"])
            finally:
                os.close(fd)
        finally:
            if parent != root_fd:
                os.close(parent)


def _open_dirs(root_fd, parts):
    """Open (creating 0755 as needed) the directory root/parts..., never following a symlink. Returns its fd."""
    fd = root_fd
    try:
        for part in parts:
            try:
                os.mkdir(part, 0o700, dir_fd=fd)
                created = True
            except FileExistsError:
                created = False
            child = os.open(part, _O_DIR, dir_fd=fd)
            if fd != root_fd:
                os.close(fd)
            fd = child
            if created:
                os.fchmod(fd, 0o755)  # explicit mode: independent of the umask
    except BaseException:
        if fd != root_fd:
            os.close(fd)
        raise
    return fd
