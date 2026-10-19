"""Fixes8 item 2: the /goal classifier lets a clear coding request anywhere in the text win.

No Swift toolchain runs here, so the Swift test table (Tests/AgentAppTests/GoalTests.swift,
plainGoalsAreClassifiedByTheRequestedAction) is read from the source and run through the Python port
(sim/goal_classifier.py), whose word lists are read from ChatAutomation.swift itself. Pure text, no processes.
"""
from pathlib import Path
import re
import unittest

try:
    from sim import goal_classifier
except ImportError:  # `python3 -m unittest discover` from inside sim/
    import goal_classifier

ROOT = Path(__file__).resolve().parents[1]
GOAL_TESTS = ROOT / 'Tests/AgentAppTests/GoalTests.swift'

# The 24 phrases of fixes7, independent of the Swift file: they must keep their classification.
FIXES7_CODING = ["fix the failing build", "Refactor the parser", "open a pull request for it",
                 "Add pagination to the users API", "Upgrade React to 19", "Write a Python scraper",
                 "Can you fix the typo in the README", "Bump the Node version in CI", "Make the tests pass",
                 "Port the CLI to TypeScript", "the login bug", "Add retry logic to the scraper and explain the approach"]
FIXES7_GENERAL = ["Explain the result", "write the changelog", "summarize the meeting", "Explain this function",
                  "Describe how the users API works", "Summarize the test results", "What does this script do?",
                  "Write a blog post about Python", "Build a presentation for the board", "Draft the release notes",
                  "Review the pull request and list concerns", "How do I fix the build?"]


def swift_table(name):
    """The string array `let <name> = [...]` of plainGoalsAreClassifiedByTheRequestedAction, comments stripped."""
    source = GOAL_TESTS.read_text()
    body = source[source.index('func plainGoalsAreClassifiedByTheRequestedAction'):]
    block = re.search(r'let %s = \[(.*?)\]\n' % name, body, re.S).group(1)
    return re.findall(r'"([^"]*)"', re.sub(r'//[^\n]*', '', block))


class GoalClassifierPortTests(unittest.TestCase):
    def test_the_review_phrase_is_coding_and_was_general_under_the_fixes7_rule(self):
        phrase = 'The tests are failing; fix the bug'
        self.assertFalse(goal_classifier.first_verb_requests_code(phrase))  # "are" decided before "fix".
        self.assertTrue(goal_classifier.looks_like_coding(phrase))

    def test_the_swift_table_is_classified_as_expected(self):
        coding, general = swift_table('coding'), swift_table('general')
        self.assertEqual((len(coding), len(general)), (27, 17))
        for phrase in coding:
            with self.subTest(coding=phrase):
                self.assertTrue(goal_classifier.looks_like_coding(phrase))
        for phrase in general:
            with self.subTest(general=phrase):
                self.assertFalse(goal_classifier.looks_like_coding(phrase))

    def test_all_24_fixes7_cases_keep_their_classification_and_stay_in_the_swift_table(self):
        coding, general = swift_table('coding'), swift_table('general')
        for phrase in FIXES7_CODING:
            self.assertTrue(goal_classifier.looks_like_coding(phrase), phrase)
            self.assertIn(phrase, coding)
        for phrase in FIXES7_GENERAL:
            self.assertFalse(goal_classifier.looks_like_coding(phrase), phrase)
            self.assertIn(phrase, general)

    def test_questions_and_non_code_imperatives_after_a_status_clause_stay_general(self):
        for phrase in ('How do I add tests, then fix the build?', 'Why are the tests failing, and how to fix them?',
                       'The meeting notes are messy; clean them up', 'The build is broken. Please write a summary',
                       'The tests are failing; explain why', 'Write a blog post about Python. Then fix it.'):
            self.assertFalse(goal_classifier.looks_like_coding(phrase), phrase)

    def test_sentence_boundaries_ignore_dots_inside_words(self):
        self.assertEqual(goal_classifier.sentence_words('Update README.md. Then fix it, please'),
                         [['update', 'readme', 'md'], ['then', 'fix', 'it', ',', 'please']])

    def test_the_port_reads_every_word_list_from_the_swift_source(self):
        lists = goal_classifier.swift_lists()
        self.assertEqual(set(lists), set(goal_classifier.LISTS))
        for name, words in lists.items():
            self.assertTrue(words, name)
        source = goal_classifier.SWIFT.read_text()
        self.assertIn('requestsCodeInAClause(text) || firstVerbRequestsCode(text)', source)


if __name__ == '__main__':
    unittest.main()
