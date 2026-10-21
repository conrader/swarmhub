"""jobroute guards (Jarvis 2026-10-21): per-bot workdir allowlist, production-path denylist,
brief size limit, audit of every submission and refusal, fixed claude flags.

Same harness as test_jobroute.py: the wrapper runs as sshd would run the forced command.
"""
from __future__ import annotations

import hashlib
import json
import os
import pathlib
import subprocess
import tomllib

import pytest

from test_jobroute import ROUTE, Env, mcp, submit

SHIPPED = pathlib.Path(__file__).resolve().parent.parent / "allowlist.toml"


@pytest.fixture
def env(tmp_path):
    e = Env(tmp_path)
    for d in ("prodrepo", "work/Admin/denied"):
        (tmp_path / d).mkdir(parents=True, exist_ok=True)
    (tmp_path / "work/Admin/to-prod").symlink_to(tmp_path / "prodrepo")
    (tmp_path / "work/Admin/to-etc").symlink_to("/etc")
    (tmp_path / "work/Admin/to-doc").symlink_to(tmp_path / "work/Doc")
    return e


def last_submit_row(env) -> dict:
    return [r for r in env.audit() if r["op"] in ("submit", "parse")][-1]


# ---------------------------------------------------------------- per-bot allowlist
def test_own_bot_workdir_ok_and_audited_with_workdir(env):
    rc, [out] = submit(env, args="engine=claude label=ok workdir=sub")
    assert rc == 0 and out["workdir"] == os.path.realpath(env.tmp / "work/Admin/sub")
    row = env.audit()[-1]
    assert row["result"] == "ok" and row["workdir"] == out["workdir"] and row["workdir_requested"] == "sub"


@pytest.mark.parametrize("wd", ["to-doc", "{tmp}/work/Doc", "{tmp}/work/Infra Caretaker"])
def test_other_bots_workdir_refused(env, wd):
    rc, [out] = env.run("submit engine=claude label=x workdir=" + wd.format(tmp=env.tmp).replace(" ", ""), b"b")
    assert rc == 2 and out["error"] == "workdir not allowed" and env.calls() == []


def test_mcp_other_bots_workdir_refused(env):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "submit_job",
                      "arguments": {"engine": "claude", "label": "x", "brief": "b",
                                    "workdir": f"{env.tmp}/work/Infra Caretaker"}}})
    assert json.loads(r[1]["result"]["content"][0]["text"])["error"] == "workdir not allowed"
    assert env.calls() == []


def test_profile_workdirs_must_lie_under_its_bot_dir(env):
    env.cfg.write_text(env.cfg.read_text().replace(f'workdirs = ["{env.tmp}/work/Admin"]',
                                                   f'workdirs = ["{env.tmp}/work/Doc"]'))
    rc, [out] = submit(env)
    assert rc == 1 and "workdirs must be under" in out["error"] and env.calls() == []


def test_profile_without_bot_is_misconfigured(env):
    env.cfg.write_text(env.cfg.read_text().replace('bot = "Admin"\n', ""))
    rc, [out] = submit(env)
    assert rc == 1 and "needs bot" in out["error"]


# ---------------------------------------------------------------- production paths
@pytest.mark.parametrize("wd", ["/etc", "/etc/ssh", "/var/www", "/var/www/html", "to-etc", "to-prod",
                                "escape", "{tmp}/prodrepo", "{tmp}/work/Admin/sub/../../../prodrepo"])
def test_prod_paths_refused(env, wd):
    rc, [out] = env.run("submit engine=claude label=x workdir=" + wd.format(tmp=env.tmp), b"b")
    assert rc == 2 and out["error"].startswith("workdir refused: production path"), out
    assert env.calls() == []


def test_denylist_wins_over_allowlist(env):
    rc, [out] = submit(env, args="engine=claude label=x workdir=denied")
    assert rc == 2 and out["error"] == "workdir refused: production path (denylisted)"
    assert last_submit_row(env)["workdir"] == os.path.realpath(env.tmp / "work/Admin/denied")


def test_bot_dir_symlinked_to_prod_refused(env):
    (env.tmp / "work/Doc").rmdir()
    (env.tmp / "work/Doc").symlink_to("/etc")
    rc, [out] = submit(env, profile="grok-doc")
    assert rc == 2 and "production path" in out["error"] and env.calls() == []


def test_home_outside_work_is_prod_by_default(env):
    env.cfg.write_text(env.cfg.read_text().replace(f'home = "{env.tmp}"\n', ""))
    rc, [out] = env.run("submit engine=claude label=x workdir=/home/ubuntu/thiswayup", b"b")
    assert rc == 2 and out["error"].startswith("workdir refused: production path (outside")


def test_mcp_nul_workdir_refused_not_crashed(env):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "submit_job",
                      "arguments": {"engine": "claude", "label": "x", "brief": "b", "workdir": "/etc\u0000x"}}})
    assert json.loads(r[1]["result"]["content"][0]["text"])["error"] == "workdir not allowed"


# ---------------------------------------------------------------- brief size
def test_oversize_brief_refused_clearly_and_audited_with_full_sha(env):
    brief = b"a" * 5000
    rc, [out] = submit(env, brief)
    assert rc == 2 and "larger than the 1024-byte limit (max_brief_bytes)" in out["error"]
    row = env.audit()[-1]
    assert row["result"] == "refused" and row["brief_bytes"] == 5000
    assert row["brief_sha256"] == hashlib.sha256(brief).hexdigest() and env.calls() == []


def test_mcp_oversize_brief_refused(env):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "submit_job",
                      "arguments": {"engine": "claude", "label": "big", "brief": "a" * 2000}}})
    assert "1024-byte limit" in r[1]["result"]["content"][0]["text"] and env.calls() == []
    assert env.audit()[-1]["brief_bytes"] == 2000


def test_brief_at_limit_accepted(env):
    assert submit(env, b"a" * 1024)[0] == 0


# ---------------------------------------------------------------- audit of every refusal
REFUSALS = [("engine=claude label=x workdir=/etc", "production path"),
            ("engine=claude label=x workdir=to-doc", "workdir not allowed"),
            ("engine=bash label=x workdir=sub", "engine must be"),
            ("engine=claude label=x;id workdir=sub", "command refused"),
            ("engine=claude label=x workdir=sub cmd=id", "argument refused")]


@pytest.mark.parametrize("args,reason", REFUSALS)
def test_every_refusal_logged_with_profile_ts_label_workdir_sha_outcome(env, args, reason):
    brief = b"refused brief\n"
    rc, [out] = submit(env, brief, args=args)
    assert rc == 2 and reason in out["error"]
    row = last_submit_row(env)
    assert row["profile"] == "grok-admin" and row["ts"] and row["result"] == "refused"
    assert row["label"].startswith("x") and row["workdir_requested"] in ("/etc", "to-doc", "sub")
    assert row["brief_sha256"] == hashlib.sha256(brief).hexdigest() and reason in row["reason"]


def test_refused_parse_with_empty_stdin_still_logged(env):
    rc, _ = env.run("submit engine=claude label=x>y", b"")
    row = last_submit_row(env)
    assert rc == 2 and row["op"] == "parse" and row["label"] == "x>y"
    assert row["brief_sha256"] == hashlib.sha256(b"").hexdigest()


# ---------------------------------------------------------------- engines
def test_shipped_engines_and_bot_map():
    cfg = tomllib.loads(SHIPPED.read_text())
    assert cfg["engines"]["claude"] == ["claude", "-p", "--permission-mode", "acceptEdits"]
    assert cfg["engines"]["codex"] == ["codex", "exec", "--skip-git-repo-check", "-m", "gpt-6.1-sol", "-"]
    assert not any("dangerously" in a for argv in cfg["engines"].values() for a in argv)
    assert len(cfg["profiles"]) == 12
    for name, prof in cfg["profiles"].items():
        root = f"/home/ubuntu/work/{prof['bot']}"
        assert all(w == root or w.startswith(root + "/") for w in prof["workdirs"]), name
    assert {"/var/www", "/etc"} <= set(cfg["route"]["deny_paths"])


def test_claude_argv_contains_accept_edits(env):
    assert submit(env)[0] == 0
    [call] = env.calls()
    cmd = call["argv"][call["argv"].index("--") + 1:]
    assert cmd == ["claude", "-p", "--permission-mode", "acceptEdits"]
    assert "--dangerously-skip-permissions" not in call["argv"]


# ---------------------------------------------------------------- audit gaps (verifier, 2026-10-21)
def test_mcp_non_string_tool_name_refused_and_audited(env):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                      "params": {"name": ["submit_job"], "arguments": {"label": "x"}}})
    assert r[1]["result"]["isError"] is True and "unknown tool" in r[1]["result"]["content"][0]["text"]
    row = env.audit()[-1]
    assert row["op"] == "parse" and row["result"] == "refused" and row["label"] == "x"


def test_mcp_oversized_line_audited(env):
    big = b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"submit_job","arguments":{"brief":"' \
        + b"a" * (2 << 20) + b'"}}}\n'
    rc, out = env.run(None, big + b'{"jsonrpc":"2.0","id":2,"method":"ping"}\n')
    assert rc == 0 and [o["id"] for o in out] == [2]
    row = env.audit()[-1]
    assert row["result"] == "refused" and "dropped" in row["reason"] and row["line_bytes"] == len(big)
    assert row["line_sha256"] == hashlib.sha256(big).hexdigest()


def test_cli_stdin_never_closed_refused_and_audited(env):
    env.cfg.write_text(env.cfg.read_text().replace("max_brief_bytes = 1024", "max_brief_bytes = 1024\nbrief_read_secs = 1"))
    p = subprocess.Popen([str(ROUTE), "--config", str(env.cfg), "--profile", "grok-admin"], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, env={"PATH": "/usr/bin:/bin",
                                                      "SSH_ORIGINAL_COMMAND": "submit engine=claude label=open"})
    p.stdin.write(b"partial brief")
    p.stdin.flush()
    out = json.loads(p.stdout.readline())
    p.stdin.close()
    assert p.wait(timeout=30) == 2 and "stdin not closed within 1 s" in out["error"] and env.calls() == []
    row = env.audit()[-1]
    assert row["result"] == "refused" and row["label"] == "open" and row["brief_hash_partial"] is True
    assert row["brief_sha256"] == hashlib.sha256(b"partial brief").hexdigest()


def test_cli_closed_stdin_refused_and_audited(env):
    p = subprocess.run(["/bin/sh", "-c", 'exec "$0" --config "$1" --profile grok-admin <&-', str(ROUTE), str(env.cfg)],
                       capture_output=True, timeout=30,
                       env={"PATH": "/usr/bin:/bin", "SSH_ORIGINAL_COMMAND": "submit engine=claude label=closed"})
    assert p.returncode == 2 and "empty" in json.loads(p.stdout)["error"]
    row = env.audit()[-1]
    assert row["result"] == "refused" and row["label"] == "closed" and row["brief_bytes"] == 0


def test_cli_brief_over_hash_cap_marked_partial(env):
    rc, [out] = submit(env, b"a" * ((16 << 20) + 10))
    row = env.audit()[-1]
    assert rc == 2 and "larger" in out["error"] and row["brief_bytes"] == 16 << 20 and row["brief_hash_partial"] is True


# ---------------------------------------------------------------- independent review regressions (fix2)
@pytest.mark.parametrize("protocol", ["cli", "mcp"])
@pytest.mark.parametrize("target", ["Doc", "Admin-real"])
def test_bot_root_symlink_cannot_redefine_boundary(env, protocol, target):
    # Reviewer's exact cross-bot repro: work/Admin -> work/Doc, unchanged allowlist.
    import shutil
    admin = env.tmp / "work/Admin"
    shutil.rmtree(admin)
    destination = env.tmp / "work" / target
    destination.mkdir(exist_ok=True)
    admin.symlink_to(destination, target_is_directory=True)
    if protocol == "cli":
        rc, [out] = submit(env, b"root link repro", args="engine=claude label=rootlink")
        assert rc == 2
    else:
        rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "submit_job", "arguments": {"engine": "claude", "label": "rootlink", "brief": "root link repro"}}})
        assert r[1]["result"]["isError"] is True
        out = json.loads(r[1]["result"]["content"][0]["text"])
    assert "bot root" in out["error"] and env.calls() == []
    row = env.audit()[-1]
    assert row["label"] == "rootlink" and row["result"] == "refused"
    assert row["brief_sha256"] == hashlib.sha256(b"root link repro").hexdigest()


@pytest.mark.parametrize("wd", ["/\ud800", "sub/\udfff", "/etc\0bad"])
def test_mcp_malformed_workdir_is_audited_refusal(env, wd):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
        "name": "submit_job", "arguments": {"engine": "claude", "label": "pathbad", "brief": "b", "workdir": wd}}})
    assert rc == 0 and r[1]["result"]["isError"] is True and env.calls() == []
    body = json.loads(r[1]["result"]["content"][0]["text"])
    assert "workdir not allowed" in body["error"] and "route error" not in body["error"]
    assert len(env.audit()) == 1
    row = env.audit()[0]
    assert row["result"] == "refused" and row["label"] == "pathbad" and row["workdir_requested"] == wd
    assert row["brief_sha256"] == hashlib.sha256(b"b").hexdigest()


@pytest.mark.parametrize("separator", ["\t", "\n", "\r", "\v"])
def test_cli_parse_refusal_retains_metadata_across_whitespace(env, separator):
    rc, _ = env.run(f"submit{separator}engine=claude label=tabbed workdir=sub", b"brief sha\n")
    assert rc == 2 and env.calls() == []
    row = env.audit()[-1]
    assert row["result"] == "refused" and row["label"] == "tabbed" and row["engine"] == "claude"
    assert row["workdir_requested"] == "sub" and row["workdir"] is None
    assert row["brief_sha256"] == hashlib.sha256(b"brief sha\n").hexdigest()


def test_parse_refusal_metadata_is_bounded(env):
    rc, _ = env.run("submit\tlabel=" + "l" * 200 + " workdir=" + "w" * 400, b"bounded")
    row = env.audit()[-1]
    assert rc == 2 and len(row["label"]) == 64 and len(row["workdir_requested"]) == 256
    assert row["brief_sha256"] == hashlib.sha256(b"bounded").hexdigest()


@pytest.mark.parametrize("protocol", ["cli", "mcp"])
def test_non_allowlisted_connect_keeps_supplied_metadata(env, protocol):
    if protocol == "cli":
        rc, _ = env.run("submit\tengine=claude label=unknown workdir=sub", b"denied", profile="grok-ermes")
    else:
        message = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "submit_job", "arguments": {"engine": "claude", "label": "unknown", "brief": "denied",
                                                   "workdir": "sub"}}}
        rc, _ = env.run(None, json.dumps(message).encode() + b"\n", profile="grok-ermes")
    assert rc == 2 and env.calls() == []
    row = env.audit()[-1]
    assert row["op"] == "connect" and row["result"] == "refused" and row["label"] == "unknown"
    assert row["workdir_requested"] == "sub" and row["brief_sha256"] == hashlib.sha256(b"denied").hexdigest()


@pytest.mark.parametrize("message,reason", [
    (b'{broken JSON}\n', "invalid JSON"),
    (b'"not an object"\n', "must be an object"),
    (b'[]\n', "must be an object"),
    (b'{"jsonrpc":"1.0","id":1,"method":"ping"}\n', "invalid MCP request"),
    (b'{"jsonrpc":"2.0","id":[],"method":"ping"}\n', "invalid MCP request"),
    (b'{"jsonrpc":"2.0","id":true,"method":"ping"}\n', "invalid MCP request"),
    (b'{"jsonrpc":"2.0","id":1,"method":[]}\n', "invalid MCP request"),
    (b'{"jsonrpc":"2.0","id":1,"method":"tools/call","params":[]}\n', "invalid MCP request"),
    (b'{"jsonrpc":"2.0","id":1,"method":"unknown"}\n', "unknown method"),
    (b'{"jsonrpc":"2.0","method":"notifications/unknown"}\n', "unknown method"),
])
def test_protocol_rejections_are_audited_and_session_continues(env, message, reason):
    rc, out = env.run(None, message + b'{"jsonrpc":"2.0","id":2,"method":"ping"}\n')
    assert rc == 0 and out[-1] == {"jsonrpc": "2.0", "id": 2, "result": {}}
    assert env.calls() == [] and len(env.audit()) == 1
    row = env.audit()[0]
    assert row["result"] == "refused" and reason in row["reason"]
    assert row["line_sha256"] == hashlib.sha256(message).hexdigest() and row["line_bytes"] == len(message)


def test_protocol_rejection_retains_submit_metadata(env):
    rc, _ = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "bogus", "params": {
        "arguments": {"engine": "claude", "label": "proto", "brief": "b", "workdir": "sub"}}})
    row = env.audit()[-1]
    assert row["label"] == "proto" and row["workdir_requested"] == "sub"
    assert row["brief_sha256"] == hashlib.sha256(b"b").hexdigest() and env.calls() == []


def test_eight_day_old_live_job_still_counts_toward_running_limit(tmp_path):
    import time
    e = Env(tmp_path, running=1, extra_env=f'STUB_PID = "{os.getpid()}"')
    assert submit(e)[0] == 0
    index = tmp_path / "state/profiles/grok-admin.jsonl"
    row = json.loads(index.read_text())
    row["t"] = time.time() - 8 * 86400
    index.write_text(json.dumps(row) + "\n")
    rc, [out] = submit(e)
    assert rc == 3 and "already running" in out["error"] and len(e.calls()) == 1
    assert e.run("status")[1][0]["jobs"][0]["state"] == "running"
    assert e.audit()[-2]["result"] == "rate_limited"


@pytest.mark.parametrize("args", [None, [], "", False])
def test_mcp_falsey_non_object_arguments_are_refused_and_audited(env, args):
    rc, r = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
        "name": "submit_job", "arguments": args}})
    assert rc == 0 and r[1]["result"]["isError"] is True and env.calls() == []
    row = env.audit()[-1]
    assert row["result"] == "refused" and row["reason"] == "arguments must be an object"
