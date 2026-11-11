"""backlog17: a route timeout ends the whole backend call, not just its first process.

The real mac-dispatch runs with ssh swapped for a local stand-in that hangs (and, in one case,
ignores SIGTERM). After the route's timeout neither mac-dispatch nor that "ssh" may survive.
Only processes these tests start are signalled. No ssh, no Mac.
"""
import os
from pathlib import Path
import sys
import time

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jobroute_core import Route, Refused  # noqa: E402
import jobroute_commands as commands  # noqa: E402
from test_swap_commands import env  # noqa: E402,F401 (fixture: macjob/queue enabled for macbook)

SRC = Path(__file__).resolve().parents[1]
TEXT = 'backend timed out; its outcome is unknown'

# The stand-in records its own pid and its parent's (mac-dispatch), then hangs.
HUNG_SSH = '''#!/usr/bin/python3 -I
import os, signal, sys, time
def on_term(*_):                     # like ssh: note the polite stop, then exit
    open({pids!r} + '.term', 'w').close()
    os._exit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN if {ignore_term} else on_term)
sys.stdin.buffer.read()
with open({pids!r}, 'w') as f:
    f.write(f'{{os.getpid()}} {{os.getppid()}}')
while True:
    time.sleep(1)
'''
ANSWER_SSH = '''#!/usr/bin/python3 -I
import sys
sys.stdin.buffer.read()
sys.stdout.write({out!r})
sys.exit({code})
'''


def _exe(path, text):
    path.write_text(text)
    path.chmod(0o755)
    return str(path)


def dispatch_with(env, ssh_text):
    """The real mac-dispatch, with only its fixed ssh path pointed at the stand-in."""
    ssh = _exe(env.tmp / 'bin' / 'fake-ssh', ssh_text)
    text = (SRC / 'mac-dispatch').read_text()
    assert text.count("'/usr/bin/ssh'") == 1
    route = Route(str(env.cfg), 'grok-admin')
    route.backends['mac_dispatch'] = _exe(env.tmp / 'bin' / 'mac-dispatch-b17',
                                          text.replace("'/usr/bin/ssh'", repr(ssh)))
    return route


def alive(pid):
    """True while pid is a live, non-zombie process. Under `unshare -p -f` orphans may stay
    unreaped zombies of the namespace's pid 1; a zombie runs nothing, so it counts as gone."""
    try:
        stat = Path(f'/proc/{pid}/stat').read_text()
    except (FileNotFoundError, ProcessLookupError):
        return False
    return stat.rsplit(')', 1)[1].split()[0] != 'Z'


def wait_gone(pids, limit=5.0):
    end = time.monotonic() + limit
    while time.monotonic() < end and any(alive(p) for p in pids):
        time.sleep(0.05)
    return [p for p in pids if alive(p)]


@pytest.fixture
def cleanup():
    """Last resort for a failing (e.g. mutated) run: SIGKILL only pids the stand-in recorded."""
    started = []
    yield started
    for pid in started:
        if alive(pid):
            os.kill(pid, 9)


def timed_out_call(env, cleanup, ignore_term):
    pids = env.tmp / 'ssh.pids'
    route = dispatch_with(env, HUNG_SSH.format(ignore_term=ignore_term, pids=str(pids)))
    start = time.monotonic()
    with pytest.raises(Refused) as caught:
        route.backend('mac_dispatch', ['macbook'], b'{"operation": "queue"}', timeout=2)
    took = time.monotonic() - start
    assert pids.exists(), 'stand-in ssh never started'
    ssh_pid, dispatch_pid = map(int, pids.read_text().split())
    cleanup += [ssh_pid, dispatch_pid]
    return caught.value, took, ssh_pid, dispatch_pid


@pytest.mark.parametrize('ignore_term', [False, True], ids=['ssh-obeys-term', 'ssh-ignores-term'])
def test_route_timeout_leaves_no_ssh_or_dispatch(env, cleanup, ignore_term):
    err, took, ssh_pid, dispatch_pid = timed_out_call(env, cleanup, ignore_term)
    assert err.reason == TEXT and err.code == 1
    assert err.__cause__ is None and err.__suppress_context__
    # SIGKILL lands asynchronously, so allow a short settle; an un-KILLed TERM-ignoring child
    # (or one never signalled) would still be alive long after this.
    assert not alive(dispatch_pid)  # our direct child: reaped before the refusal
    assert wait_gone([ssh_pid], limit=2.0) == [], 'ssh child survived the route timeout'
    assert took < 2 + commands.BACKEND_KILL_GRACE + 2
    if ignore_term:
        assert took >= 2 + commands.BACKEND_KILL_GRACE


def test_term_comes_before_kill(env, cleanup):
    """ssh gets SIGTERM first (so it can close the connection), and a child that obeys it is not
    held for the grace period: the call ends well inside it."""
    err, took, ssh_pid, dispatch_pid = timed_out_call(env, cleanup, ignore_term=False)
    assert err.reason == TEXT
    assert (env.tmp / 'ssh.pids.term').exists(), 'ssh never received SIGTERM'
    assert took < 2 + commands.BACKEND_KILL_GRACE / 2


def test_success_output_is_unchanged(env):
    route = dispatch_with(env, ANSWER_SSH.format(out='{"holder": null, "waiting": []}', code=0))
    assert route.backend('mac_dispatch', ['macbook'], b'{"operation": "queue"}', timeout=10) \
        == '{"holder": null, "waiting": []}'


@pytest.mark.parametrize('code,text', [(255, 'mapped 255'), (124, 'mapped 124'),
                                       (3, 'backend failed; inspect the private backend ledger')])
def test_exit_code_mapping_is_unchanged(env, code, text):
    route = dispatch_with(env, ANSWER_SSH.format(out='', code=code))
    with pytest.raises(Refused) as caught:
        route.backend('mac_dispatch', ['macbook'], b'{"operation": "queue"}', timeout=10,
                      failures={255: 'mapped 255', 124: 'mapped 124'})
    assert caught.value.reason == text and caught.value.code == 1


def test_queue_and_macjob_maps_still_name_124_and_255():
    """backlog16's fixed texts are the ones the route passes; this change does not touch them."""
    src = (SRC / 'jobroute_commands.py').read_text()
    assert 'failures=QUEUE_FAILURES' in src
    assert set(commands.QUEUE_FAILURES) >= {124}


def test_parent_exit_does_not_shorten_child_grace(monkeypatch):
    # Leader has exited but remains UNREAPED while the descendant closes transport.
    from types import SimpleNamespace
    life = commands.lifecycle
    started = time.monotonic()
    child = life.Child(SimpleNamespace(pid=123, returncode=None, wait=lambda **kw: 0))
    monkeypatch.setattr(child, 'send', lambda sig: True)
    monkeypatch.setattr(life, 'membership', lambda *a:
                        life.LIVE if time.monotonic() - started < .15 else life.DRAINED)
    assert life.drain(child, .4, .2, .1)
    assert .15 <= time.monotonic() - started < .4
    assert child.reaped


def test_survivor_receives_full_grace(monkeypatch):
    import signal
    from types import SimpleNamespace
    life = commands.lifecycle
    child = life.Child(SimpleNamespace(pid=123, returncode=None))
    events = []
    started = time.monotonic()
    monkeypatch.setattr(child, 'send', lambda sig: events.append((sig, time.monotonic())))
    def inspect(*a):
        return life.DRAINED if any(sig == signal.SIGKILL for sig, _ in events) else life.LIVE
    monkeypatch.setattr(life, 'membership', inspect)
    monkeypatch.setattr(child, 'reap', lambda deadline: True)
    assert life.drain(child, .2, .1, .1)
    assert events[0][0] == signal.SIGTERM
    assert next(t for sig, t in events if sig == signal.SIGKILL) - started >= .2


def test_parent_exits_first_child_finishes_graceful_cleanup(env):
    marker = env.tmp / 'child-cleaned'
    child = ("import signal, time; from pathlib import Path; "
             f"signal.signal(signal.SIGTERM, lambda *_: (time.sleep(.3), Path({str(marker)!r}).touch(), exit(0))); "
             "time.sleep(30)")
    parent = ("import signal, subprocess, sys, time\n"
              "signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))\n"
              f"subprocess.Popen([sys.executable, '-c', {child!r}])\n"
              "time.sleep(30)\n")
    route = dispatch_with(env, '#!/usr/bin/python3 -I\n' + parent)
    started = time.monotonic()
    with pytest.raises(Refused) as exc:
        route.backend('mac_dispatch', ['macbook'], b'{"operation": "queue"}', timeout=1)
    assert exc.value.reason == commands.BACKEND_TIMED_OUT
    assert marker.exists()
    assert 1.3 <= time.monotonic() - started < 1 + commands.BACKEND_KILL_GRACE + 1


def test_ps_failure_during_cleanup_still_kills_and_waits(monkeypatch, tmp_path):
    import signal
    import subprocess
    from types import SimpleNamespace
    life = commands.lifecycle
    events = []
    stream = (tmp_path / 'stdin').open('wb')
    proc = SimpleNamespace(pid=123, stdin=stream, returncode=None,
                           wait=lambda **kw: events.append('wait'))
    monkeypatch.setattr(commands.subprocess, 'Popen', lambda *a, **kw: proc)
    monkeypatch.setattr(life.Child, 'exited', lambda self: False)
    monkeypatch.setattr(life.Child, 'send', lambda self, sig: events.append(sig))
    monkeypatch.setattr(commands, 'BACKEND_KILL_GRACE', .01)
    # A transient inspection failure is recoverable; final drain must precede reap.
    answers = iter([life.UNKNOWN, life.LIVE, life.DRAINED])
    monkeypatch.setattr(life, 'membership', lambda *a: next(answers))
    with pytest.raises(subprocess.TimeoutExpired):
        commands.run_group(['backend'], input=b'', stdout=None, env={}, cwd=None, timeout=0)
    assert events == [signal.SIGTERM, signal.SIGKILL, 'wait']
