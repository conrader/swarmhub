#!/usr/bin/env python3
"""Channel tooling: promotion and percent rollout (CORE-PLAN.md §2.1, §2.2; CORE-PHASES.md P8a).

    python3 scripts/release/channels.py promote canary beta --repo DIR --pins PINS --signer file:K \\
        --issued TS --expires TS [--version N] [--rollout P] [--seq S] [--production]
    python3 scripts/release/channels.py rollout canary --version N --percent P --repo DIR --pins PINS \\
        --signer file:K --issued TS --expires TS [--seq S] [--production]

`promote FROM TO` copies FROM's index line(s) for bundle N (default: FROM's highest bundle) into TO's index, one
step along canary -> beta -> stable. The line keeps its `manifest_sha256`, so TO's consumers fetch exactly the bytes
FROM's consumers verified. Only TO's index is signed and written: nothing under `bundles/` or `blobs/` is built,
signed or written. Before signing, the bundle is checked as consumers will check it: the manifest's raw SHA-256
against the line, its signature by a current `bundle` key, and every blob (size, hash, archive rules, class).
`--rollout` sets the copied line's `rollout_percent` (default: as in FROM).

`rollout CHANNEL` re-signs CHANNEL's index with a new `rollout_percent` on bundle N's line(s) and a higher `seq`.
Raising the percent only adds installs: the bucket is `hash(install_id, bundle_version) mod 100` (SCHEMAS.md §6).

Both sign with the release key only (as publish.py) and replace the index atomically, last.
"""

import argparse
import hashlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import jcs  # noqa: E402
import publish  # noqa: E402
import sign  # noqa: E402
from sign import p0b  # noqa: E402

ORDER = ("canary", "beta", "stable")


def _signed_index(repo, channel, release_keys, now):
    """(raw bytes, body) of CHANNEL's index, signed by a current `index` key and not expired at `now`."""
    path = Path(repo) / "channels" / f"{channel}.json"
    if path.is_symlink() or not path.is_file():
        raise publish.PublishError(f"channel {channel} has no index in {repo}")
    raw = path.read_bytes()
    body = publish._check_signed_by(raw, "index", release_keys, "index", now)
    if body["channel"] != channel:
        raise publish.PublishError(f"{path} is the index of {body['channel']!r}, not {channel!r}")
    if now >= body["expires"]:
        raise publish.PublishError(f"index of {channel} expired at {body['expires']}; renew it before using it")
    return raw, body


def _lines_for(index, version, channel):
    if version is None:
        if not index["lines"]:
            raise publish.PublishError(f"index of {channel} has no lines")
        version = max(line["bundle_version"] for line in index["lines"])
    lines = [dict(line) for line in index["lines"] if line["bundle_version"] == version]
    if not lines:
        raise publish.PublishError(f"index of {channel} has no line for bundle {version}")
    return version, lines


def check_published_bundle(repo, line, release_keys, now):
    """The manifest and blobs the line names, checked as a consumer checks them. Returns the manifest body."""
    repo = Path(repo)
    path = repo / "bundles" / f"{line['bundle_version']}.json"
    if path.is_symlink() or not path.is_file():
        raise publish.PublishError(f"bundle {line['bundle_version']} is not published in {repo}")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != line["manifest_sha256"]:
        raise publish.PublishError(f"{path} does not match the line's manifest_sha256")
    body = publish._check_signed_by(raw, "manifest", release_keys, "bundle", now)
    if body["version"] != line["bundle_version"]:
        raise publish.PublishError(f"{path} holds bundle {body['version']}")
    blobs = {}
    for component in body["components"]:
        blob = repo / "blobs/sha256" / component["sha256"]
        if blob.is_symlink() or not blob.is_file():
            raise publish.PublishError(f"blob of {component['name']} is missing from {repo}")
        blobs[component["name"]] = blob.read_bytes()
    publish.verify_blobs(body, blobs)
    return body


def _sign_and_replace(repo, channel, index, signer, release_keys, issued):
    raw = sign.envelope(index, [signer])
    publish._check_signed_by(raw, "index", release_keys, "index", issued)
    try:
        p0b.verify_index(raw, release_keys, channel=channel, now=issued, floors=publish.ZERO_FLOORS, revoked=(),
                         limits=dict(p0b.DEFAULT_LIMITS))
    except p0b.Reject as error:
        raise publish._reject(error) from error
    path = Path(repo) / "channels" / f"{channel}.json"
    publish.write_replace(path, raw)
    return [str(path.relative_to(repo))]


def _next_seq(old, seq):
    old_seq = old["seq"] if old else 0
    seq = old_seq + 1 if seq is None else seq
    if seq <= old_seq:
        raise publish.PublishError(f"index seq {seq} must be above the published {old_seq}")
    return seq


def _check_percent(percent):
    if percent is not None and (isinstance(percent, bool) or not isinstance(percent, int) or not 0 <= percent <= 100):
        raise publish.PublishError(f"rollout percent must be an integer 0-100, not {percent!r}")


def promote(repo, source, target, *, signer, pins_bytes, issued, expires, version=None, rollout_percent=None,
            seq=None, production=False):
    """Copy SOURCE's line(s) for bundle `version` into TARGET's index. Returns the written relative paths."""
    if source not in ORDER or target not in ORDER or ORDER.index(target) != ORDER.index(source) + 1:
        raise publish.PublishError(f"promotion goes one step along {' -> '.join(ORDER)}, not {source} -> {target}")
    _check_percent(rollout_percent)
    pins, release_keys, _ = publish.load_trust(repo, pins_bytes, production=production)
    publish.check_release_signer(signer, pins, release_keys, issued)
    _, source_index = _signed_index(repo, source, release_keys, issued)
    version, lines = _lines_for(source_index, version, source)
    for line in lines:
        check_published_bundle(repo, line, release_keys, issued)
    old = publish.read_index(repo, target)
    kept = []
    for item in (old["lines"] if old else []):
        same = [line for line in lines if jcs.canonical(line["requires"]) == jcs.canonical(item["requires"])]
        if not same:
            kept.append(dict(item))
            continue
        if item["bundle_version"] > version:
            raise publish.PublishError(f"{target} already serves bundle {item['bundle_version']} on that line; "
                                       f"going back is `republish`, not a promotion")
        if item["bundle_version"] == version and item["manifest_sha256"] != same[0]["manifest_sha256"]:
            raise publish.PublishError(f"{target} serves another manifest as bundle {version}")
    copied = [dict(line, **({} if rollout_percent is None else {"rollout_percent": rollout_percent}))
              for line in lines]
    index = {"schema": "swarmhub/index/1", "channel": target, "seq": _next_seq(old, seq), "issued": issued,
             "expires": expires, "lines": sorted(kept + copied, key=lambda item: item["bundle_version"])}
    return _sign_and_replace(repo, target, index, signer, release_keys, issued)


def rollout(repo, channel, version, percent, *, signer, pins_bytes, issued, expires, seq=None, production=False):
    """Re-sign CHANNEL's index with bundle `version`'s line(s) at `percent`. Returns the written relative paths."""
    _check_percent(percent)
    pins, release_keys, _ = publish.load_trust(repo, pins_bytes, production=production)
    publish.check_release_signer(signer, pins, release_keys, issued)
    old = publish.read_index(repo, channel)
    if old is None:
        raise publish.PublishError(f"channel {channel} has no index in {repo}")
    if not any(line["bundle_version"] == version for line in old["lines"]):
        raise publish.PublishError(f"index of {channel} has no line for bundle {version}")
    lines = [dict(line, **({"rollout_percent": percent} if line["bundle_version"] == version else {}))
             for line in old["lines"]]
    index = {"schema": "swarmhub/index/1", "channel": channel, "seq": _next_seq(old, seq), "issued": issued,
             "expires": expires, "lines": lines}
    return _sign_and_replace(repo, channel, index, signer, release_keys, issued)


def _common(parser):
    parser.add_argument("--repo", type=Path, required=True, help="published directory (holds keys.json)")
    parser.add_argument("--pins", type=Path, required=True, help="pin file with the root public keys")
    parser.add_argument("--signer", required=True, help="release key signer, e.g. file:TEST-release-1.key.json")
    parser.add_argument("--issued", required=True, help="YYYY-MM-DDTHH:MM:SSZ")
    parser.add_argument("--expires", required=True, help="YYYY-MM-DDTHH:MM:SSZ (plan default: issued + 7 days)")
    parser.add_argument("--seq", type=int, help="index seq (default: published seq + 1)")
    parser.add_argument("--production", action="store_true", help="refuse TEST- keys and test-only signers")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    up = commands.add_parser("promote", help="copy a channel's line one step along canary -> beta -> stable")
    up.add_argument("source", choices=ORDER)
    up.add_argument("target", choices=ORDER)
    up.add_argument("--version", type=int, help="bundle to promote (default: the source's highest)")
    up.add_argument("--rollout", type=int, help="rollout_percent on the target (default: as in the source)")
    _common(up)
    pct = commands.add_parser("rollout", help="change the rollout percent of a bundle's line")
    pct.add_argument("channel", choices=ORDER)
    pct.add_argument("--version", type=int, required=True)
    pct.add_argument("--percent", type=int, required=True)
    _common(pct)
    args = parser.parse_args(argv)
    try:
        signer = sign.load_signer(args.signer, args.production)
        common = {"signer": signer, "pins_bytes": args.pins.read_bytes(), "issued": args.issued,
                  "expires": args.expires, "seq": args.seq, "production": args.production}
        if args.command == "promote":
            written = promote(args.repo, args.source, args.target, version=args.version,
                              rollout_percent=args.rollout, **common)
            done = f"promoted {args.source} -> {args.target}"
        else:
            written = rollout(args.repo, args.channel, args.version, args.percent, **common)
            done = f"bundle {args.version} on {args.channel} at {args.percent}%"
    except (publish.PublishError, sign.SignerError, jcs.JCSError, OSError) as error:
        print(f"channels: {error}", file=sys.stderr)
        return 1
    for rel in written:
        print(f"  wrote {rel}")
    print(done)
    return 0


if __name__ == "__main__":
    sys.exit(main())
