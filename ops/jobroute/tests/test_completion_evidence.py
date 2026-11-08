"""Completion evidence: `state` still says "done" for every ended job, while the additive
outcome/signal/review_verdict/artifacts fields tell success, failure and missing report apart.

Recording backends only; run through tests/run-sandbox.sh in the sbtest PID namespace.
"""
import json
import os

import pytest

from test_jobroute import Env, env, mcp, submit  # noqa: F401 (env is a fixture)
from test_jobroute_p2 import index_rows

FIELDS = ("outcome", "signal", "review_verdict", "artifacts")


def enable_launch(env):
    env.cfg.write_text(env.cfg.read_text().replace(
        '[profiles.grok-admin]', '[profiles.grok-admin]\nenabled_verbs=["launch"]'))


def launched(env, label="evidence"):
    enable_launch(env)
    rc, [body] = env.run("launch", json.dumps({"engine": "claude", "label": label, "brief": "Fixture"}).encode())
    assert rc == 0, body
    return body["job_id"]


def submitted(env, label="evidence"):
    rc, [body] = submit(env, args=f"engine=claude label={label}")
    assert rc == 0, body
    return body["job_id"]


def status(env, job_id):
    rc, [st] = env.run(f"status job={job_id}")
    assert rc == 0, st
    [job] = st["jobs"]
    return job


def patch_record(env, job_id, **fields):
    path = env.tmp / "work/Admin" / f"{job_id}.json"
    rec = json.loads(path.read_text())
    rec.update(fields)
    path.write_text(json.dumps(rec))


def artifact(env, job_id, suffix, text="x"):
    path = env.tmp / "work/Admin" / f"{job_id}{suffix}"
    path.write_text(text)
    return path


def test_submit_success_without_report_request(env):
    job = status(env, submitted(env))
    assert job["state"] == "done" and job["exit_code"] == 0
    assert job["outcome"] == "success" and job["signal"] is None and job["review_verdict"] is None
    assert job["artifacts"] == {"log": False, "report": False, "report_expected": False}


def test_reservation_records_operation(env):
    submitted(env, "plain")
    launched(env, "asked")
    ops = [r.get("operation") for r in index_rows(env) if "t" in r]
    assert ops == ["submit", "launch"]


def test_launch_without_report_is_missing_report_then_success(env):
    job_id = launched(env)
    job = status(env, job_id)
    assert job["state"] == "done" and job["exit_code"] == 0
    assert job["outcome"] == "missing_report"
    assert job["artifacts"] == {"log": False, "report": False, "report_expected": True}
    artifact(env, job_id, ".log")
    artifact(env, job_id, "-report.md", "# Report\nchanges, tests\n")
    job = status(env, job_id)
    assert job["outcome"] == "success" and job["artifacts"] == {"log": True, "report": True, "report_expected": True}


def test_empty_symlinked_or_directory_report_is_not_evidence(env):
    job_id = launched(env)
    report = artifact(env, job_id, "-report.md", "")
    assert status(env, job_id)["outcome"] == "missing_report"
    report.unlink()
    target = env.tmp / "outside/report.md"
    target.write_text("looks real")
    report.symlink_to(target)
    job = status(env, job_id)
    assert job["outcome"] == "missing_report" and job["artifacts"]["report"] is False
    report.unlink()
    report.mkdir()
    assert status(env, job_id)["outcome"] == "missing_report"


@pytest.mark.parametrize("op", ["submit", "launch"])
@pytest.mark.parametrize("code,sig", [(1, None), (2, None), (127, None), (128, None), (130, 2), (137, 9),
                                      (143, 15), (192, 64), (193, None), (-1, None)])
def test_nonzero_exit_is_failure_even_with_report(env, op, code, sig):
    job_id = (launched if op == "launch" else submitted)(env)
    artifact(env, job_id, "-report.md")
    patch_record(env, job_id, exit_code=code)
    job = status(env, job_id)
    assert job["state"] == "done" and job["exit_code"] == code
    assert job["outcome"] == "failure" and job["signal"] == sig


@pytest.mark.parametrize("value", [None, "0", 0.0, True, [0]])
def test_ended_without_integer_exit_is_unknown(env, value):
    job_id = submitted(env)
    patch_record(env, job_id, exit_code=value)
    job = status(env, job_id)
    assert job["state"] == "done" and job["outcome"] == "unknown" and job["signal"] is None


@pytest.mark.parametrize("verdict,shown", [("PASS", "PASS"), ("CONCERNS", "CONCERNS"), ("FAIL", "FAIL"),
                                           ("fail", None), ("PASS: ok", None), (1, None)])
def test_review_verdict_reported_without_changing_outcome(env, verdict, shown):
    job_id = launched(env)
    artifact(env, job_id, "-report.md")
    patch_record(env, job_id, review="failed", review_verdict=verdict)
    job = status(env, job_id)
    assert job["review"] == "failed" and job["review_verdict"] == shown and job["outcome"] == "success"


def test_running_job_has_no_outcome(tmp_path):
    env = Env(tmp_path, extra_env=f'STUB_PID = "{os.getpid()}"')
    job = status(env, submitted(env))
    assert job["state"] == "running" and job["outcome"] is None and job["signal"] is None


def test_lost_job_has_no_outcome(env):
    job_id = submitted(env)
    patch_record(env, job_id, ended=None, exit_code=None, pid=999999999)
    job = status(env, job_id)
    assert job["state"] == "lost" and job["outcome"] is None


def test_legacy_reservation_without_operation(env):
    job_id = launched(env)
    index = env.tmp / "state/profiles/grok-admin.jsonl"
    rows = [json.loads(x) for x in index.read_text().splitlines()]
    for r in rows:
        r.pop("operation", None)
    index.write_text("".join(json.dumps(r) + "\n" for r in rows))
    job = status(env, job_id)
    assert job["outcome"] == "success" and job["artifacts"]["report_expected"] is None


def test_unresolved_reservation_has_empty_evidence(env):
    assert env.run("status")[0] == 0         # the route creates its private state directories
    index = env.tmp / "state/profiles/grok-admin.jsonl"
    # A reservation whose launcher is gone and whose status file never appeared.
    index.write_text(json.dumps({"t": 1.0, "launch": "00ff", "label": "lost-launch", "engine": "claude",
                                 "workdir": str(env.tmp / "work/Admin"), "cmd": ["claude"],
                                 "launcher": {"pid": 1, "start": -1}, "operation": "launch"}) + "\n")
    index.chmod(0o600)
    rc, [st] = env.run("status")
    assert rc == 0, st
    [job] = st["jobs"]
    assert job["state"] == "unknown" and job["job_id"] is None
    assert job["outcome"] is None and job["artifacts"] == {"log": False, "report": False, "report_expected": True}


def test_mcp_job_status_carries_evidence(env):
    job_id = launched(env)
    patch_record(env, job_id, exit_code=137)
    rc, rows = mcp(env, {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                        "params": {"name": "job_status", "arguments": {"job_id": job_id}}})
    assert rc == 0 and not rows[1]["result"]["isError"]
    [job] = json.loads(rows[1]["result"]["content"][0]["text"])["jobs"]
    assert job["state"] == "done" and job["outcome"] == "failure" and job["signal"] == 9
    assert set(FIELDS) <= set(job)


def test_existing_summary_fields_unchanged(env):
    job = status(env, submitted(env))
    for key in ("job_id", "label", "engine", "state", "started", "ended", "exit_code",
                "minutes", "model", "review", "wake"):
        assert key in job
