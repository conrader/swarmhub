"""Offline Mac queue handoff: mac-worker.py runs as a real subprocess in a scratch HOME.

The fixture sb-macjob owns ONE default queue (an flock'd lock plus an event log) and refuses
SB_MACJOB_QUEUE_DIR, so a worker that opened a second queue would fail loudly. The fixture
claude records the brief it received. No ssh, no real sb-macjob, no Mac and no live app:
ssh is a local stand-in that execs the installed worker, as sshd would on the Mac.
"""
import hashlib
import json
import os
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
# Worker copies with second-scale limits: a job deadline of QUEUE_WAIT + RUN_LIMIT = 3 s.
SHORT = {'QUEUE_WAIT': 1, 'RUN_LIMIT': 2, 'GRACE': 3, 'QUEUE_LIMIT': 1}

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
if argv == ['queue', '--json'] and mode.startswith('queue-exit-'):   # the runner's own code
    sys.exit(int(mode[len('queue-exit-'):]))
if argv == ['queue', '--json'] and mode == 'queue-stubborn':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(30)
if argv == ['queue', '--json'] and mode == 'queue-hang':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    time.sleep(30)
if argv == ['queue', '--json']:
    ev = events()
    started = [e['label'] for e in ev if e['ev'] == 'start']
    ended = {e['label'] for e in ev if e['ev'] == 'end'}
    holder = [l for l in started if l not in ended]
    print(json.dumps({'holder': holder[0] if holder else None,
                      'waiting': [e['label'] for e in ev if e['ev'] == 'enqueue' and e['label'] not in started]}))
    sys.exit(0)
if len(argv) < 10 or argv[0:9:2] != ['--agent', '--label', '--workdir', '--queue-wait', '--']:
    print('fixture sb-macjob: bad argv', file=sys.stderr); sys.exit(64)
label, workdir, queue_wait, cmd = argv[3], argv[5], int(argv[7]), argv[9:]
log(ev='enqueue', label=label, agent=argv[1], workdir=workdir, queue_wait=queue_wait, env=sorted(os.environ))
child = None
def stop(signum, frame):
    # Like sb-macjob: TERM stops the job's whole process group, then the runner exits 143.
    if child is not None:
        try:
            os.killpg(child.pid, signal.SIGKILL)   # no child.wait(): the interrupted wait holds its lock
        except ProcessLookupError:
            pass
    log(ev='stopped', label=label)
    sys.exit(143)
signal.signal(signal.SIGTERM, signal.SIG_IGN if mode == 'stubborn' else stop)
lock = open(os.path.join(qdir, 'lock'), 'w')
fcntl.flock(lock, fcntl.LOCK_EX)              # FIFO-by-lock: one job at a time
previous = os.path.join(home, 'workload.pids')
previous_pids = set(map(int, open(previous).read().split())) if os.path.exists(previous) else set()
rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,stat='], text=True)
previous_live = [int(f[0]) for row in rows.splitlines() if len(f := row.split()) == 2
                 and int(f[0]) in previous_pids and not f[1].startswith('Z')]
log(ev='start', label=label, previous_live=previous_live)
if mode == 'kill':
    os.kill(os.getpid(), signal.SIGKILL)
# The worker drains the workload session before releasing this runner. Keep its pipes
# attached so this fixture also verifies output survives the next queue handoff.
child = subprocess.Popen(cmd, cwd=workdir, start_new_session=True)
rc = child.wait()
log(ev='end', label=label, rc=rc)
sys.exit(rc)
'''

CLAUDE = r'''#!/usr/bin/python3 -I
import hashlib, json, os, signal, subprocess, sys, time
assert sys.argv[1:] == ['-p', '--permission-mode', 'acceptEdits'], sys.argv
brief = sys.stdin.buffer.read()
home = os.environ['HOME']
label = os.path.basename(os.getcwd()).rsplit('-', 1)[0]
with open(os.path.join(home, '.sb-macjob/briefs.jsonl'), 'a') as f:
    f.write(json.dumps({'label': label, 'cwd': os.getcwd(), 'sha': hashlib.sha256(brief).hexdigest()}) + '\n')
words = brief.decode().split()
if 'hold' in words:
    mode_path = os.path.join(home, '.sb-macjob/mode')
    if os.path.exists(mode_path) and open(mode_path).read().strip() == 'stubborn':
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        descendant = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)'])
        with open(os.path.join(home, 'workload.pids'), 'w') as f:
            f.write(f'{os.getpid()} {descendant.pid}')
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


def install_worker(home, path=WORKER, **limits):
    """The real worker; `limits` swaps its operator constants (e.g. RUN_LIMIT=1) in this copy only."""
    text = (SRC / 'mac-worker.py').read_text()
    for name, value in limits.items():
        line = next(x for x in text.splitlines() if x.startswith(name + ' = '))
        assert text.count(line + '\n') == 1
        text = text.replace(line + '\n', f'{name} = {value!r}\n')
    return _exe(home / path, text)


def mac_home(root, **limits):
    """Scratch Mac HOME with the worker installed where mac-dispatch's ssh command expects it."""
    home = root / 'mac'
    _exe(home / '.local/bin/sb-macjob', RUNNER)
    _exe(home / '.local/bin/claude', CLAUDE)
    install_worker(home, **limits)
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


def start(home, req, worker=WORKER):
    p = subprocess.Popen([str(home / worker)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, env=caller_env(home), cwd=home)
    p.stdin.write(req if isinstance(req, bytes) else json.dumps(req).encode())
    p.stdin.close()
    return p


def finish(p, timeout=60, cleanup_pids=()):
    # start() has already closed stdin; communicate must not flush that closed stream.
    p.stdin = None
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        # Snapshot descendants while the worker is still their ancestor. Signal only exact PIDs
        # belonging to this fixture, never a name, session or process group.
        rows = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid='], text=True, timeout=1)
        descendants = {p.pid, *cleanup_pids}
        pairs = [tuple(map(int, row.split())) for row in rows.splitlines()]
        while True:
            found = {pid for pid, parent in pairs if parent in descendants}
            if found <= descendants:
                break
            descendants.update(found)
        for pid in descendants - {p.pid}:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        p.kill()
        p.wait(timeout=5)
        p.stdout.close()
        p.stderr.close()
        raise
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


def test_worker_passes_its_queue_wait_and_keeps_production_limits(tmp_path):
    home = mac_home(tmp_path)
    assert run_worker(home, request('plain', 'brief'))[0] == 0
    [enq] = [e for e in events(home) if e['ev'] == 'enqueue']
    text = (SRC / 'mac-worker.py').read_text()
    # The shipped constants: a six-hour total call budget, plus up to two minutes cleanup.
    for line in ('QUEUE_WAIT = 7200\n', 'RUN_LIMIT = 14400\n', 'GRACE = 120\n', 'QUEUE_LIMIT = 60\n'):
        assert text.count(line) == 1
    assert enq['queue_wait'] == 7200


def test_hung_job_is_stopped_at_its_deadline_and_the_waiting_job_runs(tmp_path):
    home = mac_home(tmp_path, **SHORT)
    # The waiting job comes through a worker copy with production limits, so only the hung one times out.
    install_worker(home, '.local/lib/swarmhub/patient-worker.py')
    t0 = time.monotonic()
    a = start(home, request('hung', 'hold forever'))
    wait_for(home, ('start', 'hung'))
    b = start(home, request('waiting', 'next'), '.local/lib/swarmhub/patient-worker.py')
    wait_for(home, ('enqueue', 'waiting'))
    rc_a, out_a, err_a = finish(a)
    took = time.monotonic() - t0
    rc_b, out_b, _ = finish(b)
    assert (rc_a, out_a) == (124, '') and 'Mac worker: stopped at its 3 s limit' in err_a
    assert 2.5 < took < 3 + SHORT['GRACE'], took   # TERM worked: no wait for the KILL grace
    assert (rc_b, out_b) == (0, 'result waiting ok\n')
    order = [x for x in seen(home) if x[0] in ('start', 'stopped', 'end')]
    assert order[0] == ('start', 'hung')
    assert order[1] in [('end', 'hung'), ('stopped', 'hung')]
    assert order[2:] == [('start', 'waiting'), ('end', 'waiting')]
    assert_single_queue(home)
    assert not list((home / 'work/swarmhub-jobs').iterdir())


def test_runner_that_ignores_term_is_killed_after_the_grace(tmp_path):
    home = mac_home(tmp_path, **SHORT)
    (home / '.sb-macjob/mode').write_text('stubborn')
    t0 = time.monotonic()
    install_worker(home, '.local/lib/swarmhub/patient-worker.py')
    first = start(home, request('stubborn', 'hold forever'))
    wait_for(home, ('start', 'stubborn'))
    second = start(home, request('after', 'brief'), '.local/lib/swarmhub/patient-worker.py')
    wait_for(home, ('enqueue', 'after'))
    rc, out, err = finish(first)
    took = time.monotonic() - t0
    assert (rc, out) == (124, '') and 'stopped at its 3 s limit' in err
    assert 3 + SHORT['GRACE'] - .5 < took < 3 + SHORT['GRACE'] + 5, took
    assert finish(second)[:2] == (0, 'result after ok\n')
    from test_backend_route_timeout import alive
    assert not any(alive(int(pid)) for pid in (home / 'workload.pids').read_text().split())
    order = seen(home)
    assert order.index(('end', 'stubborn')) < order.index(('start', 'after'))
    assert next(e for e in events(home) if e['ev'] == 'start' and e['label'] == 'after')['previous_live'] == []
    assert not (home / 'release').exists()
    assert not list((home / 'work/swarmhub-jobs').iterdir())
    assert_single_queue(home)


def test_hung_queue_snapshot_is_stopped_at_its_limit(tmp_path):
    home = mac_home(tmp_path, **SHORT)
    (home / '.sb-macjob/mode').write_text('queue-hang')
    t0 = time.monotonic()
    rc, out, err = run_worker(home, {'operation': 'queue', 'agent': 'Admin'})
    assert (rc, out) == (124, '') and 'stopped at its 1 s limit' in err
    assert time.monotonic() - t0 < 1 + SHORT['GRACE']


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


def route_with_mac(env, **limits):
    home = mac_home(env.tmp, **limits)
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
    ('hold', 'limit', 124, 'failure', None),
])
def test_job_result_propagates_to_job_status(env, brief, mode, code, outcome, sig):
    route, home = route_with_mac(env, **(SHORT if mode == 'limit' else {}))
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
    if mode == 'limit':
        assert b'stopped at its 3 s limit' in p.stderr and any((ev, 'mac-check') in seen(home) for ev in ('end', 'stopped'))
    if mode == 'refuse':
        assert not list(home.rglob('lock')) and not briefs(home)
    else:
        assert_single_queue(home)


def test_finish_drains_stderr_without_deadlock(tmp_path):
    p = subprocess.Popen([sys.executable, '-c',
        "import sys; sys.stderr.write('e' * 200000); print('ok')"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert finish(p, timeout=5) == (0, 'ok\n', 'e' * 200000)


def test_finish_bounds_pipe_holding_descendant(tmp_path):
    pid_file = tmp_path / 'descendant.pid'
    program = ("import subprocess, sys; from pathlib import Path; "
               "child = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(30)']); "
               f"Path({str(pid_file)!r}).write_text(str(child.pid))")
    p = subprocess.Popen([sys.executable, '-c', program],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 5
    while not pid_file.exists() and time.monotonic() < deadline:
        time.sleep(.01)
    assert pid_file.exists()
    descendant = int(pid_file.read_text())
    started = time.monotonic()
    with pytest.raises(subprocess.TimeoutExpired):
        finish(p, timeout=.2, cleanup_pids=[descendant])
    assert time.monotonic() - started < 1.5
    assert p.poll() is not None
    from test_backend_route_timeout import wait_gone
    assert wait_gone([descendant]) == []
