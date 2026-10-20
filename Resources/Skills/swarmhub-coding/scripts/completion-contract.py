#!/usr/bin/env python3
"""File evidence for code-job. Report contents are never copied into the journal."""
import errno
import hashlib
import os
import stat
import sys


def inspect(path):
    """(state, bytes, digest): state is ok, missing, empty, not-regular or unreadable-<ERRNO>.

    Explicit stat instead of Path.is_file(): Python 3.14 folds every stat error into False (a report it may not
    stat read as missing-or-empty), while 3.12 raises, so the record must not depend on the interpreter."""
    try:
        info = os.stat(path)
    except (FileNotFoundError, NotADirectoryError):
        return "missing", "-", None
    except OSError as error:
        return "unreadable-" + errno.errorcode.get(error.errno, str(error.errno)), "-", None
    if not stat.S_ISREG(info.st_mode):
        return "not-regular", "-", None
    if info.st_size == 0:
        return "empty", "0", None
    digest = hashlib.sha256()
    try:
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(65536), b""):
                digest.update(chunk)
    except OSError as error:
        return "unreadable-" + errno.errorcode.get(error.errno, str(error.errno)), str(info.st_size), None
    return "ok", str(info.st_size), digest.hexdigest()


def fingerprint(path):
    return inspect(path)[2] or "missing-or-empty"


if __name__ == "__main__":
    command, report, job = sys.argv[1:]
    try:
        folder = os.path.join(job, "")
        state, size, digest = inspect(report)
        value = digest or "missing-or-empty"
        if command == "baseline":
            with open(folder + "report-before", "w") as out:
                out.write(value)
        elif command == "verify":
            with open(folder + "report-before") as before:
                passed = value != "missing-or-empty" and value != before.read()
            for name, text in (("report-valid", "true" if passed else "false"), ("report-sha256", value),
                               ("report-state", state if state != "ok" or passed else "unchanged"),
                               ("report-bytes", size)):
                with open(folder + name, "w") as out:
                    out.write(text)
            sys.exit(0 if passed else 65)
        else:
            sys.exit(64)
    except OSError:
        sys.exit(65)
