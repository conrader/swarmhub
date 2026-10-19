#!/usr/bin/env python3
"""Real CLI acceptance probe derived from gaps3/QA-cli-reproduce.py.

Run this from the plain box shell when available. It never changes the shipped
runner, disables its sandbox, supplies a CLI stub, or contacts Hermes. All
credentials/config are disposable copies; source values never enter evidence.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from live_cli import cli_env, coding_cli, qa_repo, source_auth_snapshot, writable_cli_state

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--execution-path', required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    source_env = dict(os.environ)
    source_home = source_env.get('CODEX_HOME') or str(Path.home() / '.codex')
    source = {'codex_home': source_home}
    before = source_auth_snapshot(source)
    cli = coding_cli(source_env)
    assert cli, 'Installed CLI authentication unavailable'
    evidence = {'execution_path': args.execution_path, 'cli_path': cli['path'],
                'model': 'gpt-6-astra', 'effort': 'high', 'source_auth_config_unchanged': None}
    try:
        with tempfile.TemporaryDirectory(prefix='QA-live6-cli-') as temporary:
            root = Path(temporary)
            home = root / 'QA-home'; home.mkdir(mode=0o700)
            private = writable_cli_state(cli, root / 'QA-codex')
            env = cli_env({'HOME': str(home), 'PYTHONDONTWRITEBYTECODE': '1', 'CODE_JOB_POLL': '1'}, private)
            runner = root / 'isolated/coding/scripts/code-job'
            runner.parent.mkdir(parents=True)
            shipped = ROOT / 'Resources/Skills/swarmhub-coding/scripts/code-job'
            shutil.copyfile(shipped, runner)
            shutil.copyfile(shipped.with_name('completion-contract.py'), runner.with_name('completion-contract.py'))
            shutil.copyfile(shipped.with_name('verify-sandbox.py'), runner.with_name('verify-sandbox.py'))
            shutil.copyfile(shipped.with_name('verify_darwin.py'), runner.with_name('verify_darwin.py'))
            shutil.copyfile(shipped.with_name('verify_processes.py'), runner.with_name('verify_processes.py'))
            shutil.copyfile(shipped.with_name('verify_signals.py'), runner.with_name('verify_signals.py'))
            repo = qa_repo(root / 'QA-repo')
            verify = "grep -Fxq 'QA-live6 CLI tools work' NOTES.md && grep -Fxq 'QA-command ran' COMMAND.txt"
            argv = ['/bin/sh', str(runner), '--bot', 'QA-Live6', '--order', 'codex', '--model', 'gpt-6-astra',
                    '--effort', 'high', '--report', 'REPORT.md', '--dir', str(repo), '--verify', verify,
                    '--timeout', '180', '--',
                    "Tiny local QA task only. Edit NOTES.md to contain exactly 'QA-live6 CLI tools work' plus newline. "
                    "Run a shell command that writes 'QA-command ran' plus newline to COMMAND.txt and checks NOTES.md "
                    "with grep. Write REPORT.md describing the actual edit and command result. Do not commit. "
                    "Do not use network, external connectors or other agents. Do not read files outside this repo."]
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=220)
            (args.output / 'QA-cli-stdout.txt').write_text(result.stdout)
            (args.output / 'QA-cli-stderr.txt').write_text(result.stderr)
            job = next((home / '.hermes/swarmhub/job-completions').glob('job.*'))
            names = ('agent', 'status', 'exit', 'cli-exit', 'report-valid', 'verify-command', 'verify-exit',
                     'tests-passed', 'evidence', 'commit-evidence')
            fields = {name: (job / name).read_text().strip() for name in names if (job / name).exists()}
            evidence.update(exit=result.returncode, fields=fields, runner_unchanged=runner.read_bytes() == shipped.read_bytes(),
                            cli_version=subprocess.run([cli['path'], '--version'], env=env, capture_output=True,
                                                       text=True).stdout.strip(),
                            private_files={name: {'symlink': (Path(private['codex_home']) / name).is_symlink(),
                                                  'mode': oct((Path(private['codex_home']) / name).stat().st_mode & 0o777)}
                                           for name in ('auth.json', 'config.toml') if (Path(private['codex_home']) / name).exists()},
                            artifacts={p.name: p.read_text() for p in repo.iterdir() if p.is_file() and p.name != 'README.md'},
                            no_messaging_sibling=not (runner.parent / '../../swarmhub-messages').exists())
            calls = set()
            for path in (Path(private['codex_home']) / 'sessions').rglob('*.jsonl'):
                for line in path.read_text().splitlines():
                    item = json.loads(line)
                    if item.get('type') == 'token_usage_record' and item.get('payload', {}).get('response_id'):
                        calls.add(item['payload']['response_id'])
            evidence['recorded_provider_responses'] = len(calls)
    finally:
        evidence['source_auth_config_unchanged'] = before == source_auth_snapshot(source)
        (args.output / 'QA-cli-smoke.json').write_text(json.dumps(evidence, indent=2) + '\n')
        assert evidence['source_auth_config_unchanged'], 'Source auth/config changed; diagnostics retained'
    print(json.dumps({k: evidence[k] for k in ('exit', 'recorded_provider_responses', 'source_auth_config_unchanged')}))
    return 0 if evidence['exit'] == 0 and evidence['fields']['report-valid'] == 'true' and evidence['fields']['tests-passed'] == 'true' else 1


if __name__ == '__main__':
    raise SystemExit(main())
