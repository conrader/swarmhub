"""Fixed read-only machine.exec probe. Its only argument is operator-supplied scope."""
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys

STATUS = re.compile(r"[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9._-]{1,44}\.json")
DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def private_directory(path):
    # Open each component relative to the pinned descriptor. A replaced symlink
    # in a project or runner directory must never expand the read scope.
    fd = os.open("/", DIRECTORY)
    try:
        for component in Path(path).parts[1:]:
            child = os.open(component, DIRECTORY, dir_fd=fd)
            os.close(fd)
            fd = child
        info = os.fstat(fd)
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise ValueError()
        return fd
    except BaseException:
        os.close(fd)
        raise


def record(directory, name):
    fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW, dir_fd=directory)
    with os.fdopen(fd, "rb") as source:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise ValueError()
        data = source.read(256 * 1024 + 1)
        if len(data) > 256 * 1024:
            raise ValueError()
        return json.loads(data)


class Linux:
    def __init__(self):
        self.boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()

    def process(self, pid):
        folder = Path("/proc", str(pid))
        fields = (folder / "stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] in ("Z", "X", "T", "t") or folder.stat().st_uid != os.geteuid():
            raise ValueError()
        return int(fields[1]), int(fields[19])

    def descendants(self, pid):
        folder = Path("/proc", str(pid))
        children = set()
        for thread in (folder / "task").iterdir():
            try:
                children.update(map(int, (thread / "children").read_text().split()))
            except FileNotFoundError:
                continue
        return children

    def executable(self, pid):
        return os.readlink("/proc/%d/exe" % pid)

    def queued(self, pid):
        # The kernel confirms this thread is waiting on a lock.
        return Path("/proc", str(pid), "wchan").read_text().strip() in (
            "locks_lock_inode_wait", "flock_lock_inode_wait", "locks_lock_file_wait")


class Darwin:
    boot = None

    def __init__(self):
        # lstart in the C locale is the installed runner's Darwin start token.
        # comm is the executable path. Never request args, command or environment.
        text = subprocess.check_output(
            ["/bin/ps", "-ww", "-U", str(os.geteuid()), "-o", "pid=,ppid=,state=,lstart=,comm="],
            env={"LC_ALL": "C"}, timeout=2).decode()
        self.rows, self.children = {}, {}
        for line in text.splitlines():
            m = re.fullmatch(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(\w{3} \w{3} [ \d]\d [\d:]{8} \d{4})\s+(.+)", line)
            if not m or m[3].startswith(("Z", "T")):
                continue
            pid, parent = int(m[1]), int(m[2])
            self.rows[pid] = (parent, m[4], m[5])
            self.children.setdefault(parent, []).append(pid)

    def process(self, pid):
        return self.rows[pid][:2]

    def descendants(self, pid):
        return self.children.get(pid, [])

    def executable(self, pid):
        return self.rows[pid][2]

    def queued(self, pid):
        return False


def activity(rec, processes, executables):
    pid, supervisor = rec["pid"], rec["supervisor_pid"]
    if any(type(n) is not int or n <= 1 for n in (pid, supervisor)):
        raise ValueError()

    def verify():
        if (rec["boot_id"] != processes.boot or
                processes.process(pid) != (supervisor, rec["pid_starttime"]) or
                processes.process(supervisor)[1] != rec["supervisor_starttime"]):
            raise ValueError()

    verify()
    pending = [pid]
    seen = set()
    waiting = incomplete = False
    while pending:
        current = pending.pop()
        if current in seen or len(seen) >= 512:
            raise ValueError()
        seen.add(current)
        # Look only in this primary's live subtree. A label, a model ledger
        # entry or 'codex' in a shell command can all precede actual execution.
        try:
            identity = processes.process(current)
            provider = executables.get(processes.executable(current))
            if provider:
                # Recheck the sampled PID and ancestry (exit / PID reuse).
                ancestor = current
                for _ in range(len(seen)):
                    if ancestor == pid:
                        verify()
                        if processes.process(current) == identity:
                            return "working", provider
                        raise ValueError()
                    ancestor = processes.process(ancestor)[0]
                raise ValueError()
            pending.extend(processes.descendants(current))
            waiting |= processes.queued(current)
        except (FileNotFoundError, ProcessLookupError):
            continue  # A short-lived sibling must not hide a live worker.
        except (PermissionError, KeyError, ValueError):
            incomplete = True
    if incomplete:
        raise ValueError()
    verify()
    return ("queued" if waiting else "wrapper"), None


def snapshot(scope):
    if socket.gethostname() != scope["hostname"]:
        raise ValueError()
    if sys.platform == "darwin":
        processes = Darwin()
    elif sys.platform.startswith("linux"):
        processes = Linux()
    else:
        raise ValueError()
    executables = {}
    for provider, path in scope["executables"].items():
        resolved = os.path.realpath(path)
        if resolved in executables or not os.path.isfile(resolved):
            raise ValueError()
        executables[resolved] = provider
    rows, complete = [], True
    bindings = {}
    for owner in scope["owners"]:
        bindings.setdefault(owner["agent"], []).append(owner)
    for agent, owners in bindings.items():
        folder = Path(scope["root"], agent)
        try:
            directory = private_directory(folder)
            try:
                with os.scandir(directory) as entries:
                    for i, entry in enumerate(entries):
                        if i >= 16384:
                            raise ValueError()
                        if not STATUS.fullmatch(entry.name):
                            continue
                        try:
                            rec = record(directory, entry.name)
                            if not isinstance(rec, dict):
                                raise ValueError()
                            if rec.get("tool") != "sb-codejob":
                                continue
                            if (rec["host"] != scope["runner_host"] or rec["agent"] != agent or
                                    rec["log"] != str(folder / (entry.name[:-5] + ".log"))):
                                raise ValueError()
                            if rec["ended"] is not None or rec["exit_code"] is not None:
                                continue
                            workdir = Path(rec["workdir"])
                            if not workdir.is_absolute() or str(workdir) != os.path.realpath(workdir):
                                raise ValueError()
                            owners_here = [o for o in owners if Path(o["workdir"]) in (workdir, *workdir.parents)]
                            if not owners_here:
                                continue
                            if len(owners_here) != 1:
                                raise ValueError()
                            try:
                                state, provider = activity(rec, processes, executables)
                            except (OSError, KeyError, ValueError, TypeError, IndexError):
                                state, provider = "unknown", None
                            # The log basename is unique across same-second launches.
                            # Hash it so even a sensitive slug stays on its host.
                            job = hashlib.sha256(os.fsencode(folder / entry.name)).hexdigest()
                            rows.append(dict(job=job, owner=owners_here[0]["bot_id"], state=state, provider=provider))
                        except (OSError, KeyError, ValueError, TypeError, RecursionError):
                            complete = False
            finally:
                os.close(directory)
        except (OSError, ValueError):
            complete = False
    if len(rows) > 256:
        raise ValueError()
    return dict(complete=complete, jobs=sorted(rows, key=lambda row: row["job"]))


if __name__ == "__main__":
    try:
        print(json.dumps(snapshot(json.loads(sys.argv[1]))))
    except Exception:
        sys.exit(1)  # Raw exceptions and record contents stay off the wire.
