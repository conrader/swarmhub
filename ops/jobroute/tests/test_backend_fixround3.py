"""Backend bounds regressions with synthetic children; never sends real signals."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace

import pytest


@pytest.mark.parametrize('failure', ['term', 'inspection', 'reap'])
def test_backend_failed_cleanup_is_bounded_incomplete_not_original_timeout(tmp_path, monkeypatch, failure):
    source = Path(os.environ.get('FIXROUND3_SOURCE', str(Path(__file__).parents[1])))
    sys.path.insert(0, str(source))
    try:
        spec = importlib.util.spec_from_file_location('fr3_backend', source / 'jobroute_commands.py')
        c = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(c)
    finally:
        sys.path.pop(0)
    assert hasattr(c, 'BackendCleanupIncomplete'), 'baseline has no incomplete cleanup result'
    life = c.lifecycle
    clock = [0]
    monkeypatch.setattr(life.time, 'monotonic', lambda: clock[0])
    monkeypatch.setattr(life.time, 'sleep', lambda delay: clock.__setitem__(0, clock[0] + delay))
    stream = (tmp_path / 'input').open('wb')
    def failed_reap(**kw):
        assert kw['timeout'] <= 5
        raise subprocess.TimeoutExpired('runner', 5)
    proc = SimpleNamespace(pid=123, stdin=stream, returncode=None, wait=failed_reap)
    monkeypatch.setattr(c.subprocess, 'Popen', lambda *a, **kw: proc)
    monkeypatch.setattr(life.Child, 'exited', lambda self: False)
    events = []
    def send(pid, sig):
        events.append(sig)
        if failure == 'term':
            raise PermissionError()
    monkeypatch.setattr(os, 'killpg', send)
    monkeypatch.setattr(life, 'membership', lambda *a: life.DRAINED if failure == 'reap' else life.UNKNOWN)
    with pytest.raises(c.BackendCleanupIncomplete):
        c.run_group(['fixture'], input=b'', stdout=None, env={}, cwd=None, timeout=0)
    assert clock[0] <= 7.1
    if failure != 'reap':
        assert events[0] == 15 and 9 in events
    assert proc.returncode is None
