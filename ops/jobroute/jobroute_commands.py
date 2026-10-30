"""Opt-in swap commands. Text is stdin data; authority stays in sb's approval ledger."""
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
from zoneinfo import ZoneInfo

from jobroute_jobs import _append
from jobroute_trust import launch_problem
from secretscan import redact

SCHEMAS = {
    'launch': {'engine', 'label', 'workdir', 'brief', 'review'},
    'park': {'script', 'reason', 'changes', 'reverse'},
    'approve-wait': {'id', 'timeout'},
    'msg': {'via', 'to', 'text', 'reason'},
    'msg-send': {'park'},
    'macjob': {'host', 'label', 'workdir', 'brief'},
    'queue': {'host'},
    'report-jarvis': {'text'},
}
ID = re.compile(r'c[0-9a-f]{8}')


def bounded_text(value, name, maximum=8192):
    from jobroute_core import Refused
    if not isinstance(value, str) or not value.strip() or '\0' in value or len(value.encode()) > maximum:
        raise Refused(f'{name} must be nonempty UTF-8 text within {maximum} bytes')
    return value


def private_read(path, maximum):
    """No links, devices or unlimited reads, including when the file changes during open."""
    import stat
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as f:
        if not stat.S_ISREG(os.fstat(f.fileno()).st_mode):
            raise ValueError('expected a regular file')
        data = f.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError('file exceeds limit')
    return data


class Commands:
    def command(self, mode, op, args):
        from jobroute_core import Refused, RateLimited
        digest = hashlib.sha256(json.dumps(args, sort_keys=True).encode()).hexdigest()
        try:
            if op not in SCHEMAS or not isinstance(args, dict) or set(args) - SCHEMAS[op]:
                raise Refused('unknown operation or arguments')
            if op not in self.enabled_verbs:
                raise Refused('operation disabled')
            # Persist a request reservation before side effects. Polling is limited too.
            self.admit_command(op, digest)
            result = self._command(mode, op, args)
        except Exception as exc:
            self.audit(op, mode, 'refused' if isinstance(exc, Refused) else 'error', request_sha256=digest,
                       reason=exc.reason if isinstance(exc, Refused) else type(exc).__name__)
            exc.audited = True
            raise
        self.audit(op, mode, 'ok', request_sha256=digest)
        return result

    def admit_command(self, op, digest):
        from jobroute_core import RateLimited
        with self._lock():
            history = self.command_history()
            now = time.time()
            if sum(now - x['t'] < 3600 for x in history) >= self.command_per_hour:
                raise RateLimited('command rate limit')
            _append(self.command_index, {'t': now, 'op': op, 'sha256': digest})

    @property
    def command_index(self):
        return self.index.with_suffix('.commands.jsonl')

    def command_history(self):
        if not self.command_index.exists():
            return []
        return [json.loads(x) for x in self.command_index.read_text().splitlines()]

    def backend(self, name, argv, data=b'', cwd=None, timeout=60):
        from jobroute_core import Refused
        binary = self.backends.get(name)
        if not isinstance(binary, str):
            raise Refused('backend not configured')
        problem, cmd = launch_problem(binary, [binary], self.path)
        if problem:
            raise Refused('backend trust check failed', 1)
        env = {'PATH': self.path, 'HOME': self.route_home, 'LANG': 'C.UTF-8', **self.extra_env}
        env.pop('ANTHROPIC_API_KEY', None)
        # Output goes to a private file, bounded on read (never a pipe-sized memory allocation).
        import tempfile
        with tempfile.TemporaryFile() as out:
            p = subprocess.run([cmd[0], *argv], input=data, stdout=out, stderr=subprocess.DEVNULL,
                               env=env, cwd=cwd, timeout=timeout)
            out.seek(0)
            text = out.read(16385).decode('utf-8', 'replace')
        if len(text.encode()) > 16384:
            raise Refused('backend output exceeds limit', 1)
        if p.returncode:
            raise Refused('backend failed; inspect the private backend ledger', 1)
        return text

    def approval(self, ident):
        from jobroute_core import Refused
        # Only ids recorded for THIS key-bound profile are visible. Never accept peer claims.
        if not isinstance(ident, str) or not ID.fullmatch(ident):
            raise Refused('unknown approval')
        own = next((x for x in self.command_history() if x.get('id') == ident), None)
        if own is None:
            raise Refused('unknown approval')
        record = json.loads(private_read(self.approvals / (ident + '.json'), 1 << 20))
        if record.get('id') != ident or record.get('by') != self.agent + ':jobroute':
            raise Refused('approval identity mismatch')
        return own, record

    def _command(self, mode, op, a):
        from jobroute_core import Refused
        if op == 'launch':
            brief = bounded_text(a.get('brief'), 'brief', self.max_brief).encode()
            brief += (b'\n\nSwarmHub completion report: write a secret-free report to '
                      b'${SB_CODEJOB%.json}-report.md (derive this path from the SB_CODEJOB environment variable; '
                      b'do not modify the .json status record). Include changes, tests, and remaining work.\n')
            review = a.get('review')
            if review is not None and review != {'claude': 'codex', 'codex': 'claude'}.get(a.get('engine')):
                raise Refused('review must name the opposite engine')
            # sb-codejob --review chooses the opposite engine; no caller-controlled flags.
            self.request_review = review is not None
            try:
                return self.submit(mode, a.get('engine'), a.get('label'), a.get('workdir'), brief)
            finally:
                self.request_review = False
        if op == 'park':
            script = Path(bounded_text(a.get('script'), 'script', 512))
            if not script.is_absolute():
                raise Refused('script must be an absolute path in your workdir')
            wd = self.check_workdir(str(script.parent))
            content = private_read(script, 65536)
            sha = hashlib.sha256(content).hexdigest()
            reason = bounded_text(a.get('reason'), 'reason')
            changes = bounded_text(a.get('changes'), 'changes')
            reverse = bounded_text(a.get('reverse'), 'reverse')
            # sb-park captures and verifies the script snapshot again before approved execution.
            text = self.backend('park', ['--by', self.agent + ':jobroute', '--reason', reason,
                '--what-changes', changes, '--reverse', reverse, '--', '/bin/sh', str(script)], cwd=wd)
            ident = text.strip().splitlines()[-1]
            if not ID.fullmatch(ident):
                raise Refused('invalid park receipt', 1)
            _append(self.command_index, {'t': time.time(), 'id': ident, 'kind': 'script', 'script_sha256': sha})
            return {'ok': True, 'id': ident, 'state': 'pending', 'script_sha256': sha}
        if op == 'approve-wait':
            seconds = a.get('timeout', 0)
            if type(seconds) is not int or not 0 <= seconds <= 600:
                raise Refused('timeout must be 0-600 seconds')
            deadline = time.monotonic() + seconds
            while True:
                _, rec = self.approval(a.get('id'))
                state = rec.get('state', 'pending')
                if state != 'pending' or time.monotonic() >= deadline:
                    return {'ok': True, 'id': a['id'], 'state': state}
                time.sleep(min(.25, max(0, deadline - time.monotonic())))
        if op == 'msg':
            if a.get('via') not in ('whatsapp', 'telegram'):
                raise Refused('via must be whatsapp or telegram')
            to = bounded_text(a.get('to'), 'to', 256)
            text = bounded_text(a.get('text'), 'text')
            reason = bounded_text(a.get('reason'), 'reason')
            binary = self.backends.get('msg')
            if not binary or launch_problem(binary, [binary], self.path)[0]:
                raise Refused('message backend trust check failed')
            argv = [binary, 'send', '--via', a['via'], '--to', to, '--text', text,
                    '--reason', reason, '--by', self.agent + ':jobroute']
            # Always park the exact argv first. sb's approval runner executes it once and records output_head.
            result = self.backend('park', ['--by', self.agent + ':jobroute', '--reason', reason,
                '--what-changes', 'Send the exact outbound message; text sha256=' + hashlib.sha256(text.encode()).hexdigest(),
                '--reverse', 'A delivered message cannot be recalled; escalate irreversible effects to the owner',
                '--', *argv])
            ident = result.strip().splitlines()[-1]
            if not ID.fullmatch(ident):
                raise Refused('invalid park receipt', 1)
            _append(self.command_index, {'t': time.time(), 'id': ident, 'kind': 'message',
                'text_sha256': hashlib.sha256(text.encode()).hexdigest(),
                'argv_sha256': hashlib.sha256(json.dumps(argv).encode()).hexdigest()})
            return {'ok': True, 'id': ident, 'state': 'pending'}
        if op == 'msg-send':
            own, rec = self.approval(a.get('park'))
            if own['kind'] != 'message' or hashlib.sha256(json.dumps(rec.get('argv')).encode()).hexdigest() != own['argv_sha256']:
                raise Refused('message approval binding mismatch')
            # sb-approve runs the parked argv itself. Replaying a send here would duplicate it.
            result = rec.get('output_head', '')
            return {'ok': True, 'state': rec.get('state', 'pending'), 'result': redact(result)}
        if op in ('macjob', 'queue'):
            host = a.get('host', 'macbook')
            if host not in self.mac_hosts or host not in ('macbook', 'mini'):
                raise Refused('Mac host not allowlisted')
            request = {'operation': op, 'agent': self.agent}
            if op == 'macjob':
                self.check_label(a.get('label'))
                wd = self.check_workdir(a.get('workdir'))
                brief = bounded_text(a.get('brief'), 'brief', self.max_brief)
                request.update(label=a['label'], brief=brief)
                # Reuse the sb-codejob reservation/recovery/wake machinery. A trusted fixed adapter sends
                # the request to the allowlisted host. No host address or SSH option comes from the bot.
                worker = self.backends.get('mac_dispatch')
                if not worker:
                    raise Refused('Mac dispatcher not configured')
                old = self.engines.get('macjob'), self.allowed_engines[:]
                self.engines['macjob'] = [worker, host]
                self.allowed_engines.append('macjob')
                try:
                    return self.submit(mode, 'macjob', a['label'], wd, json.dumps(request).encode())
                finally:
                    if old[0] is None:
                        self.engines.pop('macjob', None)
                    else:
                        self.engines['macjob'] = old[0]
                    self.allowed_engines = old[1]
            return {'ok': True, 'queue': json.loads(self.backend('mac_dispatch', [host], json.dumps(request).encode()))}
        if op == 'report-jarvis':
            text = bounded_text(a.get('text'), 'text')
            # Use sb-codejob's authenticated wake transport, targeting Jarvis; never accept a URL/key.
            now = dt.datetime.now(dt.timezone.utc)
            stamp = now.isoformat()
            result = self.backend('codejob', ['notify', '--agent', 'Jarvis', '--host', 'ovh', '--source',
                'swarmhub-jobroute', '--exit-code', '0', '--started', stamp, '--ended', stamp, '--json'],
                (self.agent + ': ' + text).encode())
            hour = now.astimezone(ZoneInfo('Europe/Warsaw')).hour
            return {'ok': True, 'jarvis': json.loads(result), 'owner_report_due': 8 <= hour < 23}
        raise Refused('unknown operation')

    def report(self, job_id):
        from jobroute_core import Refused
        self.admit_command('report', hashlib.sha256(job_id.encode()).hexdigest())
        own = next((j for j in self.own_jobs() if j.get('id') == job_id), None)
        if own is None:
            raise Refused('unknown job')
        # Only deterministic paths of the owned job are readable, never a path supplied by the bot or log.
        root = self.job_root / self.agent
        if root.is_symlink() or any(p.is_symlink() for p in root.parents):
            raise Refused('job report directory must not traverse symlinks')
        texts = []
        for suffix in ('.log', '-report.md'):
            try:
                raw = private_read(root / (job_id + suffix), 1 << 20).decode('utf-8', 'replace')
                texts.append(redact(raw))
            except FileNotFoundError:
                continue
        combined = '\n'.join(texts).encode()
        return combined[-16384:].decode('utf-8', 'ignore')
