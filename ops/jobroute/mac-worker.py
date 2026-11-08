#!/usr/bin/python3 -IB
"""Remote shell worker: the existing sb-macjob runner owns the FIFO lock until descendants drain.

Install separately under the Mac user's .local/lib/swarmhub during a later approved pilot.
No browser, LaunchAgent, arbitrary argv, workdir, host, or queue bypass comes from the caller.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

# A job holds the host's shared FIFO queue for at most QUEUE_WAIT (waiting) + RUN_LIMIT (running),
# so one hung job cannot block every other bot's Mac work. At the deadline the worker sends TERM:
# sb-macjob stops the job's process group and still sends its wake. GRACE seconds later the
# runner is KILLed. Operator constants only: no caller field or environment changes them.
QUEUE_WAIT = 7200
RUN_LIMIT = 14400
QUEUE_LIMIT = 60
GRACE = 120
TIMED_OUT = 124  # GNU timeout's code; jobroute reports it as outcome "failure" with signal null


def _status(proc):
    # sb-codejob and jobroute read death by signal n as exit 128+n; exiting with -n would report 256-n.
    code = proc.returncode
    return 128 - code if code < 0 else code


def _bounded(argv, limit, **kw):
    """Run argv; past `limit` seconds TERM it (KILL after GRACE) and report TIMED_OUT."""
    proc = subprocess.Popen(argv, **kw)
    try:
        proc.wait(timeout=limit)
        return proc
    except subprocess.TimeoutExpired:
        pass
    proc.terminate()
    try:
        proc.wait(timeout=GRACE)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()
    print(f'Mac worker: stopped at its {limit} s limit', file=sys.stderr)
    proc.returncode = TIMED_OUT
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
    with tempfile.TemporaryDirectory(prefix=request['label'] + '-', dir=root) as folder:
        with tempfile.TemporaryFile() as stream:
            stream.write(brief.encode()); stream.seek(0)
            return _status(execute([str(home / '.local/bin/sb-macjob'), '--agent', request['agent'],
                '--label', request['label'], '--workdir', folder, '--queue-wait', str(QUEUE_WAIT), '--',
                str(home / '.local/bin/claude'), '-p', '--permission-mode', 'acceptEdits'],
                QUEUE_WAIT + RUN_LIMIT, stdin=stream, env=env))


if __name__ == '__main__':
    try:
        raw = sys.stdin.buffer.read(140000)
        raise SystemExit(run(json.loads(raw)))
    except (ValueError, OSError):
        print('Mac worker refused request', file=sys.stderr)
        raise SystemExit(2)
