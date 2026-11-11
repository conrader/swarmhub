"""Fixround3 regressions. Synthetic children/signals; actual bounded temporary state files.

FIXROUND3_SOURCE selects the untouched baseline for the identical regression replay.
"""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
from types import SimpleNamespace

import pytest


@pytest.fixture
def model(tmp_path, monkeypatch):
    source = Path(os.environ.get('FIXROUND3_SOURCE', str(Path(__file__).parents[1])))
    spec = importlib.util.spec_from_file_location('fr3_worker', source / 'mac-worker.py')
    w = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(w)
    events, clock = [], [0.0]
    def now():
        clock[0] += .001
        assert clock[0] < 500, 'unbounded lifecycle'
        return clock[0]
    monkeypatch.setattr(w.time, 'monotonic', now)
    monkeypatch.setattr(w.time, 'sleep', lambda delay: (events.append(('sleep', delay)), clock.__setitem__(0, clock[0] + delay)))
    def forbidden(*a, **kw):
        raise AssertionError('real subprocess/signal forbidden in regression fixture')
    monkeypatch.setattr(w.os, 'killpg', forbidden)
    monkeypatch.setattr(w.os, 'kill', forbidden)
    monkeypatch.setattr(w.subprocess, 'Popen', forbidden)
    monkeypatch.setattr(w.subprocess, 'check_output', forbidden)
    monkeypatch.setattr(w, 'GRACE', .03)
    monkeypatch.setattr(w, 'KILL_DRAIN_LIMIT', .03)
    modern = hasattr(w, 'life')
    if modern:
        monkeypatch.setattr(w, 'SETTLE', .08)
        monkeypatch.setattr(w.life.Child, 'exited', lambda child: False)
        monkeypatch.setattr(w.life, 'supported', lambda: None)
        def drain(child, *args):
            events.append(('drain', child.proc.pid))
            child.drained = child.reaped = True
            child.proc.returncode = 7
            return True
        monkeypatch.setattr(w.life, 'drain', drain)
    else:
        monkeypatch.setattr(w, '_signal', lambda pid, sig: events.append(('signal', pid, sig)))
        monkeypatch.setattr(w, '_alive', lambda pid: True)
        monkeypatch.setattr(w, '_drain', lambda *args: True)
    def launch(*args, **kw):
        events.append(('launch', kw))
        def wait(timeout=None):
            if timeout == .01:
                raise subprocess.TimeoutExpired('runner', timeout)
            return 7
        return SimpleNamespace(pid=222, returncode=None, wait=wait, poll=lambda: None)
    monkeypatch.setattr(w.subprocess, 'Popen', launch)
    return SimpleNamespace(w=w, events=events, clock=clock, monkeypatch=monkeypatch, tmp=tmp_path, modern=modern, launch=launch)


def state_for(m):
    directory = m.tmp / 'private'
    directory.mkdir(mode=0o700)
    path = directory / '.workload.json'
    if m.modern:
        state = m.w.state_api.State(path, create=True)
        state.update(10, phase='running', pgid=333)
        return state
    path.write_text('{"pgid":333}')
    return SimpleNamespace(path=path)


def bounded(m, state):
    kw = dict(workload_control=state.path)
    if m.modern:
        kw['state'] = state
    return m.w._bounded(['runner'], .01, **kw)


@pytest.mark.parametrize('raw', ['{', '[' * 1500 + ']' * 1500, '[' * 100000, '{}',
    '{"pgid":true}', '{"pgid":"333"}', '{"pgid":1}', '{"pgid":2147483648}',
    '{"pgid":' + str(10**100) + '}', '{"pgid":333}'])
def test_invalid_control_never_destroys_guardian_or_authorizes_deletion(model, raw):
    """Audit 1/2 and deep-JSON crash: invalid input cannot grant signal authority or success."""
    m = model
    state = state_for(m)
    state.path.write_text(raw)
    result = bounded(m, state)
    assert m.w._status(result) == 125
    assert state.path.read_text() == raw
    assert not any(e[0] in ('drain', 'signal') for e in m.events)
    assert result.cleanup_complete is False


@pytest.mark.parametrize('kind', ['fifo', 'symlink', 'hardlink', 'replaced'])
def test_control_substitution_cannot_block_or_rewrite_foreign_file(model, kind):
    """Claude FIFO hang and symlink-write path: reject before any stream read/write."""
    m = model
    state = state_for(m)
    target = m.tmp / 'foreign'
    target.write_text('{"pgid":333}')
    state.path.unlink()
    if kind == 'fifo':
        os.mkfifo(state.path, 0o600)
    elif kind == 'symlink':
        state.path.symlink_to(target)
    elif kind == 'hardlink':
        os.link(target, state.path)
    else:
        state.path.write_text('{"pgid":333}')
        state.path.chmod(0o600)
    # Baseline FIFO is not executed: intercept its unsafe builtin open so the regression
    # fails immediately instead of hanging the pytest process forever.
    if not m.modern and kind == 'fifo':
        import builtins
        old_open = builtins.open
        def no_fifo(path, *a, **kw):
            assert Path(path) != state.path, 'regression: blocking FIFO open'
            return old_open(path, *a, **kw)
        m.monkeypatch.setattr(builtins, 'open', no_fifo)
    result = bounded(m, state)
    assert m.w._status(result) == 125
    assert target.read_text() == '{"pgid":333}'
    assert m.clock[0] < 1


def test_failed_drain_does_not_delete_workspace(model):
    """Audit 3: a returned-but-incomplete cleanup result cannot set finished=True."""
    m = model
    def execute(*args, **kw):
        if m.modern:
            result = m.w.Result()
            result.timed_out = True
            return result
        return SimpleNamespace(returncode=-9, timed_out=True, cleanup_complete=False)
    code = m.w.run(dict(operation='macjob', agent='Admin', label='retained', brief='brief'), m.tmp, execute)
    assert code == 125
    assert len(list((m.tmp / 'work/swarmhub-jobs').iterdir())) == 2


@pytest.mark.parametrize('code', [0, 7, -9])
def test_early_runner_exit_requires_workload_terminal_proof(model, code):
    """Audit 6: ordinary/abnormal runner exit cannot bypass workload reconciliation."""
    m = model
    state = state_for(m)
    proc = SimpleNamespace(pid=222, returncode=code, wait=lambda **kw: code, poll=lambda: code)
    m.monkeypatch.setattr(m.w.subprocess, 'Popen', lambda *a, **kw: proc)
    if m.modern:
        m.monkeypatch.setattr(m.w.life.Child, 'exited', lambda child: True)
    result = bounded(m, state)
    assert m.w._status(result) == 125
    assert state.path.exists()


def supervisor(m, after_launch=None):
    state = state_for(m)
    if m.modern:
        state.update(10, phase='queued', pgid=None)
        config = dict(token=state.token, identity=[state.directory, state.inode], deadline=10)
    else:
        state.path.write_text('{}')
        config = None
    def launch(*a, **kw):
        proc = m.launch(*a, **kw)
        if after_launch:
            after_launch(state)
        return proc
    m.monkeypatch.setattr(m.w.subprocess, 'Popen', launch)
    m.monkeypatch.setattr(m.w.os, 'getppid', lambda: 123)
    return state, config


@pytest.mark.parametrize('sig', [signal.SIGTERM, signal.SIGINT, signal.SIGHUP])
def test_supervisor_signal_latches_and_drains_owned_child(model, sig):
    """Audit 6 concrete trigger: default-action supervisor death orphaned the child."""
    m = model
    def interrupt(state):
        handler = signal.getsignal(sig)
        assert callable(handler) and handler != signal.default_int_handler, 'supervisor has no cleanup signal handler'
        handler(sig, None)
        handler(signal.SIGTERM, None)
    state, config = supervisor(m, interrupt)
    args = (state.path, ['work'])
    result = m.w._workload(*args, **({'config': config} if m.modern else {}))
    assert result == 128 + sig
    assert ('drain', 222) in m.events
    assert m.w._receipt(state)['workload_reaped']


def test_post_launch_control_corruption_keeps_child_owner_until_drain(model):
    """Audit 1: the supervisor's in-memory child survives loss of JSON authority."""
    m = model
    state, config = supervisor(m)
    if m.modern:
        original = m.w.state_api.State.read
        def corrupt(obj, deadline):
            obj.path.write_text('{broken')
            return original(obj, deadline)
        m.monkeypatch.setattr(m.w.state_api.State, 'read', corrupt)
    else:
        def corrupt_wait(timeout=None):
            state.path.write_text('{broken')
            return 0
        m.monkeypatch.setattr(m.w.subprocess, 'Popen', lambda *a, **kw: SimpleNamespace(pid=222, wait=corrupt_wait))
    code = m.w._workload(state.path, ['work'], **({'config': config} if m.modern else {}))
    assert code == 125
    assert state.path.read_text() == '{broken'
    assert ('drain', 222) in m.events
    assert m.w._receipt(state)['cleanup_complete']


def test_failed_workload_drain_remains_in_containment_until_reaped(model):
    """Audit 3: unsuccessful KILL/drain never voluntarily exits the guardian."""
    m = model
    state, config = supervisor(m)
    if m.modern:
        m.monkeypatch.setattr(m.w.life.Child, 'exited', lambda child: True)
        calls = [False, False, True]
        def drain(child, *args):
            m.events.append(('drain', child.proc.pid))
            done = calls.pop(0)
            if done:
                child.proc.returncode = 0
            return done
        m.monkeypatch.setattr(m.w.life, 'drain', drain)
    else:
        m.monkeypatch.setattr(m.w, '_drain', lambda *a: False)
        m.monkeypatch.setattr(m.w, '_kill_drain', lambda *a: False)
    code = m.w._workload(state.path, ['work'], **({'config': config} if m.modern else {}))
    assert len([e for e in m.events if e[0] == 'drain']) == 3
    assert len([e for e in m.events if e == ('sleep', 1)]) == 2
    assert code == 0


@pytest.mark.parametrize('reserved', [125, 126])
def test_literal_new_reserved_status_is_normalized(model, reserved):
    m = model
    result = m.w.Result() if m.modern else SimpleNamespace()
    result.returncode, result.cleanup_complete = reserved, True
    assert m.w._status(result) == 1


def test_artifact_removal_failure_is_126_not_request_refusal(model):
    m = model
    def execute(*args, **kwargs):
        r = m.w.Result() if m.modern else SimpleNamespace()
        r.returncode, r.cleanup_complete = 0, True
        return r
    def fail(*a, **kw):
        raise OSError('disk failure')
    m.monkeypatch.setattr(m.w.shutil, 'rmtree', fail)
    assert m.w.run(dict(operation='macjob', agent='Admin', label='retain', brief='x'), m.tmp, execute) == 126


def test_runner_output_is_private_before_any_launch(model):
    """Containment must not leave SSH stdout/stderr attached to a surviving guardian."""
    m = model
    def execute(argv, limit, **kw):
        assert kw['stdout'].fileno() > 2 and kw['stderr'].fileno() > 2
        assert kw['stdout'].seekable() and kw['stderr'].seekable()
        r = m.w.Result()
        return r
    assert m.w.run(dict(operation='macjob', agent='Admin', label='logs', brief='x'), m.tmp, execute) == 125


@pytest.mark.parametrize('pgid', [None, True, 1.5, '333', -1, 0, 1, 2222, 2147483648, 10**100])
def test_forged_pgid_in_otherwise_valid_control_never_changes_signal_target(model, pgid):
    """Audit 2: range checks alone cannot authorize a plausible foreign process group."""
    m = model
    state, config = supervisor(m)
    bad = [None]
    if m.modern:
        original = m.w.state_api.State.read
        def corrupt(obj, deadline):
            record = json.loads(obj.path.read_text())
            record['pgid'] = pgid
            bad[0] = json.dumps(record)
            obj.path.write_text(bad[0])
            return original(obj, deadline)
        m.monkeypatch.setattr(m.w.state_api.State, 'read', corrupt)
    else:
        def wait(timeout=None):
            bad[0] = json.dumps({'pgid': pgid})
            state.path.write_text(bad[0])
            return 7
        m.monkeypatch.setattr(m.w.subprocess, 'Popen', lambda *a, **kw: SimpleNamespace(pid=222, wait=wait))
    assert m.w._workload(state.path, ['work'], **({'config': config} if m.modern else {})) == 125
    assert state.path.read_text() == bad[0]
    assert [e for e in m.events if e[0] == 'drain'] == [('drain', 222)]


@pytest.mark.parametrize('runner_contract', ['forward-and-wait', 'kill-supervisor-on-term'])
def test_invalid_control_through_run_drains_owned_work_before_either_runner_contract(model, runner_contract):
    """Audit 1 end-to-end orchestration: terminal drain proof precedes runner teardown,
    while invalid bytes and BOTH directories survive even after physical drain."""
    m = model
    retained = []
    if m.modern:
        cancel = m.w._cancel
        def reconcile(state, result, deadline):
            cancel(state, result, deadline)
            m.events.append(('supervisor-owned-drain', 333))
            receipt = m.w.Result()
            receipt.workload_state = 'drained'
            receipt.workload_reaped = receipt.cleanup_complete = True
            receipt.fail('control_unavailable_or_invalid')
            state.evidence('supervisor-result.json', receipt.record())
        m.monkeypatch.setattr(m.w, '_cancel', reconcile)
        def runner_drain(child, *args):
            assert ('supervisor-owned-drain', 333) in m.events
            m.events.append((runner_contract, child.proc.pid))
            child.proc.returncode = 143
            return True
        m.monkeypatch.setattr(m.w.life, 'drain', runner_drain)
    def execute(argv, limit, **kw):
        path = Path(kw['workload_control'])
        path.write_text('{corrupt-after-launch')
        retained.append(path)
        return m.w._bounded(['runner'], .01, workload_control=path,
                            **({'state': kw['state']} if m.modern else {}))
    assert m.w.run(dict(operation='macjob', agent='Admin', label='preserve', brief='x'), m.tmp, execute) == 125
    assert retained[0].read_text() == '{corrupt-after-launch'
    assert len(list((m.tmp / 'work/swarmhub-jobs').iterdir())) == 2
    assert m.events.index(('supervisor-owned-drain', 333)) < m.events.index((runner_contract, 222))
