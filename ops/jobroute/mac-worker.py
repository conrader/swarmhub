#!/usr/bin/python3 -IB
"""Remote shell worker: the existing sb-macjob runner owns the FIFO lock until descendants drain.

Install separately under the Mac user's .local/lib/swarmhub during a later approved pilot.
No browser, LaunchAgent, arbitrary argv, workdir, host, or queue bypass comes from the caller.
"""
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import signal
import shutil
import time
import tempfile

# Six hours bounds the TOTAL call, including queue wait, not a separate four-hour runtime.
# Cleanup may add up to GRACE seconds, followed by confirmation that signalled groups drained.
# The private supervisor keeps sb-macjob (and its queue lock) alive until workload descendants drain.
QUEUE_WAIT = 7200
RUN_LIMIT = 14400
QUEUE_LIMIT = 60
GRACE = 120
TIMED_OUT = 124  # GNU timeout's code; jobroute reports outcome "failure", cause "timed_out"
# Codes this worker reserves. ssh exits 255 when it cannot connect or the connection drops, so a
# 255 the route sees must never come from the Mac side; 124 must only mean "stopped at the limit".
# The runner's own 255 or 124 is reported as RESERVED_SUBSTITUTE, and stderr keeps the real code.
SSH_FAILED = 255
RESERVED_SUBSTITUTE = 1


def _status(proc):
    if getattr(proc, 'timed_out', False):
        return TIMED_OUT
    # sb-codejob and jobroute read death by signal n as exit 128+n; exiting with -n would report 256-n.
    code = proc.returncode
    code = 128 - code if code < 0 else code
    if code in (TIMED_OUT, SSH_FAILED):
        print(f'Mac worker: the runner exited {code}; reported as {RESERVED_SUBSTITUTE}', file=sys.stderr)
        return RESERVED_SUBSTITUTE
    return code


def _alive(pgid):
    rows = subprocess.check_output(['/bin/ps', '-axo', 'pgid=,stat='], text=True)
    return any(int(f[0]) == pgid and not f[1].startswith('Z')
               for row in rows.splitlines() if len(f := row.split()) == 2)


def _signal(pgid, sig):
    try:
        os.killpg(pgid, sig)
    except ProcessLookupError:
        pass


def _drain(pgid, deadline):
    while _alive(pgid):
        left = deadline - time.monotonic()
        if left <= 0:
            return False
        time.sleep(min(.02, left))
    return True


def _workload(control, argv):
    # Serialise launch and cancellation: a queued runner cannot start work after cancellation.
    with open(control, 'r+') as state:
        fcntl.flock(state, fcntl.LOCK_EX)
        record = json.load(state)
        if record.get('cancelled'):
            return TIMED_OUT
        child = subprocess.Popen(argv, start_new_session=True)
        state.seek(0)
        json.dump({'pgid': child.pid}, state)
        state.truncate()
        state.flush()
        fcntl.flock(state, fcntl.LOCK_UN)
        code = child.wait()
        # Do not let sb-macjob release its lock while grandchildren still hold the session.
        while _alive(child.pid):
            time.sleep(.02)
        return 128 - code if code < 0 else code


def _bounded(argv, limit, workload_control=None, **kw):
    """Own the runner session and the supervisor's workload session, including cleanup."""
    proc = subprocess.Popen(argv, start_new_session=True, **kw)
    try:
        proc.wait(timeout=limit)
        return proc
    except subprocess.TimeoutExpired:
        pass
    deadline = time.monotonic() + GRACE
    workload = None
    if workload_control is not None:
        try:
            with open(workload_control, 'r+') as state:
                fcntl.flock(state, fcntl.LOCK_EX)
                record = json.load(state)
                candidate = record.get('pgid')
                if candidate is not None:
                    if type(candidate) is not int or candidate <= 1 or candidate == os.getpgrp():
                        raise ValueError('invalid workload pgid')
                    workload = candidate
                state.seek(0)
                json.dump({**record, 'cancelled': True}, state)
                state.truncate()
        except (OSError, ValueError, TypeError, AttributeError):
            print('Mac worker: invalid workload control; stopping runner', file=sys.stderr)
    # Stop actual work first. The runner still owns its queue lock during this drain.
    if workload is not None:
        _signal(workload, signal.SIGTERM)
        if not _drain(workload, deadline):
            _signal(workload, signal.SIGKILL)
            # Fail closed: never release the lock or remove the workspace before confirmed drain.
            while not _drain(workload, time.monotonic() + 1):
                pass
    _signal(proc.pid, signal.SIGTERM)
    while proc.poll() is None and time.monotonic() < deadline:
        time.sleep(.02)
    if _alive(proc.pid):
        _signal(proc.pid, signal.SIGKILL)
    proc.wait()
    while not _drain(proc.pid, time.monotonic() + 1):
        pass
    print(f'Mac worker: stopped at its {limit} s limit', file=sys.stderr)
    proc.timed_out = True
    return proc


def run(request, home=None, execute=_bounded):
    home = Path(home or Path.home())
    env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin',
           'SB_MACJOB_QUEUE': '1'}
    if request.get('operation') == 'queue' and set(request) == {'operation', 'agent'}:
        return _status(execute([str(home / '.local/bin/sb-macjob'), 'queue', '--json'], QUEUE_LIMIT, env=env))
    if set(request) != {'operation', 'agent', 'label', 'brief'} or request['operation'] != 'macjob':
        raise ValueError('invalid request')
    for key, rx in [('agent', r'[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}'), ('label', r'[A-Za-z0-9][A-Za-z0-9_-]{0,39}')]:
        if not isinstance(request[key], str) or not re.fullmatch(rx, request[key]) or '..' in request[key]:
            raise ValueError('invalid identity')
    brief = request['brief']
    if not isinstance(brief, str) or not brief.strip() or '\0' in brief or len(brief.encode()) > 65536:
        raise ValueError('invalid brief')
    # Dedicated workspace avoids another session's checkout. sb-macjob uses the host's shared default queue.
    root = home / 'work/swarmhub-jobs'
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    folder = tempfile.mkdtemp(prefix=request['label'] + '-', dir=root)
    control_dir = tempfile.mkdtemp(prefix='control-', dir=root)
    finished = False
    try:
        control = Path(control_dir) / '.workload.json'
        control.write_text('{}')
        with tempfile.TemporaryFile() as stream:
            stream.write(brief.encode()); stream.seek(0)
            code = _status(execute([str(home / '.local/bin/sb-macjob'), '--agent', request['agent'],
                '--label', request['label'], '--workdir', folder, '--queue-wait', str(QUEUE_WAIT), '--',
                sys.executable, '-I', '-B', str(Path(__file__).resolve()), '--workload', str(control),
                str(home / '.local/bin/claude'), '-p', '--permission-mode', 'acceptEdits'],
                QUEUE_WAIT + RUN_LIMIT, workload_control=control, stdin=stream, env=env))
            finished = True
            return code
    finally:
        # An error during cancellation/drain must leave evidence and the live workspace intact.
        if finished:
            shutil.rmtree(folder)
            shutil.rmtree(control_dir)


if __name__ == '__main__':
    if len(sys.argv) > 3 and sys.argv[1] == '--workload':
        raise SystemExit(_workload(sys.argv[2], sys.argv[3:]))
    try:
        raw = sys.stdin.buffer.read(140000)
        raise SystemExit(run(json.loads(raw)))
    except (ValueError, OSError):
        print('Mac worker refused request', file=sys.stderr)
        raise SystemExit(2)
