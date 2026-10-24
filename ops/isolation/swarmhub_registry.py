"""The bot registry: which profiles run in their own unix account, and on which loopback ports.

`/etc/swarmhub/bots.json`, root-owned, 0644, no secrets. Only `ops/hb-move` writes it; `peer-bridge` reads it as root and
refuses everything when it is missing, unreadable, not root-owned or writable by anyone but root (fails closed).

    {"version": 1,
     "shared": {"user": "hermes", "gateway_port": 8642},
     "bots": {"<profile>": {"user": "hb-<slug>", "uid": 1201, "gateway_port": 8651,
                            "receiver_port": 8751, "control_port": 8761}}}

A bot's profile name is its registry key ("slug"); `user` is its dedicated account. Every user, uid and port is unique.
Standard library only.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import stat
import tempfile

PATH = "/etc/swarmhub/bots.json"
NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]*\Z", re.ASCII)
USER = re.compile(r"[a-z_][a-z0-9_-]{0,30}\Z", re.ASCII)
PORTS = ("gateway_port", "receiver_port", "control_port")
SHARED_DEFAULT = {"user": "hermes", "gateway_port": 8642}


class RegistryError(ValueError):
    pass


def empty():
    return {"version": 1, "shared": dict(SHARED_DEFAULT), "bots": {}}


def _port(value, what):
    if not isinstance(value, int) or isinstance(value, bool) or not 1024 <= value <= 65535:
        raise RegistryError(f"{what} must be a port number 1024-65535")
    return value


def validate(data):
    """The registry as a plain dict, or RegistryError. Unknown keys are refused so a typo cannot pass silently."""
    if not isinstance(data, dict) or set(data) - {"version", "shared", "bots"} or data.get("version") != 1:
        raise RegistryError("registry must be {version: 1, shared, bots}")
    shared = data.get("shared", SHARED_DEFAULT)
    if not isinstance(shared, dict) or set(shared) - {"user", "gateway_port"}:
        raise RegistryError("shared must be {user, gateway_port}")
    shared = dict(SHARED_DEFAULT, **shared)
    if not isinstance(shared["user"], str) or not USER.fullmatch(shared["user"]):
        raise RegistryError("shared.user is not a valid user name")
    _port(shared["gateway_port"], "shared.gateway_port")
    bots = data.get("bots")
    if not isinstance(bots, dict):
        raise RegistryError("bots must be an object")
    users, uids, ports = {shared["user"]}, set(), {shared["gateway_port"]}
    for name, bot in bots.items():
        if not NAME.fullmatch(name) or name == "default":
            raise RegistryError(f"{name!r} is not a profile name")
        if not isinstance(bot, dict) or set(bot) != {"user", "uid", *PORTS}:
            raise RegistryError(f"{name}: needs exactly user, uid, {', '.join(PORTS)}")
        if not isinstance(bot["user"], str) or not USER.fullmatch(bot["user"]) or bot["user"] in users:
            raise RegistryError(f"{name}: user missing, invalid or not unique")
        if not isinstance(bot["uid"], int) or isinstance(bot["uid"], bool) or bot["uid"] <= 0 or bot["uid"] in uids:
            raise RegistryError(f"{name}: uid missing, root or not unique")
        for key in PORTS:
            if _port(bot[key], f"{name}.{key}") in ports:
                raise RegistryError(f"{name}.{key} {bot[key]} is already used")
            ports.add(bot[key])
        users.add(bot["user"])
        uids.add(bot["uid"])
    return {"version": 1, "shared": shared, "bots": {name: dict(bot) for name, bot in bots.items()}}


def _trusted(path):
    """Refuse a registry (or its folder) that someone other than root could have written."""
    for item in (path, path.parent):
        info = os.lstat(item)
        if stat.S_ISLNK(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
            raise RegistryError(f"{item} must be root-owned and writable only by root")


def load(path=PATH, trusted=True):
    """The validated registry. `trusted` (the bridge's case) also requires root ownership of the file and folder."""
    path = Path(path)
    try:
        if trusted:
            _trusted(path)
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise RegistryError(f"no registry at {path}") from None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RegistryError(f"registry {path} is unreadable ({type(exc).__name__})") from None
    return validate(data)


def by_uid(registry, uid):
    """The profile whose dedicated account has this uid, or None."""
    for name, bot in registry["bots"].items():
        if bot["uid"] == uid:
            return name
    return None


def save(path, data):
    """Validate and write atomically (0644, root-owned when run as root) under an exclusive lock on <path>.lock."""
    data = validate(data)
    path = Path(path)
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".bots.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise
    return data


class locked:
    """`with locked(path) as reg:` read-modify-write of the registry; call `save(path, reg)` inside the block."""

    def __init__(self, path=PATH):
        self.path = Path(path)

    def __enter__(self):
        self.path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        self.lock = os.open(str(self.path) + ".lock", os.O_CREAT | os.O_RDWR | os.O_CLOEXEC, 0o600)
        fcntl.flock(self.lock, fcntl.LOCK_EX)
        try:
            return load(self.path, trusted=False) if self.path.exists() else empty()
        except BaseException:
            os.close(self.lock)
            raise

    def __exit__(self, *exc):
        os.close(self.lock)
        return False
