"""jobroute tests: the wrapper is called the way sshd calls a forced command, with
SSH_ORIGINAL_COMMAND set and the brief on stdin. sb-codejob is a recording stub, except in
the one integration test that drives a copy of the real sb-codejob with a stub engine.

Run on ovh inside the sandbox: tests/run-sandbox.sh (sudo -u sbtest -- unshare -r -p -f --mount-proc ...).
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import time

import pytest

HERE = pathlib.Path(__file__).resolve().parent
ROUTE = HERE.parent / "jobroute"
STUB = HERE / "stub-sb-codejob"
STUB_ENGINE = HERE / "stub-engine"

CONFIG = """
[route]
submissions_enabled = true
state_dir = "{tmp}/state"
sb_codejob = "{sb_codejob}"
job_root = "{tmp}/work"
work_root = "{tmp}/work"
home = "{tmp}"
deny_paths = ["{tmp}/work/Admin/denied"]
path = "{tmp}/bin:/usr/bin:/bin"
max_brief_bytes = 1024
[route.env]
STUB_RECORD = "{tmp}/calls"
STUB_WORKROOT = "{tmp}/work"
HOME = "{tmp}/home"
{extra_env}
[engines]
claude = ["claude", "-p", "--permission-mode", "acceptEdits"]
codex = ["codex", "exec", "--skip-git-repo-check", "-m", "gpt-6.1-sol", "-"]
stub = ["{stub_engine}"]
[defaults]
submissions_enabled = true
engines = ["claude", "codex"]
max_per_hour = {per_hour}
max_per_day = 20
max_running = {running}
[profiles.grok-admin]
agent = "Admin"
bot = "Admin"
workdirs = ["{tmp}/work/Admin"]
[profiles.grok-doc]
agent = "Doc"
bot = "Doc"
workdirs = ["{tmp}/work/Doc"]
[profiles.grok-infra]
agent = "Infra Caretaker"
bot = "Infra Caretaker"
workdirs = ["{tmp}/work/Infra Caretaker"]
[profiles.grok-stub]
agent = "Stub"
bot = "Stub"
engines = ["stub"]
workdirs = ["{tmp}/work/Stub"]
"""


class Env:
    def __init__(self, tmp: pathlib.Path, per_hour=4, running=2, extra_env="", sb_codejob=STUB):
        self.tmp = tmp
        for d in ("calls", "home", "work/Admin/sub", "work/Doc", "work/Stub", "work/Infra Caretaker", "outside"):
            (tmp / d).mkdir(parents=True, exist_ok=True)
        (tmp / "work/Admin/escape").symlink_to(tmp / "outside")
        # Engines resolve on the route PATH, which the pre-launch trust check covers.
        (tmp / "bin").mkdir(mode=0o755, exist_ok=True)
        for name in ("claude", "codex"):
            shutil.copyfile(STUB_ENGINE, tmp / "bin" / name)
            (tmp / "bin" / name).chmod(0o755)
        self.cfg = tmp / "allowlist.toml"
        self.cfg.write_text(CONFIG.format(tmp=tmp, sb_codejob=sb_codejob, stub_engine=STUB_ENGINE,
                                          per_hour=per_hour, running=running, extra_env=extra_env))
        self.cfg.chmod(0o644)

    def run(self, cmd: str | None, stdin: bytes = b"", profile="grok-admin"):
        env = {"PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "must-not-leak",
               "SSH_CONNECTION": "195.201.33.222 50000 145.239.94.119 49123"}
        if cmd is not None:
            env["SSH_ORIGINAL_COMMAND"] = cmd
        p = subprocess.run([str(ROUTE), "--config", str(self.cfg), "--profile", profile],
                           input=stdin, capture_output=True, env=env, timeout=60)
        lines = p.stdout.decode().splitlines()
        return p.returncode, [json.loads(x) for x in lines]

    def calls(self) -> list[dict]:
        out = []
        for f in sorted((self.tmp / "calls").glob("*.json"), key=os.path.getmtime):
            rec = json.loads(f.read_text())
            rec["stdin"] = f.with_suffix(".stdin").read_bytes()
            out.append(rec)
        return out

    def audit(self) -> list[dict]:
        p = self.tmp / "state/audit.jsonl"
        return [json.loads(x) for x in p.read_text().splitlines()] if p.exists() else []


@pytest.fixture
def env(tmp_path):
    return Env(tmp_path)


def submit(env, brief=b"Fix the login test.\n", args="engine=claude label=fix-login", **kw):
    return env.run(f"submit {args}", brief, **kw)


# ---------------------------------------------------------------- happy paths
def test_allowlisted_submit_runs_fixed_argv_with_brief_on_stdin(env):
    brief = b"Brief with $(touch /tmp/pwned) `id`; rm -rf / && echo\n\"quoted\" 'x'\n"
    rc, [out] = submit(env, brief)
    assert rc == 0 and out["ok"] and out["agent"] == "Admin"
    [call] = env.calls()
    wd = os.path.realpath(env.tmp / "work/Admin")
    assert call["argv"] == ["--agent", "Admin", "--workdir", wd, "--label", "fix-login", "--stdin",
                            "--", str(env.tmp / "bin/claude"), "-p", "--permission-mode", "acceptEdits"]
    assert call["stdin"] == brief
    assert "ANTHROPIC_API_KEY" not in call["env"] and "SSH_ORIGINAL_COMMAND" not in call["env"]
    assert not pathlib.Path("/tmp/pwned").exists()
    launching, row = env.audit()
    assert launching["result"] == "launching" and launching["launch"] == row["launch"]
    assert launching["brief_sha256"] == row["brief_sha256"]
    assert row["profile"] == "grok-admin" and row["label"] == "fix-login" and row["result"] == "ok"
    assert row["brief_sha256"] == hashlib.sha256(brief).hexdigest() and row["ts"]
    assert row["peer"] == "195.201.33.222" and row["job_id"] == out["job_id"]


def test_codex_engine_and_subdirectory(env):
    rc, [out] = submit(env, args="engine=codex label=refactor workdir=sub")
    assert rc == 0
    argv = env.calls()[0]["argv"]
    assert argv[3] == os.path.realpath(env.tmp / "work/Admin/sub")
    assert argv[argv.index("--") + 1:] == [str(env.tmp / "bin/codex"), "exec", "--skip-git-repo-check", "-m",
                                           "gpt-6.1-sol", "-"]


def test_absolute_workdir_inside_root_and_matching_agent(env):
    rc, _ = submit(env, args=f"engine=claude label=x workdir={env.tmp}/work/Admin/sub agent=admin")
    assert rc == 0


def test_status_lists_only_own_jobs(env):
    _, [a] = submit(env)
    _, [d] = submit(env, profile="grok-doc", args="engine=claude label=doc-job")
    rc, [st] = env.run("status")
    assert rc == 0 and [j["job_id"] for j in st["jobs"]] == [a["job_id"]]
    assert st["jobs"][0]["state"] == "done" and st["jobs"][0]["exit_code"] == 0
    rc, [one] = env.run(f"status job={a['job_id']}")
    assert rc == 0 and one["jobs"][0]["label"] == "fix-login"
    rc, [other] = env.run(f"status job={d['job_id']}")         # Doc's job, asked by Admin
    assert rc == 2 and other["error"] == "unknown job"
    rc, [lst] = env.run("list limit=1")
    assert rc == 0 and len(lst["jobs"]) == 1


def test_agent_name_with_space(env):
    rc, [out] = submit(env, profile="grok-infra", args="engine=codex label=infra-job agent=infra-caretaker")
    assert rc == 0 and out["agent"] == "Infra Caretaker"
    rc, [st] = env.run(f"status job={out['job_id']}", profile="grok-infra")
    assert rc == 0 and st["jobs"][0]["state"] == "done"


def test_mcp_oversized_line_dropped_session_continues(env):
    big = b'{"jsonrpc":"2.0","id":1,"method":"tools/list","pad":"' + b"a" * (1 << 20) + b'"}\n'
    rc, out = env.run(None, big + b'{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n')
    assert rc == 0 and [o["id"] for o in out] == [2]


def test_help(env):
    rc, [out] = env.run("help")
    assert rc == 0 and out["engines"] == ["claude", "codex"]


# ---------------------------------------------------------------- refusals
def test_non_allowlisted_profile_refused(env):
    for profile in ("grok-ermes", "grok-jarvis", "../grok-admin", "GROK-ADMIN", ""):
        rc, [out] = submit(env, profile=profile)
        assert rc == 2 and out["error"] == "profile not allowlisted", profile
    assert env.calls() == []
    assert {r["result"] for r in env.audit()} == {"refused"}


ESCAPES = [
    "submit engine=claude label=x;id",
    "submit engine=claude label=x ; id",
    "submit engine=claude label=$(id)",
    "submit engine=claude label=`id`",
    "submit engine=claude label=x\nid",
    "submit engine=claude label=x\rid",
    "submit engine=claude label=x|id",
    "submit engine=claude label=x&&id",
    "submit engine=claude label='x'",
    "submit engine=claude label=\"x\"",
    "submit engine=claude label=x>out",
    "submit engine=claude label=${IFS}x",
    "submit engine=claude\tlabel=x",
    "submit engine=claude label=x --",
    "submit -- engine=claude label=x",
    "submit --workdir=/etc engine=claude label=x",
    "submit engine=claude label=--help",
    "submit engine=claude label=-x",
    "submit engine=claude label=x -- sh -c id",
    "submit engine=claude label=x engine=codex",
    "submit engine=claude label=x cmd=id",
    "submit engine=bash label=x",
    "submit engine=stub label=x",
    "submit engine=claude label=../x",
    "submit engine=claude label=x/y",
    "submit engine=claude label=x.y",
    "submit engine=claude label=x workdir=..",
    "submit engine=claude label=x workdir=../Doc",
    "submit engine=claude label=x workdir=sub/../..",
    "submit engine=claude label=x workdir=sub/../../../outside",
    "submit engine=claude label=x workdir=/etc",
    "submit engine=claude label=x workdir=/",
    "submit engine=claude label=x workdir=.hidden",
    "submit engine=claude label=x workdir=escape",
    "submit engine=claude label=x workdir=missing",
    "submit engine=claude label=x agent=Doc",
    "submit engine=claude label=" + "a" * 41,
    "submit label=x",
    "sh -c id",
    "bash",
    "id",
    "sftp",
    "internal-sftp",
    "scp -t /tmp",
    "rsync --server -e.LsfxC . /tmp",
    "git-upload-pack /home/ubuntu/sb",
    "status job=../../etc/passwd",
    "status job=x;id",
    "status limit=1000",
    "status limit=-1",
    "status x=y",
    "mcp; id",
    "help me",
    "x" * 600,
]


@pytest.mark.parametrize("cmd", ESCAPES)
def test_escape_attempts_refused(env, cmd):
    rc, out = env.run(cmd, b"brief")
    assert rc == 2 and out[0]["ok"] is False, (cmd, out)
    assert env.calls() == []
    assert env.audit() and env.audit()[-1]["result"] == "refused"


def test_relative_dotdot_absolute_path_refused(env):
    rc, [out] = submit(env, args=f"engine=claude label=x workdir={env.tmp}/work/Admin/../Doc")
    assert rc == 2 and env.calls() == []


@pytest.mark.parametrize("brief,reason", [(b"", "empty"), (b"  \n", "empty"), (b"a" * 1025, "larger"),
                                          (b"a\0b", "NUL"), (b"\xff\xfe", "UTF-8")])
def test_bad_briefs_refused(env, brief, reason):
    rc, [out] = submit(env, brief)
    assert rc == 2 and reason in out["error"] and env.calls() == []


def test_untrusted_config_refused(env):
    env.cfg.chmod(0o666)
    rc, [out] = submit(env)
    assert rc == 1 and "misconfigured" in out["error"] and env.calls() == []


def test_launch_failure_reported_and_audited(tmp_path):
    e = Env(tmp_path, extra_env='STUB_FAIL = "1"')
    rc, [out] = submit(e)
    assert rc == 1 and "launch failed" in out["error"]
    assert e.audit()[-1]["result"] == "error"
    rc, [st] = e.run("status")
    assert st["jobs"] == []


# ---------------------------------------------------------------- rate limit
def test_rate_limit_per_hour(tmp_path):
    e = Env(tmp_path, per_hour=2)
    assert submit(e)[0] == 0 and submit(e)[0] == 0
    rc, [out] = submit(e)
    assert rc == 3 and "per hour" in out["error"]
    assert len(e.calls()) == 2 and e.audit()[-1]["result"] == "rate_limited"
    rc, _ = submit(e, profile="grok-doc", args="engine=claude label=other")   # per profile
    assert rc == 0


def test_rate_limit_running_jobs(tmp_path):
    e = Env(tmp_path, running=1, extra_env=f'STUB_PID = "{os.getpid()}"')
    assert submit(e)[0] == 0
    rc, [out] = submit(e)
    assert rc == 3 and "already running" in out["error"]
    assert e.run("status")[1][0]["jobs"][0]["state"] == "running"


# ---------------------------------------------------------------- MCP mode
def mcp(env, *msgs, profile="grok-admin", cmd=None):
    stdin = b"".join(json.dumps(m).encode() + b"\n" for m in msgs)
    rc, out = env.run(cmd, stdin, profile=profile)
    return rc, {o["id"]: o for o in out}


def test_mcp_session(env):
    rc, r = mcp(env,
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2024-11-05"}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "submit_job", "arguments": {
                    "engine": "codex", "label": "mcp-job", "brief": "Do $(id) `x`\nthing"}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "job_status", "arguments": {}}},
                {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "shell", "arguments": {}}},
                {"jsonrpc": "2.0", "id": 6, "method": "tools/call", "params": {"name": "submit_job", "arguments": {
                    "engine": "claude", "label": "x", "brief": "b", "command": "id"}}},
                {"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": {"name": "submit_job", "arguments": {
                    "engine": "claude", "label": "x", "brief": "b", "workdir": "../../.."}}},
                {"jsonrpc": "2.0", "id": 8, "method": "tools/call", "params": {"name": "submit_job", "arguments": {
                    "engine": "claude", "label": "x", "brief": ["not", "text"]}}},
                {"jsonrpc": "2.0", "id": 9, "method": "resources/list"})
    assert rc == 0
    assert r[1]["result"]["serverInfo"]["name"] == "jobroute"
    assert [t["name"] for t in r[2]["result"]["tools"]] == ["submit_job", "job_status"]
    sub = json.loads(r[3]["result"]["content"][0]["text"])
    assert r[3]["result"]["isError"] is False and sub["ok"]
    assert env.calls()[0]["stdin"] == b"Do $(id) `x`\nthing"
    st = json.loads(r[4]["result"]["content"][0]["text"])
    assert [j["job_id"] for j in st["jobs"]] == [sub["job_id"]]
    for i in (5, 6, 7, 8):
        assert r[i]["result"]["isError"] is True, i
    assert r[9]["error"]["code"] == -32601
    assert len(env.calls()) == 1
    assert [(a["mode"], a["result"]) for a in env.audit() if a["op"] == "submit"] == [
        ("mcp", "launching"), ("mcp", "ok"), ("mcp", "refused")]


def test_mcp_lone_surrogate_brief_refused_and_audited(env):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "submit_job",
                      "arguments": {"engine": "claude", "label": "sur", "brief": "x\ud800"}}})
    assert rc == 0 and r[1]["result"]["isError"] is True and env.calls() == []
    row = env.audit()[-1]
    assert row["op"] == "submit" and row["result"] == "refused" and row["label"] == "sur" and row["brief_sha256"]


def test_mcp_bad_arguments_audited_with_sha(env):
    mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "submit_job",
              "arguments": {"engine": "claude", "label": "x", "brief": "b", "command": "id"}}})
    row = env.audit()[-1]
    assert row["result"] == "refused" and row["label"] == "x"
    assert row["brief_sha256"] == hashlib.sha256(b"b").hexdigest()


def test_mcp_also_via_explicit_command(env):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, cmd="mcp")
    assert rc == 0 and len(r[1]["result"]["tools"]) == 2


def test_mcp_non_allowlisted_profile_gets_no_server(env):
    rc, out = env.run(None, b'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\n', profile="grok-ermes")
    assert rc == 2 and out == [{"ok": False, "error": "profile not allowlisted"}]


# ---------------------------------------------------------------- real sb-codejob, stub engine
SB_COPY = os.environ.get("JOBROUTE_SB_COPY")   # dir with bin/sb-codejob(+watch) and lib/sbscan/


@pytest.mark.skipif(not SB_COPY, reason="set JOBROUTE_SB_COPY to a copy of ~/sb/{bin,lib/sbscan}")
@pytest.mark.parametrize("label", ["integ", "task_", "task-", "task_-_"])
def test_real_sb_codejob_with_stub_engine(tmp_path, label):
    extra = (f'SB_CODEJOB_WORKROOT = "{tmp_path}/work"\nSB_CODEJOB_MODELS_LOG = "{tmp_path}/models.log"\n'
             f'SB_CODEJOB_WAKE_ENV = "{tmp_path}/no-wake.env"\nSB_CODEJOB_STATE_DIR = "{tmp_path}/cj-state"')
    e = Env(tmp_path, extra_env=extra, sb_codejob=pathlib.Path(SB_COPY) / "bin/sb-codejob")
    brief = b"Integration brief $(id) ; `x`\n"
    rc, [out] = e.run(f"submit engine=stub label={label}", brief, profile="grok-stub")
    assert rc == 0, out
    assert out["label"] == label and out["job_id"].endswith("-" + label.rstrip("-_"))
    status = tmp_path / "work/Stub" / f"{out['job_id']}.json"
    for _ in range(100):
        rec = json.loads(status.read_text())
        if rec.get("ended"):
            break
        time.sleep(0.1)
    assert rec["ended"] and rec["exit_code"] == 0 and rec["wake"] == "dormant", rec
    log = pathlib.Path(rec["log"]).read_text()
    assert f"stub-engine brief sha256: {hashlib.sha256(brief).hexdigest()}" in log
    rc, [st] = e.run(f"status job={out['job_id']}", profile="grok-stub")
    assert rc == 0 and st["jobs"][0]["state"] == "done" and st["jobs"][0]["exit_code"] == 0
    assert st["jobs"][0]["label"] == label
    assert e.audit()[0]["brief_sha256"] == hashlib.sha256(brief).hexdigest()
    shutil.rmtree(tmp_path / "work", ignore_errors=True)
