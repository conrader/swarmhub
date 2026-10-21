"""Fixes16: a determiner followed by modifiers before a homograph ("the nightly build") is a noun object.

The same phrases live in GoalTests.swift. Compatible with Python 3.9.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import unittest

try:
    from sim import goal_classifier
    from sim.test_fixes8_goal import swift_table
except ImportError:
    import goal_classifier
    from test_fixes8_goal import swift_table


MODIFIED_NOUNS = [
    'Explain why the nightly build, refactor and test the parser',
    'Explain why our nightly build, refactor and test the parser',
    'Explain why the slow test, fix and deploy the server',
    'Explain why the previous build, refactor and test the parser',
    'Explain why a clean build, refactor and test the parser',
    'Explain why their latest deploy, fix and test the parser',
    'Explain why this quick fix, refactor and test the parser',
    'Explain why the slow unit test, refactor and deploy the server',
    'Explain why our nightly smoke run, fix and test the parser',
    "Explain why our team's nightly build, refactor and test the parser",
    'Explain what the nightly build, refactor and test the parser',
    'Explain how the slow test, fix and deploy the server',
    'Can you explain why the nightly build, refactor and test the parser?',
    'Explain why the nightly build, and refactor and test the parser',
    'Explain why the nightly build, then fix the parser',
]
NOUN_EXPLANATIONS = [
    'Explain why the nightly build fails',
    'Explain why our nightly build fails',
    'Explain why the slow test times out',
    'Explain what the slow unit test does',
    'Explain how the nightly build works',
    'Explain how the nightly build, test and deploy steps work',
    'Explain why the nightly build, write and update the summary',
    'Why does the nightly build fail?',
]
PLURAL_SUBJECTS = [
    'Explain why the developers build, test and deploy the server',
    'Explain why the senior developers build, test and deploy the server',
    'Explain why our senior developers fix, test and deploy the server',
    'Explain why the team members build, test and deploy the server',
    'Explain why the developers often build, test and deploy the server',
    'Explain why the developers also build, test and deploy the server',
]

CODING = MODIFIED_NOUNS
GENERAL = NOUN_EXPLANATIONS + PLURAL_SUBJECTS


class ModifiedNounTests(unittest.TestCase):
    def assert_phrases(self, phrases, coding):
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertEqual(goal_classifier.looks_like_coding(phrase), coding)

    def test_modified_noun_objects_do_not_head_explanatory_series(self):
        self.assert_phrases(MODIFIED_NOUNS, True)

    def test_modified_nouns_without_commands_stay_general(self):
        self.assert_phrases(NOUN_EXPLANATIONS, False)

    def test_plural_noun_subjects_still_head_explanatory_series(self):
        self.assert_phrases(PLURAL_SUBJECTS, False)

    def test_noun_phrase_scan(self):
        words = 'explain why our team s nightly build'.split()
        self.assertTrue(goal_classifier.follows_determiner(words, len(words) - 1))
        for text in ('explain why the developers build', 'explain why developers build',
                     'explain why the developers also build', 'explain why the , build'):
            words = text.split()
            with self.subTest(text=text):
                self.assertFalse(goal_classifier.follows_determiner(words, len(words) - 1))
        self.assertFalse(goal_classifier.looks_plural('previous'))
        self.assertFalse(goal_classifier.looks_plural('class'))
        self.assertTrue(goal_classifier.looks_plural('members'))

    def test_every_phrase_has_the_same_expectation_in_swift(self):
        for name, phrases in (('coding', CODING), ('general', GENERAL)):
            table = swift_table(name)
            for phrase in phrases:
                with self.subTest(table=name, phrase=phrase):
                    self.assertIn(phrase, table)


if __name__ == '__main__':
    unittest.main()
