#!/usr/bin/env python3
"""Key manifests, pins and TEST key files (CORE-PLAN.md §2.1, decision 1; SCHEMAS.md §4, §5; CORE-PHASES.md P1a).

    keys.py test-key TEST-release-1 --out FILE        TEST key file from the public fixed seed (TEST- ids only)
    keys.py pins --threshold 1 --root ID,PUBHEX ... --out pins.json
    keys.py new --version V --issued TS --key ID,PUBHEX,bundle+index,NOT_AFTER ... --out keys.unsigned.json
    keys.py sign-keys --in FILE --pins pins.json --signer file:ROOT [--signer ...] --out keys.json
                      [--previous keys.json] [--partial] [--production]

`sign-keys` signs a key manifest with root keys only: each signer must be a pinned root, and the result is
verified with the P0b library against the pins (1 of 2 roots in plan B). `--in` may be an unsigned body or an
already signed manifest, so a second root can add its signature later, elsewhere; below the pin threshold the
output is refused unless `--partial`. With `--previous`, the new `version` must be higher.

TEST seeds are public (`sha256("swarmhub-release-vectors/TEST-seed/" + key_id)`, the P0a fixture rule); a key file
made by `test-key` is for tests and local dry runs only, and every signer refuses it in production mode.
"""

import argparse
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import jcs  # noqa: E402
import sign  # noqa: E402
import vector_world  # noqa: E402
from sign import p0b  # noqa: E402

ZERO_FLOORS = {"keys_version": 0, "index_seq": 0, "bundle_version": 0}


class KeysError(Exception):
    pass


def test_key_document(key_id):
    if not sign.is_test_key_id(key_id) or not p0b.KEY_ID.fullmatch(key_id):
        raise KeysError(f"test-key makes TEST- keys only, not {key_id!r}")
    return {"schema": sign.KEY_FILE_SCHEMA, "key_id": key_id, "seed": vector_world.seed(key_id).hex(),
            "note": "TEST key from a public fixed seed. Never trust it; production signers refuse it."}


def pins_document(threshold, roots):
    pins = {"schema": "swarmhub/pins/1", "threshold": threshold,
            "roots": [{"key_id": key_id, "ed25519_pub": public} for key_id, public in roots]}
    try:
        p0b.check_pins(pins)
    except p0b.Reject as error:
        raise KeysError("bad pins: threshold must be 1..roots, ids and public keys well formed") from error
    return pins


def key_manifest(version, issued, keys):
    """keys: [(key_id, ed25519_pub hex, roles list, not_after)]."""
    body = {"schema": "swarmhub/keys/1", "version": version, "issued": issued,
            "keys": [{"key_id": k, "ed25519_pub": pub, "roles": list(roles), "not_after": not_after}
                     for k, pub, roles, not_after in keys]}
    try:
        p0b.check_key_manifest(body)
    except p0b.Reject as error:
        raise KeysError("bad key manifest: check ids, public keys, roles (bundle, index) and timestamps") from error
    return body


def sign_keys(source_bytes, pins_bytes, signers, *, previous_bytes=None, partial=False, production=False):
    """Signed key manifest bytes. Signers must be pinned roots; the result must meet the pin threshold."""
    limits = dict(p0b.DEFAULT_LIMITS)
    try:
        pins = p0b.verify_pins(pins_bytes, limits)
    except p0b.Reject as error:
        raise KeysError("pin file does not verify") from error
    roots = {root["key_id"]: root["ed25519_pub"] for root in pins["roots"]}
    for signer in signers:
        if roots.get(signer.key_id) != sign.public_hex(signer):
            raise KeysError(f"{signer.key_id} is not a pinned root; key manifests are signed by roots only")
    doc = jcs.loads(source_bytes)
    is_envelope = isinstance(doc, dict) and set(doc) == {"signed", "signatures"}
    body = doc["signed"] if is_envelope else doc
    try:
        p0b.check_key_manifest(body)
    except p0b.Reject as error:
        raise KeysError("input is not a valid swarmhub/keys/1 body") from error
    if production:
        test_ids = [k["key_id"] for k in body["keys"] if sign.is_test_key_id(k["key_id"])]
        test_ids += [k for k in roots if sign.is_test_key_id(k)]
        if test_ids:
            raise KeysError(f"production mode refuses TEST keys: {test_ids}")
    if previous_bytes is not None:
        previous = jcs.loads(previous_bytes)
        old_version = previous["signed"]["version"] if "signed" in previous else previous["version"]
        if body["version"] <= old_version:
            raise KeysError(f"key manifest version {body['version']} must be above the previous {old_version}")
    try:
        out = sign.add_signatures(source_bytes, signers) if is_envelope else sign.envelope(body, signers)
    except sign.SignerError as error:
        raise KeysError(str(error)) from error
    count = len(jcs.loads(out)["signatures"])
    if count < pins["threshold"]:
        if not partial:
            raise KeysError(f"{count} root signature(s), the pins need {pins['threshold']}; use --partial to "
                            f"write it for the next root")
        return out
    try:
        p0b.verify_keys(out, pins, ZERO_FLOORS, limits)
    except p0b.Reject as error:
        raise KeysError(f"P0b verifier refused the key manifest: {error.reason}") from error
    return out


def _key_arg(text):
    parts = text.split(",")
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("--key is ID,PUBHEX,ROLES,NOT_AFTER with ROLES like bundle+index")
    return parts[0], parts[1], parts[2].split("+"), parts[3]


def _root_arg(text):
    parts = text.split(",")
    if len(parts) != 2:
        raise argparse.ArgumentTypeError("--root is ID,PUBHEX")
    return tuple(parts)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    test_key = commands.add_parser("test-key", help="write a TEST key file from its public fixed seed")
    test_key.add_argument("key_id")
    test_key.add_argument("--out", type=Path, required=True)
    pins = commands.add_parser("pins", help="write a pin file")
    pins.add_argument("--threshold", type=int, required=True)
    pins.add_argument("--root", type=_root_arg, action="append", required=True)
    pins.add_argument("--out", type=Path, required=True)
    new = commands.add_parser("new", help="write an unsigned key manifest body")
    new.add_argument("--version", type=int, required=True)
    new.add_argument("--issued", required=True)
    new.add_argument("--key", type=_key_arg, action="append", required=True)
    new.add_argument("--out", type=Path, required=True)
    signk = commands.add_parser("sign-keys", help="sign a key manifest with root keys")
    signk.add_argument("--in", dest="source", type=Path, required=True)
    signk.add_argument("--pins", type=Path, required=True)
    signk.add_argument("--signer", action="append", required=True)
    signk.add_argument("--out", type=Path, required=True)
    signk.add_argument("--previous", type=Path)
    signk.add_argument("--partial", action="store_true")
    signk.add_argument("--production", action="store_true")
    args = parser.parse_args(argv)
    try:
        if args.command == "test-key":
            data = (json.dumps(test_key_document(args.key_id), indent=2) + "\n").encode("utf-8")
        elif args.command == "pins":
            data = jcs.canonical(pins_document(args.threshold, args.root))
        elif args.command == "new":
            data = jcs.canonical(key_manifest(args.version, args.issued, args.key))
        else:
            signers = [sign.load_signer(spec, args.production) for spec in args.signer]
            data = sign_keys(args.source.read_bytes(), args.pins.read_bytes(), signers,
                             previous_bytes=args.previous.read_bytes() if args.previous else None,
                             partial=args.partial, production=args.production)
    except (KeysError, sign.SignerError, jcs.JCSError, OSError) as error:
        print(f"keys {args.command}: {error}", file=sys.stderr)
        return 1
    args.out.write_bytes(data)
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
