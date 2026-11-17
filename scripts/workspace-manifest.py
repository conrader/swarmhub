#!/usr/bin/env python3
"""Describe a workspace server release: what `swarmhub-herdr` checks before it replaces itself.

  workspace-manifest.py asset PROGRAM
      On the machine that built PROGRAM: asks it what it is and writes PROGRAM.asset.json
      (its kind of machine, name, size and SHA-256).

  workspace-manifest.py asset PROGRAM --target ARCH-OS --like NATIVE_PROGRAM
      For a PROGRAM the build machine may not be able to run (the Intel program built on an Apple silicon Mac):
      NATIVE_PROGRAM, the same build for this machine, is asked instead, and PROGRAM's own header must say it is
      for ARCH-OS. Where PROGRAM does run (Rosetta), it is asked too and must say the same.

  workspace-manifest.py manifest --tag vX.Y.Z --notes TEXT --out FILE FRAGMENT.asset.json...
      Anywhere: joins the fragments of one version into the manifest of a release. The file is then signed with
      the release key (scripts/release.sh); the signature is over exactly its bytes, so it is never edited after.
"""
import argparse
import errno
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


def report(program):
    """What a program says it is. Only a program this machine can run answers."""
    return json.loads(subprocess.run([str(program), "version", "--json"], check=True, capture_output=True, text=True, timeout=30).stdout)


def built_for(data):
    """The kind of machine a program file is for, read from its header (64-bit Mach-O or ELF); None for anything else."""
    if data[:4] == b"\xcf\xfa\xed\xfe":
        arch = {0x01000007: "x86_64", 0x0100000C: "aarch64"}.get(int.from_bytes(data[4:8], "little"))
        return arch and arch + "-macos"
    if data[:6] == b"\x7fELF\x02\x01":
        arch = {0x3E: "x86_64", 0xB7: "aarch64"}.get(int.from_bytes(data[18:20], "little"))
        return arch and arch + "-linux"
    return None


def describe(program, target=None, like=None):
    """The fragment for one built program, from what the program itself reports.

    With `like`, the report is that of the same build for this machine, and the fragment names `target` instead:
    the program's header must be for `target`, and when the program does run here its own report must agree.
    """
    said = report(like or program)
    if not VERSION.fullmatch(said["version"]):
        raise ValueError(f"{like or program} reports version {said['version']!r}; a release is X.Y.Z")
    data = program.read_bytes()
    if like:
        if target == said["target"] or target.rpartition("-")[2] != said["target"].rpartition("-")[2]:
            raise ValueError(f"{like} is for {said['target']}; --like takes the same build for another kind of machine with the same system as {target}")
        if built_for(data) != target:
            raise ValueError(f"{program} is not a program for {target}")
        said = {**said, "target": target}
        try:
            own = report(program)
        except OSError as error:
            # "Exec format error", or macOS's "Bad CPU type in executable": this machine cannot run it.
            if error.errno not in (errno.ENOEXEC, getattr(errno, "EBADARCH", errno.ENOEXEC)):
                raise
            print(f"{program.name} cannot run on this machine; described from {like.name}.", file=sys.stderr)
        else:
            for key in ("version", "api", "api_min", "target"):
                if own[key] != said[key]:
                    raise ValueError(f"{program} reports {key} {own[key]!r}, and {like} makes it {said[key]!r}")
            print(f"{program.name} runs on this machine and reports what {like.name} does.", file=sys.stderr)
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
    asset.add_argument("--target", help="With --like: the kind of machine PROGRAM is for, e.g. x86_64-macos")
    asset.add_argument("--like", type=Path, help="With --target: the same build for this machine, asked in PROGRAM's place")
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
            if bool(args.target) != bool(args.like):
                raise ValueError("--target and --like go together")
            out = args.program.with_name(args.program.name + ".asset.json")
            out.write_text(json.dumps(describe(args.program, args.target, args.like), indent=2) + "\n")
        else:
            fragments = [json.loads(path.read_text()) for path in args.fragments]
            out = args.out
            out.write_text(json.dumps(join(fragments, args.tag, args.notes, args.released, args.base), indent=2) + "\n")
        print(out)
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as error:
        parser.exit(1, f"ERROR: {error}\n")


if __name__ == "__main__":
    main(sys.argv[1:])
