"""Exercise the exact generated installer and documented undo in two marked HOME baselines.
Invoked only by run-rollback-sandbox.sh as sbtest in its user/PID/mount namespace.
Before the undo, each scenario makes one accepted submit through the installed route (a stub
sb-codejob at the shipped path, a stub claude bound over /usr/local/bin in the private mount
namespace), so the undo must also clear the state real use creates.
"""
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys

stage = pathlib.Path(sys.argv[1])
expected = sys.argv[2]
installer = stage / 'installer.sh'
sha = re.search(r'^SHA=([0-9a-f]{40})$', installer.read_text(), re.M)[1]
pins = dict((name, digest) for digest, name in re.findall(
    r'^([0-9a-f]{64})  (jobroute|jobroute_core\.py|jobroute_jobs\.py|jobroute_trust\.py|allowlist\.toml|'
    r'check-hermes-tools|uninstall\.py|jobroute_commands\.py|secretscan\.py|mac-dispatch|mac-worker\.py|isolation_check\.py|check-jobroute-iso)$', installer.read_text(), re.M))
fails = 0
checks = 0
os.umask(0o022)


def check(name, condition):
    global fails, checks
    checks += 1
    print(('PASS  ' if condition else 'FAIL  ') + name, flush=True)
    if not condition:
        fails += 1


def snapshot(home):
    rows = []
    for path in sorted(home.rglob('*')):
        st = path.lstat()
        data = os.readlink(path) if path.is_symlink() else (
            hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
        rows.append([str(path.relative_to(home)), stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode),
                     st.st_uid, st.st_gid, data])
    return rows


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
fakebin = stage / 'fakebin'
fakebin.mkdir()
(fakebin / 'claude').write_text('#!/bin/sh\nexit 0\n')
(fakebin / 'claude').chmod(0o755)
USE = (f'mount --bind {fakebin} /usr/local/bin; '
       f'out=$(printf "Real use before rollback.\\n" | SSH_ORIGINAL_COMMAND="submit engine=claude label=undo-check" {ROUTE}); '
       'grep -q \'"ok": true\' <<<"$out"')


def run(home, command):
    wrapper = '''set -euo pipefail
mount --make-rprivate /
mount --bind "$1" /home/ubuntu
[ -f /home/ubuntu/SCRATCH-HOME-MARKER ]
export HOME=/home/ubuntu INSTALLER=$2 SHA=$3
umask 0002
bash -ex -c "$4"
'''
    p = subprocess.run(['unshare', '--mount', 'bash', '-c', wrapper, 'rollback-test', str(home),
                        str(installer), sha, command], capture_output=True, text=True, timeout=90,
                       env={'PATH': '/usr/bin:/bin', 'HOME': str(stage)})
    print(p.stdout, end='', flush=True)
    print(p.stderr, end='', flush=True)
    return p.returncode


check('staged installer byte-identical: sha256 ' + expected,
      hashlib.sha256(installer.read_bytes()).hexdigest() == expected)
check('all thirteen runtime pins found in generated installer', len(pins) == 13)
print('pinned SHA: ' + sha, flush=True)
print('namespace uid: ' + str(os.geteuid()) + '; pid: ' + str(os.getpid()), flush=True)

for populated in (False, True):
    name = 'populated' if populated else 'fresh'
    print('\n== ' + name + ' HOME scenario ==', flush=True)
    home = stage / name
    home.mkdir()
    (home / 'SCRATCH-HOME-MARKER').touch()
    # ovh has ~/sb and ~/work; they belong to the baseline and rollback never touches them.
    (home / 'sb/bin').mkdir(parents=True)
    (home / 'sb/bin/sb-codejob').write_text(SB_STUB)
    (home / 'sb/bin/sb-codejob').chmod(0o755)
    (home / 'work/Admin').mkdir(parents=True)
    (home / '.gitconfig').write_text(
        f'[url "file://{stage}/swarmhub.git"]\n\tinsteadOf = git@github.com:conrader/swarmhub.git\n')
    if populated:
        for directory in ('.config/user', '.local/lib/user', '.local/state/user', '.ssh'):
            path = home / directory
            path.mkdir(parents=True, exist_ok=True)
            (path / 'keep').write_bytes(b'user content stays byte-identical\n')
        (home / '.local/keep-link').symlink_to('../.config/user/keep')
    baseline = snapshot(home)
    print('baseline: ' + json.dumps(baseline), flush=True)
    check(name + ': correct baseline', populated or {p.name for p in home.iterdir()} == {
        'SCRATCH-HOME-MARKER', '.gitconfig', 'sb', 'work'})
    rc = run(home, 'bash -x "$INSTALLER"')
    check(name + ': install #1 self-check exit 0, inherited umask 0002', rc == 0)
    if rc:
        continue
    base = home / '.local/lib/jobroute'
    release = base / 'releases' / sha
    check(name + ': current points to pinned release', os.readlink(base / 'current') ==
          '/home/ubuntu/.local/lib/jobroute/releases/' + sha)
    for file, digest in pins.items():
        check(name + ': installed ' + file + ' matches pin', hashlib.sha256((release / file).read_bytes()).hexdigest() == digest)
    for parent in ('.config', '.local', '.local/lib', '.local/lib/jobroute', '.local/lib/jobroute/releases', '.local/state'):
        st = (home / parent).stat()
        check(name + ': trusted parent ' + parent, st.st_uid == os.geteuid() and not st.st_mode & 0o022)
    readme = (release / 'README.md').read_text()
    undo = readme.split('# 4. full removal', 1)[1].split('\n', 1)[1].split('```', 1)[0].replace('<sha>', sha)
    cut_access = readme.split('# 1. cut access', 1)[1].split('\n', 1)[1].split('# (or restore', 1)[0]
    first = snapshot(home)
    rc = run(home, 'bash "$INSTALLER"')
    check(name + ': install #2 exit 0', rc == 0)
    second = snapshot(home)
    check(name + ': rerun preserves modes, owners, contents and symlinks except audit append',
          [r for r in first if r[0] != '.local/state/jobroute/audit.jsonl'] ==
          [r for r in second if r[0] != '.local/state/jobroute/audit.jsonl'])
    check(name + ': two audited non-allowlisted self-checks',
          len((home / '.local/state/jobroute/audit.jsonl').read_text().splitlines()) == 2)
    cfg = home / '.config/jobroute/allowlist.toml'
    preimage = cfg.read_bytes()
    cfg.write_text(cfg.read_text().replace('submissions_enabled = false', 'submissions_enabled = true')
                   .replace('[defaults]', '[defaults]\nsubmissions_enabled = true'))
    rc = run(home, USE)
    cfg.write_bytes(preimage)
    check(name + ': accepted submit through the installed route', rc == 0)
    state = home / '.local/state/jobroute'
    check(name + ': real use created .lock and profiles/grok-admin.jsonl',
          (state / '.lock').is_file() and (state / 'profiles/grok-admin.jsonl').is_file())
    jobs = list((home / 'work/Admin').glob('*-undo-check.json'))
    check(name + ': stub sb-codejob wrote one status file', len(jobs) == 1)
    print('documented rollback commands:\n' + undo, flush=True)
    rc = run(home, undo)
    check(name + ': exact README rollback commands exit 0', rc == 0)
    for job in jobs:   # sb-codejob's own status file, not jobroute state
        job.unlink()
    after = snapshot(home)
    print('after rollback: ' + json.dumps(after), flush=True)
    check(name + ': HOME after rollback identical to baseline', after == baseline)
    check(name + ': no jobroute path remains', not list(home.rglob('*jobroute*')))

    # Fake text only, no usable keys and no production authorized_keys access.
    ssh = home / '.ssh'
    ssh.mkdir(exist_ok=True)
    ak = ssh / 'authorized_keys'
    original = (b'ssh-ed25519 FAKE_NORMAL_ONE normal-one\n'
                b'restrict,command="fake" ssh-ed25519 FAKE_ROUTE_ADMIN jobroute:grok-admin\n'
                b'ssh-ed25519 FAKE_NORMAL_TWO normal-two\n'
                b'restrict,command="fake" ssh-ed25519 FAKE_ROUTE_INFRA jobroute:grok-infra\n')
    ak.write_bytes(original)
    ak.chmod(0o600)
    rc = run(home, cut_access)
    check(name + ': README fake authorized_keys rollback exit 0', rc == 0)
    check(name + ': only route lines removed, normal lines byte-identical', ak.read_bytes() ==
          b'ssh-ed25519 FAKE_NORMAL_ONE normal-one\nssh-ed25519 FAKE_NORMAL_TWO normal-two\n')
    backups = list(ssh.glob('authorized_keys.bak-pre-rollback-*'))
    check(name + ': backup equals original', len(backups) == 1 and backups[0].read_bytes() == original)
    check(name + ': mode 600, no temporary .new', stat.S_IMODE(ak.stat().st_mode) == 0o600 and not (ssh / 'authorized_keys.new').exists())
    ak.unlink()
    for backup in backups:
        backup.unlink()
    if not populated:
        ssh.rmdir()
    check(name + ': final HOME still identical to baseline after fake key test cleanup', snapshot(home) == baseline)

print(f'rollback checks: {checks}; failures: {fails}', flush=True)
sys.exit(bool(fails))
