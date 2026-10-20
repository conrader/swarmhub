"""The admin-owned pin file (CORE-PLAN.md §3.2, §3.5; SCHEMAS.md §4; phase P2b).

One protected file, installed by the operator bootstrap next to the updater (`<prefix>/pins.json`, beside
`<prefix>/bin/swarmhub-update`) with no bot-account write access. It holds the trust anchor and the protected floor
checkpoint:

    {"schema": "swarmhub/pins/1", "threshold": 1, "roots": [{"key_id", "ed25519_pub"}, ...],
     "checkpoint": {"min_keys_version": 3, "min_index_seq": 40, "min_bundle_version": 412},
     "revoked_key_ids": ["release-2025"]}

`checkpoint` and `revoked_key_ids` are optional (absent = 0 and none); anything malformed fails closed. The updater
enforces max(checkpoint, state) for each floor, and refuses revoked key IDs from here, so wiping or lowering the
bot-writable state never goes below the checkpoint. The path is not a command-line or environment option: callers
pass it in code (the installed launcher derives it from its own location). Stdlib only, Python 3.8+.
"""

from collections import namedtuple
import hashlib
import os
import stat

from . import verify

FLOOR_NAMES = ("keys_version", "index_seq", "bundle_version")
CHECKPOINT_NAMES = {"min_keys_version": "keys_version", "min_index_seq": "index_seq",
                    "min_bundle_version": "bundle_version"}
MEMBERS = {"schema", "threshold", "roots", "checkpoint", "revoked_key_ids", "note"}
MAX_BYTES = 65536

Pins = namedtuple("Pins", "path raw doc checkpoint revoked sha256 protected")


class PinError(ValueError):
    """The pin file is missing, unreadable or malformed: nothing verifies, nothing applies."""


def load(path):
    """Read and validate the pin file. Returns Pins; raises PinError (fail closed)."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    except OSError as error:
        raise PinError("pin file unreadable: %s" % error) from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > MAX_BYTES:
            raise PinError("pin file is not a small regular file")
        raw = b""
        while True:
            chunk = os.read(fd, MAX_BYTES + 1)
            if not chunk:
                break
            raw += chunk
            if len(raw) > MAX_BYTES:
                raise PinError("pin file is not a small regular file")
    finally:
        os.close(fd)
    try:
        doc = verify.verify_pins(raw, verify.DEFAULT_LIMITS)
    except verify.Reject:
        raise PinError("pin file is not swarmhub/pins/1") from None
    if set(doc) - MEMBERS:
        raise PinError("pin file has unknown members %s" % sorted(set(doc) - MEMBERS))
    return Pins(path, raw, doc, _checkpoint(doc.get("checkpoint", {})), _revoked(doc.get("revoked_key_ids", [])),
                hashlib.sha256(raw).hexdigest(), is_protected(path))


def _checkpoint(value):
    if not isinstance(value, dict) or set(value) - set(CHECKPOINT_NAMES):
        raise PinError("checkpoint must be an object of %s" % sorted(CHECKPOINT_NAMES))
    floors = {name: 0 for name in FLOOR_NAMES}
    for member, floor in CHECKPOINT_NAMES.items():
        number = value.get(member, 0)
        if type(number) is not int or not 0 <= number <= 2**53 - 1:
            raise PinError("checkpoint %s must be a non-negative integer" % member)
        floors[floor] = number
    return floors


def _revoked(value):
    if not isinstance(value, list) or not all(isinstance(k, str) and verify.KEY_ID.fullmatch(k) for k in value):
        raise PinError("revoked_key_ids must be a list of key IDs")
    if len(set(value)) != len(value):
        raise PinError("revoked_key_ids lists a key twice")
    return frozenset(value)


def is_protected(path):
    """True when this account can modify neither the pin file nor the folder holding it (reported, not enforced:
    the operator bootstrap, P2d, makes it so)."""
    folder = os.path.dirname(os.path.abspath(path))
    return not (os.access(path, os.W_OK) or os.access(folder, os.W_OK))


def effective_floors(checkpoint, state_floors):
    """max(checkpoint, state) per floor; state values that are not non-negative integers count as 0."""
    result = {}
    for name in FLOOR_NAMES:
        value = state_floors.get(name, 0) if isinstance(state_floors, dict) else 0
        value = value if type(value) is int and value >= 0 else 0
        result[name] = max(checkpoint[name], value)
    return result


def summary(pins):
    """The status-file view of the pins (no key material beyond IDs)."""
    return {"path": pins.path, "sha256": pins.sha256, "protected": pins.protected,
            "roots": [root["key_id"] for root in pins.doc["roots"]], "threshold": pins.doc["threshold"],
            "checkpoint": dict(pins.checkpoint), "revoked_key_ids": sorted(pins.revoked)}
