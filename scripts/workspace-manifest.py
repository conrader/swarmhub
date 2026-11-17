#!/usr/bin/env python3
"""Describe a workspace server release: what `swarmhub-herdr` checks before it replaces itself.

  workspace-manifest.py asset PROGRAM
      On the machine that built PROGRAM: asks it what it is and writes PROGRAM.asset.json
      (its kind of machine, name, size and SHA-256).

  workspace-manifest.py manifest --tag vX.Y.Z --notes TEXT --out FILE FRAGMENT.asset.json...
      Anywhere: joins the fragments of one version into the manifest of a release. The file is then signed with
      the release key (scripts/release.sh); the signature is over exactly its bytes, so it is never edited after.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

PRODUCT = "swarmhub-herdr"
RELEASES = "https://github.com/conrader/swarmhub/releases/download/"
VERSION = re.compile(r"[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}")
NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}")


def describe(program):
    """The fragment for one built program, from what the program itself reports."""
    said = json.loads(subprocess.run([str(program), "version", "--json"], check=True, capture_output=True, text=True, timeout=30).stdout)
    if not VERSION.fullmatch(said["version"]):
        raise ValueError(f"{program} reports version {said['version']!r}; a release is X.Y.Z")
    data = program.read_bytes()
    return {"product": PRODUCT, "version": said["version"], "api": said["api"], "api_min": said["api_min"],
            "asset": {"target": said["target"], "name": program.name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}}


def join(fragments, tag, notes, released, base=None):
    """One manifest from the fragments of one version, one per kind of machine."""
    if not fragments:
        raise ValueError("a manifest needs at least one program")
    first = fragments[0]
    for fragment in fragments:
        if fragment.get("product") != PRODUCT or any(fragment[key] != first[key] for key in ("version", "api", "api_min")):
            raise ValueError("the programs are not builds of one version")
        if not NAME.fullmatch(fragment["asset"]["name"]) or not re.fullmatch(r"[0-9a-f]{64}", fragment["asset"]["sha256"]):
            raise ValueError(f"{fragment['asset']['name']!r} is not a plain file name with a SHA-256")
    targets = [fragment["asset"]["target"] for fragment in fragments]
    if len(set(targets)) != len(targets):
        raise ValueError("two programs are for the same kind of machine")
    if not re.fullmatch(r"v" + VERSION.pattern, tag):
        raise ValueError("the tag is v<version> of the release the programs are uploaded to")
    base = base or f"{RELEASES}{tag}/"
    if not base.endswith("/"):
        raise ValueError("the base address ends with /")
    return {"product": PRODUCT, "version": first["version"], "api": first["api"], "api_min": first["api_min"],
            "released": released, "notes": notes.strip(), "base": base,
            "assets": sorted((fragment["asset"] for fragment in fragments), key=lambda asset: asset["target"])}


def main(arguments):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    asset = commands.add_parser("asset")
    asset.add_argument("program", type=Path)
    manifest = commands.add_parser("manifest")
    manifest.add_argument("--tag", required=True)
    manifest.add_argument("--notes", required=True, help="One or two plain sentences on what changed for the person")
    manifest.add_argument("--released", required=True, help="The date, YYYY-MM-DD")
    manifest.add_argument("--base", help="Where the programs are served from (default: the tag's release)")
    manifest.add_argument("--out", type=Path, required=True)
    manifest.add_argument("fragments", type=Path, nargs="+")
    args = parser.parse_args(arguments)
    try:
        if args.command == "asset":
            out = args.program.with_name(args.program.name + ".asset.json")
            out.write_text(json.dumps(describe(args.program), indent=2) + "\n")
        else:
            fragments = [json.loads(path.read_text()) for path in args.fragments]
            out = args.out
            out.write_text(json.dumps(join(fragments, args.tag, args.notes, args.released, args.base), indent=2) + "\n")
        print(out)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        parser.exit(1, f"ERROR: {error}\n")


if __name__ == "__main__":
    main(sys.argv[1:])
