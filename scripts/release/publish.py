#!/usr/bin/env python3
"""Publish a built bundle to a local directory laid out as the update service (CORE-PHASES.md P1a; SCHEMAS.md §1).

    python3 scripts/release/publish.py --repo DIR --pins PINS --build BUILD --version N --signer file:K \\
        --channel stable --issued TS --expires TS [--seq S] [--rollout 100] [--line-requires JSON] \\
        [--replace-lines] [--production]

The directory holds `keys.json` (root-signed, from `keys.py sign-keys`), `bundles/<N>.json`, `blobs/sha256/<h>`
and `channels/<channel>.json`. Publishing signs with the release key only: the signer must be a key the verified
key manifest lists with roles `bundle` and `index`, valid at `--issued`, and never a pinned root. The roots are
needed only to sign the key manifest. P1c adds object-store and mirror backends; this is the local one.

Order and immutability: everything is checked, signed and verified with the P0b library first; then blobs are
written, then the manifest, then the index (atomic replace). A blob or manifest that exists with other bytes is
never overwritten, and nothing is written when any check fails. The new index line replaces the line with the same
`requires` (one line per compatibility group) unless `--replace-lines` drops them all.
"""

import argparse
import hashlib
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import build_bundle  # noqa: E402
import jcs  # noqa: E402
import sign  # noqa: E402
from sign import p0b, p0b_ed25519  # noqa: E402

ZERO_FLOORS = {"keys_version": 0, "index_seq": 0, "bundle_version": 0}


class PublishError(Exception):
    pass


def _reject(error):
    return PublishError(f"P0b verifier refused {error.stage}: {error.reason}")


# Reading the published directory ---------------------------------------------------------------------------------

def load_trust(repo, pins_bytes, *, production=False):
    """(pins, {key_id: release key}, key manifest body) from PINS and repo/keys.json, verified with P0b."""
    limits = dict(p0b.DEFAULT_LIMITS)
    try:
        pins = p0b.verify_pins(pins_bytes, limits)
        keys_bytes = (Path(repo) / "keys.json").read_bytes()
        release_keys = p0b.verify_keys(keys_bytes, pins, ZERO_FLOORS, limits)
    except p0b.Reject as error:
        raise _reject(error) from error
    except OSError as error:
        raise PublishError(f"no key manifest in {repo}: {error}") from error
    if production:
        test_ids = [r["key_id"] for r in pins["roots"] if sign.is_test_key_id(r["key_id"])]
        test_ids += [k for k in release_keys if sign.is_test_key_id(k)]
        if test_ids:
            raise PublishError(f"production mode refuses TEST keys in the pins or key manifest: {test_ids}")
    return pins, release_keys, jcs.loads(keys_bytes)["signed"]


def check_release_signer(signer, pins, release_keys, issued):
    roots = {root["key_id"] for root in pins["roots"]}
    roots_pub = {root["ed25519_pub"] for root in pins["roots"]}
    public = sign.public_hex(signer)
    if signer.key_id in roots or public in roots_pub:
        raise PublishError(f"{signer.key_id} is a root key; publishing uses the release key, never a root")
    key = release_keys.get(signer.key_id)
    if key is None:
        raise PublishError(f"{signer.key_id} is not in the key manifest")
    if key["ed25519_pub"] != public:
        raise PublishError(f"{signer.key_id}: the signer's public key differs from the key manifest's")
    missing = {"bundle", "index"} - set(key["roles"])
    if missing:
        raise PublishError(f"{signer.key_id} lacks role(s) {sorted(missing)}")
    if issued >= key["not_after"]:
        raise PublishError(f"{signer.key_id} expired at {key['not_after']}")


def published_versions(repo):
    return sorted(int(p.stem) for p in (Path(repo) / "bundles").glob("*.json") if p.stem.isdigit())


def read_index(repo, channel):
    path = Path(repo) / "channels" / f"{channel}.json"
    if not path.exists():
        return None
    try:
        doc = jcs.loads(path.read_bytes())
        p0b.check_envelope(doc, "index")
        p0b.check_index(doc["signed"])
    except (jcs.JCSError, p0b.Reject) as error:
        raise PublishError(f"{path} is not a valid index; fix it before publishing") from error
    return doc["signed"]


def load_build(build_dir, version):
    """(body, {name: blob}) from a build_bundle.py output directory; every blob must match its digest."""
    build_dir = Path(build_dir)
    try:
        body = jcs.loads((build_dir / f"bundle-{version}.unsigned.json").read_bytes())
        blobs = {c["name"]: (build_dir / "blobs/sha256" / c["sha256"]).read_bytes() for c in body["components"]}
    except (OSError, jcs.JCSError, KeyError, TypeError) as error:
        raise PublishError(f"cannot read build {build_dir} for bundle {version}: {error}") from error
    return body, blobs


# Signing and P0b self-check --------------------------------------------------------------------------------------

def _check_signed_by(raw, stage, release_keys, role, now):
    """Schema and release-key signature of a signed file, with the P0b library's own checks."""
    limits = dict(p0b.DEFAULT_LIMITS)
    try:
        doc = p0b.parse_signed(raw, stage, limits)
        p0b.check_envelope(doc, stage)
        (p0b.check_bundle if stage == "manifest" else p0b.check_index)(doc["signed"])
    except p0b.Reject as error:
        raise _reject(error) from error
    entry = doc["signatures"][0]
    key = release_keys.get(entry["key_id"])
    if key is None or role not in key["roles"] or now >= key["not_after"] or not p0b_ed25519.verify(
            bytes.fromhex(key["ed25519_pub"]), p0b.signing_message(doc["signed"]), bytes.fromhex(entry["sig"])):
        raise PublishError(f"{stage} signature by {entry['key_id']} does not verify for role {role}")
    return doc["signed"]


def verify_blobs(body, blobs):
    """P0b blob checks (size, hash, archive rules, content class) for every component."""
    limits = dict(p0b.DEFAULT_LIMITS)
    for component in body["components"]:
        try:
            p0b.check_declared_size(component, limits)
            p0b.verify_blob(component, blobs.get(component["name"]), limits)
        except p0b.Reject as error:
            raise PublishError(f"component {component['name']}: P0b verifier refused {error.reason}") from error


def next_index(old, channel, line, *, seq, issued, expires, replace_lines):
    lines = [] if old is None or replace_lines else [
        dict(item) for item in old["lines"] if jcs.canonical(item["requires"]) != jcs.canonical(line["requires"])]
    lines.append(line)
    lines.sort(key=lambda item: item["bundle_version"])
    old_seq = old["seq"] if old else 0
    seq = old_seq + 1 if seq is None else seq
    if seq <= old_seq:
        raise PublishError(f"index seq {seq} must be above the published {old_seq}")
    return {"schema": "swarmhub/index/1", "channel": channel, "seq": seq, "issued": issued, "expires": expires,
            "lines": lines}


# Writing ---------------------------------------------------------------------------------------------------------

def check_immutable(path, data):
    """True when path must be written, False when it already holds data; PublishError when it holds other bytes."""
    if path.is_symlink():
        raise PublishError(f"{path} is a symlink")
    if not path.exists():
        return True
    if path.read_bytes() != data:
        raise PublishError(f"{path} already exists with other bytes; published objects are never overwritten")
    return False


def write_immutable(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, 0o644)
        os.link(temp, path)  # fails if path appeared meanwhile: never overwrite
    finally:
        os.unlink(temp)


def write_replace(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=".tmp-")
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, 0o644)
        os.replace(temp, path)
    except BaseException:
        if os.path.exists(temp):
            os.unlink(temp)
        raise


def publish_body(repo, body, blobs, *, signer, pins_bytes, channel, issued, expires, seq=None, rollout_percent=100,
                 line_requires=None, replace_lines=False, production=False):
    """Sign body with the release signer and publish it with its blobs. Returns the written relative paths."""
    repo = Path(repo)
    pins, release_keys, _ = load_trust(repo, pins_bytes, production=production)
    check_release_signer(signer, pins, release_keys, issued)
    try:
        p0b.check_bundle(body)
    except p0b.Reject as error:
        raise _reject(error) from error
    version = body["version"]
    manifest_raw = sign.envelope(body, [signer])
    manifest_path = repo / "bundles" / f"{version}.json"
    existing = published_versions(repo)
    if existing and version <= existing[-1]:
        raise PublishError(f"bundle {version} is not above the published {existing[-1]}; versions only increase")
    _check_signed_by(manifest_raw, "manifest", release_keys, "bundle", issued)
    verify_blobs(body, blobs)
    line = {"requires": dict(body["requires"] if line_requires is None else line_requires), "bundle_version": version,
            "manifest_sha256": hashlib.sha256(manifest_raw).hexdigest(), "rollout_percent": rollout_percent}
    index = next_index(read_index(repo, channel), channel, line, seq=seq, issued=issued, expires=expires,
                       replace_lines=replace_lines)
    index_raw = sign.envelope(index, [signer])
    _check_signed_by(index_raw, "index", release_keys, "index", issued)
    try:
        p0b.verify_index(index_raw, release_keys, channel=channel, now=issued, floors=ZERO_FLOORS, revoked=(),
                         limits=dict(p0b.DEFAULT_LIMITS))
    except p0b.Reject as error:
        raise _reject(error) from error
    blob_writes = []
    for component in body["components"]:
        path = repo / "blobs/sha256" / component["sha256"]
        if check_immutable(path, blobs[component["name"]]) and path not in [p for p, _ in blob_writes]:
            blob_writes.append((path, blobs[component["name"]]))
    write_manifest = check_immutable(manifest_path, manifest_raw)
    written = []
    for path, data in blob_writes:  # 1. blobs
        write_immutable(path, data)
        written.append(path)
    if write_manifest:  # 2. manifest
        write_immutable(manifest_path, manifest_raw)
        written.append(manifest_path)
    index_path = repo / "channels" / f"{channel}.json"
    write_replace(index_path, index_raw)  # 3. index, last
    written.append(index_path)
    return [str(p.relative_to(repo)) for p in written]


def common_arguments(parser):
    parser.add_argument("--repo", type=Path, required=True, help="published directory (holds keys.json)")
    parser.add_argument("--pins", type=Path, required=True, help="pin file with the root public keys")
    parser.add_argument("--signer", required=True, help="release key signer, e.g. file:TEST-release-1.key.json")
    parser.add_argument("--channel", required=True)
    parser.add_argument("--issued", required=True, help="YYYY-MM-DDTHH:MM:SSZ")
    parser.add_argument("--expires", required=True, help="YYYY-MM-DDTHH:MM:SSZ (plan default: issued + 7 days)")
    parser.add_argument("--seq", type=int, help="index seq (default: published seq + 1)")
    parser.add_argument("--rollout", type=int, default=100, help="rollout_percent of the new line")
    parser.add_argument("--line-requires", type=json.loads, help="requires map of the line (default: the bundle's)")
    parser.add_argument("--replace-lines", action="store_true", help="drop every other line of the index")
    parser.add_argument("--production", action="store_true", help="refuse TEST- keys and test-only signers")


def options(args):
    return {"pins_bytes": args.pins.read_bytes(), "channel": args.channel, "issued": args.issued,
            "expires": args.expires, "seq": args.seq, "rollout_percent": args.rollout,
            "line_requires": args.line_requires, "replace_lines": args.replace_lines, "production": args.production}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    common_arguments(parser)
    parser.add_argument("--build", type=Path, required=True, help="build_bundle.py output directory")
    parser.add_argument("--version", type=int, required=True)
    args = parser.parse_args(argv)
    try:
        signer = sign.load_signer(args.signer, args.production)
        body, blobs = load_build(args.build, args.version)
        written = publish_body(args.repo, body, blobs, signer=signer, **options(args))
    except (PublishError, sign.SignerError, build_bundle.BuildError, jcs.JCSError, OSError) as error:
        print(f"publish: {error}", file=sys.stderr)
        return 1
    for rel in written:
        print(f"  wrote {rel}")
    print(f"published bundle {body['version']} on {args.channel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
