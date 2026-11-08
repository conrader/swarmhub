"""A launcher receipt is not evidence that no detached job started.

Recording backends only; run through tests/run-sandbox.sh in the sbtest PID namespace.
"""
import json
import os

import pytest

from test_jobroute import Env, mcp, submit
from test_jobroute_p2 import index_rows
from jobroute_core import Refused, Route
import jobroute_core


def launch(env, protocol):
    args = {"engine": "claude", "label": "receipt", "brief": "Fixture job"}
    if protocol == "cli":
        rc, [body] = submit(env, args="engine=claude label=receipt")
        assert rc == 1
        return body
    if protocol == "launch":
        rc, [body] = env.run("launch", json.dumps(args).encode())
        assert rc == 1
        return body
    rc, rows = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                        "params": {"name": "submit_job", "arguments": args}})
    assert rc == 0 and rows[1]["result"]["isError"]
    return json.loads(rows[1]["result"]["content"][0]["text"])


@pytest.mark.parametrize("protocol", ["cli", "mcp", "launch"])
@pytest.mark.parametrize("receipt,exit_code", [
    ("normal", 1), ("missing", 1), ("missing", 0), ("empty", 0), ("foreign", 0),
    ("duplicate", 0), ("nul", 0), ("extension", 0),
])
@pytest.mark.parametrize("running", [False, True])
def test_bad_receipt_recovers_existing_job_without_relaunch(tmp_path, protocol, receipt, exit_code, running):
    extra = f'STUB_RECEIPT = "{receipt}"\nSTUB_EXIT = "{exit_code}"'
    if running:
        extra += f'\nSTUB_PID = "{os.getpid()}"'
    env = Env(tmp_path, running=1, extra_env=extra)
    env.cfg.write_text(env.cfg.read_text().replace(
        '[profiles.grok-admin]', '[profiles.grok-admin]\nenabled_verbs=["launch"]'))
    body = launch(env, protocol)
    [record] = (tmp_path / "work/Admin").glob("*-receipt.json")
    assert f"job {record.stem} did start, see job_status" in body["error"]
    for _ in range(2):
        rc, [status] = env.run(f"status job={record.stem}")
        assert rc == 0
        [job] = status["jobs"]
        assert job["state"] == ("running" if running else "done")
        assert job["exit_code"] == (None if running else 0)
    rows = index_rows(env)
    assert not any("failed" in row for row in rows)
    assert rows[-1] == {"launch": rows[0]["launch"], "id": record.stem, "recovered": True}
    assert len([row for row in env.audit() if row["op"] == "recover"]) == 1
    assert env.run(f"status job={record.stem}", profile="grok-doc")[0] == 2
    if running:
        rc, [refused] = submit(env, args="engine=claude label=another")
        assert rc == 3 and "already running" in refused["error"]
    assert len(env.calls()) == 1


def test_missing_receipt_can_recover_record_on_a_later_status(tmp_path, monkeypatch):
    env = Env(tmp_path, extra_env='STUB_RECEIPT = "missing"')
    route = Route(str(env.cfg), "grok-admin")
    original = route._find_record
    # The record is unavailable to the immediate lookup, as with a delayed publish.
    monkeypatch.setattr(route, "_find_record", lambda *args: None)
    with pytest.raises(Refused, match="see job_status"):
        route.submit("cli", "claude", "receipt", None, b"fixture")
    [pending] = route.status("cli")["jobs"]
    assert pending["state"] == "unknown" and pending["job_id"] is None
    monkeypatch.setattr(route, "_find_record", original)
    [job] = route.status("cli")["jobs"]
    assert job["job_id"] and job["state"] == "done"
    assert len(env.calls()) == 1


def test_exec_failure_before_launcher_starts_closes_reservation(tmp_path, monkeypatch):
    env = Env(tmp_path)
    route = Route(str(env.cfg), "grok-admin")

    def unavailable(*args, **kwargs):
        raise FileNotFoundError("fixture launcher disappeared")

    monkeypatch.setattr(jobroute_core.subprocess, "run", unavailable)
    with pytest.raises(Refused, match="launch failed: FileNotFoundError"):
        route.submit("cli", "claude", "receipt", None, b"fixture")
    assert route.status("cli")["jobs"] == []
    assert index_rows(env)[-1]["failed"] == "FileNotFoundError"
    assert env.calls() == []
