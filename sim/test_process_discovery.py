"""Positive cleanup oracles: a known, live child MUST be discoverable.

No test is skipped on a failed/empty ps listing. Children have only synthetic
environment values and are reaped by their Popen handle, independently of the
discovery helper under test.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
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
        # Executes /proc on Linux and the real ps -E/fallback path on macOS (where /bin/sleep's
        # environment is withheld under SIP, so it is found as a live descendant).
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
                self.assertEqual(calls, ["axww", "-axEww", "axeww"])

    def test_both_ps_commands_failing_or_empty_is_an_error(self):
        real_run = subprocess.run
        for result in (subprocess.CompletedProcess([], 1, "", "denied"),
                       subprocess.CompletedProcess([], 0, "", "")):
            for plain_works in (False, True):
                def run(argv, **kwargs):
                    return real_run(argv, **kwargs) if plain_works and argv[1] == "axww" else result

                with self.subTest(status=result.returncode, plain_works=plain_works), \
                        patch.object(boundary.Path, "exists", return_value=False), \
                        patch.object(boundary.subprocess, "run", side_effect=run), \
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


class DarwinWithheldEnvironmentTests(unittest.TestCase):
    """macOS-format listings, no /proc. With SIP, macOS ps -E shows no environment for restricted platform
    binaries such as /bin/sleep. Dashless axeww selects legacy BSD mode: e requests the environment too,
    with the same restrictions. Unrestricted processes retain their environment in either listing."""
    marker = "HOME=/private/tmp/discovery home x"

    def test_exec_between_ps_snapshots_cannot_report_clean(self):
        me, child = os.getpid(), 900001
        # The same live PID execs between plain ps and each environment snapshot.
        outputs = {"axww": f"{me} 1 S python3\n{child} {me} S /bin/sh -c sleep 60\n",
                   "-axEww": f"{me} python3\n{child} /bin/sleep 60\n",
                   "axeww": f"{me} python3\n{child} /bin/sleep 59\n"}

        def run(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, outputs[argv[1]], "")

        with patch.object(boundary.Path, "exists", return_value=False), \
                patch.object(boundary.subprocess, "run", side_effect=run):
            self.assertEqual(boundary.children_by_home(self.marker[5:]), [child])

    def listings(self):
        me = 899999  # not os.getpid(): pid 1 in the harness namespace would adopt the ppid-1 orphans
        rows = [(me, 1, "S", "/usr/bin/python3 -m unittest", "HOME=/Users/k PATH=/usr/bin:/bin"),
                (900001, me, "S", "/bin/sleep 60", None),                    # withheld child
                (900002, 900001, "S", "/bin/sh -c sleep 5", None),           # withheld grandchild
                (900003, 1, "S", "/bin/sleep 61", None),                     # withheld orphan
                (900004, me, "S", "/opt/node server.js", "HOME=/Users/other PATH=/bin"),
                (900005, me, "Z", "(sleep)", None),                          # zombie child
                (900006, me, "S+", "/Applications/Xcode.app/python3 -c pass", self.marker + " PATH=/bin"),
                (900007, 1, "S", "/opt/python3 worker.py", self.marker + " PATH=/bin")]  # marked orphan
        plain = "".join("%6d %6d %-4s %s\n" % (pid, ppid, stat, cmd) for pid, ppid, stat, cmd, _ in rows)
        env = "".join("%6d %s\n" % (pid, cmd + (" " + e if e else "")) for pid, _, _, cmd, e in rows)
        return plain, env

    def discover(self, plain_rc=0, env_rc=0):
        plain, env = self.listings()
        outputs = {"axww": (plain_rc, plain), "-axEww": (env_rc, env), "axeww": (0, env)}

        def run(argv, **kwargs):
            rc, out = outputs[argv[1]]
            return subprocess.CompletedProcess(argv, rc, out if rc == 0 else "", "")

        with patch.object(boundary.Path, "exists", return_value=False), \
                patch.object(boundary.subprocess, "run", side_effect=run):
            return boundary._children_by_home_ps(self.marker, 899999)

    def test_withheld_environment_descendants_are_found_with_marked_processes(self):
        self.assertEqual(sorted(self.discover()), [900001, 900002, 900004, 900006, 900007])

    def test_bsd_e_fallback_finds_marked_orphan_and_withheld_descendants(self):
        # Marked orphan proves fallback reads HOME; a withheld orphan and zombie remain excluded.
        self.assertEqual(sorted(self.discover(env_rc=1)), [900001, 900002, 900004, 900006, 900007])

    def test_unavailable_plain_listing_fails_closed(self):
        with self.assertRaisesRegex(RuntimeError, "process discovery failed"):
            self.discover(plain_rc=1)


if __name__ == "__main__":
    unittest.main()
