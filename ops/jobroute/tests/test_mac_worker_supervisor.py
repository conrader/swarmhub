"""Supervisor contract checks with synthetic PIDs and mocked signals only."""
import importlib.util
import json
from pathlib import Path
import signal
import subprocess
from types import SimpleNamespace


def worker_module():
    spec = importlib.util.spec_from_file_location('supervisor_worker', Path(__file__).parents[1] / 'mac-worker.py')
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    return worker


def test_deadline_drains_workload_before_stopping_lock_holder(tmp_path, monkeypatch):
    worker = worker_module()
    control = tmp_path / 'control'
    control.write_text(json.dumps({'pgid': 222}))
    events = []
    def wait(timeout=None):
        if timeout is not None:
            raise subprocess.TimeoutExpired('runner', timeout)
        return -9
    proc = SimpleNamespace(pid=111, wait=wait, poll=lambda: None, returncode=-9)
    def launch(argv, **kw):
        assert kw['start_new_session'] is True
        return proc
    monkeypatch.setattr(worker.subprocess, 'Popen', launch)
    monkeypatch.setattr(worker, 'GRACE', .01)
    monkeypatch.setattr(worker, '_signal', lambda pgid, sig: events.append(('signal', pgid, sig)))
    drains = iter([False, True, True])
    def drain(pgid, deadline):
        events.append(('drain', pgid))
        return next(drains)
    monkeypatch.setattr(worker, '_drain', drain)
    monkeypatch.setattr(worker, '_alive', lambda pgid: True)
    result = worker._bounded(['runner'], 1, workload_control=control)
    assert result.timed_out
    assert json.loads(control.read_text())['cancelled'] is True
    assert events == [('signal', 222, signal.SIGTERM), ('drain', 222),
                      ('signal', 222, signal.SIGKILL), ('drain', 222),
                      ('signal', 111, signal.SIGTERM), ('signal', 111, signal.SIGKILL), ('drain', 111)]


def test_cancelled_queued_command_cannot_launch(tmp_path, monkeypatch):
    worker = worker_module()
    control = tmp_path / 'control'
    control.write_text('{"cancelled": true}')
    def forbidden(*args, **kwargs):
        raise AssertionError('cancelled work launched')
    monkeypatch.setattr(worker.subprocess, 'Popen', forbidden)
    assert worker._workload(control, ['work']) == 124


def test_supervisor_records_session_and_waits_for_descendants(tmp_path, monkeypatch):
    worker = worker_module()
    control = tmp_path / 'control'
    control.write_text('{}')
    monkeypatch.setattr(worker.subprocess, 'Popen', lambda argv, **kw:
                        SimpleNamespace(pid=222, wait=lambda: -15) if kw['start_new_session'] else None)
    live = iter([True, False])
    monkeypatch.setattr(worker, '_alive', lambda pgid: next(live))
    assert worker._workload(control, ['work']) == 143
    assert json.loads(control.read_text()) == {'pgid': 222}


def test_cleanup_error_preserves_workspace(tmp_path):
    import pytest
    worker = worker_module()
    def failed_drain(*args, **kwargs):
        raise OSError('cannot confirm drain')
    with pytest.raises(OSError, match='cannot confirm drain'):
        worker.run({'operation': 'macjob', 'agent': 'Admin', 'label': 'keep', 'brief': 'brief'},
                   home=tmp_path, execute=failed_drain)
    [workspace] = (tmp_path / 'work/swarmhub-jobs').iterdir()
    assert (workspace / '.workload.json').exists()
