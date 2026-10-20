#!/usr/bin/env python3
"""File evidence for code-job. Report contents are never copied into the journal."""
import errno
import hashlib
import os
import re
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
    digest = hashlib.sha256()
    size = 0
    try:
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(65536), b""):
                digest.update(chunk)
                size += len(chunk)
    except OSError as error:
        return "unreadable-" + errno.errorcode.get(error.errno, str(error.errno)), str(info.st_size), None
    if size == 0:
        return "empty", "0", None
    return "ok", str(size), digest.hexdigest()


def fingerprint(path):
    state, _, digest = inspect(path)
    if state not in ("ok", "missing", "empty"):
        raise OSError("cannot fingerprint report: " + state)
    return digest or "missing-or-empty"


def main(command, report, job):
    try:
        folder = os.path.join(job, "")
        state, size, digest = inspect(report)
        value = digest or "missing-or-empty"
        if command == "baseline":
            # An unknown baseline must never become permission to accept unchanged bytes later.
            with open(folder + "report-before-state", "w") as out:
                out.write(state)
            with open(folder + "report-before", "w") as out:
                out.write(value if state in ("ok", "missing", "empty") else "invalid:" + state)
            if state not in ("ok", "missing", "empty"):
                print("code-job: report baseline unavailable: " + state, file=sys.stderr)
                return 65
        elif command == "verify":
            with open(folder + "report-before") as before:
                baseline = before.read()
            known = baseline == "missing-or-empty" or re.fullmatch(r"[0-9a-f]{64}", baseline)
            passed = bool(known and digest and value != baseline)
            result_state = state if state != "ok" or passed else "unchanged"
            if not known:
                result_state = "baseline-invalid"
            for name, text in (("report-valid", "true" if passed else "false"), ("report-sha256", value),
                               ("report-state", result_state),
                               ("report-bytes", size)):
                with open(folder + name, "w") as out:
                    out.write(text)
            return 0 if passed else 65
        else:
            return 64
    except OSError:
        return 65
    return 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
