#!/usr/bin/env python3
"""Check the public Sparkle update against the version being released and the previously installed app's trust key."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def verify(installed_plist, expected_plist):
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
    print(f"Public update verified: SwarmHub {version} (build {build})")
    print(enclosure.attrib["url"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("installed_plist", type=Path, help="Info.plist of the Mac app that should receive the update")
    args = parser.parse_args()
    verify(args.installed_plist, ROOT / "Resources/Info.plist")
