"""Fixes14: comma-separated verb series inside an explanation, shared with the native Swift goal table.

Pure classifier probes; compatible with the Mac's Python 3.9.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import unittest

try:
    from sim import goal_classifier
    from sim.test_fixes8_goal import swift_table
except ImportError:
    import goal_classifier
    from test_fixes8_goal import swift_table


# The fixes13 review phrases: a series of the explained clause's own verbs.
REVIEW_SERIES = [
    'Explain why we install, configure and run the server',
    'Can you explain why we install, configure and run the server?',
    'Explain why we build, test, and deploy the server',
]
SERIES = [
    'Explain why we build, test, deploy the server',
    'Explain why we lint, test, build and deploy the server',
    'Explain why we lint, test, build, and deploy the server',
    'Explain why we build, test or deploy the server',
    'Explain why we build, test and also deploy the server',
    'Explain why we refactor, test and deploy the parser',
    'Explain why we build, test, and then deploy the server',
    'Explain why we build, test and then deploy the server',
    'Explain why we install, configure, and then run the server',
    'Explain why we build, test, deploy, then release the server',
    'Explain why we build, test and deploy it',
    'Explain why we install and configure the server',
]
OTHER_WH_SERIES = [
    'Explain how we build, test and deploy the server',
    'Explain where we install, configure and run the server',
    'Describe when we build, test, and deploy the server',
    'Explain who can build, test and deploy the server',
    'Explain what we build, test and deploy on the server',
    'Explain what we should add, fix and remove in the package',
    'Explain which tests we write, run and fix in the parser',
    'Explain the reasons we install, configure and run the server',
    'Explain why the developers build, test and deploy the server',
    'Explain how to build, test and deploy the server',
    'Explain how to build, test, and then deploy the server',
]
POLITE_AND_QUESTION_SERIES = [
    'Could you explain why we build, test, and deploy the server?',
    'Would you describe how we install, configure and run the server?',
    'Can you explain why we lint, test, build and deploy the server?',
    'Why do we build, test and deploy the server?',
    'How do we install, configure, and run the server?',
]
SERIES_THEN_NON_CODE = [
    'Explain why we build, test, and deploy the server; also describe the parser',
    'Explain why we build, test and deploy the server, and write a summary',
]
# Without punctuation "also V" cannot be told from a noun subject's adverb ("why the developers also fix the parser"),
# so a run-on stays general; any punctuated form is coding (ALSO_COMMANDS).
ALSO_EXPLANATIONS = [
    'Explain why the parser crashes also fix it',
    'Explain why the developers also fix the parser',
]

SERIES_THEN_COMMANDS = [
    'Explain why we install, configure and run the server, and fix the parser',
    'Explain why we build, test, and deploy the server, then fix the parser',
    'Explain why we build, test and deploy the server, fix the parser',
    'Can you explain why we install, configure and run the server, and fix the parser?',
    'Explain why we build, test and deploy, then fix the parser',
    'Explain why we install, configure and run the server; fix the parser',
    'Explain why we install; configure and run the server',
    'Explain why we build, test, and deploy; then fix the server',
]
# Not a series: the clause's verb has an object, or only one verb follows the comma.
COMMA_COMMANDS = [
    'Explain why we add tests, and fix the parser',
    'Explain why we install, fix the parser, and run tests',
    'Explain why we add tests, and build, test and deploy the server',
    'Explain why we test, fix the parser',
    'Explain why we install, configure the server',
    'Explain why we build, and deploy the server',
    'Explain what we should add, then fix the parser',
    'Explain why we add, then fix the parser',
    # Fixes12 rule: "then" after the clause's verb opens a command when no comma series precedes it.
    'Explain why we build and then deploy the server',
]
IMPERATIVE_SERIES = [
    'Build, test and deploy the server',
    'Install, configure, and run the server',
    'Explain the result, then build, test and deploy the server',
]
ALSO_COMMANDS = [
    'Explain why the parser crashes, also fix it',
    'Explain why the parser crashes; also fix it',
]

GENERAL = REVIEW_SERIES + SERIES + OTHER_WH_SERIES + POLITE_AND_QUESTION_SERIES + SERIES_THEN_NON_CODE + ALSO_EXPLANATIONS
CODING = SERIES_THEN_COMMANDS + COMMA_COMMANDS + IMPERATIVE_SERIES + ALSO_COMMANDS


class VerbSeriesTests(unittest.TestCase):
    def assert_phrases(self, phrases, coding):
        for phrase in phrases:
            with self.subTest(phrase=phrase):
                self.assertEqual(goal_classifier.looks_like_coding(phrase), coding)

    def test_the_review_phrases_are_general(self):
        self.assert_phrases(REVIEW_SERIES, False)

    def test_series_of_the_explained_clauses_verbs_stay_general(self):
        self.assert_phrases(SERIES + OTHER_WH_SERIES + POLITE_AND_QUESTION_SERIES, False)

    def test_a_series_followed_by_a_non_code_command_stays_general(self):
        self.assert_phrases(SERIES_THEN_NON_CODE, False)

    def test_a_series_does_not_swallow_a_following_command(self):
        self.assert_phrases(SERIES_THEN_COMMANDS, True)

    def test_a_comma_after_an_object_or_before_one_verb_still_opens_a_command(self):
        self.assert_phrases(COMMA_COMMANDS, True)

    def test_imperative_series_outside_an_explanation_are_coding(self):
        self.assert_phrases(IMPERATIVE_SERIES, True)

    def test_also_needs_punctuation_to_open_a_command(self):
        self.assert_phrases(ALSO_EXPLANATIONS, False)
        self.assert_phrases(ALSO_COMMANDS, True)

    def test_the_series_connectors_are_read_from_the_swift_source(self):
        self.assertEqual(goal_classifier.SERIES_CONNECTORS, {',', 'and', 'or', 'then', 'plus', 'also'})

    def test_every_phrase_is_in_the_correct_shared_swift_table(self):
        for name, phrases in (('coding', CODING), ('general', GENERAL)):
            table = swift_table(name)
            for phrase in phrases:
                with self.subTest(table=name, phrase=phrase):
                    self.assertIn(phrase, table)


if __name__ == '__main__':
    unittest.main()
