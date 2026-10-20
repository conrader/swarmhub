"""Reference evaluation of one release test vector (docs/update-service/SCHEMAS.md §9). Stdlib only.

This is the executable statement of the verification order the vectors encode, used to check that every vector in
Tests/Fixtures/release-bundles/vectors.json has its expected verdict. It is not the updater: no I/O policy, no
extraction, no state. P0b/P0c implement the production verifiers against the same vectors.
"""

import hashlib
import re
from pathlib import Path

import ed25519_ref
import jcs
import ustar
from schemas import (Reject, check_bundle, check_envelope, check_index, check_key_manifest, check_pins, satisfies,
                     version_tuple)

SIG_CONTEXT = b"swarmhub-signature/1\n"
DATA_EXTENSIONS = {"skill": {".md"}, "config": {".json", ".md", ".txt"}, "ui": {".json"}}
SAFE_PART = re.compile(r"^[A-Za-z0-9._-]+$")


def signing_message(signed):
    return SIG_CONTEXT + jcs.canonical(signed)


def _load(root, rel, stage, limit):
    data = (root / rel).read_bytes()
    if len(data) > limit:
        raise Reject(stage, "schema_invalid")
    try:
        value = jcs.loads(data)
    except jcs.JCSError as error:
        raise Reject(stage, "schema_invalid") from error
    return data, value


def verify_keys(envelope, pins, floors):
    check_envelope(envelope, "keys")
    signed = envelope["signed"]
    check_key_manifest(signed)
    roots = {root["key_id"]: bytes.fromhex(root["ed25519_pub"]) for root in pins["roots"]}
    message, seen = signing_message(signed), set()
    for entry in envelope["signatures"]:
        public = roots.get(entry["key_id"])
        if public is None or entry["key_id"] in seen:
            raise Reject("keys", "keys_untrusted")
        if not ed25519_ref.verify(public, message, bytes.fromhex(entry["sig"])):
            raise Reject("keys", "keys_bad_signature")
        seen.add(entry["key_id"])
    if len(seen) < pins["threshold"]:
        raise Reject("keys", "keys_threshold")
    if signed["version"] < floors["keys_version"]:
        raise Reject("keys", "keys_rollback")
    return {key["key_id"]: key for key in signed["keys"]}


def verify_signed_by_release_key(envelope, keys, role, stage, now, revoked):
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
    if not ed25519_ref.verify(bytes.fromhex(key["ed25519_pub"]), message, bytes.fromhex(signature["sig"])):
        raise Reject(stage, "bad_signature")


def bucket(install_id, bundle_version):
    digest = hashlib.sha256(f"{install_id}\n{bundle_version}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") % 100


def select_line(index, consumer, install_id):
    compatible = [line for line in index["lines"] if satisfies(line["requires"], consumer)]
    if not compatible:
        raise Reject("index", "no_compatible_line")
    included = [line for line in compatible if bucket(install_id, line["bundle_version"]) < line["rollout_percent"]]
    if not included:
        return None
    return max(included, key=lambda line: line["bundle_version"])


def check_archive(data, kind, limits):
    """Apply the archive rules; return True when the content needs class `code`."""
    entries = ustar.read(data)
    if len(entries) > limits["max_entries"]:
        raise Reject("component", "archive_oversize")
    paths, dirs, total, needs_code = set(), set(), 0, False
    for entry in entries:
        flag = entry["typeflag"]
        if flag in "12":
            raise Reject("component", "archive_link")
        if flag in "346":
            raise Reject("component", "archive_special_file")
        if flag not in "05":
            raise Reject("component", "archive_unsupported_entry")
        name = entry["name"]
        if flag == "5" and name.endswith("/"):
            name = name[:-1]
        parts = name.split("/")
        if (name.startswith("/") or len(name.encode("utf-8")) > limits["max_path_bytes"]
                or len(parts) > limits["max_depth"]
                or not all(SAFE_PART.match(p) and p not in (".", "..") for p in parts)):
            raise Reject("component", "archive_unsafe_path")
        if name in paths:
            raise Reject("component", "archive_duplicate_path")
        paths.add(name)
        allowed = {0o755} if flag == "5" else {0o644, 0o755}
        if entry["mode"] not in allowed:
            raise Reject("component", "archive_bad_mode")
        if flag == "5":
            dirs.add(name)
            continue
        if entry["size"] > limits["max_file_size"]:
            raise Reject("component", "archive_oversize")
        total += entry["size"]
        if total > limits["max_total_size"]:
            raise Reject("component", "archive_oversize")
        if entry["mode"] == 0o755 or Path(name).suffix not in DATA_EXTENSIONS.get(kind, set()):
            needs_code = True
    files = paths - dirs
    for name in paths:
        for i in range(1, name.count("/") + 1):
            if name.rsplit("/", i)[0] in files:
                raise Reject("component", "archive_path_conflict")
    return needs_code


def check_components(manifest, consumer, root, limits):
    names = {c["name"]: c for c in manifest["components"]}
    for component in manifest["components"]:
        for dep in component["requires_component"]:
            target = names.get(dep["name"])
            if target is None or dep["name"] == component["name"] or \
                    version_tuple(target["version"]) < version_tuple(dep["min_version"]) or \
                    not set(component["targets"]) <= set(target["targets"]):
                raise Reject("manifest", "dependency_invalid")
    platform = consumer["platform"]
    wanted = [c for c in manifest["components"] if platform in c["targets"]]
    skipped = {}
    for component in wanted:
        if not satisfies(component["requires"], consumer):
            skipped[component["name"]] = "incompatible"
    changed = True
    while changed:  # a component that requires a skipped one is skipped too, transitively
        changed = False
        for component in wanted:
            if component["name"] in skipped:
                continue
            if any(dep["name"] in skipped for dep in component["requires_component"]):
                skipped[component["name"]] = "dependency_skipped"
                changed = True
    apply = []
    for component in wanted:
        if component["name"] in skipped:
            continue
        if component["size"] > limits["max_blob_size"]:
            raise Reject("component", "archive_oversize")
        data = (root / "blobs" / "sha256" / component["sha256"]).read_bytes()
        if len(data) != component["size"]:
            raise Reject("component", "blob_size_mismatch")
        if hashlib.sha256(data).hexdigest() != component["sha256"]:
            raise Reject("component", "blob_hash_mismatch")
        try:
            needs_code = check_archive(data, component["kind"], limits)
        except ustar.ArchiveError as error:
            raise Reject("component", error.reason) from error
        if needs_code and component["class"] != "code":
            raise Reject("component", "class_mismatch")
        apply.append(component["name"])
    return apply, [{"name": c["name"], "reason": skipped[c["name"]]} for c in wanted if c["name"] in skipped]


def evaluate(case, root):
    """Return the verdict dict for one vector case; root is the fixture directory."""
    root = Path(root)
    inputs = case["inputs"]
    limits, floors, consumer = inputs["limits"], inputs["floors"], inputs["consumer"]
    now, revoked = inputs["now"], set(inputs["revoked_key_ids"])
    try:
        _, pins = _load(root, inputs["pins"], "pins", limits["max_signed_bytes"])
        check_pins(pins)
        _, envelope = _load(root, inputs["keys"], "keys", limits["max_signed_bytes"])
        keys = verify_keys(envelope, pins, floors)

        _, envelope = _load(root, inputs["index"], "index", limits["max_signed_bytes"])
        check_envelope(envelope, "index")
        index = envelope["signed"]
        check_index(index)
        verify_signed_by_release_key(envelope, keys, "index", "index", now, revoked)
        if index["seq"] < floors["index_seq"]:
            raise Reject("index", "index_rollback")
        if index["channel"] != inputs["channel"]:
            raise Reject("index", "channel_mismatch")
        if now >= index["expires"]:
            raise Reject("index", "index_expired")
        line = select_line(index, consumer, inputs["install_id"])
        if line is None:
            return {"verdict": "no_update", "stage": "index", "reason": "not_in_rollout"}
        if line["bundle_version"] < floors["bundle_version"]:
            raise Reject("index", "bundle_rollback")
        if line["bundle_version"] == floors["bundle_version"]:
            return {"verdict": "no_update", "stage": "index", "reason": "already_applied"}

        raw = (root / inputs["manifest"]).read_bytes()
        if hashlib.sha256(raw).hexdigest() != line["manifest_sha256"]:
            raise Reject("manifest", "manifest_hash_mismatch")
        _, envelope = _load(root, inputs["manifest"], "manifest", limits["max_signed_bytes"])
        check_envelope(envelope, "manifest")
        manifest = envelope["signed"]
        check_bundle(manifest)
        verify_signed_by_release_key(envelope, keys, "bundle", "manifest", now, revoked)
        if manifest["version"] != line["bundle_version"]:
            raise Reject("manifest", "version_mismatch")
        if not satisfies(manifest["requires"], consumer):
            raise Reject("manifest", "incompatible_requires")
        apply, skipped = check_components(manifest, consumer, root, limits)
    except Reject as reject:
        return {"verdict": "reject", "stage": reject.stage, "reason": reject.reason}
    return {"verdict": "accept", "stage": "component", "reason": "ok", "bundle_version": manifest["version"],
            "apply": apply, "skipped": skipped}
