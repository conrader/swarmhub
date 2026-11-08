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
