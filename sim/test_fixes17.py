"""Fixes17: platform modifiers and plural quantity subjects; phrases mirrored in GoalTests.swift."""
import unittest

try:
    from sim import goal_classifier
    from sim.test_fixes8_goal import swift_table
except ImportError:
    import goal_classifier
    from test_fixes8_goal import swift_table


PLATFORM_NOUNS = [
    'Explain why the Windows build, refactor and test the parser',
    'Explain why the macOS build, refactor and test the parser',
    'Explain why the iOS build, refactor and test the parser',
    'Explain why the tvOS build, refactor and test the parser',
    'Explain why the watchOS build, refactor and test the parser',
    'Explain why the Jenkins build, refactor and test the parser',
    'Explain why the Kubernetes build, refactor and test the parser',
    'Explain why our nightly Windows build, refactor and test the parser',
    'Explain why the macOS nightly build, refactor and test the parser',
    'Explain why the WINDOWS build, refactor and test the parser',
    'Explain why the Windows 11 build, refactor and test the parser',
    'Explain why the iOS 18 build, refactor and test the parser',
    'Explain how the Jenkins test, fix and deploy the server',
    'Can you explain why the Kubernetes deploy, fix and test the parser?',
]
PLATFORM_EXPLANATIONS = [
    'Explain why the Windows build fails',
    'Explain why the macOS build fails',
    'Explain why the iOS build fails',
    'Explain why the tvOS build fails',
    'Explain why the watchOS build fails',
    'Explain why the Jenkins build fails',
    'Explain why the Kubernetes build fails',
    'Explain why the Windows build, write and update the summary',
    'Explain why the Windows developers build, test and deploy the server',
    'Explain why the developers using Windows build, test and deploy the server',
    'Explain why the Kubernetes maintainers build, test and deploy the server',
    'Explain why the Windows developers also build, test and deploy the server',
]
QUANTITY_SUBJECTS = [
    'Explain why these two build, test and deploy the server',
    'Explain why those three build, test and deploy the server',
    'Explain why both build, test and deploy the server',
    'Explain why all build, test and deploy the server',
    'Explain why many build, test and deploy the server',
    'Explain why several build, test and deploy the server',
    'Explain why the two build, test and deploy the server',
    'Explain why these both build, test and deploy the server',
    'Explain why these all build, test and deploy the server',
    'Explain why the many build, test and deploy the server',
    'Explain why those several build, test and deploy the server',
    'Explain why the few build, test and deploy the server',
    'Explain why these twelve build, test and deploy the server',
    'Explain why those twenty build, test and deploy the server',
    'Explain why these 2 build, test and deploy the server',
    'Explain why the 12 build, test and deploy the server',
    'Explain why the two often build, test and deploy the server',
    'Explain why the two also build, test and deploy the server',
    'Explain how those three test, build and deploy the server',
    'Can you explain why these two build, test and deploy the server?',
]
# Each subject still permits commands after the series has ended, including objectless series.
QUANTITY_COMMANDS = [
    'Explain why these two build, test and deploy the server, fix the parser',
    'Explain why those three build, test and deploy the server, fix the parser',
    'Explain why both build, test and deploy the server, fix the parser',
    'Explain why all build, test and deploy the server, fix the parser',
    'Explain why many build, test and deploy the server, fix the parser',
    'Explain why several build, test and deploy the server, fix the parser',
    'Explain why the two build, test and deploy the server, fix the parser',
    'Explain why these two build, test and deploy, refactor and lint the parser',
    'Explain why these 2 build, test and deploy, fix the parser',
    'Explain why these two build, test and deploy the server; fix the parser',
]
CODING = PLATFORM_NOUNS + QUANTITY_COMMANDS
GENERAL = PLATFORM_EXPLANATIONS + QUANTITY_SUBJECTS


class PlatformAndQuantityTests(unittest.TestCase):
    def assert_phrases(self, phrases, coding):
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertEqual(goal_classifier.looks_like_coding(phrase), coding)

    def test_platform_nouns_do_not_hide_commands(self):
        self.assert_phrases(PLATFORM_NOUNS, True)

    def test_platform_explanations_stay_general(self):
        self.assert_phrases(PLATFORM_EXPLANATIONS, False)

    def test_quantity_subjects_keep_the_series_inside_the_explanation(self):
        self.assert_phrases(QUANTITY_SUBJECTS, False)

    def test_commands_after_quantity_subject_series_still_win(self):
        self.assert_phrases(QUANTITY_COMMANDS, True)

    def test_every_phrase_has_the_same_expectation_in_swift(self):
        for name, phrases in (('coding', CODING), ('general', GENERAL)):
            table = swift_table(name)
            for phrase in phrases:
                with self.subTest(table=name, phrase=phrase):
                    self.assertIn(phrase, table)


if __name__ == '__main__':
    unittest.main()
