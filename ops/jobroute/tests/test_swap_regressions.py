"""Report regressions and real sb parser contracts; backend calls never execute."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from test_swap_commands import env, call
from jobroute_core import Route
from sb_cli_contracts import send_parser, park_parser, notify_parser, queue_parser


@pytest.mark.parametrize('log,report', [
    ('old log\n' * 150000 + '\nlog tail', 'completion report'),
    (None, 'completion report'),
    ('log tail', None),
    (None, None),
    ('log tail', 'old report\n' * 110000 + '\ncompletion report'),
], ids=['oversize-log', 'missing-log', 'missing-report', 'both-missing', 'oversize-report'])
def test_status_report_reads_bounded_artifacts_independently(env, log, report):
    rc, [out] = call(env, 'launch', {'engine': 'codex', 'label': 'report', 'brief': 'Fix tests'})
    assert rc == 0, out
    job = out['job_id']
    root = env.tmp / 'work/Admin'
    for suffix, text in (('.log', log), ('-report.md', report)):
        path = root / (job + suffix)
        path.unlink(missing_ok=True)
        if text is not None:
            path.write_text(text + '\napi_key=abc123456789XYZ')
    rc, [out] = env.run(f'status job={job} report=1')
    assert rc == 0, out
    text = out['jobs'][0]['report']
    assert len(text.encode()) <= 16384
    assert 'abc123456789XYZ' not in text
    if log is not None and (report is None or len(report) < 16300):
        assert 'log tail' in text
    if report is not None:
        assert 'completion report' in text
    if log is report is None:
        assert text == ''


def test_message_and_script_park_match_installed_sb_parsers(env, monkeypatch):
    route = Route(str(env.cfg), 'grok-admin')
    route.backends['msg'] = '/usr/bin/true'
    parked = []

    def backend(name, argv, **kwargs):
        assert name == 'park'
        parsed = park_parser().parse_args(argv)
        assert parsed.by == 'Admin:jobroute'
        assert len(parsed.reason) >= 15 and parsed.what_changes and parsed.reverse
        assert parsed.command is None and parsed.argv[0] == '--'
        parked.append(parsed.argv[1:])
        return 'c12345678\n'

    monkeypatch.setattr(route, 'backend', backend)
    args = {'via': 'telegram', 'to': 'recipient', 'text': 'Exact $(id) text',
            'reason': 'Reply to the requested question'}
    route.command('cli', 'msg', args)
    assert parked[0][:2] == ['/usr/bin/true', 'send']
    parsed = send_parser().parse_args(parked[0][2:])
    assert (parsed.via, parsed.to, parsed.text, parsed.reason, parsed.by) == (
        args['via'], args['to'], args['text'], args['reason'], 'Admin:jobroute')
    assert not parsed.approved and not parsed.as_konrad and not parsed.dry
    script = env.tmp / 'work/Admin/action.sh'
    script.write_text('echo fixture\n')
    route.command('cli', 'park', {'script': str(script), 'reason': args['reason'],
                                 'changes': 'fixture change', 'reverse': 'restore fixture'})
    assert parked[1] == ['/bin/sh', str(script)]


def test_report_jarvis_matches_installed_notify_parser_and_stdin(env, monkeypatch):
    route = Route(str(env.cfg), 'grok-admin')

    def backend(name, argv, data=b'', **kwargs):
        assert name == 'codejob' and argv[0] == 'notify'
        parsed = notify_parser().parse_args(argv[1:])
        assert (parsed.agent, parsed.host, parsed.source, parsed.exit_code, parsed.json) == (
            'Jarvis', 'ovh', 'swarmhub-jobroute', 0, True)
        assert parsed.started == parsed.ended and parsed.started > 0
        assert data == b'Admin: Fixture report'  # notify reads up to 64 KiB from stdin.
        return json.dumps({'wake': 'HTTP 202'})

    monkeypatch.setattr(route, 'backend', backend)
    assert route.command('cli', 'report-jarvis', {'text': 'Fixture report'})['jarvis']['wake'] == 'HTTP 202'


def test_mac_queue_matches_installed_wrapper_and_helper_parser(tmp_path):
    spec = importlib.util.spec_from_file_location('queue_worker', Path(__file__).parents[1] / 'mac-worker.py')
    worker = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(worker)
    calls = []

    def execute(argv, **kwargs):
        calls.append(argv)
        assert argv[:2] == [str(tmp_path / '.local/bin/sb-macjob'), 'queue']
        # Installed sb-macjob prepends QUEUE_DIR before delegating to job_process.py.
        parsed = queue_parser().parse_args([str(tmp_path / 'fixture-queue'), *argv[2:]])
        assert parsed.json is True
        return SimpleNamespace(returncode=0)

    assert worker.run({'operation': 'queue', 'agent': 'Admin'}, tmp_path, execute) == 0
    assert len(calls) == 1
    assert not (tmp_path / 'work').exists()
