"""Building blocks for the release test vectors: fixed-seed TEST keys, signed envelopes, archives, base objects.

Everything is deterministic: seeds derive from key IDs, timestamps are constants, archives use ustar.build, and
signed files are the JCS bytes of their envelope. See docs/update-service/SCHEMAS.md.
"""

import copy
import hashlib

import ed25519_ref
import jcs
import ustar

SIG_CONTEXT = b"swarmhub-signature/1\n"
SEED_LABEL = "swarmhub-release-vectors/TEST-seed/"
NOW = "2026-10-20T12:00:00Z"
ROOT_1, ROOT_2 = "TEST-root-1", "TEST-root-2"
RELEASE, RELEASE_OLD, RELEASE_BUNDLE_ONLY, ROGUE = ("TEST-release-1", "TEST-release-old",
                                                     "TEST-release-bundle-only", "TEST-rogue")
ALL_KEYS = [ROOT_1, ROOT_2, RELEASE, RELEASE_OLD, RELEASE_BUNDLE_ONLY, ROGUE]
BASE_REQUIRES = {"updater": ">=1.0", "ui_catalog": ">=1.0"}
LIMITS = {"max_signed_bytes": 1048576, "max_blob_size": 67108864, "max_entries": 4096,
          "max_file_size": 8388608, "max_total_size": 67108864, "max_path_bytes": 255, "max_depth": 16}
BOX = {"platform": "box", "versions": {"updater": "1.0.0", "hermes": "0.21.7"}}
MAC = {"platform": "mac", "versions": {"app": "0.6.2", "ui_catalog": "1.3", "config_schema": "2"}}
FLOORS = {"keys_version": 1, "index_seq": 4, "bundle_version": 10}
INSTALL_ID = "TEST-install-0001"


def seed(key_id):
    return hashlib.sha256((SEED_LABEL + key_id).encode("utf-8")).digest()


def public_hex(key_id):
    return ed25519_ref.public_key(seed(key_id)).hex()


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def f(name, data, mode=0o644):
    return {"name": name, "type": "file", "mode": mode, "data": data}


class World:
    def __init__(self):
        self.files = {}
        self.cases = []

    def put(self, rel, data, replace=False):
        if rel in self.files and self.files[rel] != data and not replace:
            raise ValueError(f"conflicting content for {rel}")
        self.files[rel] = data
        return rel

    def signed_file(self, rel, signed, signers):
        """signers: key IDs, or (claimed key_id, seed owner) pairs for wrong-key vectors."""
        message = SIG_CONTEXT + jcs.canonical(signed)
        signatures = []
        for signer in signers:
            claimed, owner = signer if isinstance(signer, tuple) else (signer, signer)
            signatures.append({"key_id": claimed, "sig": ed25519_ref.sign(seed(owner), message).hex()})
        return self.put(rel, jcs.canonical({"signed": signed, "signatures": signatures}))

    def component(self, kind, cls, name, version, targets, entries=None, raw=None, requires=None, deps=None):
        data = raw if raw is not None else ustar.build(entries)
        digest = sha256_hex(data)
        self.put(f"blobs/sha256/{digest}", data)
        return {"kind": kind, "class": cls, "name": name, "version": version, "targets": targets,
                "sha256": digest, "size": len(data), "path": name, "requires": requires or {},
                "requires_component": deps or []}

    def base_components(self):
        skill_md = b"---\nname: %s\nversion: %s\n---\nTEST fixture skill. Not a real Swarm Hub skill.\n"
        return [
            self.component("skill", "data", "swarmhub-manager", "1.2.0", ["box"],
                           [f("SKILL.md", skill_md % (b"swarmhub-manager", b"1.2.0"))]),
            self.component("skill", "code", "swarmhub-feedback", "1.0.0", ["box"], self.feedback_entries()),
            self.component("tool", "code", "swarm-tools", "1.0.0", ["box"],
                           [f("swarmctl", b"#!/bin/sh\necho TEST swarmctl\n", 0o755),
                            f("swarm_policy.py", b"# TEST fixture tool module\nVERSION = 1\n")],
                           requires={"hermes": ">=0.21,<0.23"}),
            self.component("config", "data", "box-prompts", "1.0.0", ["box"],
                           [f("prompts/manager.md", b"TEST prompt that needs swarm-tools 1.0.0.\n")],
                           deps=[{"name": "swarm-tools", "min_version": "1.0.0"}]),
            self.component("config", "data", "policy", "2.0.0", ["box", "mac", "ios"],
                           [f("policy.json", b'{"coding_job_limit":2,"default_model":"TEST-model"}\n')]),
            self.component("ui", "data", "routine-card", "1.0.0", ["mac", "ios"],
                           [f("routine-card.json", b'{"type":"card","children":[{"type":"text","text":"TEST"}]}\n')]),
        ]

    @staticmethod
    def feedback_entries(script=b"#!/bin/sh\necho TEST swarmhub-report\n"):
        return [f("SKILL.md", b"---\nname: swarmhub-feedback\nversion: 1.0.0\n---\nTEST fixture skill.\n"),
                {"name": "scripts/", "type": "dir", "mode": 0o755},
                f("scripts/swarmhub-report", script, 0o755)]

    @staticmethod
    def bundle(version, components, requires=None, code_bearing=None):
        if code_bearing is None:
            code_bearing = any(c["class"] == "code" for c in components)
        return {"schema": "swarmhub/bundle/1", "version": version, "label": f"2026.10.{version}",
                "created": "2026-10-18T09:00:00Z", "code_bearing": code_bearing,
                "requires": copy.deepcopy(BASE_REQUIRES if requires is None else requires),
                "components": components}

    @staticmethod
    def index(lines, seq=5, channel="stable", issued="2026-10-19T00:00:00Z", expires="2026-10-26T00:00:00Z"):
        return {"schema": "swarmhub/index/1", "channel": channel, "seq": seq, "issued": issued,
                "expires": expires, "lines": lines}

    @staticmethod
    def line(manifest_bytes, version=11, requires=None, percent=100):
        return {"requires": copy.deepcopy(BASE_REQUIRES if requires is None else requires),
                "bundle_version": version, "manifest_sha256": sha256_hex(manifest_bytes),
                "rollout_percent": percent}

    def key_manifest(self, version=2):
        def key(key_id, roles, not_after):
            return {"key_id": key_id, "ed25519_pub": public_hex(key_id), "roles": roles, "not_after": not_after}
        return {"schema": "swarmhub/keys/1", "version": version, "issued": "2026-10-01T00:00:00Z",
                "keys": [key(RELEASE, ["bundle", "index"], "2027-01-01T00:00:00Z"),
                         key(RELEASE_OLD, ["bundle", "index"], "2026-10-15T00:00:00Z"),
                         key(RELEASE_BUNDLE_ONLY, ["bundle"], "2027-01-01T00:00:00Z")]}

    def build_base(self):
        """Write the shared valid objects and return the default case inputs."""
        self.put("keys/TEST-keys.json", jcs.canonical({
            "note": "TEST keys only. Seeds are public: sha256(seed_label + key_id). Never trust these keys.",
            "seed_label": SEED_LABEL,
            "keys": [{"key_id": k, "seed": seed(k).hex(), "ed25519_pub": public_hex(k)} for k in ALL_KEYS]}))
        self.put("keys/pins.json", self.pins(1))
        self.put("keys/pins--threshold-2.json", self.pins(2))
        self.signed_file("keys/keys-2.json", self.key_manifest(), [ROOT_1])
        self.components = self.base_components()
        manifest = self.files[self.signed_file("bundles/11.json", self.bundle(11, self.components), [RELEASE])]
        self.base_line = self.line(manifest)
        self.signed_file("channels/stable.json", self.index([self.base_line]), [RELEASE])
        return {"pins": "keys/pins.json", "keys": "keys/keys-2.json", "index": "channels/stable.json",
                "manifest": "bundles/11.json", "channel": "stable", "now": NOW, "floors": dict(FLOORS),
                "consumer": copy.deepcopy(BOX), "install_id": INSTALL_ID, "revoked_key_ids": [],
                "limits": dict(LIMITS)}

    @staticmethod
    def pins(threshold):
        return jcs.canonical({"schema": "swarmhub/pins/1", "threshold": threshold,
                              "roots": [{"key_id": k, "ed25519_pub": public_hex(k)} for k in (ROOT_1, ROOT_2)]})

    def variant(self, case_id, mutate, line_version=11, manifest_version=11, line_requires=None):
        """A re-signed bundle manifest built from fresh base components, plus an index pointing at it."""
        components = copy.deepcopy(self.components)
        signed = self.bundle(manifest_version, components)
        mutate(signed, components)
        rel = self.signed_file(f"bundles/{manifest_version}--{case_id}.json", signed, [RELEASE])
        line = self.line(self.files[rel], line_version, line_requires)
        index = self.signed_file(f"channels/stable--{case_id}.json", self.index([line]), [RELEASE])
        return {"manifest": rel, "index": index}

    def replace_component(self, components, name, **changes):
        for i, component in enumerate(components):
            if component["name"] == name:
                args = {k: component[k] for k in ("kind", "name", "version", "targets", "requires")}
                args.update(cls=component["class"], deps=component["requires_component"])
                if changes.get("entries") is None and changes.get("raw") is None:
                    changes["raw"] = self.files[f"blobs/sha256/{component['sha256']}"]
                args.update(changes)
                components[i] = self.component(**args)
                return components[i]
        raise KeyError(name)
