"""Stub smoke regressions: cleanup, timeouts, reports and symlinked TMPDIRs.

No Codex, provider or network. Darwin Library regressions live in test_macsmoke_library.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    from sim.macsmoke_library import ROOT, os_library_problems
except ImportError:
    from macsmoke_library import ROOT, os_library_problems

SCRIPT = ROOT / "sim/mac-codex-tmp-smoke.sh"
# Keep HOME and TMPDIR siblings outside system /tmp, including a Mac checkout in /tmp/qm6.
FIXTURE_BASE = ROOT if Path('/tmp').resolve() not in ROOT.parents else Path.home()
DARWIN = sys.platform == "darwin"


def temp_entries():
    return {p.name for p in Path("/tmp").iterdir() if re.match(r"(code-job|macsmoke1)", p.name)}


@unittest.skipIf(os.geteuid() == 0, "the stub denies writes with permission bits, which root ignores")
@unittest.skipUnless(shutil.which("python3"), "needs python3")
class SmokeStubTests(unittest.TestCase):
    def setUp(self):
        self.shm = Path(tempfile.mkdtemp(prefix="msk2.", dir=FIXTURE_BASE))
        self.addCleanup(shutil.rmtree, self.shm, True)
        self.home = Path(tempfile.mkdtemp(prefix="msk2-home.", dir=FIXTURE_BASE))
        self.addCleanup(shutil.rmtree, self.home, True)
        self.before = temp_entries()

    def run_smoke(self, tmpdir, *args, log="-", script=SCRIPT, path=None):
        tmpdir.mkdir(parents=True, exist_ok=True)
        env = {k: v for k, v in os.environ.items() if k not in ("ANTHROPIC_API_KEY", "SMOKE_TEED")}
        env.update(TMPDIR=str(tmpdir), HOME=str(self.home), SMOKE_LOG=str(log),
                   PYTHONDONTWRITEBYTECODE="1", PYTHONPYCACHEPREFIX=str(self.shm / "pycache"))
        if path:
            env["PATH"] = f"{path}{os.pathsep}{env.get('PATH', os.defpath)}"
        proc = subprocess.run(["sh", str(script), "--timeout", "3", *args], cwd=self.shm, env=env,
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
        out = proc.stdout + proc.stderr
        last = [line for line in out.splitlines() if line.startswith("smoke: ")]
        self.assertTrue(last, out[-3000:])
        self.assertEqual(list(tmpdir.iterdir()), [], "disposable dirs left in $TMPDIR")
        left = sorted(p.name for p in self.home.iterdir())
        if DARWIN and "Library" in left:
            paths = {str(p) for p in (self.shm, self.home, tmpdir)}
            paths |= {os.path.realpath(p) for p in paths}
            markers = [os.fsencode(p) for p in paths] + [b"macsmoke", b"code-job"]
            problems = os_library_problems(self.home / "Library", markers, (self.shm, self.home, tmpdir))
            self.assertEqual(problems, [], "smoke files in HOME/Library")
            left.remove("Library")
        self.assertEqual(left, [], "outside dir left in HOME")
        self.assertEqual(temp_entries() - self.before, set(), "disposable dirs left in /tmp")
        self.assertIn("cleanup: all disposable directories removed", out)
        self.assertNotIn("REFUSED", out)
        return proc.returncode, last[-1], out

    def test_space_in_tmpdir_cleans_exactly_and_default_run_covers_cj_outside(self):
        decoy = self.shm / "td"  # what an unquoted split of "<shm>/td x/..." would hit
        decoy.mkdir()
        (decoy / "canary").write_text("keep\n")
        rc, last, out = self.run_smoke(self.shm / "td x", "--stub")
        self.assertEqual((decoy / "canary").read_text(), "keep\n")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=PASS "), last)
        self.assertIn("cj-outside", last.split(" enforced=")[1].split(" ")[0])
        self.assertIn("expect fallback=no", out)
        self.assertNotIn("skipped=", last)

    def test_timeout_with_probe_files_present_is_never_pass(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "timeout")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=INCONCLUSIVE reason=first-run:timeout "), last)
        self.assertIn("positive control: written; completion marker: written; exit: 124 -> inconclusive (timeout)", out)

    def test_probe_without_completion_marker_is_inconclusive(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "incomplete")
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=INCONCLUSIVE "), last)
        for run in ("on", "off", "slash", "tmpdir", "cj-home", "cj-sibling", "cj-outside"):
            self.assertIn(f"{run}:probe-incomplete", last)
        self.assertNotIn("enforced=cj", last)

    def test_unexpected_write_on_timed_out_first_run_fails_through_the_log_tee(self):
        log = self.shm / "smoke.log"
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "leaky-timeout", log=log)
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=FAIL reason=first-run:timeout "), last)
        self.assertIn("unexpected=on:tmp,on:tmpdir", last)
        self.assertIn(last, log.read_text())

    def test_leaky_full_run_fails(self):
        rc, last, out = self.run_smoke(self.shm / "td", "--stub", "leaky")
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith("smoke: result=FAIL "), last)
        for loc in ("on:tmp", "on:tmpdir", "cj-home:snapshot", "cj-sibling:snapshot"):
            self.assertIn(loc, last)

    def test_stderr_only_probe_reproduces_exit_65_without_shim_status(self):
        # A real fresh report and completed probe can still hit 65: code-job also requires stdout.
        # Revert only the harness status line, leaving all production launcher checks intact.
        with tempfile.NamedTemporaryFile(mode='w', prefix='macsmoke3-', suffix='.sh',
                                         dir=SCRIPT.parent) as old:
            status = "printf 'smoke shim: codex exited %s\\n' \"$rc\"\n"
            source = SCRIPT.read_text()
            self.assertEqual(source.count(status), 1)
            old.write(source.replace(status, ''))
            old.flush()
            rc, last, out = self.run_smoke(self.shm / 'td', '--stub', 'stderr-only', script=old.name)
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=INCONCLUSIVE '), last)
        for run in ('cj-home', 'cj-sibling', 'cj-outside'):
            self.assertIn(f'{run}:code-job-exit-65', last)
        self.assertEqual(out.count('  | report-before=missing-or-empty\n'), 3)
        self.assertEqual(out.count('  | report-valid=true\n'), 3)
        self.assertEqual(out.count('  | codex-stdout-bytes=0\n'), 3)
        self.assertEqual(out.count('completion marker: written; exit: 65'), 3)

    def test_stderr_only_completed_probe_passes_without_model_report_rewrite(self):
        # Also exercise physical-vs-given TMPDIR spellings; the report is written only by the probe.
        real = self.shm / 'td real'
        real.mkdir()
        alias = self.shm / 'td alias'
        alias.symlink_to(real, target_is_directory=True)
        rc, last, out = self.run_smoke(alias, '--stub', 'stderr-only')
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=PASS '), last)
        for run in ('cj-home', 'cj-sibling', 'cj-outside'):
            self.assertIn(run, last.split(' enforced=')[1].split(' ')[0])
        self.assertEqual(out.count('  | codex-stdout-bytes=0\n'), 3)
        self.assertEqual(out.count('  | report-before=missing-or-empty\n'), 3)
        self.assertEqual(out.count('  | report-valid=true\n'), 3)

    def test_mac_fallback_record_is_reproduced_and_located(self):
        # mac-smoke3-533593b: stdout DONE (5 bytes), the probe logs its report WROTE, symlinked TMPDIR, yet the
        # launcher records report-exists=true and report-sha256=missing-or-empty. The same layout with the probe's
        # 44-byte report intact passes; an emptied one is named at every step and never passes.
        real = self.shm / 'td real'
        real.mkdir()
        alias = self.shm / 'td alias'
        alias.symlink_to(real, target_is_directory=True)
        rc, last, out = self.run_smoke(alias, '--stub')
        self.assertEqual(rc, 0, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=PASS '), last)
        self.assertEqual(out.count('  | codex-stdout-bytes=5\n'), 3)
        self.assertEqual(out.count('  | report-state=ok\n'), 3)
        self.assertEqual(out.count('  report timeline: cli-exit python:bytes-44 sh:nonempty; verify ok (44 bytes); '
                                   'finish nonempty; host now python:bytes-44 sh:nonempty\n'), 3)
        rc, last, out = self.run_smoke(alias, '--stub', 'emptied-report')
        self.assertEqual(rc, 1, out[-3000:])
        self.assertTrue(last.startswith('smoke: result=REPORT_FAILURE '), last)
        self.assertIn(' unexpected=none ', last)
        for run in ('cj-home', 'cj-sibling', 'cj-outside'):
            label = 'report' if run == 'cj-outside' else 'fallback-report'
            self.assertIn(f'{run}:{label}-empty', last)
        self.assertEqual(len(re.findall(r'\| report /[^\n]+/REPORT\.txt: WROTE\n', out)), 6)  # transcript + probe log
        for line in ('  | codex-stdout-bytes=5\n', '  | report-exists=true\n', '  | report-sha256=missing-or-empty\n',
                     '  | report-valid=false\n', '  | report-final=empty\n',
                     '  report timeline: cli-exit python:empty sh:empty; verify empty (0 bytes); finish empty; '
                     'host now python:empty sh:empty\n'):
            self.assertEqual(out.count(line), 3, line)

    def test_missing_and_unchanged_reports_still_exit_65(self):
        for mode in ('missing-report', 'unchanged-report'):
            with self.subTest(mode=mode):
                rc, last, out = self.run_smoke(self.shm / 'td', '--stub', mode)
                self.assertEqual(rc, 1, out[-3000:])
                self.assertTrue(last.startswith('smoke: result=REPORT_FAILURE '), last)
                for run in ('cj-home', 'cj-sibling', 'cj-outside'):
                    label = 'report' if run == 'cj-outside' else 'fallback-report'
                    state = 'missing' if mode == 'missing-report' else 'unchanged'
                    self.assertIn(f'{run}:{label}-{state}', last)
                self.assertEqual(out.count('  | report-valid=false\n'), 3)
                self.assertEqual(out.count('launcher exit 65'), 3)

    def test_existing_report_denied_and_failed_replacement_are_named_failures(self):
        for mode in ('existing-report-denied', 'rewrite-denied'):
            with self.subTest(mode=mode):
                rc, last, out = self.run_smoke(self.shm / 'td', '--stub', mode)
                self.assertEqual(rc, 1, out[-3000:])
                self.assertTrue(last.startswith('smoke: result=REPORT_FAILURE '), last)
                self.assertIn(' unexpected=none ', last)
                self.assertIn('cj-outside', last.split(' enforced=')[1].split(' ')[0])
                for run in ('cj-home', 'cj-sibling'):
                    self.assertIn(f'{run}:fallback-report-empty', last)
                self.assertEqual(out.count('  | report-valid=false\n'), 2)
                self.assertEqual(out.count('  | report-valid=true\n'), 1)
                self.assertEqual(out.count('  | control ./smoke-control.txt: WROTE\n'), 14)
                if mode == 'existing-report-denied':
                    self.assertEqual(len(re.findall(r'\| report /[^\n]+/REPORT\.txt: refused:', out)), 4)
                else:
                    self.assertEqual(out.count('stub: replacement refused; new file allowed'), 2)
                    self.assertEqual(len(re.findall(r'\| report /[^\n]+/REPORT\.txt: WROTE\n', out)), 6)

    def test_completed_launcher_probe_with_nonzero_or_timeout_never_passes(self):
        for mode, reason, code in (('cj-fail', 'code-job-exit-7', 7), ('cj-timeout', 'timeout', 124)):
            with self.subTest(mode=mode):
                rc, last, out = self.run_smoke(self.shm / 'td', '--stub', mode)
                self.assertEqual(rc, 0, out[-3000:])
                self.assertTrue(last.startswith('smoke: result=INCONCLUSIVE '), last)
                for run in ('cj-home', 'cj-sibling', 'cj-outside'):
                    self.assertIn(f'{run}:{reason}', last)
                self.assertEqual(out.count(f'completion marker: written; exit: {code}'), 3)


if __name__ == "__main__":
    unittest.main()
