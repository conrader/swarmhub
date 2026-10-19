"""Fixes13: explanatory clause boundaries, shared with the native Swift goal table.

Pure classifier probes; compatible with the Mac's Python 3.9.
"""
import unittest

try:
    from sim import goal_classifier
    from sim.test_fixes8_goal import swift_table
except ImportError:
    import goal_classifier
    from test_fixes8_goal import swift_table


COMMA_COMMANDS = [
    'Explain why we add tests, and fix the parser',
    'Explain why we add tests, fix the parser',
    'Explain why we add tests, then fix the parser',
    'Explain why we add tests, and then fix the parser',
    'Explain why we add tests, also fix the parser',
    'Explain why we add tests, and also fix the parser',
    'Explain why we add tests, plus fix the parser',
    'Explain what we should add, then fix the parser',
    'Explain what we should add, and fix the parser',
    'Explain where we install Python packages, fix the parser',
    'Explain how we build the parser, and then fix it',
    'Explain when we run tests, also fix the parser',
    'Explain which tests we run, plus fix the parser',
    'Explain who can add tests, and fix the parser',
    'Explain why we add tests, refactor the parser',
    'Explain why we add tests, and fix it',
    'Explain why we also add tests, and fix the parser',
]
POLITE_COMMANDS = [
    'Can you explain why we add tests, and fix the parser?',
    'Could you explain what we should add, fix the parser?',
    'Would you describe where we install Python packages, also fix the parser?',
    'Will you explain when we run tests, plus fix the parser?',
    'Can you explain how to build the parser, and fix it?',
]
SENTENCE_COMMANDS = [
    'Explain why we add tests; fix the parser',
    'Explain why we add tests; and fix the parser',
    'Explain why we add tests; and then fix the parser',
    'Explain why we add tests; also fix the parser',
    'Explain why we add tests; plus fix the parser',
    'Explain why we add tests. Also fix the parser',
    'Explain why we add tests. Plus fix the parser',
    'Explain why we add tests! Then fix the parser',
    'Explain why we add tests? Fix the parser',
    'Explain why we add tests\nThen fix the parser',
]
COORDINATED_COMMANDS = [
    'Explain why we add tests and then fix the bug',
    'Explain why the parser crashes plus fix it',
    'Explain how to build the parser, plus fix it',
    'Explain why we add tests and also why the parser crashes and fix it',
    'Explain why we add tests and what went wrong and fix the parser',
    'Explain why we add tests, and why the parser crashes and fix it',
]
EXPLANATIONS = [
    'Explain why we add tests and remove Python packages',
    'Explain why we add tests and also remove Python packages',
    'Explain why we add tests plus remove Python packages',
    'Explain what we should add and remove in the package',
    'Explain where we install and remove Python packages',
    'Explain when we add tests and remove Python packages',
    'Explain how we build and test the parser',
    'Explain who can add tests and remove Python packages',
    'Explain which tests we add and remove',
    'Explain why we add tests, and why we remove Python packages',
    'Explain why we add tests, and how to remove Python packages',
    'Explain why we add tests, and they remove Python packages',
    'Explain why we add tests, and describe the parser',
    'Explain why we add tests, and then explain how to fix the parser',
    'Explain why we add tests; also describe the parser',
    'Explain why we add tests. Plus explain how to fix the parser',
    'Explain why we also add tests and remove Python packages',
    'Explain why we also add tests plus remove Python packages',
    # "also" is an adverb, not a clause boundary on its own.
    'Explain why the parser crashes also fix it',
    'Explain why they also fix the parser',
]
QUESTIONS = [
    'Why do we add tests, and fix the parser?',
    'What should we add, then remove in the Python package?',
    'Where do we install Python packages, and run tests?',
    'How do I add tests, then fix the build?',
    'When do we add tests, plus fix the parser?',
    'Who can add tests, and also fix the parser?',
    'Which tests should we add, and remove?',
    'Can you explain why we add tests, and how to fix the parser?',
]
INFINITIVES = [
    'Explain how to build and test the parser',
    'Describe how to add and remove a Python package',
    'Can you explain how to build and then test the parser?',
    'Explain how to build and also test the parser',
    'Explain how to build and then test the parser',
    'Explain how to build plus test the parser',
    'Explain how to also build and then test the parser',
    'Explain how to build plus then test the parser',
    'Explain how to install the package and configure the database',
]
NON_CODE_COMMANDS = [
    'Explain why we add tests, and write a summary',
    'Explain why we add tests, plus write a summary',
    'Explain why we add tests; also write a summary',
    'Explain why we add tests. Then build a presentation',
    'Can you explain why we add tests, and write a summary?',
]

CODING = COMMA_COMMANDS + POLITE_COMMANDS + SENTENCE_COMMANDS + COORDINATED_COMMANDS
GENERAL = EXPLANATIONS + QUESTIONS + INFINITIVES + NON_CODE_COMMANDS


class GoalClassifierTests(unittest.TestCase):
    def assert_phrases(self, phrases, coding):
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertEqual(goal_classifier.looks_like_coding(phrase), coding)

    def test_comma_ends_the_explained_clauses_coordination(self):
        self.assert_phrases(COMMA_COMMANDS, True)

    def test_polite_explanations_can_be_followed_by_commands(self):
        self.assert_phrases(POLITE_COMMANDS, True)

    def test_sentence_boundaries_end_the_explanation(self):
        self.assert_phrases(SENTENCE_COMMANDS, True)

    def test_conjunctions_and_fresh_explanatory_clauses(self):
        self.assert_phrases(COORDINATED_COMMANDS, True)

    def test_explanations_keep_their_own_coordinated_verbs(self):
        self.assert_phrases(EXPLANATIONS, False)

    def test_questions_remain_general(self):
        self.assert_phrases(QUESTIONS, False)

    def test_infinitive_coordination_remains_general(self):
        self.assert_phrases(INFINITIVES, False)

    def test_trailing_commands_still_need_code_objects(self):
        self.assert_phrases(NON_CODE_COMMANDS, False)

    def test_every_phrase_is_in_the_correct_shared_swift_table(self):
        for name, phrases in (('coding', CODING), ('general', GENERAL)):
            table = swift_table(name)
            for phrase in phrases:
                with self.subTest(table=name, phrase=phrase):
                    self.assertIn(phrase, table)


if __name__ == '__main__':
    unittest.main()
