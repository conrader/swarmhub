"""Fixes8 item 3: the coding and messages skills changed in fixes7/fixes8, so their versions were bumped.

SkillLibrary.state (Sources/AgentApp/BotManager/SkillLibrary.swift) reports an install as outdated when its semver is
below the bundled SKILL.md version. No Swift toolchain here: this checks the bundled versions against the previous
ones with the same numeric comparison, and that the Swift tests pin the same numbers (they run on the Mac).
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SKILLS = ROOT / 'Resources/Skills'
TESTS = ROOT / 'Tests/AgentAppTests'
# skill -> (version installed before this change, bundled now, the Swift test that pins it)
BUMPS = {'swarmhub-coding': ('1.3.12', '1.3.13', 'CodingSkillTests.swift'),  # skill-update-loop: `kill -1` prose tripped Hermes's hardline guard
         'swarmhub-messages': ('1.4.5', '1.4.6', 'BotMessageSkillTests.swift')}  # coreInt2: merged P5d/P8a content collision


def semver(text):
    match = re.fullmatch(r'(\d+)\.(\d+)\.(\d+)', text)
    return tuple(int(part) for part in match.groups()) if match else None


def bundled_version(skill):
    return re.search(r'^version: (\S+)$', (SKILLS / skill / 'SKILL.md').read_text(), re.M).group(1)


class SkillVersionBumpTests(unittest.TestCase):
    def test_an_install_at_the_previous_version_is_outdated(self):
        for skill, (previous, current, _) in BUMPS.items():
            with self.subTest(skill):
                self.assertEqual(bundled_version(skill), current)
                self.assertLess(semver(previous), semver(bundled_version(skill)))  # SkillLibrary.state: .outdated

    def test_the_swift_tests_pin_the_bundled_versions(self):
        for skill, (previous, current, tests) in BUMPS.items():
            with self.subTest(skill):
                source = (TESTS / tests).read_text()
                self.assertIn('skill.version == SkillVersion("%s")!' % current, source)
                self.assertNotIn('skill.version == SkillVersion("%s")!' % previous, source)
        self.assertIn('func installsAtThePreviousSkillVersionsAreOutdated', (TESTS / 'CodingSkillTests.swift').read_text())


if __name__ == '__main__':
    unittest.main()
