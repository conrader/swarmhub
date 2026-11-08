"""backlog15: a backend that outlives its timeout is a fixed refusal, and the Mac queue call
waits longer than the worker's own queue limit. No ssh, no Mac: stand-in backends only."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jobroute_core import Route, Refused  # noqa: E402
import jobroute_commands as commands  # noqa: E402
from test_swap_commands import env  # noqa: E402,F401 (fixture: macjob/queue enabled for macbook)

SRC = Path(__file__).resolve().parents[1]
TEXT = 'backend timed out; its outcome is unknown'


def worker_module():
    spec = importlib.util.spec_from_file_location('queue_worker_b15', SRC / 'mac-worker.py')
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    return worker


def stand_in(env, name, body):
    path = env.tmp / 'bin' / name
    path.write_text('#!/bin/sh\n' + body + '\n')
    path.chmod(0o755)
    return str(path)


def recording_run(seen, raise_timeout):
    """Replace jobroute_commands.run_group: record the timeout, then time out or answer."""
    def run(argv, **kw):
        seen.append((argv, kw['timeout']))
        if raise_timeout:
            raise subprocess.TimeoutExpired(argv, kw['timeout'])
        kw['stdout'].write(b'{"holder": null, "waiting": []}')
        return subprocess.CompletedProcess(argv, 0)
    return run


def route_with_dispatch(env, script='exit 0'):
    route = Route(str(env.cfg), 'grok-admin')
    route.backends['mac_dispatch'] = stand_in(env, 'mac-dispatch', script)
    return route


# (a) a timeout is a fixed Refused -------------------------------------------------------------

def test_real_backend_timeout_is_fixed_refusal(env):
    route = route_with_dispatch(env, 'sleep 30')
    with pytest.raises(Refused) as caught:
        route.backend('mac_dispatch', ['macbook'], b'{}', timeout=1)
    assert caught.value.reason == TEXT and caught.value.code == 1
    assert caught.value.__cause__ is None and caught.value.__suppress_context__


def test_queue_timeout_is_audited_as_refusal(env, monkeypatch):
    route = route_with_dispatch(env)
    monkeypatch.setattr(commands, 'run_group', recording_run([], raise_timeout=True))
    with pytest.raises(Refused, match='^backend timed out; its outcome is unknown$'):
        route.command('mcp', 'queue', {})
    last = env.audit()[-1]
    assert last['result'] == 'refused' and last['reason'] == TEXT


DRIVER = r"""
import importlib.machinery, importlib.util, subprocess, sys
sys.path.insert(0, sys.argv[1])
import jobroute_commands
def run(argv, **kw):                      # the backend outlives its timeout
    raise subprocess.TimeoutExpired(argv, kw['timeout'])
jobroute_commands.run_group = run
loader = importlib.machinery.SourceFileLoader('jobroute_cli', sys.argv[1] + '/jobroute')
module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
loader.exec_module(module)
sys.exit(module.main(sys.argv[2:]))
"""


@pytest.mark.parametrize('transport', ['cli', 'mcp'])
def test_entry_points_answer_with_fixed_text(env, transport):
    """A real route process: the CLI prints one JSON refusal and no traceback; MCP returns the
    reason instead of the catch-all 'route error: TimeoutExpired'."""
    stand_in(env, 'mac-dispatch', 'exit 0')
    env.cfg.write_text(env.cfg.read_text().replace(
        '[route.env]', f'backends = {{ mac_dispatch = "{env.tmp}/bin/mac-dispatch" }}\n[route.env]', 1))
    if transport == 'cli':
        cmd, stdin = 'queue', b'{}'
    else:
        cmd = 'mcp'
        stdin = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                            'params': {'name': 'queue', 'arguments': {}}}).encode() + b'\n'
    p = subprocess.run([sys.executable, '-I', '-B', '-c', DRIVER, str(SRC), '--config', str(env.cfg),
                        '--profile', 'grok-admin'], input=stdin, capture_output=True, timeout=60,
                       env={'PATH': '/usr/bin:/bin', 'SSH_ORIGINAL_COMMAND': cmd})
    out, err = p.stdout.decode(), p.stderr.decode()
    assert 'Traceback' not in out + err and 'TimeoutExpired' not in out + err, (out, err)
    lines = [json.loads(x) for x in out.splitlines()]
    if transport == 'cli':
        assert p.returncode == 1 and lines == [{'ok': False, 'error': TEXT}]
    else:
        result = lines[-1]['result']
        assert result['isError'] is True
        assert json.loads(result['content'][0]['text']) == {'ok': False, 'error': TEXT}
    assert env.audit()[-1]['result'] == 'refused' and env.audit()[-1]['reason'] == TEXT


# (b) the queue call outwaits the worker's queue limit -----------------------------------------

def test_queue_timeout_exceeds_worker_queue_limit(env, monkeypatch):
    worker = worker_module()
    assert commands.MAC_QUEUE_LIMIT == worker.QUEUE_LIMIT  # the mirror cannot drift silently
    seen = []
    route = route_with_dispatch(env)
    monkeypatch.setattr(commands, 'run_group', recording_run(seen, raise_timeout=False))
    assert route.command('cli', 'queue', {})['queue'] == {'holder': None, 'waiting': []}
    [(argv, timeout)] = seen
    assert argv[-1] == 'macbook'
    # strictly greater, with room for ssh connect; not padded by the worker's KILL-after-TERM GRACE
    assert worker.QUEUE_LIMIT + 15 <= timeout == commands.QUEUE_TIMEOUT < worker.QUEUE_LIMIT + worker.GRACE


# (c) every other backend caller keeps its timeout ---------------------------------------------

def test_other_backend_callers_keep_default_timeout(env, monkeypatch):
    seen = []
    route = Route(str(env.cfg), 'grok-admin')
    monkeypatch.setattr(route, 'backend', lambda name, argv, *a, **kw: seen.append((name, kw.get('timeout'))) or
                        json.dumps({'wake': 'HTTP 202'}))
    route.command('cli', 'report-jarvis', {'text': 'Fixture report'})
    assert seen == [('codejob', None)]  # no override: backend()'s default applies
    import inspect
    assert inspect.signature(Route.backend).parameters['timeout'].default == 60
    # Only the queue call passes a timeout; park, msg and report-jarvis use the default.
    src = (SRC / 'jobroute_commands.py').read_text()
    assert src.count('self.backend(') == 4 and src.count('timeout=QUEUE_TIMEOUT') == 1
