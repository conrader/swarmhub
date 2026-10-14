#!/usr/bin/env python3
"""Apply release overrides and validate Sparkle configuration before signing a bundle."""
import argparse
import base64
import os
from pathlib import Path
import plistlib
import re
from urllib.parse import urlsplit


def validate(info, require_key=True):
    feed = urlsplit(info.get("SUFeedURL", ""))
    if feed.scheme != "https" or not feed.hostname or feed.username or feed.password or feed.fragment:
        raise ValueError("SUFeedURL must be an HTTPS URL without credentials or a fragment")
    key = info.get("SUPublicEDKey", "")
    if key or require_key:
        try:
            decoded = base64.b64decode(key, validate=True)
        except (ValueError, TypeError) as error:
            raise ValueError("SUPublicEDKey must be a base64 Ed25519 public key") from error
        if len(decoded) != 32:
            raise ValueError("SUPublicEDKey is missing or invalid; run ./scripts/setup-updates.sh first")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", info.get("CFBundleVersion", "")):
        raise ValueError("CFBundleVersion must be an incrementing numeric build number")
    if info.get("SUVerifyUpdateBeforeExtraction") is not True:
        raise ValueError("SUVerifyUpdateBeforeExtraction must remain enabled")


def configure(path, environment, require_key=True):
    with path.open("rb") as file:
        info = plistlib.load(file)
    for variable, key in [("SWARMHUB_UPDATE_PUBLIC_KEY", "SUPublicEDKey"), ("SWARMHUB_UPDATE_FEED_URL", "SUFeedURL")]:
        if variable in environment:
            info[key] = environment[variable].strip()
    validate(info, require_key=require_key)
    with path.open("wb") as file:
        plistlib.dump(info, file, sort_keys=False)
    return info


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=Path)
    parser.add_argument("--allow-missing-key", action="store_true", help="For local development bundles only")
    args = parser.parse_args()
    try:
        configure(args.plist, os.environ, require_key=not args.allow_missing_key)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"ERROR: {error}\n")
