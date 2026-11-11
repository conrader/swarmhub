"""Isolated worker installation regressions; no runner/workload is ever launched."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

import pytest

HERE = Path(__file__).parents[1]


def installed(tmp_path):
    source = Path(os.environ.get('FIXROUND3_SOURCE', str(HERE)))
    dest = tmp_path / 'install'
    dest.mkdir(mode=0o700)
    shutil.copyfile(source / 'mac-worker.py', dest / 'mac-worker.py')
    # Replay old worker with new helpers present too: it must actually enforce the pins.
    for name in ('mac_worker_lifecycle.py', 'mac_worker_state.py'):
        shutil.copyfile(HERE / name, dest / name)
    return dest


@pytest.mark.parametrize('role', ['outer', 'supervisor'])
@pytest.mark.parametrize('damage', ['missing', 'tampered', 'mixed'])
def test_isolated_worker_refuses_missing_tampered_or_mixed_helpers_before_launch(tmp_path, role, damage):
    dest = installed(tmp_path)
    helper = dest / 'mac_worker_state.py'
    if damage == 'missing':
        helper.unlink()
    elif damage == 'tampered':
        helper.write_text('raise RuntimeError("untrusted helper executed")')
    else:
        helper.write_text(helper.read_text() + '\n# stale release\n')
    args = [] if role == 'outer' else ['--workload', str(tmp_path / 'absent'), '{}', 'never-launched']
    p = subprocess.run([sys.executable, '-I', '-B', str(dest / 'mac-worker.py'), *args],
                       input=b'{}', capture_output=True, timeout=5)
    assert p.returncode == 2 and p.stderr == b'Mac worker refused helper installation\n'
    assert b'Traceback' not in p.stderr


def test_isolated_imports_ignore_hostile_cwd_and_pythonpath(tmp_path):
    dest = installed(tmp_path)
    hostile = tmp_path / 'hostile'
    hostile.mkdir()
    for name in ('mac_worker_state.py', 'mac_worker_lifecycle.py'):
        (hostile / name).write_text('raise RuntimeError("hostile import")')
    code = ('import runpy,sys; w=runpy.run_path(sys.argv[1]); '
            'assert len(w["HELPERS"]) == 2; print("trusted helpers loaded")')
    p = subprocess.run([sys.executable, '-I', '-B', '-c', code, str(dest / 'mac-worker.py')],
                       cwd=hostile, env={**os.environ, 'PYTHONPATH': str(hostile)}, capture_output=True, timeout=5)
    assert (p.returncode, p.stdout, p.stderr) == (0, b'trusted helpers loaded\n', b'')
