"""jobroute exec trust: nobody but the route user (or root) may be able to swap what the route runs.

The route execs sb-codejob, and sb-codejob execs the engine, as the route user with the bot's
brief. Before each launch the route checks sb-codejob, the engine binary found on the route
PATH, both their resolved real paths, every directory above them and every PATH directory.
Each must be owned by the route user or by the filesystem root's owner, and must not be
group/world-writable. The one exception is a sticky directory owned by the root owner
(like /tmp): others cannot rename or replace entries in it they do not own, and every entry
below it on the path is still checked.
"""
from __future__ import annotations

import os
import stat


def owners() -> tuple[int, int]:
    """(route user, trust anchor). The anchor is root on the host; inside sbtest's user NS it is
    the unmapped overflow uid, which is also what every host-owned file reads as there."""
    return os.geteuid(), os.stat("/").st_uid


def _prefixes(path: str) -> list[str]:
    """'/a/b/c' -> ['/', '/a', '/a/b', '/a/b/c']"""
    parts = [p for p in path.split("/") if p]
    return ["/"] + ["/" + "/".join(parts[:i]) for i in range(1, len(parts) + 1)]


def _entry_problem(path: str, st: os.stat_result, who: tuple[int, int]) -> str | None:
    if stat.S_ISLNK(st.st_mode):
        return None          # its own mode is meaningless: the directory holding it and its target are checked
    if st.st_uid not in who:
        return f"{path} is not owned by the route user or root"
    if st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        if stat.S_ISDIR(st.st_mode) and st.st_mode & stat.S_ISVTX and st.st_uid == who[1]:
            return None
        return f"{path} is group/world-writable"
    return None


def chain_problem(path: str, must_exist: bool = True, who: tuple[int, int] | None = None) -> str | None:
    """Why `path` could be swapped by someone else, or None. Checks every component of its lexical
    and of its resolved form. A missing tail is fine only when must_exist is false (a PATH entry)."""
    who = who or owners()
    if not os.path.isabs(path) or ".." in path.split("/"):
        return f"{path} must be an absolute path without '..'"
    for form in dict.fromkeys((os.path.normpath(path), os.path.realpath(path))):
        for comp in _prefixes(form):
            try:
                st = os.lstat(comp)
            except FileNotFoundError:
                if must_exist:
                    return f"{comp} does not exist"
                break
            problem = _entry_problem(comp, st, who)
            if problem:
                return problem
    return None


def executable_problem(path: str, who: tuple[int, int] | None = None) -> str | None:
    problem = chain_problem(path, True, who)
    if problem:
        return problem
    real = os.path.realpath(path)
    if not stat.S_ISREG(os.stat(real).st_mode) or not os.access(real, os.X_OK):
        return f"{path} is not an executable file"
    return None


def resolve_engine(name: str, path: str) -> str | None:
    """The absolute path the engine name resolves to on the route PATH (absolute names as given)."""
    if "/" in name:
        return name
    for d in path.split(":"):
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def launch_problem(sb_codejob: str, engine_cmd: list[str], path: str,
                   who: tuple[int, int] | None = None) -> tuple[str | None, list[str]]:
    """-> (problem or None, engine argv with argv[0] made absolute). Checked before every launch."""
    for d in path.split(":"):
        problem = chain_problem(d, False, who) if d else "route PATH has an empty entry"
        if problem:
            return f"untrusted PATH entry: {problem}", engine_cmd
    problem = executable_problem(sb_codejob, who)
    if problem:
        return f"untrusted sb_codejob: {problem}", engine_cmd
    if not engine_cmd:
        return "engine has an empty argv", engine_cmd
    exe = resolve_engine(engine_cmd[0], path)
    if exe is None:
        return f"engine {engine_cmd[0]} not found on the route PATH", engine_cmd
    problem = executable_problem(exe, who)
    if problem:
        return f"untrusted engine {engine_cmd[0]}: {problem}", engine_cmd
    return None, [exe, *engine_cmd[1:]]
