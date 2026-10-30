"""Read-only identity checks with synthetic accounts/stat metadata, never host uid changes."""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'ops/jobroute'))
import isolation_check


def load_client():
    from importlib.machinery import SourceFileLoader
    loader = SourceFileLoader('job_route_client', str(ROOT/'Resources/Skills/swarmhub-coding/scripts/job-route'))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec); loader.exec_module(module)
    return module


@pytest.fixture
def fixture(tmp_path, monkeypatch):
    uid = 2200
    home = tmp_path/'home/hb-pilot'; (home/'.ssh').mkdir(parents=True)
    home.chmod(0o700); (home/'.ssh').chmod(0o700)
    key = home/'.ssh/jobroute_ed25519'; key.write_text('fixture-private-material'); key.chmod(0o600)
    reg = tmp_path/'bots.json'; reg.write_text(json.dumps({'bots':{'grok-pilot':{'uid':uid,'user':'hb-pilot'}}})); reg.chmod(0o644)
    real = Path.lstat
    def lstat(path, *args, **kwargs):
        st = real(path, *args, **kwargs)
        if path == home or home in path.parents:
            fields = list(st); fields[4] = uid
            return os.stat_result(fields)
        return st
    monkeypatch.setattr(Path,'lstat', lstat)
    account = SimpleNamespace(pw_name='hb-pilot', pw_dir=str(home), pw_uid=uid)
    return uid, home, key, reg, account


def test_client_derives_profile_and_key_from_uid(fixture):
    uid, home, key, reg, account = fixture
    assert load_client().identity(reg, uid, lambda _:account, os.geteuid()) == ('grok-pilot', key)


@pytest.mark.parametrize('kind', ['wrong-uid','root','shared','key-readable','home-readable','key-symlink','registry-writable','foreign-account'])
def test_client_refuses_bad_boundary(fixture, kind):
    uid, home, key, reg, account = fixture
    if kind=='wrong-uid': uid += 1
    if kind=='root': uid=0
    if kind=='shared': account.pw_name='hermes'
    if kind=='foreign-account': account.pw_name='hb-other'
    if kind=='key-readable': key.chmod(0o644)
    if kind=='home-readable': home.chmod(0o755)
    if kind=='key-symlink': key.unlink(); key.symlink_to(reg)
    if kind=='registry-writable': reg.chmod(0o666)
    with pytest.raises(ValueError): load_client().identity(reg,uid,lambda _:account,os.geteuid())


def test_gate_checks_template_and_rejects_user_override(fixture, tmp_path):
    uid, home, key, reg, account = fixture
    unit=tmp_path/'etc/systemd/system/hermes-bot@.service'; unit.parent.mkdir(parents=True)
    unit.write_text('[Service]\nUser=hb-%i\n'); unit.chmod(0o644)
    # inspect root prefixes account HOME, so expose a synthetic account path relative to fixture root.
    fake=SimpleNamespace(pw_name=account.pw_name,pw_dir='/home/hb-pilot')
    assert isolation_check.inspect('grok-pilot',reg,lambda _:fake,tmp_path,os.geteuid())['ok']
    folder=unit.parent/'hermes-bot@pilot.service.d'; folder.mkdir()
    (folder/'override.conf').write_text('[Service]\nUser=hermes\n')
    with pytest.raises(ValueError): isolation_check.inspect('grok-pilot',reg,lambda _:fake,tmp_path,os.geteuid())


def test_client_unknown_commands_do_not_start_ssh(monkeypatch):
    client=load_client()
    monkeypatch.setattr(client.subprocess,'run', lambda *a,**kw:pytest.fail('must not start SSH'))
    with pytest.raises(ValueError): client.main(['launch','--host=evil'])
    with pytest.raises(ValueError): client.main(['status','job=foo;id'])
