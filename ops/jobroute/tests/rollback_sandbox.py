"""Exercise the exact generated installer and documented undo in two marked HOME baselines.
Invoked only by run-rollback-sandbox.sh as sbtest in its user/PID/mount namespace.
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
    r'^([0-9a-f]{64})  (jobroute|jobroute_core.py|allowlist.toml|check-hermes-tools)$', installer.read_text(), re.M))
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
check('all four pins found in generated installer', len(pins) == 4)
print('pinned SHA: ' + sha, flush=True)
print('namespace uid: ' + str(os.geteuid()) + '; pid: ' + str(os.getpid()), flush=True)

for populated in (False, True):
    name = 'populated' if populated else 'fresh'
    print('\n== ' + name + ' HOME scenario ==', flush=True)
    home = stage / name
    home.mkdir()
    (home / 'SCRATCH-HOME-MARKER').touch()
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
        'SCRATCH-HOME-MARKER', '.gitconfig'})
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
    print('documented rollback commands:\n' + undo, flush=True)
    rc = run(home, undo)
    check(name + ': exact README rollback commands exit 0', rc == 0)
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
