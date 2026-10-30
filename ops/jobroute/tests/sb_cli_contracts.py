"""Parser-only snapshots from installed OVH sb sources, 2026-10-30.
No sb imports, dispatch, submissions, network access or ledger writes.
Only argparse declarations and pure notify value validators are retained.
sb-macjob delegates queue to job_process.py with its fixed directory prepended.
Source SHA-256:
sb-msg: a919aac12e0c03df41d1f267df9e5e93db856c11e0a1543741893d64ae837789
sb-park: d5b6451033eca5678619cfbb4b90019ed3598a5e757fd2f9f2196002bf98a66e
sb-codejob: cffae7cb5c728cfc61d81d213a5311648e95ef17eee1db43b02dcf1e5035c617
job_process.py: 33c8ad831f672c562627853bfada58a73d5c97bb2f770fd72ed2213048a775e0
sb-macjob: 8eca7c321f7f99cf82cadeb4739a702d28b1aa07b3ac295368f002c31f593c7d
"""
import argparse
import datetime
import re

NAME_RX = re.compile('[A-Za-z0-9][A-Za-z0-9._-]{0,63}')
AGENT_RX = re.compile('[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}')

def name_arg(s: str) -> str:
    if not NAME_RX.fullmatch(s):
        raise ValueError(s)
    return s

def agent_arg(s: str) -> str:
    if not AGENT_RX.fullmatch(s):
        raise ValueError(s)
    return s

def path_arg(s: str) -> str:
    if len(s) > 1024 or any((ord(c) < 32 for c in s)):
        raise ValueError(s)
    return s

def iso_arg(s: str) -> float:
    s = s.strip()
    if s[-1:] in ('Z', 'z'):
        s = s[:-1] + '+00:00'
    d = datetime.datetime.fromisoformat(s)
    return (d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)).timestamp()

def send_parser():
    s = argparse.ArgumentParser()
    s.add_argument('--via', choices=('whatsapp', 'telegram'), required=True)
    s.add_argument('--to', required=True)
    s.add_argument('--text', required=True)
    s.add_argument('--reason', default='')
    s.add_argument('--reply-to')
    s.add_argument('--as-konrad', action='store_true')
    s.add_argument('--by')
    s.add_argument('--wait', type=int, default=0)
    s.add_argument('--dry', action='store_true')
    s.add_argument('--approved', help=argparse.SUPPRESS)
    return s

def park_parser():
    ap = argparse.ArgumentParser()
    ap.add_argument('--by', required=True, help='kto prosi, np. pilot-responso-answer')
    ap.add_argument('--reason', required=True, help='argumentacja — po co, teraz, komu to służy')
    ap.add_argument('--what-changes', required=True, help='co ta komenda zmienia, jednym zdaniem')
    ap.add_argument('--reverse', required=True, help='polecenie, które to odwraca')
    ap.add_argument('--command', help='explicit shell script to execute after approval; prefer argv after --')
    ap.add_argument('argv', nargs=argparse.REMAINDER, help='command argv after -- (no shell)')
    ap.add_argument('--dry', action='store_true', help='pokaż i nie zapisuj')
    return ap

def notify_parser():
    p = argparse.ArgumentParser()
    p.add_argument('--agent', required=True, type=agent_arg)
    p.add_argument('--host', required=True, type=name_arg)
    p.add_argument('--exit-code', required=True, type=lambda s: None if s == 'unknown' else int(s))
    p.add_argument('--started', required=True, type=iso_arg)
    p.add_argument('--ended', required=True, type=iso_arg)
    p.add_argument('--log', type=path_arg)
    p.add_argument('--workdir', type=path_arg)
    p.add_argument('--label', type=name_arg)
    p.add_argument('--source', default='sb-macjob', type=name_arg)
    p.add_argument('--commit', default=None)
    p.add_argument('--json', action='store_true', help='return the safe wake receipt as JSON')
    p.add_argument('--remote-workdir', action='store_true', help='workdir is on the launching host')
    p.add_argument('--review-state', choices=('none', 'requested', 'ran', 'passed', 'concerns', 'failed', 'unavailable'))
    p.add_argument('--reviewer-model')
    p.add_argument('--review-verdict', choices=('PASS', 'CONCERNS', 'FAIL'))
    p.add_argument('--review-summary')
    p.add_argument('--review-reason')
    p.add_argument('--review-file', type=path_arg)
    return p

def queue_parser():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory')
    parser.add_argument('--json', action='store_true')
    return parser
