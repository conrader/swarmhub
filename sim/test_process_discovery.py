"""Positive cleanup oracles: a known, live child MUST be discoverable.

No test is skipped on a failed/empty ps listing. Children have only synthetic
environment values and are reaped by their Popen handle, independently of the
discovery helper under test.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import test_peer_runtime as boundary


class ProcessDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="discovery home ")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.child = subprocess.Popen(
            ["/bin/sleep", "60"], env={"HOME": str(self.home), "PATH": "/usr/bin:/bin"},
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.addCleanup(self.reap)

    def reap(self):
        if self.child.poll() is None:
            self.child.kill()
        self.child.wait(timeout=5)

    def assert_discovered(self):
        self.assertIsNone(self.child.poll(), "the discovery fixture must still be alive")
        found = boundary.children_by_home(self.home)
        self.assertIn(self.child.pid, found,
                      "PROCESS DISCOVERY BROKEN: known live child PID %s absent from %r; "
                      "empty discovery must never count as successful cleanup" % (self.child.pid, found))
        self.assertNotIn(os.getpid(), found)

    def test_native_discovery_finds_known_live_child(self):
        # Executes /proc on Linux and the real ps -E/fallback path on macOS.
        self.assert_discovered()

    def test_no_proc_discovery_finds_known_live_child(self):
        # Real ps calls even on Linux: -E is rejected there, so BSD e must work.
        with patch.object(boundary.Path, "exists", return_value=False):
            self.assert_discovered()

    def test_ps_fallback_finds_child_after_primary_failure_or_empty_result(self):
        real_run = subprocess.run
        for primary in (subprocess.CompletedProcess([], 1, "", "unsupported"),
                        subprocess.CompletedProcess([], 0, "", ""),
                        subprocess.CompletedProcess([], 0, "1 init\n", ""),
                        OSError("ps unavailable"), subprocess.TimeoutExpired("ps", 10)):
            calls = []

            def run(argv, **kwargs):
                calls.append(argv[1])
                if argv[1] == "-axEww":
                    if isinstance(primary, Exception):
                        raise primary
                    return primary
                return real_run(argv, **kwargs)

            with self.subTest(primary=type(primary).__name__), \
                    patch.object(boundary.Path, "exists", return_value=False), \
                    patch.object(boundary.subprocess, "run", side_effect=run):
                self.assert_discovered()
                self.assertEqual(calls, ["-axEww", "axeww"])

    def test_both_ps_commands_failing_or_empty_is_an_error(self):
        for result in (subprocess.CompletedProcess([], 1, "", "denied"),
                       subprocess.CompletedProcess([], 0, "", "")):
            with self.subTest(status=result.returncode), \
                    patch.object(boundary.Path, "exists", return_value=False), \
                    patch.object(boundary.subprocess, "run", return_value=result), \
                    self.assertRaisesRegex(RuntimeError, "process discovery failed"):
                boundary.children_by_home(self.home)

    def test_ps_parser_preserves_home_spaces_and_rejects_prefixes(self):
        marker = "HOME=/tmp/discovery home.[1]"
        listing = (f" 12 sleep 60 {marker} PATH=/usr/bin:/bin\n"
                   f" 13 sleep 60 {marker}\n"
                   f" 14 sleep 60 {marker}/other PATH=/bin\n"
                   f" 15 sleep 60 {marker} extra PATH=/bin\n"
                   f" 16 sleep 60 OTHER_{marker} PATH=/bin\n"
                   f" 17 sleep 60 {marker} PATH=/bin\n"
                   " PID COMMAND\n")
        self.assertEqual(boundary._pids_by_home_ps(listing, marker, 17), [12, 13])


if __name__ == "__main__":
    unittest.main()
