"""Structural checks for the signed update-service objects (docs/update-service/SCHEMAS.md §3–§7). Stdlib only.

Each check raises Reject(stage, reason) and nothing else: any malformed shape (wrong type, unhashable item, missing
member) is schema_invalid. Patterns are matched with fullmatch, so a trailing newline never passes. Unknown members
inside `signed` are ignored (schema /1 grows additively); unknown envelope members are rejected because the
envelope is not signed.
"""

import re
from datetime import datetime

# All patterns are used with fullmatch (never match/search): `$` would accept a trailing newline.
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX128 = re.compile(r"[0-9a-f]{128}")
KEY_ID = re.compile(r"[A-Za-z0-9._-]{1,64}")
NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
CHANNEL = re.compile(r"[a-z0-9-]{1,32}")
AXIS = re.compile(r"[a-z_]{1,32}")
VERSION = re.compile(r"(0|[1-9][0-9]{0,8})(\.(0|[1-9][0-9]{0,8})){0,3}")
CLAUSE = re.compile(r"(>=|<|==)(.+)")
SAFE_PART = re.compile(r"[A-Za-z0-9._-]+")
TIMESTAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
AXES = {"box": {"updater", "hermes"}, "mac": {"app", "ui_catalog", "config_schema"},
        "ios": {"app", "ui_catalog", "config_schema"}}
KINDS = {"skill", "tool", "config", "ui"}


class Reject(Exception):
    def __init__(self, stage, reason):
        super().__init__(f"{stage}: {reason}")
        self.stage, self.reason = stage, reason


def _require(condition, stage, reason="schema_invalid"):
    if not condition:
        raise Reject(stage, reason)


def _is_int(value, low=0, high=2**53 - 1):
    return isinstance(value, int) and not isinstance(value, bool) and low <= value <= high


def _is_str(value, pattern):
    return isinstance(value, str) and pattern.fullmatch(value) is not None


def _is_time(value):
    if not _is_str(value, TIMESTAMP):
        return False
    try:
        datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True


def _string_set(value, allowed):
    """A non-empty list of distinct strings from allowed. Items are type-checked before hashing ([{}] is invalid)."""
    return (isinstance(value, list) and bool(value) and all(isinstance(item, str) and item in allowed for item in value)
            and len(set(value)) == len(value))


def _one_of(value, allowed):
    return isinstance(value, str) and value in allowed


def safe_relative(path):
    """Relative path of `[A-Za-z0-9._-]+` segments, none `.` or `..` (SCHEMAS.md §7 path, §9 archive paths)."""
    parts = path.split("/") if isinstance(path, str) else []
    return bool(parts) and all(SAFE_PART.fullmatch(p) and p not in (".", "..") for p in parts)


def version_tuple(text):
    parts = [int(part) for part in text.split(".")]
    return tuple(parts + [0] * (4 - len(parts)))


def _check_constraint(text):
    if not isinstance(text, str) or not text:
        return False
    for clause in text.split(","):
        match = CLAUSE.fullmatch(clause)
        if not match or not VERSION.fullmatch(match.group(2)):
            return False
    return True


def check_requires(value, stage):
    _require(isinstance(value, dict), stage)
    for axis, constraint in value.items():
        _require(_is_str(axis, AXIS) and _check_constraint(constraint), stage)


def satisfies(requires, consumer):
    """True when every requirement on an axis of the consumer's platform holds (§8). Unknown axes fail closed."""
    axes = AXES[consumer["platform"]]
    for axis, constraint in requires.items():
        if axis not in AXES["box"] | AXES["mac"]:
            return False
        if axis not in axes:
            continue
        have = consumer["versions"].get(axis)
        if have is None:
            return False
        for clause in constraint.split(","):
            op, want = CLAUSE.fullmatch(clause).groups()
            a, b = version_tuple(have), version_tuple(want)
            if (op == ">=" and a < b) or (op == "<" and a >= b) or (op == "==" and a != b):
                return False
    return True


def check_envelope(envelope, stage):
    _require(isinstance(envelope, dict) and set(envelope) == {"signed", "signatures"}, stage)
    _require(isinstance(envelope["signed"], dict), stage)
    signatures = envelope["signatures"]
    _require(isinstance(signatures, list) and signatures, stage)
    _require(stage == "keys" or len(signatures) == 1, stage)
    for entry in signatures:
        _require(isinstance(entry, dict) and set(entry) == {"key_id", "sig"}, stage)
        _require(_is_str(entry["key_id"], KEY_ID) and _is_str(entry["sig"], HEX128), stage)


def check_pins(pins):
    _require(isinstance(pins, dict) and pins.get("schema") == "swarmhub/pins/1", "pins")
    roots = pins.get("roots")
    _require(isinstance(roots, list) and roots, "pins")
    for root in roots:
        _require(isinstance(root, dict) and _is_str(root.get("key_id"), KEY_ID)
                 and _is_str(root.get("ed25519_pub"), HEX64), "pins")
    _require(_is_int(pins.get("threshold"), 1, len(roots)), "pins")


def check_key_manifest(signed):
    stage = "keys"
    _require(signed.get("schema") == "swarmhub/keys/1", stage)
    _require(_is_int(signed.get("version"), 1) and _is_time(signed.get("issued")), stage)
    keys = signed.get("keys")
    _require(isinstance(keys, list) and keys, stage)
    for key in keys:
        _require(isinstance(key, dict) and _is_str(key.get("key_id"), KEY_ID), stage)
        _require(_is_str(key.get("ed25519_pub"), HEX64) and _is_time(key.get("not_after")), stage)
        _require(_string_set(key.get("roles"), {"bundle", "index"}), stage)
    _require(len({key["key_id"] for key in keys}) == len(keys), stage)


def check_index(signed):
    stage = "index"
    _require(signed.get("schema") == "swarmhub/index/1", stage)
    _require(_is_str(signed.get("channel"), CHANNEL) and _is_int(signed.get("seq"), 1), stage)
    _require(_is_time(signed.get("issued")) and _is_time(signed.get("expires")), stage)
    lines = signed.get("lines")
    _require(isinstance(lines, list), stage)
    for line in lines:
        _require(isinstance(line, dict), stage)
        check_requires(line.get("requires"), stage)
        _require(_is_int(line.get("bundle_version"), 1) and _is_str(line.get("manifest_sha256"), HEX64), stage)
        _require(_is_int(line.get("rollout_percent"), 0, 100), stage)


def check_bundle(signed):
    stage = "manifest"
    _require(signed.get("schema") == "swarmhub/bundle/1", stage)
    _require(_is_int(signed.get("version"), 1) and isinstance(signed.get("label"), str), stage)
    _require(_is_time(signed.get("created")) and isinstance(signed.get("code_bearing"), bool), stage)
    check_requires(signed.get("requires"), stage)
    components = signed.get("components")
    _require(isinstance(components, list) and components, stage)
    for c in components:
        _require(isinstance(c, dict) and _one_of(c.get("kind"), KINDS)
                 and _one_of(c.get("class"), {"data", "code"}), stage)
        _require(_is_str(c.get("name"), NAME) and _is_str(c.get("version"), VERSION), stage)
        _require(_string_set(c.get("targets"), set(AXES)), stage)
        _require(_is_str(c.get("sha256"), HEX64) and _is_int(c.get("size")) and safe_relative(c.get("path")), stage)
        check_requires(c.get("requires"), stage)
        deps = c.get("requires_component")
        _require(isinstance(deps, list), stage)
        for dep in deps:
            _require(isinstance(dep, dict) and _is_str(dep.get("name"), NAME)
                     and _is_str(dep.get("min_version"), VERSION), stage)
    _require(len({c["name"] for c in components}) == len(components), stage)
    for c in components:
        _require(not (c["kind"] == "tool" and c["class"] != "code"), stage, "class_mismatch")
        _require(not (c["kind"] in ("config", "ui") and c["class"] != "data"), stage, "class_mismatch")
    _require(signed["code_bearing"] == any(c["class"] == "code" for c in components), stage, "code_bearing_mismatch")
    for c in components:
        box_only = c["class"] == "code" or c["kind"] in ("skill", "tool")
        _require(not box_only or c["targets"] == ["box"], stage, "target_invalid")
