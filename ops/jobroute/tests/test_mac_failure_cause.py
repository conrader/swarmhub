"""A failed macjob says why when its exit code proves it: ssh failure (255) or the deadline (124).

ssh exits 255 when it cannot connect, the connection drops, or the remote command dies without
an exit status. mac-worker.py therefore never exits 255, and it reports its runner's own 124 as 1,
so at the route those two codes have one meaning each. Runs like test_mac_queue_fixtures: the
real worker and mac-dispatch as subprocesses, with ssh swapped for a local stand-in.
"""
import json
from pathlib import Path
import signal
import subprocess
import sys

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jobroute_core import Refused  # noqa: E402
from jobroute_jobs import MAC_CAUSES  # noqa: E402
from test_swap_commands import env  # noqa: E402,F401 (fixture: macjob/queue enabled for macbook)
from test_mac_queue_fixtures import (SHORT, SRC, _exe, assert_single_queue, mac_home, request,  # noqa: E402
                                     route_with_mac, run_worker, seen)
from test_completion_evidence import patch_record, status, submitted  # noqa: E402

# ssh stand-ins that never reach the worker: no route to the Mac, or ssh itself killed.
UNREACHABLE = '''#!/usr/bin/python3 -I
import sys
sys.stdin.buffer.read()
print('ssh: connect to host macbook port 22: No route to host', file=sys.stderr)
sys.exit(255)
'''
KILLED = '''#!/usr/bin/python3 -I
import os, signal
os.kill(os.getpid(), signal.SIGKILL)
'''


def broken_dispatcher(bin_dir, ssh_text):
    ssh = _exe(bin_dir / 'broken-ssh', ssh_text)
    text = (SRC / 'mac-dispatch').read_text()
    assert text.count("'/usr/bin/ssh'") == 1
    return _exe(bin_dir / 'mac-dispatch-broken', text.replace("'/usr/bin/ssh'", repr(str(ssh))))


def run_job(env, route, brief):
    """Submit through the route, run the recorded command as sb-codejob would, record its code."""
    out = route.command('cli', 'macjob', {'host': 'macbook', 'label': 'mac-check', 'brief': brief})
    [call] = env.calls()
    cmd = call['argv'][call['argv'].index('--') + 1:]
    assert cmd == [route.backends['mac_dispatch'], 'macbook']
    p = subprocess.run(cmd, input=call['stdin'], cwd=call['cwd'], capture_output=True,
                       env={'PATH': '/usr/bin:/bin', 'HOME': str(env.tmp / 'home')}, timeout=60)
    patch_record(env, out['job_id'], exit_code=p.returncode)
    return p, status(env, out['job_id'])


@pytest.mark.parametrize('code', [255, 124])
def test_worker_never_passes_on_a_reserved_code_from_its_runner(tmp_path, code):
    home = mac_home(tmp_path)
    rc, out, err = run_worker(home, request('reserved', f'exit {code}'))
    assert rc == 1 and out == 'result reserved ok\n'
    assert f'Mac worker: the runner exited {code}; reported as 1' in err
    assert ('end', 'reserved') in seen(home)


def test_worker_keeps_every_other_runner_code(tmp_path):
    home = mac_home(tmp_path)
    for code in (0, 3, 75, 123, 125, 254):
        rc, _, err = run_worker(home, request('kept', f'exit {code}'))
        assert rc == code and 'reported as' not in err


def test_dispatch_reports_ssh_failure_as_mac_connection_failed(env):
    route, home = route_with_mac(env)
    route.backends['mac_dispatch'] = str(broken_dispatcher(env.tmp / 'bin', UNREACHABLE))
    p, job = run_job(env, route, 'Shell task')
    assert p.returncode == 255 and b'No route to host' in p.stderr
    assert (job['exit_code'], job['outcome'], job['signal'], job['cause']) == (255, 'failure', None,
                                                                               'mac_connection_failed')
    assert not seen(home)


def test_dispatch_reports_a_killed_ssh_as_128_plus_n(env):
    route, _ = route_with_mac(env)
    route.backends['mac_dispatch'] = str(broken_dispatcher(env.tmp / 'bin', KILLED))
    p, job = run_job(env, route, 'Shell task')
    assert p.returncode == 128 + signal.SIGKILL
    assert (job['outcome'], job['signal'], job['cause']) == ('failure', signal.SIGKILL, None)


@pytest.mark.parametrize('brief,limits,code,cause', [
    ('exit 255', {}, 1, None),          # the job's own 255 is not an ssh failure
    ('exit 124', {}, 1, None),          # the job's own 124 is not the deadline
    ('exit 3', {}, 3, None),
    ('hold', SHORT, 124, 'timed_out'),  # stopped by the worker at its (short) deadline
    ('Shell task', {}, 0, None),
])
def test_cause_through_the_real_worker_and_dispatch(env, brief, limits, code, cause):
    route, home = route_with_mac(env, **limits)
    p, job = run_job(env, route, brief)
    assert p.returncode == code, p.stderr
    assert (job['exit_code'], job['cause']) == (code, cause)
    assert job['outcome'] == ('success' if code == 0 else 'failure')
    assert_single_queue(home)


@pytest.mark.parametrize('code', sorted(MAC_CAUSES))
def test_cause_is_only_inferred_for_macjob(env, code):
    # A claude/codex job's 255 or 124 is that engine's own code: nothing proves why.
    job_id = submitted(env)
    patch_record(env, job_id, exit_code=code)
    job = status(env, job_id)
    assert job['engine'] == 'claude' and (job['outcome'], job['cause']) == ('failure', None)


def test_cause_is_null_for_success(env):
    job = status(env, submitted(env))
    assert job['outcome'] == 'success' and job['cause'] is None


def test_queue_snapshot_says_mac_unreachable_on_ssh_failure(env):
    route, home = route_with_mac(env)
    good = route.backends['mac_dispatch']
    route.backends['mac_dispatch'] = str(broken_dispatcher(env.tmp / 'bin', UNREACHABLE))
    with pytest.raises(Refused, match='^Mac host unreachable; retry later$'):
        route.command('cli', 'queue', {'host': 'macbook'})
    # Any other failure keeps the generic text: the worker or runner failed, not the connection.
    route.backends['mac_dispatch'] = good
    (home / '.sb-macjob/mode').write_text('refuse')
    with pytest.raises(Refused, match='backend failed'):
        route.command('cli', 'queue', {'host': 'macbook'})


def test_shipped_cause_table():
    assert MAC_CAUSES == {255: 'mac_connection_failed', 124: 'timed_out'}
