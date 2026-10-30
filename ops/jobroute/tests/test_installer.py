"""All installer executions bind a marked scratch HOME over /home/ubuntu in a private
mount namespace, itself inside run-sandbox.sh's sbtest user/PID namespace. No live install.
"""
import hashlib
import json
import os
import pathlib
import shutil
import stat
import subprocess

import pytest

SOURCE = pathlib.Path(__file__).resolve().parent.parent
HOME = pathlib.Path('/home/ubuntu')
BASE = HOME / '.local/lib/jobroute'


def snapshot(home):
    rows = []
    for path in sorted(home.rglob('*')):
        st = path.lstat()
        data = os.readlink(path) if path.is_symlink() else (
            hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
        rows.append((str(path.relative_to(home)), stat.S_IFMT(st.st_mode), stat.S_IMODE(st.st_mode),
                     st.st_uid, st.st_gid, data))
    return rows


class Installer:
    def __init__(self, root, repo, sha, script):
        self.root, self.sha, self.script = root, sha, script
        self.home = root / 'home'
        self.home.mkdir()
        (self.home / 'SCRATCH-HOME-MARKER').touch()
        (self.home / '.gitconfig').write_text(
            f'[url "file://{repo}"]\n\tinsteadOf = git@github.com:conrader/swarmhub.git\n')

    def run(self, command=None):
        wrapper = '''set -euo pipefail
mount --make-rprivate /
mount --bind "$1" /home/ubuntu
[ -f /home/ubuntu/SCRATCH-HOME-MARKER ]
export HOME=/home/ubuntu
export INSTALLER=$2 SHA=$3
umask 0002
bash -euo pipefail -c "$4"
'''
        return subprocess.run(['unshare', '--mount', 'bash', '-c', wrapper, 'test-install', str(self.home),
                               str(self.script), self.sha, command or 'bash "$INSTALLER"'],
                              capture_output=True, text=True, timeout=60,
                              env={'PATH': '/usr/bin:/bin', 'HOME': str(self.root)})

    def install(self):
        p = self.run()
        assert p.returncode == 0, p.stdout + p.stderr
        assert 'self-check ok' in p.stdout

    def undo(self):
        return self.run('python3 -IB /home/ubuntu/.local/lib/jobroute/releases/$SHA/uninstall.py '
                        '--release "$SHA" --remove-audit')


@pytest.fixture(scope='session')
def artifact(tmp_path_factory):
    root = tmp_path_factory.mktemp('installer-artifact')
    repo = root / 'repo'
    target = repo / 'ops/jobroute'
    shutil.copytree(SOURCE, target, ignore=shutil.ignore_patterns('__pycache__', '.pytest_cache'))
    for args in (['init', '-q', str(repo)], ['-C', str(repo), 'add', '.'],
                 ['-C', str(repo), '-c', 'user.name=sbtest', '-c', 'user.email=sbtest@invalid',
                  'commit', '-qm', 'sandbox installer fixture']):
        subprocess.run(['git', *args], check=True, capture_output=True)
    sha = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
    script = root / 'installer.sh'
    subprocess.run(['python3', str(SOURCE / 'generate-installer.py'), str(repo), sha, str(script)],
                   check=True, capture_output=True)
    return repo, sha, script


@pytest.fixture
def installer(tmp_path, artifact):
    # Fixture baselines are trusted; the installer subprocess explicitly inherits 0002.
    previous = os.umask(0o022)
    try:
        yield Installer(tmp_path, *artifact)
    finally:
        os.umask(previous)


def test_inherited_umask_0002_produces_trusted_parents(installer):
    installer.install()
    for name in ('.local', '.local/lib', '.local/lib/jobroute', '.local/lib/jobroute/releases',
                 '.config', '.config/jobroute', '.local/state', '.local/state/jobroute'):
        st = (installer.home / name).stat()
        assert not st.st_mode & 0o022 and st.st_uid == os.geteuid(), name
    manifest = json.loads((installer.home / '.local/lib/jobroute/install-state.json').read_text())
    assert {d['path'] for d in manifest['created_dirs']} >= {
        str(HOME / p) for p in ('.config', '.local/lib', '.local/state', '.local')}


@pytest.mark.parametrize('parent', ['.local', '.local/lib', '.local/lib/jobroute',
                                   '.local/lib/jobroute/releases', '.config', '.local/state'])
def test_existing_writable_parents_are_refused_without_correction(installer, parent):
    path = installer.home / parent
    path.mkdir(parents=True)
    path.chmod(0o775)
    before = snapshot(installer.home)
    p = installer.run()
    assert p.returncode != 0 and 'untrusted ownership/mode/type' in p.stderr
    assert snapshot(installer.home) == before


def test_symlink_parent_is_refused(installer):
    target = installer.root / 'redirect'
    target.mkdir()
    (installer.home / '.local').symlink_to(target)
    p = installer.run()
    assert p.returncode != 0 and 'untrusted ownership/mode/type' in p.stderr
    assert list(target.iterdir()) == []


def test_foreign_owned_parent_is_refused(installer):
    (installer.home / '.local').mkdir()
    # /usr is owned by the host root, unmapped/foreign to sbtest. Read-only use.
    p = installer.run('mount --bind /usr /home/ubuntu/.local; bash "$INSTALLER"')
    assert p.returncode != 0 and 'untrusted ownership/mode/type: /home/ubuntu/.local' in p.stderr


@pytest.mark.parametrize('name', ['jobroute', 'jobroute_core.py', 'jobroute_jobs.py', 'jobroute_trust.py',
                                  'allowlist.toml', 'check-hermes-tools', 'uninstall.py', 'jobroute_commands.py', 'secretscan.py',
                                  'mac-dispatch', 'mac-worker.py', 'isolation_check.py', 'check-jobroute-iso'])
def test_reinstall_refuses_each_tampered_installed_pin(installer, name):
    installer.install()
    installed = installer.home / '.local/lib/jobroute/releases' / installer.sha / name
    with installed.open('ab') as f:
        f.write(b'\n# tampered installed copy\n')
    audit = installer.home / '.local/state/jobroute/audit.jsonl'
    before = audit.read_bytes()
    p = installer.run()
    assert p.returncode != 0 and f'installed pin mismatch: {name}' in p.stderr
    assert audit.read_bytes() == before  # fail before either installed self-check executes


@pytest.mark.parametrize('name', ['', 'jobroute_core.py'])
def test_reinstall_refuses_unsafe_release_modes(installer, name):
    installer.install()
    path = installer.home / '.local/lib/jobroute/releases' / installer.sha
    if name:
        path /= name
    path.chmod(path.stat().st_mode | 0o020)
    p = installer.run()
    assert p.returncode != 0 and 'untrusted ownership/mode/type' in p.stderr


def test_reinstall_refuses_foreign_owned_installed_module(installer):
    installer.install()
    p = installer.run('mount --bind /usr/bin/true /home/ubuntu/.local/lib/jobroute/releases/$SHA/jobroute_core.py; '
                      'bash "$INSTALLER"')
    assert p.returncode != 0 and 'untrusted ownership/mode/type' in p.stderr


@pytest.mark.parametrize('prepopulated', [False, True])
def test_full_rollback_matches_fresh_and_populated_home_baselines(installer, prepopulated):
    if prepopulated:
        for name in ('.config/user', '.local/lib/user', '.local/state/user', '.ssh'):
            path = installer.home / name
            path.mkdir(parents=True, exist_ok=True)
            (path / 'keep').write_bytes(b'user content\n')
        (installer.home / '.local/user-link').symlink_to('../.config/user/keep')
    baseline = snapshot(installer.home)
    installer.install()
    after_first = snapshot(installer.home)
    first_audit = installer.home / '.local/state/jobroute/audit.jsonl'
    installer.install()
    assert [r for r in snapshot(installer.home) if r[0] != '.local/state/jobroute/audit.jsonl'] == [
        r for r in after_first if r[0] != '.local/state/jobroute/audit.jsonl']
    assert len(first_audit.read_text().splitlines()) == 2
    p = installer.undo()
    assert p.returncode == 0, p.stdout + p.stderr
    assert snapshot(installer.home) == baseline


def test_rollback_keeps_new_user_content_and_changed_config(installer):
    installer.install()
    for name in ('.config/keep', '.local/lib/keep', '.local/state/keep', '.local/keep'):
        (installer.home / name).write_text('user data')
    cfg = installer.home / '.config/jobroute/allowlist.toml'
    cfg.write_text(cfg.read_text() + '\n# user config change\n')
    changed = cfg.read_bytes()
    p = installer.undo()
    assert p.returncode == 0, p.stdout + p.stderr
    assert cfg.read_bytes() == changed
    for name in ('.config/keep', '.local/lib/keep', '.local/state/keep', '.local/keep'):
        assert (installer.home / name).read_text() == 'user data'


def test_rollback_keeps_replaced_parent_even_when_empty(installer):
    installer.install()
    config_parent = installer.home / '.config'
    original = installer.root / 'original-config-parent'
    config_parent.rename(original)
    config_parent.mkdir()
    # Keep the installer-owned unchanged config accessible for its normal cleanup.
    (original / 'jobroute').rename(config_parent / 'jobroute')
    p = installer.undo()
    assert p.returncode == 0, p.stdout + p.stderr
    assert config_parent.is_dir() and list(config_parent.iterdir()) == []
    assert original.is_dir()


def test_rollback_retains_preexisting_route_config_and_empty_parents(installer):
    cfg = installer.home / '.config/jobroute/allowlist.toml'
    cfg.parent.mkdir(parents=True)
    original = (SOURCE / 'allowlist.toml').read_bytes() + b'\n# pre-existing config\n'
    cfg.write_bytes(original)
    cfg.chmod(0o644)
    for name in ('.local/lib', '.local/state'):
        (installer.home / name).mkdir(parents=True, exist_ok=True)
    baseline = snapshot(installer.home)
    installer.install()
    assert installer.undo().returncode == 0
    assert snapshot(installer.home) == baseline
