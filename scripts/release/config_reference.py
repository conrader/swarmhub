"""Reference decoder for app config components (docs/update-service/SCHEMAS.md §12, phase P6a). Stdlib only.

The Python statement of Packages/SwarmHubCore/Sources/SwarmHubCore/Updates/ConfigDecoder.swift and the reads of
ConfigStore.swift. scripts/test_swift_config_vectors.py runs it over Tests/Fixtures/release-bundles/config/ and
checks that the Swift sources carry the same denylist. `snapshot` mirrors the pinned, all-or-nothing store
read; release tooling can call `decode` to refuse a config component an app would ignore.
"""

import hashlib
import json
import os
from pathlib import Path
import re

import jcs
import ustar
from reference_verify import check_archive
from schemas import Reject

DOMAINS = ("policy", "prompts", "copy", "flags")
MAX_DOCUMENT_BYTES = 262_144
KEY_PATTERN = re.compile(r"[A-Za-z0-9._-]{1,128}")
DENIED_FRAGMENTS = (
    "allowlist", "apikey", "approv", "authent", "authoriz", "bearer", "blacklist", "blocklist", "confirm",
    "credential", "denylist", "endpoint", "enroll", "hmac", "keychain", "nonce", "operationreview",
    "passphrase", "password", "permission", "privatekey", "publickey", "secret", "signingkey", "webhook",
    "whitelist",
)
DENIED_WORDS = frozenset((
    "auth", "device", "devices", "gate", "gated", "gates", "gateway", "gating", "host", "hostname", "hosts",
    "key", "keys", "origin", "origins", "pin", "pinned", "pins", "signature", "signatures", "signer",
    "signing", "token", "tokens", "trust", "trusted", "uri", "url", "urls",
))
KILL_SCOPES = frozenset(("policy", "prompts", "copy", "flags", "view"))
LIMITS = dict(max_blob_size=67108864, max_depth=16, max_entries=4096, max_file_size=8388608, max_path_bytes=255,
              max_signed_bytes=1048576, max_total_size=67108864)


def report(reason, domain=None, key=None, component=None):
    out = {"reason": reason}
    for name, value in (("domain", domain), ("key", key), ("component", component)):
        if value is not None:
            out[name] = value
    return out


def _lower(data):
    return bytes(b + 32 if 65 <= b <= 90 else b for b in data)


def _normalized(data):
    return _lower(bytes(b for b in data if b not in b"-._"))


def denied_name(name):
    raw = name.encode("utf-8")
    flat = _normalized(raw)
    if any(f.encode() in flat for f in DENIED_FRAGMENTS):
        return True
    words, word = [], bytearray()
    for i, b in enumerate(raw):
        if b in b"-._":
            words.append(bytes(word))
            word = bytearray()
            continue
        if 65 <= b <= 90 and i > 0 and (97 <= raw[i - 1] <= 122 or 48 <= raw[i - 1] <= 57):
            words.append(bytes(word))
            word = bytearray()
        word.append(_lower(bytes([b]))[0])
    words.append(bytes(word))
    return any(w.decode("ascii", "replace") in DENIED_WORDS for w in words)


def name_problem(name):
    if not KEY_PATTERN.fullmatch(name):
        return "invalid_key"
    return "denied_key" if denied_name(name) else None


def denied_string(text):
    raw = text.encode("utf-8", "surrogatepass")
    if raw.startswith(b"/") or b"://" in raw:
        return True
    flat = _normalized(raw)
    return any(f.encode() in flat for f in DENIED_FRAGMENTS)


def _collect(value, names, strings):
    if isinstance(value, str):
        strings.append(value)
    elif isinstance(value, list):
        for item in value:
            _collect(item, names, strings)
    elif isinstance(value, dict):
        for name, item in value.items():
            names.append(name)
            _collect(item, names, strings)


def value_problem(domain, value):
    if domain == "flags":
        return None if isinstance(value, bool) else "wrong_type"
    if domain in ("prompts", "copy"):
        return None if isinstance(value, str) else "wrong_type"
    names, strings = [], []
    _collect(value, names, strings)
    if any(not KEY_PATTERN.fullmatch(n) for n in names):
        return "invalid_key"
    if any(denied_name(n) for n in names):
        return "denied_key"
    return "denied_value" if any(denied_string(s) for s in strings) else None


def _sorted_names(names):
    return sorted(names, key=lambda n: n.encode("utf-8"))


def _decode_document(domain, component, data, result):
    def rep(reason, key=None):
        result["reports"].append(report(reason, domain, key, component))
    if len(data) > MAX_DOCUMENT_BYTES:
        return rep("config_too_large")
    try:
        members = jcs.loads(data)
    except jcs.JCSError:
        return rep("config_invalid")
    if not isinstance(members, dict) or members.get("schema") != f"swarmhub/config-{domain}/1":
        return rep("schema_invalid")
    accepted = {}
    for key in _sorted_names(members):
        if key in ("schema", "note"):
            continue
        value = members[key]
        reason = name_problem(key) or value_problem(domain, value)
        if reason:
            rep(reason, key)
            continue
        if domain != "flags" or not key.startswith("kill."):
            accepted[key] = value
            continue
        scope, dot, name = key[len("kill."):].partition(".")
        if not dot or scope not in KILL_SCOPES or not name or name.startswith("kill."):
            rep("invalid_kill", key)
            continue
        if value is True:
            if scope == "view":
                result["killed_views"].add(name)
            else:
                result["killed_keys"].add(f"{scope}.{name}")
    result["values"][domain] = accepted


def decode(components):
    """Decoder-only vectors: [(name, archive bytes or None)], record order. Live reads use snapshot below."""
    result = {"values": {}, "killed_keys": set(), "killed_views": set(), "reports": []}
    found = {}
    for name, archive in components:
        if archive is None:
            result["reports"].append(report("component_unreadable", component=name))
            continue
        try:
            if check_archive(archive, "config", LIMITS):
                result["reports"].append(report("component_not_data", component=name))
                continue
            files = {e["name"]: e["data"] for e in ustar.read(archive) if e["typeflag"] == "0"}
        except (Reject, ustar.ArchiveError) as error:
            result["reports"].append(report(error.reason, component=name))
            continue
        for domain in DOMAINS:
            if f"{domain}.json" in files:
                found.setdefault(domain, []).append((name, files[f"{domain}.json"]))
    for domain in DOMAINS:
        documents = found.get(domain)
        if not documents:
            continue
        if len(documents) > 1:
            for component, _ in documents:
                result["reports"].append(report("duplicate_document", domain, component=component))
            continue
        _decode_document(domain, documents[0][0], documents[0][1], result)
    return result


def snapshot(root, before_component_read=None):
    """ConfigStore's disk rule: pin current + record once, read each archive once, then decode.

    A missing/corrupt pinned record or config component discards ALL values and kill flags. No retry against
    a newer current is allowed. The optional hook models a switch/collection between the record and bytes,
    or between components. Decoder-only fixtures above retain their original partial-decode semantics.
    """
    root = Path(root)
    empty = decode([])
    empty["bundle_version"] = None
    try:
        target = os.readlink(root / "current")
    except OSError:
        return empty
    if not re.fullmatch(r"versions/[0-9]{1,16}-[0-9a-f]{16}", target):
        return empty
    directory = root / target
    try:
        record = json.loads((directory / "record.json").read_bytes())
        entries = [c for c in record["components"] if c["kind"] == "config" and c["class"] == "data"]
        version = record["bundle_version"]
    except (OSError, ValueError, KeyError, TypeError):
        empty["reports"] = [report("bundle_unreadable")]
        return empty
    components, failures = [], []
    for entry in entries:
        name, archive = entry["name"], None
        try:
            if re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,63}", name):
                if before_component_read:
                    before_component_read(name)
                data = (directory / "components" / name).read_bytes()
                if len(data) == entry["size"] and hashlib.sha256(data).hexdigest() == entry["sha256"]:
                    archive = data
        except OSError:
            pass
        components.append((name, archive))
        if archive is None:
            failures.append(report("component_unreadable", component=name))
    if failures:
        empty["reports"] = failures
        return empty
    result = decode(components)
    result["bundle_version"] = version
    return result


def _typed(kind, value, low, high):
    """The read-time type rule of ConfigKey; returns (value, None) or (None, reason)."""
    def integer(v):
        if not isinstance(v, int) or isinstance(v, bool):
            return None, "wrong_type"
        return (v, None) if low <= v <= high else (None, "out_of_range")
    if kind == "string":
        return (value, None) if isinstance(value, str) else (None, "wrong_type")
    if kind == "bool":
        return (value, None) if isinstance(value, bool) else (None, "wrong_type")
    if kind == "integer":
        return integer(value)
    if kind == "string_list":
        ok = isinstance(value, list) and all(isinstance(v, str) for v in value)
        return (value, None) if ok else (None, "wrong_type")
    if kind == "string_map":
        ok = isinstance(value, dict) and all(isinstance(v, str) for v in value.values())
        return (value, None) if ok else (None, "wrong_type")
    if kind == "integer_map":
        if not isinstance(value, dict) or not all(isinstance(v, int) and not isinstance(v, bool)
                                                  for v in value.values()):
            return None, "wrong_type"
        if not all(low <= v <= high for v in value.values()):
            return None, "out_of_range"
        return value, None
    raise ValueError(f"unknown read type {kind}")


def read(result, domain, key, kind, default, low=-jcs.MAX_SAFE_INT, high=jcs.MAX_SAFE_INT):
    """Returns (value, read-time reason or None), as ConfigStore.value does."""
    if f"{domain}.{key}" in result["killed_keys"]:
        return default, "killed"
    values = result["values"].get(domain, {})
    if key not in values:
        return default, None
    value, reason = _typed(kind, values[key], low, high)
    return (default, reason) if reason else (value, None)
