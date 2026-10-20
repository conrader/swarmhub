#!/usr/bin/env python3
"""Check the baseline and bootstrap package embedded in an app build (CORE-PHASES.md P2c). Stdlib only, Linux-runnable.

    check_baseline.py --configuration debug|release [--ios] [--without-baseline] RESOURCES

RESOURCES is the app's resource folder (`Contents/Resources`, `AgentApp.resources`, the iOS `.app`). Exit 0 when
every check passes, 1 with one line per problem otherwise. Both configurations check:

- `Baseline/` verifies with the P0b library: pin file, root-signed key manifest, each channel index, every line's
  bundle manifest (raw SHA-256, release-key signature, requires against the packaged updater) and every blob (size,
  hash, archive rules, content class; with `--ios`, only components that target `ios` and no other blob). Signatures are checked as of the index's `issued` time: expiry is the
  consumer's run-time question, not the build's.
- The highest bundle has exactly the components this checkout builds (`build_bundle.py`): a stale baseline fails.
- `Bootstrap/` (unless `--ios`, which instead requires it absent) holds exactly the package and its `.sha256`
  file; the digest matches the package bytes; the package is the one this checkout builds with `Baseline/pins.json`.

A release configuration also fails when any pinned root, any signature (key manifest, index, bundle) or any listed
release key uses a TEST key: a `key_id` starting with `TEST-` (any case), or a public key from the TEST fixture set
(`Tests/Fixtures/release-bundles/keys/TEST-keys.json`, or the public seed of the id with `TEST-` prepended).
`--without-baseline` (release only) passes only when neither folder is present.
"""

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import baseline  # noqa: E402
import build_bundle  # noqa: E402
import jcs  # noqa: E402
import sign  # noqa: E402
import vector_world  # noqa: E402
from sign import p0b  # noqa: E402

ZERO_FLOORS = {"keys_version": 0, "index_seq": 0, "bundle_version": 0}
TEST_KEYS_FILE = "Tests/Fixtures/release-bundles/keys/TEST-keys.json"
DIGEST_LINE = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9._-]+)\n")


class Problems(list):
    def add(self, text):
        self.append(text)


def _load(path):
    return jcs.loads(Path(path).read_bytes())


def test_public_keys(root):
    """Public keys of the TEST fixture set (hex)."""
    try:
        doc = json.loads((Path(root) / TEST_KEYS_FILE).read_text(encoding="utf-8"))
        return {entry["ed25519_pub"] for entry in doc["keys"]}
    except (OSError, ValueError, KeyError, TypeError):
        return set()


def is_test_key(key_id, public, test_publics):
    if sign.is_test_key_id(key_id) or public in test_publics:
        return True
    return public is not None and public == vector_world.public_hex("TEST-" + key_id)


def verify_baseline(folder, problems, test_findings, root=ROOT, ios=False):
    """P0b verification of Baseline/. Returns the highest bundle body, or None. test_findings collects (where, id, pub)."""
    limits = dict(p0b.DEFAULT_LIMITS)
    try:
        pins = p0b.verify_pins((folder / "pins.json").read_bytes(), limits)
        keys_raw = (folder / "keys.json").read_bytes()
        release_keys = p0b.verify_keys(keys_raw, pins, ZERO_FLOORS, limits)
    except (OSError, p0b.Reject) as error:
        problems.add(f"Baseline: pins or key manifest do not verify: {getattr(error, 'reason', error)}")
        return None
    roots = {r["key_id"]: r["ed25519_pub"] for r in pins["roots"]}
    test_findings += [("pinned root", k, pub) for k, pub in roots.items()]
    test_findings += [("key manifest signature", s["key_id"], roots.get(s["key_id"]))
                      for s in _load(folder / "keys.json")["signatures"]]
    test_findings += [("listed release key", k, v["ed25519_pub"]) for k, v in release_keys.items()]
    consumer = {"platform": "box", "versions": {"updater": baseline.updater_version(root)}}
    channels = sorted((folder / "channels").glob("*.json"))
    if not channels:
        problems.add("Baseline: no channel index")
    best = None
    for path in channels:
        try:
            raw = path.read_bytes()
            issued = _load(path)["signed"]["issued"]
            index = p0b.verify_index(raw, release_keys, channel=path.stem, now=issued, floors=ZERO_FLOORS,
                                     revoked=(), limits=limits)
        except (OSError, jcs.JCSError, KeyError, TypeError, p0b.Reject) as error:
            problems.add(f"Baseline: channel {path.stem} does not verify: {getattr(error, 'reason', error)}")
            continue
        signer = _load(path)["signatures"][0]["key_id"]
        test_findings.append((f"index {path.stem} signature", signer, release_keys[signer]["ed25519_pub"]))
        for line in index["lines"]:
            body = _verify_bundle(folder, line, release_keys, consumer, issued, limits, problems, test_findings, ios)
            if body is not None and (best is None or body["version"] > best["version"]):
                best = body
    return best


def _verify_bundle(folder, line, release_keys, consumer, now, limits, problems, test_findings, ios=False):
    version = line["bundle_version"]
    try:
        raw = (folder / "bundles" / f"{version}.json").read_bytes()
        body = p0b.verify_manifest(raw, line, release_keys, consumer=consumer, now=now, revoked=(), limits=limits)
        for component in body["components"]:
            if ios and "ios" not in component["targets"]:
                continue
            p0b.check_declared_size(component, limits)
            p0b.verify_blob(component, (folder / "blobs/sha256" / component["sha256"]).read_bytes(), limits)
    except (OSError, p0b.Reject) as error:
        problems.add(f"Baseline: bundle {version} does not verify: {getattr(error, 'reason', error)}")
        return None
    signer = _load(folder / "bundles" / f"{version}.json")["signatures"][0]["key_id"]
    test_findings.append((f"bundle {version} signature", signer, release_keys[signer]["ed25519_pub"]))
    return body


def check_current(body, root, problems):
    """The embedded bundle's components equal what this checkout builds (versions, classes, bytes, edges)."""
    try:
        fresh, _ = build_bundle.build(version=body["version"], label=body["label"], created=body["created"],
                                      previous=None, root=root)
    except build_bundle.BuildError as error:
        problems.add(f"Baseline: this checkout does not build: {error}")
        return
    want = {c["name"]: jcs.canonical(c) for c in fresh["components"]}
    have = {c["name"]: jcs.canonical(c) for c in body["components"]}
    for name in sorted(set(want) | set(have)):
        if want.get(name) != have.get(name):
            problems.add(f"Baseline: component {name} differs from this checkout (stale baseline)")
    if jcs.canonical(fresh["requires"]) != jcs.canonical(body["requires"]):
        problems.add("Baseline: bundle requires differ from this checkout's bundle_layout.json")


def check_bootstrap(folder, pins_bytes, root, problems):
    name = baseline.package_name(root)
    present = sorted(p.name for p in folder.iterdir()) if folder.is_dir() else []
    if present != [name, name + ".sha256"]:
        problems.add(f"Bootstrap: expected exactly {name} and {name}.sha256, found {present}")
        return
    package = (folder / name).read_bytes()
    match = DIGEST_LINE.fullmatch((folder / (name + ".sha256")).read_text(encoding="ascii", errors="replace"))
    if match is None or match.group(2) != name:
        problems.add(f"Bootstrap: {name}.sha256 is not '<sha256>  {name}'")
    elif match.group(1) != hashlib.sha256(package).hexdigest():
        problems.add(f"Bootstrap: {name}.sha256 does not match the package bytes")
    if pins_bytes is None or package != baseline.bootstrap_package(pins_bytes, root):
        problems.add(f"Bootstrap: {name} is not this checkout's updater with Baseline/pins.json")


def check(resources, configuration, *, ios=False, without_baseline=False, root=ROOT):
    """Problems (strings) with the embedded baseline and package in RESOURCES; empty when all checks pass."""
    resources, root, problems = Path(resources), Path(root), Problems()
    base, boot = resources / "Baseline", resources / "Bootstrap"
    if without_baseline:
        if configuration != "release":
            problems.add("--without-baseline is for release builds only")
        for part in (base, boot):
            if part.exists() or part.is_symlink():
                problems.add(f"{part.name}: present in a build made without a baseline")
        return problems
    if not base.is_dir() or base.is_symlink():
        problems.add("Baseline: missing")
        return problems
    findings = []
    body = verify_baseline(base, problems, findings, root, ios)
    if body is not None:
        check_current(body, root, problems)
    if not ios:
        pins = (base / "pins.json").read_bytes() if (base / "pins.json").is_file() else None
        check_bootstrap(boot, pins, root, problems)
    else:
        if boot.exists() or boot.is_symlink():
            problems.add("Bootstrap: present in an iOS build")
        if body is not None:
            wanted = {c["sha256"] for c in body["components"] if "ios" in c["targets"]}
            extra = sorted(p.name for p in (base / "blobs/sha256").iterdir() if p.name not in wanted)
            if extra:
                problems.add(f"Baseline: blobs no iOS component uses: {extra}")
    if configuration == "release":
        publics = test_public_keys(root)
        for where, key_id, public in findings:
            if is_test_key(key_id, public, publics):
                problems.add(f"release build: {where} {key_id} is a TEST key")
    return problems


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--configuration", required=True, choices=("debug", "release"))
    parser.add_argument("--ios", action="store_true", help="iOS build: no Bootstrap/, only blobs that target ios")
    parser.add_argument("--without-baseline", action="store_true", help="release only: both folders must be absent")
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("resources", type=Path)
    args = parser.parse_args(argv)
    problems = check(args.resources, args.configuration, ios=args.ios,
                     without_baseline=args.without_baseline, root=args.root)
    for problem in problems:
        print(f"check-baseline: {problem}", file=sys.stderr)
    if not problems:
        print(f"check-baseline: {args.resources} OK ({args.configuration})")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
