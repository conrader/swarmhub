"""Read the previously published feeds when preparing or verifying an update."""
import argparse
import re
import xml.etree.ElementTree as ET
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.request import urlopen


def read(url, *, allow_missing=False):
    try:
        with urlopen(url, timeout=30) as response:
            return response.read()
    except HTTPError as error:
        if error.code == 404 and allow_missing:
            return None
        raise


def workspace(feed, *, allow_missing=False):
    url = feed.rstrip("/") + "/workspace-manifest.json"
    manifest = read(url, allow_missing=allow_missing)
    if manifest is None:
        return None
    signature = read(url + ".sig")
    if not manifest.strip() or not signature.strip():
        raise ValueError("The published workspace manifest or signature is empty.")
    return manifest, signature


def previous_build(feed):
    appcast = read(feed.rstrip("/") + "/appcast.xml", allow_missing=True)
    if appcast is None:
        return None
    item = ET.fromstring(appcast).find("./channel/item")
    build = item.findtext("{http://www.andymatuschak.org/xml-namespaces/sparkle}version") if item is not None else None
    if not build or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", build):
        raise ValueError("The previous appcast has no readable build number.")
    return build


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    actions.add_parser("previous-build").add_argument("feed")
    carry = actions.add_parser("carry-workspace")
    carry.add_argument("feed")
    carry.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.action == "previous-build":
        print(previous_build(args.feed) or "")
        return
    pair = workspace(args.feed, allow_missing=True)
    if pair is None:
        print("The previous release has no workspace manifest (HTTP 404).")
        pair = b"", b""
    else:
        print("Carrying over the published workspace manifest and signature.")
    args.output.write_bytes(pair[0])
    args.output.with_name(args.output.name + ".sig").write_bytes(pair[1])


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, ET.ParseError) as error:
        sys.exit(f"Could not read the published release feed: {error}")
