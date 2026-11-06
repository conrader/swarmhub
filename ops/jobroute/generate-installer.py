#!/usr/bin/env python3
"""Render an installer from an exact commit, never from uncommitted working files.

Usage: generate-installer.py REPO SHA OUTPUT
"""
import hashlib
import pathlib
import re
import subprocess
import sys

repo, sha, output = sys.argv[1:]
sha = subprocess.check_output(['git', '-C', repo, 'rev-parse', sha + '^{commit}'], text=True).strip()
if not re.fullmatch(r'[0-9a-f]{40}', sha):
    raise SystemExit('expected a full commit SHA')

def blob(name):
    return subprocess.check_output(['git', '-C', repo, 'show', f'{sha}:ops/jobroute/{name}'])

pins = '\n'.join(f'{hashlib.sha256(blob(name)).hexdigest()}  {name}'
                 for name in ('jobroute', 'jobroute_core.py', 'allowlist.toml', 'check-hermes-tools'))
script = blob('install.sh.in').decode().replace('@SHA@', sha).replace('@PINS@', pins)
path = pathlib.Path(output)
with path.open('x') as f:
    f.write(script)
path.chmod(0o755)
print(f'{sha}  {path}')
print(f'{hashlib.sha256(path.read_bytes()).hexdigest()}  installer sha256')
