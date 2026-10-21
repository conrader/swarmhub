"""Kill-tree guards: an empty, garbage, broadcast or foreign root signals nothing.

2026-10-21: every uid-1000 process on the ovh host got SIGTERM, then SIGKILL about a second later. code-job's
kill_tree() walked `ps -A` from its root, and a root of 0 or 1 is the parent of every process on the host. These
tests never send a real signal: code-job's functions run with `kill`, `sleep` and `ps` replaced by shell functions
that record or print, and the Python helpers run with os.kill/os.killpg patched. Each shell case first proves the
`kill` it would call is the recorder, so a broken override fails the test instead of signalling.
"""
import sim_isolation  # noqa: F401  Exits unless isolated (PID namespace / macOS signal guard); keep it the first import.
import contextlib
import io
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "Resources/Skills"
CODE_JOB = SCRIPTS / "swarmhub-coding/scripts/code-job"
sys.path.insert(0, str(SCRIPTS / "swarmhub-messages/scripts"))
sys.path.insert(0, str(SCRIPTS / "swarmhub-coding/scripts"))

import swarm_store  # noqa: E402
import verify_darwin  # noqa: E402

BAD_ROOTS = ("", "0", "1", "-1", "abc", "12 13", "1;2", " ", "007x", "99999999999999999999999")

# Recorded 2026-10-21 on the MacBook (Darwin 25.6.0): `LC_ALL=C ps -A -o pid= -o ppid= -o pgid= -o sess= -o lstart=`.
# BSD `sess` is a session pointer, printed 0 for every process; columns are right-aligned with trailing blanks.
DARWIN_PS_SAMPLE = (
    "    1     0     1      0 Fri Oct 16 06:11:44 2026    \n"
    "  333     1   333      0 Fri Oct 16 06:13:36 2026    \n"
    "  335     1   335      0 Fri Oct 16 06:13:36 2026    \n")


def functions(*names):
    text = CODE_JOB.read_text()
    out = []
    for name in names:
        found = re.search(r"^%s\(\) \{\n.*?^\}\n" % re.escape(name), text, re.M | re.S)
        assert found, name
        out.append(found.group(0))
    return "".join(out)


# A synthetic host: init and kthreadd, this shell's parent and grandparent (ancestors), this shell, a child with a
# grandchild (the job's own tree), and a foreign process. Synthetic PIDs exceed kernel limits so a busy PID
# namespace cannot recycle one as the real $$ or $PPID of the shell running the fixture.
HARNESS = r'''
set -u
: > "$LOG"
kill() { printf 'kill %s\n' "$*" >> "$LOG"; }
sleep() { :; }
listing() { printf '%s\n' "1 0" "2 0" "1900000000 1" "$PPID 1900000000" "$$ $PPID" "1500000001 $$" "1500000002 1500000001" "1500000003 1500000002" "1600000001 1" "1600000002 1600000001" "33 2"; }
ps() { listing | awk '{print $0, "700 800 Wed Oct 21 12:00:00 2026"}'; }
case $(command -V kill) in *function*) ;; *) echo "kill is not the recorder" >&2; exit 99 ;; esac
'''


def run_shell(body, shell="sh"):
    with tempfile.TemporaryDirectory() as d:
        logfile = Path(d) / "kills"
        script = HARNESS + functions("tree", "tree_pids", "signalable", "kill_tree") + body
        proc = subprocess.run([shell, "-c", script, shell], env=dict(os.environ, LOG=str(logfile)),
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=30)
        assert proc.returncode != 99, proc.stderr
        return proc, logfile.read_text() if logfile.exists() else ""


class CodeJobKillTreeTests(unittest.TestCase):
    def after_term(self, awk):
        # Capture the mocked listing before overriding ps. sleep changes the fixture, never a real process.
        return ('ps > "$LOG.before"\n'
                'awk %s "$LOG.before" > "$LOG.after"\n'
                'ps() { if [ -f "$LOG.next" ]; then cat "$LOG.next"; else cat "$LOG.before"; fi; }\n'
                'sleep() { cp "$LOG.after" "$LOG.next"; }\n'
                'kill_tree 1500000001; echo done=$?\n') % shlex.quote(awk)

    def test_bad_roots_signal_nothing_and_say_so(self):
        for root in BAD_ROOTS:
            with self.subTest(root=root):
                proc, kills = run_shell('kill_tree %s; echo done=$?' % shlex.quote(root))
                self.assertEqual(kills, "", proc.stderr)
                self.assertIn("done=0", proc.stdout)
                if root.strip():
                    self.assertIn("code-job: not signalling", proc.stderr)

    def test_this_shell_its_ancestors_and_foreign_processes_are_refused(self):
        for root in ('"$$"', '"$PPID"', "1900000000", "1600000001", "1600000002", "33", "2", "1500000002", "1424242424"):
            with self.subTest(root=root):
                proc, kills = run_shell("kill_tree %s; echo done=$?" % root)
                self.assertEqual(kills, "", proc.stderr)
                self.assertIn("done=0", proc.stdout)
                self.assertIn("code-job: not signalling", proc.stderr)

    def test_tree_lists_nothing_for_bad_roots_and_never_an_ancestor(self):
        for root in [shlex.quote(r) for r in BAD_ROOTS] + ['"$$"', '"$PPID"', "1900000000", "1600000001", "1500000002"]:
            with self.subTest(root=root):
                proc, _ = run_shell("tree %s" % root)
                self.assertEqual(set(proc.stdout.split()) - {"end"}, set(), proc.stdout)

    def test_own_child_tree_is_signalled_term_then_kill_and_nothing_else(self):
        proc, kills = run_shell('kill_tree 1500000001; echo done=$?')
        self.assertIn("done=0", proc.stdout)
        lines = kills.splitlines()
        self.assertEqual(lines[0].split(), ["kill", "-TERM", "1500000001", "1500000002", "1500000003"], kills)
        self.assertEqual(lines[1].split()[:2], ["kill", "-KILL"], kills)
        self.assertEqual(set(lines[1].split()[2:]), {"1500000001", "1500000002", "1500000003"}, kills)
        self.assertEqual(len(lines), 2, kills)

    def test_signalable_accepts_only_plain_pids_above_one_other_than_this_shell(self):
        proc, kills = run_shell(
            'for p in "" 0 1 -1 abc "1 2" "$$" 1500000001 1600000001; do signalable "$p" && echo "yes:$p" || echo "no:$p"; done')
        self.assertEqual(kills, "")
        got = proc.stdout.split()
        self.assertEqual([g for g in got if g.startswith("yes:")], ["yes:1500000001", "yes:1600000001"], got)

    def test_code_job_never_falls_back_to_the_bare_root(self):
        """The old kill_tree killed `${READ_OUTPUT:-$1}`: an empty listing still signalled the root itself."""
        self.assertNotIn("${READ_OUTPUT:-$1}", CODE_JOB.read_text())

    def test_delayed_kill_refuses_reused_pid_and_changed_boundaries(self):
        for change in ('$8="12:00:01"', '$2=1600000001', '$3=701'):
            with self.subTest(change=change):
                proc, kills = run_shell(self.after_term('{ if ($1 == 1500000003) { %s }; print }' % change))
                self.assertIn("done=0", proc.stdout, proc.stderr)
                self.assertIn("1500000003", kills.splitlines()[0])
                self.assertEqual(set(kills.splitlines()[1].split()[2:]), {"1500000001", "1500000002"}, kills)

    def test_delayed_kill_checks_sessions_only_on_linux(self):
        # Exercise both behaviours on every host: BSD sess is not a session ID.
        for platform in ("Linux", "Darwin", "FreeBSD", "OpenBSD", "NetBSD", "DragonFly"):
            with self.subTest(platform=platform):
                proc, kills = run_shell('uname() { echo %s; }\n' % platform + self.after_term(
                    '{ if ($1 == 1500000003) $4=801; print }'))
                self.assertIn("done=0", proc.stdout, proc.stderr)
                self.assertIn("1500000003", kills.splitlines()[0])
                expected = {"1500000001", "1500000002"}
                if platform != "Linux":
                    expected.add("1500000003")
                self.assertEqual(set(kills.splitlines()[1].split()[2:]), expected, kills)

    def test_missing_or_incomplete_identity_never_uses_cached_pids(self):
        for listing in ('{ if ($1 != 1500000003) print }', '{ print $1, $2 }', 'BEGIN { exit }'):
            with self.subTest(listing=listing):
                proc, kills = run_shell(self.after_term(listing))
                self.assertIn("done=0", proc.stdout, proc.stderr)
                self.assertNotIn("1500000003", "\n".join(kills.splitlines()[1:]))
                if listing != '{ if ($1 != 1500000003) print }':
                    self.assertEqual(len(kills.splitlines()), 1, kills)

    def test_original_orphans_are_killed_after_the_root_exits(self):
        proc, kills = run_shell(self.after_term('{ if ($1 == 1500000001) next; if ($1 == 1500000002) $2=1; print }'))
        self.assertIn("done=0", proc.stdout, proc.stderr)
        self.assertEqual(set(kills.splitlines()[1].split()[2:]), {"1500000002", "1500000003"}, kills)

    def test_reused_root_cannot_admit_new_foreign_descendants(self):
        proc, kills = run_shell(self.after_term(
            '{ if ($1 == 1500000001) $8="12:00:01"; print } END { print "1500000004 1500000001 700 800 Wed Oct 21 12:00:01 2026" }'))
        self.assertIn("done=0", proc.stdout, proc.stderr)
        self.assertEqual(set(kills.splitlines()[1].split()[2:]), {"1500000002", "1500000003"}, kills)

    def test_new_descendants_of_the_original_root_are_included(self):
        proc, kills = run_shell(self.after_term(
            '{ print } END { print "1500000004 1500000001 700 800 Wed Oct 21 12:00:01 2026" }'))
        self.assertIn("done=0", proc.stdout, proc.stderr)
        self.assertEqual(set(kills.splitlines()[1].split()[2:]), {"1500000001", "1500000002", "1500000003", "1500000004"}, kills)

    def test_identity_checks_also_work_under_bash_posix_mode(self):
        proc, kills = run_shell('set -o posix\n' + self.after_term('{ if ($1 == 1500000003) $8="12:00:01"; print }'), shell="bash")
        self.assertIn("done=0", proc.stdout, proc.stderr)
        self.assertEqual(set(kills.splitlines()[1].split()[2:]), {"1500000001", "1500000002"}, kills)

    def darwin_ps(self):
        # The fixture tree in the recorded Darwin layout (session 0 everywhere), plus two recorded foreign rows.
        sample = "".join(line + "\\n" for line in DARWIN_PS_SAMPLE.splitlines()[1:])
        return ('uname() { echo Darwin; }\n'
                'ps() { listing | awk \'{ printf "%%5s %%5s %%5s %%6s Wed Oct 21 12:00:00 2026    \\n", $1, $2, "700", "0" }\'; '
                'printf "%s"; }\n') % sample

    def test_darwin_session_pointer_column_parses_and_the_tree_is_signalled(self):
        proc, _ = run_shell(self.darwin_ps() + 'tree 1500000001')
        rows = [line.split() for line in proc.stdout.splitlines() if line != "end"]
        self.assertEqual({r[0] for r in rows}, {"1500000001", "1500000002", "1500000003"}, proc.stdout)
        self.assertEqual({len(r) for r in rows} | {r[3] for r in rows}, {9, "-"}, proc.stdout)
        proc, kills = run_shell(self.darwin_ps() + 'kill_tree 1500000001; echo done=$?')
        self.assertIn("done=0", proc.stdout, proc.stderr)
        lines = kills.splitlines()
        self.assertEqual(lines[0].split(), ["kill", "-TERM", "1500000001", "1500000002", "1500000003"], kills)
        self.assertEqual(set(lines[1].split()[2:]), {"1500000001", "1500000002", "1500000003"}, kills)

    def test_darwin_still_refuses_foreign_roots_and_a_changed_group(self):
        for root in ('"$$"', '"$PPID"', "1", "333", "1600000001"):
            with self.subTest(root=root):
                proc, kills = run_shell(self.darwin_ps() + "kill_tree %s" % root)
                self.assertEqual(kills, "", proc.stderr)
        proc, kills = run_shell(self.darwin_ps() + self.after_term('{ if ($1 == 1500000003) $3=701; print }'))
        self.assertEqual(set(kills.splitlines()[1].split()[2:]), {"1500000001", "1500000002"}, kills)

    def test_orphans_adopted_by_an_ancestor_subreaper_are_killed(self):
        # $PPID and 1900000000 stand in for a systemd --user subreaper above this shell.
        for adopter in ('ENVIRON["PP"]', '1900000000'):
            with self.subTest(adopter=adopter):
                proc, kills = run_shell('PP=$PPID; export PP\n' + self.after_term(
                    '{ if ($1 == 1500000001) next; if ($1 == 1500000002) $2=%s; print }' % adopter))
                self.assertIn("done=0", proc.stdout, proc.stderr)
                self.assertEqual(set(kills.splitlines()[1].split()[2:]), {"1500000002", "1500000003"}, kills)
                self.assertNotIn("leaving pid", proc.stderr)

    def test_orphans_adopted_by_a_foreign_subreaper_are_left_and_named(self):
        proc, kills = run_shell(self.after_term(
            '{ if ($1 == 1500000001) next; if ($1 == 1500000002) $2=1600000001; print }'))
        self.assertIn("done=0", proc.stdout, proc.stderr)
        self.assertNotIn("1500000002", "\n".join(kills.splitlines()[1:]), kills)
        self.assertIn("code-job: leaving pid 1500000002: adopted by 1600000001", proc.stderr)


def process_listing(rows):
    return "".join(f"{pid} {parent} {group} {session} Wed Oct 21 12:00:00 2026\n"
                   for pid, parent, group, session in rows)


class SwarmStoreTerminateTests(unittest.TestCase):
    LISTING = process_listing([
        (1, 0, 1, 1), (3800, 1, 700, 800), (3900, 3800, 700, 800), (4000, 3900, 700, 800),
        (5001, 4000, 700, 800), (5002, 5001, 700, 800),  # child tree
        (5101, 3900, 700, 800), (5102, 5101, 700, 800),  # bot-msg STREAM_PID sibling tree
        (6001, 1, 6001, 6001), (6002, 6001, 6001, 6001),  # foreign tree
        (6101, 3800, 700, 800), (6201, 3900, 6201, 6201)])

    def run_terminate(self, pid, after=None, before=None, parent=3900):
        listing = self.LISTING if before is None else before
        snapshots = iter([listing, listing if after is None else after])

        def ps(command, **kwargs):
            snapshot = next(snapshots)
            # Also exercise the old two-column implementation when demonstrating the regression.
            if "lstart=" in command:
                return snapshot
            return "\n".join(" ".join(row.split()[:2]) for row in snapshot.splitlines())

        with mock.patch.object(swarm_store.subprocess, "check_output", side_effect=ps), \
             mock.patch.object(swarm_store.os, "getpid", return_value=4000), \
             mock.patch.object(swarm_store.os, "getppid", return_value=parent), \
             mock.patch.object(swarm_store.os, "kill") as kill, \
             mock.patch.object(swarm_store, "process_alive", return_value=True), \
             mock.patch.object(swarm_store.time, "sleep"):
            swarm_store.terminate(pid)
        return kill.call_args_list

    def test_bad_roots_signal_nothing(self):
        for pid in (None, "", "abc", 0, 1, -1, -5001, "0", "1", "5001", 5001.0, True, 4000, 3900, 3800):
            with self.subTest(pid=pid):
                self.assertEqual(self.run_terminate(pid), [])

    def test_child_and_bot_msg_sibling_trees_are_signalled(self):
        for pid, tree in ((5001, {5001, 5002}), (5101, {5101, 5102})):
            with self.subTest(pid=pid):
                calls = self.run_terminate(pid)
                self.assertEqual({c.args[0] for c in calls}, tree)
                self.assertEqual({c.args[1] for c in calls}, {signal.SIGTERM, signal.SIGKILL})

    def test_foreign_cousin_and_different_session_siblings_are_refused(self):
        for pid in (6001, 6002, 6101, 6201, 9999):
            with self.subTest(pid=pid):
                self.assertEqual(self.run_terminate(pid), [])

    def test_reused_pid_and_changed_boundaries_are_not_killed(self):
        original = "5002 5001 700 800 Wed Oct 21 12:00:00 2026"
        for changed in ("5002 5001 700 800 Wed Oct 21 12:00:01 2026",
                        "5002 6001 700 800 Wed Oct 21 12:00:00 2026",
                        "5002 5001 701 800 Wed Oct 21 12:00:00 2026",
                        ""):
            with self.subTest(changed=changed):
                calls = self.run_terminate(5001, after=self.LISTING.replace(original, changed))
                self.assertIn(mock.call(5002, signal.SIGTERM), calls)
                self.assertNotIn(mock.call(5002, signal.SIGKILL), calls)

    def test_delayed_kill_checks_sessions_only_on_linux(self):
        after = self.LISTING.replace("5002 5001 700 800", "5002 5001 700 801")
        for platform in ("linux", "darwin", "freebsd14", "openbsd7", "netbsd10"):
            with self.subTest(platform=platform), mock.patch.object(swarm_store.sys, "platform", platform):
                calls = self.run_terminate(5001, after=after)
                self.assertIn(mock.call(5002, signal.SIGTERM), calls)
                self.assertEqual(mock.call(5002, signal.SIGKILL) in calls, platform != "linux")

    def test_same_orphan_is_still_killed(self):
        calls = self.run_terminate(5001, after=self.LISTING.replace("5002 5001", "5002 1"))
        self.assertIn(mock.call(5002, signal.SIGKILL), calls)

    def test_unreadable_identity_fails_closed(self):
        self.assertEqual(self.run_terminate(5001, before="5001 4000\n"), [])
        calls = self.run_terminate(5001, after="")
        self.assertEqual({c.args[1] for c in calls}, {signal.SIGTERM})

    def test_siblings_of_an_adopted_process_are_refused(self):
        listing = self.LISTING.replace("4000 3900", "4000 1").replace("5101 3900", "5101 1")
        self.assertEqual(self.run_terminate(5101, before=listing, parent=1), [])

    def test_orphans_adopted_by_an_ancestor_subreaper_are_killed(self):
        for adopter in (1, 3800, 3900):
            with self.subTest(adopter=adopter):
                calls = self.run_terminate(5001, after=self.LISTING.replace("5002 5001", "5002 %d" % adopter))
                self.assertIn(mock.call(5002, signal.SIGKILL), calls)

    def test_orphans_adopted_by_a_foreign_subreaper_are_left_and_named(self):
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            calls = self.run_terminate(5001, after=self.LISTING.replace("5002 5001", "5002 6001"))
        self.assertIn(mock.call(5002, signal.SIGTERM), calls)
        self.assertNotIn(mock.call(5002, signal.SIGKILL), calls)
        self.assertIn("swarm_store: leaving pid 5002: adopted by 6001", err.getvalue())

    def test_darwin_session_pointer_is_recorded_as_unknown(self):
        with mock.patch.object(swarm_store.subprocess, "check_output", return_value=DARWIN_PS_SAMPLE):
            with mock.patch.object(swarm_store.sys, "platform", "darwin"):
                darwin = swarm_store.process_snapshot()
            with mock.patch.object(swarm_store.sys, "platform", "linux"):
                linux = swarm_store.process_snapshot()
        self.assertEqual(darwin, {1: (0, 1, "-", "Fri Oct 16 06:11:44 2026"),
                                  333: (1, 333, "-", "Fri Oct 16 06:13:36 2026"),
                                  335: (1, 335, "-", "Fri Oct 16 06:13:36 2026")})
        self.assertEqual(linux[333], (1, 333, "0", "Fri Oct 16 06:13:36 2026"))

    def test_darwin_child_and_sibling_trees_are_signalled_and_foreign_refused(self):
        darwin = "".join("%5s %5s %5s %6s %s    \n" % (*row.split()[:3], "0", " ".join(row.split()[4:]))
                         for row in self.LISTING.splitlines())
        with mock.patch.object(swarm_store.sys, "platform", "darwin"):
            for pid, tree in ((5001, {5001, 5002}), (5101, {5101, 5102}), (6001, set()), (6201, set())):
                with self.subTest(pid=pid):
                    calls = self.run_terminate(pid, before=darwin)
                    self.assertEqual({c.args[0] for c in calls}, tree)


class VerifierGuardTests(unittest.TestCase):
    def test_darwin_signal_group_refuses_broadcast_groups(self):
        for pgid in (0, 1, -1, os.getpgrp()):
            with self.subTest(pgid=pgid):
                killpg = mock.Mock()
                self.assertFalse(verify_darwin.signal_group(pgid, signal.SIGKILL, killpg))
                killpg.assert_not_called()

    @unittest.skipUnless(sys.platform == "linux", "the seccomp supervisor exists only on Linux")
    def test_linux_supervisor_refuses_a_root_of_one_or_less(self):
        import verify_signals
        for root in (0, 1, -1, os.getpid()):
            with self.subTest(root=root), self.assertRaises(ValueError):
                verify_signals.Supervisor(None, root, {})

    @unittest.skipUnless(sys.platform == "linux", "Linux only")
    def test_linux_supervisor_refuses_ancestor_foreign_and_missing_roots(self):
        import verify_signals
        parents = {900: 1, 3900: 900, 4000: 3900, 5001: 4000, 5002: 5001, 6001: 3900}
        with mock.patch.object(verify_signals.os, "getpid", return_value=4000), \
             mock.patch.object(verify_signals, "status_field", side_effect=lambda pid, key: parents.get(pid)):
            for root in (900, 3900, 6001, 5002, 9999):
                with self.subTest(root=root), self.assertRaises(ValueError):
                    verify_signals.Supervisor(None, root, {})
            supervisor = verify_signals.Supervisor(None, 5001, {})
            self.assertTrue(supervisor.descendant(5002))
            self.assertFalse(supervisor.descendant(6001))


class ManagedCleanupGuardTests(unittest.TestCase):
    def test_real_home_is_refused_even_when_home_environment_was_replaced(self):
        import live_managed
        with tempfile.TemporaryDirectory(prefix="QA-LIVE9-") as directory:
            suite = live_managed.ManagedSuite.__new__(live_managed.ManagedSuite)
            suite.temp, suite.home = Path(directory), Path(directory) / "QA-home"
            with mock.patch.dict(os.environ, {"HOME": str(suite.home)}), \
                 mock.patch.object(live_managed.pwd, "getpwuid", return_value=mock.Mock(pw_dir=str(suite.home))), \
                 mock.patch.object(live_managed, "children_by_home") as discover, \
                 mock.patch.object(live_managed.os, "kill") as kill:
                with self.assertRaises(ValueError):
                    suite.stop_local_processes()
                discover.assert_not_called()
                kill.assert_not_called()

    def test_only_a_system_temp_qa_home_can_be_swept(self):
        sys.path.insert(0, str(ROOT / "sim"))
        import live_managed
        with tempfile.TemporaryDirectory(prefix="QA-LIVE9-") as directory:
            temp = Path(directory)
            (temp / "QA-home").mkdir()
            (temp / "alias").symlink_to(Path.home(), target_is_directory=True)
            suite = live_managed.ManagedSuite.__new__(live_managed.ManagedSuite)
            suite.temp = temp
            for home in (Path.home(), Path("/"), temp, temp / "home", temp / "alias"):
                suite.home = home
                with self.subTest(home=home), \
                     mock.patch.object(live_managed, "children_by_home") as discover, \
                     mock.patch.object(live_managed.os, "kill") as kill:
                    with self.assertRaises(ValueError):
                        suite.stop_local_processes()
                    discover.assert_not_called()
                    kill.assert_not_called()

    def test_symlinked_qa_home_and_non_temp_qa_directory_are_refused(self):
        import live_managed
        with tempfile.TemporaryDirectory(prefix="QA-LIVE9-") as directory:
            temp = Path(directory)
            (temp / "QA-home").symlink_to(Path.home(), target_is_directory=True)
            suite = live_managed.ManagedSuite.__new__(live_managed.ManagedSuite)
            suite.temp, suite.home = temp, temp / "QA-home"
            with mock.patch.object(live_managed.os, "kill") as kill:
                with self.assertRaises(ValueError):
                    suite.stop_local_processes()
                suite.temp = temp / "nested" / "QA-LIVE9-fake"
                suite.home = suite.temp / "QA-home"
                with self.assertRaises(ValueError):
                    suite.stop_local_processes()
                kill.assert_not_called()

    def test_valid_temporary_qa_home_still_gets_cleaned(self):
        import live_managed
        with tempfile.TemporaryDirectory(prefix="QA-LIVE9-") as directory:
            suite = live_managed.ManagedSuite.__new__(live_managed.ManagedSuite)
            suite.temp, suite.home = Path(directory), Path(directory) / "QA-home"
            with mock.patch.object(live_managed, "children_by_home", return_value=[5001]), \
                 mock.patch.object(live_managed.subprocess, "check_output", return_value="5001 1\n5002 5001\n"), \
                 mock.patch.object(live_managed.time, "sleep"), \
                 mock.patch.object(live_managed.os, "kill") as kill:
                suite.stop_local_processes()
            self.assertEqual(set(c.args for c in kill.call_args_list), {(pid, sig) for pid in (5001, 5002) for sig in (15, 9)})


class TestsNeverBroadcast(unittest.TestCase):
    def test_no_sim_test_sends_a_real_signal_to_minus_one(self):
        """fixes7 asked the sandbox to deny a SIGTERM to pid -1; had it not, every process of the user died."""
        pattern = re.compile(r"os\.kill\(\s*-1\s*,(?!\s*0\s*\))")
        offenders = [p.name for p in (ROOT / "sim").glob("*.py") if pattern.search(p.read_text())]
        self.assertEqual(offenders, [])


if __name__ == "__main__":
    unittest.main()
