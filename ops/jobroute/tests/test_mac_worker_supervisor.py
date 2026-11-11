"""Supervisor contract checks with synthetic PIDs and mocked signals only.

The v3 contract replaces disk-authorized signalling with supervisor receipts. Assertions
still require workload-before-runner cleanup, complete grace and retained evidence on errors.
"""
import signal
import pytest
from test_mac_fixround3 import model, state_for, supervisor, bounded  # noqa: F401


def terminal(m, state):
    r = m.w.Result()
    r.cleanup_complete = r.workload_reaped = True
    r.workload_state = 'drained'
    r.returncode = 0
    state.evidence('supervisor-result.json', r.record())


def test_deadline_drains_workload_before_stopping_lock_holder(model):
    m = model
    state = state_for(m)
    original = m.w._cancel
    def cancel(s, result, deadline):
        original(s, result, deadline)
        m.events.append(('workload-drained', 333))
        terminal(m, s)
    m.monkeypatch.setattr(m.w, '_cancel', cancel)
    result = bounded(m, state)
    assert result.timed_out and result.cleanup_complete
    assert state.read(10)['cancelled']
    assert m.events.index(('workload-drained', 333)) < m.events.index(('drain', 222))
    assert not any(e[0] == 'signal' for e in m.events)


def test_cancelled_queued_command_cannot_launch(model):
    m = model
    state, config = supervisor(m)
    state.update(10, cancelled=True)
    assert m.w._workload(state.path, ['work'], config) == 0  # acknowledged before launch
    assert not any(e[0] == 'launch' for e in m.events)
    proof = m.w._receipt(state)
    assert proof['cancel_ack'] and proof['workload_state'] == 'not_started'


def test_supervisor_records_session_and_waits_for_descendants(model):
    m = model
    state, config = supervisor(m)
    def exited(child):
        assert state.read(10)['pgid'] == child.proc.pid
        return True
    m.monkeypatch.setattr(m.w.life.Child, 'exited', exited)
    assert m.w._workload(state.path, ['work'], config) == 7
    assert state.read(10)['phase'] == 'drained'
    assert ('drain', 222) in m.events
    assert m.w._receipt(state)['workload_reaped']


def test_cleanup_error_preserves_workspace(model):
    m = model
    def failed(*args, **kwargs):
        raise OSError('cannot confirm drain')
    assert m.w.run(dict(operation='macjob', agent='Admin', label='keep', brief='brief'), m.tmp, failed) == 125
    entries = list((m.tmp / 'work/swarmhub-jobs').iterdir())
    control = next(p for p in entries if p.name.startswith('control-'))
    assert len(entries) == 2 and control.stat().st_mode & 0o777 == 0o700
    assert (control / 'cleanup-result.json').exists()


def test_invalid_control_still_reaches_runner_phase_after_drain_proof(model):
    m = model
    state = state_for(m)
    state.path.write_text('{')
    terminal(m, state)
    result = bounded(m, state)
    assert ('drain', 222) in m.events and result.runner_reaped
    assert m.w._status(result) == 125 and state.path.read_text() == '{'


def test_runner_gets_fresh_grace_after_workload_drain(model):
    m = model
    state = state_for(m)
    def cancel(s, result, deadline):
        m.clock[0] += .04
        terminal(m, s)
    m.monkeypatch.setattr(m.w, '_cancel', cancel)
    def drain(child, grace, kill_limit):
        assert grace == m.w.GRACE and kill_limit == m.w.KILL_DRAIN_LIMIT
        m.events.append(('runner-start', m.clock[0]))
        child.proc.returncode = 0
        return True
    m.monkeypatch.setattr(m.w.life, 'drain', drain)
    assert bounded(m, state).cleanup_complete
    assert next(e[1] for e in m.events if e[0] == 'runner-start') >= .04


def test_kill_retries_are_bounded_and_never_reap_before_drain(model):
    m = model
    # Test the actual shared drain implementation, not model's success replacement.
    import importlib.util
    spec = importlib.util.spec_from_file_location('drain_test', m.w.Path(m.w.__file__).with_name('mac_worker_lifecycle.py'))
    life = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(life)
    proc = m.launch()
    child = life.Child(proc)
    m.monkeypatch.setattr(child, 'exited', lambda: False)
    m.monkeypatch.setattr(life, 'membership', lambda *a: life.LIVE)
    m.monkeypatch.setattr(m.w.os, 'killpg', lambda pid, sig: m.events.append(('signal', pid, sig)))
    assert not life.drain(child, .1, .3, .1)
    signals = [e for e in m.events if e[0] == 'signal']
    assert signals[0] == ('signal', 222, signal.SIGTERM)
    assert 2 <= len(signals[1:]) <= 4
    assert all(e == ('signal', 222, signal.SIGKILL) for e in signals[1:])
    assert child.owned and not child.reaped
