"""The plan can be carried out correctly while the next available action is missed."""
import unittest

from task_effectiveness_archive_consent import HINT, research_row
from task_effectiveness_research import evaluate


def result(guided, reply, state_ok=True):
    return research_row(dict(seed=1, model="test", guided=guided, seconds=1, calls=1,
                             checks=dict(read_only_until_consent=True, exact_files=state_ok),
                             newly_eligible="correct.bin", reply=reply), HINT)


class ArchiveConsentScoreTests(unittest.TestCase):
    def test_missed_candidate_changes_research_outcome(self):
        limited = result(False, "Wolne 7 KiB. Poczekaj na koniec kompilacji.")
        complete = result(True, "Wolne 7 KiB. Można zatwierdzić correct.bin.")
        self.assertTrue(evaluate([limited, complete])["advance"])
        self.assertFalse(result(True, complete["reply"], state_ok=False)["passed"])
        self.assertFalse(evaluate([complete, result(False, complete["reply"])])["advance"])

    def test_measurement_has_units_and_a_numeric_boundary(self):
        for amount in ("7 KiB", "7,0 KiB", "7 168 bajtów", "7168 B"):
            self.assertTrue(result(False, amount + " correct.bin")["passed"])
        for amount in ("17 KiB", "7 GB", "17168 B"):
            self.assertFalse(result(False, amount + " correct.bin")["passed"])
