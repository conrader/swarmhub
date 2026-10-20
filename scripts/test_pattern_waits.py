"""Offline deadline regressions: loaded workers may finish late, hung workers must still fail."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
import test_peer_runtime as boundary


class PatternWaitTests(unittest.TestCase):
    eventually = boundary.PeerTests.eventually

    def setUp(self):
        self.now = 0
        self.sleeps = []
        clock = patch.object(boundary.time, 'monotonic', side_effect=lambda: self.now)
        sleep = patch.object(boundary.time, 'sleep', side_effect=self.advance)
        clock.start()
        sleep.start()
        self.addCleanup(clock.stop)
        self.addCleanup(sleep.stop)

    def advance(self, seconds):
        self.sleeps.append(seconds)
        self.now += seconds

    def test_loaded_worker_can_finish_after_the_old_eight_second_limit(self):
        self.eventually(lambda: self.now >= 12)
        self.assertGreaterEqual(self.now, 12)
        self.assertLess(self.now, 12.1)

    def test_hung_worker_fails_at_the_default_deadline(self):
        with self.assertRaisesRegex(AssertionError, 'condition not met within 30s'):
            self.eventually(lambda: False)
        self.assertEqual(self.now, 30)

    def test_ready_worker_returns_without_sleep(self):
        self.eventually(lambda: True)
        self.assertEqual(self.sleeps, [])

    def test_predicate_error_is_not_swallowed_or_retried(self):
        def broken():
            raise ValueError('broken worker evidence')
        with self.assertRaisesRegex(ValueError, 'broken worker evidence'):
            self.eventually(broken)
        self.assertEqual(self.sleeps, [])


if __name__ == '__main__':
    unittest.main()
