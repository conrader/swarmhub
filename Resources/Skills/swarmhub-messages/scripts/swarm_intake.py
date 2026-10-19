"""Secure user-key intake: a secret read from stdin into an owner-only file; only the path is ever returned.

Provisioning requests reference secrets by these paths (see `swarm_policy.provisioner_argv`),
so no command line, journal, chat turn or wake ever carries the value. The value is never
echoed, hashed into a record or copied; listing shows names and paths only.
"""
from pathlib import Path
import os
import sys
import stat
import tempfile

from swarm_store import NAME, state

SECRET_LIMIT = 65536


def folder():
    path = state() / "secrets"
    if path.is_symlink():
        raise ValueError("secret folder must not be a symlink")
    path.mkdir(mode=0o700, exist_ok=True)
    path.chmod(0o700)
    return path


def write_private(path, data):
    """Atomically replace a private file without following links or exposing an old file's mode."""
    fd, temporary = tempfile.mkstemp(prefix=".intake-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def intake(name, stream=None):
    """Write the secret on `stream` (default stdin) to <state>/secrets/<name> with mode 0600.

    Refuses an empty or oversized value and a name that could escape the folder. A
    trailing newline from an interactive paste is removed; nothing else is altered.
    """
    if not isinstance(name, str) or not NAME.fullmatch(name) or len(name) > 64:
        raise ValueError("secret name must be a short file name")
    stream = sys.stdin.buffer if stream is None else stream
    data = stream.read(SECRET_LIMIT + 2)
    if isinstance(data, str):
        data = data.encode()
    if data.endswith(b"\n"):
        data = data[:-1]
    if not data.strip():
        raise ValueError("secret value is empty")
    if len(data) > SECRET_LIMIT:
        raise ValueError("secret value too large")
    path = folder() / name
    write_private(path, data)
    return {"name": name, "path": str(path), "mode": "0600", "value": "never printed"}


def listing():
    return [{"name": p.name, "path": str(p), "mode": oct(p.stat().st_mode & 0o777)}
            for p in sorted(folder().iterdir()) if NAME.fullmatch(p.name) and not p.is_symlink() and p.is_file()]


def remove(name):
    if not isinstance(name, str) or not NAME.fullmatch(name):
        raise ValueError("secret name must be a short file name")
    path = folder() / name
    if not path.is_file():
        raise ValueError("unknown secret")
    path.unlink()
    return {"name": name, "removed": True}


def is_intake_path(value):
    try:
        if not isinstance(value, str):
            return False
        path = Path(value)
        info = path.lstat()
        return (path.is_absolute() and path.parent.resolve() == folder().resolve() and
                stat.S_ISREG(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o600 and info.st_uid == os.getuid())
    except OSError:
        return False
