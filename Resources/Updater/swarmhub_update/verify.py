"""Release verification for the updater (CORE-PLAN.md §3.1; contract and order in docs/update-service/SCHEMAS.md).

No I/O policy: callers pass bytes, and two callables fetch the bundle manifest and component blobs on demand, so the
same code serves pull (P3a), `apply --staged` (P4b) and tests. Stages run in order and the first failing check
decides: pins → key manifest (root threshold) → channel index (release key, floors, expiry, line selection) →
bundle manifest (hash, schema, signature, compatibility) → components (size, hash, archive rules, content class).

Every malformed shape is `schema_invalid` and every check raises Reject or NoUpdate, never another exception, for
any input bytes. Patterns are matched in full, so a trailing newline never passes. Stdlib only, Python 3.8+.
"""

import hashlib
import re
from datetime import datetime

from . import archive, ed25519, jcs

SIG_CONTEXT = b"swarmhub-signature/1\n"
HEX64 = re.compile(r"[0-9a-f]{64}")
HEX128 = re.compile(r"[0-9a-f]{128}")
KEY_ID = re.compile(r"[A-Za-z0-9._-]{1,64}")
NAME = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")
CHANNEL = re.compile(r"[a-z0-9-]{1,32}")
AXIS = re.compile(r"[a-z_]{1,32}")
VERSION = re.compile(r"(0|[1-9][0-9]{0,8})(\.(0|[1-9][0-9]{0,8})){0,3}")
CLAUSE = re.compile(r"(>=|<|==)(.+)")
TIMESTAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z")
AXES = {"box": {"updater", "hermes"}, "mac": {"app", "ui_catalog", "config_schema"},
        "ios": {"app", "ui_catalog", "config_schema"}}
KNOWN_AXES = AXES["box"] | AXES["mac"]
KINDS = {"skill", "tool", "config", "ui"}
CLASSES = {"data", "code"}
DEFAULT_LIMITS = {"max_signed_bytes": 1048576, "max_blob_size": 67108864, "max_entries": 4096,
                  "max_file_size": 8388608, "max_total_size": 67108864, "max_path_bytes": 255, "max_depth": 16}


class Reject(Exception):
    """A failed check: the consumer stays on its last good bundle and reports stage + reason."""

    def __init__(self, stage, reason):
        super().__init__(f"{stage}: {reason}")
        self.stage, self.reason = stage, reason


class NoUpdate(Exception):
    """Nothing to apply: `not_in_rollout` or `already_applied`."""

    def __init__(self, reason):
        super().__init__(reason)
        self.stage, self.reason = "index", reason


# Shapes ----------------------------------------------------------------------------------------------------------

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


def _one_of(value, allowed):
    return isinstance(value, str) and value in allowed


def _string_set(value, allowed):
    """A non-empty list of distinct strings from allowed; items are type-checked before hashing."""
    return (isinstance(value, list) and bool(value) and all(_one_of(item, allowed) for item in value)
            and len(set(value)) == len(value))


def version_tuple(text):
    parts = [int(part) for part in text.split(".")]
    return tuple(parts + [0] * (4 - len(parts)))


def _valid_constraint(text):
    if not isinstance(text, str) or not text:
        return False
    for clause in text.split(","):
        match = CLAUSE.fullmatch(clause)
        if not match or not VERSION.fullmatch(match.group(2)):
            return False
    return True


def _check_requires(value, stage):
    _require(isinstance(value, dict), stage)
    for axis, constraint in value.items():
        _require(_is_str(axis, AXIS) and _valid_constraint(constraint), stage)


def satisfies(requires, consumer):
    """True when every requirement on an axis of the consumer's platform holds (§8). Unknown axes fail closed."""
    axes = AXES[consumer["platform"]]
    for axis, constraint in requires.items():
        if axis not in KNOWN_AXES:
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
    _require(isinstance(signatures, list) and bool(signatures), stage)
    _require(stage == "keys" or len(signatures) == 1, stage)
    for entry in signatures:
        _require(isinstance(entry, dict) and set(entry) == {"key_id", "sig"}, stage)
        _require(_is_str(entry["key_id"], KEY_ID) and _is_str(entry["sig"], HEX128), stage)


def check_pins(pins):
    _require(isinstance(pins, dict) and pins.get("schema") == "swarmhub/pins/1", "pins")
    roots = pins.get("roots")
    _require(isinstance(roots, list) and bool(roots), "pins")
    for root in roots:
        _require(isinstance(root, dict) and _is_str(root.get("key_id"), KEY_ID)
                 and _is_str(root.get("ed25519_pub"), HEX64), "pins")
    _require(_is_int(pins.get("threshold"), 1, len(roots)), "pins")


def check_key_manifest(signed):
    stage = "keys"
    _require(signed.get("schema") == "swarmhub/keys/1", stage)
    _require(_is_int(signed.get("version"), 1) and _is_time(signed.get("issued")), stage)
    keys = signed.get("keys")
    _require(isinstance(keys, list) and bool(keys), stage)
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
        _check_requires(line.get("requires"), stage)
        _require(_is_int(line.get("bundle_version"), 1) and _is_str(line.get("manifest_sha256"), HEX64), stage)
        _require(_is_int(line.get("rollout_percent"), 0, 100), stage)


def check_bundle(signed):
    """Schema, then class metadata, code_bearing and targets (SCHEMAS.md §7, §10 manifest stage)."""
    stage = "manifest"
    _require(signed.get("schema") == "swarmhub/bundle/1", stage)
    _require(_is_int(signed.get("version"), 1) and isinstance(signed.get("label"), str), stage)
    _require(_is_time(signed.get("created")) and isinstance(signed.get("code_bearing"), bool), stage)
    _check_requires(signed.get("requires"), stage)
    components = signed.get("components")
    _require(isinstance(components, list) and bool(components), stage)
    for c in components:
        _require(isinstance(c, dict) and _one_of(c.get("kind"), KINDS) and _one_of(c.get("class"), CLASSES), stage)
        _require(_is_str(c.get("name"), NAME) and _is_str(c.get("version"), VERSION), stage)
        _require(_string_set(c.get("targets"), set(AXES)), stage)
        _require(_is_str(c.get("sha256"), HEX64) and _is_int(c.get("size")), stage)
        _require(archive.safe_relative(c.get("path")), stage)
        _check_requires(c.get("requires"), stage)
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


# Stages ----------------------------------------------------------------------------------------------------------

def signing_message(signed):
    return SIG_CONTEXT + jcs.canonical(signed)


def parse_signed(data, stage, limits):
    """Size, then profile JSON. Returns the parsed value."""
    if not isinstance(data, (bytes, bytearray)) or len(data) > limits["max_signed_bytes"]:
        raise Reject(stage, "schema_invalid")
    try:
        return jcs.loads(bytes(data))
    except jcs.JCSError as error:
        raise Reject(stage, "schema_invalid") from error


def verify_pins(data, limits):
    pins = parse_signed(data, "pins", limits)
    check_pins(pins)
    return pins


def verify_keys(data, pins, floors, limits):
    """Verify the key manifest against the pinned roots; return {key_id: key} of release keys."""
    envelope = parse_signed(data, "keys", limits)
    check_envelope(envelope, "keys")
    signed = envelope["signed"]
    check_key_manifest(signed)
    roots = {root["key_id"]: bytes.fromhex(root["ed25519_pub"]) for root in pins["roots"]}
    message, seen = signing_message(signed), set()
    for entry in envelope["signatures"]:
        public = roots.get(entry["key_id"])
        if public is None or entry["key_id"] in seen:
            raise Reject("keys", "keys_untrusted")
        if not ed25519.verify(public, message, bytes.fromhex(entry["sig"])):
            raise Reject("keys", "keys_bad_signature")
        seen.add(entry["key_id"])
    if len(seen) < pins["threshold"]:
        raise Reject("keys", "keys_threshold")
    if signed["version"] < floors["keys_version"]:
        raise Reject("keys", "keys_rollback")
    return {key["key_id"]: key for key in signed["keys"]}


def _check_release_signature(envelope, keys, role, stage, now, revoked):
    signature = envelope["signatures"][0]
    key_id = signature["key_id"]
    if key_id in revoked:
        raise Reject(stage, "key_revoked")
    key = keys.get(key_id)
    if key is None:
        raise Reject(stage, "unknown_key")
    if role not in key["roles"]:
        raise Reject(stage, "key_wrong_role")
    if now >= key["not_after"]:
        raise Reject(stage, "key_expired")
    message = signing_message(envelope["signed"])
    if not ed25519.verify(bytes.fromhex(key["ed25519_pub"]), message, bytes.fromhex(signature["sig"])):
        raise Reject(stage, "bad_signature")


def rollout_bucket(install_id, bundle_version):
    digest = hashlib.sha256(f"{install_id}\n{bundle_version}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") % 100


def verify_index(data, keys, *, channel, now, floors, revoked, limits):
    """Verify the channel index; return its signed body."""
    envelope = parse_signed(data, "index", limits)
    check_envelope(envelope, "index")
    index = envelope["signed"]
    check_index(index)
    _check_release_signature(envelope, keys, "index", "index", now, revoked)
    if index["seq"] < floors["index_seq"]:
        raise Reject("index", "index_rollback")
    if index["channel"] != channel:
        raise Reject("index", "channel_mismatch")
    if now >= index["expires"]:
        raise Reject("index", "index_expired")
    return index


def select_line(index, consumer, install_id, floors):
    """The line to apply (§6 line selection), or NoUpdate / Reject."""
    compatible = [line for line in index["lines"] if satisfies(line["requires"], consumer)]
    if not compatible:
        raise Reject("index", "no_compatible_line")
    included = [line for line in compatible
                if rollout_bucket(install_id, line["bundle_version"]) < line["rollout_percent"]]
    if not included:
        raise NoUpdate("not_in_rollout")
    line = max(included, key=lambda item: item["bundle_version"])
    if line["bundle_version"] < floors["bundle_version"]:
        raise Reject("index", "bundle_rollback")
    if line["bundle_version"] == floors["bundle_version"]:
        raise NoUpdate("already_applied")
    return line


def verify_manifest(raw, line, keys, *, consumer, now, revoked, limits):
    """Verify the bundle manifest served for line; return its signed body."""
    if not isinstance(raw, (bytes, bytearray)) or hashlib.sha256(raw).hexdigest() != line["manifest_sha256"]:
        raise Reject("manifest", "manifest_hash_mismatch")
    envelope = parse_signed(raw, "manifest", limits)
    check_envelope(envelope, "manifest")
    manifest = envelope["signed"]
    check_bundle(manifest)
    _check_release_signature(envelope, keys, "bundle", "manifest", now, revoked)
    if manifest["version"] != line["bundle_version"]:
        raise Reject("manifest", "version_mismatch")
    if not satisfies(manifest["requires"], consumer):
        raise Reject("manifest", "incompatible_requires")
    names = {c["name"]: c for c in manifest["components"]}
    for component in manifest["components"]:
        for dep in component["requires_component"]:
            target = names.get(dep["name"])
            if (target is None or dep["name"] == component["name"]
                    or version_tuple(target["version"]) < version_tuple(dep["min_version"])
                    or not set(component["targets"]) <= set(target["targets"])):
                raise Reject("manifest", "dependency_invalid")
    return manifest


def plan_components(manifest, consumer):
    """(components to fetch and apply in manifest order, skipped [{name, reason}]) for this consumer."""
    wanted = [c for c in manifest["components"] if consumer["platform"] in c["targets"]]
    skipped = {c["name"]: "incompatible" for c in wanted if not satisfies(c["requires"], consumer)}
    changed = True
    while changed:  # a component that requires a skipped one is skipped too, transitively
        changed = False
        for component in wanted:
            if component["name"] not in skipped and any(d["name"] in skipped for d in component["requires_component"]):
                skipped[component["name"]] = "dependency_skipped"
                changed = True
    return ([c for c in wanted if c["name"] not in skipped],
            [{"name": c["name"], "reason": skipped[c["name"]]} for c in wanted if c["name"] in skipped])


def check_declared_size(component, limits):
    """Before download: the declared size must fit max_blob_size."""
    if component["size"] > limits["max_blob_size"]:
        raise Reject("component", "archive_oversize")


def verify_blob(component, blob, limits):
    """Size, hash, archive rules and content class of one fetched blob. Returns the checked archive entries."""
    if not isinstance(blob, (bytes, bytearray)) or len(blob) != component["size"]:
        raise Reject("component", "blob_size_mismatch")
    if hashlib.sha256(blob).hexdigest() != component["sha256"]:
        raise Reject("component", "blob_hash_mismatch")
    try:
        entries, needs_code = archive.check(blob, component["kind"], limits)
    except archive.ArchiveError as error:
        raise Reject("component", error.reason) from error
    if needs_code and component["class"] != "code":
        raise Reject("component", "class_mismatch")
    return entries


def _check_inputs(now, consumer, floors, limits):
    """Caller inputs are trusted but must be well-formed; a programming error is a ValueError, not a verdict."""
    if not _is_time(now):
        raise ValueError(f"now must be YYYY-MM-DDTHH:MM:SSZ, got {now!r}")
    if not isinstance(consumer, dict) or consumer.get("platform") not in AXES \
            or not isinstance(consumer.get("versions"), dict) \
            or not all(_is_str(v, VERSION) for v in consumer["versions"].values()):
        raise ValueError(f"bad consumer {consumer!r}")
    if not all(_is_int(floors.get(k)) for k in ("keys_version", "index_seq", "bundle_version")):
        raise ValueError(f"bad floors {floors!r}")
    if not all(_is_int(limits.get(k)) for k in DEFAULT_LIMITS):
        raise ValueError(f"bad limits {limits!r}")


def verify_release(pins, keys, index, *, fetch_manifest, fetch_blob, channel, now, floors, consumer, install_id,
                   revoked_key_ids=(), limits=None):
    """Run every stage; return the verdict dict (the `expect` shape of vectors.json).

    pins, keys, index: raw bytes. fetch_manifest(line) -> raw manifest bytes; fetch_blob(component) -> blob bytes,
    called only for components this consumer applies, after their declared size passed. Fetch errors propagate
    (storage/network policy belongs to the caller). On accept, `blobs` maps component name to its verified bytes.
    """
    limits = dict(DEFAULT_LIMITS if limits is None else limits)
    _check_inputs(now, consumer, floors, limits)
    revoked = set(revoked_key_ids)
    try:
        pin_doc = verify_pins(pins, limits)
        release_keys = verify_keys(keys, pin_doc, floors, limits)
        index_doc = verify_index(index, release_keys, channel=channel, now=now, floors=floors, revoked=revoked,
                                 limits=limits)
        line = select_line(index_doc, consumer, install_id, floors)
        manifest = verify_manifest(fetch_manifest(line), line, release_keys, consumer=consumer, now=now,
                                   revoked=revoked, limits=limits)
        apply, skipped = plan_components(manifest, consumer)
        blobs = {}
        for component in apply:
            check_declared_size(component, limits)
            blob = fetch_blob(component)
            verify_blob(component, blob, limits)
            blobs[component["name"]] = bytes(blob)
    except NoUpdate as outcome:
        return {"verdict": "no_update", "stage": outcome.stage, "reason": outcome.reason}
    except Reject as reject:
        return {"verdict": "reject", "stage": reject.stage, "reason": reject.reason}
    return {"verdict": "accept", "stage": "component", "reason": "ok", "bundle_version": manifest["version"],
            "apply": [c["name"] for c in apply], "skipped": skipped, "manifest": manifest, "blobs": blobs}
