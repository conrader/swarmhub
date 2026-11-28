"""Command-line inputs and journal polling shared by isolated effectiveness studies."""
import argparse
from pathlib import Path
import time


def wait_reply(db, key, after, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        row = db.execute(
            "SELECT r.id,r.text FROM journal r JOIN journal t ON r.reply_for=t.launch_key "
            "WHERE r.kind='reply' AND t.address=? AND t.created_ms=? AND r.id>? ORDER BY r.id LIMIT 1",
            (*key, after)).fetchone()
        if row:
            return row
        time.sleep(.5)
    return after, ""


def existing_path(value):
    return Path(value).resolve(strict=True)


def study_parser(description, timeout):
    parser = argparse.ArgumentParser(description=description)
    for name in ("bridge", "core", "codex", "auth"):
        parser.add_argument("--" + name, type=existing_path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--model", required=True)
    parser.add_argument("--bridge-version", default="0.2.45")
    parser.add_argument("--timeout", type=int, default=timeout)
    parser.add_argument("--seeds", type=int, nargs="+", required=True)
    return parser
