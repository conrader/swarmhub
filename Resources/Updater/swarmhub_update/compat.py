"""Compatibility for the box (CORE-PLAN.md §6; SCHEMAS.md §8; phase P3a): the consumer's versions, the installed
Hermes version (read-only), and which axis made a line or a component incompatible.

Hermes version. Hermes' own source of truth is `hermes_cli.__version__` (its API server's `/health` returns exactly
that, `gateway/platforms/api_server.py` `_hermes_version()`), defined as a string literal in
`<install>/hermes_cli/__init__.py`. The updater reads that file as text, at most 256 KiB, and takes the literal; it
never imports or runs Hermes code, never calls Hermes, and opens the file read-only. Install folders tried in order
(the Hermes installer's layouts, `scripts/install.sh`):

    config.json `hermes_install_dir`     set by the operator for another layout
    $HERMES_INSTALL_DIR                  the installer's override
    <hermes home>/hermes-agent           default non-root install (~/.hermes/hermes-agent)
    /usr/local/lib/hermes-agent          root (FHS) install

If none yields a version (`[0-9]+(.[0-9]+){0,3}`), config.json `hermes_version` (operator-set) is used; else Hermes is
"unknown": the consumer has no `hermes` axis, so a line or component that declares a Hermes range is unsatisfied and
skipped with `incompatible: hermes` (SCHEMAS.md §8), and the rest apply. Stdlib only, Python 3.8+.
"""

import os
import re

from . import bundle, verify

SYSTEM_INSTALL_DIRS = ("/usr/local/lib/hermes-agent",)
VERSION_FILE = ("hermes_cli", "__init__.py")
MAX_SOURCE = 256 * 1024
ASSIGNMENT = re.compile(r"""^__version__[ \t]*=[ \t]*(['"])([^'"\r\n]{1,40})\1[ \t]*(#.*)?$""", re.MULTILINE)


def install_dirs(hermes_home, config):
    candidates = []
    if isinstance(config.get("hermes_install_dir"), str) and os.path.isabs(config["hermes_install_dir"]):
        candidates.append(config["hermes_install_dir"])
    if os.path.isabs(os.environ.get("HERMES_INSTALL_DIR", "")):
        candidates.append(os.environ["HERMES_INSTALL_DIR"])
    candidates.append(os.path.join(hermes_home, "hermes-agent"))
    candidates.extend(SYSTEM_INSTALL_DIRS)
    return candidates


def read_version(install_dir):
    """The `__version__` literal of `<install_dir>/hermes_cli/__init__.py`, or None. Text only, never executed."""
    try:
        text = bundle.read_file(os.path.join(install_dir, *VERSION_FILE), MAX_SOURCE).decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None
    found = [match.group(2) for match in ASSIGNMENT.finditer(text)]
    if len(found) != 1 or not verify.VERSION.fullmatch(found[0]):
        return None  # absent, ambiguous or not a plain version: unknown, never a guess
    return found[0]


def hermes(hermes_home, config):
    """{"version": str|None, "source": where it came from, or "unknown"}."""
    for folder in install_dirs(hermes_home, config):
        version = read_version(folder)
        if version is not None:
            return {"version": version, "source": os.path.join(folder, *VERSION_FILE)}
    configured = config.get("hermes_version")
    if isinstance(configured, str) and verify.VERSION.fullmatch(configured):
        return {"version": configured, "source": "config.json hermes_version"}
    return {"version": None, "source": "unknown"}


def consumer(config, hermes_home, updater_version):
    """(box consumer for verification, Hermes info for the status). `hermes` only when known."""
    info = hermes(hermes_home, config)
    versions = {"updater": updater_version}
    if info["version"] is not None:
        versions["hermes"] = info["version"]
    return {"platform": "box", "versions": versions}, info


def unmet(requires, consumer_):
    """Axes of `requires` this consumer does not satisfy, sorted (an unknown axis counts; other platforms' axes
    do not), using verify.satisfies per axis so there is one comparison rule."""
    return sorted(axis for axis, constraint in requires.items()
                  if not verify.satisfies({axis: constraint}, consumer_))


def annotate(verified, consumer_):
    """`verified` with each `incompatible` skip naming its axes: `{"name", "reason": "incompatible", "axes":
    ["hermes"], "detail": "incompatible: hermes"}`. Verdicts and reasons stay as SCHEMAS.md §10 defines them."""
    by_name = {c["name"]: c for c in verified.manifest["components"]}
    skipped = []
    for entry in verified.skipped:
        entry = dict(entry)
        if entry.get("reason") == "incompatible" and entry.get("name") in by_name:
            axes = unmet(by_name[entry["name"]]["requires"], consumer_)
            entry.update(axes=axes, detail="incompatible: " + ", ".join(axes))
        skipped.append(entry)
    return verified._replace(skipped=skipped)
