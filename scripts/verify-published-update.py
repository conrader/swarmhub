#!/usr/bin/env python3
"""Check the public Sparkle update against the version being released and the previously installed app's trust key."""
import argparse
import hashlib
import json
import re
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile

from release_feed import workspace

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def verify_workspace(feed, key, expected_manifest):
    manifest, signature = workspace(feed)
    if manifest != expected_manifest.read_bytes():
        raise ValueError("The public workspace manifest differs from the one staged for this release.")
    with tempfile.TemporaryDirectory(prefix="swarmhub-manifest-") as scratch:
        signed = Path(scratch) / "workspace-manifest.json"
        signed.write_bytes(manifest)
        subprocess.run(["xcrun", "swift", ROOT / "scripts/release-signature.swift", "verify",
                        signed, signature.decode("ascii").strip(), key], check=True)
    release = json.loads(manifest)
    base = release["base"]
    if not re.fullmatch(r"https://github\.com/conrader/swarmhub/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/", base):
        raise ValueError("The workspace programs must come from a tagged SwarmHub release.")
    for asset in release["assets"]:
        name = asset["name"]
        if not re.fullmatch(r"[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}", name):
            raise ValueError(f"Invalid workspace program name: {name!r}")
        digest = hashlib.sha256()
        size = 0
        with urlopen(base + name, timeout=60) as response:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                size += len(block)
                digest.update(block)
        if size != asset["size"] or digest.hexdigest() != asset["sha256"]:
            raise ValueError(f"The downloaded workspace program differs from the signed manifest: {name}")
        print(f"Verified workspace {release['version']} for {asset['target']}")


def verify(installed_plist, expected_plist, workspace_manifest=None):
    trusted = plistlib.loads(installed_plist.read_bytes())
    expected = plistlib.loads(expected_plist.read_bytes())
    version, build = expected["CFBundleShortVersionString"], expected["CFBundleVersion"]
    with urlopen(trusted["SUFeedURL"], timeout=30) as feed:
        item = ET.parse(feed).find("./channel/item")
    if item is None or (item.findtext(SPARKLE + "shortVersionString"), item.findtext(SPARKLE + "version")) != (version, build):
        raise ValueError(f"The public feed does not offer {version} (build {build}) as its newest update.")
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise ValueError("The published update has no archive.")
    with tempfile.TemporaryDirectory(prefix="swarmhub-published-") as scratch:
        archive = Path(scratch) / "update.zip"
        with urlopen(enclosure.attrib["url"], timeout=60) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
        if archive.stat().st_size != int(enclosure.attrib["length"]):
            raise ValueError("The archive size differs from the public feed.")
        subprocess.run(["xcrun", "swift", ROOT / "scripts/release-signature.swift", "verify", archive,
                        enclosure.attrib[SPARKLE + "edSignature"], trusted["SUPublicEDKey"]], check=True)
        with ZipFile(archive) as bundle:
            info = plistlib.loads(bundle.read("SwarmHub.app/Contents/Info.plist"))
        for field in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            if info.get(field) != expected[field]:
                raise ValueError(f"The signed archive has an unexpected {field}.")
    if workspace_manifest:
        verify_workspace(trusted["SUFeedURL"].rsplit("/", 1)[0], trusted["SUPublicEDKey"], workspace_manifest)
    print(f"Public update verified: SwarmHub {version} (build {build})")
    print(enclosure.attrib["url"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installed_plist", type=Path, help="Info.plist of the Mac app that should receive the update")
    parser.add_argument("--workspace-manifest", type=Path, help="Signed workspace-manifest.json staged for publication")
    args = parser.parse_args()
    verify(args.installed_plist, ROOT / "Resources/Info.plist", args.workspace_manifest)
