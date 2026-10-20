"""The updater's own state directory (CORE-PLAN.md §3.2, §3.4; phase P2b). Bot-writable by design: everything
here is either re-verified before use (stored bundle, blobs) or only ever raised above the protected checkpoint
(floors, see pins.py).

    floors.json            persisted floors {keys_version, index_seq, bundle_version}
    config.json            {channel, install_id, hermes_version?}; install_id is random and local
    profiles.json          swarmhub/profiles/1: which profiles get which skills, in which coding order
    latest.json            pointer to the latest verified bundle: {bundle_version, manifest_sha256, verified_at}
    bundles/<version>/     its raw keys.json, index.json and manifest.json, re-verified on every use
    blobs/sha256/<hex>     verified component archives, hash-checked again whenever read
    applied.json           {components: {name: {version, sha256, kind, class}}, confirmed_version, pin, ...}
    status.json            what `swarmhub-update status` and `swarmctl update-status` print
    profiles/<name>.json   the apply engine's per-profile record (apply.py)

Stdlib only, Python 3.8+.
"""

import hashlib
import json
import os
import secrets
import shutil

from . import apply, bundle, render, verify

STATUS_SCHEMA = "swarmhub/update-status/1"
PROFILES_SCHEMA = "swarmhub/profiles/1"
DEFAULT_CHANNEL = "stable"
MAX_FILE = 64 * 1024 * 1024


def default_state_dir():
    """`$XDG_STATE_HOME/swarmhub-update`, else `~/.local/state/swarmhub-update` (swarmctl reads the same place)."""
    base = os.environ.get("XDG_STATE_HOME") or os.path.join(os.path.expanduser("~"), ".local", "state")
    return os.path.join(base, "swarmhub-update")


class State:
    def __init__(self, root):
        self.root = root

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    # ---- raw files ----------------------------------------------------------------------------------------------

    def read_json(self, *parts, default=None):
        try:  # bot-writable: a FIFO, a huge or deeply nested file is "no value", never a hang or a crash
            value = json.loads(bundle.read_file(self.path(*parts), MAX_FILE).decode("utf-8"))
        except (OSError, ValueError, RecursionError):
            return default
        return value if isinstance(value, dict) else default

    def write_json(self, value, *parts):
        os.makedirs(os.path.dirname(self.path(*parts)), 0o700, exist_ok=True)
        apply._write_json(self.path(*parts), value, 0o600)

    def write_bytes(self, data, *parts):
        target = self.path(*parts)
        os.makedirs(os.path.dirname(target), 0o700, exist_ok=True)
        temporary = "%s.%d.tmp" % (target, os.getpid())
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        try:
            view = memoryview(data)
            while view:
                view = view[os.write(fd, view):]
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, target)

    def read_bytes(self, *parts):
        return bundle.read_file(self.path(*parts), MAX_FILE)

    # ---- floors and config --------------------------------------------------------------------------------------

    def floors(self):
        return self.read_json("floors.json", default={})

    def raise_floors(self, **values):
        """Persist floors, never lowering one (a lower value from the caller is ignored)."""
        floors = self.floors()
        for name, value in values.items():
            current = floors.get(name, 0)
            floors[name] = max(value, current if type(current) is int else 0)
        self.write_json(floors, "floors.json")

    def config(self):
        """{channel, install_id, hermes_version?}; creates install_id on first use."""
        config = self.read_json("config.json", default={})
        changed = False
        if not (isinstance(config.get("channel"), str) and verify.CHANNEL.fullmatch(config["channel"])):
            config["channel"], changed = DEFAULT_CHANNEL, True
        install_id = config.get("install_id")
        if not (isinstance(install_id, str) and 0 < len(install_id) <= 256):
            config["install_id"], changed = secrets.token_hex(16), True
        if changed:
            self.write_json(config, "config.json")
        return config

    def consumer(self, updater_version):
        """The box consumer for verification: `updater` always, `hermes` only when known (unknown → components with a
        Hermes range are skipped, SCHEMAS.md §8)."""
        versions = {"updater": updater_version}
        hermes = self.config().get("hermes_version")
        if isinstance(hermes, str) and verify.VERSION.fullmatch(hermes):
            versions["hermes"] = hermes
        return {"platform": "box", "versions": versions}

    # ---- profiles -----------------------------------------------------------------------------------------------

    def profiles(self):
        """[{name, coding_order, skills}] from profiles.json, or None when there is none (callers discover)."""
        doc = self.read_json("profiles.json")
        return None if doc is None else check_profiles(doc)

    # ---- stored bundle and blobs --------------------------------------------------------------------------------

    def latest(self):
        """(meta, keys, index, manifest bytes) of the latest verified bundle, or None."""
        meta = self.read_json("latest.json")
        digest = meta.get("manifest_sha256") if meta is not None else None
        if meta is None or type(meta.get("bundle_version")) is not int or meta["bundle_version"] < 1 \
                or not (isinstance(digest, str) and verify.HEX64.fullmatch(digest)):
            return None
        folder = ("bundles", str(meta["bundle_version"]))
        try:
            return meta, self.read_bytes(*folder, "keys.json"), self.read_bytes(*folder, "index.json"), \
                self.read_bytes(*folder, "manifest.json")
        except OSError:
            return None

    def store_bundle(self, meta, keys, index, manifest):
        version = str(meta["bundle_version"])
        for name, data in (("keys.json", keys), ("index.json", index), ("manifest.json", manifest)):
            self.write_bytes(data, "bundles", version, name)
        self.write_json(meta, "latest.json")
        for name in os.listdir(self.path("bundles")):
            if name != version:
                shutil.rmtree(self.path("bundles", name), ignore_errors=True)

    def refresh_bundle(self, version, keys=None, index=None):
        """Replace the stored bundle's key manifest and/or index with newer verified ones."""
        for name, data in (("keys.json", keys), ("index.json", index)):
            if data is not None:
                self.write_bytes(data, "bundles", str(version), name)

    def put_blob(self, data):
        digest = hashlib.sha256(data).hexdigest()
        if not os.path.exists(self.path("blobs", "sha256", digest)):
            self.write_bytes(data, "blobs", "sha256", digest)
        return digest

    def blob(self, digest):
        """The stored blob with this SHA-256, or None when missing or altered."""
        if not (isinstance(digest, str) and verify.HEX64.fullmatch(digest)):
            return None
        try:
            data = self.read_bytes("blobs", "sha256", digest)
        except OSError:
            return None
        return data if hashlib.sha256(data).hexdigest() == digest else None

    def prune_blobs(self, keep):
        folder = self.path("blobs", "sha256")
        for name in os.listdir(folder) if os.path.isdir(folder) else []:
            if name not in keep:
                os.unlink(os.path.join(folder, name))

    # ---- applied record and status ------------------------------------------------------------------------------

    def applied(self):
        record = self.read_json("applied.json", default={})
        components = record.get("components")
        record["components"] = {name: value for name, value in components.items() if isinstance(value, dict)} \
            if isinstance(components, dict) else {}
        for key in ("bundle_version", "confirmed_version"):
            if type(record.get(key)) is not int:
                record.pop(key, None)
        if not isinstance(record.get("confirmed_manifest_sha256"), str):
            record.pop("confirmed_manifest_sha256", None)
        if record.get("pin") is not None and not isinstance(record["pin"], dict):
            record["pin"] = {"mode": "unreadable"}  # an unreadable pin still holds: never apply on a guess
        return record

    def save_applied(self, record):
        self.write_json(record, "applied.json")

    def status(self):
        return self.read_json("status.json")

    def save_status(self, status):
        status["schema"] = STATUS_SCHEMA
        self.write_json(status, "status.json")


def check_profiles(doc):
    """Validate a swarmhub/profiles/1 document; returns the profile list. Raises ValueError."""
    if not isinstance(doc, dict) or doc.get("schema") != PROFILES_SCHEMA or not isinstance(doc.get("profiles"), list):
        raise ValueError("profiles.json is not %s" % PROFILES_SCHEMA)
    result, seen = [], set()
    for entry in doc["profiles"]:
        if not isinstance(entry, dict) or not render.is_valid_profile_name(entry.get("name")):
            raise ValueError("profiles.json: bad profile name")
        if entry["name"] in seen:
            raise ValueError("profiles.json: %s listed twice" % entry["name"])
        if entry.get("coding_order", render.STANDARD_ORDER) not in render.CODING_ORDERS:
            raise ValueError("profiles.json: unknown coding order for %s" % entry["name"])
        skills = entry.get("skills")
        if skills is not None and not (isinstance(skills, list)
                                       and all(render.is_valid_profile_name(s) for s in skills)):
            raise ValueError("profiles.json: skills of %s must be a list of names or null" % entry["name"])
        seen.add(entry["name"])
        result.append({"name": entry["name"], "coding_order": entry.get("coding_order", render.STANDARD_ORDER),
                       "skills": None if skills is None else sorted(set(skills))})
    return result
