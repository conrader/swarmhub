"""Device-approval v2 (docs/update-service/DEVICE-APPROVALS.md): shapes, crypto checks, local state.

Box-local only: devices, the device-required mode and box-issued challenges live in control.sqlite,
next to actions and receipts, so one transaction covers verification, nonce use, decision and receipt.
Every read validates every row; anything unexpected is `state_invalid` (fail closed). No network.
"""
import hashlib
import math
import re
import time
from urllib.parse import urlsplit

import swarm_ed25519 as ed25519
import swarm_jcs as jcs

DOMAIN = "swarmhub/device-approval/2"
CONTEXT = b"swarmhub-device-approval/2\n"
# Reads (challenge, receipt) are device-signed too, under their own domain, never the decision one.
REQUEST_DOMAIN = "swarmhub/device-request/2"
REQUEST_CONTEXT = b"swarmhub-device-request/2\n"
LIMIT = 16384
TTL = 60
SKEW = 5  # A read request may be stamped up to 5 s ahead of the box clock, as in v1.
FIELDS = {"version", "domain", "key_id", "origin", "runtime", "profile", "task",
          "fingerprint", "gate", "approved", "nonce", "issued", "expires"}
NONCE_FIELDS = FIELDS - {"approved"}
REQUEST_FIELDS = {"version", "domain", "verb", "key_id", "origin", "profile", "task", "issued"}
NAME = r"[A-Za-z0-9_-]{1,64}"
KEY_ID = r"[A-Za-z0-9._-]{1,64}"
UUID = r"[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}"
TASK = r"task\.[a-f0-9]{32}"
HEX32 = r"[a-f0-9]{64}"
ERRORS = (ValueError, TypeError, KeyError, AttributeError, RecursionError, OverflowError)


class Refusal(ValueError):
    """A v2 refusal; str(error) is the reason code from DEVICE-APPROVALS.md."""


def require(ok, reason):
    if not ok:
        raise Refusal(reason)


def matches(value, pattern):
    return isinstance(value, str) and re.fullmatch(pattern, value) is not None


def integer(value):
    return type(value) is int and 0 <= value <= jcs.MAX_SAFE_INT


def canonical_origin(value):
    """Operator-configured lowercase HTTPS authority, no path/credentials/default port."""
    if not isinstance(value, str) or not value.isascii() or any(c.isspace() for c in value):
        return False
    try:
        parts = urlsplit(value)
        return (parts.scheme == "https" and bool(parts.hostname) and not parts.username
                and not parts.password and not parts.path and not parts.query and not parts.fragment
                and value == "https://" + parts.netloc and parts.netloc == parts.netloc.lower()
                and len(parts.hostname) <= 253
                and all(matches(label, r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")
                        for label in parts.hostname.split("."))
                and (parts.port is None or 1 <= parts.port <= 65535 and parts.port != 443)
                and parts.netloc == parts.hostname + (":" + str(parts.port) if parts.port else ""))
    except ValueError:
        return False


def box_now():
    """Box clock as integer Unix seconds; a clock that is not a finite safe nonnegative value fails closed."""
    value = time.time()
    require(isinstance(value, (int, float)) and math.isfinite(value) and 0 <= value <= jcs.MAX_SAFE_INT,
            "state_invalid")
    return int(math.floor(value))


def fingerprint(spec):
    """v2 fingerprint: SHA-256 of JCS(full spec). Not the v1 digest (different escaping)."""
    require(isinstance(spec, dict), "state_invalid")
    return hashlib.sha256(jcs.canonical(spec)).hexdigest()


def message(context, signed):
    return context + jcs.canonical(signed)


def prime_point(encoded):
    point = ed25519.decode_point(encoded)
    return (point is not None and not ed25519._equal(point, ed25519.IDENTITY)
            and ed25519._equal(ed25519._mul(ed25519.L, point), ed25519.IDENTITY))


def signature_valid(public, signed_message, signature):
    return (prime_point(public) and prime_point(signature[:32])
            and ed25519.verify(public, signed_message, signature))


def check_shape(body):
    require(isinstance(body, dict) and set(body) == FIELDS, "schema_invalid")
    require(type(body["version"]) is int and isinstance(body["domain"], str), "schema_invalid")
    require(matches(body["key_id"], KEY_ID) and canonical_origin(body["origin"])
            and matches(body["runtime"], UUID) and matches(body["profile"], NAME)
            and matches(body["task"], TASK) and matches(body["fingerprint"], HEX32)
            and body["gate"] in ("owner", "coordinator")
            and type(body["approved"]) is bool and matches(body["nonce"], HEX32)
            and integer(body["issued"]) and integer(body["expires"])
            and 0 < body["expires"] - body["issued"] <= TTL, "schema_invalid")


def check_request_shape(body, verb):
    require(isinstance(body, dict) and set(body) == REQUEST_FIELDS, "schema_invalid")
    require(type(body["version"]) is int and isinstance(body["domain"], str), "schema_invalid")
    require(matches(body["key_id"], KEY_ID) and canonical_origin(body["origin"])
            and matches(body["profile"], NAME) and matches(body["task"], TASK)
            and body["verb"] in ("challenge", "receipt") and integer(body["issued"]), "schema_invalid")
    require(body["version"] == 2 and body["domain"] == REQUEST_DOMAIN and body["verb"] == verb,
            "protocol_unsupported")


def envelope(raw):
    """Strict outer JSON. Returns the parsed document (any top-level dict)."""
    require(isinstance(raw, bytes) and 0 < len(raw) <= LIMIT, "schema_invalid")
    doc = jcs.loads(raw)
    require(isinstance(doc, dict), "schema_invalid")
    return doc


def signed_parts(doc):
    require(set(doc) == {"signed", "signature"}, "schema_invalid")
    return doc["signed"], doc["signature"]


def check_signature(device, context, body, signature):
    require(matches(signature, r"[a-f0-9]{128}"), "schema_invalid")
    require(device is not None, "device_unknown")
    require(not device["revoked"], "device_revoked")
    require(signature_valid(bytes.fromhex(device["public"]), message(context, body),
                            bytes.fromhex(signature)), "signature_invalid")


def device_required(db):
    """Persistent mode. No row = a box that never enrolled = legacy; any doubt = state_invalid."""
    rows = db.execute("SELECT id,required,changed FROM approval_mode").fetchall()
    devices = db.execute("SELECT count(*) FROM approval_devices").fetchone()[0]
    if not rows:
        require(devices == 0, "state_invalid")  # Devices without a mode row: the row was lost or removed.
        return False
    require(len(rows) == 1 and rows[0]["id"] == 1 and type(rows[0]["required"]) is int
            and rows[0]["required"] in (0, 1) and integer(rows[0]["changed"]), "state_invalid")
    return rows[0]["required"] == 1


def devices(db):
    result = {}
    for row in db.execute("SELECT key_id,public,profiles,revoked,enrolled,label FROM approval_devices"):
        require(matches(row["key_id"], KEY_ID) and matches(row["public"], HEX32)
                and prime_point(bytes.fromhex(row["public"]))
                and type(row["revoked"]) is int and row["revoked"] in (0, 1)
                and integer(row["enrolled"]) and isinstance(row["label"], str)
                and isinstance(row["profiles"], str), "state_invalid")
        try:
            profiles = jcs.loads(row["profiles"].encode())
        except ERRORS as error:
            raise Refusal("state_invalid") from error
        require(isinstance(profiles, list) and profiles and len(set(profiles)) == len(profiles)
                and all(matches(p, NAME) for p in profiles)
                and jcs.canonical(profiles).decode() == row["profiles"], "state_invalid")
        result[row["key_id"]] = {"public": row["public"], "profiles": profiles,
                                 "revoked": row["revoked"] == 1, "label": row["label"]}
    # One key under two IDs would let revoking one ID leave the key live under the other.
    require(len({d["public"] for d in result.values()}) == len(result), "state_invalid")
    return result


def challenges(db):
    """Every stored challenge, validated; a corrupt or inconsistent row anywhere fails closed.

    `expired`: a receipt read already reported box time at or past this nonce's expiry.
    """
    result = {}
    expired = {row[0] for row in db.execute("SELECT nonce FROM approval_expired")}
    for row in db.execute("SELECT nonce,key_id,task,issued,expires,used,binding FROM approval_challenges"):
        require(isinstance(row["binding"], str) and type(row["used"]) is int and row["used"] in (0, 1),
                "state_invalid")
        try:
            binding = jcs.loads(row["binding"].encode())
            require(isinstance(binding, dict) and set(binding) == NONCE_FIELDS, "state_invalid")
            check_shape({**binding, "approved": False})
        except ERRORS as error:
            raise Refusal("state_invalid") from error
        require(binding["version"] == 2 and binding["domain"] == DOMAIN
                and jcs.canonical(binding).decode() == row["binding"]
                and (row["nonce"], row["key_id"], row["task"], row["issued"], row["expires"])
                == (binding["nonce"], binding["key_id"], binding["task"], binding["issued"], binding["expires"]),
                "state_invalid")
        result[row["nonce"]] = {"binding": binding, "used": row["used"] == 1, "expired": row["nonce"] in expired}
    return result


def runtime(db):
    rows = db.execute("SELECT identity FROM approval_runtime").fetchall()
    require(len(rows) == 1 and matches(rows[0][0], UUID), "state_invalid")
    return rows[0][0]


def snapshot(db, origin):
    """All local trust state, re-read inside the caller's transaction."""
    require(canonical_origin(origin), "state_invalid")
    return {"device_required": device_required(db), "devices": devices(db),
            "nonces": challenges(db), "runtime": runtime(db), "origin": origin}
