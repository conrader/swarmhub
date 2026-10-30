"""Offline, dry-run-first migration of a reviewed Grok export to hb-* staging files.

Existing Hermes config/secrets and account moves belong to hb-move. This importer never
reads a live HOME or copies credentials and never installs/enables routines or services.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sys
import tempfile
from zoneinfo import ZoneInfo

sys.path.insert(0, str(Path(__file__).resolve().parent / 'jobroute'))
from jobroute_commands import private_read
from secretscan import find

NAME = re.compile(r'[a-z0-9][a-z0-9-]{0,47}')
MARK = '.swap-migration.json'


def encode(obj):
    return (json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2) + '\n').encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def checked_text(value):
    if not isinstance(value, str) or '\0' in value or len(value.encode()) > 1 << 20:
        raise ValueError('invalid export text or size')
    if find(value) or re.search(r'-----BEGIN .*PRIVATE KEY-----|\bBearer\s+\S+', value, re.I):
        raise ValueError('secret-shaped content in export; remove it before importing')
    return value


def safe_name(value):
    if not isinstance(value, str) or not NAME.fullmatch(value):
        raise ValueError('invalid profile or routine name')
    return value


def relative(value):
    if not isinstance(value, str):
        raise ValueError('invalid relative path')
    p = PurePosixPath(value)
    if not p.parts or p.is_absolute() or any(x in ('.', '..') or not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]*', x) for x in p.parts):
        raise ValueError('invalid relative path')
    if any(x.startswith('.') or x in ('config.yaml', 'auth.json') for x in p.parts):
        raise ValueError('credentials and config are excluded from export')
    return str(p)


def cron_fields(expr):
    if not isinstance(expr, str) or len(expr.split()) != 5:
        raise ValueError('cron must contain five fields')
    out = []
    for text, lo, hi in zip(expr.split(), (0, 0, 1, 1, 0), (59, 23, 31, 12, 7)):
        values = set()
        for item in text.split(','):
            base, sep, step = item.partition('/')
            n = int(step) if sep else 1
            if n < 1 or n > hi + 1:
                raise ValueError('invalid cron step')
            if base == '*':
                first, last = lo, hi
            elif '-' in base:
                first, last = map(int, base.split('-'))
            else:
                first = last = int(base)
            if not lo <= first <= last <= hi:
                raise ValueError('cron value outside range')
            values.update(range(first, last + 1, n))
        out.append(values)
    return out


def next_run(expr, timezone, after):
    """Iterate UTC minutes so DST folds/gaps use the box's named zone correctly."""
    values = cron_fields(expr)
    zone = ZoneInfo(timezone)
    cursor = after.astimezone(dt.timezone.utc).replace(second=0, microsecond=0) + dt.timedelta(minutes=1)
    parts = expr.split()
    for _ in range(366 * 24 * 60):
        local = cursor.astimezone(zone)
        dow = (local.weekday() + 1) % 7
        dom_ok, dow_ok = local.day in values[2], dow in {x % 7 for x in values[4]}
        day_ok = (dom_ok and dow_ok) if '*' in (parts[2], parts[4]) else (dom_ok or dow_ok)
        if local.minute in values[0] and local.hour in values[1] and local.month in values[3] and day_ok:
            return cursor.isoformat()
        cursor += dt.timedelta(minutes=1)
    raise ValueError('cron has no occurrence within 366 days')


def plan(export):
    if not isinstance(export, dict) or set(export) - {'version', 'profile', 'account', 'memory_char_limit', 'memory', 'user', 'journal', 'skills', 'routines'} or export.get('version') != 1:
        raise ValueError('unknown export schema')
    profile = safe_name(export.get('profile'))
    account = export.get('account')
    if not isinstance(account, str) or not re.fullmatch(r'hb-[a-z0-9][a-z0-9-]{0,28}', account):
        raise ValueError('account must be an explicit hb-* Unix account')
    limit = export.get('memory_char_limit', 2200)
    if type(limit) is not int or not 1 <= limit <= 100000:
        raise ValueError('invalid memory_char_limit')
    memory, user = checked_text(export.get('memory', '')), checked_text(export.get('user', ''))
    if len(memory) + len(user) > limit:
        raise ValueError('distill MEMORY.md and USER.md within memory_char_limit before importing')
    base = f'profile/'
    files = {base + 'memories/MEMORY.md': memory.encode(), base + 'memories/USER.md': user.encode()}
    for kind, prefix in [('journal', 'journal/'), ('skills', base + 'skills/')]:
        items = export.get(kind, {})
        if not isinstance(items, dict) or len(items) > 500:
            raise ValueError('invalid export file map')
        for name, text in items.items():
            name = relative(name)
            if kind == 'journal' and not name.endswith('.md'):
                raise ValueError('journals must be markdown')
            files[prefix + name] = checked_text(text).encode()
    routines = export.get('routines', [])
    if not isinstance(routines, list) or len(routines) > 100:
        raise ValueError('invalid routine manifest')
    seen = set()
    for routine in routines:
        if not isinstance(routine, dict) or set(routine) != {'name', 'cron', 'timezone', 'prompt', 'delivery', 'source', 'confidence'}:
            raise ValueError('routine needs name, cron, timezone, prompt, delivery, source, confidence')
        name = safe_name(routine['name'])
        if name in seen:
            raise ValueError('duplicate routine')
        seen.add(name)
        cron_fields(routine['cron']); ZoneInfo(routine['timezone'])
        for k in ('prompt', 'delivery', 'source'):
            if not checked_text(routine[k]).strip():
                raise ValueError('routine provenance/prompt/delivery required')
        if routine['confidence'] not in ('confirmed', 'inferred', 'unknown'):
            raise ValueError('invalid routine confidence')
    # JSON is valid YAML; no extra YAML parser dependency. Explicitly inert until Jarvis reviews a report-only run.
    files[f'routines/{profile}.yaml'] = encode({'profile': profile, 'enabled': False, 'report_only': True, 'routines': routines})
    key = f'/home/{account}/.ssh/jobroute_ed25519'
    files[base + 'config.patch.json'] = encode({'mcp_servers': {'sb_jobs': {'command': 'ssh', 'args': [
        '-T', '-oBatchMode=yes', '-oStrictHostKeyChecking=yes', '-oUpdateHostKeys=no', '-oIdentitiesOnly=yes',
        '-i', key, 'jobroute-ovh', 'mcp']}}})
    manifest = {'version': 1, 'profile': profile, 'account': account,
                'export_sha256': digest(encode(export)), 'files': {k: digest(v) for k, v in files.items()}}
    return files, manifest


def output_path(raw):
    p = Path(raw).absolute()
    # No symlink parent and no accidental writes into HOME's operational directories.
    for parent in (p, *p.parents):
        if parent.is_symlink():
            raise ValueError('staging path must not traverse symlinks')
    if p == Path('/') or p == Path.home() or any(x in p.parts for x in ('.hermes', '.ssh', 'etc', 'var')):
        raise ValueError('choose a separate offline staging directory')
    if not p.parent.is_dir():
        raise ValueError('staging parent must already exist')
    return p


def verify_tree(target, manifest):
    if manifest.get('version') != 1 or not isinstance(manifest.get('files'), dict):
        raise ValueError('invalid migration manifest')
    expected = {MARK, *manifest['files']}
    actual = {str(p.relative_to(target)) for p in target.rglob('*') if not p.is_dir() or p.is_symlink()}
    if actual != expected:
        raise ValueError('staging tree has extra or missing files; preserve and review it')
    for name, sha in manifest['files'].items():
        relative(name)
        p = target / name
        if any(x.is_symlink() for x in (p, *p.parents)) or digest(private_read(p, 1 << 20)) != sha:
            raise ValueError('staging tree changed; refusing to overwrite or remove it')


def migrate(source, target, apply=False, undo=False):
    target = output_path(target)
    if undo:
        if not target.exists():
            return {'action': 'already-absent', 'apply': apply}
        manifest = json.loads(private_read(target / MARK, 1 << 20))
        verify_tree(target, manifest)
        if apply:
            shutil.rmtree(target)
        return {'action': 'remove-staging', 'apply': apply, 'profile': manifest['profile']}
    export = json.loads(private_read(source, 8 << 20))
    # Scan the whole input as well as individual fields; keys/metadata can carry secrets too.
    checked_text(json.dumps(export, ensure_ascii=False))
    files, manifest = plan(export)
    if target.exists():
        existing = json.loads(private_read(target / MARK, 1 << 20))
        if existing != manifest:
            raise ValueError('staging already belongs to another export; choose a new directory')
        verify_tree(target, manifest)
        return {'action': 'unchanged', 'apply': apply, 'files': len(files)}
    if apply:
        temp = Path(tempfile.mkdtemp(prefix='.swap-stage-', dir=target.parent))
        try:
            for name, data in {**files, MARK: encode(manifest)}.items():
                path = temp / name
                path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                # mkdir(parents=True) can give intermediate parents default modes: seal all before publication.
                path.write_bytes(data); path.chmod(0o600)
            for p in temp.rglob('*'):
                if p.is_dir(): p.chmod(0o700)
            os.rename(temp, target)
        finally:
            if temp.exists(): shutil.rmtree(temp)
    return {'action': 'stage', 'apply': apply, 'profile': manifest['profile'], 'files': len(files),
            'routines_enabled': False, 'config': 'reviewable patch only; existing config preserved by hb-move'}


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--export')
    p.add_argument('--output', required=True)
    p.add_argument('--undo', action='store_true')
    flag = p.add_mutually_exclusive_group()
    flag.add_argument('--apply', action='store_true')
    flag.add_argument('--dry-run', action='store_true')
    a = p.parse_args(argv)
    if not a.undo and not a.export: p.error('--export is required')
    try:
        print(json.dumps(migrate(a.export, a.output, a.apply, a.undo), sort_keys=True))
        return 0
    except (OSError, ValueError, TypeError, KeyError):
        # No input text, private paths or scanner matches in diagnostics.
        print('swap-migrate refused: invalid export, changed staging, unsafe path or secret-shaped content', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
