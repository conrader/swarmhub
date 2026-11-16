"""Offline entrypoint for the SwarmHub Grok Bot export helper."""

import argparse
import os
from pathlib import Path

from export_grokbot import DEFAULT_CACHE, DEFAULT_OUT, export


def main():
    parser = argparse.ArgumentParser(description="Export recent Grok Bot messages from this Mac. This tool uses no network or sign-in.")
    parser.add_argument("--cache", type=Path, default=Path(DEFAULT_CACHE).expanduser())
    parser.add_argument("--out", type=Path, help="new folder for the local export (defaults to Documents)")
    args = parser.parse_args()
    output = args.out.expanduser() if args.out is not None else Path(DEFAULT_OUT).expanduser()
    if args.out is None:
        base = output
        for number in range(2, 1000):
            if not os.path.lexists(output):
                break
            output = base.with_name(f"{base.name} ({number})")
    if os.path.lexists(output):
        parser.error("choose a new export folder with --out; the existing folder was not changed")
    result = export(args.cache.expanduser(), str(output), replace_existing=False)
    bots = result["bots"]
    print(f"Exported {len(bots)} conversations and {sum(bot['messages'] for bot in bots)} messages.")
    print(f"In SwarmHub, choose Import from Grok Bot and select: {output}")


if __name__ == "__main__":
    main()
