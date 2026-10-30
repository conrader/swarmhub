"""jobroute core: allowlist, validation, rate limit, audit log, submit and status.

Everything a caller sends is data. Nothing here builds a shell string: sb-codejob is
run with a fixed argv list, the engine argv comes from the allowlist file, and the
brief reaches the job through stdin only.
"""
from __future__ import annotations

import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import pwd
import re
import stat
import subprocess
import time
import tomllib

from jobroute_jobs import LABEL_RX, Busy, JobIndex, _append, _launcher, _locked
from jobroute_trust import launch_problem
from jobroute_commands import Commands

PROFILE_RX = re.compile(r"[a-z0-9][a-z0-9-]{0,63}")
COMPONENT_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
BOT_RX = re.compile(r"[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}")
JOB_ID_RX = re.compile(r"[0-9]{8}T[0-9]{6}Z-[A-Za-z0-9_-]{1,40}(-[0-9]{1,2})?")
MAX_DEPTH = 8
LAUNCH_TIMEOUT = 60
DEFAULTS = {"engines": ["claude", "codex"], "max_per_hour": 4, "max_per_day": 20, "max_running": 2}
# Production paths a job may never start in, whatever the allowlist says. On top of these:
# anything under [route] home that is not under work_root, and [route] deny_paths.
BUILTIN_DENY = ("/var/www", "/etc")
PROD_HOME = "/home/ubuntu"


class Refused(Exception):
    """A request the route will not run. The message is safe to show the caller."""

    def __init__(self, reason: str, code: int = 2):
        super().__init__(reason)
        self.reason, self.code = reason, code


class RateLimited(Refused):
    def __init__(self, reason: str):
        super().__init__(reason, 3)


def now_iso() -> str:
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def norm_agent(name: str) -> str:
    """sb-codejob's own matching: case, spaces, hyphens and underscores ignored."""
    return re.sub(r"[^a-z0-9]", "", name.lower())


def _under(path: str, root: str) -> bool:
    return path == root or path.startswith(root.rstrip("/") + "/")


def _forms(path: str) -> set[str]:
    """The lexical and the resolved form of a configured path; a check must hit neither."""
    return {os.path.normpath(path), os.path.realpath(path)}


def _misconfigured(what: str) -> Refused:
    return Refused(f"route misconfigured: {what}", 1)


def _trusted(path: pathlib.Path) -> None:
    st = path.stat()
    if st.st_uid != os.geteuid() or st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
        raise Refused(f"route misconfigured: {path.name} must be owned by the route user and not group/world-writable", 1)


class Route(Commands, JobIndex):
    """One loaded allowlist bound to one profile (the profile comes from the forced command)."""

    def __init__(self, config_path: str, profile: str, refused_connect=None):
        cfg_path = pathlib.Path(config_path)
        _trusted(cfg_path)
        with cfg_path.open("rb") as f:
            cfg = tomllib.load(f)
        r = cfg.get("route", {})
        self.state_dir = pathlib.Path(r["state_dir"])
        self.sb_codejob = r["sb_codejob"]
        self.job_root = pathlib.Path(r["job_root"])
        self.path = r.get("path", "/usr/local/bin:/usr/bin:/bin")
        self.max_brief = int(r.get("max_brief_bytes", 65536))
        # a CLI submit's stdin must reach EOF within this (+ 5 s lock + 60 s launch stays under the 120 s alarm)
        self.brief_read_secs = min(float(r.get("brief_read_secs", 50)), 50.0)
        self.launch_timeout = min(float(r.get("launch_timeout_secs", LAUNCH_TIMEOUT)), LAUNCH_TIMEOUT)
        self.work_root = os.path.normpath(r.get("work_root", r["job_root"]))
        self.canonical_work_root = os.path.realpath(self.work_root)
        self.home = _forms(r.get("home", PROD_HOME))
        self.deny = set().union(*(_forms(d) for d in (*BUILTIN_DENY, *r.get("deny_paths", []))))
        self.backends = r.get('backends', {})
        self.approvals = pathlib.Path(r.get('approvals', '/nonexistent/jobroute-approvals'))
        self.route_home = pwd.getpwuid(os.geteuid()).pw_dir
        self.submissions_enabled = r.get('submissions_enabled', False) is True
        self.extra_env = {str(k): str(v) for k, v in r.get("env", {}).items()}
        self.engines = {k: [str(x) for x in v] for k, v in cfg.get("engines", {}).items()}
        defaults = {**DEFAULTS, **cfg.get("defaults", {})}
        self.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        _trusted(self.state_dir)
        self.profile = profile if PROFILE_RX.fullmatch(profile or "") else "<invalid>"
        prof = cfg.get("profiles", {}).get(self.profile)
        if not isinstance(prof, dict):
            fields = refused_connect() if refused_connect else {}
            self.audit("connect", "-", "refused", reason="profile not allowlisted", **fields)
            raise Refused("profile not allowlisted")
        try:
            self._load_profile(prof, defaults)
        except (KeyError, TypeError, ValueError) as e:
            err = _misconfigured(f"profile {self.profile} is invalid ({type(e).__name__})")
        except Refused as e:
            err = e
        else:
            self.index = self.state_dir / "profiles" / f"{profile}.jsonl"
            self.index.parent.mkdir(mode=0o700, exist_ok=True)
            return
        fields = refused_connect() if refused_connect else {}
        self.audit("connect", "-", "error", reason=err.reason, **fields)
        err.audited = True
        raise err

    def _load_profile(self, prof: dict, defaults: dict) -> None:
        self.enabled_verbs = prof.get('enabled_verbs', [])
        self.mac_hosts = prof.get('mac_hosts', [])
        self.command_per_hour = prof.get('command_per_hour', 60)
        if (not isinstance(self.enabled_verbs, list) or not all(isinstance(v, str) for v in self.enabled_verbs)
                or not isinstance(self.mac_hosts, list) or not all(v in ('macbook', 'mini') for v in self.mac_hosts)
                or type(self.command_per_hour) is not int or not 1 <= self.command_per_hour <= 3600):
            raise _misconfigured('invalid verb/host allowlist or command limit')
        self.submissions_enabled = (self.submissions_enabled
                                    and prof.get('submissions_enabled', defaults.get('submissions_enabled', False)) is True)
        self.agent = prof["agent"]
        if not isinstance(self.agent, str) or not self.agent.strip():
            raise _misconfigured(f"profile {self.profile} needs agent = <sb-codejob agent name>")
        bot = prof.get("bot")
        if not isinstance(bot, str) or not BOT_RX.fullmatch(bot) or ".." in bot:
            raise _misconfigured(f"profile {self.profile} needs bot = <directory name under {self.work_root}>")
        self.bot_root = os.path.join(self.work_root, bot)
        # The target of a bot-root symlink must never redefine this boundary.
        self.bot_boundary = os.path.join(self.canonical_work_root, bot)
        configured = prof.get("workdirs", [self.bot_root])
        if not configured or any(not _under(os.path.normpath(w), self.bot_root) for w in configured):
            raise _misconfigured(f"profile {self.profile} workdirs must be under {self.bot_root}")
        self.workdirs = [os.path.realpath(w) for w in configured]
        self.allowed_engines = [e for e in prof.get("engines", defaults["engines"]) if e in self.engines]
        self.max_per_hour = int(prof.get("max_per_hour", defaults["max_per_hour"]))
        self.max_per_day = int(prof.get("max_per_day", defaults["max_per_day"]))
        self.max_running = int(prof.get("max_running", defaults["max_running"]))

    # ------------------------------------------------------------ audit
    def audit(self, op: str, mode: str, result: str, **fields) -> None:
        peer = (os.environ.get("SSH_CONNECTION") or "").split(" ")[0] or None
        row = {"ts": now_iso(), "profile": self.profile, "op": op, "mode": mode,
               "result": result, "peer": peer, **fields}
        _append(self.state_dir / "audit.jsonl", row)

    # ------------------------------------------------------------ validation
    def check_engine(self, engine) -> str:
        if not isinstance(engine, str) or engine not in self.allowed_engines:
            raise Refused(f"engine must be one of: {', '.join(self.allowed_engines)}")
        return engine

    def check_agent(self, agent) -> None:
        if agent is None:
            return
        if not isinstance(agent, str) or norm_agent(agent) != norm_agent(self.agent):
            raise Refused("agent does not match this profile")

    @staticmethod
    def check_label(label) -> str:
        if not isinstance(label, str) or not LABEL_RX.fullmatch(label):
            raise Refused("label must be 1-40 chars [A-Za-z0-9_-], starting alphanumeric")
        return label

    def prod_reason(self, path: str) -> str | None:
        """Why `path` (lexical or resolved) is a production path, or None. Wins over the allowlist."""
        if any(_under(path, d) for d in self.deny):
            return "workdir refused: production path (denylisted)"
        work = _forms(self.work_root)
        if any(_under(path, h) for h in self.home) and not any(_under(path, w) for w in work):
            return f"workdir refused: production path (outside {self.work_root})"
        return None

    def _refuse_prod(self, *paths: str) -> None:
        for p in paths:
            reason = self.prod_reason(p)
            if reason:
                raise Refused(reason)

    def check_workdir(self, raw, logged: dict | None = None) -> str:
        try:
            if isinstance(raw, str):
                raw.encode("utf-8")   # realpath can otherwise raise on JSON lone surrogates
            return self._check_workdir(raw, logged)
        except (OSError, ValueError, UnicodeError):
            raise Refused("workdir not allowed: malformed or inaccessible path") from None

    def _check_workdir(self, raw, logged: dict | None = None) -> str:
        """Resolve the realpath first, then: denylist, then this profile's bot allowlist."""
        bot_real = os.path.realpath(self.bot_root)
        self._refuse_prod(self.bot_root, bot_real)
        if os.path.islink(self.bot_root) or bot_real != self.bot_boundary:
            raise Refused("workdir not allowed: bot root must be its own directory")
        root = self.workdirs[0]
        if raw is None or raw in ("", "."):
            rel = ""
        elif not isinstance(raw, str) or len(raw) > 512 or "\0" in raw:
            raise Refused("workdir not allowed")
        elif raw.startswith("/"):
            self._refuse_prod(os.path.normpath(raw), os.path.realpath(raw))
            raw = raw.rstrip("/") or "/"
            match = [w for w in self.workdirs if raw == w or raw.startswith(w + "/")]
            if not match:
                raise Refused("workdir not allowed")
            root = match[0]
            rel = raw[len(root):].lstrip("/")
        else:
            rel = raw.rstrip("/")
        parts = rel.split("/") if rel else []
        if len(parts) > MAX_DEPTH or any(".." in p or not COMPONENT_RX.fullmatch(p) for p in parts):
            raise Refused("workdir not allowed")
        lexical = os.path.join(root, *parts)
        real = os.path.realpath(lexical)
        if logged is not None:
            logged["workdir"] = real
        self._refuse_prod(lexical, real)
        if not any(_under(real, w) for w in self.workdirs) or not _under(real, self.bot_boundary):
            raise Refused("workdir not allowed")
        if not os.path.isdir(real):
            raise Refused("workdir does not exist")
        return real

    def check_brief(self, brief: bytes) -> bytes:
        if not brief.strip():
            raise Refused("brief is empty (send it on stdin)")
        if len(brief) > self.max_brief:
            raise Refused(f"brief is larger than the {self.max_brief}-byte limit (max_brief_bytes); "
                          "send a shorter brief, e.g. point to a file in the workdir")
        if b"\0" in brief:
            raise Refused("brief contains NUL bytes")
        try:
            brief.decode("utf-8")
        except UnicodeDecodeError:
            raise Refused("brief is not UTF-8") from None
        return brief

    def check_rate(self, jobs: list[dict]) -> None:
        now = time.time()
        hour = sum(1 for j in jobs if now - j.get("t", 0) < 3600)
        day = sum(1 for j in jobs if now - j.get("t", 0) < 86400)
        if hour >= self.max_per_hour:
            raise RateLimited(f"rate limit: {self.max_per_hour} submissions per hour")
        if day >= self.max_per_day:
            raise RateLimited(f"rate limit: {self.max_per_day} submissions per day")
        if self._running(jobs) >= self.max_running:
            raise RateLimited(f"rate limit: {self.max_running} jobs already running")

    # ------------------------------------------------------------ operations
    def submit(self, mode: str, engine, label, workdir, brief: bytes, agent=None, brief_meta=None) -> dict:
        """brief_meta: the CLI reader's {"sha256", "bytes", "end", "problem"?} when it read more than it
        kept (oversize) or stopped early (stdin never closed)."""
        meta = brief_meta or {"sha256": hashlib.sha256(brief).hexdigest(), "bytes": len(brief), "end": "eof"}
        digest = meta["sha256"]
        logged = {"label": label[:64] if isinstance(label, str) else None,
                  "engine": engine[:32] if isinstance(engine, str) else None,
                  "workdir_requested": workdir[:256] if isinstance(workdir, str) else None,
                  "workdir": None, "brief_sha256": digest, "brief_bytes": meta["bytes"]}
        if meta["end"] != "eof":
            logged["brief_hash_partial"] = True      # the hash covers only the bytes that arrived
        try:
            if not self.submissions_enabled:
                raise Refused('submissions disabled')
            self.check_agent(agent)
            engine = self.check_engine(engine)
            label = self.check_label(label)
            wd = self.check_workdir(workdir, logged)
            if meta.get("problem"):
                raise Refused(meta["problem"])
            self.check_brief(brief)
            problem, cmd = launch_problem(self.sb_codejob, self.engines[engine], self.path)
            if problem:
                raise _misconfigured(f"launch refused: {problem}")
            launch = os.urandom(8).hex()
            with self._lock():
                self.check_rate(self.own_jobs(mode))
                # Reserve before the slow launch: a killed launch still leaves an index + audit row.
                _append(self.index, {"t": time.time(), "launch": launch, "label": label, "engine": engine,
                                     "workdir": wd, "cmd": cmd, "launcher": _launcher()})
                self.audit("submit", mode, "launching", launch=launch, **logged)
            job_id = self._launch(launch, cmd, label, wd, brief, mode)
            _append(self.index, {"launch": launch, "id": job_id})
        except RateLimited as e:
            self.audit("submit", mode, "rate_limited", reason=e.reason, **logged)
            e.audited = True
            raise
        except Refused as e:
            self.audit("submit", mode, "refused" if e.code == 2 else "error", reason=e.reason, **logged)
            e.audited = True
            raise
        except Exception as e:
            self.audit("submit", mode, "error", reason=f"route error: {type(e).__name__}", **logged)
            e.audited = True
            raise
        self.audit("submit", mode, "ok", job_id=job_id, launch=launch, **logged)
        return {"ok": True, "job_id": job_id, "agent": self.agent, "engine": engine, "label": label,
                "workdir": wd, "brief_sha256": digest,
                "note": "the job runs detached on ovh; sb-codejob wakes this agent when it ends"}

    @contextlib.contextmanager
    def _lock(self):
        try:
            with _locked(self.state_dir / ".lock"):
                yield
        except Busy:
            raise RateLimited("route busy: try again shortly") from None

    def _launch(self, launch: str, cmd: list[str], label: str, workdir: str, brief: bytes, mode: str) -> str:
        argv = [self.sb_codejob, "--agent", self.agent, "--workdir", workdir, "--label", label,
                "--stdin", *(["--review"] if getattr(self, "request_review", False) else []), "--", *cmd]
        home = pwd.getpwuid(os.geteuid()).pw_dir
        env = {"PATH": self.path, "HOME": home, "USER": pwd.getpwuid(os.geteuid()).pw_name,
               "LANG": "C.UTF-8", **self.extra_env}
        env.pop("ANTHROPIC_API_KEY", None)        # subscription auth only, never an API key
        try:
            p = subprocess.run(argv, input=brief, capture_output=True, env=env, cwd=workdir,
                               timeout=self.launch_timeout)
        except OSError as e:
            _append(self.index, {"launch": launch, "failed": type(e).__name__})
            raise Refused(f"launch failed: {type(e).__name__}", 1) from None
        except subprocess.TimeoutExpired:
            raise self._abandon(launch, mode, "launch failed: TimeoutExpired") from None
        status = next((ln.split(None, 1)[1] for ln in p.stdout.decode(errors="replace").splitlines()
                       if ln.startswith("status ")), None)
        if p.returncode != 0 or not status:
            _append(self.index, {"launch": launch, "failed": f"exit {p.returncode}"})
            raise Refused(f"launch failed: sb-codejob exit {p.returncode}", 1)
        sp = pathlib.Path(status.strip())
        if (os.path.realpath(sp.parent) != os.path.realpath(self.job_root / self.agent)
                or not JOB_ID_RX.fullmatch(sp.stem)):
            raise self._abandon(launch, mode, "launch failed: unexpected status path")
        return sp.stem

    def _abandon(self, launch: str, mode: str, reason: str) -> Refused:
        """The launcher gave up, but sb-codejob may already have detached the job: let recovery find it."""
        _append(self.index, {"launch": launch, "abandoned": True})
        with contextlib.suppress(RateLimited), self._lock():
            job = next((j for j in self.own_jobs(mode) if j.get("launch") == launch), {})
            if job.get("id"):
                reason += f"; job {job['id']} did start, see job_status"
        return Refused(reason, 1)

    def status(self, mode: str, job_id=None, limit=10, report=False) -> dict:
        try:
            if type(report) is not bool:
                raise Refused('report must be a boolean')
            if report and (report is not True or job_id is None or 'report' not in self.enabled_verbs):
                raise Refused('report requires an enabled verb and an owned job id')
            if job_id is not None and (not isinstance(job_id, str) or not JOB_ID_RX.fullmatch(job_id)):
                raise Refused("unknown job")
            if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 50:
                raise Refused("limit must be 1-50")
        except Refused as e:
            self.audit("status", mode, "refused", reason=e.reason)
            e.audited = True
            raise
        try:
            with self._lock():
                jobs = self.own_jobs(mode)
        except RateLimited:                    # busy: answer from the index without recovering
            jobs = self.own_jobs()
        if job_id is not None:
            jobs = [j for j in jobs if j.get("id") == job_id]
            if not jobs:
                self.audit("status", mode, "refused", reason="unknown job")
                e = Refused("unknown job")
                e.audited = True
                raise e
        out = [self._summary(j) for j in reversed(jobs[-limit:])]
        if report:
            try:
                out[0]['report'] = self.report(job_id)
            except Exception as exc:
                self.audit('report', mode, 'refused' if isinstance(exc, Refused) else 'error',
                           job_id=job_id, reason=exc.reason if isinstance(exc, Refused) else type(exc).__name__)
                exc.audited = True
                raise
        self.audit("status", mode, "ok", count=len(out))
        return {"ok": True, "profile": self.profile, "agent": self.agent, "jobs": out}
