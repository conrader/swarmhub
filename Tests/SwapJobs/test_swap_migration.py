"""All fixtures are offline export/staging trees. No host accounts or services are queried."""
import datetime as dt
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'ops'))
import swap_migrate as m


def export():
    return {'version': 1, 'profile': 'grok-pilot', 'account': 'hb-pilot', 'memory_char_limit': 200,
            'memory': 'Remember the project constraints.', 'user': 'Ask Konrad for irreversible actions.',
            'journal': {'2026-10-30.md': 'Prepared the migration.'},
            'skills': {'demo/SKILL.md': 'Use this reviewed local tool.'},
            'routines': [{'name': 'daily', 'cron': '0 9 * * 1-5', 'timezone': 'Europe/Warsaw',
                          'prompt': 'Report status only.', 'delivery': 'self', 'source': 'reviewed export',
                          'confidence': 'confirmed'}]}


@pytest.fixture
def setup(tmp_path):
    source, target = tmp_path / 'export.json', tmp_path / 'stage'
    source.write_text(json.dumps(export()))
    return source, target


def test_default_dry_run_never_creates_any_file(setup):
    src, target = setup
    before = list(src.parent.rglob('*'))
    assert m.migrate(src, target)['apply'] is False
    assert list(src.parent.rglob('*')) == before


def test_apply_repeat_and_undo_are_idempotent_and_private(setup):
    src, target = setup
    assert m.migrate(src, target, True)['action'] == 'stage'
    before = {str(p): (p.stat().st_ino, p.read_bytes()) for p in target.rglob('*') if p.is_file()}
    assert m.migrate(src, target, True)['action'] == 'unchanged'
    assert before == {str(p): (p.stat().st_ino, p.read_bytes()) for p in target.rglob('*') if p.is_file()}
    for path in (target, *target.rglob('*')):
        assert path.stat().st_mode & 0o777 == (0o700 if path.is_dir() else 0o600)
    manifest = json.loads((target / 'routines/grok-pilot.yaml').read_text())
    assert manifest['enabled'] is False and manifest['report_only'] is True
    assert m.migrate(None, target, undo=True)['apply'] is False and target.exists()
    assert m.migrate(None, target, True, True)['action'] == 'remove-staging'
    assert m.migrate(None, target, True, True)['action'] == 'already-absent'


@pytest.mark.parametrize('change', ['changed', 'extra', 'symlink', 'missing', 'parent-symlink'])
def test_undo_and_reapply_preserve_changed_trees(setup, change):
    src, target = setup
    m.migrate(src, target, True)
    memory = target / 'profile/memories/MEMORY.md'
    if change == 'changed': memory.write_text('new memory')
    if change == 'extra': (target / 'keep').write_text('user content')
    if change == 'symlink': memory.unlink(); memory.symlink_to(src)
    if change == 'missing': memory.unlink()
    if change == 'parent-symlink':
        folder = target / 'profile/memories'
        folder.rename(target / 'saved'); folder.symlink_to(target / 'saved', target_is_directory=True)
    for undo in (True, False):
        with pytest.raises((ValueError, OSError)):
            m.migrate(src, target, True, undo)
    assert target.exists()


@pytest.mark.parametrize('secret', ['api_key=abc123456789XYZ', 'Bearer abc123456', '-----BEGIN OPENSSH PRIVATE KEY-----', 'ghp_' + 'A'*36])
def test_secrets_rejected_without_echo_or_writes(setup, secret):
    src, target = setup
    doc = export(); doc['memory'] = secret; src.write_text(json.dumps(doc))
    p = subprocess.run([str(ROOT/'ops/swap-migrate'), '--export', str(src), '--output', str(target), '--apply'], capture_output=True, text=True)
    assert p.returncode == 2 and secret not in p.stdout + p.stderr and not target.exists()


@pytest.mark.parametrize('field,value', [('memory_char_limit', 1), ('account', 'hermes'), ('profile', '../evil'),
    ('routines', [{'name': 'daily'}]), ('skills', {'../escape': 'bad'}), ('skills', {'.env': 'bad'}),
    ('journal', {'../../x.md': 'bad'}), ('skills', {'demo/config.yaml': 'bad'})])
def test_bad_export_refused(setup, field, value):
    src, target = setup
    doc = export(); doc[field] = value; src.write_text(json.dumps(doc))
    with pytest.raises(ValueError): m.migrate(src, target, True)
    assert not target.exists()


def test_changed_export_requires_new_stage(setup):
    src, target = setup; m.migrate(src, target, True)
    doc = export(); doc['memory'] = 'Changed scope'; src.write_text(json.dumps(doc))
    with pytest.raises(ValueError): m.migrate(src, target, True)


def test_cron_uses_warsaw_zone_and_dst():
    after = dt.datetime(2026, 10, 30, 0, 0, tzinfo=dt.timezone.utc)
    assert m.next_run('0 9 * * 1-5', 'Europe/Warsaw', after) == '2026-10-30T08:00:00+00:00'
    # DST fold includes both occurrences of local 02:30.
    assert m.next_run('30 2 * * *', 'Europe/Warsaw', dt.datetime(2026, 10, 25, 0, 30, tzinfo=dt.timezone.utc)) == '2026-10-25T01:30:00+00:00'


@pytest.mark.parametrize('cron', ['61 * * * *', '* * *', '0 9 * * MON', '*/0 * * * *'])
def test_invalid_cron(cron):
    with pytest.raises(ValueError): m.cron_fields(cron)


def test_cli_default_and_reverse_default_are_dry(setup):
    src, target = setup
    cmd = [str(ROOT/'ops/swap-migrate'), '--output', str(target)]
    p = subprocess.run(cmd + ['--export', str(src)], capture_output=True, text=True)
    assert p.returncode == 0 and not target.exists()
    m.migrate(src, target, True)
    p = subprocess.run(cmd + ['--undo'], capture_output=True, text=True)
    assert p.returncode == 0 and target.exists()


def test_hb_move_cli_defaults_dry_and_apply_is_explicit(monkeypatch):
    import hb_move
    calls = []
    monkeypatch.setattr(hb_move, 'render_nginx', lambda box: calls.append(box.dry))
    assert hb_move.main(['--root', '/offline-fixture', '--render-nginx']) == 0
    assert hb_move.main(['--root', '/offline-fixture', '--render-nginx', '--apply']) == 0
    assert hb_move.main(['--root', '/offline-fixture', '--render-nginx', '--dry-run']) == 0
    assert calls == [True, False, True]
