"""Retry IDs are durable profile-scoped bindings, not permission to relaunch.

Recording launchers only; run in the sbtest sandbox with the rest of jobroute.
"""
from concurrent.futures import ThreadPoolExecutor
import json
import os
import subprocess
import time

import pytest

from test_jobroute import Env, ROUTE, mcp
from test_jobroute_p2 import index_rows
from jobroute_core import Refused, Route
import jobroute_core

PROTOCOLS = ['cli', 'mcp', 'launch', 'mcp-launch']
ARGS = {'engine': 'claude', 'label': 'retry', 'brief': 'Fixture request.\n', 'request_id': 'Req_123-xyz'}


def setup(tmp_path, **kw):
    env = Env(tmp_path, **kw)
    env.cfg.write_text(env.cfg.read_text().replace(
        '[profiles.grok-admin]', '[profiles.grok-admin]\nenabled_verbs=["launch"]'))
    return env


def request(env, protocol, args=None, profile='grok-admin'):
    args = dict(ARGS if args is None else args)
    if protocol == 'cli':
        brief = args.pop('brief').encode()
        command = 'submit ' + ' '.join(f'{k}={v}' for k, v in args.items())
        rc, [body] = env.run(command, brief, profile=profile)
        return rc, body
    if protocol == 'launch':
        rc, [body] = env.run('launch', json.dumps(args).encode(), profile=profile)
        return rc, body
    rc, rows = mcp(env, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/call',
                        'params': {'name': 'launch' if protocol == 'mcp-launch' else 'submit_job',
                                   'arguments': args}}, profile=profile)
    assert rc == 0
    result = rows[1]['result']
    return int(result['isError']), json.loads(result['content'][0]['text'])


@pytest.mark.parametrize('protocol', PROTOCOLS)
@pytest.mark.parametrize('running', [False, True])
def test_lost_response_replays_after_reconnect_and_at_capacity(tmp_path, protocol, running):
    env = setup(tmp_path, per_hour=1, running=1,
                extra_env=f'STUB_PID="{os.getpid()}"' if running else '')
    env.cfg.write_text(env.cfg.read_text().replace('max_per_day = 20', 'max_per_day = 1').replace(
        'enabled_verbs=["launch"]', 'enabled_verbs=["launch"]\ncommand_per_hour=1'))
    rc, first = request(env, protocol)
    assert rc == 0, first
    # Each call is a fresh route process; the caller may have lost the first response.
    for _ in range(2):
        assert request(env, protocol) == (0, first)
    assert first['request_id'] == ARGS['request_id']
    assert len(env.calls()) == 1
    assert len([r for r in index_rows(env) if 't' in r]) == 1
    audit = [r for r in env.audit() if r['op'] == 'submit']
    assert [r['result'] for r in audit] == ['launching', 'ok', 'replayed', 'replayed']
    assert all(r['request_id'] == ARGS['request_id'] for r in audit)
    route = Route(str(env.cfg), 'grok-admin')
    assert len(route.command_history()) == (1 if 'launch' in protocol else 0)
    assert route.status('cli')['jobs'][0]['request_id'] == ARGS['request_id']
    assert request(env, protocol, dict(ARGS, request_id='another'))[0] != 0
    ledger = route.index.read_text()
    assert ARGS['brief'].strip() not in ledger
    assert len(env.calls()) == 1


@pytest.mark.parametrize('protocol', PROTOCOLS)
@pytest.mark.parametrize('change', [{'engine': 'codex'}, {'label': 'changed'}, {'workdir': 'sub'},
                                   {'brief': 'Fixture request.'}])
def test_changed_payload_conflicts_without_side_effects(tmp_path, protocol, change):
    env = setup(tmp_path)
    assert request(env, protocol)[0] == 0
    before = index_rows(env)
    rc, body = request(env, protocol, dict(ARGS, **change))
    assert rc != 0 and 'different payload' in body['error']
    assert index_rows(env) == before and len(env.calls()) == 1


@pytest.mark.parametrize('protocol', ['launch', 'mcp-launch'])
def test_review_is_part_of_binding(tmp_path, protocol):
    env = setup(tmp_path)
    assert request(env, protocol)[0] == 0
    rc, body = request(env, protocol, dict(ARGS, review='codex'))
    assert rc != 0 and 'different payload' in body['error']
    assert len(env.calls()) == 1


@pytest.mark.parametrize('first,second', [('cli', 'mcp'), ('mcp', 'cli'),
                                         ('launch', 'mcp-launch'), ('mcp-launch', 'launch')])
def test_transport_and_equivalent_workdir_do_not_change_binding(tmp_path, first, second):
    env = setup(tmp_path)
    rc, original = request(env, first)
    assert rc == 0
    for wd in ['.', '', str(tmp_path / 'work/Admin')]:
        assert request(env, second, dict(ARGS, workdir=wd)) == (0, original)
    assert len(env.calls()) == 1


def test_submit_and_launch_share_namespace_but_are_different_payloads(tmp_path):
    env = setup(tmp_path)
    assert request(env, 'cli')[0] == 0
    rc, body = request(env, 'launch')
    assert rc == 2 and 'different payload' in body['error']
    assert len(env.calls()) == 1


@pytest.mark.parametrize('protocol', ['cli', 'mcp'])
def test_id_is_profile_scoped_and_case_sensitive(tmp_path, protocol):
    env = setup(tmp_path)
    assert request(env, protocol)[0] == 0
    rc, doc = request(env, protocol, dict(ARGS, label='doc-retry'), profile='grok-doc')
    assert rc == 0 and doc['agent'] == 'Doc'
    assert request(env, protocol, dict(ARGS, request_id=ARGS['request_id'].lower()))[0] == 0
    assert len(env.calls()) == 3
    rc, [out] = env.run('status job=' + doc['job_id'])
    assert rc == 2 and out['error'] == 'unknown job'


@pytest.mark.parametrize('protocol', ['mcp', 'launch', 'mcp-launch'])
@pytest.mark.parametrize('invalid', ['', 'a'*65, '-bad', '../bad', 'two words', '\n', 'a\0b', 5, True, [], {}])
def test_invalid_request_ids_are_refused(tmp_path, protocol, invalid):
    env = setup(tmp_path)
    rc, body = request(env, protocol, dict(ARGS, request_id=invalid))
    assert rc != 0 and 'request_id' in body['error']
    assert not env.calls() and not index_rows(env)


@pytest.mark.parametrize('protocol', PROTOCOLS)
def test_omitted_id_keeps_legacy_new_launch_behavior(tmp_path, protocol):
    env = setup(tmp_path)
    args = {k: v for k, v in ARGS.items() if k != 'request_id'}
    rc, first = request(env, protocol, args)
    rc2, second = request(env, protocol, args)
    assert rc == rc2 == 0 and first['job_id'] != second['job_id']
    assert 'request_id' not in first and 'request_id' not in second
    assert len(env.calls()) == 2


@pytest.mark.parametrize('protocol', PROTOCOLS)
def test_concurrent_duplicate_is_refused_then_replays(tmp_path, protocol):
    env = setup(tmp_path, extra_env='STUB_SLEEP="2"')
    with ThreadPoolExecutor(max_workers=1) as pool:
        first = pool.submit(request, env, protocol)
        deadline = time.monotonic() + 10
        while not list((tmp_path / 'calls').glob('*.stdin')) and time.monotonic() < deadline:
            time.sleep(.01)
        assert list((tmp_path / 'calls').glob('*.stdin'))
        rc, duplicate = request(env, protocol)
        assert rc != 0 and 'in progress' in duplicate['error']
        rc, conflict = request(env, protocol, dict(ARGS, brief='Changed.'))
        assert rc != 0 and 'different payload' in conflict['error']
        result = first.result(timeout=10)
    assert result[0] == 0 and request(env, protocol) == result
    assert len(env.calls()) == 1 and len([r for r in index_rows(env) if 't' in r]) == 1


@pytest.mark.parametrize('protocol', PROTOCOLS)
@pytest.mark.parametrize('extra', ['STUB_RECEIPT="missing"', 'STUB_EXIT="1"'])
def test_uncertain_launcher_replays_recovered_job(tmp_path, protocol, extra):
    env = setup(tmp_path, extra_env=extra)
    rc, body = request(env, protocol)
    assert rc != 0 and 'did start' in body['error']
    rc, replay = request(env, protocol)
    assert rc == 0 and replay['job_id'] in body['error']
    assert request(env, protocol) == (0, replay)
    assert len(env.calls()) == 1
    assert len([r for r in env.audit() if r['op'] == 'recover']) == 1


@pytest.mark.parametrize('protocol', PROTOCOLS)
def test_unknown_outcome_retains_binding_and_never_relaunches(tmp_path, protocol):
    env = setup(tmp_path, extra_env='STUB_FAIL="1"')
    assert request(env, protocol)[0] != 0
    before = index_rows(env)
    for _ in range(2):
        rc, out = request(env, protocol)
        assert rc != 0 and 'outcome unknown' in out['error'] and 'not relaunched' in out['error']
    assert len(env.calls()) == 1 and index_rows(env) == before


def test_late_record_is_recovered_on_same_id_retry(tmp_path, monkeypatch):
    env = setup(tmp_path, extra_env='STUB_RECEIPT="missing"')
    route = Route(str(env.cfg), 'grok-admin')
    monkeypatch.setattr(route, '_find_record', lambda *a: None)
    with pytest.raises(Refused, match='outcome unknown'):
        route.submit('cli', 'claude', 'retry', None, ARGS['brief'].encode(), request_id=ARGS['request_id'])
    assert request(env, 'cli')[0] == 0
    assert len(env.calls()) == 1


def test_pre_exec_failure_retains_binding_and_historical_failed_rows(tmp_path, monkeypatch):
    env = setup(tmp_path)
    route = Route(str(env.cfg), 'grok-admin')
    historical = {'t': time.time(), 'launch': 'old', 'label': 'retry', 'engine': 'claude'}
    route.index.write_text(json.dumps(historical) + '\n' + '{"launch":"old","failed":"OldError"}\n')
    prefix = route.index.read_bytes()
    with monkeypatch.context() as m:
        def unavailable(*a, **kw):
            raise FileNotFoundError('fixture')
        m.setattr(jobroute_core.subprocess, 'run', unavailable)
        with pytest.raises(Refused, match='FileNotFoundError'):
            route.submit('cli', 'claude', 'retry', None, ARGS['brief'].encode(), request_id=ARGS['request_id'])
    before = route.index.read_bytes()
    assert before.startswith(prefix)
    rc, out = request(env, 'cli')
    assert rc == 1 and 'FileNotFoundError; not relaunched' in out['error']
    assert route.index.read_bytes() == before
    assert route.status('cli')['jobs'] == [] and not env.calls()
    assert request(env, 'cli', dict(ARGS, request_id='new-attempt'))[0] == 0
    assert route.index.read_bytes().startswith(before)


def test_killed_route_recovers_same_id_without_launching_again(tmp_path):
    env = setup(tmp_path, extra_env='STUB_SLEEP="2"')
    cmd = 'submit engine=claude label=retry request_id=' + ARGS['request_id']
    with subprocess.Popen([str(ROUTE), '--config', str(env.cfg), '--profile', 'grok-admin'],
                          env={'PATH': '/usr/bin:/bin', 'SSH_ORIGINAL_COMMAND': cmd},
                          stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as p:
        p.stdin.write(ARGS['brief'].encode())
        p.stdin.close()
        deadline = time.monotonic() + 10
        while not list((tmp_path / 'work/Admin').glob('*-retry.json')) and time.monotonic() < deadline:
            time.sleep(.01)
        try:
            assert list((tmp_path / 'work/Admin').glob('*-retry.json'))
            assert p.poll() is None
        finally:
            if p.poll() is None:
                p.kill()  # exact PID of the route child this test started
            p.wait(timeout=5)
    rc, out = request(env, 'cli')
    assert rc == 0 and out['job_id']
    assert len(env.calls()) == 1 and len([r for r in index_rows(env) if 't' in r]) == 1


def test_replay_still_checks_authorization_but_does_not_need_launcher(tmp_path):
    env = setup(tmp_path)
    result = request(env, 'launch')
    assert result[0] == 0
    # Existing receipts need no executable. A new ID still fails the trust gate.
    (tmp_path / 'bin/claude').unlink()
    assert request(env, 'launch') == result
    assert request(env, 'launch', dict(ARGS, request_id='new'))[0] != 0
    env.cfg.write_text(env.cfg.read_text().replace('submissions_enabled = true', 'submissions_enabled = false'))
    assert request(env, 'launch')[1]['error'] == 'submissions disabled'
    assert len(env.calls()) == 1


def test_mcp_schemas_advertise_id_for_both_launch_interfaces(tmp_path):
    env = setup(tmp_path)
    rc, rows = mcp(env, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'})
    assert rc == 0
    schemas = {t['name']: t['inputSchema'] for t in rows[1]['result']['tools']}
    for name in ['submit_job', 'launch']:
        spec = schemas[name]['properties']['request_id']
        assert spec['type'] == 'string' and '{0,63}' in spec['pattern']
        assert 'request_id' not in schemas[name].get('required', [])


@pytest.mark.parametrize('invalid', ['', 'a'*65, '_bad', 'a.b', 'a/b'])
def test_cli_validates_id_before_reserving(tmp_path, invalid):
    env = setup(tmp_path)
    rc, out = request(env, 'cli', dict(ARGS, request_id=invalid))
    assert rc == 2 and 'request_id' in out['error']
    assert not env.calls() and not index_rows(env)


@pytest.mark.parametrize('request_id', ['a', 'A' + '_-'*31 + 'Z'])
def test_request_id_length_boundaries(tmp_path, request_id):
    env = setup(tmp_path)
    args = dict(ARGS, request_id=request_id)
    result = request(env, 'cli', args)
    assert result[0] == 0 and request(env, 'mcp', args) == result
    assert len(env.calls()) == 1


def test_validation_refusal_does_not_bind_id(tmp_path):
    env = setup(tmp_path)
    assert request(env, 'cli', dict(ARGS, brief=''))[0] == 2
    assert not index_rows(env)
    assert request(env, 'cli')[0] == 0
    assert len(env.calls()) == 1


def test_completed_job_receipt_survives_missing_record_and_old_reservation(tmp_path):
    env = setup(tmp_path)
    result = request(env, 'cli')
    assert result[0] == 0
    (tmp_path / 'work/Admin' / (result[1]['job_id'] + '.json')).unlink()
    route = Route(str(env.cfg), 'grok-admin')
    rows = index_rows(env)
    rows[0]['t'] -= 86400 * 30
    route.index.write_text(''.join(json.dumps(r) + '\n' for r in rows))
    assert request(env, 'cli') == result
    assert len(env.calls()) == 1


def test_command_quota_refusal_does_not_bind_new_id(tmp_path):
    env = setup(tmp_path)
    route = Route(str(env.cfg), 'grok-admin')
    route.command_per_hour = 1
    route.admit_command('queue', 'fixture')
    with pytest.raises(Refused, match='command rate limit'):
        route.command('cli', 'launch', ARGS)
    assert not index_rows(env) and not env.calls()
    route.command_per_hour = 2
    assert route.command('cli', 'launch', ARGS)['ok']
    assert len(env.calls()) == 1
