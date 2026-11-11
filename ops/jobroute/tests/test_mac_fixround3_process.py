"""Permitted Linux real-process checks: only exact numeric PIDs started by this test.

These do not substitute for the forbidden process-group/Mac handoff acceptance suite.
"""
import importlib.util
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest


def lifecycle():
    source = Path(os.environ.get('FIXROUND3_SOURCE', str(Path(__file__).parents[1])))
    path = source / 'mac_worker_lifecycle.py'
    assert path.exists(), 'baseline has no pinned non-reaping lifecycle'
    spec = importlib.util.spec_from_file_location('process_lifecycle', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_real_child_exit_remains_unreaped_until_final_drain(monkeypatch):
    life = lifecycle()
    def forbidden(*a):
        pytest.fail('real process-group signals are prohibited')
    monkeypatch.setattr(os, 'killpg', forbidden)
    proc = subprocess.Popen([sys.executable, '-I', '-B', '-c', 'pass'], start_new_session=True)
    try:
        child = life.Child(proc)
        deadline = time.monotonic() + 5
        while not child.exited() and time.monotonic() < deadline:
            time.sleep(.01)
        assert child.exited() and proc.returncode is None
        if hasattr(os, 'waitid'):
            assert os.waitid(os.P_PID, proc.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT).si_pid == proc.pid
        assert life.drain(child, .1, .1, .1)
        assert child.reaped and proc.returncode == 0
        assert not child.send(signal.SIGTERM)
    finally:
        if proc.returncode is None:
            os.kill(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)


def test_exact_owned_pid_term_preserves_pin_until_reap(monkeypatch):
    life = lifecycle()
    monkeypatch.setattr(os, 'killpg', lambda *a: pytest.fail('group signal forbidden'))
    proc = subprocess.Popen([sys.executable, '-I', '-B', '-c', 'import time; time.sleep(10)'], start_new_session=True)
    try:
        child = life.Child(proc)
        assert not child.exited()
        os.kill(proc.pid, signal.SIGTERM)  # Exact child this fixture just started.
        deadline = time.monotonic() + 5
        while not child.exited() and time.monotonic() < deadline:
            time.sleep(.01)
        assert child.exited() and proc.returncode is None
        assert life.drain(child, .1, .1, .1)
        assert proc.returncode == -signal.SIGTERM and child.reaped
    finally:
        if proc.returncode is None:
            os.kill(proc.pid, signal.SIGKILL)
            proc.wait(timeout=5)
