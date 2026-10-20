"""Shared fixtures for the P2b CLI tests (test_cli.py, test_floors.py): TEST-key releases signed into staged folders
with the update service's layout, an admin-style pin file, and `run()` around cli.main. Timestamps are far in the
future so the fixtures never expire on the real clock. TEST keys only (fixed public seeds, SCHEMAS.md §11).
Not a test module itself."""

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from apply_fixtures import (CODING, MANAGER, MESSAGES, PROFILES, ROOT, BoxCase, apply, box_snapshot,  # noqa: E402,F401
                            changed, render, stage)



def _release_module(name):
    """Load a scripts/release helper (signing, JCS, ustar) without putting it on sys.path or in sys.modules, so the
    updater's own tests keep proving they never use the reference implementation (test_verify.py)."""
    path = str(ROOT / "scripts/release" / (name + ".py"))
    spec = importlib.util.spec_from_file_location("_p2b_fixture_" + name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ed25519_ref, ref_jcs, ustar = (_release_module(n) for n in ("ed25519_ref", "jcs", "ustar"))
SIG_CONTEXT = b"swarmhub-signature/1\n"
SEED_LABEL = "swarmhub-release-vectors/TEST-seed/"  # as scripts/release/vector_world.py (SCHEMAS.md §11)
ROOT_1, ROOT_2 = "TEST-root-1", "TEST-root-2"


def seed(key_id):
    return hashlib.sha256((SEED_LABEL + key_id).encode("utf-8")).digest()


def public_hex(key_id):
    return ed25519_ref.public_key(seed(key_id)).hex()


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


from swarmhub_update import cli, state as statefile  # noqa: E402

FEEDBACK = "swarmhub-feedback"
PROMPTS = "manager-prompts"
RELEASE, RELEASE_2 = "TEST-release-1", "TEST-release-2"
NOW = "2026-10-20T12:00:00Z"
FAR = "2099-01-01T00:00:00Z"
REQUIRES = {"updater": ">=1.0"}
PROFILES_DOC = {"schema": "swarmhub/profiles/1", "profiles": [
    {"name": p.name, "coding_order": p.coding_order, "skills": None if p.skills is None else list(p.skills)}
    for p in PROFILES]}


def _entries(files):
    """ustar entries for {path: (bytes, mode)} with every parent folder listed, in path order."""
    entries, folders = [], set()
    for path in sorted(files):
        parts = path.split("/")
        for depth in range(1, len(parts)):
            folder = "/".join(parts[:depth])
            if folder not in folders:
                folders.add(folder)
                entries.append({"name": folder + "/", "type": "dir", "mode": 0o755})
        data, mode = files[path]
        entries.append({"name": path, "type": "file", "mode": mode, "data": data})
    return entries


def component(kind, name, version, files, deps=None, cls=None):
    """(manifest component, blob). Class is derived the way the verifier re-derives it."""
    blob = ustar.build(_entries(files))
    if cls is None:
        data_ext = {"skill": {".md"}, "config": {".json", ".md", ".txt"}, "ui": {".json"}}.get(kind, set())
        code = kind == "tool" or any(mode == 0o755 or os.path.splitext(p)[1] not in data_ext
                                     for p, (_, mode) in files.items())
        cls = "code" if code else "data"
    return ({"kind": kind, "class": cls, "name": name, "version": version, "targets": ["box"],
             "sha256": sha256_hex(blob), "size": len(blob), "path": name, "requires": {},
             "requires_component": list(deps or [])}, blob)


def _read_tree(folder, to=""):
    files = {}
    for directory, _, names in os.walk(folder):
        for name in names:
            full = os.path.join(directory, name)
            rel = os.path.relpath(full, folder).replace(os.sep, "/")
            mode = 0o755 if rel.startswith("scripts/") else 0o644
            files[(to + "/" + rel) if to else rel] = (Path(full).read_bytes(), mode)
    return files


def source_components(source_folder, prompts_version="1.0.0", deps=None):
    """Components for a write_source() folder, laid out as scripts/release/bundle_layout.json does: one skill per
    folder (the manager skill with the recipes as references/), plus `manager-prompts` from BotManager/."""
    deps = deps or {}
    folder = Path(source_folder)
    result = []
    for skill_dir in sorted((folder / "Skills").iterdir()):
        files = _read_tree(skill_dir)
        if skill_dir.name == MANAGER:
            files.update(_read_tree(folder / "BotManager/recipes", "references"))
        version = render.parse_version(render.frontmatter(files["SKILL.md"][0].decode())["version"])
        extra = [{"name": PROMPTS, "min_version": prompts_version}] if skill_dir.name == MANAGER else []
        result.append(component("skill", skill_dir.name, version, files, extra + deps.get(skill_dir.name, [])))
    result.append(component("config", PROMPTS, prompts_version, _read_tree(folder / "BotManager"),
                            deps.get(PROMPTS)))
    return result


def signed(body, signer):
    message = SIG_CONTEXT + ref_jcs.canonical(body)
    return ref_jcs.canonical({"signed": body, "signatures": [
        {"key_id": signer, "sig": ed25519_ref.sign(seed(signer), message).hex()}]})


def key_manifest(version=2, keys=(RELEASE, RELEASE_2), not_after=FAR, root=ROOT_1):
    return signed({"schema": "swarmhub/keys/1", "version": version, "issued": "2026-10-01T00:00:00Z",
                   "keys": [{"key_id": k, "ed25519_pub": public_hex(k), "roles": ["bundle", "index"],
                             "not_after": not_after} for k in keys]}, root)


def manifest(version, components, signer=RELEASE):
    return signed({"schema": "swarmhub/bundle/1", "version": version, "label": "2026.10.%d" % version,
                   "created": "2026-10-18T09:00:00Z", "code_bearing": any(c["class"] == "code" for c in components),
                   "requires": dict(REQUIRES), "components": components}, signer)


def index(lines, seq, signer=RELEASE, expires=FAR, channel="stable"):
    return signed({"schema": "swarmhub/index/1", "channel": channel, "seq": seq, "issued": "2026-10-19T00:00:00Z",
                   "expires": expires, "lines": lines}, signer)


def line(manifest_bytes, version, percent=100):
    return {"requires": dict(REQUIRES), "bundle_version": version, "manifest_sha256": sha256_hex(manifest_bytes),
            "rollout_percent": percent}


class CliCase(BoxCase):
    """A BoxCase plus a pin file and a staging area for signed TEST releases."""

    def setUp(self):
        super().setUp()
        self.prefix = self.tmp / "updater"
        self.prefix.mkdir()
        self.pins_path = self.prefix / "pins.json"
        self.write_pins()
        self.staged_count = 0

    def write_pins(self, checkpoint=None, revoked=None, **extra):
        doc = {"schema": "swarmhub/pins/1", "threshold": 1,
               "roots": [{"key_id": k, "ed25519_pub": public_hex(k)} for k in (ROOT_1, ROOT_2)]}
        if checkpoint is not None:
            doc["checkpoint"] = checkpoint
        if revoked is not None:
            doc["revoked_key_ids"] = revoked
        doc.update(extra)
        self.pins_path.write_bytes(ref_jcs.canonical(doc))

    def stage(self, version, components, seq=5, keys_version=2, signer=RELEASE, expires=FAR, profiles=PROFILES_DOC,
              extra_lines=(), keys=None, percent=100, omit=()):
        """A staged folder for bundle `version` ([(component, blob)]); returns its path."""
        self.staged_count += 1
        folder = self.tmp / ("staged-%d" % self.staged_count)
        (folder / "channels").mkdir(parents=True)
        (folder / "bundles").mkdir()
        (folder / "blobs/sha256").mkdir(parents=True)
        (folder / "keys.json").write_bytes(keys if keys is not None else key_manifest(keys_version))
        raw = manifest(version, [c for c, _ in components], signer)
        if "manifest" not in omit:
            (folder / "bundles" / ("%d.json" % version)).write_bytes(raw)
        lines = [line(raw, version, percent)] + list(extra_lines)
        (folder / "channels/stable.json").write_bytes(index(lines, seq, signer, expires))
        if "blobs" not in omit:
            for comp, blob in components:
                (folder / "blobs/sha256" / comp["sha256"]).write_bytes(blob)
        if profiles is not None:
            (folder / "profiles.json").write_text(json.dumps(profiles))
        return folder

    def update(self, *argv, now=NOW):
        out = io.StringIO()
        code = cli.main(["--state-dir", str(self.state), "--hermes-home", str(self.hermes), "--max-wait", "0"]
                        + list(argv), str(self.pins_path), now=now, out=out)
        return code, json.loads(out.getvalue())

    def status(self):
        return statefile.State(str(self.state)).status()

    def floors(self):
        return statefile.State(str(self.state)).floors()

    def wipe_state(self):
        shutil.rmtree(str(self.state))

    def release(self, tag, version="1.0.0", deps=None, prompts_version="1.0.0", **kwargs):
        """(write_source result, components) for a source tree tagged `tag`."""
        source = self.source(tag, version=version, **kwargs)
        return source, source_components(self.sources / tag, prompts_version, deps)

    def live_version(self, skill, profile="default"):
        text = (self.live(skill, profile) / "SKILL.md").read_text()
        return render.parse_version(render.frontmatter(text)["version"])


__all__ = ["CODING", "MANAGER", "MESSAGES", "FEEDBACK", "PROMPTS", "PROFILES", "ROOT", "RELEASE", "RELEASE_2",
           "NOW", "FAR", "CliCase", "component", "source_components", "key_manifest", "manifest", "index", "line",
           "box_snapshot", "changed", "apply", "cli", "render", "stage", "statefile"]
