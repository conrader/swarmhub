#!/usr/bin/env python3
"""File evidence for code-job. Report contents are never copied into the journal."""
import hashlib
from pathlib import Path
import sys


def fingerprint(path):
    if not path.is_file() or path.stat().st_size == 0:
        return "missing-or-empty"
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


if __name__ == "__main__":
    command, report, job = sys.argv[1:]
    try:
        path, folder = Path(report), Path(job)
        value = fingerprint(path)
        if command == "baseline":
            (folder / "report-before").write_text(value)
        elif command == "verify":
            passed = value != "missing-or-empty" and value != (folder / "report-before").read_text()
            (folder / "report-valid").write_text("true" if passed else "false")
            (folder / "report-sha256").write_text(value)
            sys.exit(0 if passed else 65)
        else:
            sys.exit(64)
    except OSError:
        sys.exit(65)
