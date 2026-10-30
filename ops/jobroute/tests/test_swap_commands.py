"""Fixed sb backends and all Mac calls are recording stand-ins; no real jobs or messages."""
import importlib.machinery
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace

import pytest

from test_jobroute import Env, mcp
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from jobroute_core import Route, Refused
import jobroute_commands as commands


@pytest.fixture
def env(tmp_path):
    e = Env(tmp_path)
    e.cfg.write_text(e.cfg.read_text().replace('[profiles.grok-admin]', '[profiles.grok-admin]\nenabled_verbs=["launch","report","park","approve-wait","msg","msg-send","macjob","queue","report-jarvis"]\nmac_hosts=["macbook"]'))
    return e


def call(env, op, args, profile='grok-admin'):
    return env.run(op, json.dumps(args).encode(), profile=profile)


def test_launch_status_owned_report_redacts_and_bounds(env):
    rc, [out] = call(env, 'launch', {'engine': 'codex', 'label': 'test', 'brief': 'Fix tests.'})
    assert rc == 0, out
    assert b'${SB_CODEJOB%.json}-report.md' in env.calls()[0]['stdin']
    job = out['job_id']
    (env.tmp / 'work/Admin' / (job + '.log')).write_text('log\napi_key=abc123456789XYZ\n' + 'a'*17000)
    (env.tmp / 'work/Admin' / (job + '-report.md')).write_text('Report ghp_' + 'X'*36)
    rc, [out] = env.run(f'status job={job} report=1')
    text = out['jobs'][0]['report']
    assert rc == 0 and len(text.encode()) <= 16384 and 'abc123456789XYZ' not in text and 'ghp_'+'X'*36 not in text
    rc, [out] = env.run(f'status job={job} report=1', profile='grok-doc')
    assert rc == 2


@pytest.mark.parametrize('review', ['claude', 'anything'])
def test_review_must_be_opposite(env, review):
    rc, [out] = call(env, 'launch', {'engine': 'claude', 'label': 'test', 'brief': 'fix', 'review': review})
    assert rc == 2 and not env.calls()


def test_valid_review_uses_sb_review_flag(env):
    rc, [out] = call(env, 'launch', {'engine': 'claude', 'label': 'test', 'brief': 'fix', 'review': 'codex'})
    assert rc == 0 and '--review' in env.calls()[0]['argv']


@pytest.mark.parametrize('op', ['launch','park','approve-wait','msg','msg-send','macjob','queue','report-jarvis'])
def test_all_new_verbs_fail_closed_without_opt_in(env, op):
    rc, [out] = call(env, op, {}, profile='grok-doc')
    assert rc == 2 and out['error'] == 'operation disabled' and not env.calls()
    assert env.audit()[-1]['result'] == 'refused'


def test_shipped_route_submissions_are_off():
    import tomllib
    cfg = tomllib.loads((Path(__file__).parents[1] / 'allowlist.toml').read_text())
    assert cfg['route']['submissions_enabled'] is False
    assert all(not p.get('enabled_verbs') and not p.get('mac_hosts') for p in cfg['profiles'].values())


@pytest.mark.parametrize('args', [{'engine':'codex','label':'x','brief':'x','argv':['id']}, [], {'brief': 'a'*66000}])
def test_invalid_inputs_do_not_launch(env, args):
    rc, _ = call(env, 'launch', args)
    assert rc != 0 and not env.calls()


def test_foreign_approval_and_timeout(env, monkeypatch):
    route = Route(str(env.cfg), 'grok-admin')
    with pytest.raises(Refused): route.command('mcp', 'approve-wait', {'id':'c12345678'})
    monkeypatch.setattr(route, 'approval', lambda ident: ({}, {'state':'pending'}))
    assert route.command('mcp','approve-wait', {'id':'c12345678', 'timeout':0})['state'] == 'pending'
    with pytest.raises(Refused): route.command('mcp','approve-wait', {'id':'c12345678', 'timeout':601})


def test_msg_always_parks_exact_argv_and_poll_never_resends(env, monkeypatch):
    route = Route(str(env.cfg), 'grok-admin')
    route.backends = {'msg': '/usr/bin/true'}
    calls = []
    def backend(name, argv, **kw):
        calls.append((name, argv)); return 'c12345678\n'
    monkeypatch.setattr(route, 'backend', backend)
    a = {'via':'telegram','to':'recipient','text':'Exact reviewed text','reason':'Reply to the requested question'}
    assert route.command('mcp', 'msg', a)['state'] == 'pending'
    assert calls[0][0] == 'park' and 'Exact reviewed text' in calls[0][1]
    history = route.command_history()[-1]
    argv = calls[0][1][calls[0][1].index('--')+1:]
    rec = {'state':'approved','argv':argv,'output_head':'wyslane'}
    monkeypatch.setattr(route, 'approval', lambda ident: (history, rec))
    for _ in range(2):
        assert route.command('mcp', 'msg-send', {'park':'c12345678'})['result'] == 'wyslane'
    assert len(calls) == 1
    rec['argv'] = argv[:-1] + ['changed']
    with pytest.raises(Refused): route.command('mcp', 'msg-send', {'park':'c12345678'})


def test_park_foreign_script_symlink_and_hash(env, monkeypatch):
    route = Route(str(env.cfg), 'grok-admin')
    script = env.tmp / 'work/Admin/action.sh'; script.write_text('echo test')
    monkeypatch.setattr(route, 'backend', lambda *a, **kw: 'c12345678\n')
    args = {'script':str(script), 'reason':'Test action for review', 'changes':'test', 'reverse':'restore snapshot'}
    assert route.command('cli','park',args)['script_sha256']
    script.unlink(); script.symlink_to('/usr/bin/true')
    with pytest.raises(OSError): route.command('cli','park',args)
    args['script'] = str(env.tmp/'work/Doc/action.sh')
    with pytest.raises(Refused): route.command('cli','park',args)


def test_rate_limit_covers_all_commands(env):
    route = Route(str(env.cfg), 'grok-admin'); route.command_per_hour = 1
    with pytest.raises(Refused): route.command('cli','queue',{'host':'mini'})
    with pytest.raises(Refused, match='rate limit'): route.command('cli','queue',{'host':'macbook'})


def test_macjob_uses_existing_detached_route_and_allowlists(env):
    route = Route(str(env.cfg), 'grok-admin')
    route.backends['mac_dispatch'] = str(env.tmp/'bin/codex')
    out = route.command('cli','macjob', {'host':'macbook','label':'mac-check','brief':'Shell task'})
    assert out['job_id'] and route.own_jobs()[0]['engine'] == 'macjob'
    assert env.calls()[0]['stdin'].startswith(b'{')
    with pytest.raises(Refused): route.command('cli','macjob', {'host':'mini','label':'x','brief':'x'})
    with pytest.raises(Refused): route.command('cli','macjob', {'host':'-oProxyCommand=evil','label':'x','brief':'x'})


def test_queue_dispatch_and_report_receipt(env, monkeypatch):
    route = Route(str(env.cfg), 'grok-admin'); calls=[]
    def backend(name, argv, data=b'', **kw):
        calls.append((name,argv,data)); return '{"holder":null}' if name=='mac_dispatch' else '{"status":"queued"}'
    monkeypatch.setattr(route, 'backend', backend)
    assert route.command('mcp','queue',{})['queue'] == {'holder':None}
    result = route.command('mcp','report-jarvis',{'text':'Test report'})
    assert type(result['owner_report_due']) is bool
    assert calls[-1][1][calls[-1][1].index('--agent')+1] == 'Jarvis'


def test_mcp_exposes_and_calls_new_command(env):
    rc, rows = mcp(env, {'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':'launch','arguments':{'engine':'codex','label':'mcp','brief':'Fix.'}}})
    assert rc == 0 and not rows[1]['result']['isError']


def test_report_rejects_symlink(env):
    rc, [out] = call(env, 'launch', {'engine':'codex','label':'x','brief':'Fix'})
    path = env.tmp/'work/Admin'/(out['job_id']+'-report.md'); path.symlink_to('/etc/passwd')
    rc, [out] = env.run('status job='+out['job_id']+' report=1')
    assert rc != 0 and 'root:' not in json.dumps(out)


def test_mac_worker_uses_shared_runner_and_fixed_shell_argv(tmp_path):
    import importlib.util
    spec = importlib.util.spec_from_file_location('mac_worker', Path(__file__).parents[1]/'mac-worker.py')
    worker = importlib.util.module_from_spec(spec); spec.loader.exec_module(worker)
    calls=[]
    def execute(argv, **kw):
        calls.append((argv,kw)); assert kw['stdin'].read() == b'hello $(id)'; return SimpleNamespace(returncode=0)
    assert worker.run({'operation':'macjob','agent':'Admin','label':'task','brief':'hello $(id)'}, tmp_path, execute) == 0
    argv, kw = calls[0]
    assert argv[0].endswith('/sb-macjob') and '--workdir' in argv and argv[-3:] == ['-p','--permission-mode','acceptEdits']
    assert kw['env']['SB_MACJOB_QUEUE']=='1' and 'SB_MACJOB_QUEUE_DIR' not in kw['env']


def test_per_profile_submission_switch_is_required(env):
    env.cfg.write_text(env.cfg.read_text().replace('[profiles.grok-admin]', '[profiles.grok-admin]\nsubmissions_enabled=false'))
    rc, [out] = call(env, 'launch', {'engine':'codex','label':'x','brief':'Fix'})
    assert rc == 2 and out['error'] == 'submissions disabled' and not env.calls()


def test_backend_executes_fixed_argv_and_scrubs_environment(env):
    route = Route(str(env.cfg), 'grok-admin')
    script = env.tmp/'bin/backend'
    script.write_text('#!/usr/bin/python3\nimport json,os,sys\nprint(json.dumps({"argv":sys.argv[1:],"stdin":sys.stdin.read(),"key":os.getenv("ANTHROPIC_API_KEY")}))\n')
    script.chmod(0o755); route.backends['park'] = str(script)
    result = json.loads(route.backend('park', ['literal $(id)', '; no shell'], b'input $(id)'))
    assert result == {'argv':['literal $(id)', '; no shell'], 'stdin':'input $(id)', 'key':None}
    script.chmod(0o777)
    with pytest.raises(Refused, match='trust check'): route.backend('park', [])


def test_real_approval_reader_checks_profile_and_identity(env):
    from jobroute_jobs import _append
    route=Route(str(env.cfg),'grok-admin')
    route.approvals=env.tmp/'approvals'; route.approvals.mkdir()
    _append(route.command_index,{'t':0,'id':'c12345678','kind':'script'})
    path=route.approvals/'c12345678.json'
    path.write_text(json.dumps({'id':'c12345678','by':'Admin:jobroute','state':'denied'}))
    assert route.command('cli','approve-wait',{'id':'c12345678'})['state']=='denied'
    path.write_text(json.dumps({'id':'c12345678','by':'Doc:jobroute','state':'approved'}))
    with pytest.raises(Refused,match='identity mismatch'): route.approval('c12345678')


def test_backend_timeout_is_audited(env, monkeypatch):
    import subprocess
    route=Route(str(env.cfg),'grok-admin')
    monkeypatch.setattr(route,'backend',lambda *a,**kw: (_ for _ in ()).throw(subprocess.TimeoutExpired('stub',1)))
    with pytest.raises(subprocess.TimeoutExpired): route.command('cli','queue',{})
    assert env.audit()[-1]['result']=='error' and env.audit()[-1]['reason']=='TimeoutExpired'
