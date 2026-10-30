"""Installer/rollback P2 follow-ups (jobroute-xrev2-verdict.md): full undo after real use, and a
stale install-state.new. Same scratch-HOME harness as test_installer.py (sbtest user/PID NS plus
a private mount NS binding a marked HOME over /home/ubuntu).
"""
import json
import os

import pytest

from test_installer import BASE, artifact, installer, snapshot  # noqa: F401  (fixtures)

# Scratch-HOME stand-in for sb-codejob at the shipped config's path: writes a finished status
# file where the real one would and prints its path. It never runs the engine.
SB_STUB = '''#!/usr/bin/python3 -I
import datetime, json, pathlib, sys
argv = sys.argv[1:]
sys.stdin.buffer.read()
arg = lambda k: argv[argv.index(k) + 1]
ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
status = pathlib.Path('/home/ubuntu/work') / arg('--agent') / f"{ts}-{arg('--label')}.json"
status.write_text(json.dumps({'tool': 'sb-codejob', 'pid': None, 'ended': ts, 'exit_code': 0,
                              'cmd': argv[argv.index('--') + 1:], 'workdir': arg('--workdir')}))
print(f'status {status}')
'''
ROUTE = ('/home/ubuntu/.local/lib/jobroute/current/jobroute --config /home/ubuntu/.config/jobroute/allowlist.toml '
         '--profile grok-admin')
# The shipped route PATH includes /usr/local/bin: a trusted stub claude is bound there, in the
# private mount namespace only.
USE = ('sed -i "s/submissions_enabled = false/submissions_enabled = true/" /home/ubuntu/.config/jobroute/allowlist.toml; '
       'sed -i "/\\[defaults\\]/a submissions_enabled = true" /home/ubuntu/.config/jobroute/allowlist.toml; '
       'mount --bind "$FAKEBIN" /usr/local/bin; '
       f'out=$(printf "Real use before rollback.\\n" | SSH_ORIGINAL_COMMAND="submit engine=claude label=undo-check" {ROUTE}); '
       'echo "$out"; grep -q \'"ok": true\' <<<"$out"; '
       f'SSH_ORIGINAL_COMMAND=status {ROUTE} | grep -q \'"label": "undo-check"\'')


def plant_sb_codejob(installer):
    """sb and work exist on ovh too; they are part of the baseline, never touched by rollback."""
    sb = installer.home / 'sb/bin'
    sb.mkdir(parents=True)
    (sb / 'sb-codejob').write_text(SB_STUB)
    (sb / 'sb-codejob').chmod(0o755)
    (installer.home / 'work/Admin').mkdir(parents=True)
    fakebin = installer.root / 'fakebin'
    fakebin.mkdir()
    (fakebin / 'claude').write_text('#!/bin/sh\nexit 0\n')
    (fakebin / 'claude').chmod(0o755)
    return fakebin


def use(installer, fakebin):
    p = installer.run(f'export FAKEBIN={fakebin}; {USE}')
    assert p.returncode == 0, p.stdout + p.stderr
    cfg = installer.home / '.config/jobroute/allowlist.toml'
    cfg.write_text(cfg.read_text().replace('[defaults]\nsubmissions_enabled = true', '[defaults]').replace('submissions_enabled = true', 'submissions_enabled = false'))
    state = installer.home / '.local/state/jobroute'
    assert (state / '.lock').is_file()
    assert 'undo-check' in (state / 'profiles/grok-admin.jsonl').read_text()
    [job] = (installer.home / 'work/Admin').glob('*-undo-check.json')
    return job.stem


def without_job_files(rows, job_id):
    """sb-codejob's own status file (work/<agent>/<job>.json) is not jobroute state."""
    return [r for r in rows if r[0] != f'work/Admin/{job_id}.json']


@pytest.mark.parametrize('prepopulated', [False, True])
def test_full_rollback_after_real_submit_matches_baseline(installer, prepopulated):
    fakebin = plant_sb_codejob(installer)
    if prepopulated:
        for name in ('.config/user', '.local/lib/user', '.local/state/user', '.ssh'):
            path = installer.home / name
            path.mkdir(parents=True, exist_ok=True)
            (path / 'keep').write_bytes(b'user content\n')
    baseline = snapshot(installer.home)
    installer.install()
    job_id = use(installer, fakebin)
    p = installer.undo()
    assert p.returncode == 0, p.stdout + p.stderr
    after = snapshot(installer.home)
    assert f'work/Admin/{job_id}.json' in [r[0] for r in after]
    assert without_job_files(after, job_id) == baseline


def test_rollback_without_remove_audit_keeps_only_the_audit_log(installer):
    fakebin = plant_sb_codejob(installer)
    baseline = snapshot(installer.home)
    installer.install()
    job_id = use(installer, fakebin)
    p = installer.run('python3 -IB /home/ubuntu/.local/lib/jobroute/releases/$SHA/uninstall.py --release "$SHA"')
    assert p.returncode == 0, p.stdout + p.stderr
    extra = {r[0] for r in without_job_files(snapshot(installer.home), job_id)} - {r[0] for r in baseline}
    assert extra == {'.local', '.local/state', '.local/state/jobroute', '.local/state/jobroute/audit.jsonl'}
    audit = (installer.home / '.local/state/jobroute/audit.jsonl').read_text()
    assert job_id in audit                       # the removed job index is also in the retained audit


def test_stale_install_state_new_does_not_break_rerun_or_undo(installer):
    baseline = snapshot(installer.home)
    installer.install()
    stale = installer.home / BASE.relative_to('/home/ubuntu') / 'install-state.new'
    stale.write_text('')                         # what ENOSPC during json.dump leaves behind
    installer.install()                          # was: FileExistsError, exit 1
    assert not os.path.lexists(stale)
    manifest = json.loads((stale.parent / 'install-state.json').read_text())
    assert manifest['version'] == 1 and manifest['created_dirs']
    stale.write_text('{"partial": ')
    p = installer.undo()
    assert p.returncode == 0, p.stdout + p.stderr
    assert snapshot(installer.home) == baseline


@pytest.mark.parametrize('kind', ['symlink', 'directory', 'writable'])
def test_untrusted_stale_install_state_new_is_refused_and_left_alone(installer, kind):
    installer.install()
    stale = installer.home / BASE.relative_to('/home/ubuntu') / 'install-state.new'
    target = installer.root / 'target'
    target.write_text('keep')
    if kind == 'symlink':
        stale.symlink_to(target)
    elif kind == 'directory':
        stale.mkdir()
    else:
        stale.write_text('')
        stale.chmod(0o666)
    manifest = (stale.parent / 'install-state.json').read_bytes()
    p = installer.run()
    assert p.returncode != 0 and 'untrusted ownership/mode/type' in p.stderr
    assert target.read_text() == 'keep' and os.path.lexists(stale)
    assert (stale.parent / 'install-state.json').read_bytes() == manifest
