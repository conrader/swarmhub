"""jobroute P2 follow-ups (jobroute-xrev2-verdict.md): pre-launch exec trust check, a reservation
row before the slow launch (with recovery), and an audited refusal of a misconfigured profile.

Same harness as test_jobroute.py, run only inside tests/run-sandbox.sh.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import time

import pytest

from test_jobroute import ROUTE, STUB, Env, mcp, submit

sys.path.insert(0, str(ROUTE.parent))
import jobroute_jobs  # noqa: E402
import jobroute_trust  # noqa: E402


def index_rows(env, profile="grok-admin") -> list[dict]:
    p = env.tmp / f"state/profiles/{profile}.jsonl"
    return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


def set_route(env, old: str, new: str) -> None:
    text = env.cfg.read_text()
    assert text.count(old) == 1, old
    env.cfg.write_text(text.replace(old, new))


def assert_trust_refusal(env, rc, out, needle, args="engine=claude label=fix-login"):
    assert rc == 1 and out["error"].startswith("route misconfigured: launch refused:"), out
    assert needle in out["error"], out
    assert env.calls() == [] and index_rows(env) == []        # nothing ran, nothing reserved
    row = env.audit()[-1]
    assert row["op"] == "submit" and row["result"] == "error" and row["reason"] == out["error"]
    assert row["label"] == args.split("label=")[1].split()[0] and row["brief_sha256"]


# ---------------------------------------------------------------- 2. exec trust check
def _stage_sb_codejob(env) -> pathlib.Path:
    d = env.tmp / "sbbin"
    d.mkdir(mode=0o755)
    shutil.copyfile(STUB, d / "sb-codejob")
    (d / "sb-codejob").chmod(0o755)
    set_route(env, f'sb_codejob = "{STUB}"', f'sb_codejob = "{d}/sb-codejob"')
    assert submit(env)[0] == 0                                  # the staged copy itself is trusted
    (env.tmp / "state/profiles/grok-admin.jsonl").unlink()
    shutil.rmtree(env.tmp / "calls")
    (env.tmp / "calls").mkdir()
    return d


@pytest.mark.parametrize("target,mode", [("sbbin/sb-codejob", 0o775), ("sbbin/sb-codejob", 0o757),
                                         ("sbbin", 0o775), ("sbbin", 0o777)])
def test_writable_sb_codejob_or_its_dir_is_refused_and_audited(tmp_path, target, mode):
    env = Env(tmp_path)
    _stage_sb_codejob(env)
    (tmp_path / target).chmod(mode)
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, f"untrusted sb_codejob: {tmp_path / target} is group/world-writable")


@pytest.mark.parametrize("target,mode", [("bin/claude", 0o775), ("bin/claude", 0o777), ("bin", 0o775)])
def test_writable_engine_or_path_dir_is_refused_and_audited(tmp_path, target, mode):
    env = Env(tmp_path)
    (tmp_path / target).chmod(mode)
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, f"{tmp_path / target} is group/world-writable")


def test_engine_symlink_to_untrusted_real_path_is_refused(tmp_path):
    env = Env(tmp_path)
    real = tmp_path / "shared"
    real.mkdir()
    shutil.copyfile(tmp_path / "bin/claude", real / "claude-real")
    (real / "claude-real").chmod(0o755)
    real.chmod(0o775)                                           # e.g. ~/.local/share/claude/versions
    (tmp_path / "bin/claude").unlink()
    (tmp_path / "bin/claude").symlink_to(real / "claude-real")
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, f"untrusted engine claude: {real} is group/world-writable")
    real.chmod(0o755)                                           # trusted target: accepted, symlink path passed
    rc, [ok] = submit(env)
    assert rc == 0, ok
    cmd = env.calls()[0]["argv"]
    assert cmd[cmd.index("--") + 1] == str(tmp_path / "bin/claude")


def test_writable_ancestor_of_engine_is_refused(tmp_path):
    env = Env(tmp_path)
    nested = tmp_path / "opt/tools/bin"
    nested.mkdir(parents=True)
    shutil.move(tmp_path / "bin/claude", nested / "claude")
    (tmp_path / "opt").chmod(0o777)                             # not sticky: anyone could swap tools/
    set_route(env, f'path = "{tmp_path}/bin:', f'path = "{nested}:{tmp_path}/bin:')
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, f"{tmp_path / 'opt'} is group/world-writable")


@pytest.mark.parametrize("entry", ["bin", "", "{tmp}/x/../bin"])
def test_relative_empty_or_dotdot_path_entry_is_refused(tmp_path, entry):
    env = Env(tmp_path)
    set_route(env, 'path = "', f'path = "{entry.format(tmp=tmp_path)}:')
    rc, [out] = submit(env)
    assert_trust_refusal(env, rc, out, "untrusted PATH entry")


def test_engine_missing_from_path_is_refused(tmp_path):
    env = Env(tmp_path)
    (tmp_path / "bin/codex").unlink()
    rc, [out] = submit(env, args="engine=codex label=no-codex")
    assert_trust_refusal(env, rc, out, "engine codex not found on the route PATH", "engine=codex label=no-codex")


def test_mcp_untrusted_engine_is_refused_and_audited(tmp_path):
    env = Env(tmp_path)
    (tmp_path / "bin/claude").chmod(0o775)
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
        "name": "submit_job", "arguments": {"engine": "claude", "label": "m", "brief": "b"}}})
    body = json.loads(r[1]["result"]["content"][0]["text"])
    assert r[1]["result"]["isError"] and "launch refused: untrusted engine claude" in body["error"]
    assert env.calls() == [] and env.audit()[-1]["result"] == "error"


def test_trust_helper_owner_and_sticky_rules(tmp_path):
    exe = tmp_path / "bin/tool"
    exe.parent.mkdir()
    exe.parent.chmod(0o755)                         # the sandbox umask is 0002
    exe.write_text("#!/bin/sh\n")
    exe.chmod(0o755)
    me, anchor = jobroute_trust.owners()
    entry = jobroute_trust._entry_problem
    assert jobroute_trust.executable_problem(str(exe)) is None
    # owned by neither the route user nor root (inside the user NS nobody else can own a file)
    assert entry(str(exe), os.lstat(exe), (me + 4242, anchor + 4242)) == f"{exe} is not owned by the route user or root"
    # a sticky world-writable directory is accepted only when the trust anchor (root) owns it
    sticky = tmp_path / "sticky"
    sticky.mkdir()
    sticky.chmod(0o1777)
    assert entry(str(sticky), os.lstat(sticky), (me, me + 4242)) == f"{sticky} is group/world-writable"
    assert entry(str(sticky), os.lstat(sticky), (me + 4242, me)) is None
    sticky.chmod(0o777)
    assert entry(str(sticky), os.lstat(sticky), (me + 4242, me)) == f"{sticky} is group/world-writable"
    (sticky / "tool").write_text("#!/bin/sh\n")
    (sticky / "tool").chmod(0o755)
    assert "is group/world-writable" in jobroute_trust.executable_problem(str(sticky / "tool"))


# ---------------------------------------------------------------- 3. reservation before launch
def test_killed_launch_keeps_reservation_and_is_recovered(tmp_path):
    env = Env(tmp_path, running=1, extra_env=f'STUB_PID = "{os.getpid()}"\nSTUB_SLEEP = "20"')
    penv = {"PATH": "/usr/bin:/bin", "SSH_ORIGINAL_COMMAND": "submit engine=claude label=slow",
            "SSH_CONNECTION": "195.201.33.222 50000 145.239.94.119 49123"}
    p = subprocess.Popen([str(ROUTE), "--config", str(env.cfg), "--profile", "grok-admin"], env=penv,
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    p.stdin.write(b"A slow launch.\n")
    p.stdin.close()
    deadline = time.monotonic() + 20
    while not list((tmp_path / "work/Admin").glob("*-slow.json")) and time.monotonic() < deadline:
        time.sleep(0.05)
    [record] = (tmp_path / "work/Admin").glob("*-slow.json")    # sb-codejob detached the job...
    # ...and before the launch returned, the route had already reserved and audited it.
    [reserved] = index_rows(env)
    assert reserved["label"] == "slow" and reserved["launcher"]["pid"] == p.pid
    assert [r["result"] for r in env.audit()] == ["launching"]
    # Kill exactly our own child, the route, mid-launch (as the CLI alarm would).
    cmdline = pathlib.Path(f"/proc/{p.pid}/cmdline").read_bytes().split(b"\0")
    assert p.poll() is None and str(ROUTE).encode() in cmdline
    p.send_signal(signal.SIGKILL)
    p.wait(timeout=10)
    p.stdout.close()
    p.stderr.close()
    rc, [st] = env.run("status")
    assert rc == 0 and [j["job_id"] for j in st["jobs"]] == [record.stem]
    assert st["jobs"][0]["state"] == "running"
    rec = [r for r in env.audit() if r["op"] == "recover"]
    assert len(rec) == 1 and rec[0]["job_id"] == record.stem and rec[0]["launch"] == reserved["launch"]
    assert index_rows(env)[-1] == {"launch": reserved["launch"], "id": record.stem, "recovered": True}
    rc, [out] = submit(env, args="engine=claude label=next")
    assert rc == 3 and "already running" in out["error"]           # the recovered job counts
    env.run("status")
    assert len([r for r in env.audit() if r["op"] == "recover"]) == 1   # recovered once


def test_launch_timeout_recovers_detached_job_at_once(tmp_path):
    env = Env(tmp_path, extra_env=f'STUB_PID = "{os.getpid()}"\nSTUB_SLEEP = "20"')
    set_route(env, "max_brief_bytes = 1024", "max_brief_bytes = 1024\nlaunch_timeout_secs = 2")
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
        "name": "submit_job", "arguments": {"engine": "claude", "label": "late", "brief": "b"}}})
    body = json.loads(r[1]["result"]["content"][0]["text"])
    [record] = (tmp_path / "work/Admin").glob("*-late.json")
    assert r[1]["result"]["isError"]
    assert body["error"] == f"launch failed: TimeoutExpired; job {record.stem} did start, see job_status"
    assert [(a["op"], a["result"]) for a in env.audit()] == [
        ("submit", "launching"), ("recover", "ok"), ("submit", "error")]
    rows = index_rows(env)
    assert rows[1] == {"launch": rows[0]["launch"], "abandoned": True}
    assert rows[2] == {"launch": rows[0]["launch"], "id": record.stem, "recovered": True}
    rc, [st] = env.run(f"status job={record.stem}")
    assert rc == 0 and st["jobs"][0]["state"] == "running"


def _reserve(env, launcher, t=None):
    row = {"t": t or time.time(), "launch": "feedfacefeedface", "label": "inflight", "engine": "claude",
           "workdir": os.path.realpath(env.tmp / "work/Admin"),
           "cmd": [str(env.tmp / "bin/claude"), "-p", "--permission-mode", "acceptEdits"], "launcher": launcher}
    for d in ("state", "state/profiles"):            # as the route creates them (the sandbox umask is 0002)
        (env.tmp / d).mkdir(mode=0o700, exist_ok=True)
        (env.tmp / d).chmod(0o700)
    with (env.tmp / "state/profiles/grok-admin.jsonl").open("a") as f:
        f.write(json.dumps(row) + "\n")


def test_in_flight_launch_counts_toward_running_limit(tmp_path):
    env = Env(tmp_path, running=1)
    _reserve(env, jobroute_jobs._launcher())        # a live launcher (this test process) still launching
    rc, [out] = submit(env)
    assert rc == 3 and "already running" in out["error"] and env.calls() == []
    rc, [st] = env.run("status")
    assert st["jobs"][0]["job_id"] is None and st["jobs"][0]["state"] == "launching"


def test_dead_launcher_without_job_counts_per_hour_only(tmp_path):
    env = Env(tmp_path, per_hour=2, running=1)
    _reserve(env, {"pid": 2 ** 22 + 1, "start": 1})   # launcher gone, sb-codejob never wrote a status file
    rc, [st] = env.run("status")
    assert st["jobs"][0]["state"] == "unknown" and not [r for r in env.audit() if r["op"] == "recover"]
    assert submit(env)[0] == 0                        # not running: the running limit is free
    rc, [out] = submit(env, args="engine=claude label=third")
    assert rc == 3 and "per hour" in out["error"]     # but the reservation counts toward the hour


def test_failed_launch_reservation_is_closed(tmp_path):
    env = Env(tmp_path, extra_env='STUB_FAIL = "1"')
    assert submit(env)[0] == 1
    rows = index_rows(env)
    assert len(rows) == 2 and rows[1] == {"launch": rows[0]["launch"], "failed": "exit 1"}
    assert env.run("status")[1][0]["jobs"] == []


# ---------------------------------------------------------------- 5. misconfigured profile is audited
@pytest.mark.parametrize("old,new,needle", [
    ('bot = "Admin"\n', "", "needs bot"),
    ('agent = "Admin"\n', "", "is invalid (KeyError)"),
    ('agent = "Admin"\n', 'agent = ""\n', "needs agent"),
    ('workdirs = ["{tmp}/work/Admin"]', 'workdirs = ["{tmp}/work/Doc"]', "workdirs must be under"),
    ('workdirs = ["{tmp}/work/Admin"]', 'workdirs = ["{tmp}/work/Admin"]\nmax_per_hour = "x"',
     "is invalid (ValueError)"),
])
@pytest.mark.parametrize("protocol", ["cli", "mcp"])
def test_misconfigured_allowlisted_profile_refusal_is_audited(tmp_path, old, new, needle, protocol):
    env = Env(tmp_path)
    set_route(env, old.format(tmp=tmp_path), new.format(tmp=tmp_path))
    if protocol == "cli":
        rc, [out] = submit(env, brief=b"brief")
        assert rc == 1 and needle in out["error"]
    else:
        msg = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "submit_job", "arguments": {"engine": "claude", "label": "fix-login", "brief": "brief"}}}
        rc, [out] = env.run(None, json.dumps(msg).encode() + b"\n")   # no MCP server: one error line
        assert rc == 1 and needle in out["error"]
    [row] = env.audit()
    assert row["op"] == "connect" and row["result"] == "error" and needle in row["reason"]
    assert row["profile"] == "grok-admin" and row["label"] == "fix-login"
    assert row["brief_sha256"] == hashlib.sha256(b"brief").hexdigest()
    assert env.calls() == []
