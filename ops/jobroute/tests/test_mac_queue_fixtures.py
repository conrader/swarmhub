"""Offline Mac queue handoff: mac-worker.py runs as a real subprocess in a scratch HOME.

The fixture sb-macjob owns ONE default queue (an flock'd lock plus an event log) and refuses
SB_MACJOB_QUEUE_DIR, so a worker that opened a second queue would fail loudly. The fixture
claude records the brief it received. No ssh, no real sb-macjob, no Mac and no live app:
ssh is a local stand-in that execs the installed worker, as sshd would on the Mac.
"""
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import sys
import time

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jobroute_core import Route, Refused  # noqa: E402
from test_swap_commands import env  # noqa: E402,F401 (fixture: macjob/queue enabled for macbook)

SRC = Path(__file__).resolve().parents[1]
WORKER = '.local/lib/swarmhub/mac-worker.py'

RUNNER = r'''#!/usr/bin/python3 -I
import fcntl, json, os, signal, subprocess, sys, time
home = os.environ['HOME']
base = os.path.join(home, '.sb-macjob')
qdir = os.path.join(base, 'queue')            # the host's single default queue
def events():
    path = os.path.join(qdir, 'events.jsonl')
    return [json.loads(x) for x in open(path)] if os.path.exists(path) else []
def log(**e):
    e.update(t=time.time(), pid=os.getpid())
    with open(os.path.join(qdir, 'events.jsonl'), 'a') as f:
        f.write(json.dumps(e) + '\n')
if os.environ.get('SB_MACJOB_QUEUE') != '1' or 'SB_MACJOB_QUEUE_DIR' in os.environ:
    print('fixture sb-macjob: queue override refused', file=sys.stderr); sys.exit(64)
os.makedirs(qdir, exist_ok=True)
mode_file = os.path.join(base, 'mode')
mode = open(mode_file).read().strip() if os.path.exists(mode_file) else ''
if mode == 'refuse':
    print('fixture sb-macjob: runner unavailable', file=sys.stderr); sys.exit(75)
argv = sys.argv[1:]
if argv == ['queue', '--json']:
    ev = events()
    started = [e['label'] for e in ev if e['ev'] == 'start']
    ended = {e['label'] for e in ev if e['ev'] == 'end'}
    holder = [l for l in started if l not in ended]
    print(json.dumps({'holder': holder[0] if holder else None,
                      'waiting': [e['label'] for e in ev if e['ev'] == 'enqueue' and e['label'] not in started]}))
    sys.exit(0)
if len(argv) < 8 or argv[0:7:2] != ['--agent', '--label', '--workdir', '--']:
    print('fixture sb-macjob: bad argv', file=sys.stderr); sys.exit(64)
label, workdir, cmd = argv[3], argv[5], argv[7:]
log(ev='enqueue', label=label, agent=argv[1], workdir=workdir, env=sorted(os.environ))
lock = open(os.path.join(qdir, 'lock'), 'w')
fcntl.flock(lock, fcntl.LOCK_EX)              # FIFO-by-lock: one job at a time
log(ev='start', label=label)
if mode == 'kill':
    os.kill(os.getpid(), signal.SIGKILL)
rc = subprocess.run(cmd, cwd=workdir).returncode
log(ev='end', label=label, rc=rc)
sys.exit(rc)
'''

CLAUDE = r'''#!/usr/bin/python3 -I
import hashlib, json, os, sys, time
assert sys.argv[1:] == ['-p', '--permission-mode', 'acceptEdits'], sys.argv
brief = sys.stdin.buffer.read()
home = os.environ['HOME']
label = os.path.basename(os.getcwd()).rsplit('-', 1)[0]
with open(os.path.join(home, '.sb-macjob/briefs.jsonl'), 'a') as f:
    f.write(json.dumps({'label': label, 'cwd': os.getcwd(), 'sha': hashlib.sha256(brief).hexdigest()}) + '\n')
words = brief.decode().split()
if 'hold' in words:
    for _ in range(3000):
        if os.path.exists(os.path.join(home, 'release')):
            break
        time.sleep(0.01)
open('result.txt', 'w').write(label)
print('result ' + label + ' ok')
sys.exit(int(words[words.index('exit') + 1]) if 'exit' in words else 0)
'''

SSH = r'''#!/usr/bin/python3 -I
import os, sys
HOME = {home!r}
if sys.argv[1:] != ['-T', '-oBatchMode=yes', '-oStrictHostKeyChecking=yes', '-oUpdateHostKeys=no',
                    '--', 'macbook', {worker!r}]:
    print('fixture ssh: unexpected argv', sys.argv, file=sys.stderr); sys.exit(99)
os.chdir(HOME)
os.execve({worker!r}, [{worker!r}], {{'HOME': HOME, 'PATH': '/usr/bin:/bin'}})
'''


def _exe(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(0o755)
    return path


def mac_home(root):
    """Scratch Mac HOME with the worker installed where mac-dispatch's ssh command expects it."""
    home = root / 'mac'
    _exe(home / '.local/bin/sb-macjob', RUNNER)
    _exe(home / '.local/bin/claude', CLAUDE)
    _exe(home / WORKER, (SRC / 'mac-worker.py').read_text())
    (home / '.sb-macjob').mkdir(exist_ok=True)
    return home


def dispatcher(bin_dir, home):
    """The real mac-dispatch with only its /usr/bin/ssh swapped for the local stand-in."""
    ssh = _exe(bin_dir / 'fixture-ssh', SSH.format(home=str(home), worker=WORKER))
    text = (SRC / 'mac-dispatch').read_text()
    assert text.count("'/usr/bin/ssh'") == 1
    return _exe(bin_dir / 'mac-dispatch', text.replace("'/usr/bin/ssh'", repr(str(ssh))))


def request(label, brief, agent='Admin'):
    return {'operation': 'macjob', 'agent': agent, 'label': label, 'brief': brief}


def caller_env(home):
    # Noise the worker must not forward: an API key and a second queue directory.
    return {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'ANTHROPIC_API_KEY': 'must-not-leak',
            'SB_MACJOB_QUEUE_DIR': str(home / 'second-queue')}


def start(home, req):
    p = subprocess.Popen([str(home / WORKER)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=caller_env(home), cwd=home)
    p.stdin.write(req if isinstance(req, bytes) else json.dumps(req).encode())
    p.stdin.close()
    return p


def finish(p):
    out, err = p.stdout.read(), p.stderr.read()
    p.wait(timeout=60)
    return p.returncode, out.decode(), err.decode()


def run_worker(home, req):
    return finish(start(home, req))


def events(home):
    path = home / '.sb-macjob/queue/events.jsonl'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


def seen(home):
    return [(e['ev'], e['label']) for e in events(home)]


def wait_for(home, item):
    for _ in range(2000):
        if item in seen(home):
            return
        time.sleep(0.01)
    raise AssertionError(f'{item} never happened: {seen(home)}')


def briefs(home):
    path = home / '.sb-macjob/briefs.jsonl'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []


def assert_single_queue(home):
    assert list(home.rglob('lock')) == [home / '.sb-macjob/queue/lock'] and not (home / 'second-queue').exists()


def hold_two(home, first_brief, second_brief):
    """first holds the queue until released; second is submitted meanwhile and must wait."""
    a = start(home, request('first', first_brief))
    wait_for(home, ('start', 'first'))
    b = start(home, request('second', second_brief))
    wait_for(home, ('enqueue', 'second'))
    rc, out, _ = run_worker(home, {'operation': 'queue', 'agent': 'Admin'})
    assert rc == 0 and json.loads(out) == {'holder': 'first', 'waiting': ['second']}
    assert ('start', 'second') not in seen(home)
    (home / 'release').touch()
    return finish(a), finish(b)


def test_two_queued_submissions_run_in_order_through_one_queue(tmp_path):
    home = mac_home(tmp_path)
    (rc_a, out_a, _), (rc_b, out_b, _) = hold_two(home, 'hold first brief', 'second $(id) brief')
    assert (rc_a, out_a, rc_b, out_b) == (0, 'result first ok\n', 0, 'result second ok\n')
    order = [x for x in seen(home) if x[0] in ('start', 'end')]
    assert order == [('start', 'first'), ('end', 'first'), ('start', 'second'), ('end', 'second')]
    assert_single_queue(home)
    got = {b['label']: b for b in briefs(home)}
    assert got['first']['sha'] == hashlib.sha256(b'hold first brief').hexdigest()
    assert got['second']['sha'] == hashlib.sha256(b'second $(id) brief').hexdigest()
    jobs = home / 'work/swarmhub-jobs'
    assert got['first']['cwd'] != got['second']['cwd']
    assert all(Path(b['cwd']).parent == jobs for b in got.values()) and not list(jobs.iterdir())
    for e in events(home):
        if e['ev'] == 'enqueue':
            assert {'HOME', 'PATH', 'SB_MACJOB_QUEUE'} <= set(e['env']) and e['agent'] == 'Admin'
            assert not {'ANTHROPIC_API_KEY', 'SB_MACJOB_QUEUE_DIR'} & set(e['env'])


def test_failed_job_reports_its_code_and_releases_the_queue(tmp_path):
    home = mac_home(tmp_path)
    (rc_a, out_a, _), (rc_b, out_b, _) = hold_two(home, 'hold exit 3', 'next')
    assert (rc_a, rc_b) == (3, 0) and out_b == 'result second ok\n'
    assert [e.get('rc') for e in events(home) if e['ev'] == 'end'] == [3, 0]
    assert_single_queue(home)


def test_runner_refusal_propagates_without_running_the_job(tmp_path):
    home = mac_home(tmp_path)
    (home / '.sb-macjob/mode').write_text('refuse')
    rc, out, err = run_worker(home, request('refused', 'brief'))
    assert (rc, out) == (75, '') and 'runner unavailable' in err
    assert not briefs(home) and not list((home / 'work/swarmhub-jobs').iterdir())


def test_runner_killed_by_signal_reports_128_plus_n_and_queue_recovers(tmp_path):
    home = mac_home(tmp_path)
    (home / '.sb-macjob/mode').write_text('kill')
    rc, _, _ = run_worker(home, request('killed', 'brief'))
    assert rc == 128 + signal.SIGKILL and not briefs(home)
    (home / '.sb-macjob/mode').unlink()
    assert run_worker(home, request('after', 'brief'))[0] == 0
    assert ('end', 'after') in seen(home) and ('end', 'killed') not in seen(home)
    assert_single_queue(home)


def test_missing_runner_is_a_refusal(tmp_path):
    home = mac_home(tmp_path)
    (home / '.local/bin/sb-macjob').unlink()
    rc, out, err = run_worker(home, request('nobody', 'brief'))
    assert (rc, out, err) == (2, '', 'Mac worker refused request\n')


@pytest.mark.parametrize('raw', [
    b'not json',
    json.dumps({**request('x', 'brief'), 'workdir': '/tmp'}).encode(),
    json.dumps(request('../x', 'brief')).encode(),
    json.dumps(request('x', '   ')).encode(),
    json.dumps({'operation': 'queue', 'agent': 'Admin', 'dir': '/tmp/q'}).encode(),
])
def test_rejected_request_never_reaches_the_runner(tmp_path, raw):
    home = mac_home(tmp_path)
    rc, out, err = run_worker(home, raw)
    assert (rc, out, err) == (2, '', 'Mac worker refused request\n') and not events(home)


def route_with_mac(env):
    home = mac_home(env.tmp)
    route = Route(str(env.cfg), 'grok-admin')
    route.backends['mac_dispatch'] = str(dispatcher(env.tmp / 'bin', home))
    return route, home


def test_queue_snapshot_propagates_through_route_and_dispatch(env):
    route, home = route_with_mac(env)
    assert route.command('cli', 'queue', {'host': 'macbook'}) == {'ok': True, 'queue': {'holder': None, 'waiting': []}}
    (home / '.sb-macjob/mode').write_text('refuse')
    with pytest.raises(Refused, match='backend failed'):
        route.command('cli', 'queue', {'host': 'macbook'})
    assert not list(home.rglob('lock')) and not (home / 'second-queue').exists()


@pytest.mark.parametrize('brief,mode,code,outcome,sig', [
    ('Shell task', '', 0, 'success', None),
    ('exit 3', '', 3, 'failure', None),
    ('Shell task', 'refuse', 75, 'failure', None),
    ('Shell task', 'kill', 128 + signal.SIGKILL, 'failure', signal.SIGKILL),
])
def test_job_result_propagates_to_job_status(env, brief, mode, code, outcome, sig):
    route, home = route_with_mac(env)
    if mode:
        (home / '.sb-macjob/mode').write_text(mode)
    out = route.command('cli', 'macjob', {'host': 'macbook', 'label': 'mac-check', 'brief': brief})
    # The stub sb-codejob records the detached command; run it exactly as sb-codejob would.
    [call] = env.calls()
    cmd = call['argv'][call['argv'].index('--') + 1:]
    assert cmd == [route.backends['mac_dispatch'], 'macbook']
    assert json.loads(call['stdin']) == request('mac-check', brief)
    p = subprocess.run(cmd, input=call['stdin'], cwd=call['cwd'], capture_output=True,
                       env={'PATH': '/usr/bin:/bin', 'HOME': str(env.tmp / 'home')}, timeout=60)
    assert p.returncode == code, p.stderr
    assert p.stdout == (b'' if mode else b'result mac-check ok\n')
    # sb-codejob writes the command's exit status into the job record; jobroute reads it back.
    path = env.tmp / 'work/Admin' / f"{out['job_id']}.json"
    rec = json.loads(path.read_text())
    rec['exit_code'] = p.returncode
    path.write_text(json.dumps(rec))
    rc, [st] = env.run(f"status job={out['job_id']}")
    [job] = st['jobs']
    assert rc == 0 and (job['exit_code'], job['outcome'], job['signal']) == (code, outcome, sig)
    if mode == 'refuse':
        assert not list(home.rglob('lock')) and not briefs(home)
    else:
        assert_single_queue(home)
