#!/usr/bin/python3 -IB
"""Remove an inert jobroute install, retaining pre-existing directories and user files.

Run using the pinned release: python3 -IB .../current/uninstall.py --release SHA [--remove-audit]
The optional flag explicitly discards audit.jsonl. Detached jobs are unaffected.
"""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--release', required=True)
ap.add_argument('--remove-audit', action='store_true')
a = ap.parse_args()
if not re.fullmatch(r'[0-9a-f]{40}', a.release):
    ap.error('release must be a full SHA')
home = pathlib.Path('/home/ubuntu')
base = home / '.local/lib/jobroute'
manifest = base / 'install-state.json'
st = manifest.lstat()
if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_mode & 0o022:
    raise SystemExit('untrusted install-state.json')
state = json.loads(manifest.read_text())
if state.get('version') != 1:
    raise SystemExit('unknown install-state version')
release = base / 'releases' / a.release
current = base / 'current'
if current.is_symlink() and os.readlink(current) == str(release):
    current.unlink()
if release.is_dir() and not release.is_symlink():
    shutil.rmtree(release)
# Do not remove shared state/config while another installed release remains.
if any((base / 'releases').iterdir()):
    raise SystemExit('release removed; other releases remain, keeping shared config/state')
config = home / '.config/jobroute/allowlist.toml'
if config.is_file() and not config.is_symlink() and state.get('config_sha256'):
    if hashlib.sha256(config.read_bytes()).hexdigest() == state['config_sha256']:
        config.unlink()
if a.remove_audit:
    audit = home / '.local/state/jobroute/audit.jsonl'
    if audit.is_file() and not audit.is_symlink():
        audit.unlink()
manifest.unlink()
# Only prune directories recorded as created by this installer, still the same inode,
# and now empty. Pre-existing parents and new user files always survive.
allowed = {str(home / p) for p in ('.local', '.local/lib', '.local/lib/jobroute',
           '.local/lib/jobroute/releases', '.config', '.config/jobroute',
           '.local/state', '.local/state/jobroute', '.local/state/jobroute/profiles')}
for entry in reversed(state['created_dirs']):
    path = pathlib.Path(entry['path'])
    if str(path) not in allowed:
        continue
    try:
        st = path.lstat()
        if stat.S_ISDIR(st.st_mode) and (st.st_dev, st.st_ino) == (entry['dev'], entry['ino']):
            path.rmdir()
    except OSError:
        pass
print('jobroute release removed; only installer-created empty parents pruned')
