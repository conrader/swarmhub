"""`queue` exit codes with a guaranteed meaning get fixed text; every other code stays generic.

On `queue`, mac-dispatch exits 124 only when mac-worker.py stops `sb-macjob queue` at its
QUEUE_LIMIT: the worker reports its runner's own 124 as 1, and ssh never exits 124 itself. 255 is
ssh's own failure. A job's 124 is the 6 h deadline and stays a job status (`cause: timed_out`).
75 (sb-macjob's queue `Busy`) is not mapped: a job can exit 75 too, and nothing a job cannot forge
marks Busy (docs/swap-jobs-migration.md).
"""
import json
from pathlib import Path
import subprocess
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jobroute_core import Refused  # noqa: E402
import jobroute_commands as commands  # noqa: E402
from test_swap_commands import env  # noqa: E402,F401 (fixture: macjob/queue enabled for macbook)
from test_mac_queue_fixtures import SHORT, dispatcher, mac_home, route_with_mac  # noqa: E402
from test_mac_failure_cause import UNREACHABLE, broken_dispatcher, run_job  # noqa: E402

QUEUE_TIMED_OUT = 'Mac worker timed out waiting for the queue; retry later'
UNREACHABLE_TEXT = 'Mac host unreachable; retry later'
GENERIC = 'backend failed; inspect the private backend ledger'
QUEUE_LIMIT_ONLY = {'QUEUE_LIMIT': 1, 'GRACE': 3}   # the queue snapshot gives up after 1 s


def queue_error(route):
    with pytest.raises(Refused) as caught:
        route.command('cli', 'queue', {'host': 'macbook'})
    assert caught.value.code == 1
    return caught.value.reason


def set_mode(home, mode):
    (home / '.sb-macjob/mode').write_text(mode)


# (a) the worker's queue limit is a fixed refusal ----------------------------------------------

def test_queue_limit_through_real_worker_and_dispatch_is_fixed_refusal(env):
    route, home = route_with_mac(env, **QUEUE_LIMIT_ONLY)
    set_mode(home, 'queue-hang')
    assert queue_error(route) == QUEUE_TIMED_OUT
    last = env.audit()[-1]
    assert (last['op'], last['result'], last['reason']) == ('queue', 'refused', QUEUE_TIMED_OUT)


def route_process(env, home_or_none, ssh_text=None):
    """Configure the real route to use a real mac-dispatch (fixture ssh, or a broken one)."""
    bin_dir = env.tmp / 'bin'
    path = broken_dispatcher(bin_dir, ssh_text) if ssh_text else dispatcher(bin_dir, home_or_none)
    env.cfg.write_text(env.cfg.read_text().replace(
        '[route.env]', f'backends = {{ mac_dispatch = "{path}" }}\n[route.env]', 1))


def entry_point(env, transport):
    if transport == 'cli':
        p = subprocess.run([str(commands_route()), '--config', str(env.cfg), '--profile', 'grok-admin'],
                           input=b'{"host": "macbook"}', capture_output=True, timeout=60,
                           env={'PATH': '/usr/bin:/bin', 'SSH_ORIGINAL_COMMAND': 'queue'})
        out = p.stdout.decode() + p.stderr.decode()
        lines = [json.loads(x) for x in p.stdout.decode().splitlines()]
        assert p.returncode == 1 and len(lines) == 1, out
        return lines[0], out
    msg = {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
           'params': {'name': 'queue', 'arguments': {'host': 'macbook'}}}
    p = subprocess.run([str(commands_route()), '--config', str(env.cfg), '--profile', 'grok-admin'],
                       input=json.dumps(msg).encode() + b'\n', capture_output=True, timeout=60,
                       env={'PATH': '/usr/bin:/bin', 'SSH_ORIGINAL_COMMAND': 'mcp'})
    out = p.stdout.decode() + p.stderr.decode()
    result = [json.loads(x) for x in p.stdout.decode().splitlines()][-1]['result']
    assert result['isError'] is True, out
    return json.loads(result['content'][0]['text']), out


def commands_route():
    return Path(commands.__file__).with_name('jobroute')


@pytest.mark.parametrize('transport', ['cli', 'mcp'])
def test_entry_points_say_queue_timed_out(env, transport):
    home = mac_home(env.tmp, **QUEUE_LIMIT_ONLY)
    set_mode(home, 'queue-hang')
    route_process(env, home)
    answer, out = entry_point(env, transport)
    assert answer == {'ok': False, 'error': QUEUE_TIMED_OUT}
    assert 'backend failed' not in out and 'Traceback' not in out


# (b) ssh 255 keeps the unreachable text -------------------------------------------------------

@pytest.mark.parametrize('transport', ['cli', 'mcp'])
def test_entry_points_still_say_unreachable_on_ssh_failure(env, transport):
    route_process(env, None, UNREACHABLE)
    answer, out = entry_point(env, transport)
    assert answer == {'ok': False, 'error': UNREACHABLE_TEXT}
    assert QUEUE_TIMED_OUT not in out


def test_route_still_says_unreachable_on_ssh_failure(env):
    route, _ = route_with_mac(env)
    route.backends['mac_dispatch'] = str(broken_dispatcher(env.tmp / 'bin', UNREACHABLE))
    assert queue_error(route) == UNREACHABLE_TEXT


# (c) a job's deadline is still 124 / timed_out, never the queue text --------------------------

def test_job_deadline_is_still_timed_out_not_a_queue_refusal(env):
    route, _ = route_with_mac(env, **SHORT)
    p, job = run_job(env, route, 'hold')
    assert p.returncode == 124, p.stderr
    assert (job['exit_code'], job['outcome'], job['cause']) == (124, 'failure', 'timed_out')
    assert QUEUE_TIMED_OUT not in json.dumps(job)


# (d) every other queue code keeps its current text --------------------------------------------

@pytest.mark.parametrize('code', [1, 2, 3, 75, 124, 125, 143, 254, 255])
def test_runner_codes_on_queue_stay_generic(env, code):
    """The runner's own 124/255 are reported as 1, so they are not the queue limit or ssh; 75
    from `sb-macjob queue` (which never waits for the lock) is not Busy either."""
    route, home = route_with_mac(env)
    set_mode(home, f'queue-exit-{code}')
    assert queue_error(route) == GENERIC


def test_refusing_runner_75_stays_generic(env):
    route, home = route_with_mac(env)
    set_mode(home, 'refuse')   # the fixture runner exits 75 before reading the queue
    assert queue_error(route) == GENERIC


def test_queue_success_is_unchanged(env):
    route, _ = route_with_mac(env)
    assert route.command('cli', 'queue', {'host': 'macbook'}) == {'ok': True,
                                                                  'queue': {'holder': None, 'waiting': []}}


def test_shipped_queue_failure_table():
    assert commands.QUEUE_FAILURES == {255: UNREACHABLE_TEXT, 124: QUEUE_TIMED_OUT}
    assert commands.MAC_QUEUE_TIMED_OUT == QUEUE_TIMED_OUT
