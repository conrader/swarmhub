"""Skill-update loop (0.6.0): no shipped skill or manager text trips Hermes's hardline command guard.

The install turn writes each file with a shell heredoc, so Hermes's terminal guard reads every line of every file.
swarmhub-coding 1.3.12's SKILL.md said `kill -1` in prose; Hermes's "kill all processes" hardline rule treats a backtick
as a command start, refused the whole command whatever the approval mode, and the install never landed. The rules below
are ported from Hermes 0.22.0 tools/approval_detection.py (plus 0.20.5's unanchored kill rule); `;`, `&` and `|` count
as command starts because Hermes splits on them. SkillInstallLoopTests.swift checks the rendered commands on the Mac.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
START = r'(?:^|[\n`;&|]|\$\()\s*(?:sudo\s+(?:-\S+\s+)*)?(?:env\s+(?:\w+=\S*\s+)*)?(?:(?:exec|nohup|setsid|time)\s+)*\s*'
RM = START + r'rm\s+(-\S*\s+)*'
SYSTEM_DIRS = (r'/home|/home/\*|/root|/root/\*|/etc|/etc/\*|/usr|/usr/\*|/var|/var/\*|/bin|/bin/\*|/sbin|/sbin/\*|'
               r'/boot|/boot/\*|/lib|/lib/\*')


def rm_path(alt):
    return r'(?:["\'](?:%s)["\']|(?:%s)(?:\s|$|[)`;|&]))' % (alt, alt)


HARDLINE = [re.compile(pattern, re.I | re.M) for pattern in [
    RM + rm_path(r'/(?:(?:\.\.?)?/)*(?:\.\.?)?\**|/ \*'), RM + rm_path(SYSTEM_DIRS), RM + rm_path(r'(?:~|\$\{?HOME\}?)(?:/?|/\*)?'),
    START + r'mkfs(\.[a-z0-9]+)?\b', START + r'dd\b[^\n]*\bof=/dev/(sd|nvme|hd|mmcblk|vd|xvd)[a-z0-9]*',
    r'>\s*/dev/(sd|nvme|hd|mmcblk|vd|xvd)[a-z0-9]*\b', r':\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:',
    r'\bkill\s+(-\S+\s+)*-1\b', START + r'(shutdown|reboot|halt|poweroff)\b', START + r'init\s+[06]\b',
    START + r'systemctl\s+(poweroff|reboot|halt|kexec)\b', START + r'telinit\s+[06]\b']]


def matches(text):
    return [found.group(0) for rule in HARDLINE for found in rule.finditer(text)]


def shipped():
    folders = [ROOT / 'Resources/Skills', ROOT / 'Resources/BotManager']
    return [path for folder in folders for path in sorted(folder.rglob('*'))
            if path.is_file() and not path.name.startswith('.') and '__pycache__' not in path.parts]


class SkillGuardPhraseTests(unittest.TestCase):
    def test_the_port_catches_the_060_sentence(self):
        self.assertEqual(matches("groups (`verify_signals.py`; `kill -1`, the"), ['kill -1'])
        self.assertEqual(matches('a broadcast signal to PID -1, the launcher'), [])

    def test_no_shipped_file_trips_a_hardline_rule(self):
        files = shipped()
        self.assertTrue(any(path.name == 'SKILL.md' for path in files))
        for path in files:
            with self.subTest(str(path.relative_to(ROOT))):
                self.assertEqual(matches(path.read_text(encoding='utf-8')), [])


if __name__ == '__main__':
    unittest.main()
