#!/usr/bin/env python3
"""Roll forward: publish an old bundle's content as a new, higher version (CORE-PLAN.md §2.2; CORE-PHASES.md P1a).

    python3 scripts/release/republish.py OLD as NEW --repo DIR --pins PINS --signer file:K --channel stable \\
        --issued TS --expires TS --created TS [--label L] [publish options]

To undo bundle N, republish N-1 as N+1. The new manifest is N-1's signed body with only `version`, `label` and
`created` changed: the same components, so the same blobs, byte for byte, and nothing is rebuilt. NEW must be
above every published version, so anti-rollback never has to tell a legitimate downgrade from an attack.

Before anything is signed, OLD is verified with the P0b library: its signature by a key the current key manifest
lists with role `bundle` (the key may since have passed `not_after`; a key dropped from the manifest is not
trusted), and every blob in the directory (size, hash, archive rules, content class). Publishing then goes through
publish.py, with the release key only.
"""

import argparse
import copy
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import jcs  # noqa: E402
import publish  # noqa: E402
import sign  # noqa: E402
from sign import p0b, p0b_ed25519  # noqa: E402


def load_old(repo, old, release_keys):
    """(body, {name: blob}) of published bundle OLD, verified."""
    repo = Path(repo)
    path = repo / "bundles" / f"{old}.json"
    try:
        raw = path.read_bytes()
        doc = p0b.parse_signed(raw, "manifest", dict(p0b.DEFAULT_LIMITS))
        p0b.check_envelope(doc, "manifest")
        p0b.check_bundle(doc["signed"])
    except OSError as error:
        raise publish.PublishError(f"bundle {old} is not published in {repo}") from error
    except p0b.Reject as error:
        raise publish._reject(error) from error
    body, entry = doc["signed"], doc["signatures"][0]
    key = release_keys.get(entry["key_id"])
    if body["version"] != old:
        raise publish.PublishError(f"{path} holds bundle {body['version']}, not {old}")
    if key is None or "bundle" not in key["roles"] or not p0b_ed25519.verify(
            bytes.fromhex(key["ed25519_pub"]), p0b.signing_message(body), bytes.fromhex(entry["sig"])):
        raise publish.PublishError(f"bundle {old} is not signed by a bundle key of the current key manifest")
    blobs = {}
    for component in body["components"]:
        blob_path = repo / "blobs/sha256" / component["sha256"]
        if blob_path.is_symlink() or not blob_path.is_file():
            raise publish.PublishError(f"blob of {component['name']} is missing from {repo}")
        blobs[component["name"]] = blob_path.read_bytes()
    publish.verify_blobs(body, blobs)
    return body, blobs


def republish(repo, old, new, *, signer, pins_bytes, created, label=None, production=False, **options):
    """Publish OLD's content as NEW. Returns the written relative paths (blobs are already there, so none)."""
    pins, release_keys, _ = publish.load_trust(repo, pins_bytes, production=production)
    publish.check_release_signer(signer, pins, release_keys, options["issued"])
    body, blobs = load_old(repo, old, release_keys)
    versions = publish.published_versions(repo)
    if new <= versions[-1]:
        raise publish.PublishError(f"new version {new} must be above every published version (highest {versions[-1]})")
    fresh = copy.deepcopy(body)
    fresh.update(version=new, created=created, label=label or f"{body['label']} (republish of {old})")
    return publish.publish_body(repo, fresh, blobs, signer=signer, pins_bytes=pins_bytes, production=production,
                                **options)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("old", type=int)
    parser.add_argument("word", choices=["as"], metavar="as")
    parser.add_argument("new", type=int)
    publish.common_arguments(parser)
    parser.add_argument("--created", required=True, help="YYYY-MM-DDTHH:MM:SSZ of the new manifest")
    parser.add_argument("--label", help="display label (default: '<old label> (republish of OLD)')")
    args = parser.parse_args(argv)
    try:
        signer = sign.load_signer(args.signer, args.production)
        written = republish(args.repo, args.old, args.new, signer=signer, created=args.created, label=args.label,
                            **publish.options(args))
    except (publish.PublishError, sign.SignerError, jcs.JCSError, OSError) as error:
        print(f"republish: {error}", file=sys.stderr)
        return 1
    for rel in written:
        print(f"  wrote {rel}")
    print(f"republished bundle {args.old} as {args.new} on {args.channel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
