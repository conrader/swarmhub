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


def run(request, home=None, execute=subprocess.run):
    home = Path(home or Path.home())
    env = {'HOME': str(home), 'PATH': f'{home}/.local/bin:/opt/homebrew/bin:/usr/bin:/bin',
           'SB_MACJOB_QUEUE': '1'}
    if request.get('operation') == 'queue' and set(request) == {'operation', 'agent'}:
        return execute([str(home / '.local/bin/sb-macjob'), 'queue', '--json'], env=env, check=False).returncode
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
            return execute([str(home / '.local/bin/sb-macjob'), '--agent', request['agent'], '--label', request['label'],
                '--workdir', folder, '--', str(home / '.local/bin/claude'), '-p', '--permission-mode', 'acceptEdits'],
                stdin=stream, env=env, check=False).returncode


if __name__ == '__main__':
    try:
        raw = sys.stdin.buffer.read(140000)
        raise SystemExit(run(json.loads(raw)))
    except (ValueError, OSError):
        print('Mac worker refused request', file=sys.stderr)
        raise SystemExit(2)
