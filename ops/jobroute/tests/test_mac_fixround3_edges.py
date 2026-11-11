"""Regression edges for pinned ownership, bounded helpers and exception boundaries."""
import errno
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
from types import SimpleNamespace

import pytest
from test_mac_fixround3 import model, state_for, supervisor, bounded  # noqa: F401


def lifecycle(m):
    assert m.modern, 'baseline lacks non-reaping lifecycle'
    spec = importlib.util.spec_from_file_location('edge_lifecycle', Path(m.w.__file__).with_name('mac_worker_lifecycle.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize('lost', [False, True])
def test_signal_authority_ends_at_reap_or_echild(model, lost):
    """The old wait-before-signal path could target a reused PGID."""
    m = model
    life = lifecycle(m)
    proc = m.launch()
    child = life.Child(proc)
    def waitid(*a):
        if lost:
            raise ChildProcessError()
        return object()
    m.monkeypatch.setattr(os, 'waitid', waitid)
    m.monkeypatch.setattr(os, 'killpg', lambda pid, sig: m.events.append(('signal', pid, sig)))
    assert child.send(signal.SIGTERM) is not lost
    if not lost:
        child.drained = True
        assert child.reap(1)
    assert not child.send(signal.SIGKILL)
    assert [e for e in m.events if e[0] == 'signal'] == ([] if lost else [('signal', 222, signal.SIGTERM)])


def test_ps_unknown_cannot_authorize_reap_and_retry_budget_is_shared(model):
    m = model
    life = lifecycle(m)
    child = life.Child(m.launch())
    m.monkeypatch.setattr(child, 'exited', lambda: True)
    m.monkeypatch.setattr(os, 'killpg', lambda pid, sig: m.events.append(('signal', pid, sig)))
    m.monkeypatch.setattr(life, 'membership', lambda *a: life.UNKNOWN)
    assert not life.drain(child, .02, .03, .01)
    assert not child.drained and not child.reaped and child.owned
    assert m.clock[0] < .15


@pytest.mark.parametrize('output,code,expected', [(b'', 0, 'drained'), (b'222 Z\n', 0, 'drained'),
    (b'222 S\n', 0, 'live'), (b'garbage\n', 0, 'unknown'), (b'222 S\n', 1, 'unknown'),
    (b'x' * 1048577, 0, 'unknown')])
def test_ps_malformed_nonzero_and_oversize_are_unknown(model, output, code, expected):
    m = model
    life = lifecycle(m)
    def launch(argv, **kw):
        kw['stdout'].write(output)
        return SimpleNamespace(returncode=code, wait=lambda **kw: code)
    m.monkeypatch.setattr(life.subprocess, 'Popen', launch)
    reasons = set()
    assert life.membership(222, 1, reasons) == expected
    if expected == 'unknown':
        assert 'process_inspection_failed' in reasons


def test_lock_second_clock_crossing_deadline_cannot_sleep_negative(model):
    m = model
    assert m.modern, 'baseline has unbounded flock'
    times = iter([0, 2])
    m.monkeypatch.setattr(m.w.time, 'monotonic', lambda: next(times))
    def busy(*a):
        raise BlockingIOError(errno.EAGAIN, 'busy')
    m.monkeypatch.setattr(m.w.state_api.fcntl, 'flock', busy)
    with pytest.raises(TimeoutError):
        m.w.state_api.acquire_until(10, 1)
    assert not any(e[0] == 'sleep' for e in m.events)


@pytest.mark.parametrize('trigger', ['parent', 'runtime'])
def test_supervisor_watchdog_retains_independent_deadline(model, trigger):
    m = model
    state, config = supervisor(m)
    assert m.modern, 'baseline has neither parent watchdog nor independent runtime limit'
    calls = [0]
    def parent():
        calls[0] += 1
        return 123 if calls[0] < 3 or trigger != 'parent' else 1
    m.monkeypatch.setattr(os, 'getppid', parent)
    if trigger == 'runtime':
        m.monkeypatch.setattr(m.w, 'RUN_LIMIT', .01)
    result = m.w._workload(state.path, ['work'], config)
    assert result == (124 if trigger == 'runtime' else 7)
    proof = m.w._receipt(state)
    assert proof['workload_reaped']
    if trigger == 'parent':
        assert proof['queue_state'] == 'unknown'
        assert 'runner_parent_lost' in proof['reasons']


@pytest.mark.parametrize('sig', [signal.SIGTERM, signal.SIGINT, signal.SIGHUP])
def test_outer_signal_uses_reconciliation_not_default_action(model, sig):
    m = model
    state = state_for(m)
    assert m.modern, 'baseline outer worker has no stop handlers'
    def exited(child):
        signal.getsignal(sig)(sig, None)
        return False
    m.monkeypatch.setattr(m.w.life.Child, 'exited', exited)
    def cancel(s, result, deadline):
        r = m.w.Result()
        r.workload_state, r.workload_reaped, r.cleanup_complete = 'drained', True, True
        s.evidence('supervisor-result.json', r.record())
    m.monkeypatch.setattr(m.w, '_cancel', cancel)
    result = bounded(m, state)
    assert m.w._status(result) == 128 + sig
    assert result.runner_reaped and result.workload_reaped


def test_publication_failure_after_popen_cannot_escape_guardian(model):
    m = model
    state, config = supervisor(m)
    assert m.modern, 'baseline has no post-Popen finally cleanup'
    write = m.w.state_api.State._write
    def fail(fd, record):
        if record.get('phase') == 'running':
            raise OSError('disk full')
        write(fd, record)
    m.monkeypatch.setattr(m.w.state_api.State, '_write', staticmethod(fail))
    assert m.w._workload(state.path, ['work'], config) == 125
    assert ('drain', 222) in m.events
    assert m.w._receipt(state)['workload_reaped']


def test_entrypoint_late_permission_error_is_incomplete_not_refusal(model):
    """Exercise actual main dispatcher with a failure after request validation."""
    m = model
    assert m.modern, 'baseline maps late OSError to request refusal'
    import io
    request = dict(operation='macjob', agent='Admin', label='entry', brief='x')
    m.monkeypatch.setattr(m.w.sys, 'argv', ['mac-worker.py'])
    m.monkeypatch.setattr(m.w.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(json.dumps(request).encode())))
    m.monkeypatch.setattr(m.w.Path, 'home', lambda: m.tmp)
    m.monkeypatch.setattr(m.w, '_bounded', lambda *a, **kw: (_ for _ in ()).throw(PermissionError()))
    assert m.w.main() == 125
    dirs = list((m.tmp / 'work/swarmhub-jobs').iterdir())
    assert len(dirs) == 2


def test_evidence_enospc_forbids_deletion_even_after_drain(model):
    m = model
    state = state_for(m)
    assert m.modern, 'baseline has no independent evidence failure contract'
    def receipt(s):
        r = m.w.Result().record()
        return dict(r, cleanup_complete=True, workload_reaped=True, workload_state='drained', phase='terminal')
    m.monkeypatch.setattr(m.w, '_has_receipt', lambda s: True)
    m.monkeypatch.setattr(m.w, '_receipt', receipt)
    m.monkeypatch.setattr(state, 'evidence', lambda *a: (_ for _ in ()).throw(OSError(errno.ENOSPC, 'full')))
    result = bounded(m, state)
    assert result.cleanup_complete and m.w._status(result) == 125
    assert 'evidence_write_failed' in result.reasons


def test_inherited_sigchld_ignore_is_reset_before_launch_and_restored(model):
    m = model
    life = lifecycle(m)
    seen = {}
    old = signal.getsignal(signal.SIGCHLD)
    try:
        signal.signal(signal.SIGCHLD, signal.SIG_IGN)
        with life.Stops():
            assert signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL
        assert signal.getsignal(signal.SIGCHLD) == signal.SIG_IGN
    finally:
        signal.signal(signal.SIGCHLD, old)


def test_cancelled_gate_prevents_delayed_launch_after_outer_exit(model):
    m = model
    state, config = supervisor(m)
    assert m.modern, 'baseline lacks independent cancellation latch'
    state.latch()
    assert m.w._workload(state.path, ['work'], config) == 0
    assert not any(e[0] == 'launch' for e in m.events)
    assert m.w._receipt(state)['cancel_ack']


def test_cancel_marker_fifo_is_never_opened_as_stream(model):
    m = model
    state, config = supervisor(m)
    assert m.modern, 'baseline has no independent cancellation latch'
    os.mkfifo(state.path.parent / '.cancel', 0o600)
    assert m.w._workload(state.path, ['work'], config) == 0
    assert not any(e[0] == 'launch' for e in m.events)


@pytest.mark.parametrize('error', [PermissionError, OverflowError, RecursionError])
def test_real_main_post_launch_exception_exits_125_without_traceback(model, error, capfd):
    """Baseline main either mislabels OSError as refusal or leaks a traceback."""
    m = model
    import io
    import runpy
    request = dict(operation='macjob', agent='Admin', label='main', brief='x')
    m.monkeypatch.setattr(m.w.sys, 'argv', ['mac-worker.py'])
    m.monkeypatch.setattr(m.w.sys, 'stdin', SimpleNamespace(buffer=io.BytesIO(json.dumps(request).encode())))
    m.monkeypatch.setattr(m.w.Path, 'home', lambda: m.tmp)
    def failed(*a, **kw):
        raise error('injected after launch')
    m.monkeypatch.setattr(os, 'waitid', failed)
    proc = SimpleNamespace(pid=222, returncode=None, wait=failed)
    m.monkeypatch.setattr(subprocess, 'Popen', lambda *a, **kw: proc)
    with pytest.raises(SystemExit) as result:
        runpy.run_path(m.w.__file__, run_name='__main__')
    assert result.value.code == 125
    out, err = capfd.readouterr()
    assert 'Traceback' not in out + err and 'refused request' not in err


def test_malformed_receipt_does_not_skip_independent_cancellation(model):
    m = model
    state = state_for(m)
    assert m.modern, 'baseline lacks independent cancellation'
    (state.path.parent / 'supervisor-result.json').write_text('{}')
    result = bounded(m, state)
    assert state.latched() and state.read(10)['cancelled']
    assert m.w._status(result) == 125
    assert not result.runner_reaped


def test_terminal_receipt_cannot_be_overwritten_by_partial_state(model):
    m = model
    state = state_for(m)
    assert m.modern, 'baseline has no terminal-proof monotonicity'
    r = m.w.Result()
    r.cleanup_complete = True
    state.evidence('supervisor-result.json', r.record())
    original = (state.path.parent / 'supervisor-result.json').read_bytes()
    r.cleanup_complete = False
    with pytest.raises(ValueError, match='terminal'):
        state.evidence('supervisor-result.json', r.record())
    assert (state.path.parent / 'supervisor-result.json').read_bytes() == original
