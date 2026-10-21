"""jobroute job index: one profile's own jobs, reservations, launch outcomes and recovery.

The index holds one reservation row per accepted submit, written under the lock BEFORE the
launch, then one outcome row ({"launch", "id"} | {"failed"} | {"abandoned"}). A launch that is
killed or times out leaves its reservation: it counts toward the rate limits and is matched to
the job's sb-codejob status file once its launcher is gone (an audited "recover" row).
"""
from __future__ import annotations

import contextlib
import datetime
import fcntl
import json
import os
import pathlib
import re
import time

LOCK_WAIT = 5              # seconds a request waits for the state lock (held only briefly, never over a launch)
RECOVER_WINDOW = 300       # a recovered job's status file must be named within this many seconds of its reservation
LABEL_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,39}")


class Busy(Exception):
    """The state lock stayed held for LOCK_WAIT seconds."""


class JobIndex:
    """Mixed into Route: needs self.index, self.job_root, self.agent and self.audit()."""

    def own_jobs(self, recover_mode: str | None = None) -> list[dict]:
        jobs, by_launch = [], {}
        with contextlib.suppress(FileNotFoundError):
            for line in self.index.read_text().splitlines():
                try:
                    row = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(row, dict):
                    continue
                launch = row.get("launch")
                if launch is None:
                    if isinstance(row.get("id"), str):     # a row from before reservations
                        jobs.append(row)
                elif "t" in row:
                    if launch not in by_launch:
                        by_launch[launch] = dict(row, id=None)
                        jobs.append(by_launch[launch])
                elif launch in by_launch:
                    j = by_launch[launch]
                    if row.get("abandoned"):
                        j["abandoned"] = True
                    if j["id"] is None and not j.get("failed"):
                        if isinstance(row.get("id"), str):
                            j["id"] = row["id"]
                        elif row.get("failed"):
                            j["failed"] = row["failed"]
        jobs = [j for j in jobs if not j.get("failed")]   # a failed launch started nothing
        if recover_mode:
            self._recover(jobs, recover_mode)
        return jobs

    def _recover(self, jobs: list[dict], mode: str) -> None:
        """Call with the lock held. Resolve reservations whose launcher died or gave up."""
        claimed = {j["id"] for j in jobs if j.get("id")}
        for j in jobs:
            if (j.get("id") or "launch" not in j
                    or (not j.get("abandoned") and _launcher_alive(j.get("launcher")))):
                continue
            job_id = self._find_record(j, claimed)
            if job_id:
                claimed.add(job_id)
                j["id"] = job_id
                _append(self.index, {"launch": j["launch"], "id": job_id, "recovered": True})
                self.audit("recover", mode, "ok", job_id=job_id, launch=j["launch"], label=j.get("label"),
                           engine=j.get("engine"), workdir=j.get("workdir"))

    def _find_record(self, j: dict, claimed: set) -> str | None:
        """The earliest unclaimed sb-codejob status file for this reservation: same label, engine
        argv and workdir, named within RECOVER_WINDOW seconds of the reservation."""
        label = j.get("label")
        if not isinstance(label, str) or not LABEL_RX.fullmatch(label):
            return None
        # sb-codejob.slugify strips '-._' at both ends before truncating to 40 chars.
        # Accepted route labels already start alphanumeric, contain no dots and fit in
        # 40 chars, so only trailing hyphens/underscores can change. Keep the submitted
        # label in the reservation/audit; match the filename using sb-codejob's label.
        label = label.rstrip("-_")
        rx = re.compile(r"([0-9]{8}T[0-9]{6}Z)-" + re.escape(label) + r"(-[0-9]{1,2})?")
        best = None
        for f in (self.job_root / self.agent).glob(f"*Z-{label}*.json"):
            m = rx.fullmatch(f.stem)
            if not m or f.stem in claimed:
                continue
            ts = datetime.datetime.strptime(m[1], "%Y%m%dT%H%M%SZ").replace(
                tzinfo=datetime.timezone.utc).timestamp()
            if not j.get("t", 0) - 2 <= ts <= j.get("t", 0) + RECOVER_WINDOW:
                continue
            rec = self.job_record(f.stem)
            wd = rec.get("workdir") if rec else None
            if (not rec or rec.get("cmd") != j.get("cmd")
                    or (wd is not None and os.path.realpath(str(wd)) != j.get("workdir"))):
                continue
            if best is None or ts < best[0]:
                best = (ts, f.stem)
        return best[1] if best else None

    def job_record(self, job_id: str) -> dict | None:
        path = self.job_root / self.agent / f"{job_id}.json"
        try:
            rec = json.loads(path.read_text())
        except (OSError, ValueError):
            return None
        return rec if isinstance(rec, dict) and rec.get("tool") == "sb-codejob" else None

    def _running(self, jobs: list[dict]) -> int:
        n = 0
        for j in jobs:
            if not j.get("id"):
                n += self._state(j) == "launching"
                continue
            rec = self.job_record(j["id"])
            if rec and not rec.get("ended") and (_alive(rec.get("pid")) or _alive(rec.get("supervisor_pid"))):
                n += 1
        return n

    def _state(self, j: dict) -> str:
        if not j.get("id"):
            launching = not j.get("abandoned") and _launcher_alive(j.get("launcher"))
            return "launching" if launching else "unknown"
        rec = self.job_record(j["id"]) or {}
        if rec.get("ended"):
            return "done"
        if rec and (_alive(rec.get("pid")) or _alive(rec.get("supervisor_pid"))):
            return "running"
        return "lost" if rec else "unknown"

    def _summary(self, j: dict) -> dict:
        rec = (self.job_record(j["id"]) if j.get("id") else None) or {}
        state = self._state(j)
        return {"job_id": j["id"], "label": j.get("label"), "engine": j.get("engine"), "state": state,
                "started": rec.get("started"), "ended": rec.get("ended"), "exit_code": rec.get("exit_code"),
                "minutes": rec.get("minutes"), "model": rec.get("model"), "review": rec.get("review"),
                "wake": rec.get("wake")}


def _alive(pid) -> bool:
    return isinstance(pid, int) and pid > 0 and os.path.exists(f"/proc/{pid}")


def _proc_start(pid) -> int | None:
    try:
        return int(pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()[19])
    except (OSError, ValueError, IndexError):
        return None


def _launcher() -> dict:
    return {"pid": os.getpid(), "start": _proc_start(os.getpid())}


def _launcher_alive(launcher) -> bool:
    """The launching route process still runs (same pid and start time)."""
    if not isinstance(launcher, dict) or not isinstance(launcher.get("pid"), int):
        return False
    start = _proc_start(launcher["pid"])
    return start is not None and start == launcher.get("start")


def _append(path: pathlib.Path, row: dict) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    try:
        os.write(fd, (json.dumps(row, ensure_ascii=True) + "\n").encode())
    finally:
        os.close(fd)


@contextlib.contextmanager
def _locked(path: pathlib.Path):
    """Bounded wait (LOCK_WAIT): the lock is never held across a launch."""
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() > deadline:
                    raise Busy() from None
                time.sleep(0.05)
        yield
    finally:
        os.close(fd)
