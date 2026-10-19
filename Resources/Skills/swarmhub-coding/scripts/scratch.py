#!/usr/bin/env python3
"""Conservative cleanup of code-job scratch left after an untrappable launcher exit."""
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import time


def sweep(root, now=None):
    cutoff = (time.time() if now is None else now) - 86400
    for entry in Path(root).iterdir():
        # New names atomically record the shell PID at mktemp, with no marker-write crash window.
        # Legacy names have no owner PID: age alone cannot prove they are unused.
        match = re.fullmatch(r"code-job\.([1-9][0-9]{0,9})\.[A-Za-z0-9]{6}", entry.name)
        if not match:
            continue
        pid = int(match[1])
        if pid <= 1 or pid > 2147483647:
            continue
        try:
            info = entry.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mtime >= cutoff:
                continue
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                shutil.rmtree(entry)
            # A live or reused PID, EPERM, or any uncertain filesystem state retains the directory.
        except OSError:
            continue


if __name__ == "__main__":
    try:
        sweep(sys.argv[1])
    except OSError:
        sys.exit(1)
