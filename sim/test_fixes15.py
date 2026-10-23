"""Fixes15: noun homographs and completed explanatory series must not hide commands.

The same phrases live in GoalClassificationTests.swift. Compatible with Python 3.9.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import unittest

try:
    from sim import goal_classifier
    from sim.test_fixes8_goal import swift_table
except ImportError:
    import goal_classifier
    from test_fixes8_goal import swift_table


NOUN_OBJECTS = [
    'Explain the build, refactor and test the parser',
    'Explain the test, refactor and test the parser',
    'Explain the run, refactor and test the parser',
    'Explain the fix, refactor and test the parser',
    'Explain the deploy, refactor and test the parser',
    'Explain a clean build, refactor and test the parser',
    'Explain the unit test, refactor and deploy the server',
    'Explain our nightly run, refactor and test the parser',
    'Explain this quick fix, refactor and test the parser',
    'Explain their latest deploy, refactor and test the parser',
    'Can you explain the build, refactor and test the parser?',
    'Could you describe the unit test, refactor and deploy the server?',
]
CLAUSE_OBJECTS = [
    'Explain why we run the build, refactor and test the parser',
    'Explain why we run the unit test, refactor and deploy the server',
    'Explain why we test the run, refactor and test the parser',
    'Explain why we deploy the fix, refactor and test the parser',
    'Explain why we test the deploy, refactor and test the parser',
    'Explain why we fix the build, refactor and deploy the server',
    'Explain why the build, refactor and test the parser',
    'Explain why the unit test, refactor and deploy the server',
    'Explain how to run the build, refactor and test the parser',
]
CHAINED_SERIES = [
    'Explain why we install, configure and run, fix and test the parser',
    'Explain why we build, test, and deploy, refactor and lint the parser',
    'Explain why we build, test and deploy, refactor then lint the parser',
    'Explain why we build, test or deploy, fix and test the parser',
    'Explain why we build, test plus deploy, fix and test the parser',
    'Explain why we build, test and also deploy, fix and test the parser',
    'Explain why we build, test and then deploy, fix and test the parser',
    'Explain why we lint, test, build and deploy, fix, refactor and test the parser',
    'Explain why the developers build, test and deploy, fix and test the parser',
    'Explain the reasons we install, configure and run, fix and test the parser',
    'Can you explain why we install, configure and run, fix and test the parser?',
    'Explain why we install, configure and run, and fix and test the parser',
    'Explain why we install, configure and run, then fix and test the parser',
    'Explain why we install, configure and run; fix and test the parser',
    'Explain why we install, configure and run the server, fix and test the parser',
    'Explain how to build, test and deploy, refactor and lint the parser',
    'Explain how to build, test and deploy, fix the parser',
]
CODING_CONTROLS = [
    'Explain why we add tests, and fix the parser',
    'Explain the build, fix and test the parser',
    'Explain the deploy, configure and run the server',
    'Explain the build, fix the parser',
    'Build, test and deploy the server',
]
EXPLANATIONS = [
    'Explain why we install, configure and run the server',
    'Can you explain why we install, configure and run the server?',
    'Explain why we build, test, and deploy the server',
    'Explain why the developers build, test and deploy the server',
    'Explain why the developers test, build and deploy the server',
    'Explain why the developers run, test and deploy the server',
    'Explain why the developers fix, test and deploy the server',
    'Explain why the developers deploy, configure and run the server',
    'Explain why we also install, configure and run the server',
    'Explain what we should add, fix and remove in the package',
    'Explain how to build, test and deploy the server',
    'Explain how to also build, test and deploy the server',
    'Explain the reasons we install, configure and run the server',
    'Explain why we build, test and deploy, and why we install, configure and run the server',
]
GENERAL_CONTROLS = [
    'Explain the build',
    'Explain the test',
    'Explain the run',
    'Explain the fix',
    'Explain the deploy',
    'Explain the build, write and update the summary',
    'Explain why we install, configure and run, write and update the summary',
    'Why do we install, configure and run, fix and test the parser?',
]

CODING = NOUN_OBJECTS + CLAUSE_OBJECTS + CHAINED_SERIES + CODING_CONTROLS
GENERAL = EXPLANATIONS + GENERAL_CONTROLS


class SeriesBoundaryTests(unittest.TestCase):
    def assert_phrases(self, phrases, coding):
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertEqual(goal_classifier.looks_like_coding(phrase), coding)

    def test_noun_homographs_do_not_hide_commands(self):
        self.assert_phrases(NOUN_OBJECTS, True)

    def test_objects_inside_explanations_do_not_start_verb_series(self):
        self.assert_phrases(CLAUSE_OBJECTS, True)

    def test_completed_series_do_not_absorb_another_command_list(self):
        self.assert_phrases(CHAINED_SERIES, True)

    def test_commands_still_require_coding_evidence(self):
        self.assert_phrases(CODING_CONTROLS, True)

    def test_actual_explanatory_verbs_stay_general(self):
        self.assert_phrases(EXPLANATIONS, False)

    def test_nouns_questions_and_non_code_lists_stay_general(self):
        self.assert_phrases(GENERAL_CONTROLS, False)

    def test_every_phrase_has_the_same_expectation_in_swift(self):
        for name, phrases in (('coding', CODING), ('general', GENERAL)):
            table = swift_table(name)
            for phrase in phrases:
                with self.subTest(table=name, phrase=phrase):
                    self.assertIn(phrase, table)


if __name__ == '__main__':
    unittest.main()
