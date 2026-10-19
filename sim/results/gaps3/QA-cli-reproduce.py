import hashlib, json, os
from pathlib import Path
import shutil, subprocess, sys, tempfile
sys.path.insert(0, str(Path.cwd() / 'sim'))
from live_cli import cli_env, coding_cli, qa_repo, writable_cli_state
out = Path.cwd() / 'sim/results/gaps3'
installed = '/home/box/.npm-global/bin'
source_env = dict(os.environ, PATH=installed + ':' + os.environ['PATH'])
cli = coding_cli(source_env)
assert cli, 'Installed CLI authentication unavailable'
source = Path(cli['codex_home'])
def hashes():
 return {name: hashlib.sha256((source / name).read_bytes()).hexdigest() for name in ('auth.json', 'config.toml') if (source / name).is_file()}
before = hashes()
with tempfile.TemporaryDirectory(prefix='gaps3-cli-') as temporary:
 root = Path(temporary)
 home = root / 'home'; home.mkdir()
 private = writable_cli_state(cli, root / 'codex')
 env = cli_env(dict(source_env, HOME=str(home), PYTHONDONTWRITEBYTECODE='1', CODE_JOB_POLL='1'), private)
 # Unchanged shipped runner in an isolated layout with no messaging/control sibling:
 # the job records its completion locally and cannot send a wake to any gateway.
 runner = root / 'isolated/coding/scripts/code-job'; runner.parent.mkdir(parents=True)
 shutil.copyfile(Path.cwd() / 'Resources/Skills/swarmhub-coding/scripts/code-job', runner)
 shutil.copyfile(Path.cwd() / 'Resources/Skills/swarmhub-coding/scripts/completion-contract.py', runner.with_name('completion-contract.py'))
 repo = qa_repo(root / 'repo')
 verify = "grep -Fxq 'gaps3 CLI tools work' NOTES.md && grep -Fxq 'command ran' COMMAND.txt"
 argv = ['/bin/sh', str(runner), '--bot', 'QA-Gaps3', '--order', 'codex', '--model', 'gpt-6-astra', '--effort', 'high', '--report', 'REPORT.md', '--dir', str(repo), '--verify', verify, '--timeout', '180', '--',
         "Tiny local QA task only. Edit NOTES.md to contain exactly 'gaps3 CLI tools work' plus newline. Run a shell command that writes 'command ran' plus newline to COMMAND.txt and checks NOTES.md with grep. Write REPORT.md describing the actual edit and command result. Do not commit. Do not use network, external connectors or other agents."]
 result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=220)
 (out / 'QA-cli-stdout.txt').write_text(result.stdout)
 (out / 'QA-cli-stderr.txt').write_text(result.stderr)
 job = next((home / '.hermes/swarmhub/job-completions').glob('job.*'))
 fields = {k:(job/k).read_text().strip() for k in ('agent','status','exit','cli-exit','report-valid','verify-command','verify-exit','tests-passed','evidence','commit-evidence') if (job/k).exists()}
 evidence = {'cli_path':cli['path'], 'cli_version':subprocess.run([cli['path'],'--version'],env=env,capture_output=True,text=True).stdout.strip(), 'model':'gpt-6-astra','effort':'high','runner_unchanged':runner.read_bytes()==(Path.cwd()/'Resources/Skills/swarmhub-coding/scripts/code-job').read_bytes(), 'exit':result.returncode,'fields':fields,'runtime_modes':{k:oct(Path(private[k]).stat().st_mode & 0o777) for k in ('codex_home','runtime_dir','tmp_dir')}, 'artifacts':{p.name:p.read_text() for p in repo.glob('*.md') if p.name != 'README.md'}, 'command_output':(repo/'COMMAND.txt').read_text() if (repo/'COMMAND.txt').exists() else None,'source_auth_config_unchanged':before==hashes(), 'no_messaging_sibling':not (runner.parent/'../../swarmhub-messages').exists()}
 (out/'QA-cli-smoke.json').write_text(json.dumps(evidence,indent=2)+'\n')
 print(json.dumps(evidence,indent=2))
 assert result.returncode == 0 and fields['report-valid']=='true' and fields['tests-passed']=='true', 'Real CLI smoke failed; diagnostics retained'
